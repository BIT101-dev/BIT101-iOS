"""Exercise workflow ownership and bounded network evidence using memory IO substitutes."""

from contextlib import contextmanager, nullcontext, redirect_stderr, redirect_stdout
from datetime import timedelta
from io import BytesIO, StringIO
import ast
import json
import re
import subprocess
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch
from validation_manual_tests import image_resource_self_test, report_budget_self_test
from worker_contract_tests import (
    worker_deployment_fixture,
    worker_deployment_self_test,
    emergency_configuration_fixture,
)
from validation_provenance import LIVE_GROUPS, evidence_current, sampling_evidence_current, utc_now

from network_fixture_tests import network_trace_fixture
from network_contract_tests import network_route_identity_self_test


def sampled_module_inputs_self_test() -> None:
    from validation_inputs import sampled_module_inputs, includes_input

    root = Path(__file__).resolve().parents[1]
    cloud = sampled_module_inputs("icloud")
    assert {"ScheduleSync", "StorageCore", "ScorePorts"} <= cloud and "CommunityUI" not in cloud
    source = root / "BIT101-iOS/Schedule/ScheduleCloudSyncManager.swift"
    original = Path.read_bytes
    try:
        with patch.object(
            Path,
            "read_bytes",
            lambda path: (
                original(path) + b"\nimport MapFeature\n" if path == source else original(path)
            ),
        ):
            sampled_module_inputs.cache_clear()
            assert "MapFeature" in sampled_module_inputs("icloud")
    finally:
        sampled_module_inputs.cache_clear()
    for host in ("network", "community-writes", "icloud"):
        sampled_module_inputs(host)
    assert includes_input("Modules/StorageCore/Sources/AppFileService.swift", "icloud")
    assert not includes_input("Modules/CommunityUI/Sources/CommunityViews.swift", "icloud")
    assert includes_input("Modules/CommunityUI/Sources/CommunityViews.swift", "build-icloud-smoke")


def source_snapshot_self_test() -> None:
    from types import SimpleNamespace
    import validation_provenance as subject

    inputs = {"Package.swift": b"product", "README.md": b"documentation"}
    reads = []

    def read(path):
        name = path.relative_to(subject.ROOT).as_posix()
        reads.append(name)
        return inputs[name]

    def identity(group, files, context, **kwargs):
        return json.dumps(files, sort_keys=True)

    with (
        patch.object(subject, "repository_input_names", return_value=list(inputs)) as inventory,
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_bytes", read),
        patch.object(Path, "stat", return_value=SimpleNamespace(st_mode=0o644)),
        patch.object(subject, "_clean_source_identity", return_value=None),
        patch.object(subject, "_local_source_identity", side_effect=identity),
    ):
        with subject.source_snapshot():
            full = subject.input_identity()
            with subject.source_snapshot():
                group = subject.input_identity("modules", environment={})
            assert set(json.loads(full)) == set(inputs) and set(json.loads(group)) == {
                "Package.swift"
            }
            inputs["Package.swift"] = b"changed product"
            assert subject.input_identity("modules", environment={}) == group
        assert inventory.call_count == 1 and sorted(reads) == sorted(inputs)
        assert subject.input_identity("modules", environment={}) != group
        assert inventory.call_count == 2 and reads[-1] == "Package.swift"


def test_identity_self_test() -> None:
    import validation_test_areas as subject

    root = subject.ROOT / "ModuleTests"
    first, second = root / "Transport/ClientCoreTests.swift", root / "Sync/ScheduleSyncTests.swift"
    original_read, original_rglob = Path.read_text, Path.rglob
    cases = [
        (
            {
                first: (
                    "import Testing\nstruct Probe { @Test func check(value: Int) {}\n@Test func ch"
                    "eck(number: Int) {} }"
                )
            },
            True,
        ),
        (
            {
                first: "import Testing\nstruct Probe { @Test func check(value: Int) {} }",
                second: "import Testing\nstruct Probe { @Test func check(number: Int) {} }",
            },
            True,
        ),
        (
            {
                first: (
                    "import Testing\nstruct Probe { @Test func checkValue(value: Int) {}\n@Test fu"
                    "nc checkNumber(number: Int) {} }"
                )
            },
            False,
        ),
        (
            {
                first: "import Testing\nstruct First { @Test func check(value: Int) {} }",
                second: "import Testing\nstruct Second { @Test func check(number: Int) {} }",
            },
            False,
        ),
    ]
    for sources, ambiguous in cases:

        def read(path, *args, **kwargs):
            return sources[path] if path in sources else original_read(path, *args, **kwargs)

        with (
            patch.object(
                Path,
                "rglob",
                lambda path, pattern: (
                    iter(sources) if path == root else original_rglob(path, pattern)
                ),
            ),
            patch.object(Path, "read_text", read),
        ):
            try:
                inventory = subject.test_selectors.__wrapped__("modules")
            except ValueError as error:
                assert ambiguous and "测试库存需要唯一 Suite/method" in str(error)
                assert (
                    str(first) in str(error)
                    and "check(value:)" in str(error)
                    and "check(number:)" in str(error)
                )
            else:
                assert not ambiguous and len(inventory) == 2
    facts = subject.swift_syntax_index_sources(
        {str(first): "import Testing\nstruct Probe { @Test func check(value: Int) {} }"}
    )
    import copy

    other = copy.deepcopy(facts[str(first)])
    facts[str(first)]["tests"][0]["value"] = "FirstTests.Probe/check"
    other["tests"][0]["value"] = "SecondTests.Probe/check"
    facts[str(second)] = other
    with patch.object(subject, "indexed_test_sources", return_value=facts):
        try:
            subject.test_selectors.__wrapped__("modules")
        except ValueError as error:
            assert "Probe/check" in str(error)
        else:
            raise AssertionError("模块前缀归一化后的歧义需要进入库存失败")
    directory = subject.ROOT / "BIT101-iOSTests"
    test_path = directory / "NetworkClientTests.swift"
    enum_path = subject.ROOT / "Modules/TransportCore/Sources/SecureURLTransport.swift"
    extension_path = subject.ROOT / "Modules/ClientCore/Sources/DateFormatters.swift"
    enum = "enum Fixture { enum Choice: CaseIterable { case first, second; MEMBER } }"
    for member, extension, arguments, accepted in [
        ("", "", "Fixture.Choice.allCases", True),
        ("var allCases: [Self] { [.first] }", "", "Fixture.Choice.allCases", True),
        (
            "func selected() -> [Self] { let allCases = [Choice.first]; return allCases }",
            "",
            "Fixture.Choice.allCases",
            True,
        ),
        (
            "func selected() { let (first, second) = (Choice.first, Choice.second) }",
            "",
            "Fixture.Choice.allCases",
            True,
        ),
        ("static var allCases: [Self] { [.first] }", "", "Fixture.Choice.allCases", False),
        (
            "static let allCases = [Choice.first, Choice.first]",
            "",
            "Fixture.Choice.allCases",
            False,
        ),
        (
            "",
            "extension Fixture.Choice { static var allCases: [Self] { [.second] } }",
            "Fixture.Choice.allCases",
            False,
        ),
        (
            "",
            "extension Fixture.Choice { static let allCases = [Fixture.Choice.first] }",
            "Fixture.Choice.allCases",
            False,
        ),
        (
            "static var allCases: [Self] { [.first] }",
            "",
            "[Fixture.Choice.first, Fixture.Choice.second]",
            True,
        ),
    ]:
        sources = {
            test_path: "import Testing\nstruct Probe { @Test(arguments: "
            + arguments
            + ") func check(_ choice: Fixture.Choice) {} }",
            enum_path: enum.replace("MEMBER", member),
            extension_path: extension,
        }
        with (
            patch.object(
                Path,
                "rglob",
                lambda path, pattern: (
                    iter([test_path]) if path == directory else original_rglob(path, pattern)
                ),
            ),
            patch.object(
                Path,
                "read_text",
                lambda path, *args, **kwargs: (
                    sources[path] if path in sources else original_read(path, *args, **kwargs)
                ),
            ),
            patch(
                "validation_inputs.repository_input_names",
                return_value=[path.relative_to(subject.ROOT).as_posix() for path in sources],
            ),
            patch("validation_inputs.includes_input", return_value=True),
            patch.object(subject, "test_inventory", return_value={"Probe/check"}),
        ):
            try:
                inventory = subject.test_case_inventory.__wrapped__("all")
            except ValueError as error:
                assert not accepted and "自动合成 allCases" in str(error), (
                    member,
                    extension,
                    str(error),
                )
            else:
                assert accepted and inventory == {"Probe/check": 2}, (member, extension, inventory)


def probe_identity_self_test(subject) -> None:
    path = subject.ROOT / "BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift"
    original_read = Path.read_text
    original = path.read_text()
    baseline = subject.network_inventory()
    assert "gallery.newest" in baseline and "话廊最新列表" not in baseline
    with patch.object(
        Path,
        "read_text",
        lambda target, *args, **kwargs: (
            original.replace("话廊最新列表", "新版显示名称")
            if target == path
            else original_read(target, *args, **kwargs)
        ),
    ):
        subject.network_inventory.cache_clear()
        assert subject.network_inventory() == baseline
    subject.network_inventory.cache_clear()


def run_self_test(recorder) -> None:
    worker_cli_diagnostics_self_test()
    sampled_module_inputs_self_test()
    worker_deployment_self_test(network_trace_fixture)
    module = sys.modules[recorder.__module__]
    check_group_bundle_self_test(module)
    summary = {
        "passed": True,
        "totalTests": 1,
        "passedTests": 1,
        "failedTests": 0,
        "skippedTests": 0,
    }
    for group, start, run_id, artifact, expected in (
        ("audit", "", "run", None, 1),
        ("audit", "current", "", None, 1),
        ("audit", "current", "run", None, 0),
        ("all", "current", "run", "验证输入：old\n验证运行：run\n", 1),
        ("all", "current", "run", "验证输入：current\n验证运行：old\n", 1),
        ("all", "current", "run", "验证输入：current\n验证运行：run\n", 0),
        ("ui", "current", "run", "验证输入：current\n验证运行：run\n", 0),
        ("network", "current", "run", json.dumps({"runID": "old"}), 1),
        ("network", "current", "run", json.dumps({"runID": "run"}), 0),
    ):
        values = [artifact, '{"groups":{}}'] if artifact is not None else ['{"groups":{}}']
        with (
            patch.object(module, "input_identity", return_value="current"),
            patch.object(module, "complete_environment", return_value=True),
            patch.object(module, "report_lock", side_effect=nullcontext),
            patch.object(module, "write_report") as saved,
            patch.object(module, "test_summary", return_value=summary),
            patch.object(module, "smoke_summary", return_value=summary),
            patch.object(module, "test_inventory", return_value={"Suite/testRun"}),
            patch.object(module, "complete_summary", return_value=True),
            patch.object(module, "environment_context", return_value={}),
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "read_text", side_effect=values),
            patch.object(module.subprocess, "check_output", return_value="head"),
            patch("validation_performance.bundle_identity", return_value="a" * 64),
            patch("validation_performance.current_commit", return_value="head"),
            patch("validation_performance.extract_measurements", return_value={"records": {}}),
            patch.dict(
                os.environ,
                BIT101_VALIDATION_RUN_ID=run_id,
                BIT101_VALIDATION_STARTED_AT=utc_now().isoformat(),
                BIT101_VALIDATION_ELAPSED_SECONDS="12.5",
            ),
            redirect_stderr(StringIO()),
        ):
            assert recorder(group, 0, "full", start) == expected, (group, artifact)
            assert saved.call_args.args[0]["groups"][group]["exitCode"] == expected
            assert saved.call_args.args[0]["groups"][group]["durationSeconds"] == 12.5
            if group in {"all", "ui"} and expected == 0:
                assert saved.call_args.args[0]["groups"][group]["resultBundleIdentity"] == "a" * 64
                assert saved.call_args.args[0]["groups"][group]["sourceCommit"] == "head"
    group_row = {
        "scope": "full",
        "exitCode": 0,
        "runID": "run",
        "inputDigest": "current",
        "summary": summary,
        "recordedAt": utc_now().isoformat(),
        "environment": module.environment_context("all"),
    }
    for digest, expected in (("current", 0), ("changed", 1)):
        with (
            patch.object(sys, "argv", ["validation_evidence.py", "check-group", "all"]),
            patch.object(module, "report_lock", side_effect=nullcontext),
            patch.object(module, "complete_summary", return_value=True),
            patch.object(module, "input_identity", return_value=digest),
            patch.object(Path, "is_file", return_value=True),
            patch.object(
                Path, "read_text", return_value=json.dumps({"groups": {"all": group_row}})
            ),
            redirect_stderr(StringIO()),
        ):
            assert module.main() == expected
    selected = dict(group_row, scope="selected", lastFullRun=group_row)
    for status in (0, 1):
        selected["exitCode"] = status
        with (
            patch.object(sys, "argv", ["validation_evidence.py", "check-group", "all"]),
            patch.object(module, "report_lock", side_effect=nullcontext),
            patch.object(module, "complete_summary", return_value=True),
            patch.object(module, "input_identity", return_value="current"),
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "read_text", return_value=json.dumps({"groups": {"all": selected}})),
            redirect_stderr(StringIO()),
        ):
            assert module.main() == status
    artifact_lock_self_test(module)
    selected_coverage_self_test(module)
    baseline_policy_self_test(module)
    report_budget_self_test(module)
    aggregate_failure_self_test(module)
    complete_run_reuse_self_test(module)
    check_group_coverage_policy_self_test(module)
    now = utc_now()
    fresh = {
        "startedAt": (now - timedelta(minutes=2)).isoformat(),
        "finishedAt": (now - timedelta(minutes=1)).isoformat(),
    }
    assert sampling_evidence_current(fresh, now)
    assert not sampling_evidence_current(
        dict(fresh, startedAt=(now - timedelta(days=2)).isoformat()), now
    )
    for group in LIVE_GROUPS:
        assert evidence_current(group, fresh)
        assert not evidence_current(
            group, dict(fresh, startedAt=(now - timedelta(days=2)).isoformat())
        )
    assert not sampling_evidence_current(fresh, now + timedelta(days=1))
    assert not sampling_evidence_current(
        dict(fresh, finishedAt=(now + timedelta(minutes=1)).isoformat()), now
    )
    assert not sampling_evidence_current(dict(fresh, startedAt=now.isoformat()), now)
    assert not sampling_evidence_current({"startedAt": "invalid", "finishedAt": "invalid"}, now)
    assert not sampling_evidence_current({}, now)
    for group in ("audit", "network", "icloud", "manual-device"):
        for summary, expected, label in (
            (fresh, 0, "通过"),
            (dict(fresh, finishedAt=(now - timedelta(days=2)).isoformat()), 1, "待复验"),
        ):
            row = dict(group_row, summary=dict(summary, passed=True))
            report = json.dumps({"groups": {group: row}})
            with (
                patch.object(module, "input_identity", return_value="current"),
                patch.object(module, "report_lock", side_effect=nullcontext),
                patch.object(module, "complete_summary", return_value=True),
                patch.object(Path, "is_file", return_value=True),
                patch.object(Path, "read_text", return_value=report),
                patch.object(sys, "argv", ["validation_evidence.py", "check-group", group]),
                redirect_stderr(StringIO()),
            ):
                assert module.main() == expected
                output = StringIO()
                with redirect_stdout(output), patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}):
                    assert (
                        module.inspect_report(
                            SimpleNamespace(action="summary", recorded_environment=False)
                        )
                        == 0
                    )
                assert f"| {group} | full | {label} |" in output.getvalue()


def check_group_bundle_self_test(module) -> None:
    from validation_performance import result_bundle_findings

    for group in ("all", "ui"):
        for stored, raw in (
            ("a" * 64, "a" * 64),
            ("b" * 64, "a" * 64),
            ("invalid", "a" * 64),
            ("a" * 64, None),
        ):
            def mock_identity(path, current_raw=raw):
                if current_raw:
                    return current_raw
                raise ValueError("absent result bundle")

            row = {
                "scope": "full",
                "exitCode": 0,
                "runID": "run",
                "inputDigest": "current",
                "resultBundleIdentity": stored,
                "summary": {"passed": True},
                "recordedAt": utc_now().isoformat(),
            }
            report = {"groups": {group: row}}
            with (
                patch.object(module, "report_lock", side_effect=nullcontext),
                patch.object(module, "input_identity", return_value="current"),
                patch.object(module, "complete_summary", return_value=True),
                patch.object(module, "complete_environment", return_value=True),
                patch("validation_coverage.policy_floors", return_value={}),
                patch.object(module, "result_bundle_findings", wraps=result_bundle_findings),
                patch("validation_performance.bundle_identity", side_effect=mock_identity),
                patch.object(Path, "is_file", return_value=True),
                patch.object(Path, "read_text", return_value=json.dumps(report)),
                patch.object(sys, "argv", ["evidence", "check-group", group]),
                redirect_stderr(StringIO()),
            ):
                assert module.main() == int(stored != raw)


def check_group_coverage_policy_self_test(module) -> None:
    for group in ("modules", "all", "ui", "catalyst"):
        name = (
            "GalleryFeature"
            if group == "modules"
            else "Catalyst/GalleryFeature"
            if group == "catalyst"
            else "iOS/GalleryFeature"
        )
        for selected in (False, True):
            for floor, covered, expected in ((70, 74, 0), (75, 74, 1), (75, 75, 0)):
                full = {
                    "scope": "full",
                    "exitCode": 0,
                    "runID": "full",
                    "inputDigest": "current",
                    "environment": {},
                    "recordedAt": utc_now().isoformat(),
                    "summary": {
                        "passed": True,
                        "coverage": {name: {"coveredLines": covered, "executableLines": 100}},
                    },
                }
                row = (
                    dict(
                        full,
                        scope="selected",
                        lastFullRun=full,
                        summary={
                            "passed": True,
                            "coverage": {name: {"coveredLines": 100, "executableLines": 100}},
                        },
                    )
                    if selected
                    else full
                )
                report = {
                    "groups": {group: row},
                    "coveragePolicy": {
                        "modules" if group == "modules" else "all": {"GalleryFeature": floor}
                    },
                }
                with (
                    patch.object(module, "input_identity", return_value="current"),
                    patch.object(module, "report_lock", side_effect=nullcontext),
                    patch.object(module, "complete_summary", return_value=True),
                    patch.object(module, "complete_environment", return_value=True),
                    patch("validation_policy.MODULE_COVERAGE_FLOORS", {"GalleryFeature": 70}),
                    patch("validation_policy.IOS_MODULE_COVERAGE_FLOORS", {"GalleryFeature": 70}),
                    patch("validation_policy.UI_PRODUCTION_MODULES", frozenset({"GalleryFeature"})),
                    patch.object(Path, "is_file", return_value=True),
                    patch.object(Path, "read_text", return_value=json.dumps(report)),
                    patch.object(sys, "argv", ["validation_evidence.py", "check-group", group]),
                    redirect_stderr(StringIO()),
                ):
                    assert module.main() == expected, (group, selected, floor, covered)


def artifact_lock_self_test(module) -> None:
    source = (module.ROOT / "Scripts/validation_artifacts.py").read_text()
    import fcntl

    diagnostics = module.ROOT / ".build/extended-automation/diagnostics"
    for names in (
        (),
        ("test-results.xcresult",),
        ("exported.log",),
        ("test-results.xcresult", "exported.log"),
    ):
        retained = set(names)

        def mock_iterdir(path):
            if path == diagnostics:
                return iter([diagnostics / name for name in tuple(retained)])
            return iter(())

        with (
            patch.object(sys, "argv", ["validation_artifacts.py", str(module.ROOT)]),
            patch.dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1"),
            patch.object(Path, "exists", lambda path: bool(names) and path == diagnostics),
            patch.object(Path, "is_dir", return_value=False),
            patch.object(Path, "iterdir", side_effect=mock_iterdir),
            patch.object(Path, "unlink", lambda path, **kwargs: retained.discard(path.name)),
            patch.object(Path, "open", return_value=nullcontext(BytesIO())),
            patch.object(os, "walk", return_value=[]),
            patch.object(fcntl, "flock", side_effect=BlockingIOError),
            redirect_stdout(StringIO()),
        ):
            status = 0
            namespace = {"__name__": "artifact_cleanup_fixture"}
            try:
                exec(compile(source, "validation_artifacts.py", "exec"), namespace)
                namespace["clear_diagnostic_exports"](diagnostics)
            except SystemExit as error:
                status = error.code
            assert status == 0 and retained == set(names) - {"exported.log"}, (
                "诊断导出清理保留原始编译失败包"
            )
    definition = next(
        node
        for node in ast.parse(source).body
        if isinstance(node, ast.FunctionDef) and node.name == "committed_children"
    )
    harness = "from pathlib import Path\nimport fcntl, sys\n" + ast.get_source_segment(
        source, definition
    )
    harness += (
        '\nprint("ready", flush=True)\nchildren = committed_children(Path(sys.argv[1]))\nassert al'
        'l(path.suffix != ".incoming" for path in children)\nprint("committed", flush=True)\n'
    )
    for report in (
        module.REPORT,
        module.ROOT / ".build/icloud-cross-device-smoke/report.json",
        module.ROOT / ".build/static-audit/compilation-conditions.json",
    ):
        incoming = report.with_suffix(".incoming")
        with module.report_lock(path=report):
            incoming.write_text("pending atomic report")
            child = subprocess.Popen(
                [sys.executable, "-B", "-c", harness, str(report.parent)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                assert child.stdout.readline().strip() == "ready"
                try:
                    child.communicate(timeout=0.2)
                except subprocess.TimeoutExpired:
                    pass
                else:
                    raise AssertionError("产物扫描需要等待验证报告原子写入锁")
            finally:
                incoming.unlink()
        output, error = child.communicate(timeout=10)
        assert child.returncode == 0 and output.strip() == "committed", error


def baseline_policy_self_test(module) -> None:
    report = {
        "coverageBaseCommit": "target",
        "coveragePolicy": {
            "modules": {"Feature": 80},
            "all": {"Feature": 70, "BIT101-iOS.app": 60},
        },
        "groups": {},
    }
    for fault in ("none", "commit", "missing", "missing-app", "value", "extra"):
        candidate = json.loads(json.dumps(report))
        if fault == "commit":
            candidate["coverageBaseCommit"] = "other"
        if fault == "missing":
            candidate["coveragePolicy"].pop("all")
        if fault == "missing-app":
            candidate["coveragePolicy"]["all"].pop("BIT101-iOS.app")
        if fault == "value":
            candidate["coveragePolicy"]["all"]["Feature"] = True
        if fault == "extra":
            candidate["coveragePolicy"]["audit"] = {"Feature": 70}
        with (
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "read_text", return_value=json.dumps(candidate)),
            patch.object(module, "write_report") as saved,
            redirect_stderr(StringIO()),
        ):
            assert module.inspect_report(SimpleNamespace(action="baseline", group="target")) == (
                0 if fault == "none" else 1
            )
        if fault == "none":
            actual = saved.call_args.args[0]
            assert actual["groups"] == {} and actual["coveragePolicy"] == report["coveragePolicy"]
            from validation_coverage import regressions, policy_floors

            with patch("validation_policy.IOS_MODULE_COVERAGE_FLOORS", {"Feature": 60}):
                assert regressions(
                    {"iOS/Feature": {"coveredLines": 69, "executableLines": 100}},
                    policy_floors("all", actual["coveragePolicy"]),
                ) == ["iOS/Feature: 69% < 70%"]
        else:
            saved.assert_not_called()


def selected_coverage_self_test(module) -> None:
    full = {
        "scope": "full",
        "exitCode": 0,
        "inputDigest": "digest",
        "runID": "full",
        "summary": {
            "passed": True,
            "coverage": {"iOS/Feature": {"coveredLines": 95, "executableLines": 100}},
        },
    }
    report = {"groups": {"all": full}}
    for scope, expected in (("selected", 0), ("selected", 0), ("full", 0), ("full", 1)):
        if expected:
            report["coveragePolicy"] = {"all": {"Feature": 95}}
        summary = {
            "passed": True,
            "totalTests": 1,
            "passedTests": 1,
            "failedTests": 0,
            "skippedTests": 0,
            "executedTests": ["Suite/testRun"],
            "coverage": {"iOS/Feature": {"coveredLines": 94, "executableLines": 100}},
        }
        summary["testCases"] = {
            "passed": True,
            "total": 1,
            "byTest": {"Suite/testRun": 1},
            "expectedByTest": {"Suite/testRun": 1},
            "destinations": [{"platform": "iOS", "deviceIdentifier": "fixture-device"}],
            "identifiersByTest": {
                "Suite/testRun": ["test://com.apple.xcode/BIT101-iOS/BIT101-iOSTests/Suite/testRun"]
            },
        }
        with (
            patch.object(module, "input_identity", return_value="digest"),
            patch.object(module, "complete_environment", return_value=True),
            patch.object(module, "report_lock", side_effect=nullcontext),
            patch.object(module, "write_report") as saved,
            patch.object(module, "test_summary", return_value=summary),
            patch.object(module, "complete_summary", return_value=True),
            patch.object(module, "test_case_inventory", return_value={"Suite/testRun": 1}),
            patch.object(module, "test_inventory", return_value={"Suite/testRun"}),
            patch.object(Path, "is_file", return_value=True),
            patch.object(
                Path,
                "read_text",
                side_effect=["验证输入：digest\n验证运行：run\n", json.dumps(report)],
            ),
            patch.object(subprocess, "check_output", return_value="head"),
            patch("validation_performance.bundle_identity", return_value="a" * 64),
            patch("validation_performance.current_commit", return_value="head"),
            patch("validation_policy.IOS_MODULE_COVERAGE_FLOORS", {"Feature": 94}),
            patch("validation_performance.extract_measurements", return_value={}),
            patch.dict(
                os.environ,
                BIT101_VALIDATION_RUN_ID="run",
                BIT101_VALIDATION_EXPECTED_TESTS='["Suite/testRun"]',
            ),
            redirect_stderr(StringIO()),
        ):
            assert module.record("all", 0, scope, "digest") == expected
        report = saved.call_args.args[0]
        row = report["groups"]["all"]
        assert "coverageBaseline" not in row
        if scope == "selected":
            assert row["lastFullRun"] == full
        elif expected:
            assert row["summary"]["coverageRegressions"] and row["summary"]["passed"] is False
        else:
            assert row["summary"]["passed"] is True


def aggregate_failure_self_test(module) -> None:
    from script_test_support import shell_function

    support = module.ROOT / "Scripts/script-support.sh"
    step = (
        shell_function(support, "bit101_check_verification_audit")
        + "\n"
        + shell_function(support, "bit101_verify_step")
    )
    for command_status, evidence_status in ((0, 0), (7, 0), (0, 7)):
        harness = f"""ROOT_DIR=/repo
SECONDS=0
completed_result_groups=()
command() {{ return {command_status}; }}
python3() {{ if [[ "$2" == check-group ]]; then return {evidence_status}; fi; return 0; }}
"""
        result = subprocess.run(
            ["zsh", "-c", harness + step + "\nbit101_verify_step all command\nprint next-group"],
            capture_output=True,
            text=True,
        )
        assert (result.returncode == 0) == (command_status == evidence_status == 0)
        assert ("next-group" in result.stdout) == (result.returncode == 0)


def complete_run_reuse_self_test(module=None) -> None:
    from copy import deepcopy
    from validation_provenance import complete_group_row

    full = {
        "scope": "full",
        "exitCode": 0,
        "summary": {"passed": True},
        "inputDigest": "same",
        "environment": {"device": "phone"},
    }
    selected = dict(full, scope="selected", lastFullRun=full)
    assert complete_group_row(selected) is full
    for name, value in [
        ("exitCode", 1),
        ("inputDigest", "changed"),
        ("environment", {"device": "other"}),
        ("summary", {"passed": False}),
    ]:
        changed = dict(selected, **{name: value})
        assert complete_group_row(changed) is changed
    changed = deepcopy(selected)
    changed["lastFullRun"]["exitCode"] = 1
    assert complete_group_row(changed) is changed
    from validation_environment import exchange_identity

    context = {"developer": "/fixture/Xcode", "device": {"identifier": "phone"}}
    shared_full = dict(full, environment=exchange_identity(context))
    selected = dict(full, scope="selected", environment=context, lastFullRun=shared_full)
    assert complete_group_row(selected) is shared_full
    changed = dict(selected, environment=context | {"device": {"identifier": "other"}})
    assert complete_group_row(changed) is changed
    if module is None:
        return
    full = dict(full, environment={})
    report = {"groups": {"network": full}}
    for status, scope, reusable in (
        (0, "selected", True),
        (1, "selected", False),
        (0, "selected", False),
        (0, "full", True),
    ):
        with (
            patch.object(module, "input_identity", return_value="same"),
            patch.object(module, "environment_context", return_value={}),
            patch.object(module, "complete_environment", return_value=True),
            patch.object(module, "report_lock", side_effect=nullcontext),
            patch.object(module, "write_report") as saved,
            patch.object(module, "smoke_summary", return_value={"passed": True}),
            patch.object(module, "complete_summary", return_value=True),
            patch.object(Path, "is_file", return_value=True),
            patch.object(
                Path,
                "read_text",
                side_effect=[json.dumps({"runID": "fixture"}), json.dumps(report)],
            ),
            patch.object(module.subprocess, "check_output", return_value="head"),
            patch.dict(os.environ, BIT101_VALIDATION_RUN_ID="fixture"),
            redirect_stderr(StringIO()),
        ):
            assert module.record("network", status, scope, "same") == status
        report = saved.call_args.args[0]
        row = report["groups"]["network"]
        assert (complete_group_row(row).get("scope") == "full") == reusable, row


def worker_cli_diagnostics_self_test() -> None:
    from validation_provenance import worker_cli_json, workflow_elapsed_seconds, WORKER_LOG

    result = subprocess.CompletedProcess(
        [], 1, "", "ERROR: fixture authentication requires a configured credential\n"
    )
    with patch.object(subprocess, "run", return_value=result):
        try:
            worker_cli_json("ErrorReportWorker", "deployments", "status")
        except ValueError as error:
            assert "fixture authentication" in str(error) and str(WORKER_LOG) in str(error)
        else:
            raise AssertionError("CLI failure needs its actionable diagnostic")
    for value, expected in [("0", 0), ("12.5", 12.5), ("nan", None), ("-1", None)]:
        with patch.dict(os.environ, BIT101_VALIDATION_ELAPSED_SECONDS=value):
            if expected is None:
                try:
                    workflow_elapsed_seconds()
                except ValueError:
                    pass
                else:
                    raise AssertionError("Workflow timing requires finite nonnegative seconds")
            else:
                assert workflow_elapsed_seconds() == expected
