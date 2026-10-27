#!/usr/bin/env python3
"""Validate normal App readiness and its live process after installation."""
import json
import plistlib
import uuid
from validation_environment import input_identity_complete
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit
from validation_provenance import sampling_evidence_current

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / 'build/DeviceInstall/restore-readiness.json'
PROCESS = ROOT / 'build/DeviceInstall/restore-process.json'


def simulator_startup_diagnostics(device: str, process: int) -> None:
    import sys
    subprocess.run(['xcrun', 'simctl', 'spawn', device, 'log', 'show', '--style', 'compact', '--info', '--last', '2m',
        '--predicate', 'subsystem == "BIT101" AND (category == "RestoreReadiness" OR category == "LoginKeychain" OR category == "PersistentBackup")'],
        check=False, stdout=sys.stderr, stderr=sys.stderr)
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    for report in reports.glob('BIT101-iOS-*.ips'):
        try:
            payload = json.loads(report.read_text().partition('\n')[2])
            if not isinstance(payload, dict) or payload.get('pid') != process: continue
            print(f'启动崩溃：{report} · {json.dumps(payload.get("exception"), ensure_ascii=False)}', file=sys.stderr)
            thread = payload.get('threads', [])[payload.get('faultingThread', 0)]
            for frame in thread.get('frames', []):
                print('  ' + str(frame.get('symbol') or frame.get('imageOffset')), file=sys.stderr)
            break
        except (OSError, ValueError, TypeError, IndexError):
            continue


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
        return str(uuid.UUID(proof['runID'])).lower() == proof['runID'].lower() and input_identity_complete(proof['inputDigest'])
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
    proof['identityMatches'] = matches_app(proof, info, run_id, digest)
    proof['passed'] = complete(proof) and proof['identityMatches']
    return proof


def readiness_diagnostic(proof: dict) -> None:
    import sys
    state = dict(App身份=proof.get('identityMatches'), 就绪身份=valid_identity(proof), 初始化=proof.get('initialized'),
        会话恢复=proof.get('sessionRecovered'), 活跃=proof.get('active'), 进程存活=proof.get('processAlive'),
        进程编号=proof.get('processIdentifier'), 采样有效=sampling_evidence_current(proof))
    print('App 就绪状态：' + json.dumps(state, ensure_ascii=False), file=sys.stderr)


def mac_app_pids(app: Path) -> list[int]:
    expected = str(app / 'Contents/MacOS/BIT101-iOS')
    processes = subprocess.check_output(['/bin/ps', '-ww', '-axo', 'pid=,comm='], text=True)
    result = []
    for line in processes.splitlines():
        pid, _, executable = line.lstrip().partition(' ')
        if executable.strip() == expected: result.append(int(pid))
    return result


def mac_ready(app: Path, proof_path: Path, run_id: str, digest: str, *, diagnose: bool = False) -> bool:
    proof = json.loads(proof_path.read_text())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    process = subprocess.run(['/bin/ps', '-p', str(proof['processIdentifier']), '-o', 'comm='],
        capture_output=True, text=True, check=False)
    proof = dict(proof, kind='restore', startedAt=proof.get('readyAt'), finishedAt=proof.get('readyAt'),
        processAlive=process.returncode == 0 and process.stdout.strip() == str(app / 'Contents/MacOS/BIT101-iOS'))
    proof['identityMatches'] = matches_app(proof, info, run_id, digest)
    passed = complete(proof) and proof['identityMatches']
    if diagnose and not passed: readiness_diagnostic(proof)
    return passed


def verify_simulator() -> int:
    import os
    import time
    environment = dict(os.environ, BIT101_DEFER_APP_RESTORE='1', BIT101_VALIDATION_RESULT_BATCH_HELD='1', BIT101_SIMULATOR_PREPARE_RESTORE='1')
    started = float(environment.get('BIT101_WORKFLOW_STARTED_AT', time.monotonic()))
    def run(*arguments):
        return subprocess.run(arguments, cwd=ROOT, env=environment).returncode
    status = run('Scripts/run-static-audit.sh', 'prepare')
    audit = None
    completed = []
    try:
        if status == 0: status = run('Scripts/run-extended-tests.sh', 'simulator', 'prepare')
        if status == 0:
            audit = subprocess.Popen(['Scripts/run-static-audit.sh'], cwd=ROOT,
                env=dict(environment, BIT101_AUDIT_BACKGROUND='1', BIT101_AUDIT_ARTIFACTS_PREPARED='1'))
            status = run('Scripts/run-extended-tests.sh', 'modules')
        for operation, group in [('app', 'all'), ('release-runtime', 'release-runtime'), ('ui', 'ui')]:
            if status: break
            status = run('python3', '-B', 'Scripts/validation_performance.py', 'begin-batch', 'append' if completed else 'first')
            if status: break
            status = run('Scripts/run-extended-tests.sh', 'simulator', operation)
            completed.append(group)
            retained = run('python3', '-B', 'Scripts/validation_performance.py', 'retain-batch', *completed)
            status = status or retained
    finally:
        restored = run('Scripts/run-extended-tests.sh', 'simulator', 'restore')
        status = status or restored
        if audit is not None:
            audited = audit.wait()
            status = status or audited
        print(f'[完整验证总耗时] {time.monotonic() - started:.1f} 秒（含等待、编译、测试、汇总及常规 App 恢复）', flush=True)
    return status


def simulator_verification_self_test() -> None:
    import os
    from contextlib import redirect_stdout
    from io import StringIO
    from types import SimpleNamespace
    from unittest.mock import patch
    failures = [None, ('Scripts/run-static-audit.sh', 'prepare'),
        ('Scripts/run-extended-tests.sh', 'simulator', 'prepare'), ('Scripts/run-extended-tests.sh', 'modules'),
        *[('Scripts/run-extended-tests.sh', 'simulator', mode) for mode in ('app', 'release-runtime', 'ui', 'restore')],
        ('python3', '-B', 'Scripts/validation_performance.py', 'begin-batch', 'append'),
        ('python3', '-B', 'Scripts/validation_performance.py', 'retain-batch', 'all'),
        'audit']
    for failure in failures:
        events = []
        def run(arguments, **kwargs):
            events.append(tuple(arguments))
            assert kwargs['env']['BIT101_DEFER_APP_RESTORE'] == '1'
            assert kwargs['env']['BIT101_VALIDATION_RESULT_BATCH_HELD'] == '1'
            assert kwargs['env']['BIT101_SIMULATOR_PREPARE_RESTORE'] == '1'
            return SimpleNamespace(returncode=7 if tuple(arguments) == failure else 0)
        def launch(arguments, **kwargs):
            label = 'audit'
            events.append(label)
            if label == 'audit': assert kwargs['env']['BIT101_AUDIT_ARTIFACTS_PREPARED'] == '1'
            def wait():
                events.append(('wait', label))
                return 7 if label == failure else 0
            return SimpleNamespace(wait=wait)
        with patch.dict(os.environ, BIT101_WORKFLOW_STARTED_AT='100'), patch.object(subprocess, 'run', side_effect=run), \
                patch.object(subprocess, 'Popen', side_effect=launch), patch('time.monotonic', return_value=117), \
                redirect_stdout(output := StringIO()):
            assert verify_simulator() == (7 if failure else 0), failure
        restore = ('Scripts/run-extended-tests.sh', 'simulator', 'restore')
        assert events.count(restore) == 1 and '17.0 秒' in output.getvalue()
        if 'audit' in events:
            assert events.index(restore) < events.index(('wait', 'audit'))
        if failure is None:
            native = [row[-1] for row in events if isinstance(row, tuple) and row[:2] == ('Scripts/run-extended-tests.sh', 'simulator')]
            assert native == ['prepare', 'app', 'release-runtime', 'ui', 'restore']


def simulator_restore_findings(simulator_source: str) -> list[str]:
    import os
    import sys
    from unittest.mock import patch
    from contextlib import redirect_stderr
    from io import StringIO
    from script_test_support import heredoc_body
    SCRIPT_ROOT = ROOT / 'Scripts'
    findings = simulator_startup_findings(simulator_source)
    simulator_verification_self_test()
    restoration = 'restore_application() {' + simulator_source.split('restore_application() {', 1)[1].split(
        'if [[ "$operation" == restore ||', 1)[0]
    launch = 'simulator_restore_prepare_pid=\n' + simulator_source.split('simulator_restore_prepare_pid=\n', 1)[1].split('\nif [[ "$mode" == ui', 1)[0]
    launch = launch.replace('"$ROOT_DIR/Scripts/run-extended-tests.sh" simulator prepare-restore', 'preparation_probe')
    if simulator_source.index('simulator_restore_prepare_pid=\n') < simulator_source.index('xcodebuild build-for-testing'):
        findings.append('恢复准备自测：测试宿主编译完成后并行准备生产 App')
    for operation in ('app', 'ui'):
        for original, prepared in ((0, 0), (7, 0), (0, 9), (7, 9)):
            reader, writer = os.pipe()
            try:
                harness = f'''operation={operation} BIT101_SIMULATOR_PREPARE_RESTORE=1 BIT101_DEFER_APP_RESTORE=1
preparation_probe() {{ read -r message <&{reader}; print PREPARED; return {prepared}; }}
'''
                result = subprocess.run(['zsh', '-c', harness + restoration + launch +
                    f'\nprint native >&{writer}\ntrap restore_on_exit EXIT\nexit {original}'],
                    capture_output=True, text=True, pass_fds=(reader, writer), timeout=5)
                if result.returncode != (original or (prepared if operation == 'app' else 0)) \
                        or ('PREPARED' in result.stdout) != (operation == 'app'):
                    findings.append('恢复准备自测：原生测试与主机编译重叠，设备操作完成后归集子进程及失败状态')
            finally:
                os.close(reader)
                os.close(writer)
    stub = 'ROOT_DIR=/fixture\npython3() { print digest; }\nbit101_run_logged() { print RESTORE; if [[ "$2" == "常规模拟器包编译" && ( " $* " != *" ENABLE_TESTABILITY=YES "* || " $* " != *" ONLY_ACTIVE_ARCH=YES "* || " $* " != *" -derivedDataPath /fixture/build/DeviceInstall "* ) ]]; then return 64; fi; return $probe_restore_status; }\n'
    for original, restore_result in ((0, 0), (7, 0), (0, 9), (7, 9)):
        result = subprocess.run(['zsh', '-c', f'probe_restore_status={restore_result}\n' + stub + restoration + '\ntrap restore_on_exit EXIT\nexit "$1"',
            'simulator-restore-test', str(original)], env=dict(os.environ, GITHUB_ACTIONS='false', BIT101_DEFER_APP_RESTORE='0'), capture_output=True, text=True)
        if result.returncode != (original or restore_result) or result.stdout.count('RESTORE') != (1 if restore_result else 2):
            findings.append('模拟器恢复自测：退出时恢复常规包并保留测试失败状态')
    result = subprocess.run(['zsh', '-c', 'operation=prepare-restore probe_restore_status=0\n' + stub + restoration + '\nrestore_application'],
        capture_output=True, text=True)
    if result.returncode or result.stdout.count('RESTORE') != 1:
        findings.append('模拟器恢复准备自测：生产构建目录完成主机编译后交回设备操作')
    for hosted, deferred in ((True, False), (False, True)):
        for original in (0, 7):
            result = subprocess.run(['zsh', '-c', 'bit101_run_logged() { print UNEXPECTED; return 99; }\n' + restoration +
                '\ntrap restore_on_exit EXIT\nexit "$1"', 'simulator-deferred-test', str(original)],
                env=dict(os.environ, GITHUB_ACTIONS=str(hosted).lower(), RUNNER_ENVIRONMENT='github-hosted',
                    BIT101_DEFER_APP_RESTORE='1' if deferred else '0'), capture_output=True, text=True)
            if result.returncode != original or 'UNEXPECTED' in result.stdout:
                findings.append('聚合与托管模拟器退出自测：外层恢复或运行器回收并保留测试失败状态')
    restoration_program = heredoc_body(simulator_source, 'PYRESTORE')
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
                patch('validation_restore.simulator_startup_diagnostics') as diagnosed, \
                patch('time.monotonic', side_effect=[0, 0, 61]), patch('time.sleep'), patch('uuid.uuid4', return_value=restore_id), redirect_stderr(diagnostics := StringIO()):
            try: exec(compile(restoration_program, '<simulator-restore>', 'exec'), {}); outcome = ''
            except SystemExit as error: outcome = str(error.code)
            if expected not in outcome or bool(expected) != bool(outcome) or diagnosed.called != bool(expected) \
                    or expected == '就绪验收超时' and json.loads(diagnostics.getvalue())['readiness'] != dict(ready, **change):
                findings.append('模拟器恢复自测：实际进程、会话恢复和编译输入共同参与就绪验收')
    return findings


def simulator_startup_findings(source: str) -> list[str]:
    import os
    import sys
    from contextlib import redirect_stdout
    from io import StringIO
    from unittest.mock import patch
    from script_test_support import heredoc_body, shell_function
    support = ROOT / 'Scripts/script-support.sh'
    try:
        programs = {marker: heredoc_body(source if marker == 'PYDEVICE' else support.read_text(), marker)
            for marker in ('PYDEVICE', 'PYREADY', 'PYAPPREADY')}
    except ValueError:
        return ['模拟器启动自测：设备、系统与 App 初始化入口应提供完整脚本正文。']
    device_program = programs['PYDEVICE']
    runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27'
    inventory = {'runtimes': [{'isAvailable': True, 'identifier': runtime, 'version': '27.0',
        'supportedDeviceTypes': [{'name': 'iPhone 17 Pro', 'identifier': 'phone'}]}],
        'devices': {runtime: [{'udid': 'device', 'isAvailable': True, 'state': 'Shutdown', 'deviceTypeIdentifier': 'phone'}]}}
    findings = []
    for hosted in ('true', 'false'):
        for operation in ('prepare', 'prepare-restore', 'build-ui', 'app', 'release-runtime', 'ui'):
            commands = []
            with patch.dict(os.environ, GITHUB_ACTIONS=hosted, DEVELOPER_DIR='/fixture/Xcode.app/Contents/Developer'), \
                    patch.object(sys, 'argv', ['device', '/fixture/device.json', operation]), \
                    patch.object(subprocess, 'check_output', return_value=json.dumps(inventory)), \
                    patch.object(subprocess, 'run', side_effect=lambda command, **kwargs: commands.append(command)), \
                    patch.object(Path, 'is_file', return_value=True), \
                    patch.object(Path, 'read_text', return_value=json.dumps({'identifier': 'device', 'runtime': runtime})), redirect_stdout(StringIO()):
                try: exec(compile(device_program, '<simulator-device>', 'exec'), {})
                except SystemExit as error:
                    if error.code not in (None, 0): raise
            expected = [['xcrun', 'simctl', 'boot', 'device']] if hosted == 'true' and operation == 'prepare' else []
            if hosted == 'false' and operation not in {'prepare-restore', 'build-ui'}: expected = [['xcrun', 'simctl', 'boot', 'device'],
                ['xcrun', 'simctl', 'bootstatus', 'device', '-b'], ['open', '-a', '/fixture/Xcode.app/Contents/Applications/DeviceHub.app']]
            if commands != expected:
                findings.append('模拟器启动自测：托管准备请求启动，完整系统与本机初始化沿实际执行核对')
    stock = {'runtimes': [{'isAvailable': True, 'identifier': runtime, 'version': '27.0',
        'supportedDeviceTypes': [{'name': 'iPhone 17 Pro', 'identifier': 'phone'}]}], 'devices': {runtime: [
            {'udid': 'shutdown', 'name': 'iPhone 17 Pro', 'isAvailable': True, 'state': 'Shutdown', 'deviceTypeIdentifier': 'phone'},
            {'udid': 'booted', 'name': 'iPhone 17 Pro', 'isAvailable': True, 'state': 'Booted', 'deviceTypeIdentifier': 'phone'}]}}
    for hosted, expected in (('true', 'booted'), ('false', 'created')):
        def command_output(command, **kwargs):
            return json.dumps(stock) if command[2] == 'list' else 'created'
        with patch.dict(os.environ, GITHUB_ACTIONS=hosted, DEVELOPER_DIR='/fixture/Xcode.app/Contents/Developer'), \
                patch.object(sys, 'argv', ['device', '/fixture/device.json', 'prepare']), \
                patch.object(Path, 'is_file', return_value=False), patch.object(Path, 'write_text') as saved, \
                patch.object(subprocess, 'check_output', side_effect=command_output) as executed, \
                patch.object(subprocess, 'run') as prepared, redirect_stdout(StringIO()):
            exec(compile(device_program, '<simulator-stock-device>', 'exec'), {})
        if json.loads(saved.call_args.args[0])['identifier'] != expected or executed.call_count != (1 if hosted == 'true' else 2):
            findings.append('模拟器选择自测：托管环境优先复用已启动 iPhone，本机维护项目独立设备')
        if hosted == 'true' and prepared.call_count: findings.append('模拟器选择自测：已启动库存设备保持运行')
    for hosted, operation in (('true', 'app'), ('true', 'release-runtime'), ('true', 'ui'), ('false', 'ui')):
        with patch.object(sys, 'argv', ['ready', str(ROOT / 'Scripts'), 'device', '/fixture', operation, hosted]), \
                patch('validation_coverage.prepare_simulator_system') as system, \
                patch('validation_coverage.prepare_simulator_photos') as photos:
            exec(compile(programs['PYREADY'], '<simulator-ready>', 'exec'), {})
        prepared = system if hosted == 'true' else photos
        if prepared.call_count != 1 or prepared.call_args.args != ('device', Path('/fixture')) \
                or prepared.call_args.kwargs != ({'ui': operation == 'ui'} if hosted == 'true' else {}) \
                or (photos if hosted == 'true' else system).called:
            findings.append('模拟器启动自测：托管环境准备系统，本地 UI 准备选图样本')
    with patch.object(sys, 'argv', ['app-ready', str(ROOT / 'Scripts'), 'device', '/fixture/Build/Products']), \
            patch('validation_coverage.prepare_simulator_ui') as prepared:
        exec(compile(programs['PYAPPREADY'], '<simulator-app-ready>', 'exec'), {})
    if prepared.call_count != 1 or prepared.call_args.args != ('device', Path('/fixture/Build/Products')):
        findings.append('模拟器启动自测：UI 初始化使用已编译的测试宿主')
    if source.index('chmod +x "$ROOT_DIR/.build/compiler-cache/swift-syntax-indexer"') > source.index('selection_started='):
        findings.append('共享宿主自测：库存规划前恢复下载工具的执行权限')
    body = shell_function(support, 'bit101_prepare_simulator_test_host')
    log_root = ROOT / '.build/static-audit/simulator-startup-self-test'
    log_root.mkdir(parents=True, exist_ok=True)
    try:
        for hosted in ('true', 'false'):
            for operation in ('app', 'release-runtime', 'ui'):
                for build_status, ready_status in ((0, 0), (7, 0), (0, 9), (7, 9)):
                    harness = f'''set -euo pipefail
    exec 3>&1
    ROOT_DIR=/fixture DERIVED_ROOT="{log_root}" SIMULATOR_DEVICE=device mode={operation} scheme=scheme configuration=Release destination=target conditions= GITHUB_ACTIONS={hosted} BIT101_REUSE_UI_HOST=0
    only_testing=()
    bit101_run_logged() {{ if [[ "$3" == python3 ]]; then cat >/dev/null; print PREPARE; return {ready_status}; else print BUILD; [[ " $* " == *" ONLY_ACTIVE_ARCH=YES "* ]] || return 64; return {build_status}; fi; }}
    python3() {{ cat >/dev/null; print -u3 APPREADY; }}
    '''
                    result = subprocess.run(['zsh', '-c', harness + body + '\nbit101_prepare_simulator_test_host\nprint COMPLETE'], capture_output=True, text=True, timeout=10)
                    prepares = hosted == 'true' or operation == 'ui'
                    expected = build_status or (ready_status if prepares else 0)
                    rows = result.stdout.splitlines()
                    complete = result.returncode == expected and 'BUILD' in rows and ('PREPARE' in rows) == prepares \
                        and ('COMPLETE' in rows) == (expected == 0)
                    app_ready = hosted == 'true' and operation == 'ui' and expected == 0
                    complete = complete and ('APPREADY' in rows) == app_ready
                    if complete and app_ready:
                        complete = rows.index('APPREADY') > max(rows.index('BUILD'), rows.index('PREPARE'))
                    if not complete:
                        findings.append('模拟器启动自测：两项完成后初始化 App，失败状态归集后结束')
        for hosted in ('true', 'false'):
            for ready_status in (0, 9):
                harness = f'''set -euo pipefail
    exec 3>&1
    ROOT_DIR=/fixture DERIVED_ROOT="{log_root}" SIMULATOR_DEVICE=device mode=ui GITHUB_ACTIONS={hosted} BIT101_REUSE_UI_HOST=1
    bit101_run_logged() {{ cat >/dev/null; print PREPARE; return {ready_status}; }}
    python3() {{ cat >/dev/null; if [[ "$3" == device ]]; then print -u3 APPREADY; else print -u3 PERMISSIONS; fi; }}
    '''
                result = subprocess.run(['zsh', '-c', harness + body + '\nbit101_prepare_simulator_test_host\nprint COMPLETE'], capture_output=True, text=True, timeout=10)
                rows = result.stdout.splitlines()
                expected = ready_status
                complete = result.returncode == expected and 'PERMISSIONS' in rows \
                    and 'PREPARE' in rows and ('COMPLETE' in rows) == (expected == 0) \
                    and ('APPREADY' in rows) == (hosted == 'true' and expected == 0)
                if complete and 'APPREADY' in rows:
                    complete = rows.index('APPREADY') > max(rows.index('PREPARE'), rows.index('PERMISSIONS'))
                if not complete: findings.append('共享宿主自测：恢复执行权限，归集系统就绪状态后执行 App 初始化')
    finally:
        import shutil
        shutil.rmtree(log_root)
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
        if sys.argv[1:] == ['simulator-verify']:
            sys.exit(verify_simulator())
        if sys.argv[1:] == ['invalidate']:
            invalidate()
            sys.exit(0)
        if sys.argv[1:2] == ['mac-pids']:
            sys.stdout.write(''.join(f'{pid}\n' for pid in mac_app_pids(Path(sys.argv[2]))))
            sys.exit(0)
        if sys.argv[1:2] == ['mac-ready']:
            sys.exit(0 if mac_ready(Path(sys.argv[2]), Path(sys.argv[3]), *sys.argv[4:], diagnose=True) else 1)
        result = summary(*sys.argv[1:])
        if not result['passed']: readiness_diagnostic(result)
        sys.exit(0 if result['passed'] else 1)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f'App 就绪采样失败：{type(error).__name__}：{error}', file=sys.stderr)
        sys.exit(1)
