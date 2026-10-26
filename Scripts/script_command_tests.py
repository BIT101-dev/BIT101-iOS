"""Workflow dispatch tests use tool and filesystem substitutes."""
import os
import json
import re
import shutil
import signal
import shlex
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from itertools import product
from unittest.mock import Mock, patch
from pathlib import Path
from script_device_tests import device_discovery_boundary_findings
from network_smoke_config_tests import network_configuration_boundary_findings

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = ROOT / "Scripts"

def test_build_argument_findings(output: str, *, testing_device: bool = False) -> list[str]:
    findings = []
    for line in output.splitlines():
        if not line.startswith('ARGUMENTS '): continue
        arguments = shlex.split(line)[3:]
        if arguments[:1] == ['xcodebuild']:
            required = ('-enableCodeCoverage YES', 'ENABLE_CODE_COVERAGE=YES',
                        'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES',
                        '-configuration Release')
            if testing_device: required += ('ONLY_ACTIVE_ARCH=YES',)
        elif arguments[:2] == ['xcrun', 'swift']:
            required = ('--configuration release',)
            if 'test' in arguments: required += ('--enable-code-coverage',)
        else: continue
        for option in required:
            tokens = shlex.split(option)
            if not any(arguments[index:index + len(tokens)] == tokens for index in range(len(arguments))):
                findings.append(f'测试命令参数需要实际传入：{option}')
    return findings

def result_retention_boundary_findings() -> list[str]:
    "聚合验收保留各组结果，并传播准备、测试及合并的失败。"
    source = (SCRIPT_ROOT / 'run-extended-tests.sh').read_text()
    from script_test_support import shell_function
    step = shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_check_verification_audit') + '\n' + shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_verify_step')
    findings = []
    for retained, statuses in product(('', 'catalyst'), ((0, 0, 0), (7, 0, 0), (0, 9, 0), (0, 0, 5))):
        child_status, retain_status, begin_status = statuses
        harness = f'''set -euo pipefail
ROOT_DIR=/fixture
completed_result_groups=()
child() {{ print -r -- "CHILD $*"; return {child_status}; }}
python3() {{
  print -ru2 -- "PY $*"
  if [[ "$2" == begin-full ]]; then print -r -- '{retained}'; return {begin_status}; fi
  if [[ "$2" == retain-batch ]]; then return {retain_status}; fi
  return 0
}}
'''
        result = subprocess.run(['zsh', '-c', harness + step + '\nbit101_verify_step all child all\nbit101_verify_step ui child ui'],
            text=True, capture_output=True)
        expected = begin_status or int(bool(child_status or retain_status))
        output = result.stdout + result.stderr
        groups = f'{retained} all'.strip()
        if result.returncode != expected or 'begin-full all' not in output:
            findings.append('结果保留自测：准备与执行失败沿聚合流程传播')
        if begin_status:
            if 'CHILD' in output: findings.append('结果保留自测：准备成功后执行测试')
        elif f'retain-batch {groups}' not in output:
            findings.append('结果保留自测：测试成功与失败均保留实际结果')
        if expected == 0 and ('begin-batch append' not in output or f'retain-batch {groups} ui' not in output):
            findings.append('结果保留自测：后续测试组合并本次全部结果')
    for current in (True, False):
        harness = f'''set -euo pipefail
ROOT_DIR=/fixture
completed_result_groups=()
checks=0
python3() {{ (( checks += 1 )); [[ $checks -gt 1 ]] || return {0 if current else 1}; }}
child() {{ print executed; }}
'''
        result = subprocess.run(['zsh', '-c', harness + step + '\nbit101_verify_step modules child\nprint checks=$checks'],
            text=True, capture_output=True)
        if result.returncode or ('executed\n' in result.stdout) == current or f'checks={1 if current else 2}' not in result.stdout:
            findings.append('模块聚合复验：当前完整证据复用，缺失与过期证据执行后验收')
    finish = 'finish_validation() {' + source.split('finish_validation() {', 1)[1].split('\ntrap finish_validation', 1)[0]
    for test_status, merge_status in ((0, 0), (7, 0), (0, 9), (7, 9)):
        harness = f'''ROOT_DIR=/fixture DERIVED_ROOT=/fixture validation_group=all validation_scope=selected
BUILD_ONLY=false WORKFLOW_STARTED_SECONDS=$SECONDS
retained_result_groups=(all ui)
python3() {{ print -r -- "PY $*"; [[ "$2" != retain-selected ]] || return {merge_status}; }}
'''
        result = subprocess.run(['zsh', '-c', harness + finish + f'\ntrap finish_validation EXIT\nexit {test_status}'],
            capture_output=True, text=True)
        if result.returncode != (merge_status or test_status) or 'retain-selected all all ui' not in result.stdout:
            findings.append('定向结果保留自测：退出钩子合并有效证据并传播失败')
    return findings

def restore_installation_boundary_findings() -> list[str]:
    "安装前清理旧恢复证据，清理失败沿真实安装分支传播。"
    import shlex
    support = shlex.quote(str(SCRIPT_ROOT / 'script-support.sh'))
    prefix = f'set -euo pipefail\nROOT_DIR={shlex.quote(str(ROOT))}\nsource {support}\n'
    prefix += '''rm() { :; }
xcrun() { print -ru2 INSTALL; }
bit101_run_logged() { print EXECUTE; }
record_result() { print RESULT; }
DERIVED_ROOT=/fixture DERIVED_DATA=/fixture RESULT_BUNDLE=/fixture/result
DEVICETCL_DEVICE_ID=phone BIT101_DEVICETCL_DEVICE_ID=phone DEVICE_ID=phone TEST_CLASS=fixture
common_args=()
'''
    native = (SCRIPT_ROOT / 'run-extended-tests.sh').read_text()
    start = '  if [[ "$BUILD_ONLY" == false && "$MODE" != catalyst && "$MODE" != catalyst-release-runtime ]]; then'
    native = start + native.split(start, 1)[1].split('  TEST_DURATION_SECONDS=', 1)[0]
    native = '''group=fixture log=/fixture test_action=test diagnostics=never conditions= TEST_DESTINATION=phone
execution_args=() only_testing=() SIGNING_ARGS=() coverage_args=() project_args=()
execute_test() {
''' + native + '\n}\nexecute_test\n'
    network = (SCRIPT_ROOT / 'release-network-smoke.sh').read_text()
    network = 'SMOKE_APP_PATH=' + network.split('\nSMOKE_APP_PATH=', 1)[1].split('\npython3 - "$LOCAL_REQUEST_PATH"', 1)[0]
    install = (SCRIPT_ROOT / 'build-install-device.sh').read_text()
    install = 'APP_PATH=' + install.split('\nAPP_PATH=', 1)[1].split('\nxcrun devicectl device process launch', 1)[0]
    cloud = (SCRIPT_ROOT / 'icloud-smoke-support.sh').read_text()
    cloud = 'run_phone_test() {' + cloud.split('run_phone_test() {', 1)[1].split('\nrun_mac_cleanup()', 1)[0]
    cases = [(native, f'MODE={mode} BUILD_ONLY={build}\n', status,
              status if mode in {'all', 'ui'} and build == 'false' else 0,
              ['CLEAR'] if status and mode in {'all', 'ui'} and build == 'false' else
              ['CLEAR', 'EXECUTE'] if mode in {'all', 'ui'} and build == 'false' else ['EXECUTE'])
        for mode, build, status in [('all', 'false', 0), ('ui', 'false', 0), ('all', 'false', 13),
            ('ui', 'false', 13), ('catalyst', 'false', 13), ('catalyst-release-runtime', 'false', 13), ('all', 'true', 13)]]
    cases += [(program, '', status, status, ['CLEAR'] if status else ['CLEAR', 'INSTALL'])
              for program in (network, install) for status in (0, 13)]
    cases += [(cloud + f'\nrun_phone_test {method}\n', '', status, status,
               ['CLEAR'] if status else ['CLEAR', 'EXECUTE', 'RESULT'])
              for method in ('testPhoneRoundTrip', 'testCleanup') for status in (0, 13)]
    findings = []
    for program, context, invalidation, expected, events in cases:
        stub = f'python3() {{ print CLEAR; return {invalidation}; }}\n'
        result = subprocess.run(['zsh', '-c', prefix + stub + context + program],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
        observed = [line for line in result.stdout.splitlines() if line in {'CLEAR', 'INSTALL', 'EXECUTE', 'RESULT'}]
        if result.returncode != expected or observed != events:
            findings.append(f'安装恢复生命周期自测：{context.strip()} {expected}，实际 {result.returncode} {result.stdout.strip()}')
    from script_test_support import heredoc_body
    program = heredoc_body((SCRIPT_ROOT / 'script-support.sh').read_text(), 'PYMACINSTALL')
    fixture = ROOT / '.build/static-audit/workflow-lock-self-test'
    try:
        for stage in ('copy-failure', 'swap-failure', 'replace', 'first-install'):
            shutil.rmtree(fixture, ignore_errors=True)
            source, installed = fixture / 'source.app', fixture / 'installed.app'
            source.mkdir(parents=True); (source / 'binary').write_text('new')
            if stage != 'first-install':
                installed.mkdir(); (installed / 'binary').write_text('old')
            def copy(arguments, **kwargs):
                shutil.copytree(arguments[1], arguments[2])
                if stage == 'copy-failure': raise OSError('copy interrupted')
            library = Mock(renamex_np=Mock(return_value=-1)) if stage == 'swap-failure' else __import__('ctypes').CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
            with patch.object(sys, 'argv', ['install', str(source), str(installed)]), patch.object(subprocess, 'run', side_effect=copy), patch('ctypes.CDLL', return_value=library):
                try: exec(compile(program, '<mac-app-install>', 'exec'), {})
                except OSError:
                    if not stage.endswith('failure'): raise
            expected = 'old' if stage.endswith('failure') else 'new'
            assert (installed / 'binary').read_text() == expected and not (fixture / '.BIT101-iOS.install.app').exists(), stage
    finally: shutil.rmtree(fixture, ignore_errors=True)
    return findings

def audit_lock_boundary_findings() -> list[str]:
    "并发验收沿产物锁、审计锁顺序执行，并复用父流程锁。"
    import fcntl
    import select
    import shlex
    fixture = ROOT / '.build/static-audit/workflow-lock-self-test'
    worker = fixture / 'worker.sh'
    processes, findings = [], []
    environment = dict(os.environ)
    for name in ('BIT101_EXTENDED_TESTS_LOCK_HELD', 'BIT101_STATIC_AUDIT_LOCK_HELD', 'BIT101_WORKFLOW_DEADLINE'):
        environment.pop(name, None)
    source = (SCRIPT_ROOT / 'run-static-audit.sh').read_text()
    parser = source[source.index('set -euo pipefail'):source.index('\nROOT_DIR=')]
    shell = 'ROOT_DIR=' + source.split('ROOT_DIR=', 1)[1].split('LOG_DIR=', 1)[0]
    shell = re.sub(r'(?m)^ROOT_DIR=.*$', 'ROOT_DIR=' + shlex.quote(str(fixture)), shell)
    shell = shell.replace('source "$ROOT_DIR/Scripts/script-support.sh"', 'source ' + shlex.quote(str(SCRIPT_ROOT / 'script-support.sh')))
    manifest = f'''import ast, fcntl, os, runpy, sys
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace
sys.path.insert(0, {str(SCRIPT_ROOT)!r})
import code_quality_rules as quality
quality.ROOT = Path({str(fixture)!r})
rules = runpy.run_path({str(SCRIPT_ROOT / 'check-module-boundaries.py')!r})
original = fcntl.flock
def observe(lock, operation):
    if getattr(lock, 'name', '').endswith('extended-automation.lock'):
        print('artifact', flush=True)
    return original(lock, operation)
fcntl.flock = observe
def manifest():
    with patch('subprocess.run', return_value=SimpleNamespace(returncode=0, stdout='{{}}')):
        rules['read_manifest'](quality.ROOT)
if sys.argv[1] == 'direct':
    before = dict(os.environ)
    try: exec(compile(ast.Module(body=[ast.parse(Path({str(SCRIPT_ROOT / 'check-module-boundaries.py')!r}).read_text()).body[-1]], type_ignores=[]), '<module-entry>', 'exec'), dict(__name__='__main__', main=manifest, ROOT=quality.ROOT))
    except SystemExit as error: assert error.code is None
    assert dict(os.environ) == before
else: manifest()
print('entered', flush=True)
'''
    command = shlex.quote(sys.executable) + ' -B -c ' + shlex.quote(manifest)
    try:
        shutil.rmtree(fixture, ignore_errors=True)
        fixture.mkdir(parents=True)
        (fixture / 'Scripts').symlink_to(SCRIPT_ROOT, target_is_directory=True)
        (fixture / '.build/static-audit').mkdir(parents=True)
        worker.write_text('if [[ "$1" == direct ]]; then exec ' + command + ' direct; fi\nshift\n' + parser + '\n' + shell
            + '\nif (( ${group_names[(Ie)module-boundary]} )); then ' + command + ' shell; else print entered; fi\n')
        for mode in ('shell', 'direct'):
            with (fixture / '.build/extended-automation.lock').open('a') as artifact:
                fcntl.flock(artifact, fcntl.LOCK_EX)
                standalone = subprocess.Popen(['zsh', str(worker), mode], env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                processes.append(standalone)
                if not select.select([standalone.stdout], [], [], 5)[0]: raise ValueError('并发审计开始等待产物锁')
                progress = standalone.stdout.readline().strip()
                if progress != 'artifact' and not progress.startswith('[等待]'): raise ValueError(progress)
                with (fixture / '.build/static-audit/audit.lock').open('a') as audit:
                    fcntl.flock(audit, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(audit, fcntl.LOCK_UN)
                inherited = subprocess.run(['zsh', str(worker), 'shell'], capture_output=True, text=True, timeout=5,
                    env=dict(environment, BIT101_EXTENDED_TESTS_LOCK_HELD='1'))
                if inherited.returncode or inherited.stdout.strip() != 'entered': raise ValueError(inherited.stderr)
                focused = subprocess.run(['zsh', str(worker), 'shell', '--self-test', 'docs', 'python-parse'],
                    capture_output=True, text=True, timeout=5,
                    env=dict(environment, GITHUB_ACTIONS='false', BIT101_RELEASE_CHECK='false'))
                if focused.returncode or focused.stdout.strip() != 'entered': raise ValueError(focused.stderr)
                fcntl.flock(artifact, fcntl.LOCK_UN)
            output, error = standalone.communicate(timeout=5)
            if standalone.returncode or output.strip() != 'entered': raise ValueError(error)
        cache = (SCRIPT_ROOT / 'run-extended-tests.sh').read_text().split('if [[ "${1:-}" == performance', 1)[0]
        cache = re.sub(r'(?m)^ROOT_DIR=.*$', 'ROOT_DIR=' + shlex.quote(str(fixture)), cache)
        cache = cache.replace('source "$ROOT_DIR/Scripts/script-support.sh"',
                              'source ' + shlex.quote(str(SCRIPT_ROOT / 'script-support.sh')))
        recovery = '''python3() {
  if [[ "${1:-}" == */Scripts/validation_performance.py && "${2:-}" == recover-batch ]]; then return 0; fi
  command python3 "$@"
}
'''
        worker.write_text(recovery + cache)
        diagnostics = fixture / '.build/extended-automation/diagnostics'
        (diagnostics / 'test-results.xcresult').mkdir(parents=True)
        (diagnostics / 'test-results.xcresult/Info.plist').write_text('retained')
        (diagnostics / 'exported.log').write_text('temporary')
        with (fixture / '.build/extended-automation.lock').open('a') as artifact:
            fcntl.flock(artifact, fcntl.LOCK_EX)
            standalone = subprocess.Popen(['zsh', str(worker), 'cache'], env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            processes.append(standalone)
            if not select.select([standalone.stdout], [], [], 5)[0]: raise ValueError('缓存整理开始等待产物锁')
            if not standalone.stdout.readline().startswith('[等待]'): raise ValueError('缓存整理复用产物锁顺序')
            inherited = subprocess.Popen(['zsh', str(worker), 'cache'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, start_new_session=True, env=dict(environment, BIT101_EXTENDED_TESTS_LOCK_HELD='1'))
            processes.append(inherited)
            output, error = inherited.communicate(timeout=5)
            if inherited.returncode or '缓存整理：' not in output: raise ValueError(error)
            fcntl.flock(artifact, fcntl.LOCK_UN)
        output, error = standalone.communicate(timeout=5)
        if standalone.returncode or '缓存整理：' not in output: raise ValueError(error)
        assert (diagnostics / 'test-results.xcresult/Info.plist').read_text() == 'retained'
        assert not (diagnostics / 'exported.log').exists()
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        findings.append(f'审计锁顺序自测：{error}')
    finally:
        for process in processes:
            if process.poll() is None:
                import signal
                try: os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError: process.terminate()
                process.communicate(timeout=5)
        shutil.rmtree(fixture, ignore_errors=True)
    return findings

def audit_cancellation_findings() -> list[str]:
    import os
    import select
    source = (SCRIPT_ROOT / 'run-static-audit.sh').read_text()
    cleanup = 'finish_audit() {' + source.split('finish_audit() {', 1)[1].split('\nSWIFT_FRONTEND=', 1)[0]
    from script_test_support import shell_function
    launcher = shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_start_audit_group')
    runner = shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_run_audit_group')
    fixture = ROOT / '.build/static-audit/audit-cancellation-self-test'
    shutil.rmtree(fixture, ignore_errors=True)
    fixture.mkdir(parents=True, exist_ok=True)
    (fixture / 'Scripts').symlink_to(SCRIPT_ROOT, target_is_directory=True)
    harness = 'LOG_DIR=' + shlex.quote(str(fixture)) + '''
exec 3>&1
ROOT_DIR=/fixture SWIFT_FRONTEND=frontend AUDIT_STARTED=$SECONDS group_processes=() group_names=() full_audit=1
python3() { if [[ "$1" == "$ROOT_DIR/Scripts/validation_evidence.py" ]]; then return 0; fi; command python3 "$@"; }
bit101_show_audit_log() { :; }
blocked_task() { python3 -c 'import os, time; print(os.getpid(), os.getpgrp(), flush=True); time.sleep(60)' >&3; }
'''
    harness = harness.replace('ROOT_DIR=/fixture', 'ROOT_DIR=' + shlex.quote(str(fixture)))
    findings = []
    for signum, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
        process = subprocess.Popen(['zsh', '-c', harness + cleanup + runner + launcher + '\nbit101_start_audit_group stdout blocked_task\nwait "$group_processes[1]"'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        worker_group = None
        try:
            if not select.select([process.stdout], [], [], 5)[0]: raise ValueError('后台检查启动需要及时响应')
            worker, worker_group = map(int, process.stdout.readline().split())
            os.kill(process.pid, signum)
            _, error = process.communicate(timeout=5)
            assert process.returncode == expected, error
            from workflow_processes import active_members
            if worker in active_members({worker_group}): raise ValueError('中断完成后后台检查需要结束')
        except (ValueError, AssertionError, subprocess.TimeoutExpired) as error:
            reason = '后台检查清理需要按测试预算完成' if isinstance(error, subprocess.TimeoutExpired) else str(error)
            findings.append(f'审计中断自测：{reason}')
        finally:
            if worker_group is not None:
                try:
                    if os.getpgid(worker) == worker_group: os.killpg(worker_group, signal.SIGKILL)
                except ProcessLookupError: pass
            if process.poll() is None: os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
    shutil.rmtree(fixture)
    return findings
def script_command_boundary_findings() -> list[str]:
    for name in ('run-extended-tests.sh', 'run_icloud_cross_device_smoke.sh'):
        result = subprocess.run(['/bin/zsh', str(SCRIPT_ROOT / name), '--help'], capture_output=True, text=True,
            env=dict(os.environ, PATH='/usr/bin:/bin'))
        assert result.returncode == 0 and result.stdout and not result.stderr, (name, result.stderr)
    from test_results import module_filter
    selected = StringIO()
    with redirect_stdout(selected): module_filter(['Suite', 'Other/name()'])
    pattern = selected.getvalue().strip()
    assert re.search(pattern, 'App.Suite/works()') and re.search(pattern, 'Other/name()')
    assert not re.search(pattern, 'App.SuiteExtra/works()')
    audit = (SCRIPT_ROOT / 'run-static-audit.sh').read_text()
    for option, status in (('--help', 0), ('--unknown', 64)):
        result = subprocess.run(['zsh', '-c', audit, '/missing/audit', option], text=True, capture_output=True)
        assert result.returncode == status and '用法' in result.stdout + result.stderr
    from ci_wiring_rules import hook_documents_checked, active_script_markers
    from module_boundary_tests import build_cache_exit_self_test
    assert hook_documents_checked('exec python3 Scripts/check-docs.py --staged')
    for source in ('# exec python3 Scripts/check-docs.py --staged', 'echo "python3 Scripts/check-docs.py --staged"'):
        assert not hook_documents_checked(source)
    assert 'xccov' not in active_script_markers('# xccov\necho ready # xccov')
    "通过内存替身验证自动选机、操作分派、筛选合并及参数拒绝。"
    import shlex
    import plistlib
    metadata_option = 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES'
    metadata_arguments = ['ARGUMENTS', '/fixture/log', metadata_option, 'xcodebuild', 'build-for-testing',
        '-configuration', 'Release', '-enableCodeCoverage', 'YES', 'ENABLE_CODE_COVERAGE=YES', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES']
    assert any(metadata_option in finding for finding in test_build_argument_findings(shlex.join(metadata_arguments))), \
        '日志标签中的参数进入元数据，实际编译命令承担参数门禁'
    assert any('ONLY_ACTIVE_ARCH=YES' in finding for finding in test_build_argument_findings(shlex.join(metadata_arguments), testing_device=True))

    findings = result_retention_boundary_findings() + audit_cancellation_findings() + build_cache_exit_self_test()
    from script_output_tests import log_output_boundary_findings, combined_audit_order_findings
    findings += log_output_boundary_findings()
    findings += combined_audit_order_findings()
    from test_results_tests import test_result_boundary_findings
    findings += test_result_boundary_findings()
    isolated_digest = '''from pathlib import Path
from unittest.mock import patch
import sys
original_read = Path.read_text
def read(path, *args, **kwargs):
    if path.name == 'PerformanceWorkloads.json': raise ValueError('invalid workload fixture')
    return original_read(path, *args, **kwargs)
with patch.object(Path, 'read_text', read):
    import validation_evidence
    with patch.object(validation_evidence, 'input_identity', return_value='fixture'), patch.object(sys, 'argv', ['validation_evidence.py', 'digest']):
        raise SystemExit(validation_evidence.main())
'''
    result = subprocess.run([sys.executable, '-B', '-c', isolated_digest], cwd=SCRIPT_ROOT, capture_output=True, text=True)
    if result.returncode or result.stdout.strip() != 'fixture':
        findings.append('基础证据摘要自测：人工性能配置按所属操作加载')
    audit_source = (SCRIPT_ROOT / 'run-static-audit.sh').read_text()
    audit_exit = 'finish_audit() {' + audit_source.split('finish_audit() {', 1)[1].split('\nSWIFT_FRONTEND=', 1)[0]
    for action, expected, recording in (('exit 0', 0, 0), ('exit 7', 7, 0), ('kill -s INT $$', 130, 0),
                                       ('kill -s TERM $$', 143, 0), ('exit 0', 9, 9), ('exit 7', 7, 9)):
        harness = f'''ROOT_DIR=/fixture AUDIT_STARTED=$SECONDS group_processes=() group_names=() full_audit=1
python3() {{ print -r -- "RECORD $*"; return {recording}; }}
'''
        result = subprocess.run(['zsh', '-c', harness + audit_exit + '\n' + action], capture_output=True, text=True)
        original = expected if not recording else 0 if action == 'exit 0' else 7
        if result.returncode != expected or result.stdout.count(f'RECORD /fixture/Scripts/validation_evidence.py record audit {original}') != 1:
            findings.append('静态审计退出自测：完成、失败及信号统一登记，保留原始失败状态')
    simulator = subprocess.run(['zsh', str(SCRIPT_ROOT / 'simulator-tests.sh'), 'info'],
        env=dict(os.environ, BIT101_SIMULATOR_AUTHORIZED='0'), capture_output=True, text=True)
    if simulator.returncode != 64 or '显式授权' not in simulator.stderr:
        findings.append('模拟器命令自测：执行前核对用户授权标记')
    simulator_source = (SCRIPT_ROOT / 'simulator-tests.sh').read_text()
    import validation_evidence as evidence
    inventory = ['Suite/first', 'Suite/second']
    with patch.object(evidence, 'test_inventory', return_value=set(inventory)), \
            patch.object(evidence, 'test_selectors', return_value={name: name + '()' for name in inventory}), \
            patch('validation_coverage.shard_inventory', return_value=inventory):
        for scope, selected, shard in (('full', [], None), ('shard', [], '0/1'), ('selected', inventory[:1], None)):
            expected, selectors = evidence.simulator_test_selection('all', scope, selected, shard)
            assert expected == (selected if scope == 'selected' else inventory)
            assert selectors == [name + '()' for name in expected]
        try: evidence.simulator_test_selection('all', 'selected', ['Missing/test'], None)
        except ValueError: pass
        else: findings.append('模拟器库存规划需要传播失效筛选。')
    from types import SimpleNamespace
    from validation_coverage import run_simulator_ui, SIMULATOR_KEYBOARD_TESTS
    selected = ['-only-testing:BIT101-iOSUITests/' + sorted(SIMULATOR_KEYBOARD_TESTS)[0],
        '-only-testing:BIT101-iOSUITests/First/test', '-only-testing:BIT101-iOSUITests/Second/test']
    with patch.object(Path, 'read_bytes', return_value=plistlib.dumps({'TestConfigurations': []})), \
            patch.object(Path, 'write_bytes'), patch.object(shutil, 'rmtree'), \
            patch.object(shutil, 'copyfile') as copied, \
            patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=65)) as executed, \
            patch('validation_performance.result_bundle_complete', return_value=True):
        result = run_simulator_ui(Path('/audit/plan'), Path('/audit/derived'), 'device', 2, selected)
        if result != 65 or executed.call_count != 1 or copied.called:
            findings.append('原生键盘阶段失败应保留原始退出状态和结果包并立即结束。')
    from validation_restore import simulator_restore_findings
    from script_output_tests import verification_finish_findings
    findings.extend(simulator_restore_findings(simulator_source))
    findings.extend(verification_finish_findings())
    support = SCRIPT_ROOT / "script-support.sh"
    icloud_source = (SCRIPT_ROOT / 'run_icloud_cross_device_smoke.sh').read_text()
    recovery = 'finish_smoke() {' + icloud_source.split('finish_smoke() {', 1)[1].split('\ntrap finish_smoke', 1)[0]
    for original, phone_status, mac_status, attempted in ((0, 0, 0, False), (7, 0, 0, False),
            (0, 9, 0, False), (0, 0, 9, False), (7, 9, 9, False), (7, 9, 9, True)):
        stub = f'''ROOT_DIR=/fixture SUMMARY_PATH=/fixture/report CLEANUP_ONLY=false validation_group=icloud PHONE_AVAILABLE=true
PHONE_TEST_PID= PHONE_TESTS_STARTED=true PHONE_CLEANED_UP=false MAC_TESTS_STARTED=true MAC_CLEANED_UP=false
PHONE_CLEANUP_ATTEMPTED={str(attempted).lower()} MAC_CLEANUP_ATTEMPTED={str(attempted).lower()}
run_phone_test() {{ print PHONE; return {phone_status}; }}
run_mac_cleanup() {{ print MAC; return {mac_status}; }}
python3() {{ :; }}
report_result() {{ :; }}
'''
        result = subprocess.run(['zsh', '-c', stub + recovery + '\ntrap finish_smoke EXIT\nexit "$1"',
            'icloud-recovery-test', str(original)], capture_output=True, text=True)
        if result.returncode != (original or int(bool(phone_status or mac_status))) \
                or result.stdout.splitlines().count('PHONE') != int(not attempted) or result.stdout.splitlines().count('MAC') != int(not attempted):
            findings.append('iCloud 恢复自测：双端清理独立执行并保留原始失败状态')
    availability = icloud_source.split('PHONE_AVAILABLE=true\n', 1)[1].split('BIT101_VALIDATION_RUN_ID=', 1)[0]
    cleanup_entry = 'cleanup_status=0\n' + icloud_source.split('cleanup_status=0\n', 1)[1].split(
        'echo "[构建] 准备 Mac Catalyst 测试宿主"', 1)[0]
    cleanup_recovery = recovery
    for phone, mac, build, test, expected in ((0, 0, 0, 0, 0), (1, 0, 0, 0, 1), (1, 9, 0, 0, 1),
            (0, 9, 0, 0, 1), (0, 0, 9, 0, 9), (0, 0, 0, 9, 1)):
        stub = f'''set -euo pipefail
ROOT_DIR=/fixture DERIVED_ROOT=/fixture SUMMARY_PATH=/fixture/report RESULT_BUNDLE=/fixture/result
CLEANUP_ONLY=true validation_group=icloud PHONE_AVAILABLE=true CLEANUP_DEVICE_ID=phone-a DEVICE_ID=phone-a
PHONE_TEST_PID= PHONE_TESTS_STARTED=false PHONE_CLEANED_UP=false MAC_TESTS_STARTED=false MAC_CLEANED_UP=false
PHONE_CLEANUP_ATTEMPTED=false MAC_CLEANUP_ATTEMPTED=false
common_args=() TEST_CLASS=Fixture
bit101_require_device() {{ [[ "$1" == phone-a ]] || exit 81; return {phone}; }}
bit101_run_logged() {{ print BUILD; return {build}; }}
run_phone_test() {{ PHONE_CLEANUP_ATTEMPTED=true; print PHONE; return {test}; }}
run_mac_cleanup() {{ MAC_CLEANUP_ATTEMPTED=true; print MAC; return {mac}; }}
python3() {{ :; }}
report_result() {{ :; }}
'''
        result = subprocess.run(['zsh', '-c', stub + availability + cleanup_recovery +
            '\ntrap finish_smoke EXIT ZERR\n' + cleanup_entry],
            capture_output=True, text=True)
        rows = result.stdout.splitlines()
        if result.returncode != expected or rows.count('MAC') != 1 \
                or rows.count('PHONE') != int(not phone and not build) \
                or 'RESTORE' in rows or phone and any(marker in rows for marker in ('BUILD', 'PHONE')) \
                or not phone and ('BUILD' not in rows or rows.index('MAC') > rows.index('BUILD')) \
                or not phone and not build and 'PHONE' not in rows:
            findings.append('iCloud 恢复自测：手机离线及构建失败仍推进 Mac 清理，两端失败保留待恢复状态')
    pending = icloud_source.split('pending_cleanup="$(python3 - "$SUMMARY_PATH" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
    passed = dict(exitCode=0, totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
    prior_stages = [dict(passed, stage=stage) for stage in ('testPhoneRoundTrip', 'testMacReceiveAndRestore')]
    for overrides, expected in (({}, ''), ({'macCleanup': dict(passed, exitCode=1)}, 'cleanup'),
            ({'cleanup': dict(passed, exitCode=1)}, 'cleanup'), ({'stages': prior_stages[:1]}, 'cleanup'),
            ({'stages': [], 'testsStarted': False}, ''), ({'stages': [], 'testsStarted': True}, 'cleanup')):
        output = StringIO()
        with patch.object(sys, 'argv', ['pending-cleanup', '/fixture']), \
                patch.object(Path, 'read_text', return_value=json.dumps(dict({'stages': prior_stages}, **overrides))), redirect_stdout(output):
            exec(compile(pending, '<icloud-pending-cleanup>', 'exec'), {})
        if output.getvalue().strip() != expected:
            findings.append('iCloud 恢复自测：双端恢复通过后进入新验收账号')
    identity = icloud_source.split('cleanup_identity="$(python3 - "$SUMMARY_PATH" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
    run_id = '00000000-0000-0000-0000-000000000001'
    phone = dict(stage='testPhoneRoundTrip', destination={'deviceIdentifier': 'phone-a'})
    for report, valid in (
        ({'phoneDeviceIdentifier': 'phone-a', 'stages': [phone]}, True),
        ({'stages': [phone]}, True), ({'phoneDeviceIdentifier': 'phone-a', 'stages': []}, True),
        ({'stages': []}, False), ({'phoneDeviceIdentifier': 'phone-b', 'stages': [phone]}, False),
    ):
        output, succeeded = StringIO(), True
        with patch.object(sys, 'argv', ['cleanup-identity', '/fixture']), \
                patch.object(Path, 'read_text', return_value=json.dumps(dict(report, runID=run_id))), redirect_stdout(output):
            try: exec(compile(identity, '<icloud-cleanup-identity>', 'exec'), {})
            except SystemExit: succeeded = False
        if succeeded != valid or output.getvalue().splitlines() != ([run_id, 'phone-a'] if valid else []):
            findings.append('iCloud 恢复自测：沿原执行设备读取账号，身份冲突保留既有报告')
    from test_results import report_test_results
    for has_info, staging in ((True, False), (True, True), (False, False)):
        output = StringIO()
        with patch.object(sys, 'argv', ['report', '/fixture/results.xcresult', 'json', 'report', str(SCRIPT_ROOT)]), \
                patch.object(Path, 'is_file', lambda path: has_info and path.name == 'Info.plist'), \
                patch.object(Path, 'exists', lambda path: staging and path.name == 'Staging'), \
                patch.object(subprocess, 'check_output', return_value='{}'), redirect_stdout(output):
            try:
                report_test_results(sys.argv[1:])
            except SystemExit as error:
                if (error.code == 0) != (has_info and not staging):
                    findings.append('结果包读取自测：已完成的文件存储格式沿 xcresulttool 读取')
    frame = r'''
bit101_require_device() {
  print DEVICE
  export BIT101_XCODE_DEVICE_ID=udid BIT101_DEVICETCL_DEVICE_ID=core
  export BIT101_DEVICE_TRANSPORT=wired BIT101_DEVICE_NAME=phone
}
bit101_build_cache() { print CACHE; }
bit101_set_workflow_budget() { :; }
bit101_acquire_workflow_lock() { print WORKFLOW_LOCK; print DEVICE_LOCK; }
bit101_acquire_artifact_lock() { print WORKFLOW_LOCK; print ARTIFACT_LOCK; }
bit101_acquire_script_lock() { :; }
bit101_invalidate_restore() { print RESTORE_INVALIDATED; }
mkdir() { :; }
rm() { :; }
ditto() { :; }
bit101_install_mac_app() { :; }
open() { :; }
pgrep() { return 1; }
trap() { :; }
xcrun() {
  if [[ "$*" == '--find swift-frontend' ]]; then print /usr/bin/true;
  elif [[ "$*" == *lockState* ]]; then print '{"result":{"isLocked":false}}';
  else print -ru2 -- "TOOL $*"; fi
}
'''
    from script_test_support import shell_function
    frame += shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_catalyst_signing_arguments')
    archive = (SCRIPT_ROOT / 'build-install-device.sh').read_text().split('if [[ "$ACTION" == install-archive ]]; then', 1)[1]
    archive = 'bit101_require_device || exit 1' + archive.split('bit101_require_device || exit 1', 1)[1].split('\nfi\n', 1)[0]
    for clean in (False, True):
        program = frame + '\nAPP_PATH=/archive/App.app\nAPP_VERSION=1\nAPP_BUILD=1\n' + archive
        result = subprocess.run(['zsh', '-c', program, 'archive-install', 'install-archive', '/archive',
            *(['--clean'] if clean else [])], capture_output=True, text=True)
        assert result.returncode == 0 and 'RESTORE_INVALIDATED' in result.stdout
        assert 'device install app' in result.stderr and ('device uninstall app' in result.stderr) == clean
    valid_fixture = dict(posterID=1, courseID=2, courseNumber='COURSE', paperID=3)
    export_source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
    scope_source = (SCRIPT_ROOT / "release-network-smoke.sh").read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame).split('RUN_ID="', 1)[0]
    findings.extend(network_configuration_boundary_findings())
    preflight = re.search(r'(?ms)^  for group in .*?^  acquire_test_lock$', export_source)[0]
    assert '--check-config' in preflight and 'verify_step' not in preflight
    block = re.search(r'(?ms)^  verification_network_args=.*?(?=^  acquire_test_lock$)', export_source)[0]
    for arguments in (['verify', 'modules', 'network'], ['verify', 'all', 'community-writes']):
        harness = 'set -euo pipefail\nROOT_DIR=' + shlex.quote(str(SCRIPT_ROOT.parent)) + '\nshift\n' + block + '\nprint READY'
        result = subprocess.run(['zsh', '-c', harness, 'configuration-order', *arguments], capture_output=True, text=True,
            env=dict(os.environ, BIT101_COMMUNITY_SMOKE_ACCOUNT='1', BIT101_NETWORK_SMOKE_FIXTURES='{}',
                BIT101_NETWORK_SMOKE_CAPTURE='none', BIT101_COMMUNITY_RECOVERY_CONFIRMATION=''))
        assert result.returncode == 64 and 'READY' not in result.stdout, '聚合配置失败在编译及设备恢复前返回'
    for capture in ('rawCourseResponse', 'scheduleCache'):
        for scope in ('all', 'school', 'schedule', 'bit101', 'ddl', 'transcript', 'community-writes', 'community-cleanup'):
            result = subprocess.run(['zsh', '-c', scope_source, str(SCRIPT_ROOT / 'release-network-smoke.sh'), scope],
                env=dict(os.environ, BIT101_NETWORK_SMOKE_CAPTURE=capture, BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture), BIT101_COMMUNITY_SMOKE_ACCOUNT='1'), capture_output=True, text=True)
            if (result.returncode == 0) != (scope in ('all', 'school', 'schedule')):
                findings.append('网络采样自测：课表采样与执行范围匹配')
    confirmation = dict(account=1, marker='功能验收 fixture', serverReceipt='backend-reconciliation', kinds=['poster'], parents=[])
    for scope, value, valid in (('community-cleanup', confirmation, True), ('ddl', confirmation, False),
            ('community-cleanup', dict(confirmation, kinds=[], settledMutations=['follow:user2', 'like:course1']), True),
            ('community-cleanup', dict(confirmation, kinds=[], settledMutations=['like:course0']), False),
            ('community-cleanup', dict(confirmation, serverReceipt=''), False),
            ('community-cleanup', dict(confirmation, kinds=['course']), False), ('community-cleanup', {}, False)):
        result = subprocess.run(['zsh', '-c', scope_source, str(SCRIPT_ROOT / 'release-network-smoke.sh'), scope],
            env=dict(os.environ, BIT101_COMMUNITY_RECOVERY_CONFIRMATION=json.dumps(value)), capture_output=True, text=True)
        assert (result.returncode == 0) == valid, '服务端未创建确认需要匹配清理范围及确认载荷'
        if not valid: assert 'WORKFLOW_LOCK' not in result.stdout, '确认载荷校验在选机及安装前完成'
    for value, valid in ((valid_fixture, True), ({}, False), (dict(valid_fixture, posterID=True), False),
            (dict(valid_fixture, courseID=0), False), (dict(valid_fixture, courseNumber=' COURSE'), False)):
        result = subprocess.run(['zsh', '-c', scope_source, str(SCRIPT_ROOT / 'release-network-smoke.sh'), 'bit101'],
            env=dict(os.environ, BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(value), BIT101_COMMUNITY_SMOKE_ACCOUNT='1'), capture_output=True, text=True)
        if (result.returncode == 0) != valid:
            findings.append('网络维护对象自测：校验对象标识及课程编号')
    for arguments, term, expected in ((['all'], '', 'network full'), (['all'], 'historical', 'network selected'),
            (['school', 'sms'], '', 'school-sms full'), (['school', 'sms'], 'historical', 'school-sms selected')):
        result = subprocess.run(['zsh', '-c', scope_source + '\nprint -r -- "$validation_group $validation_scope"',
            str(SCRIPT_ROOT / 'release-network-smoke.sh'), *arguments], capture_output=True, text=True,
            env=dict(os.environ, BIT101_NETWORK_SMOKE_TERM=term, BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture), BIT101_COMMUNITY_SMOKE_ACCOUNT='1'))
        if result.returncode or result.stdout.splitlines()[-1:] != [expected]:
            findings.append('网络学期自测：覆盖学期采样沿定向范围登记')
    export_source = export_source.replace('  python3 "$ROOT_DIR/Scripts/test_results.py" report',
        '  exit 86\n  python3 "$ROOT_DIR/Scripts/test_results.py" report')
    for arguments, locked in ((["report", "json"], False), (["diagnostics"], True), (["activities", "test"], False),
                              (["screenshot", "test"], True), (["report", "Suite/test"], True)):
        result = subprocess.run(["zsh", "-c", export_source, str(SCRIPT_ROOT / "run-extended-tests.sh"), *arguments],
                                env=dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1"), capture_output=True, text=True)
        if result.returncode != 86 or result.stdout.count("WORKFLOW_LOCK") != int(locked):
            findings.append(f"结果读取与附件导出沿各自的锁范围执行：{arguments[0]}")
    for command, markers in ((["xcrun", "devicectl", "device", "process", "launch", "--help"], ["--terminate-existing", "<command-line-arguments>"]),
            (["xcrun", "devicectl", "device", "info", "processes", "--help"], ["--json-output"]),
            (['xcrun', 'xcresulttool', 'merge', '--help'], ['--output-path'])):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode or any(marker not in result.stdout for marker in markers):
            findings.append("装机恢复自测：当前工具链需要正式启动与进程读取参数")
    ui_test_count = sum(
        len(re.findall(r"^\s*(?:@objc )?func test\w+\(", path.read_text(), re.MULTILINE))
        for path in (ROOT / "BIT101-iOSUITests").glob("*.swift")
    )
    cases = (
        ("build-install-device.sh", [], 0, "platform=iOS,id=udid", "DEVICE"),
        ("build-install-device.sh", ["build"], 0, "generic/platform=iOS", ""),
        ("build-install-device.sh", ["archive"], 0, "xcodebuild archive", ""),
        ("build-install-device.sh", ["archive-signed"], 0, "xcodebuild archive", ""),
        ("build-install-device.sh", ["mac"], 0, "variant=Mac Catalyst", ""),
        ("build-install-device.sh", ["info"], 0, "phone", "DEVICE"),
        ("build-install-device.sh", ["screenshot"], 0, "截图已保存", "DEVICE"),
        ("run-extended-tests.sh", ["build"], 0, "build-for-testing", ""),
        ("run-extended-tests.sh", ["build", "ui"], 0, "BIT101-iOS-UIAutomation", ""),
        ("run-extended-tests.sh", ["build", "network-smoke"], 0, "RELEASE_NETWORK_SMOKE", ""),
        ("run-extended-tests.sh", ["build", "icloud-smoke"], 0, "ICLOUD_CROSS_DEVICE_SMOKE", ""),
        ("run-extended-tests.sh", ["build", "modules"], 0, "swift build", ""),
        ("run-extended-tests.sh", ["build", "catalyst"], 0, "variant=Mac Catalyst", ""),
        ("run-extended-tests.sh", ["build", "catalyst-release-runtime"], 0, "BIT101_WORKFLOW_CONDITIONS=", ""),
        ("run-extended-tests.sh", ["catalyst"], 86, "-only-testing:BIT101-iOSTests", ""),
        ("run-extended-tests.sh", ["catalyst", "LoginStorageTests"], 86, "-only-testing:BIT101-iOSTests/LoginStorageTests", ""),
        ("run-extended-tests.sh", ["catalyst-release-runtime"], 86, "ReleaseRuntimeContractTests", ""),
        ("run-extended-tests.sh", ["release-runtime"], 86, "ReleaseRuntimeContractTests", "DEVICE"),
        ("run-extended-tests.sh", ["network-smoke", "NetworkSmokeRegressionTests"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "About", "About"], 86, "CommunityPublishingUITests/testAboutLicenseUpdateAndResetConfirmation", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "Schedule"], 86, "testScheduleWeekButtonsAndSectionSwipes", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "DDLEditor"], 86, "ScheduleNavigationUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "test"], 86, f"{ui_test_count} 项 UI 用例", "DEVICE"),
        ("run-extended-tests.sh", ["modules"], 86, "swift test", ""),
        ("run-extended-tests.sh", ["modules", "CommunityCoreTests"], 86, "--filter", ""),
        ("run-extended-tests.sh", [], 86, "-only-testing:BIT101-iOSTests", "DEVICE"),
        ("run-extended-tests.sh", ["NetworkClientTests"], 86, "BIT101-iOSTests/NetworkClientTests", "DEVICE"),
        ("run-extended-tests.sh", ["AppUpdateCheckerTests/promptQueueIsSerial"], 86, "BIT101-iOSTests/AppUpdateCheckerTests/promptQueueIsSerial()", "DEVICE"),
        ("run-extended-tests.sh", ["cache"], 0, "CACHE", ""),
        ("release-network-smoke.sh", ["ddl"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("release-network-smoke.sh", ["all", "sms"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("release-network-smoke.sh", ["school", "sms"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("run_icloud_cross_device_smoke.sh", [], 86, "ICLOUD_CROSS_DEVICE_SMOKE", "DEVICE"), ("run_icloud_cross_device_smoke.sh", ["report"], 0, "REPORT", ""),
    )
    environment = dict(os.environ, BIT101_WORKFLOW_CONDITIONS='DEBUG RELEASE_NETWORK_SMOKE', BIT101_EXTENDED_TESTS_LOCK_HELD="1", BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture), BIT101_COMMUNITY_SMOKE_ACCOUNT='1')
    for filename, arguments in (("build-install-device.sh", ["archive"]), ("run-extended-tests.sh", ["build"]),
                                ("release-network-smoke.sh", ["ddl"]), ("run_icloud_cross_device_smoke.sh", []),
                                ("run-static-audit.sh", [])):
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
        failure = frame + '''\npython3() {
  if [[ "$*" == *"validation_evidence.py digest"* ]]; then return 79; fi
  return 0
}\n'''
        result = subprocess.run(["zsh", "-c", failure + source, str(path), *arguments],
                                env=dict(environment, BIT101_STATIC_AUDIT_LOCK_HELD="1", SWIFT_FRONTEND="/usr/bin/true"),
                                capture_output=True, text=True)
        if result.returncode != 79:
            findings.append(f"源码摘要失败应在工作流启动前退出：{filename}")
    for arguments, groups in ((['ddl'], ['ddl']), (['all', 'sms'], ['network', 'school-sms']),
                             (['school', 'sms'], ['school-sms'])):
        path = SCRIPT_ROOT / 'release-network-smoke.sh'
        failure = frame.replace('trap() { :; }', '') + r'''
python3() {
  if [[ "$*" == *"validation_evidence.py digest"* ]]; then print self-test-inputs;
  elif [[ "$1" == *"/network_smoke_config.py" ]]; then command python3 "$@";
  elif [[ "$*" == *"validation_provenance.py worker-snapshot"* ]]; then return 79;
  elif [[ "$*" == *"validation_evidence.py record"* ]]; then print -r -- "RECORD $3 $4 $5";
  else return 0; fi
}
bit101_run_logged() { print BUILD; return 79; }
'''
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', failure)
        result = subprocess.run(['zsh', '-c', source, str(path), *arguments],
            env=environment, capture_output=True, text=True)
        records = [line for line in result.stdout.splitlines() if line.startswith('RECORD ')]
        if result.returncode != 79 or records != [f'RECORD {group} 79 full' for group in groups] \
                or 'BUILD\n' not in result.stdout or 'RESTORE\n' in result.stdout:
            findings.append(f'网络部署身份缺口自测：{arguments} 构建失败保留设备现有 App 并登记采样结果；退出 {result.returncode}；{result.stderr[-400:]}')
    for filename, arguments, expected, marker, device in cases:
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"',
                                         f"source {shlex.quote(str(support))}\n" + frame)
        source = re.sub(r'(?:>>|>) "\$RESTORE_LOG" 2>&1', '>&2', source)
        stop = "exit 86" if expected == 86 else "return 0"
        source = source.replace(frame, frame + f'\nbit101_run_logged() {{ print -r -- "BUILD $*"; print -r -- "ARGUMENTS ${{(qqq)@}}"; {stop}; }}\n' + '\npython3() { if [[ "$*" == *"validation_performance.py"* ]]; then return 0; fi; if [[ "$*" == *"validation_provenance.py worker-snapshot"* ]]; then print "{}"; return 0; fi; if [[ "$*" == *"validation_restore.py"* ]]; then print -ru2 RESTORE_PROBE; return 0; fi; if [[ "$*" == *"/signing.entitlements"* || "$*" == *"/icloud-cross-device-smoke/report.json"* ]]; then return 0; fi; if [[ "$*" == *"validation_evidence.py digest"* ]]; then case "$3" in all|release-runtime|ui|schedule|infrastructure|login|extensions|network|ddl|school-sms|community-writes|community-cleanup|icloud|icloud-cleanup|restore) [[ "${BIT101_XCODE_DEVICE_ID:-}" == udid ]] || return 78 ;; esac; print self-test-inputs; return 0; fi; command python3 "$@"; }\n')
        source = re.sub(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$",
                        'ui_test_plan() { print -r -- /audit/ui.xctestrun; }', source, count=1)
        source = re.sub(r"(?ms)^report_result\(\) \{\n.*?^\}$", 'report_result() { print REPORT; }', source, count=1)
        result = subprocess.run(["zsh", "-c", source, str(path), *arguments], env=environment,
                                capture_output=True, text=True)
        command_output = '\n'.join(line for line in result.stdout.splitlines() if line.startswith('BUILD '))
        if result.returncode != expected or marker not in result.stdout or ("DEVICE\n" in result.stdout) != bool(device) or filename == 'build-install-device.sh' and command_output and any(not re.search(r'\b' + name + r'=(?:\s|$)', command_output) for name in ('BIT101_WORKFLOW_CONDITIONS', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS')):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 退出 {result.returncode}/{expected}；目标参数 {marker!r}；{result.stderr}")
        if filename == 'run-extended-tests.sh':
            findings.extend(test_build_argument_findings(result.stdout, testing_device=arguments[:1] != ['build']))
            if arguments in (['build'], ['modules']):
                options = ('--enable-code-coverage',) if arguments == ['modules'] else (
                    '-enableCodeCoverage YES', 'ENABLE_CODE_COVERAGE=YES',
                    'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES')
                for option in options:
                    changed = source.replace(option, '') + '\n# ' + option + '\n'
                    mutated = subprocess.run(['zsh', '-c', changed, str(path), *arguments], env=environment,
                                             capture_output=True, text=True)
                    if not test_build_argument_findings(mutated.stdout):
                        findings.append(f'编译参数变异自测：注释中的 {option} 保留执行门禁')
        if filename == "build-install-device.sh" and not arguments and ("RESTORE_PROBE" not in result.stderr or "device info processes" not in result.stderr):
            findings.append("装机恢复自测：就绪信号与当前进程共同参与验收")
        if filename == "run-extended-tests.sh" and (not arguments or arguments[0] in {
                "catalyst", "catalyst-release-runtime", "release-runtime", "modules", "build"}):
            group = arguments[0] if arguments else "all"
            if group == "build":
                group = "build-" + (arguments[1] if len(arguments) > 1 else "release")
            if f"/extended-automation/{group}.log" not in result.stdout:
                findings.append(f"命令自测：{group} 保存独立验证组日志")
        needs_lock = arguments != ["info"] and (filename != "run_icloud_cross_device_smoke.sh" or arguments != ["report"])
        if ("WORKFLOW_LOCK\n" in result.stdout) != needs_lock:
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 取得工作流锁")
        if filename in {'run-extended-tests.sh', 'build-install-device.sh'} and needs_lock \
                and ("DEVICE_LOCK\n" in result.stdout) != (bool(device) or arguments == ["mac"] or filename == 'run-extended-tests.sh' and arguments[0] in {'modules', 'catalyst', 'catalyst-release-runtime'}):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 按共享资源选择锁范围")
        if filename == "run-extended-tests.sh" and arguments[:2] == ["ui", "About"] and command_output.count(marker) != 1:
            findings.append("命令自测：重复 UI 关键词合并为一个用例")
        if arguments == ["ui", "Schedule"] and "testAboutLicense" in result.stdout:
            findings.append("命令自测：方法关键词按实际流程筛选")
        if arguments == ["ui", "test"] and command_output.count("-only-testing:BIT101-iOSUITests/") != ui_test_count:
            findings.append("命令自测：两个测试类的全部交互用例可通过关键词选择")
    for filename, arguments in (
        ("run-extended-tests.sh", ["network-smoke"]),
        ("build-install-device.sh", ["build", "extra"]),
        ("run-extended-tests.sh", ["ui", "unmatched-keyword"]),
        ("run-extended-tests.sh", ["build", "unknown"]),
        ("run-extended-tests.sh", ["verify", "unknown"]),
        ("release-network-smoke.sh", ["unknown"]),
        ("run_icloud_cross_device_smoke.sh", ["unknown"]),
    ):
        result = subprocess.run(["zsh", str(SCRIPT_ROOT / filename), *arguments], capture_output=True, text=True)
        if result.returncode != 64:
            findings.append(f"命令自测：{filename} 错误参数在执行前拒绝")
    from test_results import ui_test_plan
    older, newer = Mock(), Mock()
    older.stat.return_value.st_mtime = 1
    newer.stat.return_value.st_mtime = 2
    selected = StringIO()
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), \
         patch.object(Path, "glob", return_value=[older, newer]), redirect_stdout(selected):
        try: ui_test_plan(sys.argv[1:])
        except SystemExit as error:
            if error.code not in (None, 0): raise
    if older.open.called or newer.open.called or selected.getvalue().strip() != str(newer):
        findings.append("UI 计划自测：最新构建选择及默认诊断配置保留")
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), patch.object(Path, "glob", return_value=[]):
        try:
            ui_test_plan(sys.argv[1:])
        except SystemExit as error:
            if ".xctestrun" not in str(error):
                findings.append("UI 计划自测：冷缓存缺少运行配置时的诊断")
        else:
            findings.append("UI 计划自测：运行配置完整性检查")

    findings.extend(device_discovery_boundary_findings())
    findings.extend(ui_metrics_boundary_findings())
    return findings


def ui_metrics_boundary_findings() -> list[str]:
    from test_results import record_native_metrics
    def inventory(process, key, pending=()):
        return {"processIdentifier": process, "scope": "mounted-controls",
            "identityScope": "testCaseNavigationPresentationAndOccurrence",
            "observedControls": [key, *pending], "disabledControls": [], "checkedDisabledControls": [],
            "unidentifiedInstances": [], "visitedControls": [{"instance": key, "identifier": key,
                "scope": f"Journey{process}/testRun", "actions": ["tap"]}]}
    output = "\n".join(["UI automation App process: 10", "UI control inventory: " + json.dumps(inventory(10, "first", ["pending"])),
        "UI automation App process: 20", "UI control inventory: " + json.dumps(inventory(20, "second")),
        'UI query metrics: {"liveQueries":{"count":20,"seconds":0.5},"sharedSnapshots":{"count":2,"seconds":1.5}}',
        'UI query metrics: {"liveQueries":{"count":3,"seconds":0.2}}'])
    summary = {"result": "Passed", "totalTestCount": 2, "passedTests": 2, "failedTests": 0, "skippedTests": 0}
    report = {}
    diagnostic = Path("/audit/diagnostics/StandardOutputAndStandardError.txt")
    original_read, original_open, original_rglob = Path.read_text, Path.open, Path.rglob
    def run(arguments, **kwargs):
        response = summary if "summary" in arguments else {'targets': [{'name': 'BIT101-iOS.app', 'lineCoverage': 0,
            'coveredLines': 0, 'executableLines': 0}]} if 'xccov' in arguments else None
        return subprocess.CompletedProcess(arguments, 0, json.dumps(response) if response is not None else "", "")
    with patch('validation_evidence.test_case_inventory', return_value={}), \
            patch.object(sys, "argv", ["metrics", "/audit/result.xcresult", "/audit/test-metrics.txt", "ui", "1", "device", str(ROOT)]), \
            patch.object(subprocess, "run", side_effect=run), patch.object(subprocess, "check_output", return_value='{"devices":[{"platform":"iOS","deviceId":"device"}]}'), \
            patch.object(shutil, "rmtree"), patch.object(Path, "rglob", lambda path, pattern: [diagnostic]
                if path == diagnostic.parent else original_rglob(path, pattern)), \
            patch.object(Path, "read_text", lambda path, *args, **kwargs: output if path == diagnostic else original_read(path, *args, **kwargs)), \
            patch.object(Path, "open", lambda path, *args, **kwargs: StringIO() if path == Path("/audit/ui-tests.log") else original_open(path, *args, **kwargs)), \
            patch.object(Path, "write_text", lambda path, value, **kwargs: report.__setitem__(path, value)), \
            patch('validation_evidence.native_source_coverage', return_value={'ScoreFeature': (30, 100), 'BIT101-iOS.app': (60, 100)}), \
            patch.dict(os.environ, BIT101_VALIDATION_INPUT_IDENTITY="digest", BIT101_VALIDATION_RUN_ID="run"), redirect_stdout(StringIO()):
        record_native_metrics(sys.argv[1:])
    result = json.loads(next(line.split("：", 1)[1] for line in report[Path("/audit/test-metrics.txt")].splitlines() if line.startswith("控件库存：")))
    if result["processIdentifiers"] == ["10", "20"] and result["observed"] == 3 and result["visited"] == 2 \
            and result["pending"] == ["10:pending"] and {row["identifier"] for row in result["visitedControls"]} == {"first", "second"} \
            and all(row in report[Path('/audit/test-metrics.txt')] for row in ('- iOS/ScoreFeature: 30.00% (30/100 lines)', '- BIT101-iOS.app: 60.00% (60/100 lines)',
                'App 内界面查询：23 次；累计 0.7 秒', '共享原生快照读取：2 次；累计 1.5 秒')):
        return []
    return ["UI 指标自测：冷启动前后的实际库存与待访问项共同保留"]
