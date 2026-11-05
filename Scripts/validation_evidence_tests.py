#!/usr/bin/env python3
"""Regression contracts for evidence inputs, inventories and release summaries."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from contextlib import ExitStack
from unittest.mock import patch
from swift_source_index import swift_syntax_index_sources
from validation_performance_tests import developer_directory_self_test
from validation_provenance_tests import network_trace_fixture, network_route_identity_self_test


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
from validation_workflow_tests import verify_workflow_inputs, verify_test_inventory
from validation_summary_tests import verify_group_summaries


def request_body_shape_self_test() -> None:
    from copy import deepcopy
    from network_request_contracts import complete

    cases = (
        ("feedback.recovery", "/api/error-reports", {"mode", "runID"}),
        (
            "schedule.sync",
            "cxzkbrq.do",
            {"requestParamStr", "requestParamStr.XNXQDM", "requestParamStr.ZC"},
        ),
        ("schedule.sync", "cxxsksap.do", {"XNXQDM", "*order"}),
        (
            "community.writes",
            "/reaction/comments",
            {"obj", "text", "anonymous", "image_mids", "rate"},
        ),
        ("community.writes", "/reaction/like", {"obj"}),
        (
            "lexue.calendar",
            "export.php",
            {
                "sesskey",
                "_qf__core_calendar_export_form",
                "events[exportevents]",
                "period[timeperiod]",
                "generateurl",
            },
        ),
    )
    for probe, suffix, required in cases:
        trace = network_trace_fixture({"requiredProbes": [probe]})["requestEvidence"][0]
        assert complete(probe, trace["requests"], trace["expectedParameters"])
        if probe == "feedback.recovery":
            assert not complete(
                probe,
                [dict(trace["requests"][0], query={"mode": "raw"}, finalQuery={"mode": "raw"})],
            )
        for field in ("bodyParameterNames", "finalBodyParameterNames"):
            for name in required:
                rows = deepcopy(trace["requests"])
                changed = _matching_post_requests(rows, suffix, name)
                assert changed, (probe, name)
                for row in changed:
                    row[field] = sorted(set(row[field]) - {name})
                assert not complete(probe, rows, trace["expectedParameters"]), (probe, field, name)
    trace = network_trace_fixture({"requiredProbes": ["community.writes"]})["requestEvidence"][0]
    for missing in ({"reply_obj"}, {"reply_uid"}, {"reply_obj", "reply_uid"}):
        rows = deepcopy(trace["requests"])
        for row in rows:
            if not (
                row[("method")] == ("POST")
                and row.get(("query"), {}).get(("obj"), ("")).startswith(("comment"))
            ):
                continue
            for field in ("bodyParameterNames", "finalBodyParameterNames"):
                row[field] = sorted(set(row[field]) - missing)
        assert not complete("community.writes", rows, trace["expectedParameters"]), missing


def package_condition_self_test() -> None:
    from validation_compilation import compilation_condition, active_network_source
    from network_capability_rules import business_methods

    path = "Modules/GalleryFeature/Sources/Service.swift"
    assert compilation_condition(
        "SWIFT_PACKAGE && !Xcode && !SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE", "modules", path=path
    )
    for platform in ("iOS", "watchOS", "macCatalyst"):
        assert compilation_condition(
            "SWIFT_PACKAGE && Xcode && SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE",
            "restore",
            platform=platform,
            path=path,
        )
    assert not compilation_condition(
        "SWIFT_PACKAGE || Xcode || SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE",
        "restore",
        path="BIT101-iOS/Shell/AppAccountLifecycle.swift",
    )
    for condition in ("SWIFT_PACKAGE", "Xcode", "SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE"):
        source = (
            "import Foundation\npublic struct Service {\npublic func fetch() async throws {\n#if "
            + condition
            + "\n_ = try await URLSession.shared.data(from: url)\n#endif\n}\n}"
        )
        assert "URLSession.shared.data" in active_network_source(source, path)
        assert "GalleryFeature.Service" in business_methods(
            swift_syntax_index_sources({path: source})
        ), condition


def additional_network_probe_self_test() -> None:
    from copy import deepcopy
    from validation_provenance import network_requests_complete

    required = {"profile.mine"}
    proof = network_trace_fixture({"requiredProbes": sorted(required)})
    extra = network_trace_fixture({"requiredProbes": ["message.comment"]})["requestEvidence"][0]
    assert network_requests_complete(
        required, dict(proof, requestEvidence=proof["requestEvidence"] + [extra])
    )
    for probe in ("unregistered.write", "message.unknown", "message.comment"):
        changed = deepcopy(extra)
        changed["probe"] = probe
        if probe != "message.unknown":
            for request in changed["requests"]:
                request.update(
                    endpoint="https://unregistered.invalid/write",
                    finalEndpoint="https://unregistered.invalid/write",
                    method="POST",
                    finalMethod="POST",
                    query={},
                    finalQuery={},
                )
        assert not network_requests_complete(
            required, dict(proof, requestEvidence=proof["requestEvidence"] + [changed])
        ), probe


def sms_request_mode_self_test() -> None:
    from copy import deepcopy
    from network_request_contracts import complete
    from validation_provenance import network_requests_complete

    for probe, endpoint, fields, purpose in (
        (
            "profile.mine",
            "https://sso.bit.edu.cn/cas/api/protected/sms/publicNoToken/sendSmsCode",
            ["phone", "businessNo"],
            "school_sso_second_factor",
        ),
        (
            "eclass.authentication",
            "https://sso.bit.edu.cn/cas/api/protected/sms/publicNoToken/sendSmsCode",
            ["phone", "businessNo"],
            "school_sso_second_factor",
        ),
        (
            "eclass.authentication",
            "https://sso.bit.edu.cn/cas/api/protected/sms/checkToken",
            ["phone", "token", "delete", "trustDevice"],
            "school_sso_second_factor",
        ),
        (
            "score.authentication",
            "https://login.bit101.flwfdd.xyz/api/auth/fixture/sms",
            ["code"],
            "jwb",
        ),
    ):
        required = {probe}
        proof = network_trace_fixture({"requiredProbes": [probe]})
        row = proof["requestEvidence"][0]
        row["requests"].append(
            dict(
                endpoint=endpoint,
                finalEndpoint=endpoint,
                method="POST",
                finalMethod="POST",
                query={},
                finalQuery={},
                statusCode=200,
                bodyParameterNames=fields,
                finalBodyParameterNames=fields,
            )
        )
        assert not complete(probe, row["requests"], row["expectedParameters"])
        assert not network_requests_complete(required, proof)
        proof.update(
            schoolSMSCoverage="verified",
            requestedSMSPurposes=[purpose],
            verifiedSMSProbes=[{"probe": probe, "purpose": purpose}],
        )
        allowed = probe != "profile.mine"
        assert (
            complete(probe, row["requests"], row["expectedParameters"], allow_sms=True) == allowed
        )
        assert network_requests_complete(required, proof) == allowed
        if not (allowed):
            continue
        for changes in (
            {"schoolSMSCoverage": "preflight_only"},
            {"verifiedSMSProbes": []},
            {"requestedSMSPurposes": []},
            {"verifiedSMSProbes": [{"probe": "profile.mine", "purpose": purpose}]},
        ):
            assert not network_requests_complete(required, dict(deepcopy(proof), **changes))


@patch.dict(os.environ, GITHUB_ACTIONS="false", GITHUB_SHA="")
def run_self_test(subject) -> int:
    from validation_provenance_tests import test_identity_self_test, probe_identity_self_test

    test_identity_self_test()
    probe_identity_self_test(subject)
    package_condition_self_test()
    additional_network_probe_self_test()
    sms_request_mode_self_test()
    from validation_manual_tests import registration_self_test, source_identity_fixture

    registration_self_test(subject)
    network_scope_boolean_self_test(subject)
    developer_directory_self_test()
    from validation_compilation import self_test as compilation_cache_self_test

    compilation_cache_self_test()
    module_events_self_test(subject)
    native_cases_self_test(subject)
    summary_status_self_test(subject)
    from validation_test_areas import formal_inventory_self_test

    formal_inventory_self_test()
    from validation_policy import workflow_budget_self_test

    workflow_budget_self_test()
    network_route_identity_self_test()
    from validation_provenance_tests import source_snapshot_self_test

    source_snapshot_self_test()
    request_body_shape_self_test()
    module_name = subject.__name__
    original_is_file = Path.is_file
    from validation_environment import host_environment
    from validation_environment import ci_commit_findings

    with patch.dict(os.environ, GITHUB_SHA="a" * 40):
        assert ci_commit_findings("a" * 40) == []
        assert ci_commit_findings("b" * 40)
    with patch.dict(os.environ, GITHUB_SHA="", GITHUB_ACTIONS="true"):
        assert ci_commit_findings("a" * 40)
    for changed in (
        b"",
        b" M Modules/Feature/Sources/Service.swift\0",
        b"?? Modules/Feature/Sources/Residual.swift\0",
    ):
        with (
            patch.dict(os.environ, GITHUB_SHA="a" * 40, GITHUB_ACTIONS="true"),
            patch.object(subprocess, "check_output", return_value=changed),
        ):
            assert bool(ci_commit_findings("a" * 40)) == bool(changed)
    selected_compiler = "/fixture/Xcode/Toolchains/selected/usr/bin/swift-frontend"
    with (
        patch.dict(os.environ, SWIFT_FRONTEND="/other/swift-frontend", SWIFT="/other/swift"),
        patch.object(subprocess, "check_output", return_value=selected_compiler) as lookup,
        patch.object(Path, "is_file", return_value=False),
    ):
        assert host_environment.__wrapped__()["compiler"]["path"] == selected_compiler
        lookup.assert_called_once_with(["xcrun", "--find", "swift-frontend"], text=True)

    fixture_environment = {
        "host": {"system": "fixture"},
        "developer": "/fixture",
        "xcode": {"version": "fixture"},
        "compiler": {
            "path": "/fixture/swift-frontend",
            "modified": 1,
            "size": 100,
            "version": "a" * 64,
        },
        "sdks": {"fixture": {"Version": "1"}},
        "device": {
            "identifier": "fixture-phone",
            "systemVersion": "fixture-os",
            "systemBuild": "fixture-build",
        },
    }
    fixture_environment["runtimes"] = {
        name: "fixture-version" for name in ("python", "ruby", "node", "npm", "ruff")
    }
    with (
        patch(f"{module_name}.environment_context", return_value=fixture_environment),
        patch(
            "validation_provenance._local_source_identity", side_effect=source_identity_fixture()
        ),
        patch("validation_merge.environment_context", return_value=fixture_environment),
        patch("validation_provenance.environment_context", return_value=fixture_environment),
        patch("validation_merge.result_bundle_findings", side_effect=lambda *args, **kwargs: []),
        patch(f"{module_name}.result_bundle_findings", side_effect=lambda *args, **kwargs: []),
        patch("validation_merge.performance_findings", return_value=[]),
        ExitStack() as stable_inputs,
    ):
        compiler = verify_workflow_inputs(subject, fixture_environment)
        test, icloud_summary = verify_test_inventory(subject, stable_inputs)
        return verify_group_summaries(
            subject, test, icloud_summary, fixture_environment, compiler, original_is_file
        )


def summary_status_self_test(subject) -> None:
    from contextlib import redirect_stdout
    from copy import deepcopy
    from io import StringIO
    from types import SimpleNamespace
    from unittest.mock import patch

    method = "Suite/test"
    valid = native_case_fixture(
        {
            "passed": True,
            "totalTests": 1,
            "passedTests": 1,
            "failedTests": 0,
            "skippedTests": 0,
            "executedTests": [method],
            "coverage": {"Fixture": {"coveredLines": 1, "executableLines": 1}},
        },
        {method: 1},
    )
    row = {
        "scope": "full",
        "exitCode": 0,
        "runID": "run",
        "inputDigest": "digest",
        "recordedAt": subject.utc_now().isoformat(),
        "summary": valid,
    }
    cases = [(row, "通过", [])]
    for changes, label in [
        ({"summary": dict(valid, executedTests=[], coverage={})}, "待处理"),
        ({"summary": dict(valid, coverage={})}, "待处理"),
        ({"runID": ""}, "待处理"),
        ({"environment": {}}, "待处理"),
        ({"inputDigest": "changed"}, "待复验"),
        ({"recordedAt": "2000-01-01T00:00:00Z"}, "待复验"),
        ({"scope": "selected", "expectedTests": [method]}, "定向通过"),
        ({"scope": "selected", "expectedTests": []}, "待处理"),
    ]:
        cases.append((dict(row, **changes), label, []))
    cases.append((row, "待处理", ["结果包已变化"]))
    for candidate, label, bundle_errors in cases:
        candidate = deepcopy(candidate)
        candidate.setdefault("environment", {"fixture": True})
        report = {"groups": {"all": candidate}}
        output = StringIO()
        with (
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "read_text", return_value=json.dumps(report)),
            patch.object(subject, "input_identity", return_value="digest"),
            patch(("validation_result_readers.test_inventory"), return_value={method}),
            patch.object(subject, ("test_inventory"), return_value={method}),
            patch(("validation_result_readers.test_case_inventory"), return_value={method: 1}),
            patch.object(subject, ("test_case_inventory"), return_value={method: 1}),
            patch.object(
                subject,
                "coverage_complete",
                side_effect=lambda group, summary: bool(summary.get("coverage")),
            ),
            patch.object(
                subject,
                "complete_environment",
                side_effect=lambda group, environment: bool(environment),
            ),
            patch.object(subject, "result_bundle_findings", return_value=bundle_errors),
            patch.dict(os.environ, GITHUB_STEP_SUMMARY=""),
            redirect_stdout(output),
        ):
            assert (
                subject.inspect_report(
                    SimpleNamespace(action="summary", recorded_environment=False)
                )
                == 0
            )
            assert f"| all | {candidate['scope']} | {label} |" in output.getvalue(), (
                output.getvalue()
            )
            if candidate["scope"] == "full":
                assert subject.group_complete(report, "all") == (label == "通过")


def native_cases_self_test(subject) -> None:
    from copy import deepcopy
    from unittest.mock import patch

    method = "Suite/image"
    identity = "test://com.apple.xcode/BIT101-iOS/BIT101-iOSTests/" + method
    row = {
        "devices": [{"platform": "iOS", "deviceId": "fixture-device"}],
        "nodeType": "Test Case",
        "nodeIdentifier": method + "(stage:)",
        "nodeIdentifierURL": identity,
        "result": "Passed",
        "children": [
            {
                "nodeType": "Arguments",
                "nodeIdentifierURL": identity + "?args=" + format(index, "064x"),
                "result": "Passed",
            }
            for index in range(5)
        ],
    }
    summary = {
        "passed": True,
        "totalTests": 1,
        "passedTests": 1,
        "failedTests": 0,
        "skippedTests": 0,
        "executedTests": [method],
    }
    with (
        patch(("validation_result_readers.test_case_inventory"), return_value={method: 5}),
        patch.object(subject, ("test_case_inventory"), return_value={method: 5}),
        patch(("validation_result_readers.test_inventory"), return_value={method}),
        patch.object(subject, ("test_inventory"), return_value={method}),
        patch.object(subject, "coverage_complete", return_value=True),
    ):
        summary["testCases"] = subject.native_case_summary(row, "all")
        assert subject.selected_test_summary_complete(
            summary, [method]
        ) and subject.complete_summary("all", summary)
        for project, target in [
            ("ForeignProject", "BIT101-iOSTests"),
            ("BIT101-iOS", "ForeignTarget"),
            ("BIT101-iOS", "BIT101-iOSUITests"),
        ]:
            forged = deepcopy(summary)
            forged["testCases"]["identifiersByTest"][method] = [
                value.replace("/BIT101-iOS/BIT101-iOSTests/", f"/{project}/{target}/")
                for value in summary["testCases"]["identifiersByTest"][method]
            ]
            assert not subject.selected_test_summary_complete(forged, [method])
        for devices in (
            [],
            [{"platform": "macOS", "deviceId": "fixture-device"}],
            [{"platform": "iOS", "deviceId": ""}],
            [{"platform": "iOS", "deviceId": "other-device"}],
            [{"platform": "iOS Simulator", "deviceId": "fixture-device"}],
        ):
            changed = dict(
                summary,
                testCases=subject.native_case_summary(
                    dict(row, devices=devices), "all", device_identifier="fixture-device"
                ),
            )
            assert not subject.selected_test_summary_complete(changed, [method])
        simulated = dict(
            summary,
            testCases=subject.native_case_summary(
                dict(row, devices=[{"platform": "iOS Simulator", "deviceId": "fixture-device"}]),
                "all",
                simulator=True,
            ),
        )
        assert subject.selected_test_summary_complete(simulated, [method], simulator=True)
        assert not subject.complete_summary("all", simulated)
        encoded = deepcopy(summary)
        encoded["testCases"]["identifiersByTest"][method] = [
            identity + "?args=" + value.encode().hex()
            for value in [".currentAccount", ".otherAccounts", ".first", ".second", ".third"]
        ]
        assert subject.selected_test_summary_complete(encoded, [method])
        partial = deepcopy(row)
        partial["children"] = partial["children"][:1]
        duplicated = deepcopy(row)
        duplicated["children"][1]["nodeIdentifierURL"] = duplicated["children"][0][
            "nodeIdentifierURL"
        ]
        failed = deepcopy(row)
        failed["children"][1]["result"] = "Failed"
        skipped = deepcopy(row)
        skipped["children"][1]["result"] = "Skipped"
        for broken in (partial, duplicated, failed, skipped):
            changed = dict(summary, testCases=subject.native_case_summary(broken, "all"))
            assert not subject.selected_test_summary_complete(
                changed, [method]
            ) and not subject.complete_summary("all", changed)
        forged = native_case_fixture(summary, {method: 1})
        assert not subject.selected_test_summary_complete(forged, [method])
        for values in (
            [str(index) for index in range(5)],
            [
                identity.replace("/Suite/", "/OtherSuite/") + "?args=" + format(index, "064x")
                for index in range(5)
            ],
            [identity + "?args=" + str(index) for index in range(5)],
        ):
            forged = deepcopy(summary)
            forged["testCases"]["identifiersByTest"][method] = values
            assert not subject.selected_test_summary_complete(forged, [method])
    facts = subject.swift_syntax_index_sources(
        {
            "parameter-count": (
                "import Testing; struct Suite { @Test(arguments: [1, 2], [true, false, true]) func"
                " image(_: Int, _: Bool) {} }"
            )
        }
    )["parameter-count"]
    assert facts["tests"][0]["testCaseCount"] == 6


def module_events_self_test(subject) -> None:
    from unittest.mock import patch

    single = "Consumer.Suite/single()/Tests.swift:1:1"
    parameterized = "Consumer.Suite/parameterized(_:)/Tests.swift:2:1"

    def declaration(identifier, parameterized=False):
        return {
            "kind": "test",
            "payload": {
                "kind": "function",
                "id": identifier,
                "isParameterized": parameterized,
                "_testCases": [{"id": "case-a"}, {"id": "case-b"}] if parameterized else [],
            },
        }

    def event(kind, identifier="", **fields):
        return {"kind": "event", "payload": dict(kind=kind, testID=identifier, **fields)}

    def encode(records):
        return "\n".join(json.dumps(record) for record in records)

    records = [
        declaration(single),
        declaration(parameterized, True),
        event("runStarted"),
        event("testStarted", single),
        event("testEnded", single),
        event("testStarted", parameterized),
        event("testCaseStarted", parameterized, _testCase={"id": "case-a"}),
        event("testCaseStarted", parameterized, _testCase={"id": "case-b"}),
        event("testCaseEnded", parameterized, _testCase={"id": "case-a"}),
        event("testCaseEnded", parameterized, _testCase={"id": "case-b"}),
        event("testEnded", parameterized),
        event("runEnded"),
    ]
    result = subject.module_event_summary(encode(records))
    assert result["totalTests"] == result["passedTests"] == 2
    assert result["failedTests"] == result["skippedTests"] == 0
    assert result["testCases"] == {
        "total": 3,
        "byTest": {single: 1, parameterized: 2},
        "expectedByTest": {single: 1, parameterized: 2},
    }
    assert subject.module_cases_complete(result)
    for broken in (
        records[:3] + [records[4], records[3]] + records[5:],
        records[:4] + [records[3]] + records[4:],
        records[:5] + [records[4]] + records[5:],
        records[:3] + [records[-1]] + records[3:-1],
        records[:3] + [records[2]] + records[3:],
        records[:3] + [records[6]] + records[3:],
        records + [records[4]],
        records[:4]
        + [
            event("testCaseStarted", single, _testCase={"id": "one"}),
            event("testCaseEnded", single, _testCase={"id": "one"}),
            event("testCaseStarted", single, _testCase={"id": "two"}),
            event("testCaseEnded", single, _testCase={"id": "two"}),
        ]
        + records[4:],
    ):
        try:
            subject.module_event_summary(encode(broken))
        except ValueError:
            pass
        else:
            raise AssertionError("普通函数和运行事件需要唯一且有序的起止配对")
    metrics = (
        "总计 2；通过 2；失败 0；跳过 0\n已执行用例："
        + json.dumps(result["executedTests"])
        + "\n测试实例："
        + json.dumps(result["testCases"])
    )
    summary = subject.test_summary(metrics)
    with (
        patch.object(subject, "coverage_complete", return_value=True),
        patch(
            ("validation_result_readers.test_inventory"),
            return_value={subject.normalized_test_id(name) for name in result[("executedTests")]},
        ),
        patch.object(
            subject,
            "test_inventory",
            return_value={subject.normalized_test_id(name) for name in result["executedTests"]},
        ),
    ):
        assert subject.complete_summary("modules", summary)
        for cases in (
            None,
            {"total": 2, "byTest": result["testCases"]["byTest"]},
            {"total": 1, "byTest": {single: 1}},
            {"total": 1, "byTest": {single: 1, parameterized: 0}},
        ):
            assert not subject.complete_summary("modules", dict(summary, testCases=cases))
    skipped = "Consumer.Suite/skipped()/Tests.swift:3:1"
    result = subject.module_event_summary(
        encode(records + [declaration(skipped), event("testSkipped", skipped)])
    )
    assert result["totalTests"] == 3 and result["passedTests"] == 2 and result["skippedTests"] == 1
    for issue, failed in (
        ({"isKnown": False}, 1),
        ({"isKnown": True}, 1),
        ({"isKnown": True, "isFailure": True}, 1),
        ({"isKnown": False, "isFailure": False}, 0),
        ({"isKnown": True, "isFailure": False}, 0),
    ):
        result = subject.module_event_summary(
            encode(records + [event("issueRecorded", parameterized, issue=issue)])
        )
        assert result["failedTests"] == failed and result["passedTests"] == 2 - failed
    for incomplete in (
        records[:-1],
        [row for index, row in enumerate(records) if index != 8],
        [row for row in records if row["payload"].get("_testCase", {}).get("id") != "case-b"],
        [row for row in records if not row["payload"]["kind"].startswith("testCase")],
        [],
        records + [event("issueRecorded", issue={"isKnown": False})],
    ):
        try:
            subject.module_event_summary(encode(incomplete))
        except ValueError:
            pass
        else:
            raise AssertionError("事件缺失、空参数及运行失败需要进入证据检查")
    for declared in (None, [], [{"id": "case-a"}], [{"id": "case-a"}, {"id": "case-a"}], [{}]):
        broken = json.loads(json.dumps(records))
        broken[1]["payload"]["_testCases"] = declared
        try:
            subject.module_event_summary(encode(broken))
        except ValueError:
            pass
        else:
            raise AssertionError("参数实例需要完整且唯一的框架清单")
    for kind, case_id in [
        ("testCaseStarted", "case-a"),
        ("testCaseEnded", "case-a"),
        ("testCaseEnded", "other"),
        ("testCaseEnded", None),
    ]:
        broken = json.loads(json.dumps(records))
        broken[9] = event(kind, parameterized, _testCase={"id": case_id})
        try:
            subject.module_event_summary(encode(broken))
        except ValueError:
            pass
        else:
            raise AssertionError("参数实例重复、遗漏及身份错配需要验收失败")


def network_scope_boolean_self_test(subject) -> None:
    from unittest.mock import patch

    path = subject.ROOT / "BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift"
    source, read = path.read_text(), Path.read_text
    baseline = {
        scope: subject.network_inventory(scope)
        for scope in (
            "all",
            "bit101",
            "school",
            "transcript",
            "schedule",
            "ddl",
            "community-writes",
            "community-cleanup",
        )
    }
    assert (
        len(baseline["all"]) == 60
        and {"course.search", "paper.search", "gallery.subscriptions", "message.subscription"}
        <= baseline["all"]
    )
    assert baseline["all"].isdisjoint(
        {
            "community.writes",
            "community.report-types",
            "message.follow",
            "message.system",
            "message.like",
            "message.comment",
        }
    )
    fixtures = [
        ("all", "area != .communityWrites", baseline["all"]),
        ("all", "!(area == .communityWrites)", baseline["all"]),
        (
            "all",
            "area != .communityWrites && (area == .authentication || area != .authentication)",
            baseline["all"],
        ),
        ("bit101", "!(area != .authentication && area != .bit101)", baseline["bit101"]),
        ("transcript", "area == NetworkSmokeArea.transcript", baseline["transcript"]),
        ("schedule", "false", set()),
        ("schedule", "true", baseline["all"] | {"community.writes"}),
    ]
    try:
        for scope, expression, expected in fixtures:
            rewritten, count = re.subn(
                r"(?ms)(case \." + scope + r":\s*\n).*?(?=^\s*case \.)",
                lambda match: match[1] + "            return " + expression + "\n",
                source,
                count=1,
            )
            assert count == 1

            def fixture_read(candidate, *args, **kwargs):
                return rewritten if candidate == path else read(candidate, *args, **kwargs)

            subject.network_inventory.cache_clear()
            with patch.object(Path, "read_text", fixture_read):
                assert subject.network_inventory(scope) == expected, (scope, expression)
        rewritten = source.replace("_ area: NetworkSmokeArea", "_ topic: NetworkSmokeArea").replace(
            "area ==", "topic =="
        )
        subject.network_inventory.cache_clear()
        with patch.object(Path, "read_text", fixture_read):
            assert subject.network_inventory("all") == baseline["all"]
        rewritten = re.sub(
            r"case \.communityWrites:.*?(?=case \.communityCleanup:)",
            "case .communityWrites, ",
            source,
            count=1,
            flags=re.DOTALL,
        ).replace(
            "case .communityWrites, case .communityCleanup:",
            "case .communityWrites, .communityCleanup:",
        )
        assert rewritten != source
        subject.network_inventory.cache_clear()
        with patch.object(Path, "read_text", fixture_read):
            assert subject.network_inventory("community-writes") == baseline["community-cleanup"]
            assert subject.network_inventory("community-cleanup") == baseline["community-cleanup"]
    finally:
        subject.network_inventory.cache_clear()


if __name__ == "__main__":
    import validation_evidence

    raise SystemExit(run_self_test(validation_evidence))
