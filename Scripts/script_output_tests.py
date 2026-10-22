"""Exercise public command logging and workflow completion boundaries."""
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
from command_output import run_command

SCRIPT_ROOT = Path(__file__).resolve().parent


class RetainedLog(StringIO):
    def close(self): pass


def captured_command(lines, status=7, *, ci=False, executable='fixture'):
    saved = RetainedLog()
    def open_log(path, mode='r', **kwargs):
        if mode != 'w': saved.seek(0)
        return saved
    child = SimpleNamespace(stdout=iter(lines), wait=lambda: status)
    output = StringIO()
    with patch.object(Path, 'open', open_log), patch.object(Path, 'mkdir'), \
            patch.object(subprocess, 'Popen', return_value=child), \
            patch.dict(os.environ, GITHUB_ACTIONS='true' if ci else 'false'), redirect_stdout(output):
        assert run_command(['/dev/null', 'fixture', executable]) == status
    return output.getvalue(), saved.getvalue()


def log_output_boundary_findings() -> list[str]:
    findings = []
    temporary_bundle = Path('/fixture/cache/ResultBundle_failure.xcresult')
    diagnostic_bundle = Path('/fixture/diagnostics/test-results.xcresult')
    for status in (0, 7):
        with patch.dict(os.environ, BIT101_COMMAND_DIAGNOSTICS=str(diagnostic_bundle.parent)), \
                patch('tempfile.gettempdir', return_value='/fixture/cache'), \
                patch.object(Path, 'resolve', lambda path: path), patch.object(Path, 'is_dir', return_value=True), \
                patch('shutil.move') as moved, patch('shutil.rmtree') as removed:
            captured_command([f'Writing error result bundle to {temporary_bundle}\n'], status, executable='xcodebuild')
            assert moved.call_args.args == (str(temporary_bundle), str(diagnostic_bundle)) if status else not moved.called
            assert removed.call_args.args[0] == (diagnostic_bundle if status else temporary_bundle)
    from test_results import report_test_results
    exported = diagnostic_bundle.parent / 'session.log'
    with patch.object(sys, 'argv', ['diagnostics', '/fixture/test-results.xcresult', '', 'diagnostics', str(SCRIPT_ROOT)]), \
            patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'exists', lambda path: path == diagnostic_bundle.parent), \
            patch('test_results.current_result_bundle', return_value=diagnostic_bundle), \
            patch.object(Path, 'is_dir', lambda path: path == diagnostic_bundle), \
            patch.object(Path, 'iterdir', return_value=[diagnostic_bundle, exported]), \
            patch.object(Path, 'unlink') as unlinked, patch.object(shutil, 'rmtree') as removed, \
            patch.object(subprocess, 'run') as export, redirect_stdout(StringIO()):
        try: report_test_results(sys.argv[1:])
        except SystemExit as error: assert error.code == 0
        arguments = export.call_args.args[0]
        assert arguments[arguments.index('--path') + 1] == str(diagnostic_bundle)
        assert arguments[arguments.index('--output-path') + 1] == str(diagnostic_bundle.parent)
        assert unlinked.call_count == 1 and not removed.called
    logger = 'ROOT_DIR=' + shlex.quote(str(SCRIPT_ROOT.parent)) + '\nsource ' + shlex.quote(str(SCRIPT_ROOT / 'script-support.sh'))
    command = logger + '\nbit101_log_command /dev/null stdin-contract ' + shlex.quote(sys.executable) + ' - delegated-argument\n'
    for status in (0, 7):
        payload = f'import sys\nassert sys.argv[1] == "delegated-argument"\nprint("warning: delegated-stdin-executed")\nraise SystemExit({status})\n'
        result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True,
            env={**os.environ, 'GITHUB_ACTIONS': 'false'})
        assert result.returncode == status and 'delegated-stdin-executed' in result.stdout
    peaks = []
    program = 'import resource, sys; from command_output import run_command; status=run_command(sys.argv[1:]); print("LOGGER_RSS", resource.getrusage(resource.RUSAGE_SELF).ru_maxrss); raise SystemExit(status)'
    for lines in (1_000, 70_000):
        result = subprocess.run([sys.executable, '-c', program, '/dev/null', 'memory-contract', sys.executable, '-'],
            input=f'for index in range({lines}): print("warning:", index, "x" * 256)\n', capture_output=True, text=True,
            env={**os.environ, 'PYTHONPATH': str(SCRIPT_ROOT)})
        peak = re.search(r'LOGGER_RSS (\d+)', result.stdout)
        assert result.returncode == 0 and peak
        peaks.append(int(peak[1]) * (1 if sys.platform == 'darwin' else 1024))
    assert peaks[1] - peaks[0] < (70_000 - 1_000) * 256 // 2
    lines = [*(f'error: retained {index}\n' for index in range(100)), 'UI control inventory: {}\n']
    output, raw = captured_command(lines, ci=True)
    assert 'error: retained 0\n' in output and 'error: retained 99\n' in output
    assert 'UI control inventory:' not in output and 'UI control inventory:' in raw
    output, _ = captured_command(['error: image-retry-failed\n', *('    t = 1.0s Checking existence of retry button\n' for _ in range(100))])
    assert 'error: image-retry-failed' in output and 'Checking existence' not in output
    for prefix in ('progress', 'warning:', 'error:'):
        output, raw = captured_command([*(f'{prefix} {index}\n' for index in range(45)), 'error: late-root-cause\n', 'tail-context\n'])
        assert 'error: late-root-cause' in output and 'error: late-root-cause' in raw
        if prefix == 'error:': assert 'error: 0\n' in output and 'error: 44\n' in output
    return findings


def verification_finish_findings() -> list[str]:
    import os
    from script_test_support import shell_function
    step = shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_check_verification_audit') + '\n' + shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_verify_step')
    finish = shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_finish_verification')
    findings = []
    for prepare_status, audit_status, initial in ((0, 0, 0), (0, 11, 0), (13, 0, 0), (0, 11, 7), (0, 0, 7)):
        harness = f'''set -euo pipefail
unset BIT101_AUDIT_BACKGROUND BIT101_AUDIT_ARTIFACTS_PREPARED
ROOT_DIR=/fixture verification_audit_pid=
completed_result_groups=()
python3() {{ print 17.0; }}
audit_probe() {{ if [[ "${{1:-}}" == prepare ]]; then print PREPARE; return {prepare_status}; fi; [[ "$BIT101_AUDIT_ARTIFACTS_PREPARED" == 1 ]]; print AUDIT_FINISHED; return {audit_status}; }}
'''
        result = subprocess.run(['zsh', '-c', harness + step + '\n' + finish +
            f'\ntrap bit101_finish_verification EXIT ZERR\nbit101_verify_step audit audit_probe\nexit {initial}'],
            capture_output=True, text=True, timeout=5)
        expected = prepare_status or initial or int(bool(audit_status))
        if result.returncode != expected or bool(prepare_status) == ('AUDIT_FINISHED' in result.stdout) \
                or not prepare_status and result.stdout.index('PREPARE') > result.stdout.index('AUDIT_FINISHED') \
                or '[完整验证总耗时] 17.0 秒' not in result.stdout:
            findings.append('聚合退出自测：归集后台审计、原始失败状态与完整耗时')
    from test_results import workflow_elapsed
    from unittest.mock import patch
    from io import StringIO
    from contextlib import redirect_stdout
    with patch.dict(os.environ, BIT101_WORKFLOW_STARTED_AT='100'), patch('time.monotonic', return_value=191.5), redirect_stdout(output := StringIO()):
        workflow_elapsed([])
    assert output.getvalue().strip() == '91.5'
    for audit_status in (0, 7):
        harness = f'''set -euo pipefail
ROOT_DIR=/fixture verification_audit_pid=
completed_result_groups=()
python3() {{ return 0; }}
audit_probe() {{ [[ "${{1:-}}" == prepare ]] && return 0; return {audit_status}; }}
child() {{ print NEXT_PHASE; }}
'''
        result = subprocess.run(['zsh', '-c', harness + step + '''
bit101_verify_step audit audit_probe
while kill -0 "$verification_audit_pid" 2>/dev/null; do sleep 0.01; done
bit101_verify_step all child
'''], capture_output=True, text=True, timeout=5)
        assert bool(result.returncode) == bool(audit_status), result.stderr
        assert ('NEXT_PHASE' in result.stdout) == (audit_status == 0)
    return findings
