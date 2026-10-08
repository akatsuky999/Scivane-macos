"""Per-call proxy credentials, revoked when the call ends.

One mechanism, two jobs: authentication (any local process can reach the proxy port) and
attribution (the token carries the job and call ids, so concurrent tools are never confused).
Delivered as the username in http_proxy/https_proxy, which curl, pip, git and requests all
accept unchanged.
"""

from __future__ import annotations

import base64
import binascii
import secrets
import threading
import time
from dataclasses import dataclass

__all__ = ["Grant", "GrantBook"]


@dataclass(frozen=True)
class Grant:
    token: str
    job_id: str
    call_id: str
    issued_at: float

    def proxy_url(self, port: int) -> str:
        """http_proxy value: the token as username, empty password (standard Basic auth)."""
        return f"http://{self.token}:@127.0.0.1:{port}"


class GrantBook:
    """Thread-safe: the sandbox runner blocks in to_thread while the proxy reads this on the loop."""

    def __init__(self) -> None:
        self._grants: dict[str, Grant] = {}
        self._lock = threading.Lock()

    def issue(self, job_id: str, call_id: str) -> Grant:
        grant = Grant(
            token=secrets.token_urlsafe(32),
            job_id=job_id,
            call_id=call_id,
            issued_at=time.time(),
        )
        with self._lock:
            self._grants[grant.token] = grant
        return grant

    def revoke(self, grant: Grant) -> None:
        """Revoke; callers guarantee this with try/finally."""
        with self._lock:
            self._grants.pop(grant.token, None)

    def lookup(self, token: str) -> Grant | None:
        """No grace period: an unknown token is unknown."""
        if not token:
            return None
        with self._lock:
            return self._grants.get(token)

    def __len__(self) -> int:
        with self._lock:
            return len(self._grants)


def token_from_header(value: str) -> str:
    """Extract the token from Proxy-Authorization (Basic, token as username).

    Returns "" when absent, which then fails the lookup exactly like a wrong token.
    """
    if not value:
        return ""
    scheme, _, payload = value.partition(" ")
    if scheme.lower() != "basic" or not payload:
        return ""
    try:
        decoded = base64.b64decode(payload.strip(), validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return ""
    username, sep, _password = decoded.partition(":")
    return username if sep else decoded
