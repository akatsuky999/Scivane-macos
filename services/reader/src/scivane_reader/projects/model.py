"""项目与上下文的数据形状。

一个项目就是一篇论文。它拥有原稿、一份作为静态上下文的 Markdown、
一个标题，以及一条 append-only 的会话日志。

这套结构让 agent 项目拥有稳定身份、有随身携带的上下文和可回放的历史，
而这里的上下文就是论文正文。
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Literal, TypeAlias

#: 标题从哪来。精确度递增，后来者才允许覆盖先来者 —— 见 title.py 的 `better_than`。
#:
#: `placeholder` 是新建空项目时用户没起名字的占位名。它排在最底下，
#: 意思是「这不是谁给的名字，只是个占位」——  之后导入原稿、跑完 OCR，
#: 任何一次提取都可以改进它。用户**真打了字**的名字是 `manual`，
#: 在最顶上，任何自动提取都不许覆盖（红线）。
TitleSource: TypeAlias = Literal[
    "placeholder", "filename", "pdf-metadata", "pdf-heading", "markdown-heading", "manual"
]

#: 上下文从哪来。OCR 的结果天然对应原稿；用户上传的则不一定，需要人工确认。
ContextOrigin: TypeAlias = Literal["ocr", "upload"]

#: 磁盘布局的版本。
#:
#: 1 = 扁平：project.json / session.jsonl / source.* / context.md / assets/ 全摆在项目根
#: 2 = 工作区骨架：.lumen/ + pdf/ + md/ + code/ + workbench/ + notes/
#: 3 = 对话拆分：.lumen/session.jsonl 只留项目生命周期，
#:     每条对话独立成 .lumen/conversations/<id>.jsonl
#:
#: 打开项目时按它决定要不要就地升级。**只做相邻升级**（vN → vN+1），
#: 跨版本靠把相邻步骤串起来 —— 这样每一步都能单独测，也不会出现
#: 「从 v1 直接跳 v5」那种没人验证过的路径。
LAYOUT_VERSION = 3


@dataclass
class ContextState:
    """项目当前的静态上下文。

    这就是要喂给大模型的那份论文正文，也是 prompt 缓存的对象。
    """

    origin: ContextOrigin
    #: 内容的 SHA-256。换了内容就换了缓存前缀，这个值是判断依据。
    sha256: str
    chars: int
    tokens: int
    updated_at: str
    #: 上传进来的 Markdown 未必真是这篇论文的正文，必须由人确认过才作数。
    #: OCR 出来的结果直接为 True —— 它就是从这份原稿扫出来的。
    confirmed: bool = True
    #: 产出这份上下文的 OCR 任务号，便于回溯插图来源。
    job_id: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> ContextState:
        return ContextState(
            origin=raw.get("origin", "ocr"),
            sha256=raw.get("sha256", ""),
            chars=int(raw.get("chars", 0)),
            tokens=int(raw.get("tokens", 0)),
            updated_at=raw.get("updated_at", ""),
            confirmed=bool(raw.get("confirmed", True)),
            job_id=raw.get("job_id"),
        )


@dataclass
class Project:
    """一篇论文。"""

    id: str
    title: str
    title_source: TitleSource
    #: 原文件名，仅供显示。真正的原稿在项目目录里叫 source.<ext>。
    source_name: str
    #: 原稿内容的 SHA-256。用来发现「同一篇论文被重复构建」。
    source_sha256: str
    source_suffix: str
    created_at: str
    updated_at: str
    #: 磁盘布局版本。老数据没有这个字段，读出来按 1 算。
    layout: int = 1
    context: ContextState | None = None
    #: 预留给以后的作者、年份、DOI。现在只提取标题，但形状先留好。
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def has_source(self) -> bool:
        """有没有原稿。

        空项目（用户直接新建、还没导入 PDF）是没有的。界面据此决定
        要不要摆出阅读区 —— 没有原稿时强行进阅读区只会显示一个空白 PDF 面板。
        """
        return bool(self.source_sha256)

    @property
    def has_usable_context(self) -> bool:
        """能不能拿去喂模型。未经确认的上传内容不算数。"""
        return self.context is not None and self.context.confirmed

    def as_dict(self) -> dict[str, Any]:
        described = asdict(self)
        described["context"] = self.context.as_dict() if self.context else None
        described["has_usable_context"] = self.has_usable_context
        described["has_source"] = self.has_source
        return described

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> Project:
        context = raw.get("context")
        return Project(
            id=raw["id"],
            title=raw.get("title", ""),
            title_source=raw.get("title_source", "filename"),
            source_name=raw.get("source_name", ""),
            source_sha256=raw.get("source_sha256", ""),
            source_suffix=raw.get("source_suffix", ".pdf"),
            created_at=raw.get("created_at", ""),
            updated_at=raw.get("updated_at", ""),
            # 缺字段说明是骨架迁移之前写的，那就是 v1
            layout=int(raw.get("layout", 1)),
            context=ContextState.from_dict(context) if context else None,
            metadata=raw.get("metadata", {}) or {},
        )


class ProjectEvent:
    """会话日志的事件名。

    日志是 append-only 的：**凡是会改变模型可见内容的事，都必须在这里留痕**。
    这条纪律保证「模型看见的内容都有记录」—— 有了它，
    「这个项目现在为什么是这个上下文」永远能回答，将来的 fork、回放、
    审计也都是同一份日志的不同投影。

    问答消息（user/message、assistant/message）会加在这里，
    格式已经预留好，本步先不产生。
    """

    CREATED = "project/created"
    TITLE_CHANGED = "project/title-changed"
    CONTEXT_REPLACED = "context/replaced"
    CONTEXT_CONFIRMED = "context/confirmed"
    CONTEXT_REJECTED = "context/rejected"
    #: 磁盘布局升级。记下从哪一版到哪一版、备份在哪 —— 出了问题要能溯源。
    LAYOUT_MIGRATED = "layout/migrated"
    #: 事后给一个空项目挂上原稿。**它是项目生命周期事件，不属于任何对话。**
    SOURCE_ATTACHED = "source/attached"
    #: 用户往 files/ 里放了一份材料。同样属于项目而不属于某次谈话 ——
    #: 放进来之后每一条对话都看得见它。
    FILE_ADDED = "file/added"

    #: 对话自身的事件。写在**那条对话的文件里**，作为它的头 ——
    #: 有了它，一条空对话在磁盘上也是存在的，列表里看得见。
    CONVERSATION_CREATED = "conversation/created"
    CONVERSATION_RENAMED = "conversation/renamed"
    #: 这条对话改用哪个 provider（哪张模型卡）。
    #:
    #: **走事件而不是给对话建一份元数据文件**：对话本来就是日志的投影
    #: （见 conversations.summarise），加一个事件就自动获得「老对话没有这个
    #: 事件就回落到全局默认」的兼容行为，不需要任何迁移。
    CONVERSATION_PROVIDER = "conversation/provider"

    #: 问答与工具。**凡是进入过模型请求的东西都必须能从这里重建。**
    #:
    #: 工具这几条尤其要紧：科研场景里「这个结论是怎么得出来的」必须能回答，
    #: 而结论往往来自某次 grep 命中的某一行、或某次 bash 跑出来的数字。
    #: 调用了什么、参数是什么、返回了什么、用户批准还是拒绝，全部落盘。
    USER_MESSAGE = "user/message"
    ASSISTANT_MESSAGE = "assistant/message"
    TOOL_CALL = "tool/call"
    TOOL_RESULT = "tool/result"
    #: 用户对一次需要批准的调用的裁决。拒绝也要留痕 —— 「当时没做什么」
    #: 和「当时做了什么」同样是历史的一部分。
    TOOL_DECISION = "tool/decision"
