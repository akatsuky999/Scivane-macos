"""工具注册表。

职责只有三件：按名字找工具、导出模型可见的 schema 列表、按 agent 层级过滤
（书房滤掉要项目目录的，子级只能从父级里挑）。

**不做延迟加载。** 我们工具总共十来个、schema 合起来几千 token，装得下；
再加一层按需加载只会增加无谓的
往返。
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass

from ..llm.types import ToolSchema
from .definition import ToolDef, ToolError

__all__ = ["ToolRegistry", "UNKNOWN_TOOL"]

UNKNOWN_TOOL = "UNKNOWN_TOOL"


@dataclass(frozen=True)
class ToolRegistry:
    """一组工具。不可变 —— 两层 agent 各持一个，互不影响。"""

    tools: tuple[ToolDef, ...] = ()

    def __post_init__(self) -> None:
        names = [t.name for t in self.tools]
        duplicates = {n for n in names if names.count(n) > 1}
        if duplicates:
            # 重名会让 find() 静默返回先注册的那个，排查起来很费时间
            raise ValueError(f"工具重名：{'、'.join(sorted(duplicates))}")

    def find(self, name: str) -> ToolDef:
        """:raises ToolError: 没有这个工具。

        模型偶尔会凭印象发明一个工具名。抛成 ToolError 而不是崩掉，
        错误会作为结果回给模型，它下一轮通常就改对了。
        """
        for tool in self.tools:
            if tool.name == name:
                return tool

        available = "、".join(t.name for t in self.tools) or "（无）"
        raise ToolError(f"没有叫 {name} 的工具。可用：{available}", UNKNOWN_TOOL)

    def schemas(self) -> tuple[ToolSchema, ...]:
        """发给模型的 schema 列表。主机侧字段已被 `ToolDef.schema()` 剥掉。"""
        return tuple(tool.schema() for tool in self.tools)

    def without_project(self) -> "ToolRegistry":
        """书房层用的子集：把需要项目目录的工具整个去掉。

        过滤发生在注册表层面，所以书房层的模型**连这些工具的名字都看不到** ——
        比「给它看见但拒绝执行」干净得多：后者会让模型反复尝试并解释失败。
        """
        return ToolRegistry(tuple(t for t in self.tools if not t.requires_project))

    def restricted_to(self, names: Iterable[str]) -> "ToolRegistry":
        """只留这几个工具。**要一个这里没有的名字就抛** —— 子级只能收窄，不能放宽。

        这是将来给读者派生子 agent 时**唯一**的取工具途径：
        子 agent 的工具集只能从父级的注册表里挑，挑不出父级没有的东西。
        名字拼错也抛，而不是悄悄少给一个 —— 少给的那个工具在子 agent 眼里就是
        「不存在」，它会绕开它另想办法，没人会发现是一个错字。

        顺序跟父级走，不跟 `names` 走：工具集属于 prompt 缓存的静态前缀，
        同一组工具换个顺序就是另一个前缀。

        :raises ValueError: `names` 里有父级没有的工具。这是构造期的编程错误，
            不是模型的错，所以不是 ToolError。
        """
        wanted = set(names)
        missing = sorted(wanted - set(self.names()))
        if missing:
            raise ValueError(f"父级没有这些工具，不能给子级：{'、'.join(missing)}")
        return ToolRegistry(tuple(t for t in self.tools if t.name in wanted))

    def names(self) -> tuple[str, ...]:
        return tuple(t.name for t in self.tools)
