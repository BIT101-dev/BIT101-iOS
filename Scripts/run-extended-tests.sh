#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/extended-automation"
TEST_BUNDLE="BIT101-iOSTests"
CONDITIONS="DEBUG EXTENDED_AUTOMATION BIT101_AUTOMATED_TESTING"

MODE="all"
if [[ $# -gt 0 ]]; then
  case "$1" in
    all|default|schedule|infrastructure|login)
      MODE="$1"
      shift
      ;;
  esac
fi

if [[ $# -eq 0 ]]; then
  source "$ROOT_DIR/Scripts/device-support.sh"
  bit101_require_device "$PROJECT" || exit 1
  DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
else
  if [[ $# -gt 2 ]]; then
    echo "用法：Scripts/run-extended-tests.sh [all|default|schedule|infrastructure|login] [真机设备ID]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
fi

mkdir -p "$DERIVED_ROOT"

run_tests() {
  local group="$1"
  local log="$DERIVED_ROOT/$group.log"
  local conditions="$2"
  local only_testing="$TEST_BUNDLE"
  if [[ "$group" != "all-tests" && "$group" != "default-tests" ]]; then
    only_testing="$TEST_BUNDLE/$group"
  fi

  echo "[测试] $group"
  if ! xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme BIT101-iOS \
    -configuration Release \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_ROOT" \
    -collect-test-diagnostics never \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$conditions" \
    ENABLE_TESTABILITY=YES \
    "-only-testing:$only_testing" \
    -allowProvisioningUpdates > "$log" 2>&1
  then
    echo "测试失败：$group" >&2
    tail -n 80 "$log" >&2
    exit 1
  fi
  echo "[通过] $group"
}

case "$MODE" in
  all)
    run_tests all-tests "$CONDITIONS"
    echo "默认测试与扩展自动化测试全部通过。"
    ;;
  default)
    run_tests default-tests "DEBUG BIT101_AUTOMATED_TESTING"
    echo "默认测试全部通过。"
    ;;
  schedule)
    run_tests ExtendedSchedulePolicyTests "$CONDITIONS"
    ;;
  infrastructure)
    run_tests ExtendedInfrastructureTests "$CONDITIONS"
    ;;
  login)
    run_tests ExtendedLoginTests "$CONDITIONS"
    ;;
esac
