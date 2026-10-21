"""Exercise command output, failure diagnostics and bounded log retention."""
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from contextlib import redirect_stdout
from io import StringIO
from types import SimpleNamespace
from unittest.mock import patch

SCRIPT_ROOT = Path(__file__).resolve().parent


def log_output_boundary_findings() -> list[str]:
    findings = []
    support = (SCRIPT_ROOT / 'script-support.sh').read_text()
    logger = support.split('\nbit101_set_workflow_budget() {', 1)[0] + '\nbit101_log_command() {' \
        + support.split('bit101_log_command() {', 1)[1].split('\nbit101_build_cache() {', 1)[0]
    log_program = logger.split("3<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
    temporary_bundle = Path('/fixture/cache/ResultBundle_failure.xcresult')
    diagnostic_bundle = Path('/fixture/diagnostics/test-results.xcresult')
    for status in (0, 7):
        child = SimpleNamespace(stdout=iter([f'Writing error result bundle to {temporary_bundle}\n']), wait=lambda: status)
        with patch.object(sys, 'argv', ['logger', '/dev/null', 'fixture', 'xcodebuild']), \
                patch.dict(os.environ, BIT101_COMMAND_DIAGNOSTICS=str(diagnostic_bundle.parent)), \
                patch.object(subprocess, 'Popen', return_value=child), patch('tempfile.gettempdir', return_value='/fixture/cache'), \
                patch.object(Path, 'mkdir'), patch.object(Path, 'resolve', lambda path: path), patch.object(Path, 'is_dir', return_value=True), \
                patch('shutil.move') as moved, patch('shutil.rmtree') as removed, redirect_stdout(StringIO()):
            try: exec(compile(log_program, '<build-diagnostic>', 'exec'), {})
            except SystemExit as error: assert error.code == status
            assert moved.call_args.args == (str(temporary_bundle), str(diagnostic_bundle)) if status else not moved.called
            assert removed.call_args.args[0] == (diagnostic_bundle if status else temporary_bundle)
    diagnostics_program = (SCRIPT_ROOT / 'run-extended-tests.sh').read_text().split(
        'python3 - "$DERIVED_ROOT/test-results.xcresult"', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
    exported = diagnostic_bundle.parent / 'session.log'
    with patch.object(sys, 'argv', ['diagnostics', '/fixture/test-results.xcresult', '', 'diagnostics', str(SCRIPT_ROOT)]), \
            patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'exists', lambda path: path == diagnostic_bundle.parent), \
            patch.object(Path, 'is_dir', lambda path: path == diagnostic_bundle), \
            patch.object(Path, 'iterdir', return_value=[diagnostic_bundle, exported]), \
            patch.object(Path, 'unlink') as unlinked, patch.object(shutil, 'rmtree') as removed, \
            patch.object(subprocess, 'run') as export, redirect_stdout(StringIO()):
        try: exec(compile(diagnostics_program, '<diagnostic-export>', 'exec'), {})
        except SystemExit as error: assert error.code == 0
        arguments = export.call_args.args[0]
        assert arguments[arguments.index('--path') + 1] == str(diagnostic_bundle)
        assert arguments[arguments.index('--output-path') + 1] == str(diagnostic_bundle.parent)
        assert unlinked.call_count == 1 and not removed.called
    memory_report = '''from io import StringIO
class RetainedLog(StringIO):
    def close(self): pass
saved_log = RetainedLog()
def open_log(path, mode="r", **kwargs):
    if mode != "w": saved_log.seek(0)
    return saved_log
Path.open = open_log
'''
    ci_logger = logger.replace('report_path = Path(sys.argv[1])', memory_report + '\nreport_path = Path(sys.argv[1])')
    command = ci_logger + '\nbit101_log_command /dev/null stdin-contract ' + shlex.quote(sys.executable) + ' - delegated-argument\n'
    for status in (0, 7):
        payload = f'import sys\nassert sys.argv[1] == "delegated-argument"\nprint("warning: delegated-stdin-executed")\nraise SystemExit({status})\n'
        result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True,
            env={**os.environ, 'GITHUB_ACTIONS': 'false'})
        if result.returncode != status or 'delegated-stdin-executed' not in result.stdout:
            findings.append(f'日志委托自测：子命令继承调用方输入、参数和退出状态；预期 {status}，实际 {result.returncode}；{(result.stdout + result.stderr)[-500:]!r}')
    measured = logger.replace('raise SystemExit(exit_code if exit_code >= 0 else 128 - exit_code)',
        'import resource\nprint("LOGGER_RSS", resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)\nraise SystemExit(exit_code if exit_code >= 0 else 128 - exit_code)')
    peaks = []
    for lines in (1_000, 70_000):
        payload = f'for index in range({lines}): print("warning:", index, "x" * 256)\n'
        command = measured + '\nbit101_log_command /dev/null memory-contract ' + shlex.quote(sys.executable) + ' -\n'
        result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True)
        peak = re.search(r'LOGGER_RSS (\d+)', result.stdout)
        if result.returncode or not peak:
            findings.append('日志驻留内存自测：大量诊断仍沿成功状态完成')
            break
        peaks.append(int(peak[1]) * (1 if sys.platform == 'darwin' else 1024))
    if len(peaks) == 2 and peaks[1] - peaks[0] >= (70_000 - 1_000) * 256 // 2:
        findings.append('日志驻留内存自测：摘要占用需要随显示容量保持有限')
    inventory_logger = ci_logger.replace('raise SystemExit(exit_code if exit_code >= 0 else 128 - exit_code)',
        'assert "UI control inventory:" in saved_log.getvalue()\nraise SystemExit(exit_code if exit_code >= 0 else 128 - exit_code)')
    command = inventory_logger + '\nbit101_log_command /dev/null ci-contract ' + shlex.quote(sys.executable) + ' -\n'
    payload = 'for index in range(100): print("error: retained", index)\nprint("UI control inventory: {}")\nraise SystemExit(7)\n'
    result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True,
        env={**os.environ, 'GITHUB_ACTIONS': 'true'})
    if result.returncode != 7 or 'error: retained 0\n' not in result.stdout or 'error: retained 99\n' not in result.stdout or 'UI control inventory:' in result.stdout:
        findings.append('日志磁盘重读自测：CI 失败完整呈现诊断，控件库存保留在原始日志')
    command = logger + '\nbit101_log_command /dev/null late-error ' + shlex.quote(sys.executable) + ' -\n'
    for prefix in ('progress', 'warning:'):
        payload = f'for index in range(45): print("{prefix}", index)\nprint("error: late-root-cause")\nprint("tail-context")\nraise SystemExit(7)\n'
        result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True,
            env={**os.environ, 'GITHUB_ACTIONS': 'false'})
        if result.returncode != 7 or 'error: late-root-cause' not in result.stdout:
            findings.append('失败摘要需要优先呈现末尾出现的根因诊断')
    return findings
