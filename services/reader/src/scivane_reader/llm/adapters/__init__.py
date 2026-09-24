"""三套厂商协议，以及它们各自的能力。

按「协议而非厂商清单」的原则组织：这里只描述**协议**能做什么，不维护会
过期的厂商模型清单。厂商由配置表达（protocol + base_url + model），
所以接一家新厂商通常一行配置就够，不用改代码。

一套 OpenAI 兼容协议即可覆盖 OpenAI、DeepSeek、Kimi、智谱、通义、
硅基流动、Ollama、vLLM。
"""

from __future__ import annotations

from dataclasses import dataclass

from ..cache import CacheCapability
from .anthropic import AnthropicAdapter
from .base import ProtocolAdapter, SseDecoder, SseEvent, StreamTranslator, aiter_sse
from .gemini import GeminiAdapter
from .openai_compat import OpenAiCompatAdapter


@dataclass(frozen=True)
class ProtocolInfo:
    """一套协议的能力。给设置界面显示用，让用户知道选了它能得到什么。"""

    adapter: ProtocolAdapter
    #: 是否能回传推理过程。
    thinking: bool
    #: 是否支持图片输入。
    vision: bool
    #: 流式响应里是否带用量统计。
    streaming_usage: bool

    @property
    def cache(self) -> CacheCapability:
        return self.adapter.cache_capability

    def describe(self) -> dict[str, object]:
        return {
            "protocol": self.adapter.name,
            "cache": self.cache.value,
            "thinking": self.thinking,
            "vision": self.vision,
            "streaming_usage": self.streaming_usage,
            "default_base_url": self.adapter.default_base_url,
        }


PROTOCOLS: dict[str, ProtocolInfo] = {
    "openai": ProtocolInfo(
        adapter=OpenAiCompatAdapter(),
        thinking=True,   # DeepSeek reasoner 等把推理放在 reasoning_content
        vision=True,
        streaming_usage=True,
    ),
    "anthropic": ProtocolInfo(
        adapter=AnthropicAdapter(),
        thinking=True,
        vision=True,
        streaming_usage=True,
    ),
    "gemini": ProtocolInfo(
        adapter=GeminiAdapter(),
        thinking=True,
        vision=True,
        streaming_usage=True,
    ),
}


def get_adapter(protocol: str) -> ProtocolAdapter | None:
    info = PROTOCOLS.get(protocol)
    return info.adapter if info is not None else None


__all__ = [
    "PROTOCOLS", "ProtocolInfo", "get_adapter",
    "ProtocolAdapter", "StreamTranslator", "SseEvent", "SseDecoder", "aiter_sse",
    "OpenAiCompatAdapter", "AnthropicAdapter", "GeminiAdapter",
]
