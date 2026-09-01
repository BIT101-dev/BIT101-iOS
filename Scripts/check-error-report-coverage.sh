#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT_DIR/BIT101-iOS" <<'PY'
from pathlib import Path
import re, sys

root = Path(sys.argv[1])
problems = []
schedule_notice_presenters = 0
for path in root.rglob("*.swift"):
    text = path.read_text(encoding="utf-8")
    schedule_notice_presenters += text.count("schoolDataRefresh.scheduleViewModel.$notice")
    if ".diagnosticAlert(item: $viewModel.notice)" in text:
        problems.append(f"{path}: 日程共享错误不得在子页面重复展示")
    if path.name != "ErrorReportSupport.swift":
        position = 0
        while (start := text.find(".alert(item:", position)) >= 0:
            opening = text.find("{", start)
            depth, end = 1, opening + 1
            while end < len(text) and depth:
                depth += (text[end] == "{") - (text[end] == "}")
                end += 1
            block = text[start:end]
            if ".title" in block and ".message" in block and "primaryButton" not in block:
                line = text.count("\n", 0, start) + 1
                problems.append(f"{path}:{line}: AppAlert 未使用 diagnosticAlert")
            position = end

    if not any(word in path.name for word in ("View", "Screen")):
        continue
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if not re.search(r"(?:case|if case|else if case) let \.failed\(message\)", line):
            continue
        window = "\n".join(lines[index:index + 35])
        if "ContentUnavailableView" not in window and "PaperEmptyState" not in window:
            continue
        if "DiagnosticRecoveryActions" not in window and "PaperEmptyState" not in window:
            problems.append(f"{path}:{index + 1}: 失败态缺少错误报告入口")

if schedule_notice_presenters != 1:
    problems.append(f"日程共享错误展示器数量异常：引用数 {schedule_notice_presenters}")

if problems:
    print("\n".join(problems), file=sys.stderr)
    raise SystemExit(1)
print("错误报告入口覆盖检查通过。")
PY
