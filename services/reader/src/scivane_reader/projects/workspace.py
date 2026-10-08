"""Path boundary inside a project.

resolve() is the only entry point for the agent's file access; tools and the sandbox never build
paths themselves. The store (store.py) builds paths directly because it maintains .lumen/;
resolve() refusing .lumen/ means the agent may not touch it.

    .lumen/      no read  no write   policy and logs: writable would mean editing its own limits
    pdf/         read     no write   the source document is the single source of truth
    md/          read     write      fixing OCR errors happens here
    code/        read     write      clone, edit, run
    workbench/   read     write      the agent's default place
    notes/       read     confirm    the user's conclusions; overwriting needs confirmation
    anything     read     write      grows as needed (data/, refs/)
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # type annotations only; no runtime import of sandbox
    from ..sandbox.policy import NetworkPolicy, SandboxMode, SandboxPolicy

#: ASCII names: code/ holds real git repos the agent runs shells in.
CONTROL_DIR = ".lumen"
PDF_DIR = "pdf"
MD_DIR = "md"
CODE_DIR = "code"
WORKBENCH_DIR = "workbench"
NOTES_DIR = "notes"
#: Material the user dropped in. Unlike notes/, it needs no confirmation.
FILES_DIR = "files"

#: created with the project; anything else grows on demand
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
    """Path refused by the boundary; route on the stable code, not the message."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class TierRule:
    readable: bool
    writable: bool
    #: writes need explicit confirmation (only notes/ today)
    needs_confirmation: bool = False
    reason: str = ""


#: top-level dir -> rule; anything unlisted uses _DEFAULT_TIER
TIERS: dict[str, TierRule] = {
    CONTROL_DIR: TierRule(False, False, reason="策略与日志在这里，能碰它就能改自己的权限边界"),
    PDF_DIR: TierRule(True, False, reason="原稿是唯一事实来源，必须不可变"),
    MD_DIR: TierRule(True, True),
    CODE_DIR: TierRule(True, True),
    WORKBENCH_DIR: TierRule(True, True),
    NOTES_DIR: TierRule(True, True, needs_confirmation=True, reason="人写的结论，不能被悄悄覆盖"),
    FILES_DIR: TierRule(True, True, reason="用户给的材料，本来就是给你看的"),
}

#: Tiers a caller may mark as confirmed, derived from TIERS. Anything else is rejected by
#: check_confirmed() at the route and in ToolContext: extra names happen to be harmless today,
#: but nothing structural guarantees it.
CONFIRMABLE_TIERS: frozenset[str] = frozenset(
    name for name, rule in TIERS.items() if rule.needs_confirmation
)

_DEFAULT_TIER = TierRule(True, True)

_ROOT_TIER = TierRule(True, False, reason="要写就写进某个子目录")


def canonical_root(project_dir: Path | str) -> Path:
    """Canonical project root. Path.resolve(), not normpath: symlinks must be followed
    (/tmp is /private/tmp on macOS).
    """
    return Path(project_dir).expanduser().resolve()


def tier_for(relative: Path) -> tuple[str, TierRule]:
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
    """Resolve an agent-supplied path inside the project; out of bounds or not permitted raises.

    Never clamps silently: writing somewhere else while reporting success is worse than an error.
    Raises WorkspaceError: OUT_OF_BOUNDS, READ_DENIED, WRITE_DENIED or NEEDS_CONFIRMATION.
    """
    root = canonical_root(project_dir)
    raw = Path(path).expanduser()

    # Resolve first (symlinks and '..' together), then check containment. Normalising lexically
    # first would let md/link/../../../etc escape. resolve() is fine with paths that don't exist yet.
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
    """Every confirmed dir must be in CONFIRMABLE_TIERS; returned unchanged.

    Unknown names raise NOT_CONFIRMABLE instead of being skipped, or "notes/" with a slash would
    silently count as unconfirmed.
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
    """Readable form of the tier table for the UI and prompts; tests pin it."""
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
    """Translate the tier table into a sandbox file policy.

    Kept next to TIERS so the two never drift: resolve() governs file tools, this governs
    subprocesses (a shell redirect never passes through resolve()). notes/ is write-denied unless
    the caller lists it in `confirmed` for this call. Reads also deny the user's whole home and
    re-open only the project root and runtime dirs; the most specific rule wins, so .lumen/ stays
    denied. Network is a separate axis passed through as is; None means no network.
    """
    from .. import config
    from ..sandbox.policy import FilePolicy, NetworkPolicy as _NetworkPolicy, SandboxPolicy

    root = canonical_root(project_dir)
    deny_write: list[Path] = []
    deny_read: list[Path] = []

    for name, rule in TIERS.items():
        if not rule.readable:
            deny_read.append(root / name)
            deny_write.append(root / name)
        elif not rule.writable:
            deny_write.append(root / name)
        elif rule.needs_confirmation and name not in confirmed:
            deny_write.append(root / name)

    # OCR locations are not part of the paper, not even readable
    deny_read.extend(config.SANDBOX_DENY_READ)

    # Deny the whole home and re-open only what the agent needs; the most specific rule wins
    # (FilePolicy.read_rules()).
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
    """Paths a sandboxed process can't start without, all inside the read-denied home: the bundled
    interpreter and shared env, the dev interpreter's base, and git's empty hooks dir.

    Paths equal to or containing a private root are refused: re-opening one would undo the home
    deny. A python tool that fails to start beats a silently open home.
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
