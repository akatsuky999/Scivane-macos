#!/bin/bash
# Builds Scivane with SwiftPM, assembles a standard .app in var/app/Scivane.app and installs a
# copy on the Desktop. A copy rather than a symlink, since var/ may be deleted at any time
# (make distclean). For a symlink: SCIVANE_APP_INSTALL=link bash scripts/build_app.sh
#
# The bundle carries its own backend (Contents/Resources/backend/, see build_backend.sh), so the
# light backend needs nothing outside it. Local OCR is optional; the app installs it into
# ~/.scivane/runtime/ocr.
#
# The terminal gets one line per step. What the tools print goes to var/build/make-app.log, and a
# failed step shows the end of it.

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPDIR="$PROJECT_ROOT/app/macos"
BUILD="$PROJECT_ROOT/var/build"        # intermediate output (icon etc.), removed by make clean
APPOUT="$PROJECT_ROOT/var/app"         # finished bundle, kept by make clean
STAGE="$APPOUT/Scivane.app"
DEST="${1:-$HOME/Desktop}"
TARGET="$DEST/Scivane.app"
INSTALL_MODE="${SCIVANE_APP_INSTALL:-copy}"
LOG="$BUILD/make-app.log"
TIMES="$BUILD/.make-app.time"
VERSION="0.0.3"
BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"
REVISION="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# --- Output ---------------------------------------------------------------------------------
# A right-aligned verb, what it acts on, and how long it took. On a terminal the running step is
# redrawn in place with its elapsed time; piped output gets plain final lines only.

if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then LIVE=1; else LIVE=0; fi
if [ "$LIVE" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi
# A redraw only works while the line fits the terminal, so long details are cut, never wrapped.
# Asked of /dev/tty: inside $(...) a tool's stdout is a pipe and the size would read as 80.
COLS=80
if [ "$LIVE" = 1 ]; then
  COLS="$(stty size 2>/dev/null </dev/tty | awk '{ print $2 }')" || COLS=80
  case "$COLS" in ''|*[!0-9]*|0) COLS=80 ;; esac   # a pty without a window size reports 0
fi
WIDTH=$(( COLS - 23 ))
[ "$WIDTH" -le 46 ] || WIDTH=46
[ "$WIDTH" -ge 20 ] || WIDTH=20

TIMEFORMAT=%R
# The terminal, kept for the exit handler: a failing step exits while its redirections still
# point at the log and the timing file.
exec 3>&1 4>&2
CURRENT=""
CURRENT_DETAIL=""
CURRENT_OUTPUT=1
TICKER=""
TOTAL=0

status() {  # status <colour> <verb> <detail> <time>
  local detail="$3"
  # ASCII on purpose: printf pads by bytes, so a multibyte ellipsis would break the alignment
  [ "${#detail}" -le "$WIDTH" ] || detail="${detail:0:$((WIDTH - 3))}..."
  [ "$LIVE" = 0 ] || printf '\r\033[K'
  printf '%s%12s%s %-*s %s%9s%s' "$BOLD$1" "$2" "$RESET" "$WIDTH" "$detail" "$DIM" "$4" "$RESET"
}

duration() {  # seconds -> 4.2s, or 1m 05s from a minute up
  awk -v s="$1" 'BEGIN { if (s < 60) printf "%.1fs", s; else printf "%dm %02ds", int(s / 60), int(s) % 60 }'
}

home_relative() {
  case "$1" in
    "$HOME"/*) printf '%s' "~${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

tick() {  # tick <verb> <detail>: redraws the running line once a second
  local started=$SECONDS
  while sleep 1; do status "" "$1" "$2" "$((SECONDS - started))s"; done
}

stop_ticker() {
  [ -n "$TICKER" ] || return 0
  kill "$TICKER" 2>/dev/null || true
  wait "$TICKER" 2>/dev/null || true
  TICKER=""
}

# The redirection lives inside the subshell: bash 3.2 reports `time ( ... ) >log` into the log.
logged() {
  ( exec >>"$LOG" 2>&1 3>&- 4>&-; "$@" )
}

# step <verb> <detail> <command...>: runs the command in a subshell, output into the log. Never call
# it from an if or a && list: that would switch off set -e inside the command.
step() {
  local verb="$1" detail="$2" before seconds warnings
  shift 2
  CURRENT="$verb"
  CURRENT_DETAIL="$detail"
  before="$(wc -l <"$LOG")"
  CURRENT_OUTPUT=$((before + 3))   # first log line of this step's own output, after its header
  printf '\n==> %s %s\n' "$verb" "$detail" >>"$LOG"
  if [ "$LIVE" = 1 ]; then
    status "" "$verb" "$detail" ""
    tick "$verb" "$detail" 3>&- 4>&- &
    TICKER=$!
  fi
  { time logged "$@"; } 2>"$TIMES"
  stop_ticker
  seconds="$(tail -n 1 "$TIMES")"
  TOTAL="$(awk -v a="$TOTAL" -v b="$seconds" 'BEGIN { print a + b }')"
  warnings="$(tail -n +"$((before + 1))" "$LOG" | grep -cE '(^|: )warning: ' || true)"
  case "$warnings" in
    0) ;;
    1) detail="$detail, 1 warning" ;;
    *) detail="$detail, $warnings warnings" ;;
  esac
  status "$GREEN" "$verb" "$detail" "$(duration "$seconds")"
  printf '\n'
  CURRENT=""
}

on_exit() {
  local code=$?
  exec 1>&3 2>&4
  stop_ticker
  rm -f "$TIMES"
  { [ "$code" -ne 0 ] && [ -n "$CURRENT" ]; } || return 0
  if [ "$code" -ge 128 ]; then
    status "$YELLOW" "$CURRENT" "$CURRENT_DETAIL" "cancelled"
    printf '\n'
    return 0
  fi
  status "$RED" "$CURRENT" "$CURRENT_DETAIL" "failed"
  printf '\n'
  {
    printf '\n%serror:%s %s %s failed (exit status %s)\n\n' "$BOLD$RED" "$RESET" "$CURRENT" "$CURRENT_DETAIL" "$code"
    if [ "$(wc -l <"$LOG")" -ge "$CURRENT_OUTPUT" ]; then
      tail -n +"$CURRENT_OUTPUT" "$LOG" | tail -n 25 | sed 's/^/    /'
    else
      printf '    (the step printed nothing)\n'
    fi
    printf '\n%sFull log: %s%s\n' "$DIM" "${LOG#"$PROJECT_ROOT"/}" "$RESET"
  } >&2
}
trap on_exit EXIT
trap 'exit 130' INT TERM

die() {
  printf '%serror:%s %s\n' "$BOLD$RED" "$RESET" "$1" >&2
  exit 1
}

# --- Steps ----------------------------------------------------------------------------------

compile() {
  cd "$APPDIR"
  swift build -c release
}

assemble_backend() {
  SCIVANE_BUILD_NUMBER="$BUILD_NUMBER" bash "$PROJECT_ROOT/scripts/build_backend.sh"
}

render_icon() {
  swift "$PROJECT_ROOT/scripts/make_icon.swift" "$BUILD"
}

bundle() {
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

  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$STAGE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ScivaneSourceRevision string $REVISION" "$STAGE/Contents/Info.plist"
}

sign() {
  # Ad-hoc signing. No --deep (deprecated; nothing sits in nested code locations). The interpreter
  # and .so files in backend/ keep their linker signatures and are sealed as resources, so
  # `codesign --verify` fails if anything in the bundle changes at run time. Notarisation would
  # need those Mach-O files re-signed inside out.
  codesign --force --sign - "$STAGE"
  codesign --verify --strict "$STAGE"
  # locally built output shouldn't carry quarantine attributes
  xattr -cr "$STAGE" 2>/dev/null || true
}

install_app() {
  # may be a symlink or a copy from an earlier build
  rm -rf "$TARGET"
  if [ "$INSTALL_MODE" = "copy" ]; then
    ditto "$STAGE" "$TARGET"   # keeps timestamps, as above
    xattr -cr "$TARGET" 2>/dev/null || true
  else
    ln -s "$STAGE" "$TARGET"
  fi
  # Explicitly register this build; backups can otherwise share the same bundle ID.
  "$LSREGISTER" -f "$TARGET"
}

# --- Main -----------------------------------------------------------------------------------

# Do not replace files underneath a running process: reopening would keep old code.
if pgrep -x Scivane >/dev/null 2>&1; then
  die "Scivane is running. Quit it (⌘Q), then run make app again."
fi
command -v swift >/dev/null 2>&1 || die "swift was not found. Install the Command Line Tools: xcode-select --install"

mkdir -p "$BUILD"
printf 'Scivane %s, build %s, revision %s\nStarted %s\n' \
  "$VERSION" "$BUILD_NUMBER" "$REVISION" "$(date '+%Y-%m-%d %H:%M:%S %z')" >"$LOG"

WHERE="$(home_relative "$TARGET")"
[ "$INSTALL_MODE" = "copy" ] || WHERE="$WHERE (symlink)"

step Compiling  "Scivane $VERSION (release)" compile
step Assembling "Python backend"             assemble_backend
step Rendering  "app icon"                   render_icon
step Bundling   "Scivane.app"                bundle
step Signing    "Scivane.app (ad-hoc)"       sign
step Installing "$WHERE"                     install_app

SIZE="$(du -sk "$STAGE" | awk '{ printf "%d MB", $1 / 1024 + 0.5 }')"
printf '%s%12s%s Scivane %s (build %s) in %s\n' "$BOLD$GREEN" Finished "$RESET" \
  "$VERSION" "$BUILD_NUMBER" "$(duration "$TOTAL")"
printf '%12s %s, %s\n' "" "$(home_relative "$TARGET")" "$SIZE"
