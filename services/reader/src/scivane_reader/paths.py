"""Locate the source tree during development.

Only answers "am I running from a checkout"; runtime artefacts never depend on it.
"""

from __future__ import annotations

import os
from pathlib import Path

# Marker file for the repo root; sturdier than a fixed parents[N].
_MARKER = Path("app") / "macos" / "Package.swift"


def find_source_root() -> Path | None:
    """Repository root, or None when not running from a checkout.

    Never falls back to cwd: a process started in /tmp would silently put its artefacts there.
    """
    override = os.environ.get("SCIVANE_PROJECT_ROOT")
    if override:
        return Path(override).expanduser().resolve()

    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / _MARKER).is_file():
            return parent

    return None


SOURCE_ROOT = find_source_root()
