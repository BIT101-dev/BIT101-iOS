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
from unittest.mock import Mock, patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = ROOT / "Scripts"

def test_build_argument_findings(output: str) -> list[str]:
    findings = []
    for line in output.splitlines():
        if not line.startswith('ARGUMENTS '): continue
        arguments = shlex.split(line)[3:]
        if arguments[:1] == ['xcodebuild']:
            required = ('-enableCodeCoverage YES', 'ENABLE_CODE_COVERAGE=YES',
                        'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES',
                        '-configuration Release')
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
    step = 'verify_step() {' + source.split('verify_step() {', 1)[1].split('\n  for group in', 1)[0]
    findings = []
    for child_status, retain_status, begin_status in ((0, 0, 0), (7, 0, 0), (0, 9, 0), (0, 0, 5)):
        harness = f'''set -euo pipefail
ROOT_DIR=/fixture
completed_result_groups=()
child() {{ print -r -- "CHILD $*"; return {child_status}; }}
python3() {{
  print -r -- "PY $*"
  if [[ "$2" == begin-batch ]]; then return {begin_status}; fi
  if [[ "$2" == retain-batch ]]; then return {retain_status}; fi
  return 0
}}
'''
        result = subprocess.run(['zsh', '-c', harness + step + '\nverify_step all child all\nverify_step ui child ui'],
            text=True, capture_output=True)
        expected = begin_status or int(bool(child_status or retain_status))
        output = result.stdout
        if result.returncode != expected or 'begin-batch first' not in output:
            findings.append('结果保留自测：准备与执行失败沿聚合流程传播')
        if begin_status:
            if 'CHILD' in output: findings.append('结果保留自测：准备成功后执行测试')
        elif 'retain-batch all' not in output:
            findings.append('结果保留自测：测试成功与失败均保留实际结果')
        if expected == 0 and ('begin-batch append' not in output or 'retain-batch all ui' not in output):
            findings.append('结果保留自测：后续测试组合并本次全部结果')
    for current in (True, False):
        harness = f'''set -euo pipefail
ROOT_DIR=/fixture
completed_result_groups=()
checks=0
python3() {{ (( checks += 1 )); [[ $checks -gt 1 ]] || return {0 if current else 1}; }}
child() {{ print executed; }}
'''
        result = subprocess.run(['zsh', '-c', harness + step + '\nverify_step modules child\nprint checks=$checks'],
            text=True, capture_output=True)
        if result.returncode or ('executed\n' in result.stdout) == current or f'checks={1 if current else 2}' not in result.stdout:
            findings.append('模块聚合复验：当前完整证据复用，缺失与过期证据执行后验收')
    restore = 'restore_release_app() {' + source.split('restore_release_app() {', 1)[1].split('\n  trap restore_release_app', 1)[0]
    restore = restore.replace('"$ROOT_DIR/Scripts/build-install-device.sh"', 'restore_probe')
    finish = 'finish_validation() {' + source.split('finish_validation() {', 1)[1].split('\ntrap finish_validation', 1)[0]
    for hook in (finish, restore):
        for test_status, merge_status in ((0, 0), (7, 0), (0, 9), (7, 9)):
            harness = f'''ROOT_DIR=/fixture DERIVED_ROOT=/fixture validation_group=all validation_scope=selected
WORKFLOW_STARTED_SECONDS=$SECONDS DEVICE_TEST_EXECUTION_STARTED=true
retained_result_groups=(all ui)
restore_probe() {{ print RESTORE; }}
python3() {{ print -r -- "PY $*"; [[ "$2" != retain-selected ]] || return {merge_status}; }}
'''
            name = 'restore_release_app' if hook == restore else 'finish_validation'
            result = subprocess.run(['zsh', '-c', harness + hook + f'\ntrap {name} EXIT\nexit {test_status}'],
                capture_output=True, text=True)
            if result.returncode != (merge_status or test_status) or 'retain-selected all all ui' not in result.stdout:
                findings.append('定向结果保留自测：退出与 App 恢复钩子合并有效证据并传播失败')
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
    program = (SCRIPT_ROOT / 'script-support.sh').read_text().split("<<'PYMACINSTALL'\n", 1)[1].split('\nPYMACINSTALL', 1)[0]
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
    shell = (SCRIPT_ROOT / 'run-static-audit.sh').read_text().split('LOG_DIR=', 1)[0]
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
        worker.write_text('if [[ "$1" == direct ]]; then exec ' + command + ' direct; fi\n' + shell + '\n' + command + ' shell\n')
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
    launcher = 'start_group() {' + source.split('start_group() {', 1)[1].split('\nfailed_groups=()', 1)[0]
    runner = ('run_group() {' + source.split('run_group() {', 1)[1].split('\nshow_group_log()', 1)[0]).replace('> "$log" 2>&1', '')
    harness = '''ROOT_DIR=/fixture LOG_DIR=/fixture SWIFT_FRONTEND=frontend AUDIT_STARTED=$SECONDS group_processes=()
python3() { if [[ "$1" == /fixture/Scripts/validation_evidence.py ]]; then return 0; fi; command python3 "$@"; }
blocked_task() { python3 -c 'import os, time; print(os.getpid(), os.getpgrp(), flush=True); time.sleep(60)'; }
'''
    findings = []
    for signum, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
        process = subprocess.Popen(['zsh', '-c', harness + cleanup + runner + launcher + '\nstart_group sample blocked_task\nwait "$group_processes[1]"'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        worker_group = None
        try:
            if not select.select([process.stdout], [], [], 5)[0]: raise ValueError('后台检查启动需要及时响应')
            worker, worker_group = map(int, process.stdout.readline().split())
            os.kill(process.pid, signum)
            _, error = process.communicate(timeout=5)
            assert process.returncode == expected, error
            try: os.kill(worker, 0)
            except ProcessLookupError: pass
            else: raise ValueError('中断完成后后台检查需要结束')
        except (ValueError, AssertionError, subprocess.TimeoutExpired) as error:
            reason = '后台检查清理需要按测试预算完成' if isinstance(error, subprocess.TimeoutExpired) else str(error)
            findings.append(f'审计中断自测：{reason}')
        finally:
            if worker_group is not None:
                try: os.killpg(worker_group, signal.SIGKILL)
                except ProcessLookupError: pass
            if process.poll() is None: os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
    return findings


def script_command_boundary_findings() -> list[str]:
    from ci_wiring_rules import hook_documents_checked, active_script_markers
    from module_boundary_tests import build_cache_exit_self_test
    assert hook_documents_checked('exec python3 Scripts/check-docs.py --all --staged')
    for source in ('# exec python3 Scripts/check-docs.py --all --staged', 'echo "python3 Scripts/check-docs.py --all --staged"'):
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

    findings = result_retention_boundary_findings() + audit_cancellation_findings() + build_cache_exit_self_test()
    support = (SCRIPT_ROOT / 'script-support.sh').read_text()
    logger = 'bit101_log_command() {' + support.split('bit101_log_command() {', 1)[1].split('\nbit101_build_cache() {', 1)[0]
    log_program = logger.split("3<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
    from contextlib import redirect_stdout
    from io import StringIO
    from types import SimpleNamespace
    from unittest.mock import patch
    temporary_bundle = Path('/fixture/cache/ResultBundle_failure.xcresult')
    diagnostic_bundle = Path('/fixture/diagnostics/test-results.xcresult')
    for status in (0, 7):
        child = SimpleNamespace(stdout=iter([f'Writing error result bundle to {temporary_bundle}\n']), wait=lambda: status)
        with patch.object(sys, 'argv', ['logger', '/dev/null', 'fixture', 'xcodebuild']), \
                patch.dict(os.environ, BIT101_COMMAND_DIAGNOSTICS=str(diagnostic_bundle.parent)), \
                patch.object(subprocess, 'Popen', return_value=child), patch('tempfile.gettempdir', return_value='/fixture/cache'), \
                patch.object(Path, 'mkdir'), patch.object(Path, 'resolve', lambda path: path), patch.object(Path, 'is_dir', return_value=True), \
                patch('shutil.move') as moved, patch('shutil.rmtree') as removed, redirect_stdout(StringIO()):
            try: exec(compile(log_program, '<build-diagnostic>', 'exec'), {})
            except SystemExit as error: assert error.code == status
            assert moved.call_args.args == (str(temporary_bundle), str(diagnostic_bundle)) if status else not moved.called
            assert removed.call_args.args[0] == (diagnostic_bundle if status else temporary_bundle)
    diagnostics_program = (SCRIPT_ROOT / 'run-extended-tests.sh').read_text().split(
        'python3 - "$DERIVED_ROOT/test-results.xcresult"', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
    exported = diagnostic_bundle.parent / 'session.log'
    with patch.object(sys, 'argv', ['diagnostics', '/fixture/test-results.xcresult', '', 'diagnostics', str(SCRIPT_ROOT)]), \
            patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'exists', lambda path: path == diagnostic_bundle.parent), \
            patch.object(Path, 'is_dir', lambda path: path == diagnostic_bundle), \
            patch.object(Path, 'iterdir', return_value=[diagnostic_bundle, exported]), \
            patch.object(Path, 'unlink') as unlinked, patch.object(shutil, 'rmtree') as removed, \
            patch.object(subprocess, 'run') as export, redirect_stdout(StringIO()):
        try: exec(compile(diagnostics_program, '<diagnostic-export>', 'exec'), {})
        except SystemExit as error: assert error.code == 0
        arguments = export.call_args.args[0]
        assert arguments[arguments.index('--path') + 1] == str(diagnostic_bundle)
        assert arguments[arguments.index('--output-path') + 1] == str(diagnostic_bundle.parent)
        assert unlinked.call_count == 1 and not removed.called
    memory_report = '''from io import StringIO
class RetainedLog(StringIO):
    def close(self): pass
saved_log = RetainedLog()
def open_log(path, mode="r", **kwargs):
    if mode != "w": saved_log.seek(0)
    return saved_log
Path.open = open_log
'''
    ci_logger = logger.replace('report_path = Path(sys.argv[1])', memory_report + '\nreport_path = Path(sys.argv[1])')
    command = ci_logger + '\nbit101_log_command /dev/null stdin-contract ' + shlex.quote(sys.executable) + ' - delegated-argument\n'
    for status in (0, 7):
        payload = f'import sys\nassert sys.argv[1] == "delegated-argument"\nprint("warning: delegated-stdin-executed")\nraise SystemExit({status})\n'
        result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True)
        if result.returncode != status or 'delegated-stdin-executed' not in result.stdout:
            findings.append(f'日志委托自测：子命令继承调用方输入、参数和退出状态；预期 {status}，实际 {result.returncode}；{(result.stdout + result.stderr)[-500:]!r}')
    measured = logger.replace('raise SystemExit(exit_code if exit_code >= 0 else 128 - exit_code)',
        'import resource\nprint("LOGGER_RSS", resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)\nraise SystemExit(exit_code if exit_code >= 0 else 128 - exit_code)')
    peaks = []
    for lines in (1_000, 70_000):
        payload = f'for index in range({lines}): print("warning:", index, "x" * 256)\n'
        command = measured + '\nbit101_log_command /dev/null memory-contract ' + shlex.quote(sys.executable) + ' -\n'
        result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True)
        peak = re.search(r'LOGGER_RSS (\d+)', result.stdout)
        if result.returncode or not peak:
            findings.append('日志驻留内存自测：大量诊断仍沿成功状态完成')
            break
        peaks.append(int(peak[1]) * (1 if sys.platform == 'darwin' else 1024))
    if len(peaks) == 2 and peaks[1] - peaks[0] >= (70_000 - 1_000) * 256 // 2:
        findings.append('日志驻留内存自测：摘要占用需要随显示容量保持有限')
    command = ci_logger + '\nbit101_log_command /dev/null ci-contract ' + shlex.quote(sys.executable) + ' -\n'
    payload = 'for index in range(100): print("error: retained", index)\nraise SystemExit(7)\n'
    result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True,
        env={**os.environ, 'GITHUB_ACTIONS': 'true'})
    if result.returncode != 7 or 'error: retained 0\n' not in result.stdout or 'error: retained 99\n' not in result.stdout:
        findings.append('日志磁盘重读自测：CI 失败完整呈现摘要容量之外的诊断')
    isolated_digest = '''from pathlib import Path
from unittest.mock import patch
import sys
original_read = Path.read_text
def read(path, *args, **kwargs):
    if path.name == 'PerformanceWorkloads.json': raise ValueError('invalid workload fixture')
    return original_read(path, *args, **kwargs)
with patch.object(Path, 'read_text', read):
    import validation_evidence
    with patch.object(validation_evidence, 'source_digest', return_value='fixture'), patch.object(sys, 'argv', ['validation_evidence.py', 'digest']):
        raise SystemExit(validation_evidence.main())
'''
    result = subprocess.run([sys.executable, '-B', '-c', isolated_digest], cwd=SCRIPT_ROOT, capture_output=True, text=True)
    if result.returncode or result.stdout.strip() != 'fixture':
        findings.append('基础证据摘要自测：人工性能配置按所属操作加载')
    audit_source = (SCRIPT_ROOT / 'run-static-audit.sh').read_text()
    audit_exit = 'finish_audit() {' + audit_source.split('finish_audit() {', 1)[1].split('\nSWIFT_FRONTEND=', 1)[0]
    for action, expected, recording in (('exit 0', 0, 0), ('exit 7', 7, 0), ('kill -s INT $$', 130, 0),
                                       ('kill -s TERM $$', 143, 0), ('exit 0', 9, 9), ('exit 7', 7, 9)):
        harness = f'''ROOT_DIR=/fixture AUDIT_STARTED=$SECONDS group_processes=()
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
    from validation_restore import simulator_restore_findings, verification_finish_findings
    findings.extend(simulator_restore_findings(simulator_source))
    findings.extend(verification_finish_findings((SCRIPT_ROOT / 'run-extended-tests.sh').read_text()))
    support = SCRIPT_ROOT / "script-support.sh"
    icloud_source = (SCRIPT_ROOT / 'run_icloud_cross_device_smoke.sh').read_text()
    recovery = 'finish_smoke() {' + icloud_source.split('finish_smoke() {', 1)[1].split('\ntrap finish_smoke', 1)[0]
    for original, phone_status, mac_status in ((0, 0, 0), (7, 0, 0), (0, 9, 0), (0, 0, 9), (7, 9, 9)):
        stub = f'''ROOT_DIR=/fixture SUMMARY_PATH=/fixture/report CLEANUP_ONLY=false validation_group=icloud PHONE_AVAILABLE=true
PHONE_TEST_PID= PHONE_TESTS_STARTED=true PHONE_CLEANED_UP=false MAC_TESTS_STARTED=true MAC_CLEANED_UP=false
run_phone_test() {{ print PHONE; return {phone_status}; }}
run_mac_cleanup() {{ print MAC; return {mac_status}; }}
python3() {{ :; }}
report_result() {{ :; }}
'''
        result = subprocess.run(['zsh', '-c', stub + recovery + '\ntrap finish_smoke EXIT\nexit "$1"',
            'icloud-recovery-test', str(original)], env=dict(os.environ, BIT101_DEFER_APP_RESTORE='1'), capture_output=True, text=True)
        if result.returncode != (original or int(bool(phone_status or mac_status))) \
                or result.stdout.splitlines().count('PHONE') != 1 or result.stdout.splitlines().count('MAC') != 1:
            findings.append('iCloud 恢复自测：双端清理独立执行并保留原始失败状态')
    availability = icloud_source.split('PHONE_AVAILABLE=true\n', 1)[1].split('BIT101_VALIDATION_RUN_ID=', 1)[0]
    cleanup_entry = 'cleanup_status=0\n' + icloud_source.split('cleanup_status=0\n', 1)[1].split(
        'echo "[构建] 准备 Mac Catalyst 测试宿主"', 1)[0]
    cleanup_recovery = recovery.replace('"$ROOT_DIR/Scripts/build-install-device.sh"', 'restore_normal_app')
    for phone, mac, build, test, expected in ((0, 0, 0, 0, 0), (1, 0, 0, 0, 1), (1, 9, 0, 0, 1),
            (0, 9, 0, 0, 1), (0, 0, 9, 0, 9), (0, 0, 0, 9, 1)):
        stub = f'''set -euo pipefail
ROOT_DIR=/fixture DERIVED_ROOT=/fixture SUMMARY_PATH=/fixture/report RESULT_BUNDLE=/fixture/result
CLEANUP_ONLY=true validation_group=icloud PHONE_AVAILABLE=true CLEANUP_DEVICE_ID=phone-a DEVICE_ID=phone-a
PHONE_TEST_PID= PHONE_TESTS_STARTED=false PHONE_CLEANED_UP=false MAC_TESTS_STARTED=false MAC_CLEANED_UP=false
common_args=() TEST_CLASS=Fixture
bit101_require_device() {{ [[ "$1" == phone-a ]] || exit 81; return {phone}; }}
bit101_run_logged() {{ print BUILD; return {build}; }}
run_phone_test() {{ print PHONE; return {test}; }}
run_mac_cleanup() {{ print MAC; return {mac}; }}
restore_normal_app() {{ print RESTORE; }}
python3() {{ :; }}
report_result() {{ :; }}
'''
        result = subprocess.run(['zsh', '-c', stub + availability + cleanup_recovery +
            '\ntrap finish_smoke EXIT ZERR\n' + cleanup_entry],
            env=dict(os.environ, BIT101_DEFER_APP_RESTORE='0'), capture_output=True, text=True)
        rows = result.stdout.splitlines()
        if result.returncode != expected or 'MAC' not in rows \
                or phone and any(marker in rows for marker in ('BUILD', 'PHONE', 'RESTORE')) \
                or not phone and ('BUILD' not in rows or rows.index('MAC') > rows.index('BUILD')) \
                or not phone and not build and 'PHONE' not in rows:
            findings.append('iCloud 恢复自测：手机离线及构建失败仍推进 Mac 清理，两端失败保留待恢复状态')
    pending = icloud_source.split('pending_cleanup="$(python3 - "$SUMMARY_PATH" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
    passed = dict(exitCode=0, totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
    prior_stages = [dict(passed, stage=stage) for stage in ('testPhoneRoundTrip', 'testMacReceiveAndRestore')]
    for overrides, expected in (({}, ''), ({'macCleanup': dict(passed, exitCode=1)}, 'cleanup'),
            ({'cleanup': dict(passed, exitCode=1)}, 'cleanup'), ({'stages': prior_stages[:1]}, 'cleanup')):
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
    report_program = (SCRIPT_ROOT / 'run-extended-tests.sh').read_text().split(
        ' <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
    for has_info, staging in ((True, False), (True, True), (False, False)):
        output = StringIO()
        with patch.object(sys, 'argv', ['report', '/fixture/results.xcresult', 'json', 'report', str(SCRIPT_ROOT)]), \
                patch.object(Path, 'is_file', lambda path: has_info and path.name == 'Info.plist'), \
                patch.object(Path, 'exists', lambda path: staging and path.name == 'Staging'), \
                patch.object(subprocess, 'check_output', return_value='{}'), redirect_stdout(output):
            try:
                exec(compile(report_program, '<result-report>', 'exec'), {})
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
    valid_fixture = dict(posterID=1, courseID=2, courseNumber='COURSE', paperID=3)
    export_source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
    scope_source = (SCRIPT_ROOT / "release-network-smoke.sh").read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame).split('RUN_ID="', 1)[0]
    for scope in ('all', 'bit101', 'community-writes'):
        result = subprocess.run(['zsh', '-c', scope_source, str(SCRIPT_ROOT / 'release-network-smoke.sh'), scope],
            env=dict(os.environ, BIT101_NETWORK_SMOKE_FIXTURES=''), capture_output=True, text=True)
        assert result.returncode == 64 and 'WORKFLOW_LOCK' not in result.stdout, '维护对象配置需要在构建与选机前验收'
    for scope, configuration in (('all', {}), ('all', {'BIT101_NETWORK_SMOKE_FIXTURES': json.dumps(valid_fixture)}), ('all', {'BIT101_NETWORK_SMOKE_FIXTURES': json.dumps(valid_fixture), 'BIT101_COMMUNITY_SMOKE_ACCOUNT': ''}),
            ('community-writes', {'BIT101_NETWORK_SMOKE_FIXTURES': json.dumps(valid_fixture)}),
            ('community-writes', {'BIT101_NETWORK_SMOKE_FIXTURES': json.dumps(valid_fixture),
                'BIT101_COMMUNITY_SMOKE_ACCOUNT': '1', 'BIT101_COMMUNITY_FOLLOW_TARGET': '2'})):
        environment = dict(os.environ, BIT101_NETWORK_SMOKE_FIXTURES='', BIT101_NETWORK_SMOKE_CAPTURE='none',
            BIT101_COMMUNITY_SMOKE_ACCOUNT='1', BIT101_COMMUNITY_FOLLOW_TARGET='', BIT101_COMMUNITY_RECOVERY_CONFIRMATION='')
        environment.update(configuration)
        result = subprocess.run(['zsh', '-c', scope_source, str(SCRIPT_ROOT / 'release-network-smoke.sh'), '--check-config', scope],
            env=environment, capture_output=True, text=True)
        expected = bool(configuration) and (scope == 'all' and bool(environment['BIT101_COMMUNITY_SMOKE_ACCOUNT']) or scope != 'all' and 'BIT101_COMMUNITY_SMOKE_ACCOUNT' in configuration)
        assert (result.returncode == 0) == expected and not result.stdout, '配置预检沿叶子流程验收，设备与产物保持独立'
    preflight = re.search(r'(?ms)^  for group in .*?^  acquire_test_lock$', export_source)[0]
    assert '--check-config' in preflight and 'verify_step' not in preflight
    block = re.search(r'(?ms)^  verification_network_args=.*?(?=^  acquire_test_lock$)', export_source)[0]
    for arguments in (['verify', 'modules', 'network'], ['verify', 'all', 'community-writes']):
        harness = 'set -euo pipefail\nROOT_DIR=' + shlex.quote(str(SCRIPT_ROOT.parent)) + '\nshift\n' + block + '\nprint READY'
        result = subprocess.run(['zsh', '-c', harness, 'configuration-order', *arguments], capture_output=True, text=True,
            env=dict(os.environ, BIT101_NETWORK_SMOKE_FIXTURES='', BIT101_NETWORK_SMOKE_CAPTURE='none',
                BIT101_COMMUNITY_RECOVERY_CONFIRMATION=''))
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
    export_source = export_source[:export_source.index('if [[ "${1:-}" == -h')]
    export_source = export_source.replace('  python3 - "$DERIVED_ROOT/test-results.xcresult"', '  exit 86\n  python3 - "$DERIVED_ROOT/test-results.xcresult"')
    for arguments in (["report", "json"], ["diagnostics"], ["activities", "test"], ["screenshot", "test"]):
        result = subprocess.run(["zsh", "-c", export_source, str(SCRIPT_ROOT / "run-extended-tests.sh"), *arguments],
                                env=dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1"), capture_output=True, text=True)
        if result.returncode != 86 or result.stdout.count("WORKFLOW_LOCK") != 1:
            findings.append(f"固定产物导出自测：{arguments[0]} 取得工作流锁")
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
        ("run-extended-tests.sh", ["catalyst"], 86, "all-tests", ""),
        ("run-extended-tests.sh", ["catalyst-release-runtime"], 86, "ReleaseRuntimeContractTests", ""),
        ("run-extended-tests.sh", ["release-runtime"], 86, "ReleaseRuntimeContractTests", "DEVICE"),
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
    environment = dict(os.environ, BIT101_WORKFLOW_CONDITIONS='DEBUG RELEASE_NETWORK_SMOKE', BIT101_EXTENDED_TESTS_LOCK_HELD="1", BIT101_DEFER_APP_RESTORE="1", BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture), BIT101_COMMUNITY_SMOKE_ACCOUNT='1')
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
  elif [[ "$*" == *"validation_provenance.py worker-snapshot"* ]]; then return 79;
  elif [[ "$*" == *"validation_evidence.py record"* ]]; then print -r -- "RECORD $3 $4 $5";
  else return 0; fi
}
restore_probe() { print RESTORE; }
bit101_run_logged() { print BUILD; return 79; }
'''
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', failure).replace(
            '"$ROOT_DIR/Scripts/build-install-device.sh"', 'restore_probe')
        result = subprocess.run(['zsh', '-c', source, str(path), *arguments],
            env=dict(environment, BIT101_DEFER_APP_RESTORE='0'), capture_output=True, text=True)
        records = [line for line in result.stdout.splitlines() if line.startswith('RECORD ')]
        if result.returncode != 79 or records != [f'RECORD {group} 79 full' for group in groups] \
                or 'BUILD\n' not in result.stdout or 'RESTORE\n' in result.stdout:
            findings.append('网络部署身份缺口自测：构建失败保留设备现有 App 并登记采样结果')
    for filename, arguments, expected, marker, device in cases:
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"',
                                         f"source {shlex.quote(str(support))}\n" + frame)
        stop = "exit 86" if expected == 86 else "return 0"
        source = source.replace(frame, frame + f'\nbit101_run_logged() {{ print -r -- "BUILD $*"; print -r -- "ARGUMENTS ${{(qqq)@}}"; {stop}; }}\n' + '\npython3() { if [[ "$*" == *"validation_performance.py"* ]]; then return 0; fi; if [[ "$*" == *"validation_provenance.py worker-snapshot"* ]]; then print "{}"; return 0; fi; if [[ "$*" == *"validation_restore.py"* ]]; then print -ru2 RESTORE_PROBE; return 0; fi; if [[ "$*" == *"/signing.entitlements"* || "$*" == *"/icloud-cross-device-smoke/report.json"* ]]; then return 0; fi; if [[ "$*" == *"validation_evidence.py digest"* ]]; then case "$3" in all|release-runtime|ui|schedule|infrastructure|login|extensions|network|ddl|school-sms|community-writes|community-cleanup|icloud|icloud-cleanup|restore) [[ "${BIT101_XCODE_DEVICE_ID:-}" == udid ]] || return 78 ;; esac; print self-test-inputs; return 0; fi; command python3 "$@"; }\n')
        source = re.sub(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$",
                        'ui_test_plan() { print -r -- /audit/ui.xctestrun; }', source, count=1)
        source = re.sub(r"(?ms)^report_result\(\) \{\n.*?^\}$", 'report_result() { print REPORT; }', source, count=1)
        result = subprocess.run(["zsh", "-c", source, str(path), *arguments], env=environment,
                                capture_output=True, text=True)
        command_output = '\n'.join(line for line in result.stdout.splitlines() if line.startswith('BUILD '))
        if result.returncode != expected or marker not in result.stdout or ("DEVICE\n" in result.stdout) != bool(device) or filename == 'build-install-device.sh' and command_output and any(not re.search(r'\b' + name + r'=(?:\s|$)', command_output) for name in ('BIT101_WORKFLOW_CONDITIONS', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS')):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 分派及自动选机；{result.stderr}")
        if filename == 'run-extended-tests.sh':
            findings.extend(test_build_argument_findings(result.stdout))
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
    plan_function = re.search(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$", (SCRIPT_ROOT / "run-extended-tests.sh").read_text())
    plan_source = re.search(r"<<'PY'\n(.*?)^PY$", plan_function[0], re.MULTILINE | re.DOTALL)[1]
    older, newer = Mock(), Mock()
    older.stat.return_value.st_mtime = 1
    newer.stat.return_value.st_mtime = 2
    selected = StringIO()
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), \
         patch.object(Path, "glob", return_value=[older, newer]), redirect_stdout(selected):
        exec(compile(plan_source, "ui-plan-self-test", "exec"), {})
    if older.open.called or newer.open.called or selected.getvalue().strip() != str(newer):
        findings.append("UI 计划自测：最新构建选择及默认诊断配置保留")
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), patch.object(Path, "glob", return_value=[]):
        try:
            exec(compile(plan_source, "ui-plan-empty-self-test", "exec"), {})
        except SystemExit as error:
            if ".xctestrun" not in str(error):
                findings.append("UI 计划自测：冷缓存缺少运行配置时的诊断")
        else:
            findings.append("UI 计划自测：运行配置完整性检查")

    findings.extend(device_discovery_boundary_findings())
    findings.extend(ui_metrics_boundary_findings())
    return findings


def ui_metrics_boundary_findings() -> list[str]:
    source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text().split("record_metrics() {", 1)[1]
    source = re.search(r"<<'PY'\n(.*?)^PY$", source, re.MULTILINE | re.DOTALL)[1]
    def inventory(process, key, pending=()):
        return {"processIdentifier": process, "scope": "mounted-controls",
            "identityScope": "testCaseNavigationPresentationAndOccurrence",
            "observedControls": [key, *pending], "disabledControls": [], "checkedDisabledControls": [],
            "unidentifiedInstances": [], "visitedControls": [{"instance": key, "identifier": key,
                "scope": f"Journey{process}/testRun", "actions": ["tap"]}]}
    output = "\n".join(["UI automation App process: 10", "UI control inventory: " + json.dumps(inventory(10, "first", ["pending"])),
        "UI automation App process: 20", "UI control inventory: " + json.dumps(inventory(20, "second"))])
    summary = {"result": "Passed", "totalTestCount": 2, "passedTests": 2, "failedTests": 0, "skippedTests": 0}
    report = {}
    diagnostic = Path("/audit/diagnostics/StandardOutputAndStandardError.txt")
    original_read, original_open, original_rglob = Path.read_text, Path.open, Path.rglob
    def run(arguments, **kwargs):
        response = summary if "summary" in arguments else {'targets': [{'name': 'BIT101-iOS.app', 'lineCoverage': 0.5,
            'coveredLines': 50, 'executableLines': 100}]} if 'xccov' in arguments else None
        return subprocess.CompletedProcess(arguments, 0, json.dumps(response) if response is not None else "", "")
    with patch('validation_evidence.test_case_inventory', return_value={}), \
            patch.object(sys, "argv", ["metrics", "/audit/result.xcresult", "/audit/test-metrics.txt", "ui", "1", "device", str(ROOT)]), \
            patch.object(subprocess, "run", side_effect=run), patch.object(subprocess, "check_output", return_value='{"devices":[{"platform":"iOS","deviceId":"device"}]}'), \
            patch.object(shutil, "rmtree"), patch.object(Path, "rglob", lambda path, pattern: [diagnostic]
                if path == diagnostic.parent else original_rglob(path, pattern)), \
            patch.object(Path, "read_text", lambda path, *args, **kwargs: output if path == diagnostic else original_read(path, *args, **kwargs)), \
            patch.object(Path, "open", lambda path, *args, **kwargs: StringIO() if path == Path("/audit/ui-tests.log") else original_open(path, *args, **kwargs)), \
            patch.object(Path, "write_text", lambda path, value, **kwargs: report.__setitem__(path, value)), \
            patch('validation_evidence.native_source_coverage', return_value={'ScoreFeature': (30, 100)}), \
            patch.dict(os.environ, BIT101_VALIDATION_SOURCE_DIGEST="digest", BIT101_VALIDATION_RUN_ID="run"), redirect_stdout(StringIO()):
        exec(compile(source, "ui-metrics-self-test", "exec"), {})
    result = json.loads(next(line.split("：", 1)[1] for line in report[Path("/audit/test-metrics.txt")].splitlines() if line.startswith("控件库存：")))
    if result["processIdentifiers"] == ["10", "20"] and result["observed"] == 3 and result["visited"] == 2 \
            and result["pending"] == ["10:pending"] and {row["identifier"] for row in result["visitedControls"]} == {"first", "second"} \
            and '- iOS/ScoreFeature: 30.00% (30/100 lines)' in report[Path('/audit/test-metrics.txt')]:
        return []
    return ["UI 指标自测：冷启动前后的实际库存与待访问项共同保留"]


def device_discovery_boundary_findings() -> list[str]:
    import json
    import shlex
    support = ROOT / "Scripts/script-support.sh"
    findings = []
    def candidate(name, transport, tunnel="connected", pairing="paired", reality="physical"):
        return {"identifier": name, "hardwareProperties": {"udid": name, "deviceType": "iPhone", "reality": reality},
                "connectionProperties": {"transportType": transport, "tunnelState": tunnel, "pairingState": pairing},
                "deviceProperties": {"name": name}}

    for devices, expected in (
        ([candidate("wireless", "localNetwork"), candidate("wired", "wired")], "wired"),
        ([candidate("wireless", "localNetwork"), candidate("offline", None)], "wireless"),
        ([candidate("pending", "wired", "disconnected"), candidate("connected", "wired")], "connected"),
        ([candidate("unpaired", "wired", pairing="unpaired"), candidate("virtual", "wired", reality="virtual")], ""),
    ):
        snapshot = shlex.quote(json.dumps({"result": {"devices": devices}}))
        code = f'source {shlex.quote(str(support))}\nunset BIT101_XCODE_DEVICE_ID BIT101_DEVICETCL_DEVICE_ID BIT101_DEVICE_TRANSPORT BIT101_DEVICE_NAME\n'
        code += f'bit101_device_snapshot() {{ print -r -- {snapshot}; }}\nbit101_find_device || exit 1\nprint -r -- "$BIT101_DEVICE_NAME"\n'
        result = subprocess.run(["zsh", "-c", code], capture_output=True, text=True)
        if (expected and (result.returncode or result.stdout.strip() != expected)) or (not expected and result.returncode != 1):
            findings.append("设备自测：有线优先、无线发现、连接状态及真实配对设备范围")
    for requested, devices, cached, expected in (
        ('phone-a', [candidate('phone-b', 'wired'), candidate('phone-a', 'localNetwork')], 'phone-b', 'phone-a'),
        ('phone-a', [candidate('phone-b', 'wired')], 'phone-b', ''),
        ('phone-a', [candidate('phone-a', 'wired')], 'phone-a', 'phone-a'),
        ('', [], 'phone-b', 'phone-b'),
    ):
        snapshot = shlex.quote(json.dumps({'result': {'devices': devices}}))
        code = f'source {shlex.quote(str(support))}\n'
        code += f'BIT101_XCODE_DEVICE_ID={cached} BIT101_DEVICETCL_DEVICE_ID=cached-pair BIT101_DEVICE_TRANSPORT=wired BIT101_DEVICE_NAME={cached}\n'
        code += f'bit101_device_snapshot() {{ print -r -- {snapshot}; }}\nbit101_find_device {shlex.quote(requested)} || exit 1\n'
        code += 'print -r -- "$BIT101_XCODE_DEVICE_ID:$BIT101_DEVICETCL_DEVICE_ID"\n'
        result = subprocess.run(['zsh', '-c', code], capture_output=True, text=True)
        paired = expected if requested else 'cached-pair'
        if (expected and (result.returncode or result.stdout.strip() != f'{expected}:{paired}')) \
                or (not expected and result.returncode != 1):
            findings.append('设备自测：指定原执行设备时刷新身份配对，普通流程复用已选设备')
    return findings


def workflow_lock_boundary_findings() -> list[str]:
    "验证竞争工作流排队及父子流程锁复用。"
    import select
    import shlex
    import time
    fixture = ROOT / ".build/static-audit/workflow-lock-self-test"
    worker, release = fixture / "worker.sh", fixture / "release"
    processes, findings = [], []
    environment = dict(os.environ)
    optimization = subprocess.run(["zsh", "-c", 'source "$1"; python3 -c "assert False"',
        "assertion-contract", str(SCRIPT_ROOT / "script-support.sh")],
        env=dict(environment, PYTHONOPTIMIZE="1"), capture_output=True, text=True)
    if optimization.returncode == 0 or "AssertionError" not in optimization.stderr:
        findings.append("工作流环境自测：Python 自测断言沿默认优化级别执行")
    environment.pop("BIT101_EXTENDED_TESTS_LOCK_HELD", None)
    environment.pop("BIT101_DEVICE_WORKFLOW_LOCK_HELD", None)
    environment.pop("BIT101_WORKFLOW_DEADLINE", None)
    environment["BIT101_LOCK_TEST_CHECKOUT"] = str(fixture)
    try:
        shutil.rmtree(fixture, ignore_errors=True)
        fixture.mkdir(parents=True, exist_ok=True); os.mkfifo(release)
        support = (SCRIPT_ROOT / "script-support.sh").read_text().replace(
            '"$HOME/Library/Caches/BIT101-iOS/device-workflow.lock"', shlex.quote(str(fixture / "device-workflow.lock")))
        dispatch = (SCRIPT_ROOT / 'build-install-device.sh').read_text().split('if [[ "$ACTION" == install', 1)[1].split('\nif [[ "$ACTION" == install', 1)[0]
        test_lock = re.search(r'(?ms)^acquire_test_lock\(\) \{.*?^\}', (SCRIPT_ROOT / 'run-extended-tests.sh').read_text())[0]
        worker.write_text('ROOT_DIR="$BIT101_LOCK_TEST_CHECKOUT"\n' + support + '\n' + test_lock + '\n'
                         'case "${1:-}" in modules|catalyst|catalyst-release-runtime) MODE="$1"; BUILD_ONLY=false; GENERIC_BUILD=false; SCRIPT_PATH="$0"; SCRIPT_ARGS=("$@"); acquire_test_lock ;; *)\n'
                         'ACTION=install; case "${1:-}" in artifact) ACTION=build ;; mac) ACTION=mac ;; esac\n'
                         + 'if [[ "$ACTION" == install' + dispatch + '\n;; esac\nprint entered\n'
                         'if [[ "${1:-}" == signal || "${1:-}" == budget ]]; then\n'
                         '  trap \'print cleanup; if [[ "$1" == signal ]]; then read -r reply < "$ROOT_DIR/release"; fi; exit 143\' TERM\n'
                         'fi\n'
                         'case "${1:-}" in hold|signal|budget) read -r reply < "$ROOT_DIR/release" ;; esac\n')
        def line(process):
            return process.stdout.readline().strip() if select.select([process.stdout], [], [], 5)[0] else "timeout"
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered":
            raise ValueError("首个工作流取得锁")
        other_checkout = dict(environment, BIT101_LOCK_TEST_CHECKOUT=str(fixture / "other-checkout"))
        independent = subprocess.run(["zsh", str(worker), "artifact"], capture_output=True, text=True,
            env=other_checkout, timeout=5)
        if independent.returncode or independent.stdout.strip() != 'entered':
            raise ValueError('独立工作区的本机流程与真机流程并行')
        competing = subprocess.Popen(["zsh", str(worker), "artifact"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS='0.5'))
        processes.append(competing)
        output, _ = competing.communicate(timeout=5)
        if competing.returncode != 124 or 'entered' in output:
            raise ValueError('同一工作区的本机与真机流程共用固定产物锁')
        seconds = [subprocess.Popen(["zsh", str(worker), mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=other_checkout)
                   for mode in ('mac', 'modules', 'catalyst', 'catalyst-release-runtime')]
        processes.extend(seconds)
        if any(not line(second).startswith("[等待]") for second in seconds):
            raise ValueError("竞争工作流在执行前排队")
        with release.open("w") as stream:
            stream.write("done\n")
        first.communicate(timeout=5)
        for second in seconds:
            output, _ = second.communicate(timeout=5)
            if first.returncode or second.returncode or output.strip() != "entered": raise ValueError("锁释放后继续执行并复用父流程锁")
        first = subprocess.Popen(["zsh", str(worker), "signal"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered":
            raise ValueError("信号测试取得工作流锁")
        first.terminate()
        if line(first) != "cleanup":
            raise ValueError("外层信号传递到执行子进程")
        second = subprocess.Popen(["zsh", str(worker)], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=other_checkout)
        processes.append(second)
        if not line(second).startswith("[等待]"):
            raise ValueError("子进程清理期间保持工作流锁")
        with release.open("w") as stream:
            stream.write("done\n")
        first.communicate(timeout=5)
        output, _ = second.communicate(timeout=5)
        if first.returncode != 143 or second.returncode or output.strip() != "entered":
            raise ValueError("信号清理完成后释放锁并保持退出状态")
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered": raise ValueError("超时竞争测试取得锁")
        second = subprocess.Popen(["zsh", str(worker)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(other_checkout, BIT101_WORKFLOW_TIMEOUT_SECONDS="0.5"))
        processes.append(second)
        output, _ = second.communicate(timeout=5)
        if second.returncode != 124 or "[超时]" not in output or "entered" in output:
            raise ValueError("竞争工作流沿等待预算结束")
        with release.open("w") as stream: stream.write("done\n")
        first.communicate(timeout=5)
        timed = subprocess.Popen(["zsh", str(worker), "signal"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS="0.5"))
        processes.append(timed)
        if line(timed) != "entered": raise ValueError("执行超时测试取得锁")
        if not line(timed).startswith("[超时]") or line(timed) != "cleanup":
            raise ValueError("执行预算触发恢复清理")
        with release.open("w") as stream: stream.write("done\n")
        timed.communicate(timeout=5)
        recovered = subprocess.run(["zsh", str(worker)], capture_output=True, text=True, env=environment, timeout=5)
        if timed.returncode != 124 or recovered.returncode or recovered.stdout.strip() != "entered":
            raise ValueError("超时恢复完成后释放全局与工作区锁")
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment)
        processes.append(first)
        if line(first) != "entered": raise ValueError("共享预算测试取得锁")
        started = time.monotonic()
        second = subprocess.Popen(["zsh", str(worker), "budget"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS="1"))
        processes.append(second)
        if not line(second).startswith("[等待]"): raise ValueError("共享预算测试进入排队")
        time.sleep(0.4)
        with release.open("w") as stream: stream.write("done\n")
        first.communicate(timeout=5)
        output, _ = second.communicate(timeout=5)
        if second.returncode != 124 or "entered" not in output or "cleanup" not in output or time.monotonic() - started >= 1.3:
            raise ValueError("等待与执行沿同一截止时间消费预算")
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        findings.append(f"工作流锁自测：{error}")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
        shutil.rmtree(fixture, ignore_errors=True)
    return findings
