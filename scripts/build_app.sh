#!/bin/bash
# Builds Scivane with SwiftPM, assembles a standard .app in var/app/Scivane.app and installs a
# copy on the Desktop. A copy rather than a symlink, since var/ may be deleted at any time
# (make distclean). For a symlink: SCIVANE_APP_INSTALL=link bash scripts/build_app.sh
#
# The bundle carries its own backend (Contents/Resources/backend/, see build_backend.sh), so the
# light backend needs nothing outside it. Local OCR is optional; the app installs it into
# ~/.scivane/runtime/ocr.

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPDIR="$PROJECT_ROOT/app/macos"
BUILD="$PROJECT_ROOT/var/build"        # intermediate output (icon etc.), removed by make clean
APPOUT="$PROJECT_ROOT/var/app"         # finished bundle, kept by make clean
STAGE="$APPOUT/Scivane.app"
DEST="${1:-$HOME/Desktop}"
INSTALL_MODE="${SCIVANE_APP_INSTALL:-copy}"

# Do not replace files underneath a running process: reopening would keep old code.
if pgrep -x Scivane >/dev/null 2>&1; then
  echo "请先退出 Scivane 再打包，以免旧进程继续显示上一版界面。" >&2
  exit 1
fi
BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"
REVISION="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
echo "==> 1/6 编译"
cd "$APPDIR"
swift build -c release

echo "==> 2/6 组装后端"
SCIVANE_BUILD_NUMBER="$BUILD_NUMBER" bash "$PROJECT_ROOT/scripts/build_backend.sh"

echo "==> 3/6 生成图标"
mkdir -p "$BUILD"
swift "$PROJECT_ROOT/scripts/make_icon.swift" "$BUILD"

echo "==> 4/6 组装 .app"
rm -rf "$STAGE"
mkdir -p "$APPOUT" "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/web"

cp "$APPDIR/.build/release/Scivane" "$STAGE/Contents/MacOS/Scivane"
cp "$BUILD/Scivane.icns"            "$STAGE/Contents/Resources/Scivane.icns"
# WebResources looks for viewer.html under Contents/Resources/web first
cp -R "$APPDIR/Sources/Scivane/Resources/." "$STAGE/Contents/Resources/web/"
# Where InstallContext looks. ditto keeps timestamps: the interpreter's stdlib .pyc files are
# validated by mtime.
ditto "$BUILD/backend" "$STAGE/Contents/Resources/backend"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Scivane</string>
  <key>CFBundleDisplayName</key>       <string>Scivane</string>
  <key>CFBundleExecutable</key>        <string>Scivane</string>
  <key>CFBundleIdentifier</key>        <string>local.scivane.app</string>
  <key>CFBundleIconFile</key>          <string>Scivane</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.2</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticTermination</key><false/>

  <!-- UI strings live in the code; this only declares both languages, so system menu items and
       panels pick theirs with the same matching as "Follow System". -->
  <key>CFBundleDevelopmentRegion</key> <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>

  <!-- the WebView loads extracted figures from 127.0.0.1; ATS blocks http by default -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key> <true/>
  </dict>

  <!-- PDFs and images can be dropped onto the Dock icon -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key>  <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
        <string>com.adobe.pdf</string>
        <string>public.png</string>
        <string>public.jpeg</string>
        <string>public.tiff</string>
        <string>public.heic</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ScivaneSourceRevision string $REVISION" "$STAGE/Contents/Info.plist"
echo "==> 5/6 签名（本地 ad-hoc）"
# Ad-hoc signing. No --deep (deprecated; nothing sits in nested code locations). The interpreter
# and .so files in backend/ keep their linker signatures and are sealed as resources, so
# `codesign --verify` fails if anything in the bundle changes at run time. Notarisation would
# need those Mach-O files re-signed inside out.
codesign --force --sign - "$STAGE"
codesign --verify --strict "$STAGE"

# locally built output shouldn't carry quarantine attributes
xattr -cr "$STAGE" 2>/dev/null || true

echo "==> 6/6 安装到 $DEST"
# may be a symlink or a copy from an earlier build
rm -rf "$DEST/Scivane.app"

if [ "$INSTALL_MODE" = "copy" ]; then
  ditto "$STAGE" "$DEST/Scivane.app"   # keeps timestamps, as above
  xattr -cr "$DEST/Scivane.app" 2>/dev/null || true
  echo "    实体拷贝（与项目脱钩，重新构建不会自动更新）"
else
  ln -s "$STAGE" "$DEST/Scivane.app"
  echo "    软链接 → $STAGE"
fi

echo
# Explicitly register this build; backups can otherwise share the same bundle ID.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$DEST/Scivane.app"
echo "完成 → $DEST/Scivane.app（构建 ${BUILD_NUMBER}）"
du -sh "$STAGE"
