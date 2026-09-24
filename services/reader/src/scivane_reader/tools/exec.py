"""执行工具：bash 与 python。**一律走第二段的沙箱运行器。**

这两个工具自己不起任何进程 —— 起进程是 `sandbox/runner.py` 的事，边界是
`workspace.sandbox_policy()` 派生的。这条分工不能破：工具里只要出现一次
`subprocess`，沙箱就从「唯一执行路径」退化成「其中一条执行路径」。

**为什么不要求逐次批准。** 沙箱就是为此而建的：项目外写不进去、
`pdf/` 与 `.lumen/` 拦住、dotfiles 与 git hooks 堵上、出网只有一个经审计的口子。
在这个边界内跑命令已经是被约束的动作，再叠一层
逐次确认只会训练用户无脑点同意 —— 那比不问更糟。**装包也在这个边界内**：
项目环境在可写根里、pip 在沙箱里经代理出网，所以 `python`
带 `packages` 也不再弹卡。取代码的 `fetch_repo` 同理 ——
读者这一层已经没有要批准的工具了。

`call_policy` / `call_refusals` / `explain_refusals` / `in_sandbox` 是公开的：
`tools/repo.py` 的 clone 走的是同一个沙箱与同一个代理，这几件事只该有一份。

执行强度如实上报：`ExecResult.enforcement` 是 `partial` 时，把原因一并写进
给模型的文本里 —— 模型据此知道这次结果的可信度打了折扣。
"""

from __future__ import annotations

import asyncio
import subprocess
import time
from pathlib import Path

from ..projects import workspace
from ..sandbox import (
    SandboxError,
    SandboxUnavailable,
    analysis_env,
    analysis_ready,
    ensure_analysis_env,
    install_into_project,
    project_env,
    run_bash,
    run_python,
)
from ..sandbox.policy import NetworkPolicy
from ..sandbox.runner import ExecResult
from .definition import ToolContext, ToolDef, ToolError, ToolOutcome

__all__ = [
    "exec_tools", "DEFAULT_TIMEOUT", "NO_DEVELOPER_TOOLS",
    "call_policy", "call_refusals", "explain_refusals", "in_sandbox",
]

DEFAULT_TIMEOUT = 120.0
MAX_TIMEOUT = 600.0
#: 装包的上限。比执行超时宽得多 —— torch 这类包光下载就要几分钟，
#: 按 120 秒砍掉的话「带 packages」这个能力等于没有。
_INSTALL_TIMEOUT = 900.0
#: 第一次建共享分析环境的上限（建 venv、装三样各算一次）。实测一共 20 秒左右
#: （M5/16GB 实测），给慢网络留足余量。
_ANALYSIS_TIMEOUT = 600.0

# 沙箱运行器是同步阻塞的（subprocess + communicate）。直接在协程里调它会**卡住
# 整个事件循环** —— 一条跑 30 秒的命令期间，SSE 心跳发不出去、别的工具也动不了，
# 「只读工具可并发」会退化成名义上的并发。所以一律 asyncio.to_thread。
# 这一条是被单测里 asyncio 的慢回调告警抓出来的，不是看代码看出来的。


def call_policy(context: ToolContext):
    """派生这一次调用的沙箱边界。**文件与网络两条轴都在这里定。**

    翻译凭据的地方选在这里，而不是 `netproxy/` 里：那个子包不认识
    `SandboxPolicy`，这样两边各自都能单独测，换掉任何一边另一边不用动。
    """
    if context.project_dir is None:
        raise ToolError("这一层 agent 没有项目目录，用不了执行工具", "NO_PROJECT")
    network = None
    if context.network is not None:
        network = NetworkPolicy(
            proxy_port=context.network.port, proxy_token=context.network.token
        )
    return workspace.sandbox_policy(
        Path(context.project_dir), confirmed=context.confirmed, network=network
    )


def _timeout(arguments: dict[str, object]) -> float:
    raw = arguments.get("timeout")
    if isinstance(raw, (int, float)) and raw > 0:
        return min(float(raw), MAX_TIMEOUT)
    return DEFAULT_TIMEOUT


#: 命令没找到时，把模型引到对的工具上。
#:
#: **错误消息是最有效的纠偏位置** —— 模型刚撞墙，正在读这句话，
#: 而且这条路径上它已经证明了自己想干什么。Anthropic 那篇
#: 《Writing effective tools for AI agents》把这条单独拎出来说过：
#: 「tool truncation and error responses can steer agents towards more
#: token-efficient tool-use behaviors」。
#:
#: 实机踩过：模型习惯性地 `bash python -c "..."`，而沙箱 PATH 只有
#: /usr/bin:/bin:/usr/sbin:/sbin，macOS 上根本没有 `python` 这个名字 ——
#: 于是白白烧掉一轮。
_MISSING = {
    "python": "→ 跑 Python 请用 **python 工具**（那里有 numpy / pandas / matplotlib），bash 里没有它。",
    "python3": "→ 跑 Python 请用 **python 工具**，它带着分析环境；bash 里这个解释器没有第三方库。",
    "pip": "→ 装包请用 **python 工具的 `packages` 参数**（在沙箱里装进这个项目自己的环境）；bash 里没有 pip。",
    "rg": "→ 搜内容请用 **grep 工具**，它更快而且直接给 文件:行号: 内容。",
    # curl / git 在 macOS 上是有的（/usr/bin 下），这两条平时不会触发；
    # 留着是为了万一缺失时不要再把模型引回「这里没有网」那条早已不成立的路。
    "curl": "→ 这台机器上没有 curl。取网上的东西可以用 **wget** 或 python 的 urllib —— 沙箱是通网的（经本地审计代理）。",
    "wget": "→ 这台机器上没有 wget。用 **curl** 或 python 的 urllib —— 沙箱是通网的（经本地审计代理）。",
    "git": "→ 这台机器上没有 git。",
}

#: 没装命令行开发者工具的 Mac 上跑 git 的下场。
#:
#: macOS 的 `/usr/bin/git` 是 xcrun 的转发壳（和 clang、make 共用一个二进制），
#: 真正的 git 在开发者工具里 —— 所以这时不会有「command not found」，只有一句
#: `xcrun: error: …`（实测：`DEVELOPER_DIR` 指到不存在的目录时是
#: `xcrun: error: missing DEVELOPER_DIR path: …`）。**干净的 Mac 默认就是这样**，
#: 而 agent 这一侧装不了开发者工具（要管理员密码），所以话要说给用户听，
#: 同时给模型一条不用 git 的路（`/usr/bin/curl` 与 `/usr/bin/tar` 是系统自带的；
#: `archive/HEAD.tar.gz` 2026-09-22 实测会跳到 codeload 拿到默认分支的 tar 包）。
#: `fetch_repo` 与 bash 共用这一句，同一个事实只说一次。
NO_DEVELOPER_TOOLS = (
    "这台 Mac 没装命令行开发者工具，git 跑不起来（/usr/bin/git 只是个转发壳）。"
    "可以请用户在终端跑一次 xcode-select --install（要几分钟）；等不及的话，"
    "GitHub 上的代码用 bash 下 tar 包：curl -L https://github.com/<owner>/<repo>/archive/HEAD.tar.gz "
    "| tar xz -C code/"
)


def _steer(result: ExecResult) -> str:
    """命令不存在时，指一条对的路，而不是只说「not found」。"""
    if result.ok:
        return ""
    if "xcrun: error:" in result.stderr:
        return "→ " + NO_DEVELOPER_TOOLS
    if "command not found" not in result.stderr:
        return ""
    hints: list[str] = []
    for name, hint in _MISSING.items():
        if f"{name}: command not found" in result.stderr and hint not in hints:
            hints.append(hint)
    return "\n".join(hints)


#: 没放行的目的地最多列几个。一个跑飞的重试循环能撞几百次同一个主机 ——
#: 同一个目的地合成一行，不同的也只列前几个，其余报个数。
_REFUSAL_LINES = 5


def call_refusals(context: ToolContext) -> tuple:
    """这次调用被代理拦下了什么。没有网（或代理没起来）就是空的。

    **要在命令跑完之后查。** 代理先落簿、再回 403，所以命令退出的那一刻，
    它撞过的每一条都已经在簿子上了。
    """
    return context.network.refusals() if context.network is not None else ()


def explain_refusals(refusals: tuple) -> str:
    """没过审计代理的连接：主机、端口、为什么。

    **命令那一侧只看得到一个状态码。** curl 说 `CONNECT tunnel failed, response 403`，
    git 说 `unable to access … 403`，pip 说 `ProxyError … 403 Forbidden` —— 模型只能猜，
    而真机上它猜过「沙箱只放行 fetch_repo」，用户会信。原因码早就在审计簿里，
    这里把**这一次调用**的那几条交给它。错误消息是最有效的
    纠偏位置（同 `_MISSING`）。只有主机、端口与原因：路径在审计那一层就不存在。
    """
    grouped: dict[tuple[str, str], list] = {}
    for refusal in refusals:
        grouped.setdefault((refusal.target, refusal.reason), []).append(refusal)
    lines = ["→ 下面这些连接没过本地审计代理（命令那边只会显示 403 / 502，原因在这里）："]
    for (target, reason), same in list(grouped.items())[:_REFUSAL_LINES]:
        times = f"（{len(same)} 次）" if len(same) > 1 else ""
        meaning = same[0].meaning
        lines.append(f"  · {target}{times} —— {reason}" + (f"：{meaning}" if meaning else ""))
    rest = len(grouped) - _REFUSAL_LINES
    if rest > 0:
        lines.append(f"  · 另有 {rest} 个目的地同样没放行")
    return "\n".join(lines)


def _render(result: ExecResult, label: str, *, networked: bool = True,
            refusals: tuple = (), note: str = "") -> ToolOutcome:
    """把执行结果译成给模型看的文本。

    五件事必须说清楚：退出码、有没有撞边界、执行强度是不是打了折、
    **这次到底有没有网**、**连接被拦时拦它的是哪条规则**。只给 stdout 的话，
    一个被沙箱拦住的命令看起来就是「什么都没发生」。

    `networked` 那一条：工具描述说沙箱是通网的（那是设计），但审计代理
    偶尔起不来（那是此刻的事实）。两者分开说 —— 描述属于提示词的静态前缀，
    为一个罕见状态把它做成条件拼接会一直打掉 prompt 缓存（与
    `reocr` 提示词的判断相同）；而**错误消息是最有效的纠偏位置**，模型刚撞墙，
    正在读这句话。

    `refusals` 与退出码无关：脚本自己接住了 403、照样退出 0 的时候，
    「它试过去一个不许去的地方」仍然是模型该知道的事实。没有被拦就一个字都不多。

    `note` 是这次调用顺带做了的事（装了什么包、第一次建了共享环境），放在最前面 ——
    模型要先知道环境变了，才读得懂后面的输出。
    """
    parts: list[str] = [f"退出码 {result.exit_code}"]
    if result.timed_out:
        parts.append("超时被终止")
    if result.denied:
        parts.append(f"有动作被沙箱拦住：{result.denial_hint}")
    if result.enforcement != "full":
        parts.append(f"⚠ 沙箱强度 {result.enforcement} —— {result.enforcement_reason}")
    if not networked and not result.ok:
        parts.append("这次运行没有网络（本地审计代理没起来）—— 联网的命令这一轮都会失败")
    if refusals:
        parts.append("有连接没过本地审计代理（原因见末尾）")
    head = f"[{label}] " + " · ".join(parts)

    body = [note] if note else []
    if result.stdout.strip():
        body.append("stdout:\n" + result.stdout.rstrip())
    if result.stderr.strip():
        body.append("stderr:\n" + result.stderr.rstrip())
    hint = _steer(result)
    if hint:
        body.append(hint)
    if refusals:
        body.append(explain_refusals(refusals))
    return ToolOutcome(
        head + ("\n\n" + "\n\n".join(body) if body else ""),
        is_error=not result.ok,
        detail={
            "exit_code": result.exit_code,
            "enforcement": result.enforcement,
            "denied": result.denied,
            "timed_out": result.timed_out,
        },
    )


async def _bash(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    command = arguments.get("command")
    if not isinstance(command, str) or not command.strip():
        raise ToolError("command 必须是非空字符串", "INVALID_ARGS")
    policy = call_policy(context)
    try:
        result = await asyncio.to_thread(
            run_bash, command, policy, timeout=_timeout(arguments)
        )
    except SandboxUnavailable as exc:
        # 沙箱不可用只有一条正确反应：拒绝执行。绝不降级成无约束执行 ——
        # 用户看不出区别，而那正是最危险的情况。
        raise ToolError(str(exc), exc.code) from exc
    except SandboxError as exc:
        raise ToolError(str(exc), exc.code) from exc
    return _render(result, "bash", networked=policy.network.enabled,
                   refusals=call_refusals(context))


def _packages(arguments: dict[str, object]) -> tuple[str, ...]:
    """要装的包。形状不对就当没有 —— 模型会从结果里看出没装上，
    而不是装了一个它没想要的东西。"""
    raw = arguments.get("packages")
    if raw is None:
        return ()
    if not isinstance(raw, list) or not all(isinstance(p, str) for p in raw):
        return ()
    return tuple(p.strip() for p in raw if p.strip())


def _existing_env(context: ToolContext):
    """不装包时用哪个环境。

    **项目环境优先。** 之前某一轮装过 torch，后面每次调用都该继续看得见它；
    退回共享环境的话，模型会遇到「刚装完就又 ModuleNotFoundError」——
    那比一开始就没有更让人困惑。反过来的代价是项目环境里没有共享环境那三样，
    所以结果的标签上写明这次用的是哪个环境（`_label`）。
    """
    if context.project_dir is not None:
        project = project_env(context.project_dir)
        if project.exists:
            return project
    return analysis_env()


def _label(env, context: ToolContext) -> str:
    """结果行上的标签。用的是项目环境时说出来 —— 那里没有共享环境的 numpy 三件，
    模型撞上 ModuleNotFoundError 时要能自己想明白为什么。"""
    if context.project_dir is not None and env.root == project_env(context.project_dir).root:
        return "python · 项目环境 workbench/.venv"
    return "python"


async def in_sandbox(run, *args, **kwargs):
    """在工作线程里跑一次沙箱执行。沙箱不可用只有一条正确反应：拒绝执行 ——
    装包也一样，**绝不退回宿主端装**（用户看不出区别，而那正是最危险的情况）。"""
    try:
        return await asyncio.to_thread(run, *args, **kwargs)
    except SandboxUnavailable as exc:
        raise ToolError(str(exc), exc.code) from exc
    except SandboxError as exc:
        raise ToolError(str(exc), exc.code) from exc


def _pip_tail(exc: subprocess.CalledProcessError) -> str:
    """pip 失败时最后那几行 —— 连不上 PyPI、版本冲突、磁盘满，原因都在那里。"""
    text = (exc.stderr or exc.stdout or b"").decode("utf-8", "replace").strip()
    return text[-800:]


async def _build_analysis_env() -> float:
    """第一次有人跑 python 时，在宿主端把共享分析环境建好。返回用了几秒。

    这一步留在宿主端是被迫的：共享环境住在所有项目之外，沙箱写不到那里。
    它装的是 App 自己定的三样东西，与 OCR 组件同一类，
    不是 agent 挑的包，所以不走审计代理。
    """
    started = time.monotonic()
    try:
        await asyncio.to_thread(ensure_analysis_env, timeout=_ANALYSIS_TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        raise ToolError(
            f"共享分析环境 {int(_ANALYSIS_TIMEOUT)} 秒还没建好，已放弃 —— 多半是网络太慢",
            "ENV_BUILD_TIMEOUT",
        ) from exc
    except subprocess.CalledProcessError as exc:
        raise ToolError(f"共享分析环境建不起来：\n{_pip_tail(exc)}", "ENV_BUILD_FAILED") from exc
    return time.monotonic() - started


async def _python(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    code = arguments.get("code")
    if not isinstance(code, str) or not code.strip():
        raise ToolError("code 必须是非空字符串", "INVALID_ARGS")
    policy = call_policy(context)
    wanted = _packages(arguments)
    note = ""
    if wanted:
        # **装包在沙箱里做**。项目环境在可写根里，pip 经本地审计代理出网 ——
        # 用的就是这一次调用的边界与凭据，所以审计簿上的 pypi.org 归在这一次调用名下。
        # 装进项目自己的环境而不是共享分析环境：一篇论文要 torch 不等于别的项目也要，
        # 而且共享环境在项目外，沙箱本来就写不进去。
        fresh = not project_env(context.project_dir).exists
        started = time.monotonic()
        installed = await in_sandbox(
            install_into_project, context.project_dir, wanted, policy, timeout=_INSTALL_TIMEOUT
        )
        if not installed.ok:
            # 装不上就不跑代码 —— 跑了只会再撞一次 ModuleNotFoundError，
            # 把真正的原因（pip 的输出、被代理拦下的主机）挤到后面去。
            return _render(installed, "python · 装包没成功，代码没有跑",
                           networked=policy.network.enabled, refusals=call_refusals(context))
        env = project_env(context.project_dir)
        seconds = time.monotonic() - started
        note = f"装包：{' '.join(wanted)} 装进了这个项目自己的环境（用了 {seconds:.0f} 秒）。"
        if fresh:
            note += ("这个项目之后的 python 调用都用这个环境 —— 共享环境里的 "
                     "numpy / pandas / matplotlib 不在其中，要用就一并写进 packages。")
    else:
        env = _existing_env(context)
        if env == analysis_env() and not analysis_ready():
            seconds = await _build_analysis_env()
            note = (f"第一次用 python：刚在这台机器上建好共享分析环境"
                    f"（numpy / pandas / matplotlib，用了 {seconds:.0f} 秒），以后不用再等。")
    result = await in_sandbox(run_python, code, policy, env=env, timeout=_timeout(arguments))
    return _render(result, _label(env, context), networked=policy.network.enabled,
                   refusals=call_refusals(context), note=note)


def exec_tools() -> tuple[ToolDef, ...]:
    timeout_schema = {
        "type": "number",
        "description": f"超时秒数，默认 {int(DEFAULT_TIMEOUT)}，上限 {int(MAX_TIMEOUT)}",
    }
    return (
        ToolDef(
            name="bash",
            description=(
                "跑一条**真正需要 shell** 的命令：管道、循环、仓库里自带的脚本。"
                "工作目录是项目根，项目外写不进去，pdf/ 与 .lumen/ 不可访问。\n\n"
                "**可以联网**：curl、git clone、下开源数据都行，代理已经配在环境变量里，"
                "不用自己设。出口是本机的审计代理，它会记下你访问过哪些主机"
                "（只记主机名和端口，不记路径）并显示给用户。连本机地址会被拒绝。\n\n"
                "**有专用工具的事不要用它做** —— 读文件用 read、找文件用 glob、"
                "搜内容用 grep、改文件用 edit。那些更快、输出更干净，"
                "用户也看得更清楚。\n"
                "**这里没有 python**：沙箱的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，"
                "macOS 上没有 `python` 这个名字。要跑 Python 用 python 工具，"
                "那里才有 numpy / pandas / matplotlib。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "要跑的命令"},
                    "timeout": timeout_schema,
                },
                "required": ["command"],
            },
            run=_bash,
        ),
        ToolDef(
            name="python",
            description=(
                "跑一段 Python。**这是跑 Python 的唯一入口** —— bash 的 PATH 里"
                "没有 python。numpy / pandas / matplotlib 开箱可用。"
                "工作目录是 workbench/outputs/，画出来的图默认落在那里。"
                "代码本身在沙箱里跑，**可以联网**（经本机审计代理，"
                "代理已配在环境变量里；标准库的 urllib 直接用即可）。\n\n"
                "**缺库不要放弃，用 `packages` 装。** 复现论文经常要 torch、"
                "scipy、sklearn、requests 这些 —— 把包名填进 `packages`，会在沙箱里"
                "装进这个项目自己的环境（workbench/.venv，不用等用户批准），"
                "装一次之后这个项目后续的调用都用它。**项目环境是独立的**："
                "共享环境里的 numpy / pandas / matplotlib 不在其中，要用就一并写进 packages。"
                "拿到 ModuleNotFoundError 时的正确反应是重试一次并带上 `packages`，"
                "而不是改写成纯 numpy 或者就此收工。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "code": {"type": "string", "description": "要跑的 Python 代码"},
                    "packages": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": (
                            "缺的第三方包（pip 名字，可带版本，如 torch 或 numpy==1.26）。"
                            "已经有的不用填。在沙箱里经审计代理装进这个项目自己的环境。"
                        ),
                    },
                    "timeout": timeout_schema,
                },
                "required": ["code"],
            },
            run=_python,
            # **不设 needs_approval，带不带 packages 都一样。** 装包从前要点头，
            # 因为它要越出沙箱联网；如今项目环境在可写根里、pip 在沙箱里
            # 经审计代理出网，这一次调用与别的沙箱内命令没有区别了。
            # 再弹卡只会训练用户闭着眼睛点 —— 那道门留给真正越出沙箱的动作。
        ),
    )
