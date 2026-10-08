"""HTTP routes for agent conversations (reader and librarian), both SSE.

Orchestration only; the logic lives in tools/ and projects/. Event names in api/sse.py are a
contract with the Swift client. Unconfirmed context is refused with a 409, provider error
bodies are never forwarded, and every cancelled tool call still gets a result.
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
from ..llm.estimate import estimate_request
from ..llm.types import CallRequest, Finish, TextDelta, ThinkingDelta, UsageUpdate
from ..projects import ProjectError, assemble, projects
from ..projects.compaction import Compactor, CompactionError, auto_threshold, occupy
from ..projects.compaction import release as release_conversation
from ..projects.context import paper_message
from ..projects.meter import calibration, measure
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
    model: str | None = None
    #: Top-level dirs the user confirmed as writable for this call, e.g. ["notes"].
    confirmed: list[str] = Field(default_factory=list)
    max_steps: int | None = None
    #: Conversation to continue; defaults to the most recent one (or a new one).
    conversation: str | None = None

    @field_validator("confirmed")
    @classmethod
    def _only_confirmable(cls, value: list[str]) -> list[str]:
        """Validated at the door: `confirmed` flows straight into the sandbox policy, so only
        confirmable tiers (today notes/) pass; anything else is a 422.
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



class Emitter:
    """Turns loop activity into SSE events. A queue merges the three sources (model stream,
    tool journal, approvals) in order.
    """

    def __init__(self) -> None:
        self.queue: asyncio.Queue[tuple[str, dict] | None] = asyncio.Queue()

    def emit(self, event: str, payload: dict) -> None:
        self.queue.put_nowait((event, payload))

    def close(self) -> None:
        self.queue.put_nowait(None)


class StreamingJournal:
    """Journal that both persists and streams. The UI gets a preview; the full result stays in the log."""

    PREVIEW = 600

    def __init__(
        self, store_journal: StoreJournal | None, emitter: Emitter, meter: Compactor | None = None
    ) -> None:
        self._store = store_journal
        self._emitter = emitter
        #: Reader only: assistant messages record usage and the estimate so the next open can calibrate.
        self._meter = meter

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
            # lets the UI tell "tool failed" from "tool never ran"
            "synthetic": synthetic,
        }
        if detail:
            payload["detail"] = detail
        self._emitter.emit(AgentEvent.TOOL_RESULT, payload)

        # Partial sandbox enforcement must reach the UI, not just the log.
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
            record = self._meter.step_record() if self._meter is not None else {}
            self._store.assistant_message(text, stop=stop, **record)

    def user_message(self, text: str) -> None:
        if self._store:
            self._store.user_message(text)


async def _pump(
    emitter: Emitter, task: asyncio.Task, clock: timing.Recorder | None = None
) -> AsyncIterator[str]:
    """Drain the queue with periodic heartbeats (one bash call can be silent for a minute).

    With `clock` set, records when each frame reaches the HTTP layer (llm/timing.py).
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
        # Safety net: a crashed task must not look like a clean end of stream.
        if not task.done():
            await task
    finally:
        if clock is not None:
            clock.mark("closed")
            clock.write(config.TIMING_LOG)



def _request_shape(request, provider_id: str, job_id: str) -> dict[str, object]:
    """Size of this turn's request by part. Lengths only, no content."""
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


async def _window(provider_id: str | None) -> int | None:
    """Context window for the card: hand-filled first, otherwise asked from the endpoint;
    None when unknown.
    """
    if not provider_id:
        return None
    try:
        return await llm_registry.context_window(provider_id)
    except LlmError:
        return None


def _paper_text(project_id: str) -> str:
    path = projects.context_path(project_id)
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""


def _busy() -> str:
    return ui("这条对话还有一轮没结束（或者正在压缩）—— 等它结束再发。",
              "This conversation is still busy with a previous turn or a compaction — wait for it to finish.")


def _network_watcher(emitter: Emitter):
    """Map an audit record to a NETWORK event: host, port and method only."""
    def watch(entry) -> None:
        record = entry.record
        # A 407 challenge is not a violation: libcurl's git clone sends CONNECT without credentials
        # first. Reporting it would flag every successful clone; the audit log keeps the record.
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
    audit: object = None, epilogue=None, release=None,
) -> None:
    """Run the loop and translate its end into done/error, always closing the stream.

    `epilogue` runs before the terminal event and cannot fail the turn; `release` always runs.
    """
    watching = (
        audit.watching(job_id, _network_watcher(emitter))  # type: ignore[attr-defined]
        if audit is not None else contextlib.nullcontext()
    )
    try:
        with watching:
            result = await loop.run(request)
            if epilogue is not None:
                try:
                    epilogue()
                except Exception:  # noqa: BLE001
                    logger.exception("一轮的收尾没做成 job=%s", job_id)
            # Model-side failures come back as stop == "error"; send ERROR, not DONE, or the UI shows nothing.
            if result.stop == "error" and result.failure is not None:
                # only the provider and a stable code; never credentials
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
        # Only our own code and message: provider error bodies may echo the request.
        logger.warning("agent 一轮失败 job=%s code=%s", job_id, exc.code)
        emitter.emit(AgentEvent.ERROR, {"code": exc.code, "message": str(exc)})
    except asyncio.CancelledError:
        emitter.emit(AgentEvent.ERROR, {"code": "CANCELLED", "message": ui("已取消", "Canceled")})
        raise
    except Exception as exc:  # noqa: BLE001
        logger.exception("agent 一轮出错 job=%s", job_id)
        emitter.emit(AgentEvent.ERROR, {"code": "INTERNAL", "message": str(exc)})
    finally:
        # Pending approvals resolve as denied so the loop doesn't wait for its timeout.
        approvals.abandon(prefix)
        jobs.forget(job_id)
        if release is not None:
            release()
        emitter.close()


def _instrumented(provider_id: str, emitter: Emitter, state: dict, meter: Compactor | None = None):
    """Pass the model stream through to the loop while pushing deltas to the UI.
    Kept out of loop.py: the loop shouldn't know anyone is watching.
    """

    async def stream(request):
        state["step"] += 1
        clock = timing.current()
        if clock is not None:
            clock.begin_step()
        emitter.emit(AgentEvent.MESSAGE_START, {
            "step": state["step"], "provider": provider_id, "model": request.model,
        })
        latest = None
        async for chunk in llm_registry.stream(provider_id, request):
            if isinstance(chunk, TextDelta):
                emitter.emit(AgentEvent.TEXT, {"text": chunk.text})
            elif isinstance(chunk, ThinkingDelta):
                emitter.emit(AgentEvent.THINKING, {"text": chunk.text})
            elif isinstance(chunk, UsageUpdate):
                latest = chunk.usage
                emitter.emit(AgentEvent.USAGE, chunk.usage.as_dict())
            elif isinstance(chunk, Finish) and meter is not None:
                meter.observe(chunk.usage or latest)
            yield chunk

    return stream


def _approver(emitter: Emitter, prefix: str):
    """Approval consumer: emit approval_request, then await the verdict."""

    async def approve(call, context) -> tuple[bool, str]:
        emitter.emit(AgentEvent.APPROVAL_REQUEST, {
            "call_id": call.id, "tool": call.name,
            "summary": summarise_call(call.name, call.arguments),
            "arguments": call.arguments,
            "expires_in": APPROVAL_TIMEOUT,
        })
        return await approvals.request(f"{prefix}{call.id}")

    return approve



@router.post("/projects/{project_id}/agent/chat")
async def project_chat(project_id: str, body: ChatIn, http: Request):
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
    try:
        conversation = projects.ensure_conversation(project_id, body.conversation)
    except ProjectError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    # History is projected from the log, the only reason a conversation survives a restart.
    # Never keep a second copy.
    events = list(projects.events(project_id, conversation=conversation))
    history = list(derive_messages(events))

    # Fix the job id first so the reader's context carries the cancel signal; only reader()
    # builds that context.
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
        # Unconfirmed context must never reach the model; say what to do instead of a 500.
        raise HTTPException(
            status_code=409,
            detail=ui(f"{exc} —— 在项目上右键确认这份正文之后再提问。",
                      f"{exc} — right-click the project and confirm this text, then ask again."),
        ) from exc

    window = await _window(body.provider)
    # One writer per conversation: a concurrent turn or compaction would interleave the log.
    if not occupy(project_id, conversation):
        raise HTTPException(status_code=409, detail=_busy())
    try:
        prefix = f"{job_id}:"
        emitter = Emitter()
        # Measure before each step, compact older turns near the limit, compact and retry on overflow.
        # Summaries use the bare model stream so their text never enters the transcript.
        compactor = Compactor(
            store=projects, project_id=project_id, conversation=conversation,
            provider=body.provider, model=model, system=request.system or "",
            tools=request.tools, paper=request.messages[0],
            stream=lambda call: llm_registry.stream(body.provider, call),
            window=window, in_turn=True,
            turn_start=len(request.messages) - 1, ratio=calibration(events),
            on_context=lambda report: emitter.emit(AgentEvent.CONTEXT, report.as_dict()),
            on_compaction=lambda payload: emitter.emit(AgentEvent.COMPACTION, payload),
            cancelled=lambda: jobs.is_cancelled(job_id),
        )
        journal = StreamingJournal(
            StoreJournal(projects, project_id, conversation), emitter, meter=compactor
        )
        journal.user_message(body.question)

        # No proxy means no network: tools get no credentials and the sandbox stays offline.
        network = getattr(http.app.state, "network", None)
        audit = getattr(http.app.state, "audit", None)

        agent_loop = AgentLoop(
            stream=_instrumented(body.provider, emitter, {"step": 0}, meter=compactor),
            registry=agent.registry,
            context=agent.context,
            journal=journal,
            approve=_approver(emitter, prefix),
            network=network,
            job_id=job_id,
            prepare=compactor.prepare,
            recover=compactor.recover,
            **({"max_steps": body.max_steps} if body.max_steps else {}),
        )

        if clock is not None:
            clock.meta.update(_request_shape(request, body.provider, job_id))
            clock.mark("ready")
        # The timing recorder travels via ContextVar; create_task copies it into the loop.
        with timing.recording(clock):
            task = asyncio.create_task(_run(
                agent_loop, request, emitter, job_id, prefix, audit=audit,
                epilogue=lambda: emitter.emit(AgentEvent.CONTEXT, compactor.idle_report().as_dict()),
                release=lambda: release_conversation(project_id, conversation),
            ))
    except BaseException:
        # The task never started: release the conversation now or it stays busy forever.
        release_conversation(project_id, conversation)
        raise

    async def stream() -> AsyncIterator[str]:
        # Echo the chosen conversation as a field on an existing event, not a new event name.
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
    """Past records of a conversation for the UI, projected by the same code as the model history
    so the two never diverge. Read-only: never creates a conversation.
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


@router.get("/projects/{project_id}/agent/context")
async def project_context(
    project_id: str, provider: str | None = None, conversation: str | None = None
):
    """Idle context report for the next question. Read-only; without `provider` the window is unknown."""
    try:
        project = projects.get(project_id, migrate=False)
        target = conversation or projects.latest_conversation(project_id)
        events = list(projects.events(project_id, conversation=target)) if target else []
    except ProjectError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    agent = reader(project_dir=str(projects.dir_for(project_id)), project_id=project_id)
    try:
        model = llm_registry.get(provider).model if provider else ""
    except LlmError:
        model = ""
    paper = paper_message(project, _paper_text(project_id))
    window = await _window(provider)
    if target is None:
        estimate = estimate_request(CallRequest(
            model=model or "-", messages=(paper,), system=agent.system,
            tools=agent.schemas(), cacheable_prefix=1,
        ))
        return measure(
            estimate, has_summary=False, turn_start=1, ratio=None, window=window,
            threshold=auto_threshold(window), turns=0, covered=0, compactions=0, live=False,
        ).as_dict()
    meter = Compactor(
        store=projects, project_id=project_id, conversation=target,
        provider=provider or "", model=model or "-", system=agent.system,
        tools=agent.schemas(), paper=paper,
        stream=lambda call: llm_registry.stream(provider or "", call),
        window=window, ratio=calibration(events),
    )
    return meter.idle_report().as_dict()


class CompactIn(BaseModel):
    provider: str = Field(min_length=1)
    model: str | None = None
    conversation: str | None = None


@router.post("/projects/{project_id}/agent/compact")
async def project_compact(project_id: str, body: CompactIn):
    """Compact a conversation by hand (projects/compaction.py). Streams like chat: MESSAGE_START,
    COMPACTION and CONTEXT, then DONE (stop="compacted") or ERROR.
    """
    try:
        project = projects.get(project_id)
        target = body.conversation or projects.latest_conversation(project_id)
    except ProjectError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if target is None:
        raise HTTPException(status_code=409, detail=ui("这个项目还没有对话，没有可以压缩的内容。",
                                                       "This project has no conversation to compact yet."))
    markdown = _paper_text(project_id)
    if not markdown.strip():
        raise HTTPException(status_code=409, detail=ui(
            "这个项目还没有正文 —— 先识别原稿，或导入一份 Markdown。",
            "This project has no text yet — run OCR on the original, or import a Markdown file."))
    model = _provider_model(body.provider, body.model)
    window = await _window(body.provider)
    if not occupy(project_id, target):
        raise HTTPException(status_code=409, detail=_busy())

    try:
        job_id = jobs.new_id()
        emitter = Emitter()
        agent = reader(project_dir=str(projects.dir_for(project_id)), project_id=project_id)
        events = list(projects.events(project_id, conversation=target))
        compactor = Compactor(
            store=projects, project_id=project_id, conversation=target,
            provider=body.provider, model=model, system=agent.system,
            tools=agent.schemas(), paper=paper_message(project, markdown),
            stream=lambda call: llm_registry.stream(body.provider, call),
            window=window, ratio=calibration(events),
            on_context=lambda report: emitter.emit(AgentEvent.CONTEXT, report.as_dict()),
            on_compaction=lambda payload: emitter.emit(AgentEvent.COMPACTION, payload),
            cancelled=lambda: jobs.is_cancelled(job_id),
        )

        async def work() -> None:
            try:
                done = await compactor.compact_now()
                emitter.emit(AgentEvent.CONTEXT, compactor.idle_report().as_dict())
                emitter.emit(AgentEvent.DONE, {
                    "stop": "compacted", "steps": 0, "exhausted": False, "text": "",
                    "usage": done.data.get("usage", {}), "calls": [],
                })
            except CompactionError as exc:
                emitter.emit(AgentEvent.ERROR, {"code": exc.code, "message": str(exc)})
            except asyncio.CancelledError:
                emitter.emit(AgentEvent.ERROR, {"code": "CANCELLED", "message": ui("已取消", "Canceled")})
                raise
            except Exception as exc:  # noqa: BLE001
                logger.exception("压缩出错 project=%s", project_id)
                emitter.emit(AgentEvent.ERROR, {"code": "INTERNAL", "message": str(exc)})
            finally:
                release_conversation(project_id, target)
                jobs.forget(job_id)
                emitter.close()

        task = asyncio.create_task(work())
    except BaseException:
        release_conversation(project_id, target)
        raise

    async def stream() -> AsyncIterator[str]:
        yield encode(AgentEvent.MESSAGE_START, {"job_id": job_id, "step": 0,
                                                "provider": body.provider, "model": model,
                                                "conversation": target})
        async for frame in _pump(emitter, task):
            yield frame

    return StreamingResponse(stream(), media_type="text/event-stream", headers=_NO_BUFFER)


@router.post("/projects/{project_id}/agent/cancel")
async def project_cancel(project_id: str, body: CancelIn):
    """Cancel a turn; the scheduler fills in results for undispatched calls so history stays valid."""
    jobs.cancel(body.job_id)
    abandoned = approvals.abandon(f"{body.job_id}:")
    return {"cancelled": body.job_id, "abandoned_approvals": abandoned}


@router.post("/projects/{project_id}/agent/approve")
async def project_approve(project_id: str, body: ApproveIn):
    """Answer an approval. delivered=false means it arrived too late (unknown, answered or timed out)."""
    delivered = approvals.resolve(
        f"{body.job_id}:{body.call_id}", body.approved, body.reason
    )
    return {"delivered": delivered, "approved": body.approved}



class DeskChatIn(BaseModel):
    question: str = Field(min_length=1)
    provider: str = Field(min_length=1)
    model: str | None = None
    max_steps: int | None = None


@router.post("/agent/chat")
async def desk_chat(body: DeskChatIn):
    """Chat with the librarian: list, find, open and delete projects. SSE.

    No project content at this level: no shell or file tools, no paper text, no session log.
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


#: Disable proxy buffering, or events arrive in batches.
_NO_BUFFER = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
