"""File tools inside a project: read / write / edit / glob / grep.

All five go through workspace.resolve(), never building paths themselves. Out-of-bounds paths
are refused, never clamped back into the project (that would report success for a write that
went elsewhere).
"""

from __future__ import annotations

import asyncio
import difflib
import re
from pathlib import Path

from ..projects import workspace
from ..projects.attachments import dimensions, sniff
from .definition import (
    UNLIMITED_RESULT,
    ToolContext,
    ToolDef,
    ToolError,
    ToolOutcome,
)

__all__ = ["file_tools", "READ_MAX_LINES", "GREP_MAX_HITS", "DIFF_MAX_LINES", "SECTION_CHARS"]

#: read limits itself, so its results never spill (see results.py)
READ_MAX_LINES = 2_000
GREP_MAX_HITS = 200
#: a paper's text is a few hundred KB; anything much larger is usually binary or a log
READ_MAX_BYTES = 2_000_000

#: Most a single write should carry. A tool call's arguments are generated before anything is
#: sent; some gateways cut a stream that stays silent for about two minutes, and at the slowest
#: rate measured on one (about 60 characters a second) this much takes under a minute.
SECTION_CHARS = 3000


def _root(context: ToolContext) -> Path:
    if context.project_dir is None:
        raise ToolError("这一层 agent 没有项目目录，用不了文件工具", "NO_PROJECT")
    return Path(context.project_dir)


def _resolve(context: ToolContext, raw: object, *, write: bool = False) -> Path:
    """Resolve and check an agent-supplied path. WorkspaceError codes pass through unchanged as
    ToolError codes.
    """
    if not isinstance(raw, str) or not raw.strip():
        raise ToolError("path 必须是非空字符串", "INVALID_ARGS")
    root = _root(context)
    try:
        return workspace.resolve(root, raw, write=write)
    except workspace.WorkspaceError as exc:
        raise ToolError(str(exc), exc.code) from exc


#: Bytes sniffed to tell binary from text: a NUL in here means binary, as git and ripgrep decide.
SNIFF_BYTES = 8192


def _head(path: Path) -> bytes:
    try:
        with path.open("rb") as handle:
            return handle.read(SNIFF_BYTES)
    except OSError:
        return b""


def _binary(head: bytes) -> bool:
    return sniff(head) is not None or b"\0" in head


def _describe_binary(target: Path, head: bytes, relative: str) -> ToolOutcome:
    """What `read` says about a binary file instead of decoding it.

    Decoded as text, a 235 KB plot came back as 70,000 tokens of mojibake: paid for on every
    later request of the turn, and no use to the model.
    """
    size = target.stat().st_size
    media = sniff(head)
    if media is not None:
        shape = dimensions(head, media)
        pixels = f"，{shape[0]}×{shape[1]} 像素" if shape else ""
        return ToolOutcome(
            f"{relative} 是一张 {media.split('/')[1].upper()} 图片（{size} 字节{pixels}）。"
            "read 只读文本，看不到图里画了什么；要核对一张图，用 python 读它的尺寸、像素或数据，"
            "或者请用户在 Finder 里打开它看。",
            detail={"binary": media, "bytes": size},
        )
    raise ToolError(
        f"{relative} 是二进制文件（{size} 字节），read 只读文本 —— 用 python 或 bash 里合适的工具处理它",
        "BINARY_FILE",
    )


async def _read(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    target = _resolve(context, arguments.get("path"))
    if not target.is_file():
        raise ToolError(f"不是文件或不存在：{arguments.get('path')}", "NOT_FOUND")
    head = _head(target)
    if _binary(head):
        return _describe_binary(target, head, str(target.relative_to(_root(context))))
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
    # line numbers: edit locates text by them and citations need positions
    body = "\n".join(f"{offset + i + 1:>6}\t{line}" for i, line in enumerate(window))
    more = len(lines) - (offset + len(window))
    if more > 0:
        body += f"\n\n[还有 {more} 行未显示，用 offset={offset + len(window)} 继续]"
    return ToolOutcome(body or "[空文件]", detail={"lines": len(lines)})


#: Cap on diff lines returned per change. Protects the UI: overwriting a 20,000-line text would
#: otherwise push 20,000 rows into the transcript. Truncation is marked.
DIFF_MAX_LINES = 400
#: context lines around a change, as in `diff -u`
DIFF_CONTEXT = 3


def _diff(before: str, after: str, path: str) -> dict[str, object]:
    """A change as a structured diff for the UI: (kind, old_no, new_no, text) rows, so it can show line
    numbers, colours and folds. Only lines near the change, never the whole file.
    """
    old_lines = before.splitlines()
    new_lines = after.splitlines()
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)

    rows: list[dict[str, object]] = []
    added = removed = 0
    truncated = False

    def push(kind: str, old_no: int | None, new_no: int | None, text: str,
             skipped: int | None = None) -> bool:
        """False when the cap is reached."""
        nonlocal truncated
        if len(rows) >= DIFF_MAX_LINES:
            truncated = True
            return False
        row: dict[str, object] = {"kind": kind, "old": old_no, "new": new_no, "text": text}
        if skipped is not None:
            # for the UI only: tool execution is pinned to Chinese, so the number lets the UI phrase it
            row["skipped"] = skipped
        rows.append(row)
        return True

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            span = i2 - i1
            # keep only lines next to a change: short hunks whole, long ones trimmed
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
    # Appending lets a long document go in sections, each call small enough to be generated and
    # sent before a gateway gives up on a silent stream (SECTION_CHARS).
    appending = arguments.get("append") is True
    existed = target.is_file()
    # read the old content first so the UI can show what changed; a failed read never fails the write
    before = ""
    if existed:
        try:
            before = target.read_text(encoding="utf-8", errors="replace")
        except OSError:
            before = ""
    after = before + content if appending else content
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        if appending:
            with target.open("a", encoding="utf-8") as handle:
                handle.write(content)
        else:
            target.write_text(content, encoding="utf-8")
    except OSError as exc:
        raise ToolError(f"写不了：{exc.strerror}", "IO_ERROR") from exc
    relative = target.relative_to(_root(context))
    change = _diff(before, after, str(relative))
    if appending and existed:
        summary = f"已追加到 {relative}（这次 {len(content)} 字，文件现在 {len(after)} 字，+{change['added']}）"
    else:
        verb = "覆盖" if existed else "新建"
        summary = f"已{verb} {relative}（{len(content)} 字，+{change['added']} −{change['removed']}）"
    return ToolOutcome(
        summary,
        detail={"path": str(relative), "overwrote": existed and not appending,
                "appended": appending and existed, "diff": change},
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
        # Only a unique match is replaced by default: replacing every occurrence while proofreading is
        # usually wrong and hard to spot. The error offers both ways out (more context, or replace_all);
        # with only the first, models re-ran OCR on whole pages to fix a misspelt term.
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
    """Make a trailing `**` match files, as bash (globstar), git and ripgrep do.

    pathlib's `**` only matches directories, and this tool keeps only files, so `code/**` found
    nothing and the model reported a cloned repository as empty. Only a trailing `**` is changed;
    `code/**/*.py` stays as is.
    """
    cleaned = pattern.rstrip("/")
    if not cleaned:
        return pattern
    return f"{cleaned}/*" if cleaned == "**" or cleaned.endswith("/**") else cleaned


async def _glob(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    # walking a whole repository can take hundreds of ms; keep it off the event loop
    return await asyncio.to_thread(_glob_sync, arguments, context)


def _glob_sync(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    root = _root(context)
    pattern = arguments.get("pattern")
    if not isinstance(pattern, str) or not pattern:
        raise ToolError("pattern 必须是非空字符串", "INVALID_ARGS")
    hits: list[str] = []
    #: Matches that aren't files. An empty result must mention them, or "no matches" reads as
    #: "this directory is empty".
    folders: list[str] = []
    effective = normalise_glob(pattern)
    for path in sorted(root.glob(effective)):
        try:
            # check every match: glob can follow a symlink out of the project
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
    # walking a whole repository can take hundreds of ms; keep it off the event loop
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
        # as in glob: without normalising, `code/**` would silently search no files
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
        # a regex over decoded image bytes matches noise and returns it as hits
        if _binary(_head(path)):
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
            # limits itself; never spills, or read would end up reading its own spill file
            max_result_chars=UNLIMITED_RESULT,
        ),
        ToolDef(
            name="write",
            description=(
                "把内容写进项目内一个文件：默认整体覆盖，`append=true` 时接在文件末尾（文件不存在就新建）。"
                "pdf/ 与 .lumen/ 不可写。\n\n"
                f"**一次调用的 content 不要超过约 {SECTION_CHARS} 字。** 长文档（整篇译文、长笔记）分节写："
                "第一节用 write 新建，之后每一节用 `append=true` 接上去；追加不会自动换行，"
                "节与节之间的空行写在 content 开头。原因：一次调用的参数要整段生成完才会发出来，"
                "有的网关在这段时间里收不到任何输出，等两分钟左右就会切断，已经生成的全部作废。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "path": _string("相对项目根的路径"),
                    "content": _string(f"要写的内容；不超过约 {SECTION_CHARS} 字，更长的分节追加"),
                    "append": {
                        "type": "boolean",
                        "description": "接在文件末尾而不是覆盖（默认 false）",
                    },
                },
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
