"""一个项目里的多条对话。

**为什么一条对话一个文件，而不是在同一份日志里加 `conversation_id` 过滤。**
两条路都能做到「一个项目多条对话」，但代价差很远：

- 同文件加字段：每次投影一条对话都要扫完**所有**对话的事件，
  代价随项目总历史增长；而「删掉一条对话」会变成改写一份 append-only 日志 ——
  那是这一层最不该做的事。
- 一条对话一个文件（当前采用）：投影只读自己那份；删除就是删一个文件；
  导出天然就是「把这个文件交出去」。

代价是 `session.jsonl` 要拆成两半，所以有了布局 v3（见 store.py 的迁移）：

    .lumen/session.jsonl              项目生命周期：建项目、改名、换正文、升布局
    .lumen/conversations/<id>.jsonl   一条对话：提问、回答、工具调用与裁决

**分界线是「这件事属于项目还是属于这次谈话」**，不是「重不重要」。
换正文会影响之后每一条对话，所以它属于项目；某次 grep 只属于发生它的那轮。

**刻意不建索引文件。** 标题、条数、时间全部从对话文件自己算出来 ——
同一个事实只在一处维护是本仓库的纪律，而索引必然要和文件同步，
不同步的那一刻用户看到的列表就是错的。代价是列表要读一遍文件：
单条结果落盘前已被 `tools/results.py` 截到 3 万字，十几条对话也就几 MB、
毫秒级，真慢了再加缓存不迟。
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable

from .model import ProjectEvent

__all__ = [
    "CONVERSATIONS_DIR", "CONVERSATION_EVENTS", "TITLE_CHARS",
    "new_id", "is_valid_id", "derive_title", "summarise",
]

#: 对话文件所在的子目录，在 `.lumen/` 下面 —— 和会话日志一样属于控制面，
#: agent 看不见（workspace.py 的 TIERS 把整个 `.lumen/` 都拒了）。
CONVERSATIONS_DIR = "conversations"

#: 属于「一次谈话」的事件。**这张表是 v3 拆分的唯一依据** ——
#: 迁移按它把老日志分成两半，写入时也按它决定落哪个文件。
#: 不在表里的一律算项目生命周期。
CONVERSATION_EVENTS = frozenset({
    ProjectEvent.CONVERSATION_CREATED,
    ProjectEvent.CONVERSATION_RENAMED,
    ProjectEvent.USER_MESSAGE,
    ProjectEvent.ASSISTANT_MESSAGE,
    ProjectEvent.TOOL_CALL,
    ProjectEvent.TOOL_RESULT,
    ProjectEvent.TOOL_DECISION,
})

#: 自动标题的长度上限。侧栏那一行放不下更多，超出的部分只会被截成省略号。
TITLE_CHARS = 40

#: 合法的对话 id。字符集与项目 id 一致 —— 不含 `.` 与 `/`，
#: 所以它永远不可能拼出一个跑到 `conversations/` 之外的路径。
_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")


def new_id() -> str:
    """生成一个对话 id：可排序的时间戳 + 随机尾巴。

    前缀用 UTC 时间戳而不是纯随机，是为了**按文件名排序就等于按创建时间排序** ——
    列对话时不必先把每个文件都打开读头一条事件。随机尾巴管撞号：
    同一秒内连建两条（点两下「新对话」）靠它区分开。
    """
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    return f"{stamp}-{uuid.uuid4().hex[:6]}"


def is_valid_id(conversation_id: str) -> bool:
    """挡掉用对话 id 做目录穿越。与 `store.dir_for` 是同一道防线。"""
    return bool(conversation_id) and _ID.fullmatch(conversation_id) is not None


def derive_title(events: Iterable[dict[str, Any]]) -> str:
    """这条对话叫什么。

    **默认取第一句提问** —— 人回想一段对话靠的就是「我当时问了什么」，
    而不是一个编号。用户改过名字的话，
    最后一次改名说了算。

    改名走事件而不是回头改文件头：append-only 的日志不该被重写，
    而「什么时候改的名」本身也是历史的一部分。
    """
    renamed = ""
    first_question = ""
    for event in events:
        if not isinstance(event, dict):
            continue
        data = event.get("data")
        if not isinstance(data, dict):
            continue
        kind = event.get("type")
        if kind == ProjectEvent.CONVERSATION_RENAMED:
            title = data.get("title")
            if isinstance(title, str) and title.strip():
                renamed = title.strip()
        elif kind == ProjectEvent.USER_MESSAGE and not first_question:
            text = data.get("text")
            if isinstance(text, str) and text.strip():
                first_question = text.strip()
    if renamed:
        return renamed[:TITLE_CHARS]
    if not first_question:
        return ""
    # 多行提问只取第一行：第二行往后多半是粘贴进来的材料，当标题毫无辨识度
    head = first_question.splitlines()[0].strip()
    return head[:TITLE_CHARS]


def summarise(conversation_id: str, events: list[dict[str, Any]]) -> dict[str, Any]:
    """一条对话在列表里的样子。

    `messages` 只数**用户与助手的消息**，不数工具调用 —— 用户说「这段聊了几轮」
    指的是来回几句，把几十次 grep 算进去只会让这个数字失去意义。
    """
    messages = 0
    created_at = ""
    updated_at = ""
    #: 这条对话最后一次选定的 provider。**没有就是 None** ——
    #: 界面据此回落到全局默认，老对话因此不需要迁移。
    provider: str | None = None
    for event in events:
        if not isinstance(event, dict):
            continue
        at = event.get("at")
        if isinstance(at, str) and at:
            if not created_at:
                created_at = at
            updated_at = at
        if event.get("type") in (ProjectEvent.USER_MESSAGE, ProjectEvent.ASSISTANT_MESSAGE):
            messages += 1
        if event.get("type") == ProjectEvent.CONVERSATION_PROVIDER:
            chosen = (event.get("data") or {}).get("provider")
            if isinstance(chosen, str) and chosen.strip():
                provider = chosen.strip()
    return {
        "id": conversation_id,
        "title": derive_title(events),
        "messages": messages,
        "created_at": created_at,
        "updated_at": updated_at,
        "provider": provider,
    }
