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

from .attachments import ImageRecord
from .model import ProjectEvent

__all__ = [
    "CONVERSATIONS_DIR", "CONVERSATION_EVENTS", "TITLE_CHARS",
    "new_id", "is_valid_id", "derive_title", "summarise", "opens_turn", "active_events",
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


#: Facts about the conversation rather than turn content. A rewind keeps them, so a rename or a
#: model switch made after the edited question still holds.
_KEPT_ON_REWIND = frozenset({
    ProjectEvent.CONVERSATION_CREATED,
    ProjectEvent.CONVERSATION_RENAMED,
    ProjectEvent.CONVERSATION_PROVIDER,
})


def opens_turn(data: dict[str, Any]) -> bool:
    """Whether a user/message starts a turn: it carries words or at least one image.

    The one definition behind the model history, the transcript and rewinds, so turn n is the same
    question in all three.
    """
    text = data.get("text")
    if isinstance(text, str) and text:
        return True
    images = data.get("images")
    return isinstance(images, list) and any(ImageRecord.from_dict(raw) is not None for raw in images)


def active_events(events: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """The log as it stands after its rewinds.

    A conversation/rewound keeps the first `keep` turns and drops everything logged after the next
    question began: answers, tool calls, compactions, stop notes. Conversation facts survive, and the
    rewind events themselves are consumed. One that would keep every turn, or is malformed, changes
    nothing. Projections read the log through here, so none of them handles rewinds itself.
    """
    kept: list[dict[str, Any]] = []
    #: index in `kept` of each turn's question
    starts: list[int] = []
    for event in events:
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        data = event.get("data") if isinstance(event.get("data"), dict) else {}
        if kind == ProjectEvent.CONVERSATION_REWOUND:
            keep = data.get("keep")
            if type(keep) is int and 0 <= keep < len(starts):
                cut = starts[keep]
                kept = kept[:cut] + [e for e in kept[cut:] if e.get("type") in _KEPT_ON_REWIND]
                del starts[keep:]
            continue
        if kind == ProjectEvent.USER_MESSAGE and opens_turn(data):
            starts.append(len(kept))
        kept.append(event)
    return kept


def derive_title(events: Iterable[dict[str, Any]]) -> str:
    """Conversation title: the first question by default; the latest rename wins.

    Renames are events rather than edits to the file header, keeping the log append-only. An edited
    first question retitles a conversation that was never renamed.
    """
    renamed = ""
    first_question = ""
    for event in active_events(events):
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
    """How a conversation looks in the list. `messages` counts the user and assistant messages
    still in the conversation, not tool calls or turns dropped by a rewind; the times cover every
    event, the rewind included.
    """
    created_at = ""
    updated_at = ""
    for event in events:
        if not isinstance(event, dict):
            continue
        at = event.get("at")
        if isinstance(at, str) and at:
            if not created_at:
                created_at = at
            updated_at = at
    messages = 0
    #: None when never chosen; the UI falls back to the default, so old conversations need no migration.
    provider: str | None = None
    active = active_events(events)
    for event in active:
        if event.get("type") in (ProjectEvent.USER_MESSAGE, ProjectEvent.ASSISTANT_MESSAGE):
            messages += 1
        if event.get("type") == ProjectEvent.CONVERSATION_PROVIDER:
            chosen = (event.get("data") or {}).get("provider")
            if isinstance(chosen, str) and chosen.strip():
                provider = chosen.strip()
    return {
        "id": conversation_id,
        # already rewound; applying the rewinds again is a no-op
        "title": derive_title(active),
        "messages": messages,
        "created_at": created_at,
        "updated_at": updated_at,
        "provider": provider,
    }
