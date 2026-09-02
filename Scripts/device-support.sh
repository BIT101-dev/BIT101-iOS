#!/bin/zsh

# 真机脚本共用的设备发现逻辑。被 source 后提供：
# BIT101_XCODE_DEVICE_ID、BIT101_DEVICETCL_DEVICE_ID、BIT101_DEVELOPER_DIR。

BIT101_DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/harrybit/Desktop/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR="$BIT101_DEVELOPER_DIR"

bit101_find_device() {
  local project="$1"
  local destinations device_list device_line

  destinations="$(xcodebuild -showdestinations \
    -project "$project" \
    -scheme BIT101-iOS 2>/dev/null || true)"
  BIT101_XCODE_DEVICE_ID="$(printf '%s\n' "$destinations" \
    | grep -E '\{ platform:iOS, arch:arm64,' \
    | sed -nE 's/.*id:([^,}]+).*/\1/p' \
    | head -n 1 || true)"

  device_list="$(xcrun devicectl list devices 2>/dev/null || true)"
  device_line="$(printf '%s\n' "$device_list" \
    | grep -E 'available.*physical' \
    | head -n 1 || true)"
  BIT101_DEVICETCL_DEVICE_ID="$(printf '%s\n' "$device_line" \
    | grep -Eo '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' \
    | head -n 1 || true)"
}

bit101_require_device() {
  local project="$1"
  bit101_find_device "$project"
  if [[ -z "$BIT101_XCODE_DEVICE_ID" || -z "$BIT101_DEVICETCL_DEVICE_ID" ]]; then
    echo "未发现可用的 iPhone 真机。请连接并信任 iPhone 后重新运行。" >&2
    return 1
  fi
}
