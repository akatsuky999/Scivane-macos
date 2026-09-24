"""git 执行器 —— 在沙箱里把一个远端仓库浅克隆进工作区。

和 bash / python 两个执行器一样，这一层只管「怎么起这个进程」。**来源校验**
（哪些站点、URL 长什么样、落在哪个目录）是工具层的事（`tools/repo.py`），
这一层不知道「论文代码」是什么 —— Seatbelt 会消失，这一层必须能整个换掉。

三条都不是可选项：

**只走 https。** `protocol.allow=never` 再单开 `https`：工具层给的地址永远是 https，
其余协议一个都用不上。`ext::` 能让一个 URL 直接跑命令，`file://` 能把宿主端的
仓库当来源 —— 与其逐个列出不许的，不如只留那一个要用的（白名单，与沙箱的写策略同一个思路）。

**hook 不跑。** clone 过程本身也会执行 hook（`post-checkout`），模板目录里的 hook 还会被
复制进 `.git/hooks`。`core.hooksPath=/dev/null` 管这一次 clone；`Runner` 另外把
`core.hooksPath` 指向一个空目录，管之后沙箱里的每一条 git 命令 —— 两道，
因为这一条出事的代价太大。复制进来的 hook 文件由工具层在 clone 之后删掉。

**浅克隆、只要一条分支。** 读论文要的是现在这版代码，不是它的全部历史；
大仓库的完整历史动辄几百 MB，全在项目目录里、全算进用户的磁盘。
"""

from __future__ import annotations

from pathlib import Path

from .policy import SandboxPolicy
from .runner import ExecResult, Runner

__all__ = ["GIT", "clone_argv", "run_git_clone"]

#: 绝对路径，同 bash.py：走 PATH 查找的话，PATH 本身就成了可以被换掉的输入。
#:
#: macOS 上它是 xcrun 的转发壳，真正的 git 在命令行开发者工具（或 Xcode）里 ——
#: **没装开发者工具的 Mac 上这里跑不起来**。那是这台机器的事实，工具层会把它
#: 译成一句能照着做的话（`tools/repo.py` 的 `GIT_MISSING`）。
GIT = "/usr/bin/git"


def clone_argv(url: str, target: Path) -> tuple[str, ...]:
    """纯函数，方便测试直接盯住参数形态而不必起进程。

    `--` 放在地址前面：工具层给的地址以 `https://` 开头，本来就不会被当成选项；
    多一道是因为这个函数不该靠调用方替它保证这一点。
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
    """在沙箱内 clone。联网与否、能写哪里，全由 `policy` 决定 —— 这里不加任何例外。

    :raises SandboxUnavailable: 沙箱不可用 —— 此时不执行，也不退回宿主端 clone。
    """
    active = runner if runner is not None else Runner()
    return active.run(
        clone_argv(url, target), policy, cwd=policy.workspace_root, timeout=timeout
    )
