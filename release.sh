#!/bin/bash
# Cut a release: bump VERSION → build → zip → GitHub Release → update the
# Homebrew cask so `brew upgrade --cask prompt-qy` picks it up.
#
#   ./release.sh 0.1.2
#
# Needs `gh`, authenticated. The Homebrew tap is cloned on demand, so no local
# checkout of it has to exist — point TAP_DIR at one to reuse it instead.
set -euo pipefail

TAP_REPO="DoAutumn/homebrew-tap"
GH_REPO="DoAutumn/prompt-qy"
CASK_TOKEN="prompt-qy"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: ./release.sh <version>   e.g. ./release.sh 0.1.2"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
ZIP="$ROOT/dist/PromptQy.app.zip"
TAG="v$VERSION"

[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "!! working tree is dirty — commit first"; exit 1; }
git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1 && { echo "!! tag $TAG already exists"; exit 1; }

# A clean tree says nothing about being up to date: a release cut from another
# machine leaves this one behind, and the push then bounces *after* the release
# commit and tag are already made locally. Check against the remote up front —
# and check the remote tag too, since the local one can be absent while the
# version is long since published.
echo "==> Checking the remote"
git -C "$ROOT" fetch -q origin
[ -z "$(git -C "$ROOT" ls-remote --tags origin "$TAG")" ] || {
    echo "!! tag $TAG already exists on the remote — someone released it elsewhere."
    echo "   Pull, then pick the next free version."
    exit 1
}
UPSTREAM="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/main)"
BEHIND="$(git -C "$ROOT" rev-list --count "HEAD..$UPSTREAM")"
[ "$BEHIND" -eq 0 ] || {
    echo "!! HEAD is $BEHIND commit(s) behind $UPSTREAM — rebase first, then rerun."
    exit 1
}

# `gh` is not needed until after the tag is pushed, so check it up front: finding
# out late leaves the tag published with no release behind it, and the rerun then
# trips over "tag already exists".
command -v gh >/dev/null || { echo "!! gh not found — install it first (brew install gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "!! gh is not authenticated — run: gh auth login"; exit 1; }

if [ -n "${TAP_DIR:-}" ]; then
    TAP="$TAP_DIR"
    git -C "$TAP" pull -q --ff-only
else
    TAP="$(mktemp -d)/homebrew-tap"
    trap 'rm -rf "$(dirname "$TAP")"' EXIT
    echo "==> Cloning $TAP_REPO"
    git clone -q "https://github.com/$TAP_REPO.git" "$TAP"
fi
CASK="$TAP/Casks/${CASK_TOKEN}.rb"
OLD_CASK="$TAP/Casks/claude-command-bar.rb"

echo "$VERSION" > "$ROOT/VERSION"

"$ROOT/build_app.sh"
"$ROOT/make_zip.sh"

echo "==> Tagging $TAG"
git -C "$ROOT" commit -am "release: $TAG"
git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push origin HEAD "$TAG"

echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$ZIP" --repo "$GH_REPO" --generate-notes

# The cask pins a checksum, so it must be recomputed from the exact artifact the
# release serves. Hash the local zip — it is byte-identical to what was uploaded.
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> Writing cask $CASK_TOKEN $VERSION ($SHA)"
cat > "$CASK" <<CASK
cask "$CASK_TOKEN" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$GH_REPO/releases/download/v#{version}/PromptQy.app.zip"
  name "PromptQy"
  desc "Menu-bar composer that feeds text, paths and screenshots to Claude Code"
  homepage "https://github.com/$GH_REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :big_sur

  app "PromptQy.app"

  # The app is not Apple-notarized, so Homebrew's quarantine flag would make
  # Gatekeeper refuse the first launch ("damaged, move to Trash"). Strip it here
  # rather than making every user remember \`--no-quarantine\` on install *and*
  # upgrade. Only possible in a third-party tap; homebrew-cask forbids this.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/PromptQy.app"]
  end

  uninstall quit: "io.github.promptqy"

  zap trash: [
    "~/Library/Preferences/io.github.promptqy.plist",
    "~/Library/Saved Application State/io.github.promptqy.savedState",
  ]
end
CASK

# Drop the legacy cask token so installs go through prompt-qy only.
rm -f "$OLD_CASK"

git -C "$TAP" add -A
git -C "$TAP" commit -m "prompt-qy $VERSION (rename from claude-command-bar)"
# The tap is cloned over https, so pushing needs a git credential helper — which
# `gh auth login` alone does not set up. Say so instead of dying on git's
# "could not read Username": the release is already out at this point and only
# the cask bump is missing.
git -C "$TAP" push || {
    echo "!! pushing the tap failed — the GitHub release for $TAG is already published,"
    echo "   only the cask bump is missing. Fix the git credentials and rerun just that:"
    echo "     gh auth setup-git"
    echo "     ./release.sh $VERSION   # will refuse: the tag exists — bump the cask by hand instead"
    exit 1
}

echo
echo "==> Released $TAG"
echo "    brew install --cask DoAutumn/tap/prompt-qy"
echo "    brew upgrade --cask prompt-qy"
