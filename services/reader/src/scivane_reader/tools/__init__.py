"""The tool loop: path boundary plus sandbox, so the agent can actually work.

    definition   tool definitions; model-visible and host-side fields kept strictly apart
    registry     lookup, schema export, filtering per agent level
    results      oversized results spill to disk; the model gets a preview and a path
    journal      calls and results are written to the conversation log
    scheduler    read-only calls run concurrently, others serialise; cancellation fills results
    loop         model -> tools -> results -> model
    files        read / write / edit / glob / grep (through workspace.resolve)
    exec         bash / python (through the sandbox runner)
    repo         fetch_repo (shallow clone through the audit proxy, hooks stripped)
    paper        reocr / cite
    agents       two levels: the librarian sees the project list, the reader one project
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
