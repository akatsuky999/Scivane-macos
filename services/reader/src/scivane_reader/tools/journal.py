"""把工具调用与结果写进会话日志。

遵守一条纪律：**凡是进入过模型请求的东西都必须能从日志重建**。
对工具而言就是：调用了什么、
参数是什么、返回了什么、用户批准还是拒绝，全部落盘。

科研场景尤其需要这个 —— 一个结论往往来自某次 grep 命中的某一行，
「这是怎么得出来的」必须能回答。

**结果与调用用 call_id 配对，且结果事件记下它对应的调用。** 这样即使中途
取消、日志尾部不完整，也能看出哪次调用没有结果。

安全：参数与结果原样落盘，但**日志里不会出现凭据** —— 工具参数里没有
API key（模型层的凭据走 credentials.py，从不经过工具），这一条有测试钉着。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from ..projects.model import ProjectEvent

__all__ = ["Journal", "NullJournal", "StoreJournal", "ABORTED_BEFORE_DISPATCH"]

#: 取消后给未派发调用补的合成结果所用的稳定码。
ABORTED_BEFORE_DISPATCH = "TOOL_ABORTED_BEFORE_DISPATCH"


class EventSink(Protocol):
    def append_event(
        self, project_id: str, kind: str, data: dict | None = None,
        *, conversation: str | None = None,
    ) -> None: ...


class Journal(Protocol):
    """日志写入口。做成协议是为了让书房层（没有项目）也能用 NullJournal。"""

    def tool_call(self, call_id: str, name: str, arguments: dict) -> None: ...
    def tool_result(self, call_id: str, name: str, content: str, *, is_error: bool,
                    detail: dict | None = None, synthetic: bool = False) -> None: ...
    def tool_decision(self, call_id: str, name: str, approved: bool, reason: str = "") -> None: ...
    def assistant_message(self, text: str, *, stop: str) -> None: ...
    def user_message(self, text: str) -> None: ...


class NullJournal:
    """不落盘。书房层用 —— 它不属于任何项目，没有 session.jsonl 可写。"""

    def tool_call(self, call_id: str, name: str, arguments: dict) -> None: ...
    def tool_result(self, call_id: str, name: str, content: str, *, is_error: bool,
                    detail: dict | None = None, synthetic: bool = False) -> None: ...
    def tool_decision(self, call_id: str, name: str, approved: bool, reason: str = "") -> None: ...
    def assistant_message(self, text: str, *, stop: str) -> None: ...
    def user_message(self, text: str) -> None: ...


@dataclass
class StoreJournal:
    """写进项目里**某一条对话**的日志（沿用既有的 append-only 约定）。

    `conversation` 是必填的：一个项目可以有多条对话，而「这一轮发生的事
    属于哪一次谈话」不是这一层能猜的 —— 路由层装配请求时就已经定下了
    （`store.ensure_conversation`），带着它进来即可。
    """

    store: EventSink
    project_id: str
    conversation: str

    def _append(self, kind: str, data: dict) -> None:
        self.store.append_event(self.project_id, kind, data, conversation=self.conversation)

    def tool_call(self, call_id: str, name: str, arguments: dict) -> None:
        self._append(ProjectEvent.TOOL_CALL, {
            "call_id": call_id, "name": name, "arguments": arguments,
        })

    def tool_result(
        self, call_id: str, name: str, content: str, *, is_error: bool,
        detail: dict | None = None, synthetic: bool = False,
    ) -> None:
        data: dict[str, object] = {
            "call_id": call_id, "name": name, "content": content, "is_error": is_error,
        }
        if detail:
            data["detail"] = detail
        if synthetic:
            # 标出这条不是工具跑出来的，是取消后补的。回放时要能分辨
            # 「工具报错了」和「工具根本没跑」。
            data["synthetic"] = True
        self._append(ProjectEvent.TOOL_RESULT, data)

    def tool_decision(self, call_id: str, name: str, approved: bool, reason: str = "") -> None:
        self._append(ProjectEvent.TOOL_DECISION, {
            "call_id": call_id, "name": name, "approved": approved,
            **({"reason": reason} if reason else {}),
        })

    def assistant_message(self, text: str, *, stop: str) -> None:
        self._append(ProjectEvent.ASSISTANT_MESSAGE, {
            "text": text, "stop": stop,
        })

    def user_message(self, text: str) -> None:
        self._append(ProjectEvent.USER_MESSAGE, {"text": text})
