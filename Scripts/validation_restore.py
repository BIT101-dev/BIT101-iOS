#!/usr/bin/env python3
"""Validate normal App readiness and its live process after installation."""
import json
import plistlib
import uuid
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit
from validation_provenance import sampling_evidence_current

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / 'build/DeviceInstall/restore-readiness.json'
PROCESS = ROOT / 'build/DeviceInstall/restore-process.json'


def invalidate() -> None:
    from validation_provenance import REPORT, report_lock, write_report
    with report_lock():
        if not REPORT.is_file(): return
        report = json.loads(REPORT.read_text())
        report.get('groups', {}).pop('restore', None)
        for key in ('mergeCommit', 'releaseCommit'): report.pop(key, None)
        write_report(report)


def valid_identity(proof: dict) -> bool:
    try:
        return str(uuid.UUID(proof['runID'])).lower() == proof['runID'].lower() and bool(re.fullmatch(r'[0-9a-f]{64}', proof['inputDigest']))
    except (ValueError, TypeError, KeyError, AttributeError): return False


def complete(proof: dict) -> bool:
    return proof.get('kind') == 'restore' and proof.get('initialized') is True and proof.get('sessionRecovered') is True and proof.get('active') is True \
        and proof.get('processAlive') is True and type(proof.get('processIdentifier')) is int and proof['processIdentifier'] > 0 \
        and valid_identity(proof) and sampling_evidence_current(proof)


def matches_app(proof: dict, info: dict, run_id: str, digest: str) -> bool:
    return proof.get('schemaVersion') == 1 and proof.get('runID') == run_id \
        and proof.get('inputDigest') == digest == info.get('BIT101RestoreInputDigest') \
        and all(proof.get(key) == info.get(field) for key, field in
            [('bundleIdentifier', 'CFBundleIdentifier'), ('version', 'CFBundleShortVersionString'), ('build', 'CFBundleVersion')])


def executable_path(value) -> str | None:
    if not isinstance(value, str) or not value: return None
    parsed = urlsplit(value)
    if parsed.scheme and (parsed.scheme != 'file' or parsed.netloc not in {'', 'localhost'}): return None
    path = unquote(parsed.path)
    if not path.startswith('/'): return None
    if path.startswith('/var/'): path = '/private' + path
    return path


def owned_process_alive(proof: dict, processes: list[dict]) -> bool:
    expected = executable_path(proof.get('executablePath'))
    return expected is not None and any(row.get('processIdentifier') == proof.get('processIdentifier')
        and executable_path(row.get('executable')) == expected for row in processes)


def summary(run_id: str, digest: str) -> dict:
    proof = json.loads(PROOF.read_text())
    processes = json.loads(PROCESS.read_text())['result']['runningProcesses']
    info_path = ROOT / 'build/DeviceInstall/Build/Products/Release-iphoneos/BIT101-iOS.app/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    proof = dict(proof, kind='restore', startedAt=proof.get('readyAt'), finishedAt=proof.get('readyAt'),
        processAlive=owned_process_alive(proof, processes))
    proof['passed'] = complete(proof) and matches_app(proof, info, run_id, digest)
    return proof


def mac_ready(app: Path, proof_path: Path, run_id: str, digest: str) -> bool:
    proof = json.loads(proof_path.read_text())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    process = subprocess.run(['/bin/ps', '-p', str(proof['processIdentifier']), '-o', 'comm='],
        capture_output=True, text=True, check=False)
    proof = dict(proof, kind='restore', startedAt=proof.get('readyAt'), finishedAt=proof.get('readyAt'),
        processAlive=process.returncode == 0 and process.stdout.strip() == str(app / 'Contents/MacOS/BIT101-iOS'))
    return complete(proof) and matches_app(proof, info, run_id, digest)


def simulator_restore_findings(simulator_source: str) -> list[str]:
    import os
    import sys
    from unittest.mock import patch
    from contextlib import redirect_stderr
    from io import StringIO
    SCRIPT_ROOT = ROOT / 'Scripts'
    findings = simulator_startup_findings(simulator_source)
    restoration = 'restore_application() {' + simulator_source.split('restore_application() {', 1)[1].split(
        'if [[ "$operation" == restore ]]', 1)[0]
    for original, restore_result in ((0, 0), (7, 0), (0, 9), (7, 9)):
        stub = f'python3() {{ print digest; }}\nbit101_run_logged() {{ print RESTORE; if [[ "$2" == "常规模拟器包编译" && " $* " != *" ENABLE_TESTABILITY=YES "* ]]; then return 64; fi; return {restore_result}; }}\n'
        result = subprocess.run(['zsh', '-c', stub + restoration + '\ntrap restore_on_exit EXIT\nexit "$1"',
            'simulator-restore-test', str(original)], env=dict(os.environ, GITHUB_ACTIONS='false', BIT101_DEFER_APP_RESTORE='0'), capture_output=True, text=True)
        if result.returncode != (original or restore_result) or result.stdout.count('RESTORE') != (1 if restore_result else 2):
            findings.append('模拟器恢复自测：退出时恢复常规包并保留测试失败状态')
    for hosted, deferred in ((True, False), (False, True)):
        for original in (0, 7):
            result = subprocess.run(['zsh', '-c', 'bit101_run_logged() { print UNEXPECTED; return 99; }\n' + restoration +
                '\ntrap restore_on_exit EXIT\nexit "$1"', 'simulator-deferred-test', str(original)],
                env=dict(os.environ, GITHUB_ACTIONS=str(hosted).lower(), RUNNER_ENVIRONMENT='github-hosted',
                    BIT101_DEFER_APP_RESTORE='1' if deferred else '0'), capture_output=True, text=True)
            if result.returncode != original or 'UNEXPECTED' in result.stdout:
                findings.append('聚合与托管模拟器退出自测：外层恢复或运行器回收并保留测试失败状态')
    restoration_program = simulator_source.split("<<'PYRESTORE'\n", 1)[1].split('\nPYRESTORE', 1)[0]
    from datetime import datetime, timezone
    from types import SimpleNamespace
    import uuid
    restore_id = uuid.UUID('00000000-0000-4000-8000-000000000001')
    app_info = dict(CFBundleExecutable='App', CFBundleIdentifier='app', CFBundleShortVersionString='1',
        CFBundleVersion='1', BIT101RestoreInputDigest='a' * 64)
    ready = dict(schemaVersion=1, runID=str(restore_id), inputDigest='a' * 64, processIdentifier=123,
        bundleIdentifier='app', version='1', build='1', initialized=True, sessionRecovered=True, active=True,
        readyAt=datetime.now(timezone.utc).isoformat())
    for exited, change, expected in ((False, {}, ''), (True, {}, '就绪前退出'),
            (False, {'processIdentifier': 124}, '就绪验收超时'), (False, {'sessionRecovered': False}, '就绪验收超时'), (False, {'active': False}, '就绪验收超时'),
            (False, {'inputDigest': 'b' * 64}, '就绪验收超时')):
        def run_command(command, **kwargs):
            return SimpleNamespace(returncode=int(exited and command[0] == '/bin/kill'), stdout='app: 123')
        def command_output(command, **kwargs):
            if command[1:4] == ['simctl', 'list', 'devices']:
                return json.dumps({'devices': {'runtime': [{'udid': 'device', 'state': 'Shutdown'}]}})
            return '/fixture/container'
        with patch.object(sys, 'argv', ['restore', 'device', '/fixture/App', str(SCRIPT_ROOT), 'a' * 64, '/fixture/screenshot.png']), \
                patch.object(subprocess, 'run', side_effect=run_command), \
                patch.object(subprocess, 'check_output', side_effect=command_output), \
                patch.object(Path, 'read_bytes', lambda path: plistlib.dumps(app_info) if path.name == 'Info.plist' else b'app'), \
                patch.object(Path, 'read_text', return_value=json.dumps(dict(ready, **change))), \
                patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'unlink'), \
                patch('time.monotonic', side_effect=[0, 0, 61]), patch('time.sleep'), patch('uuid.uuid4', return_value=restore_id), redirect_stderr(diagnostics := StringIO()):
            try: exec(compile(restoration_program, '<simulator-restore>', 'exec'), {}); outcome = ''
            except SystemExit as error: outcome = str(error.code)
            if expected not in outcome or bool(expected) != bool(outcome) \
                    or expected == '就绪验收超时' and json.loads(diagnostics.getvalue())['readiness'] != dict(ready, **change):
                findings.append('模拟器恢复自测：实际进程、会话恢复和编译输入共同参与就绪验收')
    return findings


def simulator_startup_findings(source: str) -> list[str]:
    import os
    import sys
    from contextlib import redirect_stdout
    from io import StringIO
    from unittest.mock import patch
    try:
        programs = {marker: source.split(f"<<'{marker}'", 1)[1].split('\n', 1)[1].split('\n' + marker, 1)[0]
            for marker in ('PYDEVICE', 'PYREADY', 'PYAPPREADY')}
    except IndexError:
        return ['模拟器启动自测：设备、系统与 App 初始化入口应提供完整脚本正文。']
    device_program = programs['PYDEVICE']
    inventory = {'runtimes': [{'isAvailable': True, 'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27'}],
        'devices': {'runtime': [{'udid': 'device', 'isAvailable': True, 'state': 'Shutdown'}]}}
    findings = []
    for hosted in ('true', 'false'):
        for operation in ('prepare', 'app', 'release-runtime', 'ui'):
            commands = []
            with patch.dict(os.environ, GITHUB_ACTIONS=hosted, DEVELOPER_DIR='/fixture/Xcode.app/Contents/Developer'), \
                    patch.object(sys, 'argv', ['device', '/fixture/device.json', operation]), \
                    patch.object(subprocess, 'check_output', return_value=json.dumps(inventory)), \
                    patch.object(subprocess, 'run', side_effect=lambda command, **kwargs: commands.append(command)), \
                    patch.object(Path, 'is_file', return_value=True), \
                    patch.object(Path, 'read_text', return_value=json.dumps({'identifier': 'device'})), redirect_stdout(StringIO()):
                exec(compile(device_program, '<simulator-device>', 'exec'), {})
            expected = [] if hosted == 'true' else [['xcrun', 'simctl', 'boot', 'device'],
                ['xcrun', 'simctl', 'bootstatus', 'device', '-b'], ['open', '-a', '/fixture/Xcode.app/Contents/Applications/DeviceHub.app']]
            if commands != expected:
                findings.append('模拟器启动自测：托管设备选择与系统初始化分离，本机准备完成设备启动')
    runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27'
    stock = {'runtimes': [{'isAvailable': True, 'identifier': runtime, 'version': '27.0',
        'supportedDeviceTypes': [{'name': 'iPhone', 'identifier': 'phone'}]}], 'devices': {runtime: [
            {'udid': 'shutdown', 'name': 'iPhone', 'isAvailable': True, 'state': 'Shutdown'},
            {'udid': 'booted', 'name': 'iPhone', 'isAvailable': True, 'state': 'Booted'}]}}
    for hosted, expected in (('true', 'shutdown'), ('false', 'created')):
        def command_output(command, **kwargs):
            return json.dumps(stock) if command[2] == 'list' else 'created'
        with patch.dict(os.environ, GITHUB_ACTIONS=hosted, DEVELOPER_DIR='/fixture/Xcode.app/Contents/Developer'), \
                patch.object(sys, 'argv', ['device', '/fixture/device.json', 'prepare']), \
                patch.object(Path, 'is_file', return_value=False), patch.object(Path, 'write_text') as saved, \
                patch.object(subprocess, 'check_output', side_effect=command_output) as executed, \
                patch.object(subprocess, 'run'), redirect_stdout(StringIO()):
            exec(compile(device_program, '<simulator-stock-device>', 'exec'), {})
        if json.loads(saved.call_args.args[0])['identifier'] != expected or executed.call_count != (1 if hosted == 'true' else 2):
            findings.append('模拟器选择自测：托管环境复用库存 iPhone，本机维护项目独立设备')
    for operation in ('app', 'release-runtime', 'ui'):
        with patch.object(sys, 'argv', ['ready', str(ROOT / 'Scripts'), 'device', '/fixture', operation]), \
                patch('validation_coverage.prepare_simulator_system') as prepared:
            exec(compile(programs['PYREADY'], '<simulator-ready>', 'exec'), {})
        if prepared.call_count != 1 or prepared.call_args.args != ('device', Path('/fixture')) \
                or prepared.call_args.kwargs != {'ui': operation == 'ui'}:
            findings.append('模拟器启动自测：系统初始化接入实际设备及所属测试模式')
    with patch.object(sys, 'argv', ['app-ready', str(ROOT / 'Scripts'), 'device', '/fixture/Build/Products']), \
            patch('validation_coverage.prepare_simulator_ui') as prepared:
        exec(compile(programs['PYAPPREADY'], '<simulator-app-ready>', 'exec'), {})
    if prepared.call_count != 1 or prepared.call_args.args != ('device', Path('/fixture/Build/Products')):
        findings.append('模拟器启动自测：UI 初始化使用已编译的测试宿主')
    if source.index("<<'PYREADY'") > source.index('xcodebuild build-for-testing') \
            or source.split("<<'PYREADY'", 1)[1].split('\n', 1)[0].strip() != '&':
        findings.append('模拟器启动自测：系统初始化与测试宿主编译并行执行')
    body = 'coverage_arguments=(' + source.split('coverage_arguments=(', 1)[1].split('\nplan="$(', 1)[0]
    body = body.replace('>> "$DERIVED_ROOT/simulator.log" 2>&1', '')
    for hosted in ('true', 'false'):
        for operation in ('app', 'release-runtime', 'ui'):
            for build_status, ready_status in ((0, 0), (7, 0), (0, 9), (7, 9)):
                harness = f'''set -euo pipefail
ROOT_DIR=/fixture DERIVED_ROOT=/fixture SIMULATOR_DEVICE=device mode={operation} scheme=scheme configuration=Release destination=target conditions= GITHUB_ACTIONS={hosted}
only_testing=()
bit101_run_logged() {{ if [[ "$3" == python3 ]]; then cat >/dev/null; print PREPARE; return {ready_status}; else local coverage=YES; [[ "$mode" == release-runtime ]] && coverage=NO; [[ " $* " == *" -enableCodeCoverage $coverage ENABLE_CODE_COVERAGE=$coverage "* ]] || return 88; print BUILD; return {build_status}; fi; }}
python3() {{ cat >/dev/null; print APPREADY; }}
'''
                result = subprocess.run(['zsh', '-c', harness + body + '\nprint COMPLETE'], capture_output=True, text=True, timeout=10)
                expected = build_status or (ready_status if hosted == 'true' else 0)
                rows = result.stdout.splitlines()
                complete = result.returncode == expected and 'BUILD' in rows and ('PREPARE' in rows) == (hosted == 'true') \
                    and ('COMPLETE' in rows) == (expected == 0)
                app_ready = hosted == 'true' and operation == 'ui' and expected == 0
                complete = complete and ('APPREADY' in rows) == app_ready
                if complete and app_ready:
                    complete = rows.index('APPREADY') > max(rows.index('BUILD'), rows.index('PREPARE'))
                if not complete:
                    findings.append('模拟器启动自测：两项完成后初始化 App，失败状态归集后结束')
    return findings


def verification_finish_findings(source: str) -> list[str]:
    import os
    step = 'verify_step() {' + source.split('verify_step() {', 1)[1].split('\n  for group in', 1)[0]
    step = step.replace('"$ROOT_DIR/Scripts/run-static-audit.sh" prepare', 'prepare_probe')
    finish = 'finish_verification() {' + source.split('finish_verification() {', 1)[1].split('\n  trap finish_verification', 1)[0]
    finish = finish.replace('"$ROOT_DIR/Scripts/build-install-device.sh"', 'restore_probe')
    findings = []
    for prepare_status, restore_status, audit_status in ((0, 0, 0), (0, 9, 0), (0, 0, 11), (0, 9, 11), (13, 0, 0)):
        reader, writer = os.pipe()
        try:
            harness = f'''set -euo pipefail
unset BIT101_AUDIT_BACKGROUND BIT101_AUDIT_ARTIFACTS_PREPARED
ROOT_DIR=/fixture verification_needs_device=true verification_audit_pid=
completed_result_groups=()
python3() {{ print 17.0; }}
prepare_probe() {{ print PREPARE; return {prepare_status}; }}
restore_probe() {{ print RESTORE; print ready >&{writer}; return {restore_status}; }}
audit_probe() {{ [[ "$BIT101_AUDIT_ARTIFACTS_PREPARED" == 1 ]]; read -r message <&{reader}; print AUDIT_FINISHED; return {audit_status}; }}
'''
            result = subprocess.run(['zsh', '-c', harness + step + '\n' + finish +
                '\ntrap finish_verification EXIT ZERR\nverify_step audit audit_probe\nexit 0'],
                capture_output=True, text=True, pass_fds=(reader, writer), timeout=5)
            expected = prepare_status or int(bool(restore_status or audit_status))
            if result.returncode != expected or result.stdout.index('PREPARE') > result.stdout.index('RESTORE') \
                    or bool(prepare_status) == ('AUDIT_FINISHED' in result.stdout) \
                    or not prepare_status and result.stdout.index('RESTORE') > result.stdout.index('AUDIT_FINISHED') \
                    or '[完整验证总耗时] 17.0 秒' not in result.stdout:
                findings.append('聚合恢复自测：产物准备成功后并行审计，单设备恢复完成后汇总状态和总耗时')
        finally:
            os.close(reader)
            os.close(writer)
    clock = source.split("<<'PYELAPSED'\n", 1)[1].split('\nPYELAPSED', 1)[0]
    from unittest.mock import patch
    from io import StringIO
    from contextlib import redirect_stdout
    with patch.dict(os.environ, BIT101_WORKFLOW_STARTED_AT='100'), patch('time.monotonic', return_value=191.5), redirect_stdout(output := StringIO()):
        exec(compile(clock, '<workflow-elapsed>', 'exec'), {})
    assert output.getvalue().strip() == '91.5'
    return findings


def self_test() -> None:
    from validation_provenance import utc_now
    row = dict(kind='restore', initialized=True, sessionRecovered=True, active=True, processAlive=True, processIdentifier=1,
        runID='00000000-0000-4000-8000-000000000001', inputDigest='a' * 64, startedAt=utc_now().isoformat(), finishedAt=utc_now().isoformat())
    assert complete(row)
    for key, value in [('sessionRecovered', False), ('initialized', False), ('active', False), ('processAlive', False), ('processIdentifier', 0),
            ('runID', ''), ('inputDigest', ''), ('startedAt', '2000-01-01T00:00:00+00:00')]:
        assert not complete(dict(row, **{key: value}))
    from unittest.mock import patch
    ready = dict(row, schemaVersion=1, readyAt=utc_now().isoformat(), bundleIdentifier='app', version='1', build='1',
        executablePath='/private/var/containers/Bundle/Application/fixture/BIT101-iOS.app/BIT101-iOS')
    info = dict(CFBundleIdentifier='app', CFBundleShortVersionString='1', CFBundleVersion='1', BIT101RestoreInputDigest='a' * 64)
    app = Path('/Applications/BIT101-iOS.app')
    from types import SimpleNamespace
    with patch.object(Path, 'read_text', return_value=json.dumps(ready)), patch.object(Path, 'read_bytes', return_value=plistlib.dumps(info)), \
            patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=str(app / 'Contents/MacOS/BIT101-iOS') + '\n')) as process:
        assert mac_ready(app, PROOF, ready['runID'], 'a' * 64)
        assert not mac_ready(app, PROOF, ready['runID'], 'b' * 64)
        process.return_value.returncode = 1
        assert not mac_ready(app, PROOF, ready['runID'], 'a' * 64)
        process.return_value.returncode = 0
        process.return_value.stdout = '/Applications/Other.app/Contents/MacOS/Other'
        assert not mac_ready(app, PROOF, ready['runID'], 'a' * 64)
    def contents(path):
        return json.dumps(ready if path == PROOF else {'result': {'runningProcesses': [{'processIdentifier': 1, 'executable': ready['executablePath']}]}})
    with patch.object(Path, 'read_text', contents), patch.object(Path, 'read_bytes', return_value=plistlib.dumps(info)):
        assert summary(ready['runID'], 'a' * 64)['passed']
        assert not summary(str(uuid.uuid4()), 'a' * 64)['passed']
        assert not summary(ready['runID'], 'b' * 64)['passed']
        ready['processIdentifier'] = 2
        assert not summary(ready['runID'], 'a' * 64)['passed']
    for executable in ['/usr/libexec/unrelated-process', None, '', 'https://example.invalid/App']:
        assert not owned_process_alive(ready, [dict(processIdentifier=ready['processIdentifier'], executable=executable)])
    assert owned_process_alive(ready, [dict(processIdentifier=ready['processIdentifier'], executable='file://' + ready['executablePath'])])
    assert owned_process_alive(ready, [dict(processIdentifier=ready['processIdentifier'], executable=ready['executablePath'].removeprefix('/private'))])
    from contextlib import nullcontext
    import validation_provenance
    retained = {'sourceDigest': 'source', 'mergeCommit': 'commit', 'releaseCommit': 'commit',
        'groups': {'restore': {'summary': ready, 'lastFullRun': row}, 'all': {'runID': 'test'}}}
    with patch.object(validation_provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(Path, 'is_file', return_value=True), \
            patch.object(Path, 'read_text', side_effect=lambda *_: json.dumps(retained)), \
            patch.object(validation_provenance, 'write_report', side_effect=lambda report: retained.update(report)) as saved:
        invalidate()
        current = saved.call_args.args[0]
        assert current == {'sourceDigest': 'source', 'groups': {'all': {'runID': 'test'}}}
        retained = current
        invalidate()
        assert saved.call_args.args[0] == current
    with patch.object(validation_provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(Path, 'is_file', return_value=False), patch.object(validation_provenance, 'write_report') as saved:
        invalidate()
        saved.assert_not_called()


if __name__ == '__main__':
    import sys
    try:
        if sys.argv[1:] == ['invalidate']:
            invalidate()
            sys.exit(0)
        if sys.argv[1:2] == ['mac-ready']:
            sys.exit(0 if mac_ready(Path(sys.argv[2]), Path(sys.argv[3]), *sys.argv[4:]) else 1)
        result = summary(*sys.argv[1:])
        sys.exit(0 if result['passed'] else 1)
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit(1)
