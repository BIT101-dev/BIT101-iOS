#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo '用法: ./Scripts/publish-emergency-update.sh <最大受影响Build> <标题> <正文>' >&2
  exit 64
fi

MAXIMUM_BUILD="$1"
TITLE="$2"
MESSAGE="$3"
[[ "$MAXIMUM_BUILD" == <-> ]] || { echo 'Build 必须是非负整数。' >&2; exit 64; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT_DIR/.generated-emergency-update.json"
NOTICE_ID="$(date -u +'%Y%m%dT%H%M%SZ')-build-$MAXIMUM_BUILD"

python3 - "$OUTPUT" "$NOTICE_ID" "$MAXIMUM_BUILD" "$TITLE" "$MESSAGE" <<'PY'
import json
import sys

path, notice_id, maximum_build, title, message = sys.argv[1:]
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
npx wrangler kv key put emergency-update \
  --binding EMERGENCY_CONFIG \
  --remote \
  --path "$OUTPUT"

echo "紧急提醒已发布：notice_id=$NOTICE_ID, maximum_affected_build=$MAXIMUM_BUILD"
