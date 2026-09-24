"""项目内的文件工具：read / write / edit / glob / grep。

**五个工具一条入口**：全部走 `projects/workspace.py` 的 `resolve()`，
没有任何一个自己拼路径。那个函数是 agent 侧文件访问的唯一边界 ——
一旦这里有第二条路，边界就只在其中一条上成立，而漏掉的那条不会报错。

越界一律拒绝，**绝不静默截断回项目内**：把路径悄悄夹回来会让 agent 以为
自己写成功了，实际写去了别处。拒绝的错误文本会作为结果交回模型，
模型看到「越界」通常下一轮就改对了。

`notes/` 的写入需要用户确认，这条由 `resolve()` 判定，确认状态从
`ToolContext.confirmed` 里来 —— 按调用携带，和沙箱策略同一个路子。
"""

from __future__ import annotations

import asyncio
import difflib
import re
from pathlib import Path

from ..projects import workspace
from .definition import (
    UNLIMITED_RESULT,
    ToolContext,
    ToolDef,
    ToolError,
    ToolOutcome,
)

__all__ = ["file_tools", "READ_MAX_LINES", "GREP_MAX_HITS", "DIFF_MAX_LINES"]

#: `read` 自己的上限。它是「自带上限」那类工具，所以结果不落盘
#: （落盘会造成读文件又读回自己的循环，见 results.py）。
READ_MAX_LINES = 2_000
GREP_MAX_HITS = 200
#: 单个文件读取上限。论文正文十万 token 也就几百 KB，超过这个数的八成是
#: 二进制或日志，整块读进上下文没有意义。
READ_MAX_BYTES = 2_000_000


def _root(context: ToolContext) -> Path:
    if context.project_dir is None:
        raise ToolError("这一层 agent 没有项目目录，用不了文件工具", "NO_PROJECT")
    return Path(context.project_dir)


def _resolve(context: ToolContext, raw: object, *, write: bool = False) -> Path:
    """解析并检查一个 agent 给的路径。

    `WorkspaceError` 带稳定 code（OUT_OF_BOUNDS / READ_DENIED / WRITE_DENIED /
    NEEDS_CONFIRMATION），原样转成 `ToolError` —— 码不变，上层与模型都据码判断。
    """
    if not isinstance(raw, str) or not raw.strip():
        raise ToolError("path 必须是非空字符串", "INVALID_ARGS")
    root = _root(context)
    top = Path(raw).parts[0] if Path(raw).parts else ""
    try:
        return workspace.resolve(
            root, raw, write=write, confirmed=top in context.confirmed
        )
    except workspace.WorkspaceError as exc:
        raise ToolError(str(exc), exc.code) from exc


async def _read(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    target = _resolve(context, arguments.get("path"))
    if not target.is_file():
        raise ToolError(f"不是文件或不存在：{arguments.get('path')}", "NOT_FOUND")
    if target.stat().st_size > READ_MAX_BYTES:
        raise ToolError(
            f"文件有 {target.stat().st_size} 字节，超过 {READ_MAX_BYTES} 上限 —— "
            "用 grep 定位，或用 bash 取其中一段",
            "TOO_LARGE",
        )
    try:
        text = target.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ToolError(f"读不了：{exc.strerror}", "IO_ERROR") from exc

    lines = text.splitlines()
    offset = _as_int(arguments.get("offset"), 0)
    limit = _as_int(arguments.get("limit"), READ_MAX_LINES)
    window = lines[offset : offset + min(limit, READ_MAX_LINES)]
    # 带行号 —— edit 要靠它定位，模型引用正文时也需要说得出位置
    body = "\n".join(f"{offset + i + 1:>6}\t{line}" for i, line in enumerate(window))
    more = len(lines) - (offset + len(window))
    if more > 0:
        body += f"\n\n[还有 {more} 行未显示，用 offset={offset + len(window)} 继续]"
    return ToolOutcome(body or "[空文件]", detail={"lines": len(lines)})


#: 一次改动最多回传多少行 diff。
#:
#: 这不是省流量，是**护界面**：`write` 覆盖一份两万行的正文时，全量 diff
#: 会让对话流里塞进两万行、每行一个 Text —— 那正是把主线程占满的那条路
#: （见 Swift 侧 `ActivityCard.detail` 的实测表）。超出就截断并标明。
DIFF_MAX_LINES = 400
#: 改动前后各留几行上下文。三行是 `diff -u` 的默认值，够认出位置又不喧宾夺主。
DIFF_CONTEXT = 3


def _diff(before: str, after: str, path: str) -> dict[str, object]:
    """把一次改动译成**给界面画的**结构化 diff。

    为什么不直接给 unified diff 文本：那样界面只能当成一段等宽文字贴上去，
    行号、增删着色、折叠都做不了。拆成 `(kind, old_no, new_no, text)` 之后，
    渲染端才有东西可画，界面可以据此显示行号、增删和折叠。

    只带**变化附近**的行（前后各 `DIFF_CONTEXT` 行）。整文件回传的话，
    改一个字也要传一整份正文，而用户想看的从来只是变了什么。
    """
    old_lines = before.splitlines()
    new_lines = after.splitlines()
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)

    rows: list[dict[str, object]] = []
    added = removed = 0
    truncated = False

    def push(kind: str, old_no: int | None, new_no: int | None, text: str,
             skipped: int | None = None) -> bool:
        """返回 False 表示已经到顶，别再加了。"""
        nonlocal truncated
        if len(rows) >= DIFF_MAX_LINES:
            truncated = True
            return False
        row: dict[str, object] = {"kind": kind, "old": old_no, "new": new_no, "text": text}
        if skipped is not None:
            # 这一行只给界面看。工具执行期语言钉在中文，`text` 因而总是中文 ——
            # 带上数字，界面按自己的语言说；`text` 留给日志与不认这个字段的旧界面
            row["skipped"] = skipped
        rows.append(row)
        return True

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            span = i2 - i1
            # 只留贴着改动的那几行：块很短就整段留下，长了就掐头去尾
            keep: list[int] = []
            if span <= DIFF_CONTEXT * 2:
                keep = list(range(i1, i2))
            else:
                keep = list(range(i1, i1 + DIFF_CONTEXT)) + list(range(i2 - DIFF_CONTEXT, i2))
            previous = None
            for index in keep:
                if previous is not None and index != previous + 1:
                    skipped = index - previous - 1
                    if not push("gap", None, None, f"… 略过 {skipped} 行", skipped=skipped):
                        break
                if not push("same", index + 1, index - i1 + j1 + 1, old_lines[index]):
                    break
                previous = index
            continue
        for index in range(i1, i2):
            removed += 1
            if not push("remove", index + 1, None, old_lines[index]):
                break
        for index in range(j1, j2):
            added += 1
            if not push("add", None, index + 1, new_lines[index]):
                break

    return {
        "path": path,
        "rows": rows,
        "added": added,
        "removed": removed,
        "truncated": truncated,
    }


async def _write(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    target = _resolve(context, arguments.get("path"), write=True)
    content = arguments.get("content")
    if not isinstance(content, str):
        raise ToolError("content 必须是字符串", "INVALID_ARGS")
    existed = target.is_file()
    # 覆盖之前先读一份 —— 界面要画的是「变了什么」，而不是「现在是什么」。
    # 读失败不该让写失败：diff 是附加信息，不是这次调用的目的。
    before = ""
    if existed:
        try:
            before = target.read_text(encoding="utf-8", errors="replace")
        except OSError:
            before = ""
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    except OSError as exc:
        raise ToolError(f"写不了：{exc.strerror}", "IO_ERROR") from exc
    verb = "覆盖" if existed else "新建"
    relative = target.relative_to(_root(context))
    change = _diff(before, content, str(relative))
    return ToolOutcome(
        f"已{verb} {relative}（{len(content)} 字，+{change['added']} −{change['removed']}）",
        detail={"path": str(relative), "overwrote": existed, "diff": change},
    )


async def _edit(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    target = _resolve(context, arguments.get("path"), write=True)
    old = arguments.get("old_text")
    new = arguments.get("new_text")
    if not isinstance(old, str) or not isinstance(new, str):
        raise ToolError("old_text 与 new_text 都必须是字符串", "INVALID_ARGS")
    if not target.is_file():
        raise ToolError(f"不存在：{arguments.get('path')}", "NOT_FOUND")
    text = target.read_text(encoding="utf-8", errors="replace")
    hits = text.count(old)
    if hits == 0:
        raise ToolError("old_text 在文件里找不到 —— 先 read 确认原文", "NO_MATCH")
    every = arguments.get("replace_all") is True
    if hits > 1 and not every:
        # **默认只改唯一的那一处。** 审校正文时「改掉所有同样的串」多数时候
        # 是错的，而错了之后很难发现改坏了哪里。
        #
        # 但错误消息必须给出**两条**出路。早先只说「多带一些上下文」，
        # 模型遇到「整篇都拼错的术语」这种本该全量替换的情况就没路可走，
        # 于是转头去 reocr 重跑整页 —— 代价大三个数量级，而且会覆盖掉
        # 用户手工修过的行。实机报过这个。
        raise ToolError(
            f"old_text 出现了 {hits} 次，不唯一。两条路："
            f"要改的只是其中一处就多带几行上下文让它唯一；"
            f"这 {hits} 处本来就该一起改（比如一个从头错到尾的术语）"
            f"就加上 replace_all=true。",
            "NOT_UNIQUE",
        )
    after = text.replace(old, new) if every else text.replace(old, new, 1)
    target.write_text(after, encoding="utf-8")
    relative = target.relative_to(_root(context))
    change = _diff(text, after, str(relative))
    changed = hits if every else 1
    return ToolOutcome(
        f"已改 {relative}（{changed} 处，+{change['added']} −{change['removed']}）",
        detail={"path": str(relative), "diff": change, "occurrences": changed},
    )


def normalise_glob(pattern: str) -> str:
    """把 `**` 翻成 pathlib 听得懂的样子。

    **实机踩过（2026-09-21）。** 模型写 `glob("code/**")` 想列出 `code/` 下所有文件，
    拿到「没有匹配」，于是告诉用户「`code/` 是空的」—— 而那里躺着一个 11 个文件的
    git 克隆。下一步 `fetch_repo` 报 `EXISTS` 才拆穿。

    根因是 **pathlib 的 `**` 只匹配目录**，而这个工具只收 `is_file()`：

        Path.glob("code/**")    → ['code', 'code/SOTER', 'code/SOTER/soter', …]  全是目录
        Path.glob("code/**/*")  → 目录 + 文件

    而模型的直觉来自 bash（开了 globstar）、git、ripgrep —— 那几家的 `code/**`
    **都匹配文件**。工具的语义和模型的直觉对不上时，该改的是工具：
    一个「找文件」的工具，不该在最自然的写法上回答「没有文件」。

    只动末尾那一段 `**`，中间的 `code/**/*.py` 原样不碰。
    """
    cleaned = pattern.rstrip("/")
    if not cleaned:
        return pattern
    return f"{cleaned}/*" if cleaned == "**" or cleaned.endswith("/**") else cleaned


async def _glob(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    # 走一整个 code/ 仓库可能要几百毫秒，别占着事件循环
    return await asyncio.to_thread(_glob_sync, arguments, context)


def _glob_sync(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    root = _root(context)
    pattern = arguments.get("pattern")
    if not isinstance(pattern, str) or not pattern:
        raise ToolError("pattern 必须是非空字符串", "INVALID_ARGS")
    hits: list[str] = []
    #: 匹配上但不是文件的。**空结果时必须把它说出来** —— 「没有匹配」会被读成
    #: 「这个目录是空的」，而那正是实机上误导过模型的那句话。
    folders: list[str] = []
    effective = normalise_glob(pattern)
    for path in sorted(root.glob(effective)):
        try:
            # 每一条都过一遍边界：glob 可能顺着符号链接走到项目外
            workspace.resolve(root, path.relative_to(root))
        except (workspace.WorkspaceError, ValueError):
            continue
        if path.is_file():
            hits.append(str(path.relative_to(root)))
        elif path.is_dir() and path != root:
            folders.append(str(path.relative_to(root)))
    if not hits:
        if folders:
            listed = "、".join(f"{d}/" for d in folders[:8])
            more = f"（共 {len(folders)} 个）" if len(folders) > 8 else ""
            return ToolOutcome(
                f"{pattern} 没匹配到文件，但匹配到目录：{listed}{more}"
                f" —— 目录本身不算文件，要看里面加 `/**/*`。"
            )
        return ToolOutcome(f"没有匹配 {pattern} 的文件，这个位置确实是空的")
    return ToolOutcome("\n".join(hits), detail={"count": len(hits)})


async def _grep(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    # 走一整个 code/ 仓库可能要几百毫秒，别占着事件循环
    return await asyncio.to_thread(_grep_sync, arguments, context)


def _grep_sync(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    root = _root(context)
    pattern = arguments.get("pattern")
    if not isinstance(pattern, str) or not pattern:
        raise ToolError("pattern 必须是非空字符串", "INVALID_ARGS")
    try:
        regex = re.compile(pattern)
    except re.error as exc:
        raise ToolError(f"正则写错了：{exc}", "INVALID_ARGS") from exc

    where = arguments.get("path")
    base = _resolve(context, where) if isinstance(where, str) and where else root
    glob_pattern = arguments.get("glob")
    candidates = (
        # 同 glob 工具：`code/**` 在 pathlib 下只匹配目录，不规范化的话
        # 这里会静默地一个文件都不搜。
        base.glob(normalise_glob(glob_pattern))
        if isinstance(glob_pattern, str) and glob_pattern
        else base.rglob("*")
    )

    lines: list[str] = []
    for path in sorted(candidates):
        if not path.is_file():
            continue
        try:
            workspace.resolve(root, path.relative_to(root))
        except (workspace.WorkspaceError, ValueError):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        relative = path.relative_to(root)
        for number, line in enumerate(text.splitlines(), 1):
            if regex.search(line):
                lines.append(f"{relative}:{number}: {line.strip()[:200]}")
                if len(lines) >= GREP_MAX_HITS:
                    lines.append(f"[命中超过 {GREP_MAX_HITS} 条，已停止 —— 把 pattern 收窄些]")
                    return ToolOutcome("\n".join(lines), detail={"truncated": True})
    if not lines:
        return ToolOutcome(f"没有命中 {pattern}")
    return ToolOutcome("\n".join(lines), detail={"count": len(lines)})


def _as_int(value: object, fallback: int) -> int:
    if isinstance(value, bool):
        return fallback
    if isinstance(value, int) and value >= 0:
        return value
    return fallback


def _string(description: str) -> dict[str, object]:
    return {"type": "string", "description": description}


def file_tools() -> tuple[ToolDef, ...]:
    return (
        ToolDef(
            name="read",
            description=(
                "读项目内一个文件，返回带行号的内容。路径相对项目根。\n\n**论文正文不用读*"
                "* —— `md/context.md` 已经完整地在你的上下文里了，再读一遍只是把同样的内容付两遍钱。"
                "这个工具是用来看**上下文里没有的**东西：`code/` 里的源码、`"
                "workbench/` 里你自己的产物、`notes/`。\n\n要读多个文件就在同一轮里一起发出来，不要读一个等一个。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": _string("相对项目根的路径，如 md/context.md"),
                    "offset": {"type": "integer", "description": "从第几行开始（0 基）"},
                    "limit": {"type": "integer", "description": f"最多读多少行，上限 {READ_MAX_LINES}"},
                },
                "required": ["path"],
            },
            run=_read,
            read_only=True,
            concurrency_safe=True,
            # 自带行数上限，结果绝不落盘 —— 否则就是读文件又读回自己
            max_result_chars=UNLIMITED_RESULT,
        ),
        ToolDef(
            name="write",
            description="把内容整体写进项目内一个文件（覆盖）。pdf/ 与 .lumen/ 不可写。",
            parameters={
                "type": "object",
                "properties": {"path": _string("相对项目根的路径"), "content": _string("完整内容")},
                "required": ["path", "content"],
            },
            run=_write,
            destructive=True,
        ),
        ToolDef(
            name="edit",
            description=(
                "精确替换文件里的一段文本。**改文件就用它** —— "
                "改正文的 OCR 错漏、改代码、改笔记，都是它。\n\n"
                "- **先 `read` 再改。** `old_text` 要和文件里的原文逐字一致，"
                "凭印象写的片段基本对不上。`read` 的输出带行号前缀"
                "（空格 + 行号 + 制表符），**行号前缀不属于文件内容**，"
                "不要抄进 old_text。\n"
                "- `old_text` 取**刚好唯一**的最小片段，通常两三行就够，"
                "不必贴十几行上下文。\n"
                "- 不唯一会拒绝。那时要么多带几行让它唯一，要么加 "
                "`replace_all=true` 把每一处都改掉（一个从头错到尾的术语就该这样）。\n"
                "- 多处要改就在同一轮里发多个 edit，不要一个一个等。\n"
                "- 不要在 bash 里 sed —— 那绕过了边界检查，界面上也看不到改了什么。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": _string("相对项目根的路径"),
                    "old_text": _string("要被替换的原文，逐字一致；默认必须唯一"),
                    "new_text": _string("替换成什么"),
                    "replace_all": {
                        "type": "boolean",
                        "description": "把每一处都替换掉（默认 false，只改唯一的那一处）",
                    },
                },
                "required": ["path", "old_text", "new_text"],
            },
            run=_edit,
        ),
        ToolDef(
            name="glob",
            description=(
                "按通配符列出项目内的文件，如 `code/**/*.py`。\n\n*"
                "*找文件用这个，不要在 bash 里 ls 或 find** —— "
                "这个更快、输出更干净，也不会撞上沙箱拒读 `.lumen/` 产生的噪音。"
            ),
            parameters={
                "type": "object",
                "properties": {"pattern": _string("通配符，相对项目根")},
                "required": ["pattern"],
            },
            run=_glob,
            read_only=True,
            concurrency_safe=True,
        ),
        ToolDef(
            name="grep",
            description=(
                "在项目内按正则搜索，返回 `文件:行号: 内容`。\n\n**搜内容用这个，不要在 "
                "bash 里 grep。** 搜论文正文也不必用它 —— 正文已经在你的上下文里，直接看就行。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "pattern": _string("Python 正则"),
                    "path": _string("只搜这个子目录（可选）"),
                    "glob": _string("只搜匹配这个通配符的文件（可选）"),
                },
                "required": ["pattern"],
            },
            run=_grep,
            read_only=True,
            concurrency_safe=True,
        ),
    )
