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
    destination = staging_dir / filename
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
    destination.write_text(result.stdout, encoding="utf-8")
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

python3 - "$OUTPUT_DIR/github-issues.json" "$CURRENT_DIR" "$OUTPUT_DIR/summary.txt" "$REPORT_COUNT" <<'PY'
import json
import pathlib
import sys

issues = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
report_dir = pathlib.Path(sys.argv[2])
new_report_count = int(sys.argv[4])
reports = []
if report_dir.exists():
    for path in sorted(report_dir.glob("*.json"), reverse=True):
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
            report = item.get("report", {})
            reports.append((
                item.get("receivedAt", "未知时间"),
                report.get("appVersion", "未知版本"),
                report.get("build", "未知 Build"),
                report.get("mode", "未知模式"),
                report.get("errorTitle", "未知错误"),
                path.name,
            ))
        except (OSError, json.JSONDecodeError):
            continue

lines = [f"GitHub Issues：{len(issues)}"]
for issue in issues:
    lines.append(f"  #{issue['number']} [{issue['state']}] {issue['title']}  {issue['url']}")
lines.append("")
lines.append(f"Cloudflare 错误报告：本次新增 {new_report_count} 条；当前本次批次共 {len(reports)} 条")
for received_at, version, build, mode, title, filename in reports:
    lines.append(f"  {received_at}  {version} ({build})  {mode}  {title}")
    lines.append(f"    文件：本次/{filename}")

pathlib.Path(sys.argv[3]).write_text("\n".join(lines) + "\n", encoding="utf-8")
print(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"), end="")
PY

rm -f "$WRANGLER_LOG" "$OUTPUT_DIR/report-keys.txt" "$SKIP_KEYS_FILE"
echo "本地报告目录：$OUTPUT_DIR"
