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
BUNDLE_ID="app.pavlenko.startmenu"
STABLE_REQUIREMENT_BODY="identifier \"$BUNDLE_ID\""
STABLE_REQUIREMENT="designated => $STABLE_REQUIREMENT_BODY"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "error: must be on main (currently on $BRANCH)" >&2
    exit 1
fi

DIRTY=$(git status --porcelain | grep -v '^.M \.claude/' || true)
if [ -n "$DIRTY" ]; then
    echo "error: working tree not clean — commit or stash changes first" >&2
    echo "$DIRTY"
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

echo "==> Re-signing app with stable designated requirement"
codesign \
    --force \
    --sign - \
    --entitlements StartMenu/Resources/StartMenu.entitlements \
    --requirements "=$STABLE_REQUIREMENT" \
    "$BUILT_APP"

ACTUAL_REQUIREMENT=$(codesign -d -r- "$BUILT_APP" 2>&1 | awk -F'=> ' '/designated =>/ {print $2}')
if [ "$ACTUAL_REQUIREMENT" != "$STABLE_REQUIREMENT_BODY" ]; then
    echo "error: expected designated requirement '$STABLE_REQUIREMENT_BODY' but got '$ACTUAL_REQUIREMENT'" >&2
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

# -- Homebrew cask update -----------------------------------------------
# Mirror the new version into region23/homebrew-tap so
# `brew upgrade --cask region23/tap/startmenu` sees the release.

TAP_REPO="region23/homebrew-tap"
TAP_CHECKOUT="$OUT_DIR/homebrew-tap"
CASK_PATH="$TAP_CHECKOUT/Casks/startmenu.rb"
DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo "==> Updating Homebrew tap ($TAP_REPO)"
rm -rf "$TAP_CHECKOUT"
if ! gh repo clone "$TAP_REPO" "$TAP_CHECKOUT" -- --quiet; then
    echo "warning: could not clone $TAP_REPO — skipping cask update" >&2
else
    mkdir -p "$(dirname "$CASK_PATH")"
    cat > "$CASK_PATH" <<CASK
cask "startmenu" do
  version "$VERSION"
  sha256 "$DMG_SHA"

  url "https://github.com/region23/StartMenu/releases/download/v#{version}/StartMenu-#{version}.dmg"
  name "Start Menu"
  desc "Windows-style taskbar and Start menu for macOS"
  homepage "https://github.com/region23/StartMenu"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :sonoma"

  app "StartMenu.app"

  postflight do
    # Ad-hoc signed, not notarized — strip the quarantine attribute
    # Homebrew applies to every downloaded cask so Gatekeeper doesn't
    # block the first launch.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/StartMenu.app"]
  end

  zap trash: [
    "~/Library/Preferences/app.pavlenko.startmenu.plist",
    "~/Library/Application Support/app.pavlenko.startmenu",
    "~/Library/Caches/app.pavlenko.startmenu",
  ]
end
CASK

    pushd "$TAP_CHECKOUT" >/dev/null
    if git diff --quiet -- Casks/startmenu.rb; then
        echo "    cask unchanged — nothing to push"
    else
        git add Casks/startmenu.rb
        git -c commit.gpgsign=false commit -m "startmenu $VERSION" >/dev/null
        git push origin HEAD >/dev/null
        echo "    pushed startmenu $VERSION to $TAP_REPO"
    fi
    popd >/dev/null
fi

echo
echo "==> Done. Released $TAG"
echo "    $RELEASE_URL"
