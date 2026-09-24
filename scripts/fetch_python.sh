#!/bin/bash
# 取一份可重定位的 CPython，供打包进 Scivane.app 的后端使用。
#
# **为什么要自带解释器**：后端要是借用外部的 Python 环境，没有那套环境
# 连项目管理和云端问答都起不来。发给别人的 App 不能要求对方先准备环境，也不能要求装 uv。
#
# 来源是 astral-sh/python-build-standalone 的 release（uv 自己用的也是它）。
# **版本、文件名、sha256 都钉死在下面** —— 换版本就是改这三行，
# 校验值取自该 release 的 SHA256SUMS。校验不过绝不解包。
#
# 结果落在 var/build/（编译中间产物，make clean 会清，重跑本脚本即可重建）。
# 已经取过且校验一致时什么都不做。最后一行输出解释器根目录，供 build_backend.sh 使用。
#
#   bash scripts/fetch_python.sh

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PBS_TAG="20260901"
PY_VERSION="3.12.14"
# 只做 arm64。install_only 是给「拿来直接用」的变体：
# 目录布局是标准的 bin/ lib/ include/，不带构建用的中间文件。
ASSET="cpython-${PY_VERSION}+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
SHA256="3ee3ee547cedfeb7c2b16b2b7156039f7b470bb8f857e226fd3d2eb11db83c76"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${ASSET//+/%2B}"

# 这份解释器的身份。写进解包目录，后端首次启动拷到用户目录时拿它判断要不要重拷。
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
  # 先落 .partial 再改名：断在一半的文件不会被下次当成已下载。
  # 只认 https —— 重定向到别的协议直接失败。
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

# 解到临时目录再整体换上去：解到一半中断不会留下一个看起来完整的解释器。
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
