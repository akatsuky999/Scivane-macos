"""大模型接入层：统一词汇、多厂商适配、以及围绕它们的保护。

这是 Scivane 从「PDF 转 Markdown 工具」走向阅读 agent 的地基：
本地负责把论文变成结构化 Markdown，云端负责在这份 Markdown
之上理解与推理；那份 Markdown 是整个会话的静态上下文，所以 prompt 缓存
从第一版就是一等公民。

分层：

    types      厂商无关的消息与流式词汇（终止分片协议）
    errors     稳定失败码 —— 路由靠 code，绝不解析文本
    cache      prompt 缓存的能力声明与断点规划
    retry      超时、退避、重试判定
    credentials 凭据解析与「永不泄漏」纪律
    adapters   三套厂商协议的翻译
    registry   provider 注册与统一的流式调用（一处机制）

本层刻意**不**知道「论文」「项目」「会话」是什么 —— 那些属于上层。
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

logger = logging.getLogger("scivane.llm")

__all__ = [
    "CallRequest", "Message", "TextBlock", "ImageBlock", "ContentBlock",
    "StreamChunk", "TextDelta", "ThinkingDelta", "UsageUpdate", "Finish",
    "Usage", "Purpose",
    "LlmError", "LlmFailure", "ALL_CODES",
    "CacheCapability", "CachePlan", "plan_cache", "prefix_fingerprint",
    "RetryPolicy", "Timeouts", "is_retryable", "compute_delay",
    "CredentialStore", "credentials", "env_var_for",
    "LlmRegistry", "ProviderConfig", "registry",
    "load_providers", "save_providers",
]


def _effort(raw: object) -> str | None:
    """读盘时校验推理档位。**认不出就当没配**（回到默认档），
    而不是把一个非法值传给厂商换来一个 400。"""
    from .types import REASONING_LEVELS

    return str(raw) if isinstance(raw, str) and raw in REASONING_LEVELS else None



def load_providers(path: Path, into: LlmRegistry | None = None) -> int:
    """从 JSON 文件加载 provider 配置。返回成功注册的条数。

    文件形如：

        [
          {"id": "deepseek", "protocol": "openai", "model": "deepseek-chat",
           "base_url": "https://api.deepseek.com/v1", "label": "DeepSeek"},
          {"id": "claude", "protocol": "anthropic", "model": "claude-sonnet-4-6"}
        ]

    文件不存在不是错误 —— 全新安装本来就还没配任何 provider，
    这时应当正常启动并在界面上显示「未配置」，而不是拒绝启动。
    单条配置有问题只跳过那一条，不连累其它已经配好的。
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
    """key 从哪来。认不出来就当 `own` —— 同样**不要因为一个坏字段丢掉整条 provider**。

    只认两种形状：`own`、`macro:<编号>`。**这里不碰任何秘密**，它就是个引用。
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
    """上下文窗口：认不出来就当没填，**不要因为一个坏字段丢掉整条 provider**。"""
    try:
        value = int(raw)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def save_providers(path: Path, source: LlmRegistry | None = None) -> int:
    """把当前注册的 provider 写回 JSON 文件。返回写了几条。

    **这个文件里永远没有凭据。** key 在 App 的钥匙串里，后端只在内存里拿着
    运行期副本 —— 落盘的只有「怎么连」（协议、地址、模型名），
    那部分既不敏感、也正是换台机器要带走的东西。

    路径由 `config.LLM_PROVIDERS_PATH` 给出，**不要在别处再写一遍
    `~/.scivane/providers.json`** —— 尤其不要在 Swift 侧硬编码一份。
    同一个路径两处维护必然漂移，而漂移之后的症状是「设置里明明改了，
    重启就回到旧的」，极难查。

    写临时文件再替换：中途崩了不会留下半截 JSON 把已有配置毁掉。
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
