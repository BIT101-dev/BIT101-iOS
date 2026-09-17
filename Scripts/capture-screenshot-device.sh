#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${1:-00008150-001129041146401C}"
DESTINATION="$ROOT_DIR/.build/screenshot.png"

mkdir -p "$ROOT_DIR/.build"
xcrun devicectl device capture screenshot \
  --device "$DEVICE_ID" \
  --destination "$DESTINATION" \
  --quiet

echo "截图已保存：$DESTINATION"
