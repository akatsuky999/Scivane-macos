"""项目层：一个 PDF 就是一个项目。

项目有稳定身份、有随身携带的
上下文、有可回放的会话历史。区别只在「上下文」在那边是代码库，在这里是
论文正文。

分层：

    model         Project / ContextState / 事件名
    title         标题提取（快猜 + OCR 后精确化）
    conversations 一个项目里的多条对话：id、分界线、摘要
    store         落盘存储、插图吸收、append-only 日志
    context       装配成 llm 层的 CallRequest（prompt 缓存在这里落地）

本层依赖 llm 层，反过来不成立：llm 层不知道「论文」「项目」是什么。
"""

from __future__ import annotations

from .context import SYSTEM_PROMPT, assemble
from .conversations import CONVERSATION_EVENTS, CONVERSATIONS_DIR
from .model import ContextOrigin, ContextState, Project, ProjectEvent, TitleSource
from .store import (
    DEFAULT_PROJECTS_ROOT,
    ProjectError,
    ProjectStore,
    projects,
    rough_tokens,
)
from .title import better_than, from_markdown, from_pdf

__all__ = [
    "Project", "ContextState", "ContextOrigin", "TitleSource", "ProjectEvent",
    "ProjectStore", "ProjectError", "projects", "DEFAULT_PROJECTS_ROOT",
    "assemble", "SYSTEM_PROMPT", "rough_tokens",
    "CONVERSATIONS_DIR", "CONVERSATION_EVENTS",
    "from_pdf", "from_markdown", "better_than",
]
