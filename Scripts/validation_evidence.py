#!/usr/bin/env python3
"""Bind executed validation groups to the repository contents and release commit."""
from __future__ import annotations
import argparse
import ast
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
from code_quality_rules import mask_literals_and_comments
from functools import cache
from contextlib import contextmanager
sys.dont_write_bytecode = True
from swift_source_index import swift_syntax_index_sources

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
RELEASE_GROUPS = {"modules", "all", "release-runtime", "catalyst", "ui", "network", "school-sms", "icloud", "audit", "restore", "manual-device", "build-archive", "community-writes"}
MANUAL_DEVICE_CHECKS = {"system-autofill", "photos", "calendar-permissions", "notifications", "external-handoff", "web-interactions", "widget", "watch"}
TEST_GROUPS = {"modules", "all", "release-runtime", "catalyst", "ui", "schedule", "infrastructure", "login", "extensions"}
ICLOUD_DOMAINS = {"score-kvs", "schedule-cloudkit"}
SCHOOL_SMS_PROBES = {
    "webvpn": {"当前学期", "切换学期列表", "课表、考试与首周同步", "空教室校区列表", "空教室教学楼列表", "空教室占用数据"},
    "jwb": {"成绩认证接口"},
    "jwb_cjd": {"可信成绩单接口"},
    "school_sso_second_factor": {"课程中心原生认证", "课程中心 DDL 下载", "乐学日历订阅地址", "乐学 DDL 下载"},
}
MODULE_COVERAGE_FLOORS = {
    "ClientCore": 63, "CommunityCore": 76, "CommunityPersistence": 97, "CommunityTransport": 79,
    "CommunityUI": 100, "CourseFeature": 60, "DesignSystemKit": 86, "GalleryFeature": 49,
    "MapFeature": 34, "MediaKit": 100, "MineFeature": 77, "PaperFeature": 42,
    "ScheduleContracts": 83, "ScheduleDomain": 64, "ScheduleFeature": 40, "ScheduleInfrastructure": 48,
    "SchedulePersistence": 74, "SchedulePorts": 33, "ScheduleSharedStore": 97, "ScheduleSync": 76,
    "ScoreDomain": 73, "ScoreFeature": 52, "ScoreInfrastructure": 34, "StorageCore": 71, "TransportCore": 55,
}
IOS_MODULE_COVERAGE_FLOORS = {
    "ClientCore": 48, "CommunityCore": 47, "CommunityPersistence": 67, "CommunityTransport": 67,
    "CommunityUI": 6, "CourseFeature": 8, "DesignSystemKit": 44, "GalleryFeature": 14,
    "MapFeature": 21, "MediaKit": 53, "MineFeature": 25, "PaperFeature": 36,
    "ScheduleActivityContracts": 100, "ScheduleContracts": 88, "ScheduleDomain": 79,
    "ScheduleFeature": 30, "ScheduleInfrastructure": 26, "SchedulePersistence": 27,
    "SchedulePorts": 64, "ScheduleSharedStore": 52, "ScheduleSync": 5,
    "ScoreDomain": 45, "ScoreFeature": 7, "ScoreInfrastructure": 31, "StorageCore": 75, "TransportCore": 77,
}
TEST_AREA_MARKERS = {
    "schedule": ("Schedule", "Reminder", "AcademicTerm", "SmallTermWeek", "CourseLookup", "Classroom", "CloudPrompt", "CloudSyncPresentation"),
    "infrastructure": ("Infrastructure", "Storage", "DiskRepository", "DiskQuota", "Settings", "Dependency", "Preference", "NetworkClient", "NetworkSmoke", "AppDeepLink", "FeatureComposition", "AppUpdate", "AppLocalData", "CampusMap"),
    "login": ("Login",),
    "extensions": ("ExternalSchedule", "AppExternalDisplay"),
}


@contextmanager
def report_lock():
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    with REPORT.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def write_report(report: dict) -> None:
    incoming = REPORT.with_suffix(".incoming")
    incoming.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    incoming.replace(REPORT)


@cache
def compilation_condition(condition: str, group: str) -> bool:
    enabled = {"DEBUG", "EXTENDED_AUTOMATION", "BIT101_AUTOMATED_TESTING"} if group in {"all", "catalyst"} else {"EXTENDED_AUTOMATION", "BIT101_AUTOMATED_TESTING", "BIT101_UI_TESTING"} if group == "ui" else set()
    platform = "macOS" if group == "modules" else "iOS"
    architecture = os.uname().machine if group in {"modules", "catalyst"} else "arm64"
    def predicate(match):
        name, value = match.groups()
        value = value.strip()
        if name == "os": result = value == platform
        elif name == "targetEnvironment": result = value == "macCatalyst" and group == "catalyst"
        elif name == "arch": result = value == architecture
        elif name == "canImport":
            shared = {"Foundation", "Testing", "XCTest", "Swift", "Combine", "CryptoKit", "CloudKit", "SwiftUI", "EventKit", "UserNotifications",
                      "Observation", "os", "OSLog", "Security", "CoreFoundation", "CoreGraphics", "CoreLocation", "MapKit", "WidgetKit",
                      "WatchConnectivity", "WebKit", "Charts", "Compression", "ImageIO", "UniformTypeIdentifiers", "QuickLook", "PhotosUI",
                      "Network", "Darwin", "Dispatch"}
            if value in shared or (ROOT / "Modules" / value).is_dir(): result = True
            elif value == "UIKit": result = platform == "iOS"
            elif value == "AppKit": result = platform == "macOS"
            elif value == "ActivityKit": result = platform == "iOS" and group != "catalyst"
            else: raise ValueError(f"测试清单需要登记框架可用性：canImport({value})")
        else: raise ValueError(f"测试清单需要支持编译谓词：{name}({value})")
        return str(result)
    expression = re.sub(r"\b(\w+)\s*\(([^()]*)\)", predicate, condition)
    expression = re.sub(r"\b[A-Za-z_]\w*\b", lambda match: match[0] if match[0] in {"True", "False"} else str(match[0] in enabled), expression)
    expression = expression.replace("&&", " and ").replace("||", " or ").replace("!", " not ").strip()
    tree = ast.parse(expression, mode="eval")
    if any(type(node) not in {ast.Expression, ast.BoolOp, ast.UnaryOp, ast.And, ast.Or, ast.Not, ast.Constant} for node in ast.walk(tree)):
        raise ValueError(f"测试清单需要支持编译条件：{condition}")
    return bool(eval(compile(tree, "<Swift condition>", "eval"), {"__builtins__": {}}, {}))


def active_swift_source(source: str, group: str) -> str:
    levels = [(True, False)]
    active = []
    code_lines = mask_literals_and_comments(source).split("\n")
    for line, code in zip(source.split("\n"), code_lines):
        masked = re.sub(r"[^\r\n]", lambda match: " " * len(match[0].encode()), line)
        directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", code)
        if directive:
            kind, condition = directive.groups()
            if kind in {"if", "elseif"}:
                selected = compilation_condition(condition, group)
                if kind == "if": levels.append((levels[-1][0] and selected, selected))
                else:
                    _, taken = levels.pop()
                    levels.append((levels[-1][0] and not taken and selected, taken or selected))
            elif kind == "else":
                _, taken = levels.pop()
                levels.append((levels[-1][0] and not taken, True))
            else: levels.pop()
            active.append(masked)
        else: active.append(line if levels[-1][0] else masked)
    return "\n".join(active)


@cache
def test_inventory(group: str) -> set[str]:
    if group in TEST_AREA_MARKERS:
        return {test for test in test_inventory("all")
                if any(marker in test.split("/", 1)[0] for marker in TEST_AREA_MARKERS[group])}
    directory = ROOT / ("ModuleTests" if group == "modules" else "BIT101-iOSUITests" if group == "ui" else "BIT101-iOSTests")
    sources = {}
    for path in directory.rglob("*.swift"):
        sources[str(path)] = active_swift_source(path.read_text(), group)
    tests = {test["value"] for facts in swift_syntax_index_sources(sources).values() for test in facts["tests"]}
    return {test for test in tests if test.startswith("ReleaseRuntimeContractTests/")} if group == "release-runtime" else tests


def normalized_test_id(identifier: str) -> str:
    parts = identifier.split("/")
    method = next((index for index, part in enumerate(parts) if "(" in part), len(parts) - 1)
    return "/".join([parts[0].rsplit(".", 1)[-1], *parts[1:method], parts[method].split("(", 1)[0]]) if method else identifier


def selected_test_inventory(group: str, selections: list[str]) -> set[str]:
    group = "all" if group in TEST_AREA_MARKERS else group
    available = {normalized_test_id(test) for test in test_inventory(group)}
    expected = set()
    for selection in selections:
        prefix = normalized_test_id(selection)
        matches = {test for test in available if test == prefix or test.startswith(prefix + "/")}
        if not matches: raise ValueError(f"请核对测试筛选：{selection}")
        expected.update(matches)
    return expected


def selected_test_summary_complete(summary: dict, expected: list[str]) -> bool:
    executed = {normalized_test_id(test) for test in summary.get("executedTests", [])}
    return bool(expected) and summary.get("passed") is True and successful_test_counts(summary) \
        and summary.get("totalTests", 0) >= len(expected) and executed == set(expected)


@cache
def school_sms_inventory() -> set[str]:
    paths = [ROOT / "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift", ROOT / "Modules/ScheduleInfrastructure/Sources/ScheduleServiceLexue.swift"]
    return {purpose for facts in swift_syntax_index_sources({str(path): path.read_text() for path in paths}).values()
        for call in facts["invocations"] for purpose in re.findall(r'\bpurpose:\s*"([^"\\]+)"', call["value"])}


@cache
def network_inventory(scope: str = "all") -> set[str]:
    scope = {"community-writes": "communityWrites", "community-cleanup": "communityCleanup"}.get(scope, scope)
    paths = [ROOT / name for name in (
        "BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift",
        "Modules/CommunityCore/Sources/CommunityMessageStorage.swift", "Modules/PaperFeature/Sources/PaperModels.swift")]
    facts = swift_syntax_index_sources({str(path): path.read_text() for path in paths})
    models = facts[str(paths[0])]
    areas = {}
    for branch in models["controlFlow"]:
        if branch["scope"] != ["NetworkSmokeArea"] or not branch["value"].startswith("case ."):
            continue
        name = branch["value"].split(":", 1)[0].removeprefix("case .")
        start, end = branch["start"], branch["start"] + len(branch["value"].encode())
        areas[name] = {segment["value"] for segment in models["stringSegments"]
                       if start <= segment["start"] < end and segment["value"]}
    areas["bit101"] -= {"消息列表-", "文章列表-"}
    areas["bit101"] |= {"消息列表-" + (json.loads(case["rawValue"]) if case.get("rawValue") else case["name"])
                 for item in facts.values() for case in item["enumCases"] if case["scope"] == ["GalleryMessageType"]}
    for item in facts.values():
        for binding in item["bindings"]:
            if binding["scope"] == ["PaperSortOrder"] and binding["value"].startswith("title:"):
                areas["bit101"] |= {"文章列表-" + json.loads(value) for value in re.findall(r'"(?:[^"\\]|\\.)*"', binding["value"])}
    branch = next(item for item in models["controlFlow"] if item["scope"] == ["NetworkSmokeScope"]
                  and item["value"].startswith(f"case .{scope}:"))
    start = branch["start"] + len(branch["value"].split(":", 1)[0].encode()) + 1
    end = branch["start"] + len(branch["value"].encode())
    included = set(areas) if "return true" in branch["value"] else {
        member["value"].removeprefix(".") for member in models["members"]
        if start <= member["start"] < end and member["value"].removeprefix(".") in areas}
    return set().union(*(areas[area] for area in included))


def source_digest() -> str:
    names = subprocess.check_output([
        "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"
    ], cwd=ROOT).decode().split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(names) - {""}):
        path = ROOT / name
        if path.is_file():
            executable = b"x" if path.stat().st_mode & 0o111 else b"-"
            digest.update(name.encode() + b"\0" + executable + path.read_bytes() + b"\0")
    return digest.hexdigest()


def test_summary(text: str) -> dict:
    counts = re.search(r"总计 (\d+)；通过 (\d+)；失败 (\d+)；跳过 (\d+)", text)
    module_count = re.search(r"测试通过：(\d+) 项", text)
    if counts:
        total, passed, failed, skipped = map(int, counts.groups())
    elif module_count:
        total = passed = int(module_count[1])
        failed = skipped = 0
    else:
        raise ValueError("测试摘要需要包含实际执行数量。")
    coverage = {}
    for name, percent, covered, executable in re.findall(
        r"^- ([^:\n]+): ([\d.]+)% \((\d+)/(\d+) lines\)", text, re.MULTILINE
    ):
        coverage[name] = {"percent": float(percent), "coveredLines": int(covered), "executableLines": int(executable)}
    return {"totalTests": total, "passedTests": passed, "failedTests": failed, "skippedTests": skipped,
            "passed": total > 0 and passed == total and failed == skipped == 0, "coverage": coverage,
            "coverageScope": next((line for line in text.splitlines() if line.startswith("统计范围：")), "宿主报告范围"),
            "executedTests": json.loads(next((line.split("：", 1)[1] for line in text.splitlines() if line.startswith("已执行用例：")), "[]")),
            "uiInventory": json.loads(next((line.split("：", 1)[1] for line in text.splitlines() if line.startswith("控件库存：")), "null"))}


def community_writes_complete(evidence: list) -> bool:
    if not all(isinstance(item, str) for item in evidence):
        return False
    deleted = [match[1] for item in evidence if (match := re.fullmatch(r"服务端确认删除 comment([1-9]\d*)", item))]
    created = [(match[1], match[2]) for item in evidence
               if (match := re.fullmatch(r"创建 comment([1-9]\d*) 目标 ((?:poster|paper|course|comment)[1-9]\d*)", item))]
    if len(deleted) != 6 or len(set(deleted)) != 6 or len(created) != 6 or {item[0] for item in created} != set(deleted):
        return False
    parents = [(identifier, parent) for identifier, parent in created if not parent.startswith("comment")]
    replies = [parent for _, parent in created if parent.startswith("comment")]
    targets = {parent for _, parent in parents}
    likes = [match[1] for item in evidence if (match := re.fullmatch(r"点赞恢复 ((?:poster|paper|course)[1-9]\d*)", item))]
    contents = [match[1] for item in evidence if (match := re.fullmatch(r"服务端确认删除 ((?:poster|paper)[1-9]\d*)", item))]
    return len(parents) == len(replies) == len(likes) == 3 and len(contents) == 2 \
        and {re.match(r"[a-z]+", parent)[0] for parent in targets} == {"poster", "paper", "course"} \
        and set(replies) == {"comment" + identifier for identifier, _ in parents} \
        and set(likes) == targets and set(contents) == {target for target in targets if not target.startswith("course")}


def smoke_summary(group: str, value: dict, *, full: bool = True) -> dict:
    if group in {"network", "ddl", "school-sms", "community-writes", "community-cleanup"}:
        required = set(value.get("requiredProbes", []))
        executed = set(value.get("executedProbes", []))
        sms_steps = value.get("verifiedSMSProbes", [])
        expected_scope = ("all" if full else value.get("scope")) if group == "network" else "school" if group == "school-sms" else group
        return {"passed": value.get("passed") is True and value.get("scope") == expected_scope
                and (group != "community-writes" or community_writes_complete(value.get("communityWriteEvidence", [])))
                and required == network_inventory(expected_scope) and bool(required) and required <= executed
                and (group != "school-sms" or value.get("schoolSMSCoverage") == "verified"
                    and {step.get("purpose") for step in sms_steps} == school_sms_inventory()
                    and all(step.get("probe") in executed
                            and step.get("probe") in SCHOOL_SMS_PROBES.get(step.get("purpose"), set()) for step in sms_steps))
                and not any(value.get(name) for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")),
                "scope": value.get("scope"), "executedProbes": len(value.get("executedProbes", [])),
                "schoolSMSCoverage": value.get("schoolSMSCoverage"),
                "communityWriteEvidence": value.get("communityWriteEvidence", []),
                "verifiedSMSProbes": sms_steps,
                "requiredProbes": sorted(required), "probeInventory": sorted(executed),
                **{name: len(value.get(name, [])) for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")}}
    stages = [{name: row.get(name, 0) for name in
               ("stage", "exitCode", "totalTestCount", "passedTests", "failedTests", "skippedTests")}
              for row in value.get("stages", [])]
    expected = {"testPhoneRoundTrip", "testMacReceiveAndRestore"}
    cleanup = value.get("cleanup")
    cleanup_passed = value.get("cleanupExitCode", 0) == 0 and (cleanup is None or
        cleanup.get("exitCode") == 0 and cleanup.get("totalTestCount") == cleanup.get("passedTests") == 1
        and cleanup.get("failedTests") == cleanup.get("skippedTests") == 0)
    passed = value.get("exitCode") == 0 and cleanup_passed and set(value.get("validatedDomains", [])) == ICLOUD_DOMAINS \
        and value.get("cloudKitEnvironment") == "Production" and len(stages) == 2 and {row["stage"] for row in stages} == expected and all(
        row["exitCode"] == 0 and row["totalTestCount"] == row["passedTests"] > 0
        and row["failedTests"] == row["skippedTests"] == 0 for row in stages)
    return {"passed": passed, "stages": stages, "validatedDomains": value.get("validatedDomains", []),
            "cloudKitEnvironment": value.get("cloudKitEnvironment")}


def successful_test_counts(summary: dict) -> bool:
    total = summary.get("totalTests", summary.get("totalTestCount", 0))
    return total > 0 and total == summary.get("passedTests") and summary.get("failedTests") == summary.get("skippedTests") == 0


def coverage_complete(group: str, summary: dict) -> bool:
    floors = MODULE_COVERAGE_FLOORS if group == "modules" else {
        "BIT101-iOS.app": 35, **{"iOS/" + name: floor for name, floor in IOS_MODULE_COVERAGE_FLOORS.items()}
    } if group == "all" else {}
    if group == "modules" and {path.name for path in (ROOT / "Modules").iterdir() if path.is_dir()} \
            - {"ScheduleActivityContracts"} != set(floors):
        return False
    if group == "all" and {path.name for path in (ROOT / "Modules").iterdir() if path.is_dir()} != set(IOS_MODULE_COVERAGE_FLOORS):
        return False
    coverage = summary.get("coverage", {})
    for name, floor in floors.items():
        row = coverage.get(name, {})
        covered, executable = row.get("coveredLines"), row.get("executableLines")
        if not isinstance(covered, int) or not isinstance(executable, int) \
                or not 0 < covered <= executable or covered * 100 < floor * executable:
            return False
    return True


def ios_module_coverage(products: Path, profile: Path) -> dict[str, tuple[int, int]]:
    import plistlib
    app = products / "BIT101-iOS.app"
    with (app / "Info.plist").open("rb") as stream:
        executable = app / plistlib.load(stream)["CFBundleExecutable"]
    command = ["xcrun", "llvm-cov", "export", str(executable), "-instr-profile", str(profile)]
    for framework in sorted((app / "Frameworks").glob("*.framework")):
        with (framework / "Info.plist").open("rb") as stream:
            binary = framework / plistlib.load(stream)["CFBundleExecutable"]
        command += ["-object", str(binary)]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    if result.stderr.strip():
        raise ValueError("iOS 模块覆盖率采集诊断：" + result.stderr.strip())
    files = {}
    for section in json.loads(result.stdout)["data"]:
        for file in section["files"]:
            path = Path(file["filename"])
            if path.is_relative_to(ROOT / "Modules") and "/Sources/" in str(path):
                files[path] = file["summary"]["lines"]
    modules = {}
    for path, lines in files.items():
        name = path.relative_to(ROOT / "Modules").parts[0]
        hit, count = modules.get(name, (0, 0))
        modules[name] = hit + lines["covered"], count + lines["count"]
    if not modules:
        raise ValueError("iOS 模块覆盖率需要包含生产源码。")
    return modules


def complete_summary(group: str, summary: dict) -> bool:
    if summary.get("passed") is not True:
        return False
    if group in TEST_GROUPS:
        executed = {normalized_test_id(identifier) for identifier in summary.get("executedTests", [])}
        complete = successful_test_counts(summary) and coverage_complete(group, summary) and test_inventory(group) <= executed \
            and summary.get("totalTests", 0) >= len(test_inventory(group))
        if group == "ui":
            inventory = summary.get("uiInventory")
            complete = complete and isinstance(inventory, dict) and inventory.get("observed", 0) > 0 \
                and inventory.get("visited") == inventory.get("observed") and inventory.get("pending") == [] \
                and inventory.get("scope") == "mounted-controls" and inventory.get("unidentifiedControls") == 0 \
                and inventory.get("pendingDisabled") == [] \
                and inventory.get("identityScope") == "testCaseNavigationPresentationAndOccurrence"
            if complete:
                from ui_rules import documented_interactions, source_runtime_interaction_findings
                from ui_source_facts import syntax_index
                complete = not source_runtime_interaction_findings(syntax_index(), documented_interactions(), inventory.get("visitedControls", []))
        return complete
    if group in {"network", "school-sms", "community-writes", "community-cleanup"}:
        expected_scope = "all" if group == "network" else "school" if group == "school-sms" else group
        return summary.get("scope") == expected_scope and set(summary.get("requiredProbes", [])) == network_inventory(expected_scope) \
            and (group != "community-writes" or community_writes_complete(summary.get("communityWriteEvidence", []))) \
            and (group != "school-sms" or summary.get("schoolSMSCoverage") == "verified"
                and {step.get("purpose") for step in summary.get("verifiedSMSProbes", [])} == school_sms_inventory()
                and all(step.get("probe") in summary.get("probeInventory", []) for step in summary.get("verifiedSMSProbes", []))) \
            and set(summary["requiredProbes"]) <= set(summary.get("probeInventory", [])) and all(
            summary.get(name) == 0 for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes"))
    if group == "icloud":
        stages = summary.get("stages", [])
        return set(summary.get("validatedDomains", [])) == ICLOUD_DOMAINS and summary.get("cloudKitEnvironment") == "Production" \
            and len(stages) == 2 and {row.get("stage") for row in stages} == {"testPhoneRoundTrip", "testMacReceiveAndRestore"} and all(
            row.get("exitCode") == 0 and successful_test_counts(row) for row in stages)
    if group == "manual-device":
        checks = summary.get("checks", {})
        return set(checks) == MANUAL_DEVICE_CHECKS and all(isinstance(note, str) and note.strip() for note in checks.values())
    if group.startswith("build-"): return summary.get("kind") == "build"
    return summary.get("kind") == ("restore" if group == "restore" else "audit")


def release_findings(report: dict, digest: str) -> list[str]:
    errors = []
    if report.get("sourceDigest") != digest:
        errors.append("验证源码摘要与当前仓库内容存在差异。")
    for name in sorted(RELEASE_GROUPS):
        row = report.get("groups", {}).get(name, {})
        if row.get("exitCode") != 0 or row.get("scope") != "full" or not complete_summary(name, row.get("summary", {})):
            errors.append(f"{name} 需要完整执行并通过，并保留结果摘要。")
    return errors


def record(group: str, status: int, scope: str, started_digest: str) -> int:
    digest = source_digest()
    if started_digest and digest != started_digest:
        status = status or 1
        print("验证期间源码变更，请按当前源码重新执行该组。", file=sys.stderr)
    row = {"exitCode": status, "scope": scope}
    if group in TEST_GROUPS:
        row["report"] = ".build/extended-automation/test-metrics.txt"
        metrics = ROOT / row["report"]
        if metrics.is_file():
            try:
                row["summary"] = test_summary(metrics.read_text())
            except ValueError:
                if status == 0:
                    raise
    elif group in {"network", "ddl", "school-sms", "icloud", "community-writes", "community-cleanup"}:
        row["report"] = ".build/icloud-cross-device-smoke/report.json" if group == "icloud" else ".build/release-network-smoke/report/release-network-smoke.json"
        if (ROOT / row["report"]).is_file():
            row["summary"] = smoke_summary(group, json.loads((ROOT / row["report"]).read_text()), full=scope == "full")
    else:
        row["summary"] = {"passed": status == 0, "kind": "build" if group.startswith("build-") else "restore" if group == "restore" else "audit"}
    selected_complete = True
    if scope == "selected" and group in TEST_GROUPS:
        try:
            expected = json.loads(os.getenv("BIT101_VALIDATION_EXPECTED_TESTS", "[]"))
            if not isinstance(expected, list) or not all(isinstance(test, str) for test in expected): raise ValueError("测试清单需要字符串列表")
        except ValueError:
            expected = []
        row["expectedTests"] = expected
        selected_complete = selected_test_summary_complete(row.get("summary", {}), expected)
    if status == 0 and (not row.get("summary", {}).get("passed") or not selected_complete or
        scope == "full" and group in RELEASE_GROUPS | TEST_GROUPS and not complete_summary(group, row["summary"])):
        status = row["exitCode"] = 1
        print(f"{group} 的执行摘要需要确认完整通过。", file=sys.stderr)
    if os.getenv("GITHUB_RUN_ID"):
        row["ciRun"] = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        if report.get("sourceDigest") != digest:
            report = {"sourceDigest": digest, "groups": {}}
        report.pop("releaseCommit", None)
        report["groups"][group] = row
        report["testedCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        write_report(report)
    return status


def recover_community_smoke(script: Path, directory: Path, run_id: str, original_status: int) -> int:
    names = ("build.log", "console.log", "report/network-smoke-summary.txt", "report/release-network-smoke.json")
    original = {name: (directory / name).read_bytes() for name in names if (directory / name).exists()}
    status = subprocess.run([str(script), "community-cleanup"], env=dict(os.environ, BIT101_DEFER_APP_RESTORE="1")).returncode
    report_name = names[-1]
    child_path = directory / report_name
    try:
        cleanup = json.loads(child_path.read_bytes()) if child_path.exists() else {}
    except (OSError, ValueError):
        cleanup = {"passed": False, "failures": ["清理报告读取失败；诊断见控制台记录"]}
    cleanup["exitStatus"] = status
    if status and (directory / names[0]).exists():
        cleanup["buildLog"] = (directory / names[0]).read_text()
    try:
        parent = json.loads(original[report_name]) if report_name in original else {}
    except ValueError:
        parent = {}
    if parent.get("runID") != run_id or parent.get("scope") != "community-writes":
        parent = {"runID": run_id, "scope": "community-writes", "passed": False, "coverageComplete": False,
            "failures": [f"社区写入脚本退出状态 {original_status}；恢复清理结果见 communityCleanup"], "communityWriteEvidence": []}
    parent["communityCleanup"] = cleanup
    for name in names[:-1]:
        path = directory / name
        value = original.get(name, b"")
        if name == "console.log" and path.exists():
            value += b"\n[community-cleanup]\n" + path.read_bytes()
        path.write_bytes(value)
    child_path.write_text(json.dumps(parent, ensure_ascii=False, indent=2) + "\n")
    return status


def community_recovery_self_test() -> list[str]:
    from unittest.mock import patch
    directory = Path("/community-recovery-self-test")
    report = directory / "report/release-network-smoke.json"
    console = directory / "console.log"
    findings = []
    for original_status, cleanup_status in ((1, 0), (130, 0), (1, 7), (1, 8)):
        parent = {"runID": "parent", "scope": "community-writes", "passed": False, "failures": ["edit failed"],
            "communityWriteEvidence": ["created poster1"]}
        files = {report: json.dumps(parent).encode(), console: b"original failure", directory / "build.log": b"original build"}
        def clean(*args, **kwargs):
            files[report] = json.dumps({"runID": "cleanup", "scope": "community-cleanup", "passed": cleanup_status == 0}).encode()
            if cleanup_status == 8: files[report] = b"partial report"
            files[console] = b"cleanup outcome"
            files[directory / "build.log"] = b"cleanup build"
            return subprocess.CompletedProcess(args[0], cleanup_status)
        with patch.object(Path, "exists", lambda path: path in files), patch.object(Path, "read_bytes", lambda path: files[path]), \
            patch.object(Path, "read_text", lambda path: files[path].decode()), patch.object(Path, "write_bytes", lambda path, data: files.__setitem__(path, data)), \
            patch.object(Path, "write_text", lambda path, data: files.__setitem__(path, data.encode())), patch.object(subprocess, "run", clean):
            status = recover_community_smoke(Path("/network-smoke"), directory, "parent", original_status)
        restored = json.loads(files[report])
        if status != cleanup_status or restored["scope"] != "community-writes" or restored["failures"] != ["edit failed"] \
            or restored["communityWriteEvidence"] != ["created poster1"] or restored["communityCleanup"]["exitStatus"] != cleanup_status \
            or b"original failure" not in files[console] or b"cleanup outcome" not in files[console] or files[directory / "build.log"] != b"original build":
            findings.append("社区恢复自测：原始失败、创建证据与清理结果共同保留")
    from contextlib import nullcontext
    from io import StringIO
    from contextlib import redirect_stderr
    cleanup = {"scope": "community-cleanup", "passed": True, "requiredProbes": ["cleanup"], "executedProbes": ["cleanup"]}
    write_row = {"exitCode": 0, "scope": "full", "summary": {"passed": True}}
    previous = {"sourceDigest": "source", "groups": {"community-writes": write_row}}
    with patch(f"{__name__}.source_digest", return_value="source"), patch(f"{__name__}.network_inventory", return_value={"cleanup"}), \
            patch(f"{__name__}.report_lock", side_effect=nullcontext), patch(f"{__name__}.write_report") as saved, \
            patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", side_effect=[json.dumps(cleanup), json.dumps(previous)]), \
            patch.object(subprocess, "check_output", return_value="head"), redirect_stderr(StringIO()):
        result = record("community-cleanup", 0, "full", "source")
    if result or saved.call_args.args[0]["groups"]["community-writes"] != write_row:
        findings.append("社区恢复自测：成功清理沿独立范围记录并保留完整写入证据")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["digest", "record", "bind", "check", "summary", "suites", "self-test", "manual"])
    parser.add_argument("group", nargs="?", default="")
    parser.add_argument("status", nargs="?", type=int, default=0)
    parser.add_argument("--observation", default="", help="专项真机操作、观察结果及证据位置")
    parser.add_argument("scope", nargs="?", default="full")
    args = parser.parse_args()
    if args.action == "manual":
        if args.group not in MANUAL_DEVICE_CHECKS or not args.observation.strip():
            parser.error("真机专项需要有效检查项及操作、观察结果和证据位置。")
        digest = source_digest()
        with report_lock():
            report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
            if report.get("sourceDigest") != digest: report = {"sourceDigest": digest, "groups": {}}
            report.pop("releaseCommit", None)
            summary = report["groups"].get("manual-device", {}).get("summary", {"checks": {}})
            summary["checks"][args.group] = args.observation.strip()
            summary["passed"] = set(summary["checks"]) == MANUAL_DEVICE_CHECKS
            report["groups"]["manual-device"] = {"exitCode": 0 if summary["passed"] else 2, "scope": "full", "summary": summary}
            write_report(report)
        return 0
    if args.action == "digest":
        print(source_digest())
        return 0
    if args.action == "suites":
        if args.group not in TEST_AREA_MARKERS:
            parser.error("测试领域：schedule、infrastructure、login、extensions")
        print("\n".join(sorted({test.split("/", 1)[0] for test in test_inventory(args.group)})))
        return 0
    if args.action == "self-test":
        from unittest.mock import patch
        assert compilation_condition("os(macOS) && !canImport(UIKit)", "modules")
        assert compilation_condition("canImport(SwiftUI) && canImport(AppKit)", "modules")
        for group in ("modules", "all", "catalyst", "ui"):
            assert compilation_condition("canImport(MapKit) && canImport(WidgetKit) && canImport(CoreLocation)", group)
        try: compilation_condition("canImport(UnregisteredFramework)", "all")
        except ValueError: pass
        else: raise AssertionError("未知框架需要明确登记可用性")
        assert compilation_condition("os(iOS) && targetEnvironment(macCatalyst) && canImport(UIKit)", "catalyst")
        assert compilation_condition("os(iOS) && !targetEnvironment(macCatalyst)", "all")
        assert compilation_condition("DEBUG || RELEASE_NETWORK_SMOKE", "all")
        assert not compilation_condition("os(macOS) || targetEnvironment(macCatalyst)", "all")
        assert compilation_condition("BIT101_UI_TESTING && !targetEnvironment(macCatalyst)", "ui")
        assert compilation_condition("EXTENDED_AUTOMATION && BIT101_AUTOMATED_TESTING && BIT101_UI_TESTING && !DEBUG", "ui")
        from ui_rules import check_ui_test_inventory
        original_rglob, original_read = Path.rglob, Path.read_text
        ui_root = ROOT / "BIT101-iOSUITests"
        sample_path = ui_root / "Additional/Nested.swift"
        for declaration in ("final class FormatUITests: XCTestCase {\n  func testAdded() {}\n}",
                            "final\nclass FormatUITests\n: XCTestCase {\n    func testAdded() {}\n}"):
            def sample_read(path, *args, **kwargs):
                if path == sample_path: return declaration
                if path == ROOT / "docs/UI_INTERACTION_COVERAGE.md": return ""
                return original_read(path, *args, **kwargs)
            test_inventory.cache_clear()
            errors = []
            with patch.object(Path, "rglob", lambda path, pattern: iter([sample_path]) if path == ui_root else original_rglob(path, pattern)), \
                 patch.object(Path, "read_text", sample_read):
                check_ui_test_inventory(errors, {})
            assert "UI interaction map missing: FormatUITests/testAdded" in errors
            selector = re.search(r"bit101_ui_test_selections\(\).*?<<'PY'\n(.*?)\nPY", (ROOT / "Scripts/script-support.sh").read_text(), re.DOTALL)[1]
            with patch("validation_evidence.test_inventory", return_value={"FormatUITests/testAdded"}), \
                 patch.object(sys, "argv", ["selector", str(ROOT / "Scripts"), "Added", "FormatUITests"]), patch("builtins.print") as output:
                exec(compile(selector, "<ui selector>", "exec"), {})
            output.assert_called_once_with("FormatUITests/testAdded")
        test_inventory.cache_clear()
        with patch.object(os, "uname", return_value=os.uname_result(("Darwin", "host", "release", "version", "x86_64"))):
            compilation_condition.cache_clear()
            for group in ("modules", "catalyst"):
                assert compilation_condition("arch(x86_64) && !arch(arm64)", group)
            assert compilation_condition("arch(arm64) && !arch(x86_64)", "all")
        compilation_condition.cache_clear()
        conditional = "#if targetEnvironment(macCatalyst)\n中文手势\n#else\niOSGesture()\n#endif\n"
        active = active_swift_source(conditional, "ui")
        assert len(active.encode()) == len(conditional.encode()) and "中文手势" not in active and "iOSGesture()" in active
        unicode_sources = {}
        for index, separator in enumerate(["\u2028", "\u2029", "\v", "\f", "\x85"]):
            source = f"// fixture{separator}// trailing\r\n#if DEBUG\r\n@Test func mustRun() {{}}\r\n#else\r\n@Test func inactive() {{}}\r\n#endif\r\n"
            filtered = active_swift_source(source, "catalyst")
            assert len(filtered.encode()) == len(source.encode())
            unicode_sources[f"unicode-inventory-{index}"] = filtered
        for facts in swift_syntax_index_sources(unicode_sources).values():
            assert not facts["hasParseErrors"] and [test["value"] for test in facts["tests"]] == ["mustRun"]
        for literal in ['/*\n#if DEBUG\n*/', '/* outer /* nested */\n#if DEBUG\n*/',
                        '\"\"\"\n#if DEBUG\n\"\"\"', '#\"\"\"\n#if DEBUG\n\"\"\"#']:
            source = literal + "\n@Test func realTest() {}\n"
            assert "@Test func realTest" in active_swift_source(source, "modules")
        fixture = ROOT / ".build/static-audit/source-digest-self-test.sh"
        fixture.parent.mkdir(parents=True, exist_ok=True)
        try:
            fixture.write_text("exit 0\n")
            with patch.object(subprocess, "check_output", return_value=fixture.relative_to(ROOT).as_posix().encode()):
                fixture.chmod(0o600)
                original = source_digest()
                fixture.chmod(0o700)
                assert source_digest() != original
        finally:
            fixture.unlink(missing_ok=True)
        def icloud_summary(value):
            return smoke_summary("icloud", dict(validatedDomains=sorted(ICLOUD_DOMAINS), cloudKitEnvironment="Production", **value))
        test = {"passed": True, "totalTests": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        nested = swift_syntax_index_sources({"nested-tests": '@Suite struct Outer { @Suite struct Inner { @Testing.Test func works() {}; func testHelper() {} } }; class Base: XCTestCase {}; class Case: Base { func testActual() {}; func testArgument(_ value: Int) {}; static func testStatic() {} }; struct Ordinary { func testHelper() {} }'})["nested-tests"]
        assert {item["value"] for item in nested["tests"]} == {"Outer/Inner/works", "Case/testActual"}
        aliased = swift_syntax_index_sources({"base": 'typealias BehaviorBase = XCTest.XCTestCase; enum Namespace { typealias Base = BehaviorBase }; class Direct: XCTestCase {}; typealias Indirect = Direct',
            "tests": 'class MissingTests: Namespace.Base { func testRequiredBehavior() {} }; class Derived: Indirect { func testInheritedBehavior() {} }; enum Other { typealias Base = Ordinary; class Local: Base { func testHelper() {} } }; class Ordinary {}'})["tests"]
        assert {item["value"] for item in aliased["tests"]} == {"MissingTests/testRequiredBehavior", "Derived/testInheritedBehavior"}
        from code_quality_rules import audit_wiring_findings
        audit_path = ROOT / "Scripts/run-static-audit.sh"
        audit_source, original_read = audit_path.read_text(), Path.read_text
        for before, after in (("module_boundary_audit git_check", "swift_parse git_check"),
                              ("run_group artifact-hygiene artifact_hygiene", "run_group artifact-hygiene swift_parse")):
            def mutated_read(path, *arguments, **keywords):
                return audit_source.replace(before, after) if path == audit_path else original_read(path, *arguments, **keywords)
            with patch.object(Path, "read_text", mutated_read):
                assert any("静态审计回调" in finding for finding in audit_wiring_findings())
        with patch(__name__ + ".test_inventory", return_value={"Outer/Inner/works"}), patch(__name__ + ".coverage_complete", return_value=True):
            for identifier in ("Package.Outer/Inner/works()", "Package.Outer/Inner/works()/Example.swift:1:1"):
                assert complete_summary("schedule", dict(test, executedTests=[identifier]))
        summaries = {name: dict(test, totalTests=len(test_inventory(name)), passedTests=len(test_inventory(name)),
            executedTests=sorted(test_inventory(name))) for name in ("modules", "all", "release-runtime", "catalyst", "ui")}
        summaries["modules"]["coverage"] = {name: {"coveredLines": floor, "executableLines": 100}
                                            for name, floor in MODULE_COVERAGE_FLOORS.items()}
        summaries["all"]["coverage"] = {"BIT101-iOS.app": {"coveredLines": 35, "executableLines": 100}}
        summaries["all"]["coverage"].update({"iOS/" + name: {"coveredLines": floor, "executableLines": 100}
                                            for name, floor in IOS_MODULE_COVERAGE_FLOORS.items()})
        assert coverage_complete("all", summaries["all"])
        ios_missing = dict(summaries["all"]["coverage"])
        ios_missing.pop("iOS/MediaKit")
        assert not coverage_complete("all", dict(summaries["all"], coverage=ios_missing))
        ios_missing["iOS/MediaKit"] = {"coveredLines": 52, "executableLines": 100}
        assert not coverage_complete("all", dict(summaries["all"], coverage=ios_missing))
        assert coverage_complete("modules", summaries["modules"])
        assert not coverage_complete("modules", dict(summaries["modules"], coverage={}))
        missing = dict(summaries["modules"]["coverage"])
        missing.pop("ScheduleSync")
        assert not coverage_complete("modules", dict(summaries["modules"], coverage=missing))
        missing["ScheduleSync"] = {"coveredLines": 0, "executableLines": 100}
        assert not coverage_complete("modules", dict(summaries["modules"], coverage=missing))
        missing["ScheduleSync"] = {"coveredLines": 75, "executableLines": 100}
        assert not coverage_complete("modules", dict(summaries["modules"], coverage=missing))
        summaries["ui"]["uiInventory"] = {"observed": 1, "visited": 1, "pending": [],
                                          "scope": "mounted-controls", "unidentifiedControls": 0, "pendingDisabled": [],
                                          "identityScope": "testCaseNavigationPresentationAndOccurrence"}
        summaries["audit"] = {"passed": True, "kind": "audit"}
        summaries["restore"] = {"passed": True, "kind": "restore"}
        summaries["build-archive"] = {"passed": True, "kind": "build"}
        summaries["manual-device"] = {"passed": True, "checks": {name: "操作结果及证据" for name in MANUAL_DEVICE_CHECKS}}
        assert not complete_summary("manual-device", {"passed": True, "checks": {}})
        summaries["network"] = smoke_summary("network", {"passed": True, "scope": "all", "executedProbes": sorted(network_inventory()), "requiredProbes": sorted(network_inventory())})
        sms = {"passed": True, "scope": "school", "executedProbes": sorted(network_inventory("school")),
               "requiredProbes": sorted(network_inventory("school")), "schoolSMSCoverage": "verified",
               "verifiedSMSProbes": [{"purpose": purpose, "probe": sorted(SCHOOL_SMS_PROBES[purpose])[0]} for purpose in school_sms_inventory()]}
        assert set(SCHOOL_SMS_PROBES) == school_sms_inventory()
        writes = {"passed": True, "scope": "community-writes", "executedProbes": sorted(network_inventory("community-writes")),
                  "requiredProbes": sorted(network_inventory("community-writes")), "communityWriteEvidence":
                  ["服务端确认删除 poster1", "服务端确认删除 paper2", "点赞恢复 poster1", "点赞恢复 paper2", "点赞恢复 course3"]
                  + [f"服务端确认删除 comment{id}" for id in range(10, 16)]
                  + [f"创建 comment{id} 目标 {parent}" for id, parent in
                     [(10, "poster1"), (11, "comment10"), (12, "paper2"), (13, "comment12"), (14, "course3"), (15, "comment14")]]}
        assert community_writes_complete(writes["communityWriteEvidence"])
        assert not community_writes_complete(writes["communityWriteEvidence"][:5] + ["服务端确认删除 comment42"] * 6)
        assert not community_writes_complete([item.replace("目标 comment14", "目标 comment10") for item in writes["communityWriteEvidence"]])
        assert not community_writes_complete([item.replace("创建 comment15", "创建 comment14") for item in writes["communityWriteEvidence"]])
        cleanup = {"passed": True, "scope": "community-cleanup", "executedProbes": sorted(network_inventory("community-cleanup")),
                   "requiredProbes": sorted(network_inventory("community-cleanup"))}
        assert smoke_summary("community-cleanup", cleanup)["passed"]
        assert not smoke_summary("community-writes", cleanup, full=False)["passed"]
        with patch(f"{__name__}.test_inventory", return_value={"Suite/first", "Suite/second", "Other/third"}):
            expected = selected_test_inventory("all", ["Suite", "Other/third()"])
            assert expected == {"Suite/first", "Suite/second", "Other/third"}
            try: selected_test_inventory("all", ["Suite", "Missing/none()"])
            except ValueError: pass
            else: raise AssertionError("手选测试需要拒绝混合失效选择")
        chosen = {"passed": True, "totalTests": 3, "passedTests": 3, "failedTests": 0, "skippedTests": 0,
                  "executedTests": ["Suite/first()", "Suite/second()", "Other/third()"]}
        assert selected_test_summary_complete(chosen, sorted(expected))
        assert not selected_test_summary_complete(dict(chosen, totalTests=1, passedTests=1, executedTests=["Suite/first()"]), sorted(expected))
        summaries["community-writes"] = smoke_summary("community-writes", writes)
        assert summaries["community-writes"]["passed"]
        assert not smoke_summary("community-writes", dict(writes, communityWriteEvidence=[]))["passed"]
        summaries["school-sms"] = smoke_summary("school-sms", sms)
        assert summaries["school-sms"]["passed"]
        mismatched = [{"purpose": step["purpose"], "probe": "BIT101 登录状态"} for step in sms["verifiedSMSProbes"]]
        assert not smoke_summary("school-sms", dict(sms, verifiedSMSProbes=mismatched))["passed"]
        assert smoke_summary("school-sms", dict(sms, schoolSMSCoverage="preflight_only"))["passed"] is False
        assert smoke_summary("school-sms", dict(sms, verifiedSMSProbes=sms["verifiedSMSProbes"][:1]))["passed"] is False
        summaries["icloud"] = icloud_summary({"exitCode": 0, "stages": [
            dict(test, stage=name, totalTestCount=1, exitCode=0) for name in ("testPhoneRoundTrip", "testMacReceiveAndRestore")]})
        groups = {name: {"exitCode": 0, "scope": "full", "summary": summary} for name, summary in summaries.items()}
        report = {"sourceDigest": "source", "groups": groups}
        with patch("ui_rules.source_runtime_interaction_findings", return_value=[]):
            assert release_findings(report, "source") == []
        assert release_findings(report, "changed")
        groups["ui"]["scope"] = "selected"
        assert release_findings(report, "source")
        groups["ui"]["scope"] = "full"
        groups["ui"]["summary"]["passedTests"] = 0
        assert release_findings(report, "source")
        module = test_summary("测试通过：3 项\n统计范围：macOS\n- ScheduleSync: 75.00% (3/4 lines)")
        assert module["passed"] and module["coverage"]["ScheduleSync"]["coveredLines"] == 3
        assert test_summary("总计 4；通过 3；失败 0；跳过 1")["passed"] is False
        assert test_summary("总计 0；通过 0；失败 0；跳过 0")["passed"] is False
        assert complete_summary("ui", dict(test, executedTests=["Fixture/example"])) is False
        summaries["ui"]["passedTests"] = summaries["ui"]["totalTests"]
        summaries["ui"]["uiInventory"]["pending"] = ["new-control"]
        assert complete_summary("ui", summaries["ui"]) is False
        network = {"passed": True, "scope": "all", "executedProbes": sorted(network_inventory()), "requiredProbes": sorted(network_inventory())}
        assert smoke_summary("network", network)["passed"]
        assert smoke_summary("network", {"passed": True, "scope": "all", "executedProbes": ["unrelated"]})["passed"] is False
        network["coverageGaps"] = ["fixture"]
        assert smoke_summary("network", network)["passed"] is False
        ddl = {"passed": True, "scope": "ddl", "executedProbes": sorted(network_inventory("ddl")),
               "requiredProbes": sorted(network_inventory("ddl"))}
        assert len(network_inventory("ddl")) == 5 and smoke_summary("ddl", ddl)["passed"]
        ddl["skippedProbes"] = ["课程中心 DDL 下载"]
        assert smoke_summary("ddl", ddl)["passed"] is False
        assert icloud_summary({"exitCode": 0, "stages": []})["passed"] is False
        stages = [{"stage": name, "exitCode": 0, "totalTestCount": 1, "passedTests": 1}
                  for name in ["testPhoneRoundTrip", "testMacReceiveAndRestore"]]
        assert icloud_summary({"exitCode": 0, "stages": stages})["passed"]
        assert smoke_summary("icloud", {"exitCode": 0, "stages": stages})["passed"] is False
        cleanup = dict(stages[0], stage="testCleanup", failedTests=0, skippedTests=0)
        assert icloud_summary({"exitCode": 0, "stages": stages, "cleanup": cleanup, "cleanupExitCode": 0})["passed"]
        assert icloud_summary({"exitCode": 0, "stages": stages, "cleanup": cleanup, "cleanupExitCode": 1})["passed"] is False
        cleanup["passedTests"] = 0
        assert icloud_summary({"exitCode": 0, "stages": stages, "cleanup": cleanup})["passed"] is False
        stages[1]["passedTests"] = 0
        assert icloud_summary({"exitCode": 0, "stages": stages})["passed"] is False
        return 0
    if args.action == "record":
        return record(args.group, args.status, args.scope, os.getenv("BIT101_VALIDATION_SOURCE_DIGEST", ""))
    with report_lock():
        return inspect_report(args)


def inspect_report(args) -> int:
    report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
    if args.action in {"bind", "check"}:
        errors = release_findings(report, source_digest())
        pending = subprocess.check_output(["git", "status", "--porcelain=v1", "--untracked-files=normal"], cwd=ROOT)
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
    rows = ["| 验证组 | 范围 | 结果 | 用例 / 探针 | 覆盖率模块 |", "| --- | --- | --- | ---: | ---: |"]
    for name, row in sorted(report.get("groups", {}).items()):
        result = row.get("summary", {})
        passed = row.get("exitCode") == 0 and result.get("passed") is True
        count = result.get("passedTests", result.get("executedProbes", sum(stage["passedTests"] for stage in result.get("stages", []))))
        rows.append(f"| {name} | {row.get('scope', '?')} | {'通过' if passed else '待处理'} | {count} | {len(result.get('coverage', {}))} |")
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
