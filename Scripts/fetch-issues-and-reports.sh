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
    echo "用法：Scripts/fetch-issues-and-reports.sh [fetch|list|latest|show <报告键>|delete <报告键>]"
    exit 0
    ;;
  fetch|list|latest) [[ $# -le 1 ]] || exit 64 ;;
  show|delete) [[ $# -eq 2 ]] || { echo "请提供报告键。" >&2; exit 64; } ;;
  *) echo "报告操作：fetch、list、latest、show、delete。" >&2; exit 64 ;;
esac
source "$ROOT_DIR/Scripts/script-support.sh"
bit101_acquire_script_lock "$OUTPUT_DIR/inbox.lock" BIT101_REPORT_INBOX_LOCK_HELD "$0" "$@"
NAMESPACE_ID="$(python3 - "$ROOT_DIR/Cloudflare/ErrorReportWorker/wrangler.jsonc" <<'PYNAMESPACE'
import json
from pathlib import Path
import sys

configuration = json.loads(Path(sys.argv[1]).read_text())
print(next(row["id"] for row in configuration["kv_namespaces"] if row["binding"] == "ERROR_REPORTS"))
PYNAMESPACE
)"
WRANGLER="$WRANGLER_DIR/node_modules/.bin/wrangler"
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
if len(text.splitlines()) <= 1000:
    print(text)
else:
    print(f"报告共 {len(text.splitlines())} 行 · {report}")
' "$report_path"
}

case "$ACTION" in
  list)
    keys >/dev/null
    python3 -c 'import json,sys; rows=[x for x in json.load(open(sys.argv[1])) if x["name"].startswith("report:")]; rows.sort(key=lambda x:x["name"], reverse=True); print("\n".join(x["name"] + " " + json.dumps(x.get("metadata",{}), ensure_ascii=False) for x in rows) if len(rows) <= 1000 else f"报告键共 {len(rows)} 条 · {sys.argv[1]}")' "$OUTPUT_DIR/error-report-keys.json"
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
    python3 - "$key" "$WRANGLER" "$WRANGLER_DIR" "$NAMESPACE_ID" "$OUTPUT_DIR/delete-authorization.json" <<'PYDELETE'
import json
from pathlib import Path
import subprocess
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import time
import uuid

key, wrangler, directory, namespace, filename = sys.argv[1:]
grant = str(uuid.uuid4())
grant_key = 'report-delete-grant:' + grant
path = Path(filename)
configuration = json.loads((Path(directory).parent / 'ErrorReportWorker/wrangler.jsonc').read_text())
domain = next(route['pattern'] for route in configuration['routes'] if route.get('custom_domain'))
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
print('报告已删除：' + key)
PYDELETE
    ;;
  fetch) ;;
esac
if [[ "$ACTION" != fetch ]]; then exit 0; fi

STAGING_DIR="$OUTPUT_DIR/.incoming"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
rm -f "$OUTPUT_DIR/error-report-keys.json" "$OUTPUT_DIR/summary.txt" "$WRANGLER_LOG" "$CI_RUNS_PATH"
FETCH_STATUS=0
ISSUES_STATE=success
CI_STATE=success

if gh api \
  "repos/$REPO/issues?state=open&per_page=100" --paginate --slurp \
  --jq '[.[][] | select(.pull_request == null)]' \
  > "$STAGING_DIR/github-issues.json"; then
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

CLOUDFLARE_STATE=success
if REPORT_COUNT="$(python3 - "$OUTPUT_DIR/error-report-keys.json" "$STAGING_DIR" "$WRANGLER_DIR" "$NAMESPACE_ID" "$OUTPUT_DIR/report-keys.txt" <<'PY'
import json
import base64
import pathlib
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

keys_path = pathlib.Path(sys.argv[1])
staging_dir = pathlib.Path(sys.argv[2])
worker_dir = pathlib.Path(sys.argv[3])
namespace_id = sys.argv[4]
processed_path = pathlib.Path(sys.argv[5])

output_dir = staging_dir.parent

items = json.loads(keys_path.read_text(encoding="utf-8"))
processed = {
    line.strip()
    for line in processed_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
} if processed_path.exists() else set()
local_reports = {path.name: path for path in output_dir.glob("*/*/report_*.json")}

def attachment_suffix(attachment):
    kind = attachment.get("contentType", "image/jpeg")
    return {"image/jpeg": ".jpg", "image/png": ".png", "image/heic": ".heic"}.get(kind, ".bin") if isinstance(kind, str) else ".bin"

def attachment_file(report_path, index, attachment):
    return report_path.parent / (report_path.stem + "_附件") / f"图片-{index:02d}{attachment_suffix(attachment)}"

def attachment_reference(attachment, asset):
    attributes = asset.stat()
    return {key: value for key, value in attachment.items() if key != "data"} | {
        "bytes": attributes.st_size, "fileModified": attributes.st_mtime_ns,
        "localFile": asset.relative_to(asset.parent.parent).as_posix()}

def compact_archived_report(path):
    incoming = staging_dir / "report.json"
    try:
        saved = json.loads(path.read_text())
        attachments = saved["report"].get("attachments", [])
        if not isinstance(attachments, list): return
        changed = False
        for index, attachment in enumerate(attachments, 1):
            if not isinstance(attachment, dict) or not isinstance(attachment.get("data"), str): continue
            asset = attachment_file(path, index, attachment)
            try:
                data = base64.b64decode(attachment["data"], validate=True)
                if asset.read_bytes() != data: continue
                attachments[index - 1] = attachment_reference(attachment, asset)
                changed = True
            except (OSError, ValueError): continue
        if changed:
            incoming.write_text(json.dumps(saved, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            incoming.replace(path)
    except (OSError, ValueError, KeyError, TypeError, AttributeError): pass
    finally:
        incoming.unlink(missing_ok=True)

for path in local_reports.values(): compact_archived_report(path)

def cache_complete(item):
    key = item["name"]
    path = local_reports.get(key.replace(":", "_") + ".json")
    if key not in processed or path is None: return False
    try:
        saved = json.loads(path.read_text())
        delivery = saved.get("emailDelivery", {})
        status = delivery.get("status")
        remote_status = item.get("metadata", {}).get("emailStatus")
        if status == "pending" or remote_status and status != remote_status: return False
        attachments = saved["report"].get("attachments", [])
        if not isinstance(attachments, list) or saved.get("inboxAttachmentErrors"): return False
        for index, attachment in enumerate(attachments, 1):
            asset = attachment_file(path, index, attachment)
            attributes = asset.stat()
            if attributes.st_size != attachment["bytes"]: return False
            if "data" in attachment:
                if asset.read_bytes() != base64.b64decode(attachment["data"], validate=True): return False
            elif attributes.st_mtime_ns != attachment["fileModified"]: return False
        return True
    except (OSError, ValueError, KeyError, TypeError, AttributeError): return False

keys_to_fetch = [item["name"] for item in items if item.get("name", "").startswith("report:") and not cache_complete(item)]

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
    filename = key.replace(":", "_") + ".json"
    if result.returncode:
        detail = result.stderr.strip()
        print(f"读取报告失败：{key}{f'：{detail}' if detail else ''}", file=sys.stderr)
        return key, False
    try:
        item = json.loads(result.stdout)
        report = item["report"]
        if not isinstance(report, dict):
            raise ValueError("report 需要对象结构")
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        print(f"报告 JSON 解析失败：{key}", file=sys.stderr)
        return key, False
    category = "用户建议" if report.get("mode") == "suggestion" else "错误报告"
    development = report.get("isDevelopmentBuild")
    source = "开发版" if development is True else "正式版" if development is False else "来源未知"
    category_dir = staging_dir / source / category
    category_dir.mkdir(parents=True, exist_ok=True)
    attachments = report.get("attachments", [])
    attachment_errors = 0
    if isinstance(attachments, list) and attachments:
        attachment_dir = category_dir / f"{pathlib.Path(filename).stem}_附件"
        attachment_dir.mkdir(parents=True, exist_ok=True)
        downloaded_attachments = []
        for index, attachment in enumerate(attachments, 1):
            if not isinstance(attachment, dict) or not isinstance(attachment.get("data"), str):
                downloaded_attachments.append({"original": attachment, "error": "附件格式异常"})
                attachment_errors += 1
                continue
            try:
                data = base64.b64decode(attachment["data"], validate=True)
            except (ValueError, base64.binascii.Error) as error:
                downloaded_attachments.append(dict(attachment, error=f"附件解码失败：{error}"))
                attachment_errors += 1
                continue
            extension = attachment_suffix(attachment)
            asset = attachment_dir / f"图片-{index:02d}{extension}"
            asset.write_bytes(data)
            downloaded_attachments.append(
                attachment_reference(attachment, asset)
            )
        report["attachments"] = downloaded_attachments
        item["report"] = report
        if attachment_errors:
            item["inboxAttachmentErrors"] = attachment_errors
        result_text = json.dumps(item, ensure_ascii=False, indent=2)
    else:
        if not isinstance(attachments, list):
            attachment_errors = 1
            item["inboxAttachmentErrors"] = 1
            result_text = json.dumps(item, ensure_ascii=False, indent=2)
        else:
            result_text = result.stdout
    destination = category_dir / filename
    destination.write_text(result_text, encoding="utf-8")
    return key, attachment_errors == 0

completed = set()
incomplete = set()
with ThreadPoolExecutor(max_workers=4) as executor:
    for key, complete in executor.map(fetch, keys_to_fetch):
        (completed if complete else incomplete).add(key)

downloaded_reports = sum(1 for _ in staging_dir.glob("*/*/report_*.json"))
for path in staging_dir.rglob("*"):
    if path.is_file():
        destination = output_dir / path.relative_to(staging_dir)
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(path, destination)
processed_path.write_text(
    "\n".join(sorted(processed.union(completed) - incomplete)) + ("\n" if processed or completed else ""),
    encoding="utf-8",
)
print(downloaded_reports)
if incomplete:
    print(f"报告处理待重试：{len(incomplete)} 份，成功内容已归档，附件错误随正文保存。", file=sys.stderr)
    sys.exit(1)
PY
)"; then
  :
else
  CLOUDFLARE_STATE=partial
  FETCH_STATUS=1
fi
rm -rf "$STAGING_DIR"

python3 - "$OUTPUT_DIR/github-issues.json" "$OUTPUT_DIR" "$OUTPUT_DIR/summary.txt" "${REPORT_COUNT:-0}" "$CI_REPORT_PATH" "$ISSUES_STATE" "$CI_STATE" "$CLOUDFLARE_STATE" <<'PY'
import json
import pathlib
import sys

issues_path = pathlib.Path(sys.argv[1])
issues = json.loads(issues_path.read_text(encoding="utf-8")) if issues_path.exists() else []
report_dir = pathlib.Path(sys.argv[2])
summary_path = pathlib.Path(sys.argv[3])
new_report_count = int(sys.argv[4])
issues_state, ci_state, cloudflare_state = sys.argv[6:9]
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

lines = [f"GitHub Issues：{len(issues)} · {issues_state}"]
for issue in issues:
    lines.append(f"  #{issue['number']} [{issue['state']}] {issue['title']}  {issue['url']}")
lines.append("")
lines.append(f"GitHub CI：{len(ci_runs)} 条失败运行 · {ci_state}")
for run in ci_runs:
    lines.append(
        f"  #{run.get('databaseId')} [{run.get('workflowName')}] "
        f"{run.get('displayTitle')}  {run.get('url')}"
    )
    diagnostic = next((line for line in run.get("failedLog", "").splitlines()
        if any(marker in line.lower() for marker in ("error:", "##[error]", "failed", "failure"))), None)
    if diagnostic:
        lines.append(f"    {diagnostic}")
lines.append("")
current_counts = category_counts(report_dir)
current_sources = source_counts(report_dir)
lines.append(
    f"Cloudflare 报告：本次拉取 {new_report_count} 条 · {cloudflare_state}"
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

exit "$FETCH_STATUS"
