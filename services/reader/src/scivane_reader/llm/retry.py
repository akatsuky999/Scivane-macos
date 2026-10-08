"""Timeouts, retries and backoff.

Retrying is only safe before any content was emitted; otherwise the user sees duplicated
text. That is why is_retryable() requires `emitted_content`.
"""

from __future__ import annotations

import email.utils
import random
from dataclasses import dataclass, field
from typing import Final

from .errors import (
    EMPTY_RESPONSE,
    RATE_LIMIT,
    SERVER,
    TIMEOUT,
    TRANSPORT,
    LlmFailure,
)
from .types import Purpose

@dataclass(frozen=True)
class Timeouts:
    """Separate timeouts: a total long enough for a multi-minute answer would make a DNS failure
    hang just as long.
    """

    connect: float = 10.0
    #: providers may queue before the first token
    first_token: float = 120.0
    #: upper bound for one stream
    total: float = 1800.0


DEFAULT_TIMEOUTS: Final = Timeouts()


#: Failures where sending the same request again may succeed.
DEFAULT_RETRYABLE: Final = frozenset({
    EMPTY_RESPONSE, RATE_LIMIT, SERVER, TIMEOUT, TRANSPORT,
})

#: Deliberately narrower: when the provider is out of capacity, background jobs (titles,
#: summaries) give up instead of competing with the question the user is waiting on.
BACKGROUND_RETRYABLE: Final = frozenset({TIMEOUT, TRANSPORT, EMPTY_RESPONSE})


@dataclass(frozen=True)
class RetryPolicy:
    max_retries: int = 5
    initial_delay: float = 0.5
    max_delay: float = 10.0
    #: symmetric jitter so rate-limited clients don't retry in lockstep
    jitter_ratio: float = 0.1
    retryable_codes: frozenset[str] = field(default_factory=lambda: DEFAULT_RETRYABLE)
    background_retryable_codes: frozenset[str] = field(
        default_factory=lambda: BACKGROUND_RETRYABLE
    )
    background_max_retries: int = 1

    def budget(self, purpose: Purpose) -> int:
        return (
            self.max_retries if purpose == "foreground" else self.background_max_retries
        )

    def eligible_codes(self, purpose: Purpose) -> frozenset[str]:
        return (
            self.retryable_codes
            if purpose == "foreground"
            else self.background_retryable_codes
        )


DEFAULT_POLICY: Final = RetryPolicy()


def is_retryable(
    failure: LlmFailure,
    *,
    attempt: int,
    emitted_content: bool,
    policy: RetryPolicy = DEFAULT_POLICY,
    purpose: Purpose = "foreground",
) -> bool:
    """Whether to retry this failure. Never once content has been emitted."""
    if emitted_content:
        return False
    if attempt > policy.budget(purpose):
        return False
    return failure.code in policy.eligible_codes(purpose)


def compute_delay(
    attempt: int,
    *,
    policy: RetryPolicy = DEFAULT_POLICY,
    retry_after: float | None = None,
    rng: random.Random | None = None,
) -> float:
    """Delay before the next attempt. Retry-After wins when it falls within max_delay;
    some providers send hours, which would hang the request.
    """
    if retry_after is not None and 0 <= retry_after <= policy.max_delay:
        return retry_after

    # 0.5, 1, 2, 4, 8 s, capped at 10 s
    base = min(policy.initial_delay * (2 ** max(0, attempt - 1)), policy.max_delay)
    if policy.jitter_ratio <= 0:
        return base
    source = rng if rng is not None else random
    factor = 1.0 + source.uniform(-policy.jitter_ratio, policy.jitter_ratio)
    return max(0.0, base * factor)


def parse_retry_after(raw: str | None) -> float | None:
    """Parse Retry-After (seconds or an HTTP date); None lets the local backoff take over."""
    if not raw:
        return None
    text = raw.strip()
    try:
        seconds = float(text)
    except ValueError:
        pass
    else:
        return seconds if seconds >= 0 else None

    try:
        when = email.utils.parsedate_to_datetime(text)
    except (TypeError, ValueError):
        return None
    if when is None:
        return None
    import datetime as _dt

    now = _dt.datetime.now(_dt.timezone.utc)
    if when.tzinfo is None:
        when = when.replace(tzinfo=_dt.timezone.utc)
    delta = (when - now).total_seconds()
    return max(0.0, delta)
