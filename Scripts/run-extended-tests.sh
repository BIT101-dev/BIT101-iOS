#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/extended-automation"
TEST_BUNDLE="BIT101-iOSTests"
TEST_SCHEME="BIT101-iOS"
CONDITIONS="DEBUG EXTENDED_AUTOMATION BIT101_AUTOMATED_TESTING"
RESULT_BUNDLE="$DERIVED_ROOT/test-results.xcresult"
UI_TEST_SELECTION=""

MODE="all"
if [[ $# -gt 0 ]]; then
  case "$1" in
    all|default|schedule|schedule-share|infrastructure|login|extensions|ui|catalyst)
      MODE="$1"
      shift
      ;;
  esac
fi

if [[ "$MODE" == "ui" ]]; then
  TEST_BUNDLE="BIT101-iOSUITests"
  TEST_SCHEME="BIT101-iOS-UIAutomation"
  CONDITIONS="EXTENDED_AUTOMATION BIT101_AUTOMATED_TESTING BIT101_UI_TESTING"
  if [[ $# -gt 0 && "$1" == */* ]]; then
    UI_TEST_SELECTION="$1"
    shift
  fi
fi

UI_RESTORE_DEVICE_ID=""
if [[ "$MODE" == "catalyst" ]]; then
  if [[ $# -gt 0 ]]; then
    echo "用法：Scripts/run-extended-tests.sh catalyst" >&2
    exit 64
  fi
  TEST_DESTINATION="platform=macOS,variant=Mac Catalyst"
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
elif [[ $# -eq 0 ]]; then
  source "$ROOT_DIR/Scripts/device-support.sh"
  bit101_require_device "$PROJECT" || exit 1
  TEST_DESTINATION="platform=iOS,id=$BIT101_XCODE_DEVICE_ID"
  SIGNING_ARGS=(-allowProvisioningUpdates)
  UI_RESTORE_DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
else
  if [[ $# -gt 2 ]]; then
    echo "用法：Scripts/run-extended-tests.sh [all|default|schedule|schedule-share|infrastructure|login|extensions|ui] [UI测试类/用例] [真机设备ID]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
  TEST_DESTINATION="platform=iOS,id=$DEVICE_ID"
  SIGNING_ARGS=(-allowProvisioningUpdates)
  UI_RESTORE_DEVICE_ID="$DEVICE_ID"
fi

if [[ "$MODE" == "ui" ]]; then
  restore_release_app() {
    local test_exit_code=$?
    trap - EXIT
    echo "[恢复] 安装并启动常规 Release App"
    if ! "$ROOT_DIR/Scripts/build-install-device.sh" "$UI_RESTORE_DEVICE_ID"; then
      echo "常规 Release App 恢复失败，请运行 Scripts/build-install-device.sh $UI_RESTORE_DEVICE_ID" >&2
      (( test_exit_code == 0 )) && test_exit_code=1
    fi
    exit "$test_exit_code"
  }
  trap restore_release_app EXIT
fi

mkdir -p "$DERIVED_ROOT"
rm -rf "$RESULT_BUNDLE"

emit_output() {
  local output_path="$1"
  local label="$2"
  local output="$3"
  local line_count

  if [[ -z "$output" ]]; then
    rm -f "$output_path"
    return 0
  fi

  line_count="$(printf '%s\n' "$output" | wc -l | tr -d '[:space:]')"
  if (( line_count <= 1000 )); then
    rm -f "$output_path"
    print -r -- "$output"
  else
    printf '%s\n' "$output" > "$output_path"
    echo "[输出] $label 共 $line_count 行，详情写入 $output_path"
  fi
}

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

run_tests() {
  local group="$1"
  local log="$DERIVED_ROOT/$group.log"
  local conditions="$2"
  local only_testing="$TEST_BUNDLE"
  local failure_summary
  local exit_code
  local diagnostics="never"
  if [[ "$group" == "ui-tests" && -n "$UI_TEST_SELECTION" ]]; then
    only_testing="$TEST_BUNDLE/$UI_TEST_SELECTION"
  elif [[ "$group" != "all-tests" && "$group" != "default-tests" && "$group" != "ui-tests" ]]; then
    only_testing="$TEST_BUNDLE/$group"
  fi

  echo "[测试] $group"
  if run_with_output_threshold "$log" "$group 测试输出" xcodebuild test -quiet \
    -project "$PROJECT" \
    -scheme "$TEST_SCHEME" \
    -configuration Release \
    -destination "$TEST_DESTINATION" \
    -derivedDataPath "$DERIVED_ROOT" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -collect-test-diagnostics "$diagnostics" \
    -enableCodeCoverage YES \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$conditions" \
    ENABLE_CODE_COVERAGE=YES \
    ENABLE_TESTABILITY=YES \
    "-only-testing:$only_testing" \
    "${SIGNING_ARGS[@]}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  if (( exit_code != 0 )); then
    echo "测试失败：$group" >&2
    failure_summary="$(python3 - "$RESULT_BUNDLE" <<'PY'
import json
import subprocess
import sys

result = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", sys.argv[1]],
    capture_output=True,
    text=True,
)
if result.returncode == 0:
    summary = json.loads(result.stdout)
    failures = summary.get("testFailures", [])
    if failures:
        print(json.dumps(failures, ensure_ascii=False, indent=2))
PY
    )"
    if [[ -n "$failure_summary" ]]; then
      emit_output "$DERIVED_ROOT/test-failures.txt" "XCTest 失败摘要" "$failure_summary"
    fi
  fi

  (( exit_code == 0 )) || exit 1
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
coverage = None
coverage_error = None
if mode != "catalyst":
    coverage_result = subprocess.run([
        "xcrun", "xccov", "view", "--report", "--json", result_bundle,
    ], capture_output=True, text=True)
    if coverage_result.returncode == 0:
        try:
            coverage = json.loads(coverage_result.stdout)
        except json.JSONDecodeError as error:
            coverage_error = f"xccov returned invalid JSON: {error}"
    else:
        coverage_error = (coverage_result.stderr or coverage_result.stdout).strip()
        if not coverage_error:
            coverage_error = f"xccov exited with status {coverage_result.returncode}"

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
    "# XCTest 与覆盖率指标",
    f"测试分组：{mode}",
    "",
    "## 测试汇总",
    json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True),
    "",
    "## 逐 target 行覆盖率",
]
if coverage is None:
    if mode == "catalyst":
        lines.append("Mac Catalyst runtime does not provide an xccov archive.")
    else:
        lines.append("设备测试汇总已采集；Xcode 覆盖率归档诊断如下。")
        if coverage_error:
            lines.append(coverage_error)
else:
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
  ui)
    run_tests ui-tests "$CONDITIONS"
    ;;
  catalyst)
    run_tests all-tests "$CONDITIONS"
    echo "Mac Catalyst 行为测试全部通过。"
    ;;
esac

record_metrics
