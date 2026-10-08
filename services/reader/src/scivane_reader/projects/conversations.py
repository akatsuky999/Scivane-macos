"""Several conversations per project, one .jsonl file each.

One file per conversation rather than a conversation_id filter in one log: projecting a
conversation reads only its own file, deleting one deletes a file instead of rewriting an
append-only log, and exporting one hands over the file.

    .lumen/session.jsonl              project lifecycle: created, renamed, context replaced
    .lumen/conversations/<id>.jsonl   one conversation: questions, answers, tool calls

No index file: titles, counts and times are computed from the files themselves, so the list
can never disagree with them.
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable

from .model import ProjectEvent

__all__ = [
    "CONVERSATIONS_DIR", "CONVERSATION_EVENTS", "TITLE_CHARS",
    "new_id", "is_valid_id", "derive_title", "summarise",
]

#: under .lumen/, the control plane the agent can't see
CONVERSATIONS_DIR = "conversations"

#: Events that belong to a conversation. Both the v3 migration and every write use this table;
#: everything else is project lifecycle.
CONVERSATION_EVENTS = frozenset({
    ProjectEvent.CONVERSATION_CREATED,
    ProjectEvent.CONVERSATION_RENAMED,
    ProjectEvent.CONVERSATION_COMPACTED,
    ProjectEvent.USER_MESSAGE,
    ProjectEvent.ASSISTANT_MESSAGE,
    ProjectEvent.TOOL_CALL,
    ProjectEvent.TOOL_RESULT,
    ProjectEvent.TOOL_DECISION,
})

#: longest automatic title that fits one sidebar row
TITLE_CHARS = 40

#: Valid conversation ids: no '.' or '/', so an id can never build a path outside conversations/.
_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")


def new_id() -> str:
    """New conversation id: sortable UTC timestamp plus a random tail.

    Sorting file names then sorts by creation time without opening them; the tail separates two
    conversations created in the same second.
    """
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    return f"{stamp}-{uuid.uuid4().hex[:6]}"


def is_valid_id(conversation_id: str) -> bool:
    """Reject ids that could traverse directories (same guard as store.dir_for)."""
    return bool(conversation_id) and _ID.fullmatch(conversation_id) is not None


def derive_title(events: Iterable[dict[str, Any]]) -> str:
    """Conversation title: the first question by default; the latest rename wins.

    Renames are events rather than edits to the file header, keeping the log append-only.
    """
    renamed = ""
    first_question = ""
    for event in events:
        if not isinstance(event, dict):
            continue
        data = event.get("data")
        if not isinstance(data, dict):
            continue
        kind = event.get("type")
        if kind == ProjectEvent.CONVERSATION_RENAMED:
            title = data.get("title")
            if isinstance(title, str) and title.strip():
                renamed = title.strip()
        elif kind == ProjectEvent.USER_MESSAGE and not first_question:
            text = data.get("text")
            if isinstance(text, str) and text.strip():
                first_question = text.strip()
    if renamed:
        return renamed[:TITLE_CHARS]
    if not first_question:
        return ""
    # first line only: later lines are usually pasted material
    head = first_question.splitlines()[0].strip()
    return head[:TITLE_CHARS]


def summarise(conversation_id: str, events: list[dict[str, Any]]) -> dict[str, Any]:
    """How a conversation looks in the list. `messages` counts user and assistant messages,
    not tool calls.
    """
    messages = 0
    created_at = ""
    updated_at = ""
    #: None when never chosen; the UI falls back to the default, so old conversations need no migration.
    provider: str | None = None
    for event in events:
        if not isinstance(event, dict):
            continue
        at = event.get("at")
        if isinstance(at, str) and at:
            if not created_at:
                created_at = at
            updated_at = at
        if event.get("type") in (ProjectEvent.USER_MESSAGE, ProjectEvent.ASSISTANT_MESSAGE):
            messages += 1
        if event.get("type") == ProjectEvent.CONVERSATION_PROVIDER:
            chosen = (event.get("data") or {}).get("provider")
            if isinstance(chosen, str) and chosen.strip():
                provider = chosen.strip()
    return {
        "id": conversation_id,
        "title": derive_title(events),
        "messages": messages,
        "created_at": created_at,
        "updated_at": updated_at,
        "provider": provider,
    }
