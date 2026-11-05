#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Spektrafilm.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
NAME="Spektrafilm Oltra $VERSION"
OUT="$ROOT/build/SpektrafilmOltra-$VERSION-$ARCH.dmg"
RW="/tmp/spektrafilmolt-rw.dmg"
MOUNT="/Volumes/$NAME"
STAGE="$(mktemp -d /tmp/spektrafilmolt-stage.XXXXXX)"

cleanup() {
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  "$ROOT/build.sh"
fi

ditto "$APP" "$STAGE/Spektrafilm.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/Licenses & Source/Source" "$STAGE/.background"
cp -R "$ROOT/Resources/Licenses" "$STAGE/Licenses & Source/Licenses"
cp "$ROOT/Resources/Brand/dmg-background.png" "$STAGE/.background/background.png"
cp "$ROOT/Resources/Spektrafilm.icns" "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE/.VolumeIcon.icns"
test -f "$STAGE/.VolumeIcon.icns"
git -C "$ROOT" archive --format=tar.gz \
  --prefix="Spektrafilm-source-$VERSION/" HEAD \
  -o "$STAGE/Licenses & Source/Source/Spektrafilm-source-$VERSION.tar.gz"

rm -f "$RW" "$OUT"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
hdiutil attach "$RW" -nobrowse -readwrite >/dev/null
sleep 1


osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {120, 120, 840, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Spektrafilm.app" of container window to {180, 190}
    set position of item "Applications" of container window to {540, 190}
    set position of item "Licenses & Source" of container window to {360, 340}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

# Finder 在写入布局时会移除卷图标文件，布局后再补一次。
cp "$ROOT/Resources/Spektrafilm.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT/.VolumeIcon.icns"
test -f "$MOUNT/.VolumeIcon.icns"
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
echo "Built $OUT"
