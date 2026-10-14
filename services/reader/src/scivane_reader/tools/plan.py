"""plan: the reader's working plan for a task with several parts.

The list lives in the call's own arguments: the latest call in the history is the plan, so it is
logged, replayed and compacted like any other call and nothing is kept on the side. The tool only
checks the shape and answers with the count. Users see the progress on the tool card
(projects/session.summarise_call): on a long job, "plan 3/7: translating section 4" is what tells
them it is moving rather than stuck.
"""

from __future__ import annotations

from .definition import ToolContext, ToolDef, ToolError, ToolOutcome

__all__ = ["plan_tools", "PLAN_MAX_ITEMS", "PLAN_STATUSES"]

#: A plan longer than this is a list of everything rather than a plan.
PLAN_MAX_ITEMS = 20
PLAN_STATUSES = ("pending", "doing", "done")


async def _plan(arguments: dict[str, object], context: ToolContext) -> ToolOutcome:
    items = arguments.get("items")
    if not isinstance(items, list) or not items:
        raise ToolError("items 必须是非空数组，每项是 {step, status}", "INVALID_ARGS")
    if len(items) > PLAN_MAX_ITEMS:
        raise ToolError(f"计划最多 {PLAN_MAX_ITEMS} 项 —— 把相近的步骤合并", "INVALID_ARGS")
    steps: list[tuple[str, str]] = []
    for item in items:
        step = item.get("step") if isinstance(item, dict) else None
        status = item.get("status") if isinstance(item, dict) else None
        if not isinstance(step, str) or not step.strip() or status not in PLAN_STATUSES:
            raise ToolError("每项要有非空的 step，status 是 pending、doing 或 done", "INVALID_ARGS")
        steps.append((step.strip(), status))
    doing = [step for step, status in steps if status == "doing"]
    if len(doing) > 1:
        raise ToolError("同一时间只能有一项是 doing —— 做完一项标成 done，再开始下一项", "INVALID_ARGS")
    done = sum(1 for _, status in steps if status == "done")
    text = f"计划已更新：{done}/{len(steps)} 完成" + (f"，正在：{doing[0]}" if doing else "")
    if done == len(steps):
        # the moment to check the work against the request, before saying it is done
        text += "。全部做完了：收尾之前对照用户的要求把产出核对一遍（数量、完整性、链接与公式）。"
    return ToolOutcome(text, detail={"done": done, "total": len(steps)})


def plan_tools() -> tuple[ToolDef, ...]:
    return (
        ToolDef(
            name="plan",
            description=(
                "记下并更新这件事的工作计划。界面上的工具卡会显示进度（如「计划 2/5：翻第 3 节」），"
                "用户靠它知道你做到哪了、不是卡住了。\n\n"
                "什么时候用：\n"
                "- 要做三步以上、或一轮做不完的事：整篇或几节的译文、复现一张表或一张图、对照论文逐个核对代码里的公式、"
                "要分几部分写的笔记。\n"
                "- 用户一次交代了好几件事。\n"
                "- 被停下、或换了一问之后接着干：先看已经产出的东西（如 read 写到哪了），再更新计划。\n\n"
                "什么时候不用：一问一答、一两步就能做完的事 —— 直接做；不要为了显得有条理给简单的事列计划。\n\n"
                "用法：\n"
                "- 每次都发完整的清单，它整份替换上一次的。每项一句话，说要产出什么。\n"
                "- 同一时间只有一项是 `doing`；做完一项马上标 `done` 再开始下一项。可以和干活的调用在同一轮里一起发。\n"
                f"- 计划变了就改清单；最多 {PLAN_MAX_ITEMS} 项。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "items": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "step": {"type": "string", "description": "这一步要产出什么，一句话"},
                                "status": {"type": "string", "enum": list(PLAN_STATUSES)},
                            },
                            "required": ["step", "status"],
                        },
                        "description": "完整的计划，按顺序",
                    },
                },
                "required": ["items"],
            },
            run=_plan,
            # touches no file; runs alongside the work it describes
            read_only=True,
            concurrency_safe=True,
        ),
    )
