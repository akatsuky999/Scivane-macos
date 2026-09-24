#!/bin/bash
# 依次拉起 llama-server（Metal）与 Scivane 编排层。
# 前台阻塞运行；收到 TERM/INT 时连同子进程一起收干净 —— App 退出时依赖这一点。
#
# SCIVANE_SKIP_LLAMA=1 只起编排层（轻量模式，约 50MB / 1 秒）。
# 项目管理、阅读、云端问答都不需要本地 OCR 模型，没理由为它们加载 2.8GB。
# 真要 OCR 时 App 会以完整模式重启。
#
# 几个根目录，各管各的：
#   PROJECT_ROOT       代码所在的那一层，**只有代码**：源码树里是仓库根，
#                      安装包里是 Scivane.app/Contents/Resources/backend
#   AGENT_RUNTIME_DIR  运行时的家：自带解释器（python/）、本地 OCR 组件（ocr/）
#   VAR_DIR            运行期产物（日志 / pidfile / 抠图 / 沙箱策略），在用户目录下
# 本地 OCR 是可选组件，只有完整模式要它；它在哪由 runtime.py 说了算（见下面）。
# 指定一套 OCR：export SCIVANE_RUNTIME_ROOT=/某个/目录（设了就只看它）
#
# **同一份脚本跑两种形态**，靠有没有 scivane-package.json 区分：
#   源码树   <仓库>/scripts/start_backend.sh          直接运行，或开发中的 App
#   安装包   backend/bin/start_backend.sh             build_backend.sh 原样拷进包
# 仓库里这份是事实来源。reap / 守护进程 / pidfile 那套是这个仓库修过的最贵的 bug，
# 所以是「搬进包里」而不是另写一份。

set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$PROJECT_ROOT/scivane-package.json" ]; then LAYOUT=package; else LAYOUT=source; fi
cd "$PROJECT_ROOT"

export PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
LLAMA_PORT="${SCIVANE_LLAMA_PORT:-8111}"
API_PORT="${SCIVANE_API_PORT:-8710}"
CTX="${SCIVANE_LLAMA_CTX:-16384}"

# 产物不跟着代码走 —— 打包安装的机器上没有仓库，从源码跑也不该往工作副本里写。
# 与 config.py 的默认值必须一致（那边是唯一的事实来源，这里只是同一个默认）。
VAR_DIR="${SCIVANE_VAR_DIR:-$HOME/.scivane/var}"
LOG_DIR="$VAR_DIR/logs"
RUN_DIR="$VAR_DIR/run"
PIDFILE="$RUN_DIR/backend.pids"
mkdir -p "$LOG_DIR" "$RUN_DIR"
# 运行时的家（自带解释器、OCR 组件都在这下面）。同上，与 config.AGENT_RUNTIME_DIR 同一个默认，
# 并且下面会把算出来的值传给编排层 —— 两边各算一遍迟早会算得不一样。
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

# 自带解释器拷到用户目录，而不是就地在 .app 里跑。两个理由：
#   - 将来按项目建的 venv 会写死解释器的绝对路径，App 被挪动一次就集体失效；
#   - 解释器留在已签名的包里，任何一次写入（比如 .pyc）都会破坏签名。
# 拿 .scivane-build 比身份，App 升级换了解释器才重拷。先拷到旁边再整体换上去 ——
# 拷到一半被杀，留下的是 .partial 而不是一个看起来完整的解释器。
stage_python() {
  local src="$PROJECT_ROOT/python" dest="$AGENT_RUNTIME_DIR/python"
  [ -f "$src/.scivane-build" ] || fail "安装包里缺自带的解释器：$src"
  if [ -x "$dest/bin/python3" ] && cmp -s "$src/.scivane-build" "$dest/.scivane-build"; then
    return
  fi
  echo "[scivane] 安装自带的解释器 → ${dest}（$(cat "$src/.scivane-build")）"
  mkdir -p "$AGENT_RUNTIME_DIR"
  local tmp="$dest.partial.$$"
  # 顺手扫掉以前拷到一半被杀留下的（别的 pid）。端口检查已经保证同一时刻只有一个脚本在这里
  rm -rf "$dest".partial.*
  # -c：同一个 APFS 卷上是 clonefile，几乎不占时间也不占空间；跨卷时自动退回普通拷贝
  cp -Rpc "$src" "$tmp" || { rm -rf "$tmp"; fail "拷贝解释器失败：$src → $tmp"; }
  rm -rf "$dest"
  mv "$tmp" "$dest" || fail "无法把解释器放到 $dest"
}

# --- 用哪个解释器跑编排层 ---------------------------------------------------------
# 安装包：包里自带的解释器（轻量与完整都先拷到用户目录）—— 不需要模型部署存在。
# 源码树（开发）：开发用的 Python（SCIVANE_DEV_PYTHON，默认仓库里的 .venv）；安装包从不走这条。
if [ "$LAYOUT" = "package" ]; then
  stage_python
  PY="$AGENT_RUNTIME_DIR/python/bin/python3"
  CODE_PATH="$PROJECT_ROOT/src:$PROJECT_ROOT/site"
  # 包里的代码与依赖不许被改写：.pyc 构建时已按 unchecked-hash 预编译，这里再关掉
  # 写字节码 —— 漏编的哪个模块也不会把 __pycache__ 写进已签名的 .app。
  export PYTHONDONTWRITEBYTECODE=1
  # 不读用户 `pip install --user` 装的东西：同一个 App 不该在不同机器上跑出不同的依赖。
  export PYTHONNOUSERSITE=1
  # cwd 不进 sys.path：包目录下有 site/、python/ 这样的名字，不该有机会被当成模块导入。
  export PYTHONSAFEPATH=1
else
  # 与 SCIVANE_RUNTIME_ROOT（指定一套 OCR）无关 —— 一个变量兼两职，指走 OCR 就连开发环境一起没了
  PY="${SCIVANE_DEV_PYTHON:-$PROJECT_ROOT/.venv/bin/python}"
  CODE_PATH="$PROJECT_ROOT/services/reader/src"
  [ -x "$PY" ] || fail "找不到开发用的 Python：${PY}（设 SCIVANE_DEV_PYTHON，或在仓库里建 .venv）"
fi

# --- 完整模式：本地 OCR 在哪 -------------------------------------------------------
# OCR 是可选组件。它在哪、齐不齐，只有 runtime.py 一处说了算
# （覆盖 → ~/.scivane/runtime/ocr → 旧部署）—— 这里问它，不自己再找一遍。
if [ "$SKIP_LLAMA" != "1" ]; then
  RESOLVED="$(env PYTHONPATH="$CODE_PATH" SCIVANE_AGENT_RUNTIME_DIR="$AGENT_RUNTIME_DIR" \
    "$PY" -m scivane_reader.runtime shell)" || fail "查不出本地 OCR 在哪（${PY} -m scivane_reader.runtime shell 失败）"
  eval "$RESOLVED"
  [ -z "$OCR_PROBLEM" ] || fail "$OCR_PROBLEM"
  echo "[scivane] 本地 OCR：${OCR_TIER} · ${OCR_ROOT}"
  if [ "$LAYOUT" = "package" ]; then
    if [ "$OCR_LAYOUT" = "component" ]; then
      # 组件布局：OCR 依赖接在 PYTHONPATH 末尾，仍然用自带解释器（同为 CPython 3.12）
      CODE_PATH="$CODE_PATH:$OCR_SITE"
    else
      # 旧布局：OCR 依赖装在旧部署的 venv 里，只能用它跑编排层
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
# 子进程 PID 落盘。守护进程 fork 的时候这些变量还是空的，
# 只能从文件里读，否则脚本被强杀时 llama-server 就成了孤儿抱着 2.8GB。
: > "$PIDFILE"

# 先礼后兵：TERM 之后给 2 秒，还活着就 KILL。
# llama-server 正在 GPU 上推理时未必来得及响应 TERM，绝不能留。
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
  trap '' TERM INT              # 防止收尾过程中再次进入
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

# App 被强杀（活动监视器、崩溃、kill -9）时来不及发 TERM，
# 靠这个守护进程兜底。1 秒一探，直接按 PID 收子进程，不依赖脚本本身还活着。
if [ -n "${SCIVANE_PARENT_PID:-}" ]; then
  (
    while kill -0 "$SCIVANE_PARENT_PID" 2>/dev/null; do sleep 1; done
    echo "[scivane] 父进程 $SCIVANE_PARENT_PID 已退出，强制收尾"
    kill -TERM $$ 2>/dev/null          # 先让脚本自己走 trap
    sleep 2
    if [ -f "$PIDFILE" ]; then         # 没收干净就按落盘 PID 补刀
      while read -r p; do
        [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
      done < "$PIDFILE"
      rm -f "$PIDFILE"
    fi
    kill -KILL $$ 2>/dev/null
  ) &
  WATCHDOG_PID=$!
fi

# --- 第一层：llama-server（VLM，Metal 加速）---------------------------------
# 注意：不显式传 --parallel。ctx 是在所有 slot 之间切分的，动这个参数会
# 连带改变单 slot 的上下文长度，正是「输出截断」那类问题的来源。
# 服务端的并发度由 SCIVANE_VL_CONCURRENCY（默认 4）控制，和 slot 数对齐。
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

# --- 第二层：Scivane 编排层 ----------------------------------------------------
# 走 PYTHONPATH 而不是往运行时的 .venv 里装包 —— 运行时保持只装不改。
echo "[scivane] 启动 API :${API_PORT}（$LAYOUT · ${PY}）"
API_ENV=(
  PYTHONPATH="$CODE_PATH"
  SCIVANE_AGENT_RUNTIME_DIR="$AGENT_RUNTIME_DIR"
  SCIVANE_LLAMA_PORT="$LLAMA_PORT"
  SCIVANE_API_PORT="$API_PORT"
)
# SCIVANE_PROJECT_ROOT 在 paths.py 里的意思是「我在仓库里跑、仓库在这」。
# 安装包不是仓库，传了就是撒谎 —— 那边会找不到标志物而如实返回 None。
[ "$LAYOUT" = "source" ] && API_ENV+=(SCIVANE_PROJECT_ROOT="$PROJECT_ROOT")
# env 是 exec 进 python 的，$! 仍然就是 API 进程本身 —— pidfile 与 reap 照旧成立
env "${API_ENV[@]}" \
  "$PY" -m uvicorn scivane_reader.api.app:app \
  --host 127.0.0.1 --port "$API_PORT" --log-level info \
  >> "$LOG_DIR/api.log" 2>&1 &
API_PID=$!
echo "$API_PID" >> "$PIDFILE"

echo "[scivane] 全部就绪 → http://127.0.0.1:$API_PORT"
while kill -0 "$API_PID" 2>/dev/null; do
  # 轻量模式没有 llama-server 可看；完整模式下它挂了也要一起收
  if [ -n "$LLAMA_PID" ] && ! kill -0 "$LLAMA_PID" 2>/dev/null; then break; fi
  sleep 1
done
fail "后端子进程已退出，正在回收其它进程"
