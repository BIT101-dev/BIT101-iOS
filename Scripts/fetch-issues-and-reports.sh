#!/bin/zsh
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="BIT101-dev/BIT101-iOS"
WORKER_DIR="$ROOT_DIR/Cloudflare/ErrorReportWorker"
NAMESPACE_ID="4c6402dfad4e406a93cc2518843803c6"
OUTPUT_DIR="$ROOT_DIR/.build/issue-report-inbox"
REPORT_DIR="$OUTPUT_DIR/error-reports"

if ! command -v gh >/dev/null 2>&1; then
  echo "未找到 GitHub CLI：请先安装 gh 并完成 gh auth login。" >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"
rm -f "$OUTPUT_DIR/github-issues.json" "$OUTPUT_DIR/error-report-keys.json" "$OUTPUT_DIR/summary.txt"

echo "拉取 GitHub Issues..."
gh issue list \
  --repo "$REPO" \
  --state all \
  --limit 100 \
  --json number,title,state,author,createdAt,updatedAt,url,labels \
  > "$OUTPUT_DIR/github-issues.json"

echo "拉取 Cloudflare 错误报告..."
(cd "$WORKER_DIR" && npx wrangler kv key list \
  --remote \
  --prefix report: \
  --namespace-id "$NAMESPACE_ID") \
  > "$OUTPUT_DIR/error-report-keys.json"

python3 - "$OUTPUT_DIR/error-report-keys.json" "$REPORT_DIR" "$WORKER_DIR" "$NAMESPACE_ID" <<'PY'
import json
import pathlib
import subprocess
import sys

keys_path = pathlib.Path(sys.argv[1])
report_dir = pathlib.Path(sys.argv[2])
worker_dir = pathlib.Path(sys.argv[3])
namespace_id = sys.argv[4]

items = json.loads(keys_path.read_text(encoding="utf-8"))
keys = [item["name"] for item in items if item.get("name", "").startswith("report:")]
for key in keys:
    filename = key.replace(":", "_") + ".json"
    destination = report_dir / filename
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
        continue
    destination.write_text(result.stdout, encoding="utf-8")

PY

python3 - "$OUTPUT_DIR/github-issues.json" "$REPORT_DIR" "$OUTPUT_DIR/summary.txt" <<'PY'
import json
import pathlib
import sys

issues = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
report_dir = pathlib.Path(sys.argv[2])
summary_path = pathlib.Path(sys.argv[3])
reports = []
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
    lines.append(
        f"  #{issue['number']} [{issue['state']}] {issue['title']}"
        f"  {issue['url']}"
    )
lines.append("")
lines.append(f"Cloudflare 错误报告：{len(reports)}")
for received_at, version, build, mode, title, filename in reports:
    lines.append(f"  {received_at}  {version} ({build})  {mode}  {title}")
    lines.append(f"    文件：{filename}")

summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(summary_path.read_text(encoding="utf-8"), end="")
PY

echo "完整报告已保存到：$OUTPUT_DIR"
