"""Highlights and underlines on a project's source PDF.

One JSON document per project in the control plane (.lumen/annotations.json), rewritten atomically
on every change. The source PDF itself is never modified. The app owns the geometry: rects are page
space points exactly as PDFKit reports them, and this module only checks that they are well formed.
Nothing here reaches the model.
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

FILE_NAME = "annotations.json"
SCHEMA = "scivane.annotations/1"

KINDS = ("highlight", "underline")
#: Palette keys rather than RGB values, so the app decides how each one renders. Must match
#: AnnotationColor in the app.
COLORS = ("yellow", "red", "green", "blue", "purple", "magenta", "orange", "gray")

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


def _rect(value: Any) -> list[float]:
    if not isinstance(value, (list, tuple)) or len(value) != 4:
        raise _invalid("矩形必须是 [x, y, 宽, 高]", "A rect must be [x, y, width, height]")
    numbers = []
    for item in value:
        # bool is an int subclass; true/false in a rect is a client bug
        if isinstance(item, bool) or not isinstance(item, (int, float)):
            raise _invalid("矩形里只能是数字", "Rects may only contain numbers")
        number = float(item)
        if not math.isfinite(number) or abs(number) > _MAX_COORD:
            raise _invalid("矩形坐标超出范围", "Rect coordinates are out of range")
        numbers.append(number)
    if numbers[2] <= 0 or numbers[3] <= 0:
        raise _invalid("矩形的宽高必须为正", "Rect width and height must be positive")
    return numbers


def _spans(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise _invalid("标注至少要落在一页上", "An annotation must cover at least one page")
    if len(value) > MAX_SPANS:
        raise _invalid(f"一条标注最多跨 {MAX_SPANS} 页", f"An annotation may span at most {MAX_SPANS} pages")
    spans: list[dict[str, Any]] = []
    for raw in value:
        if not isinstance(raw, Mapping):
            raise _invalid("页面片段的格式不对", "Malformed page span")
        page = raw.get("page")
        if isinstance(page, bool) or not isinstance(page, int) or not 0 <= page < MAX_PAGE:
            raise _invalid(f"页码不对：{page!r}", f"Invalid page index: {page!r}")
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
    text = raw.get("text", "")
    if not isinstance(text, str):
        raise _invalid("标注文字必须是字符串", "Annotation text must be a string")
    return {
        "id": identifier,
        "kind": _kind(raw.get("kind")),
        "color": _color(raw.get("color")),
        "spans": _spans(raw.get("spans")),
        "text": text[:MAX_TEXT],
    }


def validate_changes(raw: Mapping[str, Any]) -> dict[str, str]:
    """Style and colour are the only mutable fields; the geometry of a mark never changes."""
    changes: dict[str, str] = {}
    if raw.get("kind") is not None:
        changes["kind"] = _kind(raw["kind"])
    if raw.get("color") is not None:
        changes["color"] = _color(raw["color"])
    if not changes:
        raise _invalid("kind 与 color 至少给一个", "Give at least a kind or a colour")
    return changes


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
        changes = validate_changes(raw)
        with _lock:
            items = self._load()
            for item in items:
                if item.get("id") == annotation_id:
                    item.update(changes)
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
        if document.get("schema") != SCHEMA:
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
        temporary.write_text(
            json.dumps({"schema": SCHEMA, "annotations": items}, ensure_ascii=False, indent=1),
            encoding="utf-8",
        )
        temporary.replace(self.path)
