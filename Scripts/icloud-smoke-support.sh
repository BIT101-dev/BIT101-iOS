#!/bin/zsh

record_result() {
  PYTHONPATH="$ROOT_DIR/Scripts${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SUMMARY_PATH" "$RESULT_BUNDLE" "$1" "$2" "$3" <<'PY'
import json
import os
from pathlib import Path
from datetime import datetime, timezone
import shutil
import subprocess
import sys
from validation_evidence import write_report

report_path, bundle, stage, process_status, log_path = sys.argv[1:]
exit_code = int(process_status)
row = {
    "stage": stage,
    "exitCode": exit_code,
}
generated_bundle = None
if stage in {"testCleanup", "testMacReceiveAndRestore", "testMacCleanup"}:
    host = "Phone" if stage == "testCleanup" else "Mac"
    bundles = list((Path(log_path).parent / host / "Logs/Test").glob("*.xcresult"))
    if stage == "testMacCleanup":
        bundles = [path for path in bundles if path.name != "test-results.xcresult"]
    bundle = str(bundles[0]) if len(bundles) == 1 else ""
    generated_bundle = bundles[0] if len(bundles) == 1 else None
if bundle and Path(bundle).is_dir():
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
if generated_bundle is not None:
    if row["exitCode"] == 0:
        shutil.rmtree(generated_bundle)
    else:
        retained_bundle = generated_bundle.parent / "test-results.xcresult"
        if stage == "testMacCleanup" and retained_bundle.exists():
            row["preservedResultBundle"] = str(retained_bundle)
            row["logPath"] = log_path
            shutil.rmtree(generated_bundle)
        elif generated_bundle != retained_bundle:
            if retained_bundle.exists():
                shutil.rmtree(retained_bundle)
            shutil.move(str(generated_bundle), str(retained_bundle))
            row["resultBundle"] = str(retained_bundle)
        else:
            row["resultBundle"] = str(retained_bundle)
row["recordedAt"] = datetime.now(timezone.utc).isoformat()
path = Path(report_path)
report = json.loads(path.read_text()) if path.is_file() else {"stages": []}
report["validatedDomains"] = ["score-kvs", "schedule-cloudkit"]
report["cloudKitEnvironment"] = "Production"
report["runID"] = os.environ.get("BIT101_VALIDATION_RUN_ID", "")
if stage == "testCleanup":
    report["cleanup"] = row
elif stage == "testMacCleanup":
    report["macCleanup"] = row
else:
    report["stages"].append(row)
write_report(report, path=path)
raise SystemExit(row["exitCode"])
PY
}

run_phone_test() {
  local method="$1"
  local log="$DERIVED_ROOT/$method.log"
  local result_args=()
  local test_status=0
  rm -rf "$DERIVED_ROOT/Phone/Logs/Test"
  if [[ "$method" != "testCleanup" ]]; then
    rm -rf "$RESULT_BUNDLE"
    result_args=(-resultBundlePath "$RESULT_BUNDLE")
  fi
  bit101_run_logged "$log" "$method" xcodebuild test-without-building "${common_args[@]}" \
    -test-timeouts-enabled YES \
    -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED_ROOT/Phone" \
    "${result_args[@]}" "-only-testing:$TEST_CLASS/$method" || test_status=$?
  record_result "$method" "$test_status" "$log"
}

run_mac_cleanup() {
  local log="$DERIVED_ROOT/mac-cleanup.log"
  local test_status=0
  python3 - "$DERIVED_ROOT/Mac/Logs/Test" <<'PYCLEANLOGS'
from pathlib import Path
import shutil
import sys
for path in Path(sys.argv[1]).glob('*.xcresult'):
    if path.name != 'test-results.xcresult': shutil.rmtree(path)
PYCLEANLOGS
  bit101_run_logged "$log" "Mac 本地验收清理" xcodebuild test "${common_args[@]}" \
    -test-timeouts-enabled YES -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED_ROOT/Mac" ONLY_ACTIVE_ARCH=YES \
    "-only-testing:$TEST_CLASS/testMacCleanup" || test_status=$?
  record_result testMacCleanup "$test_status" "$log"
}
