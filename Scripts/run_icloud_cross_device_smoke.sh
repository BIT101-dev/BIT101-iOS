#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="${TMPDIR:-/tmp}/BIT101ICloudCrossDeviceSmoke"
CONDITIONS="DEBUG ICLOUD_CROSS_DEVICE_SMOKE"
TEST_CLASS="BIT101-iOSTests/ICloudCrossDeviceSmokeTests"

if [[ $# -eq 0 ]]; then
  source "$ROOT_DIR/Scripts/device-support.sh"
  bit101_require_device "$PROJECT" || exit 1
  DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
else
  if [[ $# -gt 2 ]]; then
    echo "用法: $0 [真机设备ID] [Developer目录]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
  export DEVELOPER_DIR="${2:-${DEVELOPER_DIR:-/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer}}"
fi

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
  local log="$DERIVED_ROOT/phone-$method.log"
  if ! xcodebuild test "${common_args[@]}" \
      -destination "platform=iOS,id=$DEVICE_ID" \
      -derivedDataPath "$DERIVED_ROOT/Phone" \
      "-only-testing:$TEST_CLASS/$method" > "$log" 2>&1
  then
    tail -n 80 "$log" >&2
    return 1
  fi
}

cleanup() {
  echo "尝试恢复真机设置并清理 Smoke 协调数据……" >&2
  run_phone_test testCleanup >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "[1/3] 真机上传设置与成绩缓存"
run_phone_test testPhoneUpload

echo "[2/3] Mac Catalyst 接收手机数据并写回原设置"
MAC_LOG="$DERIVED_ROOT/mac-testMacReceiveAndRestore.log"
if ! xcodebuild test "${common_args[@]}" \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED_ROOT/Mac" \
    ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
    "-only-testing:$TEST_CLASS/testMacReceiveAndRestore" > "$MAC_LOG" 2>&1
then
  tail -n 80 "$MAC_LOG" >&2
  exit 1
fi

echo "[3/3] 真机接收 Mac 写回并清理"
run_phone_test testPhoneVerifyAndCleanup

trap - EXIT INT TERM
echo "iCloud 双向 Smoke 测试通过。"
