#!/usr/bin/env bash
# Install HikViewer.command — double-click to install HikViewer.app into
# /Applications and launch it.
#
# HikViewer is open-source and ad-hoc signed (no Apple Developer account).
# When you download a zip from GitHub, macOS attaches a `com.apple.quarantine`
# extended attribute to every file inside, and Gatekeeper refuses to open
# ad-hoc-signed apps that carry that flag — you get the "HikViewer is damaged
# and can't be opened" dialog, with no easy bypass on Sequoia (the old
# right-click → Open trick was removed for unsigned apps in macOS 15).
#
# This script is the workaround:
#   1. Quits a running HikViewer (so the copy doesn't fight an open file
#      descriptor).
#   2. Strips com.apple.quarantine from the bundled HikViewer.app that lives
#      next to this script.
#   3. ditto-copies it into /Applications, replacing any prior install.
#      ditto preserves codesign metadata that plain `cp` would strip.
#   4. Strips quarantine from the destination too (belt + braces).
#   5. Launches the app.
#
# Note: the .command file itself is also quarantined when downloaded. The
# first time you double-click, macOS may say "cannot verify the developer".
# If so, click Cancel, right-click the file, choose Open, then confirm.
# (Right-click → Open still works for shell scripts on Sequoia; it's only
# ad-hoc-signed .app bundles that lost that bypass.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/HikViewer.app"
DEST="/Applications/HikViewer.app"

b()   { printf '\033[1m%s\033[0m\n'   "$*"; }
ok()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn(){ printf '\033[0;33m%s\033[0m\n' "$*"; }
err() { printf '\033[0;31m%s\033[0m\n' "$*"; }

b "Installing HikViewer…"
echo

if [[ ! -d "$SRC" ]]; then
  err "HikViewer.app not found next to this installer."
  err "Expected: $SRC"
  echo
  echo "Make sure you're running this from inside the unzipped release"
  echo "folder. The .command file and HikViewer.app should sit side by side."
  echo
  echo "Press any key to close this window."
  read -r -n 1 -s
  exit 1
fi

if pgrep -f "/Applications/HikViewer.app/Contents/MacOS/hikviewer" >/dev/null 2>&1; then
  echo "Quitting running HikViewer…"
  osascript -e 'tell application "HikViewer" to quit' 2>/dev/null || true
  sleep 1
fi

echo "Stripping quarantine attribute…"
xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true

echo "Copying to /Applications…"
rm -rf "$DEST"
ditto "$SRC" "$DEST"

xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Launching HikViewer…"
open "$DEST" 2>/dev/null || true

echo
ok "Done. HikViewer is installed at $DEST"
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo
  warn "ffmpeg not found on PATH — HikViewer needs it to stream video:"
  warn "  brew install ffmpeg"
fi
echo
echo "Press any key to close this window."
read -r -n 1 -s
