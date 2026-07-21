#!/bin/bash
# Build "PromptQy.app" — an LSUIElement (no Dock) menu-bar app that
# hosts the always-on-top composer. Mirrors the build form of the sibling
# claude-desktop-usage project.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PromptQy"
APP="$ROOT/dist/$APP_NAME.app"
ICONSET="$ROOT/dist/icon.iconset"
# Single source of truth for the version; release.sh bumps it and keeps the git
# tag, the GitHub release and the Homebrew cask in sync with it.
VERSION="$(cat "$ROOT/VERSION")"

echo "==> Cleaning $APP"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "==> Generating app icon (iconset → icns)"
mkdir -p "$ICONSET"
swift "$ROOT/generate_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Compiling Swift binary"
# Pin the deployment target so the Mach-O runs on older macOS (see sibling repo).
DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-11.0}"
swiftc -O -target "$(uname -m)-apple-macos${DEPLOYMENT_TARGET}" \
    -o "$APP/Contents/MacOS/PromptQy" "$ROOT/command_bar.swift"

echo "==> Writing Info.plist (version $VERSION)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>PromptQy</string>
    <key>CFBundleDisplayName</key>     <string>PromptQy</string>
    <key>CFBundleIdentifier</key>      <string>io.github.promptqy</string>
    <key>CFBundleExecutable</key>      <string>PromptQy</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIconName</key>        <string>AppIcon</string>
    <key>LSUIElement</key>             <true/>
    <key>NSAppleEventsUsageDescription</key> <string>控制 Finder 与终端（终端.app / iTerm2），以插入文件路径、把内容发送到终端并执行。</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>Personal tool. Not an Anthropic product.</string>
</dict>
</plist>
PLIST

# Prefer a stable self-signed identity (see setup_signing.sh) so TCC grants
# (Accessibility/Automation) survive rebuilds; fall back to ad-hoc otherwise.
CERT_NAME="PromptQy Dev"
DEV_KEYCHAIN="$HOME/Library/Keychains/promptqy-dev.keychain-db"
if security find-certificate -c "$CERT_NAME" "$DEV_KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Code signing with stable identity: $CERT_NAME"
    security unlock-keychain -p "promptqy-dev" "$DEV_KEYCHAIN" 2>/dev/null || true
    codesign --force --keychain "$DEV_KEYCHAIN" --sign "$CERT_NAME" "$APP"
else
    echo "==> Code signing (ad-hoc; run ./setup_signing.sh for a stable identity)"
    codesign --force --sign - "$APP"
fi
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" || true

echo "==> Done: $APP"
echo
echo "Run with:    open \"$APP\""
echo "Install via: cp -R \"$APP\" /Applications/"
