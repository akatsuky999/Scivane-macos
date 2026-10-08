"""Destination checks: closing the loopback hole from the proxy side.

The proxy runs outside the sandbox and can reach anything on this machine, including Scivane's
unauthenticated API (8710) and llama-server (8111). So destinations resolving to loopback,
link-local, RFC 1918 or unique-local addresses are refused. The resolved IP is checked, not the
name (public names can resolve to 127.0.0.1), and the caller connects to the checked address
itself, so DNS rebinding can't swap it.
"""

from __future__ import annotations

import ipaddress
import socket

__all__ = ["ForbiddenDestination", "resolve", "why_forbidden"]


class ForbiddenDestination(Exception):
    """Forbidden destination; `code` is stable and reaches both the audit log and the model."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


#: Refused networks, listed one by one with what each protects. Not ip.is_private: that also
#: covers 198.18.0.0/15, which fake-IP VPNs use for the whole internet.
_REFUSED: tuple[tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, str], ...] = tuple(
    (ipaddress.ip_network(cidr), code) for cidr, code in (
        # this machine: the unauthenticated API and llama-server live here
        ("127.0.0.0/8", "LOOPBACK"),
        ("::1/128", "LOOPBACK"),
        # cloud metadata services live at 169.254.169.254
        ("169.254.0.0/16", "LINK_LOCAL"),
        ("fe80::/10", "LINK_LOCAL"),
        # LAN: routers, NAS, printers, other machines
        ("10.0.0.0/8", "PRIVATE"),
        ("172.16.0.0/12", "PRIVATE"),
        ("192.168.0.0/16", "PRIVATE"),
        ("fc00::/7", "PRIVATE"),
        # Tailscale-style mesh networks: still the user's own machines
        ("100.64.0.0/10", "PRIVATE"),
        ("0.0.0.0/8", "UNSPECIFIED"),
        ("::/128", "UNSPECIFIED"),
        ("224.0.0.0/4", "MULTICAST"),
        ("ff00::/8", "MULTICAST"),
    )
)

#: 198.18.0.0/15 is deliberately allowed. Fake-IP VPNs (Clash, Surge, sing-box in TUN mode) map
#: every domain into it, so on such machines it is the internet; it never leads back to this machine.

def why_forbidden(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> str:
    for network, code in _REFUSED:
        if ip.version == network.version and ip in network:
            return code
    return ""


def resolve(host: str, port: int) -> list[tuple[int, int, int, str, tuple]]:
    """Resolve and check every address; returns the getaddrinfo entries to connect to.

    One forbidden result refuses the whole name: a name resolving to both public and loopback
    addresses is an attack shape, not a configuration.
    """
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise ForbiddenDestination("DNS_FAILED", f"解析不了 {host}：{exc}") from exc
    if not infos:
        raise ForbiddenDestination("DNS_FAILED", f"解析不了 {host}")

    for family, _type, _proto, _canon, sockaddr in infos:
        try:
            ip = ipaddress.ip_address(sockaddr[0])
        except ValueError:  # pragma: no cover - getaddrinfo never returns this
            raise ForbiddenDestination("DNS_FAILED", f"解析不了 {host}") from None
        reason = why_forbidden(ip)
        if reason:
            # Never include the resolved internal address: echoing it would complete the probe.
            raise ForbiddenDestination(
                reason, f"{host} 指向不允许访问的地址（{reason}），沙箱只允许连到外网"
            )
    return infos
