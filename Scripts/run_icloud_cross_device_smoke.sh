#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/icloud-cross-device-smoke"
CONDITIONS="DEBUG ICLOUD_CROSS_DEVICE_SMOKE"
TEST_CLASS="BIT101-iOSTests/ICloudCrossDeviceSmokeTests"
RESULT_BUNDLE="$DERIVED_ROOT/test-results.xcresult"

report_result() {
  python3 - "$1" <<'PY'
import json
import subprocess
import sys

summary = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", sys.argv[1],
], text=True))
print(f"通过 {summary.get('passedTests', 0)}，失败 {summary.get('failedTests', 0)}，跳过 {summary.get('skippedTests', 0)}")
for failure in summary.get("testFailures", []):
    print(failure.get("failureText", failure))
PY
}

if [[ "${1:-}" == "--report" ]]; then
  report_result "${2:-$RESULT_BUNDLE}"
  exit $?
fi
CLEANUP_ONLY=false
if [[ "${1:-}" == "--cleanup" ]]; then
  CLEANUP_ONLY=true
  shift
fi

if [[ $# -gt 1 ]]; then
  echo "用法: $0 [--cleanup] [真机设备ID]；$0 --report [结果包路径]" >&2
  exit 64
fi
source "$ROOT_DIR/Scripts/device-support.sh"
bit101_require_device "${1:-}" || exit 1
DEVICE_ID="$BIT101_XCODE_DEVICE_ID"

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
  rm -rf "$RESULT_BUNDLE"
  if run_with_output_threshold "$log" "$method 真机测试输出" xcodebuild test-without-building "${common_args[@]}" \
      -destination "platform=iOS,id=$DEVICE_ID" \
      -derivedDataPath "$DERIVED_ROOT/Phone" \
      -resultBundlePath "$RESULT_BUNDLE" \
      "-only-testing:$TEST_CLASS/$method"; then
    return 0
  else
    local test_status=$?
    if [[ -d "$RESULT_BUNDLE" ]]; then
      report_result "$RESULT_BUNDLE" || true
    fi
    return "$test_status"
  fi
}

if $CLEANUP_ONLY; then
  cleanup_status=0
  run_phone_test testCleanup || cleanup_status=$?
  "$ROOT_DIR/Scripts/build-install-device.sh" "$DEVICE_ID" || cleanup_status=1
  exit "$cleanup_status"
fi

cleanup() {
  local smoke_status=$?
  trap - EXIT INT TERM
  echo "尝试恢复真机设置并清理 Smoke 协调数据……" >&2
  run_phone_test testCleanup || true
  exit "$smoke_status"
}

echo "[构建] 准备真机测试宿主"
run_with_output_threshold "$DERIVED_ROOT/build.log" "iCloud 真机测试构建输出" \
  xcodebuild build-for-testing "${common_args[@]}" \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_ROOT/Phone" \
    "-only-testing:$TEST_CLASS"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[1/3] 真机上传设置与成绩缓存"
run_phone_test testPhoneUpload || exit $?

echo "[2/3] Mac Catalyst 接收手机数据并写回原设置"
MAC_LOG="$DERIVED_ROOT/mac-receive.log"
rm -rf "$RESULT_BUNDLE"
if run_with_output_threshold "$MAC_LOG" "Mac Catalyst 接收测试输出" xcodebuild test "${common_args[@]}" \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED_ROOT/Mac" \
    -resultBundlePath "$RESULT_BUNDLE" \
    ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
    "-only-testing:$TEST_CLASS/testMacReceiveAndRestore"; then
  MAC_STATUS=0
else
  MAC_STATUS=$?
fi
if (( MAC_STATUS != 0 )); then
  if [[ -d "$RESULT_BUNDLE" ]]; then
    report_result "$RESULT_BUNDLE" || true
  fi
  exit 1
fi

echo "[3/3] 真机接收 Mac 写回并清理"
run_phone_test testPhoneVerifyAndCleanup || exit $?

trap - EXIT INT TERM
echo "iCloud 双向 Smoke 测试通过。"
