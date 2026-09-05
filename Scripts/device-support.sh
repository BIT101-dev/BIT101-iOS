#!/bin/zsh

# 真机脚本共用的设备发现逻辑。被 source 后提供：
# BIT101_XCODE_DEVICE_ID、BIT101_DEVICETCL_DEVICE_ID、BIT101_DEVELOPER_DIR。

BIT101_DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR="$BIT101_DEVELOPER_DIR"

bit101_find_device() {
  local project="$1"
  local destinations device_list device_line core_device_id device_details

  destinations="$(xcodebuild -showdestinations \
    -project "$project" \
    -scheme BIT101-iOS 2>/dev/null || true)"
  device_list="$(xcrun devicectl list devices 2>/dev/null || true)"
  device_line="$(printf '%s\n' "$device_list" \
    | grep -E '(connected|available).*physical' \
    | head -n 1 || true)"
  # devicectl 使用 CoreDevice UUID，xcodebuild 使用设备 UDID；两者不是同一个字符串，
  # 需要通过 device info details 映射，不能直接拿同一 ID 传给两个工具。
  core_device_id="$(printf '%s\n' "$device_line" \
    | grep -Eo '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' \
    | head -n 1 || true)"
  BIT101_DEVICETCL_DEVICE_ID="$core_device_id"
  device_details=""
  if [[ -n "$core_device_id" ]]; then
    device_details="$(xcrun devicectl device info details --device "$core_device_id" 2>/dev/null || true)"
  fi
  BIT101_XCODE_DEVICE_ID="$(printf '%s\n' "$device_details" \
    | sed -nE 's/.*UDID: ([0-9A-Fa-f-]+).*/\1/p' \
    | head -n 1 || true)"

  # xcodebuild 和 devicectl 必须使用同一台设备；分别取各自第一台设备会在多台真机
  # 同时连接或设备刚恢复连接时发生“构建 A、安装 B”的错配。
  if [[ -n "$BIT101_XCODE_DEVICE_ID" ]] && printf '%s\n' "$destinations" \
      | grep -Fq "id:$BIT101_XCODE_DEVICE_ID"; then
    :
  else
    BIT101_XCODE_DEVICE_ID=""
    BIT101_DEVICETCL_DEVICE_ID=""
  fi
}

bit101_require_device() {
  local project="$1"
  bit101_find_device "$project"
  if [[ -z "$BIT101_XCODE_DEVICE_ID" || -z "$BIT101_DEVICETCL_DEVICE_ID" ]]; then
    echo "未发现可用的 iPhone 真机。请连接并信任 iPhone 后重新运行。" >&2
    return 1
  fi
}
