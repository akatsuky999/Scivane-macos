"""保护策略：超时、重试、退避。

参数经过真实多厂商流量检验；前台与后台不共享重试预算。

**最容易踩的一条坑，写在最前面：**

    重试只在「尚未产出任何内容」时安全。

流已经吐出 token 之后再重试，用户会看到重复的内容 —— 而且这种 bug 只在
网络抖动时才出现，极难复现。所以本模块的 `is_retryable()` 强制要求传入
`emitted_content`，而不是把它做成可选参数：调用方必须正面回答这个问题。
"""

from __future__ import annotations

import email.utils
import random
from dataclasses import dataclass, field
from typing import Final

from .errors import (
    EMPTY_RESPONSE,
    RATE_LIMIT,
    SERVER,
    TIMEOUT,
    TRANSPORT,
    LlmFailure,
)
from .types import Purpose

# --- 超时 ---------------------------------------------------------------

@dataclass(frozen=True)
class Timeouts:
    """分离的超时。

    用单一总超时是不行的：论文问答的回答可能持续好几分钟，一个能容纳它的
    总超时（比如 10 分钟）意味着一次 DNS 故障也要挂 10 分钟才报错。所以
    连接、首 token、整流三段分开设。
    """

    #: 建立连接。网络正常时这一步是毫秒级，给 10 秒足够宽松。
    connect: float = 10.0
    #: 从发出请求到收到第一个 token。厂商排队时这一段会长，给 120 秒。
    first_token: float = 120.0
    #: 整个流的上限。长回答确实会很久，给 30 分钟兜底防止永久挂起。
    total: float = 1800.0


DEFAULT_TIMEOUTS: Final = Timeouts()


# --- 重试策略 -----------------------------------------------------------

#: 默认可重试的失败码。
#:
#: 共同点是「同样的请求再发一次有理由成功」：限流会过去、5xx 通常是暂时的、
#: 超时和连接错误可能是网络抖动、空响应是厂商的退化行为。
DEFAULT_RETRYABLE: Final = frozenset({
    EMPTY_RESPONSE, RATE_LIMIT, SERVER, TIMEOUT, TRANSPORT,
})

#: 后台任务可重试的失败码 —— 刻意比前台窄。
#:
#: RATE_LIMIT 与 SERVER 都是「厂商现在没容量」。这种时候后台任务（生成标题、
#: 摘要）继续重试，就是在跟用户正在等的那个问题抢配额。后台的正确行为是
#: 干脆放弃，等下次再说。
BACKGROUND_RETRYABLE: Final = frozenset({TIMEOUT, TRANSPORT, EMPTY_RESPONSE})


@dataclass(frozen=True)
class RetryPolicy:
    """一条路由的重试行为。"""

    max_retries: int = 5
    initial_delay: float = 0.5
    max_delay: float = 10.0
    #: 围绕每次延迟的对称抖动比例。多个客户端同时被限流时，
    #: 没有抖动会让它们在同一毫秒一起重试，把厂商再打一次。
    jitter_ratio: float = 0.1
    retryable_codes: frozenset[str] = field(default_factory=lambda: DEFAULT_RETRYABLE)
    background_retryable_codes: frozenset[str] = field(
        default_factory=lambda: BACKGROUND_RETRYABLE
    )
    #: 后台任务的重试次数上限，通常远小于前台。
    background_max_retries: int = 1

    def budget(self, purpose: Purpose) -> int:
        return (
            self.max_retries if purpose == "foreground" else self.background_max_retries
        )

    def eligible_codes(self, purpose: Purpose) -> frozenset[str]:
        return (
            self.retryable_codes
            if purpose == "foreground"
            else self.background_retryable_codes
        )


DEFAULT_POLICY: Final = RetryPolicy()


def is_retryable(
    failure: LlmFailure,
    *,
    attempt: int,
    emitted_content: bool,
    policy: RetryPolicy = DEFAULT_POLICY,
    purpose: Purpose = "foreground",
) -> bool:
    """这次失败该不该重试。

    :param attempt: 已经进行过的尝试次数（首次请求为 1）。
    :param emitted_content: 本次尝试是否已经向调用方产出过内容。
        为 True 时一律不重试 —— 见模块开头那条纪律。
    """
    if emitted_content:
        return False
    if attempt > policy.budget(purpose):
        return False
    return failure.code in policy.eligible_codes(purpose)


def compute_delay(
    attempt: int,
    *,
    policy: RetryPolicy = DEFAULT_POLICY,
    retry_after: float | None = None,
    rng: random.Random | None = None,
) -> float:
    """算出这次该等多久。

    厂商给了 `Retry-After` 就优先采纳它 —— 厂商比我们更清楚自己什么时候
    恢复。但**必须落在 max_delay 界内**：某些厂商会返回几小时的值，直接
    照办等于把这个请求挂死，用户只会看到界面永远转圈。超界时退回本地退避。
    """
    if retry_after is not None and 0 <= retry_after <= policy.max_delay:
        return retry_after

    # 指数退避：0.5s, 1s, 2s, 4s, 8s, 封顶 10s
    base = min(policy.initial_delay * (2 ** max(0, attempt - 1)), policy.max_delay)
    if policy.jitter_ratio <= 0:
        return base
    source = rng if rng is not None else random
    factor = 1.0 + source.uniform(-policy.jitter_ratio, policy.jitter_ratio)
    return max(0.0, base * factor)


def parse_retry_after(raw: str | None) -> float | None:
    """解析 Retry-After 响应头。

    HTTP 规定它既可以是秒数，也可以是一个 HTTP 日期，两种都要认。
    解析不了就返回 None，让本地退避接手 —— 绝不让一个畸形的头把请求搞崩。
    """
    if not raw:
        return None
    text = raw.strip()
    try:
        seconds = float(text)
    except ValueError:
        pass
    else:
        return seconds if seconds >= 0 else None

    try:
        when = email.utils.parsedate_to_datetime(text)
    except (TypeError, ValueError):
        return None
    if when is None:
        return None
    import datetime as _dt

    now = _dt.datetime.now(_dt.timezone.utc)
    if when.tzinfo is None:
        when = when.replace(tzinfo=_dt.timezone.utc)
    delta = (when - now).total_seconds()
    return max(0.0, delta)
