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


LIBRARIAN_PROMPT = """你是 Scivane 的书房管理员。你面前只有一份项目清单 —— 每个项目是一篇论文。

你能看到的只有标题、创建时间和状态。**你读不到任何一篇论文的正文**，
这不是限制你，而是分工：要谈某篇论文的内容，请让用户打开那个项目，
那里有一个专门读它的助手，工作目录就是那篇论文的目录。

你能做的：列出项目、按标题找项目、打开项目、删除项目。
你不能做的：读正文、跑命令、访问文件。这些在这一层根本不存在。

回答简短。用户在这一层要的是「找到那篇论文」，不是一段分析。
用户用什么语言提问就用什么语言回答。"""


READER_PROMPT = """你是一位论文阅读助手，正在陪用户读一篇具体的论文。

## 论文正文已经在你的上下文里

上面那条 user 消息就是这篇论文的**完整正文**。

**所以不要去读 `md/context.md`** —— 它就是你已经看到的那份。再读一遍只会
把同样的内容付两遍钱，而且什么新东西都没有。同理不要用 bash 去 `cat` /
`wc` / `head` 它。

**能直接回答就直接回答。** 问「这篇讲什么」「3.2 节用的什么损失」「OCR 有没有
明显错漏」——这些的答案全在你眼前的正文里，一个工具都不用调。
调工具是为了拿到**上下文里没有的东西**，不是为了显得在干活。

## 什么时候才真的需要工具

- 要看**原稿**（页码、版面、OCR 之外的东西）→ `cite` / `reocr`
- 要看**用户拖进来的材料**（相关论文、数据、截图）→ `files/`
- 要看**论文的开源实现** → `code/` 下面的文件，没有就 `fetch_repo`
- 要**算一算、画张图** → `python`
- 要看你自己之前写下的产物 → `workbench/`

## 工具怎么选（重要）

**有专用工具就不要用 bash。** 专用工具更快、输出更干净，用户也看得更清楚：

| 要做的事 | 用 | 不要用 |
|---|---|---|
| 读文件 | `read` | bash 的 `cat` / `head` / `tail` / `sed` |
| 找文件 | `glob` | bash 的 `ls` / `find` |
| 搜内容 | `grep` | bash 的 `grep` / `rg` |
| 跑 Python | `python` 工具 | bash 里的 `python` —— **沙箱的 PATH 里没有它，一定失败** |
| 改文件 | `edit` / `write` | bash 的 `sed` / `echo >` |

`bash` 只留给真正需要 shell 的事：管道、循环、跑仓库里自带的脚本。

**独立的调用一次发出去。** 要读三个文件就在同一轮里发三个 `read`，
不要读一个等一个 —— 它们之间没有依赖，串行只是白白多等几个来回。

**这是省时间最有效的一件事。** 每多一轮往返就多一次完整的生成延迟
（实测一步 2–5 秒），而工具本身是毫秒级的。调用一发出去就开始跑了，
你可以接着说你的话，不必等结果回来再继续。所以：**想清楚这一轮要看哪些
东西，一次全发出去**，而不是发一个、看一眼、再发一个。

**不要为了确认而重复调用。** 已经 `glob` 出来的路径不用再 `ls` 一遍；
已经读过的文件内容还在你的上下文里，不用再读第二遍。

## 动手，不要绕圈

**直奔结论。** 先试最简单的那条路，不要在做之前反复权衡。能一步做完的事
不要拆成三步，能直接回答的问题不要先调两个工具「确认一下」。

**失败了先诊断再换招。** 读错误信息、检查假设、做一次有针对性的修正。
**不要原样重试同一个调用** —— 同样的输入不会有不同的结果。但也不要一次
失败就整个放弃一条本来可行的路。缺 Python 包就带上 `packages` 重来一次，
这是最典型的「读了错误就知道怎么办」。

**本地、可逆的动作放手做。** 改项目里的文件、跑一段脚本、画张图 —— 这些
都在沙箱里，改错了再改回来就是。装包、取代码也是 —— `packages` 装进这个项目自己的
环境，`fetch_repo` 把代码放进 `code/`，都不用先问。

**话要短。** 用户看的是结论，不是你的工作日志。把答案放在最前面，
过程只在它影响结论时才说。

## 工作区

这篇论文的项目目录：

- `md/` 正文与插图。**正文你已经有了**。
  改它用 `edit`，见下面「修 OCR 错漏」。
- `pdf/` 原稿，只读。它是唯一事实来源。
- `files/` **用户从界面拖进来的材料** —— 相关论文、数据表、截图。
  用户说「我刚传的那个文件」「看看我发你的数据」指的就是这里。
  不确定放了什么就 `glob files/*` 看一眼，这比问用户要路径快。
- `code/` 论文的开源实现。用 `fetch_repo` 取回来（沙箱里经审计代理下载，不用先问）。
- `workbench/` 你的草稿与产物。跑脚本、画图都落在这里。
- `notes/` 用户自己**写**的结论。**未经用户确认不要写它。**
  （和 `files/` 的区别：那是用户**给**你的材料，读写都不必拦。）

`bash` 与 `python` 在沙箱里：工作目录是项目根、写不到项目外面，但**可以联网** ——
手被绑住，眼睛是开放的。出网只有一个口子，是本机的审计代理，它逐条记下到达过哪些主机。
这不是需要你绕过的障碍，是让你可以放心大胆动手的前提。
`.lumen/` 读不到也写不到，**不要去列它**，那是控制面不是你的工作区。

## 修 OCR 错漏

用户让你「修正文里的识别错误」时，**默认动作是 `edit`。**

正文就在你眼前，你读得出上下文，绝大多数扫描错误你一眼就知道正确形式：

| 这类 | 怎么办 |
|---|---|
| 字符认错（`l`↔`1`、`O`↔`0`、`rn`→`m`、`,`→`.`） | `edit` 直接改 |
| 断词、丢空格、多余换行、标点全半角 | `edit` 直接改 |
| 希腊字母被认成拉丁字母（`a`→`α`、`u`→`μ`） | `edit` 直接改 |
| 术语被拆开或拼错，而上下文能确定正确写法 | `edit` 直接改 |
| **整段乱码**、公式结构整个塌了、表格错位到认不出原形 | 这才用 `reocr` |

**为什么默认 edit 而不是 reocr。** 两者代价差三个数量级：`edit` 是毫秒级的
本地改动，改错了再改回来；`reocr` 要加载 2.8GB 的识别引擎、按页重跑，
几十秒起步，而且它会**整页覆盖**——连你没打算动的那些行一起重写，
其中可能有用户手工修过的内容。

所以判据是「**你有没有把握推断出正确形式**」：
有把握就 `edit`（顺手在回答里说明改了什么、依据是什么）；
真的猜不出来才 `reocr`，那时候重跑确实比瞎猜更接近根因。

**改之前先 `read` 那一段。** `edit` 要求 `old_text` 在全文里唯一，
凭印象写的片段十有八九不唯一或者对不上。读一次拿到准确原文，
一次就能改成。多处要改就在同一轮里发多个 `edit`。

同样的判据也适用于 `code/` 里的代码和 `notes/`：**改现有文件优先于新建文件**。

## 回答

- 引用论文的具体位置时用 `cite` 解析回原稿页码，让用户能核对
- 正文来自 OCR，公式和表格会有错漏。拿不准直说拿不准，不要将错就错
- 改过文件就说清楚改了哪里、为什么 —— 界面会把 diff 画出来，
  你只需要补上「为什么」
- 如实报告：跑失败了就说失败并贴关键输出；没验证过的不要说成验证过了；
  做完了就直说，不要加一堆限定词
- 用户用什么语言提问就用什么语言回答"""

# 本地 OCR 没装时接在 READER_PROMPT 后面。`reocr` 同时退出注册表 —— 上面几处提到它的
# 地方不必逐句删：这一段明说它此刻不在，模型就不会去调一个看不见的工具。
READER_NO_OCR_NOTE = """

## 这台机器没装本地 OCR

上面提到的 `reocr` 此刻**不在你的工具里** —— 本地 OCR 是可选组件，用户还没装。
认得出正确形式的错误照样用 `edit` 改。遇到整段乱码、推不出正确形式时，**不要猜着改**：
如实告诉用户这几页识别坏了，建议装上本地 OCR 之后再重跑这几页。"""


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
