#!/bin/zsh
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="BIT101-dev/BIT101-iOS"
WRANGLER_DIR="$ROOT_DIR/Cloudflare/EmergencyUpdateWorker"
NAMESPACE_ID="4c6402dfad4e406a93cc2518843803c6"
OUTPUT_DIR="$ROOT_DIR/.build/issue-report-inbox"
WRANGLER_LOG="$OUTPUT_DIR/wrangler.log"
CI_RUNS_PATH="$OUTPUT_DIR/github-ci-runs.json"
CI_REPORT_PATH="$OUTPUT_DIR/github-ci.json"

ACTION="${1:-fetch}"
case "$ACTION" in
  -h|--help)
    echo "用法：Scripts/fetch-issues-and-reports.sh [fetch|list|latest|show <报告键>|delete <报告键>]"
    exit 0
    ;;
  fetch|list|latest) [[ $# -le 1 ]] || exit 64 ;;
  show|delete) [[ $# -eq 2 ]] || { echo "请提供报告键。" >&2; exit 64; } ;;
  *) echo "报告操作：fetch、list、latest、show、delete。" >&2; exit 64 ;;
esac
WRANGLER="$WRANGLER_DIR/node_modules/.bin/wrangler"
mkdir -p "$OUTPUT_DIR"
export WRANGLER_LOG_PATH="$WRANGLER_LOG"
rm -f "$WRANGLER_LOG"
keys() {
  (cd "$WRANGLER_DIR" && "$WRANGLER" kv key list --remote --namespace-id "$NAMESPACE_ID" --prefix report:) > "$OUTPUT_DIR/error-report-keys.json"
  cat "$OUTPUT_DIR/error-report-keys.json"
}

latest_key() {
  keys | python3 -c 'import json,sys; rows=[x["name"] for x in json.load(sys.stdin) if x["name"].startswith("report:")]; print(max(rows, default=""))'
}

show_key() {
  local key="$1"
  [[ -n "$key" ]] || { echo "没有错误报告。" >&2; exit 1; }
  (cd "$WRANGLER_DIR" && "$WRANGLER" kv key get "$key" --remote --namespace-id "$NAMESPACE_ID" --text) | python3 -c '
import json
from pathlib import Path
import sys

item = json.load(sys.stdin)
for attachment in item.get("report", {}).get("attachments", []):
    if isinstance(attachment, dict):
        data = attachment.pop("data", None)
        if isinstance(data, str):
            attachment["bytes"] = len(data) * 3 // 4 - (len(data) - len(data.rstrip("=")))
text = json.dumps(item, ensure_ascii=False, indent=2)
report = Path(sys.argv[1]) / "error-report.json"
report.write_text(text + "\n", encoding="utf-8")
if len(text.splitlines()) <= 1000:
    print(text)
else:
    print(f"报告共 {len(text.splitlines())} 行 · {report}")
' "$OUTPUT_DIR"
}

case "$ACTION" in
  list)
    keys | python3 -c 'import json,sys; rows=[x for x in json.load(sys.stdin) if x["name"].startswith("report:")]; rows.sort(key=lambda x:x["name"], reverse=True); print("\n".join(x["name"] + " " + json.dumps(x.get("metadata",{}), ensure_ascii=False) for x in rows) if len(rows) <= 1000 else f"报告键共 {len(rows)} 条 · {sys.argv[1]}")' "$OUTPUT_DIR/error-report-keys.json"
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
    (cd "$WRANGLER_DIR" && "$WRANGLER" kv key delete "$key" --remote --namespace-id "$NAMESPACE_ID")
    ;;
  fetch) ;;
esac
if [[ "$ACTION" != fetch ]]; then exit 0; fi

STAGING_DIR="$OUTPUT_DIR/.incoming"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
rm -f "$OUTPUT_DIR/github-issues.json" "$OUTPUT_DIR/error-report-keys.json" "$OUTPUT_DIR/summary.txt" "$WRANGLER_LOG" "$CI_RUNS_PATH"

if ! gh api \
  "repos/$REPO/issues?state=open&per_page=100" \
  --jq '[.[] | select(.pull_request == null)]' \
  > "$OUTPUT_DIR/github-issues.json"; then
  echo "GitHub Issues 拉取失败，继续拉取其余报告。" >&2
  printf '[]\n' > "$OUTPUT_DIR/github-issues.json"
fi

if ! gh run list \
  --repo "$REPO" \
  --status failure \
  --limit 20 \
  --json databaseId,workflowName,displayTitle,status,conclusion,event,headBranch,headSha,createdAt,updatedAt,url \
  > "$CI_RUNS_PATH"; then
  echo "GitHub CI 失败记录拉取失败，继续拉取 Cloudflare 报告。" >&2
  printf '[]\n' > "$CI_RUNS_PATH"
fi

python3 - "$CI_RUNS_PATH" "$CI_REPORT_PATH" "$REPO" <<'PY'
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
cached_runs = {item["databaseId"]: item for item in previous if "failedLogTail" in item}

def cached_log(run):
    cached = cached_runs.get(run["databaseId"])
    if cached and all(cached.get(key) == run.get(key) for key in ("updatedAt", "headSha")):
        return cached["failedLogTail"]
    return None

def fetch_log(run):
    cached = cached_log(run)
    if cached is not None:
        return dict(run, failedLogTail=cached)
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
        item["failedLogTail"] = result.stdout[-30000:]
    else:
        item["failedLogError"] = result.stderr.strip()
    return item

with ThreadPoolExecutor(max_workers=4) as executor:
    enriched = list(executor.map(fetch_log, runs))

reused = sum(cached_log(run) is not None for run in runs)
print(f"GitHub CI 日志：复用 {reused} 份，读取 {len(runs) - reused} 份")
output_path.write_text(
    json.dumps(enriched, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

if WRANGLER_OUTPUT="$(
  (cd "$WRANGLER_DIR" && "$WRANGLER" kv key list \
    --remote \
    --prefix report: \
    --namespace-id "$NAMESPACE_ID" \
    > "$OUTPUT_DIR/error-report-keys.json") 2>&1
)"; then
  :
else
  print -r -- "$WRANGLER_OUTPUT" >> "$WRANGLER_LOG"
  tail -20 "$WRANGLER_LOG" >&2
  exit 1
fi

python3 - "$OUTPUT_DIR/error-report-keys.json" "$STAGING_DIR" "$WRANGLER_DIR" "$NAMESPACE_ID" "$OUTPUT_DIR/report-keys.txt" <<'PY'
import json
import base64
import datetime as dt
import pathlib
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

keys_path = pathlib.Path(sys.argv[1])
staging_dir = pathlib.Path(sys.argv[2])
worker_dir = pathlib.Path(sys.argv[3])
namespace_id = sys.argv[4]
processed_path = pathlib.Path(sys.argv[5])

def key_time(key):
    match = re.match(r"^report:(\d{4}-\d{2}-\d{2}T[^:]+Z):", key)
    if not match:
        return None
    try:
        return dt.datetime.fromisoformat(match.group(1).replace("Z", "+00:00"))
    except ValueError:
        return None

items = json.loads(keys_path.read_text(encoding="utf-8"))
processed = {
    line.strip()
    for line in processed_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
} if processed_path.exists() else set()
keys = [
    item["name"] for item in items
    if item.get("name", "").startswith("report:")
]
now = dt.datetime.now(dt.timezone.utc)
cutoff = now - dt.timedelta(days=7)
keys_to_fetch = []
for key in keys:
    timestamp = key_time(key)
    if timestamp is not None and timestamp < cutoff:
        continue
    if key not in processed:
        keys_to_fetch.append(key)

def fetch(key):
    result = subprocess.run(
        [
            str(worker_dir / "node_modules/.bin/wrangler"), "kv", "key", "get", key,
            "--remote", "--namespace-id", namespace_id, "--text",
        ],
        cwd=worker_dir,
        check=False,
        capture_output=True,
        text=True,
    )
    return key, result

with ThreadPoolExecutor(max_workers=4) as executor:
    fetched = list(executor.map(fetch, keys_to_fetch))

for key, result in fetched:
    filename = key.replace(":", "_") + ".json"
    if result.returncode:
        detail = result.stderr.strip()
        print(f"读取报告失败：{key}{f'：{detail}' if detail else ''}", file=sys.stderr)
        sys.exit(result.returncode or 1)
    try:
        item = json.loads(result.stdout)
        report = item.get("report", {})
    except json.JSONDecodeError:
        item = {}
        report = {}
    category = "用户建议" if report.get("mode") == "suggestion" else "错误报告"
    development = report.get("isDevelopmentBuild")
    source = "开发版" if development is True else "正式版" if development is False else "来源未知"
    category_dir = staging_dir / source / category
    category_dir.mkdir(parents=True, exist_ok=True)
    attachments = report.get("attachments", [])
    if isinstance(attachments, list) and attachments:
        attachment_dir = category_dir / f"{pathlib.Path(filename).stem}_附件"
        attachment_dir.mkdir(parents=True, exist_ok=True)
        downloaded_attachments = []
        for index, attachment in enumerate(attachments, 1):
            if not isinstance(attachment, dict) or not isinstance(attachment.get("data"), str):
                continue
            try:
                data = base64.b64decode(attachment["data"], validate=True)
            except (ValueError, base64.binascii.Error):
                continue
            content_type = attachment.get("contentType", "image/jpeg")
            extension = {"image/jpeg": ".jpg", "image/png": ".png", "image/heic": ".heic"}.get(content_type, ".bin")
            (attachment_dir / f"图片-{index:02d}{extension}").write_bytes(data)
            downloaded_attachments.append(
                {key: value for key, value in attachment.items() if key != "data"} | {"bytes": len(data)}
            )
        report["attachments"] = downloaded_attachments
        item["report"] = report
        result_text = json.dumps(item, ensure_ascii=False, indent=2)
    else:
        result_text = result.stdout
    destination = category_dir / filename
    destination.write_text(result_text, encoding="utf-8")

retained_processed = []
for key in sorted(processed.union(keys_to_fetch)):
    timestamp = key_time(key)
    if timestamp is None or timestamp >= cutoff:
        retained_processed.append(key)
processed_path.write_text(
    "\n".join(retained_processed) + ("\n" if retained_processed else ""),
    encoding="utf-8",
)
PY

find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name ".incoming" -exec rm -rf {} +
REPORT_COUNT="$(find "$STAGING_DIR" -type f -name '*.json' | wc -l | tr -d ' ')"
if [[ "$REPORT_COUNT" -gt 0 ]]; then
  for category in "开发版" "正式版" "来源未知"; do
    [[ -d "$STAGING_DIR/$category" ]] && mv "$STAGING_DIR/$category" "$OUTPUT_DIR/$category"
  done
  rm -rf "$STAGING_DIR"
else
  rm -rf "$STAGING_DIR"
fi

python3 - "$OUTPUT_DIR/error-report-keys.json" "$WRANGLER_DIR" "$NAMESPACE_ID" <<'PY'
import datetime as dt
import json
import pathlib
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

keys_path = pathlib.Path(sys.argv[1])
worker_dir = pathlib.Path(sys.argv[2])
namespace_id = sys.argv[3]

def key_time(key):
    match = re.match(r"^report:(\d{4}-\d{2}-\d{2}T[^:]+Z):", key)
    if not match:
        return None
    try:
        return dt.datetime.fromisoformat(match.group(1).replace("Z", "+00:00"))
    except ValueError:
        return None

cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=7)
keys = []
for item in json.loads(keys_path.read_text(encoding="utf-8")):
    key = item.get("name", "")
    timestamp = key_time(key)
    if key.startswith("report:") and timestamp is not None and timestamp < cutoff:
        keys.append(key)

if keys:
    print(f"[清理] {len(keys)} 条七天前的 Cloudflare 报告")

def delete(key):
    return key, subprocess.run(
        [
            str(worker_dir / "node_modules/.bin/wrangler"), "kv", "key", "delete", key,
            "--remote", "--namespace-id", namespace_id,
        ],
        cwd=worker_dir,
        check=False,
        capture_output=True,
        text=True,
    )

with ThreadPoolExecutor(max_workers=4) as executor:
    deleted = list(executor.map(delete, keys))

for key, result in deleted:
    if result.returncode:
        detail = result.stderr.strip()
        print(f"清理报告失败：{key}{f'：{detail}' if detail else ''}", file=sys.stderr)
        sys.exit(result.returncode or 1)
PY

python3 - "$OUTPUT_DIR/github-issues.json" "$OUTPUT_DIR" "$OUTPUT_DIR/summary.txt" "$REPORT_COUNT" "$CI_REPORT_PATH" <<'PY'
import json
import pathlib
import sys

issues = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
report_dir = pathlib.Path(sys.argv[2])
summary_path = pathlib.Path(sys.argv[3])
new_report_count = int(sys.argv[4])
ci_path = pathlib.Path(sys.argv[5])
ci_runs = json.loads(ci_path.read_text(encoding="utf-8")) if ci_path.exists() else []

def category_counts(folder):
    counts = {"错误报告": 0, "用户建议": 0}
    if not folder.exists():
        return counts
    for path in folder.glob("*/*/report_*.json"):
        try:
            report = json.loads(path.read_text(encoding="utf-8")).get("report", {})
        except (OSError, json.JSONDecodeError):
            continue
        category = "用户建议" if report.get("mode") == "suggestion" else "错误报告"
        counts[category] += 1
    return counts

def source_counts(folder):
    counts = {"开发版": 0, "正式版": 0, "来源未知": 0}
    if not folder.exists():
        return counts
    for source in counts:
        source_dir = folder / source
        if source_dir.exists():
            counts[source] = len(list(source_dir.glob("*/report_*.json")))
    return counts

lines = [f"GitHub Issues：{len(issues)}"]
for issue in issues:
    lines.append(f"  #{issue['number']} [{issue['state']}] {issue['title']}  {issue['url']}")
lines.append("")
lines.append(f"GitHub CI：{len(ci_runs)} 条失败运行")
for run in ci_runs:
    lines.append(
        f"  #{run.get('databaseId')} [{run.get('workflowName')}] "
        f"{run.get('displayTitle')}  {run.get('url')}"
    )
lines.append("")
current_counts = category_counts(report_dir)
current_sources = source_counts(report_dir)
lines.append(
    f"Cloudflare 报告：本次拉取 {new_report_count} 条"
    f"（错误报告 {current_counts['错误报告']}，用户建议 {current_counts['用户建议']}；"
    f"开发版 {current_sources['开发版']}，正式版 {current_sources['正式版']}，来源未知 {current_sources['来源未知']}）"
)

summary = "\n".join(lines) + "\n"
summary_path.write_text(summary, encoding="utf-8")
if len(lines) <= 1000:
    print(summary, end="")
else:
    print(f"汇总共 {len(lines)} 行 · {summary_path}")
PY

rm -f "$CI_RUNS_PATH"
