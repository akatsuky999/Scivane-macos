"""What reasoning budget an endpoint accepts, and which of ours to send it.

Every vendor spells its own scale. OpenAI and OpenRouter take low/medium/high, xAI only low/high,
and self-hosted gateways add words of their own or an integer range. Nothing declares it: no model
listing carries the scale. But a server that refuses a value says what it would accept instead, so
the refusal is the declaration -- one round trip, once per endpoint, then it is remembered.

Keeping a table of who accepts what was the alternative, and it is wrong the day a gateway changes
its mind. This reads the server's own answer instead, and falls back to sending no budget at all
when the answer can't be read.

Pure: no HTTP, no files. The registry does the asking and the caching.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

#: Where each word sits on a 0..100 effort axis. Our own four levels are in here too, which is
#: what lets a neutral level be matched against a vocabulary that has never heard of it.
#: Integers, not fractions: medium is exactly as far from low as from high, and that tie is
#: decided by the rule below rather than by which subtraction rounds better in binary.
EFFORT: dict[str, int] = {
    "none": 0, "off": 0, "disable": 0, "disabled": 0, "never": 0,
    "minimal": 15, "lowest": 20,
    "low": 30, "fast": 30,
    "medium": 55, "balanced": 55, "normal": 55, "auto": 55,
    "high": 80, "thorough": 80,
    "xhigh": 90, "very_high": 90, "veryhigh": 90,
    "max": 100, "maximum": 100, "highest": 100,
}

#: Position of our own levels when the endpoint's words mean nothing to us: lowest, lowest, middle,
#: highest of whatever it listed.
_POSITION = {"none": 0.0, "low": 0.0, "medium": 0.5, "high": 1.0}

#: A refusal tells us about this endpoint, not about the vendor in general, and a server can be
#: reconfigured. Same week-long life as a vision verdict.
TTL = 7 * 24 * 3600.0

#: Everything after one of these is the server listing what it would have taken.
_CUE = re.compile(
    # \b matters: without it "Unsupported value" matches the "supported value" cue and the scan
    # starts before the field name and the rejected value instead of after them.
    r"\b(?:should be|shall be|must be|has to be|expected(?:\s*:)?|one of|any of"
    r"|supported values?(?:\s+are)?|allowed values?|valid values?|choose from)\b(?P<tail>.*)",
    re.IGNORECASE | re.DOTALL,
)
#: Only quoted words count. Every server we have seen quotes the list it offers, and taking bare
#: words would pick up the model name and the value being rejected.
_WORD = re.compile(r"['\"`]([A-Za-z][A-Za-z0-9_-]{0,19})['\"`]")
_SPAN = re.compile(r"(\d{1,7})\s*(?:,|-|–|\.\.|\bto\b|\band\b)\s*(\d{1,7})")
#: Quoted in the same sentence, but naming the field rather than a value it would take.
_NOT_A_VALUE = {"reasoning", "reasoning_effort", "reasoningeffort", "effort", "thinking",
                "thinking_budget", "reasoning_budget", "budget", "int", "integer", "string"}


@dataclass(frozen=True)
class Vocabulary:
    """What one endpoint accepts as a reasoning budget.

    `words` keeps the server's own order. `span` is an inclusive integer range. Neither, with
    `takes_budget` false, means the field has to go away entirely.
    """

    words: tuple[str, ...] = ()
    span: tuple[int, int] | None = None
    takes_budget: bool = True

    @property
    def known(self) -> bool:
        return bool(self.words or self.span) or not self.takes_budget

    def as_dict(self) -> dict[str, object]:
        return {"words": list(self.words), "span": list(self.span) if self.span else None,
                "takes_budget": self.takes_budget}

    @classmethod
    def from_dict(cls, raw: object) -> "Vocabulary | None":
        if not isinstance(raw, dict):
            return None
        words = raw.get("words")
        span = raw.get("span")
        try:
            return cls(
                words=tuple(str(w) for w in words) if isinstance(words, list) else (),
                span=(int(span[0]), int(span[1])) if isinstance(span, list) and len(span) == 2 else None,
                takes_budget=bool(raw.get("takes_budget", True)),
            )
        except (TypeError, ValueError):
            return None


#: Nothing was learned; send what we always send.
UNKNOWN = Vocabulary(takes_budget=True)


def parse_vocabulary(detail: str) -> Vocabulary:
    """Read what the server says it accepts out of its refusal.

    Anchored on a cue phrase, so the value being rejected and the model's name -- which sit before
    it -- are never mistaken for an offer. Returns an unknown vocabulary when nothing parses, and
    the caller then stops sending a budget at all.
    """
    cue = _CUE.search(detail or "")
    if cue is None:
        return UNKNOWN
    tail = cue.group("tail")
    seen: list[str] = []
    for word in _WORD.findall(tail):
        if word.lower() in _NOT_A_VALUE:
            continue
        if word.lower() not in [w.lower() for w in seen]:
            seen.append(word)
    # Words beat a range: they are the scale the server documents, while an integer could be a
    # percentage or a token budget and we would be guessing which.
    if len(seen) >= 2:
        return Vocabulary(words=tuple(seen))
    span = _SPAN.search(tail)
    if span is not None:
        lo, hi = int(span.group(1)), int(span.group(2))
        if hi > lo:
            return Vocabulary(span=(lo, hi))
    return UNKNOWN


def choose(level: str | None, vocab: Vocabulary) -> str | int | None:
    """Our neutral level as this endpoint would say it. None means send no budget.

    A tie goes up, not down: our default is medium because the step below it is too weak for
    checking that formulas and code agree, and a budget quietly halved is harder to notice than
    one that costs a little more.
    """
    if not vocab.takes_budget or not level:
        return None
    if vocab.words:
        return _nearest(level, vocab.words)
    if vocab.span:
        lo, hi = vocab.span
        return lo + (EFFORT.get(level, 55) * (hi - lo) + 50) // 100
    return None


def _nearest(level: str, words: tuple[str, ...]) -> str:
    want = EFFORT.get(level)
    ranks = [EFFORT.get(word.lower()) for word in words]
    if want is not None and all(rank is not None for rank in ranks):
        # by meaning; -rank breaks a tie upwards
        return min(words, key=lambda w: (abs(EFFORT[w.lower()] - want), -EFFORT[w.lower()]))
    # The server's words mean nothing to us (fast / balanced / thorough and the like). Its order is
    # the only signal left, so spread our levels across it.
    fraction = _POSITION.get(level, 0.5)
    return words[int(fraction * (len(words) - 1) + 0.5)]
