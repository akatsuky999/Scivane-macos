"""Anthropic Messages 协议。

与 OpenAI 兼容协议的三个实质差异：

1. **max_tokens 是必填的** —— 不给会直接 400，所以这里有兜底默认值。
2. **缓存要显式打点** —— `cache_control: {"type": "ephemeral"}` 打在想缓存的
   最后一个内容块上。这正是 Scivane 那份论文 Markdown 最需要的能力。
3. **流中途会来 error 事件** —— 过载时不是 HTTP 错误，而是流里插一个
   `event: error`。不处理的话表现为「回答说到一半忽然没了」。
"""

from __future__ import annotations

import json
from collections.abc import Iterable

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

#: Anthropic 要求必填 max_tokens。论文问答的回答可能很长，给一个宽松的默认值。
DEFAULT_MAX_TOKENS = 8192

_EPHEMERAL = {"type": "ephemeral"}

#: 厂商错误类型 → 稳定失败码。有结构化类型就不必猜状态码。
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
    """内容块译成 Anthropic 形状；`cached` 时在最后一块打缓存标记。

    标记必须打在**最后一块**：厂商缓存的是「到这个标记为止」的全部内容，
    打在中间就只缓存了前半截。
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
        # content_block_start 建槽、input_json_delta 累积、content_block_stop 交付
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
                # message_delta 只报增量输出量，输入与缓存量在 message_start 已给过
                output = usage.get("output_tokens")
                if isinstance(output, int):
                    self._usage = Usage(
                        input_tokens=self._usage.input_tokens,
                        output_tokens=output,
                        cache_read_tokens=self._usage.cache_read_tokens,
                        cache_write_tokens=self._usage.cache_write_tokens,
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
    """解析攒起来的参数 JSON。坏 JSON 给空字典而不是炸掉整条流 ——
    工具自己会拒绝并把错误作为结果回给模型，模型还有机会重试；流炸了什么都救不回来。"""
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

    return Usage(
        input_tokens=as_int(raw.get("input_tokens")),
        output_tokens=as_int(raw.get("output_tokens")),
        cache_read_tokens=as_int(raw.get("cache_read_input_tokens")),
        cache_write_tokens=as_int(raw.get("cache_creation_input_tokens")),
    )


class AnthropicAdapter(ProtocolAdapter):
    name = "anthropic"
    cache_capability = CacheCapability.EXPLICIT_BREAKPOINT
    default_base_url = "https://api.anthropic.com"

    def endpoint(self, base_url: str, request: CallRequest) -> str:
        return f"{base_url.rstrip('/')}/v1/messages"

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

        body: dict[str, object] = {
            "model": request.model,
            "messages": messages,
            "stream": True,
            # 必填项，缺了直接 400
            "max_tokens": request.max_tokens or DEFAULT_MAX_TOKENS,
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
        # Anthropic 的思考是**按 token 预算**给的，不是档位。
        # 预算必须小于 max_tokens，否则请求非法 —— 所以留一半给答案。
        budget = {"low": 2048, "medium": 8192, "high": 16384}.get(request.reasoning or "")
        if budget is not None:
            ceiling = request.max_tokens or 0
            if ceiling <= 0 or budget < ceiling:
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
            # invalid_request_error 兼指参数错与 prompt 过长，要靠文本再分一次
            if mapped is INVALID_ARGS and "too long" in detail.lower():
                return CONTEXT_WINDOW_EXCEEDED
            return mapped
        return super().classify(status, detail)
