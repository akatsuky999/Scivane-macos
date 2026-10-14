"""Assemble a project into one model call.

    system          the agent's prompt (stable; tools/agents.py)
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
from ..llm.types import ContentBlock, ToolResultBlock, ToolSchema, ToolUseBlock
from .model import Project
from .session import user_content


def assemble(
    project: Project,
    context_markdown: str,
    question: str,
    history: list[Message] | None = None,
    *,
    model: str,
    system: str,
    purpose: Purpose = "foreground",
    max_tokens: int | None = None,
    tools: tuple[ToolSchema, ...] = (),
    images: Sequence[ContentBlock] = (),
    note: str = "",
) -> CallRequest:
    """Assemble project, history and question into one call; `images` go with the question.

    `system` is the agent's prompt; there is no default, so no second prompt can quietly stand in
    for it. `note` is an app message placed before the question's words (History.pending_note), so
    the projection of the log rebuilds this request byte for byte.
    Raises ValueError for text an older version left unconfirmed.
    """
    if project.context is not None and not project.context.confirmed:
        # It may not be this paper at all; answering from it is worse than no context.
        raise ValueError(ui("这份正文还没有确认，不能用于问答 —— 重新识别原稿，或换一份 Markdown",
                            "This text was never confirmed, so it can't be used for questions — "
                            "recognize the original again, or replace it with a Markdown file"))

    messages: list[Message] = [paper_message(project, context_markdown)]
    messages.extend(settle_history(history or []))
    messages.append(Message("user", user_content(question, images, note=note)))

    return CallRequest(
        model=model,
        messages=tuple(messages),
        system=system,
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


#: closing tag of the paper wrapper, escaped inside the text so a paper can't end its own wrapper
_CLOSE = "</paper"


def _wrap_paper(project: Project, markdown: str) -> str:
    """The paper inside a tagged wrapper that names where the text came from.

    The tag marks the paper as material rather than the user's words (papers quote instructions,
    some are about prompt injection), and `source` tells the model how much to trust symbols and
    numbers: OCR garbles them, a transcribing model may fill gaps, an upload may not be the paper
    at all. The origin only changes together with the text, so it costs the cache nothing; the
    title is left out on purpose, since it changes after OCR.
    """
    origin = project.context.origin if project.context is not None else "unknown"
    body = markdown.replace(_CLOSE, "<\\/paper")
    return f'<paper source="{origin}">\n{body}\n</paper>'


#: Results from earlier turns longer than this (characters) are not resent verbatim.
#: read results run a median 5.3K; grep, glob, cite and edit results are usually a few hundred,
#: so short results stay and whole files go.
HISTORY_RESULT_BUDGET = 2000

#: Tools whose results can be re-read with the same arguments and no side effects. Past results
#: become a note telling the model to call again. bash and python would redo their work, so
#: those are cut to head and tail instead.
_REREADABLE = frozenset({"read", "grep", "glob", "cite", "annotations"})

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
