"""Check structured validation evidence."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch
from swift_source_index import swift_syntax_index_sources


from validation_record_samples import (
    _always_true as _always_true,
    _check_recorded_summary as _check_recorded_summary,
    _make_malformed_coverage as _make_malformed_coverage,
    _matching_post_requests as _matching_post_requests,
    _run_network_record_case as _run_network_record_case,
    icloud_stage_fixture as icloud_stage_fixture,
    native_case_fixture as native_case_fixture,
    network_recording_self_test as network_recording_self_test,
)

from validation_inputs import self_test as input_self_test
from validation_performance_tests import run_self_test as performance_self_test


def verify_workflow_inputs(subject, fixture_environment):
    core, current_digest, module_name, relocated = verify_build_workflow_inputs(
        fixture_environment, subject
    )
    compiler = verify_restoration_workflow_inputs(
        core, current_digest, fixture_environment, module_name, relocated, subject
    )
    return compiler


def verify_test_inventory(subject, stable_inputs):
    fixture, module_name = verify_selected_test_inventory(subject)
    icloud_summary, test = verify_audit_test_inventory(fixture, subject)
    verify_test_fixture_inventory(module_name, stable_inputs, subject, test)
    return test, icloud_summary


def verify_build_workflow_inputs(fixture_environment, subject):
    module_name = subject.__name__
    from validation_provenance_tests import run_self_test as provenance_self_test
    from validation_test_areas import inventory_findings

    provenance_self_test(subject.record)
    from validation_manual_tests import (
        run_self_test as manual_self_test,
    )

    manual_self_test()
    performance_self_test()
    from validation_restore import self_test as restore_self_test

    restore_self_test()
    from validation_coverage import self_test as coverage_self_test

    coverage_self_test(subject)
    from ci_evidence import self_test as ci_evidence_self_test

    ci_evidence_self_test()
    from validation_publication import self_test as publication_self_test

    publication_self_test()
    from validation_merge import findings as merge_findings
    from validation_provenance import utc_now

    core = {
        "mergeCommit": "commit",
        "groups": {
            name: {
                "exitCode": 0,
                "scope": "full",
                "summary": {},
                "inputDigest": "digest",
                "environment": fixture_environment,
                "recordedAt": utc_now().isoformat(),
            }
            for name in ("all", "release-runtime", "ui", "restore")
        },
    }
    core["groups"]["restore"]["summary"] = {"runID": "run", "inputDigest": "digest"}
    core["groups"]["restore"]["runID"] = "run"
    assert not merge_findings(
        core,
        digest=lambda *args, **kwargs: "digest",
        complete=lambda *args: True,
        commit="commit",
    )
    regressed = json.loads(json.dumps(core))
    regressed["coverageBaseCommit"] = "base"
    regressed["coveragePolicy"] = {"all": {"GalleryFeature": 50}}
    regressed["groups"]["ui"]["runID"] = "ui-run"
    regressed["groups"]["ui"]["summary"] = {
        "passed": True,
        "coverage": {"iOS/GalleryFeature": {"coveredLines": 20, "executableLines": 100}},
    }
    assert any(
        "ui 覆盖率退化" in error
        for error in merge_findings(
            regressed,
            digest=lambda *args, **kwargs: "digest",
            complete=lambda *args: True,
            commit="commit",
        )
    )
    from contextlib import nullcontext, redirect_stderr, redirect_stdout
    from io import StringIO

    for action, expected in (("check-group", 1), ("summary", 0)):
        output = StringIO()
        arguments = ["validation_evidence.py", action] + (["ui"] if action == "check-group" else [])
        with (
            patch.object(subject, "report_lock", side_effect=nullcontext),
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "read_text", return_value=json.dumps(regressed)),
            patch.object(sys, "argv", arguments),
            patch.object(subject, "input_identity", return_value="digest"),
            patch.object(subject, "evidence_current", return_value=True),
            patch.object(subject, "complete_summary", return_value=True),
            patch.dict(os.environ, GITHUB_STEP_SUMMARY=""),
            redirect_stdout(output),
            redirect_stderr(output),
        ):
            assert subject.main() == expected
        if action == "summary":
            assert "| ui | full | 待处理 |" in output.getvalue()
    from validation_restore import invalidate as invalidate_restore
    from contextlib import nullcontext
    import validation_provenance as evidence_state

    with (
        patch.object(evidence_state, "report_lock", side_effect=nullcontext),
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_text", return_value=json.dumps(core)),
        patch.object(evidence_state, "write_report") as saved,
    ):
        invalidate_restore()
        interrupted = saved.call_args.args[0]
        assert any(
            error.startswith("restore ")
            for error in merge_findings(
                interrupted,
                digest=lambda *args, **kwargs: "digest",
                complete=lambda *args: True,
                commit="commit",
            )
        )
    with patch("validation_merge.performance_findings", return_value=["性能退化"]):
        assert merge_findings(
            core,
            digest=lambda *args, **kwargs: "digest",
            complete=lambda *args: True,
            commit="commit",
        ) == ["性能退化"]
    for name in core["groups"]:
        broken = json.loads(json.dumps(core))
        broken["groups"][name]["exitCode"] = 1
        assert merge_findings(
            broken,
            digest=lambda *args, **kwargs: "digest",
            complete=lambda *args: True,
            commit="commit",
        )
    assert merge_findings(
        core,
        digest=lambda *args, **kwargs: "changed",
        complete=lambda *args: True,
        commit="commit",
    )
    assert merge_findings(
        core,
        digest=lambda *args, **kwargs: "digest",
        complete=lambda *args: True,
        commit="other",
    )
    current_digest = lambda group, *, environment=None: (
        "digest" if environment else "new-environment"
    )
    assert merge_findings(core, digest=current_digest, complete=lambda *args: True, commit="commit")
    assert not merge_findings(
        core,
        digest=current_digest,
        complete=lambda *args: True,
        commit="commit",
        recorded_environment=True,
    )
    relocated = dict(
        fixture_environment,
        host={"system": "other-host"},
        developer="/other/Xcode",
        device=None,
        compiler=dict(fixture_environment["compiler"], path="/other/swift-frontend", modified=2),
    )
    return core, current_digest, module_name, relocated


def verify_restoration_workflow_inputs(
    core, current_digest, fixture_environment, module_name, relocated, subject
):
    from validation_test_areas import inventory_findings
    from validation_merge import findings as merge_findings

    with patch("validation_merge.environment_context", return_value=relocated):
        assert not merge_findings(
            core,
            digest=current_digest,
            complete=lambda *args: True,
            commit="commit",
            recorded_environment=True,
        )
    for field, value in (
        ("compiler", dict(fixture_environment["compiler"], version="b" * 64)),
        ("sdks", {"fixture": {"Version": "2"}}),
        ("xcode", {"version": "other"}),
    ):
        with patch(
            "validation_merge.environment_context",
            return_value=dict(fixture_environment, **{field: value}),
        ):
            assert any(
                "当前 CI" in error
                for error in merge_findings(
                    core,
                    digest=current_digest,
                    complete=_always_true,
                    commit="commit",
                    recorded_environment=True,
                )
            )
    for name in core["groups"]:
        mixed = json.loads(json.dumps(core))
        mixed["groups"][name]["environment"]["sdks"] = {"fixture": {"Version": "2"}}
        assert merge_findings(
            mixed,
            digest=current_digest,
            complete=lambda *args: True,
            commit="commit",
            recorded_environment=True,
        )
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO

    for accepted_commit, expected in (("commit", 0), ("other", 1)):
        with (
            patch.object(
                sys, "argv", ["validation_evidence.py", "check-merge", "--recorded-environment"]
            ),
            patch.object(subject, "report_lock", side_effect=nullcontext),
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "read_text", return_value=json.dumps(core)),
            patch.object(subprocess, "check_output", return_value=accepted_commit),
            patch.object(subject, "input_identity", return_value="digest"),
            patch.object(subject, "complete_summary", return_value=True),
            redirect_stderr(StringIO()),
        ):
            assert subject.main() == expected
    from ui_inventory import self_test as ui_inventory_self_test

    ui_inventory_self_test()
    all_suites = {test.split("/", 1)[0] for test in subject.test_inventory("all")}
    assert inventory_findings(all_suites) == []
    assert inventory_findings(all_suites | {"NewFeatureTests"})
    import validation_inputs

    names = validation_inputs.repository_input_names(subject.ROOT)
    baseline_cases = subject.test_case_inventory("all")
    subject.test_case_inventory.cache_clear()
    with patch(
        "validation_inputs.repository_input_names",
        return_value=[*names, "BIT101-iOS/Removed.swift"],
    ):
        assert subject.test_case_inventory("all") == baseline_cases
    subject.test_case_inventory.cache_clear()
    for group in ("infrastructure", "login"):
        assert any(
            (
                test.startswith("SchoolCookieIsolationTests/")
                for test in subject.test_inventory(group)
            )
        )
    with (
        patch.object(sys, "argv", ["validation_evidence.py", "record", "audit", "7"]),
        patch.dict(os.environ, BIT101_VALIDATION_INPUT_IDENTITY="fixture-input"),
        patch(f"{module_name}.record", return_value=7) as recorder,
    ):
        assert subject.main() == 7
        recorder.assert_called_once_with("audit", 7, "full", "fixture-input")
    input_self_test()
    from validation_environment import toolchain_identity

    compiler = fixture_environment["compiler"]
    relocated = dict(compiler, path="/other-host/swift-frontend", modified=2)
    assert toolchain_identity(fixture_environment) == toolchain_identity(
        dict(fixture_environment, compiler=relocated)
    )
    assert toolchain_identity(fixture_environment) != toolchain_identity(
        dict(fixture_environment, compiler=dict(compiler, version="b" * 64))
    )
    from contextlib import redirect_stdout
    from io import StringIO

    output = StringIO()
    with (
        patch.object(sys, "argv", ["validation_evidence.py", "verify-defaults"]),
        redirect_stdout(output),
    ):
        assert subject.main() == 0
    assert output.getvalue().splitlines() == list(subject.DEFAULT_VERIFY_GROUPS)
    with patch.object(subprocess, "check_output", return_value=b""):
        baseline = subject.input_identity("ui")
        for field, value in (
            ("host", {"system": "changed"}),
            ("xcode", {"version": "changed"}),
            ("sdks", {"fixture": {"Version": "2"}}),
            ("compiler", {"modified": 2}),
            (
                "device",
                {
                    "identifier": "changed",
                    "systemVersion": "fixture-os",
                    "systemBuild": "fixture-build",
                },
            ),
            (
                "device",
                {
                    "identifier": "fixture-phone",
                    "systemVersion": "changed",
                    "systemBuild": "fixture-build",
                },
            ),
        ):
            with patch(
                "validation_provenance.environment_context",
                return_value=dict(fixture_environment, **{field: value}),
            ):
                assert subject.input_identity("ui") != baseline
        assert not subject.complete_environment("ui", dict(fixture_environment, device=None))
        assert not subject.complete_environment("audit", {})
        audit_digest = subject.input_identity("audit")
        for name in fixture_environment["runtimes"]:
            runtimes = dict(fixture_environment["runtimes"], **{name: "changed-version"})
            with patch(
                "validation_provenance.environment_context",
                return_value=dict(fixture_environment, runtimes=runtimes),
            ):
                assert subject.input_identity("audit") != audit_digest
            for value in ("", None):
                assert not subject.complete_environment(
                    "audit", dict(fixture_environment, runtimes=dict(runtimes, **{name: value}))
                )
            del runtimes[name]
            assert not subject.complete_environment(
                "audit", dict(fixture_environment, runtimes=runtimes)
            )
    assert subject.compilation_condition("os(macOS) && !canImport(UIKit)", "modules")
    return compiler


def verify_selected_test_inventory(subject):
    module_name = subject.__name__
    assert subject.compilation_condition("canImport(SwiftUI) && canImport(AppKit)", "modules")
    for group in ("modules", "all", "catalyst", "ui"):
        assert subject.compilation_condition(
            "canImport(MapKit) && canImport(WidgetKit) && canImport(CoreLocation)", group
        )
    assert not subject.compilation_condition("canImport(UnregisteredFramework)", "all")
    from validation_compilation import local_import_conditions

    for condition in (
        "canImport(StorageCore, _version: 0.0)",
        "canImport(StorageCore, _version: 1.0)",
        "canImport(StorageCore, _underlyingVersion: 1.0)",
    ):
        try:
            local_import_conditions(condition, "Modules/MediaKit/Sources/MediaEnvironment.swift")
        except ValueError as error:
            assert "显式版本编译上下文" in str(error)
        else:
            raise AssertionError("本地版本条件应进入显式诊断")
    assert (
        local_import_conditions("canImport(Foundation, _version: 0.0)")
        == "canImport(Foundation, _version: 0.0)"
    )
    assert subject.compilation_condition("swift(>=5.0) && compiler(>=5.0)", "all")
    assert subject.compilation_condition("swift(>=6.0)", "all")
    assert not subject.compilation_condition("swift(>=6.0)", "all", language_mode="5")
    assert subject.compilation_condition(
        "swift(>=5.0) && !swift(>=6.0)", "modules", language_mode="5"
    )
    assert subject.compilation_condition("swift(>=6.0)", "modules", language_mode="6")
    try:
        subject.compilation_condition("unsupportedPredicate(value)", "all")
    except ValueError:
        pass
    else:
        raise AssertionError("Swift 编译器需要拒绝无效编译谓词")
    assert subject.compilation_condition(
        "os(iOS) && targetEnvironment(macCatalyst) && canImport(UIKit)", "catalyst"
    )
    assert subject.compilation_condition("os(iOS) && !targetEnvironment(macCatalyst)", "all")
    assert subject.compilation_condition(
        "os(watchOS) && canImport(WatchKit)", "network", platform="watchOS"
    )
    assert not subject.compilation_condition("os(iOS)", "network", platform="watchOS")
    assert not subject.compilation_condition("os(watchOS)", "network", platform="iOS")
    assert subject.compilation_condition("DEBUG || RELEASE_NETWORK_SMOKE", "all")
    assert not subject.compilation_condition("os(macOS) || targetEnvironment(macCatalyst)", "all")
    assert subject.compilation_condition(
        "BIT101_UI_TESTING && !targetEnvironment(macCatalyst)", "ui"
    )
    assert subject.compilation_condition("DEBUG && ICLOUD_CROSS_DEVICE_SMOKE", "icloud")
    assert subject.compilation_condition("DEBUG && ICLOUD_CROSS_DEVICE_SMOKE", "build-icloud-smoke")
    assert not subject.compilation_condition("DEBUG", "release")
    assert subject.compilation_condition(
        "EXTENDED_AUTOMATION && BIT101_AUTOMATED_TESTING && BIT101_UI_TESTING && !DEBUG", "ui"
    )
    from ui_rules import check_ui_test_inventory

    original_rglob, original_read = (Path.rglob, Path.read_text)
    ui_root = subject.ROOT / "BIT101-iOSUITests"
    sample_path = ui_root / "Additional/Nested.swift"
    for declaration in (
        "final class FormatUITests: XCTestCase {\n  func testAdded() {}\n}",
        "final\nclass FormatUITests\n: XCTestCase {\n    func testAdded() {}\n}",
    ):

        def sample_read(path, *args, **kwargs):
            if path == sample_path:
                return declaration
            if path == subject.ROOT / "docs/UI_INTERACTION_COVERAGE.md":
                return ""
            return original_read(path, *args, **kwargs)

        def sample_rglob(path, pattern):
            if path == ui_root:
                return iter([sample_path])
            return original_rglob(path, pattern)

        subject.test_selectors.cache_clear()
        subject.test_inventory.cache_clear()
        errors = []
        with (
            patch.object(Path, "rglob", sample_rglob),
            patch.object(Path, "read_text", sample_read),
        ):
            check_ui_test_inventory(errors, {})
        assert "UI interaction map missing: FormatUITests/testAdded" in errors
        selector = re.search(
            "bit101_ui_test_selections\\(\\).*?<<'PY'\\n(.*?)\\nPY",
            (subject.ROOT / "Scripts/script-support.sh").read_text(),
            re.DOTALL,
        )[1]
        with (
            patch(
                ("validation_result_readers.test_inventory"),
                return_value={("FormatUITests/testAdded")},
            ),
            patch(
                ("validation_evidence.test_inventory"), return_value={("FormatUITests/testAdded")}
            ),
            patch.object(
                sys,
                "argv",
                ["selector", str(subject.ROOT / "Scripts"), "Added", "FormatUITests"],
            ),
            patch("builtins.print") as output,
        ):
            exec(compile(selector, "<ui selector>", "exec"), {})
        output.assert_called_once_with("FormatUITests/testAdded")
    subject.test_selectors.cache_clear()
    subject.test_inventory.cache_clear()
    with patch.object(
        os,
        "uname",
        return_value=os.uname_result(("Darwin", "host", "release", "version", "x86_64")),
    ):
        subject.compilation_condition.cache_clear()
        for group in ("modules", "catalyst"):
            assert subject.compilation_condition("arch(x86_64) && !arch(arm64)", group)
        assert subject.compilation_condition("arch(arm64) && !arch(x86_64)", "all")
    subject.compilation_condition.cache_clear()
    conditional = "#if targetEnvironment(macCatalyst)\n中文手势\n#else\niOSGesture()\n#endif\n"
    active = subject.active_swift_source(conditional, "ui")
    assert (
        len(active.encode()) == len(conditional.encode())
        and "中文手势" not in active
        and ("iOSGesture()" in active)
    )
    unicode_sources = {}
    for index, separator in enumerate(["\u2028", "\u2029", "\x0b", "\x0c", "\x85"]):
        source = (
            f"// fixture"
            f"{separator}"
            f"// trailing\r\n#if DEBUG\r\n@Test func mustRun() {{}}\r\n#else\r\n@Test func ina"
            f"ctive() {{}}\r\n#endif\r\n"
        )
        filtered = subject.active_swift_source(source, "catalyst")
        assert len(filtered.encode()) == len(source.encode())
        unicode_sources[f"unicode-inventory-{index}"] = filtered
    for facts in swift_syntax_index_sources(unicode_sources).values():
        assert not facts["hasParseErrors"] and [test["value"] for test in facts["tests"]] == [
            "mustRun"
        ]
    for literal in [
        "/*\n#if DEBUG\n*/",
        "/* outer /* nested */\n#if DEBUG\n*/",
        '"""\n#if DEBUG\n"""',
        '#"""\n#if DEBUG\n"""#',
    ]:
        source = literal + "\n@Test func realTest() {}\n"
        assert "@Test func realTest" in subject.active_swift_source(source, "modules")
    fixture = subject.ROOT / ".build/static-audit/source-digest-self-test.sh"
    fixture.parent.mkdir(parents=True, exist_ok=True)
    return fixture, module_name


def verify_audit_test_inventory(fixture, subject):
    try:
        fixture.write_text("exit 0\n")
        with patch.object(
            subprocess,
            "check_output",
            return_value=fixture.relative_to(subject.ROOT).as_posix().encode(),
        ):
            fixture.chmod(384)
            original = subject.input_identity()
            fixture.chmod(448)
            assert subject.input_identity() != original
    finally:
        fixture.unlink(missing_ok=True)
    from types import SimpleNamespace

    inputs = {
        "README.md": b"documentation",
        "Modules/StorageCore/Sources/AppFileService.swift": b"product",
        "ModuleTests/Sync/ScheduleSyncTests.swift": b"test",
    }
    with (
        patch.object(subprocess, "check_output", return_value="\x00".join(inputs).encode()),
        patch.object(Path, "is_file", return_value=True),
        patch.object(
            Path, "read_bytes", lambda path: inputs[path.relative_to(subject.ROOT).as_posix()]
        ),
        patch.object(Path, "stat", return_value=SimpleNamespace(st_mode=420)),
    ):
        before = {
            group: subject.input_identity(group) for group in ("audit", "modules", "manual-device")
        }
        inputs["README.md"] = b"updated documentation"
        assert subject.input_identity("audit") != before["audit"]
        assert subject.input_identity("modules") == before["modules"]
        assert subject.input_identity("manual-device") == before["manual-device"]
        inputs["ModuleTests/Sync/ScheduleSyncTests.swift"] = b"updated test"
        assert subject.input_identity("modules") != before["modules"]
        assert subject.input_identity("manual-device") == before["manual-device"]
        inputs["Modules/StorageCore/Sources/AppFileService.swift"] = b"updated product"
        assert subject.input_identity("manual-device") != before["manual-device"]
    from swift_source_index import SWIFT_SYNTAX_SOURCE_NAMES

    inputs = {"Scripts/" + name: b"indexer source" for name in SWIFT_SYNTAX_SOURCE_NAMES}
    groups = (
        subject.RELEASE_GROUPS
        | subject.TEST_GROUPS
        | {"network", "icloud", "manual-device", "build-archive"}
    )
    with (
        patch("validation_provenance.repository_input_names", return_value=list(inputs)),
        patch("validation_provenance._clean_source_identity", return_value=None),
        patch.object(Path, "is_file", return_value=True),
        patch.object(
            Path, "read_bytes", lambda path: inputs[path.relative_to(subject.ROOT).as_posix()]
        ),
        patch.object(Path, "stat", return_value=SimpleNamespace(st_mode=420)),
    ):
        for name in inputs:
            before = {group: subject.input_identity(group, environment={}) for group in groups}
            inputs[name] += b" changed facts"
            sampling = subject.NETWORK_GROUPS | {"network-smoke", "icloud", "icloud-cleanup"}
            assert all(
                (subject.input_identity(group, environment={}) != before[group])
                == (group != "manual-device" and group not in sampling)
                for group in groups
            ), name

    def icloud_summary(value):
        return subject.smoke_summary(
            "icloud",
            dict(
                validatedDomains=sorted(subject.ICLOUD_DOMAINS),
                cloudKitEnvironment="Production",
                runID="fixture",
                **value,
            ),
        )

    test = {
        "passed": True,
        "totalTests": 1,
        "passedTests": 1,
        "failedTests": 0,
        "skippedTests": 0,
    }
    nested = swift_syntax_index_sources(
        {
            "nested-tests": (
                "@Suite struct Outer { @Suite struct Inner { @Testing.Test func works() {}; fu"
                "nc testHelper() {} } }; class Base: XCTestCase {}; class Case: Base { func te"
                "stActual() {}; func testArgument(_ value: Int) {}; static func testStatic() {"
                "} }; struct Ordinary { func testHelper() {} }"
            )
        }
    )["nested-tests"]
    assert {item["value"] for item in nested["tests"]} == {
        "Outer/Inner/works",
        "Case/testActual",
    }
    aliased = swift_syntax_index_sources(
        {
            "base": (
                "typealias BehaviorBase = XCTest.XCTestCase; enum Namespace { typealias Base ="
                " BehaviorBase }; class Direct: XCTestCase {}; typealias Indirect = Direct"
            ),
            "tests": (
                "class MissingTests: Namespace.Base { func testRequiredBehavior() {} }; class "
                "Derived: Indirect { func testInheritedBehavior() {} }; enum Other { typealias"
                " Base = Ordinary; class Local: Base { func testHelper() {} } }; class Ordinar"
                "y {}"
            ),
        }
    )["tests"]
    assert {item["value"] for item in aliased["tests"]} == {
        "MissingTests/testRequiredBehavior",
        "Derived/testInheritedBehavior",
    }
    from code_quality_rules import audit_callback_findings, audit_wiring_findings

    audit_path = subject.ROOT / "Scripts/run-static-audit.sh"
    audit_source, original_read = (audit_path.read_text(), Path.read_text)
    assert audit_callback_findings(audit_source) == []
    for callback in ("module_boundary_audit", "artifact_hygiene"):
        for body in (
            "true;",
            "python3 /unrelated.py;",
            'python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"; true;',
        ):
            mutated = re.sub(
                r"(?m)^" + callback + r"\(\).*$", callback + "() { " + body + " }", audit_source
            )
            assert audit_callback_findings(mutated)
    for before, after in (
        ("module_boundary_audit git_check", "swift_parse git_check"),
        (
            "bit101_run_audit_group artifact-hygiene artifact_hygiene",
            "bit101_run_audit_group artifact-hygiene swift_parse",
        ),
    ):

        def mutated_read(path, *arguments, **keywords):
            return (
                audit_source.replace(before, after)
                if path == audit_path
                else original_read(path, *arguments, **keywords)
            )

        with patch.object(Path, "read_text", mutated_read):
            assert any(("静态审计回调" in finding for finding in audit_wiring_findings()))
    return icloud_summary, test


def verify_test_fixture_inventory(module_name, stable_inputs, subject, test):
    with (
        patch(("validation_result_readers.test_inventory"), return_value={("Outer/Inner/works")}),
        patch(module_name + (".test_inventory"), return_value={("Outer/Inner/works")}),
        patch(
            ("validation_result_readers.test_case_inventory"),
            return_value={("Outer/Inner/works"): 1},
        ),
        patch(module_name + (".test_case_inventory"), return_value={("Outer/Inner/works"): 1}),
        patch(module_name + ".coverage_complete", return_value=True),
    ):
        for identifier in (
            "Package.Outer/Inner/works()",
            "Package.Outer/Inner/works()/Example.swift:1:1",
        ):
            assert subject.complete_summary(
                "schedule",
                native_case_fixture(
                    dict(test, executedTests=[identifier]), {"Outer/Inner/works": 1}
                ),
            )
    from validation_provenance import source_snapshot

    stable_inputs.enter_context(source_snapshot())
