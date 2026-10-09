#!/bin/zsh

record_result() {
  python3 - "$SUMMARY_PATH" "$RESULT_BUNDLE" "$1" "$2" "$3" <<'PY'
import json
import os
from pathlib import Path
from datetime import datetime, timezone
import shutil
import subprocess
import sys

report_path, bundle, stage, process_status, log_path = sys.argv[1:]
exit_code = int(process_status)
row = {
    "stage": stage,
    "exitCode": exit_code,
}
generated_bundle = None
if stage in {"testCleanup", "testMacReceiveAndRestore"}:
    host = "Mac" if stage == "testMacReceiveAndRestore" else "Phone"
    bundles = list((Path(log_path).parent / host / "Logs/Test").glob("*.xcresult"))
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
        if generated_bundle != retained_bundle:
            if retained_bundle.exists():
                shutil.rmtree(retained_bundle)
            shutil.move(str(generated_bundle), str(retained_bundle))
        row["resultBundle"] = str(retained_bundle)
row["recordedAt"] = datetime.now(timezone.utc).isoformat()
path = Path(report_path)
report = json.loads(path.read_text()) if path.is_file() else {"stages": []}
report["validatedDomains"] = ["score-kvs", "schedule-cloudkit"]
report["cloudKitEnvironment"] = "Production"
report["runID"] = os.environ.get("BIT101_VALIDATION_RUN_ID", "")
if stage == "testCleanup":
    report["cleanup"] = row
else:
    report["stages"].append(row)
path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
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
