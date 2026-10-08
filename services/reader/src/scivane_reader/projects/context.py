"""Assemble a project into one model call.

    system          the reader prompt (stable)
    messages[0]     the paper's Markdown     <- cacheable_prefix ends here
    messages[1..]   earlier turns
    messages[-1]    this question

The cache boundary sits right after the paper: it is most of the context and never moves.
Large tool results from earlier turns are trimmed (settle_history) deterministically, so a past
turn looks the same in every later request and the prefix cache keeps hitting. The log and the
UI keep the full text.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Sequence

from ..i18n import ui
from ..llm import CallRequest, Message, Purpose
from ..llm.types import ToolResultBlock, ToolSchema, ToolUseBlock
from .model import Project

#: Short and stable: it heads the cache prefix, so changing one character invalidates every
#: project's cache.
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
    """Assemble project, history and question into one call.

    `system` overrides the default prompt; the two agent levels keep separate prompts.
    Raises ValueError when the context hasn't been confirmed.
    """
    if project.context is not None and not project.context.confirmed:
        # Unconfirmed text may not be this paper at all; answering from it is worse than no context.
        raise ValueError(ui("这份上下文还没有经过确认，不能用于问答",
                            "This text hasn't been confirmed yet, so it can't be used for questions"))

    messages: list[Message] = [paper_message(project, context_markdown)]
    messages.extend(settle_history(history or []))
    messages.append(Message.text("user", question))

    return CallRequest(
        model=model,
        messages=tuple(messages),
        system=system if system is not None else SYSTEM_PROMPT,
        max_tokens=max_tokens,
        purpose=purpose,
        tools=tools,
        # only the paper message is static; see the module docstring
        cacheable_prefix=1,
    )


def paper_message(project: Project, markdown: str) -> Message:
    """The paper message: first in the request and the cached prefix.

    Must match what assemble() builds byte for byte; meter.py and compaction.py reuse the prefix.
    """
    return Message.text("user", _wrap_paper(project, markdown))


def _wrap_paper(project: Project, markdown: str) -> str:
    """A stable wrapper around the text. The title is left out on purpose: it changes after OCR and
    would invalidate the most expensive cache entry.
    """
    return f"以下是论文的完整正文，供后续所有问题参考。\n\n---\n\n{markdown}"


#: Results from earlier turns longer than this (characters) are not resent verbatim.
#: read results run a median 5.3K; grep, glob, cite and edit results are usually a few hundred,
#: so short results stay and whole files go.
HISTORY_RESULT_BUDGET = 2000

#: Tools whose results can be re-read with the same arguments and no side effects. Past results
#: become a note telling the model to call again. bash and python would redo their work, so
#: those are cut to head and tail instead.
_REREADABLE = frozenset({"read", "grep", "glob", "cite"})

#: head and tail kept when cutting; with the note, close to the budget
_HEAD, _TAIL = 1200, 600


def settle_history(history: Sequence[Message]) -> list[Message]:
    """Shrink large tool results from earlier turns; everything else is untouched. Pure and deterministic.

    Calls, call_id and is_error stay as they are, so every call still has its result.
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
    """What a past large result becomes. Written for the model: what is missing and how to get it back."""
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
