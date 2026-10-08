"""Google Gemini protocol.

The model name goes in the URL path, the assistant role is `model`, and the system prompt
goes in systemInstruction. Caching relies on implicit prefix caching (Gemini 2.5+);
explicit CachedContent objects are not used yet.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from urllib.parse import quote

from ...i18n import ui
from ..cache import CacheCapability
from ..errors import (
    AUTH,
    CONTEXT_WINDOW_EXCEEDED,
    EMPTY_RESPONSE,
    INVALID_ARGS,
    QUOTA,
    RATE_LIMIT,
    REFUSAL,
    SERVER,
    TIMEOUT,
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

#: gRPC-style status -> stable code (more precise than the HTTP status)
_STATUS_CODES = {
    "INVALID_ARGUMENT": INVALID_ARGS,
    "FAILED_PRECONDITION": INVALID_ARGS,
    "OUT_OF_RANGE": CONTEXT_WINDOW_EXCEEDED,
    "UNAUTHENTICATED": AUTH,
    "PERMISSION_DENIED": AUTH,
    "NOT_FOUND": INVALID_ARGS,
    "RESOURCE_EXHAUSTED": RATE_LIMIT,
    "UNAVAILABLE": SERVER,
    "INTERNAL": SERVER,
    "DEADLINE_EXCEEDED": TIMEOUT,
}

#: abnormal finish reasons; none of these should be retried
_BLOCKED_REASONS = frozenset({"SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"})


def _parts(message: Message) -> list[dict[str, object]]:
    parts: list[dict[str, object]] = []
    for block in message.content:
        if isinstance(block, TextBlock):
            parts.append({"text": block.text})
        elif isinstance(block, ImageBlock):
            parts.append({
                "inline_data": {"mime_type": block.media_type, "data": block.data}
            })
        elif isinstance(block, ToolUseBlock):
            parts.append({"functionCall": {"name": block.name, "args": block.arguments}})
        elif isinstance(block, ToolResultBlock):
            # Gemini has no call ids and pairs results by name, so two calls of the same tool in one
            # step only match by order.
            parts.append({
                "functionResponse": {
                    "name": block.call_id,
                    "response": {"content": block.content, "is_error": block.is_error},
                }
            })
    return parts


class GeminiTranslator(StreamTranslator):
    def __init__(self) -> None:
        self._usage = Usage()
        self._finish_reason: str | None = None
        self._emitted = False
        self._called = False
        self._call_index = 0

    def feed(self, event: SseEvent) -> Iterable[StreamChunk]:
        try:
            payload = json.loads(event.data)
        except ValueError:
            return
        if not isinstance(payload, dict):
            return

        usage = payload.get("usageMetadata")
        if isinstance(usage, dict):
            self._usage = _parse_usage(usage)
            yield UsageUpdate(self._usage)

        candidates = payload.get("candidates")
        if not isinstance(candidates, list) or not candidates:
            return
        candidate = candidates[0]
        if not isinstance(candidate, dict):
            return

        reason = candidate.get("finishReason")
        if isinstance(reason, str) and reason:
            self._finish_reason = reason

        content = candidate.get("content")
        if not isinstance(content, dict):
            return
        for part in content.get("parts") or []:
            if not isinstance(part, dict):
                continue
            # functionCall arrives whole; no argument fragments to assemble
            call = part.get("functionCall")
            if isinstance(call, dict):
                name = call.get("name")
                if isinstance(name, str) and name:
                    args = call.get("args")
                    self._emitted = True
                    self._called = True
                    yield ToolCall(
                        # no ids in the protocol: name plus a counter, unique within the turn
                        id=f"{name}_{self._call_index}",
                        name=name,
                        arguments=args if isinstance(args, dict) else {},
                    )
                    self._call_index += 1
                continue
            text = part.get("text")
            if not isinstance(text, str) or not text:
                continue
            # Gemini 2.5 marks reasoning with `thought` in the same text field
            if part.get("thought") is True:
                yield ThinkingDelta(text)
            else:
                self._emitted = True
                yield TextDelta(text)

    def finish(self) -> Finish:
        reason = self._finish_reason or ""
        if reason in _BLOCKED_REASONS:
            # safety stop: report the truncation reason even after partial output
            return Finish(
                kind="error",
                failure=LlmFailure(ui(f"内容被厂商安全策略拦截（{reason}）",
                                      f"Blocked by the provider's safety policy ({reason})"), REFUSAL),
                usage=self._usage,
            )
        if not self._emitted:
            return Finish(
                kind="error",
                failure=LlmFailure(ui("模型返回了空响应", "The model returned an empty response"),
                                   EMPTY_RESPONSE),
                usage=self._usage,
            )
        # Order matters: a step that called tools is tool_use even when finishReason says STOP
        # (Gemini has no dedicated terminal value).
        if self._called:
            kind = "tool_use"
        elif reason == "MAX_TOKENS":
            kind = "length"
        else:
            kind = "stop"
        return Finish(kind=kind, usage=self._usage)


def _parse_usage(raw: dict[str, object]) -> Usage:
    def as_int(value: object) -> int:
        return value if isinstance(value, int) else 0

    prompt = as_int(raw.get("promptTokenCount"))
    cached = as_int(raw.get("cachedContentTokenCount"))
    return Usage(
        # promptTokenCount includes cache hits; split them out
        input_tokens=max(0, prompt - cached),
        output_tokens=as_int(raw.get("candidatesTokenCount")),
        cache_read_tokens=cached,
        prompt_tokens=prompt,
    )


class GeminiAdapter(ProtocolAdapter):
    name = "gemini"
    #: implicit caching in practice; see the module docstring
    cache_capability = CacheCapability.EXPLICIT_OBJECT
    default_base_url = "https://generativelanguage.googleapis.com"

    def endpoint(self, base_url: str, request: CallRequest) -> str:
        # escape the model name: a slash would hit a different path
        model = quote(request.model, safe="")
        return (
            f"{base_url.rstrip('/')}/v1beta/models/{model}:streamGenerateContent?alt=sse"
        )

    def model_info_url(self, base_url: str, model: str) -> str | None:
        return f"{base_url.rstrip('/')}/v1beta/models/{quote(model, safe='')}"

    def context_window_from(self, payload: object, model: str) -> int | None:
        value = payload.get("inputTokenLimit") if isinstance(payload, dict) else None
        return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None

    def headers(self, api_key: str) -> dict[str, str]:
        return {
            "x-goog-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }

    def payload(self, request: CallRequest) -> dict[str, object]:
        contents: list[dict[str, object]] = []
        for message in request.messages:
            role = "model" if message.role == "assistant" else "user"
            contents.append({"role": role, "parts": _parts(message)})

        body: dict[str, object] = {"contents": contents}
        if request.system:
            body["systemInstruction"] = {"parts": [{"text": request.system}]}

        generation: dict[str, object] = {}
        if request.max_tokens is not None:
            generation["maxOutputTokens"] = request.max_tokens
        if request.temperature is not None:
            generation["temperature"] = request.temperature
        if generation:
            body["generationConfig"] = generation
        if request.tools:
            body["tools"] = [{
                "functionDeclarations": [
                    {
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters or {"type": "object", "properties": {}},
                    }
                    for tool in request.tools
                ]
            }]
        # also a token budget; 0 turns thinking off
        thinking = {"none": 0, "low": 2048, "medium": 8192, "high": 16384}.get(
            request.reasoning or "")
        if thinking is not None:
            generation = body.setdefault("generationConfig", {})
            if isinstance(generation, dict):
                generation["thinkingConfig"] = {"thinkingBudget": thinking}
        body.update(request.extra)
        return body

    def translator(self) -> StreamTranslator:
        return GeminiTranslator()

    def classify(self, status: int, body: str) -> str:
        detail = self.error_detail(body)
        try:
            parsed = json.loads(body)
            error = parsed.get("error") if isinstance(parsed, dict) else None
            grpc_status = error.get("status") if isinstance(error, dict) else None
        except (ValueError, TypeError, AttributeError):
            grpc_status = None
        if isinstance(grpc_status, str) and grpc_status in _STATUS_CODES:
            mapped = _STATUS_CODES[grpc_status]
            # RESOURCE_EXHAUSTED covers both rate limits and quota
            if mapped is RATE_LIMIT and "quota" in detail.lower():
                return QUOTA
            if mapped is INVALID_ARGS and "token" in detail.lower():
                return CONTEXT_WINDOW_EXCEEDED
            return mapped
        return super().classify(status, detail)
