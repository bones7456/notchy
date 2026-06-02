#!/usr/bin/env bash
set -euo pipefail

# Build, notarize, and package Notchy.app into a ZIP and a DMG, and (if a
# Sparkle private key is available) emit a signed appcast.xml that Sparkle
# can consume for in-app updates.
#
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
#   SPARKLE_PRIVATE_KEY     EdDSA private key (base64, single line) used by
#                           Sparkle's sign_update. When set, the script
#                           generates dist/appcast.xml; otherwise it is
#                           skipped with a warning.
#   SPARKLE_VERSION         Optional. Sparkle release tag to download tools
#                           from. Defaults to 2.9.2.
#   SPARKLE_RELEASE_NOTES_FILE
#                           Optional. Path to an HTML file with rendered
#                           release notes. When set, its content is inlined
#                           into appcast.xml as <description><![CDATA[...]]>
#                           so the Sparkle prompt displays the notes
#                           directly instead of loading an external URL.
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
# Sparkle compares <sparkle:version> against the installed app's CFBundleVersion,
# so it must be the build number, not the marketing string. build_app.sh pins
# CFBundleVersion to the marketing version, so the two stay in lockstep.
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
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

# Sparkle's SPM-built helpers ship without our Developer ID + secure
# timestamp, which notarization rejects. Re-sign them and rebuild the
# enclosing seals from innermost outward.
SPARKLE_FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    echo "==> Re-signing Sparkle helpers with $SIGNING_IDENTITY"
    SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/Current"
    for helper in \
        "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
        "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
        "$SPARKLE_VERSION_DIR/Updater.app" \
        "$SPARKLE_VERSION_DIR/Autoupdate"; do
        if [ -e "$helper" ]; then
            codesign --force --options runtime --timestamp \
                --sign "$SIGNING_IDENTITY" \
                --preserve-metadata=identifier,entitlements,requirements \
                "$helper"
        fi
    done
    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$SPARKLE_FRAMEWORK"
    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ROOT_DIR/Notchy/Notchy.entitlements" \
        "$APP_DIR"
fi

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
    local json_out
    json_out="$(xcrun notarytool submit "$target" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait \
        --output-format json)"
    echo "$json_out"

    local status submission_id
    status="$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["status"])' <<< "$json_out")"
    submission_id="$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])' <<< "$json_out")"

    if [ "$status" != "Accepted" ]; then
        echo "==> Notarization status: $status — fetching detailed log" >&2
        xcrun notarytool log "$submission_id" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" >&2 || true
        echo "==> codesign metadata for embedded executables:" >&2
        for path in \
            "$APP_DIR" \
            "$APP_DIR/Contents/Frameworks/Sparkle.framework" \
            "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" \
            "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app" \
            "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc" \
            "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc"; do
            if [ -e "$path" ]; then
                echo "--- $path ---" >&2
                codesign -dvvv "$path" 2>&1 | sed 's/^/    /' >&2 || true
            fi
        done
        exit 1
    fi
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

APPCAST_PATH="$DIST_DIR/appcast.xml"
rm -f "$APPCAST_PATH"

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.2}"
    SPARKLE_TOOLS_DIR="$STAGE_DIR/sparkle-tools"
    SPARKLE_ARCHIVE="$STAGE_DIR/Sparkle-${SPARKLE_VERSION}.tar.xz"
    SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

    echo "==> Fetching Sparkle ${SPARKLE_VERSION} tools"
    rm -rf "$SPARKLE_TOOLS_DIR"
    mkdir -p "$SPARKLE_TOOLS_DIR"
    curl -fsSL "$SPARKLE_URL" -o "$SPARKLE_ARCHIVE"
    tar -xJf "$SPARKLE_ARCHIVE" -C "$SPARKLE_TOOLS_DIR"
    SIGN_UPDATE="$SPARKLE_TOOLS_DIR/bin/sign_update"
    if [ ! -x "$SIGN_UPDATE" ]; then
        echo "sign_update not found in Sparkle archive" >&2
        exit 1
    fi

    echo "==> Signing $ZIP_PATH with Sparkle EdDSA key"
    SPARKLE_KEY_FILE="$STAGE_DIR/sparkle_ed_private.key"
    umask 077
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_KEY_FILE"
    SIGN_OUTPUT="$("$SIGN_UPDATE" -f "$SPARKLE_KEY_FILE" "$ZIP_PATH")"
    rm -f "$SPARKLE_KEY_FILE"

    # sign_update emits e.g.:
    #   sparkle:edSignature="<base64>" length="<bytes>"
    ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
    ZIP_LENGTH="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
    if [ -z "$ED_SIGNATURE" ] || [ -z "$ZIP_LENGTH" ]; then
        echo "Failed to parse sign_update output: $SIGN_OUTPUT" >&2
        exit 1
    fi

    PUB_DATE="$(LC_ALL=C TZ=GMT date '+%a, %d %b %Y %H:%M:%S %z')"
    ZIP_URL="https://github.com/bones7456/notchy/releases/download/v${MARKETING_VERSION}/${BASENAME}.zip"
    MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$BUILT_APP/Contents/Info.plist" 2>/dev/null || echo "")"

    NOTES_HTML=""
    if [ -n "${SPARKLE_RELEASE_NOTES_FILE:-}" ] && [ -f "$SPARKLE_RELEASE_NOTES_FILE" ]; then
        NOTES_HTML="$(cat "$SPARKLE_RELEASE_NOTES_FILE")"
    fi

    echo "==> Writing $APPCAST_PATH"
    {
        printf '<?xml version="1.0" encoding="utf-8"?>\n'
        printf '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        printf '    <channel>\n'
        printf '        <title>Notchy</title>\n'
        printf '        <link>https://github.com/bones7456/notchy</link>\n'
        printf '        <item>\n'
        printf '            <title>Version %s</title>\n' "$MARKETING_VERSION"
        printf '            <sparkle:version>%s</sparkle:version>\n' "$BUILD_VERSION"
        printf '            <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$MARKETING_VERSION"
        if [ -n "$NOTES_HTML" ]; then
            printf '            <description><![CDATA[\n'
            printf '%s' "$NOTES_HTML"
            printf '\n]]></description>\n'
        fi
        printf '            <sparkle:fullReleaseNotesLink>https://github.com/bones7456/notchy/releases/tag/v%s</sparkle:fullReleaseNotesLink>\n' "$MARKETING_VERSION"
        printf '            <pubDate>%s</pubDate>\n' "$PUB_DATE"
        if [ -n "$MIN_OS" ]; then
            printf '            <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$MIN_OS"
        fi
        printf '            <enclosure url="%s" sparkle:edSignature="%s" length="%s" type="application/octet-stream" />\n' \
            "$ZIP_URL" "$ED_SIGNATURE" "$ZIP_LENGTH"
        printf '        </item>\n'
        printf '    </channel>\n'
        printf '</rss>\n'
    } > "$APPCAST_PATH"
else
    echo "SPARKLE_PRIVATE_KEY not set; skipping appcast.xml generation" >&2
fi

echo "==> Artifacts:"
echo "    $ZIP_PATH"
echo "    $DMG_PATH"
if [ -f "$APPCAST_PATH" ]; then
    echo "    $APPCAST_PATH"
fi
