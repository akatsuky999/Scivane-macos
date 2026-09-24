"""稳定的失败分类。

**路由靠 code，绝不解析 message 文本。** 各厂商的错误措辞随时会变，
把判断建在文本上就是把产品建在流沙上。适配器的核心职责之一，就是把
厂商五花八门的 HTTP 状态码与错误体，映射成下面这一套码。

这套分类经过了真实多厂商流量的检验，路由层只认稳定 code。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Final

# --- 稳定失败码 ---------------------------------------------------------

#: 点名了一个没注册的 provider。
NO_ADAPTER: Final = "NO_ADAPTER"
#: 完全没有凭据。修法是去配一个。
MISSING_CREDENTIAL: Final = "MISSING_CREDENTIAL"
#: 有凭据但格式就不对（空串、带换行、明显截断）。修法是改掉存的值，
#: 不是再试一次 —— 所以它刻意不在可重试集合里。
INVALID_CREDENTIAL: Final = "INVALID_CREDENTIAL"
#: 凭据格式没问题，但厂商拒绝了（过期、被吊销、权限不够）。
AUTH: Final = "AUTH"
#: 限流。可重试。
RATE_LIMIT: Final = "RATE_LIMIT"
#: 厂商 5xx。可重试。
SERVER: Final = "SERVER"
#: 超时。可重试。
TIMEOUT: Final = "TIMEOUT"
#: 连接层面的错误（DNS、TLS、连接被重置）。可重试。
TRANSPORT: Final = "TRANSPORT"
#: 请求超过模型上下文窗口。重试无意义 —— 得先把输入变小。
CONTEXT_WINDOW_EXCEEDED: Final = "CONTEXT_WINDOW_EXCEEDED"
#: 余额或配额耗尽。重试只会继续失败。
QUOTA: Final = "QUOTA"
#: 正常结束但一个内容块都没有。
#:
#: 厂商偶尔会返回这种退化响应。必须当失败处理：如果放它过去，界面上就是
#: 「转了半天，然后这一轮悄无声息地结束了」，用户和上层都无从下手。
#: 这次尝试没有产出任何持久内容，所以重试是安全的。
EMPTY_RESPONSE: Final = "EMPTY_RESPONSE"
#: 请求参数不合法（模型名不存在、参数越界）。重试无意义。
INVALID_ARGS: Final = "INVALID_ARGS"
#: 被厂商的安全策略拦截。
#:
#: 与 EMPTY_RESPONSE 的区别至关重要：空响应是厂商的偶发退化，重试有意义；
#: 安全拦截是对这份输入的确定判断，重试多少次都是同样结果，只是在烧钱。
#: 两者在流层面都表现为「没有内容」，所以必须靠 finishReason 分开。
REFUSAL: Final = "REFUSAL"
#: 兜底：没能归类的失败。
UNKNOWN: Final = "UNKNOWN"

ALL_CODES: Final = frozenset({
    NO_ADAPTER, MISSING_CREDENTIAL, INVALID_CREDENTIAL, AUTH,
    RATE_LIMIT, SERVER, TIMEOUT, TRANSPORT,
    CONTEXT_WINDOW_EXCEEDED, QUOTA, EMPTY_RESPONSE, INVALID_ARGS,
    REFUSAL, UNKNOWN,
})


# --- 失败对象 -----------------------------------------------------------

@dataclass(frozen=True)
class LlmFailure:
    """一次失败的完整事实。消费方读 `code`，展示用 `message`。"""

    message: str
    code: str
    #: 厂商返回的 HTTP 状态码，仅供排查，不要拿它做路由。
    status: int | None = None
    #: 厂商建议的等待秒数（来自 Retry-After 头）。重试器会在界内采纳。
    retry_after: float | None = None

    def __post_init__(self) -> None:
        if self.code not in ALL_CODES:
            raise ValueError(f"未知失败码：{self.code}")


class LlmError(Exception):
    """携带稳定 code 的异常。跨层传递时不要丢掉 `failure`。"""

    def __init__(
        self,
        message: str,
        code: str,
        *,
        status: int | None = None,
        retry_after: float | None = None,
    ) -> None:
        super().__init__(message)
        self.failure = LlmFailure(
            message=message, code=code, status=status, retry_after=retry_after
        )

    @property
    def code(self) -> str:
        return self.failure.code


# --- 文本兜底识别 -------------------------------------------------------
#
# 只在结构化信息不足时才用这些正则。厂商给了明确的错误 code 就以那个为准。

_CONTEXT_OVERFLOW = re.compile(
    r"context[\s_-]?(?:length|window)[\s_-]?(?:exceed|overflow|limit)"
    r"|maximum[\s_-]context[\s_-]length"
    r"|(?:prompt|input|request|messages?)\s+(?:is\s+|are\s+)?too\s+(?:long|large)"
    r"|reduce\s+the\s+length\s+of\s+the\s+messages",
    re.IGNORECASE,
)

_QUOTA = re.compile(
    r"insufficient[\s_-]?(?:quota|balance|credit)"
    r"|quota[\s_-]?exceeded"
    r"|billing[\s_-]?(?:hard[\s_-]?)?limit"
    r"|exceeded\s+your\s+current\s+quota"
    r"|余额不足",
    re.IGNORECASE,
)


def looks_like_context_overflow(text: str) -> bool:
    """错误文本是否在说「上下文超了」。"""
    return bool(_CONTEXT_OVERFLOW.search(text))


def looks_like_quota_exhausted(text: str) -> bool:
    """错误文本是否在说「配额或余额没了」。"""
    return bool(_QUOTA.search(text))


def classify_status(status: int, detail: str = "") -> str:
    """把 HTTP 状态码映射成稳定失败码。

    这是所有适配器共用的默认规则；某个厂商有更精确的结构化信息时，
    应当在自己的适配器里先行判断，判断不出来再退到这里。

    `detail` 只用于区分同一状态码下的不同语义（400 既可能是参数错，
    也可能是上下文超限；429 既可能是限流，也可能是余额耗尽）。
    """
    if status == 400:
        if looks_like_context_overflow(detail):
            return CONTEXT_WINDOW_EXCEEDED
        if looks_like_quota_exhausted(detail):
            return QUOTA
        return INVALID_ARGS
    if status == 401:
        return AUTH
    if status == 403:
        # 有厂商用 403 表示余额耗尽，不都是权限问题
        return QUOTA if looks_like_quota_exhausted(detail) else AUTH
    if status == 404:
        # 模型名写错通常是 404，属于参数问题而不是"服务没了"
        return INVALID_ARGS
    if status == 413:
        return CONTEXT_WINDOW_EXCEEDED
    if status == 422:
        return CONTEXT_WINDOW_EXCEEDED if looks_like_context_overflow(detail) else INVALID_ARGS
    if status == 429:
        # 429 有两种含义，必须分开：限流可以等，配额耗尽等多久都没用
        return QUOTA if looks_like_quota_exhausted(detail) else RATE_LIMIT
    if status in (408, 504):
        return TIMEOUT
    if 500 <= status < 600:
        return SERVER
    return UNKNOWN
