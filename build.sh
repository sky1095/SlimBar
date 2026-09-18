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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/build/module-cache"
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
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx26.0 -module-cache-path "$PWD/build/module-cache" Sources/*.swift -o "$APP/Contents/MacOS/SlimBar" -framework AppKit
cp Info.plist "$APP/Contents/Info.plist"
cp "$CLI" "$APP/Contents/Resources/simslim"
cp THIRD-PARTY-NOTICES.txt LICENSE "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
rm -rf "$FINAL_APP"
mv "$APP" "$FINAL_APP"
echo "$FINAL_APP"
