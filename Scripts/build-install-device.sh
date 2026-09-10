#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DeviceInstall"
source "$ROOT_DIR/Scripts/device-support.sh"

if [[ "${BIT101_INSTALL_TARGET:-iPhone}" == "macCatalyst" ]]; then
  mkdir -p "$DERIVED_DATA"
  BUILD_OVERRIDES=()
  if [[ -n "${BIT101_MARKETING_VERSION:-}" ]]; then
    BUILD_OVERRIDES+=("MARKETING_VERSION=$BIT101_MARKETING_VERSION")
  fi
  if [[ -n "${BIT101_BUILD_NUMBER:-}" ]]; then
    BUILD_OVERRIDES+=("CURRENT_PROJECT_VERSION=$BIT101_BUILD_NUMBER")
  fi

  echo "使用 Mac Catalyst Release 构建并安装..."
  xcodebuild build \
    -quiet \
    -project "$PROJECT" \
    -scheme BIT101-iOS \
    -configuration Release \
    -destination "platform=macOS,variant=Mac Catalyst" \
    -derivedDataPath "$DERIVED_DATA" \
    "${BUILD_OVERRIDES[@]}" \
    -allowProvisioningUpdates

  APP_PATH="$DERIVED_DATA/Build/Products/Release-maccatalyst/BIT101-iOS.app"
  INSTALL_PATH="$HOME/Applications/BIT101-iOS.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALL_PATH"
  ditto "$APP_PATH" "$INSTALL_PATH"
  echo "安装完成：$INSTALL_PATH"
  open "$INSTALL_PATH"
  echo "启动完成。"
  exit 0
fi

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
  if [[ -n "${2:-}" ]]; then
    export DEVELOPER_DIR="$2"
  elif [[ -n "${DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="$DEVELOPER_DIR"
  elif [[ -d "/Users/harrybit/Desktop/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Users/harrybit/Desktop/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer"
  fi
fi

mkdir -p "$DERIVED_DATA"
BUILD_OVERRIDES=()
if [[ -n "${BIT101_MARKETING_VERSION:-}" ]]; then
  BUILD_OVERRIDES+=("MARKETING_VERSION=$BIT101_MARKETING_VERSION")
fi
if [[ -n "${BIT101_BUILD_NUMBER:-}" ]]; then
  BUILD_OVERRIDES+=("CURRENT_PROJECT_VERSION=$BIT101_BUILD_NUMBER")
fi
echo "使用 iPhone 真机构建并安装（不执行 Archive）..."
xcodebuild build \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Release \
  -destination "platform=iOS,id=$BIT101_XCODE_DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  "${BUILD_OVERRIDES[@]}" \
  -allowProvisioningUpdates

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/BIT101-iOS.app"
xcrun devicectl device install app \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  "$APP_PATH" >/dev/null
echo "安装完成。"
xcrun devicectl device process launch \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

echo "启动完成。"
