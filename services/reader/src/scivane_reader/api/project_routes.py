"""项目层的 HTTP 路由。

只做编排：参数校验与状态码映射。真正的逻辑在 scivane_reader.projects。

**为什么不代理原稿与插图文件**：项目目录就在本机，响应里直接把路径给出去，
App 用 PDFKit / WebView 直接读，比把几十 MB 的 PDF 从 HTTP 搬一遍快得多，
也省掉一整套 range 请求的麻烦。
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from .. import config
from ..i18n import ui
from ..projects import ProjectError, projects

logger = logging.getLogger("scivane.api.projects")

router = APIRouter(prefix="/projects", tags=["projects"])

#: 存储层的 code → HTTP 状态码。
_STATUS = {
    "NOT_FOUND": 404,
    "SOURCE_MISSING": 404,
    "NO_CONVERSATION": 404,
    "NO_CONTEXT": 409,
    "SOURCE_EXISTS": 409,
    "FILE_TOO_LARGE": 413,
    "INVALID_NAME": 400,
    "INVALID_ID": 400,
    "INVALID_CONVERSATION": 400,
    "INVALID_TITLE": 400,
    "CORRUPT": 500,
}


def _fail(exc: ProjectError) -> HTTPException:
    return HTTPException(status_code=_STATUS.get(exc.code, 400), detail=str(exc))


def _described(project) -> dict:
    """项目详情。附上本机路径，App 直接按路径读文件。"""
    described = project.as_dict()
    directory = projects.dir_for(project.id)
    source = projects.source_path(project.id)
    described["dir"] = str(directory)
    described["source_path"] = str(source) if source else None
    context_path = projects.context_path(project.id)
    described["context_path"] = str(context_path) if context_path.is_file() else None
    return described


class CreateIn(BaseModel):
    """建项目。两种：从一份原稿建，或者建一个空的。

    `path` 与 `title` 都可以不给，但不能都不给 —— 那就没说清要建什么了。
    """

    path: str | None = None
    #: 空项目的名字。**留空是有意义的**：留空的项目叫「未命名项目」，
    #: 之后导入原稿时会被自动识别出来的标题改进；打了字的则受红线保护，
    #: 任何自动提取都不许覆盖（见 store.create_empty）。
    title: str | None = None


class AttachSourceIn(BaseModel):
    path: str


class AddFileIn(BaseModel):
    #: 本机路径。**不走 multipart** —— App 与后端在同一台机器上，
    #: 把几十 MB 的字节从 HTTP 搬一遍毫无收益（与原稿、插图同一个取舍）。
    path: str


class ConversationIn(BaseModel):
    title: str | None = None


class ConversationPatchIn(BaseModel):
    """改名、换模型卡，或者两件一起。

    **两个字段都可选**，但不能都不给 —— 空 PATCH 是调用方写错了，
    静悄悄返回成功会让它以为改动生效了。
    """

    title: str | None = Field(default=None, min_length=1)
    provider: str | None = Field(default=None, min_length=1)


class RenameIn(BaseModel):
    title: str = Field(min_length=1)


class ContextIn(BaseModel):
    markdown: str
    origin: Literal["ocr", "upload"] = "ocr"
    #: OCR 任务号。给了它才能把 var/jobs 里的插图吸收进项目。
    job_id: str | None = None
    #: 上传的 Markdown 所在目录，用于解析它引用的相对图片。
    source_dir: str | None = None


class ConfirmIn(BaseModel):
    accepted: bool


@router.get("")
async def list_projects():
    return {"projects": [_described(p) for p in projects.list_all()]}


@router.post("")
async def create_project(body: CreateIn):
    """建项目。给了 `path` 就从原稿建，没给就建一个空的。

    从原稿建时，同一篇论文重复构建返回已有项目而不是再建一个 —— 与
    「相同路径再次导入只选中已有文档」的既有行为保持一致。
    **空项目不参与这个去重**：它们没有内容可比，按内容去重会让第二个
    空项目变成第一个的"重复"。
    """
    if body.path is None:
        try:
            project = projects.create_empty(body.title or "")
        except ProjectError as exc:
            raise _fail(exc) from exc
        return {"project": _described(project), "created": True}

    source = Path(body.path).expanduser()
    if not source.is_file():
        raise HTTPException(status_code=404, detail=ui(f"找不到原文件：{source}",
                                                       f"Source file not found: {source}"))

    from ..projects.store import sha256_file

    existing = projects.find_by_source(sha256_file(source))
    if existing is not None:
        return {"project": _described(existing), "created": False}

    try:
        project = projects.create(source)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"project": _described(project), "created": True}


@router.post("/{project_id}/source")
async def attach_source(project_id: str, body: AttachSourceIn):
    """给一个空项目挂上原稿，顺带用它精确化标题。

    只对还没有原稿的项目开放 —— 换掉一篇已有原稿会让正文、插图与既往
    对话引用的一切都不再对应它，那是另一件事。
    """
    try:
        project = projects.attach_source(project_id, Path(body.path))
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"project": _described(project)}


@router.get("/{project_id}")
async def get_project(project_id: str):
    try:
        return {"project": _described(projects.get(project_id))}
    except ProjectError as exc:
        raise _fail(exc) from exc


@router.delete("/{project_id}")
async def delete_project(project_id: str):
    try:
        removed = projects.delete(project_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"removed": project_id, "existed": removed}


@router.patch("/{project_id}")
async def rename_project(project_id: str, body: RenameIn):
    try:
        return {"project": _described(projects.rename(project_id, body.title))}
    except ProjectError as exc:
        raise _fail(exc) from exc


@router.get("/{project_id}/context")
async def get_context(project_id: str):
    try:
        return {"markdown": projects.read_context(project_id)}
    except ProjectError as exc:
        raise _fail(exc) from exc


@router.put("/{project_id}/context")
async def set_context(project_id: str, body: ContextIn):
    """替换静态上下文。

    「重新 OCR 覆盖」与「上传文件覆盖」走同一个入口，差别只在 origin：
    OCR 的结果就是从本项目原稿扫出来的，直接可用；上传的文件未必对应
    这篇论文，落地时标记为待确认。
    """
    try:
        project = projects.set_context(
            project_id,
            body.markdown,
            origin=body.origin,
            job_id=body.job_id,
            jobs_root=config.JOBS_DIR,
            source_dir=Path(body.source_dir).expanduser() if body.source_dir else None,
        )
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"project": _described(project)}


@router.post("/{project_id}/context/confirm")
async def confirm_context(project_id: str, body: ConfirmIn):
    """人工确认上传的 Markdown 是否就是这篇论文的正文。

    拒绝会把它整个撤掉 —— 不留一份没人认账的正文在项目里，
    免得日后误当作可信上下文使用。
    """
    try:
        project = projects.confirm_context(project_id, body.accepted)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"project": _described(project)}


@router.get("/{project_id}/events")
async def project_events(project_id: str):
    """会话日志。凡是改变过模型可见内容的事都在这里。"""
    try:
        projects.get(project_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"events": list(projects.events(project_id))}


# --- 对话 ----------------------------------------------------------------
#
# 一个项目可以有多条对话，各自一份 .jsonl（为什么这么存见
# projects/conversations.py）。这里只做编排，逻辑在 store 里。


@router.get("/{project_id}/conversations")
async def list_conversations(project_id: str):
    """这个项目的全部对话，最近活动的在前。"""
    try:
        projects.get(project_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"conversations": projects.list_conversations(project_id)}


@router.post("/{project_id}/conversations")
async def create_conversation(project_id: str, body: ConversationIn):
    """开一条新对话。立刻落盘，界面拿到 id 才能把输入框绑上去。"""
    try:
        conversation = projects.create_conversation(project_id, body.title or "")
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"conversation": conversation}


@router.patch("/{project_id}/conversations/{conversation_id}")
async def patch_conversation(project_id: str, conversation_id: str, body: ConversationPatchIn):
    if body.title is None and body.provider is None:
        raise HTTPException(status_code=400, detail={"code": "INVALID_ARGS",
                                                     "message": ui("title 与 provider 至少给一个",
                                                                   "Give at least a title or a provider")})
    try:
        conversation = None
        if body.title is not None:
            conversation = projects.rename_conversation(project_id, conversation_id, body.title)
        if body.provider is not None:
            conversation = projects.set_conversation_provider(
                project_id, conversation_id, body.provider)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"conversation": conversation}


@router.delete("/{project_id}/conversations/{conversation_id}")
async def delete_conversation(project_id: str, conversation_id: str):
    """删掉一条对话。**只删这一个文件** —— 正文、原稿与其它对话都不受影响。"""
    try:
        removed = projects.delete_conversation(project_id, conversation_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"removed": conversation_id, "existed": removed}


@router.get("/{project_id}/conversations/{conversation_id}/export")
async def export_conversation(project_id: str, conversation_id: str):
    """导出一条对话。

    给的是**原始事件流**而不是渲染好的文字：它是权威记录，由它能重建
    模型历史与界面记录两种投影，反过来不行。App 拿到之后存成 .json 文件。
    """
    try:
        return projects.export_conversation(project_id, conversation_id)
    except ProjectError as exc:
        raise _fail(exc) from exc


# --- 用户上传的材料 ------------------------------------------------------
#
# 落在项目的 `files/` 里。与 `notes/` 分开：notes/ 是人**写**的结论
# （改它要确认），files/ 是人**给**的材料，本来就是给 agent 看的。


@router.get("/{project_id}/files")
async def list_project_files(project_id: str):
    """`files/` 里有什么。最近放进来的在前。"""
    try:
        projects.get(project_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"files": projects.list_files(project_id)}


@router.post("/{project_id}/files")
async def add_project_file(project_id: str, body: AddFileIn):
    """把一个本机文件复制进 `files/`。重名不覆盖，自动加后缀。"""
    try:
        added = projects.add_file(project_id, Path(body.path))
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"file": added}


@router.delete("/{project_id}/files/{name}")
async def remove_project_file(project_id: str, name: str):
    try:
        removed = projects.remove_file(project_id, name)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"removed": name, "existed": removed}
