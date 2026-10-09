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

def script_command_boundary_findings() -> list[str]:
    "通过内存替身验证自动选机、操作分派、筛选合并及参数拒绝。"
    import shlex
    import plistlib

    findings = []
    support = SCRIPT_ROOT / "script-support.sh"
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
  if [[ "$*" == *lockState* ]]; then print '{"result":{"isLocked":false}}';
  else print -ru2 -- "TOOL $*"; fi
}
'''
    export_source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
    scope_source = (SCRIPT_ROOT / "release-network-smoke.sh").read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame).split('RUN_ID="', 1)[0]
    for arguments, term, expected in ((['all'], '', 'network full'), (['all'], 'historical', 'network selected'),
            (['school', 'sms'], '', 'school-sms full'), (['school', 'sms'], 'historical', 'school-sms selected')):
        result = subprocess.run(['zsh', '-c', scope_source + '\nprint -r -- "$validation_group $validation_scope"',
            str(SCRIPT_ROOT / 'release-network-smoke.sh'), *arguments], capture_output=True, text=True,
            env=dict(os.environ, BIT101_NETWORK_SMOKE_TERM=term))
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
            (["xcrun", "devicectl", "device", "info", "processes", "--help"], ["--json-output"])):
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
        ("run-extended-tests.sh", [], 86, "-only-testing:BIT101-iOSTests", "DEVICE"),
        ("run-extended-tests.sh", ["NetworkClientTests"], 86, "BIT101-iOSTests/NetworkClientTests", "DEVICE"),
        ("run-extended-tests.sh", ["cache"], 0, "CACHE", ""),
        ("release-network-smoke.sh", ["ddl"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("release-network-smoke.sh", ["all", "sms"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("release-network-smoke.sh", ["school", "sms"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("run_icloud_cross_device_smoke.sh", [], 86, "ICLOUD_CROSS_DEVICE_SMOKE", "DEVICE"), ("run_icloud_cross_device_smoke.sh", ["report"], 0, "REPORT", ""),
    )
    environment = dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1", BIT101_DEFER_APP_RESTORE="1")
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
