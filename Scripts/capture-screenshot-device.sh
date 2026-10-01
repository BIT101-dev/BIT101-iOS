#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "用法: $0 [真机设备ID]" >&2
  exit 64
fi

source "$ROOT_DIR/Scripts/device-support.sh"
bit101_require_device "${1:-}" || exit 1
DEVICE_ID="$BIT101_DEVICETCL_DEVICE_ID"

DESTINATION="$ROOT_DIR/.build/screenshot.png"

mkdir -p "$ROOT_DIR/.build"
xcrun devicectl device capture screenshot \
  --device "$DEVICE_ID" \
  --destination "$DESTINATION" \
  --quiet

echo "截图已保存：$DESTINATION"
