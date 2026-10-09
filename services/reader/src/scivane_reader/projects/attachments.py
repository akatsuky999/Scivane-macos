"""Images attached to chat messages, stored once by content.

    .lumen/attachments/<sha256>.<ext>

The conversation log names an image by its hash and the bytes live here, so logs stay small
(the conversation list reads every log) and a history replays to exactly the bytes the model saw:
the hash is checked on the way out. Control plane: the agent can neither read nor replace them.
"""

from __future__ import annotations

import base64
import hashlib
import logging
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .. import config
from ..i18n import ui
from ..llm.types import ContentBlock, ImageBlock, TextBlock

__all__ = ["ATTACHMENTS_DIR", "AttachmentError", "ImageRecord", "AttachmentStore", "sniff", "dimensions"]

logger = logging.getLogger("scivane.projects.attachments")

ATTACHMENTS_DIR = "attachments"
#: what providers accept on the long edge
MAX_EDGE = 8000

_FORMATS = (
    (b"\x89PNG\r\n\x1a\n", "image/png", "png"),
    (b"\xff\xd8\xff", "image/jpeg", "jpg"),
    (b"GIF87a", "image/gif", "gif"),
    (b"GIF89a", "image/gif", "gif"),
)
_EXTENSIONS = {"image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"}


class AttachmentError(Exception):
    """An attachment was refused; the stable code picks the HTTP status."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class ImageRecord:
    """What the log keeps of an image: enough to find, check and lay it out, never the bytes."""

    sha256: str
    media_type: str
    bytes: int
    width: int | None = None
    height: int | None = None

    @property
    def filename(self) -> str:
        return f"{self.sha256}.{_EXTENSIONS[self.media_type]}"

    def as_dict(self) -> dict[str, Any]:
        found: dict[str, Any] = {"sha256": self.sha256, "media_type": self.media_type, "bytes": self.bytes}
        if self.width and self.height:
            found.update(width=self.width, height=self.height)
        return found

    @staticmethod
    def from_dict(raw: object) -> ImageRecord | None:
        """None for anything malformed: a damaged log entry must not break the whole history."""
        if not isinstance(raw, dict):
            return None
        sha, media = raw.get("sha256"), raw.get("media_type")
        if (not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha)
                or media not in _EXTENSIONS):
            return None
        size = raw.get("bytes")
        width, height = raw.get("width"), raw.get("height")
        return ImageRecord(
            sha, media, size if isinstance(size, int) else 0,
            width if isinstance(width, int) else None, height if isinstance(height, int) else None)


def sniff(data: bytes) -> str | None:
    """Media type from the magic bytes; the declared type is never trusted."""
    for magic, media, _ in _FORMATS:
        if data.startswith(magic):
            return media
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def dimensions(data: bytes, media_type: str) -> tuple[int, int] | None:
    """Width and height from the file header, or None when the header can't be read."""
    try:
        if media_type == "image/png":
            return struct.unpack(">II", data[16:24])
        if media_type == "image/gif":
            return struct.unpack("<HH", data[6:10])
        if media_type == "image/webp":
            return _webp_size(data)
        if media_type == "image/jpeg":
            return _jpeg_size(data)
    except struct.error:
        return None
    return None


def _jpeg_size(data: bytes) -> tuple[int, int] | None:
    position = 2
    while position + 9 < len(data):
        if data[position] != 0xFF:
            position += 1
            continue
        marker = data[position + 1]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            height, width = struct.unpack(">HH", data[position + 5:position + 9])
            return width, height
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            position += 2
            continue
        position += 2 + struct.unpack(">H", data[position + 2:position + 4])[0]
    return None


def _webp_size(data: bytes) -> tuple[int, int] | None:
    chunk = data[12:16]
    if chunk == b"VP8X":
        width = int.from_bytes(data[24:27], "little") + 1
        height = int.from_bytes(data[27:30], "little") + 1
        return width, height
    if chunk == b"VP8 ":
        width, height = struct.unpack("<HH", data[26:30])
        return width & 0x3FFF, height & 0x3FFF
    if chunk == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    return None


class AttachmentStore:
    def __init__(self, root: Path) -> None:
        self.root = root

    def put(self, data: bytes) -> ImageRecord:
        """Store an image (once per content) and describe it. Raises AttachmentError for anything
        that isn't a PNG, JPEG, GIF or WebP within the size limits.
        """
        media = sniff(data)
        if media is None:
            raise AttachmentError(ui("只收 PNG、JPEG、GIF、WebP 图片", "Only PNG, JPEG, GIF and WebP images are accepted"),
                                  "UNSUPPORTED_IMAGE")
        if len(data) > config.CHAT_IMAGE_MAX_BYTES:
            raise AttachmentError(
                ui(f"图片太大（{len(data) / 1e6:.1f} MB），上限 {config.CHAT_IMAGE_MAX_BYTES / 1e6:.2f} MB",
                   f"Image too large ({len(data) / 1e6:.1f} MB); the limit is "
                   f"{config.CHAT_IMAGE_MAX_BYTES / 1e6:.2f} MB"),
                "IMAGE_TOO_LARGE")
        size = dimensions(data, media)
        if size is not None and max(size) > MAX_EDGE:
            raise AttachmentError(
                ui(f"图片太大（{size[0]}×{size[1]}），长边上限 {MAX_EDGE}",
                   f"Image too large ({size[0]}×{size[1]}); the long edge is limited to {MAX_EDGE}"),
                "IMAGE_TOO_LARGE")
        record = ImageRecord(
            hashlib.sha256(data).hexdigest(), media, len(data),
            size[0] if size else None, size[1] if size else None)
        target = self.root / record.filename
        if not target.is_file():
            self.root.mkdir(parents=True, exist_ok=True)
            staging = target.with_suffix(target.suffix + ".writing")
            staging.write_bytes(data)
            staging.replace(target)
        return record

    def path(self, record: ImageRecord) -> Path:
        return self.root / record.filename

    def load(self, record: ImageRecord) -> bytes | None:
        """The bytes, or None when the file is gone or no longer matches its hash."""
        try:
            data = self.path(record).read_bytes()
        except OSError:
            return None
        if hashlib.sha256(data).hexdigest() != record.sha256:
            logger.warning("附件内容与哈希不符：%s", record.sha256[:12])
            return None
        return data

    def block(self, record: ImageRecord) -> ContentBlock:
        """What the model sees: the image, or a fixed note when its bytes are gone. Deterministic
        either way, so a replayed history keeps the same bytes and the prompt cache still hits.
        """
        data = self.load(record)
        if data is None:
            return TextBlock(f"[image unavailable: {record.sha256[:12]}]")
        return ImageBlock(data=base64.b64encode(data).decode("ascii"), media_type=record.media_type)

    def collect(self, keep: set[str]) -> int:
        """Delete stored images whose hash is not in `keep`; returns how many went."""
        if not self.root.is_dir():
            return 0
        removed = 0
        for entry in self.root.iterdir():
            if entry.is_file() and entry.name.split(".")[0] not in keep:
                entry.unlink(missing_ok=True)
                removed += 1
        return removed
