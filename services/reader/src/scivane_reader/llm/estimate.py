"""Rough request size by part: system prompt, tool schemas, each message.

An estimate, not billing. Callers calibrate it against the provider-reported input
(projects/meter.py); it only has to be consistent.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from .cache import rough_tokens
from .types import CallRequest, ContentBlock, ImageBlock, Message, TextBlock, ToolResultBlock, ToolSchema, ToolUseBlock

__all__ = [
    "IMAGE_TOKENS", "RequestEstimate",
    "estimate_block", "estimate_message", "estimate_messages", "estimate_tools", "estimate_request",
]

#: Vendors vary widely (hundreds to over a thousand); calibration absorbs the error.
IMAGE_TOKENS = 1000


def estimate_block(block: ContentBlock) -> int:
    if isinstance(block, TextBlock):
        return rough_tokens(block.text)
    if isinstance(block, ImageBlock):
        return IMAGE_TOKENS
    if isinstance(block, ToolUseBlock):
        # the model sees the tool name plus its JSON arguments
        return rough_tokens(block.name) + rough_tokens(json.dumps(block.arguments, ensure_ascii=False))
    if isinstance(block, ToolResultBlock):
        return rough_tokens(block.content)
    return 0


def estimate_message(message: Message) -> int:
    return sum(estimate_block(block) for block in message.content)


def estimate_messages(messages: tuple[Message, ...] | list[Message]) -> int:
    return sum(estimate_message(message) for message in messages)


def estimate_tools(tools: tuple[ToolSchema, ...]) -> int:
    if not tools:
        return 0
    return rough_tokens(json.dumps([tool.as_dict() for tool in tools], ensure_ascii=False))


@dataclass(frozen=True)
class RequestEstimate:
    """Per-part estimate of one request; `messages` lines up with the request's messages."""

    system: int
    tools: int
    messages: tuple[int, ...]

    @property
    def total(self) -> int:
        return self.system + self.tools + sum(self.messages)

    def span(self, start: int, stop: int | None = None) -> int:
        return sum(self.messages[start:stop])


def estimate_request(request: CallRequest) -> RequestEstimate:
    return RequestEstimate(
        system=rough_tokens(request.system or ""),
        tools=estimate_tools(request.tools),
        messages=tuple(estimate_message(message) for message in request.messages),
    )
