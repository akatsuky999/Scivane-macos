"""The agent loop: model speaks, tools run, results come back, model continues.

    build the request (with tool schemas) and stream it
      -> dispatch each tool call as soon as it arrives
      -> when the stream ends, collect results in model order
      -> append the assistant message (text and calls) and the results
      -> repeat until the model stops calling tools

Dispatch happens mid-stream because generation takes seconds per step while local tools take
milliseconds. Every step is logged, the step count is capped, and the history stays valid after
a cancel (the dispatcher fills in results for undispatched calls).
"""

from __future__ import annotations

import asyncio
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
)
from ..llm.errors import CONTEXT_WINDOW_EXCEEDED, TRANSPORT
from .definition import ToolContext
from .journal import Journal, NullJournal
from .registry import ToolRegistry
from .scheduler import Dispatcher

__all__ = ["AgentLoop", "LoopResult", "MAX_STEPS"]


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

        for step in range(1, self.max_steps + 1):
            if self.prepare is not None:
                replaced = await self.prepare(messages)  # type: ignore[operator]
                if replaced is not None:
                    messages = list(replaced)

            #: retried once after an overflow; compacting again would give the same result
            recovered = False
            while True:
                text_parts: list[str] = []
                calls: list[ToolCall] = []
                finish: Finish | None = None

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
                aborted_mid_stream = False
                #: tasks already running, aligned with `calls` (None = not dispatched)
                started: list[object] = []
                async for chunk in self.stream(turn):  # type: ignore[operator]
                    # Cancellation must work mid-stream: generation is the longest part of a step (over a minute),
                    # and checking only between steps made the stop button look broken.
                    if self.context.cancelled():
                        aborted_mid_stream = True
                        break
                    if isinstance(chunk, TextDelta):
                        text_parts.append(chunk.text)
                    elif isinstance(chunk, ToolCall):
                        calls.append(chunk)
                        # Start right away instead of waiting for the rest of the generation; the gate enforces
                        # concurrency, so there is no need to see the whole step first.
                        started.append(dispatcher.start(chunk))
                    elif isinstance(chunk, Finish):
                        finish = chunk
                        if chunk.usage is not None:
                            usage = usage.merged(chunk.usage)

                # Try to recover from an overflow before reporting it, but only when this step produced nothing
                # yet: overflows are rejected before generation, and retrying after output would duplicate it.
                if (
                    not recovered and not aborted_mid_stream and self.recover is not None
                    and finish is not None and finish.kind == "error"
                    and finish.failure is not None
                    and finish.failure.code == CONTEXT_WINDOW_EXCEEDED
                    and not calls and not text_parts
                ):
                    replaced = await self.recover(messages, finish.failure)  # type: ignore[operator]
                    if replaced is not None:
                        messages = list(replaced)
                        recovered = True
                        continue
                break

            if aborted_mid_stream:
                # Drop half-finished tool_use blocks (a call without a result makes the next request invalid)
                # and collect running tasks so none keep writing files. A stop, not an error.
                await _abandon(started)
                return LoopResult(
                    text="".join(text_parts) or last_text, steps=step, stop="aborted",
                    usage=usage, calls=tuple(every_call),
                )

            said = "".join(text_parts)
            # A stream that ends unexpectedly is not a normal stop; treating it as one would end the turn
            # silently after the tool results.
            if finish is None:
                await _abandon(started)
                return LoopResult(
                    text=said or last_text, steps=step, stop="error",
                    usage=usage, calls=tuple(every_call + calls),
                    failure=LlmFailure("模型连接在给出终态前结束了", TRANSPORT),
                )
            if said:
                last_text = said
            stop = finish.kind if finish is not None else "stop"
            self.journal.assistant_message(said, stop=stop)

            if stop != "tool_use" or not calls:
                # calls without a tool_use finish shouldn't happen, but if they do the started tools must be collected
                await _abandon(started)
                return LoopResult(
                    text=said or last_text, steps=step, stop=stop,
                    usage=usage, calls=tuple(every_call),
                    failure=finish.failure if finish is not None else None,
                )

            every_call.extend(calls)
            # The step's text and calls go in one message: every protocol requires tool_result right after
            # the assistant message holding the tool_use.
            assistant_blocks: list[object] = []
            if said:
                assistant_blocks.append(TextBlock(said))
            assistant_blocks.extend(
                ToolUseBlock(c.id, c.name, c.arguments) for c in calls
            )
            messages.append(Message("assistant", tuple(assistant_blocks)))  # type: ignore[arg-type]

            # already running since the stream; just collect results in model order
            results = await dispatcher.settle(tuple(calls), started)  # type: ignore[arg-type]
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
