#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/RecBar.app"
DEST="/Applications/RecBar.app"

if [[ ! -d "$APP" ]]; then
    "$ROOT/scripts/build_app.sh"
fi

if [[ ! -d "$APP" ]]; then
    echo "error: $APP was not built" >&2
    exit 1
fi

echo "Installing to $DEST..."
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Installed. Launching..."
open "$DEST"
