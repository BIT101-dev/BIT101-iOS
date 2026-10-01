#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DeviceInstall"
source "$ROOT_DIR/Scripts/device-support.sh"

COMPILE_ONLY=false
GENERIC_BUILD=false
DEVICE_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compile-only)
      COMPILE_ONLY=true
      ;;
    --generic)
      GENERIC_BUILD=true
      ;;
    -h|--help)
      echo "用法：Scripts/build-install-device.sh [--compile-only [--generic]] [真机设备ID]"
      exit 0
      ;;
    *)
      if [[ -n "$DEVICE_ID" ]]; then
        echo "用法：Scripts/build-install-device.sh [--compile-only [--generic]] [真机设备ID]" >&2
        exit 64
      fi
      DEVICE_ID="$1"
      ;;
  esac
  shift
done

if $GENERIC_BUILD; then
  $COMPILE_ONLY && [[ -z "$DEVICE_ID" ]] || {
    echo "通用 iOS 编译使用 --compile-only --generic。" >&2
    exit 64
  }
fi

filter_build_output() {
  awk '
    /^[[:space:]]*$/ { next }
    /^Failed frontend command:/ { next }
    /^\/Applications\/.*swift-frontend / { next }
    /^note: Removed stale file / { next }
    { print; fflush() }
  '
}

if [[ "${BIT101_INSTALL_TARGET:-iPhone}" == "macCatalyst" ]]; then
  mkdir -p "$DERIVED_DATA"
  BUILD_OVERRIDES=()
  if [[ -n "${BIT101_SWIFT_VERSION:-}" ]]; then
    BUILD_OVERRIDES+=("SWIFT_VERSION=$BIT101_SWIFT_VERSION")
  fi
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
    -allowProvisioningUpdates 2>&1 | filter_build_output

  if $COMPILE_ONLY; then
    echo "Mac Catalyst 编译完成。"
    exit 0
  fi

  APP_PATH="$DERIVED_DATA/Build/Products/Release-maccatalyst/BIT101-iOS.app"
  INSTALL_PATH="$HOME/Applications/BIT101-iOS.app"
  RUNNING_APP_PIDS=($(pgrep -f "^${INSTALL_PATH}/Contents/MacOS/BIT101-iOS$" || true))
  for APP_PID in "${RUNNING_APP_PIDS[@]}"; do
    kill -TERM "$APP_PID"
    for ((attempt = 0; attempt < 50; attempt++)); do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
      echo "应用仍在退出，请稍后重新运行装机脚本。" >&2
      exit 1
    fi
  done
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALL_PATH"
  ditto "$APP_PATH" "$INSTALL_PATH"
  echo "安装完成：$INSTALL_PATH"
  open "$INSTALL_PATH"
  echo "启动完成。"
  exit 0
fi

if $GENERIC_BUILD; then
  BUILD_DESTINATION="generic/platform=iOS"
else
  bit101_require_device "$DEVICE_ID" || exit 1
  BUILD_DESTINATION="platform=iOS,id=$BIT101_XCODE_DEVICE_ID"
fi

mkdir -p "$DERIVED_DATA"
BUILD_OVERRIDES=()
if [[ -n "${BIT101_SWIFT_VERSION:-}" ]]; then
  BUILD_OVERRIDES+=("SWIFT_VERSION=$BIT101_SWIFT_VERSION")
fi
if [[ -n "${BIT101_MARKETING_VERSION:-}" ]]; then
  BUILD_OVERRIDES+=("MARKETING_VERSION=$BIT101_MARKETING_VERSION")
fi
if [[ -n "${BIT101_BUILD_NUMBER:-}" ]]; then
  BUILD_OVERRIDES+=("CURRENT_PROJECT_VERSION=$BIT101_BUILD_NUMBER")
fi
if $GENERIC_BUILD; then
  BUILD_OVERRIDES+=("CODE_SIGNING_ALLOWED=NO")
  echo "使用通用 iOS Release 编译..."
else
  echo "使用 iPhone Release 构建..."
fi
BUILD_ACTION=build
if [[ "${BIT101_BUILD_FOR_TESTING:-0}" == "1" ]]; then
  BUILD_ACTION=build-for-testing
  BUILD_OVERRIDES+=("ENABLE_TESTABILITY=YES")
fi
xcodebuild "$BUILD_ACTION" \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Release \
  -destination "$BUILD_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${BUILD_OVERRIDES[@]}" \
    -allowProvisioningUpdates 2>&1 | filter_build_output

if $COMPILE_ONLY; then
  echo "iOS Release 编译完成。"
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
