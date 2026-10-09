"""Model layer: vendor-neutral vocabulary, protocol adapters and the protections around them.

This layer knows nothing about papers, projects or conversations.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

from .cache import CacheCapability, CachePlan, plan_cache, prefix_fingerprint
from .credentials import CredentialStore, credentials, env_var_for
from .errors import ALL_CODES, LlmError, LlmFailure
from .registry import LlmRegistry, ProviderConfig, registry
from .retry import RetryPolicy, Timeouts, compute_delay, is_retryable
from .types import (
    CallRequest,
    ContentBlock,
    Finish,
    ImageBlock,
    Message,
    Purpose,
    StreamChunk,
    TextBlock,
    TextDelta,
    ThinkingDelta,
    Usage,
    UsageUpdate,
)
from .vision import VisionCheck

logger = logging.getLogger("scivane.llm")

__all__ = [
    "CallRequest", "Message", "TextBlock", "ImageBlock", "ContentBlock",
    "StreamChunk", "TextDelta", "ThinkingDelta", "UsageUpdate", "Finish",
    "Usage", "Purpose", "VisionCheck",
    "LlmError", "LlmFailure", "ALL_CODES",
    "CacheCapability", "CachePlan", "plan_cache", "prefix_fingerprint",
    "RetryPolicy", "Timeouts", "is_retryable", "compute_delay",
    "CredentialStore", "credentials", "env_var_for",
    "LlmRegistry", "ProviderConfig", "registry",
    "load_providers", "save_providers",
]


def _effort(raw: object) -> str | None:
    """Unknown reasoning levels fall back to the default instead of becoming a provider 400."""
    from .types import REASONING_LEVELS

    return str(raw) if isinstance(raw, str) and raw in REASONING_LEVELS else None



def load_providers(path: Path, into: LlmRegistry | None = None) -> int:
    """Load provider settings from JSON; returns how many were registered.

    A missing file is a fresh install, not an error. A bad entry is skipped, not fatal.
    """
    target = into if into is not None else registry
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return 0
    try:
        entries = json.loads(raw)
    except ValueError:
        logger.warning("provider 配置 %s 不是合法 JSON，已忽略", path)
        return 0
    if not isinstance(entries, list):
        logger.warning("provider 配置 %s 应当是一个数组，已忽略", path)
        return 0

    loaded = 0
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        try:
            target.register(ProviderConfig(
                id=str(entry["id"]),
                protocol=str(entry["protocol"]),
                model=str(entry["model"]),
                base_url=str(entry.get("base_url", "")),
                label=str(entry.get("label", "")),
                context_window=_window(entry.get("context_window")),
                reasoning=_effort(entry.get("reasoning")),
                credential_ref=_credential_ref(entry.get("credential_ref")),
            ))
        except (KeyError, LlmError, TypeError) as exc:
            logger.warning("跳过一条无效的 provider 配置：%s", exc)
            continue
        loaded += 1
    return loaded


def _credential_ref(raw: object) -> str:
    """Credential reference: own or macro:<id>. Unknown values fall back to own rather than
    dropping the provider.
    """
    if not isinstance(raw, str):
        return "own"
    value = raw.strip()
    if value == "own":
        return "own"
    if value.startswith("macro:") and value[6:] and value[6:].replace("-", "").replace("_", "").isalnum():
        return value
    return "own"


def _window(raw: object) -> int | None:
    """Unparseable windows count as unset rather than dropping the provider."""
    try:
        value = int(raw)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def save_providers(path: Path, source: LlmRegistry | None = None) -> int:
    """Persist the registered providers; returns how many were written.

    Never contains credentials. Written to a temp file and swapped in, so a crash can't leave
    half a JSON behind.
    """
    target = source if source is not None else registry
    entries = [
        {
            "id": config.id,
            "protocol": config.protocol,
            "model": config.model,
            "base_url": config.base_url,
            "label": config.label,
            "context_window": config.context_window,
            "reasoning": config.reasoning,
            "credential_ref": config.credential_ref,
        }
        for config in target.configs()
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    staging = path.with_suffix(path.suffix + ".writing")
    staging.write_text(
        json.dumps(entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    staging.replace(path)
    return len(entries)
