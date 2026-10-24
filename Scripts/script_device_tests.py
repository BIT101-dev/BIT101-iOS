"""Verify shared device selection through public shell configuration and cached identity pairs."""
import json
import shlex
import subprocess
from pathlib import Path


def device_discovery_boundary_findings() -> list[str]:
    support = Path(__file__).with_name('script-support.sh')
    findings = []
    def candidate(name, transport, tunnel='connected', pairing='paired', reality='physical'):
        return dict(identifier=name, hardwareProperties=dict(udid=name, deviceType='iPhone', reality=reality),
            connectionProperties=dict(transportType=transport, tunnelState=tunnel, pairingState=pairing),
            deviceProperties=dict(name=name))

    def select(devices, setup='', requested=''):
        snapshot = shlex.quote(json.dumps({'result': {'devices': devices}}))
        code = f'source {shlex.quote(str(support))}\n'
        code += 'unset BIT101_XCODE_DEVICE_ID BIT101_DEVICETCL_DEVICE_ID BIT101_DEVICE_TRANSPORT BIT101_DEVICE_NAME\n'
        code += setup + '\n'
        code += f'bit101_device_snapshot() {{ print -r -- {snapshot}; }}\nbit101_find_device {shlex.quote(requested)} || exit 1\n'
        code += 'print -r -- "$BIT101_XCODE_DEVICE_ID:$BIT101_DEVICETCL_DEVICE_ID"\n'
        return subprocess.run(['zsh', '-c', code], capture_output=True, text=True)

    for devices, expected in (
        ([candidate('wireless', 'localNetwork'), candidate('wired', 'wired')], 'wired'),
        ([candidate('wireless', 'localNetwork'), candidate('offline', None)], 'wireless'),
        ([candidate('pending', 'wired', 'disconnected'), candidate('connected', 'wired')], 'connected'),
        ([candidate('pending', 'wired', 'disconnected'), candidate('wireless', 'localNetwork')], 'wireless'),
        ([candidate('b', 'wired'), candidate('a', 'wired')], 'a'),
        ([candidate('a', 'wired'), candidate('b', 'wired')], 'a'),
        ([candidate('unpaired', 'wired', pairing='unpaired'), candidate('virtual', 'wired', reality='virtual')], ''),
    ):
        result = select(devices)
        if (expected and (result.returncode or result.stdout.strip() != f'{expected}:{expected}')) \
                or (not expected and result.returncode != 1):
            findings.append('设备自测：连接状态、有线优先、稳定排序及真实配对范围')
    for requested, devices, cached, expected in (
        ('phone-a', [candidate('phone-b', 'wired'), candidate('phone-a', 'localNetwork')], 'phone-b', 'phone-a'),
        ('phone-a', [candidate('phone-b', 'wired')], 'phone-b', ''),
        ('phone-a', [candidate('phone-a', 'wired')], 'phone-a', 'phone-a'),
        ('', [], 'phone-b', 'phone-b'),
    ):
        setup = f'BIT101_XCODE_DEVICE_ID={cached} BIT101_DEVICETCL_DEVICE_ID=cached-pair BIT101_DEVICE_TRANSPORT=wired BIT101_DEVICE_NAME={cached}'
        result = select(devices, setup, requested)
        paired = expected if requested else 'cached-pair'
        if (expected and (result.returncode or result.stdout.strip() != f'{expected}:{paired}')) \
                or (not expected and result.returncode != 1):
            findings.append('设备自测：指定原执行设备时刷新身份配对，聚合流程复用已选设备')
    for devices, expected in (([candidate('phone-b', 'wired'), candidate('phone-a', 'localNetwork')], 'phone-a'),
            ([candidate('phone-b', 'wired')], '')):
        result = select(devices, 'BIT101_XCODE_DEVICE_ID=phone-a')
        if (expected and (result.returncode or result.stdout.strip() != f'{expected}:{expected}')) \
                or (not expected and result.returncode != 1):
            findings.append('设备自测：单个公开 UDID 配置约束全部真机入口')
    return findings + simulator_identity_boundary_findings() + simulator_diagnostic_boundary_findings()


def simulator_identity_boundary_findings() -> list[str]:
    from contextlib import redirect_stdout
    from io import StringIO
    from types import SimpleNamespace
    from unittest.mock import patch
    import os
    import sys
    from script_test_support import heredoc_body
    source = Path(__file__).with_name('simulator-tests.sh').read_text()
    program = heredoc_body(source, 'PYDEVICE')
    path = Path('/fixture/simulator-device.json')
    runtime = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0', 'isAvailable': True,
        'supportedDeviceTypes': [{'name': 'iPhone Duo', 'identifier': 'adaptive-type'},
            {'name': 'iPhone 16', 'identifier': 'older-type'}, {'name': 'iPhone 17 Pro Max', 'identifier': 'larger-type'},
            {'name': 'iPhone 17 Pro', 'identifier': 'phone-type'}]}
    for ci, state in [(False, 'valid'), (False, 'deleted'), (False, 'unavailable'),
                      (False, 'manifest-missing'), (False, 'empty'), (True, 'valid'), (True, 'deleted'),
                      (True, 'unavailable'), (True, 'empty'), (True, 'adaptive')]:
        old = {'udid': 'old', 'name': 'BIT101', 'isAvailable': state in {'valid', 'adaptive'}, 'state': 'Booted',
            'deviceTypeIdentifier': 'adaptive-type' if state == 'adaptive' else 'phone-type'}
        reusable = {'udid': 'ready', 'name': 'iPhone 17 Pro' if ci else 'BIT101', 'isAvailable': True,
            'state': 'Booted', 'deviceTypeIdentifier': 'phone-type'}
        adaptive = {'udid': 'first', 'name': 'iPhone Duo', 'isAvailable': True, 'state': 'Booted', 'deviceTypeIdentifier': 'adaptive-type'}
        devices = ([adaptive] if ci else []) + ([] if state == 'empty' else [reusable] + ([old] if state in {'valid', 'unavailable', 'adaptive'} else []))
        adaptive_runtime = dict(runtime, identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-1', version='27.1',
            supportedDeviceTypes=[{'name': 'iPhone Duo', 'identifier': 'adaptive-type'}])
        data = {'runtimes': [runtime] + ([adaptive_runtime] if ci else []),
            'devices': {runtime['identifier']: devices, adaptive_runtime['identifier']: [adaptive]}}
        saved, commands = [], []
        def output(command, **kwargs):
            if command[:4] == ['xcrun', 'simctl', 'list', '--json']: return json.dumps(data)
            if command[:3] == ['xcrun', 'simctl', 'create']:
                if ci: assert command[4:] == ['phone-type', runtime['identifier']]
                return 'created'
            raise AssertionError(command)
        def run(command, **kwargs):
            commands.append(command)
            return SimpleNamespace(returncode=0)
        with patch.object(sys, 'argv', ['device', str(path), 'prepare']), \
                patch.dict(os.environ, GITHUB_ACTIONS='true' if ci else 'false', DEVELOPER_DIR='/Xcode/Contents/Developer'), \
                patch.object(Path, 'is_file', return_value=state != 'manifest-missing'), \
                patch.object(Path, 'read_text', return_value=json.dumps({'identifier': 'old', 'runtime': runtime['identifier']})), \
                patch.object(Path, 'write_text', side_effect=lambda text: saved.append(json.loads(text))), \
                patch.object(subprocess, 'check_output', side_effect=output), patch.object(subprocess, 'run', side_effect=run), \
                redirect_stdout(StringIO()) as console:
            exec(compile(program, 'simulator-device-selection', 'exec'), {})
        expected = 'old' if state == 'valid' else 'created' if state == 'empty' else 'ready'
        assert console.getvalue().strip() == expected, (ci, state)
        assert saved == ([] if state == 'valid' else [{'identifier': expected, 'runtime': runtime['identifier']}]), (ci, state)
        assert (['xcrun', 'simctl', 'delete', 'old'] in commands) == (state == 'unavailable'), (ci, state)
        if state == 'empty': assert saved and ['xcrun', 'simctl', 'boot', 'created'] in commands
    return []


def simulator_diagnostic_boundary_findings() -> list[str]:
    from contextlib import redirect_stderr
    from io import StringIO
    from unittest.mock import patch
    from validation_restore import simulator_startup_diagnostics
    reports = [Path('/fixture/old.ips'), Path('/fixture/current.ips')]
    payload = {'pid': 42, 'exception': {'type': 'EXC_BREAKPOINT'}, 'faultingThread': 0,
        'threads': [{'frames': [{'symbol': 'AppFileDirectories.defaults(inDomain:)'}]}]}
    for first in ('malformed', '{}\n' + json.dumps(payload | {'pid': 41})):
        with patch.object(Path, 'glob', return_value=reports), \
                patch.object(Path, 'read_text', side_effect=[first, '{}\n' + json.dumps(payload)]), \
                patch('subprocess.run') as run, redirect_stderr(StringIO()) as output:
            simulator_startup_diagnostics('device', 42)
        assert 'AppFileDirectories.defaults(inDomain:)' in output.getvalue()
        assert 'EXC_BREAKPOINT' in output.getvalue() and 'old.ips' not in output.getvalue()
        assert run.call_args.args[0][:4] == ['xcrun', 'simctl', 'spawn', 'device']
    return []
