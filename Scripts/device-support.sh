#!/bin/zsh

# 真机脚本共用设备快照，按有线、无线顺序选择，并提供同一设备的两种标识。

bit101_device_snapshot() {
  xcrun devicectl list devices --quiet --json-output /dev/stdout
}

bit101_find_device() {
  local requested_device="${1:-}"
  local snapshot selection
  local -a identifiers
  BIT101_XCODE_DEVICE_ID=""
  BIT101_DEVICETCL_DEVICE_ID=""
  BIT101_DEVICE_TRANSPORT=""
  snapshot="$(bit101_device_snapshot)" || return 1
  selection="$(print -r -- "$snapshot" | python3 -c '
import json
import sys

requested = sys.argv[1].upper()
candidates = []
for device in json.load(sys.stdin)["result"]["devices"]:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    identifier = device.get("identifier", "")
    udid = hardware.get("udid", "")
    transport = connection.get("transportType")
    if hardware.get("reality") != "physical" or hardware.get("deviceType") not in {"iPhone", "iPad"}:
        continue
    if connection.get("pairingState") != "paired" or connection.get("tunnelState") not in {"connected", "disconnected"}:
        continue
    if transport not in {"wired", "localNetwork"} or not identifier or not udid:
        continue
    if requested and requested not in {identifier.upper(), udid.upper()}:
        continue
    candidates.append((transport != "wired", identifier, udid, transport))

if candidates:
    selected = min(candidates, key=lambda candidate: candidate[0])
    print("\n".join(selected[1:]))
' "$requested_device")" || return 1
  [[ -n "$selection" ]] || return 1
  identifiers=("${(@f)selection}")
  BIT101_DEVICETCL_DEVICE_ID="${identifiers[1]}"
  BIT101_XCODE_DEVICE_ID="${identifiers[2]}"
  BIT101_DEVICE_TRANSPORT="${identifiers[3]}"
}

bit101_require_device() {
  if bit101_find_device "${1:-}"; then
    return 0
  fi
  echo "请将${1:+设备 $1 对应的}已配对 iPhone 通过 USB 或同一局域网连接到 Mac 后重新运行。" >&2
  return 1
}

# 直接执行时通过读取设备详情验证所选连接。
if [[ "$ZSH_EVAL_CONTEXT" == "toplevel" ]]; then
  set -euo pipefail
  if [[ $# -gt 1 ]]; then
    echo "用法：Scripts/device-support.sh [真机设备ID]" >&2
    exit 64
  fi
  bit101_require_device "${1:-}" || exit 1
  xcrun devicectl device info details --device "$BIT101_DEVICETCL_DEVICE_ID" --quiet >/dev/null
  echo "真机连接验证通过：$BIT101_DEVICE_TRANSPORT · $BIT101_XCODE_DEVICE_ID"
fi
