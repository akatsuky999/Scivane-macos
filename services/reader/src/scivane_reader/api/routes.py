"""HTTP routes: validation, hand-off between threads and the event loop, SSE framing.
Recognition lives in scivane_reader.ocr and job state in scivane_reader.jobs.
"""

from __future__ import annotations

import asyncio
import contextvars
import logging
import threading
import time
from pathlib import Path
from typing import Literal

import httpx
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from .. import config, ocr, runtime
from .. import runtime_install as installer
from ..i18n import ui
from ..jobs import jobs
from ..llm import registry as llm_registry
from ..text import plain_text
from .sse import EOF_SENTINEL, HEARTBEAT_SECONDS, Event, RuntimeEvent, encode

logger = logging.getLogger("scivane.api")

router = APIRouter()


@router.get("/health")
async def health():
    """Polled by the app at startup.

    `ok` reflects only the local OCR engine (BackendManager reads it); cloud Q&A is under `llm`.
    """
    llama_ok = False
    detail = "unreachable"
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get(f"http://{config.LLAMA_HOST}:{config.LLAMA_PORT}/health")
            llama_ok = r.status_code == 200
            detail = r.text[:200]
    except Exception as exc:
        detail = str(exc)[:200]

    ocr = runtime.resolve()
    return {
        "ok": llama_ok,
        "api": "up",
        "llama": {"ok": llama_ok, "url": config.LLAMA_BASE_URL, "detail": detail},
        "pipeline_version": config.PIPELINE_VERSION,
        "layout_device": config.LAYOUT_DEVICE,
        # None when OCR is not installed (it is optional)
        "runtime_root": str(ocr.root) if ocr else None,
        # never includes credentials
        "llm": {
            "providers": [
                {
                    "id": entry["id"],
                    "protocol": entry["protocol"],
                    "configured": entry["configured"],
                }
                for entry in llm_registry.describe_all()
            ],
        },
    }


@router.get("/runtime/status")
async def runtime_status():
    """Per-tier OCR status, read fresh so an install shows up without a restart."""
    return runtime.status()


class InstallRequest(BaseModel):
    #: download: fetch online; migrate: copy a local legacy deployment
    method: Literal["download", "migrate"] = "download"


# One install at a time: two would fight over the same .partial dir and cache.
_install_lock = threading.Lock()
_install_job: dict[str, str | None] = {"id": None}

# Installer kinds -> SSE event names (the contract lives in sse.py).
_RUNTIME_KINDS = {
    "step": RuntimeEvent.STEP, "progress": RuntimeEvent.PROGRESS,
    "source": RuntimeEvent.SOURCE, "log": RuntimeEvent.LOG,
}


@router.post("/runtime/install")
async def runtime_install(req: InstallRequest):
    """Install the OCR component as a cancellable job, streaming RuntimeEvents.

    Disconnecting cancels; downloaded data stays cached for the next attempt.
    """
    if config.RUNTIME_OVERRIDE is not None:
        raise HTTPException(
            status_code=409,
            detail=ui(f"设了覆盖档（{config.RUNTIME_OVERRIDE}），装进组件目录也不会被用 —— "
                      "先清掉设置页「模型运行时」那一栏",
                      f"A custom location is set ({config.RUNTIME_OVERRIDE}), so a component install "
                      "wouldn't be used — clear “Model runtime” in Settings first"),
        )
    if not _install_lock.acquire(blocking=False):
        raise HTTPException(status_code=409, detail=ui("已经有一个安装在跑",
                                                       "An install is already running"))

    job_id = jobs.new_id()
    _install_job["id"] = job_id
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()
    started = time.monotonic()
    state = {"finished": False}

    def emit(event: str, payload: dict) -> None:
        loop.call_soon_threadsafe(queue.put_nowait, (event, payload))

    def elapsed() -> float:
        return round(time.monotonic() - started, 1)

    def worker() -> None:
        try:
            dest = installer.install(
                req.method, config.OCR_COMPONENT_DIR,
                report=lambda kind, payload: emit(_RUNTIME_KINDS[kind], payload),
                should_stop=lambda: jobs.is_cancelled(job_id),
            )
            active = runtime.resolve()
            emit(RuntimeEvent.DONE, {
                "root": str(dest), "tier": active.tier if active else None, "elapsed": elapsed(),
            })
        except installer.InstallError as exc:
            emit(RuntimeEvent.ERROR, {"code": exc.code, "message": str(exc)})
        except Exception as exc:  # surface the real reason to the app
            logger.exception("install %s failed", job_id)
            emit(RuntimeEvent.ERROR, {"code": "INTERNAL", "message": f"{type(exc).__name__}: {exc}"})
        finally:
            _install_job["id"] = None
            jobs.forget(job_id)
            _install_lock.release()
            emit(EOF_SENTINEL, {})

    # Threads don't inherit the request context (UI language); copy it explicitly.
    threading.Thread(target=contextvars.copy_context().run, args=(worker,),
                     name=f"install-{job_id}", daemon=True).start()

    async def stream():
        yield encode(RuntimeEvent.META, {"job_id": job_id, "method": req.method})
        try:
            while True:
                try:
                    event, payload = await asyncio.wait_for(queue.get(), timeout=HEARTBEAT_SECONDS)
                except asyncio.TimeoutError:
                    yield encode(RuntimeEvent.HEARTBEAT, {"elapsed": elapsed()})
                    continue
                if event == EOF_SENTINEL:
                    state["finished"] = True
                    break
                yield encode(event, payload)
        finally:
            if not state["finished"]:
                logger.info("client gone, cancelling install %s", job_id)
                jobs.cancel(job_id)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.post("/runtime/install/{job_id}/cancel")
async def runtime_install_cancel(job_id: str):
    """Cancel the running install; stale job ids are ignored."""
    if _install_job["id"] != job_id:
        return {"cancelled": False}
    jobs.cancel(job_id)
    return {"cancelled": True}


class OCRRequest(BaseModel):
    path: str


@router.post("/ocr")
async def ocr_stream(req: OCRRequest):
    src = Path(req.path).expanduser()
    if not src.is_file():
        raise HTTPException(status_code=404, detail=f"file not found: {src}")

    job_id = jobs.new_id()
    total = ocr.page_count(src)
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()

    def emit(event: str, payload: dict) -> None:
        loop.call_soon_threadsafe(queue.put_nowait, (event, payload))

    started = time.monotonic()
    state = {"page": 0, "finished": False}

    def elapsed() -> float:
        return round(time.monotonic() - started, 1)

    def worker() -> None:
        try:
            def on_page_start(index: int) -> None:
                state["page"] = index
                emit(Event.PROGRESS, {"page": index, "total": total, "elapsed": elapsed()})

            def on_page(page: ocr.PageResult) -> None:
                emit(Event.PAGE, {
                    "index": page.index,
                    "total": total,
                    "markdown": page.markdown,
                    "elapsed": elapsed(),
                })

            combined = ocr.parse_document(
                src, job_id, on_page,
                should_stop=lambda: jobs.is_cancelled(job_id),
                on_page_start=on_page_start,
            )
            emit(Event.DONE, {
                "markdown": combined,
                "text": plain_text(combined),
                "elapsed": elapsed(),
                "cancelled": jobs.is_cancelled(job_id),
            })
        except Exception as exc:  # surface the real reason to the app
            logger.exception("job %s failed", job_id)
            emit(Event.ERROR, {"message": f"{type(exc).__name__}: {exc}"})
        finally:
            emit(EOF_SENTINEL, {})
            if state.get("disconnected"):
                jobs.forget(job_id)

    threading.Thread(target=contextvars.copy_context().run, args=(worker,),
                     name=f"ocr-{job_id}", daemon=True).start()

    async def stream():
        yield encode(Event.META, {"job_id": job_id, "pages": total, "filename": src.name})
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
            if state["finished"]:
                jobs.forget(job_id)
            else:
                # The worker thread outlives a disconnected client and would keep llama-server busy;
                # mark it cancelled so it stops at the next page.
                logger.info("client gone, cancelling job %s", job_id)
                state["disconnected"] = True
                jobs.cancel(job_id)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.post("/cancel/{job_id}")
async def cancel(job_id: str):
    jobs.cancel(job_id)
    return {"cancelled": job_id}


@router.get("/assets/{job_id}/{asset_path:path}")
async def asset(job_id: str, asset_path: str):
    target = jobs.asset_path(job_id, asset_path)
    if target is None:
        raise HTTPException(status_code=404, detail="asset not found")
    return FileResponse(target)


@router.delete("/jobs/{job_id}")
async def drop_job(job_id: str):
    return {"removed": job_id, "existed": jobs.drop(job_id)}
