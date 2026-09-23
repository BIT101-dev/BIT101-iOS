#!/bin/zsh
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="BIT101-dev/BIT101-iOS"
WRANGLER_DIR="$ROOT_DIR/Cloudflare/EmergencyUpdateWorker"
WRANGLER_HOME="$HOME/Library/Preferences"
NAMESPACE_ID="4c6402dfad4e406a93cc2518843803c6"
OUTPUT_DIR="$ROOT_DIR/.build/issue-report-inbox"
STAGING_DIR="$OUTPUT_DIR/.incoming"
WRANGLER_LOG="$OUTPUT_DIR/wrangler.log"
CI_RUNS_PATH="$OUTPUT_DIR/github-ci-runs.json"
CI_REPORT_PATH="$OUTPUT_DIR/github-ci.json"

if ! command -v gh >/dev/null 2>&1; then
  echo "未找到 GitHub CLI：请先安装 gh 并完成 gh auth login。" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name ".incoming" -exec rm -rf {} +
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
rm -f "$OUTPUT_DIR/github-issues.json" "$OUTPUT_DIR/error-report-keys.json" "$OUTPUT_DIR/summary.txt" "$CI_RUNS_PATH" "$CI_REPORT_PATH"

echo "拉取 GitHub Issues..."
if ! gh api \
  "repos/$REPO/issues?state=open&per_page=100" \
  --jq '[.[] | select(.pull_request == null)]' \
  > "$OUTPUT_DIR/github-issues.json"; then
  echo "GitHub Issues 拉取失败，继续拉取其余报告。" >&2
  printf '[]\n' > "$OUTPUT_DIR/github-issues.json"
fi

echo "拉取 GitHub CI 失败记录..."
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

def fetch_log(run):
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

output_path.write_text(
    json.dumps(enriched, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

echo "拉取 Cloudflare 错误报告..."
if ! (cd "$WRANGLER_DIR" && HOME="$WRANGLER_HOME" npx wrangler kv key list \
  --remote \
  --prefix report: \
  --namespace-id "$NAMESPACE_ID" \
  > "$OUTPUT_DIR/error-report-keys.json" 2> "$WRANGLER_LOG"); then
  cat "$WRANGLER_LOG" >&2
  exit 1
fi

HOME="$WRANGLER_HOME" python3 - "$OUTPUT_DIR/error-report-keys.json" "$STAGING_DIR" "$WRANGLER_DIR" "$NAMESPACE_ID" "$OUTPUT_DIR/report-keys.txt" <<'PY'
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
            "npx", "--no-install", "wrangler", "kv", "key", "get", key,
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

REPORT_COUNT="$(find "$STAGING_DIR" -type f -name '*.json' | wc -l | tr -d ' ')"
if [[ "$REPORT_COUNT" -gt 0 ]]; then
  for category in "开发版" "正式版" "来源未知"; do
    [[ -d "$STAGING_DIR/$category" ]] && mv "$STAGING_DIR/$category" "$OUTPUT_DIR/$category"
  done
  rm -rf "$STAGING_DIR"
else
  rm -rf "$STAGING_DIR"
fi

HOME="$WRANGLER_HOME" python3 - "$OUTPUT_DIR/error-report-keys.json" "$WRANGLER_DIR" "$NAMESPACE_ID" <<'PY'
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
    print("清理接收时间早于 7 天的 Cloudflare 报告...")

def delete(key):
    return key, subprocess.run(
        [
            "npx", "--no-install", "wrangler", "kv", "key", "delete", key,
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

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
PY

rm -f "$WRANGLER_LOG" "$CI_RUNS_PATH"
echo "本地报告目录：$OUTPUT_DIR"
