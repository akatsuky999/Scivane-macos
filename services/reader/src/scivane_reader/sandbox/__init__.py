"""Sandboxed execution of the agent's commands inside a project directory.

    policy.py    interface and vocabulary only; knows neither Seatbelt nor papers
    seatbelt.py  the current backend: writes an .sb profile, runs sandbox-exec
    runner.py    the execution interface consumers use
    bash.py      shell executor (minimal env, no dotfiles, cwd = project root)
    python.py    Python executor (bundled interpreter, outputs in workbench/outputs/)
    git.py       git executor (https-only shallow clones, hooks never run)
"""

from __future__ import annotations

from .bash import bash_argv, run_bash
from .git import clone_argv, run_git_clone
from .policy import (
    REQUIRED_WRITE_SINKS,
    ConfinedCommand,
    FilePolicy,
    NetworkPolicy,
    RunnerFailureRule,
    SandboxEnforcement,
    SandboxError,
    SandboxMode,
    SandboxPolicy,
    SandboxProvider,
    SandboxRunnerFailed,
    SandboxUnavailable,
)
from .python import (
    ANALYSIS_PACKAGES,
    PythonEnv,
    analysis_env,
    analysis_ready,
    create_project_env,
    ensure_analysis_env,
    install_into_project,
    interpreter,
    project_env,
    python_argv,
    run_python,
)
from .runner import MINIMAL_PATH, ExecResult, Runner, build_env
from .seatbelt import SeatbeltProvider, build_profile

__all__ = [
    "SandboxMode", "SandboxEnforcement", "FilePolicy", "SandboxPolicy",
    "RunnerFailureRule", "ConfinedCommand", "SandboxProvider",
    "SandboxError", "SandboxUnavailable", "SandboxRunnerFailed",
    "REQUIRED_WRITE_SINKS",
    "SeatbeltProvider", "build_profile",
    "Runner", "ExecResult", "build_env", "MINIMAL_PATH",
    "run_bash", "bash_argv",
    "run_git_clone", "clone_argv",
    "run_python", "python_argv", "PythonEnv", "ANALYSIS_PACKAGES", "interpreter",
    "analysis_env", "analysis_ready", "ensure_analysis_env",
    "project_env", "create_project_env", "install_into_project",
]
