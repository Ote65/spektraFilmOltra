#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Spektrafilm.app"
CORE="$ROOT/Sources/SpektraCore"
UI="$ROOT/SpektraSkin/Sources/SpektraSkin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Data"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Spektrafilm</string>
    <key>CFBundleIdentifier</key><string>com.spektrafilm.swift</string>
    <key>CFBundleName</key><string>Spektrafilm</string>
    <key>CFBundleDisplayName</key><string>Spektrafilm</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>0.3.4</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

FILES=()
while IFS= read -r -d '' file; do
  FILES+=("$file")
done < <(find "$CORE" "$UI" -name '*.swift' -print0 | sort -z)

EXTRA_FLAGS=()
if [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] \
   && [ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]; then
  mkdir -p "$ROOT/build"
  : > "$ROOT/build/empty.modulemap"
  cat > "$ROOT/build/vfs-overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$ROOT/build/empty.modulemap"}]}
JSON
  EXTRA_FLAGS=(-Xcc -ivfsoverlay -Xcc "$ROOT/build/vfs-overlay.json")
fi

swiftc \
  -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework SwiftUI -framework AppKit \
  -framework Accelerate -framework Metal \
  -framework ImageIO -framework CoreGraphics -framework CoreImage \
  -framework ColorSync -framework UniformTypeIdentifiers \
  "${EXTRA_FLAGS[@]}" \
  "${FILES[@]}" \
  -o "$APP/Contents/MacOS/Spektrafilm"

rsync -a "$CORE/Resources/Data/" "$APP/Contents/Resources/Data/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
