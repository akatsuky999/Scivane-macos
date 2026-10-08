"""Audit records: which hosts the agent reached.

Recorded: host, port, method, byte counts, the tool call, allowed or refused. Never paths or
query strings: query strings are where tokens hide, and a log containing them is a copy of
credentials. NetworkRecord has no field for a path at all, and a test checks that.
"""

from __future__ import annotations

import contextlib
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass, field, replace

__all__ = ["NetworkRecord", "AuditLog", "Entry"]


@dataclass(frozen=True)
class NetworkRecord:
    """One proxied connection. The field list is the promise: never add path-like fields."""

    #: The tool call that made it. The token both authenticates and attributes, so "the agent just
    #: reached X" is a fact, not a guess.
    job_id: str
    call_id: str
    #: CONNECT only reveals host and port; plain HTTP is reduced to the same
    host: str
    port: int
    #: "CONNECT" for tunnels; no MITM, so the inner method is unknown
    method: str
    allowed: bool
    #: stable refusal code; empty when allowed
    reason: str = ""
    #: byte counts: without MITM, the only fact about how much was transferred
    bytes_up: int = 0
    bytes_down: int = 0
    started_at: float = field(default_factory=time.time)
    elapsed: float = 0.0

    def as_dict(self) -> dict[str, object]:
        return asdict(self)

    @property
    def target(self) -> str:
        """One line for the UI: host and port only."""
        return f"{self.host}:{self.port}"


@dataclass
class Entry:
    """Handle to a recorded entry, used to add byte counts when the connection closes."""

    log: "AuditLog"
    record: NetworkRecord
    #: first host this tool call reached; the prominent UI card appears only once
    first: bool


class AuditLog:
    """In-memory audit log, bounded (oldest entries drop).

    Deliberately not persisted: it answers which hosts the agent reaches during a session.
    """

    def __init__(self, limit: int = 2000) -> None:
        self._records: list[NetworkRecord] = []
        self._limit = limit
        #: Per-job watchers, one per turn. Records land when a connection opens, so the UI hears about a
        #: five-minute clone immediately.
        self._watchers: dict[str, list[Callable[[Entry], None]]] = {}
        #: first host per tool call, for the one-time UI card
        self._first_host: dict[str, str] = {}

    def add(self, record: NetworkRecord) -> Entry:
        """Record a connection when it opens, not when it ends; settle() adds the byte counts later."""
        self._records.append(record)
        if len(self._records) > self._limit:
            del self._records[: len(self._records) - self._limit]
        key = f"{record.job_id}/{record.call_id}"
        first = key not in self._first_host
        if first:
            self._first_host[key] = record.host
        entry = Entry(log=self, record=record, first=first)
        for watcher in tuple(self._watchers.get(record.job_id, ())):
            # A failing watcher must never break the bookkeeping.
            try:
                watcher(entry)
            except Exception:  # noqa: BLE001
                pass
        return entry

    def settle(self, entry: Entry, *, bytes_up: int, bytes_down: int,
               elapsed: float) -> None:
        """Add byte counts when the connection ends. Records are frozen, so a new one replaces the old;
        an entry that was already evicted stays gone.
        """
        try:
            index = self._records.index(entry.record)
        except ValueError:
            return
        self._records[index] = replace(
            entry.record, bytes_up=bytes_up, bytes_down=bytes_down, elapsed=elapsed
        )

    @contextlib.contextmanager
    def watching(self, job_id: str, callback: "Callable[[Entry], None]"):
        """Watch this job's records for the duration of a turn; unsubscribe in `finally`."""
        self._watchers.setdefault(job_id, []).append(callback)
        try:
            yield
        finally:
            watchers = self._watchers.get(job_id, [])
            if callback in watchers:
                watchers.remove(callback)
            if not watchers:
                self._watchers.pop(job_id, None)

    def records(self) -> tuple[NetworkRecord, ...]:
        return tuple(self._records)

    def refused(self, job_id: str, call_id: str) -> tuple[NetworkRecord, ...]:
        """Connections refused for one tool call, in order, excluding 407 handshakes (NO_GRANT).

        Used in tool results: given only curl's "CONNECT tunnel failed, response 403", models invent a
        cause. Scoped by credential, so concurrent calls never see each other's.
        """
        if not call_id:
            return ()
        return tuple(
            r for r in self._records
            if not r.allowed and r.reason != "NO_GRANT"
            and r.job_id == job_id and r.call_id == call_id
        )

    def hosts(self, *, job_id: str | None = None) -> tuple[str, ...]:
        """Distinct hosts in order of first arrival, for the collapsed UI row."""
        seen: list[str] = []
        for r in self._records:
            if job_id is not None and r.job_id != job_id:
                continue
            if r.host not in seen:
                seen.append(r.host)
        return tuple(seen)

    def clear(self) -> None:
        self._records.clear()
        self._first_host.clear()
