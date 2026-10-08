"""Paper-specific tools: reocr and cite.

Garbled text is fixed by re-running OCR on the page, not by editing words: editing replaces one
model's guess with another's, in the text every answer is based on.

cite searches the source PDF because restructuring removes page boundaries from md/context.md.
That needs a text layer; on scanned PDFs it says it can't locate the passage rather than
inventing a page number.
"""

from __future__ import annotations

import asyncio
import re
from pathlib import Path

from ..projects import workspace
from .definition import ToolContext, ToolDef, ToolError, ToolOutcome

__all__ = ["paper_tools", "MAX_REOCR_PAGES", "find_anchor_probe", "locate_in_pdf"]

#: re-running loads the 2.8 GB model and takes seconds per page; "redo the whole paper" would take
#: a quarter of an hour
MAX_REOCR_PAGES = 20

#: probe length searched in the PDF: too short matches unrelated places, too long misses on
#: OCR differences (ligatures, spaces)
PROBE_CHARS = 60
_MARKUP = re.compile(r"[#*`_>\[\]()!]|<[^>]+>")


def _project(context: ToolContext) -> Path:
    if context.project_dir is None:
        raise ToolError("这一层 agent 没有项目，用不了论文工具", "NO_PROJECT")
    return Path(context.project_dir)


def find_anchor_probe(markdown: str, anchor: str) -> tuple[str, int] | None:
    """Find the line holding `anchor` in the text; returns (probe, line number). Pure, no PDF needed."""
    needle = anchor.strip().lower()
    if not needle:
        return None
    for number, line in enumerate(markdown.splitlines(), 1):
        if needle not in line.lower():
            continue
        clean = _MARKUP.sub("", line).strip()
        if len(clean) < 4:
            # a bare heading such as "## 3.2" would match the table of contents; use the next line with content
            continue
        return clean[:PROBE_CHARS], number
    return None


def locate_in_pdf(pdf: Path, probe: str) -> tuple[int, tuple[float, float, float, float]] | None:
    """Search the probe in the source; returns (1-based page, rect) or None."""
    import pymupdf

    with pymupdf.open(pdf) as doc:
        for index in range(doc.page_count):
            page = doc.load_page(index)
            for candidate in (probe, probe[: PROBE_CHARS // 2], probe[:20]):
                if len(candidate) < 6:
                    break
                rects = page.search_for(candidate)
                if rects:
                    r = rects[0]
                    return index + 1, (r.x0, r.y0, r.x1, r.y1)
    return None


def _has_text_layer(pdf: Path) -> bool:
    import pymupdf

    with pymupdf.open(pdf) as doc:
        for index in range(min(doc.page_count, 5)):
            if doc.load_page(index).get_text("text").strip():
                return True
    return False


async def _cite(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    anchor = arguments.get("anchor")
    if not isinstance(anchor, str) or not anchor.strip():
        raise ToolError("anchor 必须是非空字符串，如 '3.2' 或 '图 3' 或一句原文", "INVALID_ARGS")
    root = _project(context)

    context_md = root / "md" / "context.md"
    if not context_md.is_file():
        raise ToolError("这个项目还没有正文，无从定位", "NO_CONTEXT")
    found = find_anchor_probe(context_md.read_text(encoding="utf-8", errors="replace"), anchor)
    if found is None:
        raise ToolError(f"正文里找不到「{anchor}」", "NOT_FOUND")
    probe, line_number = found

    pdf = root / "pdf" / "source.pdf"
    if not pdf.is_file():
        return ToolOutcome(
            f"「{anchor}」在正文第 {line_number} 行：{probe}\n"
            "（这个项目没有原稿副本，给不出页码）",
            detail={"line": line_number},
        )
    if not await asyncio.to_thread(_has_text_layer, pdf):
        # Scanned PDFs have no text layer. Say so; never invent a page number.
        return ToolOutcome(
            f"「{anchor}」在正文第 {line_number} 行：{probe}\n"
            "原稿是扫描件（没有文本层），定位不到页码 —— "
            "要精确定位的话，对那几页跑 reocr 之后再试。",
            detail={"line": line_number, "text_layer": False},
        )

    hit = await asyncio.to_thread(locate_in_pdf, pdf, probe)
    if hit is None:
        return ToolOutcome(
            f"「{anchor}」在正文第 {line_number} 行：{probe}\n"
            "在原稿里没搜到对应位置（OCR 与原稿的用字可能有出入）",
            detail={"line": line_number},
        )
    page, (x0, y0, x1, y1) = hit
    return ToolOutcome(
        f"「{anchor}」在原稿第 {page} 页，位置 ({x0:.0f}, {y0:.0f})–({x1:.0f}, {y1:.0f})；"
        f"正文第 {line_number} 行：{probe}",
        detail={"page": page, "rect": [x0, y0, x1, y1], "line": line_number},
    )


def _parse_pages(raw: object) -> tuple[int, ...]:
    if not isinstance(raw, list) or not raw:
        raise ToolError("pages 必须是非空的页码数组，如 [3, 4]", "INVALID_ARGS")
    pages: list[int] = []
    for item in raw:
        if isinstance(item, bool) or not isinstance(item, int) or item < 1:
            raise ToolError(f"页码要是从 1 起的整数，拿到 {item!r}", "INVALID_ARGS")
        pages.append(item)
    unique = tuple(sorted(set(pages)))
    if len(unique) > MAX_REOCR_PAGES:
        raise ToolError(
            f"一次最多重跑 {MAX_REOCR_PAGES} 页（要了 {len(unique)} 页）—— "
            "识别要加载 2.8GB 模型，每页几秒到十几秒",
            "TOO_MANY_PAGES",
        )
    return unique


async def _reocr(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    pages = _parse_pages(arguments.get("pages"))
    root = _project(context)
    pdf = root / "pdf" / "source.pdf"
    if not pdf.is_file():
        raise ToolError("这个项目没有原稿副本，没法重新识别", "NO_SOURCE")

    # imported lazily: it pulls in the 2.8 GB model stack
    from ..ocr import pipeline

    job_id = f"reocr-{context.project_id or 'adhoc'}"
    try:
        # loads the model and keeps the GPU busy for tens of seconds; never on the event loop
        redone = await asyncio.to_thread(
            pipeline.parse_pages, pdf, job_id, pages, context.cancelled
        )
    except Exception as exc:  # noqa: BLE001
        raise ToolError(f"重新识别失败：{exc}", "REOCR_FAILED") from exc
    if not redone:
        raise ToolError("一页都没重跑出来（可能被取消，或页码超出总页数）", "REOCR_EMPTY")

    # Results go to workbench/, never straight into md/context.md: replacing the text affects every
    # later answer and should be a person's decision.
    out_dir = workspace.resolve(root, "workbench/reocr", write=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for index, markdown in sorted(redone.items()):
        target = out_dir / f"page-{index:04d}.md"
        target.write_text(markdown, encoding="utf-8")
        written.append(str(target.relative_to(root)))

    preview = next(iter(sorted(redone.items())))[1][:400]
    return ToolOutcome(
        f"重跑了第 {'、'.join(str(p) for p in sorted(redone))} 页，结果写进：\n"
        + "\n".join(written)
        + f"\n\n第一页开头：\n{preview}\n\n"
        "**没有覆盖 md/context.md** —— 看过之后要合并的话用 edit 或 write。",
        detail={"pages": sorted(redone), "files": written},
    )


def paper_tools() -> tuple[ToolDef, ...]:
    return (
        ToolDef(
            name="reocr",
            description=(
                "对原稿指定的几页**重新识别**。**这是最后手段，不是修错别字的工具。**\n\n"
                "只在**整段乱码**、公式结构整个塌了、表格错位到认不出原形时才用它 —— "
                "那种情况你推不出正确形式，重跑才比瞎猜接近根因。\n\n"
                "**认得出正确形式的错误一律用 `edit` 改**（字符认错、断词、"
                "希腊字母被认成拉丁字母等）。代价差三个数量级：`edit` 是毫秒级、"
                "可逆、只动你指定的那一处；这个工具要加载 2.8GB 引擎按页重跑，"
                "几十秒起步。\n\n"
                "结果写进 workbench/reocr/，不直接覆盖正文。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "pages": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "description": f"要重跑的页码（从 1 起），一次最多 {MAX_REOCR_PAGES} 页",
                    }
                },
                "required": ["pages"],
            },
            run=_reocr,
            # loads the model and occupies the GPU; never concurrent with other tools
            concurrency_safe=False,
        ),
        ToolDef(
            name="cite",
            description=(
                "把正文里的一个位置（章节号、图号、公式号，或一句原文）"
                "解析回原稿的页码与坐标，供用户核对。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "anchor": {
                        "type": "string",
                        "description": "章节号如 3.2、图号如「图 3」、或正文里的一句话",
                    }
                },
                "required": ["anchor"],
            },
            run=_cite,
            read_only=True,
            concurrency_safe=True,
        ),
    )
