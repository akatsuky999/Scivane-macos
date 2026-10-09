"""Anthropic Messages protocol.

Unlike OpenAI: max_tokens is required, caching needs explicit cache_control markers, and
overload arrives as an `error` event mid-stream rather than as an HTTP error.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from urllib.parse import quote

from ...i18n import ui
from ..cache import CacheCapability, plan_cache
from ..errors import (
    AUTH,
    CONTEXT_WINDOW_EXCEEDED,
    EMPTY_RESPONSE,
    INVALID_ARGS,
    RATE_LIMIT,
    SERVER,
    LlmFailure,
)
from ..types import (
    CallRequest,
    Finish,
    ImageBlock,
    Message,
    StreamChunk,
    TextBlock,
    TextDelta,
    ThinkingDelta,
    ToolCall,
    ToolResultBlock,
    ToolUseBlock,
    Usage,
    UsageUpdate,
)
from .base import ProtocolAdapter, SseEvent, StreamTranslator

#: required by the protocol; answers can be long
DEFAULT_MAX_TOKENS = 8192

_EPHEMERAL = {"type": "ephemeral"}

_ERROR_TYPES = {
    "invalid_request_error": INVALID_ARGS,
    "authentication_error": AUTH,
    "permission_error": AUTH,
    "not_found_error": INVALID_ARGS,
    "request_too_large": CONTEXT_WINDOW_EXCEEDED,
    "rate_limit_error": RATE_LIMIT,
    "api_error": SERVER,
    "overloaded_error": SERVER,
}


def _blocks(message: Message, cached: bool) -> list[dict[str, object]]:
    """Blocks in Anthropic's shape. With `cached`, the last block is marked: the cache covers
    everything up to the marker.
    """
    out: list[dict[str, object]] = []
    for block in message.content:
        if isinstance(block, TextBlock):
            out.append({"type": "text", "text": block.text})
        elif isinstance(block, ImageBlock):
            out.append({
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": block.media_type,
                    "data": block.data,
                },
            })
        elif isinstance(block, ToolUseBlock):
            out.append({
                "type": "tool_use", "id": block.id,
                "name": block.name, "input": block.arguments,
            })
        elif isinstance(block, ToolResultBlock):
            entry: dict[str, object] = {
                "type": "tool_result",
                "tool_use_id": block.call_id,
                "content": block.content,
            }
            if block.is_error:
                entry["is_error"] = True
            out.append(entry)
    if cached and out:
        out[-1]["cache_control"] = _EPHEMERAL
    return out


class AnthropicTranslator(StreamTranslator):
    def __init__(self) -> None:
        self._usage = Usage()
        self._stop_reason: str | None = None
        self._emitted = False
        self._error: LlmFailure | None = None
        # content_block_start opens a slot, input_json_delta fills it, content_block_stop delivers it
        self._tools: dict[int, dict[str, str]] = {}

    def feed(self, event: SseEvent) -> Iterable[StreamChunk]:
        try:
            payload = json.loads(event.data)
        except ValueError:
            return
        if not isinstance(payload, dict):
            return
        kind = payload.get("type") or event.event

        if kind == "error":
            error = payload.get("error")
            detail = error if isinstance(error, dict) else {}
            code = _ERROR_TYPES.get(str(detail.get("type", "")), SERVER)
            self._error = LlmFailure(
                str(detail.get("message", ui("上游返回错误", "The provider returned an error"))), code
            )
            return

        if kind == "message_start":
            message = payload.get("message")
            if isinstance(message, dict):
                usage = message.get("usage")
                if isinstance(usage, dict):
                    self._usage = _parse_usage(usage)
                    yield UsageUpdate(self._usage)
            return

        if kind == "content_block_start":
            block = payload.get("content_block")
            index = payload.get("index")
            if isinstance(block, dict) and block.get("type") == "tool_use":
                self._tools[index if isinstance(index, int) else len(self._tools)] = {
                    "id": str(block.get("id", "")),
                    "name": str(block.get("name", "")),
                    "arguments": "",
                }
            return

        if kind == "content_block_stop":
            index = payload.get("index")
            slot = self._tools.pop(index, None) if isinstance(index, int) else None
            if slot and slot["name"]:
                self._emitted = True
                yield ToolCall(
                    id=slot["id"] or f"call_{index}",
                    name=slot["name"],
                    arguments=_parse_arguments(slot["arguments"]),
                )
            return

        if kind == "content_block_delta":
            delta = payload.get("delta")
            if not isinstance(delta, dict):
                return
            delta_kind = delta.get("type")
            if delta_kind == "text_delta":
                text = delta.get("text")
                if isinstance(text, str) and text:
                    self._emitted = True
                    yield TextDelta(text)
            elif delta_kind == "thinking_delta":
                thinking = delta.get("thinking")
                if isinstance(thinking, str) and thinking:
                    yield ThinkingDelta(thinking)
            elif delta_kind == "input_json_delta":
                index = payload.get("index")
                fragment = delta.get("partial_json")
                if isinstance(index, int) and isinstance(fragment, str):
                    slot = self._tools.get(index)
                    if slot is not None:
                        slot["arguments"] += fragment
            return

        if kind == "message_delta":
            delta = payload.get("delta")
            if isinstance(delta, dict):
                reason = delta.get("stop_reason")
                if isinstance(reason, str):
                    self._stop_reason = reason
            usage = payload.get("usage")
            if isinstance(usage, dict):
                # message_delta reports only the output delta; input and cache counts came with message_start
                output = usage.get("output_tokens")
                if isinstance(output, int):
                    self._usage = Usage(
                        input_tokens=self._usage.input_tokens,
                        output_tokens=output,
                        cache_read_tokens=self._usage.cache_read_tokens,
                        cache_write_tokens=self._usage.cache_write_tokens,
                        prompt_tokens=self._usage.prompt_tokens,
                    )
                    yield UsageUpdate(self._usage)
            return

    def finish(self) -> Finish:
        if self._error is not None:
            return Finish(kind="error", failure=self._error, usage=self._usage)
        if not self._emitted:
            return Finish(
                kind="error",
                failure=LlmFailure(ui("模型返回了空响应", "The model returned an empty response"),
                                   EMPTY_RESPONSE),
                usage=self._usage,
            )
        if self._stop_reason == "tool_use":
            kind = "tool_use"
        elif self._stop_reason == "max_tokens":
            kind = "length"
        else:
            kind = "stop"
        return Finish(kind=kind, usage=self._usage)


def _parse_arguments(text: str) -> dict[str, object]:
    """Parse accumulated argument JSON; bad JSON yields {} so the tool can reject it and the model retry."""
    if not text.strip():
        return {}
    try:
        parsed = json.loads(text)
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _parse_usage(raw: dict[str, object]) -> Usage:
    def as_int(value: object) -> int:
        return value if isinstance(value, int) else 0

    uncached = as_int(raw.get("input_tokens"))
    read = as_int(raw.get("cache_read_input_tokens"))
    written = as_int(raw.get("cache_creation_input_tokens"))
    return Usage(
        input_tokens=uncached,
        output_tokens=as_int(raw.get("output_tokens")),
        cache_read_tokens=read,
        cache_write_tokens=written,
        # these three don't overlap here, so the input is their sum
        prompt_tokens=uncached + read + written,
    )


class AnthropicAdapter(ProtocolAdapter):
    name = "anthropic"
    cache_capability = CacheCapability.EXPLICIT_BREAKPOINT
    default_base_url = "https://api.anthropic.com"

    def endpoint(self, base_url: str, request: CallRequest) -> str:
        return f"{base_url.rstrip('/')}/v1/messages"

    def model_info_url(self, base_url: str, model: str) -> str | None:
        return f"{base_url.rstrip('/')}/v1/models/{quote(model, safe='')}"

    def context_window_from(self, payload: object, model: str) -> int | None:
        # max_input_tokens when the model info reports it, which it usually doesn't
        value = payload.get("max_input_tokens") if isinstance(payload, dict) else None
        return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None

    def headers(self, api_key: str) -> dict[str, str]:
        return {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }

    def payload(self, request: CallRequest) -> dict[str, object]:
        plan = plan_cache(request, self.cache_capability)

        messages: list[dict[str, object]] = []
        for index, message in enumerate(request.messages):
            messages.append({
                "role": message.role,
                "content": _blocks(message, cached=index == plan.message_breakpoint),
            })

        # Thinking is a token budget and must stay below max_tokens. When the caller set no
        # ceiling, it goes on top of the default, so a medium budget doesn't eat the whole answer
        # (or make the request invalid).
        budget = {"low": 2048, "medium": 8192, "high": 16384}.get(request.reasoning or "")
        if request.max_tokens:
            ceiling = request.max_tokens
            thinking = budget is not None and budget < ceiling
        else:
            ceiling = DEFAULT_MAX_TOKENS + (budget or 0)
            thinking = budget is not None

        body: dict[str, object] = {
            "model": request.model,
            "messages": messages,
            "stream": True,
            "max_tokens": ceiling,
        }
        if request.system:
            system_block: dict[str, object] = {"type": "text", "text": request.system}
            if plan.cache_system:
                system_block["cache_control"] = _EPHEMERAL
            body["system"] = [system_block]
        if request.temperature is not None:
            body["temperature"] = request.temperature
        if request.tools:
            body["tools"] = [
                {
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parameters or {"type": "object", "properties": {}},
                }
                for tool in request.tools
            ]
        if thinking:
            body["thinking"] = {"type": "enabled", "budget_tokens": budget}
        elif request.reasoning == "none":
            body["thinking"] = {"type": "disabled"}
        body.update(request.extra)
        return body

    def translator(self) -> StreamTranslator:
        return AnthropicTranslator()

    def classify(self, status: int, body: str) -> str:
        try:
            parsed = json.loads(body)
            error = parsed.get("error") if isinstance(parsed, dict) else None
            error_type = error.get("type") if isinstance(error, dict) else None
        except (ValueError, TypeError, AttributeError):
            error_type = None
        detail = self.error_detail(body)
        if isinstance(error_type, str) and error_type in _ERROR_TYPES:
            mapped = _ERROR_TYPES[error_type]
            # invalid_request_error covers both bad arguments and an overlong prompt
            if mapped is INVALID_ARGS and "too long" in detail.lower():
                return CONTEXT_WINDOW_EXCEEDED
            return mapped
        return super().classify(status, detail)
