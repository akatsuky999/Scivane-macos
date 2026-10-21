"""The user's marks on a project's source PDF: highlights and underlines of its text, notes written
on the page, and pen strokes.

One JSON document per project in the control plane (.lumen/annotations.json), rewritten atomically
on every change. The source PDF itself is never modified. The app owns the geometry: rects and points
are page space points exactly as PDFKit reports them, and this module only checks that they are well
formed. The agent can't open the file; the annotations tool reads it on the host and shows the model a
view of it, without geometry.

A file that only holds highlights and underlines keeps the first schema, so an app that predates notes
and strokes still reads it; one with a note or a stroke is written as the second, which such an app
refuses rather than misreads.
"""

from __future__ import annotations

import json
import math
import re
import threading
from collections.abc import Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..i18n import ui
from .workspace import CONTROL_DIR

FILE_NAME = "annotations.json"
SCHEMA = "scivane.annotations/1"
SCHEMA_FREEHAND = "scivane.annotations/2"
SCHEMAS = (SCHEMA, SCHEMA_FREEHAND)

#: Styles of a mark on the text. Must match AnnotationKind in the app, in order.
KINDS = ("highlight", "underline")
NOTE = "note"
INK = "ink"
#: kinds that only the second schema holds
FREEHAND = (NOTE, INK)
#: Palette keys rather than RGB values, so the app decides how each one renders. Must match
#: AnnotationColor in the app.
COLORS = ("yellow", "red", "green", "blue", "purple", "magenta", "orange", "gray")

#: The words the app's palette uses, so the model and the user call a colour the same thing.
COLOR_NAMES = {
    "yellow": "黄色", "red": "红色", "green": "绿色", "blue": "蓝色",
    "purple": "紫色", "magenta": "品红", "orange": "橙色", "gray": "灰色",
}
KIND_NAMES = {"highlight": "高亮", "underline": "下划线"}
#: what the app's undo menu calls a note and a drawing
FREEHAND_NAMES = {NOTE: "文字批注", INK: "手绘"}

MAX_ANNOTATIONS = 20_000
#: pages one annotation may cover
MAX_SPANS = 500
#: line rects on one page
MAX_RECTS = 1_000
MAX_PAGE = 100_000
#: The text is a convenience copy for listing and search; the geometry is the annotation. Longer
#: selections keep their full geometry and a truncated text.
MAX_TEXT = 20_000
#: page space coordinates beyond this are garbage, not a large page
_MAX_COORD = 1e6
#: a note is a few sentences written in the margin, not a document
MAX_NOTE = 5_000
#: text size of a note and width of a stroke, in page points; the app's note sizes are the same range
NOTE_SIZES = (4.0, 144.0)
INK_WIDTHS = (0.1, 36.0)
#: strokes in one ink mark, and points in one stroke and in all of them
MAX_STROKES = 500
MAX_STROKE_POINTS = 10_000
MAX_INK_POINTS = 50_000

#: client-generated, so the app can show a mark before the write returns
_ID = re.compile(r"[A-Za-z0-9-]{8,64}")

#: Serialises read-modify-write. Requests run on one event loop today; the lock keeps this correct
#: if a write ever happens from a worker thread.
_lock = threading.Lock()


class AnnotationError(Exception):
    """A refused annotation operation; the stable code picks the HTTP status."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


def _invalid(zh: str, en: str) -> AnnotationError:
    return AnnotationError(ui(zh, en), "INVALID_ANNOTATION")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def _kind(value: Any) -> str:
    if value not in KINDS:
        raise _invalid(f"未知的标注样式：{value!r}", f"Unknown annotation style: {value!r}")
    return value


def _color(value: Any) -> str:
    if value not in COLORS:
        raise _invalid(f"未知的标注颜色：{value!r}", f"Unknown annotation colour: {value!r}")
    return value


def _coordinate(item: Any) -> float:
    # bool is an int subclass; true/false in a rect is a client bug
    if isinstance(item, bool) or not isinstance(item, (int, float)):
        raise _invalid("坐标只能是数字", "Coordinates may only be numbers")
    number = float(item)
    if not math.isfinite(number) or abs(number) > _MAX_COORD:
        raise _invalid("坐标超出范围", "Coordinates are out of range")
    return number


def _rect(value: Any) -> list[float]:
    if not isinstance(value, (list, tuple)) or len(value) != 4:
        raise _invalid("矩形必须是 [x, y, 宽, 高]", "A rect must be [x, y, width, height]")
    numbers = [_coordinate(item) for item in value]
    if numbers[2] <= 0 or numbers[3] <= 0:
        raise _invalid("矩形的宽高必须为正", "Rect width and height must be positive")
    return numbers


def _page(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < MAX_PAGE:
        raise _invalid(f"页码不对：{value!r}", f"Invalid page index: {value!r}")
    return value


def _number_in(value: Any, bounds: tuple[float, float], zh: str, en: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) \
            or not bounds[0] <= value <= bounds[1]:
        raise _invalid(f"{zh}超出范围：{value!r}", f"{en} out of range: {value!r}")
    return float(value)


def _body(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise _invalid("文字批注不能是空的", "A note can't be empty")
    if len(value) > MAX_NOTE:
        raise _invalid(f"文字批注最多 {MAX_NOTE} 字", f"A note holds at most {MAX_NOTE} characters")
    return value


def _strokes(value: Any) -> list[list[float]]:
    """Each stroke is its points flattened, x then y: the compact form of a long list of pairs."""
    if not isinstance(value, list) or not value:
        raise _invalid("手绘至少要有一笔", "A drawing needs at least one stroke")
    if len(value) > MAX_STROKES:
        raise _invalid(f"一处手绘最多 {MAX_STROKES} 笔", f"A drawing holds at most {MAX_STROKES} strokes")
    strokes: list[list[float]] = []
    total = 0
    for raw in value:
        if not isinstance(raw, list) or len(raw) < 4 or len(raw) % 2:
            raise _invalid("一笔至少两个点，按 x、y 成对", "A stroke is at least two points, as x, y pairs")
        if len(raw) > MAX_STROKE_POINTS * 2:
            raise _invalid(f"一笔最多 {MAX_STROKE_POINTS} 个点", f"A stroke holds at most {MAX_STROKE_POINTS} points")
        total += len(raw) // 2
        strokes.append([_coordinate(item) for item in raw])
    if total > MAX_INK_POINTS:
        raise _invalid(f"一处手绘最多 {MAX_INK_POINTS} 个点", f"A drawing holds at most {MAX_INK_POINTS} points")
    return strokes


def _spans(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise _invalid("标注至少要落在一页上", "An annotation must cover at least one page")
    if len(value) > MAX_SPANS:
        raise _invalid(f"一条标注最多跨 {MAX_SPANS} 页", f"An annotation may span at most {MAX_SPANS} pages")
    spans: list[dict[str, Any]] = []
    for raw in value:
        if not isinstance(raw, Mapping):
            raise _invalid("页面片段的格式不对", "Malformed page span")
        page = _page(raw.get("page"))
        rects = raw.get("rects")
        if not isinstance(rects, list) or not rects:
            raise _invalid("页面片段里没有矩形", "A page span has no rects")
        if len(rects) > MAX_RECTS:
            raise _invalid(f"一页最多 {MAX_RECTS} 个矩形", f"At most {MAX_RECTS} rects per page")
        spans.append({"page": page, "rects": [_rect(rect) for rect in rects]})
    pages = [span["page"] for span in spans]
    if len(set(pages)) != len(pages):
        raise _invalid("同一页出现了两次", "A page appears twice")
    spans.sort(key=lambda span: span["page"])
    return spans


def validate_new(raw: Mapping[str, Any]) -> dict[str, Any]:
    """A normalised new record from client input; timestamps are added by the book."""
    identifier = raw.get("id")
    if not isinstance(identifier, str) or not _ID.fullmatch(identifier):
        raise _invalid(f"非法的标注 id：{identifier!r}", f"Invalid annotation id: {identifier!r}")
    kind = raw.get("kind")
    color = _color(raw.get("color"))
    if kind == NOTE:
        return {
            "id": identifier, "kind": NOTE, "color": color,
            "page": _page(raw.get("page")),
            "rect": _rect(raw.get("rect")),
            "body": _body(raw.get("body")),
            "size": _number_in(raw.get("size"), NOTE_SIZES, "字号", "Text size"),
        }
    if kind == INK:
        return {
            "id": identifier, "kind": INK, "color": color,
            "page": _page(raw.get("page")),
            "width": _number_in(raw.get("width"), INK_WIDTHS, "笔宽", "Stroke width"),
            "strokes": _strokes(raw.get("strokes")),
        }
    text = raw.get("text", "")
    if not isinstance(text, str):
        raise _invalid("标注文字必须是字符串", "Annotation text must be a string")
    return {
        "id": identifier,
        "kind": _kind(kind),
        "color": color,
        "spans": _spans(raw.get("spans")),
        "text": text[:MAX_TEXT],
    }


def validate_changes(raw: Mapping[str, Any], kind: str = KINDS[0]) -> dict[str, Any]:
    """What may change depends on the kind. A mark on the text keeps its geometry and changes style
    or colour; a note is rewritten, moved and resized; a drawing loses parts to the eraser. No mark
    becomes another kind, except a highlight and an underline, which are styles of the same thing.
    """
    changes: dict[str, Any] = {}
    if raw.get("color") is not None:
        changes["color"] = _color(raw["color"])
    if kind in KINDS:
        if raw.get("kind") is not None:
            changes["kind"] = _kind(raw["kind"])
        allowed = ("kind", "color")
    elif kind == NOTE:
        if raw.get("body") is not None:
            changes["body"] = _body(raw["body"])
        if raw.get("rect") is not None:
            changes["rect"] = _rect(raw["rect"])
        if raw.get("size") is not None:
            changes["size"] = _number_in(raw["size"], NOTE_SIZES, "字号", "Text size")
        allowed = ("color", "body", "rect", "size")
    elif kind == INK:
        if raw.get("width") is not None:
            changes["width"] = _number_in(raw["width"], INK_WIDTHS, "笔宽", "Stroke width")
        if raw.get("strokes") is not None:
            changes["strokes"] = _strokes(raw["strokes"])
        allowed = ("color", "width", "strokes")
    else:
        allowed = ("color",)
    if raw.get("kind") is not None and "kind" not in allowed:
        raise _invalid("这条标注不能换种类", "This mark can't change its kind")
    if not changes:
        names = "、".join(allowed)
        raise _invalid(f"至少给一项：{names}", f"Give at least one of: {', '.join(allowed)}")
    return changes


def path_in(project_dir: Path | str) -> Path:
    """Where a project keeps its marks."""
    return Path(project_dir) / CONTROL_DIR / FILE_NAME


class AnnotationBook:
    """The annotations of one project, backed by one file."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def list(self) -> list[dict[str, Any]]:
        """In creation order. Records written by a newer app (unknown colours or kinds) pass through."""
        with _lock:
            return self._load()

    def add(self, raw: Mapping[str, Any]) -> dict[str, Any]:
        record = validate_new(raw)
        with _lock:
            items = self._load()
            if any(item.get("id") == record["id"] for item in items):
                raise AnnotationError(ui(f"标注已存在：{record['id']}",
                                         f"Annotation already exists: {record['id']}"),
                                      "ANNOTATION_EXISTS")
            if len(items) >= MAX_ANNOTATIONS:
                raise AnnotationError(ui(f"一个项目最多 {MAX_ANNOTATIONS} 条标注",
                                         f"A project holds at most {MAX_ANNOTATIONS} annotations"),
                                      "TOO_MANY_ANNOTATIONS")
            stamp = _now()
            record["created_at"] = stamp
            record["updated_at"] = stamp
            items.append(record)
            self._save(items)
            return record

    def update(self, annotation_id: str, raw: Mapping[str, Any]) -> dict[str, Any]:
        with _lock:
            items = self._load()
            for item in items:
                if item.get("id") == annotation_id:
                    item.update(validate_changes(raw, item.get("kind", KINDS[0])))
                    item["updated_at"] = _now()
                    self._save(items)
                    return item
            raise self._missing(annotation_id)

    def remove(self, annotation_id: str) -> bool:
        """False when there was nothing to remove, so a repeated delete is harmless."""
        with _lock:
            items = self._load()
            kept = [item for item in items if item.get("id") != annotation_id]
            if len(kept) == len(items):
                return False
            self._save(kept)
            return True

    @staticmethod
    def _missing(annotation_id: str) -> AnnotationError:
        return AnnotationError(ui(f"没有这条标注：{annotation_id}",
                                  f"No such annotation: {annotation_id}"), "ANNOTATION_NOT_FOUND")

    def _load(self) -> list[dict[str, Any]]:
        """A damaged or newer file is reported, never overwritten: it holds the user's work."""
        try:
            document = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return []
        except (OSError, ValueError) as exc:
            raise AnnotationError(ui("标注文件损坏，已保持原样", "The annotation file is damaged and was left as is"),
                                  "CORRUPT_ANNOTATIONS") from exc
        if not isinstance(document, dict) or not isinstance(document.get("annotations"), list):
            raise AnnotationError(ui("标注文件损坏，已保持原样", "The annotation file is damaged and was left as is"),
                                  "CORRUPT_ANNOTATIONS")
        if document.get("schema") not in SCHEMAS:
            raise AnnotationError(ui(f"标注文件的格式不认识：{document.get('schema')!r}",
                                     f"Unrecognised annotation file format: {document.get('schema')!r}"),
                                  "UNSUPPORTED_ANNOTATIONS")
        items = document["annotations"]
        if not all(isinstance(item, dict) for item in items):
            raise AnnotationError(ui("标注文件损坏，已保持原样", "The annotation file is damaged and was left as is"),
                                  "CORRUPT_ANNOTATIONS")
        return items

    def _save(self, items: list[dict[str, Any]]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(self.path.name + ".tmp")
        schema = SCHEMA_FREEHAND if any(item.get("kind") in FREEHAND for item in items) else SCHEMA
        temporary.write_text(
            json.dumps({"schema": schema, "annotations": items}, ensure_ascii=False, indent=1),
            encoding="utf-8",
        )
        temporary.replace(self.path)
