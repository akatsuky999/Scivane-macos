"""论文专用工具：`reocr` 与 `cite`。**这一组是这个产品独有的**，通用 agent 不会有。

### 为什么 reocr 而不是「手工改乱码」

用户最初的描述是「审核扫描件、删掉乱码」。但**乱码的正解是重跑那几页**：
乱码说明识别失败了，重跑更接近根因，而且可以换识别参数再来一次。手工改字
是拿一个模型的猜测去覆盖另一个模型的猜测，改完谁也不知道对不对 ——
而正文是这个产品全部回答的依据，往里面填猜测是最不该做的事。

### cite 为什么要去查原稿而不是查正文

跨页整理（`consolidate`）会把页边界合掉，**最终的 `md/context.md` 里没有任何
页码信息**。所以 cite 不可能只靠正文回答「这在第几页」—— 它必须拿正文里的
一段文字回原稿 PDF 里搜。

代价是它依赖原稿的文本层：born-digital 的 PDF 有，扫描件没有。扫描件上
cite 会如实说「原稿没有文本层，定位不了」，而不是编一个页码 —— 一个编出来的
出处比没有出处糟得多，因为用户会去核对，然后对整个产品失去信任。
"""

from __future__ import annotations

import asyncio
import re
from pathlib import Path

from ..projects import workspace
from .definition import ToolContext, ToolDef, ToolError, ToolOutcome

__all__ = ["paper_tools", "MAX_REOCR_PAGES", "find_anchor_probe", "locate_in_pdf"]

#: 一次最多重跑几页。重跑要加载 2.8GB 模型、每页几秒到十几秒，
#: 不设上限的话模型一句「把全篇重跑一遍」就是十几分钟。
MAX_REOCR_PAGES = 20

#: 拿去 PDF 里搜的探针长度。太短会命中一堆无关位置，太长会因为 OCR 与
#: 原稿的细微差异（连字、空格）搜不到。
PROBE_CHARS = 60
_MARKUP = re.compile(r"[#*`_>\[\]()!]|<[^>]+>")


def _project(context: ToolContext) -> Path:
    if context.project_dir is None:
        raise ToolError("这一层 agent 没有项目，用不了论文工具", "NO_PROJECT")
    return Path(context.project_dir)


def find_anchor_probe(markdown: str, anchor: str) -> tuple[str, int] | None:
    """在正文里找到 anchor 所在的那一行，返回 `(可拿去搜的探针, 行号)`。

    纯函数，不碰 PDF —— 单独抽出来是为了能脱离原稿测这一半逻辑。
    """
    needle = anchor.strip().lower()
    if not needle:
        return None
    for number, line in enumerate(markdown.splitlines(), 1):
        if needle not in line.lower():
            continue
        clean = _MARKUP.sub("", line).strip()
        if len(clean) < 4:
            # 只有一个「## 3.2」这样的空标题，拿它当探针会命中目录页。
            # 往下找一行有实质内容的。
            continue
        return clean[:PROBE_CHARS], number
    return None


def locate_in_pdf(pdf: Path, probe: str) -> tuple[int, tuple[float, float, float, float]] | None:
    """在原稿里搜探针，返回 `(页码从 1 起, 矩形)`。搜不到返回 None。"""
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
        # 扫描件没有文本层。**如实说定位不了，绝不编一个页码** ——
        # 用户会去核对，编出来的出处会让整个产品失去信任。
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

    # 延迟导入：这一句会牵出 2.8GB 的模型栈，模块级导入会让单测也得起引擎
    from ..ocr import pipeline

    job_id = f"reocr-{context.project_id or 'adhoc'}"
    try:
        # 会加载 2.8GB 模型并占满 GPU 几十秒 —— 绝不能在事件循环里同步跑
        redone = await asyncio.to_thread(
            pipeline.parse_pages, pdf, job_id, pages, context.cancelled
        )
    except Exception as exc:  # noqa: BLE001
        raise ToolError(f"重新识别失败：{exc}", "REOCR_FAILED") from exc
    if not redone:
        raise ToolError("一页都没重跑出来（可能被取消，或页码超出总页数）", "REOCR_EMPTY")

    # 结果落进 workbench/，**不直接覆盖 md/context.md**：覆盖正文是会影响
    # 后续所有回答的动作，该由人看过再决定，不该是一个工具的副作用。
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
            # 会加载 2.8GB 模型并占满 GPU 几十秒，绝不能和别的工具并发
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
