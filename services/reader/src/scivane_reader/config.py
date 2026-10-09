"""Runtime configuration. Every value can be overridden by a SCIVANE_* environment variable."""

from __future__ import annotations

import os
import pwd
from pathlib import Path

from . import paths

__all__ = [
    "SOURCE_ROOT",
    "LLAMA_HOST", "LLAMA_PORT", "LLAMA_BASE_URL", "API_HOST", "API_PORT",
    "VAR_DIR", "LOGS_DIR", "JOBS_DIR", "RUN_DIR", "PID_FILE",
    "PIPELINE_VERSION", "LAYOUT_DEVICE", "VL_BACKEND",
    "VL_MAX_CONCURRENCY", "LLAMA_CTX_SIZE",
    "LLM_PROVIDERS_PATH", "LLM_CONNECT_TIMEOUT", "LLM_FIRST_TOKEN_TIMEOUT",
    "LLM_TOTAL_TIMEOUT", "LLM_MAX_RETRIES", "LLM_CONCURRENCY", "LLM_KEEPALIVE",
    "VISION_CACHE_PATH", "TRANSCRIBE_LONG_EDGE", "TRANSCRIBE_CONCURRENCY",
    "CHAT_IMAGE_MAX_BYTES", "CHAT_IMAGES_PER_MESSAGE",
    "TIMING", "TIMING_LOG",
    "PROJECTS_DIR",
    "AGENT_RUNTIME_DIR", "ANALYSIS_ENV_DIR", "PYTHON_DIR", "SANDBOX_DIR", "SANDBOX_HOOKS_DIR",
    "RUNTIME_OVERRIDE", "OCR_COMPONENT_DIR", "LEGACY_RUNTIME_DIR", "PADDLEX_CACHE_DIR",
    "OCR_HF_MIRRORS", "OCR_PYPI_INDEXES", "DOWNLOADS_DIR", "PIP_CACHE_DIR",
    "SANDBOX_TIMEOUT", "SANDBOX_DENY_READ", "USER_HOME", "SANDBOX_PRIVATE_ROOTS",
    "NETPROXY_CONNECT_TIMEOUT", "NETPROXY_IDLE_TIMEOUT", "NETPROXY_AUDIT_LIMIT",
]


#: Repository root; None in a packaged install.
SOURCE_ROOT = paths.SOURCE_ROOT

LLAMA_HOST = os.environ.get("SCIVANE_LLAMA_HOST", "127.0.0.1")
LLAMA_PORT = int(os.environ.get("SCIVANE_LLAMA_PORT", "8111"))
LLAMA_BASE_URL = f"http://{LLAMA_HOST}:{LLAMA_PORT}/v1"

API_HOST = os.environ.get("SCIVANE_API_HOST", "127.0.0.1")
API_PORT = int(os.environ.get("SCIVANE_API_PORT", "8710"))

# Disposable runtime artefacts: logs, pidfiles, crops, sandbox profiles.
# Kept under the user's home, never in the source tree. User data lives in PROJECTS_DIR.
VAR_DIR = Path(os.environ.get("SCIVANE_VAR_DIR", "~/.scivane/var")).expanduser()
LOGS_DIR = VAR_DIR / "logs"
RUN_DIR = VAR_DIR / "run"
PID_FILE = RUN_DIR / "backend.pids"

JOBS_DIR = Path(os.environ.get("SCIVANE_JOBS_DIR", str(VAR_DIR / "jobs")))

PIPELINE_VERSION = os.environ.get("SCIVANE_PIPELINE_VERSION", "v1.6")
# PaddlePaddle has no Metal backend on macOS, so layout analysis runs on CPU.
LAYOUT_DEVICE = os.environ.get("SCIVANE_LAYOUT_DEVICE", "cpu")
VL_BACKEND = os.environ.get("SCIVANE_VL_BACKEND", "llama-cpp-server")
# Must match the llama-server slot count in start_backend.sh.
VL_MAX_CONCURRENCY = int(os.environ.get("SCIVANE_VL_CONCURRENCY", "4"))

# Lowering this truncates or garbles output without raising an error.
LLAMA_CTX_SIZE = int(os.environ.get("SCIVANE_LLAMA_CTX", "16384"))


# Provider settings only; credentials live in llm/credentials.py.
LLM_PROVIDERS_PATH = Path(
    os.environ.get("SCIVANE_LLM_PROVIDERS_PATH", "~/.scivane/providers.json")
).expanduser()

# Split timeouts so a DNS failure fails fast while long answers still fit.
LLM_CONNECT_TIMEOUT = float(os.environ.get("SCIVANE_LLM_CONNECT_TIMEOUT", "10"))
LLM_FIRST_TOKEN_TIMEOUT = float(os.environ.get("SCIVANE_LLM_FIRST_TOKEN_TIMEOUT", "120"))
LLM_TOTAL_TIMEOUT = float(os.environ.get("SCIVANE_LLM_TOTAL_TIMEOUT", "1800"))

LLM_MAX_RETRIES = int(os.environ.get("SCIVANE_LLM_MAX_RETRIES", "5"))
LLM_CONCURRENCY = int(os.environ.get("SCIVANE_LLM_CONCURRENCY", "4"))
# Keep idle provider connections well past httpx's 5 s default;
# reconnecting before every question added seconds to each turn.
LLM_KEEPALIVE = float(os.environ.get("SCIVANE_LLM_KEEPALIVE", "300"))

# Whether each card's model reads images, as last probed. Disposable: a missing file costs one
# small request per card.
VISION_CACHE_PATH = VAR_DIR / "vision.json"

# Cloud transcription renders each page at this long edge (pixels). Dense two-column pages need
# about this much for subscripts; providers downscale anything larger anyway.
TRANSCRIBE_LONG_EDGE = int(os.environ.get("SCIVANE_TRANSCRIBE_LONG_EDGE", "2000"))
# Pages in flight at once. Kept below LLM_CONCURRENCY so a chat question still gets a connection
# while a paper is being transcribed.
TRANSCRIBE_CONCURRENCY = max(1, min(
    int(os.environ.get("SCIVANE_TRANSCRIBE_CONCURRENCY", "3")), LLM_CONCURRENCY - 1 or 1))

# Images attached to a chat message. The app scales them down first; these are the backstop.
# 3.75 MB raw stays under the strictest provider limit (5 MB once base64-encoded).
CHAT_IMAGE_MAX_BYTES = 3_750_000
CHAT_IMAGES_PER_MESSAGE = 8

# Per-turn timing log (llm/timing.py). Off by default; numbers only, never content or credentials.
TIMING = os.environ.get("SCIVANE_TIMING", "") == "1"
TIMING_LOG = LOGS_DIR / "timing.jsonl"


# Papers, Markdown and conversations. Not under VAR_DIR, which is disposable.
PROJECTS_DIR = Path(
    os.environ.get("SCIVANE_PROJECTS_DIR", "~/.scivane/projects")
).expanduser()


# Bundled interpreter, shared analysis env and the OCR component.
# python/ and analysis/ sit inside the read-denied home; workspace.sandbox_policy() re-opens them.
AGENT_RUNTIME_DIR = Path(
    os.environ.get("SCIVANE_AGENT_RUNTIME_DIR", "~/.scivane/runtime")
).expanduser()

# Shared numpy/pandas/matplotlib env. Papers with their own dependencies get a per-project venv.
ANALYSIS_ENV_DIR = AGENT_RUNTIME_DIR / "analysis"

# Staged from the .app by start_backend.sh, which passes the same path via SCIVANE_AGENT_RUNTIME_DIR.
PYTHON_DIR = AGENT_RUNTIME_DIR / "python"


# Local OCR is optional. Discovery order lives in runtime.py; only the locations are configured here.

#: Explicit override: when set, nothing else is searched.
RUNTIME_OVERRIDE: Path | None = (
    Path(os.environ["SCIVANE_RUNTIME_ROOT"]).expanduser()
    if os.environ.get("SCIVANE_RUNTIME_ROOT") else None
)
#: Component installed by the app (runtime.json is versioned).
OCR_COMPONENT_DIR = AGENT_RUNTIME_DIR / "ocr"
#: Legacy hand-built deployment. No default location: only searched when set.
LEGACY_RUNTIME_DIR: Path | None = (
    Path(os.environ["SCIVANE_LEGACY_RUNTIME_DIR"]).expanduser()
    if os.environ.get("SCIVANE_LEGACY_RUNTIME_DIR") else None
)
#: paddlex caches the legacy layout models under the user's home.
PADDLEX_CACHE_DIR = Path("~/.paddlex").expanduser()


def _list(name: str, default: tuple[str, ...]) -> tuple[str, ...]:
    raw = os.environ.get(name)
    return tuple(x.strip() for x in raw.split(",") if x.strip()) if raw else default


# Upstream first, mirrors when it fails or is too slow. Integrity comes from the sha256 table
# and the hashed pip lock, not from the source.
OCR_HF_MIRRORS = _list("SCIVANE_HF_MIRRORS", ("https://hf-mirror.com",))
#: First entry is upstream, the rest are mirrors.
OCR_PYPI_INDEXES = _list(
    "SCIVANE_PYPI_INDEXES", ("https://pypi.org/simple", "https://pypi.tuna.tsinghua.edu.cn/simple")
)
#: Resumable download cache; removed after a successful install.
DOWNLOADS_DIR = VAR_DIR / "downloads"
PIP_CACHE_DIR = VAR_DIR / "pip-cache"

SANDBOX_DIR = Path(os.environ.get("SCIVANE_SANDBOX_DIR", str(RUN_DIR / "sandbox")))
SANDBOX_HOOKS_DIR = SANDBOX_DIR / "empty-hooks"

SANDBOX_TIMEOUT = float(os.environ.get("SCIVANE_SANDBOX_TIMEOUT", "120"))

# Every OCR location is unreadable from the sandbox. Never widen this to AGENT_RUNTIME_DIR:
# the agent's python needs python/ and analysis/.
SANDBOX_DENY_READ: tuple[Path, ...] = tuple(
    p for p in (RUNTIME_OVERRIDE, OCR_COMPONENT_DIR, LEGACY_RUNTIME_DIR) if p is not None
)

#: From the password database, not $HOME, which the launch environment can change.
USER_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)

# Read-denied inside the sandbox: once it has network, anything readable can be exfiltrated.
# Only the project root and the runtime dirs are re-opened. Deliberately not configurable.
SANDBOX_PRIVATE_ROOTS: tuple[Path, ...] = (USER_HOME,)

# The audit proxy binds 127.0.0.1:0; its port is assigned at runtime.

# Much shorter than the command timeout so an unreachable host fails fast.
NETPROXY_CONNECT_TIMEOUT = float(os.environ.get("SCIVANE_NETPROXY_CONNECT_TIMEOUT", "15"))

NETPROXY_IDLE_TIMEOUT = float(os.environ.get("SCIVANE_NETPROXY_IDLE_TIMEOUT", "30"))

NETPROXY_AUDIT_LIMIT = int(os.environ.get("SCIVANE_NETPROXY_AUDIT_LIMIT", "2000"))
