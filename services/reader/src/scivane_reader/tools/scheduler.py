"""工具调用的调度：并发切批、屏障、取消补齐。

两条设计保证工具调度在并发、取消和模型顺序之间保持一致：

**只读工具可并发，其余串行成屏障。** 连续的只读调用聚成一批并行跑；
任何会写的调用自己成一批，前后都不与别的重叠。判定一律 **fail-closed**：
工具不认识、参数解析不了、`concurrency_safe` 没声明 —— 都当不安全。
切批是一个 reduce：连续安全的调用合并，否则新开一批；判断出错时也退回 false。

**取消之后要给未派发的调用补一对合成的 call 与错误结果。** 这是最容易漏、
漏了一定会踩的坑：模型发了 5 个调用，只跑了 2 个就被中断，历史里缺 3 个结果，
**下一次请求就是非法的** —— 三家协议都要求每个 tool_use 有对应的 tool_result。
用户看到的表现是「取消一次之后这个会话再也发不出去了」，而且重启 App 也不好，
因为非法历史已经落盘了。

补齐的纪律：已启动的调用**先**按模型序结算真实结果，
剩下的再依次拿到合成结果。合成结果在日志里带 `synthetic` 标记 ——
回放时要能分辨「工具报错了」和「工具根本没跑」。

还有一条区分：**取消**要补合成结果，而**调度器自身出错**不补 ——
后者说明我们的代码有 bug，伪造结果只会把 bug 埋进历史。
"""

from __future__ import annotations

import asyncio
import contextlib
from collections import deque
from dataclasses import dataclass, field, replace

from .. import i18n
from ..llm.types import ToolCall, ToolResultBlock
from .definition import ToolContext, ToolError, ToolOutcome
from .journal import ABORTED_BEFORE_DISPATCH, Journal
from .registry import ToolRegistry
from .results import apply_limit

__all__ = [
    "Batch", "partition", "Dispatcher", "ApprovalDenied", "DENIED_BY_USER", "Gate",
]

DENIED_BY_USER = "TOOL_DENIED_BY_USER"


class ApprovalDenied(Exception):
    """用户拒绝了这次调用。"""


class Gate:
    """并发门：只读工具共享，其余排他，**先到先得**。

    这是一个读写门：声明支持并发的取读锁（可以一起跑），
    其余取写锁（独占）。

    **为什么换掉原来的「切批」。** 切批要先看齐一整轮的全部调用才能分组，
    于是工具只能等流收完再跑。改成一道门之后，调用一从流里出来就能去抢门，
    并发规则由门本身保证 —— 这正是「流中派发」得以成立的前提。

    **必须先到先得。** 模型常常排成「先 grep 定位，再 read 那个文件」，
    顺序一乱后一个就拿不到前一个的效果。所以等待者排队，不是谁醒得早谁赢：
    写者在队头时，后来的读者也得等着，不能插队把它饿死。
    """

    def __init__(self) -> None:
        self._readers = 0
        self._writer = False
        self._queue: deque[tuple[bool, asyncio.Future]] = deque()

    def _free(self, exclusive: bool) -> bool:
        if exclusive:
            return self._readers == 0 and not self._writer
        return not self._writer

    def _take(self, exclusive: bool) -> None:
        if exclusive:
            self._writer = True
        else:
            self._readers += 1

    def _wake(self) -> None:
        while self._queue:
            exclusive, waiter = self._queue[0]
            if not self._free(exclusive):
                return
            self._queue.popleft()
            self._take(exclusive)
            if not waiter.done():
                waiter.set_result(None)
            if exclusive:
                # 写者独占：后面的都得等它 release
                return

    async def acquire(self, *, exclusive: bool) -> None:
        if not self._queue and self._free(exclusive):
            self._take(exclusive)
            return
        waiter = asyncio.get_running_loop().create_future()
        self._queue.append((exclusive, waiter))
        try:
            await waiter
        except asyncio.CancelledError:
            # 被取消的等待者要从队里摘掉，否则它会把后面的人堵死
            try:
                self._queue.remove((exclusive, waiter))
            except ValueError:
                # 已经被 _wake 放行了 —— 那就得把拿到的那份还回去
                self.release(exclusive=exclusive)
            raise

    def release(self, *, exclusive: bool) -> None:
        if exclusive:
            self._writer = False
        else:
            self._readers = max(0, self._readers - 1)
        self._wake()


@dataclass(frozen=True)
class Batch:
    """一批一起跑的调用。`concurrency_safe=False` 的批恒为单元素（屏障）。"""

    concurrency_safe: bool
    calls: tuple[ToolCall, ...]


def partition(calls: tuple[ToolCall, ...], registry: ToolRegistry) -> tuple[Batch, ...]:
    """按并发安全性切批，**保持模型给出的顺序**。

    顺序不能动：模型常常是「先 grep 定位，再 read 那个文件」这样排的，
    重排会让后一个拿不到前一个的效果。
    """
    batches: list[Batch] = []
    for call in calls:
        safe = _is_safe(call, registry)
        if safe and batches and batches[-1].concurrency_safe:
            batches[-1] = Batch(True, batches[-1].calls + (call,))
        else:
            batches.append(Batch(safe, (call,)))
    return tuple(batches)


def _is_safe(call: ToolCall, registry: ToolRegistry) -> bool:
    """fail-closed：任何不确定都算不安全。"""
    try:
        tool = registry.find(call.name)
    except ToolError:
        return False
    return bool(tool.concurrency_safe and tool.read_only)


@dataclass
class Dispatcher:
    """跑完一轮里的全部工具调用，返回按模型序排好的结果。"""

    registry: ToolRegistry
    journal: Journal
    context: ToolContext
    #: 需要批准的工具走它。返回 False 即拒绝。None 表示一律拒绝 ——
    #: fail-closed：没有提供批准通道，就不该有工具偷偷跑起来。
    approve: object = None
    #: 并发门。一个 Dispatcher 一把，所以同一轮里的调用共用一套并发规则。
    gate: Gate = field(default_factory=Gate)
    #: 联网能力。`None` = 这个后端没有代理，一切工具都无网。
    network: object = None
    #: 归因用：这一轮对话的 job id。审计簿按 `(job_id, call_id)` 记账。
    job_id: str = ""

    # --- 流中派发 --------------------------------------------------------

    def start(self, call: ToolCall) -> asyncio.Task | None:
        """**立刻开跑这一次调用**，不等这一轮的流收完。

        收到工具调用就把 `tool_future` 推进 `in_flight`，流继续往下收。原先要等整段生成
        吐完才派发，而模型常常在调用之后还要再说几百个 token ——
        那段时间工具本可以已经在跑了。

        并发规则由 `Gate` 保证，不再靠事先切批：只读工具取共享、其余取排他，
        先到先得。返回 None 表示**没有派发**（已被取消），
        由 `settle()` 给它补合成结果。
        """
        if self.context.cancelled():
            return None
        return asyncio.ensure_future(self._guarded(call))

    async def settle(
        self, calls: tuple[ToolCall, ...], started: list[asyncio.Task | None]
    ) -> tuple[ToolResultBlock, ...]:
        """按**模型序**收齐结果。长度恒等于 `calls`。

        没派发的（取消时 `start` 返回 None）在这里补合成结果 —— 这条是
        历史合法性的全部依赖：每个 tool_use 都必须有对应的 tool_result。
        """
        results: list[ToolResultBlock] = []
        for call, task in zip(calls, started):
            if task is None:
                results.append(self._synthesise(call))
                continue
            try:
                results.append(await task)
            except asyncio.CancelledError:
                # 跑到一半被取消：它仍然需要一个结果，否则历史非法。
                # 标 synthetic —— 回放时要分得清「报错了」和「没跑完」。
                results.append(self._synthesise(call))
        return tuple(results)

    async def _guarded(self, call: ToolCall) -> ToolResultBlock:
        """过并发门，再跑。"""
        exclusive = not _is_safe(call, self.registry)
        await self.gate.acquire(exclusive=exclusive)
        try:
            return await self._one(call)
        finally:
            self.gate.release(exclusive=exclusive)

    async def run(self, calls: tuple[ToolCall, ...]) -> tuple[ToolResultBlock, ...]:
        """一次把一整轮的调用跑完。

        **流中派发之后这条只剩两个用处**：书房那层（它不走流式派发）
        与单测。实现改成「全部 start 再 settle」，这样两条路共用同一套
        并发与补齐规则 —— 写两份必然漂移。
        """
        started = [self.start(call) for call in calls]
        return await self.settle(calls, started)

    # --- 单次调用 --------------------------------------------------------

    async def _one(self, call: ToolCall) -> ToolResultBlock:
        self.journal.tool_call(call.id, call.name, call.arguments)
        try:
            tool = self.registry.find(call.name)
        except ToolError as exc:
            return self._fail(call, str(exc), exc.code)

        if tool.approval_required(call.arguments):
            approved, reason = await self._ask(call, tool.name)
            self.journal.tool_decision(call.id, call.name, approved, reason)
            if not approved:
                # 被拒绝**也要有结果** —— 否则历史同样非法。
                return self._fail(
                    call, f"用户拒绝了这次调用{('：' + reason) if reason else ''}", DENIED_BY_USER
                )

        try:
            # **凭据在这里签，出了这个 with 就作废。**
            #
            # 为什么签在派发这一层而不是工具里：一是工具拿不到 call_id，
            # 归因就无从谈起；二是 `finally` 在这里才兜得住全部出口 ——
            # 工具抛异常、被取消、超时，凭据都不会留在册子上。
            # 每次调用都单独携带可变的那部分
            # 挂在「这一次调用」上，不挂在工具定义上。
            #
            # **工具体里界面语言钉成中文**（`i18n.py`）：工具结果是给模型看的，
            # 不跟着界面设置换语言 —— 否则同一段历史在两种界面里是两份前缀，
            # 模型的行为也跟着一个界面开关漂。工具摘要、批准卡在这段之外算，照常按界面语言说。
            with self._grant(call.id) as leased, i18n.speaking("zh"):
                context = replace(self.context, network=leased) if leased else self.context
                outcome = await tool.run(call.arguments, context)
        except ToolError as exc:
            return self._fail(call, str(exc), exc.code)
        except asyncio.CancelledError:
            # 取消原样上抛：此时已经没有人在听了，补结果没有意义。
            raise
        except Exception as exc:  # noqa: BLE001
            # 工具里的意外异常不该炸掉整轮对话。作为错误结果交回模型，
            # 它通常会换个参数重试；而整轮炸掉用户只能重新开始。
            return self._fail(call, f"工具执行出错：{exc}", "TOOL_CRASHED")

        limited = apply_limit(outcome, tool, self.context.project_dir)
        self.journal.tool_result(
            call.id, call.name, limited.content,
            is_error=limited.is_error, detail=limited.detail,
        )
        return ToolResultBlock(call.id, limited.content, is_error=limited.is_error)

    @contextlib.contextmanager
    def _grant(self, call_id: str):
        """这一次调用的联网凭据。没有代理就一路给 None（fail closed 到无网）。"""
        if self.network is None:
            yield None
            return
        with self.network.for_call(self.job_id, call_id) as leased:  # type: ignore[attr-defined]
            yield leased

    async def _ask(self, call: ToolCall, name: str) -> tuple[bool, str]:
        if self.approve is None:
            return False, "没有可用的批准通道"
        verdict = self.approve(call, self.context)  # type: ignore[operator]
        if asyncio.iscoroutine(verdict):
            verdict = await verdict
        if isinstance(verdict, tuple):
            return bool(verdict[0]), str(verdict[1])
        return bool(verdict), ""

    def _fail(self, call: ToolCall, message: str, code: str) -> ToolResultBlock:
        text = f"错误（{code}）：{message}"
        self.journal.tool_result(
            call.id, call.name, text, is_error=True, detail={"code": code}
        )
        return ToolResultBlock(call.id, text, is_error=True)

    def _synthesise(self, call: ToolCall) -> ToolResultBlock:
        """给取消时没来得及派发的调用补一对 call + 错误结果。"""
        text = "错误（取消）：这次调用在派发之前就被取消了"
        self.journal.tool_call(call.id, call.name, call.arguments)
        self.journal.tool_result(
            call.id, call.name, text, is_error=True,
            detail={"code": ABORTED_BEFORE_DISPATCH}, synthetic=True,
        )
        return ToolResultBlock(call.id, text, is_error=True)
