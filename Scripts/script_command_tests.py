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


from command_lifecycle_tests import (
    test_build_argument_findings as test_build_argument_findings,
    result_retention_boundary_findings as result_retention_boundary_findings,
    run_install_program as run_install_program,
    restore_installation_boundary_findings as restore_installation_boundary_findings,
    audit_lock_boundary_findings as audit_lock_boundary_findings,
    kill_worker_group as kill_worker_group,
    audit_cancellation_findings as audit_cancellation_findings,
    check_build_argument_mutations as check_build_argument_mutations,
    ui_metrics_boundary_findings as ui_metrics_boundary_findings,
)


from script_command_dispatch_tests import (
    check_archive_installation,
    check_command_dispatch,
    check_export_locks_and_tools,
    check_invalid_command_arguments,
    check_network_command_configuration,
    check_result_bundle_readiness,
    check_ui_test_plan_selection,
    check_workflow_failure_recording,
    command_dispatch_inputs,
    command_shell_frame,
)


def script_command_boundary_findings() -> list[str]:
    findings = initial_command_findings()
    check_validation_execution(findings)
    support = check_icloud_cleanup(findings)
    check_result_bundle_readiness(findings)
    frame = command_shell_frame()
    check_archive_installation(frame)
    export_source, valid_fixture = check_network_command_configuration(findings, frame)
    check_export_locks_and_tools(export_source, findings)
    cases, environment, ui_test_count = command_dispatch_inputs(valid_fixture)
    check_workflow_failure_recording(environment, findings, frame)
    check_command_dispatch(cases, environment, findings, frame, support, ui_test_count)
    check_invalid_command_arguments(findings)
    check_ui_test_plan_selection(findings)

    findings.extend(device_discovery_boundary_findings())
    findings.extend(ui_metrics_boundary_findings())
    return findings


def initial_command_findings():
    for name in ("run-extended-tests.sh", "run_icloud_cross_device_smoke.sh"):
        result = subprocess.run(
            ["/bin/zsh", str(SCRIPT_ROOT / name), "--help"],
            capture_output=True,
            text=True,
            env=dict(os.environ, PATH="/usr/bin:/bin"),
        )
        assert result.returncode == 0 and result.stdout and not result.stderr, (name, result.stderr)
    from test_results import module_filter

    selected = StringIO()
    with redirect_stdout(selected):
        module_filter(["Suite", "Other/name()"])
    pattern = selected.getvalue().strip()
    assert re.search(pattern, "App.Suite/works()") and re.search(pattern, "Other/name()")
    assert not re.search(pattern, "App.SuiteExtra/works()")
    audit = (SCRIPT_ROOT / "run-static-audit.sh").read_text()
    for option, status in (("--help", 0), ("--unknown", 64)):
        result = subprocess.run(
            ["zsh", "-c", audit, "/missing/audit", option], text=True, capture_output=True
        )
        assert result.returncode == status and "用法" in result.stdout + result.stderr
    from ci_wiring_rules import hook_documents_checked, active_script_markers
    from module_boundary_tests import build_cache_exit_self_test

    assert hook_documents_checked("exec python3 Scripts/check-docs.py --staged")
    for source in (
        "# exec python3 Scripts/check-docs.py --staged",
        'echo "python3 Scripts/check-docs.py --staged"',
        "exit 0\nexec python3 Scripts/check-docs.py --staged",
        "if false; then\nexec python3 Scripts/check-docs.py --staged\nfi",
        "cat <<'TEXT'\nexec python3 Scripts/check-docs.py --staged\nTEXT",
        "exec python3 Scripts/check-docs.py --staged || true",
    ):
        assert not hook_documents_checked(source)
    assert "xccov" not in active_script_markers("# xccov\necho ready # xccov")
    "通过内存替身验证自动选机、操作分派、筛选合并及参数拒绝。"
    import plistlib

    metadata_option = "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES"
    metadata_arguments = [
        "ARGUMENTS",
        "/fixture/log",
        metadata_option,
        "xcodebuild",
        "build-for-testing",
        "-configuration",
        "Release",
        "-enableCodeCoverage",
        "YES",
        "ENABLE_CODE_COVERAGE=YES",
        "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
    ]
    assert any(
        metadata_option in finding
        for finding in test_build_argument_findings(shlex.join(metadata_arguments))
    ), "日志标签中的参数进入元数据，实际编译命令承担参数检查"
    assert any(
        "ONLY_ACTIVE_ARCH=YES" in finding
        for finding in test_build_argument_findings(
            shlex.join(metadata_arguments), testing_device=True
        )
    )

    findings = (
        result_retention_boundary_findings()
        + audit_cancellation_findings()
        + build_cache_exit_self_test()
    )
    from script_output_tests import log_output_boundary_findings, combined_audit_order_findings

    findings += log_output_boundary_findings()
    findings += combined_audit_order_findings()
    from test_results_tests import test_result_boundary_findings

    findings += test_result_boundary_findings()
    return findings


def check_validation_execution(findings):
    import plistlib

    isolated_digest = (
        "from pathlib import Path\nfrom unittest.mock import patch\nimport sys\noriginal_read = Pa"
        "th.read_text\ndef read(path, *args, **kwargs):\n    if path.name == 'PerformanceWorkloads"
        ".json': raise ValueError('invalid workload fixture')\n    return original_read(path, *arg"
        "s, **kwargs)\nwith patch.object(Path, 'read_text', read):\n    import validation_evidence"
        "\n    with patch.object(validation_evidence, 'input_identity', return_value='fixture'), p"
        "atch.object(sys, 'argv', ['validation_evidence.py', 'digest']):\n        raise SystemExit"
        "(validation_evidence.main())\n"
    )
    result = subprocess.run(
        [sys.executable, "-B", "-c", isolated_digest],
        cwd=SCRIPT_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode or result.stdout.strip() != "fixture":
        findings.append("基础证据摘要自测：人工性能配置按所属操作加载")
    audit_source = (SCRIPT_ROOT / "run-static-audit.sh").read_text()
    audit_exit = (
        "finish_audit() {"
        + audit_source.split("finish_audit() {", 1)[1].split("\nSWIFT_FRONTEND=", 1)[0]
    )
    for action, expected, recording in (
        ("exit 0", 0, 0),
        ("exit 7", 7, 0),
        ("kill -s INT $$", 130, 0),
        ("kill -s TERM $$", 143, 0),
        ("exit 0", 9, 9),
        ("exit 7", 7, 9),
    ):
        harness = (
            f"ROOT_DIR=/fixture AUDIT_STARTED=$SECONDS group_processes=() group_names=() full_au"
            f'dit=1\npython3() {{ print -r -- "RECORD $*"; return '
            f"{recording}"
            f"; }}\n"
        )
        result = subprocess.run(
            ["zsh", "-c", harness + audit_exit + "\n" + action], capture_output=True, text=True
        )
        original = expected if not recording else 0 if action == "exit 0" else 7
        if (
            result.returncode != expected
            or result.stdout.count(
                f"RECORD /fixture/Scripts/validation_evidence.py record audit {original}"
            )
            != 1
        ):
            findings.append("静态审计退出自测：完成、失败及信号统一登记，保留原始失败状态")
    simulator = subprocess.run(
        ["zsh", str(SCRIPT_ROOT / "simulator-tests.sh"), "info"],
        env=dict(os.environ, BIT101_SIMULATOR_AUTHORIZED="0"),
        capture_output=True,
        text=True,
    )
    if simulator.returncode != 64 or "显式授权" not in simulator.stderr:
        findings.append("模拟器命令自测：执行前核对用户授权标记")
    simulator_source = (SCRIPT_ROOT / "simulator-tests.sh").read_text()
    import validation_evidence as evidence

    inventory = ["Suite/first", "Suite/second"]
    with (
        patch("validation_result_readers.test_inventory", return_value=set(inventory)),
        patch(
            "validation_result_readers.test_selectors",
            return_value={name: name + "()" for name in inventory},
        ),
        patch.object(evidence, "test_inventory", return_value=set(inventory)),
        patch.object(
            evidence, "test_selectors", return_value={name: name + "()" for name in inventory}
        ),
        patch("validation_coverage.shard_inventory", return_value=inventory),
    ):
        for scope, selected, shard in (
            ("full", [], None),
            ("shard", [], "0/1"),
            ("selected", inventory[:1], None),
        ):
            expected, selectors = evidence.simulator_test_selection("all", scope, selected, shard)
            assert expected == (selected if scope == "selected" else inventory)
            assert selectors == [name + "()" for name in expected]
        try:
            evidence.simulator_test_selection("all", "selected", ["Missing/test"], None)
        except ValueError:
            pass
        else:
            findings.append("模拟器库存规划需要传播失效筛选。")
    from types import SimpleNamespace
    from validation_coverage import run_simulator_ui, SIMULATOR_KEYBOARD_TESTS

    selected = [
        "-only-testing:BIT101-iOSUITests/" + sorted(SIMULATOR_KEYBOARD_TESTS)[0],
        "-only-testing:BIT101-iOSUITests/First/test",
        "-only-testing:BIT101-iOSUITests/Second/test",
    ]
    with (
        patch.object(Path, "read_bytes", return_value=plistlib.dumps({"TestConfigurations": []})),
        patch.object(Path, "write_bytes"),
        patch.object(shutil, "rmtree"),
        patch.object(shutil, "copyfile") as copied,
        patch.object(subprocess, "run", return_value=SimpleNamespace(returncode=65)) as executed,
        patch("validation_performance.result_bundle_complete", return_value=True),
    ):
        result = run_simulator_ui(
            Path("/audit/plan"), Path("/audit/derived"), "device", 2, selected
        )
        if result != 65 or executed.call_count != 1 or copied.called:
            findings.append("原生键盘阶段失败应保留原始退出状态和结果包并立即结束。")
    from validation_restore import simulator_restore_findings
    from script_output_tests import verification_finish_findings

    findings.extend(simulator_restore_findings(simulator_source))
    findings.extend(verification_finish_findings())


def check_icloud_cleanup(findings):
    support = SCRIPT_ROOT / "script-support.sh"
    icloud_source = (SCRIPT_ROOT / "run_icloud_cross_device_smoke.sh").read_text()
    recovery = (
        "finish_smoke() {"
        + icloud_source.split("finish_smoke() {", 1)[1].split("\ntrap finish_smoke", 1)[0]
    )
    for original, phone_status, mac_status, attempted in (
        (0, 0, 0, False),
        (7, 0, 0, False),
        (0, 9, 0, False),
        (0, 0, 9, False),
        (7, 9, 9, False),
        (7, 9, 9, True),
    ):
        stub = (
            f"ROOT_DIR=/fixture SUMMARY_PATH=/fixture/report CLEANUP_ONLY=false validation_group"
            f"=icloud PHONE_AVAILABLE=true\nPHONE_TEST_PID= PHONE_TESTS_STARTED=true PHONE_CLEAN"
            f"ED_UP=false MAC_TESTS_STARTED=true MAC_CLEANED_UP=false\nPHONE_CLEANUP_ATTEMPTED="
            f"{str(attempted).lower()}"
            f" MAC_CLEANUP_ATTEMPTED="
            f"{str(attempted).lower()}"
            f"\nrun_phone_test() {{ print PHONE; return "
            f"{phone_status}"
            f"; }}\nrun_mac_cleanup() {{ print MAC; return "
            f"{mac_status}"
            f"; }}\npython3() {{ :; }}\nreport_result() {{ :; }}\n"
        )
        result = subprocess.run(
            [
                "zsh",
                "-c",
                stub + recovery + '\ntrap finish_smoke EXIT\nexit "$1"',
                "icloud-recovery-test",
                str(original),
            ],
            capture_output=True,
            text=True,
        )
        if (
            result.returncode != (original or int(bool(phone_status or mac_status)))
            or result.stdout.splitlines().count("PHONE") != int(not attempted)
            or result.stdout.splitlines().count("MAC") != int(not attempted)
        ):
            findings.append("iCloud 恢复自测：双端清理独立执行并保留原始失败状态")
    availability = icloud_source.split("PHONE_AVAILABLE=true\n", 1)[1].split(
        "BIT101_VALIDATION_RUN_ID=", 1
    )[0]
    cleanup_entry = (
        "cleanup_status=0\n"
        + icloud_source.split("cleanup_status=0\n", 1)[1].split(
            'echo "[构建] 准备 Mac Catalyst 测试宿主"', 1
        )[0]
    )
    cleanup_recovery = recovery
    for phone, mac, build, test, expected in (
        (0, 0, 0, 0, 0),
        (1, 0, 0, 0, 1),
        (1, 9, 0, 0, 1),
        (0, 9, 0, 0, 1),
        (0, 0, 9, 0, 9),
        (0, 0, 0, 9, 1),
    ):
        stub = (
            f"set -euo pipefail\nROOT_DIR=/fixture DERIVED_ROOT=/fixture SUMMARY_PATH=/fixture/r"
            f"eport RESULT_BUNDLE=/fixture/result\nCLEANUP_ONLY=true validation_group=icloud PHO"
            f"NE_AVAILABLE=true CLEANUP_DEVICE_ID=phone-a DEVICE_ID=phone-a\nPHONE_TEST_PID= PHO"
            f"NE_TESTS_STARTED=false PHONE_CLEANED_UP=false MAC_TESTS_STARTED=false MAC_CLEANED_"
            f"UP=false\nPHONE_CLEANUP_ATTEMPTED=false MAC_CLEANUP_ATTEMPTED=false\ncommon_args=("
            f') TEST_CLASS=Fixture\nbit101_require_device() {{ [[ "$1" == phone-a ]] || exit 81; '
            f"return "
            f"{phone}"
            f"; }}\nbit101_run_logged() {{ print BUILD; return "
            f"{build}"
            f"; }}\nrun_phone_test() {{ PHONE_CLEANUP_ATTEMPTED=true; print PHONE; return "
            f"{test}"
            f"; }}\nrun_mac_cleanup() {{ MAC_CLEANUP_ATTEMPTED=true; print MAC; return "
            f"{mac}"
            f"; }}\npython3() {{ :; }}\nreport_result() {{ :; }}\n"
        )
        result = subprocess.run(
            [
                "zsh",
                "-c",
                stub
                + availability
                + cleanup_recovery
                + "\ntrap finish_smoke EXIT ZERR\n"
                + cleanup_entry,
            ],
            capture_output=True,
            text=True,
        )
        rows = result.stdout.splitlines()
        if (
            result.returncode != expected
            or rows.count("MAC") != 1
            or rows.count("PHONE") != int(not phone and not build)
            or "RESTORE" in rows
            or phone
            and any(marker in rows for marker in ("BUILD", "PHONE"))
            or not phone
            and ("BUILD" not in rows or rows.index("MAC") > rows.index("BUILD"))
            or not phone
            and not build
            and "PHONE" not in rows
        ):
            findings.append(
                "iCloud 恢复自测：手机离线及构建失败仍推进 Mac 清理，两端失败保留待恢复状态"
            )
    pending = icloud_source.split('pending_cleanup="$(python3 - "$SUMMARY_PATH" <<\'PY\'\n', 1)[
        1
    ].split("\nPY\n", 1)[0]
    passed = dict(exitCode=0, totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
    prior_stages = [
        dict(passed, stage=stage) for stage in ("testPhoneRoundTrip", "testMacReceiveAndRestore")
    ]
    for overrides, expected in (
        ({}, ""),
        ({"macCleanup": dict(passed, exitCode=1)}, "cleanup"),
        ({"cleanup": dict(passed, exitCode=1)}, "cleanup"),
        ({"stages": prior_stages[:1]}, "cleanup"),
        ({"stages": [], "testsStarted": False}, ""),
        ({"stages": [], "testsStarted": True}, "cleanup"),
    ):
        output = StringIO()
        with (
            patch.object(sys, "argv", ["pending-cleanup", "/fixture"]),
            patch.object(
                Path,
                "read_text",
                return_value=json.dumps(dict({"stages": prior_stages}, **overrides)),
            ),
            redirect_stdout(output),
        ):
            exec(compile(pending, "<icloud-pending-cleanup>", "exec"), {})
        if output.getvalue().strip() != expected:
            findings.append("iCloud 恢复自测：双端恢复通过后进入新验收账号")
    identity = icloud_source.split('cleanup_identity="$(python3 - "$SUMMARY_PATH" <<\'PY\'\n', 1)[
        1
    ].split("\nPY\n", 1)[0]
    run_id = "00000000-0000-0000-0000-000000000001"
    phone = dict(stage="testPhoneRoundTrip", destination={"deviceIdentifier": "phone-a"})
    for report, valid in (
        ({"phoneDeviceIdentifier": "phone-a", "stages": [phone]}, True),
        ({"stages": [phone]}, True),
        ({"phoneDeviceIdentifier": "phone-a", "stages": []}, True),
        ({"stages": []}, False),
        ({"phoneDeviceIdentifier": "phone-b", "stages": [phone]}, False),
    ):
        output, succeeded = StringIO(), True
        with (
            patch.object(sys, "argv", ["cleanup-identity", "/fixture"]),
            patch.object(Path, "read_text", return_value=json.dumps(dict(report, runID=run_id))),
            redirect_stdout(output),
        ):
            try:
                exec(compile(identity, "<icloud-cleanup-identity>", "exec"), {})
            except SystemExit:
                succeeded = False
        if succeeded != valid or output.getvalue().splitlines() != (
            [run_id, "phone-a"] if valid else []
        ):
            findings.append("iCloud 恢复自测：沿原执行设备读取账号，身份冲突保留既有报告")
    return support
