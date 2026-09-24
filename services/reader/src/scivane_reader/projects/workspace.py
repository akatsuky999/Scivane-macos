"""项目内的路径边界。

**这是 agent 侧所有文件访问的唯一入口。** 后面的文件工具与沙箱都必须经过
`resolve()`，不许自己拼路径 —— 一旦有第二条入口，边界就只在其中一条上成立。

需要分清两个身份：

- **agent** 通过 `resolve()` 访问项目，受这里的分层规则约束
- **存储层自己**（store.py）直接用 Path 拼，不走这里 —— 它要读写 `.lumen/`
  才能维护元数据与日志。`resolve()` 拒绝 `.lumen/` 说的是「agent 不许碰」，
  不是「谁都不许碰」

分层规则：

    .lumen/      ✗读 ✗写   策略与日志。能读能写就等于能改自己的权限边界
    pdf/         ✓读 ✗写   原稿是唯一事实来源，必须不可变
    md/          ✓读 ✓写   审校乱码就是要改这里
    code/        ✓读 ✓写   clone、改、跑
    workbench/   ✓读 ✓写   agent 的默认落点
    notes/       ✓读 ⚠写   人写的结论，覆盖需要显式确认
    其它         ✓读 ✓写   骨架之外按需生长（data/、refs/ 之类）
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # 只为类型标注，运行期不建立 projects → sandbox 的导入依赖
    from ..sandbox.policy import NetworkPolicy, SandboxMode, SandboxPolicy

#: 骨架目录名。ASCII 小写 —— code/ 里会是真实 git 仓库，agent 要在里面跑 shell，
#: 中文路径在引号、编码与第三方工具上都是持续的麻烦源。
CONTROL_DIR = ".lumen"
PDF_DIR = "pdf"
MD_DIR = "md"
CODE_DIR = "code"
WORKBENCH_DIR = "workbench"
NOTES_DIR = "notes"
#: 用户从界面拖进来的东西：相关论文、数据、截图。
#: **和 notes/ 分开** —— notes/ 是人**写**的结论（改它要确认），
#: files/ 是人**给**的材料（本来就是给 agent 看的，读写都不必拦）。
FILES_DIR = "files"

#: 建项目时就铺好的骨架。骨架之外（data/、refs/）不预建，等真有东西放时再长。
SKELETON: tuple[str, ...] = (
    CONTROL_DIR,
    PDF_DIR,
    MD_DIR,
    f"{MD_DIR}/assets",
    CODE_DIR,
    f"{WORKBENCH_DIR}/scripts",
    f"{WORKBENCH_DIR}/outputs",
    NOTES_DIR,
    FILES_DIR,
)


class WorkspaceError(Exception):
    """路径被边界拒绝。带稳定 code，调用方据此路由而不是解析文案。"""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class TierRule:
    """一个顶层目录的权限。"""

    readable: bool
    writable: bool
    #: 写入需要显式确认（目前只有 notes/）
    needs_confirmation: bool = False
    reason: str = ""


#: 顶层目录 → 权限。未列出的目录按 `_DEFAULT_TIER` 处理。
TIERS: dict[str, TierRule] = {
    CONTROL_DIR: TierRule(False, False, reason="策略与日志在这里，能碰它就能改自己的权限边界"),
    PDF_DIR: TierRule(True, False, reason="原稿是唯一事实来源，必须不可变"),
    MD_DIR: TierRule(True, True),
    CODE_DIR: TierRule(True, True),
    WORKBENCH_DIR: TierRule(True, True),
    NOTES_DIR: TierRule(True, True, needs_confirmation=True, reason="人写的结论，不能被悄悄覆盖"),
    FILES_DIR: TierRule(True, True, reason="用户给的材料，本来就是给你看的"),
}

#: 调用方**能**替用户声明「已确认」的顶层目录 —— 从 `TIERS` 推出来，不另写一份。
#:
#: 只有标了 `needs_confirmation` 的层能出现在一次调用的 `confirmed` 里。别的名字
#: 出现在那里，今天恰好无害：`sandbox_policy()` 与 `resolve()` 都只在
#: needs_confirmation 的层上查它。**那是实现的巧合，不是结构的保证** —— 哪天有人
#: 把 `confirmed` 当成「这几层放宽」来用，`.lumen` 就能从 HTTP 一路直通沙箱策略。
#: 所以在两处用 `check_confirmed()` 拦：
#: 路由边界（给客户端一个 422）与 `ToolContext` 的构造（带着它的上下文造不出来）。
CONFIRMABLE_TIERS: frozenset[str] = frozenset(
    name for name, rule in TIERS.items() if rule.needs_confirmation
)

#: 骨架之外的目录：可读可写。设计上鼓励按需生长，不预设白名单。
_DEFAULT_TIER = TierRule(True, True)

#: 项目根自身：能列目录，但「写这个目录」本身没有意义。
_ROOT_TIER = TierRule(True, False, reason="要写就写进某个子目录")


def canonical_root(project_dir: Path | str) -> Path:
    """项目根的规范形式。

    用 `Path.resolve()` 而**不是** `os.path.normpath` —— 前者按文件系统语义
    逐段解析符号链接，后者只做词法处理。macOS 上 /tmp 就是指向 /private/tmp
    的符号链接，不解析的话根本对不上。
    """
    return Path(project_dir).expanduser().resolve()


def tier_for(relative: Path) -> tuple[str, TierRule]:
    """相对项目根的路径属于哪一层。"""
    parts = relative.parts
    if not parts or parts == (".",):
        return "", _ROOT_TIER
    top = parts[0]
    return top, TIERS.get(top, _DEFAULT_TIER)


def resolve(
    project_dir: Path | str,
    path: Path | str,
    *,
    write: bool = False,
    confirmed: bool = False,
) -> Path:
    """把 agent 给的路径解析成项目内的真实路径，越界或越权一律抛错。

    **绝不静默截断。** 把越界路径悄悄夹回项目内，会让 agent 以为自己写成功了，
    实际写到了别处 —— 这比直接报错危险得多。

    :param path: 相对项目根的路径；绝对路径也接受，但同样要通过包含性检查。
    :param write: 这次是写操作。
    :param confirmed: 用户已就本次写入给出确认（`notes/` 需要）。
    :raises WorkspaceError: code 为 OUT_OF_BOUNDS / READ_DENIED /
        WRITE_DENIED / NEEDS_CONFIRMATION。
    """
    root = canonical_root(project_dir)
    raw = Path(path).expanduser()

    # 关键顺序：先按文件系统语义解析（符号链接与 .. 一起处理），再做包含性判断。
    # 反过来先做词法归一的话，`md/link/../../../etc` 会被算成 `etc` 之前就丢掉了
    # link 的真实指向，越界就漏过去了。resolve() 对不存在的尾段也安全 ——
    # 写新文件时目标本来就还不存在。
    target = (raw if raw.is_absolute() else root / raw).resolve()

    if target != root and not target.is_relative_to(root):
        raise WorkspaceError(
            f"路径越出项目目录：{path}", "OUT_OF_BOUNDS"
        )

    relative = Path("") if target == root else target.relative_to(root)
    name, rule = tier_for(relative)

    if not rule.readable:
        raise WorkspaceError(
            f"{name}/ 对 agent 不可见" + (f"：{rule.reason}" if rule.reason else ""),
            "READ_DENIED",
        )
    if write:
        if not rule.writable:
            raise WorkspaceError(
                f"{name or '项目根'} 不可写" + (f"：{rule.reason}" if rule.reason else ""),
                "WRITE_DENIED",
            )
        if rule.needs_confirmation and not confirmed:
            raise WorkspaceError(
                f"写入 {name}/ 需要用户确认" + (f"：{rule.reason}" if rule.reason else ""),
                "NEEDS_CONFIRMATION",
            )
    return target


def check_confirmed(names: Iterable[str]) -> tuple[str, ...]:
    """一次调用声明「用户已确认」的目录必须都在 `CONFIRMABLE_TIERS` 里。原样返回。

    **不认识的名字一律拒，不是跳过。** 跳过的话，客户端传一个 `notes/`（比 `notes`
    多一个斜杠）就会被悄悄当成没确认 —— 用户点过的确认白点了，而谁也看不出为什么。

    :raises WorkspaceError: code 为 NOT_CONFIRMABLE。
    """
    given = tuple(names)
    extra = sorted({name for name in given if name not in CONFIRMABLE_TIERS})
    if extra:
        allowed = "、".join(sorted(CONFIRMABLE_TIERS)) or "（无）"
        raise WorkspaceError(
            f"confirmed 只能列需要用户确认才能写的目录（{allowed}），收到：{'、'.join(extra)}",
            "NOT_CONFIRMABLE",
        )
    return given


def describe_tiers() -> list[dict[str, object]]:
    """分层规则的可读形式。给界面与提示词用，也让测试能盯住这张表。"""
    rows: list[dict[str, object]] = []
    for name in (CONTROL_DIR, PDF_DIR, MD_DIR, CODE_DIR, WORKBENCH_DIR, NOTES_DIR):
        rule = TIERS[name]
        rows.append({
            "path": f"{name}/",
            "readable": rule.readable,
            "writable": rule.writable,
            "needs_confirmation": rule.needs_confirmation,
            "reason": rule.reason,
        })
    return rows


def sandbox_policy(
    project_dir: Path | str,
    *,
    mode: SandboxMode = "workspace-write",
    confirmed: tuple[str, ...] = (),
    network: NetworkPolicy | None = None,
) -> SandboxPolicy:
    """把上面那张分层表翻译成沙箱能执行的文件策略。

    **翻译放在这里而不是 sandbox/ 里，是为了让它和 `TIERS` 待在同一个文件。**
    两处维护同一个事实必然漂移，而漂移的那份如果恰好是沙箱用的那份，边界就
    形同虚设 —— 这和 `policy.json` 刻意不镜像 `TIERS` 是同一个理由。

    `resolve()` 管的是文件工具，这里管的是子进程：同一张表，两个执行点。
    agent 在 shell 里 `echo x > pdf/source.pdf` 不会经过 `resolve()`，
    只有沙箱能拦住它。

    `notes/` 这一层要特别说明：它在表里是「可写但需确认」，而沙箱没有「确认」
    这个概念 —— 一条 shell 命令要么能写要么不能写。所以**默认把它划进
    deny_write**，只有调用方拿到用户确认后把它列进 `confirmed`，这一次调用
    才放行。策略按调用解析在这里直接兑现了价值：同一个 provider，
    上一条命令写不了 notes/，下一条（已确认）可以。

    **读的一侧不只这张表**：用户的 home 整个拒读（钥匙、令牌、别的项目都在那），只开回项目根与
    运行环境（`_runtime_roots`）。这张表拒掉的 `.lumen/` 在开回来的项目根里照样拒着 ——
    读规则是「最具体的那条说了算」。

    **网络是另一条轴，这张表管不着它。** 分层表说的是"哪个目录能读能写"，
    与"能不能连出去"正交 —— 两件事编码进一个枚举，「可写但无网」这类组合就
    表达不出来。`network` 原样透传给策略，默认（None）是完全无网。

    :param confirmed: 本次调用已获用户确认的顶层目录名（如 ``("notes",)``）。
    :param network: 网络策略。默认无网 —— 忘了传的后果是"跑不通"，不是"放开了"。
    """
    from .. import config
    from ..sandbox.policy import FilePolicy, NetworkPolicy as _NetworkPolicy, SandboxPolicy

    root = canonical_root(project_dir)
    deny_write: list[Path] = []
    deny_read: list[Path] = []

    for name, rule in TIERS.items():
        if not rule.readable:
            deny_read.append(root / name)
            # 读都不给的目录不必再列进 deny_write —— 但列上没有坏处，
            # 而且让策略文本自己说清楚意图，排障时不用回来查这张表。
            deny_write.append(root / name)
        elif not rule.writable:
            deny_write.append(root / name)
        elif rule.needs_confirmation and name not in confirmed:
            deny_write.append(root / name)

    # 模型部署目录：不是论文的一部分，agent 连读都不需要。
    deny_read.extend(config.SANDBOX_DENY_READ)

    # **用户的 home 整个拒读，只开回 agent 真要读的几处**。
    # 规则是「最具体的那条说了算」（`FilePolicy.read_rules()`）：home 拒掉 → 项目根开回 →
    # 上面那张表里的 `.lumen/` 在项目根里再拒回去；OCR 三档本来就在拒读名单上，不会被开回来。
    deny_read.extend(config.SANDBOX_PRIVATE_ROOTS)
    allow_read = [root, *_runtime_roots(config.SANDBOX_PRIVATE_ROOTS)]

    return SandboxPolicy(
        mode=mode,
        workspace_root=root,
        files=FilePolicy(
            allow_write=(root,) if mode == "workspace-write" else (),
            deny_write=tuple(deny_write),
            deny_read=tuple(deny_read),
            allow_read=tuple(allow_read),
        ),
        network=network if network is not None else _NetworkPolicy(),
    )


def _runtime_roots(private: tuple[Path, ...]) -> list[Path]:
    """沙箱里的进程离了就起不来的几处 —— 都在拒读的 home 里，要显式开回来。

    - 自带解释器（`~/.scivane/runtime/python`）与共享分析环境：python 工具、项目环境的
      venv 都链接到它们
    - 开发模式下的解释器底座（还没拷出自带解释器时 `interpreter()` 退到它，常在 home 里）
    - git 的空 hooks 目录（`core.hooksPath` 指着它）

    **拒绝开回任何「等于或包住」私人区域的路径**：解释器底座若恰好是 `~/bin/python3`，
    它的前缀就是 home 本身 —— 开回它等于整个拒读白做了。那种环境下 python 工具会起不来，
    这比悄悄放开 home 好（约束失效时用户看不出区别，那才是最危险的情况）。
    """
    from .. import config
    from ..sandbox.python import interpreter

    wanted = [
        config.PYTHON_DIR,
        config.ANALYSIS_ENV_DIR,
        interpreter().resolve().parents[1],
        config.SANDBOX_HOOKS_DIR,
    ]
    roots: list[Path] = []
    for candidate in wanted:
        path = Path(candidate).expanduser().resolve()
        swallows = any(path == p.resolve() or p.resolve().is_relative_to(path) for p in private)
        if not swallows and path not in roots:
            roots.append(path)
    return roots
