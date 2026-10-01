#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"

if [[ $# -gt 1 ]]; then
  echo "用法: $0 [真机设备ID]" >&2
  exit 64
fi
source "$ROOT_DIR/Scripts/device-support.sh"
bit101_require_device "${1:-}" || exit 1
DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
DEVICETCL_DEVICE_ID="$BIT101_DEVICETCL_DEVICE_ID"

DERIVED_DATA="$ROOT_DIR/.build/release-network-smoke"
BUILD_LOG="$DERIVED_DATA/build.log"
REPORT_DIR="$DERIVED_DATA/report"
SUMMARY_OUTPUT="$REPORT_DIR/network-smoke-summary.txt"
APP_GROUP_ID="group.BIT101-dev.BIT101-iOS.shared"
APP_BUNDLE_ID="BIT101-dev.BIT101-iOS"
SMOKE_SCOPE="${BIT101_NETWORK_SMOKE_SCOPE:-all}"
SMOKE_CAPTURE="${BIT101_NETWORK_SMOKE_CAPTURE:-none}"
SMOKE_TERM="${BIT101_NETWORK_SMOKE_TERM:-}"

case "$SMOKE_SCOPE" in
  all|bit101|school|transcript|schedule|ddl) ;;
  *) echo "BIT101_NETWORK_SMOKE_SCOPE 必须是 all、bit101、school、transcript、schedule 或 ddl。" >&2; exit 64 ;;
esac
case "$SMOKE_CAPTURE" in
  ""|none|scheduleCache|rawCourseResponse) ;;
  *) echo "BIT101_NETWORK_SMOKE_CAPTURE 参数无效。" >&2; exit 64 ;;
esac

mkdir -p "$DERIVED_DATA" "$REPORT_DIR"

RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
REMOTE_REPORT_PATH="Library/NetworkSmoke/release-network-smoke.json"
REMOTE_RAW_COURSE_PATH="Library/NetworkSmoke/raw-course-response.json"
LOCAL_REPORT_PATH="$REPORT_DIR/release-network-smoke.json"
LOCAL_RAW_COURSE_PATH="$REPORT_DIR/raw-course-response.json"
LOCAL_REQUEST_PATH="$REPORT_DIR/network-smoke-request.json"
rm -f "$BUILD_LOG" "$SUMMARY_OUTPUT" "$LOCAL_REPORT_PATH" "$LOCAL_RAW_COURSE_PATH" "$LOCAL_REQUEST_PATH"

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

restore_normal_app() {
  local smoke_status=$?
  if ! BIT101_INSTALL_TARGET=iPhone "$ROOT_DIR/Scripts/build-install-device.sh" "$DEVICE_ID" >/dev/null 2>&1; then
    echo "恢复正常 App 失败，当前设备可能仍运行网络采样宿主。" >&2
    [[ $smoke_status -eq 0 ]] && smoke_status=1
  fi
  return $smoke_status
}
if [[ "${BIT101_DEFER_APP_RESTORE:-0}" != "1" ]]; then
  trap restore_normal_app EXIT
fi

echo "发布前网络冒烟开始：scope=$SMOKE_SCOPE"
echo "设备: $DEVICE_ID"
echo "RunID: $RUN_ID"
echo "先构建 Release 网络采样宿主，再在当前 App 进程里触发 smoke。"

echo "构建 Release 网络采样宿主..."
if run_with_output_threshold "$BUILD_LOG" "Release 网络采样构建输出" xcodebuild build \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Release \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=RELEASE_NETWORK_SMOKE" \
  -allowProvisioningUpdates; then
  BUILD_STATUS=0
else
  BUILD_STATUS=$?
fi
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "构建失败。" >&2
  exit $BUILD_STATUS
fi

SMOKE_APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/BIT101-iOS.app"
echo "安装网络数据采样宿主..."
xcrun devicectl device install app \
  --device "$DEVICETCL_DEVICE_ID" \
  "$SMOKE_APP_PATH" >/dev/null

python3 - "$LOCAL_REQUEST_PATH" "$SMOKE_SCOPE" "$RUN_ID" "$SMOKE_CAPTURE" "$SMOKE_TERM" <<'PY'
import json
import sys

path, scope, run_id, capture, term = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({
        "scope": scope,
        "runID": run_id,
        "capture": capture or "none",
        "term": term or None,
    }, stream)
PY
xcrun devicectl device copy to \
  --device "$DEVICETCL_DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$APP_BUNDLE_ID" \
  --source "$LOCAL_REQUEST_PATH" \
  --destination "Documents/network-smoke-request.json" >/dev/null

echo "启动网络数据采样宿主..."
xcrun devicectl device process launch \
  --device "$DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

echo "等待结果文件..."
MAX_ATTEMPTS=1800
for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
  if xcrun devicectl device copy from \
    --device "$DEVICETCL_DEVICE_ID" \
    --domain-type appGroupDataContainer \
    --domain-identifier "$APP_GROUP_ID" \
    --source "$REMOTE_REPORT_PATH" \
    --destination "$LOCAL_REPORT_PATH" >/dev/null 2>&1; then
    if python3 - "$LOCAL_REPORT_PATH" "$RUN_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)

sys.exit(0 if report.get("runID") == sys.argv[2] else 1)
PY
    then
      break
    fi
  fi
  if [[ $attempt -eq $MAX_ATTEMPTS ]]; then
    echo "未在超时时间内拿到冒烟结果文件：$REMOTE_REPORT_PATH" >&2
    exit 1
  fi
  sleep 1
done

if [[ "$SMOKE_CAPTURE" == "rawCourseResponse" ]]; then
  if ! xcrun devicectl device copy from \
    --device "$DEVICETCL_DEVICE_ID" \
    --domain-type appGroupDataContainer \
    --domain-identifier "$APP_GROUP_ID" \
    --source "$REMOTE_RAW_COURSE_PATH" \
    --destination "$LOCAL_RAW_COURSE_PATH" >/dev/null 2>&1; then
    echo "未读取到原始课表响应：$REMOTE_RAW_COURSE_PATH" >&2
    exit 1
  fi
  echo "原始课表响应已保存：$LOCAL_RAW_COURSE_PATH"
fi

if SUMMARY_OUTPUT_TEXT="$(python3 - "$LOCAL_REPORT_PATH" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    report = json.load(stream)

passed = bool(report.get("passed"))
failures = report.get("failures", [])
auth_blocked = report.get("authenticationBlockers", [])
scope = report.get("scope")
run_id = report.get("runID")
executed = report.get("executedProbes", [])
skipped = report.get("skippedProbes", [])
sms_coverage = report.get("schoolSMSCoverage", "unknown")
coverage_gaps = report.get("coverageGaps", [])
coverage_complete = not coverage_gaps

print(
    f"发布前网络冒烟结果: passed={passed} scope={scope} "
    f"run_id={run_id} failures={len(failures)} auth_blocked={len(auth_blocked)} "
    f"coverage_complete={coverage_complete} coverage_gaps={len(coverage_gaps)} skipped={len(skipped)} "
    f"executed={len(executed)} sms_coverage={sms_coverage}"
)
if failures:
    print("网络或业务失败：")
    for line in failures:
        print(line)
if auth_blocked:
    print("需要人工认证：")
    for line in auth_blocked:
        print(line)
if coverage_gaps:
    print("验证覆盖不完整：")
    for line in coverage_gaps:
        print(line)

sys.exit(0 if passed and coverage_complete else 1 if not passed else 2)
PY
)"; then
  SMOKE_STATUS=0
else
  SMOKE_STATUS=$?
fi
emit_output "$SUMMARY_OUTPUT" "网络冒烟结果" "$SUMMARY_OUTPUT_TEXT"
exit $SMOKE_STATUS
