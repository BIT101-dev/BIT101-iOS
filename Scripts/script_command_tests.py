"""Workflow dispatch tests use tool and filesystem substitutes."""
import os
import json
import re
import shutil
import subprocess
import sys
from contextlib import redirect_stdout
from io import StringIO
from unittest.mock import Mock, patch
from ui_rule_tests import device_discovery_boundary_findings
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = ROOT / "Scripts"

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
    manifest = f'''import fcntl, os, runpy, sys
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
    with quality.static_audit_lock(): manifest()
    assert dict(os.environ) == before
else: manifest()
print('entered', flush=True)
'''
    command = shlex.quote(sys.executable) + ' -B -c ' + shlex.quote(manifest)
    try:
        shutil.rmtree(fixture, ignore_errors=True)
        fixture.mkdir(parents=True)
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
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        findings.append(f'审计锁顺序自测：{error}')
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
        shutil.rmtree(fixture, ignore_errors=True)
    return findings

def script_command_boundary_findings() -> list[str]:
    "通过内存替身验证自动选机、操作分派、筛选合并及参数拒绝。"
    import shlex
    import plistlib

    findings = result_retention_boundary_findings()
    support = (SCRIPT_ROOT / 'script-support.sh').read_text()
    logger = 'bit101_log_command() {' + support.split('bit101_log_command() {', 1)[1].split('\nbit101_build_cache() {', 1)[0]
    command = logger + '\nbit101_log_command /dev/null stdin-contract ' + shlex.quote(sys.executable) + ' - delegated-argument\n'
    for status in (0, 7):
        payload = f'import sys\nassert sys.argv[1] == "delegated-argument"\nprint("warning: delegated-stdin-executed")\nraise SystemExit({status})\n'
        result = subprocess.run(['zsh', '-c', command], input=payload, capture_output=True, text=True)
        if result.returncode != status or 'delegated-stdin-executed' not in result.stdout:
            findings.append('日志委托自测：子命令继承调用方输入、参数和退出状态')
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
    restoration = 'restore_application() {' + simulator_source.split('restore_application() {', 1)[1].split(
        'if [[ "$operation" == restore ]]', 1)[0]
    for original, restore_result in ((0, 0), (7, 0), (0, 9), (7, 9)):
        stub = f'bit101_run_logged() {{ print RESTORE; return {restore_result}; }}\n'
        result = subprocess.run(['zsh', '-c', stub + restoration + '\ntrap restore_on_exit EXIT\nexit "$1"',
            'simulator-restore-test', str(original)], capture_output=True, text=True)
        if result.returncode != (original or restore_result) or result.stdout.count('RESTORE') != (1 if restore_result else 2):
            findings.append('模拟器恢复自测：退出时恢复常规包并保留测试失败状态')
    support = SCRIPT_ROOT / "script-support.sh"
    icloud_source = (SCRIPT_ROOT / 'run_icloud_cross_device_smoke.sh').read_text()
    recovery = 'finish_smoke() {' + icloud_source.split('finish_smoke() {', 1)[1].split('\ntrap finish_smoke', 1)[0]
    for original, phone_status, mac_status in ((0, 0, 0), (7, 0, 0), (0, 9, 0), (0, 0, 9), (7, 9, 9)):
        stub = f'''ROOT_DIR=/fixture SUMMARY_PATH=/fixture/report CLEANUP_ONLY=false validation_group=icloud
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
bit101_acquire_workflow_lock() { print WORKFLOW_LOCK; print DEVICE_LOCK; }
bit101_acquire_artifact_lock() { print WORKFLOW_LOCK; print ARTIFACT_LOCK; }
bit101_acquire_script_lock() { :; }
mkdir() { :; }
rm() { :; }
ditto() { :; }
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
    for capture in ('rawCourseResponse', 'scheduleCache'):
        for scope in ('all', 'school', 'schedule', 'bit101', 'ddl', 'transcript', 'community-writes', 'community-cleanup'):
            result = subprocess.run(['zsh', '-c', scope_source, str(SCRIPT_ROOT / 'release-network-smoke.sh'), scope],
                env=dict(os.environ, BIT101_NETWORK_SMOKE_CAPTURE=capture, BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture)), capture_output=True, text=True)
            if (result.returncode == 0) != (scope in ('all', 'school', 'schedule')):
                findings.append('网络采样自测：课表采样与执行范围匹配')
    for value, valid in ((valid_fixture, True), ({}, False), (dict(valid_fixture, posterID=True), False),
            (dict(valid_fixture, courseID=0), False), (dict(valid_fixture, courseNumber=' COURSE'), False)):
        result = subprocess.run(['zsh', '-c', scope_source, str(SCRIPT_ROOT / 'release-network-smoke.sh'), 'bit101'],
            env=dict(os.environ, BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(value)), capture_output=True, text=True)
        if (result.returncode == 0) != valid:
            findings.append('网络维护对象自测：校验对象标识及课程编号')
    for arguments, term, expected in ((['all'], '', 'network full'), (['all'], 'historical', 'network selected'),
            (['school', 'sms'], '', 'school-sms full'), (['school', 'sms'], 'historical', 'school-sms selected')):
        result = subprocess.run(['zsh', '-c', scope_source + '\nprint -r -- "$validation_group $validation_scope"',
            str(SCRIPT_ROOT / 'release-network-smoke.sh'), *arguments], capture_output=True, text=True,
            env=dict(os.environ, BIT101_NETWORK_SMOKE_TERM=term, BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture)))
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
        ("run-extended-tests.sh", ["ui", "About", "About"], 86, "LoginAndScheduleUITests/testAboutLicenseUpdateAndResetConfirmation", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "Schedule"], 86, "testScheduleWeekButtonsAndSectionSwipes", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "DDLEditor"], 86, "InteractionCoverageUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing", "DEVICE"),
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
    environment = dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1", BIT101_DEFER_APP_RESTORE="1", BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture))
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
    for filename, arguments, expected, marker, device in cases:
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"',
                                         f"source {shlex.quote(str(support))}\n" + frame)
        stop = "exit 86" if expected == 86 else "return 0"
        source = source.replace(frame, frame + f'\nbit101_run_logged() {{ print -r -- "BUILD $*"; {stop}; }}\n' + '\npython3() { if [[ "$*" == *"validation_restore.py"* ]]; then print -ru2 RESTORE_PROBE; return 0; fi; if [[ "$*" == *"/signing.entitlements"* || "$*" == *"/icloud-cross-device-smoke/report.json"* ]]; then return 0; fi; if [[ "$*" == *"validation_evidence.py digest"* ]]; then case "$3" in all|release-runtime|ui|schedule|infrastructure|login|extensions|network|ddl|school-sms|community-writes|community-cleanup|icloud|icloud-cleanup|restore) [[ "${BIT101_XCODE_DEVICE_ID:-}" == udid ]] || return 78 ;; esac; print self-test-inputs; return 0; fi; command python3 "$@"; }\n')
        source = re.sub(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$",
                        'ui_test_plan() { print -r -- /audit/ui.xctestrun; }', source, count=1)
        source = re.sub(r"(?ms)^report_result\(\) \{\n.*?^\}$", 'report_result() { print REPORT; }', source, count=1)
        result = subprocess.run(["zsh", "-c", source, str(path), *arguments], env=environment,
                                capture_output=True, text=True)
        if result.returncode != expected or marker not in result.stdout or ("DEVICE\n" in result.stdout) != bool(device):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 分派及自动选机；{result.stderr}")
        if filename == "build-install-device.sh" and not arguments and ("RESTORE_PROBE" not in result.stderr or "device info processes" not in result.stderr):
            findings.append("装机恢复自测：就绪信号与当前进程共同参与验收")
        if filename == "run-extended-tests.sh" and (not arguments or arguments[0] in {
                "catalyst", "catalyst-release-runtime", "release-runtime", "modules", "build"}):
            group = arguments[0] if arguments else "all"
            if group == "build":
                group = "build-" + (arguments[1] if len(arguments) > 1 else "release")
            if f"/extended-automation/{group}.log" not in result.stdout:
                findings.append(f"命令自测：{group} 保存独立验证组日志")
        needs_lock = arguments not in (["info"], ["cache"])
        if ("WORKFLOW_LOCK\n" in result.stdout) != needs_lock:
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 取得工作流锁")
        if filename in {'run-extended-tests.sh', 'build-install-device.sh'} and needs_lock \
                and ("DEVICE_LOCK\n" in result.stdout) != bool(device):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 按设备操作选择锁范围")
        if filename == "run-extended-tests.sh" and arguments[:2] == ["ui", "About"] and result.stdout.count(marker) != 1:
            findings.append("命令自测：重复 UI 关键词合并为一个用例")
        if arguments == ["ui", "Schedule"] and "testAboutLicense" in result.stdout:
            findings.append("命令自测：方法关键词按实际流程筛选")
        if arguments == ["ui", "test"] and result.stdout.count("-only-testing:BIT101-iOSUITests/") != ui_test_count:
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
    with patch.object(sys, "argv", ["metrics", "/audit/result.xcresult", "/audit/test-metrics.txt", "ui", "1", "device", str(ROOT)]), \
            patch.object(subprocess, "run", side_effect=run), patch.object(subprocess, "check_output", return_value='[]'), \
            patch.object(shutil, "rmtree"), patch.object(Path, "rglob", lambda path, pattern: [diagnostic]
                if path == diagnostic.parent else original_rglob(path, pattern)), \
            patch.object(Path, "read_text", lambda path, *args, **kwargs: output if path == diagnostic else original_read(path, *args, **kwargs)), \
            patch.object(Path, "open", lambda path, *args, **kwargs: StringIO() if path == Path("/audit/ui-tests.log") else original_open(path, *args, **kwargs)), \
            patch.object(Path, "write_text", lambda path, value, **kwargs: report.__setitem__(path, value)), \
            patch('validation_evidence.ios_module_coverage', return_value={'ScoreFeature': (30, 100)}), \
            patch.dict(os.environ, BIT101_VALIDATION_SOURCE_DIGEST="digest", BIT101_VALIDATION_RUN_ID="run"), redirect_stdout(StringIO()):
        exec(compile(source, "ui-metrics-self-test", "exec"), {})
    result = json.loads(next(line.split("：", 1)[1] for line in report[Path("/audit/test-metrics.txt")].splitlines() if line.startswith("控件库存：")))
    if result["processIdentifiers"] == ["10", "20"] and result["observed"] == 3 and result["visited"] == 2 \
            and result["pending"] == ["10:pending"] and {row["identifier"] for row in result["visitedControls"]} == {"first", "second"} \
            and '- iOS/ScoreFeature: 30.00% (30/100 lines)' in report[Path('/audit/test-metrics.txt')]:
        return []
    return ["UI 指标自测：冷启动前后的实际库存与待访问项共同保留"]
