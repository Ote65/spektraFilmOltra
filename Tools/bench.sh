#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/build/bench"
CORE="$ROOT/Sources/SpektraCore"

mkdir -p "$ROOT/build"

FILES=()
while IFS= read -r -d '' file; do
  FILES+=("$file")
done < <(find "$CORE" "$ROOT/Tools/Bench" -name '*.swift' -print0 | sort -z)

EXTRA_FLAGS=()
if [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] \
   && [ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]; then
  : > "$ROOT/build/empty.modulemap"
  cat > "$ROOT/build/vfs-overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$ROOT/build/empty.modulemap"}]}
JSON
  EXTRA_FLAGS=(-Xcc -ivfsoverlay -Xcc "$ROOT/build/vfs-overlay.json")
fi

swiftc \
  -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit -framework Accelerate -framework Metal \
  -framework ImageIO -framework CoreGraphics -framework CoreImage \
  -framework ColorSync -framework UniformTypeIdentifiers \
  "${EXTRA_FLAGS[@]}" \
  "${FILES[@]}" \
  -o "$BIN"

SPEKTRA_DATA_DIR="$CORE/Resources/Data" "$BIN"
