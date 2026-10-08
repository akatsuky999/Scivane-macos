"""fetch_repo: clone a paper's code inside the sandbox, through the audit proxy.

Same sandbox, pinhole and audit log as a `git clone` in bash, so no approval is needed, and the
hosts it reaches show up on the tool card. The tool still exists because it makes "get this
paper's code" one named action: owner/repo shorthand, known code hosts only, a fixed target
(code/<name>), hooks stripped, file count reported. Other hosts are reachable from bash.

Allowlisted hosts only, https only (SSH would need the user's private key), no repository names
starting with a dot ('..' would target the project root), the target passes
workspace.resolve(), and hook files are deleted after the clone.
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

#: Hosts this tool knows. The tool's meaning, not a sandbox boundary: bash can clone from anywhere public.
ALLOWED_HOSTS: frozenset[str] = frozenset({
    "github.com", "gitlab.com", "bitbucket.org", "codeberg.org",
    "huggingface.co", "git.sr.ht",
})

#: Repository names usable as directory names. Dots are common (vision-transformer.pytorch) but a
#: leading dot is not allowed: '..' would target the project root and '.lumen' the control plane.
_NAME_OK = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")

#: a shallow clone of a paper repo usually takes seconds
CLONE_TIMEOUT = 300.0

#: git's reason is in the last lines; earlier ones are progress
_STDERR_LINES = 3


def normalise_repo_url(raw: str) -> tuple[str, str]:
    """Validate the source and return (canonical URL, directory name); raises ToolError."""
    text = raw.strip()
    if not text:
        raise ToolError("url 不能为空", "INVALID_ARGS")
    # owner/repo shorthand is GitHub only; it is ambiguous elsewhere
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
        # Say the allowlist is this tool's, not the sandbox's, or the model concludes the site is unreachable.
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
        # the directory name comes from the URL; unchecked, ../ would escape code/
        raise ToolError(f"仓库名里有不能做目录名的字符：{name}", "INVALID_ARGS")
    return f"https://{host}/{segments[0]}/{name}", name


def strip_hooks(repo: Path) -> int:
    """Delete every git hook in the repository; returns how many. unlink removes the link itself, so a
    hook pointing outside the project can't touch anything there.
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
    """A failed clone: remove the partial directory, which this clone created (target didn't exist).
    rmtree doesn't follow symlinks.
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
    # the target goes through the boundary resolver too; the sandbox would catch it, but it shouldn't get that far
    try:
        target = workspace.resolve(root, f"{workspace.CODE_DIR}/{name}", write=True)
    except workspace.WorkspaceError as exc:
        raise ToolError(str(exc), exc.code) from exc
    if target.exists() or target.is_symlink():
        raise ToolError(f"code/{name} 已经存在 —— 先删掉或换个名字", "EXISTS")

    if context.network is None:
        # No network, no run: unlike bash or python this tool can do nothing offline.
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
        # report partial enforcement, as exec.py does
        text += f"\n⚠ 沙箱强度 {result.enforcement} —— {result.enforcement_reason}"
    return ToolOutcome(
        text,
        detail={
            "url": url, "path": f"code/{name}", "files": files, "hooks_removed": removed,
            # partial enforcement must reach the UI
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
            # No needs_approval: inside the sandbox this is the same as git clone in bash.
        ),
    )
