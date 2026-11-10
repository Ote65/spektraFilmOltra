#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES="$ROOT/Sources/SpektraSkin"
RESOURCES="$SOURCES/Resources/SamplePhotos"
APP="$ROOT/build/SpektraFilm.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/SamplePhotos"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SpektraFilm</string>
    <key>CFBundleIdentifier</key>
    <string>com.spektrafilm.skin</string>
    <key>CFBundleName</key>
    <string>Spektrafilm</string>
    <key>CFBundleDisplayName</key>
    <string>Spektrafilm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

FILES=()
while IFS= read -r -d '' file; do
  FILES+=("$file")
done < <(find "$SOURCES" -name '*.swift' -print0 | sort -z)

EXTRA_FLAGS=()
# Command Line Tools 6.0.3 自带两份都定义 SwiftBridging 的 module map。
# 用 VFS 覆盖隐藏其中一份，不去改动系统工具链。
if [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] \
   && [ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]; then
  cat > "$ROOT/build/vfs-overlay.json" <<JSON
{
  "version": 0,
  "roots": [
    {
      "type": "file",
      "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap",
      "external-contents": "$ROOT/build/empty.modulemap"
    }
  ]
}
JSON
  : > "$ROOT/build/empty.modulemap"
  EXTRA_FLAGS=(-Xcc -ivfsoverlay -Xcc "$ROOT/build/vfs-overlay.json")
fi

swiftc \
  -parse-as-library \
  -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework SwiftUI \
  -framework AppKit \
  "${EXTRA_FLAGS[@]}" \
  "${FILES[@]}" \
  -o "$APP/Contents/MacOS/SpektraFilm"

cp "$RESOURCES"/*.jpg "$APP/Contents/Resources/SamplePhotos/"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
