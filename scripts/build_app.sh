#!/usr/bin/env bash
set -euo pipefail

# Archive Notchy.app from Notchy.xcodeproj.
#   - If SIGNING_IDENTITY is set, archive is signed with Developer ID
#     Application (signed for redistribution outside the App Store).
#   - Otherwise the .app comes out ad-hoc-signed (good for a local
#     sanity build without a Developer ID cert).
# The .app is copied directly from the .xcarchive; we don't use
# `xcodebuild -exportArchive` because Xcode 26 doesn't populate
# ApplicationProperties when signing settings are overridden on the
# command line, which makes exportArchive fail with an empty list of
# available distribution methods.
#
# Output: $ROOT_DIR/dist/Notchy.app

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Notchy.xcarchive"

XCODE_PROJECT="$ROOT_DIR/Notchy.xcodeproj"
SCHEME="${SCHEME:-Notchy}"
CONFIGURATION="${CONFIGURATION:-Release}"

cd "$ROOT_DIR"

mkdir -p "$DIST_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Sparkle decides whether an update is available by comparing the appcast's
# <sparkle:version> against the installed app's CFBundleVersion (the build
# number). The project keeps CURRENT_PROJECT_VERSION pinned at 1, so without
# this override every release would ship CFBundleVersion=1 and Sparkle could
# never tell two releases apart. Pin the build number to the marketing version
# instead: it is monotonic across releases and matches what the appcast
# publishes, so 1.2.4 == 1.2.4 (no false update) while 1.2.4 -> 1.2.5 is
# correctly detected.
MARKETING_VERSION="$(xcodebuild -project "$XCODE_PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION =/{print $2; exit}')"
if [ -z "$MARKETING_VERSION" ]; then
    echo "ERROR: could not determine MARKETING_VERSION from build settings" >&2
    exit 1
fi

echo "==> Archiving $SCHEME ($CONFIGURATION) as build $MARKETING_VERSION"
ARCHIVE_SIGN_ARGS=(CURRENT_PROJECT_VERSION="$MARKETING_VERSION")
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    # Xcode 26's automatic signing picks the Apple Development cert for
    # archives, which leaves ApplicationProperties out of the archive's
    # Info.plist and breaks exportArchive. Force Developer ID Application
    # signing with manual style so the archive is distributable.
    ARCHIVE_SIGN_ARGS+=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="Developer ID Application: LuYang Li (RHVTXHK83V)"
        PROVISIONING_PROFILE_SPECIFIER=""
        DEVELOPMENT_TEAM=RHVTXHK83V
    )
fi
xcodebuild archive \
    -project "$XCODE_PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    SKIP_INSTALL=NO \
    "${ARCHIVE_SIGN_ARGS[@]}"

BUILT_APP="$ARCHIVE_PATH/Products/Applications/Notchy.app"

OUT_APP="$DIST_DIR/Notchy.app"
rm -rf "$OUT_APP"
ditto "$BUILT_APP" "$OUT_APP"

echo "$OUT_APP"
