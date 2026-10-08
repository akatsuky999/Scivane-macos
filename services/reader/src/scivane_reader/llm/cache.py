"""Prompt caching: capability declarations and breakpoint planning.

The paper's Markdown (30-100k tokens) is byte-identical for the whole conversation, so the
static part must come first and never change: no timestamps, reordering or whitespace edits
in the prefix.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import Enum

from .types import CallRequest, ImageBlock, TextBlock


class CacheCapability(Enum):
    """How a protocol supports prompt caching."""

    NONE = "none"

    #: automatic prefix caching (OpenAI, DeepSeek); we only keep the prefix byte-stable
    IMPLICIT_PREFIX = "implicit_prefix"

    #: cache_control markers on content blocks (Anthropic), at most 4
    EXPLICIT_BREAKPOINT = "explicit_breakpoint"

    #: a separate cached-content object with its own TTL and lifecycle (Gemini)
    EXPLICIT_OBJECT = "explicit_object"


#: Below this prefix length Anthropic silently ignores cache markers; checking ourselves makes
#: it visible in the logs.
MIN_CACHEABLE_TOKENS = 1024


def rough_tokens(text: str) -> int:
    """Rough token estimate, only for deciding whether a breakpoint is worth it
    (about 4 characters per token, one per CJK character).
    """
    cjk = sum(1 for ch in text if "一" <= ch <= "鿿" or "぀" <= ch <= "ヿ")
    return cjk + (len(text) - cjk) // 4


def block_text(block: TextBlock | ImageBlock) -> str:
    if isinstance(block, TextBlock):
        return block.text
    # images get a conservative fixed size so they aren't judged too short to cache
    return " " * (MIN_CACHEABLE_TOKENS * 4)


@dataclass(frozen=True)
class CachePlan:
    cache_system: bool = False
    #: index of the message to mark, or None
    message_breakpoint: int | None = None

    @property
    def has_breakpoint(self) -> bool:
        return self.cache_system or self.message_breakpoint is not None


def plan_cache(request: CallRequest, capability: CacheCapability) -> CachePlan:
    """Plan breakpoints. Only EXPLICIT_BREAKPOINT needs markers; other capabilities get an empty plan."""
    if capability is not CacheCapability.EXPLICIT_BREAKPOINT:
        return CachePlan()

    # system and the static message prefix are separate cacheable spans, one breakpoint each
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
            # mark the last static message: the provider caches everything up to the marker
            breakpoint_index = request.cacheable_prefix - 1

    return CachePlan(cache_system=cache_system, message_breakpoint=breakpoint_index)


def prefix_fingerprint(request: CallRequest) -> str:
    """Fingerprint of the static prefix. If it changes between turns while the content looks the same,
    something put a timestamp into the prefix.
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
