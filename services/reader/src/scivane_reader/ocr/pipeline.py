"""PaddleOCR-VL-1.6 wrapper.

Layout analysis (PP-DocLayoutV3) runs on CPU in-process; element recognition goes to
llama-server on the Metal GPU.
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
    """Built on first use (loads the layout model, a few seconds), then reused."""
    global _pipeline
    if _pipeline is not None:
        return _pipeline
    with _pipeline_lock:
        if _pipeline is None:
            # OCR is optional: locate it at runtime and report it missing instead of hitting an ImportError
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
                # the default queue batches the whole document and is slower
                # (6 pages: 27 s batched, 16 s without queues, 14.6 s split per page)
                use_queues=False,
            )
            logger.info("PaddleOCRVL ready")
    return _pipeline


def warmup() -> None:
    """Warm up the layout model so the first document doesn't pay for it."""
    get_pipeline()


def _parse_document(
    path: Path,
    job_id: str,
    on_page: Callable[[PageResult], None],
    should_stop: Callable[[], bool] | None = None,
    on_page_start: Callable[[int], None] | None = None,
) -> str:
    """Parse page by page with a callback per page; returns the restructured Markdown.

    Pages are shown as they arrive (with anchors for synced scrolling); export uses the
    restructured version (merged tables, fixed heading levels, joined paragraphs).
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
            # per-page splitting makes cancellation immediate
            if should_stop is not None and should_stop():
                logger.info("job %s cancelled before page %d", job_id, i)
                break

            # dense pages take over ten seconds; announce the page so the UI shows progress
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
    """Cross-page restructuring; falls back to plain concatenation so export never breaks."""
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
    """Re-run only the given pages; returns page -> Markdown.

    For the reocr tool: garbled text is fixed by re-running the page, not by editing words.
    No cross-page restructuring, which would rewrite parts the user already checked.
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
