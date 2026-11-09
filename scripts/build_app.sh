#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building RecBar (release)..."
swift build -c release --product RecBar

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/RecBar"
APP="$ROOT/dist/RecBar.app"

if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RecBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT"/Resources/MenuBar/*.svg "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signing is enough for local use, but the designated requirement must be
# stable: macOS TCC keys Screen Recording grants to the code requirement, and the
# default ad-hoc requirement is the cdhash, which changes on every rebuild. Pinning
# the requirement to the bundle identifier keeps the grant across rebuilds.
codesign --force --deep --sign - \
    --identifier app.recbar.recorder \
    --requirements '=designated => identifier "app.recbar.recorder"' \
    "$APP" >/dev/null

echo "Built: $APP"
echo "Designated requirement:"
codesign -d -r- "$APP" 2>&1 | tail -1
