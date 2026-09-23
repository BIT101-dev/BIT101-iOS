#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DeviceInstall"
source "$ROOT_DIR/Scripts/device-support.sh"

COMPILE_ONLY=false
DEVICE_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compile-only)
      COMPILE_ONLY=true
      ;;
    -h|--help)
      echo "用法：Scripts/build-install-device.sh [--compile-only] [真机设备ID]"
      exit 0
      ;;
    *)
      if [[ -n "$DEVICE_ID" ]]; then
        echo "用法：Scripts/build-install-device.sh [--compile-only] [真机设备ID]" >&2
        exit 64
      fi
      DEVICE_ID="$1"
      ;;
  esac
  shift
done

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

  if $COMPILE_ONLY; then
    echo "Mac Catalyst 编译完成。"
    exit 0
  fi

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

if [[ -z "$DEVICE_ID" ]]; then
  bit101_require_device "$PROJECT" || {
    echo "用法：Scripts/build-install-device.sh [--compile-only] [真机设备ID]" >&2
    exit 1
  }
else
  BIT101_XCODE_DEVICE_ID="$DEVICE_ID"
  BIT101_DEVICETCL_DEVICE_ID="$DEVICE_ID"
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

if $COMPILE_ONLY; then
  echo "iPhone Release 编译完成。"
  exit 0
fi

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/BIT101-iOS.app"
xcrun devicectl device install app \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  "$APP_PATH" >/dev/null
echo "安装完成。"
xcrun devicectl device process launch \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

echo "启动完成。"
