"""Pages as the transcription model sees them: an image, the PDF's own text, and its figures.

pymupdf only, no model, so all of it is testable on its own. Figures are found in the PDF
(raster images and clusters of vector drawings) and cropped from the PDF itself, which is
sharper and more reliable than asking a model for bounding boxes; the model only decides where
each figure sits in the reading order.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

__all__ = [
    "PageImage", "Figure", "PagePlan",
    "count", "plan", "encode", "text_layer", "find_figures", "caption_kind",
]

#: Above this the text layer is truncated; a dense page has about 6,000 characters.
HINT_CHARS = 12_000
#: A raster image covering this much of the page means the page is a scan, not a figure.
SCAN_COVERAGE = 0.85
#: Graphics smaller than this (share of the page area) are icons, logos or inline symbols.
MIN_FIGURE_AREA = 0.012
#: Panels of one figure closer than this (in points, labels included) become one crop.
PANEL_GAP = 36.0
#: Regions whose words cover more than this share are text boxes or tables, not figures.
TEXTY = 0.3
#: How far a caption may sit from its figure, in points.
CAPTION_REACH = 36.0
#: Longest side of a figure crop, in pixels.
CROP_LONG_EDGE = 1800

#: "Figure 3:", "Fig. 2.", "Table 1 Results", "图 1 网络结构". A capital (or CJK) after the number
#: rules out sentences that merely start with a reference ("Figure 3 and 4 show ...").
_CAPTION = re.compile(
    r"^\s*(?:(?P<figure>fig(?:ure)?s?\.?|图|圖|插图)"
    r"|(?P<text>tab(?:le)?s?\.?|表|algorithm|算法|listing|代码))"
    r"\s*(?:[A-Z]\.?)?[\dIVX]+[a-z]?(?:\.\d+)*"
    r"(?:\s*[:.|：．]|(?-i:\s+[A-Z(\u3400-\u9fff])|\s*$)",
    re.IGNORECASE,
)
#: replacement characters and private-use glyphs: a text layer full of them is a broken encoding
_GARBLED = re.compile(r"[�-]")


@dataclass(frozen=True)
class PageImage:
    data: bytes
    media_type: str
    width: int
    height: int


@dataclass(frozen=True)
class Figure:
    """A figure region, numbered top to bottom within its page."""

    number: int
    #: fractions of the page, x0, y0, x1, y1
    box: tuple[float, float, float, float]
    #: the nearest figure caption, or ""
    caption: str
    #: PNG crop
    image: bytes


@dataclass(frozen=True)
class PagePlan:
    """Everything one transcription request needs for one page. index is 1-based."""

    index: int
    total: int
    image: PageImage
    text: str
    figures: tuple[Figure, ...]


def count(path: Path) -> int:
    import pymupdf

    with pymupdf.open(path) as document:
        return document.page_count


def plan(path: Path, index: int, total: int, *, long_edge: int) -> PagePlan:
    """Render page `index` (1-based) and gather its text and figures. Opens the document per
    call: pymupdf documents aren't safe to share between threads.
    """
    import pymupdf

    with pymupdf.open(path) as document:
        page = document.load_page(index - 1)
        if not document.is_pdf:
            # a photo or scan given as an image file: send its pixels, never upscaled
            pixmap = pymupdf.Pixmap(Path(path).read_bytes())
            return PagePlan(index, total, encode(_fit(pixmap, long_edge)), "", ())
        zoom = long_edge / max(page.rect.width, page.rect.height)
        pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
        return PagePlan(index, total, encode(pixmap), text_layer(page), find_figures(page))


def encode(pixmap) -> PageImage:
    """PNG keeps glyph edges exact; JPEG is far smaller for scans and photos. Take PNG unless it
    costs more than a fifth over JPEG.
    """
    import pymupdf

    if pixmap.alpha:
        pixmap = pymupdf.Pixmap(pixmap, 0)
    if pixmap.n not in (1, 3):
        pixmap = pymupdf.Pixmap(pymupdf.csRGB, pixmap)
    png = pixmap.tobytes("png")
    jpeg = pixmap.tobytes("jpeg", jpg_quality=85)
    if len(png) <= len(jpeg) * 1.2:
        return PageImage(png, "image/png", pixmap.width, pixmap.height)
    return PageImage(jpeg, "image/jpeg", pixmap.width, pixmap.height)


def _fit(pixmap, long_edge: int):
    import pymupdf

    longest = max(pixmap.width, pixmap.height)
    if longest <= long_edge:
        return pixmap
    scale = long_edge / longest
    return pymupdf.Pixmap(pixmap, pixmap.width * scale, pixmap.height * scale, None)


def text_layer(page) -> str:
    """The PDF's own text in content-stream order, which follows columns in most typeset papers.
    Empty for scans and for layers whose encoding is broken, since a wrong hint is worse than none.
    """
    text = page.get_text("text").strip()
    if len(text) < 20 or len(_GARBLED.findall(text)) > len(text) * 0.05:
        return ""
    return text[:HINT_CHARS]


def caption_kind(text: str) -> str | None:
    """"figure", "text" (tables, algorithms, listings) or None when the block isn't a caption."""
    match = _CAPTION.match(text)
    if match is None:
        return None
    return "figure" if match.group("figure") else "text"


def find_figures(page) -> tuple[Figure, ...]:
    import pymupdf

    bounds = page.rect
    area = bounds.width * bounds.height
    drawings = _visible_drawings(page)
    clusters = list(page.cluster_drawings(drawings=drawings)) if drawings else []
    blocks = _text_blocks(page)
    raw: list = []
    for found in [info["bbox"] for info in page.get_image_info()] + clusters:
        rect = pymupdf.Rect(found) & bounds
        if rect.is_empty or rect.width < 8 or rect.height < 8:
            continue  # rules, fraction bars, underlines
        if rect.width * rect.height > SCAN_COVERAGE * area:
            return ()  # the page is one picture: a scan, nothing to crop
        # Drawing boxes ignore clipping (a bar chart's bars run past its axes, over the
        # caption), so cut at a caption that starts inside.
        rect = _cut_at_caption(rect, blocks)
        if _caption(rect, blocks)[0] == "text":
            continue  # the rules of a table, transcribed as text
        raw.append(rect)

    regions = [
        _Region(rect, _with_labels(rect, blocks))
        for rect in (_cut_at_caption(rect, blocks) for rect in _merged(raw))
    ]
    regions = [part for region in _grouped(regions, blocks) for part in _split(region, blocks)]

    kept = []
    for region in regions:
        graphic = region.graphic
        # judged on the graphics alone: labels around a logo don't make it a figure
        if (graphic.width * graphic.height < MIN_FIGURE_AREA * area
                or graphic.width < 0.08 * bounds.width or graphic.height < 0.03 * bounds.height):
            continue
        kind, caption = _caption(region.grown, blocks)
        if kind == "text":
            continue  # a table, an algorithm or a listing: the model transcribes it
        if kind is None and _texty(page, region.grown):
            continue  # a framed paragraph without a caption, not a picture
        kept.append((region.grown, caption))

    kept.sort(key=lambda item: (round(item[0].y0), item[0].x0))
    figures = []
    for number, (rect, caption) in enumerate(kept, 1):
        zoom = min(4.0, CROP_LONG_EDGE / max(rect.width, rect.height))
        crop = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), clip=rect, alpha=False)
        box = (rect.x0 / bounds.width, rect.y0 / bounds.height,
               rect.x1 / bounds.width, rect.y1 / bounds.height)
        figures.append(Figure(number, box, caption, crop.tobytes("png")))
    return tuple(figures)


def _text_blocks(page) -> list[tuple[object, str]]:
    """Text blocks as captions need them. pymupdf's own blocks can hold a table's cells together
    with its caption, or join one-line captions that sit side by side ("Figure 3: … Figure 4: …");
    either way the caption is no longer where it begins. So: lines split at gutter-wide gaps, and
    a line that starts like a caption starts a block of its own.
    """
    import pymupdf

    found: list[list] = []  # [rect, lines]
    for block in page.get_text("dict")["blocks"]:
        if block.get("type") != 0:
            continue
        pieces: list[list] = []
        for line in block.get("lines", ()):
            for rect, text in _segments(line):
                fresh = caption_kind(text) is not None
                target = None if fresh else next(
                    (piece for piece in reversed(pieces)
                     if min(piece[0].x1, rect.x1) > max(piece[0].x0, rect.x0)), None)
                if target is None:
                    pieces.append([pymupdf.Rect(rect), [text]])
                else:
                    target[0].include_rect(rect)
                    target[1].append(text)
        found.extend(pieces)
    return [(rect, " ".join(" ".join(lines).split())) for rect, lines in found]


def _segments(line: dict) -> list[tuple[object, str]]:
    """A line cut where the gap is wider than a word space can be, even in justified text."""
    import pymupdf

    segments: list[list] = []
    for span in line.get("spans", ()):
        text = span["text"]
        if not text.strip():
            continue
        rect = pymupdf.Rect(span["bbox"])
        size = span.get("size", 10.0)
        if segments:
            gap = rect.x0 - segments[-1][0].x1
            if gap <= max(18.0, 3 * size):
                segments[-1][0].include_rect(rect)
                # spans carry no space when words are placed one by one
                joiner = " " if gap > 0.15 * size and not segments[-1][1].endswith(" ") else ""
                segments[-1][1] += joiner + text
                continue
        segments.append([rect, text])
    return [(rect, text) for rect, text in segments]


@dataclass
class _Region:
    #: drawings and images only
    graphic: object
    #: with the labels around them; what gets cropped
    grown: object


def _merged(rects: list) -> list:
    """Union of overlapping or nearly touching regions, until nothing changes."""
    import pymupdf

    pending = [pymupdf.Rect(r) for r in rects]
    merged = True
    while merged:
        merged = False
        out: list = []
        for rect in pending:
            grown = pymupdf.Rect(rect.x0 - 6, rect.y0 - 6, rect.x1 + 6, rect.y1 + 6)
            for kept in out:
                if grown.intersects(kept):
                    kept.include_rect(rect)
                    merged = True
                    break
            else:
                out.append(pymupdf.Rect(rect))
        pending = out
    return pending


def _visible_drawings(page) -> list[dict]:
    """Drawings as they appear, for clustering (which reads only "rect").

    Two corrections to the raw boxes: clip paths are applied (a bar chart draws its bars from
    off-scale and lets the axes clip them, so the raw boxes reach into the table above or the
    caption below), and white fills without a stroke are dropped (invisible on a white page, yet
    they frame whole columns: matplotlib's canvas, a figure's background box).
    """
    import pymupdf

    bounds = page.rect
    scissors: dict[int, tuple[float, float, float, float]] = {}
    visible = []
    for item in page.get_drawings(extended=True):
        level = item.get("level", 0)
        for deeper in [key for key in scissors if key >= level]:
            del scissors[deeper]  # back out of a clip: it no longer applies
        if item["type"] in ("clip", "group"):
            if item.get("scissor") is not None:
                scissors[level] = tuple(item["scissor"])
            continue
        if _invisible(item):
            continue
        x0, y0, x1, y1 = _extent(item)
        for cx0, cy0, cx1, cy1 in [tuple(bounds), *scissors.values()]:
            x0, y0, x1, y1 = max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1)
        # Lines have zero width or height and still count; only a negative extent means clipped away.
        if x0 <= x1 and y0 <= y1:
            visible.append({"rect": pymupdf.Rect(x0, y0, x1, y1)})
    return visible


def _extent(item: dict) -> tuple[float, float, float, float]:
    """A path's box from its own segments. The reported "rect" can cover only the first subpath of
    a stroked path (a chart's two axes drawn as one path came back as the x-axis alone).
    """
    xs: list[float] = []
    ys: list[float] = []
    for segment in item.get("items") or ():
        for part in segment[1:]:
            if hasattr(part, "x0"):          # Rect, IRect
                xs += [part.x0, part.x1]
                ys += [part.y0, part.y1]
            elif hasattr(part, "ul"):        # Quad
                xs += [part.ul.x, part.ur.x, part.ll.x, part.lr.x]
                ys += [part.ul.y, part.ur.y, part.ll.y, part.lr.y]
            elif hasattr(part, "x"):         # Point
                xs.append(part.x)
                ys.append(part.y)
    if not xs:
        return tuple(item["rect"])
    return min(xs), min(ys), max(xs), max(ys)


def _invisible(drawing: dict) -> bool:
    def white(color) -> bool:
        return color is not None and all(channel >= 0.97 for channel in color)

    stroke = drawing.get("color")
    if drawing.get("type") == "f":
        return white(drawing.get("fill"))
    return white(stroke) and (drawing.get("fill") is None or white(drawing.get("fill")))


#: Text blocks this short beside a figure are its labels (axis titles, ticks, legends).
LABEL_WORDS = 12


def _with_labels(rect, blocks):
    """Grow a figure over the short text blocks touching its graphics, so a crop keeps its axis
    labels. One pass from the graphics only: growing from the grown box would chain through a
    column of short lines.
    """
    import pymupdf

    grown = pymupdf.Rect(rect)
    reach = pymupdf.Rect(rect.x0 - 12, rect.y0 - 12, rect.x1 + 12, rect.y1 + 12)
    for block, text in blocks:
        if (block.intersects(reach) and caption_kind(text) is None
                and len(text.split()) <= LABEL_WORDS):
            grown.include_rect(block)
    return grown


def _grouped(regions: list[_Region], blocks) -> list[_Region]:
    """Panels become one figure when the same caption is the nearest one under both (however far
    apart they sit), or when they are close and one has no caption: a grid of plots is captioned
    once, under its last row.
    """
    import pymupdf

    groups = list(regions)
    merged = True
    while merged:
        merged = False
        for i in range(len(groups)):
            a = groups[i]
            near = pymupdf.Rect(a.grown.x0 - PANEL_GAP, a.grown.y0 - PANEL_GAP,
                                a.grown.x1 + PANEL_GAP, a.grown.y1 + PANEL_GAP)
            caption_a = _caption(a.grown, blocks)[1]
            for j in range(i + 1, len(groups)):
                b = groups[j]
                caption_b = _caption(b.grown, blocks)[1]
                shared = bool(caption_a) and caption_a == caption_b
                if shared or (near.intersects(b.grown) and (not caption_a or not caption_b)):
                    groups[i] = _Region(a.graphic | b.graphic, a.grown | b.grown)
                    del groups[j]
                    merged = True
                    break
            if merged:
                break
    return groups


def _split(region: _Region, blocks) -> list[_Region]:
    """One region over several captions side by side is several figures in a row: cut it into
    strips, one per caption.
    """
    import pymupdf

    below = sorted(
        (block for block, text in blocks
         if caption_kind(text) == "figure" and _overlaps(region.grown, block)
         and 0 <= block.y0 - region.grown.y1 + 2 <= CAPTION_REACH),
        key=lambda block: block.x0,
    )
    if len(below) < 2 or any(b.x0 < a.x1 - 2 for a, b in zip(below, below[1:])):
        return [region]
    edges = [region.grown.x0, *((a.x1 + b.x0) / 2 for a, b in zip(below, below[1:])),
             region.grown.x1]
    parts = []
    for left, right in zip(edges, edges[1:]):
        strip = pymupdf.Rect(left, region.grown.y0, right, region.grown.y1)
        graphic = region.graphic & strip
        if not graphic.is_empty:
            parts.append(_Region(graphic, region.grown & strip))
    return parts or [region]


def _overlaps(rect, block) -> bool:
    """Shares at least 30% of the narrower width: in the same column."""
    overlap = min(rect.x1, block.x1) - max(rect.x0, block.x0)
    return overlap >= 0.3 * min(rect.width, block.width)


#: A caption this far below a region's top can't be part of it: captions sit outside figures.
MIN_CUT = 24.0


def _cut_at_caption(rect, blocks):
    import pymupdf

    cut = pymupdf.Rect(rect)
    for block, text in blocks:
        if (caption_kind(text) is not None and _overlaps(cut, block)
                and cut.y0 + MIN_CUT < block.y0 < cut.y1):
            cut.y1 = block.y0 - 1
    return cut


def _caption(rect, blocks) -> tuple[str | None, str]:
    """The caption closest to the region, below it (figures) or above it (tables)."""
    best: tuple[float, str, str] | None = None
    for block, text in blocks:
        kind = caption_kind(text)
        if kind is None or not _overlaps(rect, block):
            continue  # not a caption, or one in the other column
        if block.y0 >= rect.y1 - 2:
            distance = block.y0 - rect.y1
        elif block.y1 <= rect.y0 + 2:
            distance = rect.y0 - block.y1
        else:
            continue
        if distance <= CAPTION_REACH and (best is None or distance < best[0]):
            best = (distance, kind, text)
    return (best[1], best[2]) if best else (None, "")


def _texty(page, rect) -> bool:
    words = page.get_text("words", clip=rect)
    covered = sum((w[2] - w[0]) * (w[3] - w[1]) for w in words)
    return covered > TEXTY * rect.width * rect.height
