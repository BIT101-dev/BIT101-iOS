"""Focused checks for manual sample tests."""

import copy
import base64
from datetime import timedelta
from io import BytesIO
import json
from pathlib import Path
from unittest.mock import patch
import uuid
from validation_manual import MANUAL_DEVICE_CHECKS, capture
from validation_provenance import utc_now
import validate_distribution as distribution


def source_identity_fixture():
    snapshots = []

    def identify(group, files, context, **kwargs):
        snapshot = [group, copy.deepcopy(files), copy.deepcopy(context)]
        if snapshot not in snapshots:
            snapshots.append(snapshot)
        return str(uuid.UUID(int=snapshots.index(snapshot) + 1))

    return identify


def distribution_fixture() -> tuple[dict, dict]:
    contracts = distribution.distribution_contracts()
    main = next(
        identifier
        for identifier, value in contracts.items()
        if "com.apple.developer.icloud-services" in value["entitlements"]
    )
    rows = []
    for identifier, value in contracts.items():
        entitlements = copy.deepcopy(value["entitlements"])
        entitlements = {
            key: item.replace("$(TeamIdentifierPrefix)", value["team"] + ".")
            if isinstance(item, str)
            else item
            for key, item in entitlements.items()
        }
        entitlements.update(
            {
                "application-identifier": value["team"] + "." + identifier,
                "com.apple.developer.team-identifier": value["team"],
                "get-task-allow": False,
            }
        )
        if identifier == main:
            entitlements["com.apple.developer.icloud-container-environment"] = "Production"
        parents = [
            key
            for key, contract in contracts.items()
            if not contract["extension"] and identifier.startswith(key + ".")
        ]
        rows.append(
            {
                "identifier": identifier,
                "team": value["team"],
                "version": value["version"],
                "build": value["build"],
                "entitlements": entitlements,
                "signatureVerified": True,
                "compilationConditions": [],
                "testHostMarkers": [],
                "privacyManifest": distribution.privacy_manifest(distribution.ROOT / "BIT101-iOS"),
                "platform": "watchos" if value["platform"] == "watchOS" else "iphoneos",
                "supportedPlatforms": ["WatchOS" if value["platform"] == "watchOS" else "iPhoneOS"],
                "minimumOSVersion": value["minimumOSVersion"],
                "provisioningProfile": {
                    "uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, identifier)),
                    "teamIdentifiers": [value["team"]],
                    "entitlements": entitlements | {"beta-reports-active": True},
                    "expirationDate": (utc_now() + timedelta(days=1)).isoformat(),
                    "hasProvisionedDevices": False,
                    "provisionsAllDevices": False,
                },
                "executableUUIDs": [
                    {
                        "architecture": "arm64",
                        "uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, identifier)).upper(),
                    }
                ],
                "containerIdentifier": max(parents, key=len) if parents else "",
                "companionIdentifier": main
                if identifier != main and not value["extension"]
                else "",
            }
        )
    return contracts, {
        "schemaVersion": 1,
        "verifiedAt": utc_now().isoformat(),
        "archiveProvenance": {"inputDigest": "a" * 64, "runID": "fixture-run"},
        "bundles": rows,
    }


def captured_media_fixture() -> dict:
    data = evidence_fixture("_media")
    return {
        "path": "/evidence/media",
        "byteCount": len(data),
        "dataBase64": base64.b64encode(data).decode(),
    }


def platform_installed_bundles(bundles: list[dict], contracts: dict, platform: str) -> list[dict]:
    result = []
    keys = ("identifier", "version", "build", "executableUUIDs")
    for bundle in bundles:
        if contracts[bundle["identifier"]]["platform"] == platform:
            item = {key: bundle[key] for key in keys}
            item["distributionChannel"] = "testflight"
            result.append(item)
    return result


def manual_scenario_evidence(check, observations, make_action_entry):
    from validation_manual import MANUAL_SCENARIOS

    scenarios = {
        name: {
            "operation": "实际操作",
            "result": "观察结果",
            "outcome": "passed",
            "capturedAt": utc_now().isoformat(),
            "evidence": captured_media_fixture(),
            "capabilities": observations(name),
        }
        for name in MANUAL_SCENARIOS[check]
    }
    if check == "ipad-layout":
        for name, size in [
            ("portrait", (768, 1024)),
            ("landscape", (1024, 768)),
            ("split-view", (512, 768)),
            ("resize", (640, 768)),
        ]:
            scenarios[name]["windowSize"] = dict(zip(("width", "height"), size))
        scenarios["split-view"]["screenWidth"] = 1024
        scenarios["resize"]["previousWindowSize"] = {"width": 512, "height": 768}
    if check != "performance-baseline":
        from validation_compilation import compilation_settings
        from validation_provenance import input_identity

        expected_platform = "watchOS" if check == "watch" else "iOS"
        contract = next(
            (identifier, row)
            for identifier, row in distribution.distribution_contracts().items()
            if row["platform"] == expected_platform and not row["extension"]
        )
        identifier, row = contract
        bundle = next(
            value
            for value in distribution_fixture()[1]["bundles"]
            if value["identifier"] == identifier
        )
        if check == "installation-paths":
            from validation_manual import INSTALLATION_ACTIONS

            for name, actions in INSTALLATION_ACTIONS.items():
                scenarios[name]["actions"] = make_action_entry(actions)
            scenarios["app-store-upgrade"].update(
                sourceApplication={
                    "identifier": identifier,
                    "version": "1.0",
                    "build": "1",
                    "distributionChannel": "app-store",
                },
                appStoreLookup={
                    "trackId": 6761147125,
                    "bundleId": identifier,
                    "version": "1.0",
                },
            )
        desktop = check == "catalyst-desktop"
        platform = "macCatalyst" if desktop else "watchOS" if check == "watch" else "iOS"
        minimum = compilation_settings("macOS" if desktop else platform)[1]
        if desktop:
            scenarios["window-resize"].update(
                windowSize={"width": 1024, "height": 768},
                previousWindowSize={"width": 800, "height": 600},
            )
            for name, actions in {
                "menu-actions": ("app-menu", "window-menu"),
                "keyboard-navigation": ("tab", "return", "escape"),
                "permission-dialogs": ("photos", "calendar", "notifications"),
            }.items():
                scenarios[name]["actions"] = make_action_entry(actions)
        return json.dumps(
            {
                "schemaVersion": 1,
                "platform": platform,
                "deviceIdentifier": "fixture-mac" if desktop else "fixture-pad",
                "deviceModel": "Mac" if desktop else "iPad",
                "deviceFamily": "iPad",
                "systemVersion": minimum,
                "systemBuild": "fixture-build",
                "inputDigest": input_identity("manual-device", environment={}),
                "application": {
                    "identifier": identifier,
                    "version": row["version"],
                    "build": row["build"],
                    "configuration": "Release",
                    "testHostMarkers": [],
                    "minimumOSVersion": minimum,
                    **({} if desktop else {"distributionChannel": "testflight"}),
                    "executableUUIDs": bundle["executableUUIDs"],
                },
                "scenarios": scenarios,
            }
        ).encode()
    if check == "performance-baseline":
        from validation_manual import PERFORMANCE_WORKLOADS, performance_group
        from validation_policy import workflow_conditions

        for name, row in scenarios.items():
            test, workload = PERFORMANCE_WORKLOADS[name]
            group = performance_group(test)
            current = {
                "testIdentifier": test,
                "sourceCommit": "a" * 40,
                "input": workload,
                "capturedAt": row["capturedAt"],
                "environment": {
                    "deviceIdentifier": "fixture-phone",
                    "deviceModel": "iPhone",
                    "systemVersion": "26.0",
                    "systemBuild": "fixture",
                    "xcodeBuild": "fixture",
                    "configuration": "Release",
                    "compilerVersion": "a" * 64,
                    "compilationConditions": ["DEBUG", "BIT101_AUTOMATED_TESTING"],
                },
                "resultBundle": {
                    "path": ".build/extended-automation/test-results.xcresult",
                    "identity": "a" * 64,
                },
                "metrics": {
                    "clockSeconds": {"samples": [0.1] * 10, "mean": 0.1},
                    "peakPhysicalMemoryBytes": {"samples": [1024] * 10, "mean": 1024},
                },
            }
            from validation_performance import current_commit
            from validation_provenance import input_identity

            context = {
                "host": {"system": "fixture"},
                "developer": "/fixture",
                "xcode": {"DTXcodeBuild": "fixture"},
                "compiler": {"modified": 1, "size": 1, "version": "a" * 64},
                "sdks": {"iPhoneOS": {"Version": "26.0"}},
                "device": {
                    "identifier": "fixture-phone",
                    "model": "iPhone",
                    "systemVersion": "26.0",
                    "systemBuild": "fixture",
                },
            }
            current["sourceCommit"] = current_commit()
            current["environment"]["compilationConditions"] = sorted(workflow_conditions(group))
            from validation_performance import normalize_metrics

            current["execution"] = {
                "group": group,
                "runID": "fixture-run",
                "environment": context,
                "sourceCommit": current["sourceCommit"],
                "inputDigest": input_identity(group, environment=context),
                "bundleIdentity": "a" * 64,
            }
            current["xcresultMetrics"] = [
                {
                    "testIdentifier": test + "()",
                    "testRuns": [
                        {
                            "device": {"deviceId": "fixture-phone"},
                            "metrics": [
                                {
                                    "identifier": "com.apple.dt.XCTMetric_Clock.time.monotonic",
                                    "unitOfMeasurement": "s",
                                    "measurements": [0.1] * 10,
                                },
                                {
                                    "identifier": "com.apple.dt.XCTMetric_Memory.physical_peak",
                                    "unitOfMeasurement": "kB",
                                    "measurements": [1.024] * 10,
                                },
                            ],
                        }
                    ],
                }
            ]
            current["metrics"] = normalize_metrics(
                current["xcresultMetrics"], test, "fixture-phone"
            )
            baseline = copy.deepcopy(current)
            baseline.update(
                capturedAt=(utc_now() - timedelta(days=1)).isoformat(),
                approvedAt=(utc_now() - timedelta(hours=1)).isoformat(),
                approvedBy="maintainer",
            )
            baseline["resultBundle"]["identity"] = "b" * 64
            baseline["execution"]["bundleIdentity"] = "b" * 64
            for metric in baseline["metrics"].values():
                metric["maximumRegressionPercent"] = 10
            row["measurement"] = {"current": current, "baseline": baseline}
    return json.dumps(
        {
            "schemaVersion": 1,
            "deviceFamily": "iPad",
            "deviceIdentifier": "fixture-pad",
            "scenarios": scenarios,
        }
    ).encode()


def evidence_fixture(check: str) -> bytes:
    from validation_manual import MANUAL_SCENARIOS
    from validation_test_areas import manual_capabilities

    def observations(scenario):
        return {
            name: {"operation": "实际调用", "result": "观察响应", "outcome": "passed"}
            for name in manual_capabilities(check, scenario)
        }

    def make_action_entry(actions):
        return {
            action: {"operation": "实际操作", "result": "观察结果", "outcome": "passed"}
            for action in actions
        }

    if check in MANUAL_SCENARIOS:
        return manual_scenario_evidence(check, observations, make_action_entry)
    if check == "distribution-signing":
        return json.dumps(distribution_fixture()[1]).encode()
    if check == "minimum-platforms":
        from validation_manual import BASELINE_CHECKS

        contracts = distribution.distribution_contracts()
        bundles = distribution_fixture()[1]["bundles"]
        platforms = {}
        for platform, checks in BASELINE_CHECKS.items():
            version = max(
                (
                    value["minimumOSVersion"]
                    for value in contracts.values()
                    if value["platform"] == platform
                ),
                key=distribution.minimum_os_version,
            )
            platforms[platform] = {
                "deviceIdentifier": platform + "-fixture",
                "deviceModel": platform + "-device",
                "systemVersion": version,
                "systemBuild": "fixture-build",
                "capturedAt": utc_now().isoformat(),
                "installedBundles": platform_installed_bundles(bundles, contracts, platform),
                "checks": {
                    name: {"operation": "实际操作", "result": "观察结果", "outcome": "passed"}
                    for name in checks
                },
                "evidence": captured_media_fixture(),
            }
        return json.dumps({"schemaVersion": 1, "platforms": platforms}).encode()
    if check == "feedback-delivery":
        from email.utils import format_datetime

        identifier = "00000000-0000-4000-8000-000000000001"
        received_time = utc_now()
        received = received_time.isoformat()
        configuration = json.loads(
            (
                Path(__file__).resolve().parents[1] / "Cloudflare/ErrorReportWorker/wrangler.jsonc"
            ).read_text()
        )
        recipient = next(
            binding["destination_address"]
            for binding in configuration["send_email"]
            if binding["name"] == "REPORT_EMAIL"
        )
        return json.dumps(
            {
                "reportID": identifier,
                "storageKey": "report:" + received + ":" + identifier,
                "capabilities": observations("delivery"),
                "storedReport": {
                    "id": identifier,
                    "receivedAt": received,
                    "report": {
                        "mode": "sanitized",
                        "isDevelopmentBuild": False,
                        "errorTitle": "fixture",
                        "errorMessage": "fixture failure",
                    },
                    "emailDelivery": {
                        "status": "sent",
                        "attempts": 1,
                        "messageID": "provider-fixture",
                    },
                },
                "emailRecipient": recipient,
                "emailHeaders": {
                    "To": recipient,
                    "Message-ID": "<receipt@example.invalid>",
                    "X-BIT101-Report-ID": identifier,
                    "Date": format_datetime(received_time),
                },
                "emailMessageID": "<receipt@example.invalid>",
                "emailBody": "报告编号：" + identifier + "\n接收时间：" + received,
            }
        ).encode()
    return base64.b64decode(
        (
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jub0AAAAASUVOR"
            "K5CYII="
        )
    )


def captured_fixture(check: str, provenance: dict | None = None) -> dict:
    data = evidence_fixture(check)
    if check == "distribution-signing" and provenance is not None:
        proof = json.loads(data)
        proof["archiveProvenance"] = provenance
        data = json.dumps(proof).encode()
    path = Path("/evidence/" + check)
    original = Path.open
    with (
        patch.object(
            Path,
            "open",
            lambda value, *args, **kwargs: (
                BytesIO(data) if value == path else original(value, *args, **kwargs)
            ),
        ),
        patch("validation_performance.validate_capture"),
    ):
        return capture("实际操作", "观察结果", path, check, "passed", utc_now().isoformat())


@patch("validation_provenance._local_source_identity", new=source_identity_fixture())
def registration_self_test(subject) -> None:
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import sys

    checks = {name: captured_fixture(name) for name in MANUAL_DEVICE_CHECKS}
    state = {"groups": {"manual-device": {"summary": {"checks": checks}}}}
    environment = {"device": {"identifier": "phone"}}
    original_read, original_is_file = Path.read_text, Path.is_file

    def save(report):
        state.update(copy.deepcopy(report))

    with (
        patch.object(subject, "report_lock", side_effect=nullcontext),
        patch.object(subject, "environment_context", return_value=environment),
        patch("validation_provenance.environment_context", return_value=environment),
        patch.object(subject, "complete_environment", return_value=True),
        patch.object(
            Path, "is_file", lambda path: path == subject.REPORT or original_is_file(path)
        ),
        patch.object(
            Path,
            "read_text",
            lambda path, *args, **kwargs: (
                json.dumps(state)
                if path == subject.REPORT
                else original_read(path, *args, **kwargs)
            ),
        ),
        patch.object(subject, "write_report", side_effect=save),
        patch("validation_manual.capture", return_value=checks["photos"]),
        patch.object(sys, "argv", ["evidence", "manual", "photos", "--evidence", "/fixture"]),
        redirect_stderr(StringIO()),
    ):
        state["groups"]["manual-device"]["inputDigest"] = subject.input_identity("manual-device")
        assert subject.main() == 0
        original_digest = state["groups"]["manual-device"]["inputDigest"]
        original_restore = subject.input_identity("restore")
        environment["device"] = {
            "identifier": "tablet",
            "systemVersion": "other",
            "systemBuild": "other-build",
        }
        assert subject.input_identity("manual-device") == original_digest
        assert subject.input_identity("restore") != original_restore
        assert subject.main() == 0
        assert set(state["groups"]["manual-device"]["summary"]["checks"]) == set(checks)
        assert state["groups"]["manual-device"]["environment"]["device"]["identifier"] == "tablet"
        row = state["groups"]["manual-device"]
        assert str(uuid.UUID(row["runID"])) == row["runID"]
        with patch.object(sys, "argv", ["evidence", "check-group", "manual-device"]):
            assert subject.main() == 0
            for field, value in [("runID", ""), ("exitCode", 2), ("inputDigest", "stale")]:
                original = row[field]
                row[field] = value
                assert subject.main() == 1
                row[field] = original
        environment["xcode"] = {"version": "changed-toolchain"}
        assert subject.main() == 0
        assert state["groups"]["manual-device"]["inputDigest"] != original_digest
        assert set(state["groups"]["manual-device"]["summary"]["checks"]) == {"photos"}
        assert state["groups"]["manual-device"]["summary"]["passed"] is False
