#!/usr/bin/env bash
# 与 Python 参考实现的自动对拍。
#
#   Tools/parity.sh              # 6 个确定性用例 + 眩光统计 + 3 个仅观察项
#   Tools/parity.sh couplers     # 只跑指定用例（全部按确定性门禁判）
#
# 门禁（对齐 docs/parity_report.md）：
#   - 确定性模块：最大绝对偏差 ≤ 1e-5（float32 存储下的量化上限；
#     可用 SPEKTRA_PARITY_TOL 覆盖以做更严格的调查）
#   - 眩光统计（参考侧可复现）：均值相对偏差 ≤ 5%，标准差 ≤ 25%
#
# 未纳入门禁（跑出来只打印、不判失败）：
#   - jzazbz：Python 侧用的是 `colour.XYZ_to_Jzazbz(xyz * 100)`（0–100 亮度单位），
#     Swift 侧按自己的归一化尺度算，两边输入量程不同，差值量级 ~20，属**用例口径**不一致。
#   - resize：Swift 与 Python 的重采样核不同（非逐位等价实现），差值 2e-2，属**算法口径**差异。
#   - grain_stats：参考侧是 numba 并行 RNG，**每次运行结果都不同**（`docs/parity_report.md` 已注明），
#     128×128×5 档的均值抖动实测 1.3%–5.9%，无法作为硬门禁；只能人工看量级。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${SPEKTRA_PYTHON:-/Users/megmeet/Documents/开发 APP/Spektrafilm/.venv/bin/python}"
REFERENCE="$ROOT/Tools/parity/dump_reference.py"
CORE="$ROOT/Sources/SpektraCore"
BIN="$ROOT/build/paritycheck"
TMP="${SPEKTRA_PARITY_TMP:-/tmp/spektra-parity}"

if [ ! -x "$PY" ]; then
  echo "跳过：找不到 Python 参考环境（$PY）。可用 SPEKTRA_PYTHON 指定。"
  exit 0
fi

mkdir -p "$TMP" "$ROOT/build"

echo "== 构建 ParityCheck =="
FILES=()
while IFS= read -r -d '' file; do
  FILES+=("$file")
done < <(find "$CORE" "$ROOT/Tools/ParityCheck" -name '*.swift' -print0 | sort -z)

EXTRA_FLAGS=()
if [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] \
   && [ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]; then
  : > "$ROOT/build/empty.modulemap"
  cat > "$ROOT/build/vfs-overlay.json" <<JSON
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$ROOT/build/empty.modulemap"}]}
JSON
  EXTRA_FLAGS=(-Xcc -ivfsoverlay -Xcc "$ROOT/build/vfs-overlay.json")
fi

swiftc -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit -framework Accelerate -framework Metal \
  -framework ImageIO -framework CoreGraphics -framework CoreImage \
  -framework ColorSync -framework UniformTypeIdentifiers \
  "${EXTRA_FLAGS[@]}" "${FILES[@]}" -o "$BIN" 2>&1 | grep -E "error:" && exit 1

GATED=(couplers grain_layers diffusion_psf diffusion_apply halation cam16 output_compress)
STATISTICAL=(glare_stats)
INFORMATIONAL=(jzazbz resize grain_stats)
if [ "$#" -gt 0 ]; then
  CASES=("$@")
  GATED=("$@")
  STATISTICAL=()
  INFORMATIONAL=()
else
  CASES=("${GATED[@]}" "${STATISTICAL[@]}" "${INFORMATIONAL[@]}")
fi

FAILED=0
for case_name in "${CASES[@]}"; do
  informational=0
  for candidate in "${INFORMATIONAL[@]:-}"; do
    [ "$candidate" = "$case_name" ] && informational=1
  done
  swift_out="$TMP/swift-$case_name.json"
  py_out="$TMP/py-$case_name.json"
  CASE="$case_name" OUT="$swift_out" SPEKTRA_DATA_DIR="$CORE/Resources/Data" "$BIN" 2>/dev/null || {
    echo "  ✗ $case_name：Swift 侧运行失败"; FAILED=1; continue; }
  CASE="$case_name" OUT="$py_out" "$PY" "$REFERENCE" 2>/dev/null || {
    echo "  ✗ $case_name：Python 侧运行失败"; FAILED=1; continue; }

  verdict=$("$PY" - "$swift_out" "$py_out" "$case_name" "$informational" <<'PY'
import json, math, sys

def flatten(node, path=""):
    out = {}
    if isinstance(node, dict):
        for k, v in node.items():
            out.update(flatten(v, f"{path}.{k}"))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            out.update(flatten(v, f"{path}[{i}]"))
    elif isinstance(node, (int, float)) and not isinstance(node, bool):
        out[path] = float(node)
    return out

a = flatten(json.load(open(sys.argv[1])))
b = flatten(json.load(open(sys.argv[2])))
name = sys.argv[3]
informational = sys.argv[4] == "1"
if set(a) != set(b):
    print(f"  {'·' if informational else '✗'} {name}：结构不一致（{len(a)} vs {len(b)} 个数值）")
    sys.exit(0 if informational else 1)

statistical = name in ("grain_stats", "glare_stats")
if statistical:
    worst_mean, worst_std = 0.0, 0.0
    for k in a:
        x, y = a[k], b[k]
        if "mean" in k and abs(y) > 1e-12:
            worst_mean = max(worst_mean, abs(x - y) / abs(y))
        if "std" in k and abs(y) > 1e-12:
            worst_std = max(worst_std, abs(x - y) / abs(y))
    ok = worst_mean <= 0.05 and worst_std <= 0.25
    mark = "✓" if ok else ("·" if informational else "✗")
    note = "｜仅观察，不作门禁" if informational else "（门禁 5% / 25%）"
    print(f"  {mark} {name}：均值偏差 {worst_mean:.2%}，标准差偏差 {worst_std:.2%}{note}")
    sys.exit(0 if ok or informational else 1)

worst = 0.0
for k in a:
    x, y = a[k], b[k]
    if math.isnan(x) and math.isnan(y):
        continue
    worst = max(worst, abs(x - y))
# 存储用 float32（12 字节/像素，内存减半）：单次量化误差 ~6e-8 相对量级，
# 因此确定性门禁从 1e-9 放到 1e-5——仍能抓住任何真实的算法回归
# （口径错误、插值方向反、矩阵写错都是 1e-3 以上）。算术本身仍是 float64。
tol = float(__import__("os").environ.get("SPEKTRA_PARITY_TOL", "1e-5"))
ok = worst <= tol
print(f"  {'✓' if ok else ('·' if informational else '✗')} {name}："
      f"最大绝对偏差 {worst:.2e}（门禁 {tol:.0e}）{'｜未纳入门禁' if informational and not ok else ''}")
sys.exit(0 if ok or informational else 1)
PY
) || FAILED=1
  echo "$verdict"
done

if [ "$FAILED" -ne 0 ]; then
  echo "对拍失败：见上方 ✗ 项。中间文件在 $TMP"
  exit 1
fi
echo "对拍通过：${#CASES[@]} 个用例。中间文件在 $TMP"
