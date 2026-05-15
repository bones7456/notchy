#!/usr/bin/env bash
set -euo pipefail

# Build, notarize, and package Notchy.app into a ZIP and a DMG.
# Signing happens inside build_app.sh: when SIGNING_IDENTITY is set, it
# archives with Developer ID Application and the .app is copied straight
# out of the .xcarchive (Xcode 26's exportArchive is unreliable when
# signing settings are overridden, so we skip it).
#
# Environment:
#   SIGNING_IDENTITY        Required. Tells build_app.sh to use Developer
#                           ID signing for the archive, and used here to
#                           sign the DMG.
#                           e.g. "Developer ID Application: LuYang Li (RHVTXHK83V)"
#   APPLE_ID                Apple ID email (required for notarization)
#   APPLE_APP_PASSWORD      App-specific password (required for notarization)
#   APPLE_TEAM_ID           Developer Team ID (required for notarization)
#   SKIP_NOTARIZE           Set to "1" to sign but skip notarization.
#
# Behavior:
#   - If SIGNING_IDENTITY is unset, the .app is built but left ad-hoc-signed
#     and no archives are produced (CI / local sanity build).
#   - If signing creds are set but notarization creds are missing, the script
#     signs the app and builds ZIP/DMG, but does not submit to Apple.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

# Stage the bundle outside the project tree. If the project lives inside an
# iCloud / Dropbox / OneDrive synced folder, the file provider keeps re-adding
# com.apple.FinderInfo / fileprovider xattrs that codesign refuses to sign.
STAGE_DIR="/tmp/notchy"
APP_DIR="$STAGE_DIR/Notchy.app"
DMG_STAGE_DIR="$STAGE_DIR/dmg-stage"

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/build_app.sh" >/dev/null

BUILT_APP="$DIST_DIR/Notchy.app"
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BASENAME="Notchy-${MARKETING_VERSION}"
STAGED_ZIP="$STAGE_DIR/${BASENAME}.zip"
STAGED_DMG="$STAGE_DIR/${BASENAME}.dmg"
ZIP_PATH="$DIST_DIR/${BASENAME}.zip"
DMG_PATH="$DIST_DIR/${BASENAME}.dmg"

if [ -z "${SIGNING_IDENTITY:-}" ]; then
    echo "SIGNING_IDENTITY not set; produced ad-hoc-signed $BUILT_APP" >&2
    exit 0
fi

echo "==> Staging signed bundle at $APP_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ditto "$BUILT_APP" "$APP_DIR"

# build_app.sh already signed the app with hardened runtime + entitlements.
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

needs_notarize=1
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    needs_notarize=0
fi
if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
    needs_notarize=0
    echo "Notarization credentials not fully set; will package without notarization." >&2
fi

submit_for_notarization() {
    local target="$1"
    echo "==> Submitting $target to notarytool"
    xcrun notarytool submit "$target" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
}

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGED_ZIP"

if [ "$needs_notarize" = "1" ]; then
    submit_for_notarization "$STAGED_ZIP"
    echo "==> Stapling $APP_DIR"
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"

    # Re-zip so the archive contains the stapled bundle.
    rm -f "$STAGED_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGED_ZIP"
fi

echo "==> Building DMG"
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_DIR" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

hdiutil create \
    -volname "Notchy ${MARKETING_VERSION}" \
    -srcfolder "$DMG_STAGE_DIR" \
    -ov -format UDZO \
    "$STAGED_DMG"
rm -rf "$DMG_STAGE_DIR"

codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$STAGED_DMG"

if [ "$needs_notarize" = "1" ]; then
    submit_for_notarization "$STAGED_DMG"
    xcrun stapler staple "$STAGED_DMG"
    xcrun stapler validate "$STAGED_DMG"
fi

echo "==> Copying artifacts to $DIST_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH"
cp "$STAGED_ZIP" "$ZIP_PATH"
cp "$STAGED_DMG" "$DMG_PATH"

echo "==> Artifacts:"
echo "    $ZIP_PATH"
echo "    $DMG_PATH"
