"""厂商无关的消息与流式词汇。

设计要点是**终止分片协议**：每个流恰好以一个 `Finish` 结束，正常与失败
都走同一个出口。调用方不必用 try/except 去分辨「流正常结束」和「流中途
炸了」—— 终态自带全部信息。这让上层的重试与恢复逻辑好写很多。
（统一各厂商流式响应的形状。）
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal, TypeAlias

from .errors import LlmFailure

Role: TypeAlias = Literal["user", "assistant"]

#: 请求用途。前台问答可以重试；后台任务（生成标题、摘要）不该跟前台抢配额。
#: 前台来源可以重试过载错误，后台任务不与前台争抢重试预算。
Purpose: TypeAlias = Literal["foreground", "background"]


# --- 内容块 -------------------------------------------------------------

@dataclass(frozen=True)
class TextBlock:
    text: str


@dataclass(frozen=True)
class ImageBlock:
    """base64 编码的图片。论文里的图表走这条路。"""

    data: str
    media_type: str = "image/png"


@dataclass(frozen=True)
class ToolUseBlock:
    """助手消息里的一次工具调用。

    放在内容块里而不是单独的字段，是为了让「模型这一轮说了什么 + 想调什么」
    保持在同一条消息里 —— 回放时不必把两处拼起来。
    """

    id: str
    name: str
    arguments: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class ToolResultBlock:
    """工具结果。按 Anthropic 的形状放进一条 user 消息里。

    **为什么不引入 role="tool"**：三家协议对工具结果的载体不一样（OpenAI 用
    独立的 tool 角色，Gemini 用 functionResponse part，Anthropic 放在 user
    消息的内容块里）。统一词汇只能选一种，选最能表达的那种 —— Anthropic 的
    形状允许一条消息里带多个结果，正好对应「并发跑完一批工具再一起交回去」。
    另外两家由适配器翻译过去。
    """

    call_id: str
    content: str
    is_error: bool = False


ContentBlock: TypeAlias = TextBlock | ImageBlock | ToolUseBlock | ToolResultBlock


@dataclass(frozen=True)
class Message:
    role: Role
    content: tuple[ContentBlock, ...]

    @staticmethod
    def text(role: Role, text: str) -> Message:
        """便利构造：纯文本消息。"""
        return Message(role=role, content=(TextBlock(text),))


# --- 工具 ---------------------------------------------------------------

@dataclass(frozen=True)
class ToolSchema:
    """**模型能看到的全部工具信息，只有这三个字段。**

    主机侧的东西（怎么执行、能不能并发、结果上限多大、要不要用户批准）
    一律不在这里 —— 那些属于 `tools/definition.py`，由注册表导出时剥掉。
    这条分离把主机侧执行策略严格排除在 `inputSchema`
    之外，只有 schema 进请求。混在一起的后果是主机侧策略泄漏进提示词，
    模型会开始就「我能不能并发」发表意见。
    """

    name: str
    description: str
    #: JSON Schema（object）。
    parameters: dict[str, object] = field(default_factory=dict)

    def as_dict(self) -> dict[str, object]:
        return {
            "name": self.name,
            "description": self.description,
            "parameters": self.parameters or {"type": "object", "properties": {}},
        }


# --- 用量 ---------------------------------------------------------------

@dataclass(frozen=True)
class Usage:
    """一次请求的 token 用量。

    缓存命中与缓存写入分开记，因为两者计费差别很大 —— 命中通常只要原价的
    一到两成，写入反而略贵于普通输入。合成一个数字就看不出缓存到底有没有
    生效了，而缓存是否生效正是本产品最关心的指标。
    """

    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0

    def merged(self, other: Usage) -> Usage:
        """合并两次上报。流式接口常常分多次给出用量。"""
        return Usage(
            input_tokens=self.input_tokens + other.input_tokens,
            output_tokens=self.output_tokens + other.output_tokens,
            cache_read_tokens=self.cache_read_tokens + other.cache_read_tokens,
            cache_write_tokens=self.cache_write_tokens + other.cache_write_tokens,
        )

    def as_dict(self) -> dict[str, int]:
        return {
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "cache_write_tokens": self.cache_write_tokens,
        }


# --- 流式分片 -----------------------------------------------------------

@dataclass(frozen=True)
class TextDelta:
    """正文增量。"""

    text: str


@dataclass(frozen=True)
class ThinkingDelta:
    """推理过程增量（支持该能力的模型才有）。"""

    text: str


@dataclass(frozen=True)
class ToolCall:
    """一次**完整**的工具调用。

    刻意不做成增量分片：三家都把参数当 JSON 片段流式吐出来，半个 JSON 对
    调度毫无用处，而「攒完再发」让适配器之上的所有代码都不必处理不完整状态。
    代价是界面上看不到参数逐字出现 —— 对论文工具（参数都很短）不值得换。
    """

    id: str
    name: str
    arguments: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class UsageUpdate:
    """用量上报。可能在流中出现多次，取最后一次或按 merged 累加。"""

    usage: Usage


@dataclass(frozen=True)
class Finish:
    """流的终态。每个流恰好产生一个。

    - `stop`      正常结束
    - `tool_use`  模型要求调用工具，等结果再继续
    - `length`    撞到输出上限被截断
    - `error`     失败，`failure` 必有值
    - `aborted`   被取消，`failure` 必有值

    `tool_use` 是独立终态而不是 `stop` 的一种：循环要据它决定「再转一轮」
    还是「这一轮说完了」，靠检查内容里有没有 ToolUseBlock 来推断会把
    「模型既说了话又调了工具」和「只说了话」搞混。
    """

    kind: Literal["stop", "tool_use", "length", "error", "aborted"]
    failure: LlmFailure | None = None
    usage: Usage | None = None

    def __post_init__(self) -> None:
        if self.kind in ("error", "aborted") and self.failure is None:
            raise ValueError(f"{self.kind} 终态必须携带 failure")


StreamChunk: TypeAlias = TextDelta | ThinkingDelta | ToolCall | UsageUpdate | Finish


# --- 请求 ---------------------------------------------------------------

#: 没有单独配置时用哪一档。
#:
#: 取 medium 而不是 low：论文场景里「核对公式和代码是否等价」这类活儿
#: 确实需要推理，砍到最低会让结论变浅。
REASONING_DEFAULT = "medium"
#: 允许的档位。**"none" 不是所有厂商都支持**，见各适配器。
REASONING_LEVELS = ("none", "low", "medium", "high")


@dataclass(frozen=True)
class CallRequest:
    """一次模型调用。构造之后不应再改 —— 冻结是为了让缓存前缀可被信任。"""

    model: str
    messages: tuple[Message, ...]
    system: str | None = None
    max_tokens: int | None = None
    temperature: float | None = None

    #: 前 N 条 messages 属于静态上下文（system 恒为静态）。
    #:
    #: 对 Scivane 来说这就是那篇论文的 Markdown：整个会话里逐字节不变，
    #: 正好是各家 prompt 缓存的理想输入。适配器据此决定怎么打缓存点。
    #: 详见 cache.py。
    cacheable_prefix: int = 0

    #: 这次调用允许模型使用的工具。**只含模型可见字段**（见 ToolSchema）。
    tools: tuple[ToolSchema, ...] = ()

    #: 推理预算（"none" / "low" / "medium" / "high"）。
    #:
    #: **中立值，由各家适配器翻成自己的参数** —— OpenAI 系是
    #: `reasoning_effort`，Anthropic 是 `thinking.budget_tokens`，
    #: Gemini 是 `thinkingConfig.thinkingBudget`。这一层不认识任何厂商，
    #: 所以这里只表达「想让它想多久」。
    #:
    #: **为什么必须显式传。** 不传的话各家用自己的默认，而推理模型的默认
    #: 往往是「想很久」：实测一轮 121 秒里 113 秒是生成，其中一步 78.5 秒。
    #: 这样每家服务都收到同一个明确的推理档位。
    reasoning: str | None = None

    purpose: Purpose = "foreground"

    #: 透传给厂商的额外字段，用于覆盖个别厂商的专有参数。
    extra: dict[str, object] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.model:
            raise ValueError("model 不能为空")
        if self.cacheable_prefix < 0 or self.cacheable_prefix > len(self.messages):
            raise ValueError(
                f"cacheable_prefix={self.cacheable_prefix} 超出消息数 {len(self.messages)}"
            )
