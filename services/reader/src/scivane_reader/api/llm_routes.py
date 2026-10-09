"""HTTP routes for the model layer: validation, SSE framing, provider CRUD. No vendor knowledge.

Cancellation is automatic: a client disconnect cancels the StreamingResponse iteration,
which closes the upstream connection.
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


class BlockIn(BaseModel):
    type: Literal["text", "image"] = "text"
    text: str = ""
    data: str = ""
    media_type: str = "image/png"


class MessageIn(BaseModel):
    role: Literal["user", "assistant"]
    #: plain text as a string, or blocks when images are attached
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
    #: The first N messages are static context (the paper); this decides whether the prompt
    #: cache hits. See llm/cache.py.
    cacheable_prefix: int = 0
    purpose: Literal["foreground", "background"] = "foreground"


class ProviderIn(BaseModel):
    id: str
    protocol: Literal["openai", "anthropic", "gemini"]
    model: str
    base_url: str = ""
    label: str = ""
    #: hand-filled window; otherwise the endpoint is asked. Never guessed.
    context_window: int | None = Field(default=None, gt=0)
    reasoning: str | None = Field(default=None, pattern="^(none|low|medium|high)$")
    #: where the key comes from: own or macro:<id>; not a secret
    credential_ref: str = Field(default="own", pattern=r"^(own|macro:[A-Za-z0-9_-]{1,32})$")


class CredentialIn(BaseModel):
    api_key: str


@router.get("/providers")
async def list_providers():
    """Configured providers and their credential status. Never key material, only a fingerprint."""
    return {"providers": registry.describe_all()}


@router.post("/providers")
async def add_provider(body: ProviderIn):
    """Create or replace a provider; takes effect immediately and is persisted.

    The backend owns providers.json so its path is defined in one place.
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
    """Set a credential in memory only; the app persists keys in the Keychain."""
    try:
        registry.credentials.set_runtime(provider_id, body.api_key)
    except LlmError as exc:
        # never echo the api_key into the error message
        raise HTTPException(status_code=400, detail=exc.failure.message) from exc
    return {"provider": provider_id, **registry.credentials.describe(provider_id)}


@router.delete("/providers/{provider_id}/credential")
async def clear_credential(provider_id: str):
    registry.credentials.clear_runtime(provider_id)
    return {"provider": provider_id, **registry.credentials.describe(provider_id)}


@router.post("/providers/{provider_id}/test")
async def test_provider(provider_id: str):
    """Send one minimal request to prove the provider works (Settings > Test)."""
    try:
        return await registry.test(provider_id)
    except LlmError as exc:
        return {"ok": False, "code": exc.code, "message": exc.failure.message}


@router.post("/providers/{provider_id}/vision")
async def check_vision(provider_id: str, refresh: bool = False):
    """Whether the card's model reads images. Costs one small request unless a verdict is cached.

    vision is true, false, or null when the check couldn't run (then code says why).
    """
    try:
        check = await registry.vision(provider_id, refresh=refresh)
    except LlmError as exc:
        return {"vision": None, "code": exc.code, "message": exc.failure.message}
    return {"vision": check.supported, "code": check.code, "message": check.message}


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
            # Failures before the stream exists (missing credentials) still get exactly one finish.
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
