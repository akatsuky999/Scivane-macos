"""审计记录：agent 到达过哪些主机。

**这一层的全部价值在于「记什么」与「不记什么」。**

记：主机、端口、方法、字节数、归属于哪一次工具调用、放行还是拒绝。
**不记：路径与查询串。** 这不是省事，是红线 —— API key 不进日志，而查询串
正是 token 最常见的藏身处（`?access_token=…`、`?key=…`、预签名 URL 的整串凭据）。
一旦路径进了审计，日志文件就从「agent 去过哪」变成「一份凭据副本」，
而它会跟着 `~/.scivane/var/logs/` 一起被打包、被贴进 issue、被 agent 自己读到。

所以 `NetworkRecord` **在结构上就没有放路径的地方**，而不是靠调用方自觉不传。
有一条测试盯着这件事（字段表 + 带查询串的真实请求走一遍，断言整条记录的
文本里不出现那串查询）—— 靠人记得是靠不住的。
"""

from __future__ import annotations

import contextlib
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass, field, replace

__all__ = ["NetworkRecord", "AuditLog", "Entry"]


@dataclass(frozen=True)
class NetworkRecord:
    """一次经代理的连接。**字段表本身就是承诺，不要往里加路径类字段。**"""

    #: 归属：哪一次工具调用发起的。token 这个机制同时干了认证和归因两件事，
    #: 「agent 刚访问了 X」因此是诚实的 —— 不是猜的，是它拿着那一次的凭据来的。
    job_id: str
    call_id: str
    #: 目的地。CONNECT 只看得到这两样，普通 HTTP 也只取这两样。
    host: str
    port: int
    #: 方法。CONNECT 隧道就是 "CONNECT"，不做 MITM 所以看不到里面的方法。
    method: str
    allowed: bool
    #: 拒绝的原因（稳定 code），放行时为空。
    reason: str = ""
    #: 上下行字节数。隧道里看不懂内容，但数得清字节 —— 这是不做 MITM 的前提下
    #: 还能给出的、关于「传了多少东西」的唯一事实。
    bytes_up: int = 0
    bytes_down: int = 0
    started_at: float = field(default_factory=time.time)
    elapsed: float = 0.0

    def as_dict(self) -> dict[str, object]:
        return asdict(self)

    @property
    def target(self) -> str:
        """给界面看的一行：`example.com:443`。**只有主机和端口。**"""
        return f"{self.host}:{self.port}"


@dataclass
class Entry:
    """一条已经落簿的记录的把手。收尾时用它补字节数。"""

    log: "AuditLog"
    record: NetworkRecord
    #: 这是不是本次工具调用到达的第一个主机 —— 界面那张显眼的卡只出一次。
    first: bool


class AuditLog:
    """进程内的审计簿。

    **刻意只放在内存里，不落盘。** 落盘要回答保留多久、谁能读、怎么轮转，
    而这里要回答的问题是「agent 实际到达哪些主机」—— 那是给界面和
    「要不要加 web_search」这类判断用的，一次会话的量级。真要长期留存是另一个产品决定，到时候再说。

    有上限，满了丢最旧的：一个跑疯了的循环不该把后端的内存吃光。
    """

    def __init__(self, limit: int = 2000) -> None:
        self._records: list[NetworkRecord] = []
        self._limit = limit
        #: 按 job_id 订阅的观察者。**一轮对话订一个，跑完就退订。**
        #:
        #: 为什么要观察者而不是让界面事后来查：记录在**连接建立**时就落簿，
        #: 而一次 clone 可能跑五分钟 —— 「agent 正在连 github.com」这件事
        #: 要在它发生的那一刻冒到界面上，不是五分钟后。
        self._watchers: dict[str, list[Callable[[Entry], None]]] = {}
        #: 每次工具调用第一个到达的主机 —— 界面那张「显眼但不阻塞」的卡
        #: 只在这里出一次。
        self._first_host: dict[str, str] = {}

    def add(self, record: NetworkRecord) -> Entry:
        """记一条，**在连接建立的那一刻，不等它结束**。

        字节数要到连接关掉才知道，但主机名在握手时就知道了。等到结束才记，
        界面上那张「第一个主机」的卡在一次十分钟的下载里就要等十分钟才出现 ——
        而它存在的意义正是「让人当场知道 agent 出网了」。所以先记，
        拿回一个 `Entry`，收尾时用 `settle()` 把字节数补上。
        """
        self._records.append(record)
        if len(self._records) > self._limit:
            del self._records[: len(self._records) - self._limit]
        key = f"{record.job_id}/{record.call_id}"
        first = key not in self._first_host
        if first:
            self._first_host[key] = record.host
        entry = Entry(log=self, record=record, first=first)
        for watcher in tuple(self._watchers.get(record.job_id, ())):
            # **观察者出错不许影响记账。** 界面那头断了连接是常事，
            # 让它把审计簿一起带崩就太脆了。
            try:
                watcher(entry)
            except Exception:  # noqa: BLE001
                pass
        return entry

    def settle(self, entry: Entry, *, bytes_up: int, bytes_down: int,
               elapsed: float) -> None:
        """连接结束，把字节数补进那条记录。

        记录是 frozen 的，所以换一条新的进去而不是改它 —— 审计条目在被读到
        的那一刻应该是一致的快照，半改完的记录比没有记录更难解释。
        条目可能已经被上限挤掉了，挤掉就算了，不必复活它。
        """
        try:
            index = self._records.index(entry.record)
        except ValueError:
            return
        self._records[index] = replace(
            entry.record, bytes_up=bytes_up, bytes_down=bytes_down, elapsed=elapsed
        )

    @contextlib.contextmanager
    def watching(self, job_id: str, callback: "Callable[[Entry], None]"):
        """这一轮对话期间盯着自己的网络记录。用 `finally` 退订。"""
        self._watchers.setdefault(job_id, []).append(callback)
        try:
            yield
        finally:
            watchers = self._watchers.get(job_id, [])
            if callback in watchers:
                watchers.remove(callback)
            if not watchers:
                self._watchers.pop(job_id, None)

    def records(self) -> tuple[NetworkRecord, ...]:
        return tuple(self._records)

    def refused(self, job_id: str, call_id: str) -> tuple[NetworkRecord, ...]:
        """某一次工具调用被拦下的连接，按发生顺序。**不含 407 握手**（NO_GRANT）。

        给工具结果用：模型只看得到 curl 的一句 `CONNECT tunnel failed, response 403`
        时会自己编原因（真机上编过「沙箱只放行 fetch_repo」）。按凭据归因查，
        所以一次调用只看得到自己的 —— 并发的另一个工具被拦了什么与它无关。

        NO_GRANT 本来就查不到（没有凭据的记录没有归属），这里再明着排除一次：
        它是认证握手的第一步，不是这次调用撞了哪条规则。
        """
        if not call_id:
            return ()
        return tuple(
            r for r in self._records
            if not r.allowed and r.reason != "NO_GRANT"
            and r.job_id == job_id and r.call_id == call_id
        )

    def hosts(self, *, job_id: str | None = None) -> tuple[str, ...]:
        """去重后的主机列表，按首次到达排序。给界面的折叠行用。"""
        seen: list[str] = []
        for r in self._records:
            if job_id is not None and r.job_id != job_id:
                continue
            if r.host not in seen:
                seen.append(r.host)
        return tuple(seen)

    def clear(self) -> None:
        self._records.clear()
        self._first_host.clear()
