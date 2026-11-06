"""Workflow dispatch tests use tool and filesystem substitutes."""

import os
import json
import re
import shlex
import subprocess
import sys
from contextlib import redirect_stdout
from io import StringIO
from unittest.mock import Mock, patch
from pathlib import Path
from network_smoke_config_tests import network_configuration_boundary_findings

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = ROOT / "Scripts"


from command_lifecycle_tests import (
    test_build_argument_findings as test_build_argument_findings,
    check_build_argument_mutations as check_build_argument_mutations,
)


def check_result_bundle_readiness(findings):
    from test_results import report_test_results

    for has_info, staging in ((True, False), (True, True), (False, False)):
        output = StringIO()
        with (
            patch.object(
                sys,
                "argv",
                ["report", "/fixture/results.xcresult", "json", "report", str(SCRIPT_ROOT)],
            ),
            patch.object(Path, "is_file", lambda path: has_info and path.name == "Info.plist"),
            patch.object(Path, "exists", lambda path: staging and path.name == "Staging"),
            patch.object(subprocess, "check_output", return_value="{}"),
            redirect_stdout(output),
        ):
            try:
                report_test_results(sys.argv[1:])
            except SystemExit as error:
                if (error.code == 0) != (has_info and not staging):
                    findings.append("结果包读取自测：已完成的文件存储格式沿 xcresulttool 读取")


def command_shell_frame():
    frame = r"""
bit101_require_device() {
  print DEVICE
  export BIT101_XCODE_DEVICE_ID=udid BIT101_DEVICETCL_DEVICE_ID=core
  export BIT101_DEVICE_TRANSPORT=wired BIT101_DEVICE_NAME=phone
}
bit101_build_cache() { print CACHE; }
bit101_set_workflow_budget() { :; }
bit101_limit_ui_workflow() { :; }
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
"""
    from script_test_support import shell_function

    frame += shell_function(SCRIPT_ROOT / "script-support.sh", "bit101_catalyst_signing_arguments")
    return frame


def check_archive_installation(frame):
    archive = (
        (SCRIPT_ROOT / "build-install-device.sh")
        .read_text()
        .split('if [[ "$ACTION" == install-archive ]]; then', 1)[1]
    )
    archive = (
        "bit101_require_device || exit 1"
        + archive.split("bit101_require_device || exit 1", 1)[1].split("\nfi\n", 1)[0]
    )
    for clean in (False, True):
        program = frame + "\nAPP_PATH=/archive/App.app\nAPP_VERSION=1\nAPP_BUILD=1\n" + archive
        result = subprocess.run(
            [
                "zsh",
                "-c",
                program,
                "archive-install",
                "install-archive",
                "/archive",
                *(["--clean"] if clean else []),
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0 and "RESTORE_INVALIDATED" in result.stdout
        assert (
            "device install app" in result.stderr
            and ("device uninstall app" in result.stderr) == clean
        )


def check_network_command_configuration(findings, frame):
    valid_fixture = dict(posterID=1, courseID=2, courseNumber="COURSE", paperID=3)
    export_source = (
        (SCRIPT_ROOT / "run-extended-tests.sh")
        .read_text()
        .replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
    )
    scope_source = (
        (SCRIPT_ROOT / "release-network-smoke.sh")
        .read_text()
        .replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
        .split('RUN_ID="', 1)[0]
    )
    findings.extend(network_configuration_boundary_findings())
    preflight = re.search(r"(?ms)^  for group in .*?^  acquire_test_lock$", export_source)[0]
    assert "--check-config" in preflight and "verify_step" not in preflight
    block = re.search(
        r"(?ms)^  verification_network_args=.*?(?=^  acquire_test_lock$)", export_source
    )[0]
    for arguments in (["verify", "modules", "network"], ["verify", "all", "community-writes"]):
        harness = (
            "set -euo pipefail\nROOT_DIR="
            + shlex.quote(str(SCRIPT_ROOT.parent))
            + "\nshift\n"
            + block
            + "\nprint READY"
        )
        result = subprocess.run(
            ["zsh", "-c", harness, "configuration-order", *arguments],
            capture_output=True,
            text=True,
            env=dict(
                os.environ,
                BIT101_COMMUNITY_SMOKE_ACCOUNT="1",
                BIT101_NETWORK_SMOKE_FIXTURES="{}",
                BIT101_NETWORK_SMOKE_CAPTURE="none",
                BIT101_COMMUNITY_RECOVERY_CONFIRMATION="",
            ),
        )
        assert result.returncode == 64 and "READY" not in result.stdout, (
            "聚合配置失败在编译及设备恢复前返回"
        )
    for capture in ("rawCourseResponse", "scheduleCache"):
        for scope in (
            "all",
            "school",
            "schedule",
            "bit101",
            "ddl",
            "transcript",
            "community-writes",
            "community-cleanup",
        ):
            result = subprocess.run(
                ["zsh", "-c", scope_source, str(SCRIPT_ROOT / "release-network-smoke.sh"), scope],
                env=dict(
                    os.environ,
                    BIT101_NETWORK_SMOKE_CAPTURE=capture,
                    BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture),
                    BIT101_COMMUNITY_SMOKE_ACCOUNT="1",
                ),
                capture_output=True,
                text=True,
            )
            if (result.returncode == 0) != (scope in ("all", "school", "schedule")):
                findings.append("网络采样自测：课表采样与执行范围匹配")
    confirmation = dict(
        account=1,
        marker="功能验收 fixture",
        serverReceipt="backend-reconciliation",
        kinds=["poster"],
        parents=[],
    )
    for scope, value, valid in (
        ("community-cleanup", confirmation, True),
        ("ddl", confirmation, False),
        (
            "community-cleanup",
            dict(confirmation, kinds=[], settledMutations=["follow:user2", "like:course1"]),
            True,
        ),
        (
            "community-cleanup",
            dict(confirmation, kinds=[], settledMutations=["like:course0"]),
            False,
        ),
        ("community-cleanup", dict(confirmation, serverReceipt=""), False),
        ("community-cleanup", dict(confirmation, kinds=["course"]), False),
        ("community-cleanup", {}, False),
    ):
        result = subprocess.run(
            ["zsh", "-c", scope_source, str(SCRIPT_ROOT / "release-network-smoke.sh"), scope],
            env=dict(os.environ, BIT101_COMMUNITY_RECOVERY_CONFIRMATION=json.dumps(value)),
            capture_output=True,
            text=True,
        )
        assert (result.returncode == 0) == valid, "服务端未创建确认需要匹配清理范围及确认载荷"
        if not valid:
            assert "WORKFLOW_LOCK" not in result.stdout, "确认载荷校验在选机及安装前完成"
    for value, valid in (
        (valid_fixture, True),
        ({}, False),
        (dict(valid_fixture, posterID=True), False),
        (dict(valid_fixture, courseID=0), False),
        (dict(valid_fixture, courseNumber=" COURSE"), False),
    ):
        result = subprocess.run(
            ["zsh", "-c", scope_source, str(SCRIPT_ROOT / "release-network-smoke.sh"), "bit101"],
            env=dict(
                os.environ,
                BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(value),
                BIT101_COMMUNITY_SMOKE_ACCOUNT="1",
            ),
            capture_output=True,
            text=True,
        )
        if (result.returncode == 0) != valid:
            findings.append("网络维护对象自测：校验对象标识及课程编号")
    for arguments, term, expected in (
        (["all"], "", "network full"),
        (["all"], "historical", "network selected"),
        (["school", "sms"], "", "school-sms full"),
        (["school", "sms"], "historical", "school-sms selected"),
    ):
        result = subprocess.run(
            [
                "zsh",
                "-c",
                scope_source + '\nprint -r -- "$validation_group $validation_scope"',
                str(SCRIPT_ROOT / "release-network-smoke.sh"),
                *arguments,
            ],
            capture_output=True,
            text=True,
            env=dict(
                os.environ,
                BIT101_NETWORK_SMOKE_TERM=term,
                BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture),
                BIT101_COMMUNITY_SMOKE_ACCOUNT="1",
            ),
        )
        if result.returncode or result.stdout.splitlines()[-1:] != [expected]:
            findings.append("网络学期自测：覆盖学期采样沿定向范围登记")
    return export_source, valid_fixture


def check_export_locks_and_tools(export_source, findings):
    export_source = export_source.replace(
        '  python3 "$ROOT_DIR/Scripts/test_results.py" report',
        '  exit 86\n  python3 "$ROOT_DIR/Scripts/test_results.py" report',
    )
    for arguments, locked in (
        (["report", "json"], False),
        (["diagnostics"], True),
        (["activities", "test"], False),
        (["screenshot", "test"], True),
        (["report", "Suite/test"], True),
    ):
        result = subprocess.run(
            ["zsh", "-c", export_source, str(SCRIPT_ROOT / "run-extended-tests.sh"), *arguments],
            env=dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1"),
            capture_output=True,
            text=True,
        )
        if result.returncode != 86 or result.stdout.count("WORKFLOW_LOCK") != int(locked):
            findings.append(f"结果读取与附件导出沿各自的锁范围执行：{arguments[0]}")
    for command, markers in (
        (
            ["xcrun", "devicectl", "device", "process", "launch", "--help"],
            ["--terminate-existing", "<command-line-arguments>"],
        ),
        (["xcrun", "devicectl", "device", "info", "processes", "--help"], ["--json-output"]),
        (["xcrun", "xcresulttool", "merge", "--help"], ["--output-path"]),
    ):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode or any(marker not in result.stdout for marker in markers):
            findings.append("装机恢复自测：当前工具链需要正式启动与进程读取参数")


def command_dispatch_inputs(valid_fixture):
    from validation_test_areas import test_inventory

    ui_test_count = len(test_inventory("ui"))
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
        ("run-extended-tests.sh", ["build", "modules"], 0, "swift test --quiet --skip .*", ""),
        ("run-extended-tests.sh", ["build", "catalyst"], 0, "variant=Mac Catalyst", ""),
        (
            "run-extended-tests.sh",
            ["build", "catalyst-release-runtime"],
            0,
            "BIT101_WORKFLOW_CONDITIONS=",
            "",
        ),
        ("run-extended-tests.sh", ["catalyst"], 86, "-only-testing:BIT101-iOSTests", ""),
        (
            "run-extended-tests.sh",
            ["catalyst", "LoginStorageTests"],
            86,
            "-only-testing:BIT101-iOSTests/LoginStorageTests",
            "",
        ),
        (
            "run-extended-tests.sh",
            ["catalyst-release-runtime"],
            86,
            "ReleaseRuntimeContractTests",
            "",
        ),
        ("run-extended-tests.sh", ["release-runtime"], 86, "ReleaseRuntimeContractTests", "DEVICE"),
        (
            "run-extended-tests.sh",
            ["network-smoke", "NetworkSmokeRegressionTests"],
            86,
            "RELEASE_NETWORK_SMOKE",
            "DEVICE",
        ),
        (
            "run-extended-tests.sh",
            ["ui", "About", "About"],
            86,
            "CommunityPublishingUITests/testAboutLicenseUpdateAndResetConfirmation",
            "DEVICE",
        ),
        (
            "run-extended-tests.sh",
            ["ui", "Schedule"],
            86,
            "testScheduleWeekButtonsAndSectionSwipes",
            "DEVICE",
        ),
        (
            "run-extended-tests.sh",
            ["ui", "DDLEditor"],
            86,
            "ScheduleNavigationUITests/testDdlEditorDetailsCancelEditingEditing",
            "DEVICE",
        ),
        ("run-extended-tests.sh", ["ui", "test"], 86, f"{ui_test_count} 项 UI 用例", "DEVICE"),
        ("run-extended-tests.sh", ["modules"], 86, "swift test", ""),
        ("run-extended-tests.sh", ["modules", "CommunityCoreTests"], 86, "--filter", ""),
        ("run-extended-tests.sh", [], 86, "-only-testing:BIT101-iOSTests", "DEVICE"),
        (
            "run-extended-tests.sh",
            ["NetworkClientTests"],
            86,
            "BIT101-iOSTests/NetworkClientTests",
            "DEVICE",
        ),
        (
            "run-extended-tests.sh",
            ["AppUpdateCheckerTests/promptQueueIsSerial"],
            86,
            "BIT101-iOSTests/AppUpdateCheckerTests/promptQueueIsSerial()",
            "DEVICE",
        ),
        ("run-extended-tests.sh", ["cache"], 0, "CACHE", ""),
        ("release-network-smoke.sh", ["ddl"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("release-network-smoke.sh", ["all", "sms"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("release-network-smoke.sh", ["school", "sms"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("run_icloud_cross_device_smoke.sh", [], 86, "ICLOUD_CROSS_DEVICE_SMOKE", "DEVICE"),
        ("run_icloud_cross_device_smoke.sh", ["report"], 0, "REPORT", ""),
    )
    environment = dict(
        os.environ,
        BIT101_WORKFLOW_CONDITIONS="DEBUG RELEASE_NETWORK_SMOKE",
        BIT101_EXTENDED_TESTS_LOCK_HELD="1",
        BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(valid_fixture),
        BIT101_COMMUNITY_SMOKE_ACCOUNT="1",
    )
    return cases, environment, ui_test_count


def check_workflow_failure_recording(environment, findings, frame):
    for filename, arguments in (
        ("build-install-device.sh", ["archive"]),
        ("run-extended-tests.sh", ["build"]),
        ("release-network-smoke.sh", ["ddl"]),
        ("run_icloud_cross_device_smoke.sh", []),
        ("run-static-audit.sh", []),
    ):
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
        failure = (
            frame
            + """\npython3() {
  if [[ "$*" == *"validation_evidence.py digest"* ]]; then return 79; fi
  return 0
}\n"""
        )
        result = subprocess.run(
            ["zsh", "-c", failure + source, str(path), *arguments],
            env=dict(
                environment, BIT101_STATIC_AUDIT_LOCK_HELD="1", SWIFT_FRONTEND="/usr/bin/true"
            ),
            capture_output=True,
            text=True,
        )
        if result.returncode != 79:
            findings.append(f"源码摘要失败应在工作流启动前退出：{filename}")
    for arguments, groups in (
        (["ddl"], ["ddl"]),
        (["all", "sms"], ["network", "school-sms"]),
        (["school", "sms"], ["school-sms"]),
    ):
        path = SCRIPT_ROOT / "release-network-smoke.sh"
        failure = (
            frame.replace("trap() { :; }", "")
            + r"""
python3() {
  if [[ "$*" == *"validation_evidence.py digest"* ]]; then print self-test-inputs;
  elif [[ "$1" == *"/network_smoke_config.py" ]]; then command python3 "$@";
  elif [[ "$*" == *"validation_provenance.py worker-snapshot"* ]]; then return 79;
  elif [[ "$*" == *"validation_evidence.py record"* ]]; then print -r -- "RECORD $3 $4 $5";
  else return 0; fi
}
bit101_run_logged() { print BUILD; return 79; }
"""
        )
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', failure)
        result = subprocess.run(
            ["zsh", "-c", source, str(path), *arguments],
            env=environment,
            capture_output=True,
            text=True,
        )
        records = [line for line in result.stdout.splitlines() if line.startswith("RECORD ")]
        if (
            result.returncode != 79
            or records != [f"RECORD {group} 79 full" for group in groups]
            or "BUILD\n" not in result.stdout
            or "RESTORE\n" in result.stdout
        ):
            findings.append(
                (
                    f"网络部署身份缺口自测："
                    f"{arguments}"
                    f" 构建失败保留设备现有 App 并登记采样结果；退出 "
                    f"{result.returncode}"
                    f"；"
                    f"{result.stderr[-400:]}"
                )
            )


def check_command_dispatch(cases, environment, findings, frame, support, ui_test_count):
    for filename, arguments, expected, marker, device in cases:
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace(
            'source "$ROOT_DIR/Scripts/script-support.sh"',
            f"source {shlex.quote(str(support))}\n" + frame,
        )
        source = re.sub(r'(?:>>|>) "\$RESTORE_LOG" 2>&1', ">&2", source)
        stop = "exit 86" if expected == 86 else "return 0"
        source = source.replace(
            frame,
            frame
            + (
                f'\nbit101_run_logged() {{ print -r -- "BUILD $*"; print -r -- "ARGUMENTS ${{(qqq)'
                f'@}}"; '
                f"{stop}"
                f"; }}\n"
            )
            + (
                '\npython3() { if [[ "$*" == *"validation_performance.py"* ]]; then return 0; fi; '
                'if [[ "$*" == *"validation_provenance.py worker-snapshot"* ]]; then print "{}"; r'
                'eturn 0; fi; if [[ "$*" == *"validation_restore.py"* ]]; then print -ru2 RESTORE_'
                'PROBE; return 0; fi; if [[ "$*" == *"/signing.entitlements"* || "$*" == *"/icloud'
                '-cross-device-smoke/report.json"* ]]; then return 0; fi; if [[ "$*" == *"validati'
                'on_evidence.py digest"* ]]; then case "$3" in all|release-runtime|ui|schedule|inf'
                "rastructure|login|extensions|network|ddl|school-sms|community-writes|community-cl"
                'eanup|icloud|icloud-cleanup|restore) [[ "${BIT101_XCODE_DEVICE_ID:-}" == udid ]] '
                '|| return 78 ;; esac; print self-test-inputs; return 0; fi; command python3 "$@";'
                " }\n"
            ),
        )
        source = re.sub(
            r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$",
            "ui_test_plan() { print -r -- /audit/ui.xctestrun; }",
            source,
            count=1,
        )
        source = re.sub(
            r"(?ms)^report_result\(\) \{\n.*?^\}$",
            "report_result() { print REPORT; }",
            source,
            count=1,
        )
        result = subprocess.run(
            ["zsh", "-c", source, str(path), *arguments],
            env=environment,
            capture_output=True,
            text=True,
        )
        command_output = "\n".join(
            line for line in result.stdout.splitlines() if line.startswith("BUILD ")
        )
        if (
            result.returncode != expected
            or marker not in result.stdout
            or ("DEVICE\n" in result.stdout) != bool(device)
            or filename == "build-install-device.sh"
            and command_output
            and any(
                not re.search(r"\b" + name + r"=(?:\s|$)", command_output)
                for name in ("BIT101_WORKFLOW_CONDITIONS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS")
            )
        ):
            findings.append(
                (
                    f"命令自测："
                    f"{filename}"
                    f" "
                    f"{' '.join(arguments)}"
                    f" 退出 "
                    f"{result.returncode}"
                    f"/"
                    f"{expected}"
                    f"；目标参数 "
                    f"{marker!r}"
                    f"；"
                    f"{result.stderr}"
                )
            )
        if filename == "run-extended-tests.sh":
            findings.extend(
                test_build_argument_findings(
                    result.stdout, testing_device=arguments[:1] != ["build"]
                )
            )
            if arguments in (["build"], ["modules"]):
                findings.extend(
                    check_build_argument_mutations(source, path, arguments, environment)
                )
        if (
            filename == "build-install-device.sh"
            and not arguments
            and (
                "RESTORE_PROBE" not in result.stderr or "device info processes" not in result.stderr
            )
        ):
            findings.append("装机恢复自测：就绪信号与当前进程共同参与验收")
        if filename == "run-extended-tests.sh" and (
            not arguments
            or arguments[0]
            in {"catalyst", "catalyst-release-runtime", "release-runtime", "modules", "build"}
        ):
            group = arguments[0] if arguments else "all"
            if group == "build":
                group = "build-" + (arguments[1] if len(arguments) > 1 else "release")
            if f"/extended-automation/{group}.log" not in result.stdout:
                findings.append(f"命令自测：{group} 保存独立验证组日志")
        needs_lock = arguments != ["info"] and (
            filename != "run_icloud_cross_device_smoke.sh" or arguments != ["report"]
        )
        if ("WORKFLOW_LOCK\n" in result.stdout) != needs_lock:
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 取得工作流锁")
        if (
            filename in {"run-extended-tests.sh", "build-install-device.sh"}
            and needs_lock
            and ("DEVICE_LOCK\n" in result.stdout)
            != (
                bool(device)
                or arguments == ["mac"]
                or filename == "run-extended-tests.sh"
                and arguments[0] in {"modules", "catalyst", "catalyst-release-runtime"}
            )
        ):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 按共享资源选择锁范围")
        if (
            filename == "run-extended-tests.sh"
            and arguments[:2] == ["ui", "About"]
            and command_output.count(marker) != 1
        ):
            findings.append("命令自测：重复 UI 关键词合并为一个用例")
        if arguments == ["ui", "Schedule"] and "testAboutLicense" in result.stdout:
            findings.append("命令自测：方法关键词按实际流程筛选")
        if (
            arguments == ["ui", "test"]
            and command_output.count("-only-testing:BIT101-iOSUITests/") != ui_test_count
        ):
            findings.append("命令自测：两个测试类的全部交互用例可通过关键词选择")


def check_invalid_command_arguments(findings):
    for filename, arguments in (
        ("run-extended-tests.sh", ["network-smoke"]),
        ("build-install-device.sh", ["build", "extra"]),
        ("run-extended-tests.sh", ["ui", "unmatched-keyword"]),
        ("run-extended-tests.sh", ["build", "unknown"]),
        ("run-extended-tests.sh", ["verify", "unknown"]),
        ("release-network-smoke.sh", ["unknown"]),
        ("run_icloud_cross_device_smoke.sh", ["unknown"]),
    ):
        result = subprocess.run(
            ["zsh", str(SCRIPT_ROOT / filename), *arguments], capture_output=True, text=True
        )
        if result.returncode != 64:
            findings.append(f"命令自测：{filename} 错误参数在执行前拒绝")


def check_ui_test_plan_selection(findings):
    from test_results import ui_test_plan

    older, newer = Mock(), Mock()
    older.stat.return_value.st_mtime = 1
    newer.stat.return_value.st_mtime = 2
    selected = StringIO()
    with (
        patch.object(sys, "argv", ["ui-plan", "/audit/Products"]),
        patch.object(Path, "glob", return_value=[older, newer]),
        redirect_stdout(selected),
    ):
        try:
            ui_test_plan(sys.argv[1:])
        except SystemExit as error:
            if error.code not in (None, 0):
                raise
    if older.open.called or newer.open.called or selected.getvalue().strip() != str(newer):
        findings.append("UI 计划自测：最新构建选择及默认诊断配置保留")
    with (
        patch.object(sys, "argv", ["ui-plan", "/audit/Products"]),
        patch.object(Path, "glob", return_value=[]),
    ):
        try:
            ui_test_plan(sys.argv[1:])
        except SystemExit as error:
            if ".xctestrun" not in str(error):
                findings.append("UI 计划自测：冷缓存缺少运行配置时的诊断")
        else:
            findings.append("UI 计划自测：运行配置完整性检查")
