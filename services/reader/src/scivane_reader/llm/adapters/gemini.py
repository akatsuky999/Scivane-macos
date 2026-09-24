"""Google Gemini 协议。

与前两套的差异：

1. **模型名在 URL 路径里**，不在请求体，所以 `endpoint()` 需要拿到 request。
2. **助手角色叫 `model` 而不是 `assistant`**，system 也单独放在 systemInstruction。
3. **缓存是显式对象**（CachedContent）：要先建缓存对象拿到名字，再在请求里
   引用，还得管 TTL 与销毁。

**关于缓存的已知取舍**：本版走 Gemini 2.5 起默认开启的隐式缓存 —— 前缀稳定
就能自动命中，与 OpenAI 那套一样，不需要额外调用。显式 CachedContent 能给出
更强的命中保证和更长的 TTL，但要引入一套缓存对象的生命周期管理（创建、续期、
销毁、失效重建），复杂度不低。等真实用量数据显示隐式命中率不够时再补，
接口位（CacheCapability.EXPLICIT_OBJECT）已经留好。
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

#: gRPC 风格的 status → 稳定失败码。比 HTTP 状态码精确。
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

#: 非正常终止的 finishReason。这些都不该重试。
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
            # Gemini 没有 call id 的概念，按工具名配对 —— 所以同一轮里同名工具
            # 调两次，它只能靠顺序对上。这是协议本身的限制，不是我们的取舍。
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
            # Gemini 的 functionCall 是**整块到达**的，不像另两家要攒 JSON 片段
            call = part.get("functionCall")
            if isinstance(call, dict):
                name = call.get("name")
                if isinstance(name, str) and name:
                    args = call.get("args")
                    self._emitted = True
                    self._called = True
                    yield ToolCall(
                        # 协议不给 id，用名字 + 序号自造一个，保证同一轮里唯一
                        id=f"{name}_{self._call_index}",
                        name=name,
                        arguments=args if isinstance(args, dict) else {},
                    )
                    self._call_index += 1
                continue
            text = part.get("text")
            if not isinstance(text, str) or not text:
                continue
            # Gemini 2.5 用 thought 标记推理过程，与正文走同一个 text 字段
            if part.get("thought") is True:
                yield ThinkingDelta(text)
            else:
                self._emitted = True
                yield TextDelta(text)

    def finish(self) -> Finish:
        reason = self._finish_reason or ""
        if reason in _BLOCKED_REASONS:
            # 安全拦截：即使已经吐了一部分，也要如实报告被截断的原因
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
        # 顺序要紧：调了工具就是 tool_use，哪怕同时也说了话、哪怕 finishReason
        # 报的是 STOP（Gemini 在工具调用时给的就是 STOP，没有专门的终态）。
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
        # promptTokenCount 含缓存部分，拆开记才看得出缓存有没有生效
        input_tokens=max(0, prompt - cached),
        output_tokens=as_int(raw.get("candidatesTokenCount")),
        cache_read_tokens=cached,
    )


class GeminiAdapter(ProtocolAdapter):
    name = "gemini"
    #: 见模块文档：本版实际走隐式缓存，显式对象的接口位留着。
    cache_capability = CacheCapability.EXPLICIT_OBJECT
    default_base_url = "https://generativelanguage.googleapis.com"

    def endpoint(self, base_url: str, request: CallRequest) -> str:
        # 模型名进 URL，必须转义 —— 名字里带斜杠时不转义会打到别的路径上
        model = quote(request.model, safe="")
        return (
            f"{base_url.rstrip('/')}/v1beta/models/{model}:streamGenerateContent?alt=sse"
        )

    def headers(self, api_key: str) -> dict[str, str]:
        return {
            "x-goog-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }

    def payload(self, request: CallRequest) -> dict[str, object]:
        contents: list[dict[str, object]] = []
        for message in request.messages:
            # Gemini 管助手叫 model
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
        # Gemini 同样是 token 预算；0 表示关掉。
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
            # RESOURCE_EXHAUSTED 既是限流也是配额耗尽，要靠文本再分一次
            if mapped is RATE_LIMIT and "quota" in detail.lower():
                return QUOTA
            if mapped is INVALID_ARGS and "token" in detail.lower():
                return CONTEXT_WINDOW_EXCEEDED
            return mapped
        return super().classify(status, detail)
