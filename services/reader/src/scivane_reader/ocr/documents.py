"""Pages and files: counting, splitting, saving image crops. No model, so it is testable on its own."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger("scivane.documents")

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp", ".gif"}


@dataclass
class PageResult:
    """One page's result; index is 1-based, matching the UI."""

    index: int
    markdown: str
    images: dict = field(default_factory=dict)


def is_image(path: Path) -> bool:
    return path.suffix.lower() in IMAGE_SUFFIXES


def page_count(path: Path) -> int:
    """Page count up front so the progress bar is determinate."""
    if is_image(path):
        return 1
    try:
        import pymupdf

        with pymupdf.open(path) as doc:
            return doc.page_count
    except Exception:  # not a PDF, or unreadable: leave it to the pipeline
        return 0


def split_pages(path: Path, work_dir: Path) -> list[Path]:
    """Split a PDF into one file per page.

    predict() on a whole PDF only returns at the end; per page is also faster
    (6 pages: 27 s -> 14.6 s, first page after 2.8 s).
    """
    if is_image(path):
        return [path]

    import pymupdf

    work_dir.mkdir(parents=True, exist_ok=True)
    parts: list[Path] = []
    with pymupdf.open(path) as src:
        for i in range(src.page_count):
            target = work_dir / f"page_{i + 1:04d}.pdf"
            with pymupdf.open() as one:
                one.insert_pdf(src, from_page=i, to_page=i)
                one.save(target)
            parts.append(target)
    return parts


def extract_markdown(res) -> tuple[str, dict]:
    """Markdown and crops from a paddleocr result; absorbs version differences (dict or string)."""
    md = res.markdown
    if isinstance(md, dict):
        return md.get("markdown_texts", "") or "", md.get("markdown_images", {}) or {}
    return str(md or ""), {}


def persist_images(markdown: str, images: dict, job_dir: Path, job_id: str) -> str:
    """Save image crops and rewrite their Markdown paths to /assets URLs."""
    if not images:
        return markdown

    for rel_path, image in images.items():
        target = job_dir / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            image.save(target)
        except Exception:
            logger.warning("failed to save image %s", rel_path, exc_info=True)
            continue
        markdown = markdown.replace(rel_path, f"/assets/{job_id}/{rel_path}")
    return markdown
