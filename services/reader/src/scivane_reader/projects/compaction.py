"""Compaction: replace earlier turns with a summary when the conversation nears the window.

    before  [paper, (old summary), turn 1 ... turn 9, turn 10 (in progress)]
    after   [paper, new summary (to turn 7), turn 8, turn 9, turn 10 (in progress)]

The paper is never touched and the cut always falls between turns, so tool calls stay paired and
the turn in progress keeps its full text (a single turn that overflows can't be rescued). The
latest turns stay verbatim, up to RETAIN_RATIO of the window; older ones are rewritten together
with the previous summary. Only one log event is appended and the original turns stay in the log.

The summary request reuses the conversation's cache prefix (same system prompt, tools and
messages plus one instruction) and falls back to a tool-free request if the model calls a tool.

Triggers: before a step, above AUTO_RATIO of a known window (prepare); once on
CONTEXT_WINDOW_EXCEEDED (recover); on demand (compact_now). Auto-compaction stops after
MAX_FAILURES failures in a row.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Sequence

from ..i18n import ui
from ..llm.cache import rough_tokens
from ..llm.errors import CONTEXT_WINDOW_EXCEEDED, TRANSPORT, LlmError
from ..llm.estimate import RequestEstimate, estimate_messages, estimate_request
from ..llm.types import (
    CallRequest,
    Finish,
    ImageBlock,
    LlmFailure,
    Message,
    TextBlock,
    TextDelta,
    ToolResultBlock,
    ToolSchema,
    ToolUseBlock,
    Usage,
)
from .context import settle_history
from .meter import ContextReport, measure, ratio_of
from .model import ProjectEvent
from .session import History, ImageLoader, compaction_item, derive_history

__all__ = [
    "AUTO_RATIO", "RETAIN_RATIO", "RETAIN_TOKENS_WITHOUT_WINDOW", "MAX_FAILURES", "MIN_SOURCE_TOKENS",
    "COMPACTION_INSTRUCTION", "SUMMARIZER_SYSTEM",
    "CompactionError", "NothingToCompact", "Compaction", "Compactor",
    "auto_threshold", "retain_budget", "choose", "summary_request", "extract_summary",
    "occupy", "release",
]

logger = logging.getLogger("scivane.projects.compaction")


#: 0.8 leaves room for the rest of this turn: a reasoning answer alone can take ten thousand tokens,
#: and the calibrated estimate still errs by a few percent.
AUTO_RATIO = 0.8

#: Follow-ups often refer to the last answer ("translate that into English"), so the latest turns
#: stay verbatim.
RETAIN_RATIO = 0.15

#: kept verbatim when the window is unknown (manual compaction and overflow recovery only)
RETAIN_TOKENS_WITHOUT_WINDOW = 16_000

#: circuit breaker: consecutive failures before auto-compaction stops trying; reset on success
MAX_FAILURES = 2

#: when the summary request itself overflows, how often to drop the oldest turns and retry
MAX_SUMMARY_SHRINKS = 2

#: Not worth a model call below this; a sectioned summary of such short text is often longer than it.
MIN_SOURCE_TOKENS = 1500


def auto_threshold(window: int | None) -> int | None:
    if not window or window <= 0:
        return None
    return int(window * AUTO_RATIO)


def retain_budget(window: int | None, trigger: str) -> int:
    """Budget for turns kept verbatim. Overflow recovery keeps none: it needs all the room it can get."""
    if trigger == "overflow":
        return 0
    if window and window > 0:
        return int(window * RETAIN_RATIO)
    return RETAIN_TOKENS_WITHOUT_WINDOW


def choose(sizes: Sequence[int], *, budget: int, trigger: str) -> int | None:
    """How many of the oldest uncovered, finished turns to summarise; None when not worth it.

    Counting back from the newest turn, the ones that fit `budget` stay. auto: nothing when
    everything fits (the excess is in the paper or the current turn); overflow: keep none;
    manual: always compact, keeping the newest turn when everything fits.
    """
    count = len(sizes)
    if count == 0:
        return None
    kept = 0
    total = 0
    if trigger != "overflow":
        for size in reversed(sizes):
            if total + size > budget:
                break
            total += size
            kept += 1
    summarized = count - kept
    if summarized == 0:
        if trigger != "manual":
            return None
        summarized = count - 1 if count >= 2 else 1
    return summarized


#: Appended as the last user message, after the turns being compacted. English and fixed, like the
#: system prompt; the sections follow what paper reading needs.
COMPACTION_INSTRUCTION = """Pause the reading session. Your only task now is to write a checkpoint of the conversation above, so that those turns can be removed from your context. Later you will continue with the paper text, this checkpoint, and only the most recent turns.

Respond with plain text only. Do not call any tools: everything you need is already in the conversation above.

Put the checkpoint inside <summary></summary> tags and use exactly these sections, in this order. Write "(none)" for an empty section; never drop one.

## User's goals
- What the user wants to understand or produce. Quote the user's own words where the exact wording matters.

## Answers and findings
- Conclusions already given about the paper, each with the section, figure, table, equation, or page it rests on. Keep exact numbers, formulas, and definitions.

## Work in the project
- Files read, created, or edited (exact paths under md/, files/, code/, workbench/, notes/), repositories fetched, analyses or plots run and their key results, OCR corrections made.

## Corrections and preferences
- Mistakes the user pointed out, and instructions about language, format, depth, or things to avoid.

## Open threads
- Questions or tasks still pending, and what was in progress when this checkpoint was written.

Be specific and terse: bullets, not prose. Leave out anything the paper text already states and anything already superseded. If an earlier checkpoint appears above, fold it in rather than repeating it. Write in the language the user has mostly been using. Stay under about 1,500 words."""

#: system prompt for the tool-free fallback request
SUMMARIZER_SYSTEM = (
    "You write checkpoints of research conversations about a paper. Respond with plain text only."
)


def summary_request(
    *,
    model: str,
    system: str,
    tools: tuple[ToolSchema, ...],
    paper: Message,
    previous: Message | None,
    turns: Sequence[Message],
    fallback: bool = False,
) -> CallRequest:
    """Build a summary request.

    Main path: [paper, (old summary), turns..., instruction] with the conversation's own system
    prompt and tools, so all but the last message is the next request's prefix and hits the cache.
    Fallback: no tools, a summarizer-only prompt, calls flattened into text (some protocols reject
    tool blocks without declared tools).
    """
    instruction = Message.text("user", COMPACTION_INSTRUCTION)
    head = [paper, *([previous] if previous is not None else [])]
    if not fallback:
        return CallRequest(
            model=model,
            messages=(*head, *turns, instruction),
            system=system,
            tools=tools,
            cacheable_prefix=1,
        )
    return CallRequest(
        model=model,
        messages=(*head, *(_flatten(message) for message in turns), instruction),
        system=SUMMARIZER_SYSTEM,
        cacheable_prefix=1,
    )


def _flatten(message: Message) -> Message:
    """Flatten a message's tool calls and results into text."""
    if all(isinstance(block, TextBlock) for block in message.content):
        return message
    lines: list[str] = []
    for block in message.content:
        if isinstance(block, TextBlock):
            lines.append(block.text)
        elif isinstance(block, ToolUseBlock):
            lines.append(f"[tool call {block.name}: {json.dumps(block.arguments, ensure_ascii=False)}]")
        elif isinstance(block, ToolResultBlock):
            lines.append(f"[tool result{' (error)' if block.is_error else ''}]\n{block.content}")
        elif isinstance(block, ImageBlock):
            lines.append("[image]")
    return Message.text(message.role, "\n\n".join(lines))


_ANALYSIS = re.compile(r"<analysis>.*?</analysis>", re.S)
_SUMMARY = re.compile(r"<summary>(.*?)</summary>", re.S)


def extract_summary(text: str) -> str:
    """The summary from the model's reply: inside <summary> when present, else everything;
    <analysis> drafts are dropped.
    """
    text = _ANALYSIS.sub("", text or "")
    match = _SUMMARY.search(text)
    if match is not None:
        return match.group(1).strip()
    # opened but never closed (probably truncated): drop the tag, keep the text
    return re.sub(r"</?summary>", "", text).strip()



class CompactionError(Exception):
    """Compaction failed; the stable code picks the UI wording, str() is the human sentence."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class NothingToCompact(CompactionError):
    """Nothing worth compacting. Not a failure during auto-compaction, and not shown."""

    def __init__(self) -> None:
        super().__init__(
            "NOTHING_TO_COMPACT",
            ui("没有可以压缩的内容", "Nothing to compact"),
        )


@dataclass(frozen=True)
class Compaction:
    """A successful compaction: the logged event and the replaced message list."""

    data: dict[str, Any]
    messages: tuple[Message, ...]


#: Conversations being written. One writer per conversation: compaction during a turn would race it,
#: and a turn started during compaction would see the old history. One process, so a set suffices.
_busy: set[tuple[str, str]] = set()


def occupy(project_id: str, conversation: str) -> bool:
    """Claim a conversation; False when it is already taken."""
    key = (project_id, conversation)
    if key in _busy:
        return False
    _busy.add(key)
    return True


def release(project_id: str, conversation: str) -> None:
    _busy.discard((project_id, conversation))


@dataclass
class Compactor:
    """Context management for one conversation: measure, compact when needed, swap in the new messages.

    Knows nothing about HTTP, SSE or the tool loop: reports leave through two callbacks and the
    model stream is passed in, so tests can drive it with scripted doubles.
    """

    #: log store with events() and append_event() (ProjectStore)
    store: Any
    project_id: str
    conversation: str
    provider: str
    model: str
    system: str
    tools: tuple[ToolSchema, ...]
    #: the paper message (context.paper_message), byte-identical to the chat request's first message
    paper: Message
    #: CallRequest -> async StreamChunks. Bypasses the UI wrapper: a summary is not an answer and must
    #: not appear in the transcript.
    stream: Callable[[CallRequest], Any]
    #: hand-filled or detected window; None means no auto-compaction, only overflow recovery and manual
    window: int | None = None
    #: a turn is in progress (chat); manual compaction happens between turns
    in_turn: bool = False
    #: index of this turn's question; set by the route, moved after compaction
    turn_start: int = 0
    #: calibration ratio (meter.calibration), updated after each reported step
    ratio: float | None = None
    on_context: Callable[[ContextReport], None] | None = None
    on_compaction: Callable[[dict[str, Any]], None] | None = None
    cancelled: Callable[[], bool] | None = None
    #: turns images named in the log back into blocks, so summaries and measures see them
    images: ImageLoader | None = None

    _history: History | None = field(default=None, init=False, repr=False)
    _failures: int = field(default=0, init=False)
    #: this step's estimate, waiting for its reported usage
    _pending: int = field(default=0, init=False)
    _usage: Usage | None = field(default=None, init=False)

    @property
    def threshold(self) -> int | None:
        return auto_threshold(self.window)

    def history(self, *, fresh: bool = False) -> History:
        if fresh or self._history is None:
            self._history = derive_history(
                self.store.events(self.project_id, conversation=self.conversation),
                images=self.images,
            )
        return self._history

    def _estimate(self, messages: Sequence[Message]) -> RequestEstimate:
        return estimate_request(CallRequest(
            model=self.model, messages=tuple(messages), system=self.system,
            tools=self.tools, cacheable_prefix=1 if messages else 0,
        ))

    def _scaled(self, raw: int) -> int:
        return round(raw * (self.ratio if self.ratio is not None else 1.0))

    def report(
        self, messages: Sequence[Message], *, live: bool, estimate: RequestEstimate | None = None
    ) -> ContextReport:
        history = self.history()
        return measure(
            estimate or self._estimate(messages),
            has_summary=bool(history.summary),
            turn_start=self.turn_start if live else len(messages),
            ratio=self.ratio,
            window=self.window,
            threshold=self.threshold,
            turns=history.count,
            covered=history.covered,
            compactions=history.compactions,
            live=live,
        )

    def idle_messages(self) -> list[Message]:
        """Everything in the next request except the question: paper, summary and turns
        (past turns trimmed as usual).
        """
        return [self.paper, *settle_history(self.history().visible())]

    def idle_report(self) -> ContextReport:
        """Forecast before the next question. The log grows during a turn, so it is re-read."""
        self.history(fresh=True)
        return self.report(self.idle_messages(), live=False)

    async def prepare(self, messages: list[Message]) -> list[Message] | None:
        """Before each step: compact above the threshold, and report this step's context either way."""
        replaced: list[Message] | None = None
        threshold = self.threshold
        if threshold is not None and self._failures < MAX_FAILURES:
            if self._scaled(self._estimate(messages).total) >= threshold:
                replaced = await self._attempt("auto", messages)
        current = replaced if replaced is not None else messages
        estimate = self._estimate(current)
        self._pending = estimate.total
        self._emit_context(self.report(current, live=True, estimate=estimate))
        return replaced

    async def recover(self, messages: list[Message], failure: LlmFailure) -> list[Message] | None:
        """The provider says the window overflowed: compact once regardless of the threshold. If room was
        made, return the new messages and the step is retried.
        """
        if self._failures >= MAX_FAILURES:
            return None
        replaced = await self._attempt("overflow", messages)
        if replaced is not None:
            estimate = self._estimate(replaced)
            self._pending = estimate.total
            self._emit_context(self.report(replaced, live=True, estimate=estimate))
        return replaced

    def observe(self, usage: Usage | None) -> None:
        """A step finished: record its reported usage and update the ratio."""
        self._usage = usage
        if usage is not None:
            ratio = ratio_of(usage.prompt_tokens, self._pending)
            if ratio is not None:
                self.ratio = ratio

    def step_record(self) -> dict[str, Any]:
        """Numbers logged with this step (assistant/message usage and estimate); the next open calibrates
        from them. Numbers only.
        """
        record: dict[str, Any] = {}
        if self._usage is not None:
            record["usage"] = self._usage.as_dict()
        if self._pending:
            record["estimate"] = self._pending
        return record

    async def _attempt(self, trigger: str, messages: list[Message]) -> list[Message] | None:
        try:
            return list((await self.compact(trigger, messages)).messages)
        except NothingToCompact:
            return None
        except CompactionError as exc:
            self._failures += 1
            logger.warning(
                "压缩没成 project=%s conversation=%s trigger=%s code=%s",
                self.project_id, self.conversation, trigger, exc.code,
            )
            return None

    async def compact_now(self) -> Compaction:
        """Manual compaction between turns; raises CompactionError when there is nothing to do or it fails."""
        return await self.compact("manual")

    async def compact(self, trigger: str, messages: Sequence[Message] | None = None) -> Compaction:
        """Compact once. `messages` is the request this step was about to send (chat); absent when manual."""
        history = self.history(fresh=True)
        closed = history.count - (1 if self.in_turn else 0)
        first = history.covered + 1
        groups = [tuple(settle_history(history.turns[index])) for index in range(first, closed + 1)]
        chosen = choose(
            [estimate_messages(group) for group in groups],
            budget=retain_budget(self.window, trigger), trigger=trigger,
        )
        if chosen is None or sum(estimate_messages(group) for group in groups[:chosen]) < MIN_SOURCE_TOKENS:
            raise NothingToCompact()
        upto = history.covered + chosen
        current = list(messages) if messages is not None else self.idle_messages()

        self._emit_compaction({"phase": "start", "trigger": trigger})
        try:
            before = self._scaled(self._estimate(current).total)
            previous = history.checkpoint()
            summary, usage, dropped = await self._summarize(previous, groups[:chosen])
            source = estimate_messages(
                ([previous] if previous is not None else [])
                + [message for group in groups[dropped:chosen] for message in group]
            )
            if rough_tokens(summary) >= source:
                raise CompactionError(
                    "SUMMARY_NOT_SMALLER",
                    ui("模型写的摘要不比原文短，没有采用。",
                       "The model's summary wasn't shorter than the original, so it wasn't used."),
                )
            if self._is_cancelled():
                raise CompactionError("CANCELLED", ui("已取消", "Canceled"))

            compacted = History(
                turns=history.turns, summary=summary, covered=upto,
                compactions=history.compactions + 1,
            )
            visible = settle_history(compacted.visible(upto=closed))
            tail = current[self.turn_start:] if self.in_turn and messages is not None else []
            replaced = (self.paper, *visible, *tail)
            data: dict[str, Any] = {
                "summary": summary,
                "turns": upto,
                "kept": closed - upto,
                "trigger": trigger,
                "provider": self.provider,
                "model": self.model,
                "before": before,
                "after": self._scaled(self._estimate(replaced).total),
                "usage": (usage or Usage()).as_dict(),
            }
            if dropped:
                data["dropped"] = dropped
            # The event is written last: if anything before fails, the log still shows the old history.
            self.store.append_event(
                self.project_id, ProjectEvent.CONVERSATION_COMPACTED, data,
                conversation=self.conversation,
            )
        except CompactionError as exc:
            self._emit_compaction({"phase": "failed", "trigger": trigger,
                                   "code": exc.code, "message": str(exc)})
            raise
        except Exception as exc:  # noqa: BLE001 - a failing log write must not become a 500 for the whole turn
            logger.exception("压缩出错 project=%s conversation=%s", self.project_id, self.conversation)
            error = CompactionError("INTERNAL", str(exc) or exc.__class__.__name__)
            self._emit_compaction({"phase": "failed", "trigger": trigger,
                                   "code": error.code, "message": str(error)})
            raise error from exc

        self._history = compacted
        self._failures = 0
        if self.in_turn and messages is not None:
            self.turn_start = 1 + len(visible)
        logger.info(
            "压缩完成 project=%s conversation=%s trigger=%s 覆盖到第 %d 轮 留 %d 轮 %d → %d token",
            self.project_id, self.conversation, trigger, upto, closed - upto,
            data["before"], data["after"],
        )
        payload = compaction_item(data) or {}
        payload.pop("kind", None)
        self._emit_compaction({"phase": "done", **payload})
        return Compaction(data=data, messages=replaced)

    async def _summarize(
        self, previous: Message | None, groups: Sequence[tuple[Message, ...]]
    ) -> tuple[str, Usage | None, int]:
        """Ask for a summary; returns (summary, usage, oldest turns dropped because they didn't fit)."""
        dropped = 0
        shrinks = 0
        while True:
            turns = [message for group in groups[dropped:] for message in group]
            request = summary_request(
                model=self.model, system=self.system, tools=self.tools,
                paper=self.paper, previous=previous, turns=turns,
            )
            text, finish = await self._collect(request)
            if finish.kind == "error" and finish.failure is not None:
                left = len(groups) - dropped
                if (finish.failure.code == CONTEXT_WINDOW_EXCEEDED
                        and shrinks < MAX_SUMMARY_SHRINKS and left > 1):
                    # The summary request itself overflows: drop the oldest third and retry. Lossy, but better than
                    # stuck; the dropped turns are recorded.
                    dropped += max(1, left // 3)
                    shrinks += 1
                    continue
                raise CompactionError(finish.failure.code, finish.failure.message)
            summary = extract_summary(text)
            if not summary:
                # the model didn't just write (probably called a tool): retry without tools
                fallback = summary_request(
                    model=self.model, system=self.system, tools=self.tools,
                    paper=self.paper, previous=previous, turns=turns, fallback=True,
                )
                text, finish = await self._collect(fallback)
                if finish.kind == "error" and finish.failure is not None:
                    raise CompactionError(finish.failure.code, finish.failure.message)
                summary = extract_summary(text)
            if not summary:
                raise CompactionError(
                    "SUMMARY_EMPTY", ui("模型没有给出摘要。", "The model returned no summary."))
            if dropped:
                summary = (
                    f"(The earliest {dropped} turn(s) of this span could not be summarized because "
                    "they no longer fit in the context window; they remain in the conversation log.)"
                    f"\n\n{summary}"
                )
            return summary, finish.usage, dropped

    async def _collect(self, request: CallRequest) -> tuple[str, Finish]:
        """Collect one model stream, text only; reasoning and tool calls are ignored."""
        parts: list[str] = []
        finish: Finish | None = None
        try:
            async for chunk in self.stream(request):
                if self._is_cancelled():
                    raise CompactionError("CANCELLED", ui("已取消", "Canceled"))
                if isinstance(chunk, TextDelta):
                    parts.append(chunk.text)
                elif isinstance(chunk, Finish):
                    finish = chunk
        except LlmError as exc:
            raise CompactionError(exc.code, str(exc)) from exc
        if finish is None:
            finish = Finish(kind="error", failure=LlmFailure(
                ui("模型连接在给出摘要前结束了", "The model connection ended before the summary"), TRANSPORT))
        return "".join(parts), finish

    def _is_cancelled(self) -> bool:
        return bool(self.cancelled is not None and self.cancelled())

    def _emit_context(self, report: ContextReport) -> None:
        if self.on_context is not None:
            self.on_context(report)

    def _emit_compaction(self, payload: dict[str, Any]) -> None:
        if self.on_compaction is not None:
            self.on_compaction(payload)
