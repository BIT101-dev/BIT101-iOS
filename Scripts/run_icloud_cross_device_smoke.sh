#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_ROOT="$ROOT_DIR/.build/icloud-cross-device-smoke"
CONDITIONS="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" conditions icloud)"
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
from datetime import datetime, timezone
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
    if "macCleanup" in report:
        rows = [*rows, report["macCleanup"]]
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
bit101_acquire_script_lock "$HOME/Library/Caches/BIT101-iOS/icloud-smoke.lock" BIT101_ICLOUD_HOST_LOCK_HELD "$0" "$@"
CLEANUP_ONLY=false
if [[ "${1:-}" == cleanup ]]; then
  CLEANUP_ONLY=true
  shift
fi
if ! $CLEANUP_ONLY && [[ -f "$SUMMARY_PATH" ]]; then
  pending_cleanup="$(python3 - "$SUMMARY_PATH" <<'PY'
import json
from datetime import datetime, timezone
from pathlib import Path
import sys

report = json.loads(Path(sys.argv[1]).read_text())
phone = next((row for row in report.get("stages", []) if row.get("stage") == "testPhoneRoundTrip"), {})
mac = next((row for row in report.get("stages", []) if row.get("stage") == "testMacReceiveAndRestore"), {})
def successful(row):
    return row.get("exitCode") == 0 and row.get("totalTestCount") == row.get("passedTests") == 1 \
        and row.get("failedTests", 0) == row.get("skippedTests", 0) == 0
cleared = successful(report.get("cleanup", phone)) and successful(report.get("macCleanup", mac))
print("" if cleared else "cleanup")
PY
)"
  if [[ -n "$pending_cleanup" ]]; then "$0" cleanup; fi
fi
if $CLEANUP_ONLY; then
  cleanup_identity="$(python3 - "$SUMMARY_PATH" <<'PY'
import json
from datetime import datetime, timezone
from pathlib import Path
import sys
from uuid import UUID

report = json.loads(Path(sys.argv[1]).read_text())
run_id = report["runID"]
UUID(run_id)
phone = next((row for row in report.get("stages", []) if row.get("stage") == "testPhoneRoundTrip"), {})
recorded = report.get("phoneDeviceIdentifier")
observed = phone.get("destination", {}).get("deviceIdentifier")
device = recorded or observed
if not isinstance(device, str) or not device or (recorded and observed and recorded != observed):
    raise SystemExit("iCloud 恢复需要原执行 iPhone 的一致设备身份，请核对既有报告。")
print(run_id)
print(device)
PY
)"
  cleanup_identifiers=("${(@f)cleanup_identity}")
  RUN_ID="${cleanup_identifiers[1]}"
  CLEANUP_DEVICE_ID="${cleanup_identifiers[2]}"
fi
export TEST_RUNNER_BIT101_ICLOUD_SMOKE_RUN_ID="$RUN_ID"
PHONE_AVAILABLE=true
if ! bit101_require_device "${CLEANUP_DEVICE_ID:-}"; then
  if $CLEANUP_ONLY; then PHONE_AVAILABLE=false; else exit 1; fi
fi
BIT101_VALIDATION_RUN_ID="$RUN_ID"
validation_group=icloud
if $CLEANUP_ONLY; then validation_group=icloud-cleanup; fi
BIT101_VALIDATION_SOURCE_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest "$validation_group")"
export BIT101_VALIDATION_SOURCE_DIGEST BIT101_VALIDATION_RUN_ID
finish_early_validation() {
  local smoke_status=$?
  trap - EXIT ZERR INT TERM
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" record "$validation_group" "$smoke_status" || smoke_status=$?
  exit "$smoke_status"
}
trap finish_early_validation EXIT
DEVICE_ID="${BIT101_XCODE_DEVICE_ID:-}"
mkdir -p "$DERIVED_ROOT"
python3 - "$ROOT_DIR/BIT101-iOS/BIT101-iOS.entitlements" "$DERIVED_ROOT/signing.entitlements" <<'PY'
import plistlib
from pathlib import Path
import sys

entitlements = plistlib.loads(Path(sys.argv[1]).read_bytes())
entitlements["com.apple.developer.icloud-container-environment"] = "Production"
Path(sys.argv[2]).write_bytes(plistlib.dumps(entitlements))
PY
if ! $CLEANUP_ONLY; then
  PYTHONPATH="$ROOT_DIR/Scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SUMMARY_PATH" "$RUN_ID" "$DEVICE_ID" <<'PY'
import json
from datetime import datetime, timezone
from pathlib import Path
import sys
from validation_evidence import report_lock, write_report

with report_lock(path=Path(sys.argv[1])):
    write_report({"runID": sys.argv[2], "phoneDeviceIdentifier": sys.argv[3],
        "startedAt": datetime.now(timezone.utc).isoformat(), "stages": []}, path=Path(sys.argv[1]))
PY
fi


common_args=(
  -quiet -project "$PROJECT" -scheme BIT101-iOS -configuration Release
  "BIT101_WORKFLOW_CONDITIONS=$CONDITIONS" ENABLE_TESTABILITY=YES
  "BIT101_APP_ENTITLEMENTS=$DERIVED_ROOT/signing.entitlements"
  -collect-test-diagnostics never
)

source "$ROOT_DIR/Scripts/icloud-smoke-support.sh"

PHONE_TESTS_STARTED=false
PHONE_CLEANED_UP=false
PHONE_TEST_PID=""
MAC_TESTS_STARTED=false
MAC_CLEANED_UP=false
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
  if $MAC_TESTS_STARTED && ! $MAC_CLEANED_UP; then
    echo "[恢复] Mac 本地验收数据与密钥"
    if ! run_mac_cleanup; then
      if (( smoke_status == 0 )); then smoke_status=1; fi
    fi
  fi
  if $PHONE_AVAILABLE && [[ "${BIT101_DEFER_APP_RESTORE:-0}" != "1" ]]; then
    echo "[恢复] 安装并启动常规 Release App"
    local restore_status=0
    if ! "$ROOT_DIR/Scripts/build-install-device.sh"; then
      restore_status=1
      if (( smoke_status == 0 )); then smoke_status=1; fi
    fi
  fi
  PYTHONPATH="$ROOT_DIR/Scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SUMMARY_PATH" "$smoke_status" "$CLEANUP_ONLY" <<'PY'
import json
from datetime import datetime, timezone
from pathlib import Path
import sys
from validation_evidence import report_lock, write_report

path = Path(sys.argv[1])
with report_lock(path=path):
    report = json.loads(path.read_text()) if path.is_file() else {"stages": []}
    if sys.argv[3] == "true":
        report["cleanupExitCode"] = int(sys.argv[2])
        report.setdefault("exitCode", int(sys.argv[2]))
    else:
        report["exitCode"] = int(sys.argv[2])
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
    write_report(report, path=path)
PY
  report_result "$SUMMARY_PATH"
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" record "$validation_group" "$smoke_status" || smoke_status=$?
  if (( smoke_status == 0 )); then
    echo "iCloud Smoke 验证与恢复完成。"
  fi
  exit "$smoke_status"
}
trap finish_smoke EXIT ZERR
trap 'exit 130' INT
trap 'exit 143' TERM

cleanup_status=0
if $CLEANUP_ONLY; then
  MAC_TESTS_STARTED=true
  run_mac_cleanup && MAC_CLEANED_UP=true || cleanup_status=1
  if ! $PHONE_AVAILABLE; then
    echo "[待恢复] 原执行 iPhone 重新连接后继续 cleanup。" >&2
    exit 1
  fi
fi

echo "[构建] 准备真机测试宿主"
bit101_run_logged "$DERIVED_ROOT/build.log" "iCloud 真机测试构建" \
  xcodebuild build-for-testing "${common_args[@]}" \
  -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED_ROOT/Phone" \
  "-only-testing:$TEST_CLASS"

if $CLEANUP_ONLY; then
  PHONE_TESTS_STARTED=true
  run_phone_test testCleanup && PHONE_CLEANED_UP=true || cleanup_status=1
  exit "$cleanup_status"
fi

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
  exec python3 - "$ROOT_DIR" "$DERIVED_ROOT" "$RESULT_BUNDLE" "$SUMMARY_PATH" \
    "$DEVICE_ID" "$TEST_CLASS" "${common_args[@]}" <<'PYWORKER'
import os
import signal
import subprocess
import sys
import time

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
source "$ROOT_DIR/Scripts/icloud-smoke-support.sh"
run_phone_test testPhoneRoundTrip
'''
process = subprocess.Popen(["zsh", "-c", worker, "phone-smoke", *sys.argv[1:]], start_new_session=True)

def interrupt(signum, _frame):
    for pending in (signal.SIGINT, signal.SIGTERM): signal.signal(pending, signal.SIG_IGN)
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass
    raise SystemExit(128 + signum)

for signum in (signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, interrupt)
try:
    result = process.wait()
except SystemExit:
    deadline = float(os.environ.get('BIT101_WORKFLOW_DEADLINE', time.monotonic() + 5 * 60))
    try: process.wait(timeout=max(0, min(5 * 60, deadline - time.monotonic())))
    except subprocess.TimeoutExpired:
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait()
    raise
raise SystemExit(result if result >= 0 else 128 - result)
PYWORKER
) &
PHONE_TEST_PID=$!
MAC_LOG="$DERIVED_ROOT/mac-receive.log"
MAC_STATUS=0
MAC_TESTS_STARTED=true
rm -rf "$DERIVED_ROOT/Mac/Logs/Test"
bit101_run_logged "$MAC_LOG" "Mac Catalyst 接收测试" xcodebuild test-without-building "${common_args[@]}" \
  -test-timeouts-enabled YES \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$DERIVED_ROOT/Mac" \
  ONLY_ACTIVE_ARCH=YES \
  "-only-testing:$TEST_CLASS/testMacReceiveAndRestore" || MAC_STATUS=$?
PHONE_STATUS=0
wait "$PHONE_TEST_PID" || PHONE_STATUS=$?
PHONE_TEST_PID=""
if (( PHONE_STATUS == 0 )); then PHONE_CLEANED_UP=true; fi
record_result testMacReceiveAndRestore "$MAC_STATUS" "$MAC_LOG"
MAC_CLEANED_UP=true
exit "$PHONE_STATUS"
