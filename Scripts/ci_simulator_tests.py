"""Exercise the real simulator producer, CI aggregation and portable-result export together."""
import json
import os
import shutil
import subprocess
import sys
from contextlib import ExitStack, nullcontext, redirect_stdout
from copy import deepcopy
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


def self_test(ci, context: dict, platform: dict, environment_fixture) -> None:
    from validation_policy import IOS_MODULE_COVERAGE_FLOORS
    from validation_simulator import METADATA_PREFIX
    producer = (ci.ROOT / 'Scripts/simulator-tests.sh').read_text().split("<<'PYRESULT'\n", 1)[1].split('\nPYRESULT\n', 1)[0]
    root, commit, run = Path('/fixture'), 'a' * 40, '8'
    work = root / '.build/extended-automation'
    report, metrics, bundle = work / 'validation-evidence.json', work / 'test-metrics.txt', work / 'test-results.xcresult'
    result_file = work / 'ci-validation-result.json'
    inventory = {'all': ['AppFixture/testBehavior'], 'release-runtime': ['RuntimeFixture/testComposition']}
    cases = {name: 1 for names in inventory.values() for name in names}
    lines = {f'Modules/{name}/Sources/fixture.swift': {'covered': [1], 'executable': [1]}
        for name in IOS_MODULE_COVERAGE_FLOORS}
    runtime = dict(identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0', isAvailable=True,
        version=platform['systemVersion'], buildversion=platform['systemBuild'])
    simulator = dict(runtimes=[runtime], devices={runtime['identifier']: [{'udid': 'device'}]})
    plan = dict(commit=commit, run=run, jobs={name: dict(execute=True) for name in ('modules', 'release', 'catalyst', 'app')})
    files, bundles, artifacts = {report: json.dumps({'coveragePolicy': {}})}, {}, {}
    current_tree = {}

    def tree(group, selected):
        target = 'BIT101-iOSUITests' if group == 'ui' else 'BIT101-iOSTests'
        return dict(devices=[dict(platform='iOS Simulator', deviceId='device')], children=[dict(nodeType='Test Case',
            nodeIdentifier=name + '()', result='Passed', nodeIdentifierURL=f'test://com.apple.xcode/BIT101-iOS/{target}/{name}()')
            for name in selected])

    def check_output(command, **kwargs):
        if command[:3] == ['git', 'rev-parse', 'HEAD']: return commit
        if command[:4] == ['xcrun', 'simctl', 'list', '--json']: return json.dumps(simulator)
        assert command[:4] == ['xcrun', 'xcresulttool', 'get', 'test-results'], command
        value = bundles.get(Path(command[command.index('--path') + 1]), current_tree)
        if command[4] == 'tests': return json.dumps(value)
        count = len(value['children'])
        return json.dumps(dict(result='Passed', totalTestCount=count, passedTests=count, failedTests=0, skippedTests=0))

    def command(arguments, **kwargs):
        if arguments[:3] == ['gh', 'run', 'download']:
            artifact = arguments[arguments.index('--name') + 1]
            if artifact == 'validation-static-audit': return SimpleNamespace(returncode=0)
            files[metrics], bundles[bundle] = deepcopy(artifacts[artifact])
        elif arguments[:3] == ['xcrun', 'xcresulttool', 'merge']:
            incoming, retained, downloaded = map(Path, arguments[4:7])
            bundles[incoming] = dict(devices=[dict(platform='iOS Simulator', deviceId='device')],
                children=bundles[retained]['children'] + bundles[downloaded]['children'])
        else: assert arguments[:3] == ['xcrun', 'llvm-profdata', 'merge'], arguments
        return SimpleNamespace(returncode=0)

    class Writer(StringIO):
        def __init__(self, path, mode):
            self.path = path
            super().__init__(files.get(path, '') if mode == 'a' else '')
            self.seek(0, 2)
        def close(self):
            files[self.path] = self.getvalue()
            super().close()

    def read(path, *args, **kwargs): return files[path]
    def write(path, value, **kwargs): files[path] = value; return len(value)
    def remove(path, **kwargs):
        bundles.pop(Path(path), None)
    def move(source, target): bundles[Path(target)] = bundles.pop(Path(source))
    def selected(group, index, count): return inventory[group][index::count]
    profile = work / 'Build/ProfileData/device/Coverage.profdata'
    patches = [patch.object(ci, 'ROOT', root), patch.object(ci, 'REPORT', report), patch.object(ci, 'RESULT_FILE', result_file), \
            patch.object(ci, 'read_validation_plan', return_value=plan), \
            patch.object(ci, 'ci_validation_environment', side_effect=environment_fixture), \
            patch('validation_environment.environment_context', return_value=context), \
            patch('validation_environment.ci_commit_findings', return_value=[]), \
            patch('validation_evidence.test_inventory', side_effect=lambda group: inventory[group]), \
            patch('validation_evidence.test_case_inventory', return_value=cases), \
            patch('validation_evidence.native_source_coverage', return_value=lines), \
            patch('validation_evidence.validate_community_write_test_output'), \
            patch('validation_coverage.shard_inventory', side_effect=selected), \
            patch('validation_provenance.report_lock', side_effect=lambda **kwargs: nullcontext()), \
            patch('validation_provenance.write_report', side_effect=lambda value, **kwargs: write(report, json.dumps(value))), \
            patch.object(subprocess, 'check_output', side_effect=check_output), patch.object(subprocess, 'run', side_effect=command), \
            patch.object(shutil, 'rmtree', side_effect=remove), patch.object(shutil, 'move', side_effect=move), \
            patch.object(Path, 'read_text', read), patch.object(Path, 'write_text', write), \
            patch.object(Path, 'open', lambda path, mode='r', **kwargs: Writer(path, mode)), \
            patch.object(Path, 'mkdir'), patch.object(Path, 'chmod'), \
            patch.object(Path, 'stat', return_value=SimpleNamespace(st_mode=0o600)), \
            patch.object(Path, 'exists', lambda path: path in bundles or path in files), \
            patch.object(Path, 'is_file', lambda path: path == report or path.name == 'Info.plist'), \
            patch.object(Path, 'glob', return_value=[profile]), patch.object(Path, 'replace'), \
            patch.object(Path, 'unlink', lambda path, **kwargs: files.pop(path, None)), \
            patch.dict(os.environ, GITHUB_RUN_ID=run), redirect_stdout(StringIO())]
    with ExitStack() as stack:
        for context in patches: stack.enter_context(context)
        for group, count in (('all', 1), ('release-runtime', 1)):
            for index in range(count):
                expected = selected(group, index, count)
                current_tree = tree(group, expected)
                scope = 'full' if group == 'release-runtime' else 'shard'
                arguments = ['producer', str(bundle), str(metrics), str(Path(ci.__file__).parent),
                    json.dumps(expected), '0', group, 'device', 'Debug', scope, '1']
                with patch.object(sys, 'argv', arguments), patch.dict(os.environ, BIT101_CI_SHARD=f'{index}/{count}'):
                    exec(compile(producer, '<simulator-producer>', 'exec'), {})
                assert METADATA_PREFIX in files[metrics]
                artifact = 'validation-ios-app-tests' if group == 'release-runtime' else f'validation-ios-test-shards-{"app" if group == "all" else group}-{index}'
                artifacts[artifact] = files[metrics], current_tree
        for suffix in ('.retained.xcresult', '.incoming.xcresult'):
            bundles[bundle.with_suffix(suffix)] = tree('all', ['StaleFixture/testOldResult'])
        ci.merge_simulator_ci()
        assert all(bundle.with_suffix(suffix) not in bundles for suffix in ('.retained.xcresult', '.incoming.xcresult'))
        merged = json.loads(files[report])
        assert 'groups' not in merged and set(merged['simulatorResults']) == set(inventory)
        ci.export_validation_result('ios')
        result = json.loads(files[result_file])
        assert result['commit'] == commit and result['run'] == run and set(result['groups']) == {'app'}
        assert result['groups']['app']['environment']['platform'] == platform
        for scope, field, value in (('release-runtime', 'identity', {}), ('all', 'environment', {}),
                ('all', 'summary', {})):
            invalid = deepcopy(merged)
            invalid['simulatorResults'][scope][field] = value
            files[report] = json.dumps(invalid)
            try: ci.export_validation_result('ios')
            except ValueError: pass
            else: raise AssertionError('完整模拟器结果需要正式组装、库存、来源与生产环境。')
        invalid = deepcopy(merged)
        invalid['simulatorResults']['all']['summary']['coverage']['BIT101-iOS.app']['coveredLines'] = 0
        files[report] = json.dumps(invalid)
        try: ci.export_validation_result('ios')
        except ValueError: pass
        else: raise AssertionError('导出继续核对合并覆盖率。')
        files[report] = json.dumps(merged)
        plan['jobs']['app']['execute'] = False
        try: ci.export_validation_result('ios')
        except ValueError: pass
        else: raise AssertionError('完整通过的当前分组生成成功记录。')
        plan['jobs']['app']['execute'] = True
        artifacts['validation-ios-app-tests'] = (files[metrics], tree('release-runtime', inventory['release-runtime']))
        try: ci.merge_simulator_ci()
        except ValueError: pass
        else: raise AssertionError('正式组装产物需要自己的生产记录。')
