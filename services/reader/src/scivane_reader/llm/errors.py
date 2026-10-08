"""Stable failure codes. Route on the code, never on message text: vendor wording changes."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Final

#: provider id not registered
NO_ADAPTER: Final = "NO_ADAPTER"
#: no credential configured
MISSING_CREDENTIAL: Final = "MISSING_CREDENTIAL"
#: malformed credential: fix the stored value, retrying won't help
INVALID_CREDENTIAL: Final = "INVALID_CREDENTIAL"
#: credential rejected (expired, revoked, insufficient scope)
AUTH: Final = "AUTH"
#: rate limited; retryable
RATE_LIMIT: Final = "RATE_LIMIT"
#: provider 5xx; retryable
SERVER: Final = "SERVER"
#: retryable
TIMEOUT: Final = "TIMEOUT"
#: DNS, TLS or connection reset; retryable
TRANSPORT: Final = "TRANSPORT"
#: input exceeds the context window; shrink it before retrying
CONTEXT_WINDOW_EXCEEDED: Final = "CONTEXT_WINDOW_EXCEEDED"
#: balance or quota exhausted; retrying keeps failing
QUOTA: Final = "QUOTA"
#: finished without any content. A failure (otherwise the turn silently ends), safe to retry.
EMPTY_RESPONSE: Final = "EMPTY_RESPONSE"
#: bad request (unknown model, out-of-range parameter)
INVALID_ARGS: Final = "INVALID_ARGS"
#: blocked by the provider's safety policy. Unlike EMPTY_RESPONSE this is deterministic:
#: retrying only burns money.
REFUSAL: Final = "REFUSAL"
#: anything unclassified
UNKNOWN: Final = "UNKNOWN"

ALL_CODES: Final = frozenset({
    NO_ADAPTER, MISSING_CREDENTIAL, INVALID_CREDENTIAL, AUTH,
    RATE_LIMIT, SERVER, TIMEOUT, TRANSPORT,
    CONTEXT_WINDOW_EXCEEDED, QUOTA, EMPTY_RESPONSE, INVALID_ARGS,
    REFUSAL, UNKNOWN,
})


@dataclass(frozen=True)
class LlmFailure:
    """The facts of one failure: consumers read `code`, display `message`."""

    message: str
    code: str
    #: for debugging only; never route on it
    status: int | None = None
    #: seconds from Retry-After; honoured within bounds
    retry_after: float | None = None

    def __post_init__(self) -> None:
        if self.code not in ALL_CODES:
            raise ValueError(f"未知失败码：{self.code}")


class LlmError(Exception):
    """Exception carrying a stable code; keep `failure` when re-raising across layers."""

    def __init__(
        self,
        message: str,
        code: str,
        *,
        status: int | None = None,
        retry_after: float | None = None,
    ) -> None:
        super().__init__(message)
        self.failure = LlmFailure(
            message=message, code=code, status=status, retry_after=retry_after
        )

    @property
    def code(self) -> str:
        return self.failure.code


# Text heuristics, only for when the provider gives no structured code.

_CONTEXT_OVERFLOW = re.compile(
    r"context[\s_-]?(?:length|window)[\s_-]?(?:exceed|overflow|limit)"
    r"|maximum[\s_-]context[\s_-]length"
    r"|(?:prompt|input|request|messages?)\s+(?:is\s+|are\s+)?too\s+(?:long|large)"
    r"|reduce\s+the\s+length\s+of\s+the\s+messages",
    re.IGNORECASE,
)

_QUOTA = re.compile(
    r"insufficient[\s_-]?(?:quota|balance|credit)"
    r"|quota[\s_-]?exceeded"
    r"|billing[\s_-]?(?:hard[\s_-]?)?limit"
    r"|exceeded\s+your\s+current\s+quota"
    r"|余额不足",
    re.IGNORECASE,
)


def looks_like_context_overflow(text: str) -> bool:
    return bool(_CONTEXT_OVERFLOW.search(text))


def looks_like_quota_exhausted(text: str) -> bool:
    return bool(_QUOTA.search(text))


def classify_status(status: int, detail: str = "") -> str:
    """Default HTTP status -> code mapping shared by the adapters.

    `detail` disambiguates: 400 is bad args or overflow, 429 is a rate limit or exhausted quota.
    """
    if status == 400:
        if looks_like_context_overflow(detail):
            return CONTEXT_WINDOW_EXCEEDED
        if looks_like_quota_exhausted(detail):
            return QUOTA
        return INVALID_ARGS
    if status == 401:
        return AUTH
    if status == 403:
        # some providers use 403 for an exhausted balance
        return QUOTA if looks_like_quota_exhausted(detail) else AUTH
    if status == 404:
        # a wrong model name is usually a 404
        return INVALID_ARGS
    if status == 413:
        return CONTEXT_WINDOW_EXCEEDED
    if status == 422:
        return CONTEXT_WINDOW_EXCEEDED if looks_like_context_overflow(detail) else INVALID_ARGS
    if status == 429:
        # 429 is either a rate limit (wait) or an exhausted quota (waiting won't help)
        return QUOTA if looks_like_quota_exhausted(detail) else RATE_LIMIT
    if status in (408, 504):
        return TIMEOUT
    if 500 <= status < 600:
        return SERVER
    return UNKNOWN
