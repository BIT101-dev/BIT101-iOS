"""Exercise the real simulator producer, CI aggregation and portable-result export together."""
import json
import os
import plistlib
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
    maintenance_self_test()
    runtime_maintenance_self_test()
    from validation_policy import IOS_MODULE_COVERAGE_FLOORS
    from validation_simulator import METADATA_PREFIX
    from script_test_support import heredoc_body
    source = (ci.ROOT / 'Scripts/simulator-tests.sh').read_text()
    producer, selector = (heredoc_body(source, marker) for marker in ('PYRESULT', 'PYSELECT'))
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
            patch('validation_evidence.test_selectors', side_effect=lambda group: {name: name + '()' for name in inventory[group]}), \
            patch('validation_coverage.shard_inventory', side_effect=selected), \
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
                output = StringIO()
                with patch.object(sys, 'argv', ['selector', str(Path(ci.__file__).parent), group, 'full']), \
                        patch.dict(os.environ, BIT101_CI_SHARD=f'{index}/{count}'), redirect_stdout(output):
                    exec(compile(selector, '<simulator-selector>', 'exec'), {})
                scope, encoded, *selectors = output.getvalue().splitlines()
                expected = json.loads(encoded)
                assert scope == ('full' if group == 'release-runtime' else 'shard')
                assert expected == selected(group, index, count) and selectors == [name + '()' for name in expected]
                current_tree = tree(group, expected)
                arguments = ['producer', str(bundle), str(metrics), str(Path(ci.__file__).parent),
                    json.dumps(expected), '0', group, 'device', 'Debug', scope, '1']
                with patch.object(sys, 'argv', arguments), patch.dict(os.environ, BIT101_CI_SHARD=f'{index}/{count}'):
                    exec(compile(producer, '<simulator-producer>', 'exec'), {})
                assert METADATA_PREFIX in files[metrics]
                artifact = 'validation-ios-app-tests' if group == 'release-runtime' else f'validation-ios-test-shards-{"app" if group == "all" else group}-{index}'
                artifacts[artifact] = files[metrics], current_tree
        with patch('validation_coverage.shard_inventory', side_effect=AssertionError('完整范围沿全部库存选择。')):
            output = StringIO()
            with patch.object(sys, 'argv', ['selector', str(Path(ci.__file__).parent), 'release-runtime', 'full']), \
                    patch.dict(os.environ, BIT101_CI_SHARD='1/2'), redirect_stdout(output):
                exec(compile(selector, '<simulator-runtime-selector>', 'exec'), {})
            scope, encoded, *_ = output.getvalue().splitlines()
            assert scope == 'full' and json.loads(encoded) == inventory['release-runtime']
        for suffix in ('.retained.xcresult', '.incoming.xcresult'):
            bundles[bundle.with_suffix(suffix)] = tree('all', ['StaleFixture/testOldResult'])
        with patch('validation_environment.ci_commit_findings', return_value=['fixture commit mismatch']):
            try: ci.merge_simulator_ci()
            except ValueError: pass
            else: raise AssertionError('CI 合并需要先核对来源提交。')
        assert all(bundle.with_suffix(suffix) in bundles for suffix in ('.retained.xcresult', '.incoming.xcresult'))
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


def runtime_maintenance_self_test() -> None:
    from validation_simulator import manage_runtimes
    def runtime(family, version, device_type):
        return dict(identifier=family + version, name=family + ' ' + version, version=version,
            isAvailable=True, buildversion=version, supportedDeviceTypes=[dict(identifier=device_type)])
    old_ios, ios, old_watch, watch = (runtime(family, version, kind) for family, version, kind in (
        ('iOS', '27.0', 'phone'), ('iOS', '27.1', 'phone'), ('watchOS', '27.0', 'watch'), ('watchOS', '27.1', 'watch')))
    phone = dict(udid='phone', name='phone', state='Shutdown', deviceTypeIdentifier='phone')
    other = dict(udid='other-project', name='other', state='Shutdown', deviceTypeIdentifier='phone')
    wearable = dict(udid='watch', name='watch', state='Booted', deviceTypeIdentifier='watch')
    inventory = dict(runtimes=[old_ios, ios, old_watch], devices={
        old_ios['identifier']: [phone, other], ios['identifier']: [], old_watch['identifier']: [wearable]})
    commands = []
    def output(command, **kwargs):
        if command == ['xcrun', 'simctl', 'list', '--json']: return json.dumps(inventory)
        assert command == ['xcrun', 'simctl', 'runtime', 'list', '--json'], command
        return json.dumps({row['identifier']: dict(runtimeIdentifier=row['identifier'], sizeBytes=1024)
            for row in inventory['runtimes']})
    def execute(command, **kwargs):
        commands.append(command)
        if command[2] == 'upgrade':
            device = next(device for rows in inventory['devices'].values() for device in rows if device['udid'] == command[3])
            for rows in inventory['devices'].values():
                if device in rows: rows.remove(device); break
            inventory['devices'].setdefault(command[4], []).append(device)
    with patch.object(subprocess, 'check_output', output), patch.object(subprocess, 'run', execute), \
            patch.object(Path, 'is_file', return_value=False), redirect_stdout(StringIO()):
        for action in ('prune', 'upgrade'):
            try: manage_runtimes(action, '27.2')
            except ValueError: pass
            else: raise AssertionError('运行时维护需要已安装的目标版本。')
        try: manage_runtimes('prune', '27.1')
        except ValueError: pass
        else: raise AssertionError('运行时回收需要先迁移所属设备。')
        assert not commands
        for identifiers in (None, ['missing'], ['watch']):
            try: manage_runtimes('upgrade', '27.1', identifiers=identifiers)
            except ValueError: pass
            else: raise AssertionError('升级需要明确选择目标平台设备。')
        assert not commands
        manage_runtimes('upgrade', '27.1', identifiers=['phone'])
        assert inventory['devices'][ios['identifier']] == [phone]
        assert inventory['devices'][old_ios['identifier']] == [other]
        assert inventory['devices'][old_watch['identifier']] == [wearable]
        assert commands == [['xcrun', 'simctl', 'upgrade', 'phone', ios['identifier']]]
        commands.clear()
        manage_runtimes('upgrade', '27.1', identifiers=['other-project'])
        assert commands == [['xcrun', 'simctl', 'upgrade', 'other-project', ios['identifier']],
            ['xcrun', 'simctl', 'runtime', 'delete', old_ios['identifier']]]
        commands.clear()
        inventory['runtimes'].append(watch)
        manage_runtimes('upgrade', '27.1', 'watchOS', ['watch'])
        assert inventory['devices'][watch['identifier']] == [wearable]
        assert inventory['devices'][ios['identifier']] == [phone, other]
        assert commands == [['xcrun', 'simctl', 'shutdown', 'watch'],
            ['xcrun', 'simctl', 'upgrade', 'watch', watch['identifier']],
            ['xcrun', 'simctl', 'runtime', 'delete', old_watch['identifier']]]


def maintenance_self_test() -> None:
    from validation_simulator import clean_device_caches, remove_devices
    environment = dict(os.environ)
    environment.pop('BIT101_SIMULATOR_AUTHORIZED', None)
    help_result = subprocess.run(['zsh', str(Path(__file__).with_name('simulator-tests.sh')), '--help'],
        env=environment, capture_output=True, text=True)
    assert help_result.returncode == 0 and 'devices remove' in help_result.stdout
    environment['BIT101_SIMULATOR_AUTHORIZED'] = '1'
    rejected = subprocess.run(['zsh', str(Path(__file__).with_name('simulator-tests.sh')), 'runtime', 'invalid'],
        env=environment, capture_output=True, text=True)
    assert rejected.returncode == 64 and '用法' in rejected.stderr
    root = Path('/fixture/Library/Developer/CoreSimulator/Devices')
    inventory = dict(runtimes=[dict(identifier='ios'), dict(identifier='watch')], devices={
        'ios': [dict(udid='keep', state='Booted'), dict(udid='unused', state='Shutdown'),
                dict(udid='external', state='Shutdown')], 'watch': []})
    images = {name: dict(runtimeIdentifier=name, sizeBytes=1024) for name in ('ios', 'watch')}
    commands, removed = [], []
    folders = {root / 'keep/data' / part for part in ('Library/Caches', 'tmp',
        'Containers/Data/Application/app/Library/Caches', 'Containers/Data/Application/app/tmp')}

    def output(command, **kwargs):
        if command[:3] == ['xcrun', 'simctl', 'list']: return json.dumps(inventory)
        if command[:4] == ['xcrun', 'simctl', 'runtime', 'list']: return json.dumps(images)
        assert command[:2] == ['du', '-sk'], command
        return '1024\t' + command[2]

    def glob(path, pattern):
        if path == root / 'keep/data/Containers/Data/Application': return [path / 'app']
        if path == root / 'external/data/Containers/Bundle/Application': return [path / 'app/App.app/Info.plist']
        return []

    with patch.object(Path, 'home', return_value=Path('/fixture')), \
            patch.object(Path, 'glob', glob), \
            patch.object(Path, 'read_bytes', return_value=plistlib.dumps(dict(CFBundleIdentifier='org.example.personal'))), \
            patch.object(Path, 'is_dir', lambda path: path in folders), \
            patch.object(Path, 'iterdir', lambda path: iter([path / 'entry', path / 'images'])), \
            patch.object(Path, 'is_file', lambda path: path.name == 'entry'), \
            patch.object(Path, 'is_symlink', return_value=False), \
            patch.object(Path, 'unlink', lambda path: removed.append(path)), \
            patch.object(shutil, 'rmtree', lambda path: removed.append(path)), \
            patch.object(subprocess, 'check_output', output), \
            patch.object(subprocess, 'run', lambda command, **kwargs: commands.append(command)), \
            redirect_stdout(StringIO()):
        remove_devices(['unused'])
        assert commands == [['xcrun', 'simctl', 'delete', 'unused']]
        commands.clear()
        for action in (clean_device_caches, remove_devices):
            for identifiers in ([], ['missing']):
                try: action(identifiers)
                except ValueError: pass
                else: raise AssertionError('设备维护需要有效的显式清单。')
        assert commands == [] and removed == []
        try: remove_devices(['keep'])
        except ValueError: pass
        else: raise AssertionError('移除前需要关闭目标设备。')
        assert commands == []
        clean_device_caches(['keep'])
        assert commands == [['xcrun', 'simctl', 'shutdown', 'keep']]
        assert set(removed) == {folder / name for folder in folders for name in ('entry', 'images')}
