#!/bin/bash
# Fetches a relocatable CPython (python-build-standalone) for the backend bundled in
# Scivane.app, so the app needs no Python environment on the user's machine.
#
# Version, file name and sha256 are pinned below (from the release's SHA256SUMS); a mismatch is
# never unpacked. Output goes to var/build/ (removed by make clean); nothing happens when it is
# already there. The last output line is the interpreter root, for build_backend.sh.
#
#   bash scripts/fetch_python.sh

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PBS_TAG="20260901"
PY_VERSION="3.12.14"
# arm64 only. install_only has the plain bin/ lib/ include/ layout without build files.
ASSET="cpython-${PY_VERSION}+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
SHA256="3ee3ee547cedfeb7c2b16b2b7156039f7b470bb8f857e226fd3d2eb11db83c76"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${ASSET//+/%2B}"

# This interpreter's identity, written into it; start_backend.sh uses it to decide on recopying.
BUILD_ID="cpython-${PY_VERSION}+${PBS_TAG}-aarch64-apple-darwin"

CACHE="$PROJECT_ROOT/var/build/python"
TARBALL="$CACHE/$ASSET"
DEST="$CACHE/$BUILD_ID"

log() { echo "[fetch_python] $*" >&2; }

if [ -f "$DEST/python/.scivane-build" ] && [ "$(cat "$DEST/python/.scivane-build")" = "$BUILD_ID" ]; then
  log "已就绪：$DEST/python"
  echo "$DEST/python"
  exit 0
fi

mkdir -p "$CACHE"

verify() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$SHA256" ]; }

if [ -f "$TARBALL" ] && verify "$TARBALL"; then
  log "压缩包已在缓存里，校验通过"
else
  rm -f "$TARBALL"
  log "下载 $ASSET"
  # download to .partial and rename, so a broken download never counts as done; https only
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
    --output "$TARBALL.partial" "$URL"
  if ! verify "$TARBALL.partial"; then
    rm -f "$TARBALL.partial"
    log "错误：sha256 不符，已删除下载的文件。期望 $SHA256"
    exit 1
  fi
  mv "$TARBALL.partial" "$TARBALL"
  log "校验通过"
fi

# Unpack to a temporary directory and move it into place, so an interrupted unpack never looks complete.
STAGE="$(mktemp -d "$CACHE/.extract.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$TARBALL" -C "$STAGE"
[ -x "$STAGE/python/bin/python3" ] || { log "错误：压缩包里没有 python/bin/python3"; exit 1; }
echo "$BUILD_ID" > "$STAGE/python/.scivane-build"

rm -rf "$DEST"
mkdir -p "$DEST"
mv "$STAGE/python" "$DEST/python"
log "已解包：$DEST/python（$(du -sh "$DEST/python" | cut -f1)）"
echo "$DEST/python"
