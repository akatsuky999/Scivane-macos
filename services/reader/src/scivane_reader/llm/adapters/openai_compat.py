"""OpenAI 兼容协议。

一套协议覆盖极多厂商：OpenAI、DeepSeek、Kimi、智谱、通义、硅基流动，
以及本地的 Ollama 与 vLLM。它们的差异只在 base_url 和模型名，请求体形状一致。

缓存能力是 IMPLICIT_PREFIX：不需要打任何标记，厂商自动缓存稳定的前缀。
我们唯一的责任是**保证前缀逐字节稳定** —— 这条在 cache.py 里有指纹可以验证。
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
    """把内容块译成 OpenAI 的形状。

    纯文本消息退化成字符串而不是单元素数组 —— 两者语义相同，但字符串是
    绝大多数厂商的规范形式，兼容性最好（部分兼容实现不接受数组形式）。
    """
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
    """把统一消息译成 OpenAI 的消息数组。

    工具这一段不是一对一的：统一词汇把工具结果放在一条 user 消息的内容块里
    （Anthropic 形状），而 OpenAI 要求**每个结果一条独立的 role="tool" 消息**。
    所以一条带 3 个结果的 user 消息在这里会展开成 3 条。顺序必须保持 ——
    OpenAI 按 `tool_call_id` 配对，但乱序的历史在部分兼容实现上会被拒。
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

        # 工具结果：逐个展开成 role="tool"
        for result in results:
            messages.append({
                "role": "tool",
                "tool_call_id": result.call_id,
                "content": result.content,
            })

        if uses:
            entry: dict[str, object] = {
                "role": "assistant",
                # 只有工具调用、没有正文时也要给 content，部分兼容实现缺了会 400
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
        # index → 累积中的调用。参数是 JSON 片段流式来的，攒完才有意义。
        self._pending: dict[int, dict[str, str]] = {}
        self._flushed = False

    def feed(self, event: SseEvent) -> Iterable[StreamChunk]:
        if event.data.strip() == DONE_SENTINEL:
            return
        try:
            payload = json.loads(event.data)
        except ValueError:
            # 坏帧不该毁掉整条流：厂商偶尔会插入非 JSON 的保活内容
            return
        if not isinstance(payload, dict):
            return

        clock = timing.current()
        if clock is not None:
            # 网关的元数据：请求实际落到了哪一家、别名解析成了哪个模型。
            # 只有计时开着时才看，而且只收白名单里的键（见 timing.NOTE_KEYS）。
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

        # DeepSeek 的 reasoner 系列把推理过程放在 reasoning_content。
        # 部分厂商用 reasoning，两个都认。
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

        # finish_reason 到了说明这一轮的调用都收全了，可以一次交出去。
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
            # 正常结束却一个字都没有：当失败处理，否则界面上是「转了半天然后
            # 这一轮悄无声息地结束了」，用户与上层都无从下手。
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
    """解析攒起来的参数 JSON。

    解析不了就给空字典而不是抛错 —— 抛错会让整条流炸掉，而调度层对「参数不对」
    有现成的处理：工具自己会拒绝并把错误作为结果回给模型，模型还能重试。
    流炸掉则什么都救不回来。
    """
    if not text.strip():
        return {}
    try:
        parsed = json.loads(text)
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _parse_usage(raw: dict[str, object]) -> Usage:
    """解析用量。各厂商报告缓存命中的字段名不同，都要认。"""
    def as_int(value: object) -> int:
        return value if isinstance(value, int) else 0

    prompt = as_int(raw.get("prompt_tokens"))
    completion = as_int(raw.get("completion_tokens"))

    # OpenAI：prompt_tokens_details.cached_tokens
    cached = 0
    written = 0
    details = raw.get("prompt_tokens_details")
    if isinstance(details, dict):
        cached = as_int(details.get("cached_tokens"))
        # OpenRouter 在同一个结构里还报缓存**写入**量（实测 2026-09-12）。
        # 写入比普通输入略贵，不单独记就看不出「这一轮是在建缓存还是在吃缓存」。
        written = as_int(details.get("cache_write_tokens"))
    # DeepSeek：prompt_cache_hit_tokens / prompt_cache_miss_tokens
    if not cached:
        cached = as_int(raw.get("prompt_cache_hit_tokens"))

    return Usage(
        # prompt_tokens 含缓存命中部分，这里拆开记，才看得出缓存有没有生效
        input_tokens=max(0, prompt - cached),
        output_tokens=completion,
        cache_read_tokens=cached,
        cache_write_tokens=written,
    )


class OpenAiCompatAdapter(ProtocolAdapter):
    name = "openai"
    cache_capability = CacheCapability.IMPLICIT_PREFIX
    default_base_url = "https://api.openai.com/v1"

    def endpoint(self, base_url: str, request: CallRequest) -> str:
        return f"{base_url.rstrip('/')}/chat/completions"

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
            # 不加这个的话流式响应根本不带用量，缓存是否命中就无从得知
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
        # extra 最后并：它是用户的逃生口，**必须能覆盖上面任何一项**
        body.update(request.extra)
        return body

    def translator(self) -> StreamTranslator:
        return OpenAiTranslator()

    def classify(self, status: int, body: str) -> str:
        detail = self.error_detail(body)
        # 先看结构化的 code，比状态码精确
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
    """把中立的推理档位翻成这条协议认得的参数。

    `reasoning_effort` 是 OpenAI 的标准字段，DeepSeek、OpenRouter、通义
    都跟着它走；OpenRouter 还会把它规范化后转发给子供应商。

    **"none" 走的是另一个字段。** OpenAI 没有「完全关掉」这一档，
    而 OpenRouter 有 `reasoning: {enabled: false}`。两者形状不同，
    所以分开发 —— 硬塞成 `reasoning_effort: "none"` 会被严格的网关判成非法值。

    不认识的档位一律不发：**宁可用厂商默认，也不要发一个会让请求 400 的字段。**
    """
    if not level:
        return
    if level == "none":
        body["reasoning"] = {"enabled": False}
    elif level in ("low", "medium", "high"):
        body["reasoning_effort"] = level
