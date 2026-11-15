#!/usr/bin/env python3
"""Validate normal App readiness and its live process after installation."""

import re
import json
import plistlib
import uuid
from validation_environment import input_identity_complete
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit
from validation_provenance import sampling_evidence_current
from restore_diagnostics import simulator_startup_diagnostics, mac_app_pids, mac_app_session

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / "build/DeviceInstall/restore-readiness.json"
PROCESS = ROOT / "build/DeviceInstall/restore-process.json"


def invalidate() -> None:
    from validation_provenance import REPORT, report_lock, write_report

    with report_lock():
        if not REPORT.is_file():
            return
        report = json.loads(REPORT.read_text())
        report.get("groups", {}).pop("restore", None)
        for key in ("mergeCommit", "releaseCommit"):
            report.pop(key, None)
        write_report(report)


def valid_identity(proof: dict) -> bool:
    try:
        return str(uuid.UUID(proof["runID"])).lower() == proof[
            "runID"
        ].lower() and input_identity_complete(proof["inputDigest"])
    except (ValueError, TypeError, KeyError, AttributeError):
        return False


def complete(proof: dict) -> bool:
    return (
        proof.get("kind") == "restore"
        and proof.get("initialized") is True
        and proof.get("sessionRecovered") is True
        and proof.get("active") is True
        and proof.get("processAlive") is True
        and type(proof.get("processIdentifier")) is int
        and proof["processIdentifier"] > 0
        and valid_identity(proof)
        and sampling_evidence_current(proof)
    )


def matches_app(proof: dict, info: dict, run_id: str, digest: str) -> bool:
    return (
        proof.get("schemaVersion") == 1
        and proof.get("runID") == run_id
        and proof.get("inputDigest") == digest == info.get("BIT101RestoreInputDigest")
        and all(
            proof.get(key) == info.get(field)
            for key, field in [
                ("bundleIdentifier", "CFBundleIdentifier"),
                ("version", "CFBundleShortVersionString"),
                ("build", "CFBundleVersion"),
            ]
        )
    )


def executable_path(value) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    parsed = urlsplit(value)
    if parsed.scheme and (parsed.scheme != "file" or parsed.netloc not in {"", "localhost"}):
        return None
    path = unquote(parsed.path)
    if not path.startswith("/"):
        return None
    if path.startswith("/var/"):
        path = "/private" + path
    return path


def owned_process_alive(proof: dict, processes: list[dict]) -> bool:
    expected = executable_path(proof.get("executablePath"))
    return expected is not None and any(
        row.get("processIdentifier") == proof.get("processIdentifier")
        and executable_path(row.get("executable")) == expected
        for row in processes
    )


def summary(run_id: str, digest: str) -> dict:
    proof = json.loads(PROOF.read_text())
    processes = json.loads(PROCESS.read_text())["result"]["runningProcesses"]
    info_path = (
        ROOT / "build/DeviceInstall/Build/Products/Release-iphoneos/BIT101-iOS.app/Info.plist"
    )
    info = plistlib.loads(info_path.read_bytes())
    proof = dict(
        proof,
        kind="restore",
        startedAt=proof.get("readyAt"),
        finishedAt=proof.get("readyAt"),
        processAlive=owned_process_alive(proof, processes),
    )
    proof["identityMatches"] = matches_app(proof, info, run_id, digest)
    proof["passed"] = complete(proof) and proof["identityMatches"]
    return proof


def readiness_diagnostic(proof: dict) -> None:
    import sys

    state = dict(
        App身份=proof.get("identityMatches"),
        就绪身份=valid_identity(proof),
        初始化=proof.get("initialized"),
        会话恢复=proof.get("sessionRecovered"),
        活跃=proof.get("active"),
        进程存活=proof.get("processAlive"),
        进程编号=proof.get("processIdentifier"),
        采样有效=sampling_evidence_current(proof),
    )
    print("App 就绪状态：" + json.dumps(state, ensure_ascii=False), file=sys.stderr)


def mac_ready(
    app: Path, proof_path: Path, run_id: str, digest: str, *, diagnose: bool = False
) -> bool:
    proof = json.loads(proof_path.read_text())
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    process = subprocess.run(
        ["/bin/ps", "-p", str(proof["processIdentifier"]), "-o", "comm="],
        capture_output=True,
        text=True,
        check=False,
    )
    proof = dict(
        proof,
        kind="restore",
        startedAt=proof.get("readyAt"),
        finishedAt=proof.get("readyAt"),
        processAlive=process.returncode == 0
        and process.stdout.strip() == str(app / "Contents/MacOS/BIT101-iOS"),
    )
    proof["identityMatches"] = matches_app(proof, info, run_id, digest)
    passed = complete(proof) and proof["identityMatches"]
    if diagnose and not passed:
        readiness_diagnostic(proof)
    return passed


def verify_simulator() -> int:
    import os
    import time

    environment = dict(
        os.environ,
        BIT101_VALIDATION_RESULT_BATCH_HELD="1",
    )
    started = float(environment.get("BIT101_WORKFLOW_STARTED_AT", time.monotonic()))

    def run(*arguments, extra_env=None):
        run_env = dict(environment, **(extra_env or {}))
        return subprocess.run(arguments, cwd=ROOT, env=run_env).returncode

    status = run("Scripts/run-static-audit.sh", "prepare")
    audit = None
    completed = []
    try:
        if status == 0:
            status = run("Scripts/run-extended-tests.sh", "simulator", "prepare")
        if status == 0:
            audit = subprocess.Popen(
                ["Scripts/run-static-audit.sh"],
                cwd=ROOT,
                env=dict(
                    environment, BIT101_AUDIT_BACKGROUND="1", BIT101_AUDIT_ARTIFACTS_PREPARED="1"
                ),
            )
            status = run("Scripts/run-extended-tests.sh", "modules")
        for operation, group in [
            ("app", "all"),
            ("ui", "ui"),
        ]:
            if status:
                break
            status = run(
                "python3",
                "-B",
                "Scripts/validation_performance.py",
                "begin-batch",
                "append" if completed else "first",
            )
            if status:
                break
            extra_env = {"BIT101_REUSE_UI_HOST": "1"} if operation == "ui" and completed else None
            status = run(
                "Scripts/run-extended-tests.sh", "simulator", operation, extra_env=extra_env
            )
            completed.append(group)
            retained = run(
                "python3", "-B", "Scripts/validation_performance.py", "retain-batch", *completed
            )
            status = status or retained
    finally:
        if audit is not None:
            audited = audit.wait()
            status = status or audited
        print(
            f"[完整验证总耗时] {time.monotonic() - started:.1f} 秒（含等待、编译、测试及汇总）",
            flush=True,
        )
    return status


def simulator_verification_self_test() -> None:
    import os
    from contextlib import redirect_stdout
    from io import StringIO
    from types import SimpleNamespace
    from unittest.mock import patch

    failures = [
        None,
        ("Scripts/run-static-audit.sh", "prepare"),
        ("Scripts/run-extended-tests.sh", "simulator", "prepare"),
        ("Scripts/run-extended-tests.sh", "modules"),
        *[
            ("Scripts/run-extended-tests.sh", "simulator", mode)
            for mode in ("app", "ui")
        ],
        ("python3", "-B", "Scripts/validation_performance.py", "begin-batch", "append"),
        ("python3", "-B", "Scripts/validation_performance.py", "retain-batch", "all"),
        "audit",
    ]
    for failure in failures:
        events = []

        def run(arguments, **kwargs):
            events.append(tuple(arguments))
            assert kwargs["env"]["BIT101_VALIDATION_RESULT_BATCH_HELD"] == "1"
            if tuple(arguments) == ("Scripts/run-extended-tests.sh", "simulator", "ui"):
                assert kwargs["env"]["BIT101_REUSE_UI_HOST"] == "1"
            return SimpleNamespace(returncode=7 if tuple(arguments) == failure else 0)

        def launch(arguments, **kwargs):
            label = "audit"
            events.append(label)
            if label == "audit":
                assert kwargs["env"]["BIT101_AUDIT_ARTIFACTS_PREPARED"] == "1"

            def wait():
                events.append(("wait", label))
                return 7 if label == failure else 0

            return SimpleNamespace(wait=wait)

        with (
            patch.dict(os.environ, BIT101_WORKFLOW_STARTED_AT="100"),
            patch.object(subprocess, "run", side_effect=run),
            patch.object(subprocess, "Popen", side_effect=launch),
            patch("time.monotonic", return_value=117),
            redirect_stdout(output := StringIO()),
        ):
            assert verify_simulator() == (7 if failure else 0), failure
        assert "17.0 秒" in output.getvalue()
        if failure is None:
            native = [
                row[-1]
                for row in events
                if isinstance(row, tuple)
                and row[:2] == ("Scripts/run-extended-tests.sh", "simulator")
            ]
            assert native == ["prepare", "app", "ui"]


def simulator_restore_findings(simulator_source: str) -> list[str]:
    findings = simulator_startup_findings(simulator_source)
    simulator_verification_self_test()
    exit_hook = (
        "restore_on_exit() {"
        + simulator_source.split("restore_on_exit() {", 1)[1].split("\nmode=all", 1)[0]
    )
    for original, retain_status in ((0, 0), (7, 0), (0, 9), (7, 9)):
        harness = (
            "ROOT_DIR=/fixture\nretained_result_groups=(all)\n"
            f'python3() {{ print -r -- "RETAIN $*"; return {retain_status}; }}\n'
        )
        result = subprocess.run(
            ["zsh", "-c", harness + exit_hook + f"\ntrap restore_on_exit EXIT\nexit {original}"],
            capture_output=True,
            text=True,
        )
        if result.returncode != (retain_status or original) or "RETAIN" not in result.stdout:
            findings.append("模拟器退出自测：退出钩子汇总已保留证据并传播失败状态")
    return findings


def run_simulator_device_program(device_program: str) -> None:
    try:
        exec(compile(device_program, "<simulator-device>", "exec"), {})
    except SystemExit as error:
        if error.code not in (None, 0):
            raise


def verify_simulator_startup_case(
    harness: str,
    body: str,
    hosted: str,
    operation: str,
    build_status: int,
    ready_status: int,
    findings: list[str],
) -> None:
    result = subprocess.run(
        [
            "zsh",
            "-c",
            harness + body + "\nbit101_prepare_simulator_test_host\nprint COMPLETE",
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    prepares = hosted == "true" or operation == "ui"
    expected_ready = ready_status if prepares else 0
    expected = build_status or expected_ready
    rows = result.stdout.splitlines()
    complete = (
        result.returncode == expected
        and "BUILD" in rows
        and ("PREPARE" in rows) == prepares
        and ("COMPLETE" in rows) == (expected == 0)
    )
    app_ready = hosted == "true" and operation == "ui" and expected == 0
    complete = complete and ("APPREADY" in rows) == app_ready
    if complete and app_ready:
        complete = rows.index("APPREADY") > max(rows.index("BUILD"), rows.index("PREPARE"))
    if not complete:
        findings.append("模拟器启动自测：两项完成后初始化 App，失败状态汇总后结束")


def simulator_startup_findings(source: str) -> list[str]:
    import os
    import sys
    from contextlib import redirect_stdout
    from io import StringIO
    from unittest.mock import patch
    from script_test_support import heredoc_body, shell_function

    support = ROOT / "Scripts/script-support.sh"
    try:
        programs = {
            marker: heredoc_body(source if marker == "PYDEVICE" else support.read_text(), marker)
            for marker in ("PYDEVICE", "PYREADY", "PYAPPREADY")
        }
    except ValueError:
        return ["模拟器启动自测：设备、系统与 App 初始化入口应提供完整脚本正文。"]
    device_program = programs["PYDEVICE"]
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27"
    findings = simulator_operation_startup_findings(device_program, runtime)
    stock = {
        "runtimes": [
            {
                "isAvailable": True,
                "identifier": runtime,
                "version": "27.0",
                "supportedDeviceTypes": [{"name": "iPhone 17 Pro", "identifier": "phone"}],
            }
        ],
        "devices": {
            runtime: [
                {
                    "udid": "shutdown",
                    "name": "iPhone 17 Pro",
                    "isAvailable": True,
                    "state": "Shutdown",
                    "deviceTypeIdentifier": "phone",
                },
                {
                    "udid": "booted",
                    "name": "iPhone 17 Pro",
                    "isAvailable": True,
                    "state": "Booted",
                    "deviceTypeIdentifier": "phone",
                },
            ]
        },
    }
    for hosted in ("true", "false"):

        def command_output(command, **kwargs):
            return json.dumps(stock) if command[2] == "list" else "created"

        with (
            patch.dict(
                os.environ,
                GITHUB_ACTIONS=hosted,
                DEVELOPER_DIR="/fixture/Xcode.app/Contents/Developer",
            ),
            patch.object(sys, "argv", ["device", "/fixture/device.json", "prepare"]),
            patch.object(Path, "is_file", return_value=False),
            patch.object(Path, "write_text") as saved,
            patch.object(subprocess, "check_output", side_effect=command_output) as executed,
            patch.object(subprocess, "run") as prepared,
            redirect_stdout(StringIO()),
        ):
            exec(compile(device_program, "<simulator-stock-device>", "exec"), {})
        if (
            json.loads(saved.call_args.args[0])["identifier"] != "booted"
            or executed.call_count != 1
        ):
            findings.append("模拟器选择自测：本机与托管环境沿运行时和设备类型复用已启动库存设备")
        if hosted == "true" and prepared.call_count:
            findings.append("模拟器选择自测：已启动库存设备保持运行")
    for hosted, operation in (
        ("true", "app"),
        ("true", "ui"),
        ("false", "ui"),
    ):
        with (
            patch.object(
                sys,
                "argv",
                ["ready", str(ROOT / "Scripts"), "device", "/fixture", operation, hosted],
            ),
            patch("validation_coverage.prepare_simulator_system") as system,
            patch("validation_coverage.prepare_simulator_photos") as photos,
        ):
            exec(compile(programs["PYREADY"], "<simulator-ready>", "exec"), {})
        prepared = system if hosted == "true" else photos
        if (
            prepared.call_count != 1
            or prepared.call_args.args != ("device", Path("/fixture"))
            or prepared.call_args.kwargs != ({"ui": operation == "ui"} if hosted == "true" else {})
            or (photos if hosted == "true" else system).called
        ):
            findings.append("模拟器启动自测：托管环境准备系统，本地 UI 准备选图样本")
    with (
        patch.object(
            sys, "argv", ["app-ready", str(ROOT / "Scripts"), "device", "/fixture/Build/Products"]
        ),
        patch("validation_coverage.prepare_simulator_ui") as prepared,
    ):
        exec(compile(programs["PYAPPREADY"], "<simulator-app-ready>", "exec"), {})
    if prepared.call_count != 1 or prepared.call_args.args != (
        "device",
        Path("/fixture/Build/Products"),
    ):
        findings.append("模拟器启动自测：UI 初始化使用已编译的测试宿主")
    logical_source = re.sub(r"[ \t]*\\\n[ \t]*", " ", source)
    permissions = re.search(
        r'chmod\s+\+x\s+"\$ROOT_DIR/\.build/compiler-cache/swift-syntax-indexer"',
        logical_source,
    )
    if permissions is None or permissions.start() > logical_source.find("selection_started="):
        findings.append("共享宿主自测：库存规划前恢复下载工具的执行权限")
    body = shell_function(support, "bit101_prepare_simulator_test_host")
    log_root = ROOT / ".build/static-audit/simulator-startup-self-test"
    log_root.mkdir(parents=True, exist_ok=True)
    try:
        for hosted in ("true", "false"):
            for operation in ("app", "ui"):
                for build_status, ready_status in ((0, 0), (7, 0), (0, 9), (7, 9)):
                    harness = (
                        f'set -euo pipefail\n    exec 3>&1\n    ROOT_DIR=/fixture DERIVED_ROOT="'
                        f"{log_root}"
                        f'" SIMULATOR_DEVICE=device mode='
                        f"{operation}"
                        f" scheme=scheme configuration=Debug destination=target conditions= GI"
                        f"THUB_ACTIONS="
                        f"{hosted}"
                        f" BIT101_REUSE_UI_HOST=0\n    only_testing=()\n    bit101_run_logged() "
                        f'{{ if [[ "$3" == python3 ]]; then cat >/dev/null; print PREPARE; return'
                        f" "
                        f"{ready_status}"
                        f'; else print BUILD; [[ " $* " == *" ONLY_ACTIVE_ARCH=YES "* ]] || retu'
                        f"rn 64; return "
                        f"{build_status}"
                        f"; fi; }}\n    python3() {{ cat >/dev/null; print -u3 APPREADY; }}\n    "
                    )
                    verify_simulator_startup_case(
                        harness, body, hosted, operation, build_status, ready_status, findings
                    )
        for hosted in ("true", "false"):
            for ready_status in (0, 9):
                harness = (
                    f'set -euo pipefail\n    exec 3>&1\n    ROOT_DIR=/fixture DERIVED_ROOT="'
                    f"{log_root}"
                    f'" SIMULATOR_DEVICE=device mode=ui GITHUB_ACTIONS='
                    f"{hosted}"
                    f" BIT101_REUSE_UI_HOST=1\n    bit101_run_logged() {{ cat >/dev/null; print P"
                    f"REPARE; return "
                    f"{ready_status}"
                    f'; }}\n    python3() {{ cat >/dev/null; if [[ "$3" == device ]]; then print -'
                    f"u3 APPREADY; else print -u3 PERMISSIONS; fi; }}\n    "
                )
                result = subprocess.run(
                    [
                        "zsh",
                        "-c",
                        harness + body + "\nbit101_prepare_simulator_test_host\nprint COMPLETE",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                rows = result.stdout.splitlines()
                expected = ready_status
                complete = (
                    result.returncode == expected
                    and "PERMISSIONS" in rows
                    and "PREPARE" in rows
                    and ("COMPLETE" in rows) == (expected == 0)
                    and ("APPREADY" in rows) == (hosted == "true" and expected == 0)
                )
                if complete and "APPREADY" in rows:
                    complete = rows.index("APPREADY") > max(
                        rows.index("PREPARE"), rows.index("PERMISSIONS")
                    )
                if not complete:
                    findings.append("共享宿主自测：恢复执行权限，汇总系统就绪状态后执行 App 初始化")
    finally:
        import shutil

        shutil.rmtree(log_root)
    return findings


def self_test() -> None:
    from validation_provenance import utc_now

    row = dict(
        kind="restore",
        initialized=True,
        sessionRecovered=True,
        active=True,
        processAlive=True,
        processIdentifier=1,
        runID="00000000-0000-4000-8000-000000000001",
        inputDigest="a" * 64,
        startedAt=utc_now().isoformat(),
        finishedAt=utc_now().isoformat(),
    )
    assert complete(row)
    for key, value in [
        ("sessionRecovered", False),
        ("initialized", False),
        ("active", False),
        ("processAlive", False),
        ("processIdentifier", 0),
        ("runID", ""),
        ("inputDigest", ""),
        ("startedAt", "2000-01-01T00:00:00+00:00"),
    ]:
        assert not complete(dict(row, **{key: value}))
    from unittest.mock import patch

    ready = dict(
        row,
        schemaVersion=1,
        readyAt=utc_now().isoformat(),
        bundleIdentifier="app",
        version="1",
        build="1",
        executablePath=(
            "/private/var/containers/Bundle/Application/fixture/BIT101-iOS.app/BIT101-iOS"
        ),
    )
    info = dict(
        CFBundleIdentifier="app",
        CFBundleShortVersionString="1",
        CFBundleVersion="1",
        BIT101RestoreInputDigest="a" * 64,
    )
    app = Path("/Applications/BIT101-iOS.app")
    from types import SimpleNamespace

    with (
        patch.object(Path, "read_text", return_value=json.dumps(ready)),
        patch.object(Path, "read_bytes", return_value=plistlib.dumps(info)),
        patch.object(
            subprocess,
            "run",
            return_value=SimpleNamespace(
                returncode=0, stdout=str(app / "Contents/MacOS/BIT101-iOS") + "\n"
            ),
        ) as process,
    ):
        assert mac_ready(app, PROOF, ready["runID"], "a" * 64)
        assert not mac_ready(app, PROOF, ready["runID"], "b" * 64)
        process.return_value.returncode = 1
        assert not mac_ready(app, PROOF, ready["runID"], "a" * 64)
        process.return_value.returncode = 0
        process.return_value.stdout = "/Applications/Other.app/Contents/MacOS/Other"
        assert not mac_ready(app, PROOF, ready["runID"], "a" * 64)

    def contents(path):
        return json.dumps(
            ready
            if path == PROOF
            else {
                "result": {
                    "runningProcesses": [
                        {"processIdentifier": 1, "executable": ready["executablePath"]}
                    ]
                }
            }
        )

    with (
        patch.object(Path, "read_text", contents),
        patch.object(Path, "read_bytes", return_value=plistlib.dumps(info)),
    ):
        assert summary(ready["runID"], "a" * 64)["passed"]
        assert not summary(str(uuid.uuid4()), "a" * 64)["passed"]
        assert not summary(ready["runID"], "b" * 64)["passed"]
        ready["processIdentifier"] = 2
        assert not summary(ready["runID"], "a" * 64)["passed"]
    for executable in ["/usr/libexec/unrelated-process", None, "", "https://example.invalid/App"]:
        assert not owned_process_alive(
            ready, [dict(processIdentifier=ready["processIdentifier"], executable=executable)]
        )
    assert owned_process_alive(
        ready,
        [
            dict(
                processIdentifier=ready["processIdentifier"],
                executable="file://" + ready["executablePath"],
            )
        ],
    )
    assert owned_process_alive(
        ready,
        [
            dict(
                processIdentifier=ready["processIdentifier"],
                executable=ready["executablePath"].removeprefix("/private"),
            )
        ],
    )
    from contextlib import nullcontext
    import validation_provenance

    retained = {
        "sourceDigest": "source",
        "mergeCommit": "commit",
        "releaseCommit": "commit",
        "groups": {"restore": {"summary": ready, "lastFullRun": row}, "all": {"runID": "test"}},
    }
    with (
        patch.object(validation_provenance, "report_lock", side_effect=nullcontext),
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_text", side_effect=lambda *_: json.dumps(retained)),
        patch.object(
            validation_provenance,
            "write_report",
            side_effect=lambda report: retained.update(report),
        ) as saved,
    ):
        invalidate()
        current = saved.call_args.args[0]
        assert current == {"sourceDigest": "source", "groups": {"all": {"runID": "test"}}}
        retained = current
        invalidate()
        assert saved.call_args.args[0] == current
    with (
        patch.object(validation_provenance, "report_lock", side_effect=nullcontext),
        patch.object(Path, "is_file", return_value=False),
        patch.object(validation_provenance, "write_report") as saved,
    ):
        invalidate()
        saved.assert_not_called()


def simulator_operation_startup_findings(device_program, runtime):
    from io import StringIO
    import os
    from unittest.mock import patch
    from contextlib import redirect_stdout
    import sys

    inventory = {
        "runtimes": [
            {
                "isAvailable": True,
                "identifier": runtime,
                "version": "27.0",
                "supportedDeviceTypes": [{"name": "iPhone 17 Pro", "identifier": "phone"}],
            }
        ],
        "devices": {
            runtime: [
                {
                    "udid": "device",
                    "isAvailable": True,
                    "state": "Shutdown",
                    "deviceTypeIdentifier": "phone",
                }
            ]
        },
    }
    findings = []
    for hosted in ("true", "false"):
        operations = (
            ("prepare", "build-ui", "app", "ui")
            if hosted == "true"
            else ("prepare", "build-ui", "app", "ui", "preview")
        )
        for operation in operations:
            commands = []
            with (
                patch.dict(
                    os.environ,
                    GITHUB_ACTIONS=hosted,
                    DEVELOPER_DIR="/fixture/Xcode.app/Contents/Developer",
                ),
                patch.object(sys, "argv", ["device", "/fixture/device.json", operation]),
                patch.object(subprocess, "check_output", return_value=json.dumps(inventory)),
                patch.object(
                    subprocess,
                    "run",
                    side_effect=lambda command, **kwargs: commands.append(command),
                ),
                patch.object(Path, "is_file", return_value=True),
                patch.object(
                    Path,
                    "read_text",
                    return_value=json.dumps({"identifier": "device", "runtime": runtime}),
                ),
                redirect_stdout(StringIO()),
            ):
                run_simulator_device_program(device_program)
            boot_hosted = hosted == "true" and operation == "prepare"
            expected = [["xcrun", "simctl", "boot", "device"]] if boot_hosted else []
            if hosted == "false" and operation != "build-ui":
                hub = "/fixture/Xcode.app/Contents/Applications/DeviceHub.app"
                expected = [
                    ["xcrun", "simctl", "boot", "device"],
                    ["xcrun", "simctl", "bootstatus", "device", "-b"],
                ] + ([["open", "-a", hub]] if operation == "preview" else [])
            if commands != expected:
                findings.append(
                    "模拟器启动自测：托管准备请求启动，完整系统与本机初始化沿实际执行核对"
                )
    return findings


if __name__ == "__main__":
    import sys

    try:
        if sys.argv[1:] == ["simulator-verify"]:
            sys.exit(verify_simulator())
        if sys.argv[1:] == ["invalidate"]:
            invalidate()
            sys.exit(0)
        if sys.argv[1:2] in (["mac-pause"], ["mac-resume"]):
            mac_app_session(*sys.argv[1:])
            sys.exit(0)
        if sys.argv[1:2] == ["mac-pids"]:
            sys.stdout.write("".join(f"{pid}\n" for pid in mac_app_pids(Path(sys.argv[2]))))
            sys.exit(0)
        if sys.argv[1:2] == ["mac-ready"]:
            sys.exit(
                0
                if mac_ready(Path(sys.argv[2]), Path(sys.argv[3]), *sys.argv[4:], diagnose=True)
                else 1
            )
        result = summary(*sys.argv[1:])
        if not result["passed"]:
            readiness_diagnostic(result)
        sys.exit(0 if result["passed"] else 1)
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        RuntimeError,
        subprocess.SubprocessError,
    ) as error:
        print(f"App 就绪采样失败：{type(error).__name__}：{error}", file=sys.stderr)
        sys.exit(1)
