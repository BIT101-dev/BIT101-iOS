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
CONSOLE_LOG="$DERIVED_DATA/console.log"
console_process=""
community_started=false
REPORT_DIR="$DERIVED_DATA/report"
SUMMARY_OUTPUT="$REPORT_DIR/network-smoke-summary.txt"
APP_GROUP_ID="group.BIT101-dev.BIT101-iOS.shared"
APP_BUNDLE_ID="BIT101-dev.BIT101-iOS"
SMOKE_SCOPE="${1:-all}"
SMOKE_CAPTURE="${BIT101_NETWORK_SMOKE_CAPTURE:-none}"
SMOKE_TERM="${BIT101_NETWORK_SMOKE_TERM:-}"
SMS_MODE="${2:-preflight}"
[[ $# -le 2 ]] || { echo "用法：Scripts/release-network-smoke.sh [范围] [sms]" >&2; exit 64; }
[[ "$SMS_MODE" == preflight || "$SMS_MODE" == sms && "$SMOKE_SCOPE" == school ]] \
  || { echo "短信专项使用 school sms。" >&2; exit 64; }

case "$SMOKE_SCOPE" in
  all|bit101|school|transcript|schedule|ddl|community-writes|community-cleanup) ;;
  -h|--help)
    echo "Scripts/release-network-smoke.sh   自动选机、验证全部网络探针"
    echo "指定范围：bit101、school、transcript、schedule、ddl、community-writes、community-cleanup。"
    echo "短信专项：school sms；真实发送与验证码输入按用户授权执行。"
    exit 0
    ;;
  *) echo "网络范围：all、bit101、school、transcript、schedule、ddl、community-writes、community-cleanup。" >&2; exit 64 ;;
esac
case "$SMOKE_CAPTURE" in
  ""|none|scheduleCache|rawCourseResponse) ;;
  *) echo "BIT101_NETWORK_SMOKE_CAPTURE 参数无效。" >&2; exit 64 ;;
esac
bit101_acquire_workflow_lock "$0" "$@"
BIT101_VALIDATION_SOURCE_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest)"
export BIT101_VALIDATION_SOURCE_DIGEST
validation_group=network
validation_scope=full
if [[ "$SMOKE_SCOPE" == community-writes ]]; then
  validation_group=community-writes
elif [[ "$SMOKE_SCOPE" == community-cleanup ]]; then
  validation_group=community-cleanup
elif [[ "$SMOKE_SCOPE" == ddl ]]; then
  validation_group=ddl
elif [[ "$SMOKE_SCOPE" != all ]]; then
  validation_scope=selected
fi
if [[ "$SMS_MODE" == sms ]]; then validation_group=school-sms; validation_scope=full; fi

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
  if [[ -n "$console_process" ]]; then kill "$console_process" 2>/dev/null || true; wait "$console_process" 2>/dev/null || true; fi
  if $community_started && [[ "$SMOKE_SCOPE" == community-writes ]] && (( smoke_status != 0 )); then
    echo "[社区清理] 读取待清理记录并确认服务端结果"
    if ! python3 - "$ROOT_DIR/Scripts" "$ROOT_DIR/Scripts/release-network-smoke.sh" "$DERIVED_DATA" "$RUN_ID" "$smoke_status" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from validation_evidence import recover_community_smoke
raise SystemExit(recover_community_smoke(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], int(sys.argv[5])))
PY
    then
      echo "社区清理待完成，设备恢复记录保留全部待清理对象；恢复连接后执行 community-cleanup。" >&2
      smoke_status=1
    fi
  fi
  if [[ "${BIT101_DEFER_APP_RESTORE:-0}" != "1" ]]; then
    local restore_status=0
    if ! "$ROOT_DIR/Scripts/build-install-device.sh" >/dev/null 2>&1; then
      restore_status=1
      echo "恢复正常 App 失败，当前设备可能仍运行网络采样宿主。" >&2
      [[ $smoke_status -eq 0 ]] && smoke_status=1
    fi
    python3 "$ROOT_DIR/Scripts/validation_evidence.py" record restore "$restore_status" || smoke_status=$?
  fi
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" record "$validation_group" "$smoke_status" "$validation_scope" || smoke_status=$?
  exit "$smoke_status"
}
trap restore_normal_app EXIT ZERR
trap 'exit 130' INT
trap 'exit 143' TERM
bit101_require_device || exit 1
DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
DEVICETCL_DEVICE_ID="$BIT101_DEVICETCL_DEVICE_ID"

echo "[网络 Smoke] $SMOKE_SCOPE · $BIT101_DEVICE_NAME"
if bit101_run_logged "$BUILD_LOG" "Release 网络采样构建输出" xcodebuild build \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Release \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  "BIT101_WORKFLOW_CONDITIONS=RELEASE_NETWORK_SMOKE" \
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

python3 - "$LOCAL_REQUEST_PATH" "$SMOKE_SCOPE" "$RUN_ID" "$SMOKE_CAPTURE" "$SMOKE_TERM" "$SMS_MODE" <<'PY'
import json
import sys

path, scope, run_id, capture, term, sms_mode = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({
        "scope": scope,
        "runID": run_id,
        "capture": capture or "none",
        "term": term or None,
        "interactiveSMS": sms_mode == "sms",
    }, stream)
PY
xcrun devicectl device copy to \
  --device "$DEVICETCL_DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$APP_BUNDLE_ID" \
  --source "$LOCAL_REQUEST_PATH" \
  --destination "Documents/network-smoke-request.json" >/dev/null

: > "$CONSOLE_LOG"
if [[ "$SMOKE_SCOPE" == community-writes ]]; then community_started=true; fi
xcrun devicectl device process launch \
  --device "$DEVICETCL_DEVICE_ID" \
  --console \
  BIT101-dev.BIT101-iOS > "$CONSOLE_LOG" 2>&1 &
console_process=$!

echo "[探针] 执行 $SMOKE_SCOPE"
DEADLINE=$(( SECONDS + 1800 ))
REPORT_READY=false
while (( SECONDS < DEADLINE )); do
  if rg -q "NETWORK_SMOKE_REPORT_WRITE_FAIL run_id=$RUN_ID" "$CONSOLE_LOG"; then
    echo "网络 Smoke 报告写入失败 · $CONSOLE_LOG" >&2
    exit 1
  fi
  if ! kill -0 "$console_process" 2>/dev/null; then
    echo "网络 Smoke 控制台进程已结束 · $CONSOLE_LOG" >&2
    exit 1
  fi
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
  python3 - "$LOCAL_RAW_COURSE_PATH" "$RUN_ID" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    capture = json.load(stream)
if capture.get("runID") != sys.argv[2] or "response" not in capture:
    raise SystemExit("原始课表采样需要匹配本次运行标记和响应正文。")
PY
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
