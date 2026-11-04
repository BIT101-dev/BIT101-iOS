"""Read selected test inventories and native test-case summaries."""

from __future__ import annotations
import json
import re
from pathlib import Path
import subprocess
from collections import Counter
from validation_policy import (
    IOS_MODULE_COVERAGE_FLOORS,
)
from validation_test_areas import (
    TEST_AREA_SUITES,
    test_selectors,
    test_inventory,
    test_case_inventory,
)
from validation_environment import (
    native_destinations_complete,
)
from validation_provenance import (
    normalized_test_id,
)

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
ICLOUD_DOMAINS = {"score-kvs", "schedule-cloudkit"}


def selected_test_inventory(group: str, selections: list[str]) -> set[str]:
    group = "all" if group in TEST_AREA_SUITES else group
    available = {normalized_test_id(test) for test in test_inventory(group)}
    expected = set()
    for selection in selections:
        prefix = normalized_test_id(selection)
        matches = {test for test in available if test == prefix or test.startswith(prefix + "/")}
        if not matches:
            raise ValueError(f"请核对测试筛选：{selection}")
        expected.update(matches)
    return expected


def xcode_test_selections(group: str, selections: list[str]) -> list[str]:
    selected_test_inventory(group, selections)
    selectors = test_selectors(group)
    return list(
        dict.fromkeys(
            selectors.get(normalized_test_id(selection), normalized_test_id(selection))
            for selection in selections
        )
    )


def simulator_test_selection(
    mode: str, scope: str, selections: list[str], shard: str | None
) -> tuple[list[str], list[str]]:
    from validation_coverage import shard_inventory

    if scope in {"full", "shard"}:
        tests = (
            shard_inventory(mode, *map(int, shard.split("/")))
            if scope == "shard" and shard
            else sorted(test_inventory(mode))
        )
        selections = [normalized_test_id(test) for test in tests]
    return sorted(selected_test_inventory(mode, selections)), xcode_test_selections(
        mode, selections
    )


def selected_test_summary_complete(
    summary: dict, expected: list[str], *, group: str = "all", simulator: bool = False
) -> bool:
    executed = {normalized_test_id(test) for test in summary.get("executedTests", [])}
    return (
        bool(expected)
        and summary.get("passed") is True
        and successful_test_counts(summary)
        and summary.get("totalTests", 0) >= len(expected)
        and executed == set(expected)
        and (
            module_cases_complete(summary)
            if group == "modules"
            else native_cases_complete(summary, group, simulator=simulator)
        )
    )


def native_case_summary(
    tree: dict, group: str, *, simulator: bool = False, device_identifier: str = ""
) -> dict:
    counts, identifiers = {}, {}
    passed = True

    def visit(value):
        nonlocal passed
        if isinstance(value, dict):
            if value.get("nodeType") == "Test Case":
                name = normalized_test_id(value["nodeIdentifier"])
                instances = [
                    child
                    for child in value.get("children", [])
                    if child.get("nodeType") == "Arguments"
                ] or [value]
                identities = [child.get("nodeIdentifierURL") for child in instances]
                passed &= (
                    value.get("result") == "Passed"
                    and all(child.get("result") == "Passed" for child in instances)
                    and name not in counts
                    and all(isinstance(identity, str) and identity for identity in identities)
                    and len(set(identities)) == len(identities)
                )
                counts[name], identifiers[name] = len(instances), identities
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(tree)
    inventory = test_case_inventory("all" if group in TEST_AREA_SUITES else group)
    destinations = [
        {"platform": row.get("platform"), "deviceIdentifier": row.get("deviceId")}
        for row in tree.get("devices", [])
        if isinstance(row, dict)
    ]
    passed &= native_destinations_complete(
        destinations, group, simulator=simulator, expected_device=device_identifier
    )
    return {
        "total": sum(counts.values()),
        "byTest": counts,
        "expectedByTest": {name: inventory.get(name) for name in counts},
        "identifiersByTest": identifiers,
        "destinations": destinations,
        "passed": bool(passed),
    }


def native_cases_complete(summary: dict, group: str, *, simulator: bool = False) -> bool:
    cases = summary.get("testCases", {})
    if not module_cases_complete(summary) or cases.get("passed") is not True:
        return False
    if not native_destinations_complete(cases.get("destinations"), group, simulator=simulator):
        return False
    expected = test_case_inventory("all" if group in TEST_AREA_SUITES else group)
    counts = {normalized_test_id(name): count for name, count in cases["byTest"].items()}
    identities = cases.get("identifiersByTest", {})
    return (
        counts == {name: expected.get(name) for name in counts}
        and set(identities) == set(counts)
        and all(
            isinstance(values, list)
            and len(values) == counts[name]
            and all(
                native_case_identity_matches(
                    value,
                    name,
                    parameterized=counts[name] > 1,
                    target="BIT101-iOSUITests" if group == "ui" else "BIT101-iOSTests",
                )
                for value in values
            )
            and len(set(values)) == len(values)
            for name, values in identities.items()
        )
    )


def native_case_identity_matches(
    value: object, name: str, *, parameterized: bool = False, target: str = "BIT101-iOSTests"
) -> bool:
    from urllib.parse import parse_qs, unquote, urlsplit

    if not isinstance(value, str):
        return False
    try:
        parsed = urlsplit(value)
    except ValueError:
        return False
    if parsed.scheme != "test" or parsed.netloc != "com.apple.xcode":
        return False
    if parameterized:
        arguments = parse_qs(parsed.query).get("args", [])
        if len(arguments) != 1 or re.fullmatch(r"(?:[0-9a-f]{2})+", arguments[0]) is None:
            return False
    parts = unquote(parsed.path).strip("/").split("/")
    if len(parts) < 4 or parts[:2] != ["BIT101-iOS", target]:
        return False
    parts[2] = parts[2].rsplit(".", 1)[-1]
    path = "/".join(parts[2:])
    return path == name or path.startswith((name + "(", name + "/"))


def record_test_case_event(kind: str, key: tuple, case_started, case_ended) -> None:
    if kind == "testCaseStarted":
        if case_started[key]:
            raise ValueError("参数实例开始事件需要唯一身份。")
        case_started[key] += 1
    else:
        if not case_started[key] or case_ended[key]:
            raise ValueError("参数实例结束事件需要对应的唯一开始记录。")
        case_ended[key] += 1


def module_event_summary(text: str) -> dict:
    records = [json.loads(line) for line in text.splitlines() if line.lstrip().startswith("{")]
    functions = {
        row["payload"]["id"]: row["payload"]
        for row in records
        if row.get("kind") == "test" and row["payload"].get("kind") == "function"
    }
    started, ended, skipped, failed = set(), set(), set(), set()
    case_started, case_ended = Counter(), Counter()
    runs = Counter()
    for row in records:
        if row.get("kind") != "event":
            continue
        event = row["payload"]
        kind, identifier = event["kind"], event.get("testID", "")
        if kind in {"runStarted", "runEnded"}:
            if (
                kind == "runStarted"
                and runs["runStarted"] != runs["runEnded"]
                or kind == "runEnded"
                and (runs["runStarted"] != runs["runEnded"] + 1 or started != ended)
            ):
                raise ValueError("测试运行事件需要完整且有序的起止配对。")
            runs[kind] += 1
        elif kind in {"testSkipped", "testCancelled", "testCaseCancelled"}:
            affected = {
                name
                for name in functions
                if name == identifier or name.startswith(identifier + "/")
            }
            if not affected:
                raise ValueError("跳过或取消事件需要对应测试函数。")
            skipped.update(affected)
        elif kind == "issueRecorded":
            issue = event.get("issue", {})
            if issue.get("isFailure") is False:
                continue
            affected = {
                name
                for name in functions
                if name == identifier or name.startswith(identifier + "/")
            }
            if not affected:
                raise ValueError("测试运行记录了函数范围外的失败。")
            failed.update(affected)
        elif identifier in functions and kind in {
            "testStarted",
            "testEnded",
            "testCaseStarted",
            "testCaseEnded",
        }:
            if runs["runStarted"] != runs["runEnded"] + 1:
                raise ValueError("函数事件需要归属正在执行的测试运行。")
            if kind == "testStarted":
                if identifier in started:
                    raise ValueError("函数开始事件需要唯一记录。")
                started.add(identifier)
            elif kind == "testEnded":
                if identifier not in started or identifier in ended:
                    raise ValueError("函数结束事件需要对应的唯一开始记录。")
                ended.add(identifier)
            elif kind in {"testCaseStarted", "testCaseEnded"}:
                if identifier not in started or identifier in ended:
                    raise ValueError("实例事件需要归属正在执行的测试函数。")
                case_id = event.get("_testCase", {}).get("id")
                if functions[identifier].get("isParameterized") and (
                    not isinstance(case_id, str) or not case_id
                ):
                    raise ValueError("参数实例事件需要 Swift Testing 的实例身份。")
                key = (identifier, case_id)
                record_test_case_event(kind, key, case_started, case_ended)
    attempted = started | ended | skipped | failed
    if (
        not attempted
        or started != ended
        or runs["runStarted"] == 0
        or runs["runStarted"] != runs["runEnded"]
        or case_started != case_ended
    ):
        raise ValueError("模块事件流需要完整的函数、参数实例及运行起止记录。")
    cases = {
        name: sum(count for (identifier, _), count in case_ended.items() if identifier == name)
        or (0 if functions[name].get("isParameterized") else 1)
        for name in sorted(ended)
    }
    expected = {}
    for name in sorted(ended):
        if not functions[name].get("isParameterized"):
            if cases[name] != 1:
                raise ValueError("普通函数需要对应单个测试实例。")
            expected[name] = 1
            continue
        declared = functions[name].get("_testCases")
        identities = (
            [case.get("id") for case in declared if isinstance(case, dict)]
            if isinstance(declared, list)
            else []
        )
        if (
            not identities
            or len(identities) != len(declared)
            or any(not isinstance(identifier, str) or not identifier for identifier in identities)
            or len(set(identities)) != len(identities)
            or set(identities)
            != {identifier for (function, identifier) in case_ended if function == name}
        ):
            raise ValueError("参数化测试需要执行 Swift Testing 清单中的全部实例。")
        expected[name] = len(identities)
    if any(count == 0 for count in cases.values()):
        raise ValueError("参数化测试需要实际执行参数实例。")
    return {
        "totalTests": len(attempted),
        "passedTests": len(ended - failed - skipped),
        "failedTests": len(failed),
        "skippedTests": len(skipped - failed),
        "executedTests": sorted(ended),
        "testCases": {"total": sum(cases.values()), "byTest": cases, "expectedByTest": expected},
    }


def module_cases_complete(summary: dict) -> bool:
    cases = summary.get("testCases")
    if not isinstance(cases, dict):
        return False
    counts = cases.get("byTest")
    return (
        isinstance(counts, dict)
        and bool(counts)
        and counts == cases.get("expectedByTest")
        and all(type(count) is int and count > 0 for count in counts.values())
        and type(cases.get("total")) is int
        and cases["total"] == sum(counts.values())
        and {normalized_test_id(name) for name in counts}
        == {normalized_test_id(name) for name in summary.get("executedTests", [])}
    )


def test_summary(text: str) -> dict:
    counts = re.search(r"总计 (\d+)；通过 (\d+)；失败 (\d+)；跳过 (\d+)", text)
    if counts:
        total, passed, failed, skipped = map(int, counts.groups())
    else:
        raise ValueError("测试摘要需要包含实际执行数量。")
    coverage = {}
    for name, percent, covered, executable in re.findall(
        r"^- ([^:\n]+): ([\d.]+)% \((\d+)/(\d+) lines\)", text, re.MULTILINE
    ):
        coverage[name] = {
            "percent": float(percent),
            "coveredLines": int(covered),
            "executableLines": int(executable),
        }
    return {
        "totalTests": total,
        "passedTests": passed,
        "failedTests": failed,
        "skippedTests": skipped,
        "passed": total > 0 and passed == total and failed == skipped == 0,
        "coverage": coverage,
        "coverageScope": next(
            (line for line in text.splitlines() if line.startswith("统计范围：")), "宿主报告范围"
        ),
        "executedTests": json.loads(
            next(
                (
                    line.split("：", 1)[1]
                    for line in text.splitlines()
                    if line.startswith("已执行用例：")
                ),
                "[]",
            )
        ),
        "testCases": json.loads(
            next(
                (
                    line.split("：", 1)[1]
                    for line in text.splitlines()
                    if line.startswith("测试实例：")
                ),
                "null",
            )
        ),
        "uiInventory": json.loads(
            next(
                (
                    line.split("：", 1)[1]
                    for line in text.splitlines()
                    if line.startswith("控件库存：")
                ),
                "null",
            )
        ),
    }


def successful_test_counts(summary: dict) -> bool:
    total = summary.get("totalTests", summary.get("totalTestCount", 0))
    return (
        all(
            type(value) is int
            for value in (
                total,
                summary.get("passedTests"),
                summary.get("failedTests"),
                summary.get("skippedTests"),
            )
        )
        and total > 0
        and total == summary.get("passedTests")
        and summary.get("failedTests") == summary.get("skippedTests") == 0
    )


def coverage_complete(group: str, summary: dict) -> bool:
    from validation_coverage import policy_floors, COVERAGE_GROUPS

    floors = policy_floors(group, {}) if group in COVERAGE_GROUPS else {}
    if group == "modules" and {
        path.name for path in (ROOT / "Modules").iterdir() if path.is_dir()
    } - {"ScheduleActivityContracts"} != set(floors):
        return False
    if group == "all" and {
        path.name for path in (ROOT / "Modules").iterdir() if path.is_dir()
    } != set(IOS_MODULE_COVERAGE_FLOORS):
        return False
    coverage = summary.get("coverage", {})
    if group == "catalyst-release-runtime":
        for name in ("BIT101-iOS.app", "Catalyst/TransportCore", "Catalyst/StorageCore"):
            row = coverage.get(name, {})
            covered, executable = row.get("coveredLines"), row.get("executableLines")
            if (
                type(covered) is not int
                or type(executable) is not int
                or not 0 < covered <= executable
            ):
                return False
    for name, floor in floors.items():
        row = coverage.get(name, {})
        covered, executable = row.get("coveredLines"), row.get("executableLines")
        if (
            type(covered) is not int
            or type(executable) is not int
            or not 0 < covered <= executable
            or covered * 100 < floor * executable
        ):
            return False
    return True


def native_source_coverage(
    products: Path,
    profile: Path,
    *,
    catalyst: bool = False,
    line_details: bool = False,
    include_app: bool = False,
) -> dict:
    import plistlib

    app = products / "BIT101-iOS.app"
    contents = app / "Contents" if catalyst else app
    with (contents / "Info.plist").open("rb") as stream:
        executable_name = plistlib.load(stream)["CFBundleExecutable"]
    executable = contents / "MacOS" / executable_name if catalyst else app / executable_name
    command = ["xcrun", "llvm-cov", "export", str(executable), "-instr-profile", str(profile)]
    for binary in sorted(executable.parent.glob("*.debug.dylib")):
        command += ["-object", str(binary)]
    for framework in sorted((contents / "Frameworks").glob("*.framework")):
        with (framework / "Resources/Info.plist" if catalyst else framework / "Info.plist").open(
            "rb"
        ) as stream:
            binary = framework / plistlib.load(stream)["CFBundleExecutable"]
        command += ["-object", str(binary)]
    if line_details:
        command.append("-format=lcov")
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    if result.stderr.strip():
        raise ValueError("iOS 模块覆盖率采集诊断：" + result.stderr.strip())
    from validation_coverage import coverage_source_path, lcov_lines

    if line_details:
        return lcov_lines(result.stdout, ROOT)
    files = {}
    for section in json.loads(result.stdout)["data"]:
        for file in section["files"]:
            path = coverage_source_path(file["filename"], ROOT)
            if (
                (path.is_relative_to(ROOT / "Modules") and "/Sources/" in str(path))
                or (catalyst or include_app)
                and path.is_relative_to(ROOT / "BIT101-iOS")
            ):
                files[path] = file["summary"]["lines"]
    modules = {}
    for path, lines in files.items():
        name = (
            path.relative_to(ROOT / "Modules").parts[0]
            if path.is_relative_to(ROOT / "Modules")
            else "BIT101-iOS.app"
        )
        hit, count = modules.get(name, (0, 0))
        modules[name] = hit + lines["covered"], count + lines["count"]
    if not modules:
        raise ValueError("原生覆盖率需要包含生产源码。")
    return modules
