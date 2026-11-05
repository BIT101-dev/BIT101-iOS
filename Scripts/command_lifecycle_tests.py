"""Focused workflow and source checks."""

import os
import json
import re
import shutil
import signal
import shlex
import subprocess
import sys
from contextlib import redirect_stdout
from io import StringIO
from itertools import product
from unittest.mock import Mock, patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_ROOT = ROOT / "Scripts"


def test_build_argument_findings(output: str, *, testing_device: bool = False) -> list[str]:
    findings = []
    for line in output.splitlines():
        if not line.startswith("ARGUMENTS "):
            continue
        arguments = shlex.split(line)[3:]
        if arguments[:1] == ["xcodebuild"]:
            required = (
                "-enableCodeCoverage YES",
                "ENABLE_CODE_COVERAGE=YES",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
                "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
                "-configuration Release",
            )
            if testing_device:
                required += ("ONLY_ACTIVE_ARCH=YES",)
        elif arguments[:2] == ["xcrun", "swift"]:
            required = ("--configuration release",)
            if "test" in arguments:
                required += ("--enable-code-coverage",)
        else:
            continue
        for option in required:
            tokens = shlex.split(option)
            if not any(
                arguments[index : index + len(tokens)] == tokens for index in range(len(arguments))
            ):
                findings.append(f"测试命令参数需要实际传入：{option}")
    return findings


def result_retention_boundary_findings() -> list[str]:
    "聚合验收保留各组结果，并传播准备、测试及合并的失败。"
    source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    from script_test_support import shell_function

    step = (
        shell_function(SCRIPT_ROOT / "script-support.sh", "bit101_check_verification_audit")
        + "\n"
        + shell_function(SCRIPT_ROOT / "script-support.sh", "bit101_verify_step")
    )
    findings = []
    for retained, statuses in product(
        ("", "catalyst"), ((0, 0, 0), (7, 0, 0), (0, 9, 0), (0, 0, 5))
    ):
        child_status, retain_status, begin_status = statuses
        harness = f"""set -euo pipefail
ROOT_DIR=/fixture
completed_result_groups=()
child() {{ print -r -- "CHILD $*"; return {child_status}; }}
python3() {{
  print -ru2 -- "PY $*"
  if [[ "$2" == begin-full ]]; then print -r -- '{retained}'; return {begin_status}; fi
  if [[ "$2" == retain-batch ]]; then return {retain_status}; fi
  return 0
}}
"""
        result = subprocess.run(
            [
                "zsh",
                "-c",
                harness
                + step
                + "\nbit101_verify_step all child all\nbit101_verify_step ui child ui",
            ],
            text=True,
            capture_output=True,
        )
        expected = begin_status or int(bool(child_status or retain_status))
        output = result.stdout + result.stderr
        groups = f"{retained} all".strip()
        if result.returncode != expected or "begin-full all" not in output:
            findings.append("结果保留自测：准备与执行失败沿聚合流程传播")
        if begin_status:
            if "CHILD" in output:
                findings.append("结果保留自测：准备成功后执行测试")
        elif f"retain-batch {groups}" not in output:
            findings.append("结果保留自测：测试成功与失败均保留实际结果")
        if expected == 0 and (
            "begin-batch append" not in output or f"retain-batch {groups} ui" not in output
        ):
            findings.append("结果保留自测：后续测试组合并本次全部结果")
    for current in (True, False):
        harness = f"""set -euo pipefail
ROOT_DIR=/fixture
completed_result_groups=()
checks=0
python3() {{ (( checks += 1 )); [[ $checks -gt 1 ]] || return {0 if current else 1}; }}
child() {{ print executed; }}
"""
        result = subprocess.run(
            [
                "zsh",
                "-c",
                harness + step + "\nbit101_verify_step modules child\nprint checks=$checks",
            ],
            text=True,
            capture_output=True,
        )
        if (
            result.returncode
            or ("executed\n" in result.stdout) == current
            or f"checks={1 if current else 2}" not in result.stdout
        ):
            findings.append("模块聚合复验：当前完整证据复用，缺失与过期证据执行后验收")
    finish = (
        "finish_validation() {"
        + source.split("finish_validation() {", 1)[1].split("\ntrap finish_validation", 1)[0]
    )
    for test_status, merge_status in ((0, 0), (7, 0), (0, 9), (7, 9)):
        harness = (
            f"ROOT_DIR=/fixture DERIVED_ROOT=/fixture validation_group=all validation_scope=sele"
            f"cted\nBUILD_ONLY=false WORKFLOW_STARTED_SECONDS=$SECONDS\nretained_result_groups=("
            f'all ui)\npython3() {{ print -r -- "PY $*"; [[ "$2" != retain-selected ]] || return '
            f"{merge_status}"
            f"; }}\n"
        )
        result = subprocess.run(
            ["zsh", "-c", harness + finish + f"\ntrap finish_validation EXIT\nexit {test_status}"],
            capture_output=True,
            text=True,
        )
        if (
            result.returncode != (merge_status or test_status)
            or "retain-selected all all ui" not in result.stdout
        ):
            findings.append("定向结果保留自测：退出钩子合并有效证据并传播失败")
    return findings


def run_install_program(program: str, expect_failure: bool) -> None:
    try:
        exec(compile(program, "<mac-app-install>", "exec"), {})
    except OSError:
        if not expect_failure:
            raise


def restore_installation_boundary_findings() -> list[str]:
    "安装前清理旧恢复证据，清理失败沿真实安装分支传播。"
    import shlex

    support = shlex.quote(str(SCRIPT_ROOT / "script-support.sh"))
    prefix = f"set -euo pipefail\nROOT_DIR={shlex.quote(str(ROOT))}\nsource {support}\n"
    prefix += (
        "rm() { :; }\nxcrun() { if [[ \"$*\" == 'simctl get_app_container '* ]]; then print /fixtu"
        "re; else print -ru2 INSTALL; fi; }\nbit101_run_logged() { print EXECUTE; }\nrecord_result"
        "() { print RESULT; }\nDERIVED_ROOT=/fixture DERIVED_DATA=/fixture RESULT_BUNDLE=/fixture/"
        "result\nDEVICETCL_DEVICE_ID=phone BIT101_DEVICETCL_DEVICE_ID=phone DEVICE_ID=phone TEST_C"
        "LASS=fixture\nSMOKE_PLATFORM=iphoneos SIMULATOR_DEVICE= APP_BUNDLE_ID=app APP_GROUP_ID=gr"
        "oup\ncommon_args=()\n"
    )
    native = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    native = re.sub(r"\\\n[ \t]*", "", native)
    start = (
        '  if [[ "$BUILD_ONLY" == false && "$MODE" != catalyst && "$MODE" != catalyst-release-runt'
        "ime ]]; then"
    )
    native = start + native.split(start, 1)[1].split("  TEST_DURATION_SECONDS=", 1)[0]
    native = (
        (
            "group=fixture log=/fixture test_action=test diagnostics=never conditions= TEST_DESTIN"
            "ATION=phone\nexecution_args=() only_testing=() SIGNING_ARGS=() coverage_args=() proje"
            "ct_args=()\nexecute_test() {\n"
        )
        + native
        + "\n}\nexecute_test\n"
    )
    network = (SCRIPT_ROOT / "release-network-smoke.sh").read_text()
    network = (
        "SMOKE_APP_PATH="
        + network.split("\nSMOKE_APP_PATH=", 1)[1].split('\npython3 - "$LOCAL_REQUEST_PATH"', 1)[0]
    )
    install = (SCRIPT_ROOT / "build-install-device.sh").read_text()
    install = (
        "APP_PATH="
        + install.split("\nAPP_PATH=", 1)[1].split("\nxcrun devicectl device process launch", 1)[0]
    )
    cloud = (SCRIPT_ROOT / "icloud-smoke-support.sh").read_text()
    cloud = (
        "run_phone_test() {"
        + cloud.split("run_phone_test() {", 1)[1].split("\nrun_mac_cleanup()", 1)[0]
    )
    cases = [
        (
            native,
            f"MODE={mode} BUILD_ONLY={build}\n",
            status,
            status if mode in {"all", "ui"} and build == "false" else 0,
            ["CLEAR"]
            if status and mode in {"all", "ui"} and build == "false"
            else ["CLEAR", "EXECUTE"]
            if mode in {"all", "ui"} and build == "false"
            else ["EXECUTE"],
        )
        for mode, build, status in [
            ("all", "false", 0),
            ("ui", "false", 0),
            ("all", "false", 13),
            ("ui", "false", 13),
            ("catalyst", "false", 13),
            ("catalyst-release-runtime", "false", 13),
            ("all", "true", 13),
        ]
    ]
    cases += [
        (program, "", status, status, ["CLEAR"] if status else ["CLEAR", "INSTALL"])
        for program in (network, install)
        for status in (0, 13)
    ]
    cases += [
        (
            network,
            "SMOKE_PLATFORM=iphonesimulator SIMULATOR_DEVICE=fixture\n",
            status,
            status,
            ["CLEAR"] if status else ["CLEAR", "INSTALL"],
        )
        for status in (0, 13)
    ]
    cases += [
        (
            cloud + f"\nrun_phone_test {method}\n",
            "",
            status,
            status,
            ["CLEAR"] if status else ["CLEAR", "EXECUTE", "RESULT"],
        )
        for method in ("testPhoneRoundTrip", "testCleanup")
        for status in (0, 13)
    ]
    findings = []
    for program, context, invalidation, expected, events in cases:
        stub = f"python3() {{ print CLEAR; return {invalidation}; }}\n"
        result = subprocess.run(
            ["zsh", "-c", prefix + stub + context + program],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=5,
        )
        observed = [
            line
            for line in result.stdout.splitlines()
            if line in {"CLEAR", "INSTALL", "EXECUTE", "RESULT"}
        ]
        if result.returncode != expected or observed != events:
            findings.append(
                (
                    f"安装恢复生命周期自测："
                    f"{context.strip()}"
                    f" "
                    f"{expected}"
                    f"，实际 "
                    f"{result.returncode}"
                    f" "
                    f"{result.stdout.strip()}"
                )
            )
    from script_test_support import heredoc_body

    program = heredoc_body((SCRIPT_ROOT / "script-support.sh").read_text(), "PYMACINSTALL")
    fixture = ROOT / ".build/static-audit/workflow-lock-self-test"
    try:
        for stage in ("copy-failure", "swap-failure", "replace", "first-install"):
            shutil.rmtree(fixture, ignore_errors=True)
            source, installed = fixture / "source.app", fixture / "installed.app"
            source.mkdir(parents=True)
            (source / "binary").write_text("new")
            if stage != "first-install":
                installed.mkdir()
                (installed / "binary").write_text("old")

            def copy(arguments, **kwargs):
                shutil.copytree(arguments[1], arguments[2])
                if stage == "copy-failure":
                    raise OSError("copy interrupted")

            library = (
                Mock(renamex_np=Mock(return_value=-1))
                if stage == "swap-failure"
                else __import__("ctypes").CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            )
            with (
                patch.object(sys, "argv", ["install", str(source), str(installed)]),
                patch.object(subprocess, "run", side_effect=copy),
                patch("ctypes.CDLL", return_value=library),
            ):
                run_install_program(program, stage.endswith("failure"))
            expected = "old" if stage.endswith("failure") else "new"
            assert (installed / "binary").read_text() == expected and not (
                fixture / ".BIT101-iOS.install.app"
            ).exists(), stage
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def audit_lock_boundary_findings() -> list[str]:
    "并发验收沿产物锁、审计锁顺序执行，并复用父流程锁。"
    import fcntl
    import select
    import shlex

    fixture = ROOT / ".build/static-audit/workflow-lock-self-test"
    worker = fixture / "worker.sh"
    processes, findings = [], []
    environment = dict(os.environ)
    for name in (
        "BIT101_EXTENDED_TESTS_LOCK_HELD",
        "BIT101_STATIC_AUDIT_LOCK_HELD",
        "BIT101_WORKFLOW_DEADLINE",
    ):
        environment.pop(name, None)
    source = (SCRIPT_ROOT / "run-static-audit.sh").read_text()
    parser = source[source.index("set -euo pipefail") : source.index("\nROOT_DIR=")]
    shell = "ROOT_DIR=" + source.split("ROOT_DIR=", 1)[1].split("LOG_DIR=", 1)[0]
    shell = re.sub(r"(?m)^ROOT_DIR=.*$", "ROOT_DIR=" + shlex.quote(str(fixture)), shell)
    shell = shell.replace(
        'source "$ROOT_DIR/Scripts/script-support.sh"',
        "source " + shlex.quote(str(SCRIPT_ROOT / "script-support.sh")),
    )
    manifest = (
        f"import ast, fcntl, os, runpy, sys\nfrom pathlib import Path\nfrom unittest.mock import"
        f" patch\nfrom types import SimpleNamespace\nsys.path.insert(0, "
        f"{str(SCRIPT_ROOT)!r}"
        f")\nimport code_quality_rules as quality\nquality.ROOT = Path("
        f"{str(fixture)!r}"
        f")\nrules = runpy.run_path("
        f"{str(SCRIPT_ROOT / 'check-module-boundaries.py')!r}"
        f")\noriginal = fcntl.flock\ndef observe(lock, operation):\n    if getattr(lock, 'name',"
        f" '').endswith('extended-automation.lock'):\n        print('artifact', flush=True)\n   "
        f" return original(lock, operation)\nfcntl.flock = observe\ndef manifest():\n    with pa"
        f"tch('subprocess.run', return_value=SimpleNamespace(returncode=0, stdout='{{}}')):\n     "
        f"   rules['read_manifest'](quality.ROOT)\nif sys.argv[1] == 'direct':\n    before = dic"
        f"t(os.environ)\n    try: exec(compile(ast.Module(body=[ast.parse(Path("
        f"{str(SCRIPT_ROOT / 'check-module-boundaries.py')!r}"
        f").read_text()).body[-1]], type_ignores=[]), '<module-entry>', 'exec'), dict(__name__='"
        f"__main__', main=manifest, ROOT=quality.ROOT))\n    except SystemExit as error: assert "
        f"error.code is None\n    assert dict(os.environ) == before\nelse: manifest()\nprint('en"
        f"tered', flush=True)\n"
    )
    command = shlex.quote(sys.executable) + " -B -c " + shlex.quote(manifest)
    try:
        shutil.rmtree(fixture, ignore_errors=True)
        fixture.mkdir(parents=True)
        (fixture / "Scripts").symlink_to(SCRIPT_ROOT, target_is_directory=True)
        (fixture / ".build/static-audit").mkdir(parents=True)
        worker.write_text(
            'if [[ "$1" == direct ]]; then exec '
            + command
            + " direct; fi\nshift\n"
            + parser
            + "\n"
            + shell
            + "\nif (( ${group_names[(Ie)module-boundary]} )); then "
            + command
            + " shell; else print entered; fi\n"
        )
        for mode in ("shell", "direct"):
            with (fixture / ".build/extended-automation.lock").open("a") as artifact:
                fcntl.flock(artifact, fcntl.LOCK_EX)
                standalone = subprocess.Popen(
                    ["zsh", str(worker), mode],
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                processes.append(standalone)
                if not select.select([standalone.stdout], [], [], 5)[0]:
                    raise ValueError("并发审计开始等待产物锁")
                progress = standalone.stdout.readline().strip()
                if progress != "artifact" and not progress.startswith("[等待]"):
                    raise ValueError(progress)
                with (fixture / ".build/static-audit/audit.lock").open("a") as audit:
                    fcntl.flock(audit, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(audit, fcntl.LOCK_UN)
                inherited = subprocess.run(
                    ["zsh", str(worker), "shell"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env=dict(environment, BIT101_EXTENDED_TESTS_LOCK_HELD="1"),
                )
                if inherited.returncode or inherited.stdout.strip() != "entered":
                    raise ValueError(inherited.stderr)
                focused = subprocess.run(
                    ["zsh", str(worker), "shell", "--self-test", "docs", "python-parse"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env=dict(environment, GITHUB_ACTIONS="false", BIT101_RELEASE_CHECK="false"),
                )
                if focused.returncode or focused.stdout.strip() != "entered":
                    raise ValueError(focused.stderr)
                fcntl.flock(artifact, fcntl.LOCK_UN)
            output, error = standalone.communicate(timeout=5)
            if standalone.returncode or output.strip() != "entered":
                raise ValueError(error)
        cache = (
            (SCRIPT_ROOT / "run-extended-tests.sh")
            .read_text()
            .split('if [[ "${1:-}" == performance', 1)[0]
        )
        cache = re.sub(r"(?m)^ROOT_DIR=.*$", "ROOT_DIR=" + shlex.quote(str(fixture)), cache)
        cache = cache.replace(
            'source "$ROOT_DIR/Scripts/script-support.sh"',
            "source " + shlex.quote(str(SCRIPT_ROOT / "script-support.sh")),
        )
        recovery = (
            'python3() {\n  if [[ "${1:-}" == */Scripts/validation_performance.py && "${2:-}" == r'
            'ecover-batch ]]; then return 0; fi\n  command python3 "$@"\n}\n'
        )
        worker.write_text(recovery + cache)
        diagnostics = fixture / ".build/extended-automation/diagnostics"
        (diagnostics / "test-results.xcresult").mkdir(parents=True)
        (diagnostics / "test-results.xcresult/Info.plist").write_text("retained")
        (diagnostics / "exported.log").write_text("temporary")
        with (fixture / ".build/extended-automation.lock").open("a") as artifact:
            fcntl.flock(artifact, fcntl.LOCK_EX)
            standalone = subprocess.Popen(
                ["zsh", str(worker), "cache"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            processes.append(standalone)
            if not select.select([standalone.stdout], [], [], 5)[0]:
                raise ValueError("缓存整理开始等待产物锁")
            if not standalone.stdout.readline().startswith("[等待]"):
                raise ValueError("缓存整理复用产物锁顺序")
            inherited = subprocess.Popen(
                ["zsh", str(worker), "cache"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
                env=dict(environment, BIT101_EXTENDED_TESTS_LOCK_HELD="1"),
            )
            processes.append(inherited)
            output, error = inherited.communicate(timeout=5)
            if inherited.returncode or "缓存整理：" not in output:
                raise ValueError(error)
            fcntl.flock(artifact, fcntl.LOCK_UN)
        output, error = standalone.communicate(timeout=5)
        if standalone.returncode or "缓存整理：" not in output:
            raise ValueError(error)
        assert (diagnostics / "test-results.xcresult/Info.plist").read_text() == "retained"
        assert not (diagnostics / "exported.log").exists()
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        findings.append(f"审计锁顺序自测：{error}")
    finally:
        for process in processes:
            if not (process.poll() is None):
                continue
            import signal

            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                process.terminate()
            process.communicate(timeout=5)
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def kill_worker_group(worker: int, worker_group: int) -> None:
    try:
        if os.getpgid(worker) == worker_group:
            os.killpg(worker_group, signal.SIGKILL)
    except ProcessLookupError:
        pass


def audit_cancellation_findings() -> list[str]:
    import os
    import select

    source = (SCRIPT_ROOT / "run-static-audit.sh").read_text()
    cleanup = (
        "finish_audit() {" + source.split("finish_audit() {", 1)[1].split("\nSWIFT_FRONTEND=", 1)[0]
    )
    from script_test_support import shell_function

    launcher = shell_function(SCRIPT_ROOT / "script-support.sh", "bit101_start_audit_group")
    runner = shell_function(SCRIPT_ROOT / "script-support.sh", "bit101_run_audit_group")
    fixture = ROOT / ".build/static-audit/audit-cancellation-self-test"
    shutil.rmtree(fixture, ignore_errors=True)
    fixture.mkdir(parents=True, exist_ok=True)
    (fixture / "Scripts").symlink_to(SCRIPT_ROOT, target_is_directory=True)
    harness = (
        "LOG_DIR="
        + shlex.quote(str(fixture))
        + (
            "\nexec 3>&1\nROOT_DIR=/fixture SWIFT_FRONTEND=frontend AUDIT_STARTED=$SECONDS group_p"
            'rocesses=() group_names=() full_audit=1\npython3() { if [[ "$1" == "$ROOT_DIR/Scripts'
            '/validation_evidence.py" ]]; then return 0; fi; command python3 "$@"; }\nbit101_show_'
            "audit_log() { :; }\nblocked_task() { python3 -c 'import os, time; print(os.getpid(), "
            "os.getpgrp(), flush=True); time.sleep(60)' >&3; }\n"
        )
    )
    harness = harness.replace("ROOT_DIR=/fixture", "ROOT_DIR=" + shlex.quote(str(fixture)))
    findings = []
    for signum, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
        process = subprocess.Popen(
            [
                "zsh",
                "-c",
                harness
                + cleanup
                + runner
                + launcher
                + '\nbit101_start_audit_group stdout blocked_task\nwait "$group_processes[1]"',
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        worker_group = None
        try:
            if not select.select([process.stdout], [], [], 5)[0]:
                raise ValueError("后台检查启动需要及时响应")
            worker, worker_group = map(int, process.stdout.readline().split())
            os.kill(process.pid, signum)
            _, error = process.communicate(timeout=5)
            assert process.returncode == expected, error
            from workflow_processes import active_members

            if worker in active_members({worker_group}):
                raise ValueError("中断完成后后台检查需要结束")
        except (ValueError, AssertionError, subprocess.TimeoutExpired) as error:
            reason = (
                "后台检查清理需要按测试预算完成"
                if isinstance(error, subprocess.TimeoutExpired)
                else str(error)
            )
            findings.append(f"审计中断自测：{reason}")
        finally:
            if worker_group is not None:
                kill_worker_group(worker, worker_group)
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
    shutil.rmtree(fixture)
    return findings


def check_build_argument_mutations(
    source: str, path: Path, arguments: list[str], environment: dict
) -> list[str]:
    mutations = []
    options = (
        ("--enable-code-coverage",)
        if arguments == ["modules"]
        else (
            "-enableCodeCoverage YES",
            "ENABLE_CODE_COVERAGE=YES",
            "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
            "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
        )
    )
    for option in options:
        changed = source.replace(option, "") + "\n# " + option + "\n"
        mutated = subprocess.run(
            ["zsh", "-c", changed, str(path), *arguments],
            env=environment,
            capture_output=True,
            text=True,
        )
        if not test_build_argument_findings(mutated.stdout):
            mutations.append(f"编译参数变异自测：注释中的 {option} 保留执行检查")
    return mutations


def ui_metrics_boundary_findings() -> list[str]:
    from test_results import record_native_metrics

    def inventory(process, key, pending=()):
        return {
            "processIdentifier": process,
            "scope": "mounted-controls",
            "identityScope": "testCaseNavigationPresentationAndOccurrence",
            "observedControls": [key, *pending],
            "disabledControls": [],
            "checkedDisabledControls": [],
            "unidentifiedInstances": [],
            "visitedControls": [
                {
                    "instance": key,
                    "identifier": key,
                    "scope": f"Journey{process}/testRun",
                    "actions": ["tap"],
                }
            ],
        }

    output = "\n".join(
        [
            "UI automation App process: 10",
            "UI control inventory: " + json.dumps(inventory(10, "first", ["pending"])),
            "UI automation App process: 20",
            "UI control inventory: " + json.dumps(inventory(20, "second")),
            (
                'UI query metrics: {"liveQueries":{"count":20,"seconds":0.5},"sharedSnapshots":{"c'
                'ount":2,"seconds":1.5}}'
            ),
            'UI query metrics: {"liveQueries":{"count":3,"seconds":0.2}}',
        ]
    )
    summary = {
        "result": "Passed",
        "totalTestCount": 2,
        "passedTests": 2,
        "failedTests": 0,
        "skippedTests": 0,
    }
    report = {}
    diagnostic = Path("/audit/diagnostics/StandardOutputAndStandardError.txt")
    original_read, original_open, original_rglob = Path.read_text, Path.open, Path.rglob

    def run(arguments, **kwargs):
        response = (
            summary
            if "summary" in arguments
            else {
                "targets": [
                    {
                        "name": "BIT101-iOS.app",
                        "lineCoverage": 0,
                        "coveredLines": 0,
                        "executableLines": 0,
                    }
                ]
            }
            if "xccov" in arguments
            else None
        )
        return subprocess.CompletedProcess(
            arguments, 0, json.dumps(response) if response is not None else "", ""
        )

    with (
        patch(("validation_result_readers.test_case_inventory"), return_value={}),
        patch(("validation_evidence.test_case_inventory"), return_value={}),
        patch.object(
            sys,
            "argv",
            [
                "metrics",
                "/audit/result.xcresult",
                "/audit/test-metrics.txt",
                "ui",
                "1",
                "device",
                str(ROOT),
            ],
        ),
        patch.object(subprocess, "run", side_effect=run),
        patch.object(
            subprocess,
            "check_output",
            return_value='{"devices":[{"platform":"iOS","deviceId":"device"}]}',
        ),
        patch.object(shutil, "rmtree"),
        patch.object(
            Path,
            "rglob",
            lambda path, pattern: (
                [diagnostic] if path == diagnostic.parent else original_rglob(path, pattern)
            ),
        ),
        patch.object(
            Path,
            "read_text",
            lambda path, *args, **kwargs: (
                output if path == diagnostic else original_read(path, *args, **kwargs)
            ),
        ),
        patch.object(
            Path,
            "open",
            lambda path, *args, **kwargs: (
                StringIO()
                if path == Path("/audit/ui-tests.log")
                else original_open(path, *args, **kwargs)
            ),
        ),
        patch.object(
            Path, "write_text", lambda path, value, **kwargs: report.__setitem__(path, value)
        ),
        patch(
            "validation_evidence.native_source_coverage",
            return_value={"ScoreFeature": (30, 100), "BIT101-iOS.app": (60, 100)},
        ),
        patch.dict(
            os.environ, BIT101_VALIDATION_INPUT_IDENTITY="digest", BIT101_VALIDATION_RUN_ID="run"
        ),
        redirect_stdout(StringIO()),
    ):
        record_native_metrics(sys.argv[1:])
    result = json.loads(
        next(
            line.split("：", 1)[1]
            for line in report[Path("/audit/test-metrics.txt")].splitlines()
            if line.startswith("控件库存：")
        )
    )
    if (
        result["processIdentifiers"] == ["10", "20"]
        and result["observed"] == 3
        and result["visited"] == 2
        and result["pending"] == ["10:pending"]
        and {row["identifier"] for row in result["visitedControls"]} == {"first", "second"}
        and all(
            row in report[Path("/audit/test-metrics.txt")]
            for row in (
                "- iOS/ScoreFeature: 30.00% (30/100 lines)",
                "- BIT101-iOS.app: 60.00% (60/100 lines)",
                "App 内界面查询：23 次；累计 0.7 秒",
                "共享原生快照读取：2 次；累计 1.5 秒",
            )
        )
    ):
        return []
    return ["UI 指标自测：冷启动前后的实际库存与待访问项共同保留"]
