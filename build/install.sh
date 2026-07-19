#!/usr/bin/env bash
# HikViewer curl|bash installer.
#
# Usage:
#   /bin/bash -c "$(curl -fsSL https://github.com/alkait/hikviewer/releases/latest/download/install.sh)"
#
# Why this exists:
#   HikViewer is open-source and ad-hoc signed (no Apple Developer account).
#   When Safari/Chrome/Firefox download a file, they attach the
#   `com.apple.quarantine` extended attribute. On macOS Sequoia the kernel
#   refuses to launch ad-hoc-signed apps that carry that xattr, with no
#   right-click → Open bypass — users see the "HikViewer is damaged and
#   can't be opened" dialog and give up.
#
#   `curl`, by contrast, does not attach com.apple.quarantine to files it
#   writes. So this script — itself running because it was curl'd into bash —
#   can curl down the release zip, extract it, and drop a quarantine-free
#   .app into /Applications, sidestepping Gatekeeper entirely.
#
# What it does:
#   1. Sanity-checks: macOS, /Applications writable.
#   2. Resolves the latest release tag once up front so all asset downloads
#      are pinned to the same release — defends against the brief CDN window
#      after a publish where `releases/latest/download/<asset>` can hand out
#      assets from two adjacent releases. Override with $HIKVIEWER_ZIP_URL to
#      pin a specific release or a dev pre-release.
#   3. Downloads HikViewer-macos-universal.app.zip into a temp dir.
#   4. Verifies the SHA-256 against the SHA256SUMS file shipped with the same
#      release. Skipped only via $HIKVIEWER_SKIP_VERIFY=1.
#   5. Extracts, quits a running HikViewer, replaces
#      /Applications/HikViewer.app, strips com.apple.quarantine.
#   6. Launches the new build.
#
# Idempotent. Safe to re-run after every update — the in-app updater runs
# exactly this script.

set -euo pipefail

REPO="alkait/hikviewer"
DEST="/Applications/HikViewer.app"
ASSET="HikViewer-macos-universal.app.zip"

# ---- tiny output helpers -------------------------------------------------

if [[ -t 1 ]]; then
  _BOLD=$'\033[1m'; _DIM=$'\033[2m'; _RED=$'\033[0;31m'
  _GREEN=$'\033[0;32m'; _YELLOW=$'\033[0;33m'; _RESET=$'\033[0m'
else
  _BOLD=''; _DIM=''; _RED=''; _GREEN=''; _YELLOW=''; _RESET=''
fi

step() { printf '%s==>%s %s\n' "$_BOLD" "$_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n'   "$_GREEN" "$_RESET" "$*"; }
warn() { printf '%s!%s %s\n'   "$_YELLOW" "$_RESET" "$*"; }
die()  { printf '%serror:%s %s\n' "$_RED" "$_RESET" "$*" >&2; exit 1; }

# ---- sanity checks -------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "this installer is macOS-only (got $(uname -s))"

# /Applications is writable by admins without sudo on a default macOS
# install. If it isn't (managed Mac, weird perms), bail with a clear message
# rather than spamming sudo prompts.
if [[ ! -w /Applications ]]; then
  die "/Applications is not writable by the current user. Re-run with admin privileges or move HikViewer.app there manually after extracting."
fi

# ---- temp dir + cleanup --------------------------------------------------

TMP="$(mktemp -d -t hikviewer-install)"
trap 'rm -rf "$TMP"' EXIT

ZIP_PATH="$TMP/$ASSET"
SUMS_PATH="$TMP/SHA256SUMS"

# ---- resolve latest release tag -----------------------------------------

# We resolve a single tag up front instead of using
# /releases/latest/download/<asset> per download: each of those is a separate
# redirect, and just after a publish different assets can briefly resolve to
# different releases — producing a SHA-256 mismatch even though each release
# on its own is consistent. The GitHub API updates instantly, so we go
# through that. JSON is parsed without jq (not guaranteed on the user's
# machine): the API returns the release as one minified line, so grep -o
# pulls out the `"tag_name": "vX.Y.Z"` pair and sed peels off the value.
if [[ -n "${HIKVIEWER_ZIP_URL:-}" ]]; then
  ZIP_URL="$HIKVIEWER_ZIP_URL"
  SUMS_URL="${HIKVIEWER_SUMS_URL:-${ZIP_URL%/*}/SHA256SUMS}"
  TAG="(pinned)"
else
  step "Resolving latest release"
  TAG="$(curl -fsL --retry 2 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')" \
    || die "could not reach api.github.com to resolve latest release"
  if [[ -z "$TAG" || "$TAG" == "latest" ]]; then
    die "could not parse latest release tag from GitHub API response"
  fi
  BASE="https://github.com/${REPO}/releases/download/${TAG}"
  ZIP_URL="$BASE/$ASSET"
  SUMS_URL="$BASE/SHA256SUMS"
  ok "latest release: $TAG"
fi

# ---- download ------------------------------------------------------------

step "Downloading HikViewer from $ZIP_URL"
curl -fL --retry 3 --retry-delay 2 -o "$ZIP_PATH" "$ZIP_URL" \
  || die "failed to download $ZIP_URL"

# ---- verify checksum -----------------------------------------------------

if [[ "${HIKVIEWER_SKIP_VERIFY:-0}" == "1" ]]; then
  warn "skipping checksum verification (HIKVIEWER_SKIP_VERIFY=1)"
else
  step "Verifying SHA-256 against $SUMS_URL"
  if ! curl -fsL --retry 2 -o "$SUMS_PATH" "$SUMS_URL"; then
    die "failed to download SHA256SUMS — re-run with HIKVIEWER_SKIP_VERIFY=1 to bypass (not recommended)"
  fi
  basename_zip="$(basename "$ZIP_URL")"
  expected_line="$(grep -E "[[:space:]]${basename_zip}\$" "$SUMS_PATH" || true)"
  if [[ -z "$expected_line" ]]; then
    die "no checksum entry for $basename_zip in SHA256SUMS — release may be corrupt"
  fi
  ln -s "$ZIP_PATH" "$TMP/$basename_zip" 2>/dev/null || true
  ( cd "$TMP" && printf '%s\n' "$expected_line" | shasum -a 256 -c --status ) \
    || die "SHA-256 mismatch for $basename_zip — refusing to install a corrupted download"
  ok "checksum matches"
fi

# ---- extract -------------------------------------------------------------

step "Extracting"
unzip -q "$ZIP_PATH" -d "$TMP/extracted"

# The release zip stages everything inside a versioned folder, so search for
# HikViewer.app anywhere under the extraction root instead of hard-coding the
# folder name and breaking on the next version bump.
SRC_APP="$(find "$TMP/extracted" -maxdepth 3 -name HikViewer.app -type d -print -quit)"
[[ -n "$SRC_APP" ]] || die "HikViewer.app not found inside the downloaded zip — release may be malformed"

# ---- quit running instance ----------------------------------------------

if pgrep -f "/Applications/HikViewer.app/Contents/MacOS/hikviewer" >/dev/null 2>&1; then
  step "Quitting running HikViewer"
  osascript -e 'tell application "HikViewer" to quit' 2>/dev/null || true
  # Give LaunchServices a moment to deliver the quit + tear down the process,
  # otherwise the rm below races a held file descriptor.
  sleep 1
fi

# ---- install -------------------------------------------------------------

step "Installing to $DEST"
rm -rf "$DEST"
# ditto preserves resource forks, codesign metadata, and symlinks inside the
# bundle. Plain `cp -R` can subtly corrupt the bundle.
ditto "$SRC_APP" "$DEST"

# Defensive xattr strip. curl-downloaded files don't carry
# com.apple.quarantine, but the unzip step may have preserved one baked into
# the zip by the release pipeline.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# ---- launch --------------------------------------------------------------

step "Launching HikViewer"
open "$DEST" 2>/dev/null || true

echo
ok "HikViewer installed at $DEST"
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo
  warn "ffmpeg not found on PATH — HikViewer needs it to stream video:"
  warn "  brew install ffmpeg"
fi
echo
printf '%sUpdates:%s use HikViewer → Check for Updates…, or re-run this installer.\n' "$_DIM" "$_RESET"
