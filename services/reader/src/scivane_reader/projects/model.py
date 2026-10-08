"""Data shapes for projects and their context."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Literal, TypeAlias

#: Where a title came from, in increasing reliability; only a better source may overwrite
#: (title.better_than). `placeholder` marks an empty project nobody named; `manual` is a title the
#: user typed, and no extraction may ever overwrite it.
TitleSource: TypeAlias = Literal[
    "placeholder", "filename", "pdf-metadata", "pdf-heading", "markdown-heading", "manual"
]

#: OCR output belongs to the source document by construction; uploads need confirmation.
ContextOrigin: TypeAlias = Literal["ocr", "upload"]

#: On-disk layout version.
#:
#: 1 = flat files in the project root
#: 2 = workspace skeleton: .lumen/ pdf/ md/ code/ workbench/ notes/
#: 3 = one .jsonl per conversation under .lumen/conversations/
#:
#: Projects are upgraded on open, one adjacent step at a time, so each step is testable on its own.
LAYOUT_VERSION = 3


@dataclass
class ContextState:
    """The project's static context: the paper text fed to the model and cached as the prompt prefix."""

    origin: ContextOrigin
    #: a new hash means a new cache prefix
    sha256: str
    chars: int
    tokens: int
    updated_at: str
    #: Uploaded Markdown may not be this paper; it counts only once a person confirms it.
    #: OCR output is confirmed from the start.
    confirmed: bool = True
    #: OCR job that produced this context, to trace image crops
    job_id: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> ContextState:
        return ContextState(
            origin=raw.get("origin", "ocr"),
            sha256=raw.get("sha256", ""),
            chars=int(raw.get("chars", 0)),
            tokens=int(raw.get("tokens", 0)),
            updated_at=raw.get("updated_at", ""),
            confirmed=bool(raw.get("confirmed", True)),
            job_id=raw.get("job_id"),
        )


@dataclass
class Project:
    id: str
    title: str
    title_source: TitleSource
    #: original file name, for display only; the copy is stored as source.<ext>
    source_name: str
    #: detects the same paper being built twice
    source_sha256: str
    source_suffix: str
    created_at: str
    updated_at: str
    #: old data has no such field and reads as 1
    layout: int = 1
    context: ContextState | None = None
    #: reserved for authors, year, DOI
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def has_source(self) -> bool:
        """Empty projects have no source document; the UI then skips the reading pane."""
        return bool(self.source_sha256)

    @property
    def has_usable_context(self) -> bool:
        """Whether the context may be fed to the model; unconfirmed uploads may not."""
        return self.context is not None and self.context.confirmed

    def as_dict(self) -> dict[str, Any]:
        described = asdict(self)
        described["context"] = self.context.as_dict() if self.context else None
        described["has_usable_context"] = self.has_usable_context
        described["has_source"] = self.has_source
        return described

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> Project:
        context = raw.get("context")
        return Project(
            id=raw["id"],
            title=raw.get("title", ""),
            title_source=raw.get("title_source", "filename"),
            source_name=raw.get("source_name", ""),
            source_sha256=raw.get("source_sha256", ""),
            source_suffix=raw.get("source_suffix", ".pdf"),
            created_at=raw.get("created_at", ""),
            updated_at=raw.get("updated_at", ""),
            layout=int(raw.get("layout", 1)),
            context=ContextState.from_dict(context) if context else None,
            metadata=raw.get("metadata", {}) or {},
        )


class ProjectEvent:
    """Session log event names.

    The log is append-only and everything that changes what the model sees must be recorded here,
    so the current context is always explainable and replays are projections of one log.
    """

    CREATED = "project/created"
    TITLE_CHANGED = "project/title-changed"
    CONTEXT_REPLACED = "context/replaced"
    CONTEXT_CONFIRMED = "context/confirmed"
    CONTEXT_REJECTED = "context/rejected"
    #: layout upgrade: from, to, and where the backup is
    LAYOUT_MIGRATED = "layout/migrated"
    #: a source attached to an empty project later; a project event, not part of any conversation
    SOURCE_ATTACHED = "source/attached"
    #: the user added a file to files/; visible to every conversation
    FILE_ADDED = "file/added"

    #: Header of a conversation file, so an empty conversation still exists on disk and in lists.
    CONVERSATION_CREATED = "conversation/created"
    CONVERSATION_RENAMED = "conversation/renamed"
    #: The conversation switched model card. An event rather than a metadata file: old conversations
    #: without it fall back to the global default with no migration.
    CONVERSATION_PROVIDER = "conversation/provider"
    #: Earlier turns were summarised (projects/compaction.py). Append-only: the original turns stay
    #: in the log, and the history sent to the model is derived from it (session.derive_history).
    #: Data: summary, turns, kept, trigger, provider, model, before/after (estimated tokens), usage.
    CONVERSATION_COMPACTED = "conversation/compacted"

    #: Messages and tools. Anything that ever went into a model request must be rebuildable from
    #: here: research conclusions need to show which grep line or bash output they came from.
    USER_MESSAGE = "user/message"
    ASSISTANT_MESSAGE = "assistant/message"
    TOOL_CALL = "tool/call"
    TOOL_RESULT = "tool/result"
    #: The user's verdict on a call that needed approval. Refusals are history too.
    TOOL_DECISION = "tool/decision"
