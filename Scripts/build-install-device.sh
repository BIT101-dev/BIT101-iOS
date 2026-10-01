#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DeviceInstall"
source "$ROOT_DIR/Scripts/script-support.sh"

COMPILE_ONLY=false
GENERIC_BUILD=false
DEVICE_ID=""
DEVICE_ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compile-only)
      COMPILE_ONLY=true
      ;;
    --generic)
      GENERIC_BUILD=true
      ;;
    --screenshot|--device-info)
      DEVICE_ACTION="$1"
      ;;
    -h|--help)
      echo "用法：Scripts/build-install-device.sh [--compile-only [--generic]|--screenshot|--device-info] [真机设备ID]"
      exit 0
      ;;
    --*)
      echo "构建选项：--compile-only、--generic、--screenshot、--device-info。" >&2
      exit 64
      ;;
    *)
      if [[ -n "$DEVICE_ID" ]]; then
        echo "用法：Scripts/build-install-device.sh [--compile-only [--generic]|--screenshot|--device-info] [真机设备ID]" >&2
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

if [[ -n "$DEVICE_ACTION" ]]; then
  bit101_require_device "$DEVICE_ID" || exit 1
  if [[ "$DEVICE_ACTION" == --screenshot ]]; then
    mkdir -p "$ROOT_DIR/.build"
    xcrun devicectl device capture screenshot --device "$BIT101_DEVICETCL_DEVICE_ID" \
      --destination "$ROOT_DIR/.build/screenshot.png" --quiet
    echo "截图已保存：$ROOT_DIR/.build/screenshot.png"
  else
    xcrun devicectl device info details --device "$BIT101_DEVICETCL_DEVICE_ID" --quiet >/dev/null
    echo "真机连接：$BIT101_DEVICE_TRANSPORT · $BIT101_XCODE_DEVICE_ID"
  fi
  exit 0
fi

BUILD_OVERRIDES=()
for setting in SWIFT_VERSION MARKETING_VERSION; do
  variable="BIT101_$setting"
  value="${(P)variable:-}"
  [[ -z "$value" ]] || BUILD_OVERRIDES+=("$setting=$value")
done
if [[ -n "${BIT101_BUILD_NUMBER:-}" ]]; then
  BUILD_OVERRIDES+=("CURRENT_PROJECT_VERSION=$BIT101_BUILD_NUMBER")
fi

if [[ "${BIT101_INSTALL_TARGET:-iPhone}" == "macCatalyst" ]]; then
  mkdir -p "$DERIVED_DATA"
  bit101_run_logged "$DERIVED_DATA/build.log" "Catalyst Release 编译" xcodebuild build \
    -quiet \
    -project "$PROJECT" \
    -scheme BIT101-iOS \
    -configuration Release \
    -destination "platform=macOS,variant=Mac Catalyst" \
    -derivedDataPath "$DERIVED_DATA" \
    "${BUILD_OVERRIDES[@]}" \
    -allowProvisioningUpdates

  if $COMPILE_ONLY; then
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
  open "$INSTALL_PATH"
  echo "Catalyst 已安装并启动：$INSTALL_PATH"
  exit 0
fi

if $GENERIC_BUILD; then
  BUILD_DESTINATION="generic/platform=iOS"
else
  bit101_require_device "$DEVICE_ID" || exit 1
  BUILD_DESTINATION="platform=iOS,id=$BIT101_XCODE_DEVICE_ID"
fi

mkdir -p "$DERIVED_DATA"
if $GENERIC_BUILD; then
  BUILD_OVERRIDES+=("CODE_SIGNING_ALLOWED=NO")
fi
BUILD_ACTION=build
if [[ "${BIT101_BUILD_FOR_TESTING:-0}" == "1" ]]; then
  BUILD_ACTION=build-for-testing
  BUILD_OVERRIDES+=("ENABLE_TESTABILITY=YES")
fi
bit101_run_logged "$DERIVED_DATA/build.log" "iOS Release 编译" xcodebuild "$BUILD_ACTION" \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Release \
  -destination "$BUILD_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${BUILD_OVERRIDES[@]}" \
    -allowProvisioningUpdates

if $COMPILE_ONLY; then
  exit 0
fi

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/BIT101-iOS.app"
xcrun devicectl device install app \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  "$APP_PATH" >/dev/null
xcrun devicectl device process launch \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

echo "iOS Release 已安装并启动。"
