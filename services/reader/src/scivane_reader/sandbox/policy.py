"""沙箱能力缝：只定义词汇与接口，不涉及任何具体实现。

**为什么是能力缝而不是直接写死 Seatbelt。**
macOS 上唯一能约束子进程的东西是 `sandbox-exec`（Seatbelt），而 Apple 已经
把它标记为弃用且至今没给替代品 —— App Sandbox 要代码签名与 entitlement，
是给 App Store 的 GUI 应用设计的，管不了我们要约束的子进程。它现在还能用，
但必须当成**会消失的东西**来设计：
这里只放接口，`seatbelt.py` 是当前的一个实现，哪天它没了换一个实现即可，
消费者（bash / python 执行器）一行都不用改。

这一层**不知道「论文」「项目」是什么** —— 它只认「工作区根目录」和四元组
文件策略。把项目分层规则翻译成 `FilePolicy` 的是 `projects/workspace.py`，
那样翻译逻辑与分层表在同一个文件里，两者不可能漂移。
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Literal

__all__ = [
    "SandboxMode", "SandboxEnforcement", "FilePolicy", "NetworkPolicy", "SandboxPolicy",
    "RunnerFailureRule", "ConfinedCommand", "SandboxProvider",
    "SandboxError", "SandboxUnavailable", "SandboxRunnerFailed",
    "REQUIRED_WRITE_SINKS",
]


#: 文件效果的模式。**刻意只有两态，没有 danger-full-access。**
#:
#: 通用 agent 需要「不约束」这一档，是因为用户的任务不可枚举；论文 agent 的
#: 任务是可枚举的（审校正文、跑论文代码、画图），留一个全权逃生口的唯一结果
#: 是它会变成默认选项 —— 遇到任何不顺手的情况，最省事的做法永远是关掉约束。
#:
#: 这里只保留两种文件效果，不提供第三态。它只管**文件效果**：
#: 网络与进程可见性不在这套词汇里（我们的网络是直接全禁，见 seatbelt.py）。
SandboxMode = Literal["read-only", "workspace-write"]

#: 执行强度：这次约束到底兑现了多少。
#:
#: **这是可报告的事实，不是假设。** 不同后端、
#: 不同内核版本能兑现的承诺不一样，调用方需要绝对边界时必须能看出差别，
#: 而不是拿到一个「看起来成功了」的结果。`partial` 的具体原因放在
#: `ConfinedCommand.enforcement_reason` 里，原样交给上层。
SandboxEnforcement = Literal["full", "partial"]

#: shell 与多数工具离了就没法正常跑的写入口。
#:
#: 这几个不放行的话，`deny file-write*` 会连 `cmd >/dev/null` 都一起拦掉 ——
#: 实测中第一版就栽在这里：以为是网络被禁，其实是重定向失败。
REQUIRED_WRITE_SINKS: tuple[str, ...] = (
    "/dev/null", "/dev/zero", "/dev/random", "/dev/urandom",
    "/dev/tty", "/dev/stdin", "/dev/stdout", "/dev/stderr",
    "/dev/fd", "/dev/dtracehelper",
)


@dataclass(frozen=True)
class FilePolicy:
    """文件权限四元组。

    形态采用四组明确的读写规则（allowWrite / denyWrite / allowRead / denyRead），
    但有一处关键不同：
    **我们的 `allow_write` 不做用户可配**，它由 `projects/workspace.py` 的分层
    规则直接生成。用户能配的边界等于没有边界 —— 一旦出现「加个路径就好了」
    的操作，它就会被加。

    **读：最具体的那条说了算**（`read_rules()`）。三层是真实需求 —— 整个用户 home 拒读，
    项目根与运行环境在里面开回来，项目自己的 `.lumen/` 又在开回来的项目根里再拒掉。
    从前的规则是「`allow_read` 永远高于 `deny_read`」，只表达得出两层：
    开回项目根的那一刻，`.lumen/` 也跟着开了。同一路径上既拒又放时拒绝赢（fail-closed）。

    写这一侧没有对称的「重新放行」—— 写权限只会越收越紧，不会在拒绝区域里开口子。
    """

    #: 允许写入的根（含子树）。
    allow_write: tuple[Path, ...] = ()
    #: 在 `allow_write` 区域内重新拒绝的子树。
    deny_write: tuple[Path, ...] = ()
    #: 拒绝读取的子树。
    deny_read: tuple[Path, ...] = ()
    #: 在 `deny_read` 区域内重新放行的子树。更深的那条说了算，见 `read_rules()`。
    allow_read: tuple[Path, ...] = ()

    def read_rules(self) -> tuple[tuple[Path, bool], ...]:
        """读规则排好序：`(规范路径, 是否放行)`，**越靠后越优先**。

        按路径层数从浅到深；同一层数上放行在前、拒绝在后（同一路径两条都有时拒绝赢）。
        SBPL 后写覆盖先写，所以后端照这个顺序逐条写出去，就是「更深的那条说了算」；
        `readable()` 按同一个顺序算，两处不会漂移。

        路径先按文件系统语义解析（`Path.resolve()`）—— macOS 上 `/tmp` 是指向 `/private/tmp`
        的符号链接，不解析的话规则一条都匹配不上而且不会报错（seatbelt.py 的 `canonical_roots`）。
        """
        seen: dict[tuple[str, bool], tuple[Path, bool]] = {}
        for paths, allow in ((self.deny_read, False), (self.allow_read, True)):
            for raw in paths:
                path = Path(raw).expanduser().resolve()
                seen.setdefault((str(path), allow), (path, allow))
        return tuple(sorted(seen.values(), key=lambda rule: (len(rule[0].parts), not rule[1])))

    def readable(self, path: Path | str) -> bool:
        """按 `read_rules()` 算这个路径读不读得到。底座是「默认放行」（Seatbelt 的 `allow default`）。

        给测试与排障用：一条规则写没写对，问它比读 SBPL 文本可靠。
        """
        target = Path(path).expanduser().resolve()
        verdict = True
        for root, allow in self.read_rules():
            if target == root or target.is_relative_to(root):
                verdict = allow
        return verdict


@dataclass(frozen=True)
class NetworkPolicy:
    """网络是**独立于文件的一条轴**。

    **刻意不塞进 `SandboxMode`。** mode 管的是文件效果；把两件事编码进同一个
    枚举，「可写但无网」「只读但有网」这类组合就表达不出来，而它们都是真实需求
    （codex 的 `PermissionProfile` 同样把 filesystem 与 network 拆成两条轴，
    每条各自有默认值）。

    **默认关。** 一个没填的策略必须是最小权限的那一个 —— 忘了设的后果应该是
    "跑不通"，而不是"悄悄放开了"。

    开放时**不是"给网"，是开一个针孔**：沙箱只能到达 `proxy_port` 这一个回环
    端口，由本地审计代理在那头做策略与记账。`proxy_token` 只是要透传给子进程的
    一串字符，这一层不关心它的含义 —— 沙箱层不知道"论文""项目"是什么，
    也不该知道"审计"是什么。
    """

    #: None 表示完全无网。设了就是"只能到这个回环端口"。
    proxy_port: int | None = None
    #: 子进程拿去认证自己的凭据，由上层生成。空字符串表示不需要。
    proxy_token: str = ""

    @property
    def enabled(self) -> bool:
        return self.proxy_port is not None

    def __post_init__(self) -> None:
        if self.proxy_port is not None and not (0 < self.proxy_port < 65536):
            raise ValueError(f"代理端口不合法：{self.proxy_port}")


@dataclass(frozen=True)
class SandboxPolicy:
    """一次执行的完整文件策略。

    **按调用携带，不固定在 provider 上。** 同一时刻
    可能有两个消费者在不同边界下执行 —— 比如一个 bash 工具在 `read-only` 下
    看一眼，另一个 python 工具正在 `workspace-write` 下写产物。provider 一旦
    持有可变的策略状态，这两者就会互相污染，而且这种 bug 只在并发时出现。

    所以 provider 必须是无状态的：`confine()` 把策略当成完全指定的输入。
    """

    mode: SandboxMode
    #: 工作区根。`workspace-write` 下唯一可写的根；`read-only` 下仍然携带，
    #: 这样调用方可以先解析策略再决定走哪条路。
    workspace_root: Path
    files: FilePolicy = field(default_factory=FilePolicy)
    #: 网络。带默认值 —— 既有的每个构造点都不必改，而默认是"无网"。
    network: NetworkPolicy = field(default_factory=NetworkPolicy)

    def __post_init__(self) -> None:
        if self.mode not in ("read-only", "workspace-write"):
            raise ValueError(f"未知的沙箱模式：{self.mode}")
        if not self.workspace_root.is_absolute():
            raise ValueError(f"工作区根必须是绝对路径：{self.workspace_root}")


@dataclass(frozen=True)
class RunnerFailureRule:
    """「沙箱自己没起来」的证据规则。

    必须与「命令被沙箱正常拒绝」区分开：前者意味着命令**根本没跑**，属于基础
    设施故障，要原样报给用户；后者意味着约束正常工作并挡住了越界动作，是预期
    行为。两者都表现为非零退出 + stderr 有东西，只看退出码分不出来。

    判定顺序：先按退出码过滤，再逐行剔除
    `informational_lines`（整行相等，大小写不敏感），最后在剩下的行里找
    `fatal_signatures`。**光有非零退出码永远不足以证明 runner 失败。**
    """

    fatal_signatures: tuple[str, ...]
    #: 只在这些非零退出码上匹配；None 表示任何非零退出码都可以。
    allowed_exit_codes: tuple[int, ...] | None = None
    #: 匹配前先整行剔除的良性提示，避免一句无害的 runner 提示自己构成"失败证据"。
    informational_lines: tuple[str, ...] = ()

    def matched_line(self, exit_code: int, stderr: str) -> str | None:
        """命中就返回那一行原文，否则 None。分类不改写 stderr。"""
        if exit_code == 0:
            return None
        if self.allowed_exit_codes is not None and exit_code not in self.allowed_exit_codes:
            return None
        benign = {line.strip().lower() for line in self.informational_lines}
        for line in stderr.splitlines():
            if line.strip().lower() in benign:
                continue
            lowered = line.lower()
            if any(sig.lower() in lowered for sig in self.fatal_signatures):
                return line
        return None


@dataclass
class ConfinedCommand:
    """`confine()` 的产物：调用方应当**代替自己原本的 argv** 去启动的东西。

    带着 `close()` 是因为 Seatbelt 需要一个落盘的 .sb 配置文件，它必须活到
    进程起来为止、之后要收掉。用 `with` 最稳妥。
    """

    argv: tuple[str, ...]
    enforcement: SandboxEnforcement
    #: `partial` 时说明少兑现了什么；`full` 时为空串。原样交给上层，不要吞掉。
    enforcement_reason: str = ""
    #: 本后端**拒绝一次文件效果**时 stderr 长什么样（Seatbelt 是 EPERM 文案）。
    #: 跨后端取并集是错的 —— 那会声称某个后端根本不会产生的拒绝形态。
    denial_signatures: tuple[str, ...] = ()
    #: 命中拒绝方言、但**不是 agent 撞到边界**的已知良性行。
    #:
    #: 判拒绝之前先按子串剔掉这些，否则系统工具自己那点无关紧要的写失败会把
    #: 每一次执行都报成「越界」—— 狼来了喊多了，真的越界就没人看了。
    #: 这里也用同样的规则剔除拒绝侧的良性提示。
    #: **只影响分类，不改写 stderr** —— 原文照样交给上层。
    informational_denials: tuple[str, ...] = ()
    runner_failure_rules: tuple[RunnerFailureRule, ...] = ()
    #: 生成的策略文本，留给审计与排障（**不含**任何凭据，只有路径）。
    profile: str = ""
    _cleanup: Callable[[], None] | None = None

    def close(self) -> None:
        if self._cleanup is not None:
            self._cleanup()
            self._cleanup = None

    def __enter__(self) -> "ConfinedCommand":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


class SandboxError(Exception):
    """沙箱侧的失败。带稳定 code，调用方据此路由而不是解析文案。"""

    code = "SANDBOX_ERROR"

    def __init__(self, message: str, code: str | None = None) -> None:
        super().__init__(message)
        if code is not None:
            self.code = code


class SandboxUnavailable(SandboxError):
    """这台机器上没有可用的沙箱后端。

    **拿到它只有一条正确反应：拒绝执行。** 绝不能退回去跑一个不受约束的进程 ——
    那正是我们要避免的情况，而且用户不会察觉；所以这里明确拒绝执行。
    """

    code = "SANDBOX_UNAVAILABLE"


class SandboxRunnerFailed(SandboxError):
    """沙箱后端自己没起来，命令根本没跑。与「命令被拒绝」是两回事。"""

    code = "SANDBOX_RUNNER_FAILED"


class SandboxProvider(ABC):
    """把一条 argv 包成「在本机受约束执行」的等价 argv。

    实现必须**要么返回真正生效的 argv，要么当场失败**。
    静默放行一个不受约束的进程在任何情况下都不合法。
    """

    #: 实现名，进日志与错误消息用。
    name: str = "abstract"

    @abstractmethod
    def available(self) -> bool:
        """这台机器上这个后端能不能用。"""

    @abstractmethod
    def confine(self, argv: tuple[str, ...] | list[str], policy: SandboxPolicy) -> ConfinedCommand:
        """:raises SandboxUnavailable: 后端不可用时。"""
