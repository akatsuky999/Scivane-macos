"""Project the append-only log back into model history.

Everything that went into a model request must be rebuildable from the log, and the rebuilt
history must be valid: tool/call and tool/result pair up by call_id in model order, and a call
without a result (crash, kill, old log) gets a synthetic error result here. Without that, an old
conversation could never send another message. scheduler.py does the same for cancellations
at runtime.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable

from ..i18n import ui
from ..llm.types import Message, TextBlock, ToolResultBlock, ToolUseBlock
from .model import ProjectEvent

__all__ = [
    "History", "derive_history", "derive_messages", "derive_transcript", "summarise_call",
    "MISSING_RESULT_TEXT", "MISSING_RESULT_CODE", "CHECKPOINT_PREAMBLE", "checkpoint_text",
    "compaction_item",
]

#: Distinct from the scheduler's cancellation code: "cancelled" and "no result in the log" are
#: different problems.
MISSING_RESULT_CODE = "TOOL_RESULT_MISSING_FROM_LOG"

MISSING_RESULT_TEXT = (
    f"错误（{MISSING_RESULT_CODE}）：这次调用在日志里没有结果 —— "
    "上次运行可能是崩溃或被强制结束的。"
)

#: After compaction the summary comes first in the history (after the paper). English and fixed:
#: it is an instruction to the model and part of the cached prefix, so it never follows the UI
#: language.
CHECKPOINT_PREAMBLE = (
    "Earlier turns of this conversation were compacted to free up context. The checkpoint below "
    "condenses them; the original messages, tool calls, and tool results remain in the conversation "
    "log but are no longer in your context. Treat the checkpoint as established background and "
    "continue from the messages that follow without restating it. If you need an exact detail it "
    "does not contain (a file's content, a command's full output, a precise number), run the "
    "relevant tool again instead of guessing."
)


def checkpoint_text(summary: str, covered: int) -> str:
    """The summary as it enters the history; the turn range tells the model which turns it replaces."""
    return (
        f"{CHECKPOINT_PREAMBLE}\n\n<compacted-summary turns=\"1-{covered}\">\n"
        f"{summary.strip()}\n</compacted-summary>"
    )


class _Turn:
    """One assistant step: its text, the calls it made, and the results filled in."""

    __slots__ = ("text", "uses", "results")

    def __init__(self) -> None:
        self.text: str = ""
        self.uses: list[ToolUseBlock] = []
        #: call_id -> result; concurrent tools finish in any order
        self.results: dict[str, ToolResultBlock] = {}

    @property
    def empty(self) -> bool:
        return not self.text and not self.uses


@dataclass(frozen=True)
class History:
    """A conversation's history grouped by turn.

    turns[i] is a question and everything it led to (turns[0] holds stray records from before the
    first question). A turn is the unit of compaction, so tool calls and results stay paired and the
    turn in progress is never touched. summary/covered describe the latest compaction, which covers
    turns 1..covered (summaries are cumulative).
    """

    turns: tuple[tuple[Message, ...], ...] = ((),)
    summary: str = ""
    covered: int = 0
    #: how many compactions happened; accuracy drops after several
    compactions: int = 0

    @property
    def count(self) -> int:
        return len(self.turns) - 1

    def checkpoint(self) -> Message | None:
        if not self.summary:
            return None
        return Message.text("user", checkpoint_text(self.summary, self.covered))

    def visible(self, *, upto: int | None = None) -> tuple[Message, ...]:
        """What the model gets: the summary (if any) plus the turns it doesn't cover, up to `upto`."""
        last = self.count if upto is None else min(upto, self.count)
        messages: list[Message] = []
        checkpoint = self.checkpoint()
        if checkpoint is not None:
            messages.append(checkpoint)
        first = self.covered + 1 if checkpoint is not None else 0
        for index in range(first, last + 1):
            messages.extend(self.turns[index])
        return tuple(messages)


def derive_history(events: Iterable[dict[str, Any]]) -> History:
    """Project log events into a history grouped by turn.

    Only message, tool and compaction events count. Lifecycle events and tool/decision are skipped:
    approvals are host-side facts and would make the model comment on its own permissions.
    Malformed events are skipped; a compaction claiming more turns than existed when it was
    written is clamped.
    """
    turns: list[list[Message]] = [[]]
    turn = _Turn()
    summary = ""
    covered = 0
    compactions = 0

    def flush() -> None:
        """Turn the collected step into messages. The only place synthetic results are added."""
        nonlocal turn
        if turn.empty:
            turn = _Turn()
            return

        blocks: list[Any] = []
        if turn.text:
            blocks.append(TextBlock(turn.text))
        blocks.extend(turn.uses)
        turns[-1].append(Message("assistant", tuple(blocks)))

        if turn.uses:
            # results follow the call order, not arrival order, with missing ones filled in
            results = tuple(
                turn.results.get(
                    use.id,
                    ToolResultBlock(use.id, MISSING_RESULT_TEXT, is_error=True),
                )
                for use in turn.uses
            )
            turns[-1].append(Message("user", results))
        turn = _Turn()

    for event in events:
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        data = event.get("data")
        if not isinstance(data, dict):
            data = {}

        if kind == ProjectEvent.USER_MESSAGE:
            flush()
            text = data.get("text")
            if isinstance(text, str) and text:
                turns.append([Message.text("user", text)])

        elif kind == ProjectEvent.ASSISTANT_MESSAGE:
            # a new assistant message ends the previous step and its results
            flush()
            text = data.get("text")
            turn.text = text if isinstance(text, str) else ""

        elif kind == ProjectEvent.TOOL_CALL:
            call_id = data.get("call_id")
            name = data.get("name")
            if not isinstance(call_id, str) or not isinstance(name, str):
                continue
            arguments = data.get("arguments")
            turn.uses.append(
                ToolUseBlock(call_id, name, arguments if isinstance(arguments, dict) else {})
            )

        elif kind == ProjectEvent.TOOL_RESULT:
            call_id = data.get("call_id")
            if not isinstance(call_id, str):
                continue
            content = data.get("content")
            turn.results[call_id] = ToolResultBlock(
                call_id,
                content if isinstance(content, str) else "",
                is_error=bool(data.get("is_error")),
            )

        elif kind == ProjectEvent.CONVERSATION_COMPACTED:
            # Compaction events belong to no turn and can land mid-turn (compacting earlier turns);
            # they only record where the summary starts.
            text = data.get("summary")
            upto = data.get("turns")
            if (isinstance(text, str) and text.strip()
                    and isinstance(upto, int) and not isinstance(upto, bool) and upto >= 1):
                summary = text.strip()
                covered = min(upto, len(turns) - 1)
                compactions += 1

        # anything else has no place in the model history

    flush()
    return History(
        turns=tuple(tuple(messages) for messages in turns),
        summary=summary if covered >= 1 else "",
        covered=covered if summary else 0,
        compactions=compactions,
    )


def derive_messages(events: Iterable[dict[str, Any]]) -> tuple[Message, ...]:
    """History sent to the model: the latest summary (if any) plus the turns after it."""
    return derive_history(events).visible()


def summarise_call(name: str, arguments: dict) -> str:
    """One readable line for the UI ("Searching contrastive loss", "read md/context.md").

    Lives here because the live stream and history restore both need it and must agree. It must
    say where side effects land, since approvals are decided in a second. Follows the UI language;
    English starts with a gerund because it doubles as the status line.
    """
    if name == "fetch_repo":
        url = str(arguments.get("url", "?"))
        target = url.rstrip("/").split("/")[-1].removesuffix(".git") or "?"
        return ui(f"取回 {url}，放进 code/{target}", f"Fetching {url} into code/{target}")
    if name in ("read", "write", "edit"):
        path = arguments.get("path", "?")
        doing = {"read": "Reading", "write": "Writing", "edit": "Editing"}[name]
        return ui(f"{name} {path}", f"{doing} {path}")
    if name == "grep":
        return ui(f"搜索 {arguments.get('pattern', '?')}", f"Searching {arguments.get('pattern', '?')}")
    if name == "glob":
        return ui(f"列出 {arguments.get('pattern', '?')}", f"Listing {arguments.get('pattern', '?')}")
    if name == "bash":
        command = str(arguments.get("command", "?"))[:80]
        return ui(f"跑 {command}", f"Running {command}")
    if name == "python":
        size = len(str(arguments.get("code", "")))
        return ui(f"跑一段 Python（{size} 字）", f"Running Python ({size} chars)")
    if name == "reocr":
        pages = arguments.get("pages", "?")
        return ui(f"重新识别第 {pages} 页", f"Re-running OCR on pages {pages}")
    if name == "cite":
        anchor = arguments.get("anchor", "?")
        return ui(f"定位「{anchor}」在原稿的位置", f"Locating “{anchor}” in the original")
    if name == "delete_project":
        project = arguments.get("project_id", "?")
        return ui(f"删除项目 {project}（连同原稿与历史）",
                  f"Deleting project {project} (with its original and history)")
    return name


def derive_transcript(events: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Project the log into the transcript the UI renders.

    Same pairing rules as derive_messages, so the UI never shows a different history than the
    model saw. Differences: tool/decision is included, results are previews, the synthetic flag
    is kept, and compaction hides no turns (it appears as a record where it happened).
    """
    items: list[dict[str, Any]] = []
    pending: dict[str, int] = {}      # call_id -> index in items
    decisions: dict[str, dict[str, Any]] = {}

    for event in events:
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        data = event.get("data") if isinstance(event.get("data"), dict) else {}
        at = event.get("at", "")

        if kind == ProjectEvent.USER_MESSAGE:
            text = data.get("text")
            if isinstance(text, str) and text:
                items.append({"kind": "user", "text": text, "at": at})

        elif kind == ProjectEvent.ASSISTANT_MESSAGE:
            text = data.get("text")
            if isinstance(text, str) and text.strip():
                items.append({"kind": "assistant", "text": text, "at": at})

        elif kind == ProjectEvent.TOOL_CALL:
            call_id = data.get("call_id")
            if not isinstance(call_id, str):
                continue
            pending[call_id] = len(items)
            name = data.get("name", "?")
            arguments = data.get("arguments") or {}
            items.append({
                "kind": "tool", "call_id": call_id,
                "name": name,
                "arguments": arguments,
                # computed by the same function the live stream uses, so both say the same thing
                "summary": summarise_call(name, arguments),
                "at": at,
                # placed as missing until its result arrives
                "state": "missing", "preview": MISSING_RESULT_TEXT,
                "is_error": True, "synthetic": True,
            })

        elif kind == ProjectEvent.TOOL_RESULT:
            call_id = data.get("call_id")
            index = pending.pop(call_id, None) if isinstance(call_id, str) else None
            if index is None:
                continue
            content = data.get("content")
            detail = data.get("detail") if isinstance(data.get("detail"), dict) else {}
            items[index].update({
                "state": "done",
                "preview": (content if isinstance(content, str) else "")[:_PREVIEW],
                "is_error": bool(data.get("is_error")),
                "synthetic": bool(data.get("synthetic")),
                "detail": detail,
            })

        elif kind == ProjectEvent.TOOL_DECISION:
            call_id = data.get("call_id")
            if isinstance(call_id, str):
                decisions[call_id] = {
                    "approved": bool(data.get("approved")),
                    "reason": data.get("reason", ""),
                }

        elif kind == ProjectEvent.CONVERSATION_COMPACTED:
            item = compaction_item(data)
            if item is not None:
                item["at"] = at
                items.append(item)

    # attach decisions to their tool card
    for item in items:
        if item.get("kind") == "tool":
            verdict = decisions.get(item.get("call_id"))
            if verdict is not None:
                item["decision"] = verdict
    return items


#: must match the live preview length in agent_routes
_PREVIEW = 600


def compaction_item(data: dict[str, Any]) -> dict[str, Any] | None:
    """A compaction as the UI shows it, shared by the live event and history restore.
    Numbers are estimated tokens; invalid events give None.
    """
    summary = data.get("summary")
    turns = data.get("turns")
    if not (isinstance(summary, str) and summary.strip()
            and isinstance(turns, int) and not isinstance(turns, bool) and turns >= 1):
        return None

    def count(key: str) -> int:
        value = data.get(key)
        return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0

    trigger = data.get("trigger")
    return {
        "kind": "compaction",
        "summary": summary.strip(),
        "turns": turns,
        "kept": count("kept"),
        "trigger": trigger if trigger in ("auto", "manual", "overflow") else "manual",
        "before": count("before"),
        "after": count("after"),
    }
