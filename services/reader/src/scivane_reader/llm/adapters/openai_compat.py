"""OpenAI-compatible protocol (OpenAI, DeepSeek, Kimi, Zhipu, Qwen, SiliconFlow, Ollama, vLLM).

Caching is implicit prefix caching: our only job is keeping the prefix byte-stable.
"""

from __future__ import annotations

import json
from collections.abc import Iterable

from ...i18n import ui
from .. import timing
from ..cache import CacheCapability
from ..errors import CONTEXT_WINDOW_EXCEEDED, INVALID_ARGS, QUOTA, RATE_LIMIT
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

DONE_SENTINEL = "[DONE]"


def _content(message: Message) -> object:
    """Single-text messages become a plain string, the form every compatible server accepts."""
    if len(message.content) == 1 and isinstance(message.content[0], TextBlock):
        return message.content[0].text
    parts: list[dict[str, object]] = []
    for block in message.content:
        if isinstance(block, TextBlock):
            parts.append({"type": "text", "text": block.text})
        elif isinstance(block, ImageBlock):
            parts.append({
                "type": "image_url",
                "image_url": {"url": f"data:{block.media_type};base64,{block.data}"},
            })
    return parts


def _openai_messages(request: CallRequest) -> list[dict[str, object]]:
    """Unified messages -> OpenAI messages. Each tool result expands into its own role="tool"
    message, in order.
    """
    messages: list[dict[str, object]] = []
    if request.system:
        messages.append({"role": "system", "content": request.system})

    for message in request.messages:
        results = [b for b in message.content if isinstance(b, ToolResultBlock)]
        uses = [b for b in message.content if isinstance(b, ToolUseBlock)]
        plain = tuple(
            b for b in message.content
            if not isinstance(b, (ToolResultBlock, ToolUseBlock))
        )

        for result in results:
            messages.append({
                "role": "tool",
                "tool_call_id": result.call_id,
                "content": result.content,
            })

        if uses:
            entry: dict[str, object] = {
                "role": "assistant",
                # some compatible servers reject a missing content even when there are tool calls
                "content": _content(Message(message.role, plain)) if plain else None,
                "tool_calls": [
                    {
                        "id": use.id,
                        "type": "function",
                        "function": {
                            "name": use.name,
                            "arguments": json.dumps(use.arguments, ensure_ascii=False),
                        },
                    }
                    for use in uses
                ],
            }
            messages.append(entry)
        elif plain:
            messages.append({
                "role": message.role,
                "content": _content(Message(message.role, plain)),
            })

    return messages


class OpenAiTranslator(StreamTranslator):
    def __init__(self) -> None:
        self._usage = Usage()
        self._finish_reason: str | None = None
        self._emitted = False
        # index -> call being assembled; arguments stream as JSON fragments
        self._pending: dict[int, dict[str, str]] = {}
        self._flushed = False

    def feed(self, event: SseEvent) -> Iterable[StreamChunk]:
        if event.data.strip() == DONE_SENTINEL:
            return
        try:
            payload = json.loads(event.data)
        except ValueError:
            # skip malformed frames: some servers interleave non-JSON keep-alives
            return
        if not isinstance(payload, dict):
            return

        clock = timing.current()
        if clock is not None:
            # Gateway metadata (actual upstream, resolved model); recorded only when timing is on,
            # whitelisted keys only.
            clock.note("upstream", payload.get("provider"))
            clock.note("resolved_model", payload.get("model"))
            clock.note("generation", payload.get("id"))

        usage = payload.get("usage")
        if isinstance(usage, dict):
            self._usage = _parse_usage(usage)
            if clock is not None:
                details = usage.get("completion_tokens_details")
                if isinstance(details, dict):
                    clock.usage({"reasoning_tokens": details.get("reasoning_tokens")})
            yield UsageUpdate(self._usage)

        choices = payload.get("choices")
        if not isinstance(choices, list) or not choices:
            return
        choice = choices[0]
        if not isinstance(choice, dict):
            return

        reason = choice.get("finish_reason")
        if isinstance(reason, str) and reason:
            self._finish_reason = reason

        delta = choice.get("delta")
        if not isinstance(delta, dict):
            return

        # DeepSeek reasoner uses reasoning_content; some servers use reasoning.
        for key in ("reasoning_content", "reasoning"):
            thinking = delta.get(key)
            if isinstance(thinking, str) and thinking:
                yield ThinkingDelta(thinking)

        text = delta.get("content")
        if isinstance(text, str) and text:
            self._emitted = True
            yield TextDelta(text)

        calls = delta.get("tool_calls")
        if isinstance(calls, list):
            for raw in calls:
                if isinstance(raw, dict):
                    self._absorb(raw)

        # finish_reason means every call of this step has arrived
        if self._finish_reason and not self._flushed:
            yield from self._flush()

    def _absorb(self, raw: dict[str, object]) -> None:
        index = raw.get("index")
        slot = self._pending.setdefault(
            index if isinstance(index, int) else len(self._pending),
            {"id": "", "name": "", "arguments": ""},
        )
        call_id = raw.get("id")
        if isinstance(call_id, str) and call_id:
            slot["id"] = call_id
        function = raw.get("function")
        if isinstance(function, dict):
            name = function.get("name")
            if isinstance(name, str) and name:
                slot["name"] = name
            args = function.get("arguments")
            if isinstance(args, str):
                slot["arguments"] += args

    def _flush(self) -> Iterable[StreamChunk]:
        self._flushed = True
        for index in sorted(self._pending):
            slot = self._pending[index]
            if not slot["name"]:
                continue
            self._emitted = True
            yield ToolCall(
                id=slot["id"] or f"call_{index}",
                name=slot["name"],
                arguments=_parse_arguments(slot["arguments"]),
            )

    def finish(self) -> Finish:
        if not self._emitted:
            # A normal end with no content is a failure, or the turn would silently end with nothing.
            from ..errors import EMPTY_RESPONSE, LlmFailure

            return Finish(
                kind="error",
                failure=LlmFailure(ui("模型返回了空响应", "The model returned an empty response"),
                                   EMPTY_RESPONSE),
                usage=self._usage,
            )
        if self._finish_reason == "tool_calls":
            kind = "tool_use"
        elif self._finish_reason == "length":
            kind = "length"
        else:
            kind = "stop"
        return Finish(kind=kind, usage=self._usage)


def _parse_arguments(text: str) -> dict[str, object]:
    """Parse accumulated argument JSON.

    Bad JSON yields {} instead of killing the stream: the tool rejects it and the model can retry.
    """
    if not text.strip():
        return {}
    try:
        parsed = json.loads(text)
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _parse_usage(raw: dict[str, object]) -> Usage:
    """Parse usage; vendors name the cache fields differently."""
    def as_int(value: object) -> int:
        return value if isinstance(value, int) else 0

    prompt = as_int(raw.get("prompt_tokens"))
    completion = as_int(raw.get("completion_tokens"))

    # OpenAI: prompt_tokens_details.cached_tokens
    cached = 0
    written = 0
    details = raw.get("prompt_tokens_details")
    if isinstance(details, dict):
        cached = as_int(details.get("cached_tokens"))
        # OpenRouter also reports cache writes, which cost slightly more than plain input
        written = as_int(details.get("cache_write_tokens"))
    # DeepSeek: prompt_cache_hit_tokens / prompt_cache_miss_tokens
    if not cached:
        cached = as_int(raw.get("prompt_cache_hit_tokens"))

    return Usage(
        # prompt_tokens includes cache hits; split them out
        input_tokens=max(0, prompt - cached),
        output_tokens=completion,
        cache_read_tokens=cached,
        cache_write_tokens=written,
        # prompt_tokens is everything the model saw
        prompt_tokens=prompt,
    )


class OpenAiCompatAdapter(ProtocolAdapter):
    name = "openai"
    cache_capability = CacheCapability.IMPLICIT_PREFIX
    default_base_url = "https://api.openai.com/v1"

    def endpoint(self, base_url: str, request: CallRequest) -> str:
        return f"{base_url.rstrip('/')}/chat/completions"

    def model_info_url(self, base_url: str, model: str) -> str | None:
        # the model list rather than /models/{id}: OpenRouter ids contain '/' and '~'
        return f"{base_url.rstrip('/')}/models"

    def context_window_from(self, payload: object, model: str) -> int | None:
        """Find the model's window in the list.

        Field names vary (context_length, context_window, max_model_len); OpenAI and DeepSeek report
        none. When OpenRouter also reports top_provider.context_length, take the smaller.
        """
        entries = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(entries, list):
            return None
        for entry in entries:
            if isinstance(entry, dict) and entry.get("id") == model:
                top = entry.get("top_provider")
                candidates = [entry.get(key) for key in ("context_length", "context_window", "max_model_len")]
                if isinstance(top, dict):
                    candidates.append(top.get("context_length"))
                sizes = [v for v in candidates if isinstance(v, int) and not isinstance(v, bool) and v > 0]
                return min(sizes) if sizes else None
        return None

    def headers(self, api_key: str) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }

    def payload(self, request: CallRequest) -> dict[str, object]:
        body: dict[str, object] = {
            "model": request.model,
            "messages": _openai_messages(request),
            "stream": True,
            # without this the stream carries no usage, so cache hits are invisible
            "stream_options": {"include_usage": True},
        }
        if request.max_tokens is not None:
            body["max_tokens"] = request.max_tokens
        if request.temperature is not None:
            body["temperature"] = request.temperature
        if request.tools:
            body["tools"] = [
                {"type": "function", "function": tool.as_dict()} for tool in request.tools
            ]
        _apply_reasoning(body, request.reasoning)
        # extra goes last: the user's escape hatch must be able to override anything above
        body.update(request.extra)
        return body

    def translator(self) -> StreamTranslator:
        return OpenAiTranslator()

    def classify(self, status: int, body: str) -> str:
        detail = self.error_detail(body)
        # structured code first; more precise than the status
        try:
            parsed = json.loads(body)
            error = parsed.get("error") if isinstance(parsed, dict) else None
            code = error.get("code") if isinstance(error, dict) else None
        except (ValueError, TypeError, AttributeError):
            code = None
        if isinstance(code, str):
            if code == "context_length_exceeded":
                return CONTEXT_WINDOW_EXCEEDED
            if code in ("insufficient_quota", "billing_hard_limit_reached"):
                return QUOTA
            if code == "rate_limit_exceeded":
                return RATE_LIMIT
            if code in ("model_not_found", "invalid_request_error"):
                return (
                    CONTEXT_WINDOW_EXCEEDED
                    if "context" in detail.lower()
                    else INVALID_ARGS
                )
        return super().classify(status, detail)


def _apply_reasoning(body: dict[str, object], level: str | None) -> None:
    """Translate the neutral reasoning level.

    reasoning_effort for OpenAI-style servers; "none" uses OpenRouter's reasoning.enabled=false
    instead. Unknown levels are not sent: the vendor default beats a 400.
    """
    if not level:
        return
    if level == "none":
        body["reasoning"] = {"enabled": False}
    elif level in ("low", "medium", "high"):
        body["reasoning_effort"] = level
