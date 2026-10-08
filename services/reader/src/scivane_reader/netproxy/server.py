"""The audit proxy behind the sandbox's single loopback port.

Runs as an asyncio task inside the backend and binds 127.0.0.1:0. No MITM: https is only seen
as CONNECT host:port and the bytes pass through untouched. Anything undecidable is refused:
bad credentials 407, forbidden destination 403, unreachable upstream 502.
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

#: the proxy only reads up to the first blank line
_MAX_LINE = 8192
_MAX_HEADERS = 64 * 1024

#: Hop-by-hop headers stay here. Proxy-Authorization above all: it is the agent's credential for
#: this proxy, not for the upstream.
_HOP_BY_HOP = frozenset({
    "proxy-authorization", "proxy-connection", "connection",
    "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
})


class _Refused(Exception):
    """Refusal during the checks: `status` for the client, `code` for the audit log."""

    def __init__(self, status: str, code: str, message: str,
                 headers: tuple[str, ...] = ()) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        #: extra response headers; a 407 must carry Proxy-Authenticate
        self.headers = headers


class AuditProxy:
    def __init__(
        self,
        grants: GrantBook,
        audit: AuditLog,
        *,
        vet: Callable[[str, int], list] = resolve,
    ) -> None:
        """`vet` is the destination check. Production code never passes it; it exists so offline
        tests, which can only run on loopback, can exercise the pipeline. Deliberately not a config
        option or env var, so it can't be switched off in production; a test checks that the
        default refuses loopback.
        """
        self._grants = grants
        self._audit = audit
        self._vet = vet
        self._server: asyncio.AbstractServer | None = None
        self._port: int | None = None

    async def start(self) -> int:
        """Start and return the kernel-assigned port (or the existing one)."""
        if self._server is not None:
            assert self._port is not None
            return self._port
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        # bound to a single loopback address, so the first socket's port is the port
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
        """None when not running; callers then fall back to no network."""
        return self._port

    @property
    def running(self) -> bool:
        return self._server is not None

    @property
    def audit(self) -> AuditLog:
        """The audit log this proxy writes. Read from here so the tool layer can never consult a different one."""
        return self._audit

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
            # client hung up or never finished its request: nothing to record or answer
            await self._close(writer)
            return

        assert grant is not None
        # Record before relaying: the host is known now, the byte count only at the end.
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
        """Read up to the first blank line and extract method and destination.

        The path is dropped here: absolute-form requests are rewritten to origin-form and the path
        lives only on this stack frame.
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
            # CONNECT forwards no headers, but the credential is in them and must reach authentication.
            return "CONNECT", host, port, b"", headers

        parts = urlsplit(target)
        if not parts.hostname:
            # origin-form means the client connected directly instead of using us as a proxy
            raise _Refused("400 Bad Request", "NOT_PROXY_FORM", "这个端口只接受代理请求")
        host = parts.hostname
        port = parts.port or (443 if parts.scheme == "https" else 80)
        # path?query lives only on this line; never audited or logged
        origin = parts.path or "/"
        if parts.query:
            origin = f"{origin}?{parts.query}"
        head = _rebuild(method, origin, version, headers)
        return method.upper(), host, port, head, headers

    def _authenticate(self, headers: list[tuple[str, str]]) -> Grant:
        """Check the credential; unknown means 407."""
        token = token_from_header(_header_of(headers, "proxy-authorization"))
        grant = self._grants.lookup(token)
        if grant is None:
            # A 407 must carry Proxy-Authenticate (RFC 7235); without it git (via libcurl) gives up
            # instead of retrying with credentials.
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
        """Connect to the vetted address; never let the socket resolve again."""
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
        """Relay both ways, counting bytes.

        The exchange ends when the downstream half finishes; the upstream half is then cancelled.
        Clients may keep the connection open after reading the response, which would leave the entry
        unsettled forever. The reverse doesn't hold: the client finishing its request says nothing
        about the response.
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
            # our own cancellation, not a failure
            await asyncio.gather(up, return_exceptions=True)
        return counts[0], counts[1]

    def _record(self, grant: Grant | None, host: str, port: int, method: str,
                started: float, *, allowed: bool, reason: str = "") -> Entry:
        """Record a connection, including ones without valid credentials: that someone tried is a fact."""
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



def _parse_headers(raw: list[bytes]) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for line in raw:
        text = line.decode("latin-1").rstrip("\r\n")
        name, sep, value = text.partition(":")
        if sep:
            out.append((name.strip(), value.strip()))
    return out


def _header_of(headers: list[tuple[str, str]], name: str) -> str:
    """Header value, case-insensitive."""
    for key, value in headers:
        if key.lower() == name:
            return value
    return ""


def _rebuild(method: str, origin: str, version: str, headers: list[tuple[str, str]]) -> bytes:
    """Absolute-form -> origin-form, dropping hop-by-hop headers.

    Forces Connection: close (one request per connection) so this layer needs no keep-alive state
    machine; https goes through CONNECT and is unaffected.
    """
    lines = [f"{method} {origin} {version}"]
    for name, value in headers:
        if name.lower() in _HOP_BY_HOP:
            continue
        lines.append(f"{name}: {value}")
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def _split_authority(target: str, *, default_port: int) -> tuple[str, int]:
    """host:port -> (host, port); IPv6 literals are bracketed."""
    if target.startswith("["):
        host, _, rest = target[1:].partition("]")
        port = rest.lstrip(":")
        return host, int(port) if port.isdigit() else default_port
    host, _, port = target.rpartition(":")
    if not host:
        return target, default_port
    return host, int(port) if port.isdigit() else default_port
