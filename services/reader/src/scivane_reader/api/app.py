"""FastAPI application factory."""

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

    # Report missing OCR pieces once but keep serving: /health must answer so the app can show why.
    # Cloud Q&A does not depend on local OCR.
    for problem in runtime.preflight():
        logger.warning("运行时检查未通过：%s", problem)

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

    # The audit proxy failing to start is not fatal: tools then get no credentials and the
    # sandbox stays offline, which is the safe direction.
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
    await llm_registry.aclose()


class UILanguage:
    """Put the request's UI language into the ContextVar (i18n.py).

    Pure ASGI rather than BaseHTTPMiddleware: everything here is a long-lived SSE stream and
    cancel-on-disconnect relies on the connection passing through untouched.
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
    app = FastAPI(title="Scivane Reader", version="0.0.3", lifespan=lifespan)
    app.add_middleware(UILanguage)
    app.include_router(router)
    app.include_router(llm_router)
    app.include_router(project_router)
    app.include_router(agent_router)
    return app


app = create_app()
