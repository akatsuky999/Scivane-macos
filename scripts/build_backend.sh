#!/bin/bash
# Assembles the bundled backend in var/build/backend/, which build_app.sh copies into
# Scivane.app/Contents/Resources/backend/:
#
#   scivane-package.json   what this directory is: schema / build / arch / interpreter
#   bin/start_backend.sh   copied unchanged from scripts/
#   python/                relocatable interpreter (scripts/fetch_python.sh)
#   site/                  base dependencies, pinned with hashes by requirements-base.txt
#   src/scivane_reader/    the API code
#
# The app can then start the light backend without uv, a system python3 or any checkout.
#
#   bash scripts/build_backend.sh          assemble
#   bash scripts/build_backend.sh lock     regenerate both lock files (base + local OCR; needs network)

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN="$PROJECT_ROOT/services/reader/requirements-base.in"
LOCK="$PROJECT_ROOT/services/reader/requirements-base.txt"
OUT="$PROJECT_ROOT/var/build/backend"

log() { echo "[build_backend] $*" >&2; }

PYROOT="$(bash "$PROJECT_ROOT/scripts/fetch_python.sh" | tail -1)"
PY="$PYROOT/bin/python3"
# --isolated ignores the user's pip.conf and PIP_* variables, which could silently change what goes
# into the bundle while the lock file still looks right.
PIP=("$PY" -m pip --isolated --disable-pip-version-check)

# --- Lock files ------------------------------------------------------------------
#   requirements-base.in -> requirements-base.txt                    base layer in the bundle
#   requirements-ocr.in  -> src/scivane_reader/requirements-ocr.txt  local OCR component,
#                           installed by the app (minus what the base layer has)
OCR_IN="$PROJECT_ROOT/services/reader/requirements-ocr.in"
OCR_LOCK="$PROJECT_ROOT/services/reader/src/scivane_reader/requirements-ocr.txt"

lock_one() {   # lock_one <input> <output> [lock to exclude]
  local input="$1" output="$2" exclude="${3:-}" report
  report="$(mktemp -t scivane-lock)"
  # pip resolves with --dry-run --report and reports the chosen wheels with their sha256. Wheels
  # only, so nothing is ever compiled and the result is reproducible.
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

# --- Assemble ------------------------------------------------------------------
[ -f "$LOCK" ] || { log "缺锁文件 $LOCK —— 先跑 bash scripts/build_backend.sh lock"; exit 1; }

# Assemble in a temporary directory and swap it in, so build_app.sh never copies a half-built backend.
STAGE="$(mktemp -d "$PROJECT_ROOT/var/build/.backend.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/src"

# -p keeps timestamps: the interpreter's stdlib .pyc files are validated by mtime.
cp -Rp "$PYROOT" "$STAGE/python"

# --require-hashes fails on any mismatch; --no-deps because the lock already lists everything.
log "安装基础层依赖（$(grep -c '^[a-z]' "$LOCK") 个包）"
"${PIP[@]}" install --quiet --no-deps --require-hashes --only-binary=:all: --no-compile \
  --target "$STAGE/site" -r "$LOCK"
# Console scripts (bin/uvicorn...) have absolute shebangs to the build interpreter; the backend
# always uses `python -m`.
rm -rf "$STAGE/site/bin"

# API code, without the development machine's __pycache__.
rsync -a --exclude '__pycache__' "$PROJECT_ROOT/services/reader/src/scivane_reader" "$STAGE/src/"
cp "$PROJECT_ROOT/scripts/start_backend.sh" "$STAGE/bin/start_backend.sh"
chmod +x "$STAGE/bin/start_backend.sh"

# unchecked-hash .pyc files skip the mtime check: the bundle is immutable, and a copy that changed
# mtimes would invalidate them all. PYTHONDONTWRITEBYTECODE at run time covers anything missed.
"$PY" -m compileall -q -j 0 --invalidation-mode unchecked-hash "$STAGE/src" "$STAGE/site"

# Manifest: start_backend.sh and the app recognise a bundled backend by it.
"$PY" - "$STAGE/scivane-package.json" "${SCIVANE_BUILD_NUMBER:-dev}" \
  "$(cat "$PYROOT/.scivane-build")" <<'PYEOF'
import json, sys

path, version, python = sys.argv[1:]
manifest = {"schema": "scivane.package/1", "version": version, "arch": "arm64", "python": python}
open(path, "w").write(json.dumps(manifest, indent=2) + "\n")
PYEOF

# Smoke test: with an empty environment, import the whole API from the bundle and assert every
# loaded module comes from it, so a missing or borrowed dependency fails at build time.
log "冒烟：env -i 下 import 编排层"
env -i HOME="$STAGE/home" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 PYTHONSAFEPATH=1 \
  PYTHONPATH="$STAGE/src:$STAGE/site" "$STAGE/python/bin/python3" - "$STAGE" <<'PYEOF'
import sys

stage = sys.argv[1]
import scivane_reader.api.app  # noqa: F401  pulls in fastapi / pydantic / httpx
import pymupdf  # noqa: F401                 imported unguarded by paper.py (cite)
import uvicorn  # noqa: F401

files = {getattr(m, "__file__", None) or "" for m in list(sys.modules.values())}
# real paths only; this script's own __main__ is "<stdin>"
outside = sorted(f for f in files if f.startswith("/") and not f.startswith(stage))
if outside:
    sys.exit("有模块不是从包里加载的：\n  " + "\n  ".join(outside))
PYEOF
rm -rf "$STAGE/home"

rm -rf "$OUT"
mv "$STAGE" "$OUT"
trap - EXIT
log "已组装：${OUT}（$(du -sh "$OUT" | cut -f1)；python $(du -sh "$OUT/python" | cut -f1) · site $(du -sh "$OUT/site" | cut -f1)）"
