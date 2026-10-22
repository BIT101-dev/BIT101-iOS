"""Keep report families and exported screenshot choices tied to the selected result batch."""
import json
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
                patch.object(Path, 'unlink') as cleared, patch.object(subprocess, 'run') as exported, \
                patch.object(subprocess, 'check_output', return_value=json.dumps(activities)), redirect_stdout(StringIO()):
            try: report_test_results([str(bundle), 'Fixture/test()', 'screenshot', scripts, selected])
            except SystemExit as error: assert (error.code == 0) == bool(expected)
            else: raise AssertionError('截图导出需要明确退出状态。')
            cleared.assert_called_once_with(missing_ok=True)
            if expected:
                arguments = exported.call_args.args[0]
                assert arguments[arguments.index('--id') + 1] == expected and exported.call_count == 1
            else: exported.assert_not_called()
    return []
