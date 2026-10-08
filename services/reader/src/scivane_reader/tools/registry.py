"""Tool registry: lookup by name, model-visible schema export, filtering per agent level
(the librarian drops project tools; children may only narrow their parent's set).

No lazy loading: a dozen tools fit in a few thousand tokens.
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
    """An immutable set of tools; each agent level holds its own."""

    tools: tuple[ToolDef, ...] = ()

    def __post_init__(self) -> None:
        names = [t.name for t in self.tools]
        duplicates = {n for n in names if names.count(n) > 1}
        if duplicates:
            # duplicates would make find() silently return the first one
            raise ValueError(f"工具重名：{'、'.join(sorted(duplicates))}")

    def find(self, name: str) -> ToolDef:
        """Raises ToolError for unknown names: models occasionally invent one, and the error goes back
        as a result so they can correct it.
        """
        for tool in self.tools:
            if tool.name == name:
                return tool

        available = "、".join(t.name for t in self.tools) or "（无）"
        raise ToolError(f"没有叫 {name} 的工具。可用：{available}", UNKNOWN_TOOL)

    def schemas(self) -> tuple[ToolSchema, ...]:
        """Schemas sent to the model, host-side fields already stripped by ToolDef.schema()."""
        return tuple(tool.schema() for tool in self.tools)

    def without_project(self) -> "ToolRegistry":
        """The librarian's subset: tools needing a project directory are removed entirely, so the model
        never sees their names (better than showing them and refusing).
        """
        return ToolRegistry(tuple(t for t in self.tools if not t.requires_project))

    def restricted_to(self, names: Iterable[str]) -> "ToolRegistry":
        """Keep only these tools. Children may narrow, never widen: an unknown or misspelt name raises
        ValueError instead of silently dropping a tool. The parent's order is kept because the tool
        set is part of the cached prompt prefix.
        """
        wanted = set(names)
        missing = sorted(wanted - set(self.names()))
        if missing:
            raise ValueError(f"父级没有这些工具，不能给子级：{'、'.join(missing)}")
        return ToolRegistry(tuple(t for t in self.tools if t.name in wanted))

    def names(self) -> tuple[str, ...]:
        return tuple(t.name for t in self.tools)
