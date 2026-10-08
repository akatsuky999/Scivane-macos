"""Vendor-neutral messages and stream vocabulary.

Every stream ends with exactly one Finish, for success and failure alike, so callers never
need try/except to tell the two apart.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, TypeAlias

from .errors import LlmFailure

Role: TypeAlias = Literal["user", "assistant"]

#: Background requests (titles, summaries) don't compete with the foreground for retries.
Purpose: TypeAlias = Literal["foreground", "background"]


@dataclass(frozen=True)
class TextBlock:
    text: str


@dataclass(frozen=True)
class ImageBlock:
    data: str
    media_type: str = "image/png"


@dataclass(frozen=True)
class ToolUseBlock:
    id: str
    name: str
    arguments: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class ToolResultBlock:
    """A tool result, carried in a user message (Anthropic's shape, which allows several results
    per message). Adapters translate it for OpenAI (tool role) and Gemini (functionResponse).
    """

    call_id: str
    content: str
    is_error: bool = False


ContentBlock: TypeAlias = TextBlock | ImageBlock | ToolUseBlock | ToolResultBlock


@dataclass(frozen=True)
class Message:
    role: Role
    content: tuple[ContentBlock, ...]

    @staticmethod
    def text(role: Role, text: str) -> Message:
        return Message(role=role, content=(TextBlock(text),))


@dataclass(frozen=True)
class ToolSchema:
    """Everything the model sees about a tool. Host-side policy (concurrency, limits, approval)
    lives in tools/definition.py and never reaches the prompt.
    """

    name: str
    description: str
    #: JSON Schema (object)
    parameters: dict[str, object] = field(default_factory=dict)

    def as_dict(self) -> dict[str, object]:
        return {
            "name": self.name,
            "description": self.description,
            "parameters": self.parameters or {"type": "object", "properties": {}},
        }


@dataclass(frozen=True)
class Usage:
    """Token usage of one request. Cache reads and writes are tracked separately: they are billed
    very differently and whether the cache works is what we watch.
    """

    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    #: Input the model actually saw, cache included: how full the context was. Filled in by the
    #: adapters because vendors count differently; 0 means not reported.
    prompt_tokens: int = 0

    def merged(self, other: Usage) -> Usage:
        """Merge two reports. The sums are cumulative for a turn, which is cost, not context size."""
        return Usage(
            input_tokens=self.input_tokens + other.input_tokens,
            output_tokens=self.output_tokens + other.output_tokens,
            cache_read_tokens=self.cache_read_tokens + other.cache_read_tokens,
            cache_write_tokens=self.cache_write_tokens + other.cache_write_tokens,
            prompt_tokens=self.prompt_tokens + other.prompt_tokens,
        )

    def as_dict(self) -> dict[str, int]:
        return {
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "cache_write_tokens": self.cache_write_tokens,
            "prompt_tokens": self.prompt_tokens,
        }


@dataclass(frozen=True)
class TextDelta:
    text: str


@dataclass(frozen=True)
class ThinkingDelta:
    text: str


@dataclass(frozen=True)
class ToolCall:
    """A complete tool call. Not streamed: half a JSON is useless to the scheduler."""

    id: str
    name: str
    arguments: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class UsageUpdate:
    usage: Usage


@dataclass(frozen=True)
class Finish:
    """Terminal chunk; exactly one per stream.

    kind is stop | tool_use | length | error | aborted (the last two carry `failure`).
    tool_use is its own kind so the loop never has to infer it from the content.
    """

    kind: Literal["stop", "tool_use", "length", "error", "aborted"]
    failure: LlmFailure | None = None
    usage: Usage | None = None

    def __post_init__(self) -> None:
        if self.kind in ("error", "aborted") and self.failure is None:
            raise ValueError(f"{self.kind} 终态必须携带 failure")


StreamChunk: TypeAlias = TextDelta | ThinkingDelta | ToolCall | UsageUpdate | Finish


#: medium rather than low: checking that formulas and code agree needs real reasoning.
REASONING_DEFAULT = "medium"
#: "none" isn't supported by every vendor; see the adapters.
REASONING_LEVELS = ("none", "low", "medium", "high")


@dataclass(frozen=True)
class CallRequest:
    """One model call. Frozen so the cacheable prefix can be trusted."""

    model: str
    messages: tuple[Message, ...]
    system: str | None = None
    max_tokens: int | None = None
    temperature: float | None = None

    #: The first N messages are static context (the paper), byte-identical for the whole
    #: conversation; adapters place cache points from it (see cache.py).
    cacheable_prefix: int = 0

    #: model-visible fields only (see ToolSchema)
    tools: tuple[ToolSchema, ...] = ()

    #: Vendor-neutral reasoning budget, translated by each adapter. Always sent explicitly:
    #: reasoning models tend to think for a long time by default.
    reasoning: str | None = None

    purpose: Purpose = "foreground"

    #: extra vendor-specific fields, passed through as is
    extra: dict[str, object] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.model:
            raise ValueError("model 不能为空")
        if self.cacheable_prefix < 0 or self.cacheable_prefix > len(self.messages):
            raise ValueError(
                f"cacheable_prefix={self.cacheable_prefix} 超出消息数 {len(self.messages)}"
            )
