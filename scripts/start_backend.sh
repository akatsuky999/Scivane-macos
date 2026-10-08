#!/bin/bash
# Starts llama-server (Metal) and the Scivane API in the foreground. On TERM/INT it takes its
# children down with it; the app relies on that.
#
# SCIVANE_SKIP_LLAMA=1 starts only the API (light mode, ~50 MB, ~1 s): projects, reading and
# cloud chat don't need the 2.8 GB OCR model. The app restarts in full mode when OCR is needed.
#
#   PROJECT_ROOT       code only: the repository root, or Scivane.app/Contents/Resources/backend
#   AGENT_RUNTIME_DIR  bundled interpreter (python/) and the local OCR component (ocr/)
#   VAR_DIR            runtime output (logs, pidfiles, crops, sandbox policies) in the home dir
# runtime.py decides where local OCR lives; SCIVANE_RUNTIME_ROOT=/some/dir pins one.
#
# The same script runs from the source tree and, copied unchanged by build_backend.sh, from the
# installed bundle (told apart by scivane-package.json). This copy is the source of truth.

set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$PROJECT_ROOT/scivane-package.json" ]; then LAYOUT=package; else LAYOUT=source; fi
cd "$PROJECT_ROOT"

export PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
LLAMA_PORT="${SCIVANE_LLAMA_PORT:-8111}"
API_PORT="${SCIVANE_API_PORT:-8710}"
CTX="${SCIVANE_LLAMA_CTX:-16384}"

# Output never lives next to the code: an installed app has no repository. Same default as config.py.
VAR_DIR="${SCIVANE_VAR_DIR:-$HOME/.scivane/var}"
LOG_DIR="$VAR_DIR/logs"
RUN_DIR="$VAR_DIR/run"
PIDFILE="$RUN_DIR/backend.pids"
mkdir -p "$LOG_DIR" "$RUN_DIR"
# Same default as config.AGENT_RUNTIME_DIR; the value is passed on so both sides agree.
AGENT_RUNTIME_DIR="${SCIVANE_AGENT_RUNTIME_DIR:-$HOME/.scivane/runtime}"

fail() { echo "[scivane] 错误：$*" >&2; exit 1; }

SKIP_LLAMA="${SCIVANE_SKIP_LLAMA:-0}"

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

PORTS=("$API_PORT")
[ "$SKIP_LLAMA" != "1" ] && PORTS+=("$LLAMA_PORT")
for p in "${PORTS[@]}"; do
  if port_busy "$p"; then
    fail "端口 $p 已被占用。改环境变量 SCIVANE_LLAMA_PORT / SCIVANE_API_PORT，或先关掉占用进程。"
  fi
done

# The bundled interpreter is copied to the home dir rather than run inside the .app: venvs record
# its absolute path (moving the app would break them), and any write inside the signed bundle
# (.pyc) breaks the signature. Recopied only when .scivane-build changes, through a .partial
# directory so an interrupted copy never looks complete.
stage_python() {
  local src="$PROJECT_ROOT/python" dest="$AGENT_RUNTIME_DIR/python"
  [ -f "$src/.scivane-build" ] || fail "安装包里缺自带的解释器：$src"
  if [ -x "$dest/bin/python3" ] && cmp -s "$src/.scivane-build" "$dest/.scivane-build"; then
    return
  fi
  echo "[scivane] 安装自带的解释器 → ${dest}（$(cat "$src/.scivane-build")）"
  mkdir -p "$AGENT_RUNTIME_DIR"
  local tmp="$dest.partial.$$"
  # clear leftovers of interrupted copies; the port check guarantees a single instance
  rm -rf "$dest".partial.*
  # -c: clonefile on the same APFS volume, a plain copy across volumes
  cp -Rpc "$src" "$tmp" || { rm -rf "$tmp"; fail "拷贝解释器失败：$src → $tmp"; }
  rm -rf "$dest"
  mv "$tmp" "$dest" || fail "无法把解释器放到 $dest"
}

# --- Interpreter for the API ------------------------------------------------------
# Installed: the bundled interpreter. Source tree: SCIVANE_DEV_PYTHON (default <repo>/.venv).
if [ "$LAYOUT" = "package" ]; then
  stage_python
  PY="$AGENT_RUNTIME_DIR/python/bin/python3"
  CODE_PATH="$PROJECT_ROOT/src:$PROJECT_ROOT/site"
  # The bundle stays unmodified: .pyc files are precompiled and nothing writes bytecode.
  export PYTHONDONTWRITEBYTECODE=1
  # ignore `pip install --user` packages, so dependencies don't vary between machines
  export PYTHONNOUSERSITE=1
  # keep cwd out of sys.path: site/ and python/ must never be importable as modules
  export PYTHONSAFEPATH=1
else
  # not SCIVANE_RUNTIME_ROOT, which only points at OCR
  PY="${SCIVANE_DEV_PYTHON:-$PROJECT_ROOT/.venv/bin/python}"
  CODE_PATH="$PROJECT_ROOT/services/reader/src"
  [ -x "$PY" ] || fail "找不到开发用的 Python：${PY}（设 SCIVANE_DEV_PYTHON，或在仓库里建 .venv）"
fi

# --- Full mode: where local OCR lives ----------------------------------------------
# Resolved by runtime.py alone (override, ~/.scivane/runtime/ocr, legacy deployment).
if [ "$SKIP_LLAMA" != "1" ]; then
  RESOLVED="$(env PYTHONPATH="$CODE_PATH" SCIVANE_AGENT_RUNTIME_DIR="$AGENT_RUNTIME_DIR" \
    "$PY" -m scivane_reader.runtime shell)" || fail "查不出本地 OCR 在哪（${PY} -m scivane_reader.runtime shell 失败）"
  eval "$RESOLVED"
  [ -z "$OCR_PROBLEM" ] || fail "$OCR_PROBLEM"
  echo "[scivane] 本地 OCR：${OCR_TIER} · ${OCR_ROOT}"
  if [ "$LAYOUT" = "package" ]; then
    if [ "$OCR_LAYOUT" = "component" ]; then
      # component layout: OCR packages appended to PYTHONPATH, same bundled CPython 3.12
      CODE_PATH="$CODE_PATH:$OCR_SITE"
    else
      # legacy layout: OCR packages live in the old deployment's venv, which must run the API
      PY="$OCR_VENV_PYTHON"
      CODE_PATH="$PROJECT_ROOT/src"
    fi
  fi
  [ -x "$LLAMA_BIN" ] || fail "找不到 $LLAMA_BIN"
  [ -f "$MODEL" ]     || fail "找不到模型 $MODEL"
  [ -f "$MMPROJ" ]    || fail "找不到 mmproj ${MMPROJ}（缺它会导致输出重复字符）"
fi

WATCHDOG_PID=""
LLAMA_PID=""
API_PID=""
# Child PIDs go to a file: the watchdog forks before they are known, and a killed script would
# otherwise leave llama-server orphaned with 2.8 GB.
: > "$PIDFILE"

# TERM, then KILL after 2 s: llama-server may not answer TERM mid-inference on the GPU.
reap() {
  local pids=("$@")
  [ ${#pids[@]} -eq 0 ] && return
  kill -TERM "${pids[@]}" 2>/dev/null
  for _ in 1 2 3 4; do
    local alive=0
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ $alive -eq 0 ] && return
    sleep 0.5
  done
  kill -KILL "${pids[@]}" 2>/dev/null
}

cleanup() {
  trap '' TERM INT              # no re-entry while cleaning up
  trap - EXIT
  local exit_code="${1:-0}"
  echo "[scivane] 正在关闭…"
  local targets=()
  [ -n "$API_PID" ]   && targets+=("$API_PID")
  [ -n "$LLAMA_PID" ] && targets+=("$LLAMA_PID")
  [ -n "$WATCHDOG_PID" ] && kill -TERM "$WATCHDOG_PID" 2>/dev/null
  reap "${targets[@]}"
  rm -f "$PIDFILE"
  exit "$exit_code"
}
trap 'cleanup 0' TERM INT
trap 'cleanup $?' EXIT

# A killed app (Activity Monitor, crash, kill -9) sends no TERM; this watchdog checks every
# second and reaps the children by PID, even if the script itself is gone.
if [ -n "${SCIVANE_PARENT_PID:-}" ]; then
  (
    while kill -0 "$SCIVANE_PARENT_PID" 2>/dev/null; do sleep 1; done
    echo "[scivane] 父进程 $SCIVANE_PARENT_PID 已退出，强制收尾"
    kill -TERM $$ 2>/dev/null          # let the script run its trap first
    sleep 2
    if [ -f "$PIDFILE" ]; then         # anything left: kill by the recorded PIDs
      while read -r p; do
        [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
      done < "$PIDFILE"
      rm -f "$PIDFILE"
    fi
    kill -KILL $$ 2>/dev/null
  ) &
  WATCHDOG_PID=$!
fi

# --- llama-server (VLM, Metal) -------------------------------------------------
# No explicit --parallel: ctx is split across slots, so it would shrink each slot's context and
# truncate output. Concurrency comes from SCIVANE_VL_CONCURRENCY (default 4).
if [ "$SKIP_LLAMA" = "1" ]; then
  echo "[scivane] 轻量模式：跳过 llama-server，只起编排层"
else
echo "[scivane] 启动 llama-server :$LLAMA_PORT"
"$LLAMA_BIN" \
  -m "$MODEL" \
  --mmproj "$MMPROJ" \
  --host 127.0.0.1 --port "$LLAMA_PORT" \
  --ctx-size "$CTX" \
  --temp 0 \
  >> "$LOG_DIR/llama-server.log" 2>&1 &
LLAMA_PID=$!
echo "$LLAMA_PID" >> "$PIDFILE"

echo "[scivane] 等待模型加载（首次约 10-30 秒）…"
for i in $(seq 1 120); do
  if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
    fail "llama-server 启动即退出，详见 var/logs/llama-server.log"
  fi
  if curl -sf "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1; then
    echo "[scivane] llama-server 就绪（用时 ${i}s）"
    break
  fi
  sleep 1
  [ "$i" -eq 120 ] && fail "llama-server 120 秒未就绪，详见 var/logs/llama-server.log"
done
fi

# --- Scivane API -------------------------------------------------------------
# Code comes in through PYTHONPATH; the runtime environment is never modified.
echo "[scivane] 启动 API :${API_PORT}（$LAYOUT · ${PY}）"
API_ENV=(
  PYTHONPATH="$CODE_PATH"
  SCIVANE_AGENT_RUNTIME_DIR="$AGENT_RUNTIME_DIR"
  SCIVANE_LLAMA_PORT="$LLAMA_PORT"
  SCIVANE_API_PORT="$API_PORT"
)
# SCIVANE_PROJECT_ROOT means "running from a repository, and here it is"; a bundle isn't one.
[ "$LAYOUT" = "source" ] && API_ENV+=(SCIVANE_PROJECT_ROOT="$PROJECT_ROOT")
# env execs python, so $! is the API process itself and the pidfile and reap still hold
env "${API_ENV[@]}" \
  "$PY" -m uvicorn scivane_reader.api.app:app \
  --host 127.0.0.1 --port "$API_PORT" --log-level info \
  >> "$LOG_DIR/api.log" 2>&1 &
API_PID=$!
echo "$API_PID" >> "$PIDFILE"

echo "[scivane] 全部就绪 → http://127.0.0.1:$API_PORT"
while kill -0 "$API_PID" 2>/dev/null; do
  # light mode has no llama-server; in full mode its exit ends everything too
  if [ -n "$LLAMA_PID" ] && ! kill -0 "$LLAMA_PID" 2>/dev/null; then break; fi
  sleep 1
done
fail "后端子进程已退出，正在回收其它进程"
