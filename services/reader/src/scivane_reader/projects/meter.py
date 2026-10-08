"""How full the context is: the next request estimated by part, calibrated with the
provider-reported input.

It measures one request, not the turn total: a turn resends the context at every step, and that
sum is cost, not window use. Each part is estimated with llm/estimate.py and multiplied by one
calibration ratio (last reported input / its estimate), so the parts still add up to the total.
Without a report the ratio is 1 and the UI marks the value as approximate. Only numbers are logged.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable

from ..llm.estimate import RequestEstimate
from .model import ProjectEvent

__all__ = ["PARTS", "RATIO_RANGE", "ContextReport", "calibration", "ratio_of", "measure"]

#: Parts in request order; the UI draws them in this order.
PARTS = ("system", "tools", "paper", "summary", "history", "turn")

#: Ratios outside this range mean the provider reported something odd; ignore them.
RATIO_RANGE = (0.4, 2.5)


def ratio_of(prompt_tokens: int, estimate: int) -> float | None:
    """Calibration ratio for one request; None when either side is missing."""
    if prompt_tokens <= 0 or estimate <= 0:
        return None
    low, high = RATIO_RANGE
    return min(high, max(low, prompt_tokens / estimate))


def calibration(events: Iterable[dict[str, Any]]) -> float | None:
    """Latest calibration ratio from the log, or None."""
    found: float | None = None
    for event in events:
        if not isinstance(event, dict) or event.get("type") != ProjectEvent.ASSISTANT_MESSAGE:
            continue
        data = event.get("data") if isinstance(event.get("data"), dict) else {}
        usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
        prompt = usage.get("prompt_tokens")
        estimate = data.get("estimate")
        if isinstance(prompt, int) and isinstance(estimate, int):
            ratio = ratio_of(prompt, estimate)
            if ratio is not None:
                found = ratio
    return found


@dataclass(frozen=True)
class ContextReport:
    """Context usage of one request (or the forecast before the next one).
    as_dict() field names are read by the Swift client.
    """

    #: calibrated total (tokens)
    used: int
    #: calibrated parts, keyed by PARTS
    parts: dict[str, int] = field(default_factory=dict)
    #: hand-filled or detected window; None when unknown (never guessed)
    window: int | None = None
    #: auto-compaction threshold; none without a window
    threshold: int | None = None
    #: calibrated against a provider report; otherwise the UI marks it approximate
    measured: bool = False
    #: turns in this conversation, including the one in progress
    turns: int = 0
    #: last turn covered by the summary (0 = never compacted)
    covered: int = 0
    compactions: int = 0
    #: True for a request being sent (includes this turn); False for the forecast before the next question
    live: bool = False

    def as_dict(self) -> dict[str, object]:
        return {
            "used": self.used,
            "parts": {key: self.parts.get(key, 0) for key in PARTS},
            "window": self.window,
            "threshold": self.threshold,
            "measured": self.measured,
            "turns": self.turns,
            "covered": self.covered,
            "compactions": self.compactions,
            "live": self.live,
        }


def measure(
    estimate: RequestEstimate,
    *,
    has_summary: bool,
    turn_start: int,
    ratio: float | None,
    window: int | None,
    threshold: int | None,
    turns: int,
    covered: int,
    compactions: int,
    live: bool,
) -> ContextReport:
    """Split a request estimate into parts, calibrate, and report.

    Messages are laid out as [paper, (summary), past turns..., this question, this turn's steps...]
    (context.assemble). turn_start indexes this question; for the forecast it equals the count.
    """
    count = len(estimate.messages)
    history_start = 2 if has_summary else 1
    turn_start = max(history_start, min(turn_start, count))
    raw = {
        "system": estimate.system,
        "tools": estimate.tools,
        "paper": estimate.messages[0] if count else 0,
        "summary": estimate.messages[1] if has_summary and count > 1 else 0,
        "history": estimate.span(history_start, turn_start),
        "turn": estimate.span(turn_start),
    }
    scale = ratio if ratio is not None else 1.0
    parts = {key: round(value * scale) for key, value in raw.items()}
    return ContextReport(
        used=sum(parts.values()),
        parts=parts,
        window=window,
        threshold=threshold,
        measured=ratio is not None,
        turns=turns,
        covered=covered,
        compactions=compactions,
        live=live,
    )
