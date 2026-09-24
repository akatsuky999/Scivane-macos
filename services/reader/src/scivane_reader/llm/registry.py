"""Provider 注册表与统一的流式调用。

**一处机制、多处翻译。** 网络传输、重试、超时、并发上限、取消这些机制只在
这里写一遍；三套厂商协议只负责翻译请求与响应。接一家新厂商不用碰这个文件。

调用的不变式（单测逐条守着）：

- 一条流恰好产出一个 `Finish`，正常与失败走同一个出口；
- 已经产出过内容之后绝不重试（否则用户会看到重复文本）；
- 凭据不出现在任何抛出的错误、任何日志、任何返回给上层的结构里。

唯一的例外是**取消**：消费方中途走人时，`CancelledError` 原样向上传播，
不会再有 `Finish` —— 这时连接已经断开，也没有人在听了。
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


@dataclass(frozen=True)
class ProviderConfig:
    """一个已配置的 provider。

    「厂商」在本系统里就是这四个字段的组合，没有专门的厂商代码。
    接 DeepSeek 是 protocol=openai + base_url=api.deepseek.com/v1，
    接本地 Ollama 是 protocol=openai + base_url=localhost:11434/v1，
    两者共用同一个适配器。
    """

    id: str
    protocol: str
    model: str
    base_url: str = ""
    #: 显示名，仅供界面。
    label: str = ""
    #: 这个模型的上下文窗口有多大（token）。**可选，给界面画余量用。**
    #:
    #: 为什么让用户填而不是我们猜：这个系统里没有「厂商」这个概念，
    #: 一个 provider 就是「协议 + 地址 + 模型名」，同一个模型名在不同网关后面
    #: 可能是不同的窗口。**猜错比不显示更糟** —— 用户会照着一个假的余量
    #: 规划对话，直到某次突然撞上 CONTEXT_WINDOW_EXCEEDED。
    #: 不填就只报用量，不画余量条。
    context_window: int | None = None
    #: 这张卡的 key 从哪来：`own` = 卡片自己存了一把，`macro:<编号>` = 用共享的那把。
    #:
    #: **它不是秘密，只是个引用** —— 真正的 key 始终只在钥匙串里，由 App 解析之后
    #: 通过 `/credential` 注入，后端从头到尾不知道「宏观 key」这个概念存在
    #: （红线：key 不进 providers.json）。放在 provider 配置里而不是界面偏好里，
    #: 是为了让「这张卡怎么配的」只有一处事实来源。
    credential_ref: str = "own"

    #: 推理预算："none" / "low" / "medium" / "high"。None = 用 REASONING_DEFAULT。
    #:
    #: 放在 provider 上而不是全局：同一个系统里可能同时接着一个推理模型
    #: 和一个非推理模型，给后者传 effort 只会被忽略或者报错。
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
    """已注册的 provider，以及对它们的调用。进程内单例见模块底部。"""

    credentials: CredentialStore = field(default_factory=lambda: default_credentials)
    timeouts: Timeouts = DEFAULT_TIMEOUTS
    policy: RetryPolicy = DEFAULT_POLICY
    #: 同时在飞的请求上限。防止批量任务把厂商配额打爆。
    max_concurrency: int = 4
    #: 空闲连接留多久（秒）。见 `config.LLM_KEEPALIVE`：httpx 默认的 5 秒让每一问都从冷连接开始。
    keepalive: float = 300.0
    #: 测试注入点：传入 httpx.MockTransport 即可全程离线跑通。
    transport: httpx.AsyncBaseTransport | None = None

    _providers: dict[str, ProviderConfig] = field(default_factory=dict, init=False)
    _gate: asyncio.Semaphore | None = field(default=None, init=False)
    _http: httpx.AsyncClient | None = field(default=None, init=False)
    _http_key: tuple | None = field(default=None, init=False)

    # --- 注册 ---------------------------------------------------------

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
        """当前注册的全部配置，按注册顺序。落盘时用它。"""
        return list(self._providers.values())

    def describe_all(self) -> list[dict[str, object]]:
        """给设置界面用。**刻意不含任何凭据原文。**"""
        described: list[dict[str, object]] = []
        for config in self._providers.values():
            entry: dict[str, object] = {
                "id": config.id,
                "label": config.label or config.id,
                "protocol": config.protocol,
                "model": config.model,
                "base_url": config.effective_base_url,
                "context_window": config.context_window,
                "reasoning": config.reasoning or REASONING_DEFAULT,
                "credential_ref": config.credential_ref,
                "capabilities": PROTOCOLS[config.protocol].describe(),
            }
            entry.update(self.credentials.describe(config.id))
            described.append(entry)
        return described

    # --- 调用 ---------------------------------------------------------

    def _semaphore(self) -> asyncio.Semaphore:
        # 懒建：Semaphore 会绑定创建时的事件循环，不能在 __init__ 里建
        if self._gate is None:
            self._gate = asyncio.Semaphore(self.max_concurrency)
        return self._gate

    async def _client(self) -> httpx.AsyncClient:
        """复用同一个客户端，保住连接池。

        每个请求新建客户端会让每次提问都重做一次 TLS 握手 —— 论文问答是
        「一篇论文问很多个短问题」的场景，那笔开销每一轮都要付。
        懒建是必需的：客户端会绑定创建时的事件循环，也要等 lifespan 把
        超时与并发配置写进来之后再建。

        缓存按配置取键。少了这一步，改完超时或并发之后客户端还是旧的，
        而且**不会报错** —— 配置看起来生效了，实际没有。这种静默失效
        比直接报错难查得多。
        """
        key = (self.timeouts, self.max_concurrency, self.keepalive, self.transport)
        if self._http is not None and not self._http.is_closed and self._http_key == key:
            return self._http
        await self.aclose()
        self._http_key = key
        self._http = httpx.AsyncClient(
            timeout=httpx.Timeout(
                connect=self.timeouts.connect,
                # read 超时是「两次读之间的最长间隔」，既覆盖首 token 等待，
                # 也覆盖流中途卡死 —— 后者才是真正常见的失败模式
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
        """连接池的上限与保活。

        **保活不能用 httpx 默认的 5 秒。** 论文问答是「读完一段回答再问下一句」，
        两问之间常常隔一两分钟；5 秒一到连接就被丢掉，下一问要重新握手、把几十万字节的
        请求体从 TCP 慢启动开始传 —— 实测每问多 2.5–6.5 秒，而服务端空闲 240 秒后
        还在接着用那条连接。
        """
        return httpx.Limits(
            max_connections=self.max_concurrency * 2,
            keepalive_expiry=self.keepalive,
        )

    async def aclose(self) -> None:
        """关掉连接池。进程退出时调；配置变化时 `_client` 会自己调。"""
        if self._http is not None and not self._http.is_closed:
            await self._http.aclose()
        self._http = None
        self._http_key = None

    async def stream(
        self, provider_id: str, request: CallRequest
    ) -> AsyncIterator[StreamChunk]:
        """流式调用。恰好以一个 `Finish` 结束（取消除外）。"""
        config = self.get(provider_id)
        adapter = config.adapter
        # 凭据问题要在建连之前就暴露，别让用户等一个注定失败的请求
        api_key = self.credentials.get(provider_id)

        # 推理预算跟着 provider 走。**在这里合而不是让上层每处都记得传** ——
        # 装配请求的地方有好几处（agent 循环、裸问答、连接测试），
        # 漏掉一处的表现是「设置里调了没反应」，而且不会报错。
        # 调用方显式给了就尊重它（测试要能钉住具体值）。
        if request.reasoning is None and config.reasoning != "":
            request = replace(request, reasoning=config.reasoning or REASONING_DEFAULT)

        url = adapter.endpoint(config.effective_base_url, request)
        headers = adapter.headers(api_key)
        # **不替用户改路由**：请求里只有设置里写的那个模型名，
        # 网关背后交给哪一家由网关自己定 —— 不加 `provider` 这类偏好。
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
                # 取消原样上抛：async with 会在退出时断开连接，不让请求在
                # 后台空跑烧钱。这是唯一不产出 Finish 的路径。
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
        """异常文本脱敏后再外传。

        httpx 的异常消息里会带上完整 URL，而某些厂商把凭据放在 query 里；
        厂商的错误体也可能把 key 原样回显。不过这一道，一条 400 就能把凭据
        写进 var/logs/api.log。
        """
        return self.credentials.redact(str(exc) or exc.__class__.__name__)

    # --- 连通性自检 ---------------------------------------------------

    async def test(self, provider_id: str) -> dict[str, object]:
        """打一次最小请求，确认这个 provider 真的能用。

        设置界面上「测试连接」按钮背后就是它。返回结构里不含凭据。
        """
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
    """记下厂商的第一个字节与总字节数，原样往下传。

    第一个字节常常不是内容：OpenRouter 在上游还没开口时先发 `: OPENROUTER PROCESSING`
    这类注释保活。所以「第一个字节」和「第一段推理」要分开记 —— 前者说明连接通了，
    后者才说明模型开始干活。
    """
    async for chunk in chunks:
        clock.step_mark("first_byte")
        clock.step_count("bytes", len(chunk))
        yield chunk


def _trace_into(clock: timing.Recorder):
    """httpx 的逐步跟踪 → 计时器：**这一问是不是新建了连接**（冷连接要重新握手）。

    **不记「请求体传完」**：httpx 报的 `send_request_body.complete` 是交给内核的时刻 ——
    内核缓冲一收下就算完，二三十万字节的请求体实测显示 0.00 秒，真正送到对端要晚得多
    （上行差时十几秒）。拿它当上传时长会下错结论；上传只能看「发出 → 响应头」的整段。
    """
    async def trace(name: str, info: dict) -> None:
        if name == "connection.connect_tcp.started":
            clock.step_mark("connect")
    return trace


def _observe(clock: timing.Recorder, chunk: StreamChunk) -> None:
    """一个统一分片落进计时器。只收字数与 token 数。"""
    if isinstance(chunk, ThinkingDelta):
        clock.delta("thinking", len(chunk.text))
    elif isinstance(chunk, TextDelta):
        clock.delta("text", len(chunk.text))
    elif isinstance(chunk, ToolCall):
        clock.step_mark("first_tool_call")
        clock.step_count("tool_calls")
    elif isinstance(chunk, UsageUpdate):
        clock.usage(chunk.usage.as_dict())


#: 进程内单例。与 jobs.py 的 `jobs`、credentials.py 的 `credentials` 同一模式。
registry = LlmRegistry()
