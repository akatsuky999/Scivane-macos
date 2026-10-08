"""Per-turn timing: where the time went.

This is the backend half: provider milestones (send, headers, first byte, first reasoning,
first text, end, usage) and when each SSE frame reached the HTTP layer. The app records its
half (AgentTiming.swift). Both use wall-clock time so the events line up.

Off by default (config.TIMING). Numbers only, never content, paths or credentials: Recorder
has no entry point for string content and note() accepts whitelisted keys only.
"""

from __future__ import annotations

import contextlib
import json
import time
from contextvars import ContextVar
from pathlib import Path
from typing import Iterator

__all__ = ["Recorder", "current", "recording", "NOTE_KEYS"]

#: Whitelist, not blacklist: only metadata known to carry no content or credentials.
NOTE_KEYS = frozenset({
    # which upstream the gateway picked
    "upstream",
    # the real model behind an alias such as ~deepseek/...-latest
    "resolved_model",
    # the gateway's generation id; not a credential
    "generation",
})

_current: ContextVar["Recorder | None"] = ContextVar("scivane_timing", default=None)


def current() -> "Recorder | None":
    return _current.get()


@contextlib.contextmanager
def recording(recorder: "Recorder | None") -> Iterator[None]:
    """Enable `recorder` in this block and in tasks created from it."""
    token = _current.set(recorder)
    try:
        yield
    finally:
        _current.reset(token)


class _Step:
    """One model request (a step of the agent loop)."""

    __slots__ = ("marks", "counts", "notes", "usage")

    def __init__(self) -> None:
        self.marks: dict[str, float] = {}
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
    """Timing for one turn. Not thread-safe; used on the event loop only."""

    def __init__(self, **meta: object) -> None:
        self.meta: dict[str, object] = {
            k: v for k, v in meta.items() if isinstance(v, (int, float, str, bool)) or v is None
        }
        self.marks: dict[str, float] = {}
        self.steps: list[_Step] = []
        #: (time, event name, bytes) per SSE frame
        self.frames: list[tuple[float, str, int]] = []

    def mark(self, name: str) -> None:
        self.marks.setdefault(name, time.time())

    def frame(self, event: str, nbytes: int) -> None:
        self.frames.append((time.time(), event, nbytes))

    def begin_step(self) -> None:
        self.steps.append(_Step())

    def _step(self) -> _Step:
        if not self.steps:
            self.begin_step()
        return self.steps[-1]

    def step_mark(self, name: str) -> None:
        self._step().marks.setdefault(name, time.time())

    def step_count(self, name: str, amount: int = 1) -> None:
        step = self._step()
        step.counts[name] = step.counts.get(name, 0) + amount

    def delta(self, kind: str, chars: int) -> None:
        """Counts only, never the text."""
        now = time.time()
        step = self._step()
        step.marks.setdefault(f"first_{kind}", now)
        step.counts[f"last_{kind}"] = now
        step.counts[f"{kind}_chunks"] = step.counts.get(f"{kind}_chunks", 0) + 1
        step.counts[f"{kind}_chars"] = step.counts.get(f"{kind}_chars", 0) + chars

    def note(self, key: str, value: object) -> None:
        """Whitelisted keys only; values are truncated to 80 characters."""
        if key in NOTE_KEYS and isinstance(value, str) and value:
            self._step().notes.setdefault(key, value[:80])

    def usage(self, numbers: dict[str, object]) -> None:
        """Integers (token counts) only."""
        step = self._step()
        for key, value in numbers.items():
            if isinstance(value, int) and not isinstance(value, bool):
                step.usage[key] = value

    def as_dict(self) -> dict[str, object]:
        return {
            "kind": "agent-turn",
            **self.meta,
            **self.marks,
            "steps": [step.as_dict() for step in self.steps],
            # compact triples: a turn has thousands of frames
            "frames": [[round(t, 4), event, size] for t, event, size in self.frames],
        }

    def write(self, path: Path) -> None:
        """Append one JSONL line; failures are ignored so timing can never fail a turn."""
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(self.as_dict(), ensure_ascii=False) + "\n")
        except OSError:
            pass
