#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/icloud-cross-device-smoke"
CONDITIONS="DEBUG ICLOUD_CROSS_DEVICE_SMOKE"
TEST_CLASS="BIT101-iOSTests/ICloudCrossDeviceSmokeTests"

if [[ $# -eq 0 ]]; then
  source "$ROOT_DIR/Scripts/device-support.sh"
  bit101_require_device "$PROJECT" || exit 1
  DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
else
  if [[ $# -gt 2 ]]; then
    echo "用法: $0 [真机设备ID]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
fi

mkdir -p "$DERIVED_ROOT"

run_with_output_threshold() {
  local output_path="$1"
  local label="$2"
  shift 2

  python3 - "$output_path" "$label" "$@" <<'PY'
from pathlib import Path
import subprocess
import sys

report_path = Path(sys.argv[1])
label = sys.argv[2]
command = sys.argv[3:]
report_path.unlink(missing_ok=True)
process = subprocess.Popen(
    command,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
)
buffered = []
report = None
for line in process.stdout:
    if report is None:
        buffered.append(line)
        if len(buffered) <= 1000:
            sys.stdout.write(line)
            sys.stdout.flush()
            continue
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report = report_path.open("w", encoding="utf-8")
        report.writelines(buffered)
        buffered.clear()
    else:
        report.write(line)

if report is not None:
    report.close()
    print(f"[输出] {label} 超过 1000 行，详情写入 {report_path}")

raise SystemExit(process.wait())
PY
}

common_args=(
  -quiet
  -project "$PROJECT"
  -scheme BIT101-iOS
  -configuration Release
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$CONDITIONS"
  ENABLE_TESTABILITY=YES
  -collect-test-diagnostics never
)

run_phone_test() {
  local method="$1"
  local log="$DERIVED_ROOT/$method.log"
  if run_with_output_threshold "$log" "$method 真机测试输出" xcodebuild test "${common_args[@]}" \
      -destination "platform=iOS,id=$DEVICE_ID" \
      -derivedDataPath "$DERIVED_ROOT/Phone" \
      "-only-testing:$TEST_CLASS/$method"; then
    return 0
  else
    return $?
  fi
}

cleanup() {
  echo "尝试恢复真机设置并清理 Smoke 协调数据……" >&2
  run_phone_test testCleanup || true
}
trap cleanup EXIT INT TERM

echo "[1/3] 真机上传设置与成绩缓存"
run_phone_test testPhoneUpload

echo "[2/3] Mac Catalyst 接收手机数据并写回原设置"
MAC_LOG="$DERIVED_ROOT/mac-receive.log"
if run_with_output_threshold "$MAC_LOG" "Mac Catalyst 接收测试输出" xcodebuild test "${common_args[@]}" \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED_ROOT/Mac" \
    ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
    "-only-testing:$TEST_CLASS/testMacReceiveAndRestore"; then
  MAC_STATUS=0
else
  MAC_STATUS=$?
fi
if (( MAC_STATUS != 0 )); then
  exit 1
fi

echo "[3/3] 真机接收 Mac 写回并清理"
run_phone_test testPhoneVerifyAndCleanup

trap - EXIT INT TERM
echo "iCloud 双向 Smoke 测试通过。"
