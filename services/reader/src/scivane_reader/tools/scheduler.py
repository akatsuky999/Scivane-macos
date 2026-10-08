"""Tool call scheduling: concurrency, barriers and cancellation.

Read-only tools run concurrently; anything else runs alone. Unknown tools, unparseable
arguments and undeclared concurrency all count as unsafe.

After a cancel, every call that wasn't dispatched still gets a synthetic error result: all
three protocols require a tool_result for every tool_use, and a history missing one can never
be sent again, even after a restart. Started calls settle with their real results first, in
model order. Synthetic results carry a `synthetic` flag. Scheduler bugs, unlike cancellations,
get no synthetic results: faking them would bury the bug in the history.
"""

from __future__ import annotations

import asyncio
import contextlib
from collections import deque
from dataclasses import dataclass, field, replace

from .. import i18n
from ..llm.types import ToolCall, ToolResultBlock
from .definition import ToolContext, ToolError, ToolOutcome
from .journal import ABORTED_BEFORE_DISPATCH, Journal
from .registry import ToolRegistry
from .results import apply_limit

__all__ = [
    "Batch", "partition", "Dispatcher", "ApprovalDenied", "DENIED_BY_USER", "Gate",
]

DENIED_BY_USER = "TOOL_DENIED_BY_USER"


class ApprovalDenied(Exception):
    """The user refused this call."""


class Gate:
    """Concurrency gate: read-only tools share it, everything else is exclusive, first come first served.

    A read/write lock rather than batching lets each call start as soon as it leaves the stream.
    Strict ordering matters because models chain calls (grep to locate, then read): a writer at the
    head of the queue also blocks later readers, so it can't starve.
    """

    def __init__(self) -> None:
        self._readers = 0
        self._writer = False
        self._queue: deque[tuple[bool, asyncio.Future]] = deque()

    def _free(self, exclusive: bool) -> bool:
        if exclusive:
            return self._readers == 0 and not self._writer
        return not self._writer

    def _take(self, exclusive: bool) -> None:
        if exclusive:
            self._writer = True
        else:
            self._readers += 1

    def _wake(self) -> None:
        while self._queue:
            exclusive, waiter = self._queue[0]
            if not self._free(exclusive):
                return
            self._queue.popleft()
            self._take(exclusive)
            if not waiter.done():
                waiter.set_result(None)
            if exclusive:
                # the writer holds it exclusively until release
                return

    async def acquire(self, *, exclusive: bool) -> None:
        if not self._queue and self._free(exclusive):
            self._take(exclusive)
            return
        waiter = asyncio.get_running_loop().create_future()
        self._queue.append((exclusive, waiter))
        try:
            await waiter
        except asyncio.CancelledError:
            # a cancelled waiter must leave the queue or it blocks everyone behind it
            try:
                self._queue.remove((exclusive, waiter))
            except ValueError:
                # _wake already let it through, so give back what it was granted
                self.release(exclusive=exclusive)
            raise

    def release(self, *, exclusive: bool) -> None:
        if exclusive:
            self._writer = False
        else:
            self._readers = max(0, self._readers - 1)
        self._wake()


@dataclass(frozen=True)
class Batch:
    """Calls that run together; an unsafe batch always holds a single call (a barrier)."""

    concurrency_safe: bool
    calls: tuple[ToolCall, ...]


def partition(calls: tuple[ToolCall, ...], registry: ToolRegistry) -> tuple[Batch, ...]:
    """Batch by concurrency safety, keeping the model's order (later calls often depend on earlier ones)."""
    batches: list[Batch] = []
    for call in calls:
        safe = _is_safe(call, registry)
        if safe and batches and batches[-1].concurrency_safe:
            batches[-1] = Batch(True, batches[-1].calls + (call,))
        else:
            batches.append(Batch(safe, (call,)))
    return tuple(batches)


def _is_safe(call: ToolCall, registry: ToolRegistry) -> bool:
    """Fail-closed: any doubt counts as unsafe."""
    try:
        tool = registry.find(call.name)
    except ToolError:
        return False
    return bool(tool.concurrency_safe and tool.read_only)


@dataclass
class Dispatcher:
    """Runs all tool calls of a step and returns results in model order."""

    registry: ToolRegistry
    journal: Journal
    context: ToolContext
    #: approval callback for tools that need one; None refuses them all (fail-closed)
    approve: object = None
    #: one gate per dispatcher, so calls in the same turn share one set of rules
    gate: Gate = field(default_factory=Gate)
    #: network capability; None means no proxy and no network for any tool
    network: object = None
    #: this turn's job id; the audit log attributes by (job_id, call_id)
    job_id: str = ""

    def start(self, call: ToolCall) -> asyncio.Task | None:
        """Start this call right away, without waiting for the stream to finish.

        Models often keep talking for hundreds of tokens after a call; the tool can run meanwhile.
        The gate enforces concurrency. Returns None when not dispatched (cancelled); settle() then
        fills in a synthetic result.
        """
        if self.context.cancelled():
            return None
        return asyncio.ensure_future(self._guarded(call))

    async def settle(
        self, calls: tuple[ToolCall, ...], started: list[asyncio.Task | None]
    ) -> tuple[ToolResultBlock, ...]:
        """Collect results in model order; always as many as `calls`. Undispatched calls get synthetic
        results here, which is what keeps the history valid.
        """
        results: list[ToolResultBlock] = []
        for call, task in zip(calls, started):
            if task is None:
                results.append(self._synthesise(call))
                continue
            try:
                results.append(await task)
            except asyncio.CancelledError:
                # cancelled midway: it still needs a result, flagged synthetic
                results.append(self._synthesise(call))
        return tuple(results)

    async def _guarded(self, call: ToolCall) -> ToolResultBlock:
        """Pass the gate, then run."""
        exclusive = not _is_safe(call, self.registry)
        await self.gate.acquire(exclusive=exclusive)
        try:
            return await self._one(call)
        finally:
            self.gate.release(exclusive=exclusive)

    async def run(self, calls: tuple[ToolCall, ...]) -> tuple[ToolResultBlock, ...]:
        """Run a whole step's calls at once. Only the librarian (no streamed dispatch) and tests use it;
        it is start() plus settle(), so both paths share the same rules.
        """
        started = [self.start(call) for call in calls]
        return await self.settle(calls, started)

    async def _one(self, call: ToolCall) -> ToolResultBlock:
        self.journal.tool_call(call.id, call.name, call.arguments)
        try:
            tool = self.registry.find(call.name)
        except ToolError as exc:
            return self._fail(call, str(exc), exc.code)

        if tool.approval_required(call.arguments):
            approved, reason = await self._ask(call, tool.name)
            self.journal.tool_decision(call.id, call.name, approved, reason)
            if not approved:
                # a refusal needs a result too, or the history is invalid
                return self._fail(
                    call, f"用户拒绝了这次调用{('：' + reason) if reason else ''}", DENIED_BY_USER
                )

        try:
            # The network credential is issued here and revoked when the `with` exits: only this layer knows
            # the call id, and only here does `finally` cover every exit (errors, cancellation, timeouts).
            #
            # The UI language is pinned to Chinese inside tools: results are model input and must not change
            # with a UI setting. Summaries and approval cards are computed outside and follow the UI language.
            with self._grant(call.id) as leased, i18n.speaking("zh"):
                context = replace(self.context, network=leased) if leased else self.context
                outcome = await tool.run(call.arguments, context)
        except ToolError as exc:
            return self._fail(call, str(exc), exc.code)
        except asyncio.CancelledError:
            # cancellation propagates: nobody is listening any more
            raise
        except Exception as exc:  # noqa: BLE001
            # An unexpected tool exception must not kill the turn; as an error result the model can retry.
            return self._fail(call, f"工具执行出错：{exc}", "TOOL_CRASHED")

        limited = apply_limit(outcome, tool, self.context.project_dir)
        self.journal.tool_result(
            call.id, call.name, limited.content,
            is_error=limited.is_error, detail=limited.detail,
        )
        return ToolResultBlock(call.id, limited.content, is_error=limited.is_error)

    @contextlib.contextmanager
    def _grant(self, call_id: str):
        """This call's network credential; None all the way down when there is no proxy."""
        if self.network is None:
            yield None
            return
        with self.network.for_call(self.job_id, call_id) as leased:  # type: ignore[attr-defined]
            yield leased

    async def _ask(self, call: ToolCall, name: str) -> tuple[bool, str]:
        if self.approve is None:
            return False, "没有可用的批准通道"
        verdict = self.approve(call, self.context)  # type: ignore[operator]
        if asyncio.iscoroutine(verdict):
            verdict = await verdict
        if isinstance(verdict, tuple):
            return bool(verdict[0]), str(verdict[1])
        return bool(verdict), ""

    def _fail(self, call: ToolCall, message: str, code: str) -> ToolResultBlock:
        text = f"错误（{code}）：{message}"
        self.journal.tool_result(
            call.id, call.name, text, is_error=True, detail={"code": code}
        )
        return ToolResultBlock(call.id, text, is_error=True)

    def _synthesise(self, call: ToolCall) -> ToolResultBlock:
        """A synthetic call and error result for a call cancelled before dispatch."""
        text = "错误（取消）：这次调用在派发之前就被取消了"
        self.journal.tool_call(call.id, call.name, call.arguments)
        self.journal.tool_result(
            call.id, call.name, text, is_error=True,
            detail={"code": ABORTED_BEFORE_DISPATCH}, synthetic=True,
        )
        return ToolResultBlock(call.id, text, is_error=True)
