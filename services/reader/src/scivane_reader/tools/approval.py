"""Approval channel: the user decides in the UI whether a tool call may run.

Today only the librarian's delete_project uses it (irreversible). The reader has no tools
needing approval: commands inside the sandbox shouldn't be confirmed one by one, which only
trains people to click yes. The wiring stays so a future tool that leaves the sandbox gets
asked rather than waved through.

A timeout counts as a refusal: nobody watching must never mean an unseen irreversible action.
Each key can be answered once; repeats are ignored. The channel knows nothing about tools,
only a key, a verdict and a reason.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

__all__ = ["ApprovalBroker", "APPROVAL_TIMEOUT", "TIMED_OUT_REASON"]

#: enough time to see which project is about to go, short enough not to hang a turn indefinitely
APPROVAL_TIMEOUT = 120.0

TIMED_OUT_REASON = "等待超时，按拒绝处理"


@dataclass
class ApprovalBroker:
    """One-shot approvals keyed by f"{job_id}:{call_id}": call ids come from the model and can
    collide across jobs.
    """

    timeout: float = APPROVAL_TIMEOUT
    _waiting: dict[str, asyncio.Future[tuple[bool, str]]] = field(default_factory=dict)

    async def request(self, key: str) -> tuple[bool, str]:
        """Wait for a verdict; a timeout counts as a refusal. Returns (approved, reason)."""
        loop = asyncio.get_running_loop()
        future: asyncio.Future[tuple[bool, str]] = loop.create_future()
        self._waiting[key] = future
        try:
            return await asyncio.wait_for(future, timeout=self.timeout)
        except asyncio.TimeoutError:
            return False, TIMED_OUT_REASON
        finally:
            self._waiting.pop(key, None)

    def resolve(self, key: str, approved: bool, reason: str = "") -> bool:
        """Answer a pending request. Returns False when there is no such request, it was already
        answered, or it timed out, so the client knows it was too late.
        """
        future = self._waiting.get(key)
        if future is None or future.done():
            return False
        future.set_result((approved, reason))
        return True

    def abandon(self, prefix: str) -> int:
        """Resolve every pending request of a finished or cancelled job as refused, or the loop would
        wait for the timeout.
        """
        count = 0
        for key in [k for k in self._waiting if k.startswith(prefix)]:
            future = self._waiting.get(key)
            if future is not None and not future.done():
                future.set_result((False, "这一轮已经结束"))
                count += 1
        return count


approvals = ApprovalBroker()
