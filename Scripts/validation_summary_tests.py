"""Check structured validation evidence."""

import json
from pathlib import Path
from unittest.mock import patch
from validation_provenance_tests import network_trace_fixture


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

from validation_manual_tests import captured_fixture, distribution_fixture


def verify_group_summaries(
    subject, test, icloud_summary, fixture_environment, compiler, original_is_file
):
    module_name = subject.__name__
    summaries = {
        name: dict(
            test,
            totalTests=len(subject.test_inventory(name)),
            passedTests=len(subject.test_inventory(name)),
            executedTests=sorted(subject.test_inventory(name)),
        )
        for name in (
            "modules",
            "all",
            "release-runtime",
            "catalyst",
            "catalyst-release-runtime",
            "ui",
        )
    }
    for name in summaries.keys() - {"modules"}:
        summaries[name] = native_case_fixture(
            summaries[name], subject.test_case_inventory(name), name
        )
    summaries["modules"]["testCases"] = {
        "total": len(summaries["modules"]["executedTests"]),
        "byTest": {name: 1 for name in summaries["modules"]["executedTests"]},
        "expectedByTest": {name: 1 for name in summaries["modules"]["executedTests"]},
    }
    summaries["modules"]["coverage"] = {
        name: {"coveredLines": floor, "executableLines": 100}
        for name, floor in subject.MODULE_COVERAGE_FLOORS.items()
    }
    summaries["all"]["coverage"] = {"BIT101-iOS.app": {"coveredLines": 35, "executableLines": 100}}
    summaries["all"]["coverage"].update(
        {
            "iOS/" + name: {"coveredLines": floor, "executableLines": 100}
            for name, floor in subject.IOS_MODULE_COVERAGE_FLOORS.items()
        }
    )
    summaries["ui"]["coverage"] = dict(summaries["all"]["coverage"])
    summaries["catalyst"]["coverage"] = {
        "BIT101-iOS.app": {"coveredLines": 35, "executableLines": 100}
    }
    summaries["catalyst"]["coverage"].update(
        {
            "Catalyst/" + name: {"coveredLines": floor, "executableLines": 100}
            for name, floor in subject.IOS_MODULE_COVERAGE_FLOORS.items()
            if name != "ScheduleActivityContracts"
        }
    )
    summaries["catalyst-release-runtime"]["coverage"] = dict(summaries["catalyst"]["coverage"])
    for group in ("catalyst", "catalyst-release-runtime"):
        assert subject.coverage_complete(group, summaries[group])
        assert not subject.coverage_complete(group, dict(summaries[group], coverage={}))
        for name in ("BIT101-iOS.app", "Catalyst/TransportCore", "Catalyst/StorageCore"):
            changed = dict(summaries[group]["coverage"])
            changed[name] = {"coveredLines": 0, "executableLines": 100}
            assert not subject.coverage_complete(group, dict(summaries[group], coverage=changed))
    assert subject.coverage_complete("ui", summaries["ui"])
    assert not subject.coverage_complete("ui", dict(summaries["ui"], coverage={}))
    ui_missing = dict(summaries["ui"]["coverage"])
    ui_missing["iOS/ScoreFeature"] = {"coveredLines": 0, "executableLines": 100}
    assert not subject.coverage_complete("ui", dict(summaries["ui"], coverage=ui_missing))
    for name in (
        "iOS/CommunityUI",
        "iOS/CourseFeature",
        "iOS/ScoreFeature",
        "iOS/MediaKit",
        "iOS/DesignSystemKit",
        "BIT101-iOS.app",
    ):
        weak = dict(summaries["ui"]["coverage"])
        weak[name] = {"coveredLines": 1, "executableLines": 100}
        assert not subject.coverage_complete("ui", dict(summaries["ui"], coverage=weak))
        weak.pop(name)
        assert not subject.coverage_complete("ui", dict(summaries["ui"], coverage=weak))
    assert subject.coverage_complete("all", summaries["all"])
    ios_missing = dict(summaries["all"]["coverage"])
    ios_missing.pop("iOS/MediaKit")
    assert not subject.coverage_complete("all", dict(summaries["all"], coverage=ios_missing))
    ios_missing["iOS/MediaKit"] = {"coveredLines": 52, "executableLines": 100}
    assert not subject.coverage_complete("all", dict(summaries["all"], coverage=ios_missing))
    assert subject.coverage_complete("modules", summaries["modules"])
    for group in ("modules", "all", "ui"):
        for field in ("coveredLines", "executableLines"):
            for value in (True, False, 1.0, "1", None):
                malformed = _make_malformed_coverage(summaries[group]["coverage"], field, value)
                assert not subject.coverage_complete(
                    group, dict(summaries[group], coverage=malformed)
                ), (group, field, value)
    for field in ("totalTests", "passedTests", "failedTests", "skippedTests"):
        counts = {"totalTests": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        assert subject.successful_test_counts(counts)
        assert not subject.successful_test_counts(dict(counts, **{field: bool(counts[field])})), (
            field
        )
    assert not subject.coverage_complete("modules", dict(summaries["modules"], coverage={}))
    missing = dict(summaries["modules"]["coverage"])
    missing.pop("ScheduleSync")
    assert not subject.coverage_complete("modules", dict(summaries["modules"], coverage=missing))
    missing["ScheduleSync"] = {"coveredLines": 0, "executableLines": 100}
    assert not subject.coverage_complete("modules", dict(summaries["modules"], coverage=missing))
    missing["ScheduleSync"] = {"coveredLines": 75, "executableLines": 100}
    assert not subject.coverage_complete("modules", dict(summaries["modules"], coverage=missing))
    summaries["ui"]["uiInventory"] = {
        "observed": 2,
        "visited": 1,
        "pending": ["another-mounted-value"],
        "scope": "mounted-controls",
        "unidentifiedControls": 0,
        "pendingDisabled": [],
        "identityScope": "testCaseNavigationPresentationAndOccurrence",
        "visitedControls": [
            {"instance": "control", "scope": "Fixture/example", "actions": ["tap"]}
        ],
    }
    summaries["audit"] = {
        "passed": True,
        "kind": "audit",
        "releaseVersionChecked": True,
        "startedAt": subject.utc_now().isoformat(),
        "finishedAt": subject.utc_now().isoformat(),
    }
    summaries["restore"] = dict(
        passed=True,
        kind="restore",
        initialized=True,
        sessionRecovered=True,
        active=True,
        processAlive=True,
        processIdentifier=1,
        runID="00000000-0000-4000-8000-000000000001",
        inputDigest=subject.input_identity("restore"),
        startedAt=subject.utc_now().isoformat(),
        finishedAt=subject.utc_now().isoformat(),
    )
    provenance = {
        "inputDigest": subject.input_identity("build-archive"),
        "runID": "fixture-run",
    }
    distribution_proof = distribution_fixture()[1]
    summaries["build-archive"] = {
        "passed": True,
        "kind": "build",
        "archiveProvenance": provenance,
        "executables": {
            row["identifier"]: row["executableUUIDs"] for row in distribution_proof["bundles"]
        },
    }
    from validation_manual import MANUAL_DEVICE_CHECKS, capture, complete

    checks = {}
    for name in MANUAL_DEVICE_CHECKS:
        checks[name] = captured_fixture(name, provenance)
    summaries["manual-device"] = {"passed": True, "checks": checks}
    assert complete(checks)
    stale = json.loads(json.dumps(checks))
    next(iter(stale.values()))["capturedAt"] = "2000-01-01T00:00:00+00:00"
    assert not complete(stale)
    original_read = Path.read_bytes

    def missing_artifact(path):
        if str(path).startswith("/evidence") or str(path) == "/missing":
            raise FileNotFoundError
        return original_read(path)

    with patch.object(Path, "read_bytes", missing_artifact):
        assert complete(json.loads(json.dumps(checks)))
        try:
            capture(
                "操作",
                "结果",
                Path("/missing"),
                "photos",
                "passed",
                subject.utc_now().isoformat(),
            )
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("人工证据需要已有附件")
    for field, value in [
        ("dataBase64", ""),
        ("dataBase64", "bad%base64"),
        ("dataBase64", "b3RoZXI="),
        ("byteCount", 1),
    ]:
        changed = json.loads(json.dumps(checks))
        next(iter(changed.values()))["evidence"][field] = value
        assert not complete(changed)
    assert not subject.complete_summary("manual-device", {"passed": True, "checks": {}})
    assert not subject.complete_summary(
        "manual-device",
        {"passed": True, "checks": {name: "pass" for name in MANUAL_DEVICE_CHECKS}},
    )
    summaries["network"] = subject.smoke_summary(
        "network",
        network_trace_fixture(
            {
                "passed": True,
                "scope": "all",
                "executedProbes": sorted(subject.network_inventory()),
                "requiredProbes": sorted(subject.network_inventory()),
                "currentTerm": "fixture-current",
                "validatedTerm": "fixture-current",
            }
        ),
    )
    sms = network_trace_fixture(
        {
            "passed": True,
            "scope": "school",
            "executedProbes": sorted(subject.network_inventory("school")),
            "requiredProbes": sorted(subject.network_inventory("school")),
            "schoolSMSCoverage": "verified",
            "verifiedSMSProbes": [
                {"purpose": purpose, "probe": sorted(subject.SCHOOL_SMS_PROBES[purpose])[0]}
                for purpose in subject.school_sms_inventory()
            ],
        }
    )
    sms.update(
        authenticatedSchoolProbes=sms["verifiedSMSProbes"],
        requestedSMSPurposes=sorted(subject.school_sms_inventory()),
        currentTerm="fixture-current",
        validatedTerm="fixture-current",
    )
    assert set(subject.SCHOOL_SMS_PROBES) == subject.school_sms_inventory()
    writes = network_trace_fixture(
        {
            "passed": True,
            "scope": "community-writes",
            "executedProbes": sorted(subject.network_inventory("community-writes")),
            "requiredProbes": sorted(subject.network_inventory("community-writes")),
            "communityWriteEvidence": [
                "验收账号 user1",
                "服务端确认删除 poster1",
                "服务端确认删除 paper2",
                "点赞恢复 poster1",
                "点赞恢复 paper2",
                "点赞恢复 course3",
                "图片提交 poster1",
                "图片提交 comment10",
                "关注恢复 user4",
                "定向回复 poster 目标 comment11",
                "定向回复 paper 目标 comment14",
                "定向回复 course 目标 comment17",
            ]
            + [f"服务端确认删除 comment{id}" for id in range(10, 19)]
            + [
                f"创建 comment{id} 目标 {parent}"
                for id, parent in [
                    (10, "poster1"),
                    (11, "comment10"),
                    (12, "comment10"),
                    (13, "paper2"),
                    (14, "comment13"),
                    (15, "comment13"),
                    (16, "course3"),
                    (17, "comment16"),
                    (18, "comment16"),
                ]
            ],
        }
    )
    assert subject.community_writes_complete(writes["communityWriteEvidence"])
    write_test = {"ReleaseNetworkSmokeLifecycleTests/communityWritesClean"}
    attachment = {"attachments": [{"name": "community-write-contract.json", "payloadId": "proof"}]}
    with patch.object(
        subject.subprocess,
        "check_output",
        side_effect=[json.dumps(attachment), json.dumps(writes["communityWriteEvidence"])],
    ):
        subject.validate_community_write_test_output(Path("/fixture"), write_test)
    subject.validate_community_write_test_output(Path("/fixture"), set())
    for activities, evidence in [({}, "[]"), (attachment, "[]"), (attachment, "invalid")]:
        with patch.object(
            subject.subprocess, "check_output", side_effect=[json.dumps(activities), evidence]
        ):
            try:
                subject.validate_community_write_test_output(Path("/fixture"), write_test)
            except ValueError:
                pass
            else:
                raise AssertionError("Swift 与 Python 需要共同确认实际写入证据")
    assert not subject.community_writes_complete(
        writes["communityWriteEvidence"][:5] + ["服务端确认删除 comment42"] * 9
    )
    assert not subject.community_writes_complete(
        [
            item.replace("目标 comment16", "目标 comment10")
            for item in writes["communityWriteEvidence"]
        ]
    )
    assert not subject.community_writes_complete(
        [
            item.replace("创建 comment18", "创建 comment17")
            for item in writes["communityWriteEvidence"]
        ]
    )
    assert not subject.community_writes_complete(
        [
            item
            for item in writes["communityWriteEvidence"]
            if not item.startswith("定向回复 course")
        ]
    )
    assert not subject.community_writes_complete(
        [
            item.replace("定向回复 course 目标 comment17", "定向回复 course 目标 comment11")
            for item in writes["communityWriteEvidence"]
        ]
    )
    assert not subject.community_writes_complete(
        [
            item
            for item in writes["communityWriteEvidence"]
            if item
            not in {
                "创建 comment12 目标 comment10",
                "创建 comment15 目标 comment13",
                "创建 comment18 目标 comment16",
                "服务端确认删除 comment12",
                "服务端确认删除 comment15",
                "服务端确认删除 comment18",
            }
        ]
    )
    cleanup = network_trace_fixture(
        {
            "passed": True,
            "scope": "community-cleanup",
            "executedProbes": sorted(subject.network_inventory("community-cleanup")),
            "requiredProbes": sorted(subject.network_inventory("community-cleanup")),
        }
    )
    assert subject.smoke_summary("community-cleanup", cleanup)["passed"]
    assert not subject.smoke_summary("community-writes", cleanup, full=False)["passed"]
    selection_source = (
        "import Testing; import XCTest\n            struct Suite { @Test func first() {}; @Tes"
        "t(arguments: [1]) func second(_ value: Int) {} }\n            class Other: XCTestCase"
        " { func testThird() {} }"
    )
    with (
        patch.object(Path, "rglob", return_value=[Path("selection-contract.swift")]),
        patch.object(Path, "read_text", return_value=selection_source),
    ):
        selectors = subject.test_selectors.__wrapped__("all")
    assert selectors == {
        "Suite/first": "Suite/first()",
        "Suite/second": "Suite/second(_:)",
        "Other/testThird": "Other/testThird",
    }
    with (
        patch(("validation_result_readers.test_selectors"), return_value=selectors),
        patch((f"{module_name}.test_selectors"), return_value=selectors),
        patch(("validation_result_readers.test_inventory"), return_value=set(selectors)),
        patch((f"{module_name}.test_inventory"), return_value=set(selectors)),
    ):
        assert subject.xcode_test_selections(
            "all", ["Suite/first", "Suite/second", "Other/testThird"]
        ) == ["Suite/first()", "Suite/second(_:)", "Other/testThird"]
        assert subject.xcode_test_selections("all", ["Suite", "Suite/first()", "Suite/first"]) == [
            "Suite",
            "Suite/first()",
        ]
        try:
            subject.xcode_test_selections("all", ["Suite/missing"])
        except ValueError:
            pass
        else:
            raise AssertionError("Xcode 筛选需要匹配源码库存")
    with (
        patch(
            ("validation_result_readers.test_inventory"),
            return_value={("Suite/first"), ("Suite/second"), ("Other/third")},
        ),
        patch(
            f"{module_name}.test_inventory",
            return_value={"Suite/first", "Suite/second", "Other/third"},
        ),
    ):
        expected = subject.selected_test_inventory("all", ["Suite", "Other/third()"])
        assert expected == {"Suite/first", "Suite/second", "Other/third"}
        try:
            subject.selected_test_inventory("all", ["Suite", "Missing/none()"])
        except ValueError:
            pass
        else:
            raise AssertionError("手选测试需要拒绝混合失效选择")
    chosen = {
        "passed": True,
        "totalTests": 3,
        "passedTests": 3,
        "failedTests": 0,
        "skippedTests": 0,
        "executedTests": ["Suite/first()", "Suite/second()", "Other/third()"],
    }
    with (
        patch(
            ("validation_result_readers.test_case_inventory"),
            return_value={name: 1 for name in expected},
        ),
        patch(module_name + (".test_case_inventory"), return_value={name: 1 for name in expected}),
    ):
        chosen = native_case_fixture(chosen, {name: 1 for name in expected})
        assert subject.selected_test_summary_complete(chosen, sorted(expected))
        assert not subject.selected_test_summary_complete(
            dict(chosen, totalTests=1, passedTests=1, executedTests=["Suite/first()"]),
            sorted(expected),
        )
    summaries["community-writes"] = subject.smoke_summary("community-writes", writes)
    assert summaries["community-writes"]["passed"]
    assert not subject.smoke_summary("community-writes", dict(writes, communityWriteEvidence=[]))[
        "passed"
    ]
    summaries["school-sms"] = subject.smoke_summary("school-sms", sms)
    assert summaries["school-sms"]["passed"]
    authenticated = dict(
        sms, schoolSMSCoverage="not_required", verifiedSMSProbes=[], requestedSMSPurposes=[]
    )
    assert subject.complete_summary(
        "school-sms", subject.smoke_summary("school-sms", authenticated)
    )
    assert not subject.smoke_summary(
        "school-sms", dict(authenticated, requestedSMSPurposes=["webvpn"])
    )["passed"]
    assert not subject.smoke_summary(
        "school-sms", dict(authenticated, authenticatedSchoolProbes=[])
    )["passed"]
    mixed = dict(
        sms,
        requestedSMSPurposes=[sms["verifiedSMSProbes"][0]["purpose"]],
        verifiedSMSProbes=sms["verifiedSMSProbes"][:1],
    )
    assert subject.smoke_summary("school-sms", mixed)["passed"]
    full_sms = network_trace_fixture(
        dict(
            sms,
            scope="all",
            requiredProbes=sorted(subject.network_inventory("all")),
            executedProbes=sorted(subject.network_inventory("all")),
        )
    )
    assert subject.smoke_summary("network", full_sms)["passed"]
    assert not subject.smoke_summary("network", dict(full_sms, workerDeployments={}))["passed"]
    projected = subject.smoke_summary("school-sms", full_sms)
    assert subject.complete_summary("school-sms", projected)
    assert projected["scope"] == "school" and set(
        projected["requiredProbes"]
    ) == subject.network_inventory("school")
    peripheral = dict(
        full_sms,
        passed=False,
        failures=["[update.app-store] fixture failure"],
        coverageGaps=["必需采样缺失：update.app-store"],
        skippedProbes=["update.app-store（fixture）"],
    )
    assert subject.complete_summary("school-sms", subject.smoke_summary("school-sms", peripheral))
    assert not subject.smoke_summary("school-sms", dict(peripheral, schoolSMSCoverage="pending"))[
        "passed"
    ]
    assert not subject.smoke_summary("school-sms", dict(peripheral, authenticatedSchoolProbes=[]))[
        "passed"
    ]
    assert not subject.smoke_summary(
        "school-sms", dict(peripheral, failures=["[schedule.current-term] fixture failure"])
    )["passed"]
    assert not subject.smoke_summary(
        "school-sms", dict(peripheral, failures=["网络 Smoke 报告写入失败：fixture"])
    )["passed"]
    assert not subject.smoke_summary("school-sms", dict(full_sms, passed=False))["passed"]
    assert not subject.smoke_summary(
        "school-sms", dict(full_sms, requiredProbes=sms["requiredProbes"])
    )["passed"]
    assert not subject.smoke_summary("school-sms", dict(full_sms, verifiedSMSProbes=[]))["passed"]

    mismatched = [
        {"purpose": step["purpose"], "probe": "community.login"}
        for step in sms["verifiedSMSProbes"]
    ]
    assert not subject.smoke_summary("school-sms", dict(sms, verifiedSMSProbes=mismatched))[
        "passed"
    ]
    assert (
        subject.smoke_summary("school-sms", dict(sms, schoolSMSCoverage="preflight_only"))["passed"]
        is False
    )
    assert (
        subject.smoke_summary(
            "school-sms", dict(sms, verifiedSMSProbes=sms["verifiedSMSProbes"][:1])
        )["passed"]
        is False
    )
    summaries["icloud"] = icloud_summary(
        {
            "exitCode": 0,
            "stages": [
                icloud_stage_fixture(name, dict(test, totalTestCount=1, exitCode=0))
                for name in ("testPhoneRoundTrip", "testMacReceiveAndRestore")
            ],
        }
    )
    assert summaries["icloud"]["cleanup"]["kind"] == "round-trip"
    assert summaries["icloud"]["macCleanup"]["kind"] == "round-trip"
    assert summaries["icloud"]["macCleanup"]["kvsDeletion"] == "peer-observed"
    assert subject.complete_summary("icloud", summaries["icloud"])
    for field, value in [
        ("executedTests", ["Other/testAlwaysPass"]),
        ("testTargets", ["Other"]),
        ("destination", {"platform": "iOS Simulator", "deviceIdentifier": "phone"}),
        ("runID", "other"),
    ]:
        wrong = [
            dict(summaries["icloud"]["stages"][0], **{field: value}),
            summaries["icloud"]["stages"][1],
        ]
        assert not subject.complete_summary("icloud", dict(summaries["icloud"], stages=wrong))
    assert not subject.complete_summary(
        "icloud", dict(summaries["icloud"], cleanup={"exitCode": 1})
    )
    assert not subject.complete_summary(
        "icloud", dict(summaries["icloud"], macCleanup={"exitCode": 1})
    )
    groups = {
        name: {
            "exitCode": 0,
            "scope": "full",
            "summary": summary,
            "runID": "fixture",
            "recordedAt": subject.utc_now().isoformat(),
            "inputDigest": subject.input_identity(name),
            "environment": subject.environment_context(name),
        }
        for name, summary in summaries.items()
    }
    groups["build-archive"]["runID"] = provenance["runID"]
    groups["restore"]["runID"] = summaries["restore"]["runID"]
    from validation_manual import artifact_bytes

    groups["catalyst-release-runtime"]["application"] = json.loads(
        artifact_bytes(summaries["manual-device"]["checks"]["catalyst-desktop"]["evidence"])
    )["application"]
    for name in subject.LIVE_GROUPS & groups.keys():
        groups[name]["summary"].update(
            startedAt=subject.utc_now().isoformat(), finishedAt=subject.utc_now().isoformat()
        )
    report = {"sourceDigest": "source", "groups": groups}
    with (
        patch("ui_rules.source_runtime_interaction_findings", return_value=[]),
        patch("ui_source_facts.syntax_index", return_value={}),
        patch("ui_rules.configured_interactions", return_value=[]),
    ):
        findings = subject.release_findings(report, "source")
        assert not findings, findings
        assert subject.complete_summary("ui", summaries["ui"])
        with patch(
            "ui_rules.source_runtime_interaction_findings",
            return_value=["missing source action"],
        ):
            assert not subject.complete_summary("ui", summaries["ui"])
        regressed = json.loads(json.dumps(report))
        regressed["coveragePolicy"] = {"all": {"GalleryFeature": 50}}
        regressed["groups"]["ui"]["summary"]["coverage"]["iOS/GalleryFeature"] = {
            "coveredLines": 20,
            "executableLines": 100,
        }
        assert subject.coverage_complete("ui", regressed["groups"]["ui"]["summary"])
        assert any(
            "ui 覆盖率退化" in error for error in subject.release_findings(regressed, "source")
        )
        ordinary_audit = json.loads(json.dumps(report))
        ordinary_audit["groups"]["audit"]["summary"]["releaseVersionChecked"] = False
        assert any(
            "App Store 版本核对" in row
            for row in subject.release_findings(ordinary_audit, "source")
        )
        for key, value in [("executableUUIDs", [])]:
            mismatched = json.loads(json.dumps(report))
            mismatched["groups"]["catalyst-release-runtime"]["application"][key] = value
            assert any(
                "Catalyst 桌面专项" in error
                for error in subject.release_findings(mismatched, "source")
            )
        older = json.loads(json.dumps(report))
        first = next(iter(older["groups"]["build-archive"]["summary"]["executables"].values()))
        first[0]["uuid"] = "00000000-0000-4000-8000-000000000001"
        assert any(
            "可执行文件 UUID" in error for error in subject.release_findings(older, "source")
        )
        with (
            patch(
                f"{module_name}.environment_context",
                return_value=dict(fixture_environment, host={"system": "changed"}),
            ),
            patch(
                "validation_provenance.environment_context",
                return_value=dict(fixture_environment, host={"system": "changed"}),
            ),
        ):
            assert subject.release_findings(report, "source")
            recorded_findings = subject.release_findings(
                report, "source", recorded_environment=True
            )
            assert not recorded_findings, recorded_findings
            _check_recorded_summary(module_name, subject, groups, original_is_file)
        with patch(
            f"{module_name}.environment_context",
            return_value=dict(fixture_environment, xcode={"version": "changed"}),
        ):
            assert subject.release_findings(report, "source", recorded_environment=True)
        with patch(
            f"{module_name}.environment_context",
            return_value=dict(fixture_environment, compiler=dict(compiler, version="b" * 64)),
        ):
            assert any(
                "编译工具链" in error
                for error in subject.release_findings(report, "source", recorded_environment=True)
            )
    assert subject.release_findings(report, "changed")
    groups["ui"]["scope"] = "selected"
    assert subject.release_findings(report, "source")
    groups["ui"]["scope"] = "full"
    groups["ui"]["summary"]["passedTests"] = 0
    assert subject.release_findings(report, "source")
    module = subject.test_summary(
        "总计 3；通过 3；失败 0；跳过 0\n统计范围：macOS\n- ScheduleSync: 75.00% (3/4 lines)"
    )
    assert module["passed"] and module["coverage"]["ScheduleSync"]["coveredLines"] == 3
    assert subject.test_summary("总计 4；通过 3；失败 0；跳过 1")["passed"] is False
    assert subject.test_summary("总计 0；通过 0；失败 0；跳过 0")["passed"] is False
    assert subject.complete_summary("ui", dict(test, executedTests=["Fixture/example"])) is False
    summaries["ui"]["passedTests"] = summaries["ui"]["totalTests"]
    summaries["ui"]["uiInventory"]["visitedControls"][0]["actions"] = []
    assert subject.complete_summary("ui", summaries["ui"]) is False
    network = network_trace_fixture(
        {
            "passed": True,
            "scope": "all",
            "executedProbes": sorted(subject.network_inventory()),
            "requiredProbes": sorted(subject.network_inventory()),
            "currentTerm": "fixture-current",
            "validatedTerm": "fixture-current",
        }
    )
    assert subject.smoke_summary("network", network)["passed"]
    assert not subject.smoke_summary(
        "network", dict(network, requestedTerm="2024-2025-1", validatedTerm="2024-2025-1")
    )["passed"]
    assert not subject.smoke_summary("network", dict(network, validatedTerm="other"))["passed"]
    assert not subject.smoke_summary("network", dict(network, currentTerm=None))["passed"]
    historical = network_trace_fixture(
        dict(network, requestedTerm="2024-2025-1", validatedTerm="2024-2025-1")
    )
    assert subject.smoke_summary("network", historical, full=False)["passed"]
    assert (
        subject.smoke_summary(
            "network", {"passed": True, "scope": "all", "executedProbes": ["unrelated"]}
        )["passed"]
        is False
    )
    network["coverageGaps"] = ["fixture"]
    network["failures"] = ["具体失败原因"]
    failed_summary = subject.smoke_summary("network", network)
    assert failed_summary["diagnostics"]["failures"] == ["具体失败原因"]
    assert failed_summary["diagnostics"]["coverageGaps"] == ["fixture"]
    network["failures"] = []
    assert subject.smoke_summary("network", network)["passed"] is False
    ddl = network_trace_fixture(
        {
            "passed": True,
            "scope": "ddl",
            "executedProbes": sorted(subject.network_inventory("ddl")),
            "requiredProbes": sorted(subject.network_inventory("ddl")),
        }
    )
    assert (
        len(subject.network_inventory("ddl")) == 4 and subject.smoke_summary("ddl", ddl)["passed"]
    )
    ddl_summary = subject.smoke_summary("ddl", ddl)
    assert subject.complete_summary("ddl", ddl_summary)
    assert not subject.smoke_summary("network", dict(network, requestEvidence=[]))["passed"]
    assert not subject.smoke_summary("network", dict(network, requestEvidenceRequired=False))[
        "passed"
    ]
    network_recording_self_test(
        subject,
        {
            "network": network,
            "ddl": ddl,
            "school-sms": sms,
            "community-writes": writes,
            "community-cleanup": cleanup,
        },
    )

    ddl["skippedProbes"] = ["eclass.ddl"]
    assert subject.smoke_summary("ddl", ddl)["passed"] is False
    assert icloud_summary({"exitCode": 0, "stages": []})["passed"] is False
    stages = [
        icloud_stage_fixture(
            name,
            {
                "exitCode": 0,
                "totalTestCount": 1,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 0,
            },
        )
        for name in ["testPhoneRoundTrip", "testMacReceiveAndRestore"]
    ]
    assert icloud_summary({"exitCode": 0, "stages": stages})["passed"]
    for field, value in [
        ("executedTests", ["Other/testAlwaysPass"]),
        ("testTargets", ["Other"]),
        ("destination", {"platform": "iOS Simulator", "deviceIdentifier": "phone"}),
        ("runID", "other"),
    ]:
        wrong = [dict(stages[0], **{field: value}), stages[1]]
        assert not icloud_summary({"exitCode": 0, "stages": wrong})["passed"]
    assert subject.smoke_summary("icloud", {"exitCode": 0, "stages": stages})["passed"] is False
    cleanup = icloud_stage_fixture("testCleanup", stages[0])
    assert icloud_summary(
        {"exitCode": 0, "stages": stages, "cleanup": cleanup, "cleanupExitCode": 0}
    )["passed"]
    assert (
        icloud_summary({"exitCode": 0, "stages": stages, "cleanup": cleanup, "cleanupExitCode": 1})[
            "passed"
        ]
        is False
    )
    cleanup["passedTests"] = 0
    assert icloud_summary({"exitCode": 0, "stages": stages, "cleanup": cleanup})["passed"] is False
    assert not subject.smoke_summary("icloud-cleanup", {"cleanup": cleanup, "cleanupExitCode": 0})[
        "passed"
    ]
    cleanup["passedTests"] = 1
    mac_cleanup = icloud_stage_fixture("testMacCleanup", cleanup)
    restored = {
        "exitCode": 1,
        "cleanup": cleanup,
        "macCleanup": mac_cleanup,
        "cleanupExitCode": 0,
        "runID": "fixture",
    }
    assert subject.smoke_summary("icloud-cleanup", restored)["passed"]
    assert (
        subject.smoke_summary("icloud-cleanup", restored)["macCleanup"]["kvsDeletion"]
        == "requested"
    )
    assert (
        subject.smoke_summary("icloud-cleanup", restored)["macCleanup"]["cloudKitDeletion"]
        == "server-confirmed"
    )
    from datetime import datetime, timedelta, timezone

    instant = datetime.now(timezone.utc)
    restored.update(
        cleanupStartedAt=(instant - timedelta(minutes=3)).isoformat(),
        cleanupFinishedAt=instant.isoformat(),
    )
    for mac_first in (True, False):
        restored["cleanup"]["recordedAt"] = (
            instant - timedelta(seconds=30 if mac_first else 90)
        ).isoformat()
        restored["macCleanup"]["recordedAt"] = (
            instant - timedelta(seconds=90 if mac_first else 30)
        ).isoformat()
        summary = subject.smoke_summary("icloud-cleanup", restored)
        assert summary["passed"] and subject.complete_summary("icloud-cleanup", summary)
        for key in ("cleanup", "macCleanup"):
            for field in ("executedTests", "testTargets", "destination", "runID"):
                partial = dict(summary[key])
                partial.pop(field)
                assert not subject.complete_summary(
                    "icloud-cleanup", dict(summary, **{key: partial})
                )
            assert not subject.complete_summary(
                "icloud-cleanup", dict(summary, **{key: dict(summary[key], runID="other")})
            )
        assert subject.evidence_current("icloud-cleanup", summary)
    assert not subject.evidence_current(
        "icloud-cleanup",
        subject.smoke_summary(
            "icloud-cleanup",
            dict(
                restored,
                cleanupFinishedAt=restored["cleanupStartedAt"],
                cleanupStartedAt=restored["cleanupFinishedAt"],
            ),
        ),
    )
    assert not subject.smoke_summary("icloud-cleanup", dict(restored, macCleanup={}))["passed"]
    assert not icloud_summary(
        {"exitCode": 0, "stages": stages, "macCleanup": dict(mac_cleanup, exitCode=1)}
    )["passed"]
    stages[1]["passedTests"] = 0
    assert icloud_summary({"exitCode": 0, "stages": stages})["passed"] is False
    return 0
