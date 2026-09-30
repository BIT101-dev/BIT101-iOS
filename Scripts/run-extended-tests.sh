#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/extended-automation"
TEST_BUNDLE="BIT101-iOSTests"
TEST_SCHEME="BIT101-iOS"
CONDITIONS="DEBUG EXTENDED_AUTOMATION BIT101_AUTOMATED_TESTING"
RESULT_BUNDLE="$DERIVED_ROOT/test-results.xcresult"
typeset -aU TEST_SELECTIONS
TEST_SELECTIONS=()
BUILD_ONLY=false

MODE="all"
if [[ $# -gt 0 ]]; then
  case "$1" in
    all|default|schedule|schedule-share|infrastructure|login|extensions|ui|catalyst|modules|verify)
      MODE="$1"
      shift
      ;;
  esac
fi

if [[ "$MODE" == "verify" ]]; then
  typeset -aU verification_groups verification_ui_selections
  verification_groups=()
  verification_ui_selections=()
  while (( $# > 0 )); do
    case "$1" in
      --ui-test)
        if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
          echo "--ui-test 后填写 UI 测试类或测试类/方法" >&2
          exit 64
        fi
        verification_groups+=(ui)
        verification_ui_selections+=("$2")
        shift 2
        ;;
      *) verification_groups+=("$1"); shift ;;
    esac
  done
  verification_ui_args=()
  for selection in "${verification_ui_selections[@]}"; do
    verification_ui_args+=(--only-testing "$selection")
  done
  if (( ${#verification_groups[@]} == 0 )); then
    verification_groups=(modules all catalyst ui network icloud audit)
  fi
  verification_needs_device=false
  verification_device_id=""
  for group in "${verification_groups[@]}"; do
    case "$group" in
      all|ui|network|ddl|icloud) verification_needs_device=true ;;
      modules|catalyst|audit) ;;
      *) echo "验证组：modules all catalyst ui network ddl icloud audit" >&2; exit 64 ;;
    esac
  done
  if $verification_needs_device; then
    source "$ROOT_DIR/Scripts/device-support.sh"
    bit101_require_device "$PROJECT" || exit 1
    verification_device_id="$BIT101_XCODE_DEVICE_ID"
  fi
  export BIT101_DEFER_APP_RESTORE=1
  verification_failures=()
  finish_verification() {
    local verification_status=$?
    trap - EXIT INT TERM
    if $verification_needs_device; then
      echo "[恢复] 安装并启动常规 Release App"
      "$ROOT_DIR/Scripts/build-install-device.sh" "$verification_device_id" || verification_status=1
    fi
    exit "$verification_status"
  }
  trap finish_verification EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  verify_step() {
    local label="$1"
    shift
    local started_at=$SECONDS
    if "$@"; then
      echo "[验证通过] $label · $(( SECONDS - started_at )) 秒"
    else
      verification_failures+=("$label")
      echo "[验证失败] $label · $(( SECONDS - started_at )) 秒" >&2
    fi
  }
  for group in "${verification_groups[@]}"; do
    case "$group" in
      modules|catalyst) verify_step "$group" "$0" "$group" ;;
      all) verify_step all "$0" all "$verification_device_id" ;;
      ui) verify_step ui "$0" ui "${verification_ui_args[@]}" "$verification_device_id" ;;
      network) verify_step network env BIT101_NETWORK_SMOKE_SCOPE=all "$ROOT_DIR/Scripts/release-network-smoke.sh" "$verification_device_id" ;;
      ddl) verify_step ddl env BIT101_NETWORK_SMOKE_SCOPE=ddl "$ROOT_DIR/Scripts/release-network-smoke.sh" "$verification_device_id" ;;
      icloud) verify_step icloud "$ROOT_DIR/Scripts/run_icloud_cross_device_smoke.sh" "$verification_device_id" ;;
      audit) verify_step audit "$ROOT_DIR/Scripts/run-static-audit.sh" ;;
    esac
  done
  if (( ${#verification_failures[@]} > 0 )); then
    echo "[失败汇总] ${(j:, :)verification_failures}" >&2
    exit 1
  fi
  echo "所选验证组全部通过。"
  exit 0
fi

if [[ "$MODE" == "ui" ]]; then
  TEST_BUNDLE="BIT101-iOSUITests"
  TEST_SCHEME="BIT101-iOS-UIAutomation"
  CONDITIONS="EXTENDED_AUTOMATION BIT101_AUTOMATED_TESTING BIT101_UI_TESTING"
  while [[ $# -gt 0 && "$1" == */* ]]; do
    TEST_SELECTIONS+=("$1")
    shift
  done
fi

while (( $# > 0 )); do
  case "$1" in
    --build-only) BUILD_ONLY=true; shift ;;
    --only-testing)
      if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo "--only-testing 后填写测试类或测试类/方法" >&2
        exit 64
      fi
      TEST_SELECTIONS+=("$2")
      shift 2
      ;;
    --*) echo "测试选项：--build-only、--only-testing 测试类/方法" >&2; exit 64 ;;
    *) break ;;
  esac
done

UI_RESTORE_DEVICE_ID=""
if [[ "$MODE" == "modules" ]]; then
  if [[ $# -gt 0 || ${#TEST_SELECTIONS[@]} -gt 0 ]]; then
    echo "用法：Scripts/run-extended-tests.sh modules [--build-only]" >&2
    exit 64
  fi
elif [[ "$MODE" == "catalyst" ]]; then
  if [[ $# -gt 0 ]]; then
    echo "用法：Scripts/run-extended-tests.sh catalyst" >&2
    exit 64
  fi
  TEST_DESTINATION="platform=macOS,variant=Mac Catalyst"
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
  else
    SIGNING_ARGS=(-allowProvisioningUpdates)
  fi
elif [[ $# -eq 0 ]]; then
  source "$ROOT_DIR/Scripts/device-support.sh"
  bit101_require_device "$PROJECT" || exit 1
  TEST_DESTINATION="platform=iOS,id=$BIT101_XCODE_DEVICE_ID"
  SIGNING_ARGS=(-allowProvisioningUpdates)
  UI_RESTORE_DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
else
  if [[ $# -gt 1 ]]; then
    echo "用法：Scripts/run-extended-tests.sh [模式] [--only-testing 测试类/用例]... [真机设备ID]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
  TEST_DESTINATION="platform=iOS,id=$DEVICE_ID"
  SIGNING_ARGS=(-allowProvisioningUpdates)
  UI_RESTORE_DEVICE_ID="$DEVICE_ID"
fi

if [[ "$MODE" == "ui" && "$BUILD_ONLY" == false && "${BIT101_DEFER_APP_RESTORE:-0}" != "1" ]]; then
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
    if not line.strip() or line.startswith(("note: Removed stale file ", "Failed frontend command:")):
        continue
    if (line.startswith("/") and "swift-frontend -frontend" in line) or line.lstrip().startswith("builtin-SwiftDriver -- "):
        continue
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

if [[ "$MODE" == "modules" ]]; then
  rm -f "$DERIVED_ROOT/test-metrics.txt"
  if $BUILD_ONLY; then
    echo "[编译] BIT101ModulesTests · macOS 原生 Release"
    run_with_output_threshold "$DERIVED_ROOT/module-tests.log" "模块编译" \
      xcrun swift build --build-tests -Xswiftc -enable-testing \
        --package-path "$ROOT_DIR" \
        --scratch-path "$DERIVED_ROOT" \
        --configuration release
    echo "[编译通过] BIT101ModulesTests"
  else
    echo "[测试] BIT101ModulesTests · macOS 原生 Release"
    run_with_output_threshold "$DERIVED_ROOT/module-tests.log" "模块离线测试" \
      xcrun swift test \
        --package-path "$ROOT_DIR" \
        --scratch-path "$DERIVED_ROOT" \
        --configuration release
    echo "[通过] BIT101ModulesTests"
  fi
  exit 0
fi

run_tests() {
  local group="$1"
  local log="$DERIVED_ROOT/$group.log"
  local conditions="$2"
  local only_testing=("-only-testing:$TEST_BUNDLE")
  local failure_summary
  local exit_code
  local diagnostics="never"
  local test_action=test
  local execution_args=()
  if $BUILD_ONLY; then
    test_action=build-for-testing
  fi
  if [[ "$MODE" == "ui" ]]; then
    execution_args+=(-parallel-testing-enabled NO)
  fi
  if (( ${#TEST_SELECTIONS[@]} > 0 )); then
    only_testing=()
    local selection
    for selection in "${TEST_SELECTIONS[@]}"; do
      only_testing+=("-only-testing:$TEST_BUNDLE/$selection")
    done
  elif [[ "$group" != "all-tests" && "$group" != "default-tests" && "$group" != "ui-tests" ]]; then
    only_testing=("-only-testing:$TEST_BUNDLE/$group")
  fi

  echo "[$test_action] $group"
  if run_with_output_threshold "$log" "$group 输出" xcodebuild "$test_action" -quiet \
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
    "${execution_args[@]}" \
    "${only_testing[@]}" \
    "${SIGNING_ARGS[@]}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  if (( exit_code != 0 )) && ! $BUILD_ONLY; then
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
  echo "[通过] $test_action · $group"
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

lines = [
    "# XCTest 与覆盖率指标",
    f"测试分组：{mode}",
    "",
    "## 测试汇总",
    f"结果：{summary.get('result', '?')}；总计 {summary.get('totalTestCount', '?')}；通过 {summary.get('passedTests', 0)}；失败 {summary.get('failedTests', 0)}；跳过 {summary.get('skippedTests', 0)}",
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

report = "\n".join(lines) + "\n"
if len(report.splitlines()) <= 1000:
    Path(report_path).unlink(missing_ok=True)
    print(report, end="")
else:
    Path(report_path).write_text(report, encoding="utf-8")
    print(f"测试指标共 {len(report.splitlines())} 行，详情写入 {report_path}")
PY
}

case "$MODE" in
  all)
    run_tests all-tests "$CONDITIONS"
    ;;
  default)
    run_tests default-tests "DEBUG BIT101_AUTOMATED_TESTING"
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
    ;;
esac

if $BUILD_ONLY; then
  echo "测试宿主编译完成，可通过同一入口批量执行用例。"
else
  record_metrics
fi
