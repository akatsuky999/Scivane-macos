#!/bin/bash
# 编译 Scivane 并组装成标准 .app，最后在目标位置放一个指向它的软链接。
# 用 SPM 而不是 .xcodeproj —— 工程文件不好脚本化维护，SPM 一条命令就够。
#
# 成品常驻在 var/app/Scivane.app，桌面上放的是一份**实体拷贝**。
#
# **为什么不是软链接**：var/ 的定义是「整个删掉也不影响代码」（make distclean
# 就会删），而桌面图标是用户天天点的东西 —— 指向一个随时会被清掉的目录，
# 迟早变成断链。想要软链接： SCIVANE_APP_INSTALL=link bash scripts/build_app.sh
#
# 包里自带后端（Contents/Resources/backend/：解释器 + 基础层依赖 + 编排层代码，
# 见 build_backend.sh），所以轻量后端不依赖任何外部目录；本地 OCR 是可选组件，
# 由 App 装进 ~/.scivane/runtime/ocr，不在包里。

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPDIR="$PROJECT_ROOT/app/macos"
BUILD="$PROJECT_ROOT/var/build"        # 图标等构建中间产物，make clean 会清
APPOUT="$PROJECT_ROOT/var/app"         # 成品 bundle，桌面软链接指向这里，clean 不动
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
# WebResources 会优先在 Contents/Resources/web 下找 viewer.html
cp -R "$APPDIR/Sources/Scivane/Resources/." "$STAGE/Contents/Resources/web/"
# InstallContext 认的就是这个位置。ditto 保留时间戳与权限 —— 解释器自带的
# 标准库 .pyc 按时间戳校验，改了 mtime 就全部失效。
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticTermination</key><false/>

  <!-- 界面语言：字符串写在代码里（L("中文", "English")），这里只向系统
       声明「这个 App 说这两种话」—— 菜单栏里系统自带的项目、存储面板的按钮据此挑语言，
       与 App 里「跟随系统」用的是同一条匹配规则；两种都不沾时退到英文。 -->
  <key>CFBundleDevelopmentRegion</key> <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>

  <!-- WebView 要从 127.0.0.1 取抠出来的插图，ATS 默认会拦 http -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key> <true/>
  </dict>

  <!-- 让 PDF/图片可以直接拖到 Dock 图标上打开 -->
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
# 个人自用，不进 App Store，ad-hoc 足够；不签的话 Gatekeeper 更难缠。
#
# 不用 --deep（已弃用）：实测它在这里什么都没多做 —— 包里没有放在嵌套代码位置
# （Frameworks/ PlugIns/ Helpers/）的东西；backend/ 里的解释器与 .so 各自带着
# 链接器签名，作为资源按哈希封进这一层签名。之后包里改了任何一个字节，
# `codesign --verify` 都会红 —— 跑过一次包内后端之后再验一次签名，就能确认运行期没往包里写东西。
# 将来要公证（Developer ID + hardened runtime）时，那些 Mach-O 得由内向外逐个重签 ——
# 到时候再做，ad-hoc 阶段不需要。
codesign --force --sign - "$STAGE"
codesign --verify --strict "$STAGE"

# 自己编译的产物不该带隔离属性
xattr -cr "$STAGE" 2>/dev/null || true

echo "==> 6/6 安装到 $DEST"
# 先清掉旧的：可能是软链接，也可能是上一版留下的实体目录
rm -rf "$DEST/Scivane.app"

if [ "$INSTALL_MODE" = "copy" ]; then
  ditto "$STAGE" "$DEST/Scivane.app"   # 同上：保留时间戳
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
