#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/IconSources"
OUT="$ROOT/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The app icon uses the corrected master logo, not the older pack artwork.
if [[ ! -f "$SRC/RecBar Logo.svg" ]]; then
    echo "error: missing $SRC/RecBar Logo.svg" >&2
    exit 1
fi

xcrun swiftc -O -target arm64-apple-macos15.0 -o "$TMP/render_svg" "$ROOT/scripts/render_svg.swift"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

render() {
    "$TMP/render_svg" "$SRC/RecBar Logo.svg" "$ICONSET/$1" "$2"
}

render icon_16x16.png 16
render icon_16x16@2x.png 32
render icon_32x32.png 32
render icon_32x32@2x.png 64
render icon_128x128.png 128
render icon_128x128@2x.png 256
render icon_256x256.png 256
render icon_256x256@2x.png 512
render icon_512x512.png 512
render icon_512x512@2x.png 1024

iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"

mkdir -p "$OUT/MenuBar"
rm -f "$OUT/MenuBar"/*.png
for state in idle recording paused saving saved exporting error; do
    cp "$SRC/menubar_${state}.svg" "$OUT/MenuBar/menubar-${state}.svg"
done

echo "Built $OUT/AppIcon.icns and vector menu-bar icons in $OUT/MenuBar"
