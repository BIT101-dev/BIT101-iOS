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
from validation_policy import TEST_GROUPS, RELEASE_GROUPS, DEFAULT_VERIFY_GROUPS, FORMAL_RUNTIME_SUITES, MODULE_COVERAGE_FLOORS, IOS_MODULE_COVERAGE_FLOORS, SCHOOL_SMS_PROBES
from validation_test_areas import TEST_AREA_SUITES, test_selectors, test_inventory, test_case_inventory
from validation_compilation import compilation_condition, active_swift_source
from validate_distribution import archive_build_summary, valid_archive_provenance, valid_executable_uuids, distribution_contracts
from validation_environment import environment_context, complete_environment, toolchain_identity, exchange_identity, native_destinations_complete
from validation_provenance import report_lock, write_report, input_identity, normalized_test_id, LIVE_GROUPS, NETWORK_GROUPS, evidence_current, producing_run_matches, sampling_evidence_current, utc_now
from validation_performance import result_bundle_findings

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
ICLOUD_DOMAINS = {"score-kvs", "schedule-cloudkit"}


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


def simulator_test_selection(mode: str, scope: str, selections: list[str], shard: str | None) -> tuple[list[str], list[str]]:
    from validation_coverage import shard_inventory
    if scope in {'full', 'shard'}:
        tests = shard_inventory(mode, *map(int, shard.split('/'))) if shard else sorted(test_inventory(mode))
        selections = [normalized_test_id(test) for test in tests]
    return sorted(selected_test_inventory(mode, selections)), xcode_test_selections(mode, selections)


def selected_test_summary_complete(summary: dict, expected: list[str], *, group: str = 'all', simulator: bool = False) -> bool:
    executed = {normalized_test_id(test) for test in summary.get("executedTests", [])}
    return bool(expected) and summary.get("passed") is True and successful_test_counts(summary) \
        and summary.get("totalTests", 0) >= len(expected) and executed == set(expected) \
        and (module_cases_complete(summary) if group == 'modules' else native_cases_complete(summary, group, simulator=simulator))


def native_case_summary(tree: dict, group: str, *, simulator: bool = False, device_identifier: str = '') -> dict:
    counts, identifiers = {}, {}
    passed = True
    def visit(value):
        nonlocal passed
        if isinstance(value, dict):
            if value.get('nodeType') == 'Test Case':
                name = normalized_test_id(value['nodeIdentifier'])
                instances = [child for child in value.get('children', []) if child.get('nodeType') == 'Arguments'] or [value]
                identities = [child.get('nodeIdentifierURL') for child in instances]
                passed &= value.get('result') == 'Passed' and all(child.get('result') == 'Passed' for child in instances) \
                    and name not in counts and all(isinstance(identity, str) and identity for identity in identities) \
                    and len(set(identities)) == len(identities)
                counts[name], identifiers[name] = len(instances), identities
            for child in value.values(): visit(child)
        elif isinstance(value, list):
            for child in value: visit(child)
    visit(tree)
    inventory = test_case_inventory('all' if group in TEST_AREA_SUITES else group)
    destinations = [{'platform': row.get('platform'), 'deviceIdentifier': row.get('deviceId')}
        for row in tree.get('devices', []) if isinstance(row, dict)]
    passed &= native_destinations_complete(destinations, group, simulator=simulator, expected_device=device_identifier)
    return {'total': sum(counts.values()), 'byTest': counts,
        'expectedByTest': {name: inventory.get(name) for name in counts}, 'identifiersByTest': identifiers,
        'destinations': destinations, 'passed': bool(passed)}


def native_cases_complete(summary: dict, group: str, *, simulator: bool = False) -> bool:
    cases = summary.get('testCases', {})
    if not module_cases_complete(summary) or cases.get('passed') is not True: return False
    if not native_destinations_complete(cases.get('destinations'), group, simulator=simulator): return False
    expected = test_case_inventory('all' if group in TEST_AREA_SUITES else group)
    counts = {normalized_test_id(name): count for name, count in cases['byTest'].items()}
    identities = cases.get('identifiersByTest', {})
    return counts == {name: expected.get(name) for name in counts} and set(identities) == set(counts) \
        and all(isinstance(values, list) and len(values) == counts[name]
            and all(native_case_identity_matches(value, name, parameterized=counts[name] > 1,
                target='BIT101-iOSUITests' if group == 'ui' else 'BIT101-iOSTests') for value in values) and len(set(values)) == len(values)
            for name, values in identities.items())


def native_case_identity_matches(value: object, name: str, *, parameterized: bool = False, target: str = 'BIT101-iOSTests') -> bool:
    from urllib.parse import parse_qs, unquote, urlsplit
    if not isinstance(value, str): return False
    try: parsed = urlsplit(value)
    except ValueError: return False
    if parsed.scheme != 'test' or parsed.netloc != 'com.apple.xcode': return False
    if parameterized:
        arguments = parse_qs(parsed.query).get('args', [])
        if len(arguments) != 1 or re.fullmatch(r'(?:[0-9a-f]{2})+', arguments[0]) is None: return False
    parts = unquote(parsed.path).strip('/').split('/')
    if len(parts) < 4 or parts[:2] != ['BIT101-iOS', target]: return False
    parts[2] = parts[2].rsplit('.', 1)[-1]
    path = '/'.join(parts[2:])
    return path == name or path.startswith((name + '(', name + '/'))


@cache
def school_sms_inventory() -> set[str]:
    paths = [ROOT / "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift", ROOT / "Modules/ScheduleInfrastructure/Sources/ScheduleServiceLexue.swift"]
    return {purpose for facts in swift_syntax_index_sources({str(path): path.read_text() for path in paths}).values()
        for call in facts["invocations"] for purpose in re.findall(r'\bpurpose:\s*"([^"\\]+)"', call["value"])}


@cache
def network_inventory(scope: str = "all") -> set[str]:
    scope = {"community-writes": "communityWrites", "community-cleanup": "communityCleanup"}.get(scope, scope)
    path = ROOT / 'BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift'
    models = swift_syntax_index_sources({str(path): path.read_text()})[str(path)]
    probe_ids = {case['name']: json.loads(case['rawValue']) for case in models['enumCases']
        if case['scope'] == ['NetworkSmokeProbe']}
    factories = {function['name']: function for function in models['functionRanges']
        if function['scope'] == ['NetworkSmokeProbe']}
    def probe_references(start, end):
        result = set()
        for member in models['members']:
            if not start <= member['start'] < end: continue
            name = member['value'].rsplit('.', 1)[-1]
            if name in probe_ids: result.add(probe_ids[name])
            elif name in factories:
                function = factories[name]
                result |= probe_references(function['start'], function['end'])
        return result
    areas = {}
    for branch in models['controlFlow']:
        if branch['scope'] != ['NetworkSmokeArea'] or not branch['value'].startswith('case .'): continue
        header, body = branch['value'].split(':', 1)
        name = header.removeprefix('case .')
        areas[name] = probe_references(branch['start'] + len((header + ':').encode()), branch['start'] + len(branch['value'].encode()))
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
        if kind in {'runStarted', 'runEnded'}:
            if kind == 'runStarted' and runs['runStarted'] != runs['runEnded'] \
                    or kind == 'runEnded' and (runs['runStarted'] != runs['runEnded'] + 1 or started != ended):
                raise ValueError('测试运行事件需要完整且有序的起止配对。')
            runs[kind] += 1
        elif kind in {'testSkipped', 'testCancelled', 'testCaseCancelled'}:
            affected = {name for name in functions if name == identifier or name.startswith(identifier + '/')}
            if not affected: raise ValueError('跳过或取消事件需要对应测试函数。')
            skipped.update(affected)
        elif kind == 'issueRecorded':
            issue = event.get('issue', {})
            if issue.get('isFailure') is False: continue
            affected = {name for name in functions if name == identifier or name.startswith(identifier + '/')}
            if not affected: raise ValueError('测试运行记录了函数范围外的失败。')
            failed.update(affected)
        elif identifier in functions and kind in {'testStarted', 'testEnded', 'testCaseStarted', 'testCaseEnded'}:
            if runs['runStarted'] != runs['runEnded'] + 1:
                raise ValueError('函数事件需要归属正在执行的测试运行。')
            if kind == 'testStarted':
                if identifier in started: raise ValueError('函数开始事件需要唯一记录。')
                started.add(identifier)
            elif kind == 'testEnded':
                if identifier not in started or identifier in ended: raise ValueError('函数结束事件需要对应的唯一开始记录。')
                ended.add(identifier)
            elif kind in {'testCaseStarted', 'testCaseEnded'}:
                if identifier not in started or identifier in ended: raise ValueError('实例事件需要归属正在执行的测试函数。')
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
             or (0 if functions[name].get('isParameterized') else 1) for name in sorted(ended)}
    expected = {}
    for name in sorted(ended):
        if not functions[name].get('isParameterized'):
            if cases[name] != 1: raise ValueError('普通函数需要对应单个测试实例。')
            expected[name] = 1
            continue
        declared = functions[name].get('_testCases')
        identities = [case.get('id') for case in declared if isinstance(case, dict)] if isinstance(declared, list) else []
        if not identities or len(identities) != len(declared) or any(not isinstance(identifier, str) or not identifier for identifier in identities) \
                or len(set(identities)) != len(identities) \
                or set(identities) != {identifier for (function, identifier) in case_ended if function == name}:
            raise ValueError('参数化测试需要执行 Swift Testing 清单中的全部实例。')
        expected[name] = len(identities)
    if any(count == 0 for count in cases.values()):
        raise ValueError('参数化测试需要实际执行参数实例。')
    return {'totalTests': len(attempted), 'passedTests': len(ended - failed - skipped),
            'failedTests': len(failed), 'skippedTests': len(skipped - failed), 'executedTests': sorted(ended),
            'testCases': {'total': sum(cases.values()), 'byTest': cases, 'expectedByTest': expected}}


def module_cases_complete(summary: dict) -> bool:
    cases = summary.get('testCases')
    if not isinstance(cases, dict): return False
    counts = cases.get('byTest')
    return isinstance(counts, dict) and bool(counts) and counts == cases.get('expectedByTest') \
        and all(type(count) is int and count > 0 for count in counts.values()) \
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
                "probeLabels": value.get("probeLabels", {}),
                **{name: len(value.get(name, [])) for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")}}
    if group == "icloud-cleanup":
        cleanup = value.get("cleanup", {})
        mac_cleanup = value.get("macCleanup", {})
        return {"passed": value.get("cleanupExitCode") == 0 and cleanup.get("exitCode") == 0
                and icloud_stage_complete(cleanup, 'testCleanup') and mac_cleanup.get("exitCode") == 0
                and icloud_stage_complete(mac_cleanup, 'testMacCleanup')
                and cleanup.get('runID') == mac_cleanup.get('runID') == value.get('runID'),
                "cleanup": dict(cleanup, kvsDeletion="requested", cloudKitDeletion="server-confirmed"),
                "macCleanup": dict(mac_cleanup, kvsDeletion="requested", cloudKitDeletion="server-confirmed"),
                "runID": value.get("runID"), "startedAt": value.get("cleanupStartedAt"), "finishedAt": value.get("cleanupFinishedAt")}
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
    cleanup_evidence = dict(cleanup, kind="standalone", kvsDeletion="requested") if cleanup is not None else dict(
        next((row for row in stages if row["stage"] == "testPhoneRoundTrip"), {}), kind="round-trip", kvsDeletion="peer-observed")
    mac_cleanup_evidence = dict(mac_cleanup, kind="standalone", kvsDeletion="requested") if mac_cleanup is not None else dict(
        next((row for row in stages if row["stage"] == "testMacReceiveAndRestore"), {}), kind="round-trip", kvsDeletion="peer-observed")
    return {"passed": passed, "stages": stages, "validatedDomains": value.get("validatedDomains", []),
            "cloudKitEnvironment": value.get("cloudKitEnvironment"), "cleanup": cleanup_evidence, "macCleanup": mac_cleanup_evidence,
            "startedAt": value.get("startedAt"), "finishedAt": value.get("finishedAt"), "runID": value.get("runID")}


def successful_test_counts(summary: dict) -> bool:
    total = summary.get("totalTests", summary.get("totalTestCount", 0))
    return all(type(value) is int for value in (total, summary.get("passedTests"), summary.get("failedTests"), summary.get("skippedTests"))) \
        and total > 0 and total == summary.get("passedTests") and summary.get("failedTests") == summary.get("skippedTests") == 0


def coverage_complete(group: str, summary: dict) -> bool:
    from validation_coverage import policy_floors, COVERAGE_GROUPS
    floors = policy_floors(group, {}) if group in COVERAGE_GROUPS else {}
    if group == "modules" and {path.name for path in (ROOT / "Modules").iterdir() if path.is_dir()} \
            - {"ScheduleActivityContracts"} != set(floors):
        return False
    if group == "all" and {path.name for path in (ROOT / "Modules").iterdir() if path.is_dir()} != set(IOS_MODULE_COVERAGE_FLOORS):
        return False
    coverage = summary.get("coverage", {})
    if group == 'catalyst-release-runtime':
        for name in ('BIT101-iOS.app', 'Catalyst/TransportCore', 'Catalyst/StorageCore'):
            row = coverage.get(name, {})
            covered, executable = row.get('coveredLines'), row.get('executableLines')
            if type(covered) is not int or type(executable) is not int or not 0 < covered <= executable: return False
    for name, floor in floors.items():
        row = coverage.get(name, {})
        covered, executable = row.get("coveredLines"), row.get("executableLines")
        if type(covered) is not int or type(executable) is not int \
                or not 0 < covered <= executable or covered * 100 < floor * executable:
            return False
    return True


def native_source_coverage(products: Path, profile: Path, *, catalyst: bool = False, line_details: bool = False, include_app: bool = False) -> dict:
    import plistlib
    app = products / "BIT101-iOS.app"
    contents = app / 'Contents' if catalyst else app
    with (contents / "Info.plist").open("rb") as stream:
        executable_name = plistlib.load(stream)["CFBundleExecutable"]
    executable = contents / 'MacOS' / executable_name if catalyst else app / executable_name
    command = ["xcrun", "llvm-cov", "export", str(executable), "-instr-profile", str(profile)]
    for binary in sorted(executable.parent.glob('*.debug.dylib')):
        command += ['-object', str(binary)]
    for framework in sorted((contents / "Frameworks").glob("*.framework")):
        with (framework / 'Resources/Info.plist' if catalyst else framework / 'Info.plist').open("rb") as stream:
            binary = framework / plistlib.load(stream)["CFBundleExecutable"]
        command += ["-object", str(binary)]
    if line_details: command.append('-format=lcov')
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
            if (path.is_relative_to(ROOT / "Modules") and "/Sources/" in str(path)) or (catalyst or include_app) and path.is_relative_to(ROOT / 'BIT101-iOS'):
                files[path] = file["summary"]["lines"]
    modules = {}
    for path, lines in files.items():
        name = path.relative_to(ROOT / "Modules").parts[0] if path.is_relative_to(ROOT / 'Modules') else 'BIT101-iOS.app'
        hit, count = modules.get(name, (0, 0))
        modules[name] = hit + lines["covered"], count + lines["count"]
    if not modules:
        raise ValueError("原生覆盖率需要包含生产源码。")
    return modules


def complete_summary(group: str, summary: dict) -> bool:
    if summary.get("passed") is not True:
        return False
    if group in TEST_GROUPS:
        executed = {normalized_test_id(identifier) for identifier in summary.get("executedTests", [])}
        complete = successful_test_counts(summary) and coverage_complete(group, summary) and test_inventory(group) <= executed \
            and summary.get("totalTests", 0) >= len(test_inventory(group))
        if group == 'modules': complete = complete and module_cases_complete(summary)
        else: complete = complete and native_cases_complete(summary, group)
        if group == "ui":
            from ui_inventory import has_action_evidence
            inventory = summary.get("uiInventory")
            complete = complete and has_action_evidence(inventory)
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
        return all(icloud_stage_complete(summary.get(key, {}), stage)
            and summary[key].get("runID") == summary.get("runID")
            for key, stage in (("cleanup", "testCleanup"), ("macCleanup", "testMacCleanup")))
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


def group_complete(report: dict, group: str, *, recorded_environment: bool = False) -> bool:
    from validation_provenance import complete_group_row, group_evidence_current
    from validation_coverage import policy_findings
    row = complete_group_row(report.get("groups", {}).get(group, {}))
    inputs = input_identity(group, environment=row.get("environment", {})) if recorded_environment else input_identity(group)
    return row.get("exitCode") == 0 and row.get("scope") == "full" and bool(row.get("runID")) \
        and row.get("inputDigest") == inputs and group_evidence_current(group, row) \
        and complete_environment(group, row.get("environment", {})) \
        and complete_summary(group, row.get("summary", {})) \
        and not policy_findings(report, group) \
        and (group not in {"all", "ui"} or not result_bundle_findings(report, groups=(group,), recorded_environment=recorded_environment))


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
        inputs = input_identity(name, environment=row.get("environment", {})) if recorded_environment else input_identity(name)
        if row.get("inputDigest") != inputs:
            errors.append(f"{name} 的验证输入已变化，请重新执行该组。")
        if not complete_environment(name, row.get("environment", {})):
            errors.append(f"{name} 需要保留执行环境及设备系统身份。")
        if not group_evidence_current(name, row):
            errors.append(f"{name} 的实际验收需要在发布检查前 24 小时内完成，请重新验收。")
        if name == "restore" and any(row.get("summary", {}).get(key) != row.get(key) for key in ("runID", "inputDigest")):
            errors.append("restore 的就绪信号需要对应所属运行与输入摘要。")
        if row.get("exitCode") != 0 or row.get("scope") != "full" or not complete_summary(name, row.get("summary", {})):
            errors.append(f"{name} 需要完整执行并通过，并保留结果摘要。")
        if name == 'audit' and row.get('summary', {}).get('releaseVersionChecked') is not True:
            errors.append('发布验收需要带 App Store 版本核对的静态审计。')
    if recorded_environment and toolchain_identity(report.get("groups", {}).get("build-archive", {}).get("environment", {})) \
            != toolchain_identity(environment_context("build-archive")):
        errors.append("发布编译工具链及 SDK 与已绑定证据存在差异，请重新验收。")
    groups = report.get("groups", {})
    checks = groups.get("manual-device", {}).get("summary", {}).get("checks", {})
    observation = checks.get("distribution-signing", {})
    from validation_manual import distribution_matches_archive, baseline_matches_distribution, catalyst_matches_runtime
    if not distribution_matches_archive(observation, groups.get("build-archive", {})):
        errors.append("最终分发签名需要对应已验证归档的源码摘要、运行标识与可执行文件 UUID。")
    if not baseline_matches_distribution(checks.get("minimum-platforms", {}), observation):
        errors.append("最低系统安装验收需要对应最终分发包的版本、build、摘要与可执行文件 UUID。")
    if not catalyst_matches_runtime(checks.get('catalyst-desktop', {}), groups.get('catalyst-release-runtime', {})):
        errors.append('Catalyst 桌面专项需要对应正式运行测试通过的应用摘要与可执行文件 UUID。')
    return errors


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
    row = {"exitCode": status, "scope": scope, "inputDigest": input_digest, "runID": run_id,
           "recordedAt": utc_now().isoformat(), "environment": environment_context(group)}
    from validation_provenance import workflow_elapsed_seconds
    if (seconds := workflow_elapsed_seconds()) is not None:
        row['durationSeconds'] = seconds
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
                    from validation_performance import bundle_identity, BUNDLE, current_commit
                    row["resultBundleIdentity"] = bundle_identity(BUNDLE)
                    row["sourceCommit"] = current_commit()
            except ValueError:
                if status == 0:
                    raise
        if group == 'catalyst-release-runtime' and status == 0:
            from validate_distribution import catalyst_application_identity
            try:
                row['application'] = catalyst_application_identity(ROOT / '.build/extended-automation/Build/Products/Release-maccatalyst/BIT101-iOS.app')
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
                row['summary']['passed'] = False
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
            row["summary"].update(startedAt=os.getenv("BIT101_VALIDATION_STARTED_AT", ""), finishedAt=row["recordedAt"],
                releaseVersionChecked=status == 0 and os.getenv('BIT101_RELEASE_CHECK') == 'true')
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
        selected_complete = selected_test_summary_complete(row.get("summary", {}), expected, group=group)
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
            if full and (group in TEST_GROUPS or status == 0): row["lastFullRun"] = full
        from validation_coverage import COVERAGE_GROUPS
        if group in COVERAGE_GROUPS:
            from validation_coverage import regressions, policy_floors
            problems = regressions(row.get("summary", {}).get("coverage", {}),
                policy_floors(group, report.get("coveragePolicy", {}))) if scope == "full" else []
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
            except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
                status = row["exitCode"] = 1
                row["summary"]["passed"] = False
                row["summary"]["performanceCaptureError"] = str(error)
                print(f"性能指标采集失败：{error}", file=sys.stderr)
        if group in TEST_GROUPS | NETWORK_GROUPS and status:
            from validation_provenance import invalidate_failed_evidence
            requested = set(row.get('summary', {}).get('requiredProbes', [])) \
                if group in NETWORK_GROUPS else set(row.get('expectedTests', [])) or test_inventory(group)
            invalidated = invalidate_failed_evidence(report, group, requested)
            if invalidated: print('定向回归失败，关联证据进入重新验收：' + '、'.join(invalidated), file=sys.stderr)
        report["testedCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        write_report(report)
    return status


def recover_community_smoke(script: Path, directory: Path, run_id: str, original_status: int) -> int:
    names = ("build.log", "console.log", "report/network-smoke-summary.txt", "report/release-network-smoke.json")
    original = {name: (directory / name).read_bytes() for name in names if (directory / name).exists()}
    status = subprocess.run([str(script), "community-cleanup"],
        env=dict(os.environ, BIT101_NETWORK_SMOKE_CAPTURE="none",
                 BIT101_NETWORK_SMOKE_TERM="", BIT101_NETWORK_SMOKE_FIXTURES="")).returncode
    report_name = names[-1]
    child_path = directory / report_name
    try:
        cleanup = json.loads(child_path.read_bytes()) if child_path.exists() else {}
    except (OSError, ValueError):
        cleanup = {"passed": False, "failures": ["清理报告读取失败；诊断见控制台记录"]}
    if cleanup.get("scope") != "community-cleanup" or cleanup.get("runID") in {None, "", run_id}:
        cleanup = {"scope": "community-cleanup", "passed": False, "failures": ["清理在产生所属报告前结束；原写入证据已保留"]}
        if status == 0: status = 1
    cleanup["exitStatus"] = status
    if status and (directory / names[0]).exists() and (directory / names[0]).read_bytes() != original.get(names[0]):
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
        if name == "console.log" and path.exists() and path.read_bytes() != value:
            value += b"\n[community-cleanup]\n" + path.read_bytes()
        path.write_bytes(value)
    child_path.write_text(json.dumps(parent, ensure_ascii=False, indent=2) + "\n")
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["digest", "record", "bind", "check", "check-group", "summary", "suites", "self-test", "manual", "manual-schema", "verify-defaults", "runtime-suites", "conditions", "bind-merge", "check-merge", "baseline"])
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
    if args.action == 'manual-schema':
        from validation_manual import manual_structure
        try: print(json.dumps(manual_structure(args.group), ensure_ascii=False, indent=2))
        except ValueError as error: parser.error(str(error))
        return 0
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
        if group_complete(report, args.group):
            return 0
        print(f"{args.group} 需要完整子流程结果并匹配当前验证输入。", file=sys.stderr)
        return 1
    if args.action == "manual":
        from uuid import uuid4
        from validation_manual import MANUAL_DEVICE_CHECKS, capture as capture_manual, complete as manual_complete, distribution_matches_archive
        if args.group not in MANUAL_DEVICE_CHECKS or args.evidence is None:
            parser.error("真机专项需要有效检查项及操作、观察结果和本地附件。")
        try: observation = capture_manual(args.operation, args.result, args.evidence, args.group, args.outcome, args.observed_at)
        except (ValueError, OSError) as error: parser.error(str(error))
        if not complete_environment("manual-device", environment_context("manual-device")):
            parser.error("真机专项需要连接执行设备并读取完整系统身份。")
        digest = input_identity()
        with report_lock():
            report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
            if args.group == "distribution-signing" and not distribution_matches_archive(observation, report.get("groups", {}).get("build-archive", {})):
                parser.error("分发产物需要来自当前已验证的归档，请执行 archive-signed 并导出该归档。")
            report.setdefault("groups", {})
            report["sourceDigest"] = digest
            report.pop("releaseCommit", None)
            report.pop("mergeCommit", None)
            previous = report["groups"].get("manual-device", {})
            input_digest = input_identity("manual-device")
            summary = previous.get("summary", {"checks": {}}) if previous.get("inputDigest") == input_digest else {"checks": {}}
            summary["checks"][args.group] = observation
            summary["passed"] = manual_complete(summary["checks"])
            summary["startedAt"] = min(row["capturedAt"] for row in summary["checks"].values())
            summary["finishedAt"] = max(row["capturedAt"] for row in summary["checks"].values())
            report["groups"]["manual-device"] = {"exitCode": 0 if summary["passed"] else 2, "scope": "full", "summary": summary,
                "inputDigest": input_digest, "runID": str(uuid4()), "environment": environment_context("manual-device")}
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
            return subprocess.call([sys.executable, '-B', str(ROOT / 'Scripts/validation_evidence_tests.py')])
    if args.action == "record":
        return record(args.group, args.status, args.scope, os.getenv("BIT101_VALIDATION_INPUT_IDENTITY", ""))
    with report_lock():
        return inspect_report(args)


def inspect_report(args) -> int:
    report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
    if args.action == "baseline":
        if args.group == '':
            if report.get('coverageBaseCommit') == '' and report.get('coveragePolicy') == {}: return 0
            print('当前版本覆盖率验收需要清理目标提交基准。', file=sys.stderr)
            return 1
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
        if 'BIT101-iOS.app' not in report['coveragePolicy']['all']:
            print('覆盖率基准需要目标提交的 App 阈值。', file=sys.stderr)
            return 1
        write_report(report)
        return 0
    if args.action in {"bind-merge", "check-merge"}:
        from validation_merge import findings as merge_findings
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        candidate = dict(report, mergeCommit=commit) if args.action == "bind-merge" else report
        errors = merge_findings(candidate, digest=input_identity, complete=complete_summary, commit=commit,
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
        errors = release_findings(report, input_identity(), recorded_environment=args.recorded_environment)
        if not errors:
            from validation_provenance import release_worker_findings
            errors.extend(release_worker_findings(report['groups']['network']['summary']))
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
    rows = ["| 验证组 | 范围 | 结果 | 用例 / 探针 | 覆盖率模块 | 耗时 / 秒 |", "| --- | --- | --- | ---: | ---: | ---: |"]
    from validation_coverage import policy_findings
    from validation_provenance import group_evidence_current
    for name, row in sorted(report.get("groups", {}).items()):
        result = row.get("summary", {})
        passed = row.get("exitCode") == 0 and result.get("passed") is True and not policy_findings(report, name)
        if row.get("scope") == "full":
            passed = group_complete(report, name, recorded_environment=args.recorded_environment)
        elif name in TEST_GROUPS:
            passed = passed and selected_test_summary_complete(result, row.get("expectedTests", []), group=name)
        count = result.get("passedTests", result.get("executedProbes", sum(stage["passedTests"] for stage in result.get("stages", []))))
        environment = row.get("environment", {}) if args.recorded_environment else None
        current = row.get("inputDigest") == input_identity(name, environment=environment) and group_evidence_current(name, row)
        label = "待复验" if not current else ("定向通过" if row.get("scope") == "selected" else "通过") if passed else "待处理"
        duration = row.get('durationSeconds', '?')
        rows.append(f"| {name} | {row.get('scope', '?')} | {label} | {count} | {len(result.get('coverage', {}))} | {duration} |")
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
