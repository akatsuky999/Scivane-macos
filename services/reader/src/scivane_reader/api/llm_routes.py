"""大模型接入的 HTTP 路由。

只做编排：参数校验、把统一分片译成 SSE 帧、provider 的增删查。真正的调用
逻辑在 scivane_reader.llm，这一层不含任何厂商知识。

**取消是自动的**：客户端断开 → StreamingResponse 的迭代被取消 →
CancelledError 传进 registry 的生成器 → httpx 的 async with 断开上游连接。
不让请求在后台空跑烧钱，与 OCR 那条链路「SSE 断流即标记取消」同一个思路。
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from typing import Literal

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .. import config
from ..i18n import ui
from ..llm import (
    CallRequest,
    Finish,
    ImageBlock,
    LlmError,
    Message,
    TextBlock,
    TextDelta,
    ThinkingDelta,
    UsageUpdate,
    registry,
    save_providers,
)
from ..llm.registry import ProviderConfig
from .sse import LlmEvent, encode

logger = logging.getLogger("scivane.api.llm")

router = APIRouter(prefix="/llm", tags=["llm"])


# --------------------------------------------------------------------------
# 请求模型
# --------------------------------------------------------------------------
class BlockIn(BaseModel):
    type: Literal["text", "image"] = "text"
    text: str = ""
    data: str = ""
    media_type: str = "image/png"


class MessageIn(BaseModel):
    role: Literal["user", "assistant"]
    #: 纯文本直接给字符串；要带图时给块数组。
    content: str | list[BlockIn]

    def to_message(self) -> Message:
        if isinstance(self.content, str):
            return Message.text(self.role, self.content)
        blocks: list[TextBlock | ImageBlock] = []
        for block in self.content:
            if block.type == "text":
                blocks.append(TextBlock(block.text))
            else:
                blocks.append(ImageBlock(data=block.data, media_type=block.media_type))
        return Message(role=self.role, content=tuple(blocks))


class ChatRequest(BaseModel):
    provider: str
    messages: list[MessageIn] = Field(min_length=1)
    model: str | None = None
    system: str | None = None
    max_tokens: int | None = None
    temperature: float | None = None
    #: 前 N 条消息属于静态上下文（论文 Markdown 就放在这里）。
    #: 详见 llm/cache.py —— 这是 prompt 缓存能否命中的关键。
    cacheable_prefix: int = 0
    purpose: Literal["foreground", "background"] = "foreground"


class ProviderIn(BaseModel):
    id: str
    protocol: Literal["openai", "anthropic", "gemini"]
    model: str
    base_url: str = ""
    label: str = ""
    #: 上下文窗口（token）。可选 —— 给了才画余量条，**不猜**。
    context_window: int | None = Field(default=None, gt=0)
    #: 推理预算档位。留空 = 用默认（medium）。
    reasoning: str | None = Field(default=None, pattern="^(none|low|medium|high)$")
    #: key 从哪来：own 或 macro:<编号>。**不是秘密**，见 ProviderConfig。
    credential_ref: str = Field(default="own", pattern=r"^(own|macro:[A-Za-z0-9_-]{1,32})$")


class CredentialIn(BaseModel):
    api_key: str


# --------------------------------------------------------------------------
# provider 管理
# --------------------------------------------------------------------------
@router.get("/providers")
async def list_providers():
    """列出已配置的 provider 及其凭据状态。

    响应里**没有任何凭据原文** —— 只有「配没配」「来自哪里」和一个指纹，
    指纹用来回答「我现在配的还是上次那把吗」。
    """
    return {"providers": registry.describe_all()}


@router.post("/providers")
async def add_provider(body: ProviderIn):
    """新增或改写一个 provider。**立刻生效，并落盘。**

    同一个 id 再 POST 一次就是改写 —— 设置界面改地址、改模型名都走这里。

    落盘在后端做而不是让 App 去写 providers.json：路径只在
    `config.LLM_PROVIDERS_PATH` 这一处定义，让 Swift 再硬编码一份
    `~/.scivane/providers.json` 必然漂移，而漂移之后的症状是
    「设置里明明改了，重启就回到旧的」，极难查。
    """
    if not body.id.strip():
        raise HTTPException(status_code=400, detail=ui("id 不能为空", "The id can't be empty"))
    try:
        registry.register(ProviderConfig(
            id=body.id.strip(), protocol=body.protocol, model=body.model.strip(),
            base_url=body.base_url.strip(), label=body.label.strip(),
            context_window=body.context_window,
            reasoning=body.reasoning,
            credential_ref=body.credential_ref,
        ))
    except LlmError as exc:
        raise HTTPException(status_code=400, detail=exc.failure.message) from exc
    saved = save_providers(config.LLM_PROVIDERS_PATH)
    logger.info("provider %s 已注册并落盘（共 %d 条）", body.id, saved)
    return {"registered": body.id, "saved": saved}


@router.delete("/providers/{provider_id}")
async def remove_provider(provider_id: str):
    registry.unregister(provider_id)
    registry.credentials.clear_runtime(provider_id)
    save_providers(config.LLM_PROVIDERS_PATH)
    return {"removed": provider_id}


@router.post("/providers/{provider_id}/credential")
async def set_credential(provider_id: str, body: CredentialIn):
    """设置凭据（仅本进程内存，**不落盘**）。

    持久化交给 App 侧的 Keychain：那里有系统级加密，也不会被误提交进 Git。
    后端只负责「现在能用」。
    """
    try:
        registry.credentials.set_runtime(provider_id, body.api_key)
    except LlmError as exc:
        # 这里绝不能把 api_key 回显进错误消息
        raise HTTPException(status_code=400, detail=exc.failure.message) from exc
    return {"provider": provider_id, **registry.credentials.describe(provider_id)}


@router.delete("/providers/{provider_id}/credential")
async def clear_credential(provider_id: str):
    registry.credentials.clear_runtime(provider_id)
    return {"provider": provider_id, **registry.credentials.describe(provider_id)}


@router.post("/providers/{provider_id}/test")
async def test_provider(provider_id: str):
    """打一次最小请求确认真的能用。设置界面「测试连接」背后就是它。"""
    try:
        return await registry.test(provider_id)
    except LlmError as exc:
        return {"ok": False, "code": exc.code, "message": exc.failure.message}


# --------------------------------------------------------------------------
# 问答（SSE 流式）
# --------------------------------------------------------------------------
@router.post("/chat")
async def chat(body: ChatRequest):
    try:
        config = registry.get(body.provider)
    except LlmError as exc:
        raise HTTPException(status_code=404, detail=exc.failure.message) from exc

    try:
        request = CallRequest(
            model=body.model or config.model,
            messages=tuple(m.to_message() for m in body.messages),
            system=body.system,
            max_tokens=body.max_tokens,
            temperature=body.temperature,
            cacheable_prefix=body.cacheable_prefix,
            purpose=body.purpose,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    async def events() -> AsyncIterator[str]:
        try:
            async for chunk in registry.stream(body.provider, request):
                if isinstance(chunk, TextDelta):
                    yield encode(LlmEvent.DELTA, {"text": chunk.text})
                elif isinstance(chunk, ThinkingDelta):
                    yield encode(LlmEvent.THINKING, {"text": chunk.text})
                elif isinstance(chunk, UsageUpdate):
                    yield encode(LlmEvent.USAGE, chunk.usage.as_dict())
                elif isinstance(chunk, Finish):
                    payload: dict[str, object] = {"kind": chunk.kind}
                    if chunk.failure is not None:
                        payload["code"] = chunk.failure.code
                        payload["message"] = chunk.failure.message
                    if chunk.usage is not None:
                        payload["usage"] = chunk.usage.as_dict()
                    yield encode(LlmEvent.FINISH, payload)
        except LlmError as exc:
            # 凭据缺失这类失败发生在建连之前，拿不到流，这里补一个终态，
            # 保证客户端无论如何都能收到恰好一个 finish
            logger.info("llm 请求未能开始：%s", exc.code)
            yield encode(
                LlmEvent.FINISH,
                {"kind": "error", "code": exc.code, "message": exc.failure.message},
            )

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
