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
SMOKE_SCOPE="${BIT101_NETWORK_SMOKE_SCOPE:-all}"

case "$SMOKE_SCOPE" in
  all|bit101|school|transcript|schedule) ;;
  *) echo "BIT101_NETWORK_SMOKE_SCOPE 必须是 all、bit101、school、transcript 或 schedule。" >&2; exit 64 ;;
esac

mkdir -p "$DERIVED_DATA" "$REPORT_DIR"
rm -f "$LOG_FILE" "$BUILD_LOG"

RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
SMOKE_URL="bit101://network-smoke/$SMOKE_SCOPE?run=$RUN_ID"
REMOTE_REPORT_PATH="Library/NetworkSmoke/release-network-smoke-$RUN_ID.json"
LOCAL_REPORT_PATH="$REPORT_DIR/release-network-smoke-$RUN_ID.json"

{
  echo "发布前网络冒烟开始：scope=$SMOKE_SCOPE"
  echo "设备: $DEVICE_ID"
  echo "RunID: $RUN_ID"
  echo "先构建正式 App，再在当前 App 进程里触发 smoke。"
} | tee -a "$LOG_FILE"

echo "构建正式 App..." | tee -a "$LOG_FILE"
set +e
set -o pipefail
  xcodebuild build \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS=${pipestatus[1]}
set -e
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "构建失败，日志: $BUILD_LOG" | tee -a "$LOG_FILE" >&2
  exit $BUILD_STATUS
fi

echo "触发当前已安装的正式 App 内的网络冒烟..." | tee -a "$LOG_FILE"
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
    break
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

print(
    f"发布前网络冒烟结果: passed={passed} scope={scope} "
    f"run_id={run_id} failures={len(failures)} auth_blocked={len(auth_blocked)}"
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
