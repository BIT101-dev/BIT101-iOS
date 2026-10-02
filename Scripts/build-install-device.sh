#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
DERIVED_DATA="$ROOT_DIR/build/DeviceInstall"
source "$ROOT_DIR/Scripts/script-support.sh"

ACTION="${1:-install}"
if [[ $# -gt 1 ]]; then
  echo "用法：Scripts/build-install-device.sh [build|mac|screenshot|info]" >&2
  exit 64
fi
case "$ACTION" in
  -h|--help)
    echo "Scripts/build-install-device.sh              自动选机、构建、安装并启动"
    echo "Scripts/build-install-device.sh build        编译 iOS App 与扩展"
    echo "Scripts/build-install-device.sh mac          构建并安装到本机 Mac"
    echo "Scripts/build-install-device.sh screenshot   真机截图"
    echo "Scripts/build-install-device.sh info         真机连接与锁定状态"
    exit 0
    ;;
  install|build|mac|screenshot|info) ;;
  *) echo "操作：build、mac、screenshot、info；直接运行自动装机。" >&2; exit 64 ;;
esac

if [[ "$ACTION" == screenshot || "$ACTION" == info ]]; then
  bit101_require_device || exit 1
  if [[ "$ACTION" == screenshot ]]; then
    mkdir -p "$ROOT_DIR/.build"
    xcrun devicectl device capture screenshot --device "$BIT101_DEVICETCL_DEVICE_ID" \
      --destination "$ROOT_DIR/.build/screenshot.png" --quiet
    echo "截图已保存：$ROOT_DIR/.build/screenshot.png"
  else
    xcrun devicectl device info details --device "$BIT101_DEVICETCL_DEVICE_ID" --quiet >/dev/null
    connection="无线"
    if [[ "$BIT101_DEVICE_TRANSPORT" == wired ]]; then connection="USB"; fi
    echo "真机连接：$BIT101_DEVICE_NAME · $connection"
    xcrun devicectl device info lockState --device "$BIT101_DEVICETCL_DEVICE_ID" --quiet --json-output /dev/stdout |
      python3 -c 'import json,sys; state=json.load(sys.stdin)["result"]; print("设备状态：" + ("请解锁" if state.get("passcodeRequired") else "已解锁"))'
  fi
  exit 0
fi

if [[ "$ACTION" == mac ]]; then
  mkdir -p "$DERIVED_DATA"
  bit101_run_logged "$DERIVED_DATA/build.log" "Catalyst Release 编译" xcodebuild build \
    -quiet \
    -project "$PROJECT" \
    -scheme BIT101-iOS \
    -configuration Release \
    -destination "platform=macOS,variant=Mac Catalyst" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates

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

BUILD_OVERRIDES=()
if [[ "$ACTION" == build ]]; then
  BUILD_DESTINATION="generic/platform=iOS"
  BUILD_OVERRIDES=(CODE_SIGNING_ALLOWED=NO)
else
  bit101_require_device || exit 1
  BUILD_DESTINATION="platform=iOS,id=$BIT101_XCODE_DEVICE_ID"
fi

mkdir -p "$DERIVED_DATA"
bit101_run_logged "$DERIVED_DATA/build.log" "iOS Release 编译" xcodebuild build \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Release \
  -destination "$BUILD_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${BUILD_OVERRIDES[@]}" \
    -allowProvisioningUpdates

if [[ "$ACTION" == build ]]; then
  exit 0
fi

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/BIT101-iOS.app"
xcrun devicectl device install app \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  "$APP_PATH" >/dev/null
xcrun devicectl device process launch \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  BIT101-dev.BIT101-iOS >/dev/null

echo "iOS Release 已安装并启动：$BIT101_DEVICE_NAME"
