#!/usr/bin/env python3
"""Bind executed validation groups to the repository contents and release commit."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
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
from validation_policy import TEST_GROUPS, RELEASE_GROUPS, DEFAULT_VERIFY_GROUPS, FORMAL_RUNTIME_SUITES, MODULE_COVERAGE_FLOORS, IOS_MODULE_COVERAGE_FLOORS
from validation_test_areas import TEST_AREA_SUITES
from validation_compilation import compilation_condition
from validate_distribution import archive_build_summary, valid_archive_provenance, valid_executable_uuids, distribution_contracts
from validation_environment import environment_context, complete_environment, toolchain_identity, exchange_identity
from validation_provenance import LIVE_GROUPS, NETWORK_GROUPS, evidence_current, producing_run_matches, sampling_evidence_current, utc_now
from validation_performance import result_bundle_findings

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
ICLOUD_DOMAINS = {"score-kvs", "schedule-cloudkit"}
SCHOOL_SMS_PROBES = {
    "webvpn": {"生产学校会话", "当前学期", "切换学期列表", "课表、考试与首周同步", "空教室校区列表", "空教室教学楼列表", "空教室占用数据"},
    "jwb": {"成绩认证接口"},
    "jwb_cjd": {"可信成绩单接口"},
    "school_sso_second_factor": {"课程中心原生认证", "课程中心 DDL 下载", "乐学日历订阅地址", "乐学 DDL 下载"},
}


@contextmanager
def report_lock(*, path: Path | None = None):
    destination = path if path is not None else REPORT
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def write_report(report: dict, *, path: Path | None = None) -> None:
    from validation_policy import MAXIMUM_REPORT_BYTES
    destination = path if path is not None else REPORT
    incoming = destination.with_suffix(".incoming")
    size = 1
    try:
        with incoming.open('wb') as stream:
            for chunk in json.JSONEncoder(ensure_ascii=False, indent=2).iterencode(report):
                data = chunk.encode()
                size += len(data)
                if size > MAXIMUM_REPORT_BYTES: raise ValueError('聚合验收证据需要控制在 128 MiB 以内。')
                stream.write(data)
            stream.write(b'\n')
        incoming.replace(destination)
    finally:
        incoming.unlink(missing_ok=True)




def active_swift_source(source: str, group: str, *, platform: str | None = None, path: str = '') -> str:
    levels = [(True, False)]
    active = []
    code_lines = mask_literals_and_comments(source).split("\n")
    for line, code in zip(source.split("\n"), code_lines):
        masked = re.sub(r"[^\r\n]", lambda match: " " * len(match[0].encode()), line)
        directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", code)
        if directive:
            kind, condition = directive.groups()
            if kind in {"if", "elseif"}:
                selected = compilation_condition(condition, group, platform=platform, path=path)
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
def test_selectors(group: str) -> dict[str, str]:
    if group in TEST_AREA_SUITES:
        return {test: selector for test, selector in test_selectors("all").items()
                if test.split("/", 1)[0] in TEST_AREA_SUITES[group]}
    directory = ROOT / ("ModuleTests" if group == "modules" else "BIT101-iOSUITests" if group == "ui" else "BIT101-iOSTests")
    sources = {}
    for path in directory.rglob("*.swift"):
        sources[str(path)] = active_swift_source(path.read_text(), group, path=str(path))
    selectors = {}
    for facts in swift_syntax_index_sources(sources).values():
        functions = {function['start']: function for function in facts['functionRanges']}
        for test in facts['tests']:
            selector = test['value']
            if test.get('isTestingTest'):
                parameters = functions[test['start']]['parameters']
                selector += '(' + ''.join((parameter['label'] or '_') + ':' for parameter in parameters) + ')'
            selectors[test['value']] = selector
    return {test: selector for test, selector in selectors.items() if test.split("/", 1)[0] in FORMAL_RUNTIME_SUITES} \
        if group in {"release-runtime", "catalyst-release-runtime"} else selectors


@cache
def test_inventory(group: str) -> set[str]:
    return set(test_selectors(group))


def normalized_test_id(identifier: str) -> str:
    parts = identifier.split("/")
    method = next((index for index, part in enumerate(parts) if "(" in part), len(parts) - 1)
    return "/".join([parts[0].rsplit(".", 1)[-1], *parts[1:method], parts[method].split("(", 1)[0]]) if method else identifier


def icloud_stage_complete(row: dict, stage: str) -> bool:
    if stage not in {'testPhoneRoundTrip', 'testMacReceiveAndRestore', 'testCleanup', 'testMacCleanup'}: return False
    destination = row.get('destination') or {}
    expected = 'ICloudCrossDeviceSmokeTests/' + stage
    return row.get('stage') == stage and row.get('exitCode') == 0 and row.get('totalTestCount') == 1 \
        and successful_test_counts(row) and row.get('executedTests') == [expected] \
        and row.get('testTargets') == ['BIT101-iOSTests'] and bool(row.get('runID')) \
        and destination.get('platform') == ('macOS' if stage.startswith('testMac') else 'iOS') \
        and bool(destination.get('deviceIdentifier'))


def selected_test_inventory(group: str, selections: list[str]) -> set[str]:
    group = "all" if group in TEST_AREA_SUITES else group
    available = {normalized_test_id(test) for test in test_inventory(group)}
    expected = set()
    for selection in selections:
        prefix = normalized_test_id(selection)
        matches = {test for test in available if test == prefix or test.startswith(prefix + "/")}
        if not matches: raise ValueError(f"请核对测试筛选：{selection}")
        expected.update(matches)
    return expected


def xcode_test_selections(group: str, selections: list[str]) -> list[str]:
    selected_test_inventory(group, selections)
    selectors = test_selectors(group)
    return list(dict.fromkeys(selectors.get(normalized_test_id(selection), normalized_test_id(selection))
        for selection in selections))


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
    includes = next(function for function in models['functionRanges']
        if function['scope'] == ['NetworkSmokeScope'] and function['name'] == 'includes')
    parameter = next(parameter['name'] for parameter in includes['parameters'] if parameter['type'] == 'NetworkSmokeArea')
    branch = next(item for item in models['controlFlow'] if includes['start'] <= item['start'] < includes['end']
        and re.match(r'case\b', item['value'])
        and scope in re.findall(r'\.\s*(\w+)', item['value'].split(':', 1)[0]))
    expression = re.sub(r'^return\b', '', mask_literals_and_comments(branch['value'].split(':', 1)[1]).strip()).strip()
    def enum_value(match):
        if match[1] not in areas: raise ValueError(f'Smoke 范围需要有效的 NetworkSmokeArea：{match[1]}')
        return json.dumps(match[1])
    expression = re.sub(r'\s+', ' ', re.sub(r'(?:\bNetworkSmokeArea\s*)?\.\s*(\w+)', enum_value, expression))
    from network_capability_rules import constant_boolean
    selected = {area: constant_boolean(expression, lambda name: area if name == parameter else None) for area in areas}
    if any(value is None for value in selected.values()): raise ValueError(f'Smoke 范围需要可求值的 Bool 表达式：{expression}')
    included = {area for area, value in selected.items() if value}
    return set().union(*(areas[area] for area in included))


def source_digest(group: str = "", *, environment: dict | None = None) -> str:
    names = repository_input_names(ROOT)
    digest = hashlib.sha256(group.encode() + b"\0")
    if group:
        digest.update(json.dumps(exchange_identity(environment_context(group) if environment is None else environment), sort_keys=True).encode() + b"\0")
    for name in sorted(set(names) - {""}):
        path = ROOT / name
        if path.is_file() and includes_input(name, group):
            executable = b"x" if path.stat().st_mode & 0o111 else b"-"
            digest.update(name.encode() + b"\0" + executable + path.read_bytes() + b"\0")
    return digest.hexdigest()


def module_event_summary(text: str) -> dict:
    records = [json.loads(line) for line in text.splitlines() if line.lstrip().startswith('{')]
    functions = {row['payload']['id']: row['payload'] for row in records
                 if row.get('kind') == 'test' and row['payload'].get('kind') == 'function'}
    started, ended, skipped, failed = set(), set(), set(), set()
    case_started, case_ended = Counter(), Counter()
    runs = Counter()
    for row in records:
        if row.get('kind') != 'event': continue
        event = row['payload']
        kind, identifier = event['kind'], event.get('testID', '')
        if kind in {'runStarted', 'runEnded'}: runs[kind] += 1
        elif kind in {'testSkipped', 'testCancelled', 'testCaseCancelled'}:
            affected = {name for name in functions if name == identifier or name.startswith(identifier + '/')}
            if not affected: raise ValueError('跳过或取消事件需要对应测试函数。')
            skipped.update(affected)
        elif kind == 'issueRecorded':
            issue = event.get('issue', {})
            if issue.get('isKnown') or issue.get('isFailure') is False: continue
            affected = {name for name in functions if name == identifier or name.startswith(identifier + '/')}
            if not affected: raise ValueError('测试运行记录了函数范围外的失败。')
            failed.update(affected)
        elif identifier in functions:
            if kind == 'testStarted': started.add(identifier)
            elif kind == 'testEnded': ended.add(identifier)
            elif kind in {'testCaseStarted', 'testCaseEnded'}:
                case_id = event.get('_testCase', {}).get('id')
                if functions[identifier].get('isParameterized') and (not isinstance(case_id, str) or not case_id):
                    raise ValueError('参数实例事件需要 Swift Testing 的实例身份。')
                key = (identifier, case_id)
                if kind == 'testCaseStarted':
                    if case_started[key]: raise ValueError('参数实例开始事件需要唯一身份。')
                    case_started[key] += 1
                else:
                    if not case_started[key] or case_ended[key]: raise ValueError('参数实例结束事件需要对应的唯一开始记录。')
                    case_ended[key] += 1
    attempted = started | ended | skipped | failed
    if not attempted or started != ended or runs['runStarted'] == 0 or runs['runStarted'] != runs['runEnded'] \
            or case_started != case_ended:
        raise ValueError('模块事件流需要完整的函数、参数实例及运行起止记录。')
    cases = {name: sum(count for (identifier, _), count in case_ended.items() if identifier == name)
             if functions[name].get('isParameterized') else 1 for name in sorted(ended)}
    if any(count == 0 for count in cases.values()):
        raise ValueError('参数化测试需要实际执行参数实例。')
    return {'totalTests': len(attempted), 'passedTests': len(ended - failed - skipped),
            'failedTests': len(failed), 'skippedTests': len(skipped - failed), 'executedTests': sorted(ended),
            'testCases': {'total': sum(cases.values()), 'byTest': cases}}


def module_cases_complete(summary: dict) -> bool:
    cases = summary.get('testCases')
    if not isinstance(cases, dict): return False
    counts = cases.get('byTest')
    return isinstance(counts, dict) and bool(counts) and all(type(count) is int and count > 0 for count in counts.values()) \
        and type(cases.get('total')) is int and cases['total'] == sum(counts.values()) \
        and {normalized_test_id(name) for name in counts} == {normalized_test_id(name) for name in summary.get('executedTests', [])}


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
        coverage[name] = {"percent": float(percent), "coveredLines": int(covered), "executableLines": int(executable)}
    return {"totalTests": total, "passedTests": passed, "failedTests": failed, "skippedTests": skipped,
            "passed": total > 0 and passed == total and failed == skipped == 0, "coverage": coverage,
            "coverageScope": next((line for line in text.splitlines() if line.startswith("统计范围：")), "宿主报告范围"),
            "executedTests": json.loads(next((line.split("：", 1)[1] for line in text.splitlines() if line.startswith("已执行用例：")), "[]")),
            "testCases": json.loads(next((line.split("：", 1)[1] for line in text.splitlines() if line.startswith("测试实例：")), "null")),
            "uiInventory": json.loads(next((line.split("：", 1)[1] for line in text.splitlines() if line.startswith("控件库存：")), "null"))}


def community_writes_complete(evidence: list) -> bool:
    if not all(isinstance(item, str) for item in evidence):
        return False
    if sum(bool(re.fullmatch(r"验收账号 user[1-9]\d*", item)) for item in evidence) != 1: return False
    deleted = [match[1] for item in evidence if (match := re.fullmatch(r"服务端确认删除 comment([1-9]\d*)", item))]
    created = [(match[1], match[2]) for item in evidence
               if (match := re.fullmatch(r"创建 comment([1-9]\d*) 目标 ((?:poster|paper|course|comment)[1-9]\d*)", item))]
    if len(deleted) != 9 or len(set(deleted)) != 9 or len(created) != 9 or {item[0] for item in created} != set(deleted):
        return False
    parents = [(identifier, parent) for identifier, parent in created if not parent.startswith("comment")]
    replies = [parent for _, parent in created if parent.startswith("comment")]
    targets = {parent for _, parent in parents}
    likes = [match[1] for item in evidence if (match := re.fullmatch(r"点赞恢复 ((?:poster|paper|course)[1-9]\d*)", item))]
    contents = [match[1] for item in evidence if (match := re.fullmatch(r"服务端确认删除 ((?:poster|paper)[1-9]\d*)", item))]
    images = {match[1] for item in evidence if (match := re.fullmatch(r"图片提交 ((?:poster|comment)[1-9]\d*)", item))}
    follow = [item for item in evidence if re.fullmatch(r"关注恢复 user[1-9]\d*", item)]
    poster = next((parent for _, parent in parents if parent.startswith("poster")), "")
    poster_comments = {"comment" + identifier for identifier, parent in parents if parent == poster}
    directed = [(match[1], match[2]) for item in evidence
                if (match := re.fullmatch(r"定向回复 (poster|paper|course) 目标 comment([1-9]\d*)", item))]
    reply_parents = {identifier: parent for identifier, parent in created if parent.startswith("comment")}
    roots = {re.match(r"[a-z]+", parent)[0]: "comment" + identifier for identifier, parent in parents}
    return len(follow) == 1 and images == {poster} | poster_comments and len(parents) == len(likes) == 3 and len(replies) == 6 and len(contents) == 2 \
        and {re.match(r"[a-z]+", parent)[0] for parent in targets} == {"poster", "paper", "course"} \
        and set(replies) == {"comment" + identifier for identifier, _ in parents} \
        and all(replies.count(root) == 2 for root in roots.values()) \
        and len(directed) == 3 and {kind for kind, _ in directed} == set(roots) \
        and all(reply_parents.get(identifier) == roots[kind] for kind, identifier in directed) \
        and set(likes) == targets and set(contents) == {target for target in targets if not target.startswith("course")}


def validate_community_write_test_output(bundle: Path, executed: set[str]) -> None:
    test = "ReleaseNetworkSmokeLifecycleTests/communityWritesCleanAfterLostResponsesCancellationAndResume"
    identifier = next((item for item in executed if normalized_test_id(item) == test), None)
    if identifier is None: return
    activities = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'activities',
        '--path', str(bundle), '--test-id', identifier], text=True))
    payloads = []
    def collect(value):
        if isinstance(value, dict):
            if re.fullmatch(r'community-write-contract(?:_[^/]+)?\.json', value.get('name', '')) and value.get('payloadId'):
                payloads.append(value['payloadId'])
            for child in value.values(): collect(child)
        elif isinstance(value, list):
            for child in value: collect(child)
    collect(activities)
    try:
        evidence = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'object', '--legacy', '--format', 'raw',
            '--path', str(bundle), '--id', payloads[0]])) if len(payloads) == 1 else None
    except ValueError: evidence = None
    if not isinstance(evidence, list) or not community_writes_complete(evidence):
        raise ValueError("Swift 社区写入实测输出需要通过 Python 创建、回复与清理合同。")


def school_authentication_complete(value: dict) -> bool:
    executed = set(value.get("probeInventory", value.get("executedProbes", [])))
    authenticated = value.get("authenticatedSchoolProbes", [])
    verified = value.get("verifiedSMSProbes", [])
    requested = set(value.get("requestedSMSPurposes", []))
    purposes = school_sms_inventory()
    return {step.get("purpose") for step in authenticated} == purposes \
        and requested <= purposes and requested == {step.get("purpose") for step in verified} \
        and value.get("schoolSMSCoverage") == ("verified" if requested else "not_required") \
        and all(step.get("probe") in executed
            and step.get("probe") in SCHOOL_SMS_PROBES.get(step.get("purpose"), set()) for step in authenticated + verified)


def smoke_summary(group: str, value: dict, *, full: bool = True) -> dict:
    if group in NETWORK_GROUPS:
        required = set(value.get("requiredProbes", []))
        executed = set(value.get("executedProbes", []))
        sms_steps = value.get("verifiedSMSProbes", [])
        reported_scope = value.get("scope")
        expected_scope = ("all" if full else reported_scope) if group == "network" else "school" if group == "school-sms" else group
        projected_sms = group == "school-sms" and reported_scope == "all"
        raw_required = required
        if projected_sms:
            required = network_inventory("school")
            external = network_inventory("all") - required
            def external_diagnostic(item):
                return isinstance(item, str) and any(item.startswith('[' + name + ']')
                    or item.startswith(name + '（') or item == '必需探针缺失：' + name for name in external)
            diagnostics = {name: [item for item in value.get(name, []) if not external_diagnostic(item)]
                for name in ('failures', 'coverageGaps', 'authenticationBlockers', 'skippedProbes')}
            removed = any(len(diagnostics[name]) != len(value.get(name, [])) for name in diagnostics)
            value = dict(value, **diagnostics, passed=value.get('passed') is True or removed,
                workerDeployments={},
                executedProbes=sorted(required & executed),
                requestEvidence=[row for row in value.get('requestEvidence', [])
                    if isinstance(row, dict) and row.get('probe') in required])
        current_term = value.get("currentTerm")
        term_complete = not full or group not in {"network", "school-sms"} or (
            value.get("requestedTerm") is None and isinstance(current_term, str) and bool(current_term.strip())
            and value.get("validatedTerm") == current_term)
        from validation_provenance import network_requests_complete, worker_deployments_complete
        return {"passed": value.get("passed") is True and (reported_scope == expected_scope or projected_sms)
                and network_requests_complete(required, value)
                and worker_deployments_complete(expected_scope, value.get('workerDeployments', {}))
                and term_complete
                and (not projected_sms or raw_required == network_inventory("all"))
                and (group != "community-writes" or community_writes_complete(value.get("communityWriteEvidence", [])))
                and required == network_inventory(expected_scope) and bool(required) and required <= executed
                and (group != "school-sms" or school_authentication_complete(value))
                and not any(value.get(name) for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")),
                "scope": expected_scope, "executedProbes": len(value.get("executedProbes", [])),
                "startedAt": value.get("startedAt"), "finishedAt": value.get("finishedAt"),
                "schoolSMSCoverage": value.get("schoolSMSCoverage"),
                "communityWriteEvidence": value.get("communityWriteEvidence", []),
                "productionSessionEvidence": value.get("productionSessionEvidence", []),
                "requestEvidence": value.get("requestEvidence", []),
                "requestEvidenceRequired": value.get("requestEvidenceRequired"),
                "workerDeployments": value.get("workerDeployments", {}),
                **{name: value.get(name) for name in ("requestedTerm", "currentTerm", "validatedTerm")},
                "diagnostics": {name: value.get(name, []) for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")},
                "runID": value.get("runID"), "inputDigest": value.get("inputDigest"),
                "verifiedSMSProbes": sms_steps,
                "authenticatedSchoolProbes": value.get("authenticatedSchoolProbes", []),
                "requestedSMSPurposes": value.get("requestedSMSPurposes", []),
                "requiredProbes": sorted(required), "probeInventory": sorted(executed),
                **{name: len(value.get(name, [])) for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")}}
    if group == "icloud-cleanup":
        cleanup = value.get("cleanup", {})
        mac_cleanup = value.get("macCleanup", {})
        return {"passed": value.get("cleanupExitCode") == 0 and cleanup.get("exitCode") == 0
                and icloud_stage_complete(cleanup, 'testCleanup') and mac_cleanup.get("exitCode") == 0
                and icloud_stage_complete(mac_cleanup, 'testMacCleanup')
                and cleanup.get('runID') == mac_cleanup.get('runID') == value.get('runID'), "cleanup": cleanup, "macCleanup": mac_cleanup,
                "startedAt": cleanup.get("recordedAt"), "finishedAt": mac_cleanup.get("recordedAt")}
    stages = [{name: row.get(name, 0) for name in
               ("stage", "exitCode", "totalTestCount", "passedTests", "failedTests", "skippedTests", "executedTests", "testTargets", "destination", "runID")}
              for row in value.get("stages", [])]
    expected = {"testPhoneRoundTrip", "testMacReceiveAndRestore"}
    cleanup = value.get("cleanup")
    mac_cleanup = value.get("macCleanup")
    cleanup_passed = value.get("cleanupExitCode", 0) == 0 and (cleanup is None or
        icloud_stage_complete(cleanup, 'testCleanup') and cleanup.get('runID') == value.get('runID'))
    mac_cleanup_passed = mac_cleanup is None or icloud_stage_complete(mac_cleanup, 'testMacCleanup') and mac_cleanup.get('runID') == value.get('runID')
    passed = value.get("exitCode") == 0 and cleanup_passed and mac_cleanup_passed and set(value.get("validatedDomains", [])) == ICLOUD_DOMAINS \
        and value.get("cloudKitEnvironment") == "Production" and len(stages) == 2 and {row["stage"] for row in stages} == expected and all(
        icloud_stage_complete(row, row['stage']) and row.get('runID') == value.get('runID') for row in stages)
    cleanup_evidence = dict(cleanup, kind="standalone") if cleanup is not None else dict(
        next((row for row in stages if row["stage"] == "testPhoneRoundTrip"), {}), kind="round-trip")
    mac_cleanup_evidence = dict(mac_cleanup, kind="standalone") if mac_cleanup is not None else dict(
        next((row for row in stages if row["stage"] == "testMacReceiveAndRestore"), {}), kind="round-trip")
    return {"passed": passed, "stages": stages, "validatedDomains": value.get("validatedDomains", []),
            "cloudKitEnvironment": value.get("cloudKitEnvironment"), "cleanup": cleanup_evidence, "macCleanup": mac_cleanup_evidence,
            "startedAt": value.get("startedAt"), "finishedAt": value.get("finishedAt"), "runID": value.get("runID")}


def successful_test_counts(summary: dict) -> bool:
    total = summary.get("totalTests", summary.get("totalTestCount", 0))
    return all(type(value) is int for value in (total, summary.get("passedTests"), summary.get("failedTests"), summary.get("skippedTests"))) \
        and total > 0 and total == summary.get("passedTests") and summary.get("failedTests") == summary.get("skippedTests") == 0


def coverage_complete(group: str, summary: dict) -> bool:
    from validation_coverage import policy_floors
    floors = policy_floors(group, {}) if group in {'modules', 'all', 'ui'} else {}
    if group == "modules" and {path.name for path in (ROOT / "Modules").iterdir() if path.is_dir()} \
            - {"ScheduleActivityContracts"} != set(floors):
        return False
    if group == "all" and {path.name for path in (ROOT / "Modules").iterdir() if path.is_dir()} != set(IOS_MODULE_COVERAGE_FLOORS):
        return False
    coverage = summary.get("coverage", {})
    for name, floor in floors.items():
        row = coverage.get(name, {})
        covered, executable = row.get("coveredLines"), row.get("executableLines")
        if type(covered) is not int or type(executable) is not int \
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
        if group == 'modules': complete = complete and module_cases_complete(summary)
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
    if group in NETWORK_GROUPS:
        from validation_provenance import network_requests_complete, worker_deployments_complete
        expected_scope = "all" if group == "network" else "school" if group == "school-sms" else group
        return summary.get("scope") == expected_scope and set(summary.get("requiredProbes", [])) == network_inventory(expected_scope) \
            and network_requests_complete(network_inventory(expected_scope), summary) \
            and worker_deployments_complete(expected_scope, summary.get('workerDeployments', {})) \
            and (group != "community-writes" or community_writes_complete(summary.get("communityWriteEvidence", []))) \
            and (group != "school-sms" or school_authentication_complete(summary)) \
            and set(summary["requiredProbes"]) <= set(summary.get("probeInventory", [])) and all(
            summary.get(name) == 0 for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes"))
    if group == "icloud":
        stages = summary.get("stages", [])
        cleanup = summary.get("cleanup", {})
        mac_cleanup = summary.get("macCleanup", {})
        cleanup_stage = 'testCleanup' if cleanup.get('kind') == 'standalone' else 'testPhoneRoundTrip'
        mac_cleanup_stage = 'testMacCleanup' if mac_cleanup.get('kind') == 'standalone' else 'testMacReceiveAndRestore'
        return set(summary.get("validatedDomains", [])) == ICLOUD_DOMAINS and summary.get("cloudKitEnvironment") == "Production" \
            and icloud_stage_complete(cleanup, cleanup_stage) and icloud_stage_complete(mac_cleanup, mac_cleanup_stage) \
            and len(stages) == 2 and {row.get("stage") for row in stages} == {"testPhoneRoundTrip", "testMacReceiveAndRestore"} and all(
            icloud_stage_complete(row, row.get('stage')) for row in stages) \
            and all(row.get('runID') == summary.get('runID') for row in [*stages, cleanup, mac_cleanup])
    if group == "icloud-cleanup":
        return all(summary.get(key, {}).get("exitCode") == 0 and successful_test_counts(summary.get(key, {}))
            for key in ("cleanup", "macCleanup"))
    if group == "manual-device":
        from validation_manual import complete as manual_complete
        checks = summary.get("checks", {})
        return manual_complete(checks)
    if group == "build-archive":
        executables = summary.get("executables", {})
        return summary.get("kind") == "build" and valid_archive_provenance(summary.get("archiveProvenance")) \
            and isinstance(executables, dict) and set(executables) == set(distribution_contracts()) \
            and all(valid_executable_uuids(rows) for rows in executables.values())
    if group.startswith("build-"): return summary.get("kind") == "build"
    if group == "restore":
        from validation_restore import complete as restore_complete
        return restore_complete(summary)
    return summary.get("kind") == "audit" and (group != "audit" or sampling_evidence_current(summary))


def release_findings(report: dict, digest: str, *, recorded_environment: bool = False) -> list[str]:
    errors = result_bundle_findings(report, recorded_environment=recorded_environment)
    if report.get("sourceDigest") != digest:
        errors.append("验证源码摘要与当前仓库内容存在差异。")
    for name in sorted(RELEASE_GROUPS):
        from validation_provenance import complete_group_row
        row = complete_group_row(report.get("groups", {}).get(name, {}))
        inputs = source_digest(name, environment=row.get("environment", {})) if recorded_environment else source_digest(name)
        if row.get("inputDigest") != inputs:
            errors.append(f"{name} 的验证输入已变化，请重新执行该组。")
        if not complete_environment(name, row.get("environment", {})):
            errors.append(f"{name} 需要保留执行环境及设备系统身份。")
        if not evidence_current(name, row.get("summary", {})):
            errors.append(f"{name} 的实际验收需要在发布检查前 24 小时内完成，请重新验收。")
        if name == "restore" and any(row.get("summary", {}).get(key) != row.get(key) for key in ("runID", "inputDigest")):
            errors.append("restore 的就绪信号需要对应所属运行与输入摘要。")
        if row.get("exitCode") != 0 or row.get("scope") != "full" or not complete_summary(name, row.get("summary", {})):
            errors.append(f"{name} 需要完整执行并通过，并保留结果摘要。")
    if recorded_environment and toolchain_identity(report.get("groups", {}).get("build-archive", {}).get("environment", {})) \
            != toolchain_identity(environment_context("build-archive")):
        errors.append("发布编译工具链及 SDK 与已绑定证据存在差异，请重新验收。")
    groups = report.get("groups", {})
    checks = groups.get("manual-device", {}).get("summary", {}).get("checks", {})
    observation = checks.get("distribution-signing", {})
    from validation_manual import distribution_matches_archive, baseline_matches_distribution
    if not distribution_matches_archive(observation, groups.get("build-archive", {})):
        errors.append("最终分发签名需要对应已验证归档的源码摘要、运行标识与可执行文件 UUID。")
    if not baseline_matches_distribution(checks.get("minimum-platforms", {}), observation):
        errors.append("最低系统安装验收需要对应最终分发包的版本、build、摘要与可执行文件 UUID。")
    return errors


def record(group: str, status: int, scope: str, started_digest: str) -> int:
    digest = source_digest()
    input_digest = source_digest(group)
    run_id = os.getenv("BIT101_VALIDATION_RUN_ID", "")
    if status == 0 and (not started_digest or not run_id):
        status = 1
        print("验证记录需要所属工作流的开始摘要及运行标识。", file=sys.stderr)
    if started_digest and input_digest != started_digest:
        status = status or 1
        print("验证期间输入变更，请按当前输入重新执行该组。", file=sys.stderr)
    row = {"exitCode": status, "scope": scope, "inputDigest": input_digest, "runID": run_id,
           "recordedAt": utc_now().isoformat(), "environment": environment_context(group)}
    if status == 0 and not complete_environment(group, row["environment"]):
        status = row["exitCode"] = 1
        print(f"{group} 需要完整执行环境身份。", file=sys.stderr)
    if group in TEST_GROUPS:
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
                    from validation_performance import bundle_digest, BUNDLE, current_commit
                    row["resultBundleSHA256"] = bundle_digest(BUNDLE)
                    row["sourceCommit"] = current_commit()
            except ValueError:
                if status == 0:
                    raise
    elif group in NETWORK_GROUPS | {"icloud", "icloud-cleanup"}:
        row["report"] = ".build/icloud-cross-device-smoke/report.json" if group.startswith("icloud") else ".build/release-network-smoke/report/release-network-smoke.json"
        row["summary"] = {"passed": False, "runID": run_id, "inputDigest": started_digest,
            "diagnostics": {"failures": ["当前运行缺少对应的 Smoke 报告"]}}
        if (ROOT / row["report"]).is_file():
            try: result = json.loads((ROOT / row["report"]).read_text())
            except (OSError, ValueError): result = {}
            if not isinstance(result, dict): result = {}
            if not producing_run_matches(result, started_digest, run_id):
                status = row["exitCode"] = status or 1
                print("Smoke 结果需要来自本次验证运行。", file=sys.stderr)
            else:
                row["summary"] = smoke_summary(group, result, full=scope == "full")
            if group in NETWORK_GROUPS: row["summary"]["inputDigest"] = started_digest
    else:
        row["summary"] = {"passed": status == 0, "kind": "build" if group.startswith("build-") else "restore" if group == "restore" else "audit"}
        if group == "audit":
            row["summary"].update(startedAt=os.getenv("BIT101_VALIDATION_STARTED_AT", ""), finishedAt=row["recordedAt"])
        if group == "restore" and status == 0:
            from validation_restore import summary as restore_summary
            try: row["summary"] = restore_summary(run_id, started_digest)
            except (OSError, ValueError, KeyError, TypeError): row["summary"]["passed"] = False
        if group == "build-archive" and status == 0:
            try:
                row["summary"] = archive_build_summary(ROOT / "build/DeviceInstall/BIT101-iOS.xcarchive/Products/Applications/BIT101-iOS.app")
                row["summary"]["passed"] = row["summary"]["archiveProvenance"] == {"inputDigest": started_digest, "runID": run_id}
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError): row["summary"]["passed"] = False
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
        scope == "full" and group in RELEASE_GROUPS | TEST_GROUPS | NETWORK_GROUPS and not complete_summary(group, row["summary"])):
        status = row["exitCode"] = 1
        print(f"{group} 的执行摘要需要确认完整通过。", file=sys.stderr)
    if os.getenv("GITHUB_RUN_ID"):
        row["ciRun"] = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        report.setdefault("groups", {})
        report["sourceDigest"] = digest
        report.pop("releaseCommit", None)
        report.pop("mergeCommit", None)
        previous = report["groups"].get(group, {})
        if scope == "selected" and group in TEST_GROUPS | NETWORK_GROUPS:
            full = previous if previous.get("scope") == "full" else previous.get("lastFullRun")
            if full: row["lastFullRun"] = full
        if group in {"modules", "all", "ui"}:
            from validation_coverage import regressions, policy_floors
            problems = regressions(row.get("summary", {}).get("coverage", {}),
                policy_floors(group, report.get("coveragePolicy", {}))) if scope == "full" else []
            if problems:
                status = row["exitCode"] = 1
                row["summary"]["passed"] = False
                row["summary"]["coverageRegressions"] = problems
                print("覆盖率退化：" + "；".join(problems), file=sys.stderr)
        report["groups"][group] = row
        if group in {"all", "ui"} and status == 0 and scope == "full":
            from validation_performance import extract_measurements
            try:
                row["performance"] = extract_measurements(row, group)
            except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
                status = row["exitCode"] = 1
                row["summary"]["passed"] = False
                row["summary"]["performanceCaptureError"] = str(error)
                print(f"性能指标采集失败：{error}", file=sys.stderr)
        report["testedCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        write_report(report)
    return status


def recover_community_smoke(script: Path, directory: Path, run_id: str, original_status: int) -> int:
    names = ("build.log", "console.log", "report/network-smoke-summary.txt", "report/release-network-smoke.json")
    original = {name: (directory / name).read_bytes() for name in names if (directory / name).exists()}
    status = subprocess.run([str(script), "community-cleanup"],
        env=dict(os.environ, BIT101_DEFER_APP_RESTORE="1", BIT101_NETWORK_SMOKE_CAPTURE="none",
                 BIT101_NETWORK_SMOKE_TERM="", BIT101_NETWORK_SMOKE_FIXTURES="")).returncode
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
            assert kwargs['env']['BIT101_NETWORK_SMOKE_CAPTURE'] == 'none'
            assert kwargs['env']['BIT101_NETWORK_SMOKE_TERM'] == kwargs['env']['BIT101_NETWORK_SMOKE_FIXTURES'] == ''
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
    from validation_evidence_tests import network_trace_fixture
    cleanup = network_trace_fixture({"runID": "fixture-run", "scope": "community-cleanup", "passed": True,
        "requiredProbes": ["BIT101 登录状态"], "executedProbes": ["BIT101 登录状态"]})
    write_row = {"exitCode": 0, "scope": "full", "summary": {"passed": True}}
    previous = {"sourceDigest": "source", "groups": {"community-writes": write_row}}
    cleanup_environment = {"host": {"system": "fixture"}, "developer": "/fixture", "xcode": {"version": "fixture"},
        "compiler": {"modified": 1, "size": 100, "sha256": "a" * 64}, "sdks": {"fixture": {"Version": "1"}}, "device": {
        "identifier": "fixture-phone", "systemVersion": "fixture-os", "systemBuild": "fixture-build"}}
    with patch(f"{__name__}.source_digest", return_value="source"), patch(f"{__name__}.network_inventory", return_value={"BIT101 登录状态"}), \
            patch(f"{__name__}.environment_context", return_value=cleanup_environment), \
            patch.dict(os.environ, BIT101_VALIDATION_RUN_ID="fixture-run"), \
            patch(f"{__name__}.report_lock", side_effect=nullcontext), patch(f"{__name__}.write_report") as saved, \
            patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", side_effect=[json.dumps(cleanup), json.dumps(previous)]), \
            patch.object(subprocess, "check_output", return_value="head"), redirect_stderr(StringIO()):
        result = record("community-cleanup", 0, "full", "source")
    if result or saved.call_args.args[0]["groups"]["community-writes"] != write_row:
        findings.append("社区恢复自测：成功清理沿独立范围记录并保留完整写入证据")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["digest", "record", "bind", "check", "check-group", "summary", "suites", "self-test", "manual", "verify-defaults", "runtime-suites", "conditions", "bind-merge", "check-merge", "baseline"])
    parser.add_argument("group", nargs="?", default="")
    parser.add_argument("status", nargs="?", type=int, default=0)
    parser.add_argument("--operation", default="", help="实际执行操作")
    parser.add_argument("--result", default="", help="实际观察结果")
    parser.add_argument("--outcome", choices=("passed", "failed"), help="人工验收结果状态")
    parser.add_argument("--observed-at", default="", help="实际观察的 ISO 8601 时间")
    parser.add_argument("--evidence", type=Path, help="本地验收附件")
    parser.add_argument("--recorded-environment", action="store_true", help="核对已绑定证据的记录环境和当前发布工具链")
    parser.add_argument("scope", nargs="?", default="full")
    args = parser.parse_args()
    if args.action in {'record', 'bind', 'check', 'check-group', 'summary', 'manual', 'bind-merge', 'check-merge', 'baseline'}:
        from validation_environment import ci_commit_findings
        if os.getenv('GITHUB_SHA') or os.getenv('GITHUB_ACTIONS') == 'true':
            commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
            if errors := ci_commit_findings(commit):
                print('\n'.join(errors), file=sys.stderr)
                return 1
    if args.action == "conditions":
        from validation_policy import workflow_conditions
        print(' '.join(workflow_conditions(args.group)))
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
            from validation_provenance import complete_group_row
            row = complete_group_row(report.get("groups", {}).get(args.group, {}))
        from validation_coverage import regressions, policy_floors
        coverage_matches = args.group not in {"modules", "all", "ui"} or not regressions(
            row.get("summary", {}).get("coverage", {}), policy_floors(args.group, report.get("coveragePolicy", {})))
        if row.get("exitCode") == 0 and row.get("scope") == "full" and row.get("runID") \
                and row.get("inputDigest") == source_digest(args.group) and evidence_current(args.group, row.get("summary", {})) \
                and complete_summary(args.group, row.get("summary", {})) and coverage_matches:
            return 0
        print(f"{args.group} 需要完整子流程结果并匹配当前验证输入。", file=sys.stderr)
        return 1
    if args.action == "manual":
        from validation_manual import MANUAL_DEVICE_CHECKS, capture as capture_manual, complete as manual_complete, distribution_matches_archive
        if args.group not in MANUAL_DEVICE_CHECKS or args.evidence is None:
            parser.error("真机专项需要有效检查项及操作、观察结果和本地附件。")
        try: observation = capture_manual(args.operation, args.result, args.evidence, args.group, args.outcome, args.observed_at)
        except (ValueError, OSError) as error: parser.error(str(error))
        if not complete_environment("manual-device", environment_context("manual-device")):
            parser.error("真机专项需要连接执行设备并读取完整系统身份。")
        digest = source_digest()
        with report_lock():
            report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
            if args.group == "distribution-signing" and not distribution_matches_archive(observation, report.get("groups", {}).get("build-archive", {})):
                parser.error("分发产物需要来自当前已验证的归档，请执行 archive-signed 并导出该归档。")
            report.setdefault("groups", {})
            report["sourceDigest"] = digest
            report.pop("releaseCommit", None)
            report.pop("mergeCommit", None)
            previous = report["groups"].get("manual-device", {})
            input_digest = source_digest("manual-device")
            summary = previous.get("summary", {"checks": {}}) if previous.get("inputDigest") == input_digest else {"checks": {}}
            summary["checks"][args.group] = observation
            summary["passed"] = manual_complete(summary["checks"])
            summary["startedAt"] = min(row["capturedAt"] for row in summary["checks"].values())
            summary["finishedAt"] = max(row["capturedAt"] for row in summary["checks"].values())
            report["groups"]["manual-device"] = {"exitCode": 0 if summary["passed"] else 2, "scope": "full", "summary": summary,
                "inputDigest": input_digest, "environment": environment_context("manual-device")}
            write_report(report)
        return 0
    if args.action == "digest":
        print(source_digest(args.group))
        return 0
    if args.action == "suites":
        if args.group not in TEST_AREA_SUITES:
            parser.error("测试领域：schedule、infrastructure、login、extensions")
        print("\n".join(sorted({test.split("/", 1)[0] for test in test_inventory(args.group)})))
        return 0
    if args.action == "self-test":
        from validation_evidence_tests import run_self_test
        return run_self_test(sys.modules[__name__])
    if args.action == "record":
        return record(args.group, args.status, args.scope, os.getenv("BIT101_VALIDATION_SOURCE_DIGEST", ""))
    with report_lock():
        return inspect_report(args)


def inspect_report(args) -> int:
    report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
    if args.action == "baseline":
        if report.get("coverageBaseCommit") != args.group:
            print("覆盖率基准需要绑定合并目标分支的当前提交。", file=sys.stderr)
            return 1
        if set(report.get("coveragePolicy", {})) != {"modules", "all"}:
            print("覆盖率基准需要 macOS 与 iOS 两组阈值。", file=sys.stderr)
            return 1
        for group in ("modules", "all"):
            floors = report.get("coveragePolicy", {}).get(group)
            if not isinstance(floors, dict) or not floors or any(not isinstance(name, str) or type(value) is not int
                    or not 0 <= value <= 100 for name, value in floors.items()):
                print("覆盖率基准需要目标提交登记的有效阈值。", file=sys.stderr)
                return 1
        write_report(report)
        return 0
    if args.action in {"bind-merge", "check-merge"}:
        from validation_merge import findings as merge_findings
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        candidate = dict(report, mergeCommit=commit) if args.action == "bind-merge" else report
        errors = merge_findings(candidate, digest=source_digest, complete=complete_summary, commit=commit,
            recorded_environment=args.recorded_environment)
        if args.action == "bind-merge" and subprocess.check_output(["git", "status", "--porcelain=v1"], cwd=ROOT).strip():
            errors.append("合并验证证据需要对应已完整提交的仓库内容。")
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        if args.action == "bind-merge":
            report["mergeCommit"] = commit
            write_report(report)
        return 0
    if args.action in {"bind", "check"}:
        errors = release_findings(report, source_digest(), recorded_environment=args.recorded_environment)
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
        environment = row.get("environment", {}) if args.recorded_environment else None
        current = row.get("inputDigest") == source_digest(name, environment=environment) and evidence_current(name, result)
        label = "待复验" if not current else "通过" if passed else "待处理"
        rows.append(f"| {name} | {row.get('scope', '?')} | {label} | {count} | {len(result.get('coverage', {}))} |")
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
