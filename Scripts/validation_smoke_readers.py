"""Read network and school-SMS smoke results from the validation report."""

from __future__ import annotations
import json
import re
from pathlib import Path
import subprocess
from swift_source_index import swift_code as mask_literals_and_comments
from functools import cache
from swift_source_index import swift_syntax_index_sources
from validation_policy import (
    SCHOOL_SMS_PROBES,
)
from validation_provenance import (
    normalized_test_id,
    NETWORK_GROUPS,
)

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
ICLOUD_DOMAINS = {"score-kvs", "schedule-cloudkit"}


from validation_result_readers import successful_test_counts


def icloud_stage_complete(row: dict, stage: str) -> bool:
    if stage not in {
        "testPhoneRoundTrip",
        "testMacReceiveAndRestore",
        "testCleanup",
        "testMacCleanup",
    }:
        return False
    destination = row.get("destination") or {}
    expected = "ICloudCrossDeviceSmokeTests/" + stage
    return (
        row.get("stage") == stage
        and row.get("exitCode") == 0
        and row.get("totalTestCount") == 1
        and successful_test_counts(row)
        and row.get("executedTests") == [expected]
        and row.get("testTargets") == ["BIT101-iOSTests"]
        and bool(row.get("runID"))
        and destination.get("platform") == ("macOS" if stage.startswith("testMac") else "iOS")
        and bool(destination.get("deviceIdentifier"))
    )


@cache
def school_sms_inventory() -> set[str]:
    paths = [
        *(ROOT / "BIT101-iOS/Shared/Client").glob("ReleaseNetworkSmoke*.swift"),
        ROOT / "Modules/ScheduleInfrastructure/Sources/ScheduleServiceLexue.swift",
    ]
    return {
        purpose
        for facts in swift_syntax_index_sources(
            {str(path): path.read_text() for path in paths}
        ).values()
        for call in facts["invocations"]
        for purpose in re.findall(r'\bpurpose:\s*"([^"\\]+)"', call["value"])
    }


@cache
def network_inventory(scope: str = "all") -> set[str]:
    scope = {"community-writes": "communityWrites", "community-cleanup": "communityCleanup"}.get(
        scope, scope
    )
    path = ROOT / "BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift"
    models = swift_syntax_index_sources({str(path): path.read_text()})[str(path)]
    probe_ids = {
        case["name"]: json.loads(case["rawValue"])
        for case in models["enumCases"]
        if case["scope"] == ["NetworkSmokeProbe"]
    }
    factories = {
        function["name"]: function
        for function in models["functionRanges"]
        if function["scope"] == ["NetworkSmokeProbe"]
    }

    def probe_references(start, end):
        result = set()
        for member in models["members"]:
            if not start <= member["start"] < end:
                continue
            name = member["value"].rsplit(".", 1)[-1]
            if name in probe_ids:
                result.add(probe_ids[name])
            elif name in factories:
                function = factories[name]
                result |= probe_references(function["start"], function["end"])
        return result

    areas = {}
    for branch in models["controlFlow"]:
        if branch["scope"] != ["NetworkSmokeArea"] or not branch["value"].startswith("case ."):
            continue
        header, body = branch["value"].split(":", 1)
        name = header.removeprefix("case .")
        areas[name] = probe_references(
            branch["start"] + len((header + ":").encode()),
            branch["start"] + len(branch["value"].encode()),
        )
    includes = next(
        function
        for function in models["functionRanges"]
        if function["scope"] == ["NetworkSmokeScope"] and function["name"] == "includes"
    )
    parameter = next(
        parameter["name"]
        for parameter in includes["parameters"]
        if parameter["type"] == "NetworkSmokeArea"
    )
    branch = next(
        item
        for item in models["controlFlow"]
        if includes["start"] <= item["start"] < includes["end"]
        and re.match(r"case\b", item["value"])
        and scope in re.findall(r"\.\s*(\w+)", item["value"].split(":", 1)[0])
    )
    expression = re.sub(
        r"^return\b", "", mask_literals_and_comments(branch["value"].split(":", 1)[1]).strip()
    ).strip()

    def enum_value(match):
        if match[1] not in areas:
            raise ValueError(f"Smoke 范围需要有效的 NetworkSmokeArea：{match[1]}")
        return json.dumps(match[1])

    expression = re.sub(
        r"\s+", " ", re.sub(r"(?:\bNetworkSmokeArea\s*)?\.\s*(\w+)", enum_value, expression)
    )
    from network_capability_rules import constant_boolean

    selected = {
        area: constant_boolean(expression, lambda name: area if name == parameter else None)
        for area in areas
    }
    if any(value is None for value in selected.values()):
        raise ValueError(f"Smoke 范围需要可求值的 Bool 表达式：{expression}")
    included = {area for area, value in selected.items() if value}
    return set().union(*(areas[area] for area in included))


def community_writes_complete(evidence: list) -> bool:
    if not all(isinstance(item, str) for item in evidence):
        return False
    if sum(bool(re.fullmatch(r"验收账号 user[1-9]\d*", item)) for item in evidence) != 1:
        return False
    deleted = [
        match[1]
        for item in evidence
        if (match := re.fullmatch(r"服务端确认删除 comment([1-9]\d*)", item))
    ]
    created = [
        (match[1], match[2])
        for item in evidence
        if (
            match := re.fullmatch(
                r"创建 comment([1-9]\d*) 目标 ((?:poster|paper|course|comment)[1-9]\d*)", item
            )
        )
    ]
    if (
        len(deleted) != 9
        or len(set(deleted)) != 9
        or len(created) != 9
        or {item[0] for item in created} != set(deleted)
    ):
        return False
    parents = [
        (identifier, parent) for identifier, parent in created if not parent.startswith("comment")
    ]
    replies = [parent for _, parent in created if parent.startswith("comment")]
    targets = {parent for _, parent in parents}
    likes = [
        match[1]
        for item in evidence
        if (match := re.fullmatch(r"点赞恢复 ((?:poster|paper|course)[1-9]\d*)", item))
    ]
    contents = [
        match[1]
        for item in evidence
        if (match := re.fullmatch(r"服务端确认删除 ((?:poster|paper)[1-9]\d*)", item))
    ]
    images = {
        match[1]
        for item in evidence
        if (match := re.fullmatch(r"图片提交 ((?:poster|comment)[1-9]\d*)", item))
    }
    follow = [item for item in evidence if re.fullmatch(r"关注恢复 user[1-9]\d*", item)]
    poster = next((parent for _, parent in parents if parent.startswith("poster")), "")
    poster_comments = {"comment" + identifier for identifier, parent in parents if parent == poster}
    directed = [
        (match[1], match[2])
        for item in evidence
        if (match := re.fullmatch(r"定向回复 (poster|paper|course) 目标 comment([1-9]\d*)", item))
    ]
    reply_parents = {
        identifier: parent for identifier, parent in created if parent.startswith("comment")
    }
    roots = {
        re.match(r"[a-z]+", parent)[0]: "comment" + identifier for identifier, parent in parents
    }
    return (
        len(follow) == 1
        and images == {poster} | poster_comments
        and len(parents) == len(likes) == 3
        and len(replies) == 6
        and len(contents) == 2
        and {re.match(r"[a-z]+", parent)[0] for parent in targets} == {"poster", "paper", "course"}
        and set(replies) == {"comment" + identifier for identifier, _ in parents}
        and all(replies.count(root) == 2 for root in roots.values())
        and len(directed) == 3
        and {kind for kind, _ in directed} == set(roots)
        and all(reply_parents.get(identifier) == roots[kind] for kind, identifier in directed)
        and set(likes) == targets
        and set(contents) == {target for target in targets if not target.startswith("course")}
    )


def validate_community_write_test_output(bundle: Path, executed: set[str]) -> None:
    test = "ReleaseNetworkSmokeLifecycleTests/communityWritesClean"
    identifier = next((item for item in executed if normalized_test_id(item) == test), None)
    if identifier is None:
        return
    activities = json.loads(
        subprocess.check_output(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "activities",
                "--path",
                str(bundle),
                "--test-id",
                identifier,
            ],
            text=True,
        )
    )
    payloads = []

    def collect(value):
        if isinstance(value, dict):
            if re.fullmatch(
                r"community-write-contract(?:_[^/]+)?\.json", value.get("name", "")
            ) and value.get("payloadId"):
                payloads.append(value["payloadId"])
            for child in value.values():
                collect(child)
        elif isinstance(value, list):
            for child in value:
                collect(child)

    collect(activities)
    try:
        evidence = (
            json.loads(
                subprocess.check_output(
                    [
                        "xcrun",
                        "xcresulttool",
                        "get",
                        "object",
                        "--legacy",
                        "--format",
                        "raw",
                        "--path",
                        str(bundle),
                        "--id",
                        payloads[0],
                    ]
                )
            )
            if len(payloads) == 1
            else None
        )
    except ValueError:
        evidence = None
    if not isinstance(evidence, list) or not community_writes_complete(evidence):
        raise ValueError("Swift 社区写入实测输出需要通过 Python 创建、回复与清理约定。")


def school_authentication_complete(value: dict) -> bool:
    executed = set(value.get("probeInventory", value.get("executedProbes", [])))
    authenticated = value.get("authenticatedSchoolProbes", [])
    verified = value.get("verifiedSMSProbes", [])
    requested = set(value.get("requestedSMSPurposes", []))
    purposes = school_sms_inventory()
    return (
        {step.get("purpose") for step in authenticated} == purposes
        and requested <= purposes
        and requested == {step.get("purpose") for step in verified}
        and value.get("schoolSMSCoverage") == ("verified" if requested else "not_required")
        and all(
            step.get("probe") in executed
            and step.get("probe") in SCHOOL_SMS_PROBES.get(step.get("purpose"), set())
            for step in authenticated + verified
        )
    )


def filter_projected_diagnostics(value: dict, external_diagnostic) -> dict[str, list]:
    return {
        name: [item for item in value.get(name, []) if not external_diagnostic(item)]
        for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")
    }


def smoke_summary(group: str, value: dict, *, full: bool = True) -> dict:
    if group in NETWORK_GROUPS:
        required = set(value.get("requiredProbes", []))
        executed = set(value.get("executedProbes", []))
        sms_steps = value.get("verifiedSMSProbes", [])
        reported_scope = value.get("scope")
        expected_scope = (
            ("all" if full else reported_scope)
            if group == "network"
            else "school"
            if group == "school-sms"
            else group
        )
        projected_sms = group == "school-sms" and reported_scope == "all"
        raw_required = required
        if projected_sms:
            required = network_inventory("school")
            external = network_inventory("all") - required

            def external_diagnostic(item):
                return isinstance(item, str) and any(
                    item.startswith("[" + name + "]")
                    or item.startswith(name + "（")
                    or item == "必需探针缺失：" + name
                    for name in external
                )

            diagnostics = filter_projected_diagnostics(value, external_diagnostic)
            removed = any(
                len(diagnostics[name]) != len(value.get(name, [])) for name in diagnostics
            )
            value = dict(
                value,
                **diagnostics,
                passed=value.get("passed") is True or removed,
                workerDeployments={},
                executedProbes=sorted(required & executed),
                requestEvidence=[
                    row
                    for row in value.get("requestEvidence", [])
                    if isinstance(row, dict) and row.get("probe") in required
                ],
            )
        current_term = value.get("currentTerm")
        term_complete = (
            not full
            or group not in {"network", "school-sms"}
            or (
                value.get("requestedTerm") is None
                and isinstance(current_term, str)
                and bool(current_term.strip())
                and value.get("validatedTerm") == current_term
            )
        )
        from validation_provenance import network_requests_complete, worker_deployments_complete

        return {
            "passed": value.get("passed") is True
            and (reported_scope == expected_scope or projected_sms)
            and network_requests_complete(required, value)
            and worker_deployments_complete(expected_scope, value.get("workerDeployments", {}))
            and term_complete
            and (not projected_sms or raw_required == network_inventory("all"))
            and (
                group != "community-writes"
                or community_writes_complete(value.get("communityWriteEvidence", []))
            )
            and required == network_inventory(expected_scope)
            and bool(required)
            and required <= executed
            and (group != "school-sms" or school_authentication_complete(value))
            and not any(
                value.get(name)
                for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")
            ),
            "scope": expected_scope,
            "executedProbes": len(value.get("executedProbes", [])),
            "startedAt": value.get("startedAt"),
            "finishedAt": value.get("finishedAt"),
            "schoolSMSCoverage": value.get("schoolSMSCoverage"),
            "communityWriteEvidence": value.get("communityWriteEvidence", []),
            "productionSessionEvidence": value.get("productionSessionEvidence", []),
            "requestEvidence": value.get("requestEvidence", []),
            "requestEvidenceRequired": value.get("requestEvidenceRequired"),
            "workerDeployments": value.get("workerDeployments", {}),
            **{name: value.get(name) for name in ("requestedTerm", "currentTerm", "validatedTerm")},
            "diagnostics": {
                name: value.get(name, [])
                for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")
            },
            "runID": value.get("runID"),
            "inputDigest": value.get("inputDigest"),
            "verifiedSMSProbes": sms_steps,
            "authenticatedSchoolProbes": value.get("authenticatedSchoolProbes", []),
            "requestedSMSPurposes": value.get("requestedSMSPurposes", []),
            "requiredProbes": sorted(required),
            "probeInventory": sorted(executed),
            "probeLabels": value.get("probeLabels", {}),
            **{
                name: len(value.get(name, []))
                for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")
            },
        }
    if group == "icloud-cleanup":
        cleanup = value.get("cleanup", {})
        mac_cleanup = value.get("macCleanup", {})
        return {
            "passed": value.get("cleanupExitCode") == 0
            and cleanup.get("exitCode") == 0
            and icloud_stage_complete(cleanup, "testCleanup")
            and mac_cleanup.get("exitCode") == 0
            and icloud_stage_complete(mac_cleanup, "testMacCleanup")
            and cleanup.get("runID") == mac_cleanup.get("runID") == value.get("runID"),
            "cleanup": dict(cleanup, kvsDeletion="requested", cloudKitDeletion="server-confirmed"),
            "macCleanup": dict(
                mac_cleanup, kvsDeletion="requested", cloudKitDeletion="server-confirmed"
            ),
            "runID": value.get("runID"),
            "startedAt": value.get("cleanupStartedAt"),
            "finishedAt": value.get("cleanupFinishedAt"),
        }
    stages = [
        {
            name: row.get(name, 0)
            for name in (
                "stage",
                "exitCode",
                "totalTestCount",
                "passedTests",
                "failedTests",
                "skippedTests",
                "executedTests",
                "testTargets",
                "destination",
                "runID",
            )
        }
        for row in value.get("stages", [])
    ]
    expected = {"testPhoneRoundTrip", "testMacReceiveAndRestore"}
    cleanup = value.get("cleanup")
    mac_cleanup = value.get("macCleanup")
    cleanup_passed = value.get("cleanupExitCode", 0) == 0 and (
        cleanup is None
        or icloud_stage_complete(cleanup, "testCleanup")
        and cleanup.get("runID") == value.get("runID")
    )
    mac_cleanup_passed = (
        mac_cleanup is None
        or icloud_stage_complete(mac_cleanup, "testMacCleanup")
        and mac_cleanup.get("runID") == value.get("runID")
    )
    passed = (
        value.get("exitCode") == 0
        and cleanup_passed
        and mac_cleanup_passed
        and set(value.get("validatedDomains", [])) == ICLOUD_DOMAINS
        and value.get("cloudKitEnvironment") == "Production"
        and len(stages) == 2
        and {row["stage"] for row in stages} == expected
        and all(
            icloud_stage_complete(row, row["stage"]) and row.get("runID") == value.get("runID")
            for row in stages
        )
    )
    cleanup_evidence = (
        dict(cleanup, kind="standalone", kvsDeletion="requested")
        if cleanup is not None
        else dict(
            next((row for row in stages if row["stage"] == "testPhoneRoundTrip"), {}),
            kind="round-trip",
            kvsDeletion="peer-observed",
        )
    )
    mac_cleanup_evidence = (
        dict(mac_cleanup, kind="standalone", kvsDeletion="requested")
        if mac_cleanup is not None
        else dict(
            next((row for row in stages if row["stage"] == "testMacReceiveAndRestore"), {}),
            kind="round-trip",
            kvsDeletion="peer-observed",
        )
    )
    return {
        "passed": passed,
        "stages": stages,
        "validatedDomains": value.get("validatedDomains", []),
        "cloudKitEnvironment": value.get("cloudKitEnvironment"),
        "cleanup": cleanup_evidence,
        "macCleanup": mac_cleanup_evidence,
        "startedAt": value.get("startedAt"),
        "finishedAt": value.get("finishedAt"),
        "runID": value.get("runID"),
    }
