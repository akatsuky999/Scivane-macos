"""git executor: shallow-clone a remote repository into the workspace, inside the sandbox.

Source validation (sites, URL shape, target dir) belongs to tools/repo.py; this layer only
starts the process. https only (protocol.allow=never plus https): ext:: can run commands and
file:// can read host repositories. Hooks never run: core.hooksPath=/dev/null for the clone,
the Runner's empty hooks dir afterwards, and copied hook files are deleted by the tool layer.
Shallow, single branch: a paper needs the current code, not hundreds of MB of history.
"""

from __future__ import annotations

from pathlib import Path

from .policy import SandboxPolicy
from .runner import ExecResult, Runner

__all__ = ["GIT", "clone_argv", "run_git_clone"]

#: Absolute path, as in bash.py. On macOS this is an xcrun shim; without the command line tools
#: it can't run, which tools/repo.py reports as GIT_MISSING.
GIT = "/usr/bin/git"


def clone_argv(url: str, target: Path) -> tuple[str, ...]:
    """Pure, so tests can check the arguments. `--` before the URL so this function doesn't rely on
    callers to keep options out.
    """
    return (
        GIT,
        "-c", "core.hooksPath=/dev/null",
        "-c", "protocol.allow=never",
        "-c", "protocol.https.allow=always",
        "clone", "--depth", "1", "--single-branch",
        "--", url, str(target),
    )


def run_git_clone(
    url: str,
    target: Path,
    policy: SandboxPolicy,
    *,
    runner: Runner | None = None,
    timeout: float | None = None,
) -> ExecResult:
    """Clone inside the sandbox; `policy` alone decides network and write access.

    Raises SandboxUnavailable when there is no sandbox; never falls back to a host-side clone.
    """
    active = runner if runner is not None else Runner()
    return active.run(
        clone_argv(url, target), policy, cwd=policy.workspace_root, timeout=timeout
    )
