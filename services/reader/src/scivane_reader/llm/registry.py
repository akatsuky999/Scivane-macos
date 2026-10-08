"""Provider registry and the single streaming call path.

Transport, retries, timeouts, concurrency and cancellation live here once; protocol adapters
only translate. Every stream ends with exactly one Finish, nothing is retried after content
was emitted, and credentials never appear in errors, logs or responses. Cancellation
propagates CancelledError and yields no Finish.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass, field, replace

import httpx

from ..i18n import ui
from . import timing
from .adapters import PROTOCOLS, ProtocolAdapter
from .adapters.base import aiter_sse
from .cache import prefix_fingerprint
from .credentials import CredentialStore, credentials as default_credentials
from .types import REASONING_DEFAULT
from .errors import (
    NO_ADAPTER,
    TIMEOUT,
    TRANSPORT,
    LlmError,
    LlmFailure,
)
from .retry import (
    DEFAULT_POLICY,
    DEFAULT_TIMEOUTS,
    RetryPolicy,
    Timeouts,
    compute_delay,
    is_retryable,
    parse_retry_after,
)
from .types import (
    CallRequest,
    Finish,
    Message,
    StreamChunk,
    TextDelta,
    ThinkingDelta,
    ToolCall,
    UsageUpdate,
)

logger = logging.getLogger("scivane.llm")

#: Detected windows expire: '-latest' aliases can switch versions.
WINDOW_TTL = 6 * 3600.0
#: retry a failed probe after this long
WINDOW_RETRY = 600.0
#: OpenRouter's model list is several hundred KB
WINDOW_PROBE_TIMEOUT = 8.0


@dataclass(frozen=True)
class ProviderConfig:
    """A configured provider: protocol, base URL, model and credential reference.

    There is no vendor-specific code; DeepSeek and a local Ollama both use the OpenAI adapter.
    """

    id: str
    protocol: str
    model: str
    base_url: str = ""
    label: str = ""
    #: Hand-filled context window; drives the usage percentage and auto-compaction.
    #: Not guessed from the model name: the same name can have different windows behind
    #: different gateways. Unset means asking the endpoint (detected_window).
    context_window: int | None = None
    #: Where the key comes from: own, or macro:<id> for a shared key. A reference, not a secret:
    #: keys live only in the Keychain and are injected by the app.
    credential_ref: str = "own"

    #: Reasoning budget; None means REASONING_DEFAULT. Per provider because non-reasoning models
    #: reject or ignore it.
    reasoning: str | None = None

    def __post_init__(self) -> None:
        if self.protocol not in PROTOCOLS:
            raise LlmError(
                ui(f"未知协议 {self.protocol!r}，可选：{sorted(PROTOCOLS)}",
                   f"Unknown protocol {self.protocol!r}; choose one of {sorted(PROTOCOLS)}"),
                NO_ADAPTER,
            )

    @property
    def adapter(self) -> ProtocolAdapter:
        return PROTOCOLS[self.protocol].adapter

    @property
    def effective_base_url(self) -> str:
        return self.base_url or self.adapter.default_base_url


@dataclass
class LlmRegistry:
    credentials: CredentialStore = field(default_factory=lambda: default_credentials)
    timeouts: Timeouts = DEFAULT_TIMEOUTS
    policy: RetryPolicy = DEFAULT_POLICY
    max_concurrency: int = 4
    #: idle connection lifetime; see config.LLM_KEEPALIVE
    keepalive: float = 300.0
    #: test seam: pass httpx.MockTransport to run fully offline
    transport: httpx.AsyncBaseTransport | None = None

    _providers: dict[str, ProviderConfig] = field(default_factory=dict, init=False)
    _gate: asyncio.Semaphore | None = field(default=None, init=False)
    _http: httpx.AsyncClient | None = field(default=None, init=False)
    _http_key: tuple | None = field(default=None, init=False)
    #: Detected windows keyed by (protocol, base URL, model), so editing a card never reuses a
    #: stale value.
    _windows: dict[tuple[str, str, str], tuple[int | None, float]] = field(default_factory=dict, init=False)

    def register(self, config: ProviderConfig) -> None:
        self._providers[config.id] = config

    def unregister(self, provider_id: str) -> None:
        self._providers.pop(provider_id, None)

    def get(self, provider_id: str) -> ProviderConfig:
        config = self._providers.get(provider_id)
        if config is None:
            raise LlmError(ui(f"没有注册名为 {provider_id!r} 的 provider",
                              f"No provider named {provider_id!r} is registered"), NO_ADAPTER)
        return config

    def configs(self) -> list[ProviderConfig]:
        return list(self._providers.values())

    def describe_all(self) -> list[dict[str, object]]:
        """For the settings UI; never includes key material."""
        described: list[dict[str, object]] = []
        for config in self._providers.values():
            entry: dict[str, object] = {
                "id": config.id,
                "label": config.label or config.id,
                "protocol": config.protocol,
                "model": config.model,
                "base_url": config.effective_base_url,
                "context_window": config.context_window,
                # cached value only: listing providers never triggers a request
                "detected_window": self._cached_window(config),
                "reasoning": config.reasoning or REASONING_DEFAULT,
                "credential_ref": config.credential_ref,
                "capabilities": PROTOCOLS[config.protocol].describe(),
            }
            entry.update(self.credentials.describe(config.id))
            described.append(entry)
        return described

    async def context_window(self, provider_id: str) -> int | None:
        """Hand-filled window first, otherwise the detected one; None when unknown."""
        config = self.get(provider_id)
        if config.context_window:
            return config.context_window
        return await self.detected_window(provider_id)

    async def detected_window(self, provider_id: str) -> int | None:
        """Ask the endpoint for the model's window. Hits are cached for WINDOW_TTL, misses for WINDOW_RETRY."""
        config = self.get(provider_id)
        key = (config.protocol, config.effective_base_url, config.model)
        found = self._windows.get(key)
        now = time.monotonic()
        if found is not None and now - found[1] < (WINDOW_TTL if found[0] else WINDOW_RETRY):
            return found[0]
        window = await self._probe_window(config)
        self._windows[key] = (window, now)
        return window

    def _cached_window(self, config: ProviderConfig) -> int | None:
        found = self._windows.get((config.protocol, config.effective_base_url, config.model))
        return found[0] if found is not None else None

    async def _probe_window(self, config: ProviderConfig) -> int | None:
        adapter = config.adapter
        url = adapter.model_info_url(config.effective_base_url, config.model)
        if url is None:
            return None
        headers = {"Accept": "application/json"}
        try:
            # same auth headers as chat; ask even without a key, since OpenRouter's list is public
            headers = {**adapter.headers(self.credentials.get(config.id)), "Accept": "application/json"}
        except LlmError:
            pass
        try:
            response = await (await self._client()).get(url, headers=headers, timeout=WINDOW_PROBE_TIMEOUT)
            if response.status_code != 200:
                return None
            return adapter.context_window_from(response.json(), config.model)
        except (httpx.HTTPError, ValueError) as exc:
            # provider id and exception type only: URLs and messages may echo secrets
            logger.info("问上下文窗口没成 provider=%s：%s", config.id, exc.__class__.__name__)
            return None

    def _semaphore(self) -> asyncio.Semaphore:
        # created lazily: a Semaphore binds to the event loop it was created on
        if self._gate is None:
            self._gate = asyncio.Semaphore(self.max_concurrency)
        return self._gate

    async def _client(self) -> httpx.AsyncClient:
        """One shared client keeps the connection pool warm across questions.

        Created lazily (it binds to the running loop) and keyed by its settings, so changing a
        timeout actually takes effect.
        """
        key = (self.timeouts, self.max_concurrency, self.keepalive, self.transport)
        if self._http is not None and not self._http.is_closed and self._http_key == key:
            return self._http
        await self.aclose()
        self._http_key = key
        self._http = httpx.AsyncClient(
            timeout=httpx.Timeout(
                connect=self.timeouts.connect,
                # read is the gap between reads: covers both the first-token wait and a stream that stalls midway
                read=self.timeouts.first_token,
                write=self.timeouts.connect,
                pool=self.timeouts.connect,
            ),
            limits=self.limits(),
            transport=self.transport,
            follow_redirects=True,
        )
        return self._http

    def limits(self) -> httpx.Limits:
        """Pool limits and keepalive. Not httpx's 5 s default: people read an answer for a minute or two
        before asking again.
        """
        return httpx.Limits(
            max_connections=self.max_concurrency * 2,
            keepalive_expiry=self.keepalive,
        )

    async def aclose(self) -> None:
        """Close the pool; called at exit, and by _client when the settings change."""
        if self._http is not None and not self._http.is_closed:
            await self._http.aclose()
        self._http = None
        self._http_key = None

    async def stream(
        self, provider_id: str, request: CallRequest
    ) -> AsyncIterator[StreamChunk]:
        """Streaming call; ends with exactly one Finish unless cancelled."""
        config = self.get(provider_id)
        adapter = config.adapter
        # surface credential problems before connecting
        api_key = self.credentials.get(provider_id)

        # Apply the provider's reasoning budget here, once, rather than at every call site.
        # An explicit value on the request wins.
        if request.reasoning is None and config.reasoning != "":
            request = replace(request, reasoning=config.reasoning or REASONING_DEFAULT)

        url = adapter.endpoint(config.effective_base_url, request)
        headers = adapter.headers(api_key)
        # Send only the model name from settings; routing is the gateway's business.
        payload = adapter.payload(request)

        logger.info(
            "llm 请求 provider=%s protocol=%s model=%s 缓存前缀=%s 指纹=%s",
            config.id, config.protocol, request.model,
            request.cacheable_prefix, prefix_fingerprint(request),
        )

        async with self._semaphore():
            async for chunk in self._attempts(
                await self._client(), adapter, url, headers, payload, request
            ):
                yield chunk

    async def _attempts(
        self,
        client: httpx.AsyncClient,
        adapter: ProtocolAdapter,
        url: str,
        headers: dict[str, str],
        payload: dict[str, object],
        request: CallRequest,
    ) -> AsyncIterator[StreamChunk]:
        attempt = 0
        clock = timing.current()
        while True:
            attempt += 1
            emitted = False
            failure: LlmFailure | None = None

            try:
                extensions = {}
                if clock is not None:
                    clock.step_mark("send")
                    clock.step_count("attempts")
                    extensions = {"trace": _trace_into(clock)}
                async with client.stream(
                    "POST", url, headers=headers, json=payload, extensions=extensions
                ) as response:
                    if clock is not None:
                        clock.step_mark("headers")
                    if response.status_code != 200:
                        raw = await response.aread()
                        body = self.credentials.redact(
                            raw.decode("utf-8", errors="replace")
                        )
                        failure = LlmFailure(
                            message=adapter.error_detail(body)[:500]
                            or ui("上游返回错误", "The provider returned an error"),
                            code=adapter.classify(response.status_code, body),
                            status=response.status_code,
                            retry_after=parse_retry_after(
                                response.headers.get("retry-after")
                            ),
                        )
                    else:
                        translator = adapter.translator()
                        deadline = time.monotonic() + self.timeouts.total
                        raw = response.aiter_bytes()
                        if clock is not None:
                            raw = _counted(raw, clock)
                        async for event in aiter_sse(raw):
                            if time.monotonic() > deadline:
                                raise httpx.ReadTimeout(
                                    f"流超过 {self.timeouts.total} 秒上限"
                                )
                            for chunk in translator.feed(event):
                                if isinstance(chunk, (TextDelta, ThinkingDelta)):
                                    emitted = True
                                if clock is not None:
                                    _observe(clock, chunk)
                                yield chunk
                        if clock is not None:
                            clock.step_mark("end")
                        settled = translator.finish()
                        if settled.kind != "error" or settled.failure is None:
                            yield settled
                            return
                        failure = settled.failure

            except asyncio.CancelledError:
                # Cancellation propagates: async with closes the connection so nothing keeps running.
                # The only path without a Finish.
                raise
            except httpx.TimeoutException as exc:
                failure = LlmFailure(self._safe(exc), TIMEOUT)
            except httpx.HTTPError as exc:
                failure = LlmFailure(self._safe(exc), TRANSPORT)

            if is_retryable(
                failure,
                attempt=attempt,
                emitted_content=emitted,
                policy=self.policy,
                purpose=request.purpose,
            ):
                delay = compute_delay(
                    attempt, policy=self.policy, retry_after=failure.retry_after
                )
                logger.info(
                    "llm 第 %d 次尝试失败（%s），%.1f 秒后重试",
                    attempt, failure.code, delay,
                )
                await asyncio.sleep(delay)
                continue

            yield Finish(kind="error", failure=failure)
            return

    def _safe(self, exc: Exception) -> str:
        """Redact exception text before it leaves: httpx messages include the URL (some vendors put
        keys in the query) and error bodies can echo the key.
        """
        return self.credentials.redact(str(exc) or exc.__class__.__name__)

    async def test(self, provider_id: str) -> dict[str, object]:
        """Send one minimal request to prove the provider works. Never returns credentials."""
        config = self.get(provider_id)
        request = CallRequest(
            model=config.model,
            messages=(Message.text("user", "ping"),),
            max_tokens=16,
            purpose="background",
        )
        usage = None
        try:
            async for chunk in self.stream(provider_id, request):
                if isinstance(chunk, Finish):
                    if chunk.kind == "error" and chunk.failure is not None:
                        return {
                            "ok": False,
                            "code": chunk.failure.code,
                            "message": chunk.failure.message,
                        }
                    usage = chunk.usage
        except LlmError as exc:
            return {"ok": False, "code": exc.code, "message": exc.failure.message}
        return {
            "ok": True,
            "model": config.model,
            "usage": usage.as_dict() if usage is not None else None,
        }


async def _counted(
    chunks: AsyncIterator[bytes], clock: timing.Recorder
) -> AsyncIterator[bytes]:
    """Record the provider's first byte and total bytes.

    The first byte is often a keep-alive comment (OpenRouter's ": OPENROUTER PROCESSING"),
    so it is tracked separately from the first reasoning and text.
    """
    async for chunk in chunks:
        clock.step_mark("first_byte")
        clock.step_count("bytes", len(chunk))
        yield chunk


def _trace_into(clock: timing.Recorder):
    """httpx trace -> recorder: was this a fresh connection?

    Upload completion isn't recorded: httpx reports when the kernel buffered the body, not when
    it arrived.
    """
    async def trace(name: str, info: dict) -> None:
        if name == "connection.connect_tcp.started":
            clock.step_mark("connect")
    return trace


def _observe(clock: timing.Recorder, chunk: StreamChunk) -> None:
    if isinstance(chunk, ThinkingDelta):
        clock.delta("thinking", len(chunk.text))
    elif isinstance(chunk, TextDelta):
        clock.delta("text", len(chunk.text))
    elif isinstance(chunk, ToolCall):
        clock.step_mark("first_tool_call")
        clock.step_count("tool_calls")
    elif isinstance(chunk, UsageUpdate):
        clock.usage(chunk.usage.as_dict())


registry = LlmRegistry()
