"""FastAPI 应用装配。"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from .. import config, i18n, runtime
from ..netproxy import AuditLog, AuditProxy, GrantBook, NetworkAccess
from ..llm import load_providers, registry as llm_registry
from ..llm.retry import RetryPolicy, Timeouts
from .agent_routes import router as agent_router
from .llm_routes import router as llm_router
from .project_routes import router as project_router
from .routes import router

logger = logging.getLogger("scivane.api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    for d in (config.JOBS_DIR, config.LOGS_DIR, config.RUN_DIR):
        d.mkdir(parents=True, exist_ok=True)

    # 运行时缺东西的话在这里一次性说清楚。不直接退出：
    # /health 还得能应答，App 才有办法把原因显示给用户。
    #
    # 注意这里检查的是**本地 OCR 引擎**。云端问答不依赖它 —— 读论文时
    # 本地负责把 PDF 变成 Markdown，云端负责在这份 Markdown 上推理，
    # 两条链路彼此独立，缺一个不该拖垮另一个。
    for problem in runtime.preflight():
        logger.warning("运行时检查未通过：%s", problem)

    # 大模型层：超时与并发从 config 取，保持「配置只在一处」的纪律
    llm_registry.timeouts = Timeouts(
        connect=config.LLM_CONNECT_TIMEOUT,
        first_token=config.LLM_FIRST_TOKEN_TIMEOUT,
        total=config.LLM_TOTAL_TIMEOUT,
    )
    llm_registry.policy = RetryPolicy(max_retries=config.LLM_MAX_RETRIES)
    llm_registry.max_concurrency = config.LLM_CONCURRENCY
    llm_registry.keepalive = config.LLM_KEEPALIVE
    loaded = load_providers(config.LLM_PROVIDERS_PATH)
    logger.info(
        "大模型 provider 已加载 %d 个（配置：%s）", loaded, config.LLM_PROVIDERS_PATH
    )

    # 本地审计代理：沙箱那个针孔后面站着的东西。
    #
    # **起不来不是致命错误。** 第一层 fail closed 就在这里兑现：没有代理，
    # 工具拿不到凭据，沙箱策略就是默认的「无网」—— 命令照跑，只是连不出去，
    # 而 agent 会从错误消息里知道原因。比起让整个后端起不来（连项目列表
    # 都没了），这是正确的失败方向。
    app.state.audit = AuditLog(limit=config.NETPROXY_AUDIT_LIMIT)
    app.state.grants = GrantBook()
    app.state.proxy = AuditProxy(app.state.grants, app.state.audit)
    try:
        port = await app.state.proxy.start()
        app.state.network = NetworkAccess(app.state.proxy, app.state.grants)
        logger.info("审计代理已就绪：127.0.0.1:%s（沙箱的唯一出网口）", port)
    except OSError as exc:
        app.state.network = None
        logger.warning("审计代理起不来，agent 这次运行没有网络：%s", exc)

    logger.info(
        "Scivane reader on %s:%s -> llama %s (%s)",
        config.API_HOST, config.API_PORT, config.LLAMA_BASE_URL, runtime.describe(),
    )
    yield

    await app.state.proxy.stop()
    # 关掉大模型层的连接池，让进程能干净退出
    await llm_registry.aclose()


class UILanguage:
    """把请求头里的界面语言放进 ContextVar（`i18n.py`）。

    **纯 ASGI，不包 send / receive。** `BaseHTTPMiddleware` 会在中间插一层任务，
    而这里全是 SSE 长连接 —— 断流即取消靠的正是那条连接的
    原样透传，不值得为读一个请求头去冒这个险。

    设在这里的值怎么跟到流里：流式响应的生成器、`create_task` 起的那一轮循环、
    `to_thread` 跑的工具体都在这个请求的上下文里（复制过去的）；自己起的线程见
    `api/routes.py`。
    """

    _HEADER = i18n.HEADER.lower().encode("latin-1")

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return
        raw = next((value for key, value in scope.get("headers", ()) if key == self._HEADER), None)
        with i18n.speaking(i18n.parse(raw.decode("latin-1") if raw else None)):
            await self.app(scope, receive, send)


def create_app() -> FastAPI:
    app = FastAPI(title="Scivane Reader", version="0.1.0", lifespan=lifespan)
    app.add_middleware(UILanguage)
    app.include_router(router)
    app.include_router(llm_router)
    app.include_router(project_router)
    app.include_router(agent_router)
    return app


app = create_app()
