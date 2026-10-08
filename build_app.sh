#!/bin/bash
# Build PromptQy.app (menu-bar host + Quick Look Preview/Thumbnail extensions).
# Entry point for Agent / CI — generates Xcode project via xcodegen, then xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PromptQy"
VERSION="$(cat "$ROOT/VERSION")"
DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-11.0}"
DERIVED="$ROOT/dist/DerivedData"
APP="$ROOT/dist/$APP_NAME.app"
ICONSET="$ROOT/dist/icon.iconset"

command -v xcodegen >/dev/null || {
    echo "!! xcodegen not found — install with: brew install xcodegen" >&2
    exit 1
}
command -v xcodebuild >/dev/null || {
    echo "!! xcodebuild not found — install Xcode / CLT" >&2
    exit 1
}

echo "==> Version $VERSION (macOS $DEPLOYMENT_TARGET)"
rm -rf "$APP" "$ICONSET" "$DERIVED"
mkdir -p "$ROOT/dist" "$ROOT/App"

echo "==> Generating AppIcon.icns"
mkdir -p "$ICONSET"
swift "$ROOT/generate_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/App/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Generating Xcode project"
(cd "$ROOT" && xcodegen generate)

echo "==> Building with xcodebuild"
ARCH="$(uname -m)"
# Do not pass MACOSX_DEPLOYMENT_TARGET here — it overrides every target and
# breaks MarkdownPreview (needs 12.0 for QLPreviewProvider). Per-target
# versions live in project.yml.
xcodebuild \
    -project "$ROOT/PromptQy.xcodeproj" \
    -scheme PromptQy \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination "platform=macOS,arch=${ARCH}" \
    ARCHS="$ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    build

BUILT="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "!! build product missing: $BUILT" >&2; exit 1; }
rm -rf "$APP"
cp -R "$BUILT" "$APP"

# Prefer a stable self-signed identity (see setup_signing.sh) so TCC grants
# survive rebuilds; fall back to ad-hoc otherwise. Sign nested appexes first.
sign_identity="-"
keychain_args=()
CERT_NAME="PromptQy Dev"
DEV_KEYCHAIN="$HOME/Library/Keychains/promptqy-dev.keychain-db"
if security find-certificate -c "$CERT_NAME" "$DEV_KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Code signing with stable identity: $CERT_NAME"
    security unlock-keychain -p "promptqy-dev" "$DEV_KEYCHAIN" 2>/dev/null || true
    sign_identity="$CERT_NAME"
    keychain_args=(--keychain "$DEV_KEYCHAIN")
else
    echo "==> Code signing (ad-hoc; run ./setup_signing.sh for a stable identity)"
fi

PLUGINS="$APP/Contents/PlugIns"
if [ -d "$PLUGINS/MarkdownPreview.appex" ]; then
    echo "==> Signing MarkdownPreview.appex"
    codesign --force --sign "$sign_identity" "${keychain_args[@]}" \
        --entitlements "$ROOT/MarkdownPreview/MarkdownPreview.entitlements" \
        "$PLUGINS/MarkdownPreview.appex"
fi
if [ -d "$PLUGINS/MarkdownThumbnail.appex" ]; then
    echo "==> Signing MarkdownThumbnail.appex"
    codesign --force --sign "$sign_identity" "${keychain_args[@]}" \
        --entitlements "$ROOT/MarkdownThumbnail/MarkdownThumbnail.entitlements" \
        "$PLUGINS/MarkdownThumbnail.appex"
fi

echo "==> Signing $APP_NAME.app"
codesign --force --sign "$sign_identity" "${keychain_args[@]}" "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" || true

echo "==> PlugIns:"
ls -la "$PLUGINS" 2>/dev/null || echo "(none)"

echo "==> Done: $APP"
echo
echo "Run with:    open \"$APP\""
echo "Install via: rm -rf /Applications/PromptQy.app && cp -R \"$APP\" /Applications/"
echo "  (must replace, not merge — a merge leaves stale Resources and breaks codesign)"
echo "Then enable Quick Look extensions if needed:"
echo "  System Settings → General → Login Items & Extensions → Quick Look"
