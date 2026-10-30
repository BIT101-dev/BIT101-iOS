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


def character_limit() -> int:
    return OUTPUT_LINE_LIMIT * shutil.get_terminal_size().columns


def bounded_text(value: str, limit: int) -> tuple[str, bool]:
    if len(value) <= limit: return value, False
    head = (limit - 1) // 2
    tail = limit - head - 1
    return value[:head] + '…' + (value[-tail:] if tail else ''), True


class BoundedLines:
    """Keep the initial diagnostics and the latest causes within one display budget."""
    def __init__(self, limit: int):
        self.head = []
        self.tail = deque(maxlen=limit - limit // 2)
        self.head_limit = limit // 2
        self.character_limit = character_limit()
        self.truncated = False

    def add(self, line: str) -> bool:
        line, truncated = bounded_text(line, self.character_limit)
        self.truncated |= truncated
        if line in self.head or line in self.tail: return False
        if len(self.head) < self.head_limit: self.head.append(line)
        else: self.tail.append(line)
        return True

    def lines(self) -> list[str]:
        return [*self.head, *self.tail]


def useful_line(line):
    if not line.strip(): return False
    if line.startswith('[') and line[1:2].isdigit() and re.search(r'error:|warning:|fatal:|failed', line, re.IGNORECASE): return True
    if re.match(r"^\s*t =\s*(?:[\d.]+s|nans)\s", line) and not re.search(r"error:|failed", line, re.IGNORECASE): return False
    if line.startswith(("UI control inventory: ", "UI query metrics: ", "UI input replace: ",
                       "UI scene preparation: ", "UI automation App process: ", "UI persistence App restart: ")): return False
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

    @property
    def truncated(self):
        return self.errors.truncated or self.details.truncated


def show_report_lines(lines, path: Path, label: str) -> None:
    """Show report excerpts within the shared terminal budget and retain its path."""
    first, last = [], deque(maxlen=OUTPUT_LINE_LIMIT - OUTPUT_LINE_LIMIT // 2)
    count = 0
    limit, truncated = character_limit(), False
    for line in lines:
        count += 1
        line, clipped = bounded_text(line, limit)
        truncated |= clipped
        if len(first) < OUTPUT_LINE_LIMIT // 2: first.append(line)
        else: last.append(line)
    shown = [*first, *last]
    rendered, clipped = bounded_text(''.join(shown), limit)
    sys.stdout.write(rendered)
    if rendered and not rendered.endswith('\n'): print()
    if count > OUTPUT_LINE_LIMIT or truncated or clipped: print(f'[输出] {label} 共 {count} 行 · {path}')


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
    selected = summary if failed else ordinary
    rendered, clipped = bounded_text(''.join(selected.lines()), character_limit())
    sys.stdout.write(rendered)
    if rendered and not rendered.endswith('\n'): print()
    if count > OUTPUT_LINE_LIMIT or selected.truncated or clipped: print(f'[输出] {path.stem} 共 {count} 行 · {path}')


def run_command(arguments: list[str]) -> int:
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    report_path = Path(arguments[0])
    label = arguments[1]
    started = time.monotonic()
    build_command = any(Path(argument).name == 'xcodebuild' for argument in arguments[2:])
    report_path.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(arguments[2:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    display_limit = OUTPUT_LINE_LIMIT
    diagnostics = BoundedLines(display_limit)
    failures = FailureSummary(display_limit)
    diagnostic_count = 0
    streamed = set()
    streamed_characters = 0
    summary_count = summary_tests = 0
    summary = ""
    dependency_warning_count = 0
    cache_warning_count = 0
    dependency_example = ""
    temporary_results = set()
    with report_path.open("w", encoding="utf-8", buffering=1) as report:
        for line in process.stdout:
            report.write(line)
            if build_command:
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
                report.flush()
                if dependency := re.match(r"warning: '(.+)' is missing a dependency on '(.+)' because dependency scan of Swift module", line):
                    dependency_warning_count += 1
                    if not dependency_example: dependency_example = f'{dependency[1]} → {dependency[2]}'
                    continue
                elif re.match(r"warning: (?:failed to load CAS object: unknown object|.*llvmcas://.*: No such file or directory)", line):
                    cache_warning_count += 1
                    continue
                elif diagnostics.add(line):
                    diagnostic_count += 1
                    if len(streamed) < display_limit // 2 and streamed_characters + len(line) <= diagnostics.character_limit // 2:
                        print(line, end='', flush=True)
                        streamed.add(line)
                        streamed_characters += len(line)
            if "Test run with" in line:
                summary, clipped = bounded_text(line.strip(), diagnostics.character_limit)
                diagnostics.truncated |= clipped
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
    if dependency_warning_count and not exit_code:
        diagnostics.add(f'[依赖扫描] {dependency_warning_count} 条提示 · {dependency_example} · 完整日志：{report_path}\n')
        diagnostic_count += 1
    if cache_warning_count and not exit_code:
        diagnostics.add(f'[编译缓存] {cache_warning_count} 条已回收条目提示 · 完整日志：{report_path}\n')
        diagnostic_count += 1
    output = failures.lines() if exit_code else diagnostics.lines()
    output_count = failures.count if exit_code else diagnostic_count
    pending_lines = [line for line in output if line not in streamed][:display_limit - len(streamed)]
    rendered, clipped = bounded_text(''.join(pending_lines), diagnostics.character_limit - streamed_characters)
    sys.stdout.write(rendered)
    if rendered and not rendered.endswith('\n'): print()
    if output_count > display_limit or clipped or (failures if exit_code else diagnostics).truncated:
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
