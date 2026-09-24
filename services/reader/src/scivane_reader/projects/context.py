"""把项目装配成一次模型调用。

这是整条链路的收口：本地 OCR 产出的 Markdown 在这里变成 `CallRequest`
的静态前缀。装配的形状直接决定 prompt 缓存能不能命中，所以这里的每一处
顺序都是有意为之的。

    system            阅读助手的角色设定（稳定）
    messages[0]       论文正文 Markdown       ← cacheable_prefix 覆盖到这里
    messages[1..]     历次问答
    messages[-1]      本次提问

**为什么静态前缀只算到论文那一条**：论文正文占了整个上下文的绝大部分，
把断点打在它后面就拿到了几乎全部收益，而且这个位置**永远不动** —— 后续
每一轮都命中同一个缓存。把历史也算进静态前缀能再省一点，但断点每轮都要
往后挪，收益远小于复杂度。等真实用量数据说明有必要再做。

**之前各轮的大工具结果不原样重传**（`settle_history`）。实测一篇带真实对话历史的论文：
每问 72K token 里一半是第一轮读的两个代码文件 —— 之后每问一句「翻译第 X 章」都要把它们
再传一遍、再预填一遍、再付一遍钱。**这一轮之内不动**（模型正在干活，要看全文）；过去的轮次里，
超过 `HISTORY_RESULT_BUDGET` 的结果按工具分两种收法 —— 能原样重读的只留一句说明，
重读等于重跑的截成头尾。

**这个变换是确定的**：一轮一旦过去，它在之后每一次请求里都长一个样，所以后面各轮照样能接着
命中前缀缓存。这里不看时间、不留「最近几条」，边界永远是「这一轮之前」，
于是不存在「清了反而打断热缓存」这回事。
**日志与界面一个字不改** —— 这只是「发给模型的那一份」，从日志加这条规则就能原样重算。
"""

from __future__ import annotations

from dataclasses import replace
from typing import Sequence

from ..i18n import ui
from ..llm import CallRequest, Message, Purpose
from ..llm.types import ToolResultBlock, ToolSchema, ToolUseBlock
from .model import Project

#: 阅读助手的角色设定。
#:
#: 刻意保持简短且稳定 —— 它排在缓存前缀的最前面，改一个字就会让所有项目
#: 的缓存全部失效。要加长期指令应当另开一段，而不是往这里塞。
SYSTEM_PROMPT = """You are a paper-reading assistant. The user is reading one paper, and its complete OCR-derived text is provided in the conversation context.

Ground your answer in the provided paper text and the user's request. If the text does not establish a fact, say so instead of silently filling the gap with prior knowledge; label any outside background or inference explicitly. When citing the paper, name the relevant section, figure, table, equation, or page so the user can verify it in the original. Because the text comes from OCR, formulas and tables may contain recognition errors; flag suspicious passages instead of treating them as certain.

Choose the response language from the user's latest substantive question or instruction, not from the interface language, the paper's language, tool output, stored history, or this prompt. Use Simplified Chinese for a predominantly Chinese request and English for a predominantly English request. For mixed or ambiguous input, follow the main request sentence, then the latest user message if needed. Keep quoted source text, code, filenames, identifiers, equations, and citations unchanged unless the user asks for translation."""


def assemble(
    project: Project,
    context_markdown: str,
    question: str,
    history: list[Message] | None = None,
    *,
    model: str,
    purpose: Purpose = "foreground",
    max_tokens: int | None = None,
    tools: tuple[ToolSchema, ...] = (),
    system: str | None = None,
) -> CallRequest:
    """把项目、历史与本次提问装配成一次调用。

    :param context_markdown: 项目当前的静态上下文（论文正文）。
    :param history: 之前几轮的消息，按时间顺序（可含工具调用与结果块）。
    :param tools: 这一轮允许模型使用的工具，**只含模型可见字段**。
    :param system: 覆盖默认系统提示词。两层 agent 各有各的提示词，
        必须互不污染 —— 读者那层只讲这一篇论文，书房那层根本不该提到正文。
    :raises ValueError: 上下文尚未经人工确认时拒绝装配。
    """
    if project.context is not None and not project.context.confirmed:
        # 没人认账的正文不能拿去回答问题 —— 万一它根本不是这篇论文，
        # 模型会一本正经地基于错误材料作答，比没有上下文更糟。
        raise ValueError(ui("这份上下文还没有经过确认，不能用于问答",
                            "This text hasn't been confirmed yet, so it can't be used for questions"))

    paper = Message.text("user", _wrap_paper(project, context_markdown))
    messages: list[Message] = [paper]
    messages.extend(settle_history(history or []))
    messages.append(Message.text("user", question))

    return CallRequest(
        model=model,
        messages=tuple(messages),
        system=system if system is not None else SYSTEM_PROMPT,
        max_tokens=max_tokens,
        purpose=purpose,
        tools=tools,
        # 只有论文那一条是静态的，见模块开头的说明
        cacheable_prefix=1,
    )


def _wrap_paper(project: Project, markdown: str) -> str:
    """给正文加一个稳定的外壳。

    外壳里只放**不会变**的东西。标题会随 OCR 完成而精确化，所以刻意不放
    进来 —— 否则改一次标题就让整份缓存失效，而那正是最贵的一份。
    """
    return f"以下是论文的完整正文，供后续所有问题参考。\n\n---\n\n{markdown}"


# --- 过去的轮次 ------------------------------------------------------------

#: 之前各轮的工具结果，超过这个长度（字符）就不再原样重传。
#:
#: 取 2000：真实对话里 `read` 的结果中位 5.3K、九成在 15K 以内（36 条里 30 条超过 2000），
#: 而 grep / glob / cite / edit 的结果中位只有几十到一百多字 —— 这条线把「整份文件」挡在外面，
#: 把短的命中、清单、报错、「已改好」原样留下：它们便宜，而且常是下一问要接着用的。
HISTORY_RESULT_BUDGET = 2000

#: 结果能**原样重读**的工具：同样的参数再调一次拿到同样的东西，又快又没有副作用。
#: 过去的轮次里只留一句说明，要用时模型照上面那次调用的参数再调一次。
#:
#: bash / python 刻意不在里面：再调一次等于再跑一次（可能写文件、装包、跑几十秒），
#: 不能叫模型「重跑一遍拿回来」—— 它们截成头尾，结论与报错常在结尾。
_REREADABLE = frozenset({"read", "grep", "glob", "cite"})

#: 截成头尾时各留多少字。头 + 尾 + 那句说明，落在预算附近。
_HEAD, _TAIL = 1200, 600


def settle_history(history: Sequence[Message]) -> list[Message]:
    """把之前各轮的大工具结果收小，其余原样。**纯函数、确定性。**

    只动 `ToolResultBlock` 的内容：调用本身（`ToolUseBlock` 与它的参数）、助手说的话、
    用户的提问、短的结果一律不动；`call_id` 与 `is_error` 原样保留 —— 三家协议都要求
    每个调用有配对的结果，这里只是换了结果的正文。
    """
    names: dict[str, str] = {}
    for message in history:
        for block in message.content:
            if isinstance(block, ToolUseBlock):
                names[block.id] = block.name

    settled: list[Message] = []
    for message in history:
        blocks = []
        changed = False
        for block in message.content:
            if isinstance(block, ToolResultBlock) and len(block.content) > HISTORY_RESULT_BUDGET:
                blocks.append(replace(block, content=_settle(names.get(block.call_id, ""), block.content)))
                changed = True
            else:
                blocks.append(block)
        settled.append(Message(message.role, tuple(blocks)) if changed else message)
    return settled


def _settle(name: str, content: str) -> str:
    """一条过去的大结果收成什么样。说明写给模型看：它得知道这里少了东西、怎么拿回来。"""
    if name in _REREADABLE:
        return (
            f"〔这是较早一轮 {name} 的结果（原长 {len(content)} 字），已从上下文移除 —— "
            f"每一轮都重传、重读它会拖慢回答。要用其中的内容，照上面那次调用的参数再调一次 {name}。〕"
        )
    removed = len(content) - _HEAD - _TAIL
    return (
        content[:_HEAD]
        + f"\n…〔中间 {removed} 字已从上下文移除：这是较早一轮的输出，每一轮都重传会拖慢回答〕…\n"
        + content[-_TAIL:]
    )
