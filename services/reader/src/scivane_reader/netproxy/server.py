"""本地审计代理：沙箱那个针孔后面站着的东西。

**住在 FastAPI 进程内的 asyncio 任务里**，绑 `127.0.0.1:0` 让内核给端口。
不另起进程：另起就要再管一遍启动、回收、孤儿 —— 后端的进程回收已经付过一次
这个代价，没必要再付一次。绑 0 号端口是因为写死端口在别人的机器上会撞。

**不做 MITM。** https 只看 CONNECT 那一行的 `host:port`，然后透传字节。
做 MITM 要自签 CA、要把它塞进子进程的信任库，换来的是「能看见路径」——
而路径恰恰是这里**不想要**的东西（见 audit.py）。不做，省下的不只是工作量，
更是「agent 的 https 流量在本机被解开过」这件事本身。

**fail closed 的方向永远是「能力更少」**：认证不过 → 407；目的地在禁区 → 403；
上游连不上 → 502。任何一条判不出来的路径都是拒绝，没有「拿不准就放行」。
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Callable
from urllib.parse import urlsplit

from .. import config
from .audit import AuditLog, Entry, NetworkRecord
from .destinations import ForbiddenDestination, resolve
from .grants import Grant, GrantBook, token_from_header

__all__ = ["AuditProxy"]

#: 请求头的上限。代理只需要读到第一个空行，读不完就是不正常的客户端。
_MAX_LINE = 8192
_MAX_HEADERS = 64 * 1024

#: 逐跳头，不转发给上游。`Proxy-Authorization` 尤其重要 ——
#: 那是 agent 对**代理**的凭据，转给上游等于把它送给了第三方。
_HOP_BY_HOP = frozenset({
    "proxy-authorization", "proxy-connection", "connection",
    "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
})


class _Refused(Exception):
    """判定阶段的拒绝。`status` 是给客户端的，`code` 是给审计簿的。"""

    def __init__(self, status: str, code: str, message: str,
                 headers: tuple[str, ...] = ()) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        #: 附加响应头。407 必须带 `Proxy-Authenticate`，见 `_authenticate`。
        self.headers = headers


class AuditProxy:
    """审计代理。一个后端进程一个。"""

    def __init__(
        self,
        grants: GrantBook,
        audit: AuditLog,
        *,
        vet: Callable[[str, int], list] = resolve,
    ) -> None:
        """
        :param vet: 目的地判定。**默认就是真的那一个**，生产代码从不传它。

            为什么做成构造器参数而不是配置项或环境变量：离线测试的 fixture
            只能起在回环上，而回环正是这一层要拒绝的东西 —— 不给一条路，
            整个代理的管道（认证、隧道、字节计数、审计）就一行都测不到。

            **但逃生口不能放在配置里。** 环境变量或配置项意味着它在生产环境
            里也能被打开，而「遇到不顺手就关掉约束」正是沙箱不提供
            `danger-full-access` 的理由。做成构造器参数，就只有直接写 Python
            构造这个对象的代码才碰得到它 —— 后端的装配路径永远用默认值，
            并且有一条测试盯着「默认构造出来的代理拒绝回环」。
        """
        self._grants = grants
        self._audit = audit
        self._vet = vet
        self._server: asyncio.AbstractServer | None = None
        self._port: int | None = None

    # --- 生命周期 --------------------------------------------------------

    async def start(self) -> int:
        """起来，返回内核给的端口。已经起了就返回现有端口。"""
        if self._server is not None:
            assert self._port is not None
            return self._port
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        # 只绑回环的一个地址，所以取第一个 socket 的端口就够。
        self._port = self._server.sockets[0].getsockname()[1]
        return self._port

    async def stop(self) -> None:
        if self._server is None:
            return
        self._server.close()
        await self._server.wait_closed()
        self._server = None
        self._port = None

    @property
    def port(self) -> int | None:
        """没起来时是 None —— **调用方据此把策略降成「无网」**，命令照跑。"""
        return self._port

    @property
    def running(self) -> bool:
        return self._server is not None

    @property
    def audit(self) -> AuditLog:
        """这台代理写的那本审计簿。

        工具层按调用查拒绝记录时读的就是它 —— 从代理身上取，而不是另传一本进去，
        两边就不可能指着两本不同的簿子（那种错不会报，只会让模型永远「没被拦过」）。
        """
        return self._audit

    # --- 连接处理 --------------------------------------------------------

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        started = time.time()
        grant: Grant | None = None
        host, port, method = "", 0, ""
        try:
            method, host, port, head, headers = await self._read_request(reader)
            grant = self._authenticate(headers)
            infos = self._check(host, port)
            upstream_r, upstream_w = await self._connect(infos, host)
        except _Refused as exc:
            self._record(grant, host, port, method or "?", started,
                         allowed=False, reason=exc.code)
            await self._respond(writer, exc.status, exc.message, exc.headers)
            return
        except (asyncio.IncompleteReadError, ConnectionError, asyncio.TimeoutError):
            # 客户端自己断了或者根本没说完话，没什么可记的，也没人听回应。
            await self._close(writer)
            return

        assert grant is not None
        # **先落簿再传字节。** 主机名这时候就知道了，而字节数要等连接结束 ——
        # 界面那张卡不该等一次十分钟的下载跑完才出现。
        entry = self._record(grant, host, port, method, started, allowed=True)
        up = down = 0
        try:
            if method == "CONNECT":
                writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                await writer.drain()
            else:
                upstream_w.write(head)
                await upstream_w.drain()
            up, down = await self._tunnel(reader, writer, upstream_r, upstream_w)
        finally:
            await self._close(writer)
            await self._close(upstream_w)
            self._audit.settle(entry, bytes_up=up, bytes_down=down,
                               elapsed=time.time() - started)

    async def _read_request(
        self, reader: asyncio.StreamReader
    ) -> tuple[str, str, int, bytes, list[tuple[str, str]]]:
        """读到第一个空行为止，取出方法与目的地。

        **路径在这里就被丢掉了**，不进任何变量、不往下传。普通 HTTP 的请求行
        是绝对形式（`GET http://host/path?query HTTP/1.1`），必须重写成
        原始形式发给上游 —— 重写的同时路径只在这个函数的栈上活着。
        """
        line = await asyncio.wait_for(reader.readline(), config.NETPROXY_IDLE_TIMEOUT)
        if not line or len(line) > _MAX_LINE:
            raise _Refused("400 Bad Request", "BAD_REQUEST", "请求行不合法")
        try:
            method, target, version = line.decode("latin-1").rstrip("\r\n").split(" ", 2)
        except ValueError:
            raise _Refused("400 Bad Request", "BAD_REQUEST", "请求行不合法") from None

        raw_headers: list[bytes] = []
        size = 0
        while True:
            header = await asyncio.wait_for(reader.readline(), config.NETPROXY_IDLE_TIMEOUT)
            if not header:
                raise _Refused("400 Bad Request", "BAD_REQUEST", "请求头没有结束")
            size += len(header)
            if size > _MAX_HEADERS:
                raise _Refused("431 Request Header Fields Too Large", "BAD_REQUEST", "请求头过大")
            if header in (b"\r\n", b"\n"):
                break
            raw_headers.append(header)

        headers = _parse_headers(raw_headers)
        if method.upper() == "CONNECT":
            host, port = _split_authority(target, default_port=443)
            # CONNECT 不转发任何头，但**凭据在头里** —— 它要一路带到认证那一步。
            # （第一版漏了这个，https 会全部 407：隧道不带 head，认证就查了个空。）
            return "CONNECT", host, port, b"", headers

        parts = urlsplit(target)
        if not parts.hostname:
            # 原始形式（没有 scheme://host）说明客户端没把我们当代理用，
            # 而是直接连了过来 —— 那不是这个端口的用途。
            raise _Refused("400 Bad Request", "NOT_PROXY_FORM", "这个端口只接受代理请求")
        host = parts.hostname
        port = parts.port or (443 if parts.scheme == "https" else 80)
        # 原始形式的目标：path?query。**只在这一行里活着，不进审计、不进日志。**
        origin = parts.path or "/"
        if parts.query:
            origin = f"{origin}?{parts.query}"
        head = _rebuild(method, origin, version, headers)
        return method.upper(), host, port, head, headers

    def _authenticate(self, headers: list[tuple[str, str]]) -> Grant:
        """查凭据。查不到就是 407，没有别的可能。"""
        token = token_from_header(_header_of(headers, "proxy-authorization"))
        grant = self._grants.lookup(token)
        if grant is None:
            # **407 必须带 `Proxy-Authenticate`**（RFC 7235）。少了这个头，
            # 等挑战的客户端就直接放弃 —— 实测 `git clone` 正是这样死的：
            # 它经 libcurl 先裸着发一次，收到没有挑战头的 407 就报
            # 「unable to access … error: 407」，连重试都不试。
            # curl 命令行看不出这个毛病，因为代理 URL 里带了凭据它会抢先发。
            raise _Refused(
                "407 Proxy Authentication Required", "NO_GRANT",
                "这次调用没有联网凭据（或者凭据已经随调用作废）",
                headers=('Proxy-Authenticate: Basic realm="scivane"',),
            )
        return grant

    def _check(self, host: str, port: int):
        try:
            return self._vet(host, port)
        except ForbiddenDestination as exc:
            raise _Refused("403 Forbidden", exc.code, str(exc)) from exc

    async def _connect(self, infos, host: str):
        """连**判过的那个地址**，不让 socket 自己重新解析一遍。"""
        last: Exception | None = None
        for _family, _type, _proto, _canon, sockaddr in infos:
            try:
                return await asyncio.wait_for(
                    asyncio.open_connection(sockaddr[0], sockaddr[1]),
                    config.NETPROXY_CONNECT_TIMEOUT,
                )
            except (OSError, asyncio.TimeoutError) as exc:
                last = exc
        raise _Refused("502 Bad Gateway", "UPSTREAM_FAILED", f"连不上 {host}：{last}")

    async def _tunnel(self, client_r, client_w, upstream_r, upstream_w) -> tuple[int, int]:
        """双向透传，只数字节。

        **以「下行跑完」为交换结束的判据**，然后把上行那一半收掉。

        不等两个方向都自然结束，是因为客户端完全可以在读完响应之后继续
        把连接留着（它不知道我们已经让上游 close 了）。那样这条连接会一直
        挂在事件循环上，它那条审计记录也一直结算不了字节数。上游关了就说明
        这次交换已经结束 —— CONNECT 隧道同理，服务端关了隧道就没了。

        反过来不成立：**上行先结束不能当作结束**，那只表示客户端发完了请求，
        响应还没回来。
        """
        counts = [0, 0]

        async def pipe(src, dst, slot: int) -> None:
            try:
                while True:
                    chunk = await src.read(65536)
                    if not chunk:
                        break
                    counts[slot] += len(chunk)
                    dst.write(chunk)
                    await dst.drain()
            except (ConnectionError, asyncio.TimeoutError, OSError):
                pass
            finally:
                try:
                    dst.write_eof()
                except (OSError, RuntimeError):
                    pass

        up = asyncio.ensure_future(pipe(client_r, upstream_w, 0))
        down = asyncio.ensure_future(pipe(upstream_r, client_w, 1))
        try:
            await down
        finally:
            up.cancel()
            # 收掉它并吞掉取消异常 —— 这是我们自己发起的取消，不是故障。
            await asyncio.gather(up, return_exceptions=True)
        return counts[0], counts[1]

    # --- 收尾 ------------------------------------------------------------

    def _record(self, grant: Grant | None, host: str, port: int, method: str,
                started: float, *, allowed: bool, reason: str = "") -> Entry:
        """记一条。**没有凭据的那次也要记** —— 「有人拿着错凭据来过」本身是事实。"""
        return self._audit.add(NetworkRecord(
            job_id=grant.job_id if grant else "",
            call_id=grant.call_id if grant else "",
            host=host, port=port, method=method,
            allowed=allowed, reason=reason,
            started_at=started, elapsed=time.time() - started,
        ))

    async def _respond(self, writer: asyncio.StreamWriter, status: str, message: str,
                       headers: tuple[str, ...] = ()) -> None:
        body = message.encode("utf-8")
        extra = "".join(f"{h}\r\n" for h in headers)
        writer.write(
            f"HTTP/1.1 {status}\r\n"
            f"{extra}"
            f"Content-Type: text/plain; charset=utf-8\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n".encode("latin-1") + body
        )
        try:
            await writer.drain()
        except (ConnectionError, OSError):
            pass
        await self._close(writer)

    @staticmethod
    async def _close(writer: asyncio.StreamWriter) -> None:
        try:
            writer.close()
            await writer.wait_closed()
        except (ConnectionError, OSError, RuntimeError):
            pass


# --- 头部处理（纯函数，测试直接盯着它们） ---------------------------------


def _parse_headers(raw: list[bytes]) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for line in raw:
        text = line.decode("latin-1").rstrip("\r\n")
        name, sep, value = text.partition(":")
        if sep:
            out.append((name.strip(), value.strip()))
    return out


def _header_of(headers: list[tuple[str, str]], name: str) -> str:
    """取一个头的值，大小写不敏感。**CONNECT 与普通请求走同一条路。**"""
    for key, value in headers:
        if key.lower() == name:
            return value
    return ""


def _rebuild(method: str, origin: str, version: str, headers: list[tuple[str, str]]) -> bytes:
    """绝对形式 → 原始形式，并摘掉逐跳头。

    强制 `Connection: close`：一条连接只走一个请求。代价是 pip 这种要发几十个
    请求的客户端每次都重连（https 走 CONNECT 隧道，不受这条影响），
    换来的是不必在这一层实现 keep-alive 的状态机 —— 那是一整类边界情况，
    而这里多一个状态机就多一处能悄悄放行的地方。
    """
    lines = [f"{method} {origin} {version}"]
    for name, value in headers:
        if name.lower() in _HOP_BY_HOP:
            continue
        lines.append(f"{name}: {value}")
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def _split_authority(target: str, *, default_port: int) -> tuple[str, int]:
    """`host:port` → (host, port)。IPv6 的字面量带方括号。"""
    if target.startswith("["):
        host, _, rest = target[1:].partition("]")
        port = rest.lstrip(":")
        return host, int(port) if port.isdigit() else default_port
    host, _, port = target.rpartition(":")
    if not host:
        return target, default_port
    return host, int(port) if port.isdigit() else default_port
