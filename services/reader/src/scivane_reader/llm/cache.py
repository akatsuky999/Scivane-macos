"""Prompt 缓存：能力声明与断点规划。

**为什么这是一等公民而不是后期优化。**

Scivane 的核心场景是「一篇论文 = 一个项目」：那份 OCR 出来的 Markdown 有
3–10 万 token，在整个会话里逐字节不变。每轮对话全量重发的话，成本与首
token 延迟都不可接受；而它恰好是各家 prompt 缓存的理想输入 —— 用好缓存
可以把成本降一个数量级。

缓存反过来约束了消息该怎么组装：**静态部分必须在最前，且逐字节稳定。**
不能在前缀里插时间戳、不能重排、不能顺手改空白。这条纪律如果等到后期
再补，会推翻整个消息组装方式，所以从第一版就写进类型里。
（把前缀缓存直接写进架构约束。）

三家厂商的机制完全不同，用能力声明统一：
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import Enum

from .types import CallRequest, ImageBlock, TextBlock


class CacheCapability(Enum):
    """一套协议如何支持 prompt 缓存。"""

    #: 不支持。请求照发，不做任何缓存处理。
    NONE = "none"

    #: 自动前缀缓存（OpenAI、DeepSeek 等）。不需要打标记，
    #: 我们唯一的责任是保证前缀字节稳定。
    IMPLICIT_PREFIX = "implicit_prefix"

    #: 显式断点（Anthropic）。要在内容块上打 cache_control 标记，
    #: 最多 4 个断点。
    EXPLICIT_BREAKPOINT = "explicit_breakpoint"

    #: 显式缓存对象（Gemini 的 CachedContent）。要先创建缓存对象拿到
    #: 名字，再在请求里引用，还得管 TTL 与销毁。
    EXPLICIT_OBJECT = "explicit_object"


#: 低于这个 token 数的前缀不值得打断点。
#:
#: Anthropic 对最小可缓存长度有硬性要求（各模型 1024–2048 token 不等），
#: 低于阈值时标记会被静默忽略 —— 不报错，但也不生效。与其让它静默失效，
#: 不如我们自己先判断，日志里能看出「这次没缓存是因为太短」。
MIN_CACHEABLE_TOKENS = 1024


def rough_tokens(text: str) -> int:
    """粗略估算 token 数。

    只用来判断「值不值得打断点」，不用于计费，所以不必精确。
    英文约 4 字符 1 token，中日韩字符约 1 字符 1 token。
    """
    cjk = sum(1 for ch in text if "一" <= ch <= "鿿" or "぀" <= ch <= "ヿ")
    return cjk + (len(text) - cjk) // 4


def block_text(block: TextBlock | ImageBlock) -> str:
    """取内容块里参与长度估算的文本。图片按固定开销折算。"""
    if isinstance(block, TextBlock):
        return block.text
    # 图片不是文本，给一个保守的等效长度，避免把「一张图」误判成不值得缓存
    return " " * (MIN_CACHEABLE_TOKENS * 4)


@dataclass(frozen=True)
class CachePlan:
    """这次请求该怎么落地缓存。"""

    #: 是否给 system 段打缓存标记。
    cache_system: bool = False
    #: 给 messages 的哪一条打标记（下标）。None 表示不打。
    message_breakpoint: int | None = None

    @property
    def has_breakpoint(self) -> bool:
        return self.cache_system or self.message_breakpoint is not None


def plan_cache(request: CallRequest, capability: CacheCapability) -> CachePlan:
    """规划断点位置。

    只有 EXPLICIT_BREAKPOINT 需要真的打点；其余能力返回空计划：
    IMPLICIT_PREFIX 靠前缀稳定自动生效，EXPLICIT_OBJECT 走另一套生命周期，
    NONE 则什么都不做。
    """
    if capability is not CacheCapability.EXPLICIT_BREAKPOINT:
        return CachePlan()

    # system 与静态消息前缀是两段独立的可缓存内容，各给一个断点。
    # 两个断点远在 4 个的上限之内，不必吝啬。
    cache_system = (
        request.system is not None
        and rough_tokens(request.system) >= MIN_CACHEABLE_TOKENS
    )

    breakpoint_index: int | None = None
    if request.cacheable_prefix > 0:
        prefix_chars = "".join(
            block_text(block)
            for message in request.messages[: request.cacheable_prefix]
            for block in message.content
        )
        if rough_tokens(prefix_chars) >= MIN_CACHEABLE_TOKENS:
            # 标记打在静态前缀的**最后一条**上：厂商缓存的是"到这里为止"的全部内容
            breakpoint_index = request.cacheable_prefix - 1

    return CachePlan(cache_system=cache_system, message_breakpoint=breakpoint_index)


def prefix_fingerprint(request: CallRequest) -> str:
    """静态前缀的指纹。

    缓存能不能命中，全看这个值在多轮之间是否不变。把它算出来有两个用处：
    单测可以直接断言前缀稳定，线上日志可以在缓存意外失效时定位到是哪一轮
    动了前缀。指纹变了而内容"看起来没变"，通常就是有人在前缀里插了时间戳。
    """
    hasher = hashlib.sha256()
    hasher.update((request.model or "").encode("utf-8"))
    hasher.update(b"\x00")
    hasher.update((request.system or "").encode("utf-8"))
    for message in request.messages[: request.cacheable_prefix]:
        hasher.update(b"\x00")
        hasher.update(message.role.encode("utf-8"))
        for block in message.content:
            hasher.update(b"\x01")
            if isinstance(block, TextBlock):
                hasher.update(b"t")
                hasher.update(block.text.encode("utf-8"))
            else:
                hasher.update(b"i")
                hasher.update(block.media_type.encode("utf-8"))
                hasher.update(block.data.encode("utf-8"))
    return hasher.hexdigest()[:16]
