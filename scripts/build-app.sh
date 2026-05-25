#!/usr/bin/env bash
set -euo pipefail

# Build tinyClicker as a macOS .app bundle using Swift Package Manager.
# Output: ./build/tinyClicker.app
#
# Env vars:
#   CONFIG=debug|release   (default: release)
#   UNIVERSAL=1            build a universal arm64+x86_64 binary via lipo

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/tinyClicker.app"
CONFIG="${CONFIG:-release}"
UNIVERSAL="${UNIVERSAL:-0}"

cd "$ROOT_DIR"

if [[ "$UNIVERSAL" == "1" ]]; then
    echo "==> Building Swift package ($CONFIG, universal arm64+x86_64)"
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    BIN_PATH="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/tinyClicker"
else
    echo "==> Building Swift package ($CONFIG)"
    swift build -c "$CONFIG"
    BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/tinyClicker"
fi

if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built executable not found at $BIN_PATH" >&2
    find .build -name tinyClicker -type f 2>&1 | head -20 >&2 || true
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/tinyClicker"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT_DIR/Resources/icon.icns" ]]; then
    cp "$ROOT_DIR/Resources/icon.icns" "$APP_DIR/Contents/Resources/icon.icns"
fi

# Ad-hoc sign so macOS will let it run and remember Accessibility consent
# across rebuilds for the same code identity.
codesign --force --sign - --options runtime "$APP_DIR" >/dev/null 2>&1 || \
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "==> Done: $APP_DIR"
echo "Run with:   open '$APP_DIR'"
