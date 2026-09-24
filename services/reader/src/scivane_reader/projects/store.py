"""项目的落盘存储。

    ~/.scivane/projects/<id>/
    ├── .lumen/          控制面 —— agent 看不见
    │   ├── project.json     元数据
    │   ├── session.jsonl    append-only 项目生命周期日志
    │   ├── conversations/   一条对话一个 .jsonl（见 conversations.py）
    │   └── policy.json      沙箱与工具策略
    ├── pdf/             原稿 —— 只读
    ├── md/              OCR 正文与插图 —— 可改
    ├── code/            论文的开源代码
    ├── workbench/       agent 的脚本与产物
    └── notes/           人写的批注与结论

**存储层自己不走 workspace.resolve()。** 那是 agent 侧的入口，会拒绝 `.lumen/`；
而维护元数据与日志恰恰要写那里。两者是不同身份，见 workspace.py 的模块说明。

**为什么复制原稿而不是引用原地**：一个带着对话历史的项目，因为用户挪了
或删了源文件就打不开，是很恶劣的体验。多占一份空间换取项目自包含。

**为什么不放 var/**：var/ 在本项目的文档里被定义为「整个删掉也不影响代码」，
`make clean` 会清里面的东西。对话历史不是可丢弃的运行期产物。
"""

from __future__ import annotations

import hashlib
import json
import logging
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
from .conversations import (
    CONVERSATION_EVENTS,
    CONVERSATIONS_DIR,
    is_valid_id,
    new_id as new_conversation_id,
    summarise,
)
from .workspace import CONTROL_DIR, FILES_DIR, MD_DIR, PDF_DIR, SKELETON

logger = logging.getLogger("scivane.projects")

#: 项目根。真正的配置在 config.PROJECTS_DIR，这里只是个别名 ——
#: 「配置只在 config.py 一处」是本项目的既定纪律。
DEFAULT_PROJECTS_ROOT = config.PROJECTS_DIR

#: 升级前的备份目录叫 `<id>.backup-<时间戳>`。
#: 点号不在合法 id 的字符集里，所以它永远不会被当成项目 —— list_all 也据此跳过。
BACKUP_MARK = ".backup-"

#: OCR 产出的 Markdown 里的插图路径，形如 /assets/<job>/page-1/img_0.png
_OCR_ASSET = re.compile(r"/assets/[A-Za-z0-9_\-/]+?/[^\s\"'<>)\]]+")

#: 用户上传的 Markdown 里的本地图片引用（行内、引用式、HTML 三种写法）
_LOCAL_IMAGE_PATTERNS = (
    re.compile(r"!\[[^\]]*\]\(\s*<?([^)\n]+?)>?\s*\)"),
    re.compile(r"(?m)^\s*\[[^\]]+\]:\s*<?([^\s\n]+)>?\s*$"),
    re.compile(r"""(?i)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"""),
)


def now() -> str:
    """时间戳精确到毫秒。

    秒级精度不够：连着建几个项目会落在同一秒，列表排序就变成任意的。
    """
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
    """粗估 token 数，用来在界面上告诉用户「这篇论文有多大」。"""
    cjk = sum(1 for ch in text if "一" <= ch <= "鿿" or "぀" <= ch <= "ヿ")
    return cjk + (len(text) - cjk) // 4


class ProjectError(Exception):
    """项目操作失败。带一个稳定 code，路由层据此选状态码。"""

    def __init__(self, message: str, code: str = "PROJECT_ERROR") -> None:
        super().__init__(message)
        self.code = code


class ProjectStore:
    """项目的增删查改。进程内单例见模块底部。"""

    def __init__(self, root: Path | None = None) -> None:
        self._root = root if root is not None else DEFAULT_PROJECTS_ROOT
        #: 日志文件路径 → 下一条事件的 seq。
        #:
        #: **按路径而不是按 project_id 缓存**：v3 之后一个项目有多份日志
        #: （生命周期一份、每条对话一份），按项目缓存会让它们共用一个计数器，
        #: 各文件的 seq 于是变得跳跃且相互干扰。
        #:
        #: 不缓存的话每次追加都要重扫整份日志算 seq，实测 50 条 0.09 ms/条、
        #: 200 条 0.14、400 条 0.21 —— 明显在涨。工具调用把事件频率翻了一倍
        #: 以上（一次调用两条事件），这条从「无所谓」变成了必须修。
        self._next_seq: dict[str, int] = {}

    @property
    def root(self) -> Path:
        return self._root

    # --- 路径 ---------------------------------------------------------

    def dir_for(self, project_id: str) -> Path:
        """项目目录。顺带挡掉用 id 做目录穿越。"""
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", project_id):
            raise ProjectError(ui(f"非法的项目 id：{project_id!r}",
                                  f"Invalid project id: {project_id!r}"), "INVALID_ID")
        return self._root / project_id

    def control_dir(self, project_id: str) -> Path:
        """控制面目录。元数据、日志、策略都在这里，agent 看不见。"""
        return self.dir_for(project_id) / CONTROL_DIR

    def _dual(self, project_id: str, new: Path, legacy: Path) -> Path:
        """新布局优先，回落到旧布局。

        升级**之前**也要能读到这些文件 —— list 与 stat 只读头部、不触发升级
        （列表与 stat 只读头部、不发布后继），所以访问器必须
        同时认得两种布局。都不存在时返回新位置，让写入落在新布局上。
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
        """项目生命周期日志。

        v3 之后这里**只剩生命周期事件**（建项目、改名、换正文、升布局）；
        提问、回答、工具调用都在对话文件里。分界线见 conversations.py。
        """
        return self._dual(
            project_id,
            self.control_dir(project_id) / "session.jsonl",
            self.dir_for(project_id) / "session.jsonl",
        )

    def conversations_dir(self, project_id: str) -> Path:
        return self.control_dir(project_id) / CONVERSATIONS_DIR

    def conversation_path(self, project_id: str, conversation_id: str) -> Path:
        """一条对话的日志文件。

        id 先过 `is_valid_id` —— 它来自 HTTP 查询参数，不校验的话
        `../../` 就能把追加写引到项目目录之外。与 `dir_for` 是同一道防线。
        """
        if not is_valid_id(conversation_id):
            raise ProjectError(ui(f"非法的对话 id：{conversation_id!r}",
                                  f"Invalid conversation id: {conversation_id!r}"),
                               "INVALID_CONVERSATION")
        return self.conversations_dir(project_id) / f"{conversation_id}.jsonl"

    # --- 读写元数据 ---------------------------------------------------

    def _write_meta(self, project: Project) -> None:
        project.updated_at = now()
        path = self._meta_path(project.id)
        path.parent.mkdir(parents=True, exist_ok=True)
        # 原子写：崩在半路也不会留下一个解析不了的 project.json
        temporary = path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(project.as_dict(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temporary.replace(path)

    def get(self, project_id: str, *, migrate: bool = True) -> Project:
        """读一个项目。

        **「打开」就是升级的时机**，所以默认顺带把布局升到最新。
        `migrate=False` 留给只读头部的场景（list / stat）—— 它绝不改磁盘，
        也就绝不会在列个目录时触发一串目录复制：只有真正打开项目时才升级。
        """
        project = self._read_meta(project_id)
        if migrate and project.layout < LAYOUT_VERSION:
            return self.ensure_layout(project_id)
        return project

    def _read_meta(self, project_id: str) -> Project:
        """只读元数据，绝不碰磁盘结构。"""
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
        """列出全部项目，最近更新的在前。

        单个项目损坏只跳过它，不连累其它 —— 一个坏掉的 project.json
        不该让整个项目列表打不开。
        """
        if not self._root.is_dir():
            return []
        projects: list[Project] = []
        for entry in self._root.iterdir():
            if not entry.is_dir() or BACKUP_MARK in entry.name:
                continue    # 升级备份不是项目
            try:
                # 列表只读头部，不升级 —— 否则开一次列表就会把所有项目整体复制一遍
                projects.append(self.get(entry.name, migrate=False))
            except ProjectError:
                logger.warning("跳过损坏的项目目录：%s", entry.name)
        # id 做次级键，保证时间相同时次序仍然确定
        projects.sort(key=lambda p: (p.updated_at, p.id), reverse=True)
        return projects

    def find_by_source(self, source_sha256: str) -> Project | None:
        """按原稿内容找已有项目，避免同一篇论文被重复构建。

        空摘要一律不匹配：空项目的 `source_sha256` 就是空串，不挡这一下的话
        「按内容找」会把第一个空项目当成任何东西的重复。
        """
        if not source_sha256:
            return None
        for project in self.list_all():
            if project.source_sha256 == source_sha256:
                return project
        return None

    # --- 会话日志 -----------------------------------------------------

    def append_event(
        self,
        project_id: str,
        kind: str,
        data: dict[str, Any] | None = None,
        *,
        conversation: str | None = None,
    ) -> None:
        """往 append-only 日志里追加一条。

        `conversation` 决定落哪个文件：给了就写那条对话，没给就写项目
        生命周期日志。**调用方不需要自己判断事件属于哪一类** ——
        谁在写谁知道自己在哪条对话里（`StoreJournal` 带着 id），
        而生命周期那几处本来就不属于任何对话。

        凡是会改变模型可见内容的事都要留痕。读回来重建模型历史是 `projects/session.py` 的
        `derive_messages()`。

        **`seq` 是参考值，不是主键；文件里的行序才是权威。** 用 `"a"` 模式打开
        即 `O_APPEND`，所以多个进程各自追加不会把彼此的行写坏；但它们各算的
        seq 可能撞号。撞号无害，因为没有任何消费者按 seq 索引 ——
        `derive_messages()` 只看顺序，界面也只按顺序渲染。真要做成全局唯一
        就得引入锁文件，对「一个本地 App 读一篇论文」这个场景是纯负担。
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
        """取下一个 seq，首次访问时从文件尾部恢复。

        从尾部恢复而不是数行数：数行数是 O(n)，恢复才是这次优化的重点。
        尾部那几行解析不出 seq（写了一半被 kill、旧格式）时退回数行数 ——
        这是慢路径，但只在日志确实坏了的时候走一次。
        """
        key = str(path)
        cached = self._next_seq.get(key)
        if cached is None:
            cached = self._recover_seq(path)
        self._next_seq[key] = cached + 1
        return cached

    @staticmethod
    def _recover_seq(path: Path) -> int:
        """从日志尾部读出最后一条的 seq，返回「下一条该用的 seq」。"""
        if not path.is_file():
            return 1
        try:
            size = path.stat().st_size
            with path.open("rb") as handle:
                # 只读尾部：一条事件再长也就几十 KB，64 KB 足够覆盖最后几条
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
                continue  # 坏行跳过，与 events() 的取舍一致
            if isinstance(seq, int):
                return seq + 1
        # 尾部一条都解析不出来：退回数行数（慢路径，只在日志坏了时走）
        return sum(1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
                   if line.strip()) + 1

    def events(
        self, project_id: str, *, conversation: str | None = None
    ) -> Iterator[dict[str, Any]]:
        """按顺序读出日志。坏行跳过，不让一行脏数据毁掉整份历史。

        `conversation` 给了就读那条对话，没给就读项目生命周期日志。
        """
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

    # --- 对话 ---------------------------------------------------------
    #
    # 一个项目可以有多条对话，各自一个 .jsonl。为什么这么存见
    # conversations.py 的模块说明。这里只做增删查与「取当前这条」。

    def list_conversations(self, project_id: str) -> list[dict[str, Any]]:
        """列出这个项目的全部对话，最近活动的在前。

        标题、条数、时间全部从文件本身算出来，**没有索引文件** ——
        索引与文件不同步的那一刻，用户看到的列表就是错的。
        """
        directory = self.conversations_dir(project_id)
        if not directory.is_dir():
            return []
        found: list[dict[str, Any]] = []
        for entry in sorted(directory.glob("*.jsonl")):
            conversation_id = entry.stem
            if not is_valid_id(conversation_id):
                continue        # 不是我们写的文件，别当成对话
            found.append(
                summarise(conversation_id, list(self.events(project_id, conversation=conversation_id)))
            )
        # 空对话没有事件、也就没有 updated_at，用 id 兜底 ——
        # id 本身带着可排序的时间戳（见 conversations.new_id）
        found.sort(key=lambda c: (c["updated_at"] or c["id"], c["id"]), reverse=True)
        return found

    def create_conversation(self, project_id: str, title: str = "") -> dict[str, Any]:
        """开一条新对话。

        **立刻落盘**（写一条 `conversation/created`）而不是等第一句话 ——
        界面要在用户打字之前就拿到 id，否则「新对话」这个按钮点完什么都没发生。
        """
        self.get(project_id, migrate=False)      # 项目不存在就直接报错
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
        """给对话改个名字。走事件而不是回头改文件头 —— 日志是 append-only 的。"""
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
        """这条对话改用哪张模型卡。

        **不校验这个 provider 存不存在** —— 校验属于发问那一刻（那时才需要它
        真能用），而这里记的是用户的选择。卡片被删掉之后重新打开旧对话，
        界面会发现它指向一张不存在的卡，回落到默认并提示，比在这里拒绝写入
        更接近用户预期：他的选择不该因为另一件事失效而被悄悄改掉。
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
        """删掉一条对话。

        **只删这一个文件**，项目的正文、原稿与其它对话都不受影响 ——
        这正是一条对话一个文件换来的好处。
        """
        path = self.conversation_path(project_id, conversation_id)
        if not path.is_file():
            return False
        path.unlink()
        self._next_seq.pop(str(path), None)
        return True

    def latest_conversation(self, project_id: str) -> str | None:
        """最近活动的那条对话。一条都没有时返回 None。"""
        found = self.list_conversations(project_id)
        return found[0]["id"] if found else None

    def ensure_conversation(self, project_id: str, conversation_id: str | None = None) -> str:
        """把「要写哪条对话」定下来。

        三种情况：指定了就用它（但必须真的存在，否则一个手滑的 id
        会凭空造出一条对话）；没指定就用最近那条；一条都没有就新建。

        **这是所有写入口的必经之路**，所以「对话文件从不凭空出现」
        这条保证只需要在这里成立一次。
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
        """把一条对话整理成可导出的 JSON 文档。

        导出的是**原始事件**而不是渲染好的文字：事件流是权威记录，
        由它能重建模型历史与界面记录两种投影（`session.py` 的两个函数），
        反过来则不行。带上项目与对话的头部信息，让这个文件离开本机之后
        仍然自解释。

        **不含任何凭据** —— 工具参数里从来没有 API key（模型层的凭据走
        credentials.py，从不经过工具），这一条有测试钉着。
        """
        project = self.get(project_id, migrate=False)
        path = self.conversation_path(project_id, conversation_id)
        if not path.is_file():
            raise ProjectError(ui(f"没有这条对话：{conversation_id}",
                                  f"No such conversation: {conversation_id}"), "NO_CONVERSATION")
        events = list(self.events(project_id, conversation=conversation_id))
        return {
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

    # --- 布局升级 -----------------------------------------------------
    #
    # 只做**相邻**升级（vN → vN+1），跨版本靠把相邻步骤串起来。这样每一步
    # 都能单独测，也不会出现「从 v1 直接跳 v5」那种没人验证过的路径。
    # 每一步都单独迁移并记录，失败时可以恢复原布局。

    def _ensure_policy(self, project_id: str) -> None:
        """写一份默认策略文件。

        刻意**不**把 workspace.py 的分层规则镜像进来 —— 两处同一个事实必然漂移，
        而漂移的那份如果被当成权威，边界就形同虚设。这里只放项目专属的覆盖项，
        当前还没有。
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
        """把整个项目目录复制一份到同级。这是唯一的回滚来源。"""
        directory = self.dir_for(project_id)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f")
        backup = self._root / f"{project_id}{BACKUP_MARK}{stamp}"
        shutil.copytree(directory, backup)
        return backup

    def _restore(self, project_id: str, backup: Path) -> None:
        """从备份整体恢复。失败绝不能留下半个升级过的目录。"""
        directory = self.dir_for(project_id)
        shutil.rmtree(directory, ignore_errors=True)
        shutil.copytree(backup, directory)

    def ensure_layout(self, project_id: str) -> Project:
        """把项目升级到当前布局版本。已经是最新就原样返回（幂等）。

        每一步升级前先整体备份，任何一步抛错都回滚到备份。**备份不删** ——
        结构迁移之后自动清掉用户数据是最容易让人追悔的那类操作，
        路径记在 `layout/migrated` 事件里，将来可以由界面提供清理。
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
                # 升级没有推进版本号，再循环就是死循环
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
        """扁平布局 → 工作区骨架。"""
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

        # md/assets 已经由骨架建出来了，所以要逐项搬进去而不是整目录覆盖
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
        """一条会话日志 → 生命周期 + 独立对话。

        把 `session.jsonl` 按 `CONVERSATION_EVENTS` 分成两半：属于谈话的
        整体搬进 `conversations/<新 id>.jsonl`，其余留在原地。

        三个刻意的做法：

        - **搬的是原始行，不是解析后重新序列化的结果。** 重新 dump 会改动
          键序与空白，日志就不再逐字节等于当时写下的样子了。
        - **解析不出来的行留在生命周期日志里。** 分不了类的数据宁可留着
          （读的时候本来就会跳过），也不要在一次迁移里丢掉用户的东西。
        - **原来就没有谈话事件的项目不建空对话文件。** 从没聊过的项目
          升级完应该是「零条对话」，而不是凭空多出一条空的。
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
                    lifecycle.append(line)   # 坏行留着，不在迁移里丢数据
                    continue
                (talk if kind in CONVERSATION_EVENTS else lifecycle).append(line)

        if talk:
            conversations = control / CONVERSATIONS_DIR
            conversations.mkdir(parents=True, exist_ok=True)
            conversation_id = new_conversation_id()
            # 头一条 `conversation/created` 的时间取被搬的第一条事件，
            # 这样「这条对话什么时候开始的」是真的，而不是迁移那一刻
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
        # 文件被整体改写了，缓存的 seq 不再对应它的尾部
        self._next_seq.pop(str(log), None)

        meta = control / "project.json"
        raw = json.loads(meta.read_text(encoding="utf-8"))
        raw["layout"] = 3
        meta.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")

    #: 布局版本 → 把它升到下一版的方法名。
    #:
    #: 存**名字**而不是函数对象：类体里直接引用函数会在定义时就把它捕获，
    #: 之后子类覆盖或测试替换都影响不到这张表，排查起来很费时间。
    _MIGRATIONS = {1: "_migrate_v1_to_v2", 2: "_migrate_v2_to_v3"}

    # --- 创建与删除 ---------------------------------------------------

    def create(self, source: Path) -> Project:
        """从一份原稿构建项目。复制原稿，快猜标题，写元数据。"""
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
            # 建到一半失败不留半个项目在列表里
            shutil.rmtree(directory, ignore_errors=True)
            raise

        self.append_event(project_id, ProjectEvent.CREATED, {
            "title": project.title,
            "title_source": project.title_source,
            "source_name": project.source_name,
        })
        return project

    #: 没起名字的空项目叫什么。配 `title_source="placeholder"`，
    #: 意思是「这不是谁给的名字」—— 之后导入原稿时任何提取都可以改进它。
    UNTITLED = "未命名项目"

    def create_empty(self, title: str = "") -> Project:
        """建一个还没有原稿的空项目。

        **为什么允许没有原稿**：论文项目不总是从一份 PDF 开始的。先建个
        项目放笔记、放代码、先和 agent 聊清楚要找什么，之后再把 PDF 放进来，
        是真实存在的用法。原稿可以事后用 `attach_source` 挂上。

        **名字留空与打了字是两回事**（红线：用户手动改过的名字不许被覆盖）：

        - 打了字 → `manual`，排在最顶上，此后任何自动提取都不许覆盖它
        - 留空   → `placeholder`，排在最底下，导入原稿或跑完 OCR 时会被改进

        这样「项目名用户自定义」与「导入 PDF 后识别成项目名」两件事
        同时成立，而且不互相打架。
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
        """给一个空项目挂上原稿，并顺势精确化标题。

        **只对还没有原稿的项目开放。** 换掉一篇已有原稿意味着正文、插图、
        既往对话引用的一切都不再对应它 —— 那是另一件事，不该由这个入口
        顺手做掉。

        标题走的是和建项目时同一条 `better_than` 规则：placeholder 会被
        PDF 里提取出来的名字改进，用户手打的 manual 则原样保留。
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

    # --- 用户上传的材料 -----------------------------------------------

    #: 一份上传文件的大小上限。超过这个数放进项目只会让目录变笨重，
    #: 而 agent 也读不完 —— 真要处理大数据集，让它自己在沙箱里生成更合适。
    MAX_UPLOAD_BYTES = 64 * 1024 * 1024

    def files_dir(self, project_id: str) -> Path:
        return self.dir_for(project_id) / FILES_DIR

    def add_file(self, project_id: str, source: Path) -> dict[str, Any]:
        """把用户拖进来的一个文件复制进 `files/`。

        **复制而不是引用**，和原稿同一个道理：项目要自包含，用户挪走或删掉
        原文件之后这个项目还得能打开。

        重名不覆盖，加 `-2`、`-3` 的后缀 —— 上传是个随手动作，
        悄悄覆盖掉上一份是最容易让人追悔的那类行为。
        """
        self.get(project_id)                 # 项目不存在就直接报错
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

        target_dir = self.files_dir(project_id)
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / _safe_name(source.name)
        stem, suffix = target.stem, target.suffix
        serial = 2
        while target.exists():
            target = target_dir / f"{stem}-{serial}{suffix}"
            serial += 1
        shutil.copy2(source, target)

        self.append_event(project_id, ProjectEvent.FILE_ADDED, {
            "name": target.name, "bytes": size, "origin": source.name,
        })
        return {
            "name": target.name,
            "path": f"{FILES_DIR}/{target.name}",
            "bytes": size,
        }

    def list_files(self, project_id: str) -> list[dict[str, Any]]:
        """`files/` 里有什么。最近放进来的在前。"""
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
        """删掉一份上传的材料。名字要过一遍消毒，它来自 HTTP 路径参数。"""
        safe = _safe_name(name)
        if safe != name:
            raise ProjectError(ui(f"非法的文件名：{name!r}", f"Invalid file name: {name!r}"),
                               "INVALID_NAME")
        target = self.files_dir(project_id) / safe
        if not target.is_file():
            return False
        target.unlink()
        return True

    def delete(self, project_id: str) -> bool:
        directory = self.dir_for(project_id)
        resolved = directory.resolve()
        root = self._root.resolve()
        # 绝不让一次删除跑到项目根之外
        if resolved == root or not resolved.is_relative_to(root):
            raise ProjectError(ui("拒绝删除项目根之外的路径",
                                  "Refusing to delete a path outside the projects root"), "INVALID_ID")
        if not directory.is_dir():
            return False
        shutil.rmtree(directory, ignore_errors=True)
        # 备份是为了升级失败能回滚；项目都删了，留着它们只会变成孤儿
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
        """OCR 完成后用 Markdown 的一级标题精确化名字。

        只在**更可靠**时才覆盖：用户手动改过的名字，任何自动提取都不许动。
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

    # --- 上下文 -------------------------------------------------------

    def set_context(
        self,
        project_id: str,
        markdown: str,
        *,
        origin: ContextOrigin,
        job_id: str | None = None,
        jobs_root: Path | None = None,
        source_dir: Path | None = None,
    ) -> Project:
        """替换项目的静态上下文。

        「重新 OCR 覆盖」与「上传文件覆盖」走的是同一个入口 —— 两者的差别
        只在 `origin`，以及由此决定的是否需要人工确认。

        插图会被一并吸收进项目目录并改写成相对路径，这样项目自包含：
        清掉 var/jobs 或挪走源目录都不会让正文里的图失效。
        """
        project = self.get(project_id)
        directory = self.dir_for(project_id)
        assets_dir = directory / MD_DIR / "assets"
        assets_dir.parent.mkdir(parents=True, exist_ok=True)

        # 先写到临时目录，成功了再换上去。中途失败不该毁掉已有的上下文。
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
            # OCR 的结果就是从这份原稿扫出来的，无需确认；
            # 上传的文件未必对应这篇论文，必须由人点头。
            confirmed=origin == "ocr",
            job_id=job_id,
        )
        self._write_meta(project)
        self.append_event(project_id, ProjectEvent.CONTEXT_REPLACED, {
            "origin": origin,
            "sha256": project.context.sha256,
            "chars": project.context.chars,
            "tokens": project.context.tokens,
            "confirmed": project.context.confirmed,
            "job_id": job_id,
        })

        if origin == "ocr":
            project = self.maybe_improve_title(project_id, absorbed)
        return project

    def confirm_context(self, project_id: str, accepted: bool) -> Project:
        """人工确认上传的 Markdown 是否对应这篇论文。"""
        project = self.get(project_id)
        if project.context is None:
            raise ProjectError(ui("这个项目还没有上下文", "This project has no text yet"), "NO_CONTEXT")
        if accepted:
            project.context.confirmed = True
            self._write_meta(project)
            self.append_event(project_id, ProjectEvent.CONTEXT_CONFIRMED, {})
            return project
        # 拒绝就把它整个撤掉，不留一份没人认账的正文在项目里
        self.context_path(project_id).unlink(missing_ok=True)
        shutil.rmtree(self.dir_for(project_id) / "assets", ignore_errors=True)
        project.context = None
        self._write_meta(project)
        self.append_event(project_id, ProjectEvent.CONTEXT_REJECTED, {})
        return project

    def read_context(self, project_id: str) -> str:
        path = self.context_path(project_id)
        if not path.is_file():
            raise ProjectError(ui("这个项目还没有上下文", "This project has no text yet"), "NO_CONTEXT")
        return path.read_text(encoding="utf-8")

    # --- 插图吸收 -----------------------------------------------------

    def _absorb_assets(
        self,
        markdown: str,
        assets_dir: Path,
        *,
        jobs_root: Path | None,
        source_dir: Path | None,
    ) -> str:
        """把正文引用的本地图片复制进项目，并改写成相对路径。

        改写成相对路径之后，项目目录本身就是完整的：拷走、备份、日后换台
        机器打开都不会缺图。
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
            return f"assets/{relative_name}"

        # 1) OCR 产出的 /assets/<job>/... 引用
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

        # 2) 用户上传的 Markdown 里的相对图片
        if source_dir is not None:
            candidates: set[str] = set()
            for pattern in _LOCAL_IMAGE_PATTERNS:
                for match in pattern.finditer(markdown):
                    raw = match.group(1).split(' "')[0].strip("<>").strip()
                    if not raw or raw.startswith("/assets/"):
                        continue
                    if re.match(r"^[a-z][a-z0-9+.-]*:", raw, re.IGNORECASE):
                        continue        # http(s)/data: 之类，不碰
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
        # 长的先替换，避免短引用是长引用前缀时把长的截坏
        for old in sorted(replacements, key=len, reverse=True):
            rewritten = rewritten.replace(old, replacements[old])
        return rewritten


def _safe_name(name: str) -> str:
    """把一个上传文件名压成安全的单段名字。

    只保留 basename 并挡掉分隔符与点开头 —— 名字来自用户的文件系统，
    也会经由 HTTP 路径参数回来，两条路都不能让它拼出 `files/` 之外的位置。
    """
    cleaned = re.sub(r"[/\\\x00]", "_", Path(name).name).strip()
    cleaned = cleaned.lstrip(".") or "file"
    return cleaned[:120]


def _safe_join(base: Path, relative: str) -> Path | None:
    """把相对路径接到 base 上，挡掉目录穿越与符号链接越界。"""
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


#: 进程内单例。与 jobs.py 的 `jobs`、llm 的 `registry` 同一模式。
projects = ProjectStore()
