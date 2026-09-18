#!/bin/bash
# Renders the icon at every size the iconset needs and packs icon/SlimBar.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/icon build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" icon/render-icon.swift -o build/icon/render
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/px" "$STAGE/SlimBar.iconset"
build/icon/render "$STAGE/px"
# Iconset slots are named in points; the file behind each one is its pixel size,
# so the @2x slots get the denser rendering rather than an upscale.
set -- 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
       128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
       512:icon_512x512 1024:icon_512x512@2x
for PAIR in "$@"; do
    cp "$STAGE/px/${PAIR%%:*}.png" "$STAGE/SlimBar.iconset/${PAIR##*:}.png"
done
iconutil -c icns "$STAGE/SlimBar.iconset" -o icon/SlimBar.icns
echo "icon/SlimBar.icns"
