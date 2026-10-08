"""The execution interface consumers use; executors sit above it, SandboxProvider below.

If the sandbox can't start, nothing runs: an unconfined process is far more dangerous than
one that fails, and the user couldn't tell the difference. "Sandbox failed" and "command
refused" are reported separately (runner_failure_rules first, then denial_signatures).
The environment is built from scratch, never filtered from os.environ: a blocklist always
misses something.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from .policy import (
    ConfinedCommand,
    SandboxEnforcement,
    SandboxPolicy,
    SandboxProvider,
    SandboxRunnerFailed,
    SandboxUnavailable,
)
from .seatbelt import SeatbeltProvider

__all__ = ["ExecResult", "Runner", "MINIMAL_PATH", "build_env"]

#: Not the user's PATH, which can contain anything in any order. Callers add extras (a venv's bin)
#: explicitly.
MINIMAL_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

#: Inside workbench/ because it is writable: a TMPDIR under /tmp is blocked by the sandbox and most
#: tools then fail with an obscure error.
_HOME_SUBDIR = "workbench/home"
_TMP_SUBDIR = "workbench/tmp"


@dataclass
class ExecResult:
    """Result of one confined execution."""

    argv: tuple[str, ...]
    exit_code: int
    stdout: str
    stderr: str
    duration: float
    #: how much of the confinement was enforced; enforcement_reason explains a partial
    enforcement: SandboxEnforcement = "full"
    enforcement_reason: str = ""
    #: the sandbox refused something (this backend's denial dialect on stderr). Not an error: the
    #: boundary worked, and the UI can say so.
    denied: bool = False
    #: the matching line, to explain what was refused; stderr is not rewritten
    denial_hint: str = ""
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.timed_out


def build_env(
    policy: SandboxPolicy,
    *,
    extra_path: tuple[str, ...] = (),
    hooks_dir: Path | None = None,
    extra: dict[str, str] | None = None,
) -> dict[str, str]:
    """Build a minimal environment from scratch.

    No dotfiles: HOME points to workbench/home, so ~/.zshrc, ~/.gitconfig and ~/.npmrc never reach
    the subprocess (bash also runs with --noprofile --norc), and tool caches land in the project.
    No git hooks: core.hooksPath points to an empty dir and GIT_CONFIG_GLOBAL/SYSTEM to /dev/null,
    since a cloned repo's hooks would otherwise run on something as harmless as `git status`.
    """
    root = policy.workspace_root
    path = ":".join((*extra_path, MINIMAL_PATH)) if extra_path else MINIMAL_PATH

    env: dict[str, str] = {
        "PATH": path,
        "HOME": str(root / _HOME_SUBDIR),
        "TMPDIR": str(root / _TMP_SUBDIR),
        "PWD": str(root),
        "LANG": "en_US.UTF-8",
        "LC_CTYPE": "en_US.UTF-8",
        # pin the encoding: papers are full of CJK, Greek and math symbols
        "PYTHONIOENCODING": "utf-8",
        # never pick up ~/.local/lib/pythonX.Y/site-packages; second line of defence after HOME
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        # Apple's git reads one more config, share/git-core/gitconfig, which sets
        # credential.helper = osxkeychain. Every sandboxed git would then touch the Keychain, and with
        # the screen locked it waits forever. Only GIT_CONFIG_NOSYSTEM turns that layer off.
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        # Tell the subprocess it is sandboxed so scripts can adapt. The name is a contract with tests
        # and tools; it carries a value rather than a boolean to avoid "0 vs unset" ambiguity.
        "SCIVANE_SANDBOX": "seatbelt",
        "SCIVANE_SANDBOX_NETWORK": "proxy" if policy.network.enabled else "restricted",
    }
    if policy.network.enabled:
        # The credential travels as the http_proxy username, which curl, pip, git, httpx and requests
        # all understand. Both cases are set: curl ignores HTTP_PROXY on purpose (a historical CGI
        # issue) while other tools read only the upper case. no_proxy is empty so no client bypasses
        # the proxy with its own default exceptions (usually localhost).
        proxy_url = f"http://{policy.network.proxy_token}:@127.0.0.1:{policy.network.proxy_port}"
        env["http_proxy"] = proxy_url
        env["https_proxy"] = proxy_url
        env["HTTPS_PROXY"] = proxy_url
        env["all_proxy"] = proxy_url
        env["ALL_PROXY"] = proxy_url
        env["no_proxy"] = ""
        env["NO_PROXY"] = ""
    if hooks_dir is not None:
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        env["GIT_CONFIG_VALUE_0"] = str(hooks_dir)
    if extra:
        env.update(extra)
    return env


class Runner:
    """Has the provider wrap the argv, then starts the process in the minimal environment."""

    def __init__(
        self,
        provider: SandboxProvider | None = None,
        *,
        hooks_dir: Path | None = None,
        disable_git_hooks: bool = True,
        default_timeout: float = 120.0,
    ) -> None:
        """:param disable_git_hooks: on by default; turning it off needs a good reason."""
        # Profiles go to config.SANDBOX_DIR so the boundary used for a run can be inspected.
        if provider is None:
            from .. import config

            provider = SeatbeltProvider(profile_dir=config.SANDBOX_DIR)
        self._provider = provider
        self._hooks_dir = hooks_dir
        self._disable_git_hooks = disable_git_hooks
        self._default_timeout = default_timeout

    def _hooks(self) -> Path | None:
        """Empty hooks dir, created on first use."""
        if not self._disable_git_hooks:
            return None
        if self._hooks_dir is None:
            from .. import config

            self._hooks_dir = config.SANDBOX_HOOKS_DIR
        self._hooks_dir.mkdir(parents=True, exist_ok=True)
        return self._hooks_dir

    @property
    def provider(self) -> SandboxProvider:
        return self._provider

    def preflight(self) -> None:
        """Raise right away when the sandbox is unavailable, before anything runs."""
        if not self._provider.available():
            raise SandboxUnavailable(
                f"沙箱后端 {self._provider.name} 不可用，拒绝执行。"
                "不受约束地跑一条命令等于没有边界，而用户不会察觉。"
            )

    def run(
        self,
        argv: tuple[str, ...] | list[str],
        policy: SandboxPolicy,
        *,
        cwd: Path | None = None,
        timeout: float | None = None,
        extra_path: tuple[str, ...] = (),
        env_extra: dict[str, str] | None = None,
        stdin: str | None = None,
    ) -> ExecResult:
        """Run one command in the sandbox under this call's `policy`.

        Raises SandboxUnavailable when there is no backend, SandboxRunnerFailed when the backend
        itself failed and the command never ran.
        """
        self.preflight()
        workdir = Path(cwd) if cwd is not None else policy.workspace_root
        self._prepare_dirs(policy)

        env = build_env(
            policy, extra_path=extra_path, hooks_dir=self._hooks(), extra=env_extra
        )
        limit = timeout if timeout is not None else self._default_timeout

        with self._provider.confine(tuple(argv), policy) as confined:
            return self._spawn(confined, tuple(argv), workdir, env, limit, stdin)

    def _prepare_dirs(self, policy: SandboxPolicy) -> None:
        """HOME and TMPDIR are created on the host first; most tools won't mkdir them inside the sandbox.
        Not in read-only mode, which promises no writes.
        """
        if policy.mode != "workspace-write":
            return
        for sub in (_HOME_SUBDIR, _TMP_SUBDIR):
            (policy.workspace_root / sub).mkdir(parents=True, exist_ok=True)

    def _spawn(
        self,
        confined: ConfinedCommand,
        original: tuple[str, ...],
        workdir: Path,
        env: dict[str, str],
        timeout: float,
        stdin: str | None,
    ) -> ExecResult:
        started = time.monotonic()
        timed_out = False
        try:
            proc = subprocess.Popen(
                confined.argv,
                cwd=str(workdir),
                env=env,
                stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                # own process group, so a timeout kills the agent's child processes too
                start_new_session=True,
            )
        except OSError as exc:
            raise SandboxRunnerFailed(f"沙箱后端启动失败：{exc}") from exc

        try:
            stdout, stderr = proc.communicate(input=stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            self._terminate(proc)
            stdout, stderr = proc.communicate()
        duration = time.monotonic() - started
        exit_code = proc.returncode if proc.returncode is not None else -1

        # order matters: runner failure (never ran) before refusal (ran and was blocked)
        for rule in confined.runner_failure_rules:
            line = rule.matched_line(exit_code, stderr)
            if line is not None:
                raise SandboxRunnerFailed(
                    f"沙箱后端没能起来，命令未执行：{line.strip()}"
                )

        hint = self._first_denial(stderr, confined)

        return ExecResult(
            argv=original,
            exit_code=exit_code,
            stdout=stdout or "",
            stderr=stderr or "",
            duration=duration,
            enforcement=confined.enforcement,
            enforcement_reason=confined.enforcement_reason,
            denied=bool(hint),
            denial_hint=hint.strip(),
            timed_out=timed_out,
        )

    @staticmethod
    def _first_denial(stderr: str, confined: ConfinedCommand) -> str:
        """First real denial line, after dropping known benign noise. Classification only;
        stderr is not rewritten.
        """
        benign = tuple(b.lower() for b in confined.informational_denials)
        for line in stderr.splitlines():
            lowered = line.lower()
            if benign and any(b in lowered for b in benign):
                continue
            if any(sig.lower() in lowered for sig in confined.denial_signatures):
                return line
        return ""

    @staticmethod
    def _terminate(proc: subprocess.Popen[str]) -> None:
        """Terminate, then kill, the whole process group (scripts often spawn children)."""
        try:
            group = os.getpgid(proc.pid)
        except OSError:
            group = None
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                if group is not None:
                    os.killpg(group, sig)
                else:
                    proc.send_signal(sig)
            except OSError:
                return
            try:
                proc.wait(timeout=2)
                return
            except subprocess.TimeoutExpired:
                continue
