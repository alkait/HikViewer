#!/usr/bin/env bash
# push.sh — push to GitHub, optionally cutting a stable release tag.
#
#   ./push.sh          # plain push: CI compile check only, nothing published
#   ./push.sh patch    # push + tag vX.Y.Z -> vX.Y.(Z+1): release
#   ./push.sh minor    # push + tag vX.Y.Z -> vX.(Y+1).0: release
#   ./push.sh major    # push + tag vX.Y.Z -> v(X+1).0.0: release
#
# Only tag pushes publish a release (.github/workflows/release.yml) — that's
# what the in-app updater (Check for Updates…) and the curl|bash installer
# track via releases/latest.
set -euo pipefail
cd "$(dirname "$0")"

bump="${1:-}"
case "$bump" in
  ""|patch|minor|major) ;;
  *) echo "usage: $0 [patch|minor|major]" >&2; exit 1 ;;
esac

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "main" ] || { echo "error: on branch '$branch' — releases cut from main only" >&2; exit 1; }

if ! git diff-index --quiet HEAD --; then
  echo "note: uncommitted changes exist — only committed work is pushed/released." >&2
fi

git push origin main

[ -z "$bump" ] && { echo "Pushed. CI runs a compile check only — no release published."; exit 0; }

# Base the bump on the newest vX.Y.Z tag anywhere (fetch first so a tag cut
# from another machine isn't missed and reused).
git fetch --tags -q origin
latest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
latest="${latest:-v0.0.0}"
IFS=. read -r maj min pat <<<"${latest#v}"
case "$bump" in
  major) tag="v$((maj + 1)).0.0" ;;
  minor) tag="v${maj}.$((min + 1)).0" ;;
  patch) tag="v${maj}.${min}.$((pat + 1))" ;;
esac

git tag -a "$tag" -m "HikViewer $tag"
git push origin "$tag"
echo "Cut $tag (was $latest). CI is building the stable release — installed apps will offer it via Check for Updates…"
