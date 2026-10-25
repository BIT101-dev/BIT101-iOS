#!/bin/zsh
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="BIT101-dev/BIT101-iOS"
WRANGLER_DIR="$ROOT_DIR/Cloudflare/EmergencyUpdateWorker"
OUTPUT_DIR="$ROOT_DIR/.build/issue-report-inbox"
WRANGLER_LOG="$OUTPUT_DIR/wrangler.log"
CI_RUNS_PATH="$OUTPUT_DIR/github-ci-runs.json"
CI_REPORT_PATH="$OUTPUT_DIR/github-ci.json"

ACTION="${1:-fetch}"
case "$ACTION" in
  -h|--help)
    echo "用法：Scripts/fetch-issues-and-reports.sh [fetch|list|latest|show <报告键>|delete <报告键>|clear-archive|prune-archive <保留天数>]"
    exit 0
    ;;
  fetch|list|latest|clear-archive) [[ $# -le 1 ]] || exit 64 ;;
  prune-archive) [[ $# -eq 2 && "$2" == <-> && "$2" -gt 0 ]] || exit 64 ;;
  show|delete) [[ $# -eq 2 ]] || { echo "请提供报告键。" >&2; exit 64; } ;;
  *) echo "报告操作：fetch、list、latest、show、delete、clear-archive、prune-archive。" >&2; exit 64 ;;
esac
source "$ROOT_DIR/Scripts/script-support.sh"
bit101_acquire_script_lock "$OUTPUT_DIR/inbox.lock" BIT101_REPORT_INBOX_LOCK_HELD "$0" "$@"
if [[ "$ACTION" == clear-archive ]]; then
  python3 - "$OUTPUT_DIR" <<'PYCLEAR'
from pathlib import Path
import shutil
import sys
root = Path(sys.argv[1])
count = 0
for report in root.glob('*/*/report_*.json'):
    count += 1
for source in ('开发版', '正式版', '来源未知'):
    shutil.rmtree(root / source, ignore_errors=True)
for name in ('report-keys.txt', 'archive-index.json', 'error-report-keys.json', 'error-report.json', 'summary.txt'):
    (root / name).unlink(missing_ok=True)
print(f'本地反馈归档已清理：{count} 份。')
PYCLEAR
  exit 0
fi
if [[ "$ACTION" == prune-archive ]]; then
  prune_status=0
  python3 "$ROOT_DIR/Scripts/report_inbox.py" prune "$OUTPUT_DIR" "$2" || prune_status=$?
  rm -rf "$OUTPUT_DIR/.incoming"
  exit "$prune_status"
fi
WRANGLER="$WRANGLER_DIR/node_modules/.bin/wrangler"
load_worker_config() {
  local configuration
  configuration="$(cd "$WRANGLER_DIR" && node - "$ROOT_DIR/Cloudflare/ErrorReportWorker/wrangler.jsonc" <<'NODECONFIG'
const { experimental_readRawConfig } = require('wrangler');
const configuration = experimental_readRawConfig({ config: process.argv[2] }).rawConfig;
console.log(configuration.kv_namespaces.find(row => row.binding === 'ERROR_REPORTS').id);
console.log(configuration.routes.find(row => row.custom_domain).pattern);
NODECONFIG
)" || return $?
  WORKER_CONFIG=("${(@f)configuration}")
  [[ ${#WORKER_CONFIG} -eq 2 && -n "${WORKER_CONFIG[1]}" && -n "${WORKER_CONFIG[2]}" ]] || return 1
  NAMESPACE_ID="${WORKER_CONFIG[1]}"
  REPORT_DOMAIN="${WORKER_CONFIG[2]}"
}
mkdir -p "$OUTPUT_DIR"
export WRANGLER_LOG_PATH="$WRANGLER_LOG"
rm -f "$WRANGLER_LOG"
keys() {
  (cd "$WRANGLER_DIR" && "$WRANGLER" kv key list --remote --namespace-id "$NAMESPACE_ID" --prefix report:) > "$OUTPUT_DIR/error-report-keys.json" || return $?
  cat "$OUTPUT_DIR/error-report-keys.json"
}

latest_key() {
  keys >/dev/null || return $?
  python3 -c 'import json,sys; rows=[x["name"] for x in json.load(open(sys.argv[1])) if x["name"].startswith("report:")]; print(max(rows, default=""))' "$OUTPUT_DIR/error-report-keys.json"
}

show_key() {
  local key="$1"
  [[ -n "$key" ]] || { echo "没有错误报告。" >&2; exit 1; }
  [[ "$key" == report:* ]] || { echo "请提供 report: 开头的报告键。" >&2; return 64; }
  local report_path="$OUTPUT_DIR/error-report.json"
  (cd "$WRANGLER_DIR" && "$WRANGLER" kv key get "$key" --remote --namespace-id "$NAMESPACE_ID" --text) > "$report_path" || return $?
  python3 -c '
import json
from pathlib import Path
import sys

report = Path(sys.argv[1])
item = json.loads(report.read_text())
for attachment in item.get("report", {}).get("attachments", []):
    if isinstance(attachment, dict):
        data = attachment.pop("data", None)
        if isinstance(data, str):
            attachment["bytes"] = len(data) * 3 // 4 - (len(data) - len(data.rstrip("=")))
text = json.dumps(item, ensure_ascii=False, indent=2)
report.write_text(text + "\n", encoding="utf-8")
' "$report_path"
  python3 "$ROOT_DIR/Scripts/command_output.py" show-report "$report_path" 报告
}

if [[ "$ACTION" != fetch ]]; then load_worker_config; fi
case "$ACTION" in
  list)
    keys >/dev/null
    python3 - "$OUTPUT_DIR/error-report-keys.json" "$ROOT_DIR/Scripts" <<'PYKEYS'
import json
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[2])
from command_output import show_report_lines
path = Path(sys.argv[1])
rows = [item for item in json.loads(path.read_text()) if item['name'].startswith('report:')]
rows.sort(key=lambda item: item['name'], reverse=True)
show_report_lines((item['name'] + ' ' + json.dumps(item.get('metadata', {}), ensure_ascii=False) + '\n'
    for item in rows), path, '报告键')
PYKEYS
    ;;
  latest)
    key="$(latest_key)" || exit $?
    show_key "$key"
    ;;
  show)
    show_key "${2:-}"
    ;;
  delete)
    key="${2:-}"
    [[ "$key" == report:* ]] || { echo "请提供 report: 开头的报告键。" >&2; exit 64; }
    python3 - "$key" "$WRANGLER" "$WRANGLER_DIR" "$NAMESPACE_ID" "$OUTPUT_DIR/delete-authorization.json" "$REPORT_DOMAIN" <<'PYDELETE'
import json
from pathlib import Path
import subprocess
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import time
import uuid

key, wrangler, directory, namespace, filename, domain = sys.argv[1:]
grant = str(uuid.uuid4())
grant_key = 'report-delete-grant:' + grant
path = Path(filename)
def run(*arguments, check=True):
    return subprocess.run([wrangler, 'kv', 'key', *arguments, '--remote', '--namespace-id', namespace],
        cwd=directory, check=check, stdout=subprocess.DEVNULL)
try:
    path.write_text(json.dumps({'key': key}))
    deadline = time.monotonic() + 300
    run('put', grant_key, '--path', str(path), '--ttl', '300')
    request = Request('https://' + domain + '/api/error-reports', method='DELETE',
        data=json.dumps({'key': key, 'grant': grant}).encode(), headers={'Content-Type': 'application/json'})
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0: raise TimeoutError('删除授权达到有效期，请重新执行删除。')
        try:
            with urlopen(request, timeout=min(30, remaining)) as response:
                if json.load(response).get('deleted') is not True: raise ValueError('报告删除需要队列与存储共同确认。')
            break
        except HTTPError as error:
            remaining = deadline - time.monotonic()
            error.close()
            if error.code != 403 or remaining <= 0: raise
            time.sleep(min(30, remaining))
finally:
    run('delete', grant_key, check=False)
    path.unlink(missing_ok=True)
sys.path.insert(0, str(Path(directory).parents[1] / 'Scripts'))
from report_inbox import delete_local_report
delete_local_report(path.parent, key)
print('报告已删除：' + key)
PYDELETE
    ;;
  fetch) ;;
esac
if [[ "$ACTION" != fetch ]]; then exit 0; fi

STAGING_DIR="$OUTPUT_DIR/.incoming"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cleanup_inbox() { rm -rf "$STAGING_DIR"; rm -f "$CI_RUNS_PATH"; }
trap cleanup_inbox EXIT
rm -f "$OUTPUT_DIR/error-report-keys.json" "$OUTPUT_DIR/summary.txt" "$WRANGLER_LOG" "$CI_RUNS_PATH"
FETCH_STATUS=0
ISSUES_STATE=success
CI_STATE=success

if gh api \
  "repos/$REPO/issues?state=open&per_page=100" --paginate --slurp \
  > "$STAGING_DIR/github-issues.json" \
  && python3 "$ROOT_DIR/Scripts/report_inbox.py" issues "$STAGING_DIR/github-issues.json"; then
  mv "$STAGING_DIR/github-issues.json" "$OUTPUT_DIR/github-issues.json"
else
  echo "GitHub Issues 拉取失败，保留缓存并继续拉取其余报告。" >&2
  rm -f "$STAGING_DIR/github-issues.json"
  ISSUES_STATE=failed
  FETCH_STATUS=1
fi

if gh run list \
  --repo "$REPO" \
  --status failure \
  --limit 20 \
  --json databaseId,workflowName,displayTitle,status,conclusion,event,headBranch,headSha,createdAt,updatedAt,url \
  > "$CI_RUNS_PATH"; then

if python3 - "$CI_RUNS_PATH" "$CI_REPORT_PATH" "$REPO" <<'PY'
import json
import pathlib
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

runs_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
repo = sys.argv[3]
runs = json.loads(runs_path.read_text(encoding="utf-8"))
try:
    previous = json.loads(output_path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    previous = []
cached_runs = {item["databaseId"]: item for item in previous}

def cached_log(run):
    cached = cached_runs.get(run["databaseId"])
    if cached and "failedLog" in cached and all(cached.get(key) == run.get(key) for key in ("updatedAt", "headSha")):
        return cached["failedLog"]
    return None

def fetch_log(run):
    cached = cached_log(run)
    if cached is not None:
        return dict(run, failedLog=cached)
    result = subprocess.run(
        [
            "gh", "run", "view", str(run["databaseId"]),
            "--repo", repo,
            "--log-failed",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    item = dict(run)
    if result.returncode == 0:
        item["failedLog"] = result.stdout
    else:
        item["failedLogError"] = result.stderr.strip()
        cached = cached_runs.get(run["databaseId"], {})
        if "failedLog" in cached or "previousFailedLog" in cached:
            item["previousFailedLog"] = cached.get("failedLog", cached.get("previousFailedLog"))
    return item

with ThreadPoolExecutor(max_workers=4) as executor:
    enriched = list(executor.map(fetch_log, runs))

reused = sum(cached_log(run) is not None for run in runs)
print(f"GitHub CI 日志：复用 {reused} 份，读取 {len(runs) - reused} 份")
staged_output = output_path.parent / ".incoming" / output_path.name
staged_output.write_text(
    json.dumps(enriched, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
staged_output.replace(output_path)
if any("failedLogError" in item for item in enriched):
    sys.exit(1)
PY
then
  :
else
  CI_STATE=partial
  FETCH_STATUS=1
fi
else
  echo "GitHub CI 拉取失败，保留缓存并继续拉取 Cloudflare 报告。" >&2
  CI_STATE=failed
  FETCH_STATUS=1
fi

CLOUDFLARE_STATE=success
REPORT_COUNT=0
if load_worker_config 2> "$WRANGLER_LOG" && (
  cd "$WRANGLER_DIR"
  "$WRANGLER" kv key list --remote --prefix report: --namespace-id "$NAMESPACE_ID"
) > "$STAGING_DIR/error-report-keys.json" 2>> "$WRANGLER_LOG"; then
  mv "$STAGING_DIR/error-report-keys.json" "$OUTPUT_DIR/error-report-keys.json"
if REPORT_COUNT="$(python3 "$ROOT_DIR/Scripts/report_inbox.py" archive "$OUTPUT_DIR/error-report-keys.json" "$STAGING_DIR" "$WRANGLER_DIR" "$NAMESPACE_ID" "$OUTPUT_DIR/report-keys.txt")"; then
  :
else
  CLOUDFLARE_STATE=partial
  FETCH_STATUS=1
fi
else
  CLOUDFLARE_STATE=failed
  FETCH_STATUS=1
  tail -20 "$WRANGLER_LOG" >&2
fi

python3 "$ROOT_DIR/Scripts/report_inbox.py" summary "$OUTPUT_DIR/github-issues.json" "$OUTPUT_DIR" "$OUTPUT_DIR/summary.txt" "${REPORT_COUNT:-0}" "$CI_REPORT_PATH" "$ISSUES_STATE" "$CI_STATE" "$CLOUDFLARE_STATE"

rm -f "$CI_RUNS_PATH"

exit "$FETCH_STATUS"
