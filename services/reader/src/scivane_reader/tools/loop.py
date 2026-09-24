"""agent 循环：模型说话 → 调工具 → 拿结果 → 接着想。

**这是从「问答」到「干活」的分水岭**，也是前两段产物的收口：路径边界
（段一）与沙箱（段二）到这里才第一次有消费者。

一轮的形状：

    组装请求（带工具 schema）→ 流式收
      → **每收到一个调用就立刻派给调度器**（不等这一段生成吐完）
      → 流收完，按模型序把结果收齐（只读并发、其余排他、取消补齐）
      → 把「助手这一轮说的话 + 调用」和「工具结果」两条消息接进历史
      → 再来一轮，直到模型不再要工具

**为什么是流中派发。** 实机日志里一步生成 2–5 秒、最长一步 78 秒，
而本地工具全是毫秒级；等生成吐完再跑工具，那段时间就是白等。
模型发出工具调用后就可以启动执行，流继续往下收 —— 不必等整段生成结束。

三条纪律：

**每一步都落日志。** 助手说了什么、调了什么、结果是什么，全部进
`.lumen/session.jsonl`。这不是为了调试，是因为科研场景要能回答
「这个结论是怎么得出来的」。

**步数有上限。** 模型会陷进「grep 没结果 → 换个词再 grep」的循环里。
撞到上限就停下并如实说明，而不是无声地烧钱。

**取消之后历史必须仍然合法。** 交给调度器保证 —— 它给未派发的调用补
合成结果，所以 `dispatch` 返回的结果数恒等于调用数。这一层只要不自己
丢结果就行。
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

from ..llm.types import (
    LlmFailure,
    CallRequest,
    Finish,
    Message,
    TextBlock,
    TextDelta,
    ToolCall,
    ToolResultBlock,
    ToolUseBlock,
    Usage,
)
from ..llm.errors import TRANSPORT
from .definition import ToolContext
from .journal import Journal, NullJournal
from .registry import ToolRegistry
from .scheduler import Dispatcher

__all__ = ["AgentLoop", "LoopResult", "MAX_STEPS"]


async def _abandon(started: list[object]) -> None:
    """收掉这一轮里已经起跑、但不会再有人要结果的工具。

    不收的话它们会变成孤儿任务：事件循环照样把它们跑完，于是「已经取消」
    的那一轮还在往项目里写文件，而界面上什么都看不到。
    """
    for task in started:
        if task is not None and not task.done():  # type: ignore[union-attr]
            task.cancel()  # type: ignore[union-attr]
    for task in started:
        if task is None:
            continue
        try:
            await task  # type: ignore[misc]
        except (asyncio.CancelledError, Exception):  # noqa: BLE001
            pass

#: 防跑飞的兜底轮数。**不是工作上限。**
#:
#: 原先是 12，理由写的是「一次跑飞最多烧十几次请求」。实机打脸了：
#: 「把开源代码拉下来逐个公式核对」这种活儿本来就要二三十轮，12 轮撞上限
#: 之后用户拿不到结论，而那根本不是跑飞。
#:
#: 道理是：**交互时用户看着屏幕，随时能按停** —— 人就是那道护栏，
#: 再加一道过低的硬上限只会砍断正常的长任务。所以这里取 200：撞到它说明是真的在转圈，
#: 而不是活儿长。
#:
#: 能这么放开还有个前提，是这一轮才补上的：模型侧的失败现在会如实冒到界面
#: （见 `api/agent_routes._run`）。放开之前，撞上下文窗口只会表现为静默，
#: 那才是真正危险的 —— 现在它会显示「超出上下文窗口」并说清该怎么办。
MAX_STEPS = 200


@dataclass
class LoopResult:
    """一次提问跑完之后的产物。"""

    text: str
    steps: int
    stop: str
    usage: Usage = field(default_factory=Usage)
    #: 每一步调了哪些工具，按顺序。给界面与日志用。
    calls: tuple[ToolCall, ...] = ()
    #: 撞到步数上限而停。**不是错误，但必须让用户知道**。
    exhausted: bool = False
    #: `stop == "error"` 时这一轮为什么失败。
    #:
    #: **不带上它，上层就只剩一个 "error" 字符串可看** —— 路由无从判断该发
    #: `done` 还是 `error`，界面也就没有任何东西可显示，表现是
    #: 「发了消息完全没反应」。key 过期（AUTH 401）实测就是这样静默掉的。
    #: `LlmError` 的文档里写着「跨层传递时不要丢掉 failure」，这里是兑现它。
    failure: LlmFailure | None = None


@dataclass
class AgentLoop:
    """把模型、工具、日志接成一个循环。

    `stream` 是「给一个 CallRequest，异步吐 StreamChunk」的可调用对象 ——
    做成参数而不是直接依赖 `LlmRegistry`，是为了让测试能用 MockTransport
    甚至纯脚本替身跑完整循环，不必起真实模型。
    """

    stream: object
    registry: ToolRegistry
    context: ToolContext
    journal: Journal = field(default_factory=NullJournal)
    approve: object = None
    max_steps: int = MAX_STEPS
    #: 联网能力（`netproxy.NetworkAccess`）。`None` = 这个后端无网。
    network: object = None
    #: 这一轮的 job id，审计按 `(job_id, call_id)` 归因。
    job_id: str = ""

    async def run(self, request: CallRequest) -> LoopResult:
        """跑到模型不再要工具为止。

        `request` 里的 tools 由调用方装配（`registry.schemas()`），
        这一层不替它决定给模型看哪些工具 —— 两层 agent 的差异正是在那里体现的。
        """
        dispatcher = Dispatcher(
            registry=self.registry, journal=self.journal,
            context=self.context, approve=self.approve,
            network=self.network, job_id=self.job_id,
        )
        messages = list(request.messages)
        usage = Usage()
        every_call: list[ToolCall] = []
        last_text = ""

        for step in range(1, self.max_steps + 1):
            text_parts: list[str] = []
            calls: list[ToolCall] = []
            finish: Finish | None = None

            turn = CallRequest(
                model=request.model,
                messages=tuple(messages),
                system=request.system,
                max_tokens=request.max_tokens,
                temperature=request.temperature,
                cacheable_prefix=request.cacheable_prefix,
                tools=request.tools,
                purpose=request.purpose,
                extra=request.extra,
            )
            aborted_mid_stream = False
            #: 已经在跑的工具，与 `calls` 一一对应（None = 没派发成）。
            started: list[object] = []
            async for chunk in self.stream(turn):  # type: ignore[operator]
                # **取消要在流里就生效。** 早先只在一步跑完之后才看这个标志，
                # 而一步里最长的一段恰恰是模型生成 —— 实机上那是七八十秒。
                # 用户按了「停」，界面却要等这一整段吐完、工具还照跑一遍，
                # 观感就是「停止按钮没用」。
                if self.context.cancelled():
                    aborted_mid_stream = True
                    break
                if isinstance(chunk, TextDelta):
                    text_parts.append(chunk.text)
                elif isinstance(chunk, ToolCall):
                    calls.append(chunk)
                    # **立刻开跑，不等这一段生成吐完。**
                    #
                    # 模型在发出调用之后往往还要再说几百个 token（实机日志里
                    # 一步生成 2–5 秒，最长的一步 78 秒），那段时间工具本来
                    # 可以已经在跑了。先启动工具，流继续往下收，收完再统一 drain。
                    #
                    # 并发规则交给 `Gate`（只读共享 / 其余排他 / 先到先得），
                    # 所以不需要先看齐整轮再切批。
                    started.append(dispatcher.start(chunk))
                elif isinstance(chunk, Finish):
                    finish = chunk
                    if chunk.usage is not None:
                        usage = usage.merged(chunk.usage)

            if aborted_mid_stream:
                # 半截的 tool_use 一律丢掉：没有结果的调用会让下一次请求非法，
                # 而这一轮已经不会再有下一次了。说清是「停下」而不是「出错」。
                # 已经在跑的要收干净 —— 留下孤儿任务会在事件循环里继续写文件。
                await _abandon(started)
                return LoopResult(
                    text="".join(text_parts) or last_text, steps=step, stop="aborted",
                    usage=usage, calls=tuple(every_call),
                )

            said = "".join(text_parts)
            # 流意外结束时，不能把半截响应当成正常 stop。否则路由会发 done，
            # 前端看见工具结果后就静默收尾，用户只会觉得 agent 拒绝工作。
            if finish is None:
                await _abandon(started)
                return LoopResult(
                    text=said or last_text, steps=step, stop="error",
                    usage=usage, calls=tuple(every_call + calls),
                    failure=LlmFailure("模型连接在给出终态前结束了", TRANSPORT),
                )
            if said:
                last_text = said
            stop = finish.kind if finish is not None else "stop"
            self.journal.assistant_message(said, stop=stop)

            if stop != "tool_use" or not calls:
                # 收到了调用却不是 tool_use 终态 —— 不该发生，但真发生时
                # 那些已经起跑的工具没人会去收结果，必须收干净。
                await _abandon(started)
                return LoopResult(
                    text=said or last_text, steps=step, stop=stop,
                    usage=usage, calls=tuple(every_call),
                    failure=finish.failure if finish is not None else None,
                )

            every_call.extend(calls)
            # 助手这一轮的话与调用放同一条消息 —— 三家协议都要求 tool_result
            # 紧跟在带 tool_use 的那条助手消息之后，拆开会被拒。
            assistant_blocks: list[object] = []
            if said:
                assistant_blocks.append(TextBlock(said))
            assistant_blocks.extend(
                ToolUseBlock(c.id, c.name, c.arguments) for c in calls
            )
            messages.append(Message("assistant", tuple(assistant_blocks)))  # type: ignore[arg-type]

            # 流中已经起跑了，这里只是按模型序把结果收齐。
            results = await dispatcher.settle(tuple(calls), started)  # type: ignore[arg-type]
            # 调度器保证结果数 == 调用数（取消时用合成结果补齐）。
            # 这条一旦破了，下一次请求就是非法的，所以在这里再确认一次。
            assert len(results) == len(calls), "工具结果数与调用数不一致 —— 历史会变非法"
            messages.append(Message("user", tuple(results)))

            if self.context.cancelled():
                return LoopResult(
                    text=said or last_text, steps=step, stop="aborted",
                    usage=usage, calls=tuple(every_call),
                )

        return LoopResult(
            text=last_text, steps=self.max_steps, stop="max_steps",
            usage=usage, calls=tuple(every_call), exhausted=True,
        )
