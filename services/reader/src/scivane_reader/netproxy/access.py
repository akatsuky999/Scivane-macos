"""The narrow slice the tool layer sees: proxy port, per-call token, and what was refused.

Keeps tools/ independent of the proxy implementation. Translating this into a sandbox policy is
exec.py's job, so netproxy/ and sandbox/ don't depend on each other.
"""

from __future__ import annotations

import contextlib
from collections.abc import Callable, Iterator
from dataclasses import dataclass

from .grants import GrantBook
from .server import AuditProxy

__all__ = ["CallNetwork", "NetworkAccess", "Refusal", "REASONS"]


#: Refusal code -> one sentence for the model. Only codes attributable to a call appear here, and a
#: test checks that every destination code has a sentence. Rule codes say that any tool hits the
#: same rule: models tend to retry a blocked target with another tool.
REASONS: dict[str, str] = {
    "LOOPBACK": "目的地是本机。本机上跑着本产品自己的服务，沙箱一律不许连，换命令或换工具也一样",
    "LINK_LOCAL": "目的地是链路本地地址（云主机的元数据服务在这一段），不许连，换工具也一样",
    "PRIVATE": "目的地是局域网地址（路由器、NAS、用户自己的别的机器），不许连，换工具也一样",
    "UNSPECIFIED": "目的地是 0.0.0.0 一类的未指定地址，不许连",
    "MULTICAST": "目的地是组播地址，不许连",
    "DNS_FAILED": "主机名解析不出来 —— 查一下拼写，或者这个域名确实不存在",
    "UPSTREAM_FAILED": "代理连不上对方（超时或被对方拒绝）—— 对方可能暂时不可用，不是沙箱的规则",
}


@dataclass(frozen=True)
class Refusal:
    """A connection the proxy refused, which is all the model gets.

    No path and no resolved IP: echoing an internal address would complete the probe for the agent.
    """

    host: str
    port: int
    reason: str

    @property
    def target(self) -> str:
        return f"{self.host}:{self.port}"

    @property
    def meaning(self) -> str:
        """What this code means; empty for unknown codes (a bare code beats an invented explanation)."""
        return REASONS.get(self.reason, "")


def _nothing() -> tuple[Refusal, ...]:
    return ()


@dataclass(frozen=True)
class CallNetwork:
    """Network credentials for one tool call, void once the call ends."""

    port: int
    token: str
    #: Connections refused for this call so far (407 handshakes excluded). A query scoped to this call,
    #: not the whole audit log, so nothing leaks about other calls.
    refusals: Callable[[], tuple[Refusal, ...]] = _nothing


class NetworkAccess:
    """Process-wide network capability; one per backend, on app.state."""

    def __init__(self, proxy: AuditProxy, grants: GrantBook) -> None:
        self._proxy = proxy
        self._grants = grants

    @contextlib.contextmanager
    def for_call(self, job_id: str, call_id: str) -> Iterator[CallNetwork | None]:
        """Issue a credential for this call, revoked when it ends.

        None when the proxy isn't running: the sandbox falls back to no network (fewer capabilities,
        never more). Revoked in `finally`, so cancellation revokes it too.
        """
        port = self._proxy.port
        if port is None:
            yield None
            return
        grant = self._grants.issue(job_id, call_id)
        audit = self._proxy.audit

        def refusals() -> tuple[Refusal, ...]:
            return tuple(
                Refusal(r.host, r.port, r.reason) for r in audit.refused(job_id, call_id)
            )

        try:
            yield CallNetwork(port=port, token=grant.token, refusals=refusals)
        finally:
            self._grants.revoke(grant)
