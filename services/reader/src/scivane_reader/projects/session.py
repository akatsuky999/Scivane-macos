"""会话日志的投影：把 append-only 的 `session.jsonl` 重建成模型历史。

**这是 `store.append_event()` 那件事的读取一半。** 写入在 store.py，事件名在
model.py 的 `ProjectEvent`，读回来在这里 —— 三者同处 `projects/`，因为日志是
项目的产物。这一层只依赖 `llm.types`（消息词汇），不依赖 `tools/`，
所以分层方向仍是 `projects/ → llm/`，没有反向。

凡是进入过模型请求的东西都必须能从日志重建。**反过来也成立** —— 既然日志是
唯一事实来源，那重建出来的历史必须是**合法的**，不能因为日志尾部不完整就
产出一段发不出去的历史。

所以有两条规则必须做对：

1. **`tool/call` 与 `tool/result` 按 `call_id` 配对**，并保持模型序。
   助手那一轮的正文与它的工具调用放同一条消息里（三家协议都要求
   tool_result 紧跟在带 tool_use 的助手消息之后）。

2. **有 call 无 result 的半截记录，投影时当场补一个合成的错误结果。**
   这种记录来自进程崩溃、被 kill、或者旧版本留下的日志。不补的话，
   拿这段历史发请求直接非法（三家都要求每个 tool_use 有对应 tool_result），
   表现是「打开一个旧项目，第一句话就发不出去」，而且用户完全不知道为什么。
   这和取消时补合成结果（scheduler.py）是同一条纪律的两半 ——
   一半管运行时，一半管重启之后。

这里不另设 projection 注册表。我们只有一个消费者、一次全量重放，一个纯函数就够；
多引入一层注册表对当前规模是纯负担。
"""

from __future__ import annotations

from typing import Any, Iterable

from ..i18n import ui
from ..llm.types import Message, TextBlock, ToolResultBlock, ToolUseBlock
from .model import ProjectEvent

__all__ = [
    "derive_messages", "derive_transcript", "summarise_call",
    "MISSING_RESULT_TEXT", "MISSING_RESULT_CODE",
]

#: 合成结果的稳定码。与 scheduler 里取消时用的码区分开 —— 那个是
#: 「当时被取消了」，这个是「日志里就没有结果」，排障时是两回事。
MISSING_RESULT_CODE = "TOOL_RESULT_MISSING_FROM_LOG"

MISSING_RESULT_TEXT = (
    f"错误（{MISSING_RESULT_CODE}）：这次调用在日志里没有结果 —— "
    "上次运行可能是崩溃或被强制结束的。"
)


class _Turn:
    """攒一轮助手输出：正文 + 它发起的工具调用 + 回填的结果。"""

    __slots__ = ("text", "uses", "results")

    def __init__(self) -> None:
        self.text: str = ""
        self.uses: list[ToolUseBlock] = []
        #: call_id → 结果。用字典是因为并发跑完的结果回填顺序未必等于调用顺序。
        self.results: dict[str, ToolResultBlock] = {}

    @property
    def empty(self) -> bool:
        return not self.text and not self.uses


def derive_messages(events: Iterable[dict[str, Any]]) -> tuple[Message, ...]:
    """把日志事件投影成模型历史。

    只认四种事件（`user/message`、`assistant/message`、`tool/call`、
    `tool/result`）。生命周期事件（项目创建、上下文替换、布局升级）与
    `tool/decision` 一律跳过 —— 批准与否是主机侧的事实，不进模型请求
    （进了反而会让模型就自己的权限边界发表意见）。

    对格式不对的事件宽容：缺字段、类型不对的跳过，不让一条脏数据毁掉整段历史
    （与 `store.events()` 跳过坏行是同一个取舍）。
    """
    messages: list[Message] = []
    turn = _Turn()

    def flush() -> None:
        """把攒好的一轮落成消息。**这里是补合成结果的唯一地点。**"""
        nonlocal turn
        if turn.empty:
            turn = _Turn()
            return

        blocks: list[Any] = []
        if turn.text:
            blocks.append(TextBlock(turn.text))
        blocks.extend(turn.uses)
        messages.append(Message("assistant", tuple(blocks)))

        if turn.uses:
            # 按**调用顺序**交回结果，缺的当场补。顺序不能用 results 的插入序 ——
            # 并发跑完的工具回填顺序与模型给出的顺序无关。
            results = tuple(
                turn.results.get(
                    use.id,
                    ToolResultBlock(use.id, MISSING_RESULT_TEXT, is_error=True),
                )
                for use in turn.uses
            )
            messages.append(Message("user", results))
        turn = _Turn()

    for event in events:
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        data = event.get("data")
        if not isinstance(data, dict):
            data = {}

        if kind == ProjectEvent.USER_MESSAGE:
            flush()
            text = data.get("text")
            if isinstance(text, str) and text:
                messages.append(Message.text("user", text))

        elif kind == ProjectEvent.ASSISTANT_MESSAGE:
            # 一条新的助手消息意味着上一轮（连同它的工具结果）已经结束
            flush()
            text = data.get("text")
            turn.text = text if isinstance(text, str) else ""

        elif kind == ProjectEvent.TOOL_CALL:
            call_id = data.get("call_id")
            name = data.get("name")
            if not isinstance(call_id, str) or not isinstance(name, str):
                continue
            arguments = data.get("arguments")
            turn.uses.append(
                ToolUseBlock(call_id, name, arguments if isinstance(arguments, dict) else {})
            )

        elif kind == ProjectEvent.TOOL_RESULT:
            call_id = data.get("call_id")
            if not isinstance(call_id, str):
                continue
            content = data.get("content")
            turn.results[call_id] = ToolResultBlock(
                call_id,
                content if isinstance(content, str) else "",
                is_error=bool(data.get("is_error")),
            )

        # 其余事件与模型历史无关，跳过

    flush()
    return tuple(messages)


def summarise_call(name: str, arguments: dict) -> str:
    """给界面一句人类读得懂的话（「搜索 对比损失」「read md/context.md」）。

    **放在投影层而不是路由层**，因为两处都要它：流式推送时路由要发一份，
    而历史恢复时 `derive_transcript()` 也要发一份。各写一份必然漂移，
    漂移的结果是「实时看到的那句」和「重开之后看到的那句」对不上。

    不是给模型看的，所以可以写得随意些；但**必须说清副作用落在哪** ——
    批准弹窗上用户要在一秒内判断这次动作该不该批。

    **按界面语言说**（`i18n.py`）：实时推送与历史恢复都是一次带着界面语言的请求，
    两处因此还是同一句话。英文界面跑动中直接拿它当状态行（「Searching …」），
    所以英文一律用动名词开头；中文照旧，由界面在前面接「正在」。
    """
    if name == "fetch_repo":
        url = str(arguments.get("url", "?"))
        target = url.rstrip("/").split("/")[-1].removesuffix(".git") or "?"
        return ui(f"取回 {url}，放进 code/{target}", f"Fetching {url} into code/{target}")
    if name in ("read", "write", "edit"):
        path = arguments.get("path", "?")
        doing = {"read": "Reading", "write": "Writing", "edit": "Editing"}[name]
        return ui(f"{name} {path}", f"{doing} {path}")
    if name == "grep":
        return ui(f"搜索 {arguments.get('pattern', '?')}", f"Searching {arguments.get('pattern', '?')}")
    if name == "glob":
        return ui(f"列出 {arguments.get('pattern', '?')}", f"Listing {arguments.get('pattern', '?')}")
    if name == "bash":
        command = str(arguments.get("command", "?"))[:80]
        return ui(f"跑 {command}", f"Running {command}")
    if name == "python":
        size = len(str(arguments.get("code", "")))
        return ui(f"跑一段 Python（{size} 字）", f"Running Python ({size} chars)")
    if name == "reocr":
        pages = arguments.get("pages", "?")
        return ui(f"重新识别第 {pages} 页", f"Re-running OCR on pages {pages}")
    if name == "cite":
        anchor = arguments.get("anchor", "?")
        return ui(f"定位「{anchor}」在原稿的位置", f"Locating “{anchor}” in the original")
    if name == "delete_project":
        project = arguments.get("project_id", "?")
        return ui(f"删除项目 {project}（连同原稿与历史）",
                  f"Deleting project {project} (with its original and history)")
    return name


def derive_transcript(events: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """把日志投影成**界面要渲染的那份**记录。

    与 `derive_messages()` 并列而不是各写各的：两者遵守同一条配对纪律
    （`tool/call` 与 `tool/result` 按 call_id 配对、缺结果当场补），
    区别只在产出形状 —— 一个给模型，一个给人看。

    **界面侧不重写这套逻辑。** 在 Swift 里再实现一遍「缺结果要补」，
    两份必然漂移，而漂移的那份会让用户看到一段和模型看到的不一样的历史。

    与模型那份的三处不同：
    - 带 `tool/decision`（批准与否是人要看的，但不进模型请求）
    - 工具结果只给预览，全文在日志里
    - 保留 `synthetic` 标记，让界面能分辨「工具报错了」和「工具根本没跑」
    """
    items: list[dict[str, Any]] = []
    pending: dict[str, int] = {}      # call_id → items 里的下标
    decisions: dict[str, dict[str, Any]] = {}

    for event in events:
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        data = event.get("data") if isinstance(event.get("data"), dict) else {}
        at = event.get("at", "")

        if kind == ProjectEvent.USER_MESSAGE:
            text = data.get("text")
            if isinstance(text, str) and text:
                items.append({"kind": "user", "text": text, "at": at})

        elif kind == ProjectEvent.ASSISTANT_MESSAGE:
            text = data.get("text")
            if isinstance(text, str) and text.strip():
                items.append({"kind": "assistant", "text": text, "at": at})

        elif kind == ProjectEvent.TOOL_CALL:
            call_id = data.get("call_id")
            if not isinstance(call_id, str):
                continue
            pending[call_id] = len(items)
            name = data.get("name", "?")
            arguments = data.get("arguments") or {}
            items.append({
                "kind": "tool", "call_id": call_id,
                "name": name,
                "arguments": arguments,
                # 摘要在这里算，**不要留给界面自己拼** —— 实时那份由路由用
                # 同一个函数算，两边必须是同一句话。少了它，恢复出来的历史
                # 每一行都会退化成「bash bash」这种把工具名说两遍的废话。
                "summary": summarise_call(name, arguments),
                "at": at,
                # 先按「没有结果」落位，下面收到结果再补上
                "state": "missing", "preview": MISSING_RESULT_TEXT,
                "is_error": True, "synthetic": True,
            })

        elif kind == ProjectEvent.TOOL_RESULT:
            call_id = data.get("call_id")
            index = pending.pop(call_id, None) if isinstance(call_id, str) else None
            if index is None:
                continue
            content = data.get("content")
            detail = data.get("detail") if isinstance(data.get("detail"), dict) else {}
            items[index].update({
                "state": "done",
                "preview": (content if isinstance(content, str) else "")[:_PREVIEW],
                "is_error": bool(data.get("is_error")),
                "synthetic": bool(data.get("synthetic")),
                "detail": detail,
            })

        elif kind == ProjectEvent.TOOL_DECISION:
            call_id = data.get("call_id")
            if isinstance(call_id, str):
                decisions[call_id] = {
                    "approved": bool(data.get("approved")),
                    "reason": data.get("reason", ""),
                }

    # 裁决回填到对应的工具卡片上
    for item in items:
        if item.get("kind") == "tool":
            verdict = decisions.get(item.get("call_id"))
            if verdict is not None:
                item["decision"] = verdict
    return items


#: 给界面的结果预览长度。与 agent_routes 里流式推送的那个保持一致。
_PREVIEW = 600
