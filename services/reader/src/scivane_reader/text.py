"""Small Markdown text helpers."""

from __future__ import annotations

import re

_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_HTML_TAG = re.compile(r"<[^>]+>")
_HEADING = re.compile(r"^#{1,6}\s*", re.MULTILINE)
_EMPHASIS = re.compile(r"(\*\*|__|\*|_|`)")
_BLANK_RUN = re.compile(r"\n{3,}")


def plain_text(markdown: str) -> str:
    """Strip Markdown markup for plain-text copy, keeping paragraph breaks."""
    text = _IMAGE.sub("", markdown)
    text = _LINK.sub(r"\1", text)
    text = _HTML_TAG.sub("", text)
    text = _HEADING.sub("", text)
    text = _EMPHASIS.sub("", text)
    text = _BLANK_RUN.sub("\n\n", text)
    return text.strip()
