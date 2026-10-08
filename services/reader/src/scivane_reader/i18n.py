"""UI language for human-facing text.

The app sends X-Scivane-Language with every request and ui() picks the matching string.
Text the model reads (prompts, tool descriptions, tool results) never follows it, so the
prompt prefix stays cacheable; tool execution is pinned to Chinese in tools/scheduler.py.

asyncio tasks and to_thread copy the context; plain threads do not, so wrap them in
contextvars.copy_context().run.
"""

from __future__ import annotations

import contextlib
from contextvars import ContextVar
from typing import Iterator

__all__ = ["HEADER", "LANGUAGES", "DEFAULT", "parse", "current", "ui", "speaking"]

#: Not Accept-Language: URLSession fills that from system preferences, which can differ
#: from the language chosen in the app.
HEADER = "X-Scivane-Language"
LANGUAGES = ("zh", "en")
DEFAULT = "zh"

_language: ContextVar[str] = ContextVar("scivane_ui_language", default=DEFAULT)


def parse(value: str | None) -> str:
    """Anything starting with "en" is English; everything else falls back to Chinese."""
    if value and value.strip().lower().startswith("en"):
        return "en"
    return DEFAULT


def current() -> str:
    return _language.get()


def ui(zh: str, en: str) -> str:
    """Pick the variant for the current request's language. Both must be written."""
    return en if _language.get() == "en" else zh


@contextlib.contextmanager
def speaking(language: str) -> Iterator[None]:
    """Speak `language` inside the block (the middleware wraps each request; the scheduler pins tools to zh)."""
    token = _language.set(language if language in LANGUAGES else parse(language))
    try:
        yield
    finally:
        _language.reset(token)
