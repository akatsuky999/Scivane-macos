"""Projects: one paper, one project, with a stable identity, its own context and replayable history.

This layer depends on llm/, never the other way round.
"""

from __future__ import annotations

from .context import SYSTEM_PROMPT, assemble
from .conversations import CONVERSATION_EVENTS, CONVERSATIONS_DIR
from .model import ContextOrigin, ContextState, Project, ProjectEvent, TitleSource
from .store import (
    DEFAULT_PROJECTS_ROOT,
    ProjectError,
    ProjectStore,
    projects,
    rough_tokens,
)
from .title import better_than, from_markdown, from_pdf

__all__ = [
    "Project", "ContextState", "ContextOrigin", "TitleSource", "ProjectEvent",
    "ProjectStore", "ProjectError", "projects", "DEFAULT_PROJECTS_ROOT",
    "assemble", "SYSTEM_PROMPT", "rough_tokens",
    "CONVERSATIONS_DIR", "CONVERSATION_EVENTS",
    "from_pdf", "from_markdown", "better_than",
]
