#!/bin/zsh

# 真机脚本共用的设备发现逻辑。被 source 后提供两个设备标识。

bit101_find_core_device() {
  local device_list device_line
  device_list="$(xcrun devicectl list devices 2>/dev/null || true)"
  device_line="$(printf '%s\n' "$device_list" \
    | grep -Ei 'available[[:space:]]+\(paired\)|connected' \
    | grep -Ei '(physical|iPhone|iPad)' \
    | head -n 1 || true)"
  # devicectl 使用 CoreDevice UUID，构建流程通过 device info details 映射为设备 UDID。
  BIT101_DEVICETCL_DEVICE_ID="$(printf '%s\n' "$device_line" \
    | sed -nE 's/.*[[:space:]]([0-9A-Fa-f-]+)[[:space:]]+\((UDID|CoreDevice)\).*/\1/p' \
    | head -n 1 || true)"
}

bit101_require_core_device() {
  bit101_find_core_device
  if [[ -z "$BIT101_DEVICETCL_DEVICE_ID" ]]; then
    echo "请连接并信任 iPhone 后重新运行。" >&2
    return 1
  fi
}

bit101_find_device() {
  local project="$1"
  local destinations device_details
  BIT101_XCODE_DEVICE_ID=""
  bit101_require_core_device || return 1
  destinations="$(xcodebuild -showdestinations \
    -project "$project" \
    -scheme BIT101-iOS 2>/dev/null || true)"
  device_details="$(xcrun devicectl device info details --device "$BIT101_DEVICETCL_DEVICE_ID" 2>/dev/null || true)"
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
  bit101_find_device "$project" || return 1
  if [[ -z "$BIT101_XCODE_DEVICE_ID" || -z "$BIT101_DEVICETCL_DEVICE_ID" ]]; then
    echo "未发现可用的 iPhone 真机。请连接并信任 iPhone 后重新运行。" >&2
    return 1
  fi
}
