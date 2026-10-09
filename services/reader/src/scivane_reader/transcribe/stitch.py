"""From page transcriptions to one paper. Pure text, no model.

Each page is transcribed on its own, so a paragraph broken by the page boundary comes back as
two, heading levels are only as consistent as each page's guess, and a running header the model
failed to drop repeats on every page. All three are repaired here, deterministically.
"""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import dataclass

from .prompt import BLANK, FOOTNOTES

__all__ = ["PageText", "clean", "parse", "page_markdown", "join", "normalise_headings", "blocks"]

_FENCE = re.compile(r"^\s*```[\w+-]*\s*\n(.*)\n\s*```\s*$", re.S)
_MARKER = re.compile(r"\[\[\s*fig\s*:\s*(\d+)\s*\]\]", re.I)
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
#: "3 Method", "3.2. Loss", "A.1 Proofs", "IV. Experiments": the numbering decides the level
_NUMBERED = re.compile(r"^(?:(\d+(?:\.\d+)*)|([A-Z]\.\d+(?:\.\d+)*))\.?\s+\S")
_ROMAN = re.compile(r"^[IVX]+\.\s+\S")
_TERMINAL = set(".!?。！？…:：")
_CLOSERS = "\"'”’)]）】*_"
_NOT_PARAGRAPH = re.compile(r"^(?:#|\||<|\$\$|!\[|```|>|[-*+]\s|\d+[.)]\s|\\\[)")
_CAPTION_START = re.compile(r"^(?:\*\*)?(?:fig(?:ure)?s?\.?|tab(?:le)?s?\.?|图|表)\s*\S", re.I)
_CJK = re.compile(r"[㐀-鿿豈-﫿]")
#: A block that is only a page number: "12", "- 12 -", "Page 3 of 12", "3 / 12", "第 3 页", "xii".
_PAGE_NUMBER = re.compile(
    r"^[\s\-–—|·•.(\[]*(?:page\s*|p\.\s*|第\s*)?"
    r"(?:\d{1,4}|(?=[ivx])x{0,3}(?:ix|iv|v?i{0,3}))"
    r"(?:\s*(?:/|of)\s*\d{1,4})?\s*页?[\s\-–—|·•.)\]]*$",
    re.I,
)


@dataclass(frozen=True)
class PageText:
    index: int
    body: str
    footnotes: str = ""
    blank: bool = False


def clean(raw: str) -> str:
    """Unwrap a code fence around the whole answer and normalise line breaks."""
    text = raw.replace("\r\n", "\n").replace("\r", "\n").strip()
    fenced = _FENCE.match(text)
    if fenced is not None and _wrapper(text.split("\n", 1)[0]) and _balanced(fenced.group(1)):
        text = fenced.group(1).strip()
    return text


def _wrapper(opening: str) -> bool:
    """```markdown or a bare ```: a wrapper. ```python opens a listing that happens to start the page."""
    return opening.strip().lstrip("`").strip().lower() in ("", "markdown", "md", "text")


def _balanced(inner: str) -> bool:
    """Fences inside alternate open and close, and no close carries a language: otherwise the outer
    pair were two separate code blocks, one at each end of the page.
    """
    opened = False
    for line in inner.split("\n"):
        stripped = line.strip()
        if not stripped.startswith("```"):
            continue
        if opened and stripped != "```":
            return False
        opened = not opened
    return not opened


def parse(raw: str, index: int, figures: Mapping[int, str]) -> PageText:
    """One page's answer split into body and footnotes, with figure markers replaced by `figures`
    (marker number -> Markdown image). Markers that name no detected figure are dropped.
    """
    text = clean(raw)
    if not text.replace(BLANK, "").strip():
        return PageText(index, "", blank=True)
    text = text.replace(BLANK, "")
    body, _, notes = text.partition(FOOTNOTES)

    def place(match: re.Match[str]) -> str:
        image = figures.get(int(match.group(1)))
        return f"\n\n{image}\n\n" if image else ""

    body = _MARKER.sub(place, body)
    return PageText(index, _tidy(body), _tidy(notes))


def page_markdown(page: PageText) -> str:
    """One page as shown while the paper is being transcribed."""
    if page.blank:
        return ""
    text = normalise_headings("\n\n".join(_without_page_numbers(blocks(page.body))))
    return f"{text}\n\n{page.footnotes}".strip() if page.footnotes else text


def join(pages: Sequence[PageText]) -> str:
    """The pages as one document: running headers and footers removed, paragraphs split by a page
    break rejoined, footnotes kept after the paragraph that straddles the break, headings levelled.
    """
    present = [page for page in pages if not page.blank]
    # page numbers first: a running footer sits above the number, and is only found once it is last
    split = [_without_page_numbers(blocks(page.body)) for page in present]
    repeated_first, repeated_last = _running(split)

    out: list[str] = []
    held: list[str] = []
    for page, parts in zip(present, split):
        if parts and _key(parts[0]) in repeated_first:
            parts = parts[1:]
        if parts and _key(parts[-1]) in repeated_last:
            parts = parts[:-1]
        if parts and out and _continues(out[-1], parts[0]):
            out[-1] = _glue(out[-1], parts[0])
            parts = parts[1:]
        out.extend(held)
        out.extend(parts)
        held = _without_page_numbers(blocks(page.footnotes)) if page.footnotes else []
    out.extend(held)
    return normalise_headings("\n\n".join(out))


def blocks(text: str) -> list[str]:
    """Split at blank lines, never inside a code fence or display math."""
    found: list[str] = []
    current: list[str] = []
    fence = math = False
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.startswith("```"):
            fence = not fence
        elif not fence:
            if math:
                math = not stripped.endswith("$$")
            elif stripped.startswith("$$") and (stripped == "$$" or not stripped.endswith("$$")):
                math = True
        if not stripped and not fence and not math:
            if current:
                found.append("\n".join(current).strip())
                current = []
            continue
        current.append(line)
    if current:
        found.append("\n".join(current).strip())
    return [block for block in found if block]


def normalise_headings(markdown: str) -> str:
    """Level numbered headings by their numbering and keep a single title.

    Each page is transcribed alone, so "3.2 Loss" may come back as ## on one page and ### on
    another; the number settles it. Unnumbered headings keep the model's level, except that only
    the first # survives as the title.
    """
    lines = markdown.split("\n")
    fence = False
    titled = False
    for i, line in enumerate(lines):
        if line.strip().startswith("```"):
            fence = not fence
            continue
        match = None if fence else _HEADING.match(line)
        if match is None:
            continue
        hashes, text = match.groups()
        level = len(hashes)
        numbered = _NUMBERED.match(text)
        if numbered is not None:
            number = numbered.group(1) or numbered.group(2)
            level = min(6, number.count(".") + 2)
        elif _ROMAN.match(text):
            level = 2
        elif level == 1:
            if titled:
                level = 2
            titled = True
        lines[i] = f"{'#' * level} {text}"
    return "\n".join(lines)


def _tidy(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def _without_page_numbers(parts: list[str]) -> list[str]:
    """Page numbers dropped at either edge of a page. Models are told to leave them out, but one
    left in sits between the halves of a paragraph broken by the page: the join then glues the
    number to the next page instead. _running can't catch these: with the digits gone, the key is
    empty.
    """
    start, end = 0, len(parts)
    while start < end and _PAGE_NUMBER.match(parts[start]):
        start += 1
    while end > start and _PAGE_NUMBER.match(parts[end - 1]):
        end -= 1
    return parts[start:end]


def _key(block: str) -> str:
    """A running header or footer seen on several pages, page number aside."""
    return re.sub(r"[\d\s#*_|]+", " ", block).strip().lower()


def _running(split: list[list[str]]) -> tuple[set[str], set[str]]:
    """First and last blocks that recur on at least three pages and a third of them."""
    if len(split) < 3:
        return set(), set()
    threshold = max(3, len(split) // 3)

    def recurring(picks: list[str]) -> set[str]:
        counts = Counter(_key(block) for block in picks if len(block) <= 160)
        return {key for key, count in counts.items() if key and count >= threshold}

    return (recurring([parts[0] for parts in split if parts]),
            recurring([parts[-1] for parts in split if parts]))


def _continues(previous: str, following: str) -> bool:
    """Whether `following` (first block of a page) finishes the paragraph `previous` (last block of
    the page before). Only plain paragraphs, never captions; the previous one must stop without
    final punctuation, and the next must start like a sentence continues.
    """
    if _NOT_PARAGRAPH.match(previous) or _NOT_PARAGRAPH.match(following):
        return False
    if _CAPTION_START.match(previous):
        return False
    end = previous.rstrip().rstrip(_CLOSERS)
    if not end or end[-1] in _TERMINAL:
        return False
    first = following.lstrip()[:1]
    return (first.islower() or first.isdigit() or bool(_CJK.match(first))
            or first in ",;:)]，；：）" or end[-1] in "-–—,(")


def _glue(previous: str, following: str) -> str:
    head = previous.rstrip()
    tail = following.lstrip()
    if head.endswith("-") and len(head) > 1 and head[-2].isalpha() and tail[:1].islower():
        return head[:-1] + tail  # a word hyphenated across the page break
    if _CJK.match(head[-1:]) or _CJK.match(tail[:1]):
        return head + tail
    return f"{head} {tail}"
