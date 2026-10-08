"""Seatbelt (sandbox-exec) backend, the only implementation for now.

Apple has deprecated sandbox-exec, so everything here answers only to policy.py's interface.
The generated SBPL (order matters: later rules override earlier ones):

    (version 1)
    (allow default)              ; read and exec allowed by default, see reads below
    (deny network*)              ; no network; when enabled, one loopback pinhole follows
    (deny file-link)             ; blocks hard-link escapes
    (deny mach-lookup ...)       ; no Keychain services
    (deny file-write*)           ; deny all writes
    (allow file-write* ...sinks) ; /dev/null and friends
    (allow file-write* ...roots) ; then the workspace
    (deny file-write* ...carve)  ; then carve out .lumen/ and pdf/
    (deny|allow file-read* ...)  ; reads from shallow to deep, most specific wins
    (allow file-read-metadata ...) ; metadata only for parents of re-opened dirs

Writes are a true allowlist: nothing outside the project is writable. Reads are "allow by
default, deny the user's home", with the project root and runtime dirs re-opened. System dirs
stay readable; a read allowlist would have to enumerate the dyld cache and break binaries.

(deny file-link) stops the agent from creating hard links that point outside the project, but
links that already exist would still work, so confine() scans the writable area and reports
`partial` when it finds files with st_nlink > 1. Symlinks are resolved by Seatbelt and are safe.
"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

from .policy import (
    REQUIRED_WRITE_SINKS,
    ConfinedCommand,
    RunnerFailureRule,
    SandboxPolicy,
    SandboxProvider,
    SandboxUnavailable,
)

__all__ = ["SANDBOX_EXEC", "KEYCHAIN_SERVICES", "SeatbeltProvider", "build_profile", "canonical_roots"]

#: absolute path: PATH is a tainted input
SANDBOX_EXEC = "/usr/bin/sandbox-exec"

#: Seatbelt reports refusals as EPERM, "Operation not permitted" in any locale.
_DENIAL_SIGNATURES: tuple[str, ...] = (
    "operation not permitted",
    "errno 1",
)

#: Known benign EPERM lines. /usr/bin/git is an xcrun shim that tries to write a tool cache under
#: /var/folders/.../T/xcrun_db-*, outside the project, and no environment variable turns that off;
#: git itself works fine. The write allowlist deliberately stays closed for it.
_INFORMATIONAL_DENIALS: tuple[str, ...] = ("xcrun_db",)

#: sandbox-exec prefixes its own diagnostics with its name and exits 65 (EX_DATAERR)
#: for broken or missing profiles.
_RUNNER_FAILURE_RULES: tuple[RunnerFailureRule, ...] = (
    RunnerFailureRule(
        fatal_signatures=("sandbox-exec:",),
        allowed_exit_codes=(65,),
    ),
)

#: Keychain services: legacy file keychains, the system keychain, the data-protection keychain
#: (including iCloud), and SecurityAgent, which shows the unlock prompt.
KEYCHAIN_SERVICES: tuple[str, ...] = (
    "com.apple.SecurityServer",
    "com.apple.securityd",
    "com.apple.securityd.xpc",
    "com.apple.security.agent",
)

#: Hard-link audit limit: cloned repos can hold tens of thousands of files. When the scan can't
#: finish, it reports partial instead of pretending.
_AUDIT_LIMIT = 20000


def _sbpl_string(path: str) -> str:
    """Escape as an SBPL string literal."""
    return '"' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'


def canonical_roots(paths: tuple[Path, ...] | list[Path]) -> list[str]:
    """Canonicalise and deduplicate, keeping order. Symlinks must be resolved first: a rule for /tmp/x
    never matches a process running in /private/tmp/x, and nothing reports the mismatch.
    """
    seen: dict[str, None] = {}
    for path in paths:
        seen.setdefault(str(Path(path).expanduser().resolve()), None)
    return list(seen)


def build_profile(policy: SandboxPolicy) -> str:
    """Translate a policy into SBPL text. Pure, so tests can check the output without starting
    processes.
    """
    forms: list[str] = [
        "(version 1)",
        "(allow default)",
        # deny first; the pinhole must come after it because later rules win
        "(deny network*)",
        # stop the agent from creating hard-link escapes
        "(deny file-link)",
        # No Keychain services: otherwise `git credential-osxkeychain get` or `security find-*` could
        # pull stored tokens without touching a file. security.agent shows the unlock prompt.
        # trustd is not blocked: TLS certificate checks need it.
        "(deny mach-lookup " + " ".join(
            f"(global-name {_sbpl_string(name)})" for name in KEYCHAIN_SERVICES) + ")",
        "(deny file-write*)",
    ]

    # Network is a pinhole: one loopback port, nothing else. Domain policy and accounting happen in
    # the proxy behind it, since Seatbelt only sees ip:port.
    #
    # Never `localhost:*`: loopback also hosts Scivane's unauthenticated API (which injects keys
    # into the backend) and llama-server.
    if policy.network.enabled:
        forms.append(
            f'(allow network-outbound (remote ip "localhost:{policy.network.proxy_port}"))'
        )

    sinks = " ".join(f"(literal {_sbpl_string(p)})" for p in REQUIRED_WRITE_SINKS)
    forms.append(f"(allow file-write* {sinks})")

    if policy.mode == "workspace-write":
        roots = canonical_roots(policy.files.allow_write or (policy.workspace_root,))
        if roots:
            grants = " ".join(f"(subpath {_sbpl_string(r)})" for r in roots)
            forms.append(f"(allow file-write* {grants})")

        carve = canonical_roots(policy.files.deny_write)
        if carve:
            denies = " ".join(f"(subpath {_sbpl_string(r)})" for r in carve)
            forms.append(f"(deny file-write* {denies})")

    # Reads: rules already sorted shallow to deep, so writing them in order makes the deepest win.
    rules = policy.files.read_rules()
    for root, allow in rules:
        verb = "allow" if allow else "deny"
        forms.append(f"({verb} file-read* (subpath {_sbpl_string(str(root))}))")

    # Parents of re-opened dirs inside a denied area get metadata only. Without it git fails with
    # `fatal: failed to stat` while walking up; directory listings stay denied (`ls ~` still fails).
    denied = [root for root, allow in rules if not allow]
    ancestors: dict[str, None] = {}
    for root, allow in rules:
        if not allow or not any(root != d and root.is_relative_to(d) for d in denied):
            continue
        for parent in root.parents:
            ancestors.setdefault(str(parent), None)
    if ancestors:
        forms.append(
            "(allow file-read-metadata "
            + " ".join(f"(literal {_sbpl_string(a)})" for a in sorted(ancestors)) + ")"
        )

    return "\n".join(forms) + "\n"


def audit_hardlinks(policy: SandboxPolicy, limit: int = _AUDIT_LIMIT) -> tuple[bool, str]:
    """Scan the writable area for pre-existing hard links, which path rules can't stop.

    Returns (complete, explanation); the explanation names the files and must be passed on.
    """
    if policy.mode != "workspace-write":
        return True, ""

    roots = canonical_roots(policy.files.allow_write or (policy.workspace_root,))
    skip = set(canonical_roots(policy.files.deny_write))
    found: list[str] = []
    seen = 0

    for root in roots:
        stack = [root]
        while stack:
            current = stack.pop()
            if current in skip:
                continue
            try:
                entries = list(os.scandir(current))
            except (NotADirectoryError, PermissionError, FileNotFoundError):
                continue
            for entry in entries:
                seen += 1
                if seen > limit:
                    return False, f"硬链接审计未跑完：可写区域超过 {limit} 个条目，剩下的没看"
                try:
                    if entry.is_dir(follow_symlinks=False):
                        if entry.path not in skip:
                            stack.append(entry.path)
                    elif entry.is_file(follow_symlinks=False):
                        if entry.stat(follow_symlinks=False).st_nlink > 1 and len(found) < 3:
                            found.append(entry.path)
                except OSError:
                    continue

    if found:
        listed = "、".join(found)
        return False, (
            f"可写区域内存在硬链接（{listed}）—— SBPL 按路径判定，"
            "经硬链接写入会落到项目外的同一个 inode 上"
        )
    return True, ""


class SeatbeltProvider(SandboxProvider):
    """Wraps the caller's argv in `sandbox-exec -f <profile> <argv>`.

    Stateless: the policy is entirely in confine()'s arguments, so one instance can serve two
    consumers with different boundaries at once. A test pins this.
    """

    name = "seatbelt"

    def __init__(
        self,
        *,
        profile_dir: Path | None = None,
        audit_limit: int = _AUDIT_LIMIT,
        sandbox_exec: str = SANDBOX_EXEC,
    ) -> None:
        self._profile_dir = profile_dir
        self._audit_limit = audit_limit
        self._sandbox_exec = sandbox_exec

    def available(self) -> bool:
        return os.path.isfile(self._sandbox_exec) and os.access(self._sandbox_exec, os.X_OK)

    def confine(
        self, argv: tuple[str, ...] | list[str], policy: SandboxPolicy
    ) -> ConfinedCommand:
        if not argv:
            raise ValueError("argv 不能为空")
        if not self.available():
            raise SandboxUnavailable(
                f"这台机器上没有可用的沙箱后端：{self._sandbox_exec} 不存在或不可执行。"
                "拒绝执行 —— 不受约束地跑等于没有边界。"
            )

        profile = build_profile(policy)
        path = self._write_profile(profile)
        complete, reason = audit_hardlinks(policy, self._audit_limit)

        return ConfinedCommand(
            argv=(self._sandbox_exec, "-f", str(path), *argv),
            enforcement="full" if complete else "partial",
            enforcement_reason=reason,
            denial_signatures=_DENIAL_SIGNATURES,
            informational_denials=_INFORMATIONAL_DENIALS,
            runner_failure_rules=_RUNNER_FAILURE_RULES,
            profile=profile,
            _cleanup=lambda: shutil.rmtree(path.parent, ignore_errors=True),
        )

    def _write_profile(self, profile: str) -> Path:
        """Write the profile to an .sb file rather than passing it inline with -p: the text is full of
        absolute paths that would show up in the process list, and a file can be inspected while
        debugging. The directory is 0700 and removed after execution.
        """
        if self._profile_dir is not None:
            self._profile_dir.mkdir(parents=True, exist_ok=True)
        holder = Path(tempfile.mkdtemp(prefix="sandbox-", dir=self._profile_dir))
        holder.chmod(0o700)
        path = holder / "policy.sb"
        path.write_text(profile, encoding="utf-8")
        path.chmod(0o600)
        return path
