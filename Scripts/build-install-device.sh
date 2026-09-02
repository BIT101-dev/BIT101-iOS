#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DeviceInstall"
source "$ROOT_DIR/Scripts/device-support.sh"

if [[ $# -eq 0 ]]; then
  bit101_require_device "$PROJECT" || {
    echo "用法：直接运行 Scripts/build-install-device.sh，无需参数。" >&2
    exit 1
  }
else
  if [[ $# -gt 2 ]]; then
    echo "用法：Scripts/build-install-device.sh [真机设备ID] [Developer目录]" >&2
    exit 64
  fi
  BIT101_XCODE_DEVICE_ID="$1"
  BIT101_DEVICETCL_DEVICE_ID="$1"
  export DEVELOPER_DIR="${2:-${DEVELOPER_DIR:-/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer}}"
fi

mkdir -p "$DERIVED_DATA"
echo "使用 iPhone 真机构建并安装（不执行 Archive）..."
xcodebuild build \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Debug \
  -destination "platform=iOS,id=$BIT101_XCODE_DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/BIT101-iOS.app"
xcrun devicectl device install app \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  "$APP_PATH" >/dev/null
echo "安装完成。"
xcrun devicectl device process launch \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

echo "启动完成。"
