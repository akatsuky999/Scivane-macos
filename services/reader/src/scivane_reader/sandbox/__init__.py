"""沙箱与执行：让 agent 能在项目目录里安全地跑命令。

分三层，换实现时只动中间那层：

    policy.py    只定义接口与词汇 —— 不知道 Seatbelt，也不知道「论文」
    seatbelt.py  当前实现：生成 .sb 并用 sandbox-exec 起进程
    runner.py    对上的统一执行接口
    bash.py      shell 执行器（最小环境、不读 dotfiles、cwd=项目根）
    python.py    Python 执行器（自带解释器建环境、产物落 workbench/outputs/）
    git.py       git 执行器（只走 https 的浅克隆，hook 不跑）
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
