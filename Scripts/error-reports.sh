#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_DIR="$ROOT_DIR/Cloudflare/ErrorReportWorker"
NAMESPACE_ID="4c6402dfad4e406a93cc2518843803c6"
ACTION="${1:-latest}"

keys() {
  (cd "$WORKER_DIR" && npx wrangler kv key list --remote --namespace-id "$NAMESPACE_ID")
}

latest_key() {
  keys | python3 -c 'import json,sys; rows=[x["name"] for x in json.load(sys.stdin) if x["name"].startswith("report:")]; print(max(rows, default=""))'
}

show_key() {
  local key="$1"
  [[ -n "$key" ]] || { echo "没有错误报告。" >&2; exit 1; }
  (cd "$WORKER_DIR" && npx wrangler kv key get "$key" --remote --namespace-id "$NAMESPACE_ID" --text) | python3 -m json.tool
}

case "$ACTION" in
  list)
    keys | python3 -c 'import json,sys; rows=[x for x in json.load(sys.stdin) if x["name"].startswith("report:")]; [print(x["name"], json.dumps(x.get("metadata",{}), ensure_ascii=False)) for x in sorted(rows, key=lambda x:x["name"], reverse=True)]'
    ;;
  latest)
    show_key "$(latest_key)"
    ;;
  show)
    show_key "${2:-}"
    ;;
  delete)
    key="${2:-}"
    [[ "$key" == report:* ]] || { echo "请提供 report: 开头的报告键。" >&2; exit 64; }
    (cd "$WORKER_DIR" && npx wrangler kv key delete "$key" --remote --namespace-id "$NAMESPACE_ID")
    ;;
  *)
    echo "用法: $0 {list|latest|show <key>|delete <key>}" >&2
    exit 64
    ;;
esac
