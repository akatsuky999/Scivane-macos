"""Writes tool calls and results into the conversation log.

Everything that went into a model request must be rebuildable from the log: what was called,
with which arguments, what came back, approved or refused. Results record their call_id, so
a call without a result is visible even after a cancel. Credentials never appear here: tool
arguments never carry API keys, and a test checks it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from ..projects.model import ProjectEvent

__all__ = ["Journal", "NullJournal", "StoreJournal", "ABORTED_BEFORE_DISPATCH"]

#: stable code for synthetic results added after a cancel
ABORTED_BEFORE_DISPATCH = "TOOL_ABORTED_BEFORE_DISPATCH"


class EventSink(Protocol):
    def append_event(
        self, project_id: str, kind: str, data: dict | None = None,
        *, conversation: str | None = None,
    ) -> None: ...


class Journal(Protocol):
    """Log sink. A protocol so the librarian (no project) can use NullJournal."""

    def tool_call(self, call_id: str, name: str, arguments: dict) -> None: ...
    def tool_result(self, call_id: str, name: str, content: str, *, is_error: bool,
                    detail: dict | None = None, synthetic: bool = False) -> None: ...
    def tool_decision(self, call_id: str, name: str, approved: bool, reason: str = "") -> None: ...
    def assistant_message(self, text: str, *, stop: str) -> None: ...
    def user_message(self, text: str, images: list[dict] | None = None) -> None: ...


class NullJournal:
    """Writes nothing; the librarian belongs to no project."""

    def tool_call(self, call_id: str, name: str, arguments: dict) -> None: ...
    def tool_result(self, call_id: str, name: str, content: str, *, is_error: bool,
                    detail: dict | None = None, synthetic: bool = False) -> None: ...
    def tool_decision(self, call_id: str, name: str, approved: bool, reason: str = "") -> None: ...
    def assistant_message(self, text: str, *, stop: str) -> None: ...
    def user_message(self, text: str, images: list[dict] | None = None) -> None: ...


@dataclass
class StoreJournal:
    """Writes into one conversation's log. `conversation` is required: the route settled it when
    assembling the request (store.ensure_conversation).
    """

    store: EventSink
    project_id: str
    conversation: str

    def _append(self, kind: str, data: dict) -> None:
        self.store.append_event(self.project_id, kind, data, conversation=self.conversation)

    def tool_call(self, call_id: str, name: str, arguments: dict) -> None:
        self._append(ProjectEvent.TOOL_CALL, {
            "call_id": call_id, "name": name, "arguments": arguments,
        })

    def tool_result(
        self, call_id: str, name: str, content: str, *, is_error: bool,
        detail: dict | None = None, synthetic: bool = False,
    ) -> None:
        data: dict[str, object] = {
            "call_id": call_id, "name": name, "content": content, "is_error": is_error,
        }
        if detail:
            data["detail"] = detail
        if synthetic:
            # marks a result added after a cancel, so replays tell "tool failed" from "tool never ran"
            data["synthetic"] = True
        self._append(ProjectEvent.TOOL_RESULT, data)

    def tool_decision(self, call_id: str, name: str, approved: bool, reason: str = "") -> None:
        self._append(ProjectEvent.TOOL_DECISION, {
            "call_id": call_id, "name": name, "approved": approved,
            **({"reason": reason} if reason else {}),
        })

    def assistant_message(
        self, text: str, *, stop: str,
        usage: dict | None = None, estimate: int | None = None,
    ) -> None:
        """`usage` and `estimate` are this step's reported usage and estimate
        (Compactor.step_record); numbers only, used to calibrate the context next time.
        """
        data: dict[str, object] = {"text": text, "stop": stop}
        if usage:
            data["usage"] = usage
        if estimate:
            data["estimate"] = estimate
        self._append(ProjectEvent.ASSISTANT_MESSAGE, data)

    def user_message(self, text: str, images: list[dict] | None = None) -> None:
        """`images` are attachment records (hash, type, size), never the bytes."""
        data: dict[str, object] = {"text": text}
        if images:
            data["images"] = images
        self._append(ProjectEvent.USER_MESSAGE, data)
