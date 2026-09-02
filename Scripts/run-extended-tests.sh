#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/extended-automation"
TEST_BUNDLE="BIT101-iOSTests"
CONDITIONS="DEBUG EXTENDED_AUTOMATION"

if [[ $# -eq 0 ]]; then
  source "$ROOT_DIR/Scripts/device-support.sh"
  bit101_require_device "$PROJECT" || exit 1
  DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
else
  if [[ $# -gt 2 ]]; then
    echo "用法：Scripts/run-extended-tests.sh [真机设备ID] [Developer目录]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
  export DEVELOPER_DIR="${2:-${DEVELOPER_DIR:-/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer}}"
fi

mkdir -p "$DERIVED_ROOT"

run_group() {
  local group="$1"
  local log="$DERIVED_ROOT/$group.log"
  echo "[扩展测试] $group"
  if ! xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme BIT101-iOS \
    -configuration Debug \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_ROOT" \
    -collect-test-diagnostics never \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$CONDITIONS" \
    "-only-testing:$TEST_BUNDLE/$group" \
    -allowProvisioningUpdates > "$log" 2>&1
  then
    echo "扩展测试失败：$group" >&2
    tail -n 80 "$log" >&2
    exit 1
  fi
  echo "[通过] $group"
}

run_group ExtendedSchedulePolicyTests
run_group ExtendedInfrastructureTests
run_group ExtendedLoginTests
echo "扩展自动化测试全部通过。"
