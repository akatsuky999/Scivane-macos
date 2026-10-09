"""Transcribe a document page by page with a vision model.

    plan each page (image, text layer, figures)       pages.py, in a thread
      -> one request per page, a few pages in flight    prompt.py
      -> check the answer: cut off, too short, failed   retried here, beyond the transport retries
      -> place figures, split off footnotes             stitch.parse
    then join the pages into one paper                  stitch.join

The model call is passed in, so this module knows neither providers nor projects, and tests drive
it with scripted streams. Failures that no page can survive (no key, no quota, no vision) stop the
whole run; a page that still fails after its retries becomes a visible placeholder, never a gap.
"""

from __future__ import annotations

import asyncio
import logging
import re
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field, replace
from pathlib import Path

from ..llm.errors import (
    AUTH,
    CONTEXT_WINDOW_EXCEEDED,
    INVALID_ARGS,
    INVALID_CREDENTIAL,
    MISSING_CREDENTIAL,
    NO_ADAPTER,
    NO_VISION,
    QUOTA,
    LlmError,
    LlmFailure,
)
from ..llm.types import CallRequest, Finish, Message, StreamChunk, TextDelta, Usage, UsageUpdate
from . import pages as page_tools
from .prompt import SYSTEM_PROMPT, page_message, retry_note
from .stitch import PageText, join, page_markdown, parse

__all__ = ["FATAL", "Transcript", "TranscriptionError", "PageDone", "transcribe"]

logger = logging.getLogger("scivane.transcribe")

#: No page can succeed after one of these; stop instead of failing every page in turn.
FATAL = frozenset({
    AUTH, QUOTA, MISSING_CREDENTIAL, INVALID_CREDENTIAL, NO_ADAPTER, NO_VISION, INVALID_ARGS,
    CONTEXT_WINDOW_EXCEEDED,
})

#: Output ceiling for the second attempt at a page that was cut off. 16k fits the densest page
#: and is within what current vision models accept.
LONG_PAGE_TOKENS = 16_000
#: A page whose text layer has this many characters but whose answer has under SHORT_RATIO of
#: them was summarised or refused, not transcribed.
SHORT_LAYER = 600
SHORT_RATIO = 0.25

Stream = Callable[[CallRequest], AsyncIterator[StreamChunk]]
#: (page, figure number, PNG bytes) -> the image's Markdown URL
FigureStore = Callable[[int, int, bytes], str]


class TranscriptionError(Exception):
    """The whole run stopped; `code` is a stable llm error code."""

    def __init__(self, failure: LlmFailure) -> None:
        super().__init__(failure.message)
        self.code = failure.code
        self.failure = failure


@dataclass(frozen=True)
class PageDone:
    index: int
    #: this page as displayed while the rest is still running
    markdown: str
    #: None when transcribed; otherwise the failure code
    failed: str | None
    #: all usage so far, this page included
    usage: Usage


@dataclass
class Transcript:
    markdown: str
    #: index -> page as displayed
    pages: dict[int, str]
    failed: list[int]
    usage: Usage
    cancelled: bool = False


@dataclass
class _Attempt:
    text: str = ""
    kind: str = "stop"
    failure: LlmFailure | None = None
    usage: Usage = field(default_factory=Usage)


async def transcribe(
    source: Path,
    *,
    stream: Stream,
    model: str,
    store_figure: FigureStore,
    long_edge: int,
    concurrency: int,
    on_start: Callable[[int, int], None] | None = None,
    on_page: Callable[[PageDone], None] | None = None,
    cancelled: Callable[[], bool] = lambda: False,
) -> Transcript:
    """Transcribe `source` (a PDF or an image). Raises TranscriptionError on a fatal failure."""
    total = await asyncio.to_thread(page_tools.count, source)
    results: dict[int, PageText] = {}
    failures: dict[int, str] = {}
    usage = Usage()
    gate = asyncio.Semaphore(max(1, concurrency))

    def finished(index: int, text: PageText, failed: str | None, used: Usage) -> None:
        nonlocal usage
        usage = usage.merged(used)
        results[index] = text
        if failed is None:
            failures.pop(index, None)
        else:
            failures[index] = failed
        if on_page is not None:
            on_page(PageDone(index, page_markdown(text), failed, usage))

    async def run(index: int) -> None:
        async with gate:
            if cancelled():
                return
            if on_start is not None:
                on_start(index, total)
            text, failed, used = await _page(
                source, index, total, stream=stream, model=model, store_figure=store_figure,
                long_edge=long_edge)
            finished(index, text, failed, used)

    async def watch(tasks: list[asyncio.Task]) -> None:
        # a page can stream for a minute; a cancel must stop it, not wait for it
        while not all(task.done() for task in tasks):
            if cancelled():
                for task in tasks:
                    task.cancel()
                return
            await asyncio.sleep(0.1)

    async def round_of(indices: list[int]) -> None:
        """Run pages until all are done; the first fatal error stops the others at once."""
        tasks = [asyncio.create_task(run(index)) for index in indices]
        watcher = asyncio.create_task(watch(tasks))
        try:
            pending = set(tasks)
            while pending:
                done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_EXCEPTION)
                for task in done:
                    if not task.cancelled() and task.exception() is not None:
                        raise task.exception()  # type: ignore[misc]
        finally:
            watcher.cancel()
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, watcher, return_exceptions=True)

    await round_of(list(range(1, total + 1)))
    # One more pass for pages that failed, one at a time: rate limits come in bursts.
    if failures and not cancelled():
        retry = sorted(failures)
        logger.info("重试没转出来的页：%s", retry)
        gate = asyncio.Semaphore(1)
        await round_of(retry)

    ordered = [results[index] for index in sorted(results)]
    return Transcript(
        markdown=join(ordered),
        pages={index: page_markdown(results[index]) for index in sorted(results)},
        failed=sorted(failures),
        usage=usage,
        cancelled=cancelled(),
    )


async def _page(
    source: Path, index: int, total: int, *, stream: Stream, model: str,
    store_figure: FigureStore, long_edge: int,
) -> tuple[PageText, str | None, Usage]:
    plan = await asyncio.to_thread(page_tools.plan, source, index, total, long_edge=long_edge)
    figures = {
        figure.number: f"![]({await asyncio.to_thread(store_figure, index, figure.number, figure.image)})"
        for figure in plan.figures
    }
    message = page_message(plan)
    request = CallRequest(model=model, messages=(message,), system=SYSTEM_PROMPT)

    first = await _ask(stream, request)
    used = first.usage
    if first.failure is not None:
        if first.failure.code in FATAL:
            raise TranscriptionError(first.failure)
        return _placeholder(index, first.failure.code), first.failure.code, used

    best = first
    if first.kind == "length":
        second = await _ask(stream, replace(
            request, messages=(_with_note(message, "length"),), max_tokens=LONG_PAGE_TOKENS))
        used = used.merged(second.usage)
        if second.failure is None:
            best = second
        elif second.failure.code in FATAL and second.failure.code != INVALID_ARGS:
            raise TranscriptionError(second.failure)
        # otherwise keep the first answer: some providers reject an explicit output ceiling
    elif _short(first.text, plan.text):
        second = await _ask(stream, replace(request, messages=(_with_note(message, "short"),)))
        used = used.merged(second.usage)
        if second.failure is None and _visible_length(second.text) > _visible_length(first.text):
            best = second

    page = parse(best.text, index, figures)
    if best.kind == "length":
        # still cut off: keep what there is and say so where the text stops
        page = PageText(index, page.body + f"\n\n<!-- page {index}: cut off -->", page.footnotes)
    return page, None, used


async def _ask(stream: Stream, request: CallRequest) -> _Attempt:
    attempt = _Attempt()
    parts: list[str] = []
    try:
        async for chunk in stream(request):
            if isinstance(chunk, TextDelta):
                parts.append(chunk.text)
            elif isinstance(chunk, UsageUpdate):
                attempt.usage = chunk.usage
            elif isinstance(chunk, Finish):
                attempt.kind = chunk.kind
                if chunk.usage is not None:
                    attempt.usage = chunk.usage
                if chunk.failure is not None:
                    attempt.failure = chunk.failure
    except LlmError as exc:
        attempt.failure = exc.failure
    attempt.text = "".join(parts)
    return attempt


def _with_note(message: Message, reason: str) -> Message:
    return Message(message.role, (*message.content, retry_note(reason)))


def _placeholder(index: int, code: str) -> PageText:
    return PageText(index, f"<!-- page {index}: not transcribed ({code}) -->")


def _visible_length(text: str) -> int:
    return len(re.sub(r"\s+", "", text))


def _short(answer: str, layer: str) -> bool:
    expected = _visible_length(layer)
    return expected >= SHORT_LAYER and _visible_length(answer) < SHORT_RATIO * expected
