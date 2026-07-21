#!/bin/bash
# Zip the built app into a Releases artifact (PromptQy.app.zip) that the
# README's one-line installer downloads. Run ./build_app.sh first.
#
# The app is not Apple-notarized, so the one-line installer strips the quarantine
# flag (xattr -dr com.apple.quarantine) after download — see README.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PromptQy"
APP="$ROOT/dist/$APP_NAME.app"
ZIP="$ROOT/dist/PromptQy.app.zip"

[ -d "$APP" ] || { echo "!! $APP not found — run ./build_app.sh first"; exit 1; }

rm -f "$ZIP"
# ditto keeps the bundle's code signature / resource forks intact (zip does not).
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Built: $ZIP"
ls -lh "$ZIP" | awk '{print $5, $9}'
