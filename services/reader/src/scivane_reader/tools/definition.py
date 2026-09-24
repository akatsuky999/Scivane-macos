"""工具定义：**模型可见的部分与主机侧的部分严格分开。**

这是本子包最重要的一条结构约定。`ToolDef` 里既有发给模型的三个字段
（`name` / `description` / `parameters`），也有只有主机看得到的字段
（怎么执行、能不能并发、是不是只读、结果上限多大、要不要用户批准）。
**导出 schema 时必须把后者整个剥掉** —— `schema()` 是唯一出口。

模型可见的 schema 与主机侧执行策略严格分开。
混在一起的后果不是报错，而是**主机侧策略泄漏进提示词**：模型看见
`concurrency_safe: false` 就会开始就「我能不能并行」发表意见，甚至试图说服你
放开它。边界不该拿出来和模型讨论。

默认值一律**fail-closed**：没声明就是不能并发、
不是只读、不可破坏。新增工具时忘了声明，后果是跑得慢，而不是跑出危险行为。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Awaitable, Callable, Protocol

from ..llm.types import ToolSchema
from ..projects.workspace import WorkspaceError, check_confirmed

if TYPE_CHECKING:
    from ..netproxy import CallNetwork

__all__ = [
    "ToolContext", "ToolOutcome", "ToolDef", "ToolError",
    "UNLIMITED_RESULT", "DEFAULT_MAX_RESULT_CHARS",
]

#: 结果不落盘。给**自己已经有上限**的工具用。
#:
#: `read` 必须是这个值：把它的结果落盘再给模型一个路径，模型下一步就会去
#: read 那个文件，再落一次盘 —— 一个读文件又读回自己的循环。
UNLIMITED_RESULT = math.inf

#: 其余工具的默认上限。超了就落盘，只把预览与路径给模型。
DEFAULT_MAX_RESULT_CHARS = 30_000


class ToolError(Exception):
    """工具拒绝执行。带稳定 code，调用方据此路由而不是解析文案。

    **这不是 bug，是正常出口**：越界、参数不对、需要确认，都走这里，
    错误文本会作为工具结果交回模型，模型还有机会改正重试。
    """

    def __init__(self, message: str, code: str = "TOOL_ERROR") -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class ToolContext:
    """一次工具调用拿得到的全部环境。

    刻意做得很窄：工具只认「我在哪个项目里」和「这次调用被批准了什么」。
    两层 agent 的隔离就靠它 —— 书房那一层的 context 里 `project_dir` 是 None，
    于是任何需要项目目录的工具**在类型层面就用不了**，不靠提示词约束。
    """

    #: 项目根。书房层为 None。
    project_dir: str | None = None
    project_id: str | None = None
    #: 本次调用用户已确认可写的顶层目录（如 ``("notes",)``）。
    #: **只能是需要确认的那几层**（`workspace.CONFIRMABLE_TIERS`），见 `__post_init__`。
    confirmed: tuple[str, ...] = ()
    #: 取消信号。长任务要自己检查它。
    cancelled: Callable[[], bool] = lambda: False
    #: **这一次调用**的联网凭据（端口 + token）。`None` = 无网。
    #:
    #: 按调用携带，不固定在 agent 上 —— 同 `SandboxPolicy` 的理由
    #: （provider 一旦持有可变状态，并发的两个消费者就会
    #: 互相污染）。凭据的生命周期由 Dispatcher 用 `finally` 兜住，
    #: 所以一次调用结束它就不再是一把钥匙。
    network: "CallNetwork | None" = None

    def __post_init__(self) -> None:
        # **带着 `.lumen` 这类名字的上下文造不出来。** `confirmed` 一路直通沙箱策略，
        # 而它今天无害只是因为策略恰好只在需要确认的层上查它。
        # 路由边界已经拦过一次（给客户端一个 422）；这里拦的是其余每一条构造路径 ——
        # 测试、验证脚本、`dataclasses.replace`、将来的子 agent。
        try:
            check_confirmed(self.confirmed)
        except WorkspaceError as exc:
            raise ValueError(str(exc)) from exc


@dataclass(frozen=True)
class ToolOutcome:
    """工具的返回。

    `content` 是交给模型的文本。`detail` 只进会话日志与界面，**不进模型请求** ——
    同一条纪律的另一面：模型看不到的东西就别混在模型看得到的字段里。
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
    """一个工具。"""

    # --- 模型可见 -------------------------------------------------------
    name: str
    description: str
    parameters: dict[str, object]

    # --- 主机侧，绝不进请求 ---------------------------------------------
    run: ToolRun
    #: 能否与同批其它工具并发。默认 False（fail-closed）。
    concurrency_safe: bool = False
    #: 是否只读。只读工具才允许并发，也才不需要用户批准。默认 False。
    read_only: bool = False
    #: 是否不可逆（删除、覆盖、对外发送）。默认 False。
    destructive: bool = False
    #: 结果字符数上限，超了落盘。`UNLIMITED_RESULT` 表示永不落盘。
    max_result_chars: float = DEFAULT_MAX_RESULT_CHARS
    #: 执行前需要用户批准。
    #:
    #: 可以是布尔，也可以是**按参数判定的谓词**。后者是给「这个工具通常不越界，
    #: 只有某些参数才越界」的情况用的：整个工具都设成需批准的话，用户每调一次
    #: 都要点一次，点到最后就是闭着眼睛点，批准这道门也就废了。
    #: （它最早是为 `python` 的 `packages` 加的 —— 那时装包要到宿主端联网；
    #: 装包搬进沙箱之后那个用法退场了。如今
    #: 读者那一层一个要批准的工具都没有，只剩书房的 `delete_project`，用的是布尔。）
    needs_approval: bool | Callable[[dict[str, object]], bool] = False
    #: 需要项目目录才能用 —— 书房层的工具集会被整个过滤掉。
    requires_project: bool = True

    def approval_required(self, arguments: dict[str, object]) -> bool:
        """这一次调用要不要用户点头。**判定出错一律按「要」**（fail-closed）。"""
        if callable(self.needs_approval):
            try:
                return bool(self.needs_approval(arguments))
            except Exception:
                return True
        return bool(self.needs_approval)

    def __post_init__(self) -> None:
        if self.concurrency_safe and not self.read_only:
            # 允许一个会写的工具并发，等于把「谁先写」交给调度时序决定。
            # 这不是性能取舍，是正确性问题，所以在定义期就拦住。
            raise ValueError(f"{self.name}: 只有只读工具可以声明 concurrency_safe")
        if self.parameters.get("type") != "object":
            raise ValueError(f"{self.name}: parameters 必须是 type=object 的 JSON Schema")

    def schema(self) -> ToolSchema:
        """**导出给模型的唯一出口。** 主机侧字段在这里被整个剥掉。"""
        return ToolSchema(
            name=self.name,
            description=self.description,
            parameters=self.parameters,
        )
