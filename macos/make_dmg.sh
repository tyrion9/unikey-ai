#!/bin/bash
# Package UnikeyAI.app into a distributable UnikeyAI.dmg - the standard
# macOS "drag the app into Applications" installer. Run ./build.sh first;
# this script only packages the already-built .app.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/UnikeyAI.app"
BUILD="$HERE/build"
STAGE="$BUILD/dmg-stage"
VOLNAME="UnikeyAI"
DMG_RW="$BUILD/${VOLNAME}-rw.dmg"
DMG_FINAL="$HERE/${VOLNAME}.dmg"

if [ ! -d "$APP" ]; then
  echo "UnikeyAI.app not found - run ./build.sh first" >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG_RW" "$DMG_FINAL"
mkdir -p "$STAGE"

echo "STAGE copy app + Applications shortcut"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
fi

SIZE_KB=$(du -sk "$STAGE" | cut -f1)
SIZE_MB=$(( (SIZE_KB / 1024) + 10 ))

echo "DMG create (~${SIZE_MB}MB read-write staging image)"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -fs HFS+ \
  -format UDRW -size "${SIZE_MB}m" "$DMG_RW" -quiet

MOUNT_DIR=$(mktemp -d /tmp/unikeyai-dmg-mount.XXXXXX)
hdiutil attach "$DMG_RW" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

# Give the mounted volume the app's icon, best-effort (needs Xcode's SetFile).
if [ -f "$MOUNT_DIR/.VolumeIcon.icns" ] && command -v SetFile > /dev/null 2>&1; then
  SetFile -a C "$MOUNT_DIR" || true
fi

sync
hdiutil detach "$MOUNT_DIR" -quiet
rmdir "$MOUNT_DIR" 2> /dev/null || true

echo "DMG compress to final read-only image"
hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_FINAL" -quiet
rm -f "$DMG_RW"

echo
echo "Built: $DMG_FINAL ($(du -h "$DMG_FINAL" | cut -f1))"
echo "Open it:  open '$DMG_FINAL'"
echo
echo "Note: this .dmg is signed with the same local dev certificate as the"
echo "app (not an Apple Developer ID), so on ANY other Mac Gatekeeper will"
echo "still say it's from an unidentified developer - right-click the app"
echo "in Applications and choose Open once to get past that."
