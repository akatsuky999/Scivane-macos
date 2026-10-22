"""The agent loop: model speaks, tools run, results come back, model continues.

    build the request (with tool schemas) and stream it
      -> dispatch each tool call as soon as it arrives
      -> when the stream ends, collect results in model order
      -> append the assistant message (text and calls) and the results
      -> repeat until the model stops calling tools

Dispatch happens mid-stream because generation takes seconds per step while local tools take
milliseconds. Every step is logged, the step count is capped, and the history stays valid after
a cancel (the dispatcher fills in results for undispatched calls).

A stop has to land wherever the turn is waiting. Checking a flag per chunk covers a talking
model, but not one that went silent (a provider writing a long tool argument it doesn't stream),
a compaction, or a tool still running; `interrupted` races each of those waits.
"""

from __future__ import annotations

import asyncio
from contextlib import aclosing
from dataclasses import dataclass, field

from ..llm.types import (
    LlmFailure,
    CallRequest,
    Finish,
    Message,
    TextBlock,
    TextDelta,
    ToolCall,
    ToolResultBlock,
    ToolUseBlock,
    Usage,
    append_user_text,
)
from ..jobs import INTERRUPTED as _INTERRUPTED, interruptible
from ..llm.errors import CONTEXT_WINDOW_EXCEEDED, TRANSPORT
from ..llm.retry import LONG_SILENCE, is_long_silence
from .definition import ToolContext
from .files import SECTION_CHARS
from .journal import Journal, NullJournal
from .registry import ToolRegistry
from .scheduler import Dispatcher

__all__ = [
    "AgentLoop", "LoopResult", "MAX_STEPS", "RESUME_NOTE", "SECTION_CHARS", "SILENT_CUT_SECONDS",
    "CUT_TEXT_NOTE", "CUT_CALL_NOTE", "MAX_CONTINUATIONS",
]


async def _abandon(started: list[object]) -> None:
    """Cancel tools that started but whose results nobody will collect. Left alone, they would keep
    writing files after the turn was cancelled.
    """
    for task in started:
        if task is not None and not task.done():  # type: ignore[union-attr]
            task.cancel()  # type: ignore[union-attr]
    for task in started:
        if task is None:
            continue
        try:
            await task  # type: ignore[misc]
        except (asyncio.CancelledError, Exception):  # noqa: BLE001
            pass

#: Runaway guard, not a work limit. Checking a paper's code formula by formula can take dozens of
#: steps; the user watching the screen can stop it at any time, and model-side failures now reach
#: the UI instead of failing silently.
MAX_STEPS = 200

#: A TIMEOUT after at least this much silence is the connection giving up on a model that was busy
#: (a gateway's own cut, or ours), not a network fault. The same number keeps the transport layer
#: from retrying it; a module name of its own so tests can shorten it.
SILENT_CUT_SECONDS = LONG_SILENCE

#: What the model reads after a silent cut. Written to the log verbatim with the turn/resumed
#: event, so replays stay byte-identical if this wording changes. English and fixed, like every
#: instruction to the model. True whether or not the step had said something first: those words
#: stay in the history right above this note.
RESUME_NOTE = (
    "[Scivane] Your previous response was cut off: the connection closed after {quiet} seconds "
    "in which nothing arrived, so whatever you were generating then was lost and no tool call "
    "from it ran. This usually happens while one tool call carries a very long argument, such as "
    "a whole document in one `write`: the argument is generated in full before anything is sent, "
    "and the connection gives up on the silence. Continue the task without repeating what you "
    "already said, keeping each tool call's arguments under about {section} characters: write a "
    "long file in parts, the first with `write` and each next one with `write` and "
    "`append: true`. A part is a size, not a section of the paper."
)


#: What the model reads after the output limit cut its answer. Shown below the text so far, so it
#: restarts the cut line and reopens a fence or table. Logged verbatim (turn/continued), like
#: RESUME_NOTE.
CUT_TEXT_NOTE = (
    "[Scivane] Your previous response was cut off at the output limit. Continue exactly where it "
    "stopped: begin with the sentence, line, list item, or table row that was cut and write it in "
    "full; if you were inside a code block or a table, reopen it first (the same fence and "
    "language, or the table's header row). Do not repeat anything before that point and do not "
    "mention the interruption."
)

#: After the output limit cut a tool call. The fragment never ran; a smaller call will.
CUT_CALL_NOTE = (
    "[Scivane] Your previous response reached the output limit while writing a `{tool}` call, so "
    "the call was discarded and nothing ran. Make it again with less in it: keep each call's "
    "arguments under about {section} characters, and write a long file in parts, the first with "
    "`write` and each next one with `write` and `append: true`."
)

#: Continuations after the output limit in a row; a step that runs tools resets the count. A long
#: answer can need a few; one that keeps hitting the limit is not converging.
MAX_CONTINUATIONS = 3


@dataclass
class LoopResult:
    """What one question produced."""

    text: str
    steps: int
    stop: str
    usage: Usage = field(default_factory=Usage)
    #: tools called at each step, in order; for the UI and the log
    calls: tuple[ToolCall, ...] = ()
    #: stopped at the step cap: not an error, but the user must be told
    exhausted: bool = False
    #: why the turn failed when stop == "error"; without it the route can't tell done from error and
    #: the UI shows nothing (an expired key used to fail silently this way)
    failure: LlmFailure | None = None


@dataclass
class _Step:
    """What one model request has produced so far. Filled while streaming, so whatever an
    interruption cuts short is still here to clean up."""

    text: list[str] = field(default_factory=list)
    calls: list[ToolCall] = field(default_factory=list)
    #: tasks already running, aligned with `calls` (None = not dispatched)
    started: list[object] = field(default_factory=list)
    finish: Finish | None = None
    #: the per-chunk check saw the cancel
    aborted: bool = False


def _assistant(said: str, calls: list[ToolCall]) -> Message:
    """A step as the next request carries it: its words and calls in one message, since every
    protocol wants tool_result right after the message holding the tool_use."""
    blocks: list[object] = [TextBlock(said)] if said else []
    blocks.extend(ToolUseBlock(c.id, c.name, c.arguments) for c in calls)
    return Message("assistant", tuple(blocks))  # type: ignore[arg-type]


def _silent_cut(failure: LlmFailure | None) -> bool:
    return is_long_silence(failure, SILENT_CUT_SECONDS)


def _failure_record(failure: LlmFailure | None) -> dict | None:
    """What the log keeps about a failed step: the code and the silence, never the message."""
    if failure is None:
        return None
    record: dict[str, object] = {"code": failure.code}
    if failure.quiet is not None:
        record["quiet"] = failure.quiet
    return record


@dataclass
class AgentLoop:
    """Connects the model, tools and the log into one loop.

    `stream` takes a CallRequest and yields StreamChunks asynchronously; passed in rather than
    using LlmRegistry so tests can run the whole loop against scripted doubles.
    """

    stream: object
    registry: ToolRegistry
    context: ToolContext
    journal: Journal = field(default_factory=NullJournal)
    approve: object = None
    max_steps: int = MAX_STEPS
    #: network capability (netproxy.NetworkAccess); None means no network
    network: object = None
    #: this turn's job id; audit attribution is by (job_id, call_id)
    job_id: str = ""
    #: Called before each request: async (messages) -> replacement messages or None. Used for context
    #: management (Compactor.prepare); the loop itself knows nothing about compaction.
    prepare: object = None
    #: Called when the provider reports a context overflow: async (messages, failure) -> replacement
    #: messages or None. With replacements the step is retried once; otherwise it fails as before.
    recover: object = None
    #: async () -> None, returning when the turn is cancelled (jobs.until_cancelled). Without it a
    #: stop is only noticed when the next chunk arrives.
    interrupted: object = None

    async def run(self, request: CallRequest) -> LoopResult:
        """Run until the model stops calling tools.

        The caller assembles request.tools (registry.schemas()); that choice is what separates the
        two agent levels.
        """
        dispatcher = Dispatcher(
            registry=self.registry, journal=self.journal,
            context=self.context, approve=self.approve,
            network=self.network, job_id=self.job_id,
        )
        messages = list(request.messages)
        usage = Usage()
        every_call: list[ToolCall] = []
        last_text = ""
        #: A resume is allowed once per run of failures: a second cut right after the note means
        #: it didn't help, and repeating it would only spend more.
        may_resume = True
        continuations = 0

        for step in range(1, self.max_steps + 1):
            if self.prepare is not None:
                replaced = await self._unless_interrupted(self.prepare(messages))  # type: ignore[operator]
                if replaced is _INTERRUPTED:
                    return LoopResult(
                        text=last_text, steps=step, stop="aborted",
                        usage=usage, calls=tuple(every_call),
                    )
                if replaced is not None:
                    messages = list(replaced)  # type: ignore[arg-type]

            #: retried once after an overflow; compacting again would give the same result
            recovered = False
            while True:
                current = _Step()
                turn = CallRequest(
                    model=request.model,
                    messages=tuple(messages),
                    system=request.system,
                    max_tokens=request.max_tokens,
                    temperature=request.temperature,
                    cacheable_prefix=request.cacheable_prefix,
                    tools=request.tools,
                    purpose=request.purpose,
                    extra=request.extra,
                )
                if await self._unless_interrupted(self._consume(turn, current, dispatcher)) is _INTERRUPTED:
                    current.aborted = True
                finish = current.finish
                if finish is not None and finish.usage is not None:
                    usage = usage.merged(finish.usage)

                # Try to recover from an overflow before reporting it, but only when this step produced nothing
                # yet: overflows are rejected before generation, and retrying after output would duplicate it.
                if (
                    not recovered and not current.aborted and self.recover is not None
                    and finish is not None and finish.kind == "error"
                    and finish.failure is not None
                    and finish.failure.code == CONTEXT_WINDOW_EXCEEDED
                    and not current.calls and not current.text
                ):
                    replaced = await self._unless_interrupted(
                        self.recover(messages, finish.failure))  # type: ignore[operator]
                    if replaced is _INTERRUPTED:
                        current.aborted = True
                    elif replaced is not None:
                        messages = list(replaced)  # type: ignore[arg-type]
                        recovered = True
                        continue
                break

            said = "".join(current.text)
            calls = current.calls
            if current.aborted:
                await self._stop_step(current, dispatcher, said)
                return LoopResult(
                    text=said or last_text, steps=step, stop="aborted",
                    usage=usage, calls=tuple(every_call + calls),
                )

            # A stream that ends unexpectedly is not a normal stop; treating it as one would end the turn
            # silently after the tool results.
            if finish is None:
                await _abandon(current.started)
                return LoopResult(
                    text=said or last_text, steps=step, stop="error",
                    usage=usage, calls=tuple(every_call + calls),
                    failure=LlmFailure("模型连接在给出终态前结束了", TRANSPORT),
                )
            if said:
                last_text = said
            stop = finish.kind
            failure = finish.failure if stop == "error" else None
            self.journal.assistant_message(said, stop=stop, failure=_failure_record(failure))

            if stop == "error" and may_resume and not calls and _silent_cut(failure):
                # The provider went quiet and the connection was cut, most likely while the model wrote
                # one very long tool argument. Retrying unchanged would hit the same wall, so the model is
                # told why and how to split the work; the note goes into the log so replays match.
                # Words said before the silence are already on screen and in the log: they stay in the
                # history as this step's message (the projection replays them the same way), and the
                # note follows as a user message of its own, so the model goes on instead of repeating.
                note = RESUME_NOTE.format(quiet=round(failure.quiet or 0), section=SECTION_CHARS)  # type: ignore[union-attr]
                self.journal.turn_resumed(
                    note, reason="silent_cut", failure=_failure_record(failure) or {})
                if said:
                    messages.append(_assistant(said, []))
                messages = append_user_text(messages, note)
                may_resume = False
                continue

            if stop == "length" and continuations < MAX_CONTINUATIONS:
                # The output limit cut the step. Keep what it produced (its words, any complete calls
                # and their results), then tell the model how to go on; the note joins the history the
                # way the projection replays turn/continued.
                continuations += 1
                if calls:
                    every_call.extend(calls)
                    messages.append(_assistant(said, calls))
                    results = await self._settle(dispatcher, calls, current.started)
                    messages.append(Message("user", tuple(results)))
                elif said:
                    messages.append(_assistant(said, []))
                note = (CUT_CALL_NOTE.format(tool=finish.cut, section=SECTION_CHARS) if finish.cut
                        else CUT_TEXT_NOTE)
                self.journal.turn_continued(note, reason="output_limit")
                messages = append_user_text(messages, note)
                if self.context.cancelled():
                    return LoopResult(
                        text=said or last_text, steps=step, stop="aborted",
                        usage=usage, calls=tuple(every_call),
                    )
                continue

            if stop != "tool_use" or not calls:
                # calls without a tool_use finish shouldn't happen, but if they do the started tools must be collected
                await _abandon(current.started)
                return LoopResult(
                    text=said or last_text, steps=step, stop=stop,
                    usage=usage, calls=tuple(every_call),
                    failure=failure,
                )

            may_resume = True
            continuations = 0
            every_call.extend(calls)
            messages.append(_assistant(said, calls))

            # already running since the stream; just collect results in model order
            results = await self._settle(dispatcher, calls, current.started)
            # The dispatcher guarantees one result per call (synthetic ones after a cancel); a mismatch
            # would make the next request invalid, so check again.
            assert len(results) == len(calls), "工具结果数与调用数不一致 —— 历史会变非法"
            messages.append(Message("user", tuple(results)))

            if self.context.cancelled():
                return LoopResult(
                    text=said or last_text, steps=step, stop="aborted",
                    usage=usage, calls=tuple(every_call),
                )

        return LoopResult(
            text=last_text, steps=self.max_steps, stop="max_steps",
            usage=usage, calls=tuple(every_call), exhausted=True,
        )

    async def _consume(self, turn: CallRequest, current: _Step, dispatcher: Dispatcher) -> None:
        # aclosing: leaving early must close the provider stream now, not when it is collected, or
        # the provider keeps generating (and billing) for a turn that has ended
        async with aclosing(self.stream(turn)) as chunks:  # type: ignore[operator]
            async for chunk in chunks:
                # Cancellation must work mid-stream: generation is the longest part of a step (over a
                # minute), and checking only between steps made the stop button look broken.
                if self.context.cancelled():
                    current.aborted = True
                    return
                if isinstance(chunk, TextDelta):
                    current.text.append(chunk.text)
                elif isinstance(chunk, ToolCall):
                    current.calls.append(chunk)
                    # Start right away instead of waiting for the rest of the generation; the gate enforces
                    # concurrency, so there is no need to see the whole step first.
                    current.started.append(dispatcher.start(chunk))
                elif isinstance(chunk, Finish):
                    current.finish = chunk

    async def _settle(
        self, dispatcher: Dispatcher, calls: list[ToolCall], started: list[object],
    ) -> tuple[ToolResultBlock, ...]:
        """Collect the step's results. A stop while tools run cancels them; settling still returns
        one result per call (synthetic for the cancelled), so the history stays valid."""
        settling = asyncio.ensure_future(dispatcher.settle(tuple(calls), started))  # type: ignore[arg-type]
        if await self._unless_interrupted(asyncio.shield(settling)) is _INTERRUPTED:
            for task in started:
                if task is not None and not task.done():  # type: ignore[union-attr]
                    task.cancel()  # type: ignore[union-attr]
        return await settling

    async def _stop_step(self, current: _Step, dispatcher: Dispatcher, said: str) -> None:
        """Close a step cut short by a stop. Calls already started get their results (synthetic for the
        ones cancelled midway) and the words already on screen are kept, so the log and the next request
        show what the user saw. Half-received calls never get here: a call is whole or absent."""
        if current.calls:
            for task in current.started:
                if task is not None and not task.done():  # type: ignore[union-attr]
                    task.cancel()  # type: ignore[union-attr]
            await dispatcher.settle(tuple(current.calls), current.started)  # type: ignore[arg-type]
        if said or current.calls:
            self.journal.assistant_message(said, stop="aborted")

    async def _unless_interrupted(self, awaitable):
        """Await `awaitable` unless the turn is cancelled first (then INTERRUPTED)."""
        return await interruptible(awaitable, self.interrupted)  # type: ignore[arg-type]
