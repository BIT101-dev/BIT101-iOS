#!/usr/bin/env python3
"""Bind executed validation groups to the repository contents and release commit."""

from __future__ import annotations
import argparse
import fcntl
import json
import os
import re
from pathlib import Path
import subprocess
import sys
from swift_source_index import swift_code as mask_literals_and_comments
from functools import cache
from contextlib import contextmanager
from collections import Counter

sys.dont_write_bytecode = True
from swift_source_index import swift_syntax_index_sources
from validation_inputs import includes_input, repository_input_names
from validation_policy import (
    TEST_GROUPS,
    RELEASE_GROUPS,
    DEFAULT_VERIFY_GROUPS,
    FORMAL_RUNTIME_SUITES,
    MODULE_COVERAGE_FLOORS,
    IOS_MODULE_COVERAGE_FLOORS,
    SCHOOL_SMS_PROBES,
)
from validation_test_areas import (
    TEST_AREA_SUITES,
    test_selectors,
    test_inventory,
    test_case_inventory,
)
from validation_compilation import compilation_condition, active_swift_source
from validate_distribution import (
    archive_build_summary,
    valid_archive_provenance,
    valid_executable_uuids,
    distribution_contracts,
)
from validation_environment import (
    environment_context,
    complete_environment,
    toolchain_identity,
    exchange_identity,
    native_destinations_complete,
)
from validation_provenance import (
    report_lock,
    write_report,
    input_identity,
    normalized_test_id,
    LIVE_GROUPS,
    NETWORK_GROUPS,
    evidence_current,
    producing_run_matches,
    sampling_evidence_current,
    utc_now,
)
from validation_performance import result_bundle_findings
from validation_result_readers import (
    selected_test_inventory as selected_test_inventory,
    xcode_test_selections as xcode_test_selections,
    simulator_test_selection as simulator_test_selection,
    selected_test_summary_complete as selected_test_summary_complete,
    native_case_summary as native_case_summary,
    native_cases_complete as native_cases_complete,
    native_case_identity_matches as native_case_identity_matches,
    record_test_case_event as record_test_case_event,
    module_event_summary as module_event_summary,
    module_cases_complete as module_cases_complete,
    test_summary as test_summary,
    successful_test_counts as successful_test_counts,
    coverage_complete as coverage_complete,
    native_source_coverage as native_source_coverage,
)
from validation_smoke_readers import (
    icloud_stage_complete as icloud_stage_complete,
    school_sms_inventory as school_sms_inventory,
    network_inventory as network_inventory,
    community_writes_complete as community_writes_complete,
    validate_community_write_test_output as validate_community_write_test_output,
    school_authentication_complete as school_authentication_complete,
    filter_projected_diagnostics as filter_projected_diagnostics,
    smoke_summary as smoke_summary,
)


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
ICLOUD_DOMAINS = {"score-kvs", "schedule-cloudkit"}


def complete_summary(group: str, summary: dict) -> bool:
    if summary.get("passed") is not True:
        return False
    if group in TEST_GROUPS:
        executed = {
            normalized_test_id(identifier) for identifier in summary.get("executedTests", [])
        }
        complete = (
            successful_test_counts(summary)
            and coverage_complete(group, summary)
            and test_inventory(group) <= executed
            and summary.get("totalTests", 0) >= len(test_inventory(group))
        )
        if group == "modules":
            complete = complete and module_cases_complete(summary)
        else:
            complete = complete and native_cases_complete(summary, group)
        if group == "ui":
            from ui_inventory import has_action_evidence

            inventory = summary.get("uiInventory")
            complete = complete and has_action_evidence(inventory)
            if complete:
                from ui_rules import configured_interactions, source_runtime_interaction_findings
                from ui_source_facts import syntax_index

                complete = not source_runtime_interaction_findings(
                    syntax_index(), configured_interactions(), inventory.get("visitedControls", [])
                )
        return complete
    if group in NETWORK_GROUPS:
        from validation_provenance import network_requests_complete, worker_deployments_complete

        expected_scope = (
            "all" if group == "network" else "school" if group == "school-sms" else group
        )
        return (
            summary.get("scope") == expected_scope
            and set(summary.get("requiredProbes", [])) == network_inventory(expected_scope)
            and network_requests_complete(network_inventory(expected_scope), summary)
            and worker_deployments_complete(expected_scope, summary.get("workerDeployments", {}))
            and (
                group != "community-writes"
                or community_writes_complete(summary.get("communityWriteEvidence", []))
            )
            and (group != "school-sms" or school_authentication_complete(summary))
            and set(summary["requiredProbes"]) <= set(summary.get("probeInventory", []))
            and all(
                summary.get(name) == 0
                for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")
            )
        )
    if group == "icloud":
        stages = summary.get("stages", [])
        cleanup = summary.get("cleanup", {})
        mac_cleanup = summary.get("macCleanup", {})
        cleanup_stage = (
            "testCleanup" if cleanup.get("kind") == "standalone" else "testPhoneRoundTrip"
        )
        mac_cleanup_stage = (
            "testMacCleanup"
            if mac_cleanup.get("kind") == "standalone"
            else "testMacReceiveAndRestore"
        )
        return (
            set(summary.get("validatedDomains", [])) == ICLOUD_DOMAINS
            and summary.get("cloudKitEnvironment") == "Production"
            and icloud_stage_complete(cleanup, cleanup_stage)
            and icloud_stage_complete(mac_cleanup, mac_cleanup_stage)
            and len(stages) == 2
            and {row.get("stage") for row in stages}
            == {"testPhoneRoundTrip", "testMacReceiveAndRestore"}
            and all(icloud_stage_complete(row, row.get("stage")) for row in stages)
            and all(
                row.get("runID") == summary.get("runID") for row in [*stages, cleanup, mac_cleanup]
            )
        )
    if group == "icloud-cleanup":
        return all(
            icloud_stage_complete(summary.get(key, {}), stage)
            and summary[key].get("runID") == summary.get("runID")
            for key, stage in (("cleanup", "testCleanup"), ("macCleanup", "testMacCleanup"))
        )
    if group == "manual-device":
        from validation_manual import complete as manual_complete

        checks = summary.get("checks", {})
        return manual_complete(checks)
    if group == "build-archive":
        executables = summary.get("executables", {})
        return (
            summary.get("kind") == "build"
            and valid_archive_provenance(summary.get("archiveProvenance"))
            and isinstance(executables, dict)
            and set(executables) == set(distribution_contracts())
            and all(valid_executable_uuids(rows) for rows in executables.values())
        )
    if group.startswith("build-"):
        return summary.get("kind") == "build"
    if group == "restore":
        from validation_restore import complete as restore_complete

        return restore_complete(summary)
    return summary.get("kind") == "audit" and (
        group != "audit" or sampling_evidence_current(summary)
    )


def group_complete(report: dict, group: str, *, recorded_environment: bool = False) -> bool:
    from validation_provenance import complete_group_row, group_evidence_current
    from validation_coverage import policy_findings

    row = complete_group_row(report.get("groups", {}).get(group, {}))
    inputs = (
        input_identity(group, environment=row.get("environment", {}))
        if recorded_environment
        else input_identity(group)
    )
    return (
        row.get("exitCode") == 0
        and row.get("scope") == "full"
        and bool(row.get("runID"))
        and row.get("inputDigest") == inputs
        and group_evidence_current(group, row)
        and complete_environment(group, row.get("environment", {}))
        and complete_summary(group, row.get("summary", {}))
        and not policy_findings(report, group)
        and (
            group not in {"all", "ui"}
            or not result_bundle_findings(
                report, groups=(group,), recorded_environment=recorded_environment
            )
        )
    )


def release_findings(report: dict, digest: str, *, recorded_environment: bool = False) -> list[str]:
    from validation_coverage import policy_findings
    from validation_provenance import group_evidence_current

    errors = result_bundle_findings(report, recorded_environment=recorded_environment)
    if report.get("sourceDigest") != digest:
        errors.append("验证源码摘要与当前仓库内容存在差异。")
    for name in sorted(RELEASE_GROUPS):
        errors.extend(policy_findings(report, name))
        from validation_provenance import complete_group_row

        row = complete_group_row(report.get("groups", {}).get(name, {}))
        inputs = (
            input_identity(name, environment=row.get("environment", {}))
            if recorded_environment
            else input_identity(name)
        )
        if row.get("inputDigest") != inputs:
            errors.append(f"{name} 的验证输入已变化，请重新执行该组。")
        if not complete_environment(name, row.get("environment", {})):
            errors.append(f"{name} 需要保留执行环境及设备系统身份。")
        if not group_evidence_current(name, row):
            errors.append(f"{name} 的实际验收需要在发布检查前 24 小时内完成，请重新验收。")
        if name == "restore" and any(
            row.get("summary", {}).get(key) != row.get(key) for key in ("runID", "inputDigest")
        ):
            errors.append("restore 的就绪信号需要对应所属运行与输入摘要。")
        if (
            row.get("exitCode") != 0
            or row.get("scope") != "full"
            or not complete_summary(name, row.get("summary", {}))
        ):
            errors.append(f"{name} 需要完整执行并通过，并保留结果摘要。")
        if name == "audit" and row.get("summary", {}).get("releaseVersionChecked") is not True:
            errors.append("发布验收需要带 App Store 版本核对的静态审计。")
    if recorded_environment and toolchain_identity(
        report.get("groups", {}).get("build-archive", {}).get("environment", {})
    ) != toolchain_identity(environment_context("build-archive")):
        errors.append("发布编译工具链及 SDK 与已绑定证据存在差异，请重新验收。")
    groups = report.get("groups", {})
    checks = groups.get("manual-device", {}).get("summary", {}).get("checks", {})
    observation = checks.get("distribution-signing", {})
    from validation_manual import (
        distribution_matches_archive,
        baseline_matches_distribution,
        catalyst_matches_runtime,
    )

    if not distribution_matches_archive(observation, groups.get("build-archive", {})):
        errors.append("最终分发签名需要对应已验证归档的源码摘要、运行标识与可执行文件 UUID。")
    if not baseline_matches_distribution(checks.get("minimum-platforms", {}), observation):
        errors.append("最低系统安装验收需要对应最终分发包的版本、build、摘要与可执行文件 UUID。")
    if not catalyst_matches_runtime(
        checks.get("catalyst-desktop", {}), groups.get("catalyst-release-runtime", {})
    ):
        errors.append("Catalyst 桌面专项需要对应正式运行测试通过的应用摘要与可执行文件 UUID。")
    return errors


def record_test_summary(group, status, row, started_digest, run_id):
    row["report"] = ".build/extended-automation/test-metrics.txt"
    metrics = ROOT / row["report"]
    if metrics.is_file():
        text = metrics.read_text()
        if status == 0 and not producing_run_matches(text, started_digest, run_id):
            status = row["exitCode"] = 1
            print("测试指标需要来自本次验证运行。", file=sys.stderr)
        try:
            row["summary"] = test_summary(text)
            if group in {"all", "ui"} and status == 0:
                from validation_performance import bundle_identity, BUNDLE, current_commit

                row["resultBundleIdentity"] = bundle_identity(BUNDLE)
                row["sourceCommit"] = current_commit()
        except ValueError:
            if status == 0:
                raise
    if group == "catalyst-release-runtime" and status == 0:
        from validate_distribution import catalyst_application_identity

        try:
            row["application"] = catalyst_application_identity(
                ROOT
                / ".build/extended-automation/Build/Products/Release-maccatalyst/BIT101-iOS.app"
            )
        except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
            row["summary"]["passed"] = False
    return status


def record(group: str, status: int, scope: str, started_digest: str) -> int:
    from validation_provenance import source_snapshot

    with source_snapshot():
        digest = input_identity()
        input_digest = input_identity(group)
    run_id = os.getenv("BIT101_VALIDATION_RUN_ID", "")
    if status == 0 and (not started_digest or not run_id):
        status = 1
        print("验证记录需要所属工作流的开始摘要及运行标识。", file=sys.stderr)
    if started_digest and input_digest != started_digest:
        status = status or 1
        print("验证期间输入变更，请按当前输入重新执行该组。", file=sys.stderr)
    row = {
        "exitCode": status,
        "scope": scope,
        "inputDigest": input_digest,
        "runID": run_id,
        "recordedAt": utc_now().isoformat(),
        "environment": environment_context(group),
    }
    from validation_provenance import workflow_elapsed_seconds

    if (seconds := workflow_elapsed_seconds()) is not None:
        row["durationSeconds"] = seconds
    if status == 0 and not complete_environment(group, row["environment"]):
        status = row["exitCode"] = 1
        print(f"{group} 需要完整执行环境身份。", file=sys.stderr)
    if group in TEST_GROUPS:
        status = record_test_summary(group, status, row, started_digest, run_id)
    elif group in NETWORK_GROUPS | {"icloud", "icloud-cleanup"}:
        row["report"] = (
            ".build/icloud-cross-device-smoke/report.json"
            if group.startswith("icloud")
            else ".build/release-network-smoke/report/release-network-smoke.json"
        )
        row["summary"] = {
            "passed": False,
            "runID": run_id,
            "inputDigest": started_digest,
            "diagnostics": {"failures": ["当前运行缺少对应的 Smoke 报告"]},
        }
        if (ROOT / row["report"]).is_file():
            try:
                result = json.loads((ROOT / row["report"]).read_text())
            except (OSError, ValueError):
                result = {}
            if not isinstance(result, dict):
                result = {}
            if not producing_run_matches(result, started_digest, run_id):
                status = row["exitCode"] = status or 1
                print("Smoke 结果需要来自本次验证运行。", file=sys.stderr)
            else:
                row["summary"] = smoke_summary(group, result, full=scope == "full")
            if group in NETWORK_GROUPS:
                row["summary"]["inputDigest"] = started_digest
    else:
        row["summary"] = {
            "passed": status == 0,
            "kind": "build"
            if group.startswith("build-")
            else "restore"
            if group == "restore"
            else "audit",
        }
        if group == "audit":
            row["summary"].update(
                startedAt=os.getenv("BIT101_VALIDATION_STARTED_AT", ""),
                finishedAt=row["recordedAt"],
                releaseVersionChecked=status == 0 and os.getenv("BIT101_RELEASE_CHECK") == "true",
            )
        if group == "restore" and status == 0:
            from validation_restore import summary as restore_summary

            try:
                row["summary"] = restore_summary(run_id, started_digest)
            except (OSError, ValueError, KeyError, TypeError):
                row["summary"]["passed"] = False
        if group == "build-archive" and status == 0:
            try:
                row["summary"] = archive_build_summary(
                    ROOT
                    / (
                        "build/DeviceInstall/BIT101-iOS.xcarchive/Products/Applications/BIT101-iOS"
                        ".app"
                    )
                )
                row["summary"]["passed"] = row["summary"]["archiveProvenance"] == {
                    "inputDigest": started_digest,
                    "runID": run_id,
                }
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
                row["summary"]["passed"] = False
    selected_complete = True
    if scope == "selected" and group in TEST_GROUPS:
        try:
            expected = json.loads(os.getenv("BIT101_VALIDATION_EXPECTED_TESTS", "[]"))
            if not isinstance(expected, list) or not all(
                isinstance(test, str) for test in expected
            ):
                raise ValueError("测试清单需要字符串列表")
        except ValueError:
            expected = []
        row["expectedTests"] = expected
        selected_complete = selected_test_summary_complete(
            row.get("summary", {}), expected, group=group
        )
    if status == 0 and (
        not row.get("summary", {}).get("passed")
        or not selected_complete
        or scope == "full"
        and group in RELEASE_GROUPS | TEST_GROUPS | NETWORK_GROUPS
        and not complete_summary(group, row["summary"])
    ):
        status = row["exitCode"] = 1
        print(f"{group} 的执行摘要需要确认完整通过。", file=sys.stderr)
    if os.getenv("GITHUB_RUN_ID"):
        row["ciRun"] = (
            f"https://github.com/"
            f"{os.environ['GITHUB_REPOSITORY']}"
            f"/actions/runs/"
            f"{os.environ['GITHUB_RUN_ID']}"
        )
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        report.setdefault("groups", {})
        report["sourceDigest"] = digest
        report.pop("releaseCommit", None)
        report.pop("mergeCommit", None)
        previous = report["groups"].get(group, {})
        if scope == "selected" and group in TEST_GROUPS | NETWORK_GROUPS:
            full = previous if previous.get("scope") == "full" else previous.get("lastFullRun")
            if full and (group in TEST_GROUPS or status == 0):
                row["lastFullRun"] = full
        from validation_coverage import COVERAGE_GROUPS

        if group in COVERAGE_GROUPS:
            from validation_coverage import regressions, policy_floors

            problems = (
                regressions(
                    row.get("summary", {}).get("coverage", {}),
                    policy_floors(group, report.get("coveragePolicy", {})),
                )
                if scope == "full"
                else []
            )
            if problems:
                status = row["exitCode"] = 1
                row["summary"]["passed"] = False
                row["summary"]["coverageRegressions"] = problems
                print("覆盖率低于门槛：" + "；".join(problems), file=sys.stderr)
        report["groups"][group] = row
        if group in {"all", "ui"} and status == 0 and scope == "full":
            from validation_performance import extract_measurements

            try:
                row["performance"] = extract_measurements(row, group)
            except (
                OSError,
                ValueError,
                KeyError,
                TypeError,
                subprocess.CalledProcessError,
            ) as error:
                status = row["exitCode"] = 1
                row["summary"]["passed"] = False
                row["summary"]["performanceCaptureError"] = str(error)
                print(f"性能指标采集失败：{error}", file=sys.stderr)
        if group in TEST_GROUPS | NETWORK_GROUPS and status:
            from validation_provenance import invalidate_failed_evidence

            requested = (
                set(row.get("summary", {}).get("requiredProbes", []))
                if group in NETWORK_GROUPS
                else set(row.get("expectedTests", [])) or test_inventory(group)
            )
            invalidated = invalidate_failed_evidence(report, group, requested)
            if invalidated:
                print(
                    "定向复测失败，关联证据进入重新验收：" + "、".join(invalidated), file=sys.stderr
                )
        report["testedCommit"] = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip()
        write_report(report)
    return status


def recover_community_smoke(
    script: Path, directory: Path, run_id: str, original_status: int
) -> int:
    names = (
        "build.log",
        "console.log",
        "report/network-smoke-summary.txt",
        "report/release-network-smoke.json",
    )
    original = {
        name: (directory / name).read_bytes() for name in names if (directory / name).exists()
    }
    status = subprocess.run(
        [str(script), "community-cleanup"],
        env=dict(
            os.environ,
            BIT101_NETWORK_SMOKE_CAPTURE="none",
            BIT101_NETWORK_SMOKE_TERM="",
            BIT101_NETWORK_SMOKE_FIXTURES="",
        ),
    ).returncode
    report_name = names[-1]
    child_path = directory / report_name
    try:
        cleanup = json.loads(child_path.read_bytes()) if child_path.exists() else {}
    except (OSError, ValueError):
        cleanup = {"passed": False, "failures": ["清理报告读取失败；诊断见控制台记录"]}
    if cleanup.get("scope") != "community-cleanup" or cleanup.get("runID") in {None, "", run_id}:
        cleanup = {
            "scope": "community-cleanup",
            "passed": False,
            "failures": ["清理在产生所属报告前结束；原写入证据已保留"],
        }
        if status == 0:
            status = 1
    cleanup["exitStatus"] = status
    if (
        status
        and (directory / names[0]).exists()
        and (directory / names[0]).read_bytes() != original.get(names[0])
    ):
        cleanup["buildLog"] = (directory / names[0]).read_text()
    try:
        parent = json.loads(original[report_name]) if report_name in original else {}
    except ValueError:
        parent = {}
    if parent.get("runID") != run_id or parent.get("scope") != "community-writes":
        parent = {
            "runID": run_id,
            "scope": "community-writes",
            "passed": False,
            "coverageComplete": False,
            "failures": [
                f"社区写入脚本退出状态 {original_status}；恢复清理结果见 communityCleanup"
            ],
            "communityWriteEvidence": [],
        }
    parent["communityCleanup"] = cleanup
    for name in names[:-1]:
        path = directory / name
        value = original.get(name, b"")
        if name == "console.log" and path.exists() and path.read_bytes() != value:
            value += b"\n[community-cleanup]\n" + path.read_bytes()
        path.write_bytes(value)
    child_path.write_text(json.dumps(parent, ensure_ascii=False, indent=2) + "\n")
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=[
            "digest",
            "record",
            "bind",
            "check",
            "check-group",
            "summary",
            "suites",
            "self-test",
            "manual",
            "manual-schema",
            "verify-defaults",
            "runtime-suites",
            "conditions",
            "bind-merge",
            "check-merge",
            "baseline",
        ],
    )
    parser.add_argument("group", nargs="?", default="")
    parser.add_argument("status", nargs="?", type=int, default=0)
    parser.add_argument("--operation", default="", help="实际执行操作")
    parser.add_argument("--result", default="", help="实际观察结果")
    parser.add_argument("--outcome", choices=("passed", "failed"), help="人工验收结果状态")
    parser.add_argument("--observed-at", default="", help="实际观察的 ISO 8601 时间")
    parser.add_argument("--evidence", type=Path, help="本地验收附件")
    parser.add_argument(
        "--recorded-environment",
        action="store_true",
        help="核对已绑定证据的记录环境和当前发布工具链",
    )
    parser.add_argument("scope", nargs="?", default="full")
    args = parser.parse_args()
    if args.action == "manual-schema":
        from validation_manual import manual_structure

        try:
            print(json.dumps(manual_structure(args.group), ensure_ascii=False, indent=2))
        except ValueError as error:
            parser.error(str(error))
        return 0
    if args.action in {
        "record",
        "bind",
        "check",
        "check-group",
        "summary",
        "manual",
        "bind-merge",
        "check-merge",
        "baseline",
    }:
        from validation_environment import ci_commit_findings

        if os.getenv("GITHUB_SHA") or os.getenv("GITHUB_ACTIONS") == "true":
            commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
            ).strip()
            if errors := ci_commit_findings(commit):
                print("\n".join(errors), file=sys.stderr)
                return 1
    if args.action == "conditions":
        from validation_policy import workflow_conditions

        print(" ".join(workflow_conditions(args.group)))
        return 0
    if args.action == "runtime-suites":
        print("\n".join(sorted(FORMAL_RUNTIME_SUITES)))
        return 0
    if args.action == "verify-defaults":
        print("\n".join(DEFAULT_VERIFY_GROUPS))
        return 0
    if args.recorded_environment and args.action not in {"check", "check-merge", "summary"}:
        parser.error("记录环境用于已绑定证据的 check、check-merge 与 summary 操作。")
    if args.action == "check-group":
        with report_lock():
            report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        if group_complete(report, args.group):
            return 0
        print(f"{args.group} 需要完整子流程结果并匹配当前验证输入。", file=sys.stderr)
        return 1
    if args.action == "manual":
        from uuid import uuid4
        from validation_manual import (
            MANUAL_DEVICE_CHECKS,
            capture as capture_manual,
            complete as manual_complete,
            distribution_matches_archive,
        )

        if args.group not in MANUAL_DEVICE_CHECKS or args.evidence is None:
            parser.error("真机专项需要有效检查项及操作、观察结果和本地附件。")
        try:
            observation = capture_manual(
                args.operation,
                args.result,
                args.evidence,
                args.group,
                args.outcome,
                args.observed_at,
            )
        except (ValueError, OSError) as error:
            parser.error(str(error))
        if not complete_environment("manual-device", environment_context("manual-device")):
            parser.error("真机专项需要连接执行设备并读取完整系统身份。")
        digest = input_identity()
        with report_lock():
            report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
            if args.group == "distribution-signing" and not distribution_matches_archive(
                observation, report.get("groups", {}).get("build-archive", {})
            ):
                parser.error(
                    "分发产物需要来自当前已验证的归档，请执行 archive-signed 并导出该归档。"
                )
            report.setdefault("groups", {})
            report["sourceDigest"] = digest
            report.pop("releaseCommit", None)
            report.pop("mergeCommit", None)
            previous = report["groups"].get("manual-device", {})
            input_digest = input_identity("manual-device")
            summary = (
                previous.get("summary", {"checks": {}})
                if previous.get("inputDigest") == input_digest
                else {"checks": {}}
            )
            summary["checks"][args.group] = observation
            summary["passed"] = manual_complete(summary["checks"])
            summary["startedAt"] = min(row["capturedAt"] for row in summary["checks"].values())
            summary["finishedAt"] = max(row["capturedAt"] for row in summary["checks"].values())
            report["groups"]["manual-device"] = {
                "exitCode": 0 if summary["passed"] else 2,
                "scope": "full",
                "summary": summary,
                "inputDigest": input_digest,
                "runID": str(uuid4()),
                "environment": environment_context("manual-device"),
            }
            write_report(report)
        return 0
    if args.action == "digest":
        print(input_identity(args.group))
        return 0
    if args.action == "suites":
        if args.group not in TEST_AREA_SUITES:
            parser.error("测试领域：schedule、infrastructure、login、extensions")
        print("\n".join(sorted({test.split("/", 1)[0] for test in test_inventory(args.group)})))
        return 0
    if args.action == "self-test":
        from validation_artifacts import static_audit_lock

        with static_audit_lock(ROOT):
            return subprocess.call(
                [sys.executable, "-B", str(ROOT / "Scripts/validation_evidence_tests.py")]
            )
    if args.action == "record":
        return record(
            args.group, args.status, args.scope, os.getenv("BIT101_VALIDATION_INPUT_IDENTITY", "")
        )
    with report_lock():
        return inspect_report(args)


def inspect_report(args) -> int:
    report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
    if args.action == "baseline":
        if args.group == "":
            if report.get("coverageBaseCommit") == "" and report.get("coveragePolicy") == {}:
                return 0
            print("当前版本覆盖率验收需要清理目标提交基准。", file=sys.stderr)
            return 1
        if report.get("coverageBaseCommit") != args.group:
            print("覆盖率基准需要绑定合并目标分支的当前提交。", file=sys.stderr)
            return 1
        if set(report.get("coveragePolicy", {})) != {"modules", "all"}:
            print("覆盖率基准需要 macOS 与 iOS 两组阈值。", file=sys.stderr)
            return 1
        for group in ("modules", "all"):
            floors = report.get("coveragePolicy", {}).get(group)
            if (
                not isinstance(floors, dict)
                or not floors
                or any(
                    not isinstance(name, str) or type(value) is not int or not 0 <= value <= 100
                    for name, value in floors.items()
                )
            ):
                print("覆盖率基准需要目标提交登记的有效阈值。", file=sys.stderr)
                return 1
        if "BIT101-iOS.app" not in report["coveragePolicy"]["all"]:
            print("覆盖率基准需要目标提交的 App 阈值。", file=sys.stderr)
            return 1
        write_report(report)
        return 0
    if args.action in {"bind-merge", "check-merge"}:
        from validation_merge import findings as merge_findings

        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        candidate = dict(report, mergeCommit=commit) if args.action == "bind-merge" else report
        errors = merge_findings(
            candidate,
            digest=input_identity,
            complete=complete_summary,
            commit=commit,
            recorded_environment=args.recorded_environment,
        )
        if (
            args.action == "bind-merge"
            and subprocess.check_output(["git", "status", "--porcelain=v1"], cwd=ROOT).strip()
        ):
            errors.append("合并验证证据需要对应已完整提交的仓库内容。")
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        if args.action == "bind-merge":
            report["mergeCommit"] = commit
            write_report(report)
        return 0
    if args.action in {"bind", "check"}:
        errors = release_findings(
            report, input_identity(), recorded_environment=args.recorded_environment
        )
        if not errors:
            from validation_provenance import release_worker_findings

            errors.extend(release_worker_findings(report["groups"]["network"]["summary"]))
        pending = subprocess.check_output(
            ["git", "status", "--porcelain=v1", "--untracked-files=normal"], cwd=ROOT
        )
        if pending.strip():
            errors.append("发布验证证据需要对应已完整提交的仓库内容。")
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        if args.action == "check" and report.get("releaseCommit") != commit:
            errors.append("发布验证证据需要绑定当前提交。")
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        if args.action == "bind":
            report["releaseCommit"] = commit
            write_report(report)
    rows = [
        "| 验证组 | 范围 | 结果 | 用例 / 采样项 | 覆盖率模块 | 耗时 / 秒 |",
        "| --- | --- | --- | ---: | ---: | ---: |",
    ]
    from validation_coverage import policy_findings
    from validation_provenance import group_evidence_current

    for name, row in sorted(report.get("groups", {}).items()):
        result = row.get("summary", {})
        passed = (
            row.get("exitCode") == 0
            and result.get("passed") is True
            and not policy_findings(report, name)
        )
        if row.get("scope") == "full":
            passed = group_complete(report, name, recorded_environment=args.recorded_environment)
        elif name in TEST_GROUPS:
            passed = passed and selected_test_summary_complete(
                result, row.get("expectedTests", []), group=name
            )
        count = result.get(
            "passedTests",
            result.get(
                "executedProbes", sum(stage["passedTests"] for stage in result.get("stages", []))
            ),
        )
        environment = row.get("environment", {}) if args.recorded_environment else None
        current = row.get("inputDigest") == input_identity(
            name, environment=environment
        ) and group_evidence_current(name, row)
        label = (
            "待复验"
            if not current
            else ("定向通过" if row.get("scope") == "selected" else "通过")
            if passed
            else "待处理"
        )
        duration = row.get("durationSeconds", "?")
        rows.append(
            (
                f"| "
                f"{name}"
                f" | "
                f"{row.get('scope', '?')}"
                f" | "
                f"{label}"
                f" | "
                f"{count}"
                f" | "
                f"{len(result.get('coverage', {}))}"
                f" | "
                f"{duration}"
                f" |"
            )
        )
    if report.get("releaseCommit"):
        rows.append(f"\n发布提交：{report['releaseCommit']}")
    text = "\n".join(rows)
    summary = os.getenv("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a") as stream:
            stream.write("\n验证证据\n\n" + text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
