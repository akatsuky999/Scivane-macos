"""开发期源码树的定位。

**只用来回答「我是不是在仓库里跑」**，不再用来推导任何运行期产物的位置 ——
产物统一落在用户目录下（见 `config.VAR_DIR`）。打包安装之后机器上根本没有仓库，
让产物跟着仓库走等于让它跟着一个不存在的东西走。

单独一个模块，是为了让 config 用它判断开发模式而不牵出别的依赖。
（runtime.py 如今从 config 读 OCR 的三档位置 —— 位置只在 config 一处定义。）
"""

from __future__ import annotations

import os
from pathlib import Path

# 认这个标志物来判断「到根了」。比写死 parents[N] 稳：
# 以后目录再嵌一层也不会静默指错地方。
#
# **注意单复数**：这里曾经写成 `apps/macos/Package.swift`（Lumen 时期的布局），
# 迁移到 `app/` 之后没跟着改，于是这个函数**从来没有匹配成功过** ——
# 一直靠 start_backend.sh 传 SCIVANE_PROJECT_ROOT 兜着，而兜不住的时候
# 会安静地退回 cwd。这就是下面那条「找不到返回 None」的由来。
_MARKER = Path("app") / "macos" / "Package.swift"


def find_source_root() -> Path | None:
    """返回仓库根；**不在仓库里跑（打包安装）时返回 None**。

    找不到时绝不退回 `Path.cwd()`：从 /tmp 起一个进程会让它认为仓库在 /tmp，
    产物于是落进 /tmp/var，而这个错误不报任何信息。宁可返回 None 让调用方
    自己决定，也不要给一个看起来合理的错答案。
    """
    override = os.environ.get("SCIVANE_PROJECT_ROOT")
    if override:
        return Path(override).expanduser().resolve()

    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / _MARKER).is_file():
            return parent

    return None


SOURCE_ROOT = find_source_root()
