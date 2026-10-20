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
case "$ACTION" in
  install-archive)
    if [[ $# -lt 2 || $# -gt 3 || ( $# -eq 3 && "$3" != --clean ) ]]; then
      echo "用法：Scripts/build-install-device.sh install-archive <归档路径> [--clean]" >&2
      exit 64
    fi
    ;;
  *)
    if [[ $# -gt 1 ]]; then
      echo "用法：Scripts/build-install-device.sh [build|archive|archive-signed|mac|screenshot|info|toolchain]" >&2
      exit 64
    fi
    ;;
esac
case "$ACTION" in
  -h|--help)
    echo "Scripts/build-install-device.sh              自动选机、构建、安装并启动"
    echo "Scripts/build-install-device.sh build        编译 iOS App 与扩展"
    echo "Scripts/build-install-device.sh archive      编译正式归档及 dSYM"
    echo "Scripts/build-install-device.sh archive-signed 归档并签名，供 App Store 导出"
    echo "Scripts/build-install-device.sh install-archive <归档路径> [--clean] 安装并启动归档；--clean 先卸载现有 App"
    echo "Scripts/build-install-device.sh mac          构建并安装到本机 Mac"
    echo "Scripts/build-install-device.sh screenshot   真机截图"
    echo "Scripts/build-install-device.sh info         真机连接与锁定状态"
    echo "Scripts/build-install-device.sh toolchain    核对 Xcode 工具链版本"
    exit 0
    ;;
  install|install-archive|build|archive|archive-signed|mac|screenshot|info|toolchain) ;;
  *) echo "操作：build、archive、archive-signed、install-archive、mac、screenshot、info、toolchain；直接运行自动装机。" >&2; exit 64 ;;
esac

if [[ "$ACTION" == toolchain ]]; then
  version="$(xcodebuild -version)"
  printf '%s\n' "$version"
  grep -Eq '^Xcode (2[7-9]|[3-9][0-9]|[1-9][0-9]{2,})\.' <<<"$version"
  exit 0
fi

if [[ "$ACTION" == screenshot || "$ACTION" == info ]]; then
  if [[ "$ACTION" == screenshot ]]; then bit101_acquire_workflow_lock "$0" "$@"; fi
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
    lock_state="$(xcrun devicectl device info lockState --device "$BIT101_DEVICETCL_DEVICE_ID" --quiet --json-output /dev/stdout)"
    printf '%s' "$lock_state" |
      python3 -c 'import json,sys; state=json.load(sys.stdin)["result"]; print("设备状态：" + ("请解锁" if state.get("passcodeRequired") else "已解锁"))'
  fi
  exit 0
fi

if [[ "$ACTION" == install || "$ACTION" == mac || "$ACTION" == install-archive ]]; then
  bit101_acquire_workflow_lock "$0" "$@"
else
  bit101_acquire_artifact_lock "$0" "$@"
fi
if [[ "$ACTION" == install-archive ]]; then
  APP_PATH="${2:A}/Products/Applications/BIT101-iOS.app"
  if [[ ! -f "$APP_PATH/Info.plist" || ! -f "$APP_PATH/embedded.mobileprovision" ]]; then
    echo "请提供包含已签名 BIT101-iOS App 的归档。" >&2
    exit 64
  fi
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist")"
  APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist")"
  bit101_require_device || exit 1
  if [[ "${3:-}" == --clean ]]; then
    xcrun devicectl device uninstall app --device "$BIT101_DEVICETCL_DEVICE_ID" BIT101-dev.BIT101-iOS --quiet
  fi
  xcrun devicectl device install app --device "$BIT101_DEVICETCL_DEVICE_ID" "$APP_PATH" --quiet
  xcrun devicectl device process launch --device "$BIT101_DEVICETCL_DEVICE_ID" --terminate-existing \
    BIT101-dev.BIT101-iOS --quiet
  echo "归档 App 已安装并启动：$APP_VERSION ($APP_BUILD) · $BIT101_DEVICE_NAME"
  exit 0
fi
if [[ "$ACTION" == install ]]; then
  bit101_require_device || exit 1
  BIT101_VALIDATION_SOURCE_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest restore)"
  BIT101_VALIDATION_RUN_ID="$(uuidgen)"
  export BIT101_VALIDATION_SOURCE_DIGEST BIT101_VALIDATION_RUN_ID
  finish_install() {
    local install_status=$?
    trap - EXIT
    python3 "$ROOT_DIR/Scripts/validation_evidence.py" record restore "$install_status" || install_status=$?
    exit "$install_status"
  }
  trap finish_install EXIT
fi
if [[ "$ACTION" == mac ]]; then
  MAC_INPUT_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest catalyst)"
  MAC_RUN_ID="$(uuidgen)"
  MAC_READINESS="$HOME/Library/Containers/BIT101-dev.BIT101-iOS/Data/Documents/restore-readiness.json"
  mkdir -p "$DERIVED_DATA"
  bit101_run_logged "$DERIVED_DATA/build.log" "Catalyst Release 编译" xcodebuild build \
    -quiet \
    -project "$PROJECT" \
    -scheme BIT101-iOS \
    -configuration Release \
    -destination "platform=macOS,variant=Mac Catalyst" \
    -derivedDataPath "$DERIVED_DATA" \
    BIT101_WORKFLOW_CONDITIONS= SWIFT_ACTIVE_COMPILATION_CONDITIONS= \
    "BIT101_RESTORE_INPUT_DIGEST=$MAC_INPUT_DIGEST" \
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
  bit101_install_mac_app "$APP_PATH" "$INSTALL_PATH"
  open -n "$INSTALL_PATH" --args --restore-run-id "$MAC_RUN_ID"
  mac_deadline=$(( SECONDS + 60 ))
  while (( SECONDS < mac_deadline )); do
    if python3 "$ROOT_DIR/Scripts/validation_restore.py" mac-ready "$INSTALL_PATH" "$MAC_READINESS" "$MAC_RUN_ID" "$MAC_INPUT_DIGEST"; then
      echo "Catalyst 初始化与活跃进程已确认：$INSTALL_PATH"
      exit 0
    fi
    sleep 1
  done
  echo "Catalyst 就绪验收超时，请检查启动与登录恢复状态。" >&2
  exit 1
fi

BUILD_OVERRIDES=()
if [[ "$ACTION" == install ]]; then
  BUILD_OVERRIDES+=("BIT101_RESTORE_INPUT_DIGEST=$BIT101_VALIDATION_SOURCE_DIGEST")
  rm -f "$DERIVED_DATA/restore-readiness.json" "$DERIVED_DATA/restore-process.json"
fi
BUILD_ACTION=build
if [[ "$ACTION" == build || "$ACTION" == archive || "$ACTION" == archive-signed ]]; then
  BUILD_DESTINATION="generic/platform=iOS"
  if [[ "$ACTION" != archive-signed ]]; then BUILD_OVERRIDES=(CODE_SIGNING_ALLOWED=NO); fi
else
  bit101_require_device || exit 1
  BUILD_DESTINATION="platform=iOS,id=$BIT101_XCODE_DEVICE_ID"
fi
if [[ "$ACTION" == archive || "$ACTION" == archive-signed ]]; then
  BUILD_ACTION=archive
  BUILD_OVERRIDES+=(-archivePath "$DERIVED_DATA/BIT101-iOS.xcarchive")
  BIT101_VALIDATION_SOURCE_DIGEST="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest build-archive)"
  BIT101_VALIDATION_RUN_ID="$(uuidgen)"
  export BIT101_VALIDATION_SOURCE_DIGEST BIT101_VALIDATION_RUN_ID
  BUILD_OVERRIDES+=("BIT101_ARCHIVE_INPUT_DIGEST=$BIT101_VALIDATION_SOURCE_DIGEST" "BIT101_ARCHIVE_RUN_ID=$BIT101_VALIDATION_RUN_ID")
  rm -rf "$DERIVED_DATA/BIT101-iOS.xcarchive"
  finish_archive() {
    local archive_status=$?
    trap - EXIT
    python3 "$ROOT_DIR/Scripts/validation_evidence.py" record build-archive "$archive_status" || archive_status=$?
    exit "$archive_status"
  }
  trap finish_archive EXIT
fi

mkdir -p "$DERIVED_DATA"
bit101_run_logged "$DERIVED_DATA/build.log" "iOS Release 编译" xcodebuild "$BUILD_ACTION" \
  -quiet \
  -project "$PROJECT" \
  -scheme BIT101-iOS \
  -configuration Release \
  -destination "$BUILD_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  BIT101_WORKFLOW_CONDITIONS= SWIFT_ACTIVE_COMPILATION_CONDITIONS= \
  "${BUILD_OVERRIDES[@]}" \
    -allowProvisioningUpdates

if [[ "$ACTION" == build || "$ACTION" == archive || "$ACTION" == archive-signed ]]; then
  exit 0
fi

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/BIT101-iOS.app"
bit101_invalidate_restore
xcrun devicectl device install app \
  --device "$BIT101_DEVICETCL_DEVICE_ID" \
  "$APP_PATH" >/dev/null
xcrun devicectl device process launch \
  --device "$BIT101_DEVICETCL_DEVICE_ID" --terminate-existing \
  BIT101-dev.BIT101-iOS -- --restore-run-id "$BIT101_VALIDATION_RUN_ID" >/dev/null
restore_deadline=$(( SECONDS + 60 ))
while (( SECONDS < restore_deadline )); do
  if xcrun devicectl device copy from --device "$BIT101_DEVICETCL_DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier BIT101-dev.BIT101-iOS \
      --source Documents/restore-readiness.json --destination "$DERIVED_DATA/restore-readiness.json" >/dev/null 2>&1; then
    xcrun devicectl device info processes --device "$BIT101_DEVICETCL_DEVICE_ID" \
      --quiet --json-output "$DERIVED_DATA/restore-process.json" >/dev/null
    if python3 "$ROOT_DIR/Scripts/validation_restore.py" "$BIT101_VALIDATION_RUN_ID" "$BIT101_VALIDATION_SOURCE_DIGEST"; then
      echo "iOS Release 初始化与活跃进程已确认：$BIT101_DEVICE_NAME"
      exit 0
    fi
  fi
  sleep 1
done
echo "正式 App 就绪验收超时；请检查 build/DeviceInstall 的构建、就绪与进程证据。" >&2
exit 1
