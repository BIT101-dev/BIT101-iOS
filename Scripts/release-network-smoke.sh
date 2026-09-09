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
    echo "用法: $0 [真机设备ID] [Developer目录]" >&2
    exit 64
  fi
  DEVICE_ID="$1"
  export DEVELOPER_DIR="${2:-${DEVELOPER_DIR:-/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer}}"
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

case "$SMOKE_SCOPE" in
  all|bit101|school|transcript|schedule) ;;
  *) echo "BIT101_NETWORK_SMOKE_SCOPE 必须是 all、bit101、school、transcript 或 schedule。" >&2; exit 64 ;;
esac
case "$SMOKE_CAPTURE" in
  ""|courseHistory|cachedCourseHistory) ;;
  *) echo "BIT101_NETWORK_SMOKE_CAPTURE 必须为空、courseHistory 或 cachedCourseHistory。" >&2; exit 64 ;;
esac

mkdir -p "$DERIVED_DATA" "$REPORT_DIR"

RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
SMOKE_URL="bit101://network-smoke/$SMOKE_SCOPE?run=$RUN_ID"
if [[ -n "$SMOKE_CAPTURE" ]]; then
  SMOKE_URL="${SMOKE_URL}&capture=${SMOKE_CAPTURE}"
fi
REMOTE_REPORT_PATH="Library/NetworkSmoke/release-network-smoke.json"
REMOTE_FIXTURE_PATH="course-history-audit-fixture.json"
LOCAL_FIXTURE_PATH="$ROOT_DIR/BIT101-iOSTests/CourseHistoryAuditFixture.json"
LOCAL_REPORT_PATH="$REPORT_DIR/release-network-smoke.json"
rm -f "$LOG_FILE" "$BUILD_LOG" "$LOCAL_REPORT_PATH"

restore_normal_app() {
  DEVELOPER_DIR="$DEVELOPER_DIR" "$ROOT_DIR/Scripts/build-install-device.sh" >/dev/null 2>&1 || true
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
xcrun devicectl device install app \
  --device "$DEVICETCL_DEVICE_ID" \
  "$SMOKE_APP_PATH" >/dev/null
xcrun devicectl device process launch \
  --device "$DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

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

echo "触发当前已安装的网络采样宿主..." | tee -a "$LOG_FILE"
xcrun devicectl device process openURL \
  --device "$DEVICETCL_DEVICE_ID" \
  "$SMOKE_URL" \
  --activate | tee -a "$LOG_FILE"

echo "等待结果文件..." | tee -a "$LOG_FILE"
MAX_ATTEMPTS=300
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
  sleep 2
done

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

print(
    f"发布前网络冒烟结果: passed={passed} scope={scope} "
    f"run_id={run_id} failures={len(failures)} auth_blocked={len(auth_blocked)}"
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
