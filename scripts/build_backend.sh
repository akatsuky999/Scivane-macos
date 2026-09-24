#!/bin/bash
# 组装包内后端 var/build/backend/，build_app.sh 把它整个拷进
# Scivane.app/Contents/Resources/backend/。布局：
#
#   scivane-package.json   这个目录是谁：schema / 构建号 / 架构 / 解释器
#   bin/start_backend.sh   从 scripts/ 原样拷入 —— 仓库那份是事实来源
#   python/                可重定位解释器（scripts/fetch_python.sh 取来的）
#   site/                  基础层依赖，按 requirements-base.txt 锁版本、锁哈希装入
#   src/scivane_reader/    编排层代码
#
# 有了它，Scivane.app 起轻量后端就不需要 uv、系统 python3，也不需要
# 机器上有任何开发目录。
#
#   bash scripts/build_backend.sh          组装
#   bash scripts/build_backend.sh lock     重新生成两份锁文件（基础层 + 本地 OCR，要联网）

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN="$PROJECT_ROOT/services/reader/requirements-base.in"
LOCK="$PROJECT_ROOT/services/reader/requirements-base.txt"
OUT="$PROJECT_ROOT/var/build/backend"

log() { echo "[build_backend] $*" >&2; }

PYROOT="$(bash "$PROJECT_ROOT/scripts/fetch_python.sh" | tail -1)"
PY="$PYROOT/bin/python3"
# --isolated：不读用户的 pip.conf 与 PIP_* 环境变量。否则某台机器上配的镜像源或
# --extra-index-url 会悄悄换掉装进包里的东西，而锁文件看起来仍然是对的。
PIP=("$PY" -m pip --isolated --disable-pip-version-check)

# --- 重新生成锁文件 -------------------------------------------------------------
# 两份锁，同一条路：
#   requirements-base.in → requirements-base.txt              打进包的基础层
#   requirements-ocr.in  → src/scivane_reader/requirements-ocr.txt
#                          本地 OCR 组件，随代码进包，由 App 里的安装器按它装（剔掉基础层已有的）
OCR_IN="$PROJECT_ROOT/services/reader/requirements-ocr.in"
OCR_LOCK="$PROJECT_ROOT/services/reader/src/scivane_reader/requirements-ocr.txt"

lock_one() {   # lock_one <输入> <输出> [要剔掉的那份锁]
  local input="$1" output="$2" exclude="${3:-}" report
  report="$(mktemp -t scivane-lock)"
  # --dry-run --report：让 pip 自己解析一遍，把选中的 wheel 与它的 sha256 报出来。
  # 只收 wheel（--only-binary）—— 构建机与用户机器上都不编译任何东西，结果才可复现。
  "${PIP[@]}" install --quiet --dry-run --ignore-installed --only-binary=:all: \
    --report "$report" -r "$input"
  "$PY" - "$report" "$output" "$exclude" <<'PYEOF'
import json, re, sys

report, out, exclude = sys.argv[1], sys.argv[2], sys.argv[3]
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
skip = set()
if exclude:
    skip = {norm(line.split("==")[0]) for line in open(exclude) if "==" in line}
rows = []
for item in json.load(open(report))["install"]:
    meta = item["metadata"]
    if norm(meta["name"]) in skip:
        continue
    sha = item["download_info"]["archive_info"]["hashes"]["sha256"]
    rows.append((norm(meta["name"]), meta["version"], sha))

lines = [
    "# 由 `bash scripts/build_backend.sh lock` 生成，不要手改。",
    "# 哈希锁的是 macOS arm64 / CPython 3.12 上选中的那个 wheel（只做 arm64）。",
]
if skip:
    lines.append(f"# 已剔掉基础层（{exclude.rsplit('/', 1)[-1]}）里已有的 {len(skip)} 个包。")
lines.append("")
for name, version, sha in sorted(rows):
    lines.append(f"{name}=={version} \\\n    --hash=sha256:{sha}")
open(out, "w").write("\n".join(lines) + "\n")
print(f"[build_backend] 已写 {out}（{len(rows)} 个包）", file=sys.stderr)
PYEOF
  rm -f "$report"
}

if [ "${1:-}" = "lock" ]; then
  lock_one "$IN" "$LOCK"
  lock_one "$OCR_IN" "$OCR_LOCK" "$LOCK"
  exit 0
fi

# --- 组装 ----------------------------------------------------------------------
[ -f "$LOCK" ] || { log "缺锁文件 $LOCK —— 先跑 bash scripts/build_backend.sh lock"; exit 1; }

# 组装在临时目录里做完再整体换上去：半截的 backend/ 不会被 build_app.sh 拷进包。
STAGE="$(mktemp -d "$PROJECT_ROOT/var/build/.backend.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/src"

# 解释器。-p 保留时间戳：它自带的那部分标准库 .pyc 按时间戳校验，改了就全部失效。
cp -Rp "$PYROOT" "$STAGE/python"

# 依赖。--require-hashes：任何一个文件的哈希对不上，整次安装失败。
# --no-deps：锁文件已经列全了传递依赖，不许解析器再自己挑。
log "安装基础层依赖（$(grep -c '^[a-z]' "$LOCK") 个包）"
"${PIP[@]}" install --quiet --no-deps --require-hashes --only-binary=:all: --no-compile \
  --target "$STAGE/site" -r "$LOCK"
# 控制台脚本（bin/uvicorn 之类）带着指向构建机解释器的绝对 shebang，拷到别处必然失效。
# 后端一律 `python -m`，用不到它们。
rm -rf "$STAGE/site/bin"

# 编排层代码。开发机上按时间戳编的 __pycache__ 不带进去。
rsync -a --exclude '__pycache__' "$PROJECT_ROOT/services/reader/src/scivane_reader" "$STAGE/src/"
cp "$PROJECT_ROOT/scripts/start_backend.sh" "$STAGE/bin/start_backend.sh"
chmod +x "$STAGE/bin/start_backend.sh"

# 预编译。unchecked-hash 的 .pyc 不拿源文件的时间戳做校验 —— 包是不可变的，
# 而时间戳校验只会在某次拷贝改了 mtime 时让它们全体失效。
# 运行时另有 PYTHONDONTWRITEBYTECODE 兜底，保证不往已签名的 .app 里写 __pycache__。
"$PY" -m compileall -q -j 0 --invalidation-mode unchecked-hash "$STAGE/src" "$STAGE/site"

# 清单：start_backend.sh 靠它认出「我在安装包里」，App 靠它认出「这是一个后端包」。
"$PY" - "$STAGE/scivane-package.json" "${SCIVANE_BUILD_NUMBER:-dev}" \
  "$(cat "$PYROOT/.scivane-build")" <<'PYEOF'
import json, sys

path, version, python = sys.argv[1:]
manifest = {"schema": "scivane.package/1", "version": version, "arch": "arm64", "python": python}
open(path, "w").write(json.dumps(manifest, indent=2) + "\n")
PYEOF

# 冒烟：**清空环境**、只用包里的东西 import 整个编排层，并断言每个被加载的模块
# 都来自包内。少装一个依赖、或者悄悄从别处借到了一个，都在构建时就红，
# 而不是等到别人的 Finder 里。
log "冒烟：env -i 下 import 编排层"
env -i HOME="$STAGE/home" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 PYTHONSAFEPATH=1 \
  PYTHONPATH="$STAGE/src:$STAGE/site" "$STAGE/python/bin/python3" - "$STAGE" <<'PYEOF'
import sys

stage = sys.argv[1]
import scivane_reader.api.app  # noqa: F401  顶层 import 链会带起 fastapi / pydantic / httpx
import pymupdf  # noqa: F401                 cite 用；paper.py 顶层 import，没有保护
import uvicorn  # noqa: F401

files = {getattr(m, "__file__", None) or "" for m in list(sys.modules.values())}
# 只看真实路径；这段脚本自己的 __main__ 是 "<stdin>"
outside = sorted(f for f in files if f.startswith("/") and not f.startswith(stage))
if outside:
    sys.exit("有模块不是从包里加载的：\n  " + "\n  ".join(outside))
PYEOF
rm -rf "$STAGE/home"

rm -rf "$OUT"
mv "$STAGE" "$OUT"
trap - EXIT
log "已组装：${OUT}（$(du -sh "$OUT" | cut -f1)；python $(du -sh "$OUT/python" | cut -f1) · site $(du -sh "$OUT/site" | cut -f1)）"
