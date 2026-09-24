"""纸面上的事：数页、拆页、把抠出的插图落盘。

不碰模型，纯文件操作，可以单独测。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger("scivane.documents")

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp", ".gif"}


@dataclass
class PageResult:
    """一页的识别结果。index 从 1 开始，和界面上显示的页码一致。"""

    index: int
    markdown: str
    images: dict = field(default_factory=dict)


def is_image(path: Path) -> bool:
    return path.suffix.lower() in IMAGE_SUFFIXES


def page_count(path: Path) -> int:
    """先拿到总页数，进度条才能是确定性的而不是转圈。"""
    if is_image(path):
        return 1
    try:
        import pymupdf

        with pymupdf.open(path) as doc:
            return doc.page_count
    except Exception:  # 非 PDF 或读取失败，交给下游处理
        return 0


def split_pages(path: Path, work_dir: Path) -> list[Path]:
    """把 PDF 拆成一页一个文件。

    直接把整份 PDF 交给 predict() 的话，它会攒完所有页才一次性吐结果 ——
    进度条没法动，用户也不知道要等多久。拆开逐页送反而更快，实测 6 页
    从 27 秒降到 14.6 秒，而且第一页 2.8 秒就能出来。
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
    """从 paddleocr 的结果对象里取出 markdown 和抠图。

    不同版本返回的形状不一样（dict 或字符串），统一在这里吸收。
    """
    md = res.markdown
    if isinstance(md, dict):
        return md.get("markdown_texts", "") or "", md.get("markdown_images", {}) or {}
    return str(md or ""), {}


def persist_images(markdown: str, images: dict, job_dir: Path, job_id: str) -> str:
    """把抠出的插图落盘，并把 Markdown 里的相对路径改写成 /assets URL。"""
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
