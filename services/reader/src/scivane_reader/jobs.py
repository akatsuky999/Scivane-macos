"""Registry of running jobs and their cancellation. State is shared between the event loop and
worker threads, hence the lock.

Cancellation is both a flag and an event. Worker threads and per-chunk checks poll the flag; a
coroutine that may wait on something silent (a provider that stopped sending, a running tool)
awaits until_cancelled() so a stop wakes it at once instead of whenever the next chunk arrives.
"""

from __future__ import annotations

import asyncio
import logging
import shutil
import threading
import uuid
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Final, TypeVar

from . import config

T = TypeVar("T")

logger = logging.getLogger("scivane.jobs")


def _wake(waiter: asyncio.Future) -> None:
    if not waiter.done():
        waiter.set_result(None)


#: Returned by interruptible() when the stop came first.
INTERRUPTED: Final = object()


async def interruptible(
    awaitable: Awaitable[T], stop: Callable[[], Awaitable[None]] | None,
) -> T | object:
    """Await `awaitable` unless `stop()` resolves first; then cancel it and return INTERRUPTED.

    Finished work wins a tie, and a stop that was itself cancelled (its job forgotten) is no stop.
    Without `stop` this is a plain await.
    """
    if stop is None:
        return await awaitable
    work = asyncio.ensure_future(awaitable)
    halt = asyncio.ensure_future(stop())
    try:
        await asyncio.wait({work, halt}, return_when=asyncio.FIRST_COMPLETED)
        if not work.done() and halt.done() and not halt.cancelled():
            work.cancel()
            try:
                await work
            except (asyncio.CancelledError, Exception):  # noqa: BLE001 - its outcome no longer matters
                pass
            return INTERRUPTED
        return await work
    finally:
        if not halt.done():
            halt.cancel()
        if not work.done():
            work.cancel()


class JobRegistry:
    def __init__(self, root: Path | None = None) -> None:
        self._root = root or config.JOBS_DIR
        self._cancelled: set[str] = set()
        #: coroutines waiting in until_cancelled, each on its own loop
        self._waiters: dict[str, list[asyncio.Future]] = {}
        self._lock = threading.Lock()

    @property
    def root(self) -> Path:
        return self._root

    def new_id(self) -> str:
        return uuid.uuid4().hex[:12]

    def dir_for(self, job_id: str) -> Path:
        d = self._root / job_id
        d.mkdir(parents=True, exist_ok=True)
        return d

    def cancel(self, job_id: str) -> None:
        with self._lock:
            self._cancelled.add(job_id)
            waiters = self._waiters.pop(job_id, [])
        for waiter in waiters:
            # callable from any thread: each waiter is woken on its own loop
            waiter.get_loop().call_soon_threadsafe(_wake, waiter)

    def is_cancelled(self, job_id: str) -> bool:
        with self._lock:
            return job_id in self._cancelled

    async def until_cancelled(self, job_id: str) -> None:
        """Return once `job_id` is cancelled; at once if it already is."""
        waiter = asyncio.get_running_loop().create_future()
        with self._lock:
            if job_id in self._cancelled:
                return
            self._waiters.setdefault(job_id, []).append(waiter)
        try:
            await waiter
        finally:
            with self._lock:
                pending = self._waiters.get(job_id)
                if pending is not None and waiter in pending:
                    pending.remove(waiter)
                    if not pending:
                        del self._waiters[job_id]

    def forget(self, job_id: str) -> None:
        with self._lock:
            self._cancelled.discard(job_id)
            waiters = self._waiters.pop(job_id, [])
        # whoever still waits on a finished job would wait forever
        for waiter in waiters:
            waiter.get_loop().call_soon_threadsafe(waiter.cancel)

    def drop(self, job_id: str) -> bool:
        self.forget(job_id)
        job_dir = (self._root / job_id).resolve()
        if job_dir == self._root.resolve() or not job_dir.is_relative_to(self._root.resolve()):
            return False
        if job_dir.is_dir():
            shutil.rmtree(job_dir, ignore_errors=True)
            return True
        return False

    def asset_path(self, job_id: str, rel: str) -> Path | None:
        """Resolve an /assets path inside the job directory, rejecting traversal."""
        base = (self._root / job_id).resolve()
        target = (base / rel).resolve()
        if not base.is_relative_to(self._root.resolve()) or not target.is_relative_to(base) or not target.is_file():
            return None
        return target


jobs = JobRegistry()
