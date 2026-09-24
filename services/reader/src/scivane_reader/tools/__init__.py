"""工具调用循环：把路径边界（段一）与沙箱（段二）接成「agent 真的能干活」。

    definition   工具定义 —— **模型可见字段与主机侧字段严格分开**
    registry     注册表：查找、导出 schema、按 agent 层级过滤
    results      结果超限落盘，只给模型预览与路径
    journal      调用与结果全部落进 .lumen/session.jsonl
    scheduler    只读并发、其余屏障、取消补合成结果
    loop         模型 → 工具 → 结果 → 接着想
    files        read / write / edit / glob / grep（走 workspace.resolve）
    exec         bash / python（走 sandbox runner）
    repo         fetch_repo（沙箱内经审计代理浅克隆，剥 hook）
    paper        reocr / cite（这个产品独有的）
    agents       两层：书房只见清单，读者落在一个项目里
"""

from __future__ import annotations

from .agents import (
    LIBRARIAN_PROMPT,
    READER_PROMPT,
    Agent,
    librarian,
    librarian_tools,
    reader,
    reader_registry,
)
from .definition import (
    DEFAULT_MAX_RESULT_CHARS,
    UNLIMITED_RESULT,
    ToolContext,
    ToolDef,
    ToolError,
    ToolOutcome,
)
from .exec import exec_tools
from .files import file_tools
from .journal import ABORTED_BEFORE_DISPATCH, Journal, NullJournal, StoreJournal
from .loop import MAX_STEPS, AgentLoop, LoopResult
from .paper import paper_tools
from .registry import ToolRegistry
from .repo import ALLOWED_HOSTS, normalise_repo_url, repo_tools
from .results import apply_limit
from .scheduler import Batch, Dispatcher, partition

__all__ = [
    "ToolDef", "ToolContext", "ToolOutcome", "ToolError",
    "UNLIMITED_RESULT", "DEFAULT_MAX_RESULT_CHARS",
    "ToolRegistry", "apply_limit",
    "Journal", "NullJournal", "StoreJournal", "ABORTED_BEFORE_DISPATCH",
    "Dispatcher", "Batch", "partition",
    "AgentLoop", "LoopResult", "MAX_STEPS",
    "file_tools", "exec_tools", "repo_tools", "paper_tools",
    "ALLOWED_HOSTS", "normalise_repo_url",
    "Agent", "librarian", "reader", "librarian_tools", "reader_registry",
    "LIBRARIAN_PROMPT", "READER_PROMPT",
]
