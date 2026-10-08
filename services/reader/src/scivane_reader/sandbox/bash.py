"""Shell executor: one command in the project directory.

Minimal environment from build_env() (no user PATH, SCIVANE_* or keys), no dotfiles
(--noprofile --norc, with HOME inside the project), and the project root as the working
directory so relative paths always mean the same thing.
"""

from __future__ import annotations

from pathlib import Path

from .policy import SandboxPolicy
from .runner import ExecResult, Runner

__all__ = ["BASH", "bash_argv", "run_bash"]

#: absolute path: PATH is a tainted input
BASH = "/bin/bash"


def bash_argv(command: str) -> tuple[str, ...]:
    """Pure, so tests can check the arguments without starting a process."""
    return (BASH, "--noprofile", "--norc", "-c", command)


def run_bash(
    command: str,
    policy: SandboxPolicy,
    *,
    runner: Runner | None = None,
    cwd: Path | None = None,
    timeout: float | None = None,
    stdin: str | None = None,
) -> ExecResult:
    """Raises SandboxUnavailable when there is no sandbox; never runs unconfined."""
    active = runner if runner is not None else Runner()
    return active.run(
        bash_argv(command),
        policy,
        cwd=cwd if cwd is not None else policy.workspace_root,
        timeout=timeout,
        stdin=stdin,
    )
