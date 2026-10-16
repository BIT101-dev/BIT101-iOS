"""Compare coverage with versioned policy and combine complete Simulator shards."""
from pathlib import Path

COVERAGE_GROUPS = frozenset({'modules', 'all', 'ui', 'catalyst', 'catalyst-release-runtime'})
SIMULATOR_SHARDS = {'all': 1, 'ui': 3, 'release-runtime': 1}
SIMULATOR_WORKERS = {'app': 1, 'ui': 1, 'release-runtime': 1}
SIMULATOR_KEYBOARD_TESTS = frozenset({
    'ServiceInteractionUITests/testManualUpdatePromptAllActionsAndCurrentVersion',
    'AccountRecoveryUITests/testFutureScheduleImportUpdateCancellationAndLink',
})


def restore_test_host_permissions(products: Path) -> None:
    import plistlib
    import stat
    for directory in products.iterdir():
        if not directory.name.endswith(('-iphonesimulator', '-watchsimulator')): continue
        for info in directory.rglob('Info.plist'):
            metadata = plistlib.loads(info.read_bytes())
            if name := metadata.get('CFBundleExecutable'):
                executable = info.parent / name
                executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def prepare_simulator_system(device: str, root: Path, *, ui: bool) -> None:
    import os
    import subprocess
    import time
    developer = Path(os.getenv('DEVELOPER_DIR') or subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    subprocess.run(['open', '-g', '-a', str(developer.parent / 'Applications/DeviceHub.app')], check=True)
    container = Path.home() / 'Library/Containers/com.apple.dt.Devices'
    deadline = time.monotonic() + 10
    while not container.is_dir():
        if time.monotonic() >= deadline: raise ValueError('Device Hub 首次启动需要建立应用容器。')
        time.sleep(0.1)
    subprocess.run(['defaults', '-container', 'com.apple.dt.Devices', 'write', 'com.apple.dt.Devices',
        'alwaysSimulateHardwareKeyboard', '-bool', 'true'], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'], check=True)
    if ui:
        subprocess.run(['xcrun', 'simctl', 'addmedia', device,
            str(root / 'BIT101-iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')], check=True)


def prepare_simulator_ui(device: str, products: Path) -> None:
    import json
    import os
    import socket
    import subprocess
    import time
    app = products / 'Release-iphonesimulator/BIT101-iOS.app'
    subprocess.run(['xcrun', 'simctl', 'install', device, str(app)], check=True)
    port = 20000 + int(device[-4:], 16) % 40000
    environment = dict(os.environ, **{'SIMCTL_CHILD_' + key: value for key, value in {
        'BIT101_UI_TESTING': '1', 'BIT101_UI_TEST_CONTROL_PORT': str(port),
        'BIT101_UI_TEST_CASE': 'simulator-bootstrap', 'BIT101_UI_TEST_RUN_ID': 'ui',
        'BIT101_UI_TEST_RESET_STORAGE': '1',
    }.items()})
    subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', device,
        'BIT101-dev.BIT101-iOS', '--ui-testing'], env=environment, check=True, stdout=subprocess.DEVNULL)
    try:
        request = json.dumps({'command': 'observe'}).encode() + b'\n'
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=1) as connection:
                    connection.sendall(request)
                    with connection.makefile('rb') as stream: response = stream.readline().decode().strip()
                if response == 'simulator-bootstrap / 登录':
                    break
            except OSError:
                pass
            time.sleep(0.1)
        else:
            raise ValueError('完整模拟器初始化需要呈现隔离测试 App 的登录首屏。')
    finally:
        subprocess.run(['xcrun', 'simctl', 'terminate', device, 'BIT101-dev.BIT101-iOS'], check=True)


def simulator_ui_batches(selections: list[str], workers: int) -> list[tuple[list[str], int]]:
    keyboard = [row for row in selections if row.removeprefix('-only-testing:BIT101-iOSUITests/') in SIMULATOR_KEYBOARD_TESTS]
    remaining = [row for row in selections if row not in keyboard]
    count = min(workers, len({row.split('/')[1] for row in remaining}))
    if count <= 1: return [(selections, 1)] if selections else []
    return [(rows, size) for rows, size in ((keyboard, 1), (remaining, count)) if rows]


def run_simulator_ui(plan: Path, derived: Path, device: str, workers: int, selections: list[str]) -> int:
    import plistlib
    import shutil
    import subprocess
    from validation_performance import result_bundle_complete
    result = derived / 'test-results.xcresult'
    keyboard_result = derived / 'Build/keyboard-tests.xcresult'
    shutil.rmtree(keyboard_result, ignore_errors=True)
    keyboard_profile = derived / 'Build/ProfileData/keyboard.profdata'
    batches = simulator_ui_batches(selections, workers)
    status = 0
    for index, (tests, count) in enumerate(batches):
        configuration = plistlib.loads(plan.read_bytes())
        for group in configuration.get('TestConfigurations', []):
            for target in group.get('TestTargets', []): target['ParallelizationEnabled'] = count > 1
        plan.write_bytes(plistlib.dumps(configuration))
        arguments = ['-parallel-testing-enabled', 'YES', '-parallel-testing-worker-count', str(count)] if count > 1 else ['-parallel-testing-enabled', 'NO']
        completed = subprocess.run(['xcodebuild', 'test-without-building', '-quiet', '-xctestrun', str(plan),
            '-derivedDataPath', str(derived), '-destination', 'platform=iOS Simulator,id=' + device,
            '-resultBundlePath', str(result), *arguments, '-test-timeouts-enabled', 'YES', '-collect-test-diagnostics', 'never', '-enableCodeCoverage', 'YES', *tests])
        status = status or completed.returncode
        if not result_bundle_complete(result) or completed.returncode and index + 1 < len(batches): return status or 1
        if index + 1 < len(batches):
            result.rename(keyboard_result)
            shutil.copyfile(derived / 'Build/ProfileData' / device / 'Coverage.profdata', keyboard_profile)
    if keyboard_result.exists():
        from validation_performance import merge_result_bundles
        merge_result_bundles(keyboard_result, result.with_suffix('.incoming.xcresult'))
    return status


def shard_inventory(group: str, index: int, count: int) -> list[str]:
    from validation_test_areas import test_inventory
    if group not in SIMULATOR_SHARDS or count != SIMULATOR_SHARDS[group] or not 0 <= index < count:
        raise ValueError('模拟器分片需要匹配登记的完整库存分配。')
    inventory = sorted(test_inventory(group))
    if group != 'ui': return inventory[index::count]
    from validation_inputs import performance_workloads
    weights = {test: workload.get('weekSwitchPairs', 1) for test, workload in performance_workloads().values()}
    parts, costs = [[] for _ in range(count)], [0] * count
    for test in sorted(inventory, key=lambda test: (-weights.get(test, 1), test)):
        destination = min(range(count), key=costs.__getitem__)
        parts[destination].append(test)
        costs[destination] += weights.get(test, 1)
    return sorted(parts[index])


def coverage_source_path(filename: str, root: Path) -> Path:
    path = Path(filename)
    prefix = Path('/^src')
    return (root / path.relative_to(prefix)).resolve() if path.is_relative_to(prefix) else path


def lcov_lines(source: str, root: Path) -> dict[str, dict[str, list[int]]]:
    files, path, lines = {}, None, {}
    for row in source.splitlines():
        if row.startswith('SF:'):
            path, lines = coverage_source_path(row[3:], root), {}
        elif row.startswith('DA:'):
            number, hits, *_ = row[3:].split(',')
            lines[int(number)] = int(hits)
        elif row == 'end_of_record' and path is not None and path.is_relative_to(root):
            name = path.relative_to(root).as_posix()
            files[name] = {'executable': sorted(lines), 'covered': sorted(line for line, hits in lines.items() if hits > 0)}
    if not files: raise ValueError('分片覆盖率需要包含生产源码行。')
    return files


def combined_line_coverage(shards: list[dict]) -> dict:
    if not shards: raise ValueError('覆盖率汇总需要完整分片。')
    reference = {name: row['executable'] for name, row in shards[0].items()}
    covered = {name: set() for name in reference}
    for shard in shards:
        if {name: row['executable'] for name, row in shard.items()} != reference:
            raise ValueError('分片覆盖率需要来自相同的可执行源码行。')
        for name, row in shard.items():
            if not set(row['covered']) <= set(reference[name]): raise ValueError('覆盖行需要归属于可执行源码行。')
            covered[name].update(row['covered'])
    result = {}
    for name, executable in reference.items():
        targets = ['BIT101-iOS.app']
        if name.startswith('Modules/') and '/Sources/' in name: targets.append('iOS/' + name.split('/')[1])
        for target in targets:
            row = result.setdefault(target, {'coveredLines': 0, 'executableLines': 0})
            row['coveredLines'] += len(covered[name])
            row['executableLines'] += len(executable)
    return result


def policy_floors(group: str, policy: dict) -> dict[str, int]:
    from validation_policy import APP_COVERAGE_FLOOR, MODULE_COVERAGE_FLOORS, IOS_MODULE_COVERAGE_FLOORS, UI_PRODUCTION_MODULES
    current = MODULE_COVERAGE_FLOORS if group == 'modules' else IOS_MODULE_COVERAGE_FLOORS
    if group == 'ui': current = {name: current[name] for name in UI_PRODUCTION_MODULES}
    if group == 'catalyst': current = {name: value for name, value in current.items() if name != 'ScheduleActivityContracts'}
    if group == 'catalyst-release-runtime': return {}
    prefix = '' if group == 'modules' else 'Catalyst/' if group == 'catalyst' else 'iOS/'
    baseline_group = 'all' if group in {'ui', 'catalyst'} else group
    floors = {prefix + name: max(value, policy.get(baseline_group, {}).get(name, value)) for name, value in current.items()}
    if group in {'all', 'ui', 'catalyst'}:
        floors['BIT101-iOS.app'] = max(APP_COVERAGE_FLOOR, policy.get('all', {}).get('BIT101-iOS.app', APP_COVERAGE_FLOOR))
    return floors


def percentages(coverage: dict) -> dict[str, int]:
    return {name: row['coveredLines'] * 100 // row['executableLines'] for name, row in coverage.items()
        if type(row.get('coveredLines')) is int and type(row.get('executableLines')) is int and row['executableLines'] > 0}


def regressions(coverage: dict, baseline: dict) -> list[str]:
    current = percentages(coverage)
    return [f'{name}: {current[name]}% < {floor}%' for name, floor in baseline.items() if name in current and current[name] < floor]


def policy_findings(report: dict, group: str) -> list[str]:
    if group not in COVERAGE_GROUPS: return []
    from validation_provenance import complete_group_row
    row = complete_group_row(report.get('groups', {}).get(group, {}))
    return [f'{group} 覆盖率退化：{problem}' for problem in regressions(
        row.get('summary', {}).get('coverage', {}), policy_floors(group, report.get('coveragePolicy', {})))]


def self_test(evidence) -> None:
    simulator_ui_preparation_self_test()
    native_coverage_self_test(evidence)
    from validation_policy import workflow_timeout_seconds
    from validation_test_areas import test_inventory
    inventory = sorted(test_inventory('ui'))
    assert SIMULATOR_KEYBOARD_TESTS <= set(inventory)
    selections = ['-only-testing:BIT101-iOSUITests/' + row for row in inventory]
    batches = simulator_ui_batches(selections, 3)
    assert [count for _, count in batches] == [1, 3]
    assert len(batches[0][0]) == len(SIMULATOR_KEYBOARD_TESTS)
    assert sorted(row for rows, _ in batches for row in rows) == selections
    assert simulator_ui_batches([selections[0]], 3) == [([selections[0]], 1)]
    assert simulator_ui_batches([], 3) == []
    import plistlib
    from types import SimpleNamespace
    from unittest.mock import patch
    plan = plistlib.dumps({'TestConfigurations': [{'TestTargets': [{}]}]})
    with patch.object(Path, 'read_bytes', return_value=plan), patch.object(Path, 'write_bytes') as written, \
            patch.object(Path, 'rename') as renamed, patch.object(Path, 'exists', return_value=True), \
            patch('shutil.rmtree'), patch('shutil.copyfile') as copied, \
            patch('subprocess.run', side_effect=[SimpleNamespace(returncode=0), SimpleNamespace(returncode=7)]) as executed, \
            patch('validation_performance.result_bundle_complete', return_value=True), \
            patch('validation_performance.merge_result_bundles') as merged:
        assert run_simulator_ui(Path('/fixture/plan'), Path('/fixture'), 'device', 3, selections) == 7
        assert [plistlib.loads(call.args[0])['TestConfigurations'][0]['TestTargets'][0]['ParallelizationEnabled']
            for call in written.call_args_list] == [False, True]
        assert [call.args[0][call.args[0].index('-parallel-testing-enabled') + 1] for call in executed.call_args_list] == ['NO', 'YES']
        assert renamed.call_count == copied.call_count == merged.call_count == 1
        assert [[arg for arg in call.args[0] if arg.startswith('-only-testing:')] for call in executed.call_args_list] == [rows for rows, _ in batches]
    assert workflow_timeout_seconds(('network', 'community-writes')) == 95 * 60
    assert workflow_timeout_seconds(('all', 'all')) == 50 * 60
    for group in ('all', 'ui', 'catalyst'):
        assert policy_floors(group, {'all': {'BIT101-iOS.app': 60}})['BIT101-iOS.app'] == 60
        assert policy_floors(group, {'all': {'BIT101-iOS.app': 1}})['BIT101-iOS.app'] == 35
    assert policy_floors('catalyst', {'all': {'TransportCore': 90}})['Catalyst/TransportCore'] == 90
    assert 'Catalyst/ScheduleActivityContracts' not in policy_floors('catalyst', {})
    assert policy_floors('ui', {'all': {'GalleryFeature': 40}})['iOS/GalleryFeature'] == 40
    assert policy_floors('ui', {'all': {'GalleryFeature': 1}})['iOS/GalleryFeature'] == 14
    assert 'iOS/StorageCore' not in policy_floors('ui', {'all': {'StorageCore': 90}})
    for name in ('MediaKit', 'DesignSystemKit'):
        floors = policy_floors('ui', {'all': {name: 90}})
        assert floors['iOS/' + name] == 90
        assert regressions({'iOS/' + name: {'coveredLines': 89, 'executableLines': 100}}, floors)
    assert regressions({'iOS/GalleryFeature': {'coveredLines': 39, 'executableLines': 100}},
        policy_floors('ui', {'all': {'GalleryFeature': 40}}))
    assert regressions({'Feature': {'coveredLines': 79, 'executableLines': 100}}, {'Feature': 80})
    assert not regressions({'Feature': {'coveredLines': 801, 'executableLines': 1001}}, {'Feature': 80})
    from unittest.mock import patch
    with patch('validation_test_areas.test_inventory', return_value={'a', 'b', 'c', 'd', 'e'}):
        count = SIMULATOR_SHARDS['ui']
        parts = [shard_inventory('ui', index, count) for index in range(count)]
        assert sorted(test for part in parts for test in part) == ['a', 'b', 'c', 'd', 'e']
        for index, invalid_count in ((-1, count), (count, count), (0, count + 1)):
            try: shard_inventory('ui', index, invalid_count)
            except ValueError: pass
            else: raise AssertionError('分片边界及登记数量需要严格匹配。')
    inventory = {'Layout/testWeeks', *(f'Suite/test{index:02}' for index in range(30))}
    with patch('validation_test_areas.test_inventory', return_value=inventory), \
            patch('validation_inputs.performance_workloads', return_value={'layout': ('Layout/testWeeks', {'weekSwitchPairs': 10})}):
        parts = [shard_inventory('ui', index, 3) for index in range(3)]
        costs = [sum(10 if test == 'Layout/testWeeks' else 1 for test in part) for part in parts]
        assert max(costs) - min(costs) <= 1 and 'Layout/testWeeks' in parts[0]
        assert sorted(test for part in parts for test in part) == sorted(inventory)
    first = lcov_lines('SF:/repo/Modules/Feature/Sources/A.swift\nDA:1,1\nDA:2,0\nDA:3,0\nend_of_record', Path('/repo'))
    second = lcov_lines('SF:/repo/Modules/Feature/Sources/A.swift\nDA:1,2\nDA:2,1\nDA:3,0\nend_of_record', Path('/repo'))
    mapped = 'SF:/^src/Modules/Feature/Sources/A.swift\nDA:1,1\nDA:2,0\nDA:3,0\nend_of_record'
    assert lcov_lines(mapped, Path('/repo')) == first
    foreign = '\nSF:/^src/../foreign/A.swift\nDA:1,1\nend_of_record'
    assert lcov_lines(mapped + foreign, Path('/repo')) == first
    assert coverage_source_path('/^sdk/Foundation.swift', Path('/repo')) == Path('/^sdk/Foundation.swift')
    assert combined_line_coverage([first, second]) == {name: {'coveredLines': 2, 'executableLines': 3}
        for name in ('iOS/Feature', 'BIT101-iOS.app')}
    assert combined_line_coverage([first, first])['iOS/Feature']['coveredLines'] == 1
    for invalid in ({}, {'Modules/Feature/Sources/A.swift': {'executable': [1, 2], 'covered': [1]}},
            {'Modules/Feature/Sources/A.swift': {'executable': [1, 2, 3], 'covered': [4]}}):
        try: combined_line_coverage([first, invalid])
        except ValueError: pass
        else: raise AssertionError('覆盖率汇总需要验证源码行身份。')


def native_coverage_self_test(evidence) -> None:
    import io
    import json
    import plistlib
    from types import SimpleNamespace
    from unittest.mock import patch
    root = Path('/fixture')
    for catalyst in (False, True):
        for debug in (False, True):
            for include_app in (False, True):
                contents = root / 'Products/BIT101-iOS.app' / ('Contents' if catalyst else '')
                executable = contents / ('MacOS/Executable' if catalyst else 'Executable')
                framework = contents / 'Frameworks/Feature.framework'
                def artifacts(path, pattern):
                    return [framework] if pattern == '*.framework' else [executable.parent / 'Executable.debug.dylib'] if debug else []
                raw = {'data': [{'files': [dict(filename=path, summary={'lines': dict(covered=hit, count=total)})
                    for path, hit, total in [('/^src/BIT101-iOS/Main.swift', 4, 10),
                        ('/^src/Modules/Feature/Sources/A.swift', 8, 10), ('/^sdk/Foundation.swift', 100, 100)]]}]}
                with patch.object(evidence, 'ROOT', root), patch.object(Path, 'glob', artifacts), \
                        patch.object(Path, 'open', side_effect=lambda *args, **kwargs: io.BytesIO(plistlib.dumps({'CFBundleExecutable': 'Executable'}))), \
                        patch('subprocess.run', return_value=SimpleNamespace(stdout=json.dumps(raw), stderr='')) as exported:
                    result = evidence.native_source_coverage(root / 'Products', root / 'Coverage.profdata', catalyst=catalyst, include_app=include_app)
                assert result == {'Feature': (8, 10)} | ({'BIT101-iOS.app': (4, 10)} if catalyst or include_app else {})
                command = exported.call_args.args[0]
                assert (str(executable.parent / 'Executable.debug.dylib') in command) == debug
                assert str(framework / 'Executable') in command


def simulator_ui_preparation_self_test() -> None:
    import io
    import json
    from unittest.mock import patch
    import plistlib
    from types import SimpleNamespace
    from contextlib import redirect_stdout
    device_source = Path(__file__).with_name('simulator-tests.sh').read_text().split("<<'PYDEVICE'\n", 1)[1].split('\nPYDEVICE\n', 1)[0]
    for hosted, operation, prepared, reused in (
            ('true', 'app', True, True), ('true', 'release-runtime', True, True), ('true', 'ui', True, True),
            ('false', 'app', True, False), ('true', 'prepare', True, False), ('true', 'ui', False, False)):
        output = io.StringIO()
        with patch.dict('os.environ', {'GITHUB_ACTIONS': hosted}), \
                patch('sys.argv', ['device-selection', '/fixture/device.json', operation]), \
                patch.object(Path, 'is_file', return_value=prepared), \
                patch.object(Path, 'read_text', return_value='{"identifier":"device"}'), \
                patch('subprocess.check_output', side_effect=RuntimeError('inventory')) as inventory, redirect_stdout(output):
            try: exec(compile(device_source, 'simulator-device-selection', 'exec'), {})
            except SystemExit as result:
                assert reused and result.code == 0 and output.getvalue().strip() == 'device'
                inventory.assert_not_called()
            except RuntimeError as error:
                assert not reused and str(error) == 'inventory'
                inventory.assert_called_once_with(['xcrun', 'simctl', 'list', '--json'], text=True)
            else: raise AssertionError('设备选择需要复用准备结果或读取原生库存。')
    with patch.object(Path, 'iterdir', return_value=iter([Path('/products/Release-iphonesimulator'), Path('/products/Release-maccatalyst')])), \
            patch.object(Path, 'rglob', return_value=[Path('/products/Release-iphonesimulator/Host.app/Info.plist')]) as bundles, \
            patch.object(Path, 'read_bytes', return_value=plistlib.dumps({'CFBundleExecutable': 'Host'})), \
            patch.object(Path, 'stat', return_value=SimpleNamespace(st_mode=0o100644)), patch.object(Path, 'chmod') as permissions:
        restore_test_host_permissions(Path('/products'))
        bundles.assert_called_once_with('Info.plist')
        permissions.assert_called_once_with(0o100755)
    for ui in (False, True):
        with patch('subprocess.run') as run, patch.object(Path, 'is_dir', return_value=True), \
                patch.dict('os.environ', {'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}):
            prepare_simulator_system('device', Path('/repo'), ui=ui)
            commands = [call.args[0] for call in run.call_args_list]
            assert commands[0] == ['open', '-g', '-a', '/Applications/Xcode.app/Contents/Applications/DeviceHub.app']
            assert commands[1][-3:] == ['alwaysSimulateHardwareKeyboard', '-bool', 'true']
            assert commands[2] == ['xcrun', 'simctl', 'bootstatus', 'device', '-b']
            assert len(commands) == (4 if ui else 3)
            if ui: assert commands[3] == ['xcrun', 'simctl', 'addmedia', 'device', '/repo/BIT101-iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png']
    for developer in ('/Applications/Xcode.app/Contents/Developer', ''):
        with patch('subprocess.run') as run, patch.object(Path, 'is_dir', return_value=False), \
                patch.dict('os.environ', {'DEVELOPER_DIR': developer}), \
                patch('subprocess.check_output', return_value='/Applications/Xcode.app/Contents/Developer') as selected, \
                patch('time.monotonic', side_effect=[0, 11]):
            try: prepare_simulator_system('device', Path('/repo'), ui=True)
            except ValueError as error: assert '应用容器' in str(error)
            else: raise AssertionError('系统初始化应沿容器就绪期限结束。')
            assert len(run.call_args_list) == 1
            if developer: selected.assert_not_called()
            else: selected.assert_called_once_with(['xcode-select', '-p'], text=True)
    for response, expected in (('simulator-bootstrap / 登录', True), ('', False),
            ('another scene / 登录', False), ('simulator-bootstrap / 日程', False)):
        with patch('socket.create_connection') as connect, patch('subprocess.run') as run, \
                patch('time.monotonic', side_effect=[0, 0, 61]), patch('time.sleep'):
            connection = connect.return_value.__enter__.return_value
            connection.makefile.return_value = io.BytesIO(response.encode() + b'\n')
            try: prepare_simulator_ui('0000abcd', Path('/products')); passed = True
            except ValueError as error:
                assert '登录首屏' in str(error)
                passed = False
            assert passed == expected
            commands = [call.args[0] for call in run.call_args_list]
            assert [command[2] for command in commands] == ['install', 'launch', 'terminate']
            assert commands[0][-1] == '/products/Release-iphonesimulator/BIT101-iOS.app'
            assert commands[1][-1] == '--ui-testing' and commands[-1][-1] == 'BIT101-dev.BIT101-iOS'
            environment = run.call_args_list[1].kwargs['env']
            assert environment['SIMCTL_CHILD_BIT101_UI_TEST_RESET_STORAGE'] == '1'
            assert environment['SIMCTL_CHILD_BIT101_UI_TEST_CASE'] == 'simulator-bootstrap'
            assert connect.call_args.args[0] == ('127.0.0.1', int(environment['SIMCTL_CHILD_BIT101_UI_TEST_CONTROL_PORT']))
            assert json.loads(connection.sendall.call_args.args[0]) == {'command': 'observe'}
