#!/usr/bin/env python3
"""Run a command with complete disk logs and bounded terminal diagnostics."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import signal
from collections import deque

OUTPUT_LINE_LIMIT = 40


class BoundedLines:
    """Keep the initial diagnostics and the latest causes within one display budget."""
    def __init__(self, limit: int):
        self.head = []
        self.tail = deque(maxlen=limit - limit // 2)
        self.head_limit = limit // 2

    def add(self, line: str) -> bool:
        if line in self.head or line in self.tail: return False
        if len(self.head) < self.head_limit: self.head.append(line)
        else: self.tail.append(line)
        return True

    def lines(self) -> list[str]:
        return [*self.head, *self.tail]


def useful_line(line):
    if not line.strip(): return False
    if re.match(r"^\s*t =\s*(?:[\d.]+s|nans)\s", line) and not re.search(r"error:|failed", line, re.IGNORECASE): return False
    if line.startswith(("UI control inventory: ", "UI query metrics: ", "UI input replace: ",
                       "UI scene preparation: ", "UI automation App process: ", "UI persistence App restart: ")): return False
    if re.match(r"warning: '.+' is missing a dependency on '.+' because dependency scan of Swift module", line): return False
    if line.startswith(("Test case ", "Test Case ")) and re.search(r"\bpassed(?: on | \(|$)", line): return False
    if line.startswith(("◇ ", "✔ ")): return False
    if line.startswith(("Test case ", "Test suite ", "Test Case ", "Test Suite ")) and "failed" not in line.lower(): return False
    if line.rstrip().endswith(" seconds)") and "failed" not in line.lower(): return False
    if line.startswith(("note: Removed stale file ", "Failed frontend command:", "[Pre-planning", "[Computing dependencies]", "[Using on-disk description]", "[Planning deferred tasks]", "[Starting]")): return False
    if line.startswith("[") and line[1:2].isdigit(): return False
    if "Executed 0 tests, with 0 failures" in line or "IDETestOperationsObserverDebug:" in line: return False
    if "IDELaunchParametersSnapshot:" in line and ("debugger version lookup failed" in line or "no debugger version" in line): return False
    return "swift-frontend -frontend" not in line and not line.lstrip().startswith("builtin-SwiftDriver -- ")

class FailureSummary:
    def __init__(self, limit=OUTPUT_LINE_LIMIT):
        self.errors, self.details = BoundedLines(limit), BoundedLines(limit)
        self.limit, self.count = limit, 0

    def add(self, line):
        if not useful_line(line): return
        self.count += 1
        self.details.add(line)
        if 'error:' in line.lower() or line.lstrip().startswith('✘') or 'failed' in line.lower():
            self.errors.add(line)

    def lines(self):
        return list(dict.fromkeys([*self.errors.lines(), *self.details.lines()]))[:self.limit]


def show_report_lines(lines, path: Path, label: str) -> None:
    """Show report excerpts within the shared terminal budget and retain its path."""
    first, last = [], deque(maxlen=OUTPUT_LINE_LIMIT - OUTPUT_LINE_LIMIT // 2)
    count = 0
    for line in lines:
        count += 1
        if len(first) < OUTPUT_LINE_LIMIT // 2: first.append(line)
        else: last.append(line)
    shown = [*first, *last]
    sys.stdout.writelines(shown)
    if shown and not shown[-1].endswith('\n'): print()
    if count > OUTPUT_LINE_LIMIT: print(f'[输出] {label} 共 {count} 行 · {path}')


def show_report(path: Path, label: str) -> None:
    with path.open() as report:
        show_report_lines(report, path, label)


def show_log(path: Path, failed: bool) -> None:
    summary = FailureSummary()
    ordinary, count = BoundedLines(OUTPUT_LINE_LIMIT), 0
    with path.open() as log:
        for line in log:
            count += 1
            if failed: summary.add(line)
            else: ordinary.add(line)
    sys.stdout.writelines(summary.lines() if failed else ordinary.lines())
    if count > OUTPUT_LINE_LIMIT: print(f'[输出] {path.stem} 共 {count} 行 · {path}')


def run_command(arguments: list[str]) -> int:
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    report_path = Path(arguments[0])
    label = arguments[1]
    started = time.monotonic()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(arguments[2:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    display_limit = OUTPUT_LINE_LIMIT
    diagnostics = BoundedLines(display_limit)
    failures = FailureSummary(display_limit)
    diagnostic_count = 0
    summary_count = summary_tests = 0
    summary = ""
    temporary_results = set()
    with report_path.open("w", encoding="utf-8") as report:
        for line in process.stdout:
            report.write(line)
            report.flush()
            if label == "模拟器测试" and os.environ.get("GITHUB_ACTIONS") == "true" \
                    and re.match(r"Test Case .+ (?:passed|failed) \([\d.]+ seconds\)\.", line):
                print("[用例] " + line.strip(), flush=True)
            if arguments[2] == "xcodebuild":
                match = re.search(r"Writing error result bundle to (.+\.xcresult)\s*$", line)
                if match:
                    path = Path(match[1])
                    if path.parent.resolve() == Path(tempfile.gettempdir()).resolve() and path.name.startswith("ResultBundle_"):
                        temporary_results.add(path)
                        continue
            if not line.strip():
                continue
            failures.add(line)
            if "error:" in line or "warning:" in line or useful_line(line) and (line.lstrip().startswith("✘") or "failed" in line.lower()):
                if re.match(r"warning: '.+' is missing a dependency on '.+' because dependency scan of Swift module", line):
                    continue
                elif diagnostics.add(line):
                    diagnostic_count += 1
            if "Test run with" in line:
                summary = line.strip()
                summary_count += 1
                summary_tests += int(re.search(r"Test run with (\d+) tests?", line)[1])
    exit_code = process.wait()
    for path in temporary_results:
        if exit_code and path.is_dir():
            destination = Path(os.environ['BIT101_COMMAND_DIAGNOSTICS']) / 'test-results.xcresult'
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(destination, ignore_errors=True)
            shutil.move(str(path), str(destination))
            print(f"[诊断] 构建失败结果包 · {destination}")
        else:
            shutil.rmtree(path, ignore_errors=True)
    output = failures.lines() if exit_code else diagnostics.lines()
    output_count = failures.count if exit_code else diagnostic_count
    sys.stdout.writelines(output)
    if output_count > display_limit:
        print(f"[输出] {label} 共 {output_count} 行诊断 · {report_path}")
    if not exit_code and summary_count:
        if summary_count == 1:
            print(summary)
        else:
            print(f"Swift Testing：{summary_tests} 项通过 · {summary_count} 个测试进程")
    state = "失败" if exit_code else "完成"
    print(f"[{state}] {label} · {time.monotonic() - started:.1f} 秒")
    return exit_code if exit_code >= 0 else 128 - exit_code


if __name__ == '__main__':
    if sys.argv[1:2] == ['show-report']:
        show_report(Path(sys.argv[2]), sys.argv[3])
    elif sys.argv[1:2] == ['show-log']:
        show_log(Path(sys.argv[2]), sys.argv[3] == 'true')
    else:
        raise SystemExit(run_command(sys.argv[1:]))
