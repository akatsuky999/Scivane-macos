"""On-disk project storage.

    ~/.scivane/projects/<id>/
    ├── .lumen/          control plane, hidden from the agent
    │   ├── project.json     metadata
    │   ├── session.jsonl    append-only lifecycle log
    │   ├── conversations/   one .jsonl per conversation
    │   ├── attachments/     images attached to chat messages, by content hash
    │   ├── annotations.json highlights and underlines on the source PDF
    │   └── policy.json      sandbox and tool policy
    ├── pdf/             source document, read-only
    ├── md/              the paper text (OCR or transcription) and its images
    ├── notes/           Markdown to read in the text pane: imported, or written by the agent
    ├── files/           other material the user added
    ├── code/            the paper's code
    └── workbench/       the agent's scripts and outputs

The store writes .lumen/ directly instead of going through workspace.resolve(), which is the
agent's entry point and refuses it. Source documents are copied, not referenced, so a project
survives the original file being moved or deleted.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .. import config
from ..i18n import ui
from .model import (
    LAYOUT_VERSION,
    ContextOrigin,
    ContextState,
    Project,
    ProjectEvent,
    TitleSource,
)
from . import title as title_tools
from .annotations import AnnotationBook, path_in as annotations_path
from .attachments import ATTACHMENTS_DIR, AttachmentStore, ImageRecord
from .conversations import (
    CONVERSATION_EVENTS,
    CONVERSATIONS_DIR,
    is_valid_id,
    new_id as new_conversation_id,
    summarise,
)
from .workspace import CONTROL_DIR, FILES_DIR, MD_DIR, NOTES_DIR, PDF_DIR, SKELETON

logger = logging.getLogger("scivane.projects")

DEFAULT_PROJECTS_ROOT = config.PROJECTS_DIR

#: Backups are named <id>.backup-<timestamp>. '.' is not valid in an id, so list_all can never
#: mistake one for a project.
BACKUP_MARK = ".backup-"

#: image paths in OCR Markdown, e.g. /assets/<job>/page-1/img_0.png
_OCR_ASSET = re.compile(r"/assets/[A-Za-z0-9_\-/]+?/[^\s\"'<>)\]]+")

#: local image references in uploaded Markdown (inline, reference and HTML forms)
_LOCAL_IMAGE_PATTERNS = (
    re.compile(r"!\[[^\]]*\]\(\s*<?([^)\n]+?)>?\s*\)"),
    re.compile(r"(?m)^\s*\[[^\]]+\]:\s*<?([^\s\n]+)>?\s*$"),
    re.compile(r"""(?i)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"""),
)


def now() -> str:
    """Millisecond precision: projects created within one second would otherwise sort arbitrarily."""
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rough_tokens(text: str) -> int:
    """Rough token count, to show the user how large the paper is."""
    cjk = sum(1 for ch in text if "一" <= ch <= "鿿" or "぀" <= ch <= "ヿ")
    return cjk + (len(text) - cjk) // 4


class ProjectError(Exception):
    """Project operation failed; the stable code picks the HTTP status."""

    def __init__(self, message: str, code: str = "PROJECT_ERROR") -> None:
        super().__init__(message)
        self.code = code


class ProjectStore:
    def __init__(self, root: Path | None = None) -> None:
        self._root = root if root is not None else DEFAULT_PROJECTS_ROOT
        #: Log path -> next seq. Keyed by path because each conversation has its own log since v3.
        #: Without the cache every append rescans the log (0.09 ms at 50 events, 0.21 ms at 400).
        self._next_seq: dict[str, int] = {}

    @property
    def root(self) -> Path:
        return self._root

    def dir_for(self, project_id: str) -> Path:
        """Project directory; rejects ids that would traverse directories."""
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", project_id):
            raise ProjectError(ui(f"非法的项目 id：{project_id!r}",
                                  f"Invalid project id: {project_id!r}"), "INVALID_ID")
        return self._root / project_id

    def control_dir(self, project_id: str) -> Path:
        """Control plane: metadata, logs and policy, hidden from the agent."""
        return self.dir_for(project_id) / CONTROL_DIR

    def _dual(self, project_id: str, new: Path, legacy: Path) -> Path:
        """New layout first, then the old one. list and stat read headers before any upgrade, so the
        accessors must know both layouts; when neither exists, writes go to the new one.
        """
        if new.exists():
            return new
        return legacy if legacy.exists() else new

    def _meta_path(self, project_id: str) -> Path:
        return self._dual(
            project_id,
            self.control_dir(project_id) / "project.json",
            self.dir_for(project_id) / "project.json",
        )

    def context_path(self, project_id: str) -> Path:
        return self._dual(
            project_id,
            self.dir_for(project_id) / MD_DIR / "context.md",
            self.dir_for(project_id) / "context.md",
        )

    def source_path(self, project_id: str) -> Path | None:
        directory = self.dir_for(project_id)
        for base in (directory / PDF_DIR, directory):
            if not base.is_dir():
                continue
            for candidate in sorted(base.glob("source.*")):
                return candidate
        return None

    def _log_path(self, project_id: str) -> Path:
        """Project lifecycle log. Since v3 it only holds lifecycle events; messages and tool calls live
        in the conversation files.
        """
        return self._dual(
            project_id,
            self.control_dir(project_id) / "session.jsonl",
            self.dir_for(project_id) / "session.jsonl",
        )

    def conversations_dir(self, project_id: str) -> Path:
        return self.control_dir(project_id) / CONVERSATIONS_DIR

    def conversation_path(self, project_id: str, conversation_id: str) -> Path:
        """A conversation's log file. The id comes from a query parameter, so it is validated first or
        `../../` could redirect writes outside the project.
        """
        if not is_valid_id(conversation_id):
            raise ProjectError(ui(f"非法的对话 id：{conversation_id!r}",
                                  f"Invalid conversation id: {conversation_id!r}"),
                               "INVALID_CONVERSATION")
        return self.conversations_dir(project_id) / f"{conversation_id}.jsonl"

    def _write_meta(self, project: Project) -> None:
        project.updated_at = now()
        path = self._meta_path(project.id)
        path.parent.mkdir(parents=True, exist_ok=True)
        # atomic write: a crash can't leave an unparseable project.json
        temporary = path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(project.as_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temporary.replace(path)

    def get(self, project_id: str, *, migrate: bool = True) -> Project:
        """Read a project. Opening is when the layout gets upgraded; migrate=False (list, stat) never
        touches the disk.
        """
        project = self._read_meta(project_id)
        if migrate and project.layout < LAYOUT_VERSION:
            return self.ensure_layout(project_id)
        return project

    def _read_meta(self, project_id: str) -> Project:
        """Metadata only; never touches the disk layout."""
        path = self._meta_path(project_id)
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise ProjectError(ui(f"没有这个项目：{project_id}",
                                  f"No such project: {project_id}"), "NOT_FOUND") from exc
        except ValueError as exc:
            raise ProjectError(ui(f"项目元数据损坏：{project_id}",
                                  f"Project metadata is corrupt: {project_id}"), "CORRUPT") from exc
        return Project.from_dict(raw)

    def list_all(self) -> list[Project]:
        """All projects, most recently updated first. A damaged project is skipped, not fatal."""
        if not self._root.is_dir():
            return []
        projects: list[Project] = []
        for entry in self._root.iterdir():
            if not entry.is_dir() or BACKUP_MARK in entry.name:
                continue    # upgrade backups are not projects
            try:
                # headers only, no upgrade: listing must not copy every project
                projects.append(self.get(entry.name, migrate=False))
            except ProjectError:
                logger.warning("跳过损坏的项目目录：%s", entry.name)
        # id as the tie-breaker keeps the order deterministic
        projects.sort(key=lambda p: (p.updated_at, p.id), reverse=True)
        return projects

    def find_by_source(self, source_sha256: str) -> Project | None:
        """Find a project by source hash to avoid building the same paper twice. Empty hashes never match,
        or every empty project would be a duplicate.
        """
        if not source_sha256:
            return None
        for project in self.list_all():
            if project.source_sha256 == source_sha256:
                return project
        return None

    def append_event(
        self,
        project_id: str,
        kind: str,
        data: dict[str, Any] | None = None,
        *,
        conversation: str | None = None,
    ) -> None:
        """Append an event to an append-only log: the conversation's file when given, else the lifecycle log.

        Line order is authoritative, `seq` is only a hint. "a" mode is O_APPEND, so concurrent
        writers never corrupt lines; their seqs may collide, which is harmless because nothing
        indexes by seq.
        """
        path = (
            self.conversation_path(project_id, conversation)
            if conversation is not None
            else self._log_path(project_id)
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        seq = self._reserve_seq(path)
        line = json.dumps(
            {"seq": seq, "type": kind, "at": now(), "data": data or {}},
            ensure_ascii=False,
        )
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    def _reserve_seq(self, path: Path) -> int:
        """Next seq, recovered from the end of the file on first use. Falls back to counting lines only
        when the tail is unreadable (a write killed halfway, an old format).
        """
        key = str(path)
        cached = self._next_seq.get(key)
        if cached is None:
            cached = self._recover_seq(path)
        self._next_seq[key] = cached + 1
        return cached

    @staticmethod
    def _recover_seq(path: Path) -> int:
        """Seq after the last event in the file's tail."""
        if not path.is_file():
            return 1
        try:
            size = path.stat().st_size
            with path.open("rb") as handle:
                # events are at most tens of KB, so 64 KB covers the last few
                handle.seek(max(0, size - 65_536))
                tail = handle.read().decode("utf-8", errors="replace")
        except OSError:
            return 1
        for line in reversed(tail.splitlines()):
            if not line.strip():
                continue
            try:
                seq = json.loads(line).get("seq")
            except ValueError:
                continue  # skip bad lines, as events() does
            if isinstance(seq, int):
                return seq + 1
        # nothing parseable in the tail: count lines (slow path, only for damaged logs)
        return sum(1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
                   if line.strip()) + 1

    def events(
        self, project_id: str, *, conversation: str | None = None
    ) -> Iterator[dict[str, Any]]:
        """Events in order; bad lines are skipped so one corrupt line can't lose the whole history."""
        path = (
            self.conversation_path(project_id, conversation)
            if conversation is not None
            else self._log_path(project_id)
        )
        if not path.is_file():
            return
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                yield json.loads(line)
            except ValueError:
                logger.warning("跳过 %s 中一条无法解析的日志", project_id)

    def list_conversations(self, project_id: str) -> list[dict[str, Any]]:
        """Conversations, most recent activity first. Computed from the files; there is no index."""
        directory = self.conversations_dir(project_id)
        if not directory.is_dir():
            return []
        found: list[dict[str, Any]] = []
        for entry in sorted(directory.glob("*.jsonl")):
            conversation_id = entry.stem
            if not is_valid_id(conversation_id):
                continue        # not a file we wrote
            found.append(
                summarise(conversation_id, list(self.events(project_id, conversation=conversation_id)))
            )
        # empty conversations have no updated_at; the id carries a sortable timestamp
        found.sort(key=lambda c: (c["updated_at"] or c["id"], c["id"]), reverse=True)
        return found

    def create_conversation(self, project_id: str, title: str = "") -> dict[str, Any]:
        """Start a conversation. Persisted immediately so the UI has an id before the user types."""
        self.get(project_id, migrate=False)
        conversation_id = new_conversation_id()
        data: dict[str, Any] = {}
        cleaned = title_tools.clean(title)
        if cleaned:
            data["title"] = cleaned
        self.append_event(
            project_id, ProjectEvent.CONVERSATION_CREATED, data, conversation=conversation_id
        )
        return summarise(
            conversation_id, list(self.events(project_id, conversation=conversation_id))
        )

    def rename_conversation(self, project_id: str, conversation_id: str, title: str) -> dict[str, Any]:
        """Rename via an event; the log is append-only."""
        path = self.conversation_path(project_id, conversation_id)
        if not path.is_file():
            raise ProjectError(ui(f"没有这条对话：{conversation_id}",
                                  f"No such conversation: {conversation_id}"), "NO_CONVERSATION")
        cleaned = title_tools.clean(title)
        if not cleaned:
            raise ProjectError(ui("对话标题不能为空", "The conversation title can't be empty"),
                               "INVALID_TITLE")
        self.append_event(
            project_id, ProjectEvent.CONVERSATION_RENAMED, {"title": cleaned},
            conversation=conversation_id,
        )
        return summarise(
            conversation_id, list(self.events(project_id, conversation=conversation_id))
        )

    def set_conversation_provider(
        self, project_id: str, conversation_id: str, provider: str
    ) -> dict[str, Any]:
        """Switch the conversation's model card. Not validated here: the choice is recorded as made, and
        a card deleted later is detected (and replaced by the default) when the conversation opens.
        """
        path = self.conversation_path(project_id, conversation_id)
        if not path.is_file():
            raise ProjectError(ui(f"没有这条对话：{conversation_id}",
                                  f"No such conversation: {conversation_id}"), "NO_CONVERSATION")
        cleaned = provider.strip()
        if not cleaned:
            raise ProjectError(ui("provider 不能为空", "The provider can't be empty"),
                               "INVALID_PROVIDER")
        self.append_event(
            project_id, ProjectEvent.CONVERSATION_PROVIDER, {"provider": cleaned},
            conversation=conversation_id,
        )
        return summarise(
            conversation_id, list(self.events(project_id, conversation=conversation_id))
        )

    def delete_conversation(self, project_id: str, conversation_id: str) -> bool:
        """Delete one conversation's file, then the images no other conversation refers to."""
        path = self.conversation_path(project_id, conversation_id)
        if not path.is_file():
            return False
        path.unlink()
        self._next_seq.pop(str(path), None)
        self.attachments(project_id).collect(self._referenced_images(project_id))
        return True

    def attachments(self, project_id: str) -> AttachmentStore:
        return AttachmentStore(self.control_dir(project_id) / ATTACHMENTS_DIR)

    def image_records(self, events: list[dict[str, Any]]) -> list[ImageRecord]:
        """Images attached to the user messages among `events`, in order, without repeats."""
        seen: dict[str, ImageRecord] = {}
        for event in events:
            if not isinstance(event, dict) or event.get("type") != ProjectEvent.USER_MESSAGE:
                continue
            data = event.get("data") if isinstance(event.get("data"), dict) else {}
            for raw in data.get("images") or []:
                record = ImageRecord.from_dict(raw)
                if record is not None:
                    seen.setdefault(record.sha256, record)
        return list(seen.values())

    def _referenced_images(self, project_id: str) -> set[str]:
        directory = self.conversations_dir(project_id)
        if not directory.is_dir():
            return set()
        return {
            record.sha256
            for entry in directory.glob("*.jsonl") if is_valid_id(entry.stem)
            for record in self.image_records(list(self.events(project_id, conversation=entry.stem)))
        }

    def latest_conversation(self, project_id: str) -> str | None:
        """The most recently active conversation, or None."""
        found = self.list_conversations(project_id)
        return found[0]["id"] if found else None

    def ensure_conversation(self, project_id: str, conversation_id: str | None = None) -> str:
        """Settle which conversation to write to: the given one (which must exist), else the most
        recent, else a new one. Every write goes through here, so conversation files never appear
        out of nowhere.
        """
        if conversation_id is not None:
            path = self.conversation_path(project_id, conversation_id)
            if not path.is_file():
                raise ProjectError(ui(f"没有这条对话：{conversation_id}",
                                  f"No such conversation: {conversation_id}"), "NO_CONVERSATION")
            return conversation_id
        latest = self.latest_conversation(project_id)
        if latest is not None:
            return latest
        return self.create_conversation(project_id)["id"]

    def export_conversation(self, project_id: str, conversation_id: str) -> dict[str, Any]:
        """A conversation as an exportable JSON document: the raw events (the authoritative record) plus
        project and conversation headers. Never contains credentials; a test checks this.
        """
        project = self.get(project_id, migrate=False)
        path = self.conversation_path(project_id, conversation_id)
        if not path.is_file():
            raise ProjectError(ui(f"没有这条对话：{conversation_id}",
                                  f"No such conversation: {conversation_id}"), "NO_CONVERSATION")
        events = list(self.events(project_id, conversation=conversation_id))
        store = self.attachments(project_id)
        # the log names images by hash; the export carries their bytes so it stands on its own
        attachments = {}
        for record in self.image_records(events):
            data = store.load(record)
            if data is not None:
                attachments[record.sha256] = {
                    "media_type": record.media_type,
                    "data": base64.b64encode(data).decode("ascii"),
                }
        exported: dict[str, Any] = {
            "schema": "lumen.conversation/1",
            "exported_at": now(),
            "project": {
                "id": project.id,
                "title": project.title,
                "source_name": project.source_name,
            },
            "conversation": summarise(conversation_id, events),
            "events": events,
        }
        if attachments:
            exported["attachments"] = attachments
        return exported

    # Layout upgrades go one adjacent version at a time, each step backed up and reversible.

    def _ensure_policy(self, project_id: str) -> None:
        """Write the default policy file. Deliberately doesn't mirror workspace.py's tier rules: two
        copies of a boundary drift apart. Only project-specific overrides belong here (none yet).
        """
        control = self.control_dir(project_id)
        control.mkdir(parents=True, exist_ok=True)
        policy = control / "policy.json"
        if policy.is_file():
            return
        policy.write_text(
            json.dumps({
                "version": 1,
                "note": (
                    "留给沙箱与工具策略。目录分层规则由代码决定"
                    "（projects/workspace.py 的 TIERS），这里刻意不做镜像以免漂移。"
                ),
            }, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    def _make_backup(self, project_id: str) -> Path:
        """Copy the whole project directory next to it; the only rollback source."""
        directory = self.dir_for(project_id)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f")
        backup = self._root / f"{project_id}{BACKUP_MARK}{stamp}"
        shutil.copytree(directory, backup)
        return backup

    def _restore(self, project_id: str, backup: Path) -> None:
        """Restore from the backup; a failure must never leave a half-upgraded directory."""
        directory = self.dir_for(project_id)
        shutil.rmtree(directory, ignore_errors=True)
        shutil.copytree(backup, directory)

    def ensure_layout(self, project_id: str) -> Project:
        """Upgrade to the current layout (idempotent). Each step is backed up first and rolled back on
        error. Backups are kept; their paths are in the layout/migrated event.
        """
        project = self.get(project_id, migrate=False)
        while project.layout < LAYOUT_VERSION:
            step = self._MIGRATIONS.get(project.layout)
            if step is None:
                raise ProjectError(
                    ui(f"没有从布局 v{project.layout} 起步的升级路径",
                       f"No upgrade path from layout v{project.layout}"), "NO_MIGRATION"
                )
            backup = self._make_backup(project_id)
            before = project.layout
            try:
                getattr(self, step)(project_id)
            except Exception:
                self._restore(project_id, backup)
                raise
            project = self.get(project_id, migrate=False)
            if project.layout <= before:
                # the version didn't advance; looping again would never end
                self._restore(project_id, backup)
                raise ProjectError(
                    ui(f"布局升级未推进版本号（仍为 v{project.layout}）",
                       f"The layout upgrade didn't advance the version (still v{project.layout})"),
                    "MIGRATION_STALLED"
                )
            self.append_event(project_id, ProjectEvent.LAYOUT_MIGRATED, {
                "from": before,
                "to": project.layout,
                "backup": backup.name,
            })
        return project

    def _migrate_v1_to_v2(self, project_id: str) -> None:
        """Flat layout -> workspace skeleton."""
        directory = self.dir_for(project_id)
        control = directory / CONTROL_DIR

        for relative in SKELETON:
            (directory / relative).mkdir(parents=True, exist_ok=True)

        def move(source: Path, target: Path) -> None:
            if source.exists():
                shutil.move(str(source), str(target))

        move(directory / "project.json", control / "project.json")
        move(directory / "session.jsonl", control / "session.jsonl")
        for legacy_source in sorted(directory.glob("source.*")):
            move(legacy_source, directory / PDF_DIR / legacy_source.name)
        move(directory / "context.md", directory / MD_DIR / "context.md")

        # md/assets already exists from the skeleton, so move entries one by one
        legacy_assets = directory / "assets"
        if legacy_assets.is_dir():
            target_assets = directory / MD_DIR / "assets"
            for item in legacy_assets.iterdir():
                shutil.move(str(item), str(target_assets / item.name))
            legacy_assets.rmdir()

        self._ensure_policy(project_id)

        raw = json.loads((control / "project.json").read_text(encoding="utf-8"))
        raw["layout"] = 2
        (control / "project.json").write_text(
            json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    def _migrate_v2_to_v3(self, project_id: str) -> None:
        """One session log -> lifecycle log plus conversation files, split by CONVERSATION_EVENTS.

        Raw lines are moved, not re-serialised, so the log stays byte-identical to what was written.
        Unparseable lines stay in the lifecycle log rather than being dropped. Projects that never
        chatted get no empty conversation file.
        """
        control = self.control_dir(project_id)
        log = control / "session.jsonl"
        lifecycle: list[str] = []
        talk: list[str] = []

        if log.is_file():
            for line in log.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                try:
                    kind = json.loads(line).get("type")
                except ValueError:
                    lifecycle.append(line)   # keep bad lines; a migration never drops data
                    continue
                (talk if kind in CONVERSATION_EVENTS else lifecycle).append(line)

        if talk:
            conversations = control / CONVERSATIONS_DIR
            conversations.mkdir(parents=True, exist_ok=True)
            conversation_id = new_conversation_id()
            # the header takes the time of the first moved event, so the start date stays true
            try:
                started = json.loads(talk[0]).get("at") or now()
            except ValueError:
                started = now()
            header = json.dumps(
                {"seq": 0, "type": ProjectEvent.CONVERSATION_CREATED, "at": started, "data": {}},
                ensure_ascii=False,
            )
            (conversations / f"{conversation_id}.jsonl").write_text(
                "\n".join([header, *talk]) + "\n", encoding="utf-8"
            )

        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("\n".join(lifecycle) + ("\n" if lifecycle else ""), encoding="utf-8")
        # the file was rewritten; the cached seq no longer matches its tail
        self._next_seq.pop(str(log), None)

        meta = control / "project.json"
        raw = json.loads(meta.read_text(encoding="utf-8"))
        raw["layout"] = 3
        meta.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")

    #: Layout version -> name of the method that upgrades it. Names rather than function objects,
    #: so subclasses and test doubles can override them.
    _MIGRATIONS = {1: "_migrate_v1_to_v2", 2: "_migrate_v2_to_v3"}

    def create(self, source: Path) -> Project:
        """Build a project from a source document: copy it, guess a title, write the metadata."""
        source = Path(source).expanduser()
        if not source.is_file():
            raise ProjectError(ui(f"找不到原文件：{source}", f"Source file not found: {source}"),
                               "SOURCE_MISSING")

        digest = sha256_file(source)
        project_id = uuid.uuid4().hex[:12]
        directory = self.dir_for(project_id)
        directory.mkdir(parents=True, exist_ok=True)

        try:
            for relative in SKELETON:
                (directory / relative).mkdir(parents=True, exist_ok=True)
            self._ensure_policy(project_id)

            suffix = source.suffix.lower() or ".bin"
            shutil.copy2(source, directory / PDF_DIR / f"source{suffix}")

            guessed = title_tools.from_pdf(source) or title_tools.from_filename(source)
            project = Project(
                id=project_id,
                title=guessed[0],
                title_source=guessed[1],
                source_name=source.name,
                source_sha256=digest,
                source_suffix=suffix,
                created_at=now(),
                updated_at=now(),
                layout=LAYOUT_VERSION,
            )
            self._write_meta(project)
        except Exception:
            # a failed build leaves no half project in the list
            shutil.rmtree(directory, ignore_errors=True)
            raise

        self.append_event(project_id, ProjectEvent.CREATED, {
            "title": project.title,
            "title_source": project.title_source,
            "source_name": project.source_name,
        })
        return project

    #: Name of an unnamed empty project. Paired with title_source="placeholder" so any later
    #: extraction can improve it.
    UNTITLED = "未命名项目"

    def create_empty(self, title: str = "") -> Project:
        """Create a project without a source document (notes, code and chat first; the PDF later).

        A typed title is `manual` and never overwritten; an empty one is `placeholder` and improves
        on import or after OCR.
        """
        cleaned = title_tools.clean(title)
        project_id = uuid.uuid4().hex[:12]
        directory = self.dir_for(project_id)
        directory.mkdir(parents=True, exist_ok=True)

        try:
            for relative in SKELETON:
                (directory / relative).mkdir(parents=True, exist_ok=True)
            self._ensure_policy(project_id)
            project = Project(
                id=project_id,
                title=cleaned or self.UNTITLED,
                title_source="manual" if cleaned else "placeholder",
                source_name="",
                source_sha256="",
                source_suffix="",
                created_at=now(),
                updated_at=now(),
                layout=LAYOUT_VERSION,
            )
            self._write_meta(project)
        except Exception:
            shutil.rmtree(directory, ignore_errors=True)
            raise

        self.append_event(project_id, ProjectEvent.CREATED, {
            "title": project.title,
            "title_source": project.title_source,
            "source_name": "",
        })
        return project

    def attach_source(self, project_id: str, source: Path) -> Project:
        """Attach a source document to an empty project and refine its title with the same better_than
        rule. Projects that already have one are refused: replacing it would orphan everything that
        refers to it.
        """
        project = self.get(project_id)
        if project.has_source:
            raise ProjectError(
                ui("这个项目已经有原稿了 —— 要换原稿请新建一个项目",
                   "This project already has an original — create a new project to use a different one"),
                "SOURCE_EXISTS"
            )
        source = Path(source).expanduser()
        if not source.is_file():
            raise ProjectError(ui(f"找不到原文件：{source}", f"Source file not found: {source}"),
                               "SOURCE_MISSING")

        directory = self.dir_for(project_id)
        (directory / PDF_DIR).mkdir(parents=True, exist_ok=True)
        suffix = source.suffix.lower() or ".bin"
        shutil.copy2(source, directory / PDF_DIR / f"source{suffix}")

        project.source_name = source.name
        project.source_sha256 = sha256_file(source)
        project.source_suffix = suffix
        self._write_meta(project)
        self.append_event(project_id, ProjectEvent.SOURCE_ATTACHED, {
            "source_name": project.source_name,
            "source_sha256": project.source_sha256,
        })

        guessed = title_tools.from_pdf(source) or title_tools.from_filename(source)
        candidate, origin = guessed
        if title_tools.better_than(origin, project.title_source) and candidate != project.title:
            return self.rename(project_id, candidate, origin)
        return self.get(project_id)

    def annotation_book(self, project_id: str, *, writing: bool = False) -> AnnotationBook:
        """The project's highlights and underlines. Marks need a source to sit on, so writes to an
        empty project are refused; reading one just finds none.
        """
        project = self.get(project_id)
        if writing and not project.has_source:
            raise ProjectError(ui("这个项目还没有原稿，没有地方可标注",
                                  "This project has no original to annotate yet"), "NO_SOURCE")
        return AnnotationBook(annotations_path(self.dir_for(project_id)))

    #: Upload size limit; large datasets are better generated by the agent in the sandbox.
    MAX_UPLOAD_BYTES = 64 * 1024 * 1024

    def files_dir(self, project_id: str) -> Path:
        return self.dir_for(project_id) / FILES_DIR

    def add_file(self, project_id: str, source: Path) -> dict[str, Any]:
        """Copy a dropped file into files/. Name clashes get -2, -3 suffixes instead of overwriting.

        Markdown goes to notes/ instead (import_note), wherever it was dropped: every Markdown
        document of a project lives in one place, the one the text pane lists. The returned path
        says where the file went.
        """
        source = self._upload_source(project_id, source)
        if _is_markdown(source):
            return self.import_note(project_id, source)
        size = source.stat().st_size
        target = _unique_target(self.files_dir(project_id), source.name)
        shutil.copy2(source, target)

        self.append_event(project_id, ProjectEvent.FILE_ADDED, {
            "name": target.name, "bytes": size, "origin": source.name,
        })
        return {
            "name": target.name,
            "path": f"{FILES_DIR}/{target.name}",
            "bytes": size,
        }

    def _upload_source(self, project_id: str, source: Path) -> Path:
        """The checks every copy into a project shares: the project exists, the file exists, and it
        isn't too large."""
        self.get(project_id)                 # raises when the project doesn't exist
        source = Path(source).expanduser()
        if not source.is_file():
            raise ProjectError(ui(f"找不到这个文件：{source}", f"File not found: {source}"),
                               "SOURCE_MISSING")
        size = source.stat().st_size
        if size > self.MAX_UPLOAD_BYTES:
            megabytes, limit = size / 1024 / 1024, self.MAX_UPLOAD_BYTES // 1024 // 1024
            raise ProjectError(
                ui(f"文件太大（{megabytes:.0f} MB），上限 {limit} MB",
                   f"File too large ({megabytes:.0f} MB); the limit is {limit} MB"),
                "FILE_TOO_LARGE",
            )
        return source

    def notes_dir(self, project_id: str) -> Path:
        return self.dir_for(project_id) / NOTES_DIR

    def import_note(self, project_id: str, source: Path) -> dict[str, Any]:
        """Copy a Markdown file into notes/ with the local images it links to, which go into
        notes/<name>_files/, so it still renders (and can later become the paper text) once its
        original folder is gone. Name clashes get -2, -3 suffixes instead of overwriting.
        """
        source = self._upload_source(project_id, source)
        if not _is_markdown(source):
            raise ProjectError(ui(f"notes/ 只收 Markdown：{source.name}",
                                  f"notes/ only takes Markdown: {source.name}"), "NOT_MARKDOWN")
        target = _unique_target(self.notes_dir(project_id), source.name)
        self._add_markdown(source, target)
        self.append_event(project_id, ProjectEvent.NOTE_ADDED, {
            "name": target.name, "bytes": source.stat().st_size, "origin": source.name,
        })
        return _note_record(self.notes_dir(project_id), target)

    #: A menu of hundreds of notes is no longer a menu; past this the oldest drop off the list
    #: (they stay on disk and in reach of the agent).
    NOTES_LIST_LIMIT = 500

    def list_notes(self, project_id: str) -> list[dict[str, Any]]:
        """Markdown documents under notes/ at any depth, most recently changed first.

        Skipped: hidden entries, the image folders imports bring along (<name>_files/ next to
        <name>.md) and anything that resolves outside notes/. The agent writes here, and a link
        it leaves pointing elsewhere must not put a foreign file on the list.
        """
        root = self.notes_dir(project_id)
        if not root.is_dir():
            return []
        base = root.resolve()
        found: list[dict[str, Any]] = []
        # os.walk doesn't follow directory links; file links are checked one by one below
        for current, folders, names in os.walk(root):
            here = Path(current)
            folders[:] = sorted(
                name for name in folders
                if not name.startswith(".") and not _is_companion(here / name)
            )
            for name in names:
                path = here / name
                if name.startswith(".") or not _is_markdown(path):
                    continue
                try:
                    if not path.resolve().is_relative_to(base) or not path.is_file():
                        continue
                    found.append(_note_record(root, path))
                except OSError:
                    continue
        found.sort(key=lambda note: (note["modified_at"], note["path"]), reverse=True)
        return found[: self.NOTES_LIST_LIMIT]

    def _add_markdown(self, source: Path, target: Path) -> None:
        """Copy a Markdown file and the local images it links to; links are rewritten to the copies."""
        markdown = source.read_text(encoding="utf-8", errors="replace")
        companion = _companion(target)
        staging = companion.with_name(companion.name + ".staging")
        shutil.rmtree(staging, ignore_errors=True)
        try:
            rewritten = self._absorb_assets(
                markdown, staging, jobs_root=None, source_dir=source.parent,
                link_prefix=companion.name)
            if staging.is_dir():
                staging.replace(companion)
            target.write_text(rewritten, encoding="utf-8")
        finally:
            shutil.rmtree(staging, ignore_errors=True)

    def list_files(self, project_id: str) -> list[dict[str, Any]]:
        """Contents of files/, most recent first."""
        directory = self.files_dir(project_id)
        if not directory.is_dir():
            return []
        found = []
        for entry in directory.iterdir():
            if not entry.is_file() or entry.name.startswith("."):
                continue
            stat = entry.stat()
            found.append({
                "name": entry.name,
                "path": f"{FILES_DIR}/{entry.name}",
                "bytes": stat.st_size,
                "added_at": stat.st_mtime,
            })
        found.sort(key=lambda f: f["added_at"], reverse=True)
        return found

    def remove_file(self, project_id: str, name: str) -> bool:
        """Delete an uploaded file; the name comes from a path parameter and is sanitised."""
        safe = _safe_name(name)
        if safe != name:
            raise ProjectError(ui(f"非法的文件名：{name!r}", f"Invalid file name: {name!r}"),
                               "INVALID_NAME")
        target = self.files_dir(project_id) / safe
        if not target.is_file():
            return False
        target.unlink()
        if _is_markdown(target):
            shutil.rmtree(_companion(target), ignore_errors=True)
        return True

    def delete(self, project_id: str) -> bool:
        directory = self.dir_for(project_id)
        resolved = directory.resolve()
        root = self._root.resolve()
        # never let a delete escape the project root
        if resolved == root or not resolved.is_relative_to(root):
            raise ProjectError(ui("拒绝删除项目根之外的路径",
                                  "Refusing to delete a path outside the projects root"), "INVALID_ID")
        if not directory.is_dir():
            return False
        shutil.rmtree(directory, ignore_errors=True)
        # backups only exist to roll back upgrades; with the project gone they would be orphans
        for backup in self._root.glob(f"{project_id}{BACKUP_MARK}*"):
            shutil.rmtree(backup, ignore_errors=True)
        return True

    def rename(self, project_id: str, new_title: str, source: TitleSource = "manual") -> Project:
        project = self.get(project_id)
        cleaned = title_tools.clean(new_title)
        if not cleaned:
            raise ProjectError(ui("标题不能为空", "The title can't be empty"), "INVALID_TITLE")
        previous = project.title
        project.title = cleaned
        project.title_source = source
        self._write_meta(project)
        self.append_event(project_id, ProjectEvent.TITLE_CHANGED, {
            "from": previous, "to": cleaned, "source": source,
        })
        return project

    def maybe_improve_title(self, project_id: str, markdown: str) -> Project:
        """Refine the title from the Markdown's first heading after OCR, only when more reliable.
        A title the user typed is never touched.
        """
        project = self.get(project_id)
        found = title_tools.from_markdown(markdown)
        if found is None:
            return project
        candidate, source = found
        if not title_tools.better_than(source, project.title_source):
            return project
        if candidate == project.title:
            return project
        return self.rename(project_id, candidate, source)

    def set_context(
        self,
        project_id: str,
        markdown: str,
        *,
        origin: ContextOrigin,
        job_id: str | None = None,
        jobs_root: Path | None = None,
        source_dir: Path | None = None,
        model: str | None = None,
    ) -> Project:
        """Replace the paper text. Its three ways in (local OCR, a model's transcription, a Markdown
        file the user picked) all end here and are all the user's own act, so the text is usable at
        once. Images are absorbed into the project and rewritten to relative paths so the project
        is self-contained.
        """
        project = self.get(project_id)
        directory = self.dir_for(project_id)
        assets_dir = directory / MD_DIR / "assets"
        assets_dir.parent.mkdir(parents=True, exist_ok=True)

        # stage first and swap in on success; a failure must not destroy the existing context
        staging = directory / MD_DIR / "assets.staging"
        shutil.rmtree(staging, ignore_errors=True)
        try:
            absorbed = self._absorb_assets(
                markdown, staging, jobs_root=jobs_root, source_dir=source_dir
            )
            self.context_path(project_id).write_text(absorbed, encoding="utf-8")
            shutil.rmtree(assets_dir, ignore_errors=True)
            if staging.is_dir():
                staging.replace(assets_dir)
        finally:
            shutil.rmtree(staging, ignore_errors=True)

        project.context = ContextState(
            origin=origin,
            sha256=sha256_bytes(absorbed.encode("utf-8")),
            chars=len(absorbed),
            tokens=rough_tokens(absorbed),
            updated_at=now(),
            confirmed=True,
            job_id=job_id,
            model=model if origin == "model" else None,
        )
        self._write_meta(project)
        replaced: dict[str, Any] = {
            "origin": origin,
            "sha256": project.context.sha256,
            "chars": project.context.chars,
            "tokens": project.context.tokens,
            "job_id": job_id,
        }
        if project.context.model:
            replaced["model"] = project.context.model
        self.append_event(project_id, ProjectEvent.CONTEXT_REPLACED, replaced)

        # read from this paper's own source, so its first heading may name the paper better
        if origin in ("ocr", "model"):
            project = self.maybe_improve_title(project_id, absorbed)
        return project

    def read_context(self, project_id: str) -> str:
        path = self.context_path(project_id)
        if not path.is_file():
            raise ProjectError(ui("这个项目还没有上下文", "This project has no text yet"), "NO_CONTEXT")
        return path.read_text(encoding="utf-8")

    def _absorb_assets(
        self,
        markdown: str,
        assets_dir: Path,
        *,
        jobs_root: Path | None,
        source_dir: Path | None,
        link_prefix: str = "assets",
    ) -> str:
        """Copy local images referenced by the text into `assets_dir`, rewriting the links to
        `link_prefix/<name>` (relative to the Markdown file).
        """
        replacements: dict[str, str] = {}

        def absorb(origin_path: Path, relative_name: str) -> str | None:
            try:
                data = origin_path.read_bytes()
            except OSError:
                logger.warning("插图读不到，保留原引用：%s", relative_name)
                return None
            target = assets_dir / relative_name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            return f"{link_prefix}/{relative_name}"

        # OCR references: /assets/<job>/...
        if jobs_root is not None:
            for reference in sorted(set(_OCR_ASSET.findall(markdown)), key=len, reverse=True):
                relative = reference[len("/assets/"):]
                resolved = _safe_join(jobs_root, relative)
                if resolved is None:
                    continue
                flattened = relative.replace("/", "_")
                new_path = absorb(resolved, flattened)
                if new_path:
                    replacements[reference] = new_path

        # relative images in uploaded Markdown
        if source_dir is not None:
            candidates: set[str] = set()
            for pattern in _LOCAL_IMAGE_PATTERNS:
                for match in pattern.finditer(markdown):
                    raw = match.group(1).split(' "')[0].strip("<>").strip()
                    if not raw or raw.startswith("/assets/"):
                        continue
                    if re.match(r"^[a-z][a-z0-9+.-]*:", raw, re.IGNORECASE):
                        continue        # http(s), data: and the like are left alone
                    candidates.add(raw)
            for reference in sorted(candidates, key=len, reverse=True):
                resolved = _safe_join(source_dir, reference)
                if resolved is None:
                    continue
                flattened = re.sub(r"[^A-Za-z0-9._-]", "_", reference)
                new_path = absorb(resolved, flattened)
                if new_path:
                    replacements[reference] = new_path

        rewritten = markdown
        # longest first, so a reference that prefixes another doesn't break it
        for old in sorted(replacements, key=len, reverse=True):
            rewritten = rewritten.replace(old, replacements[old])
        return rewritten


def _is_markdown(path: Path) -> bool:
    return path.suffix.lower() in (".md", ".markdown")


def _companion(markdown: Path) -> Path:
    """Where an imported Markdown file's images live: <name>_files/ beside it, like a saved web
    page."""
    return markdown.with_name(f"{markdown.stem}_files")


def _is_companion(folder: Path) -> bool:
    """An image folder an import brought along, not a folder of notes."""
    if not folder.name.endswith("_files"):
        return False
    stem = folder.name[: -len("_files")]
    return any((folder.parent / f"{stem}{suffix}").is_file() for suffix in (".md", ".markdown"))


def _unique_target(directory: Path, name: str) -> Path:
    """A free name in `directory` for an incoming file; clashes get -2, -3 instead of overwriting.
    A Markdown name also counts as taken when its image folder exists."""
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / _safe_name(name)
    stem, suffix = target.stem, target.suffix
    serial = 2
    while target.exists() or (_is_markdown(target) and _companion(target).exists()):
        target = directory / f"{stem}-{serial}{suffix}"
        serial += 1
    return target


def _note_record(root: Path, path: Path) -> dict[str, Any]:
    """How a note is listed. `path` is relative to the project, as the agent sees it."""
    relative = path.relative_to(root)
    stat = path.stat()
    return {
        "name": path.name,
        "path": f"{NOTES_DIR}/{relative.as_posix()}",
        "folder": "" if relative.parent == Path(".") else relative.parent.as_posix(),
        "bytes": stat.st_size,
        "modified_at": stat.st_mtime,
    }


def _safe_name(name: str) -> str:
    """Reduce an uploaded file name to one safe path segment: it comes from the user's file system
    and comes back through a path parameter, and neither may escape files/.
    """
    cleaned = re.sub(r"[/\\\x00]", "_", Path(name).name).strip()
    cleaned = cleaned.lstrip(".") or "file"
    return cleaned[:120]


def _safe_join(base: Path, relative: str) -> Path | None:
    """Join a relative path onto base, rejecting traversal and symlinks that escape it."""
    from urllib.parse import unquote

    try:
        decoded = unquote(relative)
        root = base.resolve()
        target = (root / decoded).resolve()
    except (OSError, ValueError):
        return None
    if not target.is_relative_to(root) or not target.is_file():
        return None
    return target


projects = ProjectStore()
