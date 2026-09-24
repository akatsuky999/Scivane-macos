"""PaddleOCR-VL-1.6 封装。

版面分析（PP-DocLayoutV3）在本进程内用 CPU 跑，逐元素识别外包给
llama-server，由它用 Metal 调 M 系列 GPU —— 这是整套架构提速的关键。
"""

from __future__ import annotations

import logging
import shutil
import threading
from pathlib import Path
from typing import Callable

from .. import config, runtime
from .documents import PageResult, extract_markdown, persist_images, split_pages

logger = logging.getLogger("scivane.pipeline")

_pipeline = None
_pipeline_lock = threading.Lock()


def get_pipeline():
    """首次调用时构建 pipeline（会加载版面模型，耗时数秒），之后复用。"""
    global _pipeline
    if _pipeline is not None:
        return _pipeline
    with _pipeline_lock:
        if _pipeline is None:
            # OCR 是可选组件：在哪一档由 runtime 现找，没装就说清楚没装，而不是撞一个 ImportError
            active = runtime.resolve()
            if active is None:
                raise FileNotFoundError(runtime.unavailable_reason())
            from paddleocr import PaddleOCRVL

            logger.info("initialising PaddleOCRVL (%s)", config.PIPELINE_VERSION)
            _pipeline = PaddleOCRVL(
                pipeline_version=config.PIPELINE_VERSION,
                device=config.LAYOUT_DEVICE,
                layout_detection_model_dir=str(active.layout_dir),
                vl_rec_backend=config.VL_BACKEND,
                vl_rec_server_url=config.LLAMA_BASE_URL,
                vl_rec_max_concurrency=config.VL_MAX_CONCURRENCY,
                # 默认的队列批处理会把整份文档攒完才吐结果，实测反而更慢
                # （6 页：批处理 27s、关队列 16s、逐页切分 14.6s）
                use_queues=False,
            )
            logger.info("PaddleOCRVL ready")
    return _pipeline


def warmup() -> None:
    """提前把版面模型加载好，别让第一份文档替所有人排队。"""
    get_pipeline()


def _parse_document(
    path: Path,
    job_id: str,
    on_page: Callable[[PageResult], None],
    should_stop: Callable[[], bool] | None = None,
    on_page_start: Callable[[int], None] | None = None,
) -> str:
    """逐页解析，每完成一页回调一次；返回跨页整理后的完整 Markdown。

    显示用逐页结果（带页锚点，支持左右联动滚动），导出用整理后的版本
    （跨页表格合并、标题层级重排、段落接续）。
    """
    pipeline = get_pipeline()
    job_dir = config.JOBS_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    split_dir = job_dir / "_pages"

    collected = []
    pages: list[str] = []

    try:
        parts = split_pages(path, split_dir)

        for i, part in enumerate(parts, start=1):
            # 拆页之后取消才是真的能立刻停下，不用等整份跑完
            if should_stop is not None and should_stop():
                logger.info("job %s cancelled before page %d", job_id, i)
                break

            # 密集论文单页要跑十几秒，先告诉前端「开始第 N 页了」，
            # 否则界面在整页跑完前完全没有动静
            if on_page_start is not None:
                on_page_start(i)

            for res in pipeline.predict(str(part)):
                collected.append(res)
                text, images = extract_markdown(res)
                text = persist_images(text, images, job_dir / f"page-{i}", f"{job_id}/page-{i}")
                pages.append(text)
                on_page(PageResult(index=i, markdown=text))

        return consolidate(pipeline, collected, pages, job_dir, job_id)
    finally:
        shutil.rmtree(split_dir, ignore_errors=True)


def consolidate(pipeline, collected: list, pages: list[str], job_dir: Path, job_id: str) -> str:
    """跨页整理。失败就退回朴素拼接 —— 导出功能不该因为整理失败而不可用。"""
    if not collected:
        return ""
    try:
        merged = pipeline.restructure_pages(collected, concatenate_pages=True)
        chunks = []
        for i, res in enumerate(merged):
            text, images = extract_markdown(res)
            chunks.append(persist_images(text, images, job_dir / f"merged-{i}", f"{job_id}/merged-{i}"))
        combined = "\n\n".join(c for c in chunks if c.strip())
        if combined.strip():
            return combined
    except Exception:
        logger.warning("restructure_pages failed, falling back to plain join", exc_info=True)
    return "\n\n".join(pages)

# Paddle's shared layout predictor is not reentrant. Waiters remain cancellable.
_prediction_lock = threading.Lock()


def parse_pages(
    path: Path,
    job_id: str,
    pages: tuple[int, ...],
    should_stop: Callable[[], bool] | None = None,
) -> dict[int, str]:
    """只重跑指定的几页，返回 `页码 → Markdown`。

    存在的理由是 `reocr` 工具：**审校乱码的正解是重跑那几页，不是手工改字。**
    乱码说明那几页识别失败了，重跑更接近根因，而且可以换识别参数再来一次；
    手工改字则是拿模型的猜测去覆盖另一个模型的猜测，谁也不知道对不对。

    不做跨页整理 —— 整理是对整篇做的，只重跑三页却把整篇重排一遍，
    会把用户已经校对过的其它部分也改掉。
    """
    pipeline = get_pipeline()
    job_dir = config.JOBS_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    split_dir = job_dir / "_pages"
    wanted = set(pages)
    out: dict[int, str] = {}

    while not _prediction_lock.acquire(timeout=0.1):
        if should_stop and should_stop():
            return out
    try:
        parts = split_pages(path, split_dir)
        for i, part in enumerate(parts, start=1):
            if i not in wanted:
                continue
            if should_stop is not None and should_stop():
                break
            for res in pipeline.predict(str(part)):
                text, images = extract_markdown(res)
                out[i] = persist_images(
                    text, images, job_dir / f"reocr-{i}", f"{job_id}/reocr-{i}"
                )
        return out
    finally:
        _prediction_lock.release()
        shutil.rmtree(split_dir, ignore_errors=True)



def parse_document(path, job_id, on_page, should_stop=None, on_page_start=None):
    while not _prediction_lock.acquire(timeout=0.1):
        if should_stop and should_stop():
            return ""
    try:
        if should_stop and should_stop():
            return ""
        return _parse_document(path, job_id, on_page, should_stop, on_page_start)
    finally:
        _prediction_lock.release()
