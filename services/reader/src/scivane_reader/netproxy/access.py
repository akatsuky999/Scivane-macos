"""工具层拿得到的那一小块：代理在哪、这一次调用的凭据是什么、这一次被拦了什么。

**这个模块存在的唯一理由是把依赖方向理顺。** 工具层需要的只有「端口 + token」
两个值，外加「我这次被拦下了哪些连接」这一个查询；而 `AuditProxy` 背后还挂着
服务器、审计簿、目的地判定。让 `tools/` 直接摸 `AuditProxy` 的话，那一层就被迫
知道代理的实现形状；而这里给它几个窄字段，换实现时工具层一行都不用动。

反过来也一样：**`netproxy/` 不认识 `sandbox.NetworkPolicy`**。把端口和 token
翻译成沙箱策略是 `exec.py` 的事（它本来就 import sandbox）—— 两个子包因此
互不依赖，各自都能单独测。
"""

from __future__ import annotations

import contextlib
from collections.abc import Callable, Iterator
from dataclasses import dataclass

from .grants import GrantBook
from .server import AuditProxy

__all__ = ["CallNetwork", "NetworkAccess", "Refusal", "REASONS"]


#: 拒绝原因码 → 给模型的一句话。**原因码是这个子包的词汇，它的意思只在这里说一次。**
#:
#: 只列**带得上凭据**的那几种：目的地判定（destinations.py）与连上游失败。
#: 认证之前就被拒的（NO_GRANT / BAD_REQUEST / NOT_PROXY_FORM）没有归属，
#: 按调用查本来就查不到，也就不会出现在工具结果里。有一条测试盯着
#: 「判定表里每个码都有一句话」—— 加了新码忘了写，模型就只能看到一个裸码。
#:
#: 规则类的几条都说「换工具也一样」：模型撞墙之后的第一反应常是换条路重试
#: （curl 不行换 python 的 urllib），而那条路撞的是同一道规则。
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
    """代理没放行的一次连接 —— 给模型看的只有这三样。

    **没有路径**（审计那一层就不存在），**也没有解析到的 IP**：说出来等于替
    agent 把内网探到的结果念一遍（destinations.py 里同一条理由）。
    """

    host: str
    port: int
    reason: str

    @property
    def target(self) -> str:
        return f"{self.host}:{self.port}"

    @property
    def meaning(self) -> str:
        """这个原因码的意思。不认识的码给空串 —— 裸码总比编一句解释好。"""
        return REASONS.get(self.reason, "")


def _nothing() -> tuple[Refusal, ...]:
    return ()


@dataclass(frozen=True)
class CallNetwork:
    """一次工具调用的联网凭据。出了这次调用就作废。"""

    port: int
    token: str
    #: 这次调用到目前为止被代理拦下的连接（不含 407 握手），按发生顺序。
    #:
    #: 给的是**一个只查得到自己的入口**，不是整本审计簿 —— 工具层要回答的只有
    #: 「我这次被拦了什么」；多给一本簿子，就多一条把别的调用去过哪漏给模型的路。
    refusals: Callable[[], tuple[Refusal, ...]] = _nothing


class NetworkAccess:
    """进程级的联网能力。一个后端一个，挂在 app.state 上。"""

    def __init__(self, proxy: AuditProxy, grants: GrantBook) -> None:
        self._proxy = proxy
        self._grants = grants

    @contextlib.contextmanager
    def for_call(self, job_id: str, call_id: str) -> Iterator[CallNetwork | None]:
        """给这一次调用签一张凭据，用完作废。

        **代理没起来就给 None**，不是抛异常 —— 那是第一层 fail closed：
        策略退回「无网」，命令照跑，agent 会从错误消息里知道现在没有网。
        这不是被禁止的那种「降级」（禁的是跑成*不受约束*），
        方向正好相反：能力更少。

        用 `finally` 作废而不是靠调用方记得。**取消也会走到这里** ——
        `asyncio.CancelledError` 同样是异常，凭据不会留在册子上。
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
