"""API credentials: resolution and protection.

Keys never appear in responses, logs or error messages (redact() runs before anything leaves).
Malformed and missing keys get different codes because the fixes differ.
Priority: runtime injection (from the app's Keychain) > environment > credentials file.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import stat
from pathlib import Path
from typing import Literal, TypeAlias

from ..i18n import ui
from .errors import INVALID_CREDENTIAL, MISSING_CREDENTIAL, LlmError

logger = logging.getLogger("scivane.llm.credentials")

CredentialSource: TypeAlias = Literal["runtime", "env", "file", "missing"]

DEFAULT_CREDENTIALS_PATH = Path("~/.scivane/credentials.json").expanduser()


def env_var_for(provider_id: str) -> str:
    """Environment variable for a provider: SCIVANE_<PROVIDER>_API_KEY."""
    normalised = provider_id.upper().replace("-", "_").replace(".", "_")
    return f"SCIVANE_{normalised}_API_KEY"


def fingerprint(key: str) -> str:
    """Short fingerprint to tell keys apart without revealing any of them."""
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]


def _validate(raw: str, provider_id: str) -> str:
    """Validate and normalise; returns the key or raises with a stable code."""
    key = raw.strip()
    if not key:
        raise LlmError(
            ui(f"provider {provider_id!r} 的凭据是空的",
               f"The key for provider {provider_id!r} is empty"), MISSING_CREDENTIAL
        )
    # Common paste mistakes: a whole `export FOO=bar` line or a quoted value.
    if any(ch.isspace() for ch in key):
        raise LlmError(
            ui(f"provider {provider_id!r} 的凭据里含有空白字符，可能粘贴了多余内容",
               f"The key for provider {provider_id!r} contains whitespace — "
               "something extra may have been pasted"),
            INVALID_CREDENTIAL,
        )
    if key.startswith(("'", '"')) or key.endswith(("'", '"')):
        raise LlmError(
            ui(f"provider {provider_id!r} 的凭据带有引号，请只填写凭据本身",
               f"The key for provider {provider_id!r} has quotes around it — paste only the key itself"),
            INVALID_CREDENTIAL,
        )
    if len(key) < 8:
        raise LlmError(
            ui(f"provider {provider_id!r} 的凭据过短，不像是有效凭据",
               f"The key for provider {provider_id!r} is too short to be a valid key"),
            INVALID_CREDENTIAL,
        )
    return key


class CredentialStore:
    def __init__(self, path: Path | None = None) -> None:
        self._path = path if path is not None else DEFAULT_CREDENTIALS_PATH
        self._runtime: dict[str, str] = {}
        self._file_cache: dict[str, str] | None = None

    def _from_file(self) -> dict[str, str]:
        if self._file_cache is not None:
            return self._file_cache
        self._file_cache = {}
        try:
            info = self._path.stat()
        except OSError:
            return self._file_cache
        # Warn rather than refuse on loose permissions; refusing would look like a configured key that
        # silently doesn't work.
        if info.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
            logger.warning(
                "凭据文件 %s 权限过宽，建议 chmod 600", self._path
            )
        try:
            loaded = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            logger.warning("凭据文件 %s 无法解析，已忽略", self._path)
            return self._file_cache
        if isinstance(loaded, dict):
            self._file_cache = {
                str(k): str(v) for k, v in loaded.items() if isinstance(v, str)
            }
        return self._file_cache

    def source_of(self, provider_id: str) -> CredentialSource:
        if provider_id in self._runtime:
            return "runtime"
        if os.environ.get(env_var_for(provider_id), "").strip():
            return "env"
        if self._from_file().get(provider_id, "").strip():
            return "file"
        return "missing"

    def get(self, provider_id: str) -> str:
        source = self.source_of(provider_id)
        if source == "runtime":
            return _validate(self._runtime[provider_id], provider_id)
        if source == "env":
            return _validate(os.environ[env_var_for(provider_id)], provider_id)
        if source == "file":
            return _validate(self._from_file()[provider_id], provider_id)
        raise LlmError(
            ui(f"provider {provider_id!r} 还没有配置凭据："
               f"在设置里填写，或设置环境变量 {env_var_for(provider_id)}",
               f"Provider {provider_id!r} has no key yet: add one in Settings, "
               f"or set the environment variable {env_var_for(provider_id)}"),
            MISSING_CREDENTIAL,
        )

    def set_runtime(self, provider_id: str, key: str) -> None:
        """In memory only; the app persists keys in the Keychain."""
        _validate(key, provider_id)
        self._runtime[provider_id] = key.strip()

    def clear_runtime(self, provider_id: str) -> None:
        self._runtime.pop(provider_id, None)

    def describe(self, provider_id: str) -> dict[str, object]:
        """Status for the API; never includes key material."""
        source = self.source_of(provider_id)
        described: dict[str, object] = {
            "configured": source != "missing",
            "source": source,
        }
        if source != "missing":
            try:
                described["fingerprint"] = fingerprint(self.get(provider_id))
            except LlmError as exc:
                # configured but invalid: say so, or the user assumes it works
                described["configured"] = False
                described["problem"] = exc.code
        return described

    def known_secrets(self) -> list[str]:
        secrets = list(self._runtime.values())
        secrets.extend(self._from_file().values())
        for name, value in os.environ.items():
            if name.startswith("SCIVANE_") and name.endswith("_API_KEY") and value.strip():
                secrets.append(value.strip())
        return [s for s in secrets if len(s) >= 8]

    def redact(self, text: str) -> str:
        """Replace any known key in `text`. Provider error bodies sometimes echo the key, so anything
        headed for logs or callers goes through this.
        """
        if not text:
            return text
        for secret in self.known_secrets():
            if secret in text:
                text = text.replace(secret, "[已隐去凭据]")
        return text


credentials = CredentialStore()
