"""Tool result size control: oversized results spill to disk; the model gets a preview and a path.

One grep in a real repository can match tens of thousands of lines and push the paper out of
the window. read must be UNLIMITED_RESULT: spilling its result would make the model read the
spill file and spill again.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from .definition import ToolDef, ToolOutcome

__all__ = ["SPILL_SUBDIR", "PREVIEW_CHARS", "apply_limit"]

#: inside the project and readable by the agent, or the path in the preview would be useless
SPILL_SUBDIR = "workbench/tool-results"

#: preview length shown to the model
PREVIEW_CHARS = 2_000


def apply_limit(
    outcome: ToolOutcome, tool: ToolDef, project_dir: Path | str | None
) -> ToolOutcome:
    """Spill an oversized result and return the rewritten one; small results pass unchanged.

    Without a project directory, or when writing fails, truncate and say so; never pass the
    oversized content through.
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
