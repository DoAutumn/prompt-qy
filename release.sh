#!/bin/bash
# Cut a release: bump VERSION → build → zip → GitHub Release → update the
# Homebrew cask so `brew upgrade --cask claude-command-bar` picks it up.
#
#   ./release.sh 0.1.2
#
# Needs `gh` (authenticated) and a local checkout of DoAutumn/homebrew-tap,
# expected next to this repo — override with TAP_DIR=/path/to/homebrew-tap.
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: ./release.sh <version>   e.g. ./release.sh 0.1.2"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
TAP="${TAP_DIR:-$ROOT/../homebrew-tap}"
CASK="$TAP/Casks/claude-command-bar.rb"
ZIP="$ROOT/dist/Claude-Command-Bar.app.zip"
TAG="v$VERSION"

[ -f "$CASK" ] || { echo "!! cask not found: $CASK (set TAP_DIR)"; exit 1; }
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "!! working tree is dirty — commit first"; exit 1; }
git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1 && { echo "!! tag $TAG already exists"; exit 1; }

echo "$VERSION" > "$ROOT/VERSION"

"$ROOT/build_app.sh"
"$ROOT/make_zip.sh"

echo "==> Tagging $TAG"
git -C "$ROOT" commit -am "release: $TAG"
git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push origin HEAD "$TAG"

echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" --repo DoAutumn/claude-command-bar --generate-notes

# The cask pins a checksum, so it must be recomputed from the exact artifact the
# release serves. Hash the local zip — it is byte-identical to what was uploaded.
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> Updating cask to $VERSION ($SHA)"
/usr/bin/sed -i '' \
    -e "s|^  version \".*\"|  version \"$VERSION\"|" \
    -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
    "$CASK"

git -C "$TAP" commit -am "claude-command-bar $VERSION"
git -C "$TAP" push

echo
echo "==> Released $TAG"
echo "    brew upgrade --cask claude-command-bar"
