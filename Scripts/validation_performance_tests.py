"""Regression contracts for real XCTest performance extraction and capture identity."""

from copy import deepcopy
import json
from pathlib import Path
from unittest.mock import patch
import validation_performance as subject
from validation_provenance import _local_source_identity

from validation_batch_tests import (
    batch_fault_expected_bytes as batch_fault_expected_bytes,
    setup_batch_fault_fixture as setup_batch_fault_fixture,
    verify_retain_failure_recovery as verify_retain_failure_recovery,
    verify_retain_interrupted_recovery as verify_retain_interrupted_recovery,
    batch_retention_self_test as batch_retention_self_test,
    merge_regression_self_test as merge_regression_self_test,
)


def source_identity_registry_self_test() -> None:
    import json
    from contextlib import nullcontext
    import validation_provenance as provenance

    state = {"groups": {"audit": {"exitCode": 0}}}

    def save(report, **kwargs):
        state.clear()
        state.update(deepcopy(report))

    with (
        patch.object(provenance, "report_lock", side_effect=nullcontext),
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_text", side_effect=lambda: json.dumps(state)),
        patch.object(provenance, "write_report", side_effect=save),
    ):
        files = {"source.swift": {"executable": False, "content": "first"}}
        initial = _local_source_identity(
            "modules", files, {}, current_inputs=set(files), committed_identity="git.original"
        )
        assert initial == "git.original"
        assert _local_source_identity("modules", files, {}, current_inputs=set(files)) == initial
        files["source.swift"]["content"] = "other"
        changed = _local_source_identity("modules", files, {}, current_inputs=set(files))
        assert changed != initial
        assert (
            _local_source_identity(
                "modules", files, {}, current_inputs=set(files), committed_identity="git.committed"
            )
            == changed
        )
        files["source.swift"]["executable"] = True
        executable = _local_source_identity("modules", files, {}, current_inputs=set(files))
        assert executable != changed
        assert (
            _local_source_identity(
                "modules", files, {"compiler": "other"}, current_inputs=set(files)
            )
            != executable
        )
        assert _local_source_identity("modules", {}, {}, current_inputs=set(files)) != executable
        assert state["groups"]["audit"]["exitCode"] == 0
        assert state["sourceInputs"]["files"] == {}
        from validation_environment import exchange_identity

        transferred = _local_source_identity("modules", files, {}, current_inputs=set(files))
        shared = exchange_identity(state)
        state.clear()
        state.update(shared)
        assert (
            _local_source_identity("modules", files, {}, current_inputs=set(files)) == transferred
        )
        files["source.swift"]["content"] = "changed after exchange"
        assert (
            _local_source_identity("modules", files, {}, current_inputs=set(files)) != transferred
        )
        _local_source_identity("ui", files, {}, current_inputs=set(files))
        renamed = {"renamed.swift": files["source.swift"]}
        _local_source_identity("modules", renamed, {}, current_inputs=set(renamed))
        assert set(state["sourceInputs"]["files"]) == {"renamed.swift"}
        assert set(state["sourceInputs"]["groups"]) == {"modules"}
        _local_source_identity("ui", renamed, {}, current_inputs=set(renamed))
        assert set(state["sourceInputs"]["groups"]) == {"modules", "ui"}
    provenance._REPORT_INPUTS.pop(provenance.REPORT, None)


def native_bundle_identity_self_test() -> None:
    import json

    bundle = Path("/fixture/results.xcresult")
    runs = [
        ({"startTime": 1, "finishTime": 2}, {"testNodes": [{"result": "Passed"}]}),
        ({"startTime": 1, "finishTime": 2}, {"testNodes": [{"result": "Failed"}]}),
    ]
    with (
        patch.object(subject, "result_bundle_complete", return_value=True),
        patch.object(Path, "is_file", return_value=False),
        patch.object(Path, "open", side_effect=AssertionError("结果身份读取原生执行记录")),
        patch.object(
            subject.subprocess,
            "check_output",
            side_effect=[json.dumps(value).encode() for run in runs for value in run],
        ) as native,
    ):
        assert subject.bundle_identity(bundle) != subject.bundle_identity(bundle)
        assert [call.args[0][4] for call in native.call_args_list] == [
            "summary",
            "tests",
            "summary",
            "tests",
        ]
    with (
        patch.object(subject, "result_bundle_complete", return_value=True),
        patch.object(Path, "is_file", return_value=False),
        patch.object(subject.subprocess, "check_output", return_value=b"{}"),
    ):
        try:
            subject.bundle_identity(bundle)
        except ValueError:
            pass
        else:
            raise AssertionError("原生记录需要有效内容")


def run_self_test() -> None:
    source_identity_registry_self_test()
    native_bundle_identity_self_test()
    committed_source_identity_self_test()
    merged_source_identity_self_test()
    static_audit_cancellation_self_test()
    failed_regression_self_test()
    with patch.object(
        subject.subprocess,
        "check_output",
        side_effect=[b"Modules/StorageCore/Sources/AppFileService.swift\0", b""],
    ) as git:
        assert subject.uncommitted_inputs() == ["Modules/StorageCore/Sources/AppFileService.swift"]
        assert git.call_args_list[0].args[0] == ["git", "diff", "--name-only", "-z", "HEAD", "--"]
    test = "MaintenancePerformanceTests/testCommunityPaginationPerformance"
    raw = [
        {
            "testIdentifier": test + "()",
            "testRuns": [
                {
                    "device": {"deviceId": "phone"},
                    "metrics": [
                        {
                            "identifier": "com.apple.dt.XCTMetric_Clock.time.monotonic",
                            "unitOfMeasurement": "s",
                            "measurements": [0.1, 0.2],
                        },
                        {
                            "identifier": "com.apple.dt.XCTMetric_Memory.physical_peak",
                            "unitOfMeasurement": "kB",
                            "measurements": [1024, 2048],
                        },
                        {
                            "identifier": "com.apple.dt.XCTMetric_Memory.physical",
                            "unitOfMeasurement": "kB",
                            "measurements": [0, 0],
                        },
                    ],
                }
            ],
        }
    ]
    normalized = subject.normalize_metrics(raw, test, "phone")
    assert normalized["peakPhysicalMemoryBytes"]["samples"] == [1_024_000, 2_048_000]
    assert normalized["clockSeconds"]["samples"] == [0.1, 0.2]
    for altered in ([], raw + raw, [{"testIdentifier": "other", "testRuns": raw[0]["testRuns"]}]):
        try:
            subject.normalize_metrics(altered, test, "phone")
        except ValueError:
            pass
        else:
            raise AssertionError("指标需要匹配唯一测试用例")
    for key, value in [("deviceId", "other"), ("unitOfMeasurement", "MB"), ("measurements", [])]:
        changed = deepcopy(raw)
        target = (
            changed[0]["testRuns"][0]["device"]
            if key == "deviceId"
            else changed[0]["testRuns"][0]["metrics"][1]
        )
        target[key] = value
        try:
            subject.normalize_metrics(changed, test, "phone")
        except ValueError:
            pass
        else:
            raise AssertionError("指标需要匹配实际设备、单位及原始采样")
    try:
        subject.bundle_identity(Path("/does-not-exist/current.xcresult"))
    except ValueError:
        pass
    else:
        raise AssertionError("性能捕获需要实际结果包")
    current = {"pagination": {"testIdentifier": test, "metrics": normalized}}
    baseline = {"pagination": {"testIdentifier": test, "approvedBy": "maintainer"}}
    proof = {
        "scenarios": {
            "pagination": {
                "measurement": {
                    "current": current["pagination"],
                    "baseline": baseline["pagination"],
                }
            }
        }
    }
    with (
        patch.object(subject, "capture_current", return_value={"records": current}),
        patch.object(
            Path,
            "read_text",
            return_value='{"baseline":{"records":{"pagination":{"testIdentifier":"'
            + test
            + '","approvedBy":"maintainer"}}}}',
        ),
    ):
        subject.validate_capture(proof)
        changed = deepcopy(proof)
        changed["scenarios"]["pagination"]["measurement"]["current"]["metrics"]["clockSeconds"][
            "samples"
        ] = [0.01]
        try:
            subject.validate_capture(changed)
        except ValueError:
            pass
        else:
            raise AssertionError("手填采样需要匹配实际 xcresult 指标")
    producing_run_capture_self_test()
    result_replacement_self_test()
    selected_result_retention_self_test()
    batch_retention_self_test(raw, test)
    merge_regression_self_test()
    baseline_approval_self_test()


def committed_source_identity_self_test() -> None:
    import validation_provenance as provenance

    commit = b"a" * 40
    history = (
        b"commit:"
        + b"b" * 40
        + b"\0\nREADME.md\0\0commit:"
        + commit
        + b"\0\nModules/Feature/Sources/Removed.swift\0"
    )
    provenance._input_history.cache_clear()
    with patch.object(
        provenance.subprocess, "check_output", side_effect=[b"", b"", commit, history, b""]
    ) as git:
        identity = provenance._clean_source_identity("manual-device", {"compiler": "fixture"})
        assert identity.startswith("git." + commit.decode() + ".")
        assert git.call_args_list[-2].args[0] == [
            "git",
            "log",
            "--first-parent",
            "--diff-merges=first-parent",
            "--no-renames",
            "--format=commit:%H",
            "--name-only",
            "-z",
            commit.decode(),
        ]
    for tracked, untracked in (
        (b"Modules/Feature/Sources/File.swift\0", b""),
        (b"", b"Modules/Feature/Sources/File.swift\0"),
    ):
        with patch.object(provenance.subprocess, "check_output", side_effect=[tracked, untracked]):
            assert provenance._clean_source_identity("manual-device", {}) is None
    provenance._input_history.cache_clear()
    with patch.object(
        provenance.subprocess,
        "check_output",
        side_effect=[b"README.md\0", b"", commit, history, b""],
    ):
        assert provenance._clean_source_identity("manual-device", {}).startswith(
            "git." + commit.decode() + "."
        )
    provenance._input_history.cache_clear()
    with patch.object(provenance.subprocess, "check_output", return_value=history) as git:
        assert provenance._input_history(
            Path("/fixture"), commit.decode(), ()
        ) == provenance._input_history(Path("/fixture"), commit.decode(), ())
        assert git.call_count == 1
    provenance._input_history.cache_clear()


def merged_source_identity_self_test() -> None:
    import os
    import shutil
    import subprocess
    import validation_provenance as provenance

    fixture = Path(__file__).resolve().parents[1] / ".build/static-audit/source-identity-self-test"
    shutil.rmtree(fixture, ignore_errors=True)
    fixture.mkdir(parents=True)
    environment = dict(
        os.environ,
        GIT_AUTHOR_NAME="Fixture",
        GIT_AUTHOR_EMAIL="fixture@example.invalid",
        GIT_COMMITTER_NAME="Fixture",
        GIT_COMMITTER_EMAIL="fixture@example.invalid",
    )

    def git(*arguments):
        return (
            subprocess.check_output(
                ["git", "-c", "commit.gpgsign=false", *arguments],
                cwd=fixture,
                env=environment,
                stderr=subprocess.PIPE,
            )
            .decode()
            .strip()
        )

    def store(name, content):
        path = fixture / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    swift = "Modules/StorageCore/Sources/"
    worker = "Cloudflare/ErrorReportWorker/"
    try:
        git("init", "-q", "-b", "main")
        for name in (
            swift + "First.swift",
            swift + "Second.swift",
            worker + "first.js",
            worker + "second.js",
        ):
            store(name, "base")
        git("add", ".")
        git("commit", "-qm", "base")
        git("checkout", "-qb", "feature")
        store(swift + "Second.swift", "feature")
        store(worker + "second.js", "feature")
        git("commit", "-qam", "feature")
        git("checkout", "-q", "main")
        store(swift + "First.swift", "main")
        store(worker + "first.js", "main")
        git("commit", "-qam", "main")
        with (
            patch.object(provenance, "ROOT", fixture),
            patch.object(
                provenance,
                "includes_input",
                side_effect=lambda name, group: name.endswith(".swift"),
            ),
        ):
            original = provenance._clean_source_identity("modules", {})
            original_worker = provenance.worker_source_revision("ErrorReportWorker")
            git("merge", "--no-ff", "-qm", "merge", "feature")
            merged = git("rev-parse", "HEAD")
            identity = provenance._clean_source_identity("modules", {})
            assert identity != original and identity.startswith("git." + merged + ".")
            assert (
                provenance.worker_source_revision("ErrorReportWorker") == merged != original_worker
            )
            store("README.md", "documentation")
            git("add", ".")
            git("commit", "-qm", "documentation")
            assert provenance._clean_source_identity("modules", {}) == identity
            assert provenance.worker_source_revision("ErrorReportWorker") == merged
            for flag in ("assume-unchanged", "skip-worktree"):
                git("update-index", "--" + flag, swift + "First.swift")
                assert provenance._clean_source_identity("modules", {}) == identity
                store(swift + "First.swift", "hidden local edit")
                assert provenance._clean_source_identity("modules", {}) is None
                store(swift + "First.swift", "main")
                path = fixture / (swift + "First.swift")
                path.chmod(0o755)
                assert provenance._clean_source_identity("modules", {}) is None
                path.chmod(0o644)
                git("update-index", "--no-" + flag, swift + "First.swift")
    finally:
        provenance._committed_worker_revision.cache_clear()
        shutil.rmtree(fixture)


def developer_directory_self_test() -> None:
    import os
    import sys
    from io import BytesIO
    from validation_manual_tests import source_identity_fixture
    from types import SimpleNamespace
    from unittest.mock import patch
    import validation_environment as environment

    developer = Path("/chosen/Xcode.app/Contents/Developer")

    def plist(path, keys):
        if path == developer.parent / "Info.plist":
            return {"CFBundleShortVersionString": "fixture", "CFBundleVersion": "1"}
        if (
            path
            == developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist"
        ):
            return {"Version": "fixture"}
        return {}

    try:
        with (
            patch.object(
                environment.subprocess,
                "check_output",
                side_effect=lambda args, **kwargs: (
                    "/chosen/swift-frontend\n"
                    if args[0] == "xcrun"
                    else args[0] + " fixture-version\n"
                ),
            ),
            patch.object(environment, "plist_values", side_effect=plist),
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "stat", return_value=SimpleNamespace(st_size=8, st_mtime_ns=1)),
            patch.object(Path, "open", side_effect=lambda *args, **kwargs: BytesIO(b"compiler")),
        ):
            expected_runtimes = {
                "python": sys.version,
                "ruby": "ruby fixture-version",
                "node": "node fixture-version",
                "npm": "npm fixture-version",
                "ruff": "ruff fixture-version",
            }
            incomplete_runtimes = {
                name: val for name, val in expected_runtimes.items() if name != "ruff"
            }
            contexts = []
            for selected in ("/chosen/Xcode.app", str(developer)):
                with patch.dict(os.environ, DEVELOPER_DIR=selected):
                    environment.host_environment.cache_clear()
                    environment.environment_context.cache_clear()
                    context = environment.environment_context("audit")
                    assert environment.complete_environment("audit", context), selected
                    assert context["runtimes"] == expected_runtimes
                    assert not environment.complete_environment(
                        "audit", context | {"runtimes": incomplete_runtimes}
                    )
                    contexts.append(context)
            assert contexts[0] == contexts[1]
    finally:
        environment.host_environment.cache_clear()
        environment.environment_context.cache_clear()
    from validation_provenance import input_identity

    context = contexts[0]
    with (
        patch("validation_provenance._clean_source_identity", return_value=None),
        patch(
            "validation_provenance._local_source_identity", side_effect=source_identity_fixture()
        ),
    ):
        assert input_identity("audit", environment=context) != input_identity(
            "audit",
            environment=context | {"runtimes": context["runtimes"] | {"ruff": "changed-version"}},
        )


def static_audit_cancellation_self_test() -> None:
    import os
    import signal
    import subprocess
    import sys
    from time import monotonic

    source = (subject.ROOT / "Scripts/run-static-audit.sh").read_text()
    finish = (
        "finish_audit() {"
        + source.split("finish_audit() {", 1)[1].split("\ntrap finish_audit EXIT", 1)[0]
    )
    for ignores_term in (False, True):
        worker = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print("rea'
                    'dy", flush=True); time.sleep(60)'
                )
                if ignores_term
                else 'import time; print("ready", flush=True); time.sleep(60)',
            ],
            stdout=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            assert worker.stdout.readline().strip() == "ready"
            prefix = (
                f"ROOT_DIR="
                f"{str(subject.ROOT)!r}"
                f" AUDIT_STARTED=$SECONDS full_audit=1\ngroup_processes=("
                f"{worker.pid}"
                f' 0)\npython3() {{\n  if [[ "$1" == "$ROOT_DIR/Scripts/validation_evidence.py" ]'
                f']; then print -r -- "RECORD $*"; return 0; fi\n  command python3 "$@"\n}}\n'
            )
            started = monotonic()
            result = subprocess.run(
                ["zsh", "-c", prefix + finish + "\ntrap finish_audit EXIT\nexit 143"],
                text=True,
                capture_output=True,
                timeout=15,
            )
            assert result.returncode == 143 and "record audit 143" in result.stdout
            assert worker.wait(timeout=1) == (-signal.SIGKILL if ignores_term else -signal.SIGTERM)
            assert monotonic() - started < 10
        finally:
            if worker.poll() is None:
                os.killpg(worker.pid, signal.SIGKILL)
            worker.wait()
            worker.stdout.close()


def selected_result_retention_self_test() -> None:
    import json
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import validation_provenance

    sha = "a" * 64
    environment = {"device": {"identifier": "phone"}}
    full = {
        "scope": "full",
        "exitCode": 0,
        "summary": {"passed": True},
        "inputDigest": "same",
        "environment": environment,
        "resultBundleIdentity": sha,
        "recordedAt": subject.utc_now().isoformat(),
    }
    with (
        redirect_stderr(StringIO()) as diagnostic,
        patch.object(subject, "recover_result_step"),
        patch.object(subject, "begin_result_step") as begin,
        patch.object(subject, "bundle_identity", side_effect=ValueError("incomplete")),
        patch.object(Path, "exists", return_value=True),
    ):
        assert subject.begin_selected_result_step() == []
        begin.assert_called_once_with(False)
        assert diagnostic.getvalue() == "中断的 XCTest 结果包已进入清理与重新采样。\n"
    for changed, retained in (
        ({}, ["all"]),
        ({"inputDigest": "changed"}, []),
        ({"exitCode": 1}, []),
        ({"recordedAt": ""}, ["all"]),
        ({"recordedAt": "2000-01-01T00:00:00Z"}, ["all"]),
        ({"recordedAt": "2200-01-01T00:00:00Z"}, ["all"]),
        ({"environment": {"device": {"identifier": "other"}}}, []),
        ({"resultBundleIdentity": "b" * 64}, []),
    ):
        row = dict(full, **changed)
        with (
            patch.object(subject, "recover_result_step"),
            patch.object(subject, "begin_result_step") as begin,
            patch.object(subject, "bundle_identity", return_value=sha),
            patch.object(subject, "environment_context", return_value=environment),
            patch.object(validation_provenance, "input_identity", return_value="same"),
            patch.object(validation_provenance, "report_lock", side_effect=nullcontext),
            patch.object(Path, "exists", return_value=True),
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "read_text", return_value=json.dumps({"groups": {"all": row}})),
        ):
            assert subject.begin_selected_result_step() == retained
            begin.assert_called_once_with(bool(retained), selected_groups=retained)
    with (
        patch.object(subject, "recover_result_step"),
        patch.object(subject, "begin_result_step") as begin,
        patch.object(subject, "bundle_identity", return_value=sha),
        patch.object(subject, "environment_context", return_value=environment),
        patch.object(validation_provenance, "input_identity", return_value="same"),
        patch.object(validation_provenance, "report_lock", side_effect=nullcontext),
        patch.object(Path, "exists", return_value=True),
        patch.object(Path, "is_file", return_value=True),
        patch.object(
            Path, "read_text", return_value=json.dumps({"groups": {"all": full, "ui": full}})
        ),
    ):
        from contextlib import redirect_stdout

        console = StringIO()
        with redirect_stdout(console):
            assert subject.main(["begin-full", "ui"]) == 0
        assert console.getvalue().strip() == ""
        begin.assert_called_once_with(False)
    with patch.object(subject, "retain_result_step") as retain:
        assert subject.main(["retain-selected", "all", "all", "ui"]) == 0
        retain.assert_called_once_with(["ui", "all"])


def failed_regression_self_test() -> None:
    from validation_provenance import invalidate_failed_evidence, complete_group_row

    method = "ScheduleCourseEditorTests/changeWeeks"
    full = dict(
        scope="full",
        exitCode=0,
        inputDigest="input",
        environment={},
        resultBundleIdentity="a" * 64,
        summary={"passed": True, "executedTests": [method + "()"]},
    )
    for scope in ("selected", "full"):
        for failure in (
            {"exitCode": 1, "summary": {}},
            {"exitCode": 0, "summary": {"passed": False}},
        ):
            parent = (
                deepcopy(full)
                if scope == "full"
                else dict(deepcopy(full), scope=scope, lastFullRun=deepcopy(full))
            )
            report = {
                "groups": {
                    "all": parent,
                    "ui": dict(
                        deepcopy(full),
                        summary={"passed": True, "executedTests": ["UITests/render"]},
                    ),
                    "schedule": dict(failure, scope="selected", runID="regression"),
                }
            }
            assert invalidate_failed_evidence(report, "schedule", {method}) == ["all"]
            assert complete_group_row(report["groups"]["all"])["exitCode"] == 1
            assert report["groups"]["all"]["summary"]["passed"] is False
            if scope == "selected":
                assert report["groups"]["all"]["lastFullRun"]["exitCode"] == 1
            assert report["groups"]["ui"]["summary"]["passed"] is True
            report["groups"]["schedule"].update(exitCode=0, summary={"passed": True})
            assert invalidate_failed_evidence(report, "schedule", {method}) == []
            assert complete_group_row(report["groups"]["all"])["exitCode"] == 1
    report = {"groups": {"all": deepcopy(full), "schedule": {"exitCode": 1}}}
    assert invalidate_failed_evidence(report, "schedule", {"OtherTests/method"}) == []
    assert report["groups"]["all"]["summary"]["passed"] is True
    report["groups"]["all"] = dict(
        deepcopy(full), scope="selected", exitCode=1, lastFullRun=deepcopy(full)
    )
    assert invalidate_failed_evidence(report, "all", {method}) == []
    report["groups"]["all"].update(exitCode=0, summary={"passed": True})
    assert complete_group_row(report["groups"]["all"])["scope"] == "selected"
    recorded_failure_self_test(full, method)
    from validation_evidence import network_inventory

    for group, scope in (("ddl", "ddl"), ("school-sms", "school"), ("network", "bit101")):
        probes = network_inventory(scope)
        full = dict(
            scope="full",
            exitCode=0,
            inputDigest="input",
            environment={},
            summary={"passed": True, "probeInventory": sorted(network_inventory("all"))},
        )
        report = {
            "groups": {
                "network": deepcopy(full),
                "ui": {"exitCode": 0, "summary": {"passed": True}},
                group: {"exitCode": 1, "scope": "selected", "runID": "regression"},
            }
        }
        if group == "network":
            report["groups"][group]["lastFullRun"] = deepcopy(full)
        assert invalidate_failed_evidence(report, group, probes) == (
            [] if group == "network" else ["network"]
        )
        assert report["groups"]["ui"]["exitCode"] == 0
        failed = report["groups"]["network"].get("lastFullRun", report["groups"]["network"])
        assert failed["exitCode"] == 1 and failed["summary"]["failedRegression"][
            "probes"
        ] == sorted(probes)


def recorded_failure_self_test(full: dict, method: str) -> None:
    import json
    import os
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import validation_evidence

    report = {
        "groups": {
            "all": deepcopy(full),
            "ui": dict(
                deepcopy(full), summary={"passed": True, "executedTests": ["UITests/render"]}
            ),
        }
    }
    with (
        patch.object(validation_evidence, "input_identity", return_value="input"),
        patch.object(validation_evidence, "environment_context", return_value={}),
        patch.object(validation_evidence, "report_lock", side_effect=nullcontext),
        patch.object(
            validation_evidence, "write_report", side_effect=lambda value: report.update(value)
        ),
        patch.object(Path, "is_file", return_value=True),
        patch.object(
            Path,
            "read_text",
            new=lambda path, *args, **kwargs: (
                json.dumps(report) if path == validation_evidence.REPORT else "metrics"
            ),
        ),
        patch.object(
            validation_evidence,
            "test_summary",
            return_value={"passed": False, "executedTests": [method]},
        ),
        patch.object(validation_evidence.subprocess, "check_output", return_value="commit"),
        patch.dict(
            os.environ,
            BIT101_VALIDATION_RUN_ID="failed-run",
            BIT101_VALIDATION_EXPECTED_TESTS=json.dumps([method]),
        ),
        redirect_stderr(StringIO()),
    ):
        assert validation_evidence.record("schedule", 1, "selected", "input") == 1
    assert (
        report["groups"]["all"]["exitCode"] == 1
        and report["groups"]["all"]["summary"]["passed"] is False
    )
    assert report["groups"]["ui"]["exitCode"] == 0


def result_replacement_self_test() -> None:
    import json
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import validation_provenance

    sha = "a" * 64
    report = {
        "releaseCommit": "commit",
        "mergeCommit": "commit",
        "resultMerge": {"groups": ["all"]},
        "groups": {
            "all": {"resultBundleIdentity": sha},
            "ui": {"lastFullRun": {"resultBundleIdentity": sha}},
            "catalyst": {"resultBundleIdentity": sha},
            "modules": {"runID": "modules"},
        },
        "performanceBaseline": {"approvedBy": "maintainer"},
    }
    output = StringIO()
    with (
        redirect_stderr(output),
        patch.object(Path, "exists", return_value=True),
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_text", return_value=json.dumps(report)),
        patch.object(validation_provenance, "report_lock", side_effect=nullcontext),
        patch.object(subject.shutil, "rmtree") as remove,
        patch.object(validation_provenance, "write_report") as save,
    ):
        save.side_effect = lambda value: remove.assert_not_called()
        assert subject.main(["reset-results"]) == 0
        assert output.getvalue() == "覆盖原始结果包：all、catalyst、ui 的验证证据将进入重新验收。\n"
        updated = save.call_args.args[0]
        assert updated["groups"] == {"modules": {"runID": "modules"}}
        assert "releaseCommit" not in updated and "mergeCommit" not in updated
        assert "resultMerge" not in updated
        assert updated["performanceBaseline"] == report["performanceBaseline"]
        remove.assert_called_once_with(subject.BUNDLE)
        remove.reset_mock()
        save.reset_mock()
        save.side_effect = OSError("report write failure")
        try:
            subject.reset_result_bundle()
        except OSError:
            pass
        else:
            raise AssertionError("证据写入失败需要保留原始结果包")
        remove.assert_not_called()
        with patch.object(Path, "exists", return_value=False):
            subject.reset_result_bundle()
        assert save.call_count == 1
    rows = {group: {"resultBundleIdentity": sha} for group in ("all", "ui")}
    with patch.object(subject, "bundle_identity", return_value=sha) as digest:
        assert not subject.result_bundle_findings({"groups": rows})
        changed = deepcopy(rows)
        changed["ui"]["resultBundleIdentity"] = "b" * 64
        assert subject.result_bundle_findings({"groups": changed})
        for value in ("b" * 64, None):
            with patch.object(subject, "bundle_identity", return_value=value):
                assert subject.result_bundle_findings({"groups": rows})
        with patch.object(subject, "bundle_identity", side_effect=ValueError("missing bundle")):
            assert subject.result_bundle_findings({"groups": rows})
        digest.reset_mock()
        assert not subject.result_bundle_findings({"groups": rows}, recorded_environment=True)
        digest.assert_not_called()
        assert subject.result_bundle_findings({"groups": changed}, recorded_environment=True)
        assert subject.result_bundle_findings({"groups": {}}, recorded_environment=True)
        complete = dict(
            rows["all"], scope="full", exitCode=0, inputDigest="input", summary={"passed": True}
        )
        selected = dict(
            complete, scope="selected", resultBundleIdentity="b" * 64, lastFullRun=complete
        )
        assert not subject.result_bundle_findings({"groups": rows | {"all": selected}})


def baseline_approval_self_test() -> None:
    import json
    from validation_manual_tests import evidence_fixture

    scenarios = json.loads(evidence_fixture("performance-baseline"))["scenarios"]
    proof = {
        "schemaVersion": 1,
        "records": {name: row["measurement"]["baseline"] for name, row in scenarios.items()},
    }
    assert subject.approved_baseline_complete(proof)
    for field, value in [
        ("approvedBy", ""),
        ("approvedAt", "invalid"),
        ("metrics", {}),
        ("input", "other"),
    ]:
        changed = deepcopy(proof)
        changed["records"][next(iter(changed["records"]))][field] = value
        assert not subject.approved_baseline_complete(changed)
    assert subject.approved_baseline_complete(
        __import__("validation_environment").exchange_identity(
            {"performanceBaseline": proof, "groups": {}}
        )["performanceBaseline"]
    )


def assert_capture_rejects_altered_group(subject, rows, group, field, value):
    changed = deepcopy(rows)
    changed[group][field] = value
    with patch.object(Path, "read_text", return_value=json.dumps({"groups": changed})):
        try:
            subject.capture_current()
        except ValueError:
            pass
        else:
            raise AssertionError("采样需要匹配完成时的生产运行")


def producing_run_capture_self_test() -> None:
    import json
    from validation_manual import PERFORMANCE_WORKLOADS, performance_group

    environment = {
        "device": {
            "identifier": "phone",
            "model": "iPhone",
            "systemVersion": "17",
            "systemBuild": "build",
        },
        "xcode": {"DTXcodeBuild": "xcode"},
        "compiler": {"version": "a" * 64},
    }
    rows = {
        group: {
            "exitCode": 0,
            "scope": "full",
            "inputDigest": "digest",
            "runID": group,
            "sourceCommit": "commit",
            "recordedAt": "captured",
            "environment": environment,
            "resultBundleIdentity": "b" * 64,
        }
        for group in ("all", "ui")
    }

    def exported(command, **kwargs):
        if "summary" in command:
            return '{"result":"Passed"}'
        return json.dumps(
            [
                {
                    "testIdentifier": command[-1],
                    "testRuns": [
                        {
                            "device": {"deviceId": "phone"},
                            "metrics": [
                                {
                                    "identifier": identifier,
                                    "unitOfMeasurement": unit,
                                    "measurements": [1, 2],
                                }
                                for identifier, unit, _ in subject.METRICS.values()
                            ],
                        }
                    ],
                }
            ]
        )

    combined = {}
    with (
        patch.object(subject.subprocess, "check_output", side_effect=exported),
        patch.object(subject, "bundle_identity", return_value="b" * 64),
    ):
        for group, row in rows.items():
            row["performance"] = subject.extract_measurements(row, group)
            expected = {
                name
                for name, (test, _) in PERFORMANCE_WORKLOADS.items()
                if performance_group(test) == group
            }
            assert set(row["performance"]["records"]) == expected
            assert all(
                record["execution"]["group"] == group
                for record in row["performance"]["records"].values()
            )
            combined.update(row["performance"]["records"])
    assert set(combined) == set(PERFORMANCE_WORKLOADS)
    with (
        patch.object(Path, "read_text", return_value=json.dumps({"groups": rows})),
        patch.object(subject, "environment_context", return_value=environment),
        patch.object(subject, "complete_environment", return_value=True),
        patch.object(subject, "uncommitted_inputs", return_value=[]),
        patch.object(subject, "record_complete", return_value=True),
        patch.object(subject, "bundle_identity", return_value="b" * 64),
        patch("validation_provenance.input_identity", return_value="digest"),
        patch.object(
            subject.subprocess,
            "check_output",
            side_effect=AssertionError("后续宿主沿固定结果包继续运行"),
        ),
    ):
        assert subject.capture_current() == {"schemaVersion": 1, "records": combined}
        from validation_environment import exchange_identity

        shared = exchange_identity({"groups": rows})
        with patch.object(Path, "read_text", return_value=json.dumps(shared)):
            assert (
                subject.capture_current()["records"]
                == shared["groups"]["all"]["performance"]["records"]
                | shared["groups"]["ui"]["performance"]["records"]
            )
        for group in rows:
            for field, value in [
                ("runID", "other"),
                ("resultBundleIdentity", "c" * 64),
                ("sourceCommit", "other"),
            ]:
                assert_capture_rejects_altered_group(subject, rows, group, field, value)
