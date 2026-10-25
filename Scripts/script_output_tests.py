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
from command_output import OUTPUT_LINE_LIMIT, run_command, show_log, show_report_lines

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
        assert run_command(['/dev/null', 'fixture', executable]) == (status if status >= 0 else 128 - status)
    return output.getvalue(), saved.getvalue()


def log_output_boundary_findings() -> list[str]:
    findings = []
    script = (SCRIPT_ROOT / 'release-network-smoke.sh').read_text()
    function = 'show_smoke_progress() {' + script.split('show_smoke_progress() {', 1)[1].split('\n}', 1)[0] + '\n}'
    stages = ['NETWORK_SMOKE_START name=school.session', 'NETWORK_SMOKE_SMS_REQUIRED purpose=成绩查询',
        'NETWORK_SMOKE_PASS name=school.session elapsed=1', 'NETWORK_SMOKE_FAIL [score] fixture',
        'NETWORK_SMOKE_AUTH_BLOCKED [score] fixture']
    fixture = 'system noise\n' + '\n'.join('timestamp ' + stage for stage in stages) + '\n'
    command = 'set -euo pipefail\ntypeset -A shown_smoke_progress=()\nCONSOLE_LOG=/dev/stdin\n' \
        + 'awk() { command awk "$@" <<< "$SMOKE_FIXTURE"; }\n' + function + '\nshow_smoke_progress\nshow_smoke_progress\n'
    result = subprocess.run(['zsh', '-c', command], env=os.environ | {'SMOKE_FIXTURE': fixture, 'PATH': '/usr/bin:/bin'},
        check=True, capture_output=True, text=True)
    output = result.stdout
    assert output.splitlines() == stages, f'Smoke 进度需要匹配已到达阶段：{output!r} · {result.stderr!r}'
    def arriving_diagnostics():
        yield 'error: early compiler failure\n'
        assert 'error: early compiler failure' in sys.stdout.getvalue()
        yield 'warning: following diagnostic\n'
    output, raw = captured_command(arriving_diagnostics())
    assert output.count('error: early compiler failure') == 1 and 'warning: following diagnostic' in raw
    for count in (0, 1, OUTPUT_LINE_LIMIT, OUTPUT_LINE_LIMIT + 1, 1000):
        rows = [f'row {index}\n' for index in range(count)]
        output = StringIO()
        with redirect_stdout(output):
            show_report_lines(iter(rows), Path('/report.json'), '报告')
        shown = output.getvalue()
        assert len(shown.splitlines()) <= OUTPUT_LINE_LIMIT + 1
        if count <= OUTPUT_LINE_LIMIT: assert shown == ''.join(rows)
        else: assert rows[0] in shown and rows[-1] in shown and '/report.json' in shown
    output = StringIO()
    with redirect_stdout(output): show_report_lines(iter(['final']), Path('/report.json'), '报告')
    assert output.getvalue() == 'final\n'
    from command_output import character_limit
    large = 'error: 开始' + 'x' * 1_048_576 + '结束\n'
    with redirect_stdout(output := StringIO()): show_report_lines(iter([large]), Path('/report.json'), '报告')
    assert len(output.getvalue()) < character_limit() + 200
    assert '开始' in output.getvalue() and '结束' in output.getvalue() and '/report.json' in output.getvalue()
    for failed in (True, False):
        with patch.object(Path, 'open', return_value=RetainedLog(large)), redirect_stdout(output := StringIO()):
            show_log(Path('/fixture/compiler.log'), failed)
        assert len(output.getvalue()) < character_limit() + 200 and '结束' in output.getvalue()
    output, raw = captured_command([large])
    assert raw == large and len(output) < character_limit() + 200 and '开始' in output and '结束' in output
    warning = "warning: 'CourseFeature' is missing a dependency on 'CommunityCore' because dependency scan of Swift module\n"
    output, raw = captured_command([warning], status=0, executable='xcodebuild')
    assert warning in raw and output.count('\n') == 2 and '[完成]' in output
    assert '[依赖扫描] 1 条提示' in output and 'CourseFeature → CommunityCore' in output and '/dev/null' in output
    output, raw = captured_command([warning] * 1000, status=0, executable='xcodebuild')
    assert raw == warning * 1000 and output.count('\n') == 2 and '[依赖扫描] 1000 条提示' in output
    for line in (warning, '[1/2] error: fixture compiler failure\n', '[12/20] warning: fixture dependency issue\n'):
        output, raw = captured_command([line], status=7, executable='xcodebuild')
        assert line in output and line in raw
        with patch.object(Path, 'open', return_value=RetainedLog(line)), redirect_stdout(output := StringIO()):
            show_log(Path('/fixture/compiler.log'), True)
        assert line in output.getvalue()
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
    assert len(output.splitlines()) <= OUTPUT_LINE_LIMIT + 2
    assert 'UI control inventory:' not in output and 'UI control inventory:' in raw
    repeated = ['error: repeated cause\n'] * 200
    for ci in (False, True):
        output, raw = captured_command(repeated, ci=ci)
        assert output.count('error: repeated cause\n') == 1 and raw.count('error: repeated cause\n') == 200
        assert '/dev/null' in output and len(output.splitlines()) <= OUTPUT_LINE_LIMIT + 2
        with patch.object(Path, 'open', return_value=RetainedLog(''.join(repeated))), \
                patch.dict(os.environ, GITHUB_ACTIONS='true' if ci else 'false'), redirect_stdout(shown := StringIO()):
            show_log(Path('/fixture/failure.log'), True)
        assert shown.getvalue().count('error: repeated cause\n') == 1
        assert '/fixture/failure.log' in shown.getvalue() and len(shown.getvalue().splitlines()) <= OUTPUT_LINE_LIMIT + 1
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


def combined_audit_order_findings() -> list[str]:
    import importlib.util
    spec = importlib.util.spec_from_file_location('combined_audit_entry', SCRIPT_ROOT / 'check-code-quality.py')
    entry = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(entry)
    findings = []
    for ui_status, quality_status, boundary in ((1, 0, []), (0, 1, []), (0, 0, []), (0, 0, ['boundary failure'])):
        calls = []
        def record(name, result):
            calls.append(name)
            return result
        ui = SimpleNamespace(main=lambda _: record('ui', ui_status),
            **{name: lambda: record('self-ui', []) for name in ('ast_marker_boundary_findings', 'source_boundary_findings',
                'map_theme_color_contract_findings', 'interaction_inventory_boundary_findings')})
        ui_spec = SimpleNamespace(name='combined_audit_ui_fixture', loader=SimpleNamespace(exec_module=lambda _: None))
        with patch.object(entry, 'swift_files', return_value=[]), patch.object(entry, 'swift_syntax_index', return_value={}), \
                patch.object(entry, 'main', side_effect=lambda _: record('quality', quality_status)), \
                patch.object(entry, 'explanatory_text_report', side_effect=lambda: record('report', None)), \
                patch.object(entry.importlib.util, 'spec_from_file_location', return_value=ui_spec), \
                patch.object(entry.importlib.util, 'module_from_spec', return_value=ui), \
                patch.dict(sys.modules, {'code_quality_tests': SimpleNamespace(
                    checker_boundary_findings=lambda: record('self-quality', boundary))}), \
                patch.object(sys, 'argv', ['audit', '--combined', '--self-test']), redirect_stdout(StringIO()):
            result = entry.combined_main()
        expected_self_tests = ui_status == quality_status == 0
        if result != int(bool(ui_status or quality_status or boundary)) or calls[:3] != ['ui', 'quality', 'report'] \
                or ('self-quality' in calls) != expected_self_tests or calls.count('self-ui') != (4 if expected_self_tests else 0):
            findings.append('组合审计应先报告源码结果，源码通过后完整运行检查器自测并传播失败。')
    return findings
