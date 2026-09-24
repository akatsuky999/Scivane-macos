"""目的地判定：**从第二侧关上回环这个口子。**

沙箱那一侧已经只开了一个针孔（一个回环端口）。但针孔后面站着
的就是这个代理，它**不在沙箱里**，能连到本机任何地方 —— 如果它肯替 agent 连，
那个针孔就等于开到了整个回环上。

回环上坐着什么：Scivane 自己的 API（8710，**没有任何鉴权**，
`POST /llm/providers/{id}/credential` 会把 API key 注入后端内存）、
llama-server（8111）、以及用户自己跑的任何东西。所以：

**目的地解析出来落在回环 / link-local / RFC1918 / 唯一本地地址上，一律拒绝。**

两个容易漏的地方，这里都堵了：

- **判的是解析后的 IP，不是主机名。** `localtest.me`、`spoof.example.com`
  这类公网域名可以解析到 127.0.0.1，只看名字挡不住。
- **连的就是判过的那个 IP。** 判完再让 socket 自己重新解析一次，中间那一下
  换个答案就绕过去了（DNS rebinding）。所以 `resolve()` 把判过的地址交回去，
  由调用方直接连它。
"""

from __future__ import annotations

import ipaddress
import socket

__all__ = ["ForbiddenDestination", "resolve", "why_forbidden"]


class ForbiddenDestination(Exception):
    """目的地不许去。`code` 是稳定的，进审计簿也进给模型的错误消息。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


#: 拒绝去的网段，**逐条列出，每条写明拦它的理由**。
#:
#: 第一版图省事用了 `ip.is_private` / `ip.is_reserved`，**实机上把整个互联网拦掉了**：
#: 在跑着 fake-IP 模式本地 VPN 的机器上，`github.com` 解析成
#: `198.18.0.30`，而 Python 的 `is_private` 对 `198.18.0.0/15` 返回 True ——
#: 于是 `git clone` 拿到 403，agent 还就此编了个错误的解释。
#:
#: 教训是：**`is_private` 不等于「内网」**。它覆盖 0.0.0.0/8、192.0.2.0/24（文档）、
#: 198.18.0.0/15（基准测试）、240.0.0.0/4 等一大串，其中大多数与「这台机器或这个
#: 局域网上的东西」毫无关系。一条拦截规则要能说出它在防谁，说不出就不该在这。
_REFUSED: tuple[tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, str], ...] = tuple(
    (ipaddress.ip_network(cidr), code) for cidr, code in (
        # 本机。**这一条是红线**：回环上坐着本产品没有鉴权的 API
        # （`/llm/providers/{id}/credential` 会把 key 注入后端内存）与 llama-server。
        ("127.0.0.0/8", "LOOPBACK"),
        ("::1/128", "LOOPBACK"),
        # 云厂商的元数据服务住在 169.254.169.254 —— 那是拿临时凭据的经典去处。
        ("169.254.0.0/16", "LINK_LOCAL"),
        ("fe80::/10", "LINK_LOCAL"),
        # 局域网：路由器后台、NAS、打印机、同一网段的别的机器。
        ("10.0.0.0/8", "PRIVATE"),
        ("172.16.0.0/12", "PRIVATE"),
        ("192.168.0.0/16", "PRIVATE"),
        ("fc00::/7", "PRIVATE"),
        # Tailscale 一类的网格网 —— 同样是「用户自己的别的机器」。
        ("100.64.0.0/10", "PRIVATE"),
        ("0.0.0.0/8", "UNSPECIFIED"),
        ("::/128", "UNSPECIFIED"),
        ("224.0.0.0/4", "MULTICAST"),
        ("ff00::/8", "MULTICAST"),
    )
)

#: **刻意不拦** `198.18.0.0/15`（RFC 2544 基准测试段）。
#:
#: 名义上它是给路由器压测用的，现实里它是 Clash / Surge / sing-box 这类本地 VPN
#: 在 TUN（fake-IP）模式下的地址池 —— 客户端把每个域名映射到这个段里的一个假地址，
#: 再由它自己转发到真实的远端。也就是说**这个段在这种机器上就是互联网**。
#: 拦掉它的后果是 GitHub、PyPI 一个都连不上（实测），而放行它并不会多开任何一条
#: 通往本机的路：VPN 映射的目的地是远端服务器，不是回环。

def why_forbidden(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> str:
    """这个地址为什么不许去。许去就返回空字符串。"""
    for network, code in _REFUSED:
        if ip.version == network.version and ip in network:
            return code
    return ""


def resolve(host: str, port: int) -> list[tuple[int, int, int, str, tuple]]:
    """解析并逐个判定，返回可以连的 `getaddrinfo` 条目。

    **任何一个解析结果落在禁区就整体拒绝**，不是「挑一个能用的连」。
    一个域名同时解析出公网地址和 127.0.0.1 时，挑着连等于把判定交给运气；
    而这种形状本身就是绕过的样子，不是正常配置。

    :raises ForbiddenDestination: 落在禁区，或者根本解析不出来。
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
        except ValueError:  # pragma: no cover —— getaddrinfo 不该给出这种东西
            raise ForbiddenDestination("DNS_FAILED", f"解析不了 {host}") from None
        reason = why_forbidden(ip)
        if reason:
            # **错误消息里不出现解析到的那个内网地址。** 说出来等于替 agent
            # 把内网探到的结果念一遍，探测就成功了一半。只说主机名和原因。
            raise ForbiddenDestination(
                reason, f"{host} 指向不允许访问的地址（{reason}），沙箱只允许连到外网"
            )
    return infos
