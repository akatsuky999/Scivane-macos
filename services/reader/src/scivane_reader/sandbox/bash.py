"""bash 执行器 —— 在项目目录里跑一条 shell 命令。

三条都不是可选项：

**最小环境。** `build_env()` 从零搭一份环境交给它，用户的 `PATH`、
`SCIVANE_*`、API key 之类一概不在里面。

**不读 dotfiles。** `--noprofile --norc` 让 bash 启动路径上一个用户文件都不读
（`/etc/profile`、`~/.bash_profile`、`~/.bashrc` 全跳过）。配合 `HOME` 被指到
项目内，就算有东西硬要展开 `~` 也落在边界里面。

**工作目录固定为项目根。** agent 写相对路径时的参照点必须是稳定的，
否则同一条命令在不同时刻含义不同。
"""

from __future__ import annotations

from pathlib import Path

from .policy import SandboxPolicy
from .runner import ExecResult, Runner

__all__ = ["BASH", "bash_argv", "run_bash"]

#: 绝对路径。走 PATH 查找的话，PATH 本身就成了可以被换掉的输入。
BASH = "/bin/bash"


def bash_argv(command: str) -> tuple[str, ...]:
    """纯函数，方便测试直接盯住参数形态而不必起进程。"""
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
    """:raises SandboxUnavailable: 沙箱不可用 —— 此时不执行，不降级。"""
    active = runner if runner is not None else Runner()
    return active.run(
        bash_argv(command),
        policy,
        cwd=cwd if cwd is not None else policy.workspace_root,
        timeout=timeout,
        stdin=stdin,
    )
