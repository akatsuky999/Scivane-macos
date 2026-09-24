"""本地审计代理：让 agent 能联网，但每一次出网都留下痕迹。

**为什么是单独一个子包，不放进 `sandbox/`。** 那一层的契约是「不知道论文、
项目、agent 是什么」—— 它只认得「一个进程、一套策略」。而这一层要按
`(job_id, call_id)` 归因、要把主机冒到对话界面上，天生知道 agent 的存在。
两件事放一起，沙箱那层就再也换不掉了（Seatbelt 会消失，
所以那一层必须是能替换的）。

**每个模块只管一件事：**

- `grants` —— 谁可以用这个代理（按工具调用签发，随调用作废）
- `destinations` —— 可以连到哪里（从第二侧关上回环这个口子）
- `server` —— 连接本身（不做 MITM，只数字节）
- `audit` —— 记下什么（主机、端口、方法、字节数；**绝不记路径与查询串**）
- `access` —— 工具层看得见的那一小块（端口 + token + 这次被拦了什么）
"""

from .access import REASONS, CallNetwork, NetworkAccess, Refusal
from .audit import AuditLog, Entry, NetworkRecord
from .destinations import ForbiddenDestination, resolve, why_forbidden
from .grants import Grant, GrantBook
from .server import AuditProxy

__all__ = [
    "CallNetwork", "NetworkAccess", "Refusal", "REASONS",
    "AuditLog", "Entry", "NetworkRecord",
    "ForbiddenDestination", "resolve", "why_forbidden",
    "Grant", "GrantBook",
    "AuditProxy",
]
