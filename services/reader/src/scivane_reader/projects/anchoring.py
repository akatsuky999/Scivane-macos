"""Locate text marked on the source PDF in the paper's Markdown.

A mark's text comes from the PDF's text layer and the paper text from OCR, so the two seldom agree
character for character: line-break hyphens, ligatures, Unicode maths against LaTeX, HTML around
tables, a selection that starts mid-word. Both sides are reduced to a key of case-folded letters
and digits that maps back to Markdown offsets. An exact key match is the usual case; repeated text
is told apart by the words around the mark on its page, and a seed-and-vote search finds passages
the OCR got slightly wrong. Pure text: no PDF, no model.
"""

from __future__ import annotations

import bisect
import functools
import html
import math
import re
import unicodedata
from array import array
from dataclasses import dataclass
from typing import Literal

__all__ = ["Anchor", "PaperIndex", "Surroundings", "fold", "surroundings"]

#: Places a key may occur before it stops being worth listing.
MAX_HITS = 50
#: Key characters of context taken on each side of a mark on its page.
CONTEXT = 48
#: Context characters that must agree before one of several identical passages is chosen.
MIN_CONTEXT = 6
#: Seed length for the approximate search; shorter seeds recur by chance in a long paper.
SEED = 8
MAX_SEEDS = 24
#: A seed found in more places than this says nothing about where the mark is.
MAX_SEED_HITS = 12
#: Seeds that must line up for an approximate location: at least half, and never fewer than three,
#: or a short figure label lands wherever two of its words happen to recur.
MIN_AGREEMENT = 0.5
MIN_AGREEING_SEEDS = 3

#: An ASCII run of letters and digits, or one non-ASCII character.
_FOLDABLE = re.compile(r"[A-Za-z0-9]+|[^\x00-\x7f]")

#: Inline maths stays on one line, so a lone dollar sign in prose can't swallow a paragraph.
_MATH = re.compile(
    r"\$\$.+?\$\$"
    r"|\\\[.+?\\\]"
    r"|\\\([^\n]+?\\\)"
    r"|\\begin\{([A-Za-z]+\*?)\}.+?\\end\{\1\}"
    r"|(?<!\\)\$[^$\n]+?(?<!\\)\$",
    re.DOTALL,
)
#: Prose markup that prints no letters of its own, except entities and commands, which are mapped.
_TEXT_MARKUP = re.compile(
    r"<[A-Za-z/!][^<>\n]*>"
    r"|&(?:[A-Za-z]+|#\d+|#[xX][0-9A-Fa-f]+);"
    r"|!\[[^\]\n]*\]\([^)\n]*\)"
    r"|\]\([^)\n]*\)"
    r"|\\(?:begin|end)\{[^}\n]*\}"
    r"|\\[A-Za-z]+|\\."
)
#: Inside maths only commands count: < and > are relations there, not tags.
_MATH_MARKUP = re.compile(r"\\(?:begin|end)\{[^}]*\}|\\[A-Za-z]+|\\.")
_HEADING = re.compile(r"^#{1,6}[ \t]+(.+?)[ \t#]*$", re.MULTILINE)
_TAG = re.compile(r"<[^<>\n]*>")

#: Control words that print letters. The PDF shows the glyph; compatibility decomposition already
#: turns its variants (ϑ, ϵ, ϕ, ℓ) into these.
_PRINTS = {
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
    "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "θ", "iota": "ι", "kappa": "κ",
    "varkappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π",
    "varpi": "π", "rho": "ρ", "varrho": "ρ", "sigma": "σ", "varsigma": "σ", "tau": "τ",
    "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
    "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
    "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    "ell": "l", "imath": "i", "jmath": "j", "bmod": "mod", "pmod": "mod",
    **{name: name for name in (
        "arccos arcsin arctan arg cos cosh cot coth csc deg det dim exp gcd hom inf ker lg lim "
        "liminf limsup ln log max min mod Pr sec sin sinh sup tan tanh"
    ).split()},
}

#: Symbols PDFs use to print a Greek letter that LaTeX writes as the letter.
_LETTER_SYMBOLS = {"\N{INCREMENT}": "\N{GREEK SMALL LETTER DELTA}"}

Status = Literal["exact", "approximate", "ambiguous", "missing"]


@functools.cache
def _fold_char(char: str) -> str:
    """The letters and digits one non-ASCII character contributes. Compatibility decomposition makes
    ligatures, maths alphanumerics and superscripts plain letters; accents fall away as marks, and
    modifier letters too: a PDF prints \\hat as a spacing ˆ that LaTeX never spells out."""
    decomposed = unicodedata.normalize("NFKD", _LETTER_SYMBOLS.get(char, char)).casefold()
    return "".join(c for c in decomposed if c.isalnum() and unicodedata.category(c) != "Lm")


def _is_cjk(char: str) -> bool:
    code = ord(char)
    return (0x2E80 <= code <= 0x9FFF or 0xAC00 <= code <= 0xD7AF
            or 0xF900 <= code <= 0xFAFF or 0x20000 <= code <= 0x3FFFF)


def _is_word(char: str) -> bool:
    # CJK runs have no spaces, so widening over them would swallow the rest of the clause
    return char.isalnum() and not _is_cjk(char)


class _Key:
    """A key under construction: folded characters, each with the source span it came from."""

    def __init__(self) -> None:
        self._parts: list[str] = []
        self.starts = array("q")
        self.ends = array("q")

    def text(self, text: str, base: int) -> None:
        for match in _FOLDABLE.finditer(text):
            piece = match.group()
            start = base + match.start()
            if piece[0] < "\x80":
                self._parts.append(piece.lower())
                self.starts.extend(range(start, start + len(piece)))
                self.ends.extend(range(start + 1, start + len(piece) + 1))
            else:
                self.token(_fold_char(piece), start, start + 1)

    def token(self, folded: str, start: int, end: int) -> None:
        """Characters that stand for the whole source span [start, end), such as α for \\alpha."""
        if folded:
            self._parts.append(folded)
            self.starts.extend([start] * len(folded))
            self.ends.extend([end] * len(folded))

    def build(self) -> str:
        return "".join(self._parts)


def fold(text: str) -> str:
    """The comparison key of plain text: a mark's text, or a page of the source PDF."""
    key = _Key()
    key.text(text, 0)
    return key.build()


def _markup(key: _Key, source: str, start: int, end: int, pattern: re.Pattern[str]) -> None:
    position = start
    for match in pattern.finditer(source, start, end):
        key.text(source[position:match.start()], position)
        token = match.group()
        if token[0] == "&":
            key.token(fold(html.unescape(token)), match.start(), match.end())
        elif token[0] == "\\":
            # environments, fonts, spacing and symbols print no letters; tags and links never do
            key.token(fold(_PRINTS.get(token[1:], "")), match.start(), match.end())
        position = match.end()
    key.text(source[position:end], position)


@dataclass(frozen=True)
class Surroundings:
    """The words on either side of a mark on its page, as keys."""

    before: str
    after: str


def surroundings(page_text: str, quote: str) -> Surroundings | None:
    """What surrounds `quote` in `page_text`; None unless it occurs there exactly once, since
    otherwise nothing says which occurrence the mark is."""
    page, needle = fold(page_text), fold(quote)
    if not needle:
        return None
    at = page.find(needle)
    if at == -1 or page.find(needle, at + 1) != -1:
        return None
    end = at + len(needle)
    return Surroundings(page[max(0, at - CONTEXT):at], page[end:end + CONTEXT])


@dataclass(frozen=True)
class Anchor:
    """Where a mark sits in the paper text.

    exact        found once, or told apart from its repeats by what surrounds it
    approximate  most of it found in one place; the OCR text differs here and there
    ambiguous    found `count` times and nothing says which (count stops at MAX_HITS), or,
                 with count 0, several places resemble it equally
    missing      not in the paper text: formulas, tables, or text the OCR lost

    start/end are Markdown offsets, widened to whole words and formulas; lines count from 1.
    """

    status: Status
    start: int = 0
    end: int = 0
    first_line: int = 0
    last_line: int = 0
    heading: str = ""
    count: int = 0

    @property
    def located(self) -> bool:
        return self.status in ("exact", "approximate")


class PaperIndex:
    """The paper's Markdown keyed for matching. Building it is the expensive part; build once per
    listing, then locate() each mark."""

    def __init__(self, markdown: str) -> None:
        self.markdown = markdown
        key = _Key()
        maths: list[tuple[int, int]] = []
        position = 0
        for match in _MATH.finditer(markdown):
            _markup(key, markdown, position, match.start(), _TEXT_MARKUP)
            _markup(key, markdown, match.start(), match.end(), _MATH_MARKUP)
            maths.append((match.start(), match.end()))
            position = match.end()
        _markup(key, markdown, position, len(markdown), _TEXT_MARKUP)
        self._key = key.build()
        self._starts = key.starts
        self._ends = key.ends
        self._maths = maths
        self._math_starts = [start for start, _ in maths]
        self._lines = [0] + [match.end() for match in re.finditer(r"\n", markdown)]
        headings = [(match.start(), _title(match.group(1))) for match in _HEADING.finditer(markdown)
                    if self._math_around(match.start()) is None]
        self._heading_offsets = [offset for offset, _ in headings]
        self._heading_titles = [title for _, title in headings]

    def locate(self, quote: str, around: Surroundings | None = None) -> Anchor:
        needle = fold(quote)
        if not needle:
            return Anchor("missing")
        hits = self._find(needle, MAX_HITS)
        if len(hits) == 1:
            return self._anchor("exact", hits[0], hits[0] + len(needle), count=1)
        if hits:
            chosen = self._choose(hits, len(needle), around) if around else None
            if chosen is None:
                return Anchor("ambiguous", count=len(hits))
            return self._anchor("exact", chosen, chosen + len(needle), count=len(hits))
        voted = self._vote(needle)
        if voted == "ambiguous":
            return Anchor("ambiguous")
        if voted is None:
            return Anchor("missing")
        return self._anchor("approximate", *voted)

    def excerpt(self, anchor: Anchor) -> str:
        """The located passage as one line, LaTeX and all."""
        return " ".join(self.markdown[anchor.start:anchor.end].split())

    # MARK: matching

    def _find(self, needle: str, limit: int) -> list[int]:
        hits: list[int] = []
        at = self._key.find(needle)
        while at != -1 and len(hits) < limit:
            hits.append(at)
            at = self._key.find(needle, at + 1)
        return hits

    def _choose(self, hits: list[int], length: int, around: Surroundings) -> int | None:
        best, winners = 0, []
        for hit in hits:
            score = (_common_suffix(self._key, hit, around.before)
                     + _common_prefix(self._key, hit + length, around.after))
            if score > best:
                best, winners = score, [hit]
            elif score == best:
                winners.append(hit)
        return winners[0] if best >= MIN_CONTEXT and len(winners) == 1 else None

    def _vote(self, needle: str) -> tuple[int, int] | Literal["ambiguous"] | None:
        """Seeds of the mark found in the paper vote for an alignment; insertions and deletions in
        the OCR text shift it a little, so votes within a tolerance count together."""
        length = len(needle)
        offsets = list(range(0, length - SEED + 1, SEED))
        if len(offsets) < MIN_AGREEING_SEEDS:
            return None
        if len(offsets) > MAX_SEEDS:
            step = len(offsets) / MAX_SEEDS
            offsets = [offsets[int(i * step)] for i in range(MAX_SEEDS)]
        votes: list[tuple[int, int, int]] = []
        for offset in offsets:
            hits = self._find(needle[offset:offset + SEED], MAX_SEED_HITS + 1)
            if len(hits) <= MAX_SEED_HITS:
                votes.extend((hit - offset, offset, hit) for hit in hits)
        if not votes:
            return None
        votes.sort()
        tolerance = max(SEED, length // 8)
        windows = []
        for i, (diagonal, _, _) in enumerate(votes):
            window = [vote for vote in votes[i:] if vote[0] - diagonal <= tolerance]
            windows.append((len({offset for _, offset, _ in window}), diagonal, window))
        windows.sort(key=lambda item: (-item[0], item[1]))
        agreeing, diagonal, window = windows[0]
        if agreeing < max(MIN_AGREEING_SEEDS, math.ceil(MIN_AGREEMENT * len(offsets))):
            return None
        if any(count == agreeing and abs(other - diagonal) > tolerance
               for count, other, _ in windows[1:]):
            return "ambiguous"
        seeds: dict[int, int] = {}
        for _, offset, hit in window:
            seeds.setdefault(offset, hit)
        first, last = min(seeds), max(seeds)
        start = max(0, seeds[first] - first)
        end = min(len(self._key), seeds[last] + length - last)
        return start, end

    # MARK: reporting

    def _anchor(self, status: Status, key_start: int, key_end: int, *, count: int = 0) -> Anchor:
        start, end = self._widen(self._starts[key_start], self._ends[key_end - 1])
        return Anchor(
            status, start, end,
            first_line=bisect.bisect_right(self._lines, start),
            last_line=bisect.bisect_right(self._lines, end - 1),
            heading=self._heading_before(start),
            count=count,
        )

    def _widen(self, start: int, end: int) -> tuple[int, int]:
        """Whole words and whole formulas: a selection often starts or ends mid-word, and half a
        formula is not LaTeX."""
        text = self.markdown
        while start > 0 and _is_word(text[start - 1]):
            start -= 1
        while end < len(text) and _is_word(text[end]):
            end += 1
        opening = self._math_around(start)
        if opening is not None:
            start = opening[0]
        closing = self._math_around(end - 1)
        if closing is not None:
            end = closing[1]
        return start, end

    def _math_around(self, offset: int) -> tuple[int, int] | None:
        """The formula strictly containing `offset`, if any."""
        i = bisect.bisect_right(self._math_starts, offset) - 1
        if i >= 0 and self._maths[i][0] < offset < self._maths[i][1] - 1:
            return self._maths[i]
        return None

    def _heading_before(self, offset: int) -> str:
        i = bisect.bisect_right(self._heading_offsets, offset) - 1
        return self._heading_titles[i] if i >= 0 else ""


def _common_suffix(key: str, end: int, before: str) -> int:
    count = 0
    while count < len(before) and count < end and key[end - 1 - count] == before[-1 - count]:
        count += 1
    return count


def _common_prefix(key: str, start: int, after: str) -> int:
    count = 0
    while count < len(after) and start + count < len(key) and key[start + count] == after[count]:
        count += 1
    return count


def _title(heading: str) -> str:
    title = " ".join(_TAG.sub("", heading).split())
    return title if len(title) <= 80 else title[:79] + "…"
