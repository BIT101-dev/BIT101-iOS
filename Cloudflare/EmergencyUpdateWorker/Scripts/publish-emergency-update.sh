#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRANGLER="$ROOT_DIR/node_modules/.bin/wrangler"
if [[ $# -eq 1 && "$1" == --disable ]]; then
  cd "$ROOT_DIR"
  "$WRANGLER" kv key put emergency-update --binding EMERGENCY_CONFIG \
    --remote --path config/emergency-update.json
  echo '紧急更新提醒已关闭。'
  exit 0
fi
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  echo '用法：./Scripts/publish-emergency-update.sh <最大受影响Build> <标题> <正文>；--disable'
  exit 0
fi

if [[ $# -ne 3 ]]; then
  echo '用法: ./Scripts/publish-emergency-update.sh <最大受影响Build> <标题> <正文>' >&2
  exit 64
fi

MAXIMUM_BUILD="$1"
TITLE="$2"
MESSAGE="$3"
[[ "$MAXIMUM_BUILD" == <-> ]] || { echo 'Build 必须是非负整数。' >&2; exit 64; }

OUTPUT="$ROOT_DIR/.generated-emergency-update.json"
NOTICE_ID="$(date -u +'%Y%m%dT%H%M%SZ')-build-$MAXIMUM_BUILD"

python3 - "$OUTPUT" "$NOTICE_ID" "$MAXIMUM_BUILD" "$TITLE" "$MESSAGE" <<'PY'
import json
import sys

path, notice_id, maximum_build, title, message = sys.argv[1:]
if int(maximum_build) > 9007199254740991 or not title.strip() or not message.strip():
    print("Build 应在 JSON 精确整数范围内，标题及正文应包含有效内容。", file=sys.stderr)
    raise SystemExit(64)
payload = {
    "schema_version": 1,
    "enabled": True,
    "notice_id": notice_id,
    "maximum_affected_build": int(maximum_build),
    "title": title,
    "message": message,
    "update_url": "https://apps.apple.com/cn/app/bit101/id6761147125",
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY

cd "$ROOT_DIR"
"$WRANGLER" kv key put emergency-update \
  --binding EMERGENCY_CONFIG \
  --remote \
  --path "$OUTPUT"

echo "紧急提醒已发布：notice_id=$NOTICE_ID, maximum_affected_build=$MAXIMUM_BUILD"
