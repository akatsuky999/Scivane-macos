"""Registry of running OCR jobs. State is shared between the event loop and worker threads, hence the lock."""

from __future__ import annotations

import logging
import shutil
import threading
import uuid
from pathlib import Path

from . import config

logger = logging.getLogger("scivane.jobs")


class JobRegistry:
    def __init__(self, root: Path | None = None) -> None:
        self._root = root or config.JOBS_DIR
        self._cancelled: set[str] = set()
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

    def is_cancelled(self, job_id: str) -> bool:
        with self._lock:
            return job_id in self._cancelled

    def forget(self, job_id: str) -> None:
        with self._lock:
            self._cancelled.discard(job_id)

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
