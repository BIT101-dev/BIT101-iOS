"""Keep report families and exported screenshot choices tied to the selected result batch."""
import json
import os
import shutil
import subprocess
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch


def test_result_boundary_findings() -> list[str]:
    from test_results import report_test_results
    root = Path('/fixture/extended-automation')
    scripts = str(Path(__file__).parent)
    bundle = root / 'test-results.xcresult'
    metrics, coverage = root / 'test-metrics.txt', root / 'out/codecov.json'
    test = 'Consumer.Fixture/current()/Tests.swift:1:1'
    events = [dict(kind='test', payload=dict(kind='function', id=test, isParameterized=False))]
    events += [dict(kind='event', payload=dict(kind=kind, testID=test if kind.startswith('test') else ''))
        for kind in ('runStarted', 'testStarted', 'testEnded', 'runEnded')]
    files = {metrics: '# 模块生产源码行覆盖率\n结果来源：' + json.dumps(dict(family='modules', coverage=str(coverage))),
        coverage: '{"moduleCoverage":100}', root / 'module-events.jsonl': '\n'.join(map(json.dumps, events))}
    with patch.object(Path, 'read_text', lambda path, **kwargs: files[path]), \
            patch.object(Path, 'is_file', lambda path: path in files or path.name == 'Info.plist'), \
            patch.object(Path, 'exists', return_value=False), patch.object(subprocess, 'check_output', return_value='{"nativeBatch":true}') as native:
        for mode in ('json', 'coverage'):
            output = StringIO()
            with redirect_stdout(output):
                try: report_test_results([str(bundle), mode, 'report', scripts])
                except SystemExit as error: assert error.code == 0
            value = json.loads(output.getvalue())
            assert value.get('passedTests') == 1 if mode == 'json' else value == {'moduleCoverage': 100}
        native.assert_not_called()
        files[metrics] = '# XCTest 与覆盖率指标\n'
        for mode in ('json', 'coverage'):
            output = StringIO()
            with redirect_stdout(output):
                try: report_test_results([str(bundle), mode, 'report', scripts])
                except SystemExit as error: assert error.code == 0
            assert json.loads(output.getvalue()) == {'nativeBatch': True}
    first = dict(name='界面截图', payloadId='first')
    second = dict(name='失败时的界面截图', payloadId='second')
    for activities, selected, expected in (([], '', None), ([first], 'missing', None),
            ([first, second], '', None), ([first, first], '', 'first'), ([first, second], 'second', 'second')):
        with patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'exists', return_value=False), \
                patch.object(Path, 'mkdir'), patch.object(Path, 'replace') as replaced, \
                patch.object(Path, 'unlink') as cleared, patch.object(subprocess, 'run') as exported, \
                patch.object(subprocess, 'check_output', return_value=json.dumps(activities)), redirect_stdout(StringIO()):
            try: report_test_results([str(bundle), 'Fixture/test()', 'screenshot', scripts, selected])
            except SystemExit as error: assert (error.code == 0) == bool(expected)
            else: raise AssertionError('截图导出需要明确退出状态。')
            if expected:
                arguments = exported.call_args.args[0]
                assert arguments[arguments.index('--id') + 1] == expected and exported.call_count == 1
                replaced.assert_called_once_with(root.parent / 'screenshot.png')
                assert cleared.call_count == 2
            else:
                exported.assert_not_called(); replaced.assert_not_called(); cleared.assert_not_called()
    module_failure_report_self_test()
    return []


def module_failure_report_self_test() -> None:
    from test_results import report_test_results, export_module_metrics
    scripts = Path(__file__).resolve().parent
    fixture = scripts.parent / '.build/static-audit/test-results-self-test'
    shutil.rmtree(fixture, ignore_errors=True)
    fixture.mkdir(parents=True)
    try:
        bundle = fixture / 'test-results.xcresult'
        bundle.mkdir()
        (bundle / 'Info.plist').write_text('old native result')
        metrics = fixture / 'test-metrics.txt'
        script = scripts / 'run-extended-tests.sh'
        source = script.read_text()
        branch = source[source.index('if [[ "$MODE" == "modules" ]]; then\n', source.index('trap finish_validation')):source.index('\nui_test_plan() {')]
        finish = 'finish_validation() {' + source.split('finish_validation() {', 1)[1].split('\ntrap finish_validation EXIT ZERR', 1)[0]
        import shlex
        harness = f'''set -euo pipefail
ROOT_DIR={shlex.quote(str(scripts.parent))} DERIVED_ROOT={shlex.quote(str(fixture))}
MODE=modules BUILD_ONLY=false validation_group=modules validation_scope=selected
WORKFLOW_STARTED_SECONDS=$SECONDS retained_result_groups=() TEST_SELECTIONS=()
python3() {{
  if [[ "$1" == "$ROOT_DIR/Scripts/validation_evidence.py" ]]; then return 0; fi
  command python3 "$@"
}}
bit101_run_logged() {{ print 'error: fixture module build failure' > "$DERIVED_ROOT/modules.log"; return 7; }}
'''
        environment = dict(os.environ, BIT101_VALIDATION_SOURCE_DIGEST='fixture', BIT101_VALIDATION_RUN_ID='fixture')
        result = subprocess.run(['zsh', '-c', harness + finish
            + '\ntrap finish_validation EXIT ZERR\n' + branch], env=environment, text=True, capture_output=True)
        assert result.returncode == 7, (result.stdout, result.stderr)
        assert metrics.with_name('test-failures.txt').is_file(), (result.stdout, result.stderr)
        assert 'fixture module build failure' in metrics.with_name('test-failures.txt').read_text()
        test = 'Consumer.Fixture/failing()/Tests.swift:1:1'
        events = [dict(kind='test', payload=dict(kind='function', id=test, isParameterized=False))]
        events += [dict(kind='event', payload=dict(kind=kind, testID=test if kind not in {'runStarted', 'runEnded'} else ''))
            for kind in ('runStarted', 'testStarted', 'issueRecorded', 'testEnded', 'runEnded')]
        for contents in (None, '\n'.join(map(json.dumps, events))):
            if contents is not None:
                (fixture / 'module-events.jsonl').write_text(contents)
                with patch.dict(os.environ, environment): export_module_metrics(['', str(metrics), str(scripts.parent), '7'])
            for mode in ('', 'json', 'coverage'):
                with redirect_stdout(output := StringIO()), patch.object(subprocess, 'check_output') as native:
                    try: report_test_results([str(bundle), mode, 'report', str(scripts)])
                    except SystemExit as error:
                        assert (error.code == 0) == (mode == 'json'), (mode, error)
                native.assert_not_called()
                if mode == 'json':
                    value = json.loads(output.getvalue())
                    assert value['passed'] is False and value['exitCode'] == 7
                    if contents is not None: assert value['failedTests'] == 1
                elif not mode: assert 'Failed' in output.getvalue() and 'fixture module build failure' in output.getvalue()
    finally: shutil.rmtree(fixture, ignore_errors=True)
