#!/bin/bash
set -euo pipefail

# Builds dist/RecBar.dmg: a drag-to-Applications disk image with a custom
# background, window size, and icon layout.
#
# Normal builds use the committed Resources/DMG.DS_Store and never talk to
# Finder. Regenerate that file only when the layout or background changes:
#
#   defaults write com.apple.finder AppleShowAllFiles -bool true
#   killall Finder
#   ./scripts/make_dmg.sh --restyle
#   defaults write com.apple.finder AppleShowAllFiles -bool false
#   killall Finder
#
# --restyle needs hidden files visible because Finder must be able to position
# .background and .VolumeIcon.icns off-screen; without that, they show up in the
# top-left corner for anyone who has "Show hidden files" enabled.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/RecBar.app"
DMG="$ROOT/dist/RecBar.dmg"
INFO="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
VOLUME="RecBar"
DS_STORE="$ROOT/Resources/DMG.DS_Store"
MOUNT="/Volumes/$VOLUME"

RESTYLE=0
if [[ "${1:-}" == "--restyle" ]]; then
    RESTYLE=1
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--restyle]" >&2
    exit 2
fi

TMP="$(mktemp -d)"
STAGING="$TMP/staging"
RW="$TMP/RecBar-rw.dmg"

cleanup() {
    if mount | grep -q " on $MOUNT "; then
        hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
}

if [[ -d "$MOUNT" ]] && mount | grep -q " on $MOUNT "; then
    echo "ERROR: $MOUNT is already mounted. Eject it and retry." >&2
    exit 1
fi
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
    "$ROOT/scripts/build_app.sh"
fi

echo "Verifying app signature..."
codesign --verify --deep --strict "$APP"

echo "Staging RecBar $VERSION..."
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/RecBar.app"
ln -s /Applications "$STAGING/Applications"

# Finder's "update without registering applications" deletes .VolumeIcon.icns,
# so a placeholder is present for styling and the real copy is restored after.
cp "$ROOT/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

xcrun swiftc -O -target arm64-apple-macos15.0 \
    -o "$TMP/make_dmg_background" "$ROOT/scripts/make_dmg_background.swift"
"$TMP/make_dmg_background" "$STAGING/.background/background.png" "$VERSION"

echo "Creating writable disk image..."
# COPYFILE_DISABLE would keep hdiutil from preserving the dotfiles that make up
# the custom layout, so clear it for this one command.
(unset COPYFILE_DISABLE; hdiutil create \
    -volname "$VOLUME" \
    -srcfolder "$STAGING" \
    -ov -format UDRW -fs HFS+ \
    "$RW" >/dev/null)

hdiutil attach "$RW" -readwrite -noverify -nobrowse -noautoopen >/dev/null

if [[ ! -d "$MOUNT" ]]; then
    echo "ERROR: expected the image at $MOUNT, but it mounted elsewhere." >&2
    mount | grep RecBar >&2 || true
    exit 1
fi

if [[ "$RESTYLE" == "1" ]]; then
    if [[ "$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null || echo 0)" != "1" ]]; then
        echo "ERROR: --restyle needs hidden files visible:" >&2
        echo "  defaults write com.apple.finder AppleShowAllFiles -bool true" >&2
        echo "  killall Finder" >&2
        exit 1
    fi

    # Finder can take a moment to register a freshly mounted volume; without
    # this wait the layout AppleScript fails with "Can't get disk".
    for _ in {1..20}; do
        if osascript -e "tell application \"Finder\" to exists disk \"$VOLUME\"" 2>/dev/null | grep -q true; then
            break
        fi
        sleep 0.25
    done
    sleep 0.5

    echo "Applying Finder layout (this restarts nothing; hidden files are already on)..."
    osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {120, 120, 780, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "RecBar.app" of container window to {165, 200}
        set position of item "Applications" of container window to {495, 200}
        set position of item ".background" of container window to {10, 700}
        set position of item ".VolumeIcon.icns" of container window to {150, 700}
        update without registering applications
        delay 3
        close
    end tell
end tell
EOF

    sleep 2
    if ! LC_ALL=C grep -q "backgroundImageAlias" "$MOUNT/.DS_Store"; then
        echo "ERROR: Finder recorded no background image; refusing to bake a blank layout." >&2
        exit 1
    fi

    cp "$MOUNT/.DS_Store" "$DS_STORE"
    echo "Saved styled .DS_Store to Resources/DMG.DS_Store"

    # Finder rewrites .DS_Store as the volume is detached, dropping the
    # background alias. Detach once, re-mount without opening Finder, and
    # apply the saved copy; this is the same path normal builds use.
    sync
    hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
    hdiutil attach "$RW" -readwrite -noverify -nobrowse -noautoopen >/dev/null
    if [[ ! -d "$MOUNT" ]]; then
        echo "ERROR: expected the image at $MOUNT after re-mount." >&2
        exit 1
    fi
    cp "$DS_STORE" "$MOUNT/.DS_Store"
    echo "Re-applied baked Finder layout after Finder's detach flush."
else
    if [[ ! -f "$DS_STORE" ]]; then
        echo "ERROR: Resources/DMG.DS_Store is missing. Run '$0 --restyle' on a GUI Mac." >&2
        exit 1
    fi
    if ! LC_ALL=C grep -q "backgroundImageAlias" "$DS_STORE"; then
        echo "ERROR: Resources/DMG.DS_Store has no background reference. Re-run '$0 --restyle'." >&2
        exit 1
    fi
    cp "$DS_STORE" "$MOUNT/.DS_Store"
    echo "Applied baked Finder layout."
fi

# Restore the volume icon that Finder removed during styling, and mark the
# volume as having a custom icon.
cp "$ROOT/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true

# macOS noise that has no place in the shipped image (and bloats compression).
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"

sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet

echo "Compressing disk image..."
rm -f "$DMG" "$DMG.sha256"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
(cd "$ROOT/dist" && shasum -a 256 "RecBar.dmg" > "RecBar.dmg.sha256")

echo "Verifying shipped DMG..."
hdiutil attach "$DMG" -readonly -noverify -nobrowse -noautoopen >/dev/null
VERIFY_FAILED=0

if [[ ! -f "$MOUNT/.DS_Store" ]]; then
    echo "ERROR: .DS_Store missing from shipped DMG." >&2
    VERIFY_FAILED=1
else
    for key in bwsp icvp Iloc backgroundImageAlias; do
        if ! LC_ALL=C grep -q "$key" "$MOUNT/.DS_Store"; then
            echo "ERROR: .DS_Store is missing $key." >&2
            VERIFY_FAILED=1
        fi
    done
fi

if [[ ! -f "$MOUNT/.background/background.png" ]]; then
    echo "ERROR: .background/background.png missing from shipped DMG." >&2
    VERIFY_FAILED=1
fi
if [[ ! -f "$MOUNT/.VolumeIcon.icns" ]]; then
    echo "ERROR: .VolumeIcon.icns missing from shipped DMG." >&2
    VERIFY_FAILED=1
fi
if [[ -e "$MOUNT/.fseventsd" ]]; then
    echo "ERROR: .fseventsd present in shipped DMG." >&2
    VERIFY_FAILED=1
fi
if ! codesign --verify --deep --strict "$MOUNT/RecBar.app" 2>/dev/null; then
    echo "ERROR: RecBar.app inside the DMG failed signature verification." >&2
    VERIFY_FAILED=1
fi

hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet

if [[ "$VERIFY_FAILED" == "1" ]]; then
    echo "ERROR: DMG verification failed." >&2
    exit 1
fi

echo "Built: $DMG"
echo "SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"
echo "Designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
