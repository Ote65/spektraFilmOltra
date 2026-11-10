#!/usr/bin/env bash
# Spektrafilm iOS 验收脚本：Release 构建 → 安装 → 播种 RAW → 多页面截图 → 日志扫描。
# 用法：Tools/acceptance.sh ["iPhone 18 Pro Max"]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE="${1:-iPhone 18 Pro}"
BUNDLE="com.spektrafilm.mobile"
OUT="${SPEKTRA_SHOT_DIR:-$ROOT/.screenshots/acceptance}"
SEED="${SPEKTRA_SEED_IMAGE:-$ROOT/build/test-IMG_6459.DNG}"

mkdir -p "$OUT"

echo "== 1/5 Release 构建 ($DEVICE) =="
xcodebuild -project "$ROOT/SpektraMobileApp/SpektraMobile.xcodeproj" \
  -scheme SpektraMobile \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedDataRelease" \
  build 2>&1 | grep -E "error:|BUILD" || true

APP="$ROOT/build/DerivedDataRelease/Build/Products/Release-iphonesimulator/SpektraMobile.app"
[ -d "$APP" ] || { echo "构建产物缺失"; exit 1; }

echo "== 2/5 启动模拟器 =="
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true

echo "== 3/5 安装 + 播种 =="
# 重启 SpringBoard 清掉上一次运行残留的系统弹窗（权限框等会一直挂在屏幕上挡截图）。
xcrun simctl spawn "$DEVICE" launchctl stop com.apple.SpringBoard 2>/dev/null || true
sleep 6
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
# 重装会重置权限；相册权限弹窗会挡住后面的截图，装完立刻预授权。
xcrun simctl privacy "$DEVICE" grant photos "$BUNDLE" 2>/dev/null || true
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
mkdir -p "$CONTAINER/Documents"
# 清空照片库，保证截图可复现（否则每次验收都会多一份导入）。
rm -rf "$CONTAINER/Library/Application Support/Spektrafilm/MobileLibrary"
if [ -f "$SEED" ]; then
  cp "$SEED" "$CONTAINER/Documents/seed.DNG"
  echo "已播种 $(basename "$SEED")"
else
  echo "警告：未找到测试 RAW（$SEED），跳过播种"
fi

echo "== 4/5 截图 =="
# 冷启动预热：新装后的第一次启动要解码 RAW + 建库，比后续启动慢得多，
# 不预热的话第一张截图很容易截到空白。
if [ -f "$CONTAINER/Documents/seed.DNG" ]; then
  xcrun simctl launch "$DEVICE" "$BUNDLE" \
    --import "$CONTAINER/Documents/seed.DNG" --screen home >/dev/null
else
  xcrun simctl launch "$DEVICE" "$BUNDLE" --screen home >/dev/null
fi
sleep 14
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true

shot() {
  local screen="$1"
  local name="$2"
  local delay="${3:-12}"
  shift 3
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  if [ -f "$CONTAINER/Documents/seed.DNG" ]; then
    xcrun simctl launch "$DEVICE" "$BUNDLE" \
      --import "$CONTAINER/Documents/seed.DNG" --screen "$screen" "$@" >/dev/null
  else
    xcrun simctl launch "$DEVICE" "$BUNDLE" --screen "$screen" "$@" >/dev/null
  fi
  sleep "$delay"
  # 小屏/慢机型首帧可能还没画出来，截到的是纯色窗口。用 PNG 体积做粗判：
  # 空白截图约 60 KB，真实界面（含照片/文字）都在 150 KB 以上；最多再等 16 s。
  local out="$OUT/$name.png" tmp="$OUT/.tmp-$name.png"
  local attempt=0
  while [ "$attempt" -lt 8 ]; do
    xcrun simctl io "$DEVICE" screenshot "$tmp" >/dev/null 2>&1
    local size
    size=$(stat -f%z "$tmp" 2>/dev/null || echo 0)
    if [ "$size" -ge 100000 ]; then
      mv "$tmp" "$out"
      echo "  $out"
      return
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  mv "$tmp" "$out" 2>/dev/null || true
  echo "  $out  [空白：等待超时]"
}
shot home home 12
shot develop develop 12
# 调色台要先等显影交接图（1600 全管线）与代理帧。小屏/慢机型（SE）实测需要 ~25 s，
# 交接未完成时预览是白布占位（体积够大，空白检测不会重试），所以起始等待给足。
shot grade grade 24
# 调整面板下半段（质感：浓度 / 暗角 / 颗粒），默认从底部起滚。
shot grade grade-quality 24 --grade-bottom
shot develop export-sheet 18 --export
shot develop develop-quick 12 --quick color_density=100,grain_amount=100,tonal_contrast=60
# 导出进行中（进度行）：原片读完后面板自动开跑。快机型 5 s 能截到进度态；
# 小屏/慢机型可能已经跑完，所以另加一张 18 s 的完成态，避免「只有黑屏」。
# 默认导出已是原图全分辨率（12 MP 约 15–20 s），进度态与完成态都要放宽等待。
shot develop export-progress 8 --export --export-run
shot develop export-complete 30 --export --export-run
# 刘海分支现在按真实安全区自动判定（iPhone 13 档位即可复现）；
# 这一张用 `--housing notch` 强制走一遍，作为回归用例。
shot develop develop-notch 14 --housing notch

echo "== 5/5 日志扫描 =="
LOGS=$(xcrun simctl spawn "$DEVICE" log show --last 3m \
  --predicate "process == \"SpectraMobile\"" --style compact 2>/dev/null || true)
CYCLE=$(echo "$LOGS" | grep -c "Cycle detected" || true)
FATAL=$(echo "$LOGS" | grep -c "fatalError" || true)
MISSING=$(echo "$LOGS" | grep -c "can't open" || true)
echo "Cycle detected: $CYCLE"
echo "fatalError:     $FATAL"
echo "文件缺失:       $MISSING"

if [ "${SPEKTRA_PERF:-0}" = "1" ] && [ -f "$SEED" ]; then
  echo "== 性能门禁（Release，macOS 基线）=="
  SPEKTRA_BENCH_IMAGE="$SEED" SPEKTRA_BENCH_SIZES=1280 SPEKTRA_BENCH_ROUNDS=1 \
    SPEKTRA_BENCH_NO_STOCHASTIC=1 "$ROOT/Tools/bench.sh" 2>/dev/null \
    | grep -E "长边|预测|敏感度" || true
fi

if [ "${SPEKTRA_PARITY:-0}" = "1" ]; then
  echo "== 附加：Python 参考对拍 =="
  "$ROOT/Tools/parity.sh" || FAILED=1
fi

if [ "$CYCLE" -ne 0 ] || [ "$FATAL" -ne 0 ] || [ "$MISSING" -ne 0 ] || [ "${FAILED:-0}" -ne 0 ]; then
  echo "验收失败：日志或对拍门禁未通过"
  exit 1
fi

echo "验收完成：截图在 $OUT"
