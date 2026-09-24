#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
FINAL_APP="$PWD/build/SlimBar.app"
mkdir -p "$PWD/build"
STAGING="$(mktemp -d "$PWD/build/.SlimBar.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/SlimBar.app"
VERSION=0.9.0
SHA256=186afdeca453d3d1f0fca020b1e3f390338828d87b6b6d3fe338e9286cd2263e
AVDSLIM_VERSION=1.0.15
AVDSLIM_SHA256=82d80c65216a4f785965ad749cedfef6bf1e05be427274bbe8395849da796fc1
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$PWD/build/module-cache"
source ./sparkle.sh
if [ -n "${SIMSLIM_CLI:-}" ]; then
    CLI="$SIMSLIM_CLI"
    [ -x "$CLI" ] || { echo 'SIMSLIM_CLI must point to an executable' >&2; exit 1; }
else
    [ "$(uname -m)" = arm64 ] || { echo 'The bundled release supports Apple Silicon only.' >&2; exit 1; }
    CACHE="$PWD/build/vendor/simslim-$VERSION"
    mkdir -p "$CACHE"
    ARCHIVE="$CACHE/release.tar.gz"
    if ! printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c --status 2>/dev/null; then
        curl --fail --location --silent --show-error --connect-timeout 20 --max-time 180 --retry 2 \
            "https://github.com/MobAI-App/simslim/releases/download/v$VERSION/simslim-v$VERSION-macos-arm64.tar.gz" -o "$ARCHIVE"
    fi
    printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c
    tar -xzf "$ARCHIVE" -C "$CACHE"
    CLI="$CACHE/simslim"
    [ -x "$CLI" ] || { echo 'Downloaded release is missing the simslim executable' >&2; exit 1; }
fi
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx26.0 -module-cache-path "$PWD/build/module-cache" Sources/*.swift -o "$APP/Contents/MacOS/SlimBar" \
    -framework AppKit -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
cp Info.plist "$APP/Contents/Info.plist"
# The public half of the release signing key is what makes updating possible;
# without it the app keeps the update menu item disabled.
if [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi
cp "$CLI" "$APP/Contents/Resources/simslim"
# avdslim is the Android counterpart to simslim (service profiles for AVDs).
# It is optional at runtime: listing and booting use the Android SDK
# directly, while Apply Profile needs avdslim. Pin it the same way.
if [ -n "${AVDSLIM_CLI:-}" ]; then
    AVDSLIM="$AVDSLIM_CLI"
    [ -x "$AVDSLIM" ] || { echo 'AVDSLIM_CLI must point to an executable' >&2; exit 1; }
else
    [ "$(uname -m)" = arm64 ] || { echo 'The bundled Android release supports Apple Silicon only.' >&2; exit 1; }
    AVDSLIM_CACHE="$PWD/build/vendor/avdslim-$AVDSLIM_VERSION"
    mkdir -p "$AVDSLIM_CACHE"
    AVDSLIM_ARCHIVE="$AVDSLIM_CACHE/release.tar.gz"
    if ! printf '%s  %s\n' "$AVDSLIM_SHA256" "$AVDSLIM_ARCHIVE" | shasum -a 256 -c --status 2>/dev/null; then
        curl --fail --location --silent --show-error --connect-timeout 20 --max-time 180 --retry 2 \
            "https://github.com/kdbhalala/avdslim/releases/download/v$AVDSLIM_VERSION/avdslim_v${AVDSLIM_VERSION}_darwin_arm64.tar.gz" -o "$AVDSLIM_ARCHIVE"
    fi
    printf '%s  %s\n' "$AVDSLIM_SHA256" "$AVDSLIM_ARCHIVE" | shasum -a 256 -c
    tar -xzf "$AVDSLIM_ARCHIVE" -C "$AVDSLIM_CACHE"
    AVDSLIM="$(find "$AVDSLIM_CACHE" -name avdslim -type f -perm +111 | head -1)"
    [ -n "$AVDSLIM" ] && [ -x "$AVDSLIM" ] || { echo 'Downloaded release is missing the avdslim executable' >&2; exit 1; }
fi
cp "$AVDSLIM" "$APP/Contents/Resources/avdslim"
cp THIRD-PARTY-NOTICES.txt LICENSE icon/SlimBar.icns "$APP/Contents/Resources/"
# Developer ID signing adds the hardened runtime and secure timestamp that
# notarization requires. Without an identity the build stays ad-hoc signed and
# usable locally, but Gatekeeper will reject it if it is redistributed.
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    sign() { codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$1"; }
else
    sign() { codesign --force --sign - "$1"; }
fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
# The bundled backend counts as nested code: notarization rejects the whole
# app if simslim is not signed with the same identity as everything else.
for NESTED in "$APP/Contents/Resources/simslim" "$APP/Contents/Resources/avdslim" \
              "$FRAMEWORK/XPCServices/Downloader.xpc" "$FRAMEWORK/XPCServices/Installer.xpc" \
              "$FRAMEWORK/Updater.app" "$FRAMEWORK/Autoupdate" "$FRAMEWORK"; do
    sign "$NESTED"
done
sign "$APP"
rm -rf "$FINAL_APP"
mv "$APP" "$FINAL_APP"
echo "$FINAL_APP"
