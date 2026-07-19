#!/usr/bin/env bash
# Build HikViewer.
#   ./build.sh            # universal binary + HikViewer.app (double-clickable, icon everywhere)
#   ./build.sh --install  # ...and copy HikViewer.app into /Applications
#   ./build.sh --native   # quick single-arch bare binary for this Mac only (dev)
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
[ "${1:-}" = "--install" ] && { INSTALL=1; shift; }

# Version stamp. Local builds leave the committed 0.0.0-dev default in place
# (sed is a no-op, tree stays clean); the release workflow exports
# VERSION=<tag> and this bakes it into the binary + Info.plist so the in-app
# updater can compare against GitHub releases.
VERSION="${VERSION:-0.0.0-dev}"
sed -i '' -E "s/^let appVersion = .*/let appVersion = \"${VERSION}\"/" Sources/Version.swift
PLIST_VERSION="${VERSION#v}"

if ! command -v swiftc >/dev/null; then
  echo "error: swiftc not found — install Xcode Command Line Tools (xcode-select --install)" >&2
  exit 1
fi

# --- 1. compile ---
if [ "${1:-}" = "--native" ]; then
  echo "Building hikviewer for $(uname -m)…"
  swiftc -O Sources/*.swift -o hikviewer
  codesign -f -s - hikviewer 2>/dev/null || true
  echo "Done → ./hikviewer"
  command -v ffmpeg >/dev/null || echo "note: ffmpeg not installed — the app needs it (brew install ffmpeg)" >&2
  exit 0
fi

echo "Building universal hikviewer (arm64 + x86_64)…"
swiftc -O -target arm64-apple-macos12  Sources/*.swift -o /tmp/hik-arm64
swiftc -O -target x86_64-apple-macos12 Sources/*.swift -o /tmp/hik-x86_64
lipo -create -output hikviewer /tmp/hik-arm64 /tmp/hik-x86_64
rm -f /tmp/hik-arm64 /tmp/hik-x86_64
codesign -f -s - hikviewer 2>/dev/null || true

# --- 2. app icon (.icns) rendered from the binary at every size ---
echo "Rendering app icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
gen() { ./hikviewer --icon "$ICONSET/$1" "$2"; }
gen icon_16x16.png 16      ; gen icon_16x16@2x.png 32
gen icon_32x32.png 32      ; gen icon_32x32@2x.png 64
gen icon_128x128.png 128   ; gen icon_128x128@2x.png 256
gen icon_256x256.png 256   ; gen icon_256x256@2x.png 512
gen icon_512x512.png 512   ; gen icon_512x512@2x.png 1024

# --- 3. assemble HikViewer.app ---
echo "Assembling HikViewer.app…"
APP="HikViewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp hikviewer "$APP/Contents/MacOS/hikviewer"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>HikViewer</string>
  <key>CFBundleDisplayName</key>     <string>HikViewer</string>
  <key>CFBundleIdentifier</key>      <string>com.hikcamviewer.app</string>
  <key>CFBundleExecutable</key>      <string>hikviewer</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${PLIST_VERSION}</string>
  <key>CFBundleVersion</key>         <string>${PLIST_VERSION}</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>LSMinimumSystemVersion</key>  <string>12.0</string>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# --- 4. ad-hoc sign the bundle ---
codesign -f -s - --deep "$APP" 2>/dev/null || true

if [ "$INSTALL" = 1 ]; then
  pkill -f "/Applications/$APP/Contents/MacOS/hikviewer" 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "Installed → /Applications/$APP"
fi

echo "Done → ./hikviewer (CLI) and ./$APP (double-clickable)"
lipo -info hikviewer
command -v ffmpeg >/dev/null || echo "note: ffmpeg not installed — the app needs it (brew install ffmpeg)" >&2
