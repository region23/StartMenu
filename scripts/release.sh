#!/usr/bin/env bash
# Build a Release .app, package it as a zip, create a git tag, publish a
# GitHub release with auto-generated release notes, and upload the zip.
#
# Usage:
#   ./scripts/release.sh <version>     # e.g. ./scripts/release.sh 0.1.0
#
# Requirements:
#   - gh CLI authenticated against the repo
#   - xcodegen, xcodebuild available
#   - Clean working tree on the main branch

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>    (e.g. 0.1.0)" >&2
    exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
    echo "error: version must look like X.Y.Z or X.Y.Z-suffix (got '$VERSION')" >&2
    exit 1
fi

TAG="v$VERSION"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "error: must be on main (currently on $BRANCH)" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree not clean — commit or stash changes first" >&2
    git status --short
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh CLI not installed (brew install gh)" >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh not authenticated — run 'gh auth login'" >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not installed (brew install xcodegen)" >&2
    exit 1
fi

PROJECT="StartMenu.xcodeproj"
SCHEME="StartMenu"
CONFIG="Release"
BUILD_NUMBER=$(git rev-list HEAD --count)

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Building $CONFIG ($VERSION, build $BUILD_NUMBER)"
BUILD_LOG=$(mktemp)
set +e
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    clean build >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' "$BUILD_LOG" || true

if [ $BUILD_STATUS -ne 0 ]; then
    echo "error: build failed (status $BUILD_STATUS). full log: $BUILD_LOG" >&2
    exit 1
fi
rm -f "$BUILD_LOG"

BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData/StartMenu-*/Build/Products/$CONFIG -name "StartMenu.app" -type d 2>/dev/null | head -1)
if [ -z "$BUILT_APP" ] || [ ! -d "$BUILT_APP" ]; then
    echo "error: built .app not found in DerivedData/$CONFIG" >&2
    exit 1
fi

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT_APP/Contents/Info.plist" 2>/dev/null || echo "?")
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "error: built CFBundleShortVersionString '$BUILT_VERSION' does not match requested '$VERSION'" >&2
    exit 1
fi

OUT_DIR="build/release"
DMG_NAME="StartMenu-$VERSION.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"

mkdir -p "$OUT_DIR"
rm -f "$DMG_PATH"

STAGING=$(mktemp -d)
cleanup_staging() { rm -rf "$STAGING"; }
trap cleanup_staging EXIT

echo "==> Staging DMG contents"
cp -R "$BUILT_APP" "$STAGING/StartMenu.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG_PATH"
hdiutil create \
    -volname "Start Menu" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo "==> Packaged ($DMG_SIZE)"

echo "==> Creating tag $TAG"
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "==> Publishing GitHub release"
gh release create "$TAG" \
    --title "Start Menu $TAG" \
    --generate-notes \
    "$DMG_PATH"

RELEASE_URL=$(gh release view "$TAG" --json url --jq .url)
echo
echo "==> Done. Released $TAG"
echo "    $RELEASE_URL"
