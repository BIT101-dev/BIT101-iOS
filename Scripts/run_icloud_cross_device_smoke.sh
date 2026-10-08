#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/icloud-cross-device-smoke"
CONDITIONS="DEBUG ICLOUD_CROSS_DEVICE_SMOKE"
TEST_CLASS="BIT101-iOSTests/ICloudCrossDeviceSmokeTests"
RESULT_BUNDLE="$DERIVED_ROOT/test-results.xcresult"
SUMMARY_PATH="$DERIVED_ROOT/report.json"
RUN_ID="$(uuidgen)"
export TEST_RUNNER_BIT101_ICLOUD_SMOKE_RUN_ID="$RUN_ID"

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  echo "Scripts/run_icloud_cross_device_smoke.sh          自动选机、验证 iPhone 与 Mac 双向同步"
  echo "Scripts/run_icloud_cross_device_smoke.sh report   读取报告"
  echo "Scripts/run_icloud_cross_device_smoke.sh cleanup  清理测试状态并恢复 App"
  exit 0
fi

report_result() {
  python3 - "$1" <<'PYREPORT'
import json
from pathlib import Path
import subprocess
import sys

path = Path(sys.argv[1])
if path.suffix == ".xcresult":
    summary = json.loads(subprocess.check_output([
        "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(path),
    ], text=True))
    rows = [dict(summary, stage="测试结果")]
else:
    report = json.loads(path.read_text())
    print(f"iCloud Smoke 状态码：{report.get('exitCode', '执行中')}")
    if "cleanupExitCode" in report:
        print(f"恢复流程状态码：{report['cleanupExitCode']}")
    rows = report.get("stages", [])
    if "cleanup" in report:
        rows = [*rows, report["cleanup"]]
for row in rows:
    print(f"{row['stage']}：通过 {row.get('passedTests', 0)}，失败 {row.get('failedTests', 0)}，跳过 {row.get('skippedTests', 0)}，状态 {row.get('exitCode', '?')}")
    for failure in row.get("testFailures", []):
        print(failure.get("failureText", failure))
PYREPORT
}

[[ $# -le 1 ]] || { echo "操作：report、cleanup；直接运行双向同步验证。" >&2; exit 64; }
case "${1:-}" in
  report|cleanup|"") ;;
  *) echo "操作：report、cleanup；直接运行双向同步验证。" >&2; exit 64 ;;
esac
source "$ROOT_DIR/Scripts/script-support.sh"
bit101_acquire_workflow_lock "$0" "$@"
if [[ "${1:-}" == report ]]; then
  report_result "$SUMMARY_PATH"
  exit $?
fi
CLEANUP_ONLY=false
if [[ "${1:-}" == cleanup ]]; then
  CLEANUP_ONLY=true
  shift
fi
BIT101_VALIDATION_SOURCE_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest)"
export BIT101_VALIDATION_SOURCE_DIGEST
finish_early_validation() {
  local smoke_status=$?
  trap - EXIT ZERR INT TERM
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" record icloud "$smoke_status" || smoke_status=$?
  exit "$smoke_status"
}
trap finish_early_validation EXIT
bit101_require_device || exit 1
DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
mkdir -p "$DERIVED_ROOT"
python3 - "$ROOT_DIR/BIT101-iOS/BIT101-iOS.entitlements" "$DERIVED_ROOT/signing.entitlements" <<'PY'
import plistlib
from pathlib import Path
import sys

entitlements = plistlib.loads(Path(sys.argv[1]).read_bytes())
entitlements["com.apple.developer.icloud-container-environment"] = "Production"
Path(sys.argv[2]).write_bytes(plistlib.dumps(entitlements))
PY
if ! $CLEANUP_ONLY; then rm -f "$SUMMARY_PATH"; fi

record_result() {
  python3 - "$SUMMARY_PATH" "$RESULT_BUNDLE" "$1" "$2" "$3" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

report_path, bundle, stage, process_status, log_path = sys.argv[1:]
exit_code = int(process_status)
row = {"stage": stage, "exitCode": exit_code}
if stage in {"testCleanup", "testMacReceiveAndRestore"}:
    statuses = re.findall(
        rf"Test case 'ICloudCrossDeviceSmokeTests\.{re.escape(stage)}\(\)' (passed|failed|skipped) on ",
        Path(log_path).read_text(),
    )
    row.update(totalTestCount=len(statuses), failedTests=statuses.count("failed"),
               passedTests=statuses.count("passed"), skippedTests=statuses.count("skipped"))
elif Path(bundle).is_dir():
    result = subprocess.run([
        "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle,
    ], capture_output=True, text=True)
    if result.returncode == 0:
        summary = json.loads(result.stdout)
        for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "testFailures"):
            row[key] = summary.get(key, [] if key == "testFailures" else 0)
if row.get("totalTestCount", 0) != 1 or row.get("passedTests", 0) != 1 or row.get("failedTests", 0) or row.get("skippedTests", 0):
    row["exitCode"] = exit_code or 1
    print(f"[失败] {stage} 要求一项用例执行并通过。")
path = Path(report_path)
report = json.loads(path.read_text()) if path.is_file() else {"stages": []}
report["validatedDomains"] = ["score-kvs", "schedule-cloudkit"]
report["cloudKitEnvironment"] = "Production"
if stage == "testCleanup":
    report["cleanup"] = row
else:
    report["stages"].append(row)
path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
raise SystemExit(row["exitCode"])
PY
}

common_args=(
  -quiet -project "$PROJECT" -scheme BIT101-iOS -configuration Release
  "BIT101_WORKFLOW_CONDITIONS=$CONDITIONS" ENABLE_TESTABILITY=YES
  "BIT101_APP_ENTITLEMENTS=$DERIVED_ROOT/signing.entitlements"
  -collect-test-diagnostics never
)

run_phone_test() {
  local method="$1"
  local log="$DERIVED_ROOT/$method.log"
  local result_args=()
  local test_status=0
  if [[ "$method" != "testCleanup" ]]; then
    rm -rf "$RESULT_BUNDLE"
    result_args=(-resultBundlePath "$RESULT_BUNDLE")
  fi
  bit101_run_logged "$log" "$method" xcodebuild test-without-building "${common_args[@]}" \
    -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED_ROOT/Phone" \
    "${result_args[@]}" "-only-testing:$TEST_CLASS/$method" || test_status=$?
  record_result "$method" "$test_status" "$log"
}

PHONE_TESTS_STARTED=false
PHONE_CLEANED_UP=false
PHONE_TEST_PID=""
finish_smoke() {
  local smoke_status=$?
  trap - EXIT ZERR INT TERM
  if [[ -n "$PHONE_TEST_PID" ]]; then
    kill -TERM "$PHONE_TEST_PID" 2>/dev/null || true
    wait "$PHONE_TEST_PID" 2>/dev/null || true
  fi
  if $PHONE_TESTS_STARTED && ! $PHONE_CLEANED_UP; then
    echo "[恢复] 实验开关与 Smoke 协调数据"
    if ! run_phone_test testCleanup; then
      if (( smoke_status == 0 )); then smoke_status=1; fi
    fi
  fi
  if [[ "${BIT101_DEFER_APP_RESTORE:-0}" != "1" ]]; then
    echo "[恢复] 安装并启动常规 Release App"
    local restore_status=0
    if ! "$ROOT_DIR/Scripts/build-install-device.sh"; then
      restore_status=1
      if (( smoke_status == 0 )); then smoke_status=1; fi
    fi
    python3 "$ROOT_DIR/Scripts/validation_evidence.py" record restore "$restore_status" || smoke_status=$?
  fi
  python3 - "$SUMMARY_PATH" "$smoke_status" "$CLEANUP_ONLY" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
report = json.loads(path.read_text()) if path.is_file() else {"stages": []}
if sys.argv[3] == "true":
    report["cleanupExitCode"] = int(sys.argv[2])
    report.setdefault("exitCode", int(sys.argv[2]))
else:
    report["exitCode"] = int(sys.argv[2])
path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
PY
  report_result "$SUMMARY_PATH"
  if ! $CLEANUP_ONLY || (( smoke_status != 0 )); then
    python3 "$ROOT_DIR/Scripts/validation_evidence.py" record icloud "$smoke_status" || smoke_status=$?
  fi
  if (( smoke_status == 0 )); then
    echo "iCloud Smoke 验证与恢复完成。"
  fi
  exit "$smoke_status"
}
trap finish_smoke EXIT ZERR
trap 'exit 130' INT
trap 'exit 143' TERM

if $CLEANUP_ONLY; then
  PHONE_TESTS_STARTED=true
  run_phone_test testCleanup
  PHONE_CLEANED_UP=true
  exit 0
fi

echo "[构建] 准备真机测试宿主"
bit101_run_logged "$DERIVED_ROOT/build.log" "iCloud 真机测试构建" \
  xcodebuild build-for-testing "${common_args[@]}" \
  -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED_ROOT/Phone" \
  "-only-testing:$TEST_CLASS"

echo "[构建] 准备 Mac Catalyst 测试宿主"
bit101_run_logged "$DERIVED_ROOT/mac-build.log" "iCloud Mac 测试构建" \
  xcodebuild build-for-testing "${common_args[@]}" \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$DERIVED_ROOT/Mac" \
  ONLY_ACTIVE_ARCH=YES "-only-testing:$TEST_CLASS/testMacReceiveAndRestore"

python3 - "$DERIVED_ROOT" <<'PY'
import plistlib
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
for host, platform in (("Phone", "iphoneos"), ("Mac", "maccatalyst")):
    app = root / host / "Build/Products" / f"Release-{platform}/BIT101-iOS.app"
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)], capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout)
    if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
        raise SystemExit(f"{host} 验收宿主需要 CloudKit Production 签名环境")
PY
echo "[同步] 真机与 Mac 宿主并行验证成绩 KVS 与课表 CloudKit"
PHONE_TESTS_STARTED=true
(
  trap - EXIT ZERR INT TERM
  exec python3 - "$ZSH_EXECUTION_STRING" "$ROOT_DIR" "$DERIVED_ROOT" "$RESULT_BUNDLE" "$SUMMARY_PATH" \
    "$DEVICE_ID" "$TEST_CLASS" "${common_args[@]}" <<'PYWORKER'
import os
import re
import signal
import subprocess
import sys

snapshot = sys.argv[1]
worker = r'''
set -euo pipefail
ROOT_DIR="$1"
DERIVED_ROOT="$2"
RESULT_BUNDLE="$3"
SUMMARY_PATH="$4"
DEVICE_ID="$5"
TEST_CLASS="$6"
shift 6
common_args=("$@")
source "$ROOT_DIR/Scripts/script-support.sh"
'''
for name in ("record_result", "run_phone_test"):
    worker += re.search(rf"(?ms)^{name}\(\) \{{\n.*?^\}}$", snapshot)[0] + "\n"
worker += "run_phone_test testPhoneRoundTrip\n"
process = subprocess.Popen(["zsh", "-c", worker, "phone-smoke", *sys.argv[2:]], start_new_session=True)

def interrupt(signum, _frame):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass

for signum in (signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, interrupt)
result = process.wait()
raise SystemExit(result if result >= 0 else 128 - result)
PYWORKER
) &
PHONE_TEST_PID=$!
MAC_LOG="$DERIVED_ROOT/mac-receive.log"
MAC_STATUS=0
bit101_run_logged "$MAC_LOG" "Mac Catalyst 接收测试" xcodebuild test-without-building "${common_args[@]}" \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$DERIVED_ROOT/Mac" \
  ONLY_ACTIVE_ARCH=YES \
  "-only-testing:$TEST_CLASS/testMacReceiveAndRestore" || MAC_STATUS=$?
PHONE_STATUS=0
wait "$PHONE_TEST_PID" || PHONE_STATUS=$?
PHONE_TEST_PID=""
if (( PHONE_STATUS == 0 )); then PHONE_CLEANED_UP=true; fi
record_result testMacReceiveAndRestore "$MAC_STATUS" "$MAC_LOG"
exit "$PHONE_STATUS"
