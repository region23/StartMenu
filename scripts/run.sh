#!/usr/bin/env bash
# Build StartMenu, copy to a stable path, relaunch.
# Using a stable install path keeps the TCC (Accessibility / Screen Recording)
# grant valid across rebuilds. Grant permissions once for ~/Applications/StartMenu.app
# and subsequent runs should keep them.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="StartMenu.xcodeproj"
SCHEME="StartMenu"
CONFIG="Debug"
INSTALL_DIR="$HOME/Applications"
INSTALL_PATH="$INSTALL_DIR/StartMenu.app"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Building ($CONFIG)"
BUILD_LOG=$(mktemp)
set +e
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    build >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' "$BUILD_LOG" || true

if [ $BUILD_STATUS -ne 0 ]; then
    echo "error: build failed (status $BUILD_STATUS)" >&2
    rm -f "$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData/StartMenu-*/Build/Products/$CONFIG -name "StartMenu.app" -type d 2>/dev/null | head -1)
if [ -z "$BUILT_APP" ]; then
    echo "error: built .app not found" >&2
    exit 1
fi

echo "==> Killing running instance"
pkill -x StartMenu 2>/dev/null || true
sleep 0.3

echo "==> Resetting TCC grants for app.pavlenko.startmenu"
# Ad-hoc signed binaries change cdhash on every build → TCC silently invalidates
# the Accessibility grant. Reset cleanly so the user is re-prompted on launch and
# the grant actually matches the fresh binary.
tccutil reset Accessibility app.pavlenko.startmenu 2>/dev/null || true
tccutil reset ScreenCapture app.pavlenko.startmenu 2>/dev/null || true
tccutil reset AppleEvents app.pavlenko.startmenu 2>/dev/null || true

echo "==> Installing to $INSTALL_PATH"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_PATH"
cp -R "$BUILT_APP" "$INSTALL_PATH"

echo "==> Launching"
open "$INSTALL_PATH"

echo "==> Done"
