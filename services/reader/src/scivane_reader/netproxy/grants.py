"""凭据：按工具调用签发，随调用作废。

**一个机制干两件事**，这是选它的理由：

1. **认证** —— 回环上任何进程都能连上代理端口，没有凭据的话，沙箱外一个跑飞的
   脚本也能借道出网，审计簿上还会记成 agent 干的。
2. **归因** —— 凭据本身携带 `(job_id, call_id)`，所以「agent 刚访问了 X」是
   诚实的：不是按时间猜的，是它拿着那一次的凭据来的。并发跑两个工具时，
   按时间猜必然张冠李戴。

**按调用签发、随调用作废**，不是长期凭据。泄进文件、写进脚本、被模型抄进正文，
下一次调用都用不了它 —— 生命周期短到来不及变成一把钥匙。

凭据怎么送到子进程：`http_proxy` / `https_proxy` 里的用户名位
（`http://<token>:@127.0.0.1:<port>`）。选它是因为 curl / pip / git / requests
**全都不用改一行**就认得，而自定义头要每个工具单独配。代价是 token 会出现在
子进程的环境变量里 —— 可以接受：它只对这一次调用有效，而环境本来就是
`build_env()` 从零搭给它自己的。
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
    """一次工具调用的联网凭据。"""

    token: str
    job_id: str
    call_id: str
    issued_at: float

    def proxy_url(self, port: int) -> str:
        """给子进程的 `http_proxy` 值。

        用户名位放 token、密码位留空 —— Basic 认证的标准形状，
        curl / pip / git / httpx 都认。
        """
        return f"http://{self.token}:@127.0.0.1:{port}"


class GrantBook:
    """在册的凭据。

    **线程安全。** 沙箱运行器是同步阻塞的、跑在 `asyncio.to_thread` 里，
    而代理在事件循环里查这本册子 —— 两边真的在不同线程上。
    """

    def __init__(self) -> None:
        self._grants: dict[str, Grant] = {}
        self._lock = threading.Lock()

    def issue(self, job_id: str, call_id: str) -> Grant:
        """签发。`token_urlsafe(32)` 是 256 位熵，够了。"""
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
        """作废。**调用结束必须走到这里** —— 调用方用 try/finally 保证。"""
        with self._lock:
            self._grants.pop(grant.token, None)

    def lookup(self, token: str) -> Grant | None:
        """查。没有就是没有 —— 不存在「宽限期」这种东西。"""
        if not token:
            return None
        with self._lock:
            return self._grants.get(token)

    def __len__(self) -> int:
        with self._lock:
            return len(self._grants)


def token_from_header(value: str) -> str:
    """从 `Proxy-Authorization` 里取出 token。

    只认 Basic，token 在用户名位。**解不出来就返回空字符串** ——
    这一层不抛异常：调用方拿空 token 去查册子，查不到就是 407，
    与「带了个错的 token」走同一条路。少一个分支就少一处能写错的地方。
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
