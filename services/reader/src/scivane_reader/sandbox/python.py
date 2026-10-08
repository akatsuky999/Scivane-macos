"""Python executor: environments built from the bundled interpreter, scripts run in the sandbox.

Two environments, split by where they live:

- the shared analysis env (~/.scivane/runtime/analysis/: numpy, pandas, matplotlib) lives
  outside every project where the sandbox can't write, so the host builds it on first use,
  under a lock, writing the ready marker last;
- per-project envs (<project>/workbench/.venv), only when a paper needs its own dependencies,
  are created and filled inside the sandbox, with pip going through the audit proxy.

The interpreter is the app's bundled one (staged to ~/.scivane/runtime/python/). No uv and
no PATH lookup: an app started from Finder has no homebrew on its PATH.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

from .policy import SandboxPolicy
from .runner import ExecResult, Runner

__all__ = [
    "ANALYSIS_PACKAGES", "PythonEnv", "interpreter",
    "analysis_env", "analysis_ready", "ensure_analysis_env",
    "project_env", "create_project_env", "install_into_project",
    "python_argv", "run_python",
]

#: Only what paper reading actually uses; a grab bag would be slow and suggest the agent can do anything.
ANALYSIS_PACKAGES: tuple[str, ...] = ("numpy", "pandas", "matplotlib")

#: under workbench/: writable, and apart from the paper's own repo in code/
_PROJECT_ENV_SUBDIR = "workbench/.venv"

#: the python executor's cwd, so a relative savefig("fig.png") lands here
_OUTPUTS_SUBDIR = "workbench/outputs"

#: Written last when the shared env is complete; without it the env counts as unfinished
#: and is rebuilt.
_READY_MARKER = ".scivane-ready"

#: --no-input: nobody can answer a prompt in the sandbox.
#: --no-cache-dir: the env itself is the artefact; a cache would duplicate wheels into the user's
#: project (or into ~/Library/Caches/pip on the host).
_PIP_INSTALL: tuple[str, ...] = (
    "-m", "pip", "install", "--disable-pip-version-check", "--no-input",
    "--no-cache-dir", "--progress-bar", "off",
)

#: creating an empty venv takes about a second (ensurepip, offline)
_VENV_TIMEOUT = 120.0

# Two projects running python for the first time build the shared env once. The backend is a
# single process, so a thread lock suffices.
_ANALYSIS_LOCK = threading.Lock()


@dataclass(frozen=True)
class PythonEnv:
    """Location of a venv."""

    root: Path

    @property
    def python(self) -> Path:
        return self.root / "bin" / "python"

    @property
    def bin_dir(self) -> Path:
        return self.root / "bin"

    @property
    def exists(self) -> bool:
        return self.python.exists()


def interpreter() -> Path:
    """Interpreter used to create environments: the bundled one, else the base of the current process
    in development. Its base rather than sys.executable: a dev venv may live in a read-denied place,
    and a project venv's bin/python must link to something the sandbox can read.
    """
    from .. import config

    bundled = config.PYTHON_DIR / "bin" / "python3"
    if bundled.is_file():
        return bundled.resolve()
    return Path(getattr(sys, "_base_executable", sys.executable)).resolve()


def analysis_env(runtime_dir: Path | None = None) -> PythonEnv:
    """Where the shared analysis env lives (not necessarily built yet)."""
    if runtime_dir is not None:
        return PythonEnv(runtime_dir)
    from .. import config

    return PythonEnv(config.ANALYSIS_ENV_DIR)


def analysis_ready(
    packages: tuple[str, ...] = ANALYSIS_PACKAGES, *, runtime_dir: Path | None = None
) -> bool:
    """Whether the shared env is complete and has the expected packages.

    The marker records what was installed, so adding to ANALYSIS_PACKAGES rebuilds old envs; a minor
    interpreter upgrade breaks bin/python and also triggers a rebuild.
    """
    env = analysis_env(runtime_dir)
    if not env.exists:
        return False
    try:
        recorded = json.loads((env.root / _READY_MARKER).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(recorded, dict) and set(packages) <= set(recorded.get("packages", ()))


def ensure_analysis_env(
    packages: tuple[str, ...] = ANALYSIS_PACKAGES,
    *,
    runtime_dir: Path | None = None,
    timeout: float = 600.0,
) -> PythonEnv:
    """Build the shared analysis env on the host if it isn't built yet.

    The ready marker is written last and builds are locked. The interpreter runs with -I: the
    backend's own PYTHONPATH (which may include numpy and pandas from the OCR component) would
    make pip skip packages and still exit 0, failing later inside the clean sandbox. No --isolated:
    the user's pip config (a mirror, say) helps here, and this env has no hash lock.

    Raises CalledProcessError (pip's output is useful, don't swallow it) or TimeoutExpired.
    """
    env = analysis_env(runtime_dir)
    if analysis_ready(packages, runtime_dir=runtime_dir):
        return env
    with _ANALYSIS_LOCK:
        if analysis_ready(packages, runtime_dir=runtime_dir):
            return env
        # leftovers of an unfinished build, or an env with an outdated marker; the app owns this dir
        shutil.rmtree(env.root, ignore_errors=True)
        env.root.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [str(interpreter()), "-I", "-m", "venv", str(env.root)],
            check=True, capture_output=True, timeout=timeout,
        )
        if packages:
            subprocess.run(
                [str(env.python), "-I", *_PIP_INSTALL, *packages],
                check=True, capture_output=True, timeout=timeout,
            )
        (env.root / _READY_MARKER).write_text(
            json.dumps({"packages": list(packages)}, ensure_ascii=False), encoding="utf-8"
        )
    return env


def project_env(project_dir: Path | str) -> PythonEnv:
    """Where the project env lives (not necessarily built yet)."""
    return PythonEnv(Path(project_dir).expanduser().resolve() / _PROJECT_ENV_SUBDIR)


def create_project_env(
    project_dir: Path | str, policy: SandboxPolicy, *, runner: Runner | None = None
) -> ExecResult:
    """Create an empty venv for the project inside the sandbox (with pip; ensurepip is offline).

    (deny file-link) doesn't block the venv's interpreter symlink. No -I here: the sandbox env is
    already built from scratch, and -I would drop PYTHONIOENCODING.

    Raises SandboxUnavailable when there is no sandbox; never builds on the host instead.
    """
    env = project_env(project_dir)
    active = runner if runner is not None else Runner()
    return active.run(
        (str(interpreter()), "-m", "venv", str(env.root)), policy, timeout=_VENV_TIMEOUT
    )


def install_into_project(
    project_dir: Path | str,
    packages: tuple[str, ...],
    policy: SandboxPolicy,
    *,
    runner: Runner | None = None,
    timeout: float = 900.0,
) -> ExecResult:
    """Install packages into the project env inside the sandbox, creating it first if needed.

    Both steps use this call's policy and network credential, so pip's traffic is attributed to
    this python call. Returns pip's result, or the venv step's when that failed.
    """
    env = project_env(project_dir)
    active = runner if runner is not None else Runner()
    if not env.exists:
        created = create_project_env(project_dir, policy, runner=active)
        if not created.ok:
            return created
    return active.run((str(env.python), *_PIP_INSTALL, *packages), policy, timeout=timeout)


def python_argv(env: PythonEnv, script: Path | None = None) -> tuple[str, ...]:
    """Pure. Reads the program from stdin when `script` is None; -u so long jobs show output as they go."""
    if script is not None:
        return (str(env.python), "-u", str(script))
    return (str(env.python), "-u", "-")


def run_python(
    code: str,
    policy: SandboxPolicy,
    *,
    env: PythonEnv | None = None,
    runner: Runner | None = None,
    script: Path | None = None,
    timeout: float | None = None,
) -> ExecResult:
    """Run Python in the sandbox with workbench/outputs/ as cwd, so relative paths in scripts land there.

    Raises SandboxUnavailable when there is no sandbox; never runs unconfined.
    """
    target = env if env is not None else analysis_env()
    active = runner if runner is not None else Runner()

    outputs = policy.workspace_root / _OUTPUTS_SUBDIR
    if policy.mode == "workspace-write":
        outputs.mkdir(parents=True, exist_ok=True)

    return active.run(
        python_argv(target, script),
        policy,
        cwd=outputs if outputs.is_dir() else policy.workspace_root,
        timeout=timeout,
        extra_path=(str(target.bin_dir),),
        env_extra={
            # no display: interactive backends crash
            "MPLBACKEND": "Agg",
            # Not SCIVANE_PROJECT_ROOT, which elsewhere means the code repository root.
            "SCIVANE_WORKSPACE_ROOT": str(policy.workspace_root),
            "SCIVANE_OUTPUT_DIR": str(outputs),
        },
        stdin=None if script is not None else code,
    )
