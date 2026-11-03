"""Check structured validation evidence."""

import json
import os
import sys
from pathlib import Path
from unittest.mock import patch
from validation_provenance_tests import network_trace_fixture


def _matching_post_requests(rows: list, suffix: str, name: str) -> list:
    return [
        row
        for row in rows
        if row["method"] == "POST"
        and row["endpoint"].endswith(suffix)
        and (name != "rate" or row.get("query", {}).get("obj", "").startswith("course"))
    ]


def _always_true(*args, **kwargs) -> bool:
    return True


def _make_malformed_coverage(coverage: dict, field: str, value) -> dict:
    return {name: dict(row, **{field: value}) for name, row in coverage.items()}


def _check_recorded_summary(module_name, subject, groups, original_is_file):
    from contextlib import nullcontext, redirect_stdout
    from io import StringIO

    for recorded, expected in ((False, "待复验"), (True, "通过")):
        output = StringIO()
        arguments = ["validation_evidence.py", "summary"]
        if recorded:
            arguments.append("--recorded-environment")
        with (
            patch.object(subject, "report_lock", side_effect=nullcontext),
            patch.object(
                Path,
                "is_file",
                lambda path: path == subject.REPORT or original_is_file(path),
            ),
            patch.object(
                Path,
                "read_text",
                return_value=json.dumps({"groups": {"modules": groups["modules"]}}),
            ),
            patch.object(sys, "argv", arguments),
            patch.dict(os.environ, GITHUB_STEP_SUMMARY=""),
            redirect_stdout(output),
        ):
            assert subject.main() == 0
        assert f"| modules | full | {expected} |" in output.getvalue()


def _run_network_record_case(
    subject,
    group,
    base_result,
    passed,
    inventories,
    check_output,
    bit101_probes,
    nullcontext,
    redirect_stderr,
    string_io_cls,
):
    result = dict(
        base_result,
        passed=passed,
        coverageGaps=[],
        runID="network-run",
        startedAt=subject.utc_now().isoformat(),
        finishedAt=subject.utc_now().isoformat(),
    )
    report = {}

    def read(path, *args, **kwargs):
        return json.dumps(report if path == subject.REPORT else result)

    def save(value):
        report.update(value)

    def fake_check_output(command, *args, **kwargs):
        if command == ["git", "rev-parse", "HEAD"] and kwargs.get("text"):
            return "head"
        return check_output(command, *args, **kwargs)

    with (
        patch.object(subject, "input_identity", return_value="current"),
        patch.object(
            subject, "network_inventory", side_effect=lambda scope="all": inventories[scope]
        ),
        patch.object(subject, "report_lock", side_effect=nullcontext),
        patch.object(subject, "write_report", side_effect=save),
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_text", read),
        patch.object(subject.subprocess, "check_output", side_effect=fake_check_output),
        patch.dict(os.environ, BIT101_VALIDATION_RUN_ID="network-run"),
        redirect_stderr(string_io_cls()),
    ):
        expected_code = 0 if passed else 1
        assert subject.record(group, 0, "full", "current") == expected_code, group
        with patch.object(sys, "argv", ["validation_evidence.py", "check-group", group]):
            assert subject.main() == expected_code, group
        if group == "network" and passed:
            full = report["groups"][group]
            original = result
            result = network_trace_fixture(
                dict(
                    result,
                    scope="bit101",
                    requiredProbes=bit101_probes,
                    executedProbes=bit101_probes,
                )
            )
            assert subject.record(group, 0, "selected", "current") == 0
            assert report["groups"][group]["lastFullRun"] == full
            with patch.object(sys, "argv", ["validation_evidence.py", "check-group", group]):
                assert subject.main() == 0
            result = original


def icloud_stage_fixture(stage: str, counts: dict) -> dict:
    return dict(
        counts,
        stage=stage,
        runID="fixture",
        executedTests=["ICloudCrossDeviceSmokeTests/" + stage],
        testTargets=["BIT101-iOSTests"],
        destination={
            "platform": "macOS" if stage.startswith("testMac") else "iOS",
            "deviceIdentifier": "phone",
        },
    )


def native_case_fixture(summary, counts, group="all"):
    return dict(
        summary,
        testCases={
            "passed": True,
            "total": sum(counts.values()),
            "byTest": counts,
            "destinations": [
                {
                    "platform": "macOS"
                    if group in {"catalyst", "catalyst-release-runtime"}
                    else "iOS",
                    "deviceIdentifier": "fixture-device",
                }
            ],
            "expectedByTest": counts,
            "identifiersByTest": {
                name: [
                    "test://com.apple.xcode/BIT101-iOS/"
                    + ("BIT101-iOSUITests" if group == "ui" else "BIT101-iOSTests")
                    + "/"
                    + name
                    + "?args="
                    + format(index, "064x")
                    for index in range(count)
                ]
                for name, count in counts.items()
            },
        },
    )


def network_recording_self_test(subject, results) -> None:
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    from validation_environment import DEVICE_GROUPS

    assert set(results) == subject.NETWORK_GROUPS
    assert subject.NETWORK_GROUPS <= DEVICE_GROUPS
    bit101_probes = sorted(subject.network_inventory("bit101"))
    inventories = {
        scope: subject.network_inventory(scope)
        for scope in {"all", "bit101", *(result["scope"] for result in results.values())}
    }
    check_output = subject.subprocess.check_output
    for group, result in results.items():
        for passed in (True, False):
            _run_network_record_case(
                subject,
                group,
                result,
                passed,
                inventories,
                check_output,
                bit101_probes,
                nullcontext,
                redirect_stderr,
                StringIO,
            )
