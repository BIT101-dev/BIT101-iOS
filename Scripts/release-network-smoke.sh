#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"

if [[ $# -eq 0 ]]; then
  source "$ROOT_DIR/Scripts/device-support.sh"
  bit101_require_device "$PROJECT" || exit 1
  DEVICE_ID="$BIT101_XCODE_DEVICE_ID"
  DEVICETCL_DEVICE_ID="$BIT101_DEVICETCL_DEVICE_ID"
else
  if [[ $# -gt 2 ]]; then
    echo "用法: $0 [真机设备ID]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
  DEVICETCL_DEVICE_ID="$DEVICE_ID"
fi

DERIVED_DATA="$ROOT_DIR/.build/release-network-smoke"
LOG_FILE="$DERIVED_DATA/network-smoke.log"
BUILD_LOG="$DERIVED_DATA/build.log"
REPORT_DIR="$DERIVED_DATA/report"
APP_GROUP_ID="group.BIT101-dev.BIT101-iOS.shared"
APP_BUNDLE_ID="BIT101-dev.BIT101-iOS"
SMOKE_SCOPE="${BIT101_NETWORK_SMOKE_SCOPE:-all}"
SMOKE_CAPTURE="${BIT101_NETWORK_SMOKE_CAPTURE:-cachedCourseHistory}"
SMOKE_TERM="${BIT101_NETWORK_SMOKE_TERM:-}"

case "$SMOKE_SCOPE" in
  all|bit101|school|transcript|schedule|ddl) ;;
  *) echo "BIT101_NETWORK_SMOKE_SCOPE 必须是 all、bit101、school、transcript、schedule 或 ddl。" >&2; exit 64 ;;
esac
case "$SMOKE_CAPTURE" in
  ""|courseHistory|cachedCourseHistory|scheduleCache|rawCourseResponse) ;;
  *) echo "BIT101_NETWORK_SMOKE_CAPTURE 参数无效。" >&2; exit 64 ;;
esac

mkdir -p "$DERIVED_DATA" "$REPORT_DIR"

RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
REMOTE_REPORT_PATH="Library/NetworkSmoke/release-network-smoke.json"
REMOTE_RAW_COURSE_PATH="Library/NetworkSmoke/raw-course-response.json"
REMOTE_FIXTURE_PATH="course-history-audit-fixture.json"
LOCAL_FIXTURE_PATH="$ROOT_DIR/BIT101-iOSTests/CourseHistoryAuditFixture.json"
LOCAL_REPORT_PATH="$REPORT_DIR/release-network-smoke.json"
LOCAL_RAW_COURSE_PATH="$REPORT_DIR/raw-course-response.json"
LOCAL_REQUEST_PATH="$REPORT_DIR/network-smoke-request.json"
rm -f "$LOG_FILE" "$BUILD_LOG" "$LOCAL_REPORT_PATH" "$LOCAL_RAW_COURSE_PATH" "$LOCAL_REQUEST_PATH"

restore_normal_app() {
  local smoke_status=$?
  if ! "$ROOT_DIR/Scripts/build-install-device.sh" >/dev/null 2>&1; then
    echo "恢复正常 App 失败，当前设备可能仍运行网络采样宿主。" >&2
    [[ $smoke_status -eq 0 ]] && smoke_status=1
  fi
  return $smoke_status
}
trap restore_normal_app EXIT

{
  echo "发布前网络冒烟开始：scope=$SMOKE_SCOPE"
  echo "设备: $DEVICE_ID"
  echo "RunID: $RUN_ID"
  echo "先构建 Release 网络采样宿主，再在当前 App 进程里触发 smoke。"
} | tee -a "$LOG_FILE"

echo "构建 Release 网络采样宿主..." | tee -a "$LOG_FILE"
set +e
set -o pipefail
  xcodebuild build \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Release \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=RELEASE_NETWORK_SMOKE" \
  -allowProvisioningUpdates 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS=${pipestatus[1]}
set -e
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "构建失败，日志: $BUILD_LOG" | tee -a "$LOG_FILE" >&2
  exit $BUILD_STATUS
fi

SMOKE_APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/BIT101-iOS.app"
echo "安装网络数据采样宿主..." | tee -a "$LOG_FILE"
xcrun devicectl device process terminate \
  --device "$DEVICETCL_DEVICE_ID" \
  "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun devicectl device install app \
  --device "$DEVICETCL_DEVICE_ID" \
  "$SMOKE_APP_PATH" >/dev/null

if [[ "$SMOKE_CAPTURE" == "cachedCourseHistory" ]]; then
  if [[ ! -f "$LOCAL_FIXTURE_PATH" ]]; then
    echo "课程历史缓存文件不存在：$LOCAL_FIXTURE_PATH" | tee -a "$LOG_FILE" >&2
    exit 1
  fi
  echo "写入课程历史缓存数据..." | tee -a "$LOG_FILE"
  xcrun devicectl device copy to \
    --device "$DEVICETCL_DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$APP_BUNDLE_ID" \
    --source "$LOCAL_FIXTURE_PATH" \
    --destination "Documents/$REMOTE_FIXTURE_PATH" >/dev/null
fi

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

echo "启动网络数据采样宿主..." | tee -a "$LOG_FILE"
xcrun devicectl device process launch \
  --device "$DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

echo "等待结果文件..." | tee -a "$LOG_FILE"
MAX_ATTEMPTS=90
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
    echo "未在超时时间内拿到冒烟结果文件：$REMOTE_REPORT_PATH" | tee -a "$LOG_FILE" >&2
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
    echo "未读取到原始课表响应：$REMOTE_RAW_COURSE_PATH" | tee -a "$LOG_FILE" >&2
    exit 1
  fi
  echo "原始课表响应已保存：$LOCAL_RAW_COURSE_PATH" | tee -a "$LOG_FILE"
fi

python3 - "$LOCAL_REPORT_PATH" <<'PY' | tee -a "$LOG_FILE"
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
metrics = report.get("courseHistoryAuditMetrics")
executed = report.get("executedProbes", [])
skipped = report.get("skippedProbes", [])
sms_coverage = report.get("schoolSMSCoverage", "unknown")

print(
    f"发布前网络冒烟结果: passed={passed} scope={scope} "
    f"run_id={run_id} failures={len(failures)} auth_blocked={len(auth_blocked)} "
    f"skipped={len(skipped)} "
    f"executed={len(executed)} sms_coverage={sms_coverage}"
)
if metrics:
    true_positive = metrics.get('truePositive', 0)
    false_positive = metrics.get('falsePositive', 0)
    false_negative = metrics.get('falseNegative', 0)
    precision = true_positive / (true_positive + false_positive) if true_positive + false_positive else 0
    recall = true_positive / (true_positive + false_negative) if true_positive + false_negative else 0
    print(
        "课程历史标签匹配: "
        f"predicted={metrics.get('predictedCandidateCount', 0)} "
        f"tp={true_positive} fp={false_positive} fn={false_negative} "
        f"precision={precision * 100:.1f}% recall={recall * 100:.1f}%"
    )
if failures:
    print("网络或业务失败：")
    for line in failures:
        print(line)
if auth_blocked:
    print("需要人工认证：")
    for line in auth_blocked:
        print(line)

sys.exit(0 if passed else 1)
PY
