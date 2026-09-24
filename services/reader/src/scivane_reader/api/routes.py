"""HTTP 路由。

只做编排：参数校验、线程/事件循环之间的搬运、SSE 成帧。
识别逻辑在 scivane_reader.ocr，任务状态在 scivane_reader.jobs。
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


# --------------------------------------------------------------------------
# 健康检查
# --------------------------------------------------------------------------
@router.get("/health")
async def health():
    """App 启动时轮询这里，两层都就绪才解锁 UI。

    `ok` 仍然只反映**本地 OCR 引擎**是否就绪 —— App 侧的 BackendManager
    读的就是这个字段，语义不能动。云端问答的状态单独放在 `llm` 段里：
    两条链路彼此独立，读论文只做问答时不该被 2.8GB 的 OCR 模型拖住。
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
        # 本地 OCR 在哪一档；没装时是 None（它是可选组件，完整状态见 /runtime/status）
        "runtime_root": str(ocr.root) if ocr else None,
        # 已配置的 provider 概览。不含任何凭据原文。
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
    """本地 OCR 组件的分项状态：在用哪一档、每一档缺什么、能不能从旧部署迁。

    OCR 是可选组件，界面据此决定是「开始识别」还是「先装」。
    每次现查文件系统 —— 装完不用重启后端就看得见。
    """
    return runtime.status()


class InstallRequest(BaseModel):
    #: download：从网上装（上游优先、失败或太慢换镜像）；migrate：从旧部署本机迁移
    method: Literal["download", "migrate"] = "download"


# 同一时刻只许一个安装在跑：两个安装抢同一个 .partial 与下载缓存，谁也装不成
_install_lock = threading.Lock()
_install_job: dict[str, str | None] = {"id": None}

# 安装器报的是种类，事件名归 sse.py 管（跨语言契约），映射只在这里一处
_RUNTIME_KINDS = {
    "step": RuntimeEvent.STEP, "progress": RuntimeEvent.PROGRESS,
    "source": RuntimeEvent.SOURCE, "log": RuntimeEvent.LOG,
}


@router.post("/runtime/install")
async def runtime_install(req: InstallRequest):
    """装本地 OCR 组件。走 `jobs` 登记（能取消），进度走 `RuntimeEvent` 流。

    客户端断开即取消 —— 已下载的部分留在缓存里，下次从断点接着下，不必 2 GB 从头来。
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
        except Exception as exc:  # 让 App 能显示出真实原因，而不是无声失败
            logger.exception("install %s failed", job_id)
            emit(RuntimeEvent.ERROR, {"code": "INTERNAL", "message": f"{type(exc).__name__}: {exc}"})
        finally:
            _install_job["id"] = None
            jobs.forget(job_id)
            _install_lock.release()
            emit(EOF_SENTINEL, {})

    # 线程不会自己带上这个请求的上下文（界面语言在里面，`i18n.py`）—— 显式复制一份
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
    """界面上的「取消」。只认正在跑的那一个 —— 取消一个早就结束的号没有意义。"""
    if _install_job["id"] != job_id:
        return {"cancelled": False}
    jobs.cancel(job_id)
    return {"cancelled": True}


# --------------------------------------------------------------------------
# 识别（SSE 流式）
# --------------------------------------------------------------------------
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
        except Exception as exc:  # 让 App 能显示出真实原因，而不是无声失败
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
                # 正常收尾，别把已完成的任务留在取消集合里
                jobs.forget(job_id)
            else:
                # 客户端断开（关窗、超时、Ctrl-C）后 worker 线程不会自己停，
                # 会继续占着 llama-server 空跑。标记取消，让它在页边界退出。
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


# --------------------------------------------------------------------------
# 抠图静态资源
# --------------------------------------------------------------------------
@router.get("/assets/{job_id}/{asset_path:path}")
async def asset(job_id: str, asset_path: str):
    target = jobs.asset_path(job_id, asset_path)
    if target is None:
        raise HTTPException(status_code=404, detail="asset not found")
    return FileResponse(target)


@router.delete("/jobs/{job_id}")
async def drop_job(job_id: str):
    return {"removed": job_id, "existed": jobs.drop(job_id)}
