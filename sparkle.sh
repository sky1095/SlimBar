# Sourced by build.sh and the test harnesses so every build links one pinned
# Sparkle. Callers have already cd'd to the repository root.
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_DIR="$PWD/build/vendor/Sparkle-$SPARKLE_VERSION"
SPARKLE_ARCHIVE="$SPARKLE_DIR/release.tar.xz"
mkdir -p "$SPARKLE_DIR"
if ! printf '%s  %s\n' "$SPARKLE_SHA256" "$SPARKLE_ARCHIVE" | shasum -a 256 -c --status 2>/dev/null; then
    curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --retry 2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$SPARKLE_ARCHIVE"
    rm -rf "$SPARKLE_DIR/Sparkle.framework" "$SPARKLE_DIR/bin"
fi
printf '%s  %s\n' "$SPARKLE_SHA256" "$SPARKLE_ARCHIVE" | shasum -a 256 -c
[ -d "$SPARKLE_DIR/Sparkle.framework" ] || tar -xJf "$SPARKLE_ARCHIVE" -C "$SPARKLE_DIR"
[ -d "$SPARKLE_DIR/Sparkle.framework" ] || { echo 'Sparkle release is missing Sparkle.framework' >&2; exit 1; }
