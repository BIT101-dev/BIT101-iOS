#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "用法: $0 <真机设备ID> [Developer目录]" >&2
  exit 64
fi

DEVICE_ID="$1"
export DEVELOPER_DIR="${2:-${DEVELOPER_DIR:-$(xcode-select -p)}}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/release-network-smoke"
LOG_FILE="$DERIVED_DATA/network-smoke.log"
SUMMARY_FILE="$DERIVED_DATA/latest-summary.json"
CONDITIONS="DEBUG RELEASE_NETWORK_SMOKE"
TEST_METHOD="BIT101-iOSTests/ReleaseNetworkSmokeTests/testReadOnlyUserNetworkFlows"

mkdir -p "$DERIVED_DATA"

echo "发布前网络冒烟测试开始。测试不会识别或切换当前网络环境。"
echo "设备: $DEVICE_ID"

set +e
set -o pipefail
xcodebuild test \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$CONDITIONS" \
  -collect-test-diagnostics never \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 300 \
  "-only-testing:$TEST_METHOD" 2>&1 | tee "$LOG_FILE"
TEST_STATUS=$pipestatus[1]
set -e

if [[ $TEST_STATUS -ne 0 ]]; then
  RESULT_BUNDLE="$(ls -td "$DERIVED_DATA"/Logs/Test/*.xcresult 2>/dev/null | head -1)"
  if [[ -n "$RESULT_BUNDLE" ]]; then
    xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" > "$SUMMARY_FILE"
    python3 - "$SUMMARY_FILE" <<'PY' | tee -a "$LOG_FILE"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    summary = json.load(stream)

for failure in summary.get("testFailures", []):
    message = failure.get("failureText", "未知测试失败")
    label = "AUTH_BLOCKED" if "需要人工认证" in message else "FAIL"
    print(f"发布前网络冒烟结果: {label}\n{message}")
PY
  fi
  exit $TEST_STATUS
fi

echo "发布前网络冒烟测试通过。日志: $LOG_FILE"
