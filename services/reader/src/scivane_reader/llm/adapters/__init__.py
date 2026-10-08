"""The three wire protocols and their capabilities.

Organised by protocol, not by vendor: a vendor is configuration (protocol, base URL, model).
The OpenAI-compatible protocol alone covers OpenAI, DeepSeek, Kimi, Zhipu, Qwen, SiliconFlow,
Ollama and vLLM.
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
    """What a protocol supports, shown in settings."""

    adapter: ProtocolAdapter
    thinking: bool
    vision: bool
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
        thinking=True,   # DeepSeek reasoner and others stream reasoning_content
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
