"""Project the append-only log back into model history.

Everything that went into a model request must be rebuildable from the log, and the rebuilt
history must be valid: tool/call and tool/result pair up by call_id in model order, and a call
without a result (crash, kill, old log) gets a synthetic error result here. Without that, an old
conversation could never send another message. scheduler.py does the same for cancellations
at runtime.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Iterable

from ..i18n import ui
from ..llm.types import (
    ContentBlock, Message, TextBlock, ToolResultBlock, ToolUseBlock, append_user_text,
)
from .annotations import COLOR_NAMES, KIND_NAMES
from .attachments import ImageRecord
from .model import ProjectEvent

#: Turns an image named in the log into what the model sees (attachments.AttachmentStore.block).
ImageLoader = Callable[[ImageRecord], ContentBlock]

__all__ = [
    "History", "ImageLoader", "derive_history", "derive_messages", "derive_transcript",
    "summarise_call", "user_content",
    "MISSING_RESULT_TEXT", "MISSING_RESULT_CODE", "CHECKPOINT_PREAMBLE", "INTERRUPTED_NOTE",
    "checkpoint_text", "compaction_item",
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


#: Opens the question after a turn the user stopped. Without it a cut-off answer replays as a
#: finished one and cancelled calls as plain errors, and models either treat the half answer as
#: complete or pick the old task back up. English and fixed, logged verbatim (TURN_INTERRUPTED).
INTERRUPTED_NOTE = (
    "[Scivane] The user stopped the previous turn. Nothing after that point happened: calls marked "
    "as cancelled did not finish, and the last answer may end mid-sentence. Do not resume that "
    "work unless the user asks for it; answer the message below."
)


def checkpoint_text(summary: str, covered: int) -> str:
    """The summary as it enters the history; the turn range tells the model which turns it replaces."""
    return (
        f"{CHECKPOINT_PREAMBLE}\n\n<compacted-summary turns=\"1-{covered}\">\n"
        f"{summary.strip()}\n</compacted-summary>"
    )


class _Step:
    """One assistant step: its text and the calls it made. Results are looked up by call id."""

    __slots__ = ("text", "uses", "claims_after")

    def __init__(self, text: str = "", uses: list[ToolUseBlock] | None = None) -> None:
        self.text = text
        self.uses: list[ToolUseBlock] = uses if uses is not None else []
        #: Logs written before tools ran mid-stream put a step's calls after its message. Such a
        #: message (a step that can carry calls, nothing logged before it) claims the calls that
        #: follow it.
        self.claims_after = False

    @property
    def empty(self) -> bool:
        return not self.text and not self.uses


#: Stops whose step can hold tool calls: a normal tool step, and one the output limit cut after some
#: complete calls (the loop runs those and continues). The loop logs the step's message as soon as
#: the stream ends, so a call a tool picks up later is logged after it and must still be claimed.
_CARRIES_CALLS = frozenset({"tool_use", "length"})


class _Steps:
    """Groups one turn's log events into steps.

    Tools start while the model is still streaming, so a step's tool/call events are logged
    before the assistant/message that closes it, and its results come before or after that
    message, in whatever order the tools finish. Calls therefore belong to the message that
    follows them, results are matched by call id, and nothing is turned into messages until the
    turn is complete. Pairing calls with the message before them (the order of older logs) once
    replayed every result as missing.
    """

    def __init__(self) -> None:
        #: steps and resume notes, in log order
        self.entries: list[_Step | str] = []
        #: calls not yet claimed by a message
        self.pending: list[ToolUseBlock] = []
        self.results: dict[str, ToolResultBlock] = {}

    def call(self, use: ToolUseBlock) -> None:
        last = self.entries[-1] if self.entries else None
        if isinstance(last, _Step) and last.claims_after:
            last.uses.append(use)
        else:
            self.pending.append(use)

    def message(self, text: str, stop: object) -> None:
        step = _Step(text, self.pending)
        step.claims_after = stop in _CARRIES_CALLS and not self.pending
        self.pending = []
        self.entries.append(step)

    def note(self, text: str) -> None:
        self._close_pending()
        self.entries.append(text)

    def result(self, block: ToolResultBlock) -> None:
        self.results[block.call_id] = block

    def _close_pending(self) -> None:
        # calls no message claimed: the stream died after they started (crash, kill)
        if self.pending:
            self.entries.append(_Step("", self.pending))
            self.pending = []

    def into(self, messages: list[Message]) -> list[Message]:
        """Append the turn's steps to `messages` (which hold its question). The only place
        synthetic results are added."""
        self._close_pending()
        out = messages
        for entry in self.entries:
            if isinstance(entry, str):
                out = append_user_text(out, entry)
                continue
            if entry.empty:
                continue
            blocks: list[Any] = [TextBlock(entry.text)] if entry.text else []
            blocks.extend(entry.uses)
            out.append(Message("assistant", tuple(blocks)))
            if entry.uses:
                # results follow the call order, not arrival order, with missing ones filled in
                out.append(Message("user", tuple(
                    self.results.get(use.id, ToolResultBlock(use.id, MISSING_RESULT_TEXT, is_error=True))
                    for use in entry.uses
                )))
        return out


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
    #: An app note waiting for the next question (the last turn was stopped). The route hands it to
    #: assemble(note=...) and the projection puts it in the same place once the question is logged.
    pending_note: str = ""

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


def user_content(
    text: str, images: Iterable[ContentBlock], *, note: str = ""
) -> tuple[ContentBlock, ...]:
    """A question as the model sees it: images first, as providers recommend, then an app note
    if there is one (INTERRUPTED_NOTE), then the user's words."""
    blocks = list(images)
    if note:
        blocks.append(TextBlock(note))
    if text:
        blocks.append(TextBlock(text))
    return tuple(blocks)


def derive_history(
    events: Iterable[dict[str, Any]], *, images: ImageLoader | None = None
) -> History:
    """Project log events into a history grouped by turn.

    Only message, tool, resume, interruption and compaction events count. Lifecycle events and
    tool/decision are skipped:
    approvals are host-side facts and would make the model comment on its own permissions.
    Malformed events are skipped; a compaction claiming more turns than existed when it was
    written is clamped. Images in user messages are named by hash; `images` turns them back into
    blocks (without it, they become a fixed note, which is all a projection that sends nothing
    needs).
    """
    turns: list[list[Message]] = [[]]
    steps = _Steps()
    summary = ""
    covered = 0
    compactions = 0
    #: the note of a stopped turn, waiting for the question it opens
    pending = ""

    def flush() -> None:
        nonlocal steps
        turns[-1] = steps.into(turns[-1])
        steps = _Steps()

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
            text = text if isinstance(text, str) else ""
            records = [r for r in map(ImageRecord.from_dict, data.get("images") or []) if r is not None]
            blocks = user_content(text, (
                images(record) if images is not None else TextBlock(f"[image {record.sha256[:12]}]")
                for record in records), note=pending)
            pending = ""
            if blocks:
                turns.append([Message("user", blocks)])

        elif kind == ProjectEvent.TURN_INTERRUPTED:
            # Not a message of the stopped turn: appended there it would leave two user messages
            # in a row (stopped turns often end on a question or on tool results).
            text = data.get("text")
            if isinstance(text, str) and text.strip():
                pending = text

        elif kind == ProjectEvent.ASSISTANT_MESSAGE:
            text = data.get("text")
            steps.message(text if isinstance(text, str) else "", data.get("stop"))

        elif kind == ProjectEvent.TOOL_CALL:
            call_id = data.get("call_id")
            name = data.get("name")
            if not isinstance(call_id, str) or not isinstance(name, str):
                continue
            arguments = data.get("arguments")
            steps.call(ToolUseBlock(call_id, name, arguments if isinstance(arguments, dict) else {}))

        elif kind == ProjectEvent.TOOL_RESULT:
            call_id = data.get("call_id")
            if not isinstance(call_id, str):
                continue
            content = data.get("content")
            steps.result(ToolResultBlock(
                call_id,
                content if isinstance(content, str) else "",
                is_error=bool(data.get("is_error")),
            ))

        elif kind in (ProjectEvent.TURN_RESUMED, ProjectEvent.TURN_CONTINUED):
            text = data.get("text")
            if isinstance(text, str) and text.strip():
                steps.note(text)

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
        pending_note=pending,
    )


def derive_messages(
    events: Iterable[dict[str, Any]], *, images: ImageLoader | None = None
) -> tuple[Message, ...]:
    """History sent to the model: the latest summary (if any) plus the turns after it."""
    return derive_history(events, images=images).visible()


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
    if name in ("bash", "python"):
        # the call's own one-line label says what it does, in the user's words; better than the raw
        # command or "Python (N chars)"
        label = arguments.get("description")
        if isinstance(label, str) and label.strip():
            return " ".join(label.split())[:80]
    if name == "plan":
        return _summarise_plan(arguments)
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
    if name == "annotations":
        return _summarise_marks(arguments)
    if name == "delete_project":
        project = arguments.get("project_id", "?")
        return ui(f"删除项目 {project}（连同原稿与历史）",
                  f"Deleting project {project} (with its original and history)")
    return name


def _summarise_plan(arguments: dict) -> str:
    """Progress as the card shows it: "计划 2/5：翻第 3 节" (the step is the model's own words)."""
    items = arguments.get("items")
    steps = [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []
    done = sum(1 for item in steps if item.get("status") == "done")
    doing = next((str(item.get("step", "")).strip() for item in steps if item.get("status") == "doing"), "")
    doing = doing[:60]
    return ui(f"计划 {done}/{len(steps)}" + (f"：{doing}" if doing else ""),
              f"Plan {done}/{len(steps)}" + (f": {doing}" if doing else ""))


def _summarise_marks(arguments: dict) -> str:
    # The model's arguments are unchecked here; a malformed call still gets a line, not a crash.
    colors = arguments.get("colors")
    colors = [c for c in colors if isinstance(c, str)] if isinstance(colors, list) else []
    kind = arguments.get("kind")
    kind = kind if isinstance(kind, str) and kind in KIND_NAMES else None
    pages = arguments.get("pages")
    pages = [str(p) for p in pages if type(p) is int] if isinstance(pages, list) else []
    zh = "、".join(COLOR_NAMES.get(c, c) for c in colors) + (KIND_NAMES[kind] if kind else "")
    shades = ", ".join(colors[:-1]) + " and " + colors[-1] if len(colors) > 1 else "".join(colors)
    marks = {"highlight": "highlights", "underline": "underlines"}.get(kind or "", "marks")
    where = f" on page{'s' if len(pages) > 1 else ''} {', '.join(pages)}" if pages else ""
    return ui(
        f"查看原稿上的{zh}标注" + (f"（第 {'、'.join(pages)} 页）" if pages else ""),
        f"Reading your {shades + ' ' if shades else ''}{marks}{where}",
    )


def derive_transcript(events: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Project the log into the transcript the UI renders.

    Same pairing rules as derive_messages, so the UI never shows a different history than the
    model saw. Differences: tool/decision is included, results are previews, the synthetic flag
    is kept, and compaction hides no turns (it appears as a record where it happened). A step's
    words go before its tool cards, as they streamed, although the log holds the calls first.
    A step's failure code and a resumed turn come back as their own items.
    """
    items: list[dict[str, Any]] = []
    pending: dict[str, dict[str, Any]] = {}  # call_id -> its tool item, until the result arrives
    #: tool items logged since the last message: the next message is theirs (see _Steps)
    unclaimed: list[dict[str, Any]] = []
    claims_after = False
    decisions: dict[str, dict[str, Any]] = {}

    for event in events:
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        data = event.get("data") if isinstance(event.get("data"), dict) else {}
        at = event.get("at", "")

        if kind == ProjectEvent.USER_MESSAGE:
            unclaimed, claims_after = [], False
            text = data.get("text")
            text = text if isinstance(text, str) else ""
            records = [r for r in map(ImageRecord.from_dict, data.get("images") or []) if r is not None]
            if text or records:
                item: dict[str, Any] = {"kind": "user", "text": text, "at": at}
                if records:
                    item["images"] = [record.as_dict() for record in records]
                items.append(item)

        elif kind == ProjectEvent.ASSISTANT_MESSAGE:
            text = data.get("text")
            if isinstance(text, str) and text.strip():
                said = {"kind": "assistant", "text": text, "at": at}
                if unclaimed:
                    first = next(i for i, existing in enumerate(items) if existing is unclaimed[0])
                    items.insert(first, said)
                else:
                    items.append(said)
            failure = data.get("failure")
            if isinstance(failure, dict) and isinstance(failure.get("code"), str):
                items.append({"kind": "failure", "code": failure["code"], "at": at})
            claims_after = data.get("stop") in _CARRIES_CALLS and not unclaimed
            unclaimed = []

        elif kind == ProjectEvent.TOOL_CALL:
            call_id = data.get("call_id")
            if not isinstance(call_id, str):
                continue
            name = data.get("name", "?")
            arguments = data.get("arguments") or {}
            tool = {
                "kind": "tool", "call_id": call_id,
                "name": name,
                "arguments": arguments,
                # computed by the same function the live stream uses, so both say the same thing
                "summary": summarise_call(name, arguments),
                "at": at,
                # placed as missing until its result arrives
                "state": "missing", "preview": MISSING_RESULT_TEXT,
                "is_error": True, "synthetic": True,
            }
            items.append(tool)
            pending[call_id] = tool
            if not claims_after:
                unclaimed.append(tool)

        elif kind == ProjectEvent.TURN_RESUMED:
            unclaimed, claims_after = [], False
            quiet = data.get("quiet")
            items.append({
                "kind": "resumed", "reason": data.get("reason", ""), "code": data.get("code", ""),
                "quiet": quiet if isinstance(quiet, (int, float)) and not isinstance(quiet, bool) else None,
                "at": at,
            })

        elif kind == ProjectEvent.TOOL_RESULT:
            call_id = data.get("call_id")
            target = pending.pop(call_id, None) if isinstance(call_id, str) else None
            if target is None:
                continue
            content = data.get("content")
            detail = data.get("detail") if isinstance(data.get("detail"), dict) else {}
            target.update({
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
