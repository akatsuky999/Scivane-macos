"""Transcribing a document with a vision model: the cloud alternative to local OCR.

The stream speaks the OCR stream's language (sse.Event: meta, progress, page, heartbeat, done,
error), so the app shows and stores a transcription exactly like an OCR run. Additions: page and
done carry usage, done lists the pages that failed, and error carries a stable code. Figure
crops land in the job's directory and are referenced as /assets/<job>/..., like OCR crops, so
project import picks them up unchanged.
"""

from __future__ import annotations

import asyncio
import logging
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .. import config
from ..i18n import ui
from ..jobs import jobs
from ..llm import LlmError
from ..llm.errors import UNKNOWN
from ..llm.registry import registry as llm_registry
from ..text import plain_text
from ..transcribe import PageDone, TranscriptionError, page_count, transcribe
from .sse import EOF_SENTINEL, HEARTBEAT_SECONDS, Event, encode

logger = logging.getLogger("scivane.api.transcribe")

router = APIRouter(tags=["transcribe"])


class TranscribeIn(BaseModel):
    path: str
    #: the model card to transcribe with; it must read images
    provider: str = Field(min_length=1)


@router.post("/transcribe")
async def transcribe_stream(body: TranscribeIn):
    source = Path(body.path).expanduser()
    if not source.is_file():
        raise HTTPException(status_code=404, detail=ui(f"找不到文件：{source}", f"File not found: {source}"))
    try:
        card = llm_registry.get(body.provider)
    except LlmError as exc:
        raise HTTPException(status_code=404, detail=exc.failure.message) from exc
    try:
        total = await asyncio.to_thread(page_count, source)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=400,
            detail=ui(f"读不了这个文件：{exc}", f"This file can't be read: {exc}")) from exc

    job_id = jobs.new_id()
    queue: asyncio.Queue = asyncio.Queue()
    started = time.monotonic()
    state = {"page": 0, "finished": False}

    def elapsed() -> float:
        return round(time.monotonic() - started, 1)

    def emit(event: str, payload: dict) -> None:
        queue.put_nowait((event, payload))

    def store_figure(page: int, number: int, data: bytes) -> str:
        target = jobs.dir_for(job_id) / f"page-{page}" / f"fig-{number}.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return f"/assets/{job_id}/page-{page}/fig-{number}.png"

    def started_page(index: int, pages: int) -> None:
        state["page"] = index
        emit(Event.PROGRESS, {"page": index, "total": pages, "elapsed": elapsed()})

    def finished_page(done: PageDone) -> None:
        emit(Event.PAGE, {
            "index": done.index, "total": total, "markdown": done.markdown,
            "elapsed": elapsed(), "failed": done.failed, "usage": done.usage.as_dict(),
        })

    async def work() -> None:
        try:
            # One small request settles whether the card reads images, before a page is spent.
            check = await llm_registry.vision(body.provider)
            if check.supported is not True:
                emit(Event.ERROR, {"code": check.code or UNKNOWN, "message": check.message})
                return
            result = await transcribe(
                source,
                stream=lambda request: llm_registry.stream(body.provider, request),
                model=card.model,
                store_figure=store_figure,
                long_edge=config.TRANSCRIBE_LONG_EDGE,
                concurrency=config.TRANSCRIBE_CONCURRENCY,
                on_start=started_page,
                on_page=finished_page,
                cancelled=lambda: jobs.is_cancelled(job_id),
            )
            emit(Event.DONE, {
                "markdown": result.markdown,
                "text": plain_text(result.markdown),
                "elapsed": elapsed(),
                "cancelled": result.cancelled,
                "failed_pages": result.failed,
                "usage": result.usage.as_dict(),
                "model": card.model,
            })
        except TranscriptionError as exc:
            # provider id and code only: messages can quote the request
            logger.warning("转写失败 job=%s provider=%s code=%s", job_id, body.provider, exc.code)
            emit(Event.ERROR, {"code": exc.code, "message": str(exc)})
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            logger.exception("转写出错 job=%s", job_id)
            emit(Event.ERROR, {"code": "INTERNAL", "message": f"{type(exc).__name__}: {exc}"})
        finally:
            emit(EOF_SENTINEL, {})

    # create_task copies the request context, so human-facing text keeps the UI language
    task = asyncio.create_task(work())

    async def stream():
        yield encode(Event.META, {
            "job_id": job_id, "pages": total, "filename": source.name,
            "engine": "model", "provider": body.provider, "model": card.model,
        })
        try:
            while True:
                try:
                    event, payload = await asyncio.wait_for(queue.get(), timeout=HEARTBEAT_SECONDS)
                except asyncio.TimeoutError:
                    yield encode(Event.HEARTBEAT, {
                        "page": state["page"], "total": total, "elapsed": elapsed(),
                    })
                    continue
                if event == EOF_SENTINEL:
                    state["finished"] = True
                    break
                yield encode(event, payload)
        finally:
            if not state["finished"]:
                # the client left: stop the pages in flight instead of paying for them
                logger.info("client gone, cancelling transcription %s", job_id)
                jobs.cancel(job_id)
                task.cancel()
            jobs.forget(job_id)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
