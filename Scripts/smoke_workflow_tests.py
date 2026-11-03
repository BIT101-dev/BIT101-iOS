"""Focused workflow and source checks."""

from __future__ import annotations
from pathlib import Path
import json, os, re, subprocess, sys, shutil, signal
from contextlib import nullcontext, redirect_stdout
from io import StringIO
from unittest.mock import patch
from code_quality_rules import (
    SCRIPT_ROOT,
)


def run_recorded_stage(code: object) -> int:
    try:
        exec(code, {})
        return 0
    except SystemExit as error:
        return error.code


def smoke_script_boundary_findings() -> list[str]:
    "通过故障注入验证清理顺序、状态传播和测试现场保留。"

    source = (SCRIPT_ROOT / "run_icloud_cross_device_smoke.sh").read_text()
    findings: list[str] = []

    def shell_function(name: str, script_source: str = source) -> str:
        match = re.search(rf"(?ms)^([ \t]*){name}\(\) \{{\n.*?^\1\}}$", script_source)
        if match is None:
            raise RuntimeError(f"Smoke 自测需要 {name} 函数")
        return match[0]

    network = (SCRIPT_ROOT / "release-network-smoke.sh").read_text()
    wait_loop = (
        shell_function("copy_smoke_report", network)
        + "\n"
        + network.split("REPORT_READY=false\n", 1)[1].split("\nif ! $REPORT_READY", 1)[0]
    )
    for marker in ("NETWORK_SMOKE_REPORT_WRITE_FAIL run_id=fixture", "NETWORK_SMOKE_REQUEST_FAIL"):
        stub = (
            "set -euo pipefail\nROOT_DIR=/fixture\nRUN_ID=fixture\nCONSOLE_LOG=/fixture-console\nc"
            "onsole_process=1\nREPORT_READY=false\nDEADLINE=$(( SECONDS + 5 ))\n"
        )
        stub += (
            'python3() { print -r -- "'
            + marker
            + '"; }\nkill() { return 0; }\nxcrun() { return 9; }\nsleep() { return 9; }\n'
        )
        failed = subprocess.run(
            ["zsh", "-c", stub + wait_loop], capture_output=True, text=True, timeout=5
        )
        assert failed.returncode == 1 and "失败" in failed.stderr, failed.stderr
    stub = (
        "set -euo pipefail\nROOT_DIR=/fixture\nRUN_ID=fixture\nCONSOLE_LOG=/fixture-console\nconso"
        "le_process=1\nREPORT_READY=false\nDEADLINE=$(( SECONDS + 5 ))\n"
    )
    stub += (
        'phase=waiting\npython3() { if [[ "$phase" == ready ]]; then print -r -- "NETWORK_SMOKE_SU'
        'MMARY run_id=fixture passed=1"; fi; }\n'
    )
    stub += (
        "SIMULATOR_DEVICE=\nDEVICETCL_DEVICE_ID=fixture\nAPP_GROUP_ID=fixture\nREMOTE_REPORT_PATH="
        "fixture\nLOCAL_REPORT_PATH=/fixture\n"
    )
    stub += (
        'kill() { [[ "$phase" == waiting ]]; }\nxcrun() { [[ "$phase" == ready ]] || exit 8; exit '
        "17; }\nsleep() { phase=ready; }\n"
    )
    ready = subprocess.run(
        ["zsh", "-c", stub + wait_loop], capture_output=True, text=True, timeout=5
    )
    assert ready.returncode == 17, ready
    stopped = subprocess.run(
        ["zsh", "-c", stub.replace("phase=waiting", "phase=stopped") + wait_loop],
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert stopped.returncode == 1 and "控制台进程已结束" in stopped.stderr, stopped
    phone_function = shell_function(
        "run_phone_test", (SCRIPT_ROOT / "icloud-smoke-support.sh").read_text()
    )
    stub = r"""
set -euo pipefail
DERIVED_ROOT=/smoke
RESULT_BUNDLE=/smoke/test-results.xcresult
DEVICE_ID=device
TEST_CLASS=smoke
common_args=()
rm() { print -r -- "DELETE $*"; }
bit101_run_logged() { print -r -- "RUN $*"; }
record_result() { print -r -- "RECORD $*"; }
bit101_invalidate_restore() { :; }
"""
    cleanup = subprocess.run(
        ["zsh", "-c", stub + phone_function + "\nrun_phone_test testCleanup"],
        capture_output=True,
        text=True,
    )
    if (
        cleanup.returncode
        or "DELETE -rf /smoke/test-results.xcresult" in cleanup.stdout
        or "-resultBundlePath" in cleanup.stdout
    ):
        findings.append("Smoke 恢复自测失败：清理覆盖业务阶段结果包")
    business = subprocess.run(
        ["zsh", "-c", stub + phone_function + "\nrun_phone_test testPhoneRoundTrip"],
        capture_output=True,
        text=True,
    )
    if business.returncode or "-resultBundlePath" not in business.stdout:
        findings.append("Smoke 恢复自测失败：业务阶段结果包保存")
    worker = re.search(r"<<'PYWORKER'\n(.*?)^PYWORKER$", source, re.MULTILINE | re.DOTALL)
    handlers = {}
    child = type(
        "Worker",
        (),
        {
            "pid": 42,
            "wait": lambda self, timeout=None: (
                -signal.SIGTERM
                if timeout is not None
                else (handlers[signal.SIGTERM](signal.SIGTERM, None), -signal.SIGTERM)[1]
            ),
        },
    )()
    with (
        patch.object(
            sys, "argv", ["worker", "/root", "/derived", "/bundle", "/report", "device", "suite"]
        ),
        patch.object(subprocess, "Popen", return_value=child) as launch,
        patch.object(
            signal, "signal", side_effect=lambda signum, handler: handlers.update({signum: handler})
        ),
        patch.object(os, "killpg") as cancel,
    ):
        try:
            exec(compile(worker[1], "phone-worker-self-test", "exec"), {})
        except SystemExit as result:
            if result.code != 143:
                findings.append("Smoke 并行自测：手机宿主信号退出状态")
        if launch.call_args.kwargs.get(
            "start_new_session"
        ) is not True or cancel.call_args.args != (42, signal.SIGTERM):
            findings.append("Smoke 并行自测：中断时终止手机测试进程组")
    import shlex
    import time

    injected = (
        "import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print(os.getpid()"
        ", flush=True); time.sleep(60)"
    )
    command = "exec " + shlex.quote(sys.executable) + " -B -c " + shlex.quote(injected)
    import ast

    tree = ast.parse(worker[1])
    assignment = next(
        node
        for node in tree.body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "worker" for target in node.targets)
    )
    assignment.value = ast.Constant(command)
    harness = ast.unparse(tree)
    supervisor = subprocess.Popen(
        [
            sys.executable,
            "-B",
            "-c",
            harness,
            "/root",
            "/derived",
            "/bundle",
            "/report",
            "device",
            "suite",
        ],
        env=dict(os.environ, BIT101_WORKFLOW_DEADLINE=str(time.monotonic() + 0.2)),
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    detached_pid = None
    try:
        detached_pid = int(supervisor.stdout.readline())
        os.killpg(supervisor.pid, signal.SIGTERM)
        _, error = supervisor.communicate(timeout=5)
        try:
            os.kill(detached_pid, 0)
        except ProcessLookupError:
            terminated = True
        else:
            terminated = False
        if supervisor.returncode != 143 or not terminated:
            findings.append("Smoke 并行自测：忽略终止信号的独立手机进程组需要在期限内结束")
    except subprocess.TimeoutExpired:
        findings.append("Smoke 并行自测：独立手机进程组需要按工作流期限强制终止")
    finally:
        if supervisor.poll() is None:
            os.killpg(supervisor.pid, signal.SIGKILL)
        if detached_pid is not None:
            try:
                os.kill(detached_pid, 0)
            except ProcessLookupError:
                pass
            else:
                os.killpg(detached_pid, signal.SIGKILL)
        supervisor.wait(timeout=5)
    finish = shell_function("finish_smoke")
    trap_registration = "\n".join(re.findall(r"(?m)^trap .+$", source))
    cases = ((7, 0, 7), (7, 1, 7), (0, 1, 1), (0, 0, 0), (130, 0, 130), (143, 0, 143))
    for initial, cleanup_status, expected in cases:
        triggers = [f"exit {initial}", f"fail_command() {{ return {initial}; }}; fail_command"]
        if initial in (130, 143):
            triggers.append(f"kill -s {'INT' if initial == 130 else 'TERM'} $$")
        for trigger in triggers:
            harness = f"""
set -euo pipefail
PHONE_TESTS_STARTED=true PHONE_CLEANED_UP=false PHONE_TEST_PID=""
MAC_TESTS_STARTED=false MAC_CLEANED_UP=false CLEANUP_ONLY=false
PHONE_CLEANUP_ATTEMPTED=false MAC_CLEANUP_ATTEMPTED=false
SUMMARY_PATH=/smoke/report.json validation_group=icloud ROOT_DIR=/audit
run_phone_test() {{ print cleanup; return {cleanup_status}; }}
report_result() {{ print report; }}
python3() {{ if [[ "$1" == - ]]; then cat >/dev/null; fi; }}
{finish}
{trap_registration}
{trigger}
"""
            result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
            if result.returncode != expected or not re.search(
                r"(?ms)^cleanup$.*^report$", result.stdout
            ):
                findings.append(f"Smoke 清理自测：状态 {initial}/{cleanup_status}；{trigger}")
    network_source = (SCRIPT_ROOT / "release-network-smoke.sh").read_text()
    finish_network = shell_function("finish_smoke", network_source)
    network_traps = "\n".join(
        line.strip() for line in network_source.splitlines() if line.strip().startswith("trap ")
    )
    cases = (
        (7, 7, "preflight", False, 0),
        (0, 0, "preflight", False, 0),
        (0, 0, "sms", False, 0),
        (7, 7, "sms", False, 0),
        (1, 1, "sms", True, 0),
        (130, 130, "sms", True, 0),
        (0, 1, "sms", True, 1),
    )
    for initial, expected, sms, ready, school_record_status, simulator in (
        (*case, device) for case in cases for device in ("", "fixture")
    ):
        expected = initial if simulator else expected
        harness = (
            f"\nset -euo pipefail\nROOT_DIR=/audit validation_group=network validation_scope=ful"
            f"l\ncommunity_started=false PREPARE_ONLY=false report_ready="
            f"{str(ready).lower()}"
            f"\nSMOKE_SCOPE=all SMS_MODE="
            f"{sms}"
            f' console_process=""\nSIMULATOR_DEVICE='
            f"{simulator}"
            f"\nBIT101_VALIDATION_INPUT_IDENTITY=network-inputs SCHOOL_SMS_STARTED_DIGEST=school"
            f'-inputs\npython3() {{ print -r -- "$BIT101_VALIDATION_INPUT_IDENTITY $*"; if [[ "$*'
            f"""" == *'record school-sms'* ]]; then return """
            f"{school_record_status}"
            f"; fi; return 0; }}\n"
            f"{finish_network}"
            f"\n"
            f"{network_traps}"
            f"\nfail_command() {{ return "
            f"{initial}"
            f"; }}\nfail_command\n"
        )
        result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
        if result.returncode != expected:
            findings.append(f"网络 Smoke 退出自测：状态 {initial}")
        school_status = 0 if ready and initial <= 2 else initial
        if simulator and "record " in result.stdout:
            findings.append("开发设备采样沿独立诊断结果传播退出状态")
        if (
            not simulator
            and sms == "sms"
            and (
                (
                    f"network-inputs /audit/Scripts/validation_evidence.py record network "
                    f"{initial}"
                    f" full"
                )
                not in result.stdout
                or (
                    f"school-inputs /audit/Scripts/validation_evidence.py record school-sms "
                    f"{school_status}"
                    f" full"
                )
                not in result.stdout
            )
        ):
            findings.append("全量短信验收退出自测：两个验证范围维持各自结果与开始摘要")
    extended_source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    from script_test_support import shell_function as shared_shell_function

    for name in ("bit101_finish_verification", "finish_validation"):
        finish = (
            shared_shell_function(SCRIPT_ROOT / "script-support.sh", name)
            if name == "bit101_finish_verification"
            else shell_function(name, extended_source)
        )
        registration = re.search(
            rf"(?m)^[ \t]*trap {name} [^\n]+(?:\n[ \t]*trap [^\n]+)*", extended_source
        )
        if registration is None:
            findings.append(f"测试退出自测需要 {name} 错误钩子")
            continue
        for initial in (0, 7, 130, 143):
            triggers = [f"exit {initial}", f"fail_command() {{ return {initial}; }}; fail_command"]
            if initial in (130, 143):
                triggers.append(f"kill -s {'INT' if initial == 130 else 'TERM'} $$")
            for trigger in triggers:
                harness = f"""
set -euo pipefail
verification_audit_pid= BUILD_ONLY=false WORKFLOW_STARTED_SECONDS=$SECONDS
DERIVED_ROOT=/dev/null ROOT_DIR=/audit validation_group=ui validation_scope=full
retained_result_groups=()
python3() {{ return 0; }}
{finish}
{registration[0]}
{trigger}
"""
                result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
                if result.returncode != initial:
                    findings.append(f"测试退出自测：{name}；状态 {initial}；{trigger}")
    for filename in (
        "run-extended-tests.sh",
        "release-network-smoke.sh",
        "run_icloud_cross_device_smoke.sh",
    ):
        shell = (SCRIPT_ROOT / filename).read_text()
        shell = re.sub(r"\\\n[ \t]*", "", shell)
        calls = [
            line.strip()
            for line in shell.splitlines()
            if '"$ROOT_DIR/Scripts/build-install-device.sh"' in line
        ]
        expected = (
            [
                (
                    'build-archive) bit101_verify_step build-archive "$ROOT_DIR/Scripts/build-inst'
                    'all-device.sh" archive ;;'
                )
            ]
            if filename == "run-extended-tests.sh"
            else []
        )
        if calls != expected:
            findings.append(f"测试入口保留测试宿主，常规 App 装机沿独立步骤执行：{filename}")
    stage_source = (SCRIPT_ROOT / "icloud-smoke-support.sh").read_text()
    match = re.search(r"(?ms)^record_result\(\).*?<<'PY'\n(.*?)^PY$", stage_source)
    if match is None:
        return [*findings, "Smoke 自测需要阶段结果记录器"]
    state = {}

    def read(path: Path, *args, **kwargs) -> str:
        return state[str(path)]

    def write(path: Path, value: str, *args, **kwargs) -> int:
        state[str(path)] = value
        return len(value)

    summary = {
        "totalTestCount": 1,
        "passedTests": 0,
        "failedTests": 1,
        "skippedTests": 0,
        "testFailures": [{"failureText": "business failure"}],
    }
    completed = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
    observed = {}

    def result_response(command, **kwargs):
        if "merge" in command:
            return subprocess.CompletedProcess(command, 0, "")
        if "tests" in command:
            stage = sys.argv[3]
            tree = {
                "devices": [
                    {
                        "platform": observed.get(
                            "platform", "macOS" if stage.startswith("testMac") else "iOS"
                        ),
                        "deviceId": observed.get("deviceId", "phone"),
                    }
                ],
                "testNodes": [
                    {
                        "nodeType": "Unit test bundle",
                        "name": observed.get("target", "BIT101-iOSTests"),
                        "children": [
                            {
                                "nodeType": "Test Case",
                                "nodeIdentifier": observed.get(
                                    "identifier", "ICloudCrossDeviceSmokeTests/" + stage + "()"
                                ),
                            }
                        ],
                    }
                ],
            }
            return subprocess.CompletedProcess(command, 0, json.dumps(tree))
        result = summary if sys.argv[3] == "testPhoneRoundTrip" else completed
        return subprocess.CompletedProcess(command, 0, json.dumps(result))

    with (
        patch.dict(os.environ, BIT101_VALIDATION_RUN_ID="fixture", BIT101_XCODE_DEVICE_ID="phone"),
        patch.object(Path, "is_file", lambda path: str(path) in state),
        patch.object(Path, "is_dir", return_value=True),
        patch.object(
            Path, "glob", side_effect=lambda *args: iter([Path("/smoke/generated.xcresult")])
        ),
        patch.object(Path, "exists", return_value=False),
        patch.object(shutil, "rmtree") as remove_bundle,
        patch.object(shutil, "move") as retain_bundle,
        patch.object(Path, "read_text", read),
        patch("validation_evidence.report_lock", side_effect=lambda **kwargs: nullcontext()),
        patch(
            "validation_evidence.write_report",
            side_effect=lambda report, *, path: write(path, json.dumps(report)),
        ),
        patch.object(subprocess, "run", side_effect=result_response) as result_tool,
    ):
        for stage, process_status, expected in (
            ("testPhoneRoundTrip", "65", 65),
            ("testCleanup", "0", 0),
        ):
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "record",
                        "/smoke/report.json",
                        "/smoke/results.xcresult",
                        stage,
                        process_status,
                        "/smoke/log",
                    ],
                ),
                redirect_stdout(StringIO()),
            ):
                code = run_recorded_stage(compile(match[1], "smoke-stage-record", "exec"))
            if code != expected:
                findings.append("Smoke 结果自测失败：阶段状态码传播")
        report = json.loads(state["/smoke/report.json"])
        if (
            report["stages"][0].get("testFailures") != summary["testFailures"]
            or len(report["stages"]) != 1
            or report.get("cleanup", {}).get("passedTests") != 1
            or result_tool.call_count != 4
        ):
            findings.append("Smoke 结果自测失败：失败阶段与清理阶段的证据归属")
        for log, expected in (("", 1), ("skipped", 1), ("failed", 1), ("passed", 0)):
            completed = {
                "totalTestCount": int(bool(log)),
                "passedTests": int(log == "passed"),
                "failedTests": int(log == "failed"),
                "skippedTests": int(log == "skipped"),
            }
            result_tool.side_effect = result_response
            remove_bundle.reset_mock()
            retain_bundle.reset_mock()
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "record",
                        "/smoke/report.json",
                        "/smoke/results.xcresult",
                        "testCleanup",
                        "0",
                        "/smoke/log",
                    ],
                ),
                redirect_stdout(StringIO()),
            ):
                code = run_recorded_stage(compile(match[1], "smoke-cleanup-record", "exec"))
            if code != expected:
                findings.append(f"Smoke 清理验收自测失败：{log or '零用例'}")
            cleanup = json.loads(state["/smoke/report.json"])["cleanup"]
            if expected and (
                remove_bundle.called
                or retain_bundle.call_args.args
                != ("/smoke/generated.xcresult", "/smoke/test-results.xcresult")
                or cleanup.get("resultBundle") != "/smoke/test-results.xcresult"
            ):
                findings.append("Smoke 结果自测：失败阶段保留固定路径原始结果包")
            if not expected and (
                retain_bundle.called or not remove_bundle.called or "resultBundle" in cleanup
            ):
                findings.append("Smoke 结果自测：成功阶段完成归集后清理原始结果包")
        completed = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        for key, value in [
            ("identifier", "UnrelatedTests/testAlwaysPass"),
            ("target", "OtherTests"),
            ("platform", "iOS Simulator"),
            ("deviceId", "other"),
        ]:
            observed[key] = value
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "record",
                        "/smoke/report.json",
                        "/smoke/results.xcresult",
                        "testCleanup",
                        "0",
                        "/smoke/log",
                    ],
                ),
                redirect_stdout(StringIO()),
            ):
                try:
                    exec(compile(match[1], "smoke-stage-identity", "exec"), {})
                except SystemExit as error:
                    assert error.code == 1
            assert json.loads(state["/smoke/report.json"])["cleanup"]["exitCode"] == 1
            observed.clear()
        for exit_code in (0, 65):
            completed = {
                "totalTestCount": 1,
                "passedTests": int(exit_code == 0),
                "failedTests": int(exit_code != 0),
                "skippedTests": 0,
                "testFailures": summary["testFailures"] if exit_code else [],
            }
            remove_bundle.reset_mock()
            retain_bundle.reset_mock()
            with (
                patch.object(
                    Path,
                    "glob",
                    return_value=iter(
                        [Path("/smoke/test-results.xcresult"), Path("/smoke/generated.xcresult")]
                    ),
                ),
                patch.object(Path, "exists", lambda path: path.name == "test-results.xcresult"),
                patch.object(
                    sys,
                    "argv",
                    [
                        "record",
                        "/smoke/report.json",
                        "",
                        "testMacCleanup",
                        str(exit_code),
                        "/smoke/log",
                    ],
                ),
                redirect_stdout(StringIO()),
            ):
                code = run_recorded_stage(compile(match[1], "mac-cleanup-record", "exec"))
            if code != exit_code:
                findings.append("Mac 恢复自测：清理状态码传播")
            cleanup = json.loads(state["/smoke/report.json"])["macCleanup"]
            merged = (
                retain_bundle.call_args.args
                == ("/smoke/test-results.incoming.xcresult", "/smoke/test-results.xcresult")
                if retain_bundle.called
                else False
            )
            if (
                (merged != bool(exit_code))
                or remove_bundle.call_args.args != (Path("/smoke/generated.xcresult"),)
                or exit_code
                and (
                    cleanup.get("resultBundle") != "/smoke/test-results.xcresult"
                    or cleanup.get("testFailures") != summary["testFailures"]
                )
            ):
                findings.append("Mac 恢复自测：保留业务结果包与清理失败诊断")
    return findings
