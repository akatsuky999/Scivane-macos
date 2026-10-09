"""Provider registry and the single streaming call path.

Transport, retries, timeouts, concurrency and cancellation live here once; protocol adapters
only translate. Every stream ends with exactly one Finish, nothing is retried after content
was emitted, and credentials never appear in errors, logs or responses. Cancellation
propagates CancelledError and yields no Finish.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import AsyncIterator
from contextlib import aclosing
from dataclasses import dataclass, field, replace
from pathlib import Path

import httpx

from ..i18n import ui
from . import timing, vision as vision_probe
from .adapters import PROTOCOLS, ProtocolAdapter
from .adapters.base import aiter_sse
from .cache import prefix_fingerprint
from .credentials import CredentialStore, credentials as default_credentials
from .types import REASONING_DEFAULT
from .errors import (
    INVALID_ARGS,
    NO_ADAPTER,
    NO_VISION,
    TIMEOUT,
    TRANSPORT,
    UNKNOWN,
    LlmError,
    LlmFailure,
    looks_like_no_vision,
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

#: What the endpoint's model list says (window, input modalities) expires: '-latest' aliases can
#: switch versions.
WINDOW_TTL = 6 * 3600.0
#: ask again after this long when the list said nothing or couldn't be read
WINDOW_RETRY = 600.0
#: OpenRouter's model list is several hundred KB
WINDOW_PROBE_TIMEOUT = 8.0
#: Vision verdicts outlive backend restarts (the backend stops when idle), but '-latest' aliases
#: can switch models, so they still expire.
VISION_TTL = 7 * 24 * 3600.0


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


@dataclass(frozen=True)
class ModelListing:
    """What the endpoint's model list says about one model; None where it says nothing."""

    window: int | None = None
    #: declared input modalities ("text", "image", ...)
    modalities: frozenset[str] | None = None

    @property
    def vision(self) -> bool | None:
        return None if self.modalities is None else "image" in self.modalities

    @property
    def said_anything(self) -> bool:
        return self.window is not None or self.modalities is not None


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
    #: Where vision verdicts persist; None keeps them in memory only. A cache: deleting it costs
    #: one small request per card.
    vision_store: Path | None = None

    _providers: dict[str, ProviderConfig] = field(default_factory=dict, init=False)
    _gate: asyncio.Semaphore | None = field(default=None, init=False)
    _http: httpx.AsyncClient | None = field(default=None, init=False)
    _http_key: tuple | None = field(default=None, init=False)
    #: Model-list facts keyed by (protocol, base URL, model), so editing a card never reuses a
    #: stale value.
    _listings: dict[tuple[str, str, str], tuple[ModelListing, float]] = field(default_factory=dict, init=False)
    #: Vision verdicts, same key; loaded from vision_store on first use. Wall-clock times, since
    #: they are persisted.
    _vision: dict[tuple[str, str, str], tuple[bool, float]] | None = field(default=None, init=False)

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
                # cached verdict only (None = never checked); checking costs a request
                "vision": self.cached_vision(config.id),
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
        """Ask the endpoint for the model's window (see _listing for caching)."""
        return (await self._listing(self.get(provider_id))).window

    def _cached_window(self, config: ProviderConfig) -> int | None:
        found = self._listings.get(self._model_key(config))
        return found[0].window if found is not None else None

    async def _listing(self, config: ProviderConfig, *, refresh: bool = False) -> ModelListing:
        """The endpoint's model list, read once for both the window and the modalities. Lists that
        said something are kept for WINDOW_TTL, the rest for WINDOW_RETRY.
        """
        key = self._model_key(config)
        found = self._listings.get(key)
        now = time.monotonic()
        if (not refresh and found is not None
                and now - found[1] < (WINDOW_TTL if found[0].said_anything else WINDOW_RETRY)):
            return found[0]
        listing = await self._read_listing(config)
        self._listings[key] = (listing, now)
        return listing

    async def _read_listing(self, config: ProviderConfig) -> ModelListing:
        adapter = config.adapter
        url = adapter.model_info_url(config.effective_base_url, config.model)
        if url is None:
            return ModelListing()
        headers = {"Accept": "application/json"}
        try:
            # same auth headers as chat; ask even without a key, since OpenRouter's list is public
            headers = {**adapter.headers(self.credentials.get(config.id)), "Accept": "application/json"}
        except LlmError:
            pass
        try:
            response = await (await self._client()).get(url, headers=headers, timeout=WINDOW_PROBE_TIMEOUT)
            if response.status_code != 200:
                return ModelListing()
            payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            # provider id and exception type only: URLs and messages may echo secrets
            logger.info("读模型列表没成 provider=%s：%s", config.id, exc.__class__.__name__)
            return ModelListing()
        return ModelListing(
            window=adapter.context_window_from(payload, config.model),
            modalities=adapter.input_modalities_from(payload, config.model),
        )

    def cached_vision(self, provider_id: str) -> bool | None:
        """Whether the card's model reads images, from what is already known: the endpoint's
        declaration if its list has been read, else the last remembered verdict. None when neither
        (or it expired). Never makes a request.
        """
        try:
            config = self.get(provider_id)
        except LlmError:
            return None
        found = self._listings.get(self._model_key(config))
        if found is not None and found[0].vision is not None:
            return found[0].vision
        return self._remembered_vision(config)

    async def vision(self, provider_id: str, *, refresh: bool = False) -> vision_probe.VisionCheck:
        """Whether the card's model reads images.

        What the endpoint declares comes first (OpenRouter lists each model's input modalities):
        it costs no model request, and no misread or routing hiccup can turn into a verdict.
        Only when nothing is declared is the model shown a probe image. Definite answers are
        remembered; a probe that couldn't run (no key, quota) is asked again next time.
        """
        config = self.get(provider_id)
        declared = (await self._listing(config, refresh=refresh)).vision
        if declared is not None:
            self._remember_vision(config, declared)
            logger.info("看图检测 provider=%s 结果=%s 来源=接入点声明", provider_id, declared)
            return _verdict(declared)
        if not refresh:
            remembered = self._remembered_vision(config)
            if remembered is not None:
                return _verdict(remembered)
        check = await vision_probe.probe(
            lambda request: self.stream(provider_id, request), config.model)
        if check.supported is not None:
            self._remember_vision(config, check.supported)
        logger.info("看图检测 provider=%s 结果=%s code=%s 来源=试图", provider_id, check.supported, check.code)
        return check

    def _remembered_vision(self, config: ProviderConfig) -> bool | None:
        found = self._vision_table().get(self._model_key(config))
        if found is None or time.time() - found[1] > VISION_TTL:
            return None
        return found[0]

    def _remember_vision(self, config: ProviderConfig, verdict: bool) -> None:
        """Persisted, so a restarted backend (it stops when idle) lists it without a request.
        Rewritten only when it changes or is halfway to expiring: a declaration is re-read before
        every transcription.
        """
        key = self._model_key(config)
        stored = self._vision_table().get(key)
        if stored is not None and stored[0] == verdict and time.time() - stored[1] < VISION_TTL / 2:
            return
        self._vision_table()[key] = (verdict, time.time())
        self._save_vision()

    @staticmethod
    def _model_key(config: ProviderConfig) -> tuple[str, str, str]:
        return (config.protocol, config.effective_base_url, config.model)

    def _vision_table(self) -> dict[tuple[str, str, str], tuple[bool, float]]:
        if self._vision is None:
            self._vision = {}
            if self.vision_store is not None:
                try:
                    raw = json.loads(self.vision_store.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    raw = []
                for entry in raw if isinstance(raw, list) else []:
                    try:
                        key = (str(entry["protocol"]), str(entry["base_url"]), str(entry["model"]))
                        if isinstance(entry["vision"], bool):
                            self._vision[key] = (entry["vision"], float(entry["at"]))
                    except (KeyError, TypeError, ValueError):
                        continue
        return self._vision

    def _save_vision(self) -> None:
        if self.vision_store is None:
            return
        entries = [
            {"protocol": key[0], "base_url": key[1], "model": key[2], "vision": verdict, "at": at}
            for key, (verdict, at) in self._vision_table().items()
        ]
        try:
            self.vision_store.parent.mkdir(parents=True, exist_ok=True)
            staging = self.vision_store.with_suffix(self.vision_store.suffix + ".writing")
            staging.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
            staging.replace(self.vision_store)
        except OSError as exc:
            # a cache: failing to write it only costs another probe later
            logger.info("看图检测结果没存下：%s", exc.__class__.__name__)

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
            # aclosing: a consumer that stops early closes this generator, and the response inside
            # must close with it rather than whenever the abandoned inner one is collected
            async with aclosing(self._attempts(
                await self._client(), adapter, url, headers, payload, request
            )) as attempts:
                async for chunk in attempts:
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
                        detail = adapter.error_detail(body)
                        code = _vision_aware(adapter.classify(response.status_code, body), detail, request)
                        failure = LlmFailure(
                            message=detail[:500]
                            or ui("上游返回错误", "The provider returned an error"),
                            code=code,
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
                        # reported inside the stream: the same care as an HTTP error body
                        message = self.credentials.redact(settled.failure.message)
                        failure = replace(
                            settled.failure, message=message,
                            code=_vision_aware(settled.failure.code, message, request))

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
        """Prove the card works: one request shaped like a chat request, read until the model
        starts generating. Never returns credentials.

        The model starting to answer (thinking counts) already proves the address, key and model
        name; the stream is closed there. No output cap is set: a reasoning model spends a small
        cap on thinking and the answer comes back empty, and some APIs reject the cap's parameter
        on reasoning models outright. Closing early keeps the cost to the first few tokens.
        """
        config = self.get(provider_id)
        request = CallRequest(
            model=config.model,
            messages=(Message.text("user", "ping"),),
            purpose="background",
        )
        try:
            async with aclosing(self.stream(provider_id, request)) as chunks:
                async for chunk in chunks:
                    if isinstance(chunk, (TextDelta, ThinkingDelta, ToolCall)):
                        break
                    if isinstance(chunk, Finish):
                        if chunk.kind == "error" and chunk.failure is not None:
                            return {
                                "ok": False,
                                "code": chunk.failure.code,
                                "message": chunk.failure.message,
                            }
                        break
        except LlmError as exc:
            return {"ok": False, "code": exc.code, "message": exc.failure.message}
        return {"ok": True, "model": config.model}


def _vision_aware(code: str, detail: str, request: CallRequest) -> str:
    """A rejection that reads like "this model takes no images" is NO_VISION, but only with images
    aboard: elsewhere the same words mean something else.
    """
    if request.has_images and code in (INVALID_ARGS, UNKNOWN) and looks_like_no_vision(detail):
        return NO_VISION
    return code


def _verdict(supported: bool) -> vision_probe.VisionCheck:
    if supported:
        return vision_probe.VisionCheck(True)
    return vision_probe.VisionCheck(
        False, NO_VISION, ui("这个模型看不到图片", "This model can't see images"))


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
