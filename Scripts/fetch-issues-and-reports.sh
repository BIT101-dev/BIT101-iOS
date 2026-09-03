#!/bin/zsh
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="BIT101-dev/BIT101-iOS"
WORKER_DIR="$ROOT_DIR/Cloudflare/ErrorReportWorker"
NAMESPACE_ID="4c6402dfad4e406a93cc2518843803c6"
OUTPUT_DIR="$ROOT_DIR/.build/issue-report-inbox"
CURRENT_DIR="$OUTPUT_DIR/本次"
PREVIOUS_DIR="$OUTPUT_DIR/上次"
OLDER_DIR="$OUTPUT_DIR/上上次"
STAGING_DIR="$OUTPUT_DIR/.incoming"
WRANGLER_LOG="$OUTPUT_DIR/wrangler.log"
SKIP_KEYS_FILE="$OUTPUT_DIR/.skip-report-keys"

if ! command -v gh >/dev/null 2>&1; then
  echo "未找到 GitHub CLI：请先安装 gh 并完成 gh auth login。" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGING_DIR" "$OUTPUT_DIR/error-reports"
mkdir -p "$STAGING_DIR"
rm -f "$OUTPUT_DIR/github-issues.json" "$OUTPUT_DIR/error-report-keys.json" "$OUTPUT_DIR/summary.txt" "$OUTPUT_DIR/report-keys.txt"

python3 - "$CURRENT_DIR" "$PREVIOUS_DIR" "$OLDER_DIR" "$SKIP_KEYS_FILE" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[-1])
keys = set()
for folder_name in sys.argv[1:-1]:
    folder = Path(folder_name)
    if not folder.exists():
        continue

    manifest = folder / ".keys"
    if manifest.exists():
        keys.update(line.strip() for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip())
        continue

    derived = []
    for report in folder.glob("report_*.json"):
        stem = report.stem[len("report_"):]
        try:
            timestamp, report_id = stem.rsplit("_", 1)
        except ValueError:
            continue
        derived.append(f"report:{timestamp.replace('_', ':')}:{report_id}")
    if derived:
        manifest.write_text("\n".join(sorted(derived)) + "\n", encoding="utf-8")
        keys.update(derived)

output.write_text("\n".join(sorted(keys)) + ("\n" if keys else ""), encoding="utf-8")
PY

echo "拉取 GitHub Issues..."
gh issue list \
  --repo "$REPO" \
  --state open \
  --limit 100 \
  --json number,title,state,author,createdAt,updatedAt,url,labels \
  > "$OUTPUT_DIR/github-issues.json"

echo "拉取 Cloudflare 错误报告..."
if ! (cd "$WORKER_DIR" && npx wrangler kv key list \
  --remote \
  --prefix report: \
  --namespace-id "$NAMESPACE_ID" \
  > "$OUTPUT_DIR/error-report-keys.json" 2> "$WRANGLER_LOG"); then
  cat "$WRANGLER_LOG" >&2
  exit 1
fi

python3 - "$OUTPUT_DIR/error-report-keys.json" "$STAGING_DIR" "$WORKER_DIR" "$NAMESPACE_ID" "$OUTPUT_DIR/report-keys.txt" "$SKIP_KEYS_FILE" <<'PY'
import json
import base64
import pathlib
import subprocess
import sys

keys_path = pathlib.Path(sys.argv[1])
staging_dir = pathlib.Path(sys.argv[2])
worker_dir = pathlib.Path(sys.argv[3])
namespace_id = sys.argv[4]
keys_output = pathlib.Path(sys.argv[5])
skip_path = pathlib.Path(sys.argv[6])

items = json.loads(keys_path.read_text(encoding="utf-8"))
skip = {line.strip() for line in skip_path.read_text(encoding="utf-8").splitlines() if line.strip()}
keys = [
    item["name"] for item in items
    if item.get("name", "").startswith("report:") and item["name"] not in skip
]
keys_output.write_text("\n".join(keys) + ("\n" if keys else ""), encoding="utf-8")

for key in keys:
    filename = key.replace(":", "_") + ".json"
    result = subprocess.run(
        [
            "npx", "wrangler", "kv", "key", "get", key,
            "--remote", "--namespace-id", namespace_id, "--text",
        ],
        cwd=worker_dir,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        print(f"读取报告失败：{key}", file=sys.stderr)
        sys.exit(result.returncode or 1)
    try:
        item = json.loads(result.stdout)
        report = item.get("report", {})
    except json.JSONDecodeError:
        item = {}
        report = {}
    category = "用户建议" if report.get("mode") == "suggestion" else "错误报告"
    category_dir = staging_dir / category
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
PY

REPORT_COUNT="$(find "$STAGING_DIR" -type f -name '*.json' | wc -l | tr -d ' ')"
if [[ "$REPORT_COUNT" -gt 0 ]]; then
  rm -rf "$OLDER_DIR"
  [[ -d "$PREVIOUS_DIR" ]] && mv "$PREVIOUS_DIR" "$OLDER_DIR"
  [[ -d "$CURRENT_DIR" ]] && mv "$CURRENT_DIR" "$PREVIOUS_DIR"
  cp "$OUTPUT_DIR/report-keys.txt" "$STAGING_DIR/.keys"
  mv "$STAGING_DIR" "$CURRENT_DIR"

  echo "清理已拉取的 Cloudflare 错误报告..."
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if ! (cd "$WORKER_DIR" && npx wrangler kv key delete "$key" \
      --remote --namespace-id "$NAMESPACE_ID" >/dev/null 2> "$WRANGLER_LOG"); then
      cat "$WRANGLER_LOG" >&2
      echo "报告已保存在本地，远端未完整清理：$key" >&2
      exit 1
    fi
  done < "$OUTPUT_DIR/report-keys.txt"
else
  rmdir "$STAGING_DIR"
fi

python3 - "$OUTPUT_DIR/github-issues.json" "$CURRENT_DIR" "$OUTPUT_DIR/summary.txt" "$REPORT_COUNT" "$PREVIOUS_DIR" "$OLDER_DIR" <<'PY'
import json
import pathlib
import sys

issues = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
report_dir = pathlib.Path(sys.argv[2])
new_report_count = int(sys.argv[4])
previous_dir = pathlib.Path(sys.argv[5])
older_dir = pathlib.Path(sys.argv[6])

def category_counts(folder):
    counts = {"错误报告": 0, "用户建议": 0}
    if not folder.exists():
        return counts
    for path in folder.rglob("*.json"):
        try:
            report = json.loads(path.read_text(encoding="utf-8")).get("report", {})
        except (OSError, json.JSONDecodeError):
            continue
        category = "用户建议" if report.get("mode") == "suggestion" else "错误报告"
        counts[category] += 1
    return counts

lines = [f"GitHub Issues：{len(issues)}"]
for issue in issues:
    lines.append(f"  #{issue['number']} [{issue['state']}] {issue['title']}  {issue['url']}")
lines.append("")
previous_count = len(list(previous_dir.rglob("*.json"))) if previous_dir.exists() else 0
older_count = len(list(older_dir.rglob("*.json"))) if older_dir.exists() else 0
current_counts = category_counts(report_dir)
previous_counts = category_counts(previous_dir)
older_counts = category_counts(older_dir)
lines.append(
    f"Cloudflare 报告：本次新增 {new_report_count} 条"
    f"（错误报告 {current_counts['错误报告']}，用户建议 {current_counts['用户建议']}）"
)
lines.append(
    f"上次批次：{previous_count} 条"
    f"（错误报告 {previous_counts['错误报告']}，用户建议 {previous_counts['用户建议']}）"
)
lines.append(
    f"上上次批次：{older_count} 条"
    f"（错误报告 {older_counts['错误报告']}，用户建议 {older_counts['用户建议']}）"
)

pathlib.Path(sys.argv[3]).write_text("\n".join(lines) + "\n", encoding="utf-8")
print(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"), end="")
PY

rm -f "$WRANGLER_LOG" "$OUTPUT_DIR/report-keys.txt" "$SKIP_KEYS_FILE"
echo "本地报告目录：$OUTPUT_DIR"
