"""工具结果的大小治理：超限落盘，只把预览与路径交给模型。

一次 `grep` 在一个真实仓库里能命中几万行，整块塞进上下文会把那篇论文
（本产品真正的上下文）挤出窗口。超限就落盘，模型拿到
一段预览加一个路径，真要看全的就自己去 read。

**`read` 必须设成 UNLIMITED_RESULT。** 把它的结果落盘再给模型一个路径，
模型下一步必然去 read 那个路径，再落一次盘 —— 一个读文件又读回自己的循环。
而且 `read` 本来就有自己的行数上限，不需要这一层再管。
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from .definition import ToolDef, ToolOutcome

__all__ = ["SPILL_SUBDIR", "PREVIEW_CHARS", "apply_limit"]

#: 落盘位置。放在项目内可写区域，**而且是 agent 读得到的地方** ——
#: 落到项目外它就拿不回来了，预览里那个路径也就成了一句空话。
SPILL_SUBDIR = "workbench/tool-results"

#: 给模型看的预览长度。
PREVIEW_CHARS = 2_000


def apply_limit(
    outcome: ToolOutcome, tool: ToolDef, project_dir: Path | str | None
) -> ToolOutcome:
    """超限则落盘，返回改写后的结果。未超限原样返回。

    落不了盘（书房层没有项目目录、或写失败）时**截断并说明**，
    绝不把超限内容原样交上去 —— 那等于这一层没做。
    """
    limit = tool.max_result_chars
    if limit == float("inf") or len(outcome.content) <= limit:
        return outcome

    preview = outcome.content[:PREVIEW_CHARS]
    full = len(outcome.content)

    if project_dir is None:
        return ToolOutcome(
            content=(
                f"{preview}\n\n[结果共 {full} 字，超过 {int(limit)} 字上限，"
                "已截断；此处没有项目目录可供落盘]"
            ),
            is_error=outcome.is_error,
            detail={**outcome.detail, "truncated": True, "full_chars": full},
        )

    digest = hashlib.sha256(outcome.content.encode("utf-8")).hexdigest()[:12]
    target = Path(project_dir) / SPILL_SUBDIR / f"{tool.name}-{digest}.txt"
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(outcome.content, encoding="utf-8")
    except OSError as exc:
        return ToolOutcome(
            content=(
                f"{preview}\n\n[结果共 {full} 字，超过上限且落盘失败（{exc.strerror}），已截断]"
            ),
            is_error=outcome.is_error,
            detail={**outcome.detail, "truncated": True, "full_chars": full},
        )

    relative = target.relative_to(Path(project_dir))
    return ToolOutcome(
        content=(
            f"{preview}\n\n[结果共 {full} 字，超过 {int(limit)} 字上限。"
            f"完整内容已写入 {relative} —— 需要的话用 read 看它]"
        ),
        is_error=outcome.is_error,
        detail={**outcome.detail, "spilled_to": str(relative), "full_chars": full},
    )
