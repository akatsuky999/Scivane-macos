"""HTTP routes for projects: validation and status mapping; logic lives in scivane_reader.projects.

Files are not proxied: responses carry local paths and the app reads them directly.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from .. import config
from ..i18n import ui
from ..projects import ProjectError, projects
from ..projects.annotations import AnnotationError

logger = logging.getLogger("scivane.api.projects")

router = APIRouter(prefix="/projects", tags=["projects"])

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
    "NO_SOURCE": 409,
    "INVALID_ANNOTATION": 400,
    "ANNOTATION_NOT_FOUND": 404,
    "ANNOTATION_EXISTS": 409,
    "TOO_MANY_ANNOTATIONS": 409,
    "CORRUPT_ANNOTATIONS": 500,
    "UNSUPPORTED_ANNOTATIONS": 500,
}


def _fail(exc: ProjectError | AnnotationError) -> HTTPException:
    return HTTPException(status_code=_STATUS.get(exc.code, 400), detail=str(exc))


def _described(project) -> dict:
    described = project.as_dict()
    directory = projects.dir_for(project.id)
    source = projects.source_path(project.id)
    described["dir"] = str(directory)
    described["source_path"] = str(source) if source else None
    context_path = projects.context_path(project.id)
    described["context_path"] = str(context_path) if context_path.is_file() else None
    return described


class CreateIn(BaseModel):
    """Create from a source document, or empty. At least one of path and title is required."""

    path: str | None = None
    #: An empty title is meaningful: untitled projects take their title from a later import,
    #: while a typed title is never overwritten by extraction.
    title: str | None = None


class AttachSourceIn(BaseModel):
    path: str


class AddFileIn(BaseModel):
    #: Local path, not multipart: the app and the backend share the machine.
    path: str


class ConversationIn(BaseModel):
    title: str | None = None


class ConversationPatchIn(BaseModel):
    """Rename, switch the model card, or both. An empty PATCH is a client bug and is rejected."""

    title: str | None = Field(default=None, min_length=1)
    provider: str | None = Field(default=None, min_length=1)


class RenameIn(BaseModel):
    title: str = Field(min_length=1)


class ContextIn(BaseModel):
    markdown: str
    origin: Literal["ocr", "upload"] = "ocr"
    #: OCR job whose image crops move into the project
    job_id: str | None = None
    #: directory of the uploaded Markdown, for its relative image links
    source_dir: str | None = None


class ConfirmIn(BaseModel):
    accepted: bool


class AnnotationIn(BaseModel):
    """Shape only; ranges and the palette are checked in projects.annotations."""

    #: chosen by the app, which shows the mark before this request returns
    id: str
    kind: str
    color: str
    spans: list[dict[str, Any]]
    text: str = ""


class AnnotationPatchIn(BaseModel):
    kind: str | None = None
    color: str | None = None


@router.get("")
async def list_projects():
    return {"projects": [_described(p) for p in projects.list_all()]}


@router.post("")
async def create_project(body: CreateIn):
    """Create a project. Rebuilding the same paper returns the existing one;
    empty projects are never deduplicated.
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
    """Attach a source document to an empty project, refining its title.
    Projects that already have one are refused.
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
    """Replace the static context. OCR output is trusted; uploaded Markdown lands unconfirmed."""
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
    """Confirm or reject uploaded Markdown as this paper's text. Rejecting removes it entirely."""
    try:
        project = projects.confirm_context(project_id, body.accepted)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"project": _described(project)}


@router.get("/{project_id}/events")
async def project_events(project_id: str):
    """Session log: everything that changed what the model saw."""
    try:
        projects.get(project_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"events": list(projects.events(project_id))}



@router.get("/{project_id}/conversations")
async def list_conversations(project_id: str):
    try:
        projects.get(project_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"conversations": projects.list_conversations(project_id)}


@router.post("/{project_id}/conversations")
async def create_conversation(project_id: str, body: ConversationIn):
    """Persisted immediately: the UI needs the id to bind the composer."""
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
    """Deletes only this conversation's file."""
    try:
        removed = projects.delete_conversation(project_id, conversation_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"removed": conversation_id, "existed": removed}


@router.get("/{project_id}/conversations/{conversation_id}/export")
async def export_conversation(project_id: str, conversation_id: str):
    """Export the raw event stream: the authoritative record both projections are rebuilt from."""
    try:
        return projects.export_conversation(project_id, conversation_id)
    except ProjectError as exc:
        raise _fail(exc) from exc


# files/ holds material the user handed over; notes/ holds conclusions they wrote
# (changing those needs confirmation).


@router.get("/{project_id}/files")
async def list_project_files(project_id: str):
    try:
        projects.get(project_id)
    except ProjectError as exc:
        raise _fail(exc) from exc
    return {"files": projects.list_files(project_id)}


@router.post("/{project_id}/files")
async def add_project_file(project_id: str, body: AddFileIn):
    """Copy a local file into files/; name clashes get a suffix instead of overwriting."""
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


# Highlights and underlines on the source PDF, stored in the control plane; the PDF is never modified.


@router.get("/{project_id}/annotations")
async def list_annotations(project_id: str):
    try:
        return {"annotations": projects.annotation_book(project_id).list()}
    except (ProjectError, AnnotationError) as exc:
        raise _fail(exc) from exc


@router.post("/{project_id}/annotations")
async def add_annotation(project_id: str, body: AnnotationIn):
    try:
        record = projects.annotation_book(project_id, writing=True).add(body.model_dump())
    except (ProjectError, AnnotationError) as exc:
        raise _fail(exc) from exc
    return {"annotation": record}


@router.patch("/{project_id}/annotations/{annotation_id}")
async def update_annotation(project_id: str, annotation_id: str, body: AnnotationPatchIn):
    try:
        record = projects.annotation_book(project_id).update(annotation_id, body.model_dump())
    except (ProjectError, AnnotationError) as exc:
        raise _fail(exc) from exc
    return {"annotation": record}


@router.delete("/{project_id}/annotations/{annotation_id}")
async def remove_annotation(project_id: str, annotation_id: str):
    try:
        removed = projects.annotation_book(project_id).remove(annotation_id)
    except (ProjectError, AnnotationError) as exc:
        raise _fail(exc) from exc
    return {"removed": annotation_id, "existed": removed}
