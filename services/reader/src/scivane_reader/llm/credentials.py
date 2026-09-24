"""API 凭据的解析与保护。

三条纪律，每条都有对应单测守着：

1. **永不回显** —— 任何返回给前端的结构里都不含 key 本身，只有「配没配」
   和一个指纹。
2. **永不进日志、永不进错误消息** —— 厂商的错误体里有时会把 key 原样回显，
   所以往外抛之前一律过一遍 `redact`。
3. **格式错误与完全没配要分开** —— 修法不同：前者是改掉存的值，后者是去
   配一个。所以是 INVALID_CREDENTIAL 与 MISSING_CREDENTIAL 两个码。

解析优先级：运行时注入 > 环境变量 > 凭据文件。

运行时注入排第一，是为了让「在 App 设置里改完 key 立刻生效」成为可能，
不必重启后端。环境变量排第二，对应 App 启动时从 Keychain 读出注入的那条
路径（沿用 BackendManager 已有的 env 注入模式）。凭据文件排最后，只服务
于从命令行直接起后端时的调试。
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
    """某个 provider 对应的环境变量名。约定：SCIVANE_<PROVIDER>_API_KEY。"""
    normalised = provider_id.upper().replace("-", "_").replace(".", "_")
    return f"SCIVANE_{normalised}_API_KEY"


def fingerprint(key: str) -> str:
    """凭据指纹。

    用来回答「我现在配的还是上次那把吗」，同时不泄漏任何一位原文。
    比回显 key 后四位更安全，信息量却一样够用。
    """
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]


def _validate(raw: str, provider_id: str) -> str:
    """校验并规范化。返回可用的 key，或抛出带稳定码的错误。"""
    key = raw.strip()
    if not key:
        raise LlmError(
            ui(f"provider {provider_id!r} 的凭据是空的",
               f"The key for provider {provider_id!r} is empty"), MISSING_CREDENTIAL
        )
    # 常见误粘贴：把整行 `export FOO=bar` 或带引号的值贴了进来。
    # 这类值重试多少次都是同样失败，必须和「没配」区分开。
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
    """按优先级解析凭据，并持有用于脱敏的已知 key 集合。"""

    def __init__(self, path: Path | None = None) -> None:
        self._path = path if path is not None else DEFAULT_CREDENTIALS_PATH
        self._runtime: dict[str, str] = {}
        self._file_cache: dict[str, str] | None = None

    # --- 读取 ---------------------------------------------------------

    def _from_file(self) -> dict[str, str]:
        if self._file_cache is not None:
            return self._file_cache
        self._file_cache = {}
        try:
            info = self._path.stat()
        except OSError:
            return self._file_cache
        # 明文落盘的文件不该让同机其它用户读到。权限不对时只警告不拒绝：
        # 直接罢工会让用户在不知情的情况下"配了但用不了"。
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
        """凭据来自哪里。不触发校验，只看有没有。"""
        if provider_id in self._runtime:
            return "runtime"
        if os.environ.get(env_var_for(provider_id), "").strip():
            return "env"
        if self._from_file().get(provider_id, "").strip():
            return "file"
        return "missing"

    def get(self, provider_id: str) -> str:
        """取出可用凭据，取不到就抛带稳定码的错误。"""
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

    # --- 运行时写入 ---------------------------------------------------

    def set_runtime(self, provider_id: str, key: str) -> None:
        """设置本进程内的凭据。**不落盘** —— 持久化由 App 侧的 Keychain 负责。"""
        _validate(key, provider_id)  # 先校验，别把坏值收下
        self._runtime[provider_id] = key.strip()

    def clear_runtime(self, provider_id: str) -> None:
        self._runtime.pop(provider_id, None)

    # --- 对外描述（永不含 key 本身）-----------------------------------

    def describe(self, provider_id: str) -> dict[str, object]:
        """给 API 用的状态描述。刻意不含凭据原文。"""
        source = self.source_of(provider_id)
        described: dict[str, object] = {
            "configured": source != "missing",
            "source": source,
        }
        if source != "missing":
            try:
                described["fingerprint"] = fingerprint(self.get(provider_id))
            except LlmError as exc:
                # 配了但不合法，要如实说出来，否则用户会以为配好了
                described["configured"] = False
                described["problem"] = exc.code
        return described

    # --- 脱敏 ---------------------------------------------------------

    def known_secrets(self) -> list[str]:
        """当前所有可能出现在外部文本里的凭据。"""
        secrets = list(self._runtime.values())
        secrets.extend(self._from_file().values())
        for name, value in os.environ.items():
            if name.startswith("SCIVANE_") and name.endswith("_API_KEY") and value.strip():
                secrets.append(value.strip())
        return [s for s in secrets if len(s) >= 8]

    def redact(self, text: str) -> str:
        """把文本里出现的任何已知凭据替换掉。

        厂商的错误体里偶尔会把 key 原样回显。任何要进日志或要返回给上层的
        外部文本，都必须先过这一道 —— 否则一条 400 错误就能把凭据写进
        var/logs/api.log。
        """
        if not text:
            return text
        for secret in self.known_secrets():
            if secret in text:
                text = text.replace(secret, "[已隐去凭据]")
        return text


#: 进程内单例。与 jobs.py 的 `jobs` 同一个模式。
credentials = CredentialStore()
