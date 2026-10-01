#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"

source "$ROOT_DIR/Scripts/script-support.sh"

DERIVED_DATA="$ROOT_DIR/.build/release-network-smoke"
BUILD_LOG="$DERIVED_DATA/build.log"
REPORT_DIR="$DERIVED_DATA/report"
SUMMARY_OUTPUT="$REPORT_DIR/network-smoke-summary.txt"
APP_GROUP_ID="group.BIT101-dev.BIT101-iOS.shared"
APP_BUNDLE_ID="BIT101-dev.BIT101-iOS"
SMOKE_SCOPE="${BIT101_NETWORK_SMOKE_SCOPE:-all}"
SMOKE_CAPTURE="${BIT101_NETWORK_SMOKE_CAPTURE:-none}"
SMOKE_TERM="${BIT101_NETWORK_SMOKE_TERM:-}"
DEVICE_ID=""
while (( $# > 0 )); do
  case "$1" in
    --scope)
      [[ $# -ge 2 ]] || { echo "--scope 后填写探针范围。" >&2; exit 64; }
      SMOKE_SCOPE="$2"
      shift 2
      ;;
    -h|--help)
      echo "用法：Scripts/release-network-smoke.sh [--scope all|bit101|school|transcript|schedule|ddl] [真机设备ID]"
      exit 0
      ;;
    --*) echo "网络 Smoke 选项：--scope 范围。" >&2; exit 64 ;;
    *)
      [[ -z "$DEVICE_ID" ]] || { echo "请提供一个真机设备 ID。" >&2; exit 64; }
      DEVICE_ID="$1"
      shift
      ;;
  esac
done

case "$SMOKE_SCOPE" in
  all|bit101|school|transcript|schedule|ddl) ;;
  *) echo "BIT101_NETWORK_SMOKE_SCOPE 必须是 all、bit101、school、transcript、schedule 或 ddl。" >&2; exit 64 ;;
esac
case "$SMOKE_CAPTURE" in
  ""|none|scheduleCache|rawCourseResponse) ;;
  *) echo "BIT101_NETWORK_SMOKE_CAPTURE 参数无效。" >&2; exit 64 ;;
esac
bit101_require_device "$DEVICE_ID" || exit 1
DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
DEVICETCL_DEVICE_ID="$BIT101_DEVICETCL_DEVICE_ID"

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
  printf '%s\n' "$output" > "$output_path"
  if (( ${#${(f)output}} <= 1000 )); then
    print -r -- "$output"
  else
    echo "[输出] $label 共 ${#${(f)output}} 行 · $output_path"
  fi
}

restore_normal_app() {
  local smoke_status=$?
  trap - EXIT ZERR INT TERM
  if ! BIT101_INSTALL_TARGET=iPhone "$ROOT_DIR/Scripts/build-install-device.sh" "$DEVICE_ID" >/dev/null 2>&1; then
    echo "恢复正常 App 失败，当前设备可能仍运行网络采样宿主。" >&2
    [[ $smoke_status -eq 0 ]] && smoke_status=1
  fi
  exit "$smoke_status"
}
if [[ "${BIT101_DEFER_APP_RESTORE:-0}" != "1" ]]; then
  trap restore_normal_app EXIT ZERR
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi

echo "[网络 Smoke] $SMOKE_SCOPE · $BIT101_DEVICE_TRANSPORT · $DEVICE_ID"
if bit101_run_logged "$BUILD_LOG" "Release 网络采样构建输出" xcodebuild build \
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

xcrun devicectl device process launch \
  --device "$DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

echo "[探针] 执行 $SMOKE_SCOPE"
DEADLINE=$(( SECONDS + 1800 ))
REPORT_READY=false
while (( SECONDS < DEADLINE )); do
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
      REPORT_READY=true
      break
    fi
  fi
  sleep 1
done
if ! $REPORT_READY; then
  echo "网络 Smoke 等待超过 30 分钟：$REMOTE_REPORT_PATH" >&2
  exit 1
fi

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
executed = report.get("executedProbes", [])
sms_coverage = report.get("schoolSMSCoverage", "unknown")
coverage_gaps = report.get("coverageGaps", [])
coverage_complete = not coverage_gaps

state = "通过" if passed and coverage_complete else "失败" if not passed else "覆盖待补齐"
print(f"网络 Smoke：{scope} · {state} · {len(executed)} 项探针")
if scope in {"all", "school", "transcript"}:
    print(f"学校短信覆盖：{sms_coverage}")
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
