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
report_ready=false
REPORT_DIR="$DERIVED_DATA/report"
SUMMARY_OUTPUT="$REPORT_DIR/network-smoke-summary.txt"
APP_GROUP_ID="group.BIT101-dev.BIT101-iOS.shared"
APP_BUNDLE_ID="BIT101-dev.BIT101-iOS"
SMOKE_SCOPE="${1:-all}"
SMOKE_CAPTURE="${BIT101_NETWORK_SMOKE_CAPTURE:-none}"
SMOKE_TERM="${BIT101_NETWORK_SMOKE_TERM:-}"
SMOKE_FIXTURES="${BIT101_NETWORK_SMOKE_FIXTURES:-}"
SMS_MODE="${2:-preflight}"
[[ $# -le 2 ]] || { echo "用法：Scripts/release-network-smoke.sh [范围] [sms]" >&2; exit 64; }
[[ "$SMS_MODE" == preflight || "$SMS_MODE" == sms && ( "$SMOKE_SCOPE" == school || "$SMOKE_SCOPE" == all ) ]] \
  || { echo "短信专项使用 all sms 或 school sms。" >&2; exit 64; }

case "$SMOKE_SCOPE" in
  all|bit101|school|transcript|schedule|ddl|community-writes|community-cleanup) ;;
  -h|--help)
    echo "Scripts/release-network-smoke.sh   自动选机、验证全部网络探针"
    echo "指定范围：bit101、school、transcript、schedule、ddl、community-writes、community-cleanup。"
    echo "短信专项：all sms、school sms；真实发送与验证码输入按用户授权执行。"
    echo "all、bit101、community-writes 需要 BIT101_NETWORK_SMOKE_FIXTURES 中的维护对象。"
    exit 0
    ;;
  *) echo "网络范围：all、bit101、school、transcript、schedule、ddl、community-writes、community-cleanup。" >&2; exit 64 ;;
esac
case "$SMOKE_CAPTURE" in
  ""|none|scheduleCache|rawCourseResponse) ;;
  *) echo "BIT101_NETWORK_SMOKE_CAPTURE 参数无效。" >&2; exit 64 ;;
esac
if [[ "$SMOKE_CAPTURE" == scheduleCache || "$SMOKE_CAPTURE" == rawCourseResponse ]]; then
  [[ "$SMOKE_SCOPE" == all || "$SMOKE_SCOPE" == school || "$SMOKE_SCOPE" == schedule ]] \
    || { echo "课表采样使用 all、school 或 schedule 范围。" >&2; exit 64; }
fi
if [[ -n "$SMOKE_FIXTURES" ]]; then
  python3 - "$SMOKE_FIXTURES" <<'PYFIXTURES' || { echo "BIT101_NETWORK_SMOKE_FIXTURES 需要有效的 posterID、courseID、courseNumber 和 paperID。" >&2; exit 64; }
import json
import sys
try:
    value = json.loads(sys.argv[1])
    valid = isinstance(value, dict) and all(type(value.get(key)) is int and 0 < value[key] <= 2**63 - 1
        for key in ('posterID', 'courseID', 'paperID'))
    number = value.get('courseNumber') if isinstance(value, dict) else None
    valid = valid and isinstance(number, str) and bool(number) and number == number.strip()
except (ValueError, TypeError):
    valid = False
raise SystemExit(0 if valid else 1)
PYFIXTURES
fi
if [[ "$SMOKE_SCOPE" == all || "$SMOKE_SCOPE" == bit101 || "$SMOKE_SCOPE" == community-writes ]]; then
  [[ -n "$SMOKE_FIXTURES" ]] || { echo "此范围需要 BIT101_NETWORK_SMOKE_FIXTURES 中的维护对象。" >&2; exit 64; }
fi
if [[ "$SMOKE_SCOPE" == community-writes ]]; then
  python3 -c 'import sys; value=sys.argv[1]; sys.exit(0 if len(value) <= 19 and value.isascii() and value.isdecimal() and 0 < int(value) <= 2**63 - 1 else 1)' "${BIT101_COMMUNITY_SMOKE_ACCOUNT:-}" || { echo "社区写入需要明确专用账号 BIT101_COMMUNITY_SMOKE_ACCOUNT。" >&2; exit 64; }
  python3 -c 'import sys; value=sys.argv[1]; sys.exit(0 if len(value) <= 19 and value.isascii() and value.isdecimal() and 0 < int(value) <= 2**63 - 1 else 1)' "${BIT101_COMMUNITY_FOLLOW_TARGET:-}" || { echo "社区写入需要已关注的专用目标 BIT101_COMMUNITY_FOLLOW_TARGET。" >&2; exit 64; }
fi
bit101_acquire_workflow_lock "$0" "$@"
bit101_require_device || exit 1
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
if [[ "$SMS_MODE" == sms && "$SMOKE_SCOPE" == school ]]; then validation_group=school-sms; validation_scope=full; fi
if [[ -n "$SMOKE_TERM" && ( "$SMOKE_SCOPE" == all || "$SMOKE_SCOPE" == school || "$SMOKE_SCOPE" == schedule ) ]]; then validation_scope=selected; fi
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
BIT101_VALIDATION_RUN_ID="$RUN_ID"
BIT101_VALIDATION_SOURCE_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest "$validation_group")"
SCHOOL_SMS_STARTED_DIGEST=""
if [[ "$SMS_MODE" == sms && "$SMOKE_SCOPE" == all ]]; then
  SCHOOL_SMS_STARTED_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest school-sms)"
fi
export BIT101_VALIDATION_SOURCE_DIGEST BIT101_VALIDATION_RUN_ID

mkdir -p "$DERIVED_DATA" "$REPORT_DIR"

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
  local school_sms_status=$smoke_status
  if $report_ready && (( smoke_status <= 2 )); then school_sms_status=0; fi
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
      school_sms_status=1
      echo "恢复正常 App 失败，当前设备可能仍运行网络采样宿主。" >&2
      [[ $smoke_status -eq 0 ]] && smoke_status=1
    fi
  fi
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" record "$validation_group" "$smoke_status" "$validation_scope" || smoke_status=$?
  if [[ "$SMS_MODE" == sms && "$SMOKE_SCOPE" == all ]]; then
    BIT101_VALIDATION_SOURCE_DIGEST="$SCHOOL_SMS_STARTED_DIGEST" \
      python3 "$ROOT_DIR/Scripts/validation_evidence.py" record school-sms "$school_sms_status" "$validation_scope" || smoke_status=$?
  fi
  exit "$smoke_status"
}
trap restore_normal_app EXIT ZERR
trap 'exit 130' INT
trap 'exit 143' TERM
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
  "BIT101_WORKFLOW_CONDITIONS=$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" conditions network)" \
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

python3 - "$LOCAL_REQUEST_PATH" "$SMOKE_SCOPE" "$RUN_ID" "$SMOKE_CAPTURE" "$SMOKE_TERM" "$SMS_MODE" "${BIT101_COMMUNITY_FOLLOW_TARGET:-}" "${BIT101_COMMUNITY_SMOKE_ACCOUNT:-}" "$SMOKE_FIXTURES" <<'PY'
import json
import sys

path, scope, run_id, capture, term, sms_mode, follow_target, smoke_account, fixtures = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({
        "scope": scope,
        "runID": run_id,
        "capture": capture or "none",
        "term": term or None,
        "interactiveSMS": sms_mode == "sms",
        "communityFollowTarget": int(follow_target) if scope == "community-writes" else None,
        "communityExpectedAccount": int(smoke_account) if scope == "community-writes" else None,
        "fixtures": json.loads(fixtures) if fixtures else None,
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
report_ready=true
exit $SMOKE_STATUS
