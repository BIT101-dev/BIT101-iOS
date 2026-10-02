#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
source "$ROOT_DIR/Scripts/script-support.sh"
DERIVED_ROOT="$ROOT_DIR/.build/extended-automation"
if [[ "${1:-}" == cache ]]; then
  [[ $# -eq 1 ]] || exit 64
  bit101_build_cache --maintenance
  exit 0
fi
if [[ "${1:-}" == report || "${1:-}" == screenshot || "${1:-}" == activities || "${1:-}" == diagnostics ]]; then
  case "$1" in
    report) [[ $# -le 2 ]] || exit 64 ;;
    diagnostics) [[ $# -eq 1 ]] || exit 64 ;;
    *) [[ $# -eq 2 ]] || { echo "请提供测试类/方法。" >&2; exit 64; } ;;
  esac
  if [[ "$1" == report && $# -eq 1 && -f "$DERIVED_ROOT/test-metrics.txt" ]]; then
    cat "$DERIVED_ROOT/test-metrics.txt"
    if [[ -f "$DERIVED_ROOT/test-failures.txt" ]]; then cat "$DERIVED_ROOT/test-failures.txt"; fi
    exit 0
  fi
  python3 - "$DERIVED_ROOT/test-results.xcresult" "${2:-}" "$1" <<'PY'
import json
import shutil
import subprocess
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
if not (bundle / "database.sqlite3").is_file() or (bundle / "Staging").exists():
    raise SystemExit("测试结果可在运行结束后通过 report 读取。")

if sys.argv[3] == "diagnostics":
    output = bundle.parent / "diagnostics"
    shutil.rmtree(output, ignore_errors=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(bundle),
                    "--output-path", str(output)], check=True, stdout=subprocess.DEVNULL)
    print(output)
    raise SystemExit(0)

if sys.argv[2]:
    activities = json.loads(subprocess.check_output([
        "xcrun", "xcresulttool", "get", "test-results", "activities", "--path", sys.argv[1],
        "--test-id", sys.argv[2],
    ], text=True))
    if sys.argv[3] == "activities":
        actions = []
        def titles(value):
            if isinstance(value, dict):
                title = str(value.get("title", ""))
                if title.startswith(("Tap ", "Type ", "Pinch ", "Swipe ", "failed ", "Failed ")):
                    actions.append(title)
                for child in value.values():
                    titles(child)
            elif isinstance(value, list):
                for child in value:
                    titles(child)
        titles(activities)
        print("\n".join(actions[-30:]))
        raise SystemExit(0)
    def attachments(value):
        if isinstance(value, dict):
            screenshot = sys.argv[3] == "screenshot"
            name = "失败时的界面截图" if screenshot else "失败时的界面元素树"
            if str(value.get("name", "")).startswith(name):
                identifier = value.get("payloadId")
                if identifier:
                    output = (Path(sys.argv[1]).parent.parent / "screenshot.png" if screenshot
                              else Path(sys.argv[1]).parent / "failure-hierarchy.txt")
                    subprocess.run(["xcrun", "xcresulttool", "export", "object", "--legacy", "--type", "file",
                                    "--path", sys.argv[1], "--id", identifier, "--output-path", str(output)], check=True,
                                   stdout=subprocess.DEVNULL)
                    print(output if screenshot else output.read_text())
                else:
                    print(json.dumps(value, ensure_ascii=False))
            for child in value.values():
                attachments(child)
        elif isinstance(value, list):
            for child in value:
                attachments(child)
    attachments(activities)
    raise SystemExit(0)

summary = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", sys.argv[1],
], text=True))
print(f"{summary.get('result', '?')} · {summary.get('passedTests', 0)}/{summary.get('totalTestCount', 0)} 通过")
for failure in summary.get("testFailures", []):
    message = str(failure.get("failureText", "?")).splitlines()[0][:240]
    print(f"{failure.get('testIdentifierString', '?')}: {message}")
tests = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", sys.argv[1],
], text=True))
def visit(value):
    if isinstance(value, dict):
        if value.get("nodeType") == "Test Case":
            print(f"{value.get('name', '?')} · {value.get('duration', '?')} · {value.get('result', '?')}")
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)
visit(tests)
PY
  exit 0
fi
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  echo "Scripts/run-extended-tests.sh                    自动选机、运行完整行为测试"
  echo "Scripts/run-extended-tests.sh modules            本机模块测试"
  echo "Scripts/run-extended-tests.sh ui [用例关键词]...  真机 UI 测试，多个筛选合并执行"
  echo "Scripts/run-extended-tests.sh build [宿主]        编译测试宿主，默认 release"
  echo "Scripts/run-extended-tests.sh report              读取测试结果"
  echo "Scripts/run-extended-tests.sh cache               整理共享构建缓存"
  echo "分组：schedule、infrastructure、login、extensions、catalyst；组后可直接填写测试类/方法。"
  echo "宿主：release、ui、network-smoke、icloud-smoke、modules、catalyst。"
  echo "专项：verify [分组]...；diagnostics；report|screenshot|activities 测试类/方法。"
  exit 0
fi
SCRIPT_PATH="$0"
SCRIPT_ARGS=("$@")
acquire_test_lock() {
  if [[ "${BIT101_EXTENDED_TESTS_LOCK_HELD:-0}" != "1" ]]; then
    exec python3 - "$ROOT_DIR/.build/extended-automation.lock" "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}" <<'PY'
import fcntl
import os
from pathlib import Path
import subprocess
import sys

lock_path = Path(sys.argv[1])
lock_path.parent.mkdir(parents=True, exist_ok=True)
with lock_path.open("a") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("[等待] 既有测试正在使用固定产物目录。", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
    environment = dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1")
    script = Path(sys.argv[2])
    command = ["zsh", "-c", script.read_text(), str(script), *sys.argv[3:]]
    result = subprocess.run(command, env=environment)
    raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
  fi
}
TEST_BUNDLE="BIT101-iOSTests"
TEST_SCHEME="BIT101-iOS"
CONDITIONS="DEBUG EXTENDED_AUTOMATION BIT101_AUTOMATED_TESTING"
RESULT_BUNDLE="$DERIVED_ROOT/test-results.xcresult"
typeset -aU TEST_SELECTIONS
TEST_SELECTIONS=()
BUILD_ONLY=false
GENERIC_BUILD=false
TEST_DURATION_SECONDS=0

MODE="all"
if [[ "${1:-}" == build ]]; then
  BUILD_ONLY=true
  shift
  MODE="${1:-release}"
  if (( $# > 0 )); then shift; fi
  case "$MODE" in
    release|ui|network-smoke|icloud-smoke) GENERIC_BUILD=true ;;
    modules|catalyst) ;;
    *) echo "编译宿主：release、ui、network-smoke、icloud-smoke、modules、catalyst。" >&2; exit 64 ;;
  esac
fi
if ! $BUILD_ONLY && [[ $# -gt 0 ]]; then
  case "$1" in
    all|schedule|infrastructure|login|extensions|ui|catalyst|modules|verify)
      MODE="$1"
      shift
      ;;
  esac
fi

if [[ "$MODE" == "verify" ]]; then
  typeset -aU verification_groups
  verification_groups=("$@")
  if (( ${#verification_groups[@]} == 0 )); then
    verification_groups=(modules all catalyst ui network icloud audit)
  fi
  verification_needs_device=false
  for group in "${verification_groups[@]}"; do
    case "$group" in
      all|ui|network|ddl|icloud) verification_needs_device=true ;;
      modules|catalyst|audit) ;;
      *) echo "验证组：modules all catalyst ui network ddl icloud audit" >&2; exit 64 ;;
    esac
  done
  acquire_test_lock
  if $verification_needs_device; then
    bit101_require_device || exit 1
  fi
  export BIT101_DEFER_APP_RESTORE=1
  verification_failures=()
  finish_verification() {
    local verification_status=$?
    trap - EXIT ZERR INT TERM
    if $verification_needs_device; then
      echo "[恢复] 安装并启动常规 Release App"
      if ! "$ROOT_DIR/Scripts/build-install-device.sh"; then
        if (( verification_status == 0 )); then verification_status=1; fi
      fi
    fi
    exit "$verification_status"
  }
  trap finish_verification EXIT ZERR
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
      all|ui) verify_step "$group" "$0" "$group" ;;
      network) verify_step network "$ROOT_DIR/Scripts/release-network-smoke.sh" ;;
      ddl) verify_step ddl "$ROOT_DIR/Scripts/release-network-smoke.sh" ddl ;;
      icloud) verify_step icloud "$ROOT_DIR/Scripts/run_icloud_cross_device_smoke.sh" ;;
      audit) verify_step audit "$ROOT_DIR/Scripts/run-static-audit.sh" ;;
    esac
  done
  if (( ${#verification_failures[@]} > 0 )); then
    echo "[失败汇总] ${(j:, :)verification_failures}" >&2
    exit 1
  fi
  exit 0
fi

if [[ "$MODE" == "ui" ]]; then
  TEST_BUNDLE="BIT101-iOSUITests"
  TEST_SCHEME="BIT101-iOS-UIAutomation"
  CONDITIONS="EXTENDED_AUTOMATION BIT101_AUTOMATED_TESTING BIT101_UI_TESTING"
fi

for selection in "$@"; do
  [[ "$selection" != -* ]] || { echo "请直接填写测试类/方法；编译使用 build 宿主。" >&2; exit 64; }
  if [[ "$MODE" != ui && "$selection" != [A-Z]* ]]; then
    echo "请填写测试类/方法，或通过 --help 查看操作。" >&2
    exit 64
  fi
done
TEST_SELECTIONS=("$@")
if [[ "$MODE" == ui && ${#TEST_SELECTIONS[@]} -gt 0 ]]; then
  selections="$(bit101_ui_test_selections "${TEST_SELECTIONS[@]}")" || exit 64
  TEST_SELECTIONS=("${(@f)selections}")
fi
if [[ ( "$MODE" == modules || "$BUILD_ONLY" == true ) && ${#TEST_SELECTIONS[@]} -gt 0 ]]; then
  echo "模块测试与宿主编译直接使用对应操作名。" >&2
  exit 64
fi

if [[ "$MODE" == "modules" ]]; then
  acquire_test_lock
elif $GENERIC_BUILD; then
  acquire_test_lock
  TEST_DESTINATION="generic/platform=iOS"
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
elif [[ "$MODE" == "catalyst" ]]; then
  acquire_test_lock
  TEST_DESTINATION="platform=macOS,variant=Mac Catalyst"
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
  else
    SIGNING_ARGS=(-allowProvisioningUpdates)
  fi
else
  acquire_test_lock
  bit101_require_device || exit 1
  TEST_DESTINATION="platform=iOS,id=$BIT101_XCODE_DEVICE_ID"
  SIGNING_ARGS=(-allowProvisioningUpdates)
fi

if [[ "$MODE" == ui && ${#TEST_SELECTIONS[@]} -gt 0 ]]; then
  echo "[筛选] ${#TEST_SELECTIONS[@]} 项 UI 用例 · 同一批次执行"
fi

if [[ "$MODE" == "ui" && "$BUILD_ONLY" == false && "${BIT101_DEFER_APP_RESTORE:-0}" != "1" ]]; then
  restore_release_app() {
    local test_exit_code=$?
    trap - EXIT ZERR INT TERM
    echo "[恢复] 安装并启动常规 Release App"
    if ! "$ROOT_DIR/Scripts/build-install-device.sh"; then
      echo "常规 Release App 恢复失败，请运行 Scripts/build-install-device.sh" >&2
      if (( test_exit_code == 0 )); then test_exit_code=1; fi
    fi
    exit "$test_exit_code"
  }
  trap restore_release_app EXIT ZERR
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi

mkdir -p "$DERIVED_ROOT"
if ! $BUILD_ONLY; then
  if [[ "$MODE" != "modules" ]]; then rm -rf "$RESULT_BUNDLE"; fi
  rm -rf "$DERIVED_ROOT/diagnostics"
  rm -f "$DERIVED_ROOT/test-metrics.txt" "$DERIVED_ROOT/test-failures.txt"
fi

if [[ "$MODE" == "modules" ]]; then
  if $BUILD_ONLY; then
    echo "[编译] 模块消费者 · macOS 原生 Release"
    bit101_run_logged "$DERIVED_ROOT/module-tests.log" "模块编译" \
      xcrun swift build --build-tests -Xswiftc -enable-testing \
        --package-path "$ROOT_DIR" \
        --scratch-path "$DERIVED_ROOT" \
        --configuration release
  else
    echo "[测试] 模块消费者 · macOS 原生 Release"
    bit101_run_logged "$DERIVED_ROOT/module-tests.log" "模块离线测试" \
      xcrun swift test --enable-code-coverage \
        --package-path "$ROOT_DIR" \
        --scratch-path "$DERIVED_ROOT" \
        --configuration release
    CODECOV_PATH="$(xcrun swift test --show-codecov-path --package-path "$ROOT_DIR" --scratch-path "$DERIVED_ROOT" --configuration release)"
    python3 - "$CODECOV_PATH" "$DERIVED_ROOT/test-metrics.txt" "$ROOT_DIR" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

coverage_path, report_path, root_path = map(Path, sys.argv[1:])
test_counts = re.findall(r"Test run with (\d+) tests?", (report_path.parent / "module-tests.log").read_text())
test_count = sum(map(int, test_counts))
if test_count == 0:
    raise SystemExit("模块测试需要实际执行用例。")
products = coverage_path.parent.parent
executables = sorted(products.glob("*.xctest/Contents/MacOS/*"))
if not executables:
    raise SystemExit("模块覆盖率需要测试消费者的可执行文件。")
command = ["xcrun", "llvm-cov", "export", str(executables[0]),
           "-instr-profile", str(coverage_path.parent / "default.profdata")]
for executable in executables[1:]:
    command += ["-object", str(executable)]
coverage_text = subprocess.check_output(command, text=True)
coverage = json.loads(coverage_text)
coverage_path.write_text(coverage_text)
modules = {}
for section in coverage["data"]:
    for file in section["files"]:
        path = Path(file["filename"])
        if not path.is_relative_to(root_path / "Modules"):
            continue
        module = path.relative_to(root_path / "Modules").parts[0]
        lines = file["summary"]["lines"]
        covered, count = modules.get(module, (0, 0))
        modules[module] = covered + lines["covered"], count + lines["count"]
if not modules:
    raise SystemExit("模块覆盖率需要包含生产源码。")
rows = ["# 模块生产源码行覆盖率", f"测试通过：{test_count} 项", *[
    f"- {name}: {covered / count * 100 if count else 0:.2f}% ({covered}/{count} lines)"
    for name, (covered, count) in sorted(modules.items())
]]
report_path.write_text("\n".join(rows) + "\n")
covered = sum(row[0] for row in modules.values())
count = sum(row[1] for row in modules.values())
print(f"[覆盖率] {len(modules)} 个模块 · {covered}/{count} 行")
PY
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
  local coverage_args=(-enableCodeCoverage YES ENABLE_CODE_COVERAGE=YES)
  if $BUILD_ONLY; then
    log="$DERIVED_ROOT/$group-build.log"
    test_action=build-for-testing
  else
    execution_args+=(-resultBundlePath "$RESULT_BUNDLE")
  fi
  if [[ "$MODE" == "ui" ]]; then
    execution_args+=(-parallel-testing-enabled NO)
    coverage_args=(-enableCodeCoverage NO ENABLE_CODE_COVERAGE=NO)
  fi
  if (( ${#TEST_SELECTIONS[@]} > 0 )); then
    only_testing=()
    local selection
    for selection in "${TEST_SELECTIONS[@]}"; do
      only_testing+=("-only-testing:$TEST_BUNDLE/$selection")
    done
  elif [[ "$group" != "all-tests" && "$group" != "ui-tests" ]]; then
    only_testing=("-only-testing:$TEST_BUNDLE/$group")
  fi

  echo "[$test_action] $group"
  local started_at=$SECONDS
  if bit101_run_logged "$log" "$group 输出" xcodebuild "$test_action" -quiet \
    -project "$PROJECT" \
    -scheme "$TEST_SCHEME" \
    -configuration Release \
    -destination "$TEST_DESTINATION" \
    -derivedDataPath "$DERIVED_ROOT" \
    -collect-test-diagnostics "$diagnostics" \
    "BIT101_WORKFLOW_CONDITIONS=$conditions" \
    "${coverage_args[@]}" \
    ENABLE_TESTABILITY=YES \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    "${execution_args[@]}" \
    "${only_testing[@]}" \
    "${SIGNING_ARGS[@]}"; then
    exit_code=0
  else
    exit_code=$?
  fi
  TEST_DURATION_SECONDS=$(( SECONDS - started_at ))

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
        grouped = {}
        for failure in failures:
            grouped.setdefault(failure.get("failureText", "测试失败"), []).append(failure.get("testIdentifierString", "?"))
        for message, tests in grouped.items():
            print(f"{message.splitlines()[0][:240]} · {len(tests)} 个用例")
            for test in tests:
                print(f"  {test}")
            if "enabling automation mode" in message:
                print("iOS 自动化初始化等待设备系统验证；请在 iPhone 完成 Enable UI Automation 的密码验证后重试。")
PY
    )"
    if [[ -n "$failure_summary" ]]; then
      printf '%s\n' "$failure_summary" > "$DERIVED_ROOT/test-failures.txt"
      if (( ${#${(f)failure_summary}} <= 40 )); then
        print -r -- "$failure_summary"
      else
        echo "失败摘要共 ${#${(f)failure_summary}} 行 · $DERIVED_ROOT/test-failures.txt"
      fi
    fi
  fi

  if (( exit_code != 0 )); then
    if ! $BUILD_ONLY; then record_metrics; fi
    exit 1
  fi
}

record_metrics() {
  python3 - "$RESULT_BUNDLE" "$DERIVED_ROOT/test-metrics.txt" "$MODE" "$TEST_DURATION_SECONDS" <<'PY'
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

result_bundle, report_path, mode, elapsed_seconds = sys.argv[1:]
summary = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary",
    "--path", result_bundle,
], text=True))
if summary.get("totalTestCount", 0) == 0:
    raise SystemExit("测试未实际执行；请检查上方编译、Runner 初始化或测试选择结果。Swift Testing 方法名保留 ()。")

coverage = None
coverage_error = None
if mode not in {"catalyst", "ui"}:
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
    f"构建与运行耗时：{elapsed_seconds} 秒",
    "",
    "## UI 交互覆盖" if mode == "ui" else "## 逐 target 行覆盖率",
]
if coverage is None:
    if mode == "ui":
        lines.append("交互覆盖依据 docs/UI_INTERACTION_COVERAGE.md；复用同一 App 进程，独立重置场景数据并验证业务结果。")
        diagnostics = Path(report_path).parent / "diagnostics"
        shutil.rmtree(diagnostics, ignore_errors=True)
        try:
            subprocess.run(["xcrun", "xcresulttool", "export", "diagnostics", "--path", result_bundle,
                            "--output-path", str(diagnostics)], check=True, stdout=subprocess.DEVNULL)
            output = "\n".join(path.read_text(errors="replace") for path in
                               diagnostics.rglob("StandardOutputAndStandardError.txt"))
            with (Path(report_path).parent / "ui-tests.log").open("a") as log:
                log.write("\n" + output)
        finally:
            shutil.rmtree(diagnostics, ignore_errors=True)
        launches = len(re.findall(r"\bt =\s*[\d.]+s\s+Launch BIT101-dev\.BIT101-iOS\b", output))
        processes = sorted(set(re.findall(r"UI automation App process: (\d+)", output)))
        lines.append(f"App 启动次数：{launches}；App 进程：{', '.join(processes) or '未采集'}")
        actions = re.findall(r"\bt =\s*[\d.]+s\s+(Tap|Type|Swipe|Press|Pinch)\b", output)
        lines.append(f"系统交互动作：{len(actions)}；" + "；".join(
            f"{action} {actions.count(action)}" for action in ["Tap", "Type", "Swipe", "Press", "Pinch"]))
    elif mode == "catalyst":
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
            if executable == 0:
                lines.append(f"- {target.get('name', '?')}: 符号合并到宿主范围")
            else:
                lines.append(f"- {target.get('name', '?')}: {percentage:.2f}% ({covered}/{executable} lines)")
    if not target_rows:
        lines.append(json.dumps(coverage, ensure_ascii=False, indent=2, sort_keys=True))

test_tree = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", result_bundle,
], text=True))
durations = []
def visit_tests(value):
    if isinstance(value, dict):
        if value.get("nodeType") == "Test Case":
            duration = str(value.get("duration", ""))
            units = {"毫秒": 0.001, "ms": 0.001, "分钟": 60, "min": 60, "m": 60, "秒": 1, "s": 1}
            seconds = sum(float(number) * units[unit] for number, unit in
                          re.findall(r"(\d+(?:\.\d+)?)\s*(毫秒|ms|分钟|min|m|秒|s)", duration))
            durations.append((seconds, value.get("name", "?"), duration))
        for child in value.values():
            visit_tests(child)
    elif isinstance(value, list):
        for child in value:
            visit_tests(child)
visit_tests(test_tree)
if durations:
    lines += ["", "## 用例耗时", f"用例耗时合计：{sum(item[0] for item in durations):.1f} 秒", *[
        f"- {name}: {duration}" for _, name, duration in sorted(durations, reverse=True)[:10]
    ]]

report = "\n".join(lines) + "\n"
Path(report_path).write_text(report, encoding="utf-8")
print(lines[4])
coverage_lines = [line for line in lines[7:] if line.startswith("- ") and "符号合并" not in line]
if len(coverage_lines) <= 1000:
    if coverage_lines:
        print("\n".join(coverage_lines))
else:
    print(f"覆盖率指标共 {len(coverage_lines)} 行 · {report_path}")
if mode not in {"catalyst", "ui"} and coverage is None:
    if coverage_error:
        print(coverage_error)
    raise SystemExit("覆盖率采集失败。")
PY
}

case "$MODE" in
  release)
    run_tests all-tests ""
    ;;
  network-smoke)
    run_tests ReleaseNetworkSmokeTests "RELEASE_NETWORK_SMOKE"
    ;;
  icloud-smoke)
    run_tests ICloudCrossDeviceSmokeTests "DEBUG ICLOUD_CROSS_DEVICE_SMOKE"
    ;;
  all)
    run_tests all-tests "$CONDITIONS"
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
