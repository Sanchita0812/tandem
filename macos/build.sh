#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-debug}"

echo "==> Building TandemMac ($CONFIG) via Swift Package Manager..."
if [ "$CONFIG" = "release" ]; then
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/TandemMac"
else
    swift build
    BIN_PATH="$(swift build --show-bin-path)/TandemMac"
fi

APP_DIR="$SCRIPT_DIR/build/TandemMac.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Creating macOS App Bundle at $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/TandemMac"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

echo "==> Code-signing bundle with ad-hoc signature..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Build successful!"
echo "To run TandemMac, execute: open $APP_DIR"
