"""agent 对话的 HTTP 路由。两层各一条，都走 SSE。

这一层只做编排：装配请求、把循环里发生的事翻成 SSE 事件、把取消与批准接上。
真正的逻辑在 `tools/`（循环、调度、工具）与 `projects/`（上下文、日志、投影）。

**事件名在 `api/sse.py` 的 `AgentEvent` 里，是跨语言契约** —— 改它必须同步改
Swift 客户端。对不上的表现不是报错，是界面永远转圈。

三条在这一层兑现的红线：

- **未经人工确认的上下文不得参与问答。** `context.assemble()` 会直接拒绝装配，
  这里把它翻成 409 并说清该去点确认 —— 而不是变成一个 500 让用户猜。
- **API key 不进错误消息、不回显。** 往流里写的只有稳定 code 与我们自己
  写的文案，厂商错误体一律不原样转发。
- **长任务走 jobs 登记才能被取消。** 取消之后每个 `tool/call` 都必须有配对的
  `tool/result`（调度器负责补），否则下一次请求非法。
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
from typing import AsyncIterator

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, field_validator

from .. import config
from ..i18n import ui
from ..jobs import jobs
from ..llm import LlmError, timing
from ..llm.registry import registry as llm_registry
from ..llm.types import TextDelta, ThinkingDelta, UsageUpdate
from ..projects import ProjectError, assemble, projects
from ..projects.workspace import WorkspaceError, check_confirmed
from ..projects.session import derive_messages, derive_transcript, summarise_call
from ..tools import AgentLoop, StoreJournal, librarian, reader
from ..tools.approval import APPROVAL_TIMEOUT, approvals
from .sse import HEARTBEAT_SECONDS, AgentEvent, encode

logger = logging.getLogger("scivane.api.agent")

router = APIRouter(tags=["agent"])


class ChatIn(BaseModel):
    question: str = Field(min_length=1)
    provider: str = Field(min_length=1)
    #: 覆盖 provider 配置里的模型名（可选）。
    model: str | None = None
    #: 本次调用用户已确认可写的顶层目录，如 ["notes"]。
    #: 按调用携带 —— 上一条命令写不了 notes/，这一条（已确认）可以。
    confirmed: list[str] = Field(default_factory=list)
    max_steps: int | None = None
    #: 这一轮说给哪条对话听。不给就接着最近那条（一条都没有就开一条），
    #: 所以老客户端不带它也能正常工作。
    conversation: str | None = None

    @field_validator("confirmed")
    @classmethod
    def _only_confirmable(cls, value: list[str]) -> list[str]:
        """**在进门的地方拦。** `confirmed` 从这里一路直通沙箱策略；只有需要确认的
        那几层（今天是 notes/）能出现在里面，别的名字给 422，不悄悄放过也不悄悄丢掉。
        """
        try:
            check_confirmed(value)
        except WorkspaceError as exc:
            raise ValueError(str(exc)) from exc
        return value


class CancelIn(BaseModel):
    job_id: str


class ApproveIn(BaseModel):
    job_id: str
    call_id: str
    approved: bool
    reason: str = ""


# --- 事件流 --------------------------------------------------------------


class Emitter:
    """把循环里发生的事推成 SSE 事件。

    做成队列而不是直接 yield，是因为事件有三个来源（模型流、工具日志、
    批准通道），它们在不同的调用栈里，只有汇到一处才好按时间顺序发出去。
    """

    def __init__(self) -> None:
        self.queue: asyncio.Queue[tuple[str, dict] | None] = asyncio.Queue()

    def emit(self, event: str, payload: dict) -> None:
        self.queue.put_nowait((event, payload))

    def close(self) -> None:
        self.queue.put_nowait(None)


class StreamingJournal:
    """既落盘又往流里发。

    落盘那一半照旧交给 `StoreJournal`（凡是进入过模型请求的东西都要能从日志
    重建）；发流那一半只给界面看，**预览而不是全文** —— 一次 grep 的结果可能
    几万字，整块推给界面没有意义，全文在日志里、也在 workbench/tool-results/。
    """

    #: 推给界面的结果预览长度。
    PREVIEW = 600

    def __init__(self, store_journal: StoreJournal | None, emitter: Emitter) -> None:
        self._store = store_journal
        self._emitter = emitter

    def tool_call(self, call_id: str, name: str, arguments: dict) -> None:
        if self._store:
            self._store.tool_call(call_id, name, arguments)
        self._emitter.emit(AgentEvent.TOOL_CALL, {
            "call_id": call_id, "name": name, "arguments": arguments,
            "summary": summarise_call(name, arguments),
        })

    def tool_result(
        self, call_id: str, name: str, content: str, *, is_error: bool,
        detail: dict | None = None, synthetic: bool = False,
    ) -> None:
        if self._store:
            self._store.tool_result(
                call_id, name, content, is_error=is_error, detail=detail, synthetic=synthetic
            )
        payload = {
            "call_id": call_id, "name": name,
            "preview": content[: self.PREVIEW],
            "truncated": len(content) > self.PREVIEW,
            "is_error": is_error,
            # 界面要能分辨「工具报错了」和「工具根本没跑」
            "synthetic": synthetic,
        }
        if detail:
            payload["detail"] = detail
        self._emitter.emit(AgentEvent.TOOL_RESULT, payload)

        # 沙箱强度不足是**可报告的事实**，必须冒到界面上，
        # 否则它只报告给了日志。
        if detail and detail.get("enforcement") not in (None, "full"):
            self._emitter.emit(AgentEvent.ENFORCEMENT, {
                "call_id": call_id,
                "level": detail.get("enforcement"),
                "reason": detail.get("enforcement_reason", ""),
            })

    def tool_decision(self, call_id: str, name: str, approved: bool, reason: str = "") -> None:
        if self._store:
            self._store.tool_decision(call_id, name, approved, reason)

    def assistant_message(self, text: str, *, stop: str) -> None:
        if self._store:
            self._store.assistant_message(text, stop=stop)

    def user_message(self, text: str) -> None:
        if self._store:
            self._store.user_message(text)


async def _pump(
    emitter: Emitter, task: asyncio.Task, clock: timing.Recorder | None = None
) -> AsyncIterator[str]:
    """把队列里的事件发出去，顺便定时心跳。

    心跳的两个理由和 OCR 那条链路一样：客户端的空闲超时
    不会误杀连接，界面上的已用时间能一直在走。agent 这边更需要 ——
    一次 `bash` 可能跑几十秒，期间一个字都没有。

    `clock` 开着时记下每一帧交给 HTTP 层的时刻（`llm/timing.py`）：
    和客户端收到的时刻逐帧对齐，就分得清慢在转发还是慢在界面。
    """
    try:
        while True:
            try:
                item = await asyncio.wait_for(emitter.queue.get(), timeout=HEARTBEAT_SECONDS)
            except asyncio.TimeoutError:
                frame = encode(AgentEvent.HEARTBEAT, {"at": time.time()})
                if clock is not None:
                    clock.frame(AgentEvent.HEARTBEAT, len(frame))
                yield frame
                continue
            if item is None:
                break
            event, payload = item
            frame = encode(event, payload)
            if clock is not None:
                clock.frame(event, len(frame))
            yield frame
        # 循环里抛出的异常不能悄悄咽掉：它已经在 _run 里被翻成 ERROR 事件了，
        # 这里只做兜底，防止任务异常而流正常结束、界面以为一切顺利。
        if not task.done():
            await task
    finally:
        if clock is not None:
            clock.mark("closed")
            clock.write(config.TIMING_LOG)


# --- 装配与执行 ----------------------------------------------------------


def _request_shape(request, provider_id: str, job_id: str) -> dict[str, object]:
    """这一轮请求的形状：多大、哪几块各多大。**只有长度，没有内容。**

    「每轮都带着整篇论文、系统提示词和十个工具的 schema」是嫌疑之一，
    所以计时里要看得出静态前缀有多长。
    """
    try:
        config_ = llm_registry.get(provider_id)
        reasoning = config_.reasoning
        body_bytes = len(json.dumps(config_.adapter.payload(request), ensure_ascii=False).encode())
    except LlmError:
        reasoning, body_bytes = None, 0
    paper = request.messages[0] if request.messages else None
    return {
        "job": job_id,
        "provider": provider_id,
        "model": request.model,
        "reasoning": reasoning,
        "body_bytes": body_bytes,
        "system_chars": len(request.system or ""),
        "tools": len(request.tools),
        "tools_bytes": len(json.dumps([t.as_dict() for t in request.tools], ensure_ascii=False).encode()),
        "paper_chars": sum(len(getattr(b, "text", "")) for b in paper.content) if paper else 0,
        "messages": len(request.messages),
    }


def _provider_model(provider_id: str, override: str | None) -> str:
    try:
        return override or llm_registry.get(provider_id).model
    except LlmError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


def _network_watcher(emitter: Emitter):
    """把审计簿的一条记录翻成一个 NETWORK 事件。

    **只出主机、端口、方法** —— 路径与查询串在审计那一层就不存在了
    （`netproxy/audit.py`），这里也没有东西可漏。`first` 让界面知道该出
    那张显眼的卡还是收进折叠行。
    """
    def watch(entry) -> None:
        record = entry.record
        # **407 握手不是越界，不往界面上报。**
        #
        # 实测（2026-09-21）：`git clone` 经 libcurl 会先裸着发一次 CONNECT，
        # 收到带挑战头的 407 之后再带凭据重发 —— 这是 Basic 认证的标准两步。
        # 照实往上报的话，一次**完全成功**的 clone 会在工具卡上挂出琥珀色的
        # 「拦下 1」。那是良性噪音：狼来了喊多了，真的越界就没人看了。
        #
        # **审计簿里那一条仍然留着** —— 它是事实，只是不值得打扰用户。
        # 真正要显眼的是策略拒绝（LOOPBACK / PRIVATE / …）：那说明 agent
        # 试过去它不该去的地方。
        if record.reason == "NO_GRANT":
            return
        emitter.emit(AgentEvent.NETWORK, {
            "call_id": record.call_id,
            "host": record.host,
            "port": record.port,
            "method": record.method,
            "allowed": record.allowed,
            "reason": record.reason,
            "first": entry.first,
        })
    return watch


async def _run(
    loop: AgentLoop, request, emitter: Emitter, job_id: str, prefix: str,
    audit: object = None,
) -> None:
    """跑循环，把终态翻成 done / error。**永远要 close 流**，否则界面挂死。"""
    watching = (
        audit.watching(job_id, _network_watcher(emitter))  # type: ignore[attr-defined]
        if audit is not None else contextlib.nullcontext()
    )
    try:
        with watching:
            result = await loop.run(request)
            # **失败要发 error，不能发 done。** 循环把模型侧的失败翻成
            # `stop == "error"` 正常返回（不抛异常），早先这里照发 done ——
            # 界面不认识这个 stop 值，于是一个字都不显示，表现是「发了消息
            # 完全没反应」。key 过期（AUTH 401）实测就是这样静默掉的。
            if result.stop == "error" and result.failure is not None:
                # 日志里只出现 provider 与稳定码，**绝不出现凭据**
                logger.warning("agent 一轮失败 job=%s code=%s", job_id, result.failure.code)
                emitter.emit(AgentEvent.ERROR, {
                    "code": result.failure.code, "message": result.failure.message,
                })
                return
            emitter.emit(AgentEvent.DONE, {
                "stop": result.stop, "steps": result.steps,
                "exhausted": result.exhausted, "text": result.text,
                "usage": result.usage.as_dict(),
                "calls": [{"id": c.id, "name": c.name} for c in result.calls],
            })
    except LlmError as exc:
        # 只发我们自己的稳定 code 与文案 —— 厂商错误体可能带上游请求的回显，
        # 不原样转发（红线：凭据不进错误消息）。
        logger.warning("agent 一轮失败 job=%s code=%s", job_id, exc.code)
        emitter.emit(AgentEvent.ERROR, {"code": exc.code, "message": str(exc)})
    except asyncio.CancelledError:
        emitter.emit(AgentEvent.ERROR, {"code": "CANCELLED", "message": ui("已取消", "Canceled")})
        raise
    except Exception as exc:  # noqa: BLE001
        logger.exception("agent 一轮出错 job=%s", job_id)
        emitter.emit(AgentEvent.ERROR, {"code": "INTERNAL", "message": str(exc)})
    finally:
        # 还在等批准的请求要按拒绝了结，否则循环会挂到超时才退出
        approvals.abandon(prefix)
        jobs.forget(job_id)
        emitter.close()


def _instrumented(provider_id: str, emitter: Emitter, state: dict):
    """包一层 llm 流：原样透传给循环，同时把增量推给界面。

    包在这里而不是改 `loop.py`：循环不该知道「有人在看」这件事，
    它只管把模型和工具接起来。
    """

    async def stream(request):
        state["step"] += 1
        clock = timing.current()
        if clock is not None:
            clock.begin_step()
        emitter.emit(AgentEvent.MESSAGE_START, {
            "step": state["step"], "provider": provider_id, "model": request.model,
        })
        async for chunk in llm_registry.stream(provider_id, request):
            if isinstance(chunk, TextDelta):
                emitter.emit(AgentEvent.TEXT, {"text": chunk.text})
            elif isinstance(chunk, ThinkingDelta):
                emitter.emit(AgentEvent.THINKING, {"text": chunk.text})
            elif isinstance(chunk, UsageUpdate):
                # 缓存命中与写入分开报 —— 缓存是否生效是本产品最关心的指标
                emitter.emit(AgentEvent.USAGE, chunk.usage.as_dict())
            yield chunk

    return stream


def _approver(emitter: Emitter, prefix: str):
    """批准通道的消费端：发一条 approval_request，然后等裁决。"""

    async def approve(call, context) -> tuple[bool, str]:
        emitter.emit(AgentEvent.APPROVAL_REQUEST, {
            "call_id": call.id, "tool": call.name,
            "summary": summarise_call(call.name, call.arguments),
            "arguments": call.arguments,
            "expires_in": APPROVAL_TIMEOUT,
        })
        return await approvals.request(f"{prefix}{call.id}")

    return approve


# --- 读者那层 ------------------------------------------------------------


@router.post("/projects/{project_id}/agent/chat")
async def project_chat(project_id: str, body: ChatIn, http: Request):
    """在一个项目里和 agent 对话。SSE。"""
    clock = timing.Recorder(layer="reader") if config.TIMING else None
    if clock is not None:
        clock.mark("recv")
    try:
        project = projects.get(project_id)
    except ProjectError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    context_path = projects.context_path(project_id)
    markdown = (
        context_path.read_text(encoding="utf-8", errors="replace")
        if context_path.is_file() else ""
    )
    if not markdown.strip():
        raise HTTPException(
            status_code=409,
            detail=ui("这个项目还没有正文 —— 先识别原稿，或导入一份 Markdown。",
                      "This project has no text yet — run OCR on the original, or import a Markdown file."),
        )

    model = _provider_model(body.provider, body.model)
    # 先把「这一轮属于哪条对话」定下来，之后取历史与落盘都用它。
    # 不给就接着最近那条 —— 老客户端与验证脚本因此不必改。
    try:
        conversation = projects.ensure_conversation(project_id, body.conversation)
    except ProjectError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    # 历史从日志投影回来。**这是「退出重开对话还在」的唯一来源**，
    # 不要在别处另存一份，两份必然漂移。
    # **只取这一条对话的事件** —— 换一条对话就是换一段历史，
    # 这正是「多对话」在模型那边的全部含义。
    history = list(derive_messages(projects.events(project_id, conversation=conversation)))

    # job id 先定下来：取消信号要在读者诞生时就接进它的上下文。
    # **读者的上下文只由 `reader()` 造**—— 从前这里另拼了一份，
    # 那是 `confirmed` 之类的字段绕开唯一构造器的一条路。
    job_id = jobs.new_id()
    agent = reader(
        project_dir=str(projects.dir_for(project_id)),
        project_id=project_id,
        confirmed=tuple(body.confirmed),
        cancelled=lambda: jobs.is_cancelled(job_id),
    )
    try:
        request = assemble(
            project, markdown, body.question, history,
            model=model, tools=agent.schemas(), system=agent.system,
        )
    except ValueError as exc:
        # 红线：未经人工确认的上下文不得参与问答。这里要说清该做什么，
        # 而不是变成 500 让用户猜。
        raise HTTPException(
            status_code=409,
            detail=ui(f"{exc} —— 在项目上右键确认这份正文之后再提问。",
                      f"{exc} — right-click the project and confirm this text, then ask again."),
        ) from exc

    prefix = f"{job_id}:"
    emitter = Emitter()
    journal = StreamingJournal(StoreJournal(projects, project_id, conversation), emitter)
    journal.user_message(body.question)

    # 联网能力从 app.state 取。**取不到就是没有** —— 代理起不来时
    # `lifespan` 把它设成 None，这里一路传下去，工具拿不到凭据，
    # 沙箱策略退回默认的「无网」。第一层 fail closed 在这里闭合。
    network = getattr(http.app.state, "network", None)
    audit = getattr(http.app.state, "audit", None)

    agent_loop = AgentLoop(
        stream=_instrumented(body.provider, emitter, {"step": 0}),
        registry=agent.registry,
        context=agent.context,
        journal=journal,
        approve=_approver(emitter, prefix),
        network=network,
        job_id=job_id,
        **({"max_steps": body.max_steps} if body.max_steps else {}),
    )

    if clock is not None:
        clock.meta.update(_request_shape(request, body.provider, job_id))
        clock.mark("ready")
    # 计时器经 ContextVar 交给这一轮：`create_task` 复制当前上下文，
    # 循环、llm 层在任务里都看得见它，而它们不必知道谁在听。
    with timing.recording(clock):
        task = asyncio.create_task(
            _run(agent_loop, request, emitter, job_id, prefix, audit=audit)
        )

    async def stream() -> AsyncIterator[str]:
        # 把 conversation 回给客户端：它可能没指定，由后端选了最近那条。
        # **这是给既有事件加一个字段，不是新事件名** —— 跨语言的那张
        # 事件名断言表不受影响。
        first = encode(AgentEvent.MESSAGE_START, {"job_id": job_id, "step": 0,
                                                  "provider": body.provider, "model": model,
                                                  "conversation": conversation})
        if clock is not None:
            clock.frame(AgentEvent.MESSAGE_START, len(first))
        yield first
        async for frame in _pump(emitter, task, clock):
            yield frame

    return StreamingResponse(stream(), media_type="text/event-stream", headers=_NO_BUFFER)


@router.get("/projects/{project_id}/agent/transcript")
async def project_transcript(project_id: str, conversation: str | None = None):
    """某一条对话此前的记录，界面用它恢复历史。

    走的是和模型历史同一份日志、同一条配对纪律（`projects/session.py`），
    **界面侧不再另写一套解析** —— 写两份必然漂移，而漂移的那份会让用户
    看到一段与模型看到的不一样的历史。

    不指定 `conversation` 就给最近那条；一条都没有就是空的 ——
    **这里不建对话**，只是读，读操作不该在磁盘上留下东西。
    """
    try:
        projects.get(project_id, migrate=False)
    except ProjectError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    try:
        target = conversation or projects.latest_conversation(project_id)
        if target is None:
            return {"items": [], "conversation": None}
        items = derive_transcript(projects.events(project_id, conversation=target))
    except ProjectError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return {"items": items, "conversation": target}


@router.post("/projects/{project_id}/agent/cancel")
async def project_cancel(project_id: str, body: CancelIn):
    """取消一轮。调度器会给未派发的调用补合成结果，所以历史仍然合法。"""
    jobs.cancel(body.job_id)
    abandoned = approvals.abandon(f"{body.job_id}:")
    return {"cancelled": body.job_id, "abandoned_approvals": abandoned}


@router.post("/projects/{project_id}/agent/approve")
async def project_approve(project_id: str, body: ApproveIn):
    """回答一次批准请求。

    `delivered=false` 表示没落到等待者上：请求不存在、已经被回答过、或者
    已经超时按拒绝处理了 —— 客户端据此知道自己点晚了，而不是以为生效了。
    """
    delivered = approvals.resolve(
        f"{body.job_id}:{body.call_id}", body.approved, body.reason
    )
    return {"delivered": delivered, "approved": body.approved}


# --- 书房那层 ------------------------------------------------------------


class DeskChatIn(BaseModel):
    question: str = Field(min_length=1)
    provider: str = Field(min_length=1)
    model: str | None = None
    max_steps: int | None = None


@router.post("/agent/chat")
async def desk_chat(body: DeskChatIn):
    """和书房对话：只能列出、查找、打开、删除项目。SSE。

    **这一层不碰任何项目的内容。** 注册表里根本没有 shell 与文件工具
    （`librarian()` 用的就是过滤过的注册表），系统提示词也只讲清单那件事。
    路由这里同样不要把项目正文混进请求 —— 两层提示词互不污染有单测钉着，
    别在这一层破掉它。

    也不写会话日志：书房不属于任何项目，没有 `session.jsonl` 可写
    （用的是 `NullJournal` 的等价物 —— StreamingJournal 的 store 传 None）。
    """
    model = _provider_model(body.provider, body.model)
    agent = librarian(projects)

    from ..llm.types import CallRequest, Message

    request = CallRequest(
        model=model,
        messages=(Message.text("user", body.question),),
        system=agent.system,
        tools=agent.schemas(),
    )

    job_id = jobs.new_id()
    prefix = f"{job_id}:"
    emitter = Emitter()
    journal = StreamingJournal(None, emitter)

    agent_loop = AgentLoop(
        stream=_instrumented(body.provider, emitter, {"step": 0}),
        registry=agent.registry,
        context=type(agent.context)(cancelled=lambda: jobs.is_cancelled(job_id)),
        journal=journal,
        approve=_approver(emitter, prefix),
        **({"max_steps": body.max_steps} if body.max_steps else {}),
    )
    task = asyncio.create_task(_run(agent_loop, request, emitter, job_id, prefix))

    async def stream() -> AsyncIterator[str]:
        yield encode(AgentEvent.MESSAGE_START, {"job_id": job_id, "step": 0,
                                                "provider": body.provider, "model": model})
        async for frame in _pump(emitter, task):
            yield frame

    return StreamingResponse(stream(), media_type="text/event-stream", headers=_NO_BUFFER)


@router.post("/agent/cancel")
async def desk_cancel(body: CancelIn):
    jobs.cancel(body.job_id)
    return {"cancelled": body.job_id, "abandoned_approvals": approvals.abandon(f"{body.job_id}:")}


@router.post("/agent/approve")
async def desk_approve(body: ApproveIn):
    delivered = approvals.resolve(
        f"{body.job_id}:{body.call_id}", body.approved, body.reason
    )
    return {"delivered": delivered, "approved": body.approved}


#: 关掉中间层的缓冲，否则事件会被攒起来批量送达，流式就白做了。
_NO_BUFFER = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
