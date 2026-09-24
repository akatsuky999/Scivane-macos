"""取论文代码：`fetch_repo` 在**沙箱里**经本机审计代理 clone。

它和在 `bash` 里敲一条 `git clone` 走的是同一个沙箱、同一个针孔、同一本审计簿，
所以**不再要用户点头**。从前它在宿主端跑、每次弹一张批准卡 —— 那是「沙箱内无网」
时代的形状。沙箱通网之后，宿主端这一条反倒成了**目的地由 agent
挑、流量却不进审计簿**的唯一一条路：批准卡上点一次同意，那次 clone 去过哪就没有记录。
（宿主端建共享分析环境的 pip 也不经代理，但它的目的地是 App 定的，不是 agent 挑的。）
搬进沙箱之后，它去过哪个主机和别的工具一样记在这次调用名下、冒到工具卡上。

**那为什么还留着这个工具，而不是让模型自己 `bash git clone`？** 它把「取这篇论文的
代码」做成一次有名字的动作：地址规范化（`owner/repo` 简写）、只认代码托管站点、
落点固定在 `code/<仓库名>`、clone 完剥掉 hook、结果里报文件数。模型一句话就要到一份
干净的代码；站点不在名单上时，错误消息把它引到 bash —— 那条路同样在沙箱里。

从宿主端时代留下、理由没变的四道：

1. **白名单而不是黑名单**（`ALLOWED_HOSTS`）—— 这个工具的语义就是「代码托管站点上的
   论文代码」；列不全的后果是模型被引去用 bash（看得见），不是去了一个没想到的地方。
2. **只接受 https** —— SSH 要用到用户的私钥，那不是 agent 该碰的东西。
3. **仓库名不许以点开头**（`_NAME_OK`）—— `..` 会让落点变成项目根。
4. **落点过一遍 `workspace.resolve()`，clone 完剥掉 hook** —— 沙箱那一层已经让 hook
   不跑（`sandbox/git.py`），这里再把 hook 文件本身删掉：两道，因为这一条出事的代价太大。
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path
from urllib.parse import urlparse

from ..projects import workspace
from ..sandbox import run_git_clone
from .definition import ToolContext, ToolDef, ToolError, ToolOutcome
from .exec import NO_DEVELOPER_TOOLS, call_policy, call_refusals, explain_refusals, in_sandbox

__all__ = ["repo_tools", "ALLOWED_HOSTS", "normalise_repo_url", "strip_hooks", "CLONE_TIMEOUT"]

#: 这个工具认得的代码托管站点。**只是这个工具的语义，不是沙箱的边界** ——
#: 沙箱放行所有公网主机（经审计代理），别的站点用 bash 的 git clone 一样取得到。
ALLOWED_HOSTS: frozenset[str] = frozenset({
    "github.com", "gitlab.com", "bitbucket.org", "codeberg.org",
    "huggingface.co", "git.sr.ht",
})

#: 能安全用作目录名的仓库名。
#:
#: 点号必须允许（`vision-transformer.pytorch` 这类名字很常见），但**不能允许
#: 以点开头** —— `..` 会让落点变成 `code/..` 也就是项目根，`.lumen` 之类的
#: 名字则会撞上控制面。`workspace.resolve()` 确实会再兜一次，但让越界路径
#: 走到那一步已经是「一条边界两条路径」了，第一道就该拦住。
_NAME_OK = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")

#: 一次 clone 的上限。浅克隆一个论文仓库通常几秒；给大仓库和慢网络留足余量。
CLONE_TIMEOUT = 300.0

#: git 的报错里，最后几行才是原因（前面是 `Cloning into …` 之类的进度）。
_STDERR_LINES = 3


def normalise_repo_url(raw: str) -> tuple[str, str]:
    """校验来源并返回 `(规范 URL, 目录名)`。

    :raises ToolError: 不在白名单、或形状不对。
    """
    text = raw.strip()
    if not text:
        raise ToolError("url 不能为空", "INVALID_ARGS")
    # 允许 owner/repo 简写，但只认 GitHub —— 简写在别的站点上有歧义
    if "/" in text and "://" not in text and not text.startswith("git@"):
        parts = text.split("/")
        if len(parts) == 2 and all(_NAME_OK.match(p) for p in parts):
            text = f"https://github.com/{parts[0]}/{parts[1]}"
    if text.startswith("git@"):
        raise ToolError(
            "只接受 https 地址 —— SSH 要用到用户的私钥，那不是 agent 该碰的东西",
            "SCHEME_REFUSED",
        )

    parsed = urlparse(text)
    if parsed.scheme != "https":
        raise ToolError(f"只接受 https，拿到的是 {parsed.scheme or '（无）'}", "SCHEME_REFUSED")
    host = (parsed.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        allowed = "、".join(sorted(ALLOWED_HOSTS))
        # **错误消息是最有效的纠偏位置**（同 exec.py 的 `_MISSING`）：名单只是这个工具的
        # 语义，不是沙箱的边界。不说这一句，模型会以为「那个站点取不到」然后就此收工。
        raise ToolError(
            f"{host or '（空）'} 不在 fetch_repo 认得的代码站点里（认得：{allowed}）。"
            "别的站点的代码用 bash 的 git clone 或 curl 取 —— 沙箱是通网的，"
            "落点请放在 code/ 下面",
            "HOST_REFUSED",
        )

    segments = [s for s in parsed.path.split("/") if s]
    if len(segments) < 2:
        raise ToolError("地址里看不出 owner/repo", "INVALID_ARGS")
    name = segments[1].removesuffix(".git")
    if not _NAME_OK.match(name):
        # 目录名直接来自 URL，不校验就能用 ../ 写到 code/ 外面去
        raise ToolError(f"仓库名里有不能做目录名的字符：{name}", "INVALID_ARGS")
    return f"https://{host}/{segments[0]}/{name}", name


def strip_hooks(repo: Path) -> int:
    """删掉仓库里所有 git hook。返回删了几个。

    删的是链接本身而不是它指向的东西（`unlink`），所以一个指向项目外的 hook
    链接也只会被摘掉，碰不到项目外的文件。
    """
    removed = 0
    for hooks in repo.rglob(".git/hooks"):
        if not hooks.is_dir():
            continue
        for entry in hooks.iterdir():
            if entry.is_file() or entry.is_symlink():
                entry.unlink()
                removed += 1
    return removed


def _discard(target: Path) -> None:
    """clone 没成：把半截目录收掉。

    只收这次 clone 自己建的东西 —— 开跑前已经确认过 `target` 不存在。
    `rmtree` 不跟符号链接，也不肯删一个本身就是链接的根。
    """
    shutil.rmtree(target, ignore_errors=True)


def _failure(stderr: str, stdout: str, exit_code: int) -> str:
    lines = [line for line in (stderr or stdout or "").strip().splitlines() if line.strip()]
    return "\n".join(lines[-_STDERR_LINES:]) if lines else f"退出码 {exit_code}"


async def _fetch_repo(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    if context.project_dir is None:
        raise ToolError("这一层 agent 没有项目目录，放不下代码", "NO_PROJECT")
    raw = arguments.get("url")
    if not isinstance(raw, str):
        raise ToolError("url 必须是字符串", "INVALID_ARGS")
    url, name = normalise_repo_url(raw)

    root = Path(context.project_dir)
    # 落点照样过一遍边界解析器 —— 沙箱会再兜一次，但越界的路径不该走到那一步
    try:
        target = workspace.resolve(root, f"{workspace.CODE_DIR}/{name}", write=True)
    except workspace.WorkspaceError as exc:
        raise ToolError(str(exc), exc.code) from exc
    if target.exists() or target.is_symlink():
        raise ToolError(f"code/{name} 已经存在 —— 先删掉或换个名字", "EXISTS")

    if context.network is None:
        # 没网就不跑：跑了只会等到 git 自己连不上，再把一句难懂的报错交回来。
        # 与 bash / python 不同，这个工具的全部意义就是联网，没有「本地也能干一半」。
        raise ToolError("这一轮没有网络（本地审计代理没起来），取不了代码", "NO_NETWORK")

    policy = call_policy(context)
    result = await in_sandbox(run_git_clone, url, target, policy, timeout=CLONE_TIMEOUT)
    refusals = call_refusals(context)

    if result.timed_out:
        _discard(target)
        raise ToolError(f"clone 超时（{int(CLONE_TIMEOUT)} 秒），已放弃", "TIMEOUT")
    if not result.ok:
        _discard(target)
        if "xcrun: error:" in result.stderr:
            raise ToolError(NO_DEVELOPER_TOOLS, "GIT_MISSING")
        message = "clone 失败：" + _failure(result.stderr, result.stdout, result.exit_code)
        if result.denied:
            message += f"\n有动作被沙箱拦住：{result.denial_hint}"
        if refusals:
            message += "\n\n" + explain_refusals(refusals)
        raise ToolError(message, "CLONE_FAILED")

    removed = strip_hooks(target)
    files = sum(1 for p in target.rglob("*") if p.is_file() and ".git" not in p.parts)
    text = (f"已把 {url} 放进 code/{name}（浅克隆，{files} 个文件，剥掉 {removed} 个 git hook）。"
            "它在沙箱的可写区域内，bash 与 python 可以跑它。")
    if result.enforcement != "full":
        # 执行强度如实上报（exec.py 同一条）：模型据此知道这次的约束打了折扣
        text += f"\n⚠ 沙箱强度 {result.enforcement} —— {result.enforcement_reason}"
    return ToolOutcome(
        text,
        detail={
            "url": url, "path": f"code/{name}", "files": files, "hooks_removed": removed,
            # 同 bash / python：沙箱强度不足是可报告的事实，要能冒到界面上
            "enforcement": result.enforcement,
        },
    )


def repo_tools() -> tuple[ToolDef, ...]:
    return (
        ToolDef(
            name="fetch_repo",
            description=(
                "取这篇论文的开源实现，放进 code/<仓库名>（浅克隆：只取最新一版，不带历史）。"
                f"认得的站点：{'、'.join(sorted(ALLOWED_HOSTS))}；"
                "别的站点用 bash 的 git clone。\n\n"
                "在沙箱里经本机审计代理下载，和 bash 联网是同一个口子 —— 不用等用户批准，"
                "用户会看到访问过哪个主机。clone 下来的 git hook 会被删掉。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "https 仓库地址，或 owner/repo 简写（GitHub）",
                    }
                },
                "required": ["url"],
            },
            run=_fetch_repo,
            # **不设 needs_approval。** 从前要点头，因为它是越出沙箱的动作（宿主端联网）；
            # 搬进沙箱之后它与 bash 里的 git clone 没有区别了。
            # 再弹卡只会训练用户闭着眼睛点 —— 那道门留给书房的 `delete_project`。
        ),
    )
