#!/bin/bash
# Builds, notarizes, and staples the release artifacts plus the appcast that
# SlimBar's updater reads. The zip is what Sparkle installs; the DMG is the
# first-time download. See CONTRIBUTING.md for the one-time key setup.
set -euo pipefail
cd "$(dirname "$0")"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity (security find-identity -v -p codesigning)}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a profile stored with: xcrun notarytool store-credentials}"
# Release-only secrets live in .env.release (gitignored), or in the environment.
if [ -f .env.release ]; then set -a; source ./.env.release; set +a; fi
: "${POSTHOG_API_KEY:?Set POSTHOG_API_KEY (the PostHog project token, phc_...) in .env.release or the environment}"
export POSTHOG_API_KEY POSTHOG_HOST
export SIGNING_IDENTITY
source ./sparkle.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
FEED="$PWD/build/release"
DMG_DIR="$PWD/build/dmg"
ZIP="$FEED/SlimBar-v$VERSION-macos-arm64.zip"
DMG="$DMG_DIR/SlimBar-v$VERSION-macos-arm64.dmg"

./build.sh > /dev/null
# An archive nobody can verify must never reach the feed.
if [ -z "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/SlimBar.app/Contents/Info.plist)" ]; then
    echo 'SUPublicEDKey is empty: set it in Info.plist or export SPARKLE_PUBLIC_KEY.' >&2
    exit 1
fi
# A release must ship with analytics wired up, or its data silently goes missing.
[ "$(/usr/libexec/PlistBuddy -c 'Print :PostHogAPIKey' build/SlimBar.app/Contents/Info.plist 2>/dev/null)" = "$POSTHOG_API_KEY" ] || {
    echo 'PostHogAPIKey did not reach the built Info.plist.' >&2
    exit 1
}
mkdir -p "$FEED" "$DMG_DIR"

# Apple rejects the whole archive over one badly signed nested binary, and only
# says so minutes later. Catch it here instead of on a round trip.
preflight() {
    local BAD=0 FILE INFO
    while IFS= read -r FILE; do
        INFO="$(codesign -dv "$FILE" 2>&1)" || continue
        printf '%s' "$INFO" | grep -q '^TeamIdentifier=[A-Z0-9]' || { echo "not Developer ID signed: $FILE" >&2; BAD=1; }
        printf '%s' "$INFO" | grep -q 'flags=.*runtime' || { echo "no hardened runtime: $FILE" >&2; BAD=1; }
        printf '%s' "$INFO" | grep -q '^Timestamp=' || { echo "no secure timestamp: $FILE" >&2; BAD=1; }
    done < <(find "$1" -type f -perm -111)
    [ "$BAD" -eq 0 ] || { echo 'Apple would reject this archive; fix signing in build.sh first.' >&2; exit 1; }
}

# notarytool exits 0 even when the result is Invalid, so the status has to be
# read back explicitly or the stapler fails later with an unreadable error.
notarize() {
    local RESULT ID STATUS
    RESULT="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    ID="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    STATUS="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
    echo "notarization: $STATUS for $(basename "$1")"
    if [ "$STATUS" != "Accepted" ]; then
        echo "--- notarization log for $ID ---" >&2
        xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
    fi
}

preflight build/SlimBar.app

# Notarize the app first and staple the ticket into the bundle, so both the
# archive Sparkle installs and the DMG clear Gatekeeper with no network call.
rm -f "$ZIP"
ditto -c -k --keepParent build/SlimBar.app "$ZIP"
notarize "$ZIP"
xcrun stapler staple build/SlimBar.app
rm -f "$ZIP"
ditto -c -k --keepParent build/SlimBar.app "$ZIP"

# The DMG is built outside the feed directory on purpose: generate_appcast
# refuses a zip and a DMG of the same version in one folder.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/SlimBar.app "$STAGE/SlimBar.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname SlimBar -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# Refuse to publish anything Gatekeeper would reject on someone else's Mac.
spctl -a -vv -t exec build/SlimBar.app
spctl -a -vv -t open --context context:primary-signature "$DMG"

# Older zips stay put on purpose: generate_appcast signs every version it finds,
# so the published feed keeps its release history.
"$SPARKLE_DIR/bin/generate_appcast" \
    --download-url-prefix "https://github.com/sky1095/SlimBar/releases/download/v$VERSION/" "$FEED"
{ (cd "$FEED" && shasum -a 256 SlimBar-*.zip); (cd "$DMG_DIR" && shasum -a 256 SlimBar-*.dmg); } > "$FEED/SHA256SUMS.txt"

echo "Upload to the v$VERSION release:"
for FILE in "$DMG" "$ZIP" "$FEED/appcast.xml" "$FEED/SHA256SUMS.txt"; do echo "  $FILE"; done
