"""Execution tools: bash and python, always through the sandbox runner.

These tools never start processes themselves; the boundary comes from
workspace.sandbox_policy(). One stray subprocess call would make the sandbox one path among
several. No per-call approval: commands inside the sandbox (including pip, through the audit
proxy) are already confined, and constant confirmation trains people to click yes.

call_policy, call_refusals, explain_refusals and in_sandbox are shared with tools/repo.py.
Partial enforcement is reported in the text the model sees.
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
#: far longer than the command timeout: packages like torch take minutes to download
_INSTALL_TIMEOUT = 900.0
#: first build of the shared analysis env, about 20 s on a fast connection
_ANALYSIS_TIMEOUT = 600.0

# The sandbox runner blocks (subprocess + communicate). Calling it from a coroutine would freeze
# the event loop (no SSE heartbeats, no concurrent tools), so it always goes through to_thread.


def call_policy(context: ToolContext):
    """This call's sandbox boundary, files and network both. The credential is translated here rather
    than in netproxy/, which knows nothing about SandboxPolicy.
    """
    if context.project_dir is None:
        raise ToolError("这一层 agent 没有项目目录，用不了执行工具", "NO_PROJECT")
    network = None
    if context.network is not None:
        network = NetworkPolicy(
            proxy_port=context.network.port, proxy_token=context.network.token
        )
    return workspace.sandbox_policy(Path(context.project_dir), network=network)


def _timeout(arguments: dict[str, object]) -> float:
    raw = arguments.get("timeout")
    if isinstance(raw, (int, float)) and raw > 0:
        return min(float(raw), MAX_TIMEOUT)
    return DEFAULT_TIMEOUT


#: Point the model at the right tool when a command is missing. An error message is read right
#: after hitting the wall, which makes it the best place to steer: models habitually run
#: `python -c`, and the sandbox PATH has no `python` on macOS.
_MISSING = {
    "python": "→ 跑 Python 请用 **python 工具**（那里有 numpy / pandas / matplotlib），bash 里没有它。",
    "python3": "→ 跑 Python 请用 **python 工具**，它带着分析环境；bash 里这个解释器没有第三方库。",
    "pip": "→ 装包请用 **python 工具的 `packages` 参数**（在沙箱里装进这个项目自己的环境）；bash 里没有 pip。",
    "rg": "→ 搜内容请用 **grep 工具**，它更快而且直接给 文件:行号: 内容。",
    # curl and git exist under /usr/bin; these entries only matter if they are missing, and must not
    # suggest that there is no network
    "curl": "→ 这台机器上没有 curl。取网上的东西可以用 **wget** 或 python 的 urllib —— 沙箱是通网的（经本地审计代理）。",
    "wget": "→ 这台机器上没有 wget。用 **curl** 或 python 的 urllib —— 沙箱是通网的（经本地审计代理）。",
    "git": "→ 这台机器上没有 git。",
}

#: git on a Mac without the command line tools: /usr/bin/git is an xcrun shim that fails with
#: `xcrun: error: ...` rather than "command not found". The agent can't install the tools (that
#: needs an admin password), so the message speaks to the user and offers a git-free route
#: (curl and tar ship with macOS). Shared by fetch_repo and bash.
NO_DEVELOPER_TOOLS = (
    "这台 Mac 没装命令行开发者工具，git 跑不起来（/usr/bin/git 只是个转发壳）。"
    "可以请用户在终端跑一次 xcode-select --install（要几分钟）；等不及的话，"
    "GitHub 上的代码用 bash 下 tar 包：curl -L https://github.com/<owner>/<repo>/archive/HEAD.tar.gz "
    "| tar xz -C code/"
)


def _steer(result: ExecResult) -> str:
    """Point to the right route when a command doesn't exist, rather than just "not found"."""
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


#: at most this many refused destinations listed; a runaway retry loop can hit one host hundreds
#: of times
_REFUSAL_LINES = 5


def call_refusals(context: ToolContext) -> tuple:
    """What the proxy refused for this call; empty without network. Checked after the command exits:
    the proxy records before answering 403, so everything is in the log by then.
    """
    return context.network.refusals() if context.network is not None else ()


def explain_refusals(refusals: tuple) -> str:
    """Connections the proxy refused: host, port and why.

    Commands only see a status code (curl: "CONNECT tunnel failed, response 403"), and models
    invent a reason. The reason codes are already in the audit log; this hands over this call's.
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
    """Turn an execution result into text for the model: exit code, whether the boundary was hit,
    whether enforcement was partial, whether there was network, and which rule refused a
    connection. Network availability is stated here rather than in the tool description, which is
    part of the cached prompt prefix. Refusals are reported even with exit code 0. `note` (packages
    installed, shared env built) comes first so the output makes sense.
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
        # no sandbox means refusing to run; never fall back to unconfined execution
        raise ToolError(str(exc), exc.code) from exc
    except SandboxError as exc:
        raise ToolError(str(exc), exc.code) from exc
    return _render(result, "bash", networked=policy.network.enabled,
                   refusals=call_refusals(context))


def _packages(arguments: dict[str, object]) -> tuple[str, ...]:
    """Packages to install. Malformed input counts as none: better nothing installed than the wrong thing."""
    raw = arguments.get("packages")
    if raw is None:
        return ()
    if not isinstance(raw, list) or not all(isinstance(p, str) for p in raw):
        return ()
    return tuple(p.strip() for p in raw if p.strip())


def _existing_env(context: ToolContext):
    """Environment for runs without packages: the project env first, so a package installed in an
    earlier turn stays importable. The label says which env was used.
    """
    if context.project_dir is not None:
        project = project_env(context.project_dir)
        if project.exists:
            return project
    return analysis_env()


def _label(env, context: ToolContext) -> str:
    """Label for the result line. Names the project env, which lacks the shared env's numpy, pandas
    and matplotlib.
    """
    if context.project_dir is not None and env.root == project_env(context.project_dir).root:
        return "python · 项目环境 workbench/.venv"
    return "python"


async def in_sandbox(run, *args, **kwargs):
    """Run one sandboxed execution in a worker thread. No sandbox means refusing, for installs too;
    never install on the host instead.
    """
    try:
        return await asyncio.to_thread(run, *args, **kwargs)
    except SandboxUnavailable as exc:
        raise ToolError(str(exc), exc.code) from exc
    except SandboxError as exc:
        raise ToolError(str(exc), exc.code) from exc


def _pip_tail(exc: subprocess.CalledProcessError) -> str:
    """The last lines of pip's output, where the reason is (no PyPI, version conflict, full disk)."""
    text = (exc.stderr or exc.stdout or b"").decode("utf-8", "replace").strip()
    return text[-800:]


async def _build_analysis_env() -> float:
    """Build the shared analysis env on the host the first time python runs; returns the seconds taken.

    Host-side because it lives outside every project. It installs the app's fixed package set,
    not packages the agent chose, so it doesn't go through the audit proxy.
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
        # Packages are installed inside the sandbox with this call's boundary and credential, so pypi.org
        # is attributed to this call. Into the project env, not the shared one: one paper needing torch
        # doesn't mean every project does.
        fresh = not project_env(context.project_dir).exists
        started = time.monotonic()
        installed = await in_sandbox(
            install_into_project, context.project_dir, wanted, policy, timeout=_INSTALL_TIMEOUT
        )
        if not installed.ok:
            # don't run the code after a failed install: the ModuleNotFoundError would bury the real reason
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
            # No needs_approval, with or without packages: installing now happens inside the sandbox like
            # any other command.
        ),
    )
