#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/extended-automation"
TEST_BUNDLE="BIT101-iOSTests"
CONDITIONS="DEBUG EXTENDED_AUTOMATION BIT101_AUTOMATED_TESTING"
RESULT_BUNDLE="$DERIVED_ROOT/test-results.xcresult"

MODE="all"
if [[ $# -gt 0 ]]; then
  case "$1" in
    all|default|schedule|schedule-share|infrastructure|login|extensions)
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
    echo "用法：Scripts/run-extended-tests.sh [all|default|schedule|schedule-share|infrastructure|login|extensions] [真机设备ID]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
fi

mkdir -p "$DERIVED_ROOT"
rm -rf "$RESULT_BUNDLE"

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
    -resultBundlePath "$RESULT_BUNDLE" \
    -collect-test-diagnostics never \
    -enableCodeCoverage YES \
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

record_metrics() {
  python3 - "$RESULT_BUNDLE" "$DERIVED_ROOT/test-metrics.txt" "$MODE" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

result_bundle, report_path, mode = sys.argv[1:]
summary = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary",
    "--path", result_bundle,
], text=True))
coverage = json.loads(subprocess.check_output([
    "xcrun", "xccov", "view", "--report", "--json", result_bundle,
], text=True))

def count_fields(value):
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = key.lower().replace("_", "")
            if normalized in {"totaltestcount", "passedtests", "failedtests", "skippedtests"}:
                yield key, item
            yield from count_fields(item)
    elif isinstance(value, list):
        for item in value:
            yield from count_fields(item)

lines = [
    "# 真机 XCTest 与覆盖率指标",
    f"测试分组：{mode}",
    "",
    "## 测试汇总",
    json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True),
    "",
    "## 逐 target 行覆盖率",
]
target_rows = coverage.get("targets", [])
for target in target_rows:
    fraction = target.get("lineCoverage")
    if isinstance(fraction, (int, float)):
        percentage = fraction * 100 if fraction <= 1 else fraction
        covered = target.get("coveredLines", "?")
        executable = target.get("executableLines", "?")
        lines.append(f"- {target.get('name', '?')}: {percentage:.2f}% ({covered}/{executable} lines)")
if not target_rows:
    lines.append(json.dumps(coverage, ensure_ascii=False, indent=2, sort_keys=True))

counts = list(count_fields(summary))
if counts:
    lines.extend(["", "## 测试计数", *(f"- {key}: {value}" for key, value in counts)])
report = "\n".join(lines) + "\n"
if len(lines) <= 1000:
    Path(report_path).unlink(missing_ok=True)
    print(report, end="")
else:
    Path(report_path).write_text(report, encoding="utf-8")
    print(f"测试指标共 {len(lines)} 行，详情写入 {report_path}")
PY
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
  schedule-share)
    run_tests ScheduleShareCodeCodecTests "$CONDITIONS"
    ;;
  infrastructure)
    run_tests ExtendedInfrastructureTests "$CONDITIONS"
    ;;
  login)
    run_tests ExtendedLoginTests "$CONDITIONS"
    ;;
  extensions)
    run_tests ExternalScheduleInfrastructureTests "$CONDITIONS"
    ;;
esac

record_metrics
