"""annotations: the user's highlights and underlines on the source PDF, as the model sees them.

The marks live in the control plane, which the agent can't open, so this reads them on the host and
returns a view instead of the file: no geometry or ids, pages counted from 1, reading order, and each
mark located in md/context.md so it ties to the paper text already in context. Read-only.
"""

from __future__ import annotations

import asyncio
import logging
import re
import sys
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..projects import annotations as book
from ..projects.anchoring import MAX_HITS, Anchor, PaperIndex, surroundings
from ..projects.workspace import MD_DIR, PDF_DIR
from .definition import ToolContext, ToolDef, ToolError, ToolOutcome

__all__ = ["annotation_tools", "EXCERPT_CHARS"]

logger = logging.getLogger("scivane.tools.annotations")

#: Longer passages are cut in the listing. A located mark loses nothing: the whole passage is in
#: the paper text the model already has, at the lines given.
EXCERPT_CHARS = 600
ORDERS = ("reading", "recent")

_HYPHEN_BREAK = re.compile(r"-[ \t]*\n\s*")

_BOOK_ERRORS = {
    "CORRUPT_ANNOTATIONS": "标注文件损坏，读不出来（文件原样留着，没有改动）",
    "UNSUPPORTED_ANNOTATIONS": "标注文件是更新版本的应用写的，这个版本认不出它的格式",
}


@dataclass
class _Mark:
    """One stored mark, read defensively: the file may come from a newer app."""

    color: str
    kind: str
    #: from 0, as stored
    pages: tuple[int, ...]
    text: str
    #: highest point on the first page; PDF page space grows upwards
    top: float
    changed: str
    ident: str
    anchor: Anchor | None = None

    @classmethod
    def read(cls, record: dict[str, Any]) -> "_Mark":
        spans = [span for span in _list(record.get("spans")) if isinstance(span, dict)]
        pages = sorted({span["page"] for span in spans if _is_int(span.get("page"))})
        top = 0.0
        if pages:
            for span in spans:
                if span.get("page") == pages[0]:
                    tops = [rect[1] + rect[3] for rect in _list(span.get("rects"))
                            if isinstance(rect, list) and len(rect) == 4
                            and all(isinstance(v, (int, float)) for v in rect)]
                    top = max(tops, default=0.0)
        return cls(
            color=_text(record.get("color")),
            kind=_text(record.get("kind")),
            pages=tuple(pages),
            text=_text(record.get("text")),
            top=top,
            changed=_text(record.get("updated_at")) or _text(record.get("created_at")),
            ident=_text(record.get("id")),
        )

    @property
    def name(self) -> str:
        return book.COLOR_NAMES.get(self.color, self.color) + book.KIND_NAMES.get(self.kind, self.kind)


@dataclass(frozen=True)
class _Query:
    colors: tuple[str, ...] | None
    kind: str | None
    #: from 1, as the model gives them
    pages: frozenset[int] | None
    order: str
    limit: int | None

    @classmethod
    def parse(cls, arguments: dict[str, object]) -> "_Query":
        colors = arguments.get("colors")
        if colors is not None:
            if not isinstance(colors, list) or not all(isinstance(c, str) for c in colors):
                raise ToolError('colors 要是颜色的数组，如 ["yellow"]', "INVALID_ARGS")
            unknown = [c for c in colors if c not in book.COLORS]
            if unknown:
                raise ToolError(f"不认识的颜色：{'、'.join(unknown)}。可选：{'、'.join(book.COLORS)}",
                                "INVALID_ARGS")
        kind = arguments.get("kind")
        if kind is not None and kind not in book.KINDS:
            raise ToolError(f"kind 只能是 {' 或 '.join(book.KINDS)}", "INVALID_ARGS")
        pages = arguments.get("pages")
        if pages is not None and (not isinstance(pages, list)
                                  or not all(_is_int(p) and p >= 1 for p in pages)):
            raise ToolError("pages 要是从 1 起的页码数组，如 [3, 4]", "INVALID_ARGS")
        order = arguments.get("order") or "reading"
        if order not in ORDERS:
            raise ToolError(f"order 只能是 {' 或 '.join(ORDERS)}", "INVALID_ARGS")
        limit = arguments.get("limit")
        if limit is not None and not (_is_int(limit) and limit >= 1):
            raise ToolError("limit 要是正整数", "INVALID_ARGS")
        return cls(
            # an empty filter means no filter
            colors=tuple(c for c in book.COLORS if c in colors) if colors else None,
            kind=kind,
            pages=frozenset(pages) if pages else None,
            order=order,
            limit=limit,
        )

    @property
    def filtered(self) -> bool:
        return self.colors is not None or self.kind is not None or self.pages is not None

    def accepts(self, mark: _Mark) -> bool:
        return ((self.colors is None or mark.color in self.colors)
                and (self.kind is None or mark.kind == self.kind)
                and (self.pages is None or any(page + 1 in self.pages for page in mark.pages)))

    def describe(self) -> str:
        parts = []
        if self.colors:
            parts.append("、".join(book.COLOR_NAMES[c] for c in self.colors))
        if self.kind:
            parts.append(book.KIND_NAMES[self.kind])
        if self.pages:
            parts.append(f"第 {'、'.join(str(p) for p in sorted(self.pages))} 页")
        return " · ".join(parts)


class _SourcePages:
    """Text of the source PDF's pages, opened on first use: only marks whose text repeats in the
    paper need it, to tell which repeat they are."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._document: Any = None
        self._failed = False
        self._texts: dict[int, str] = {}

    def __enter__(self) -> "_SourcePages":
        return self

    def __exit__(self, *_: object) -> None:
        if self._document is not None:
            self._document.close()

    def text(self, pages: Sequence[int]) -> str | None:
        try:
            document = self._open()
            if document is None or not pages:
                return None
            for page in pages:
                if page not in self._texts:
                    if not 0 <= page < document.page_count:
                        return None
                    self._texts[page] = document.load_page(page).get_text("text")
            return "\n".join(self._texts[page] for page in pages)
        except Exception:  # noqa: BLE001
            # an unreadable source only costs the tie-break; the listing still stands
            logger.warning("原稿的文字读不出来，重复出现的标注不再分辨是哪一处", exc_info=True)
            self._failed = True
            return None

    def _open(self) -> Any:
        if self._document is None and not self._failed:
            if not self._path.is_file():
                self._failed = True
                return None
            import pymupdf

            self._document = pymupdf.open(self._path)
        return self._document


async def _annotations(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    if context.project_dir is None:
        raise ToolError("这一层 agent 没有项目，看不了标注", "NO_PROJECT")
    query = _Query.parse(arguments)
    # indexing a long paper and reading the PDF take a moment; never on the event loop
    return await asyncio.to_thread(_view, Path(context.project_dir), query)


def _view(root: Path, query: _Query) -> ToolOutcome:
    try:
        records = book.AnnotationBook(book.path_in(root)).list()
    except book.AnnotationError as exc:
        raise ToolError(_BOOK_ERRORS.get(exc.code, "读不出标注"), exc.code) from exc
    every = [_Mark.read(record) for record in records]
    if not every:
        return ToolOutcome("原稿上还没有标注。", detail=_detail(every, [], []))

    matched = [mark for mark in every if query.accepts(mark)]
    markdown = _paper_text(root)
    index = PaperIndex(markdown) if markdown is not None and matched else None
    with _SourcePages(root / PDF_DIR / "source.pdf") as source:
        if query.order == "recent":
            matched.sort(key=lambda mark: (mark.changed, mark.ident), reverse=True)
            shown = matched[:query.limit]
            _locate(shown, index, source)
        else:
            _locate(matched, index, source)
            matched.sort(key=_reading_order)
            shown = matched[:query.limit]
    return ToolOutcome(
        _render(every, matched, shown, query, has_text=markdown is not None, index=index),
        detail=_detail(every, matched, shown),
    )


def _locate(marks: list[_Mark], index: PaperIndex | None, source: _SourcePages) -> None:
    if index is None:
        return
    for mark in marks:
        anchor = index.locate(mark.text)
        if anchor.status == "ambiguous" and anchor.count > 1:
            page_text = source.text(mark.pages)
            around = surroundings(page_text, mark.text) if page_text else None
            if around is not None:
                anchor = index.locate(mark.text, around)
        mark.anchor = anchor


def _reading_order(mark: _Mark) -> tuple[Any, ...]:
    page = mark.pages[0] if mark.pages else sys.maxsize
    if mark.anchor is not None and mark.anchor.located:
        return page, 0, mark.anchor.start, 0.0, mark.ident
    # unlocated marks keep to their page, top to bottom, after the located ones
    return page, 1, 0, -mark.top, mark.ident


def _render(every: list[_Mark], matched: list[_Mark], shown: list[_Mark], query: _Query,
            *, has_text: bool, index: PaperIndex | None) -> str:
    lines = [f"原稿上共 {len(every)} 条标注：{_tally(every)}。"]
    if query.filtered:
        if not matched:
            lines.append(f"没有符合条件（{query.describe()}）的标注。")
            return "\n".join(lines)
        lines.append(f"符合条件（{query.describe()}）的有 {len(matched)} 条。")
    if not has_text:
        lines.append("这个项目还没有正文，下面是原稿上的字，没有对回正文。")
    cut = len(shown) < len(matched)
    if query.order == "recent":
        lines.append(f"下面列出最近标注或改动过的 {len(shown)} 条，从新到旧：" if cut
                     else "下面按标注或改动的时间从新到旧列出：")
    else:
        lines.append(f"下面按阅读顺序列出前 {len(shown)} 条：" if cut else "下面按阅读顺序列出：")
    for number, mark in enumerate(shown, 1):
        lines.append("")
        lines.append(f"{number}. {_pages(mark.pages)} · {mark.name}{_where(mark.anchor)}")
        lines.append("   " + _passage(mark, index))
    return "\n".join(lines)


def _where(anchor: Anchor | None) -> str:
    if anchor is None:
        return ""
    heading = f" · {anchor.heading}" if anchor.heading and anchor.located else ""
    span = _lines(anchor)
    if anchor.status == "exact":
        return f"{heading} · md/context.md {span}"
    if anchor.status == "approximate":
        return f"{heading} · 约在 md/context.md {span}，与原稿用字有出入（下面是原稿上的字）"
    if anchor.status == "ambiguous" and anchor.count > 1:
        many = f"{anchor.count} 处以上" if anchor.count >= MAX_HITS else f"{anchor.count} 处"
        return f" · 正文里有 {many}同样的字，定不下是哪一处（下面是原稿上的字）"
    if anchor.status == "ambiguous":
        return " · 正文里有几处都像它，定不下是哪一处（下面是原稿上的字）"
    return " · 正文里没找到（下面是原稿上的字）"


def _passage(mark: _Mark, index: PaperIndex | None) -> str:
    if index is not None and mark.anchor is not None and mark.anchor.status == "exact":
        return _clip(index.excerpt(mark.anchor), f"（后略，全文在 md/context.md {_lines(mark.anchor)}）")
    if not mark.text.strip():
        return "（这条标注没有存下文字）"
    text = " ".join(_HYPHEN_BREAK.sub("-", mark.text).split())
    return _clip(text, f"（后略，共 {len(text)} 字）")


def _clip(text: str, note: str) -> str:
    return text if len(text) <= EXCERPT_CHARS else text[:EXCERPT_CHARS].rstrip() + "…" + note


def _lines(anchor: Anchor) -> str:
    if anchor.first_line == anchor.last_line:
        return f"第 {anchor.first_line} 行"
    return f"第 {anchor.first_line}–{anchor.last_line} 行"


def _pages(pages: Sequence[int]) -> str:
    numbers = [page + 1 for page in pages]
    if not numbers:
        return "页码不明"
    if len(numbers) > 1 and numbers == list(range(numbers[0], numbers[-1] + 1)):
        return f"第 {numbers[0]}–{numbers[-1]} 页"
    return f"第 {'、'.join(str(n) for n in numbers)} 页"


def _tally(marks: list[_Mark]) -> str:
    counts = Counter((mark.color, mark.kind) for mark in marks)

    def rank(pair: tuple[str, str]) -> tuple[Any, ...]:
        color, kind = pair
        return (book.COLORS.index(color) if color in book.COLORS else len(book.COLORS),
                book.KINDS.index(kind) if kind in book.KINDS else len(book.KINDS), color, kind)

    named = {pair: book.COLOR_NAMES.get(pair[0], pair[0]) + book.KIND_NAMES.get(pair[1], pair[1])
             for pair in counts}
    return " · ".join(f"{named[pair]} {counts[pair]}" for pair in sorted(counts, key=rank))


def _detail(every: list[_Mark], matched: list[_Mark], shown: list[_Mark]) -> dict[str, object]:
    """Counts only, for the log and the conversation view."""
    return {
        "total": len(every),
        "matched": len(matched),
        "shown": len(shown),
        "located": sum(1 for mark in shown if mark.anchor is not None and mark.anchor.located),
    }


def _paper_text(root: Path) -> str | None:
    path = root / MD_DIR / "context.md"
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else None


def _list(value: object) -> list[Any]:
    return value if isinstance(value, list) else []


def _text(value: object) -> str:
    return value if isinstance(value, str) else ""


def _is_int(value: object) -> bool:
    # bool is an int subclass; true is not page 1
    return isinstance(value, int) and not isinstance(value, bool)


_COLOR_CHOICES = "、".join(f"{key} {book.COLOR_NAMES[key]}" for key in book.COLORS)
_KIND_CHOICES = "、".join(f"{key} {book.KIND_NAMES[key]}" for key in book.KINDS)


def annotation_tools() -> tuple[ToolDef, ...]:
    return (
        ToolDef(
            name="annotations",
            description=(
                "列出用户在原稿 PDF 上做的标注（高亮或下划线，每条一种颜色），每一条都对回正文："
                "页码、所在小节、在 md/context.md 里的行号，以及正文里对应的那段原文。\n\n"
                "标注由应用保存，不在项目文件里 —— glob、grep、read 都找不到，只能用这个工具看。\n\n"
                "按用户问的收窄范围（颜色、样式、页码）；问「刚标的那句」用 order=recent 加 limit。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "colors": {
                        "type": "array",
                        "items": {"type": "string", "enum": list(book.COLORS)},
                        "description": f"只看这些颜色：{_COLOR_CHOICES}。不填就是全部颜色",
                    },
                    "kind": {
                        "type": "string",
                        "enum": list(book.KINDS),
                        "description": f"只看一种样式：{_KIND_CHOICES}。不填就是两种都要",
                    },
                    "pages": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "description": "只看这些页上的标注（页码从 1 起）",
                    },
                    "order": {
                        "type": "string",
                        "enum": list(ORDERS),
                        "description": "reading 按阅读顺序（默认）；recent 最近标的或改过的在前",
                    },
                    "limit": {"type": "integer", "description": "最多列出几条"},
                },
            },
            run=_annotations,
            read_only=True,
            concurrency_safe=True,
        ),
    )
