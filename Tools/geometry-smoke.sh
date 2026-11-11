#!/usr/bin/env bash
# 裁切几何回归 smoke：MPhotoGeometry 的映射正确性 / 取消 / 单帧成本上界。
# 用法：Tools/geometry-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/build/geometrysmoke"
mkdir -p "$ROOT/build"

swiftc -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework CoreGraphics -framework CoreImage -framework Metal \
  "$ROOT/Sources/SpektraCore/Core/Basic.swift" \
  "$ROOT/Sources/SpektraCore/Core/Image.swift" \
  "$ROOT/SpektraMobile/Sources/Engine/MPhotoGeometry.swift" \
  "$ROOT/Tools/GeometrySmoke/main.swift" \
  -o "$BIN"

"$BIN"
