#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
npx wrangler kv key put emergency-update \
  --binding EMERGENCY_CONFIG \
  --remote \
  --path config/emergency-update.json

echo '紧急更新提醒已关闭。'
