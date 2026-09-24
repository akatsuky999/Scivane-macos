"""批准通道：一次工具调用批不批，由用户在界面上回答。

**现在走这条通道的只有书房的 `delete_project`**（删掉一个项目连同原稿副本与会话历史，
不可撤销）。读者那一层一个要批准的工具都没有：装包与取代码都搬进了
沙箱、经同一个审计代理出网，与沙箱内的每条命令没有区别 —— 而沙箱内的命令不该逐次确认，
那只会训练用户无脑点同意。

从前这条通道是为 `fetch_repo` 接通的（它那时在宿主端联网）；机制原样保留，
读者那一路的接线也还在 —— 将来真有越出沙箱的读者工具，它会被问到，而不是被悄悄放行。

**三条设计取舍：**

**超时按拒绝，不按同意。** 用户没在看、窗口被挡住、App 被切到后台，
都会让请求等到超时。这种情况下「默认允许」意味着一次没人看见的不可逆动作
悄悄发生了 —— 而批准这道门留给的正是那些动作。宁可让 agent 多问一次。
（当初这一条写的是「没人看见的联网」；联网现在由审计代理记账，不再走这道门。）

**一个 key 只能被回答一次。** 重复回答（用户连点两下、客户端重发）直接忽略，
不是报错 —— 重试本身无害，但把第二次答案覆盖上去会让日志里的裁决与实际
执行的不一致。

**通道不知道「工具」是什么。** 它只认一个 key 和一个布尔值加理由。
采用 deny → ask → 自查 的判定顺序，但不引入额外的规则语言 ——
我们的任务可枚举，需要回答的只有
「这一次调用批不批」。
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

__all__ = ["ApprovalBroker", "APPROVAL_TIMEOUT", "TIMED_OUT_REASON"]

#: 等用户多久。给足看清「要删的是哪一个」的时间，又不至于让一轮请求挂到天亮。
APPROVAL_TIMEOUT = 120.0

TIMED_OUT_REASON = "等待超时，按拒绝处理"


@dataclass
class ApprovalBroker:
    """按 key 索引的一次性批准通道。

    key 用 `f"{job_id}:{call_id}"`：call_id 来自模型，跨任务撞号并非不可能，
    而撞号的后果是把另一轮的裁决用到这一轮上。
    """

    timeout: float = APPROVAL_TIMEOUT
    _waiting: dict[str, asyncio.Future[tuple[bool, str]]] = field(default_factory=dict)

    async def request(self, key: str) -> tuple[bool, str]:
        """等一个裁决。超时按拒绝。

        :returns: ``(是否批准, 理由)``
        """
        loop = asyncio.get_running_loop()
        future: asyncio.Future[tuple[bool, str]] = loop.create_future()
        self._waiting[key] = future
        try:
            return await asyncio.wait_for(future, timeout=self.timeout)
        except asyncio.TimeoutError:
            return False, TIMED_OUT_REASON
        finally:
            self._waiting.pop(key, None)

    def resolve(self, key: str, approved: bool, reason: str = "") -> bool:
        """回答一个等待中的请求。

        :returns: 是否真的落到了一个等待者上。False 表示没有这个请求、
            已经被回答过、或者已经超时 —— 客户端据此知道自己点晚了。
        """
        future = self._waiting.get(key)
        if future is None or future.done():
            return False
        future.set_result((approved, reason))
        return True

    def abandon(self, prefix: str) -> int:
        """任务结束或被取消时，把它名下还在等的请求全部按拒绝了结。

        不了结的话循环会挂在那里等到超时才退出，取消看起来像没生效。
        """
        count = 0
        for key in [k for k in self._waiting if k.startswith(prefix)]:
            future = self._waiting.get(key)
            if future is not None and not future.done():
                future.set_result((False, "这一轮已经结束"))
                count += 1
        return count


#: 进程内单例。路由与循环共用它。
approvals = ApprovalBroker()
