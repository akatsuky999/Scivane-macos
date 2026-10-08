"""Paper title extraction.

A quick guess when the project is created (PDF metadata, else the largest text on page one),
refined after OCR (the first level-one heading). A later source only wins when it is more
reliable (better_than), so a failed OCR can't replace a correct guess with a sentence.
"""

from __future__ import annotations

import re
from pathlib import Path

from .model import TitleSource

#: higher ranks may overwrite lower ones
_RANK: dict[TitleSource, int] = {
    # below the file name: a placeholder isn't anyone's choice, so even the file stem beats it
    "placeholder": -1,
    "filename": 0,
    "pdf-metadata": 1,
    "pdf-heading": 2,
    "markdown-heading": 3,
    "manual": 4,   # typed by the user; no extraction may overwrite it
}

#: metadata that is obviously not a paper title; many PDFs carry converter junk here
_JUNK_TITLE = re.compile(
    r"^\s*$"
    r"|^(microsoft word|powerpoint presentation|untitled|document\d*|print)\b"
    r"|\.(docx?|pptx?|tex|pdf|indd)\s*$",
    re.IGNORECASE,
)

MAX_TITLE_CHARS = 300


#: Unknown sources rank below everything, placeholder included; a tie with placeholder would
#: make the placeholder impossible to replace.
_UNKNOWN_RANK = -99


def better_than(candidate: TitleSource, current: TitleSource) -> bool:
    return _RANK.get(candidate, _UNKNOWN_RANK) > _RANK.get(current, _UNKNOWN_RANK)


def clean(raw: str) -> str:
    """Normalise a candidate title; PDF titles often span lines with hyphenated breaks."""
    text = raw.replace("\r", "\n")
    # rejoin "Atten-\ntion" into "Attention"
    text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = text.strip(" \t\n·—-–_*#")
    return text[:MAX_TITLE_CHARS]


def is_plausible(text: str) -> bool:
    """Whether this looks like a title: too short is a header fragment, too long swallowed the abstract."""
    stripped = clean(text)
    if len(stripped) < 4 or len(stripped) > MAX_TITLE_CHARS:
        return False
    if _JUNK_TITLE.search(stripped):
        return False
    # digits and symbols only: a page number or DOI line
    return any(ch.isalpha() or "一" <= ch <= "鿿" for ch in stripped)


def from_filename(path: Path) -> tuple[str, TitleSource]:
    """Last resort: the file name without its extension. Always has a result."""
    return clean(path.stem) or path.name, "filename"


def from_pdf(path: Path) -> tuple[str, TitleSource] | None:
    """Quick guess from PDF metadata or the largest text on page one. No model, milliseconds.
    None when unreadable; the caller falls back to the file name.
    """
    try:
        import pymupdf
    except ImportError:
        return None

    try:
        with pymupdf.open(path) as doc:
            meta = doc.metadata or {}
            candidate = clean(str(meta.get("title") or ""))
            if is_plausible(candidate):
                return candidate, "pdf-metadata"

            if doc.page_count == 0:
                return None
            heading = _largest_heading(doc[0])
            if heading and is_plausible(heading):
                return clean(heading), "pdf-heading"
    except Exception:
        # encrypted, damaged or not a PDF: never a reason for project creation to fail
        return None
    return None


def _largest_heading(page) -> str | None:
    """Largest text on the upper half of page one, where titles sit; figure captions further down
    can be just as large.
    """
    try:
        blocks = page.get_text("dict")["blocks"]
    except Exception:
        return None

    height = page.rect.height or 1
    best_size = 0.0
    best_lines: list[tuple[float, str]] = []

    for block in blocks:
        for line in block.get("lines", []):
            spans = line.get("spans", [])
            if not spans:
                continue
            top = line.get("bbox", [0, 0, 0, 0])[1]
            if top > height * 0.5:
                continue
            size = max(float(s.get("size", 0)) for s in spans)
            text = "".join(s.get("text", "") for s in spans)
            if not text.strip():
                continue
            if size > best_size + 0.5:
                best_size = size
                best_lines = [(top, text)]
            elif abs(size - best_size) <= 0.5:
                # adjacent lines in the same size belong to one title
                best_lines.append((top, text))

    if not best_lines:
        return None
    best_lines.sort(key=lambda item: item[0])
    return "\n".join(text for _, text in best_lines)


_MD_HEADING = re.compile(r"^\s{0,3}#\s+(.+?)\s*#*\s*$", re.MULTILINE)


def from_markdown(markdown: str) -> tuple[str, TitleSource] | None:
    """Refinement: the first level-one heading, which the layout model already identified as a title."""
    match = _MD_HEADING.search(markdown)
    if match is None:
        return None
    candidate = clean(match.group(1))
    if not is_plausible(candidate):
        return None
    return candidate, "markdown-heading"
