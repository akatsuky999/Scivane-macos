"""一轮请求的分段计时：时间花在了哪一段。

**为什么要有它。** 「对话慢」可能慢在模型本身、请求的形状、后端转发、客户端解析或界面显示，
只看总时长分不出来。这里只管后端这一半：厂商那一段（发出、响应头、
第一个字节、第一段推理、第一段正文、结束、用量）与每个 SSE 帧交给 HTTP 层的时刻。客户端那一半
由 App 自己记（`AgentTiming.swift`）。**两边都用墙上时钟**，同一台机器上可以逐事件直接对齐。

**默认关**（`config.TIMING`）。开着时 agent 路由为每一轮建一个 `Recorder`，经 ContextVar 交给
这一轮里跑的所有代码 —— llm 层只打点，不知道谁在听，也不知道「项目」是什么（分层不倒置）。
关着时 `current()` 是 None，每个打点处只多一次 ContextVar 读取。

**只记时刻、字节数、分片数与 token 数，绝不记内容、路径与凭据**（红线）。字段表是封闭的：
`Recorder` 没有任何接受字符串内容的入口，`note()` 只收白名单里的键。
"""

from __future__ import annotations

import contextlib
import json
import time
from contextvars import ContextVar
from pathlib import Path
from typing import Iterator

__all__ = ["Recorder", "current", "recording", "NOTE_KEYS"]

#: `note()` 允许的键。**白名单而不是黑名单** —— 厂商的响应里什么都可能有，
#: 只有明确知道不含内容与凭据的元数据才许进来。
NOTE_KEYS = frozenset({
    # 网关实际把请求交给了哪一家（OpenRouter 在每个分片里都带着）
    "upstream",
    # 别名解析之后的真实模型名（`~deepseek/…-latest` 这类别名会被解析）
    "resolved_model",
    # 网关给这次生成的编号（OpenRouter 的 `gen-…`）。不是凭据：拿它查网关自己记的
    # 首 token 时间与生成时长，要另带 key。
    "generation",
})

_current: ContextVar["Recorder | None"] = ContextVar("scivane_timing", default=None)


def current() -> "Recorder | None":
    """这一轮的计时器；没开计时时是 None。"""
    return _current.get()


@contextlib.contextmanager
def recording(recorder: "Recorder | None") -> Iterator[None]:
    """在这段代码（以及从这里 `create_task` 出去的任务）里启用 `recorder`。"""
    token = _current.set(recorder)
    try:
        yield
    finally:
        _current.reset(token)


class _Step:
    """一次模型请求（agent 循环里的一步）。"""

    __slots__ = ("marks", "counts", "notes", "usage")

    def __init__(self) -> None:
        #: 名字 → 第一次发生的时刻。
        self.marks: dict[str, float] = {}
        #: 推理 / 正文各自的分片数与字数，以及最后一片的时刻。
        self.counts: dict[str, float] = {}
        self.notes: dict[str, str] = {}
        self.usage: dict[str, int] = {}

    def as_dict(self) -> dict[str, object]:
        out: dict[str, object] = dict(self.marks)
        out.update(self.counts)
        if self.notes:
            out["notes"] = dict(self.notes)
        if self.usage:
            out["usage"] = dict(self.usage)
        return out


class Recorder:
    """一轮（一次提问）的计时。**不是线程安全的** —— 只在事件循环线程上用。"""

    def __init__(self, **meta: object) -> None:
        self.meta: dict[str, object] = {
            k: v for k, v in meta.items() if isinstance(v, (int, float, str, bool)) or v is None
        }
        self.marks: dict[str, float] = {}
        self.steps: list[_Step] = []
        #: 每个 SSE 帧交给 HTTP 层的时刻、事件名、字节数。
        self.frames: list[tuple[float, str, int]] = []

    # --- 整轮 -----------------------------------------------------------

    def mark(self, name: str) -> None:
        """整轮层面的一个时刻（第一次为准）。"""
        self.marks.setdefault(name, time.time())

    def frame(self, event: str, nbytes: int) -> None:
        self.frames.append((time.time(), event, nbytes))

    # --- 一步 -----------------------------------------------------------

    def begin_step(self) -> None:
        self.steps.append(_Step())

    def _step(self) -> _Step:
        if not self.steps:
            self.begin_step()
        return self.steps[-1]

    def step_mark(self, name: str) -> None:
        """这一步里的一个时刻（第一次为准）：send / headers / first_byte / end …"""
        self._step().marks.setdefault(name, time.time())

    def step_count(self, name: str, amount: int = 1) -> None:
        step = self._step()
        step.counts[name] = step.counts.get(name, 0) + amount

    def delta(self, kind: str, chars: int) -> None:
        """一片推理（`thinking`）或正文（`text`）。只收字数，不收内容。"""
        now = time.time()
        step = self._step()
        step.marks.setdefault(f"first_{kind}", now)
        step.counts[f"last_{kind}"] = now
        step.counts[f"{kind}_chunks"] = step.counts.get(f"{kind}_chunks", 0) + 1
        step.counts[f"{kind}_chars"] = step.counts.get(f"{kind}_chars", 0) + chars

    def note(self, key: str, value: object) -> None:
        """一条元数据。**只收白名单里的键**，值截到 80 字符。"""
        if key in NOTE_KEYS and isinstance(value, str) and value:
            self._step().notes.setdefault(key, value[:80])

    def usage(self, numbers: dict[str, object]) -> None:
        """用量。只留整数（token 数），别的一概不收。"""
        step = self._step()
        for key, value in numbers.items():
            if isinstance(value, int) and not isinstance(value, bool):
                step.usage[key] = value

    # --- 落盘 -----------------------------------------------------------

    def as_dict(self) -> dict[str, object]:
        return {
            "kind": "agent-turn",
            **self.meta,
            **self.marks,
            "steps": [step.as_dict() for step in self.steps],
            # 帧用紧凑的三元组：一轮几千帧，逐帧写成对象会大一个数量级
            "frames": [[round(t, 4), event, size] for t, event, size in self.frames],
        }

    def write(self, path: Path) -> None:
        """追加一行到 `path`（JSONL）。写不了就算了 —— 计时不该让一轮对话失败。"""
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(self.as_dict(), ensure_ascii=False) + "\n")
        except OSError:
            pass
