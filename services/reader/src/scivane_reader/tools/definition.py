"""Tool definitions, with model-visible and host-side fields kept strictly apart.

schema() is the only way out to the model and strips everything host-side (execution,
concurrency, limits, approval). Mixing them doesn't error; it leaks policy into the prompt,
and models start arguing about whether they may run in parallel. Defaults fail closed: not
concurrent, not read-only, not destructive.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Awaitable, Callable, Protocol

from ..llm.types import ToolSchema

if TYPE_CHECKING:
    from ..netproxy import CallNetwork

__all__ = [
    "ToolContext", "ToolOutcome", "ToolDef", "ToolError",
    "UNLIMITED_RESULT", "DEFAULT_MAX_RESULT_CHARS",
]

#: No spilling, for tools that already limit themselves. read must use it: spilling its result
#: to a file the model then reads would loop forever.
UNLIMITED_RESULT = math.inf

#: default limit; beyond it the result spills and the model gets a preview and a path
DEFAULT_MAX_RESULT_CHARS = 30_000


class ToolError(Exception):
    """A tool refused to run. Not a bug: out of bounds, bad arguments and missing confirmation all end
    here, and the message goes back to the model so it can correct itself.
    """

    def __init__(self, message: str, code: str = "TOOL_ERROR") -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class ToolContext:
    """Everything a tool call can see, deliberately narrow: which project, the cancel signal and
    this call's network credential.

    The librarian's context has project_dir None, so project tools are unusable by construction,
    not by prompt.
    """

    #: project root; None at the librarian level
    project_dir: str | None = None
    project_id: str | None = None
    #: cancellation signal; long-running tools check it themselves
    cancelled: Callable[[], bool] = lambda: False
    #: This call's network credential (port and token); None means no network. Per call, never
    #: stored on the agent, and revoked by the dispatcher in `finally`.
    network: "CallNetwork | None" = None


@dataclass(frozen=True)
class ToolOutcome:
    """What a tool returns. `content` goes to the model; `detail` only reaches the log and the UI,
    never the model request.
    """

    content: str
    is_error: bool = False
    detail: dict[str, object] = field(default_factory=dict)


class ToolRun(Protocol):
    def __call__(
        self, arguments: dict[str, object], context: ToolContext
    ) -> Awaitable[ToolOutcome]: ...


@dataclass(frozen=True)
class ToolDef:
    # visible to the model
    name: str
    description: str
    parameters: dict[str, object]

    # host-side, never part of a request
    run: ToolRun
    #: may run alongside other tools in the same batch; fail-closed default
    concurrency_safe: bool = False
    #: read-only tools may run concurrently and never need approval
    read_only: bool = False
    #: irreversible (delete, overwrite, send)
    destructive: bool = False
    #: result size limit in characters; UNLIMITED_RESULT never spills
    max_result_chars: float = DEFAULT_MAX_RESULT_CHARS
    #: Needs the user's approval: a boolean, or a predicate over the arguments for tools that only
    #: cross a line with certain arguments (asking on every call trains people to click yes blindly).
    #: Today only the librarian's delete_project uses it.
    needs_approval: bool | Callable[[dict[str, object]], bool] = False
    #: needs a project directory; the librarian's tool set filters these out
    requires_project: bool = True

    def approval_required(self, arguments: dict[str, object]) -> bool:
        """Whether this call needs approval. Errors in the predicate count as yes (fail-closed)."""
        if callable(self.needs_approval):
            try:
                return bool(self.needs_approval(arguments))
            except Exception:
                return True
        return bool(self.needs_approval)

    def __post_init__(self) -> None:
        if self.concurrency_safe and not self.read_only:
            # A concurrent writer would leave "who writes first" to scheduling; a correctness issue,
            # caught at definition time.
            raise ValueError(f"{self.name}: 只有只读工具可以声明 concurrency_safe")
        if self.parameters.get("type") != "object":
            raise ValueError(f"{self.name}: parameters 必须是 type=object 的 JSON Schema")

    def schema(self) -> ToolSchema:
        """The only export to the model; host-side fields are stripped here."""
        return ToolSchema(
            name=self.name,
            description=self.description,
            parameters=self.parameters,
        )
