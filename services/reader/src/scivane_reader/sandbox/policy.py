"""Sandbox interface: vocabulary and contracts, no implementation.

sandbox-exec (Seatbelt) is the only way to confine subprocesses on macOS, and Apple has
deprecated it without a replacement. So it sits behind this interface and can be swapped out
without touching the executors. This layer knows nothing about papers or projects;
projects/workspace.py translates the tier table into a FilePolicy.
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


#: File-effect modes. Deliberately only two, no danger-full-access: an escape hatch becomes the
#: default the first time something is inconvenient. Network is a separate axis (NetworkPolicy).
SandboxMode = Literal["read-only", "workspace-write"]

#: How much of the confinement was actually enforced. A reportable fact: callers that need a hard
#: boundary must be able to tell. The reason for `partial` travels in enforcement_reason.
SandboxEnforcement = Literal["full", "partial"]

#: Write sinks shells and most tools can't work without; without them `deny file-write*` also
#: breaks `cmd >/dev/null`.
REQUIRED_WRITE_SINKS: tuple[str, ...] = (
    "/dev/null", "/dev/zero", "/dev/random", "/dev/urandom",
    "/dev/tty", "/dev/stdin", "/dev/stdout", "/dev/stderr",
    "/dev/fd", "/dev/dtracehelper",
)


@dataclass(frozen=True)
class FilePolicy:
    """File permissions: allow_write / deny_write / deny_read / allow_read.

    allow_write is never user-configurable; it comes straight from the workspace tier table.
    Reads follow the most specific rule (read_rules()): the whole home denied, the project root
    and runtime dirs re-opened inside it, the project's .lumen/ denied again inside that. When one
    path is both allowed and denied, deny wins. Writes have no re-opening: they only ever tighten.
    """

    #: writable roots, including subtrees
    allow_write: tuple[Path, ...] = ()
    #: subtrees denied again inside allow_write
    deny_write: tuple[Path, ...] = ()
    #: unreadable subtrees
    deny_read: tuple[Path, ...] = ()
    #: subtrees re-opened inside deny_read; the deeper rule wins (read_rules())
    allow_read: tuple[Path, ...] = ()

    def read_rules(self) -> tuple[tuple[Path, bool], ...]:
        """Read rules as (canonical path, allowed), later entries taking precedence.

        Sorted from shallow to deep, allow before deny at the same depth (so deny wins on ties). SBPL
        lets later rules override earlier ones, so the backend writes them in this order; readable()
        evaluates the same order. Paths are resolved first: /tmp is a symlink to /private/tmp, and an
        unresolved rule silently matches nothing.
        """
        seen: dict[tuple[str, bool], tuple[Path, bool]] = {}
        for paths, allow in ((self.deny_read, False), (self.allow_read, True)):
            for raw in paths:
                path = Path(raw).expanduser().resolve()
                seen.setdefault((str(path), allow), (path, allow))
        return tuple(sorted(seen.values(), key=lambda rule: (len(rule[0].parts), not rule[1])))

    def readable(self, path: Path | str) -> bool:
        """Whether a path is readable under read_rules(), on top of Seatbelt's `allow default`.

        For tests and debugging: asking this beats reading SBPL text.
        """
        target = Path(path).expanduser().resolve()
        verdict = True
        for root, allow in self.read_rules():
            if target == root or target.is_relative_to(root):
                verdict = allow
        return verdict


@dataclass(frozen=True)
class NetworkPolicy:
    """Network is an axis separate from files, so combinations like "writable but offline" can
    be expressed.

    Off by default: a policy nobody filled in must be the least privileged one. When on, it is a
    pinhole, not a network: the sandbox can reach only proxy_port on loopback, where the audit
    proxy enforces policy. proxy_token is opaque to this layer.
    """

    #: None means no network; otherwise only this loopback port
    proxy_port: int | None = None
    #: credential the subprocess presents to the proxy; empty when not needed
    proxy_token: str = ""

    @property
    def enabled(self) -> bool:
        return self.proxy_port is not None

    def __post_init__(self) -> None:
        if self.proxy_port is not None and not (0 < self.proxy_port < 65536):
            raise ValueError(f"代理端口不合法：{self.proxy_port}")


@dataclass(frozen=True)
class SandboxPolicy:
    """The complete policy for one execution.

    Passed per call, never stored on the provider: two consumers may run concurrently under
    different boundaries, and a stateful provider would mix them up.
    """

    mode: SandboxMode
    #: the workspace root: the only writable root in workspace-write mode, carried in read-only too
    workspace_root: Path
    files: FilePolicy = field(default_factory=FilePolicy)
    #: defaults to no network
    network: NetworkPolicy = field(default_factory=NetworkPolicy)

    def __post_init__(self) -> None:
        if self.mode not in ("read-only", "workspace-write"):
            raise ValueError(f"未知的沙箱模式：{self.mode}")
        if not self.workspace_root.is_absolute():
            raise ValueError(f"工作区根必须是绝对路径：{self.workspace_root}")


@dataclass(frozen=True)
class RunnerFailureRule:
    """Evidence that the sandbox itself failed to start, as opposed to the command being refused.

    Both look like a non-zero exit with stderr. Filter by exit code, drop informational lines
    (whole-line, case-insensitive), then look for fatal signatures. A non-zero exit alone never
    proves a runner failure.
    """

    fatal_signatures: tuple[str, ...]
    #: only match on these exit codes; None means any non-zero code
    allowed_exit_codes: tuple[int, ...] | None = None
    #: benign lines removed before matching, so a harmless notice never counts as failure evidence
    informational_lines: tuple[str, ...] = ()

    def matched_line(self, exit_code: int, stderr: str) -> str | None:
        """The matching line, or None. Classification never rewrites stderr."""
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
    """What confine() returns: the argv to launch instead of the original.

    close() removes the on-disk profile once the process has started; use it with `with`.
    """

    argv: tuple[str, ...]
    enforcement: SandboxEnforcement
    #: what wasn't enforced when partial; empty when full. Pass it on, never swallow it.
    enforcement_reason: str = ""
    #: how this backend reports a refused file effect on stderr (EPERM for Seatbelt). Never a union
    #: across backends: that would claim refusals a backend can't produce.
    denial_signatures: tuple[str, ...] = ()
    #: Known benign lines that match the denial dialect but aren't the agent hitting the boundary.
    #: Removed before classifying, so system-tool noise doesn't flag every run as a violation.
    #: Affects classification only; stderr is passed on unchanged.
    informational_denials: tuple[str, ...] = ()
    runner_failure_rules: tuple[RunnerFailureRule, ...] = ()
    #: the generated profile, for audits and debugging (paths only, never credentials)
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
    """Sandbox failure with a stable code; route on it rather than on the message."""

    code = "SANDBOX_ERROR"

    def __init__(self, message: str, code: str | None = None) -> None:
        super().__init__(message)
        if code is not None:
            self.code = code


class SandboxUnavailable(SandboxError):
    """No usable sandbox backend on this machine. The only correct response is to refuse to run;
    never fall back to an unconfined process.
    """

    code = "SANDBOX_UNAVAILABLE"


class SandboxRunnerFailed(SandboxError):
    """The backend itself failed to start, so the command never ran. Not the same as a refusal."""

    code = "SANDBOX_RUNNER_FAILED"


class SandboxProvider(ABC):
    """Wraps an argv so it runs confined on this machine.

    Implementations either return an argv that really is confined or fail on the spot. Silently
    running unconfined is never acceptable.
    """

    #: backend name, for logs and error messages
    name: str = "abstract"

    @abstractmethod
    def available(self) -> bool:
        """Whether this backend works on this machine."""

    @abstractmethod
    def confine(self, argv: tuple[str, ...] | list[str], policy: SandboxPolicy) -> ConfinedCommand:
        """Raises SandboxUnavailable when the backend can't be used."""
