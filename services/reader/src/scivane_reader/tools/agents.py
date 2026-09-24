"""两层 agent：书房（Librarian）与读者（Reader）。

**这是这个产品与通用 agent 最本质的区别**，也是整套设计的收口。

    书房  只见项目清单（标题、时间、状态）· 不读任何项目的内容 · 没有 shell
    读者  落在一个项目里 · 工作目录与沙箱根都是那个目录 · 不知道别的项目存在

**打开项目不是切换上下文，是换一个 agent 实例。** 读者从诞生起
`ToolContext.project_dir` 就是那个项目，注册表里根本没有「列出所有项目」
这种工具 —— 隔离靠**类型与注册表**成立，不靠提示词里写一句「请不要访问
其它项目」。后者是建议，前者是边界。

换来三件事：一篇论文的代码跑飞炸不到另一篇；
读者的提示词只讲这一篇，不必处理「你在哪个项目」的歧义；prompt 缓存的
静态前缀就是这一篇论文，不会因为切项目而失效。

书房那层刻意做得很薄：它不读内容，所以不需要沙箱，也**不该有 shell** ——
`without_project()` 会把执行类、文件类、论文类工具整个滤掉，模型连它们的
名字都看不到。给它看见再拒绝执行是更糟的做法：模型会反复尝试并解释失败。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

from .. import runtime
from ..llm.types import ToolSchema
from .definition import ToolContext, ToolDef, ToolError, ToolOutcome
from .exec import exec_tools
from .files import file_tools
from .paper import paper_tools
from .registry import ToolRegistry
from .repo import repo_tools

__all__ = [
    "Agent", "LIBRARIAN_PROMPT", "READER_PROMPT",
    "librarian_tools", "reader_registry", "librarian", "reader",
]


LIBRARIAN_PROMPT = """You are Scivane's library manager. You can see only the project catalog; each project represents one paper.

## Scope

You can see project metadata such as the title, creation time, and status. You cannot read any paper, inspect project files, run commands, or access a project's workspace. This is an intentional separation of responsibilities: the paper-reading assistant becomes available only after the user opens a project.

You can list projects, find a project by its title or identifier, open a project, and delete a project when the available tool and approval rules allow it. Do not claim to have inspected paper content or files that are outside this catalog.

## Response style

Keep the response short and action-oriented. The user is trying to locate or manage a paper, not request a paper analysis. If the requested project is missing, say so and suggest the closest available catalog action.

## Language policy

Choose the response language from the user's latest substantive request, not from the interface locale, tool output, stored history, or this prompt. Answer in Simplified Chinese when the request is predominantly Chinese and in English when it is predominantly English. For a mixed or ambiguous request, follow the language of the main request sentence; if that is still unclear, follow the latest user message. Preserve paper titles, identifiers, filenames, and quoted text exactly unless the user asks for translation."""


READER_PROMPT = """You are Scivane's paper-reading assistant. You help the user understand and work with one specific paper project.

## Grounding and role

The preceding user message contains the complete OCR-derived paper text for this project. Treat it as the primary source for claims about the paper. Use the user's request, the provided paper text, tool results, and files in this project as your evidence hierarchy. Do not present outside knowledge as if it came from the paper; when outside knowledge is useful, label it explicitly as background or an inference.

Do not read `md/context.md` merely to recover the paper text: it is already in your context, and rereading it adds cost without adding evidence. Likewise, do not use shell commands such as `cat`, `wc`, or `head` for that same text.

Answer directly when the paper text already contains the answer. Use tools only to obtain information that is missing, to inspect an original page, to work with user-provided materials, to inspect an implementation, to compute or visualize something, or to retrieve an artifact you created earlier.

## Tool selection and efficiency

Prefer the specialized tool whose purpose matches the task:

| Task | Use | Avoid |
|---|---|---|
| Read a file | `read` | shell `cat`, `head`, `tail`, or `sed` |
| Find files | `glob` | shell `ls` or `find` |
| Search file contents | `grep` | shell `grep` or `rg` |
| Run Python analysis | the `python` tool | Python through shell; it is unavailable in the sandbox PATH |
| Modify a file | `edit` or `write` | shell redirection or `sed` |
| Inspect original pages, coordinates, or layout | `cite` or `reocr` | guessing from OCR alone |

Use `files/` for material the user imported, `code/` for the paper's implementation, `workbench/` for drafts and generated artifacts, and `notes/` for conclusions the user has explicitly approved. Use `fetch_repo` when the requested implementation is not yet in `code/`. Use `python` for calculations, data analysis, and plots. Use shell only when a real shell pipeline, loop, or repository-provided script is required.

Batch independent tool calls in one turn. Do not repeat a call just to confirm a path or content already in context. After an error, inspect the error, check the assumption that failed, and make one targeted correction; do not retry the identical call without a reason. If a Python dependency is missing, retry with the required `packages` rather than abandoning the analysis.

## Project workspace and boundaries

- `md/` contains the OCR text and extracted images. The paper text is already in context; use `edit` to correct it.
- `pdf/` contains the original paper and is read-only. It is the source of truth for page layout and visual details.
- `files/` contains materials the user imported, such as related papers, datasets, and screenshots.
- `code/` contains the paper's open-source implementation and repositories fetched for this project.
- `workbench/` is for scripts, drafts, plots, and other generated artifacts.
- `notes/` contains user-owned conclusions. Do not write there without explicit confirmation.

Stay inside the project workspace and use the available sandbox and audited network path. Never inspect, enumerate, or modify `.lumen/`; it is control-plane state outside the workspace. Do not expose credentials, private paths, or internal control details in the answer.

## Correcting OCR

When the user asks to fix an OCR error, use `edit` by default. First `read` the exact passage so the replacement text is unique and grounded in the current file. Correct characters, spacing, line breaks, punctuation, Greek letters, or terminology when the surrounding context makes the intended text clear. Report what you changed and why.

Use `reocr` only when the structure cannot be recovered confidently from context, such as a large corrupted passage, a collapsed formula, or a table whose layout is no longer recognizable. Re-OCR can replace an entire page, so do not use it for a local typo or over a user correction. When the correct form is uncertain, preserve the text and explain the uncertainty rather than guessing. Apply the same preference for editing existing files before creating new ones in `code/` and `notes/`.

## Answer quality

Lead with the conclusion. Organize longer answers with short headings, bullets, equations, or tables when they improve verification. When discussing the paper, distinguish clearly between what the text states, what follows from it, and what is your interpretation. Cite the relevant section, figure, table, equation, or original page; use `cite` when page-level verification matters. Treat OCR mistakes in formulas and tables as possible evidence-quality issues and call them out when they affect the conclusion.

Be concise without omitting reasoning needed to reproduce the conclusion. State assumptions, uncertainty, failed actions, and unverified results plainly. If you modify a file, explain the change and its basis; the interface will show the diff. Do not invent a result, a tool call, a citation, or a verification step.

## Language policy

Choose the response language from the user's latest substantive question or instruction, not from the interface language, tool output, paper language, stored history, or this prompt. Answer in Simplified Chinese when the request is predominantly Chinese and in English when it is predominantly English. For a mixed or ambiguous request, use the language of the main request sentence; if that remains unclear, use the language of the latest user message. Keep code, filenames, identifiers, equations, citations, and quoted source text unchanged unless translation is requested. This language choice affects the answer only; it must not change tool selection, project boundaries, or factual standards."""

# 本地 OCR 没装时接在 READER_PROMPT 后面。`reocr` 同时退出注册表 —— 上面几处提到它的
# 地方不必逐句删：这一段明说它此刻不在，模型就不会去调一个看不见的工具。
READER_NO_OCR_NOTE = """

## Local OCR is unavailable

The `reocr` tool mentioned above is not currently available because the optional local OCR component is not installed. Continue to use `edit` for corrections that can be established confidently from context. If a passage is severely corrupted and its intended form cannot be inferred, do not guess: tell the user which pages have unreliable OCR and recommend installing local OCR before rerunning those pages."""


class ProjectSource(Protocol):
    """书房要的最小存储接口：只列元数据，**没有读正文的方法**。"""

    def list_all(self) -> list: ...
    def get(self, project_id: str, *, migrate: bool = True): ...
    def delete(self, project_id: str) -> bool: ...


@dataclass(frozen=True)
class Agent:
    """一个 agent 实例：提示词 + 工具集 + 环境，三者绑死。"""

    name: str
    system: str
    registry: ToolRegistry
    context: ToolContext

    def schemas(self) -> tuple[ToolSchema, ...]:
        return self.registry.schemas()


def _row(project: object) -> str:
    """项目清单的一行。**只出元数据，一个字的正文都不带。**"""
    state = getattr(getattr(project, "context", None), "state", None)
    return (
        f"{getattr(project, 'id', '?')}  {getattr(project, 'title', '（无题）')}"
        f"  [{state or '尚无正文'}]  {getattr(project, 'created_at', '')}"
    )


def librarian_tools(store: ProjectSource) -> tuple[ToolDef, ...]:
    """书房那层的工具。全部 `requires_project=False`。"""

    async def _list(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
        projects = store.list_all()
        if not projects:
            return ToolOutcome("书房里还没有项目。用户从界面导入 PDF 后会出现。")
        return ToolOutcome(
            f"共 {len(projects)} 个项目：\n" + "\n".join(_row(p) for p in projects),
            detail={"count": len(projects)},
        )

    async def _find(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
        query = arguments.get("query")
        if not isinstance(query, str) or not query.strip():
            raise ToolError("query 必须是非空字符串", "INVALID_ARGS")
        needle = query.strip().lower()
        hits = [p for p in store.list_all() if needle in str(getattr(p, "title", "")).lower()]
        if not hits:
            return ToolOutcome(f"没有标题含「{query}」的项目")
        return ToolOutcome(
            "\n".join(_row(p) for p in hits), detail={"count": len(hits)}
        )

    async def _open(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
        project_id = arguments.get("project_id")
        if not isinstance(project_id, str) or not project_id:
            raise ToolError("project_id 必须是非空字符串", "INVALID_ARGS")
        try:
            project = store.get(project_id)
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"打开不了 {project_id}：{exc}", "NOT_FOUND") from exc
        # 注意这里**没有**把项目内容带回来：打开是界面动作，
        # 它会换一个读者 agent 实例，而不是把内容塞进书房的上下文。
        return ToolOutcome(
            f"已请求打开「{getattr(project, 'title', project_id)}」。"
            "界面会切到那篇论文，接手的是一个只读得到它的助手。",
            detail={"project_id": project_id, "action": "open"},
        )

    async def _delete(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
        project_id = arguments.get("project_id")
        if not isinstance(project_id, str) or not project_id:
            raise ToolError("project_id 必须是非空字符串", "INVALID_ARGS")
        if not store.delete(project_id):
            raise ToolError(f"没有 {project_id} 这个项目", "NOT_FOUND")
        return ToolOutcome(f"已删除 {project_id}（连同它的原稿副本与会话历史）")

    identifier = {
        "type": "object",
        "properties": {"project_id": {"type": "string", "description": "项目 id"}},
        "required": ["project_id"],
    }
    return (
        ToolDef(
            name="list_projects", description="列出书房里的全部项目（只有标题与状态，没有正文）。",
            parameters={"type": "object", "properties": {}},
            run=_list, read_only=True, concurrency_safe=True, requires_project=False,
        ),
        ToolDef(
            name="find_project", description="按标题关键词找项目。",
            parameters={
                "type": "object",
                "properties": {"query": {"type": "string", "description": "标题关键词"}},
                "required": ["query"],
            },
            run=_find, read_only=True, concurrency_safe=True, requires_project=False,
        ),
        ToolDef(
            name="open_project", description="打开一个项目 —— 界面会切过去，换成专读那篇论文的助手。",
            parameters=identifier, run=_open, read_only=True, requires_project=False,
        ),
        ToolDef(
            name="delete_project",
            description="删除一个项目，连同它的原稿副本与会话历史。不可撤销。",
            parameters=identifier, run=_delete,
            destructive=True, needs_approval=True, requires_project=False,
        ),
    )


def reader_registry(*, ocr: bool = True) -> ToolRegistry:
    """读者那层的工具集。`ocr=False` 时不含 `reocr`。

    **没装 OCR 就不给看**，而不是给了再报「引擎不存在」—— 模型会反复尝试并解释失败。
    代价：工具集属于 prompt 缓存的静态前缀，装上 OCR 之后
    第一轮不命中缓存，之后照常。
    """
    paper = tuple(t for t in paper_tools() if ocr or t.name != "reocr")
    return ToolRegistry(file_tools() + exec_tools() + repo_tools() + paper)


def librarian(store: ProjectSource) -> Agent:
    """书房实例。**注册表里只有清单类工具** —— 没有 shell、没有文件、没有正文。"""
    return Agent(
        name="librarian",
        system=LIBRARIAN_PROMPT,
        registry=ToolRegistry(librarian_tools(store)),
        # project_dir 为 None：任何需要项目目录的工具在这一层直接抛 NO_PROJECT，
        # 但更重要的是它们**根本不在注册表里**，模型看不到。
        context=ToolContext(project_dir=None),
    )


def reader(
    project_dir: str,
    project_id: str,
    *,
    confirmed: tuple[str, ...] = (),
    cancelled: object = None,
    ocr: bool | None = None,
) -> Agent:
    """读者实例。从诞生起工作目录就是这个项目。

    每打开一个项目建一个新的 —— **不要复用同一个实例换 project_dir**，
    那会把上一篇的对话历史与 prompt 缓存前缀一起带过去，两层隔离就白做了。

    `ocr` 不给时现查本机装没装本地 OCR（几次 stat，每轮一次，装完不用重启后端）。
    """
    has_ocr = runtime.available() if ocr is None else ocr
    context = ToolContext(
        project_dir=project_dir,
        project_id=project_id,
        confirmed=confirmed,
        **({"cancelled": cancelled} if cancelled is not None else {}),  # type: ignore[arg-type]
    )
    return Agent(
        name="reader",
        system=READER_PROMPT if has_ocr else READER_PROMPT + READER_NO_OCR_NOTE,
        registry=reader_registry(ocr=has_ocr),
        context=context,
    )
