"""Exercise workflow ownership and bounded network evidence using memory IO substitutes."""
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from datetime import timedelta
from io import BytesIO, StringIO
import ast
import json
import re
import subprocess
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch
from validation_provenance import LIVE_GROUPS, evidence_current, sampling_evidence_current, utc_now


def test_identity_self_test() -> None:
    import validation_test_areas as subject
    root = subject.ROOT / 'ModuleTests'
    first, second = root / 'Transport/ClientCoreTests.swift', root / 'Sync/ScheduleSyncTests.swift'
    original_read, original_rglob = Path.read_text, Path.rglob
    cases = [
        ({first: 'import Testing\nstruct Probe { @Test func check(value: Int) {}\n@Test func check(number: Int) {} }'}, True),
        ({first: 'import Testing\nstruct Probe { @Test func check(value: Int) {} }',
          second: 'import Testing\nstruct Probe { @Test func check(number: Int) {} }'}, True),
        ({first: 'import Testing\nstruct Probe { @Test func checkValue(value: Int) {}\n@Test func checkNumber(number: Int) {} }'}, False),
        ({first: 'import Testing\nstruct First { @Test func check(value: Int) {} }',
          second: 'import Testing\nstruct Second { @Test func check(number: Int) {} }'}, False),
    ]
    for sources, ambiguous in cases:
        def read(path, *args, **kwargs):
            return sources[path] if path in sources else original_read(path, *args, **kwargs)
        with patch.object(Path, 'rglob', lambda path, pattern: iter(sources) if path == root else original_rglob(path, pattern)), \
                patch.object(Path, 'read_text', read):
            try: inventory = subject.test_selectors.__wrapped__('modules')
            except ValueError as error:
                assert ambiguous and '测试库存需要唯一 Suite/method' in str(error)
                assert str(first) in str(error) and 'check(value:)' in str(error) and 'check(number:)' in str(error)
            else:
                assert not ambiguous and len(inventory) == 2
    facts = subject.swift_syntax_index_sources({str(first): 'import Testing\nstruct Probe { @Test func check(value: Int) {} }'})
    import copy
    other = copy.deepcopy(facts[str(first)])
    facts[str(first)]['tests'][0]['value'] = 'FirstTests.Probe/check'
    other['tests'][0]['value'] = 'SecondTests.Probe/check'
    facts[str(second)] = other
    with patch.object(subject, 'swift_syntax_index_sources', return_value=facts):
        try: subject.test_selectors.__wrapped__('modules')
        except ValueError as error: assert 'Probe/check' in str(error)
        else: raise AssertionError('模块前缀归一化后的歧义需要进入库存失败')


def probe_identity_self_test(subject) -> None:
    path = subject.ROOT / 'BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift'
    original_read = Path.read_text
    original = path.read_text()
    baseline = subject.network_inventory()
    assert 'gallery.newest' in baseline and '话廊最新列表' not in baseline
    with patch.object(Path, 'read_text', lambda target, *args, **kwargs:
            original.replace('话廊最新列表', '新版显示名称') if target == path else original_read(target, *args, **kwargs)):
        subject.network_inventory.cache_clear()
        assert subject.network_inventory() == baseline
    subject.network_inventory.cache_clear()


def worker_deployment_fixture(scope: str = 'all') -> dict:
    import uuid
    from validation_provenance import WORKER_FOLDERS, worker_source_digest
    return {folder: {'deploymentID': str(uuid.uuid5(uuid.NAMESPACE_URL, folder)),
        'sourceDigest': worker_source_digest(folder), 'versions': [{
            'versionID': str(uuid.uuid5(uuid.NAMESPACE_DNS, folder)), 'percentage': 100,
            'sourceDigest': worker_source_digest(folder)}]}
        for folder in WORKER_FOLDERS if scope in {'all', 'bit101'}}


def worker_deployment_self_test() -> None:
    import copy
    import uuid
    import validation_provenance as subject
    deploy_command = json.loads((subject.WRANGLER_ROOT / 'package.json').read_text())['scripts']['deploy']
    dispatch = subprocess.run(['zsh', '-c', 'python3() { print -rl -- "$@"; }\n' + deploy_command],
        cwd=subject.WRANGLER_ROOT, capture_output=True, text=True)
    assert dispatch.returncode == 0 and dispatch.stdout.splitlines() == [
        '../../Scripts/validation_provenance.py', 'deploy-worker', 'EmergencyUpdateWorker']
    proof = worker_deployment_fixture()
    assert subject.worker_deployments_complete('all', proof)
    assert subject.worker_deployments_complete('school', {})
    assert not subject.worker_deployments_complete('all', {})
    folder = subject.WORKER_FOLDERS[0]
    original_read = Path.read_bytes
    source = subject.ROOT / 'Cloudflare' / folder / 'worker.js'
    with patch.object(Path, 'read_bytes', lambda path: original_read(path) + b'\nchanged\n' if path == source else original_read(path)):
        assert not subject.worker_deployments_complete('all', proof)
    icon = subject.ROOT / 'BIT101-iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png'
    with patch.object(Path, 'read_bytes', lambda path: original_read(path) + b'changed' if path == icon else original_read(path)):
        assert not subject.worker_deployments_complete('all', proof)
    for field, value in [('deploymentID', 'invalid'), ('sourceDigest', 'b' * 64), ('versions', [])]:
        changed = copy.deepcopy(proof)
        changed[folder][field] = value
        assert not subject.worker_deployments_complete('all', changed), field
    for field, value in [('versionID', 'invalid'), ('percentage', True), ('percentage', 99),
            ('percentage', float('nan')), ('sourceDigest', 'b' * 64)]:
        changed = copy.deepcopy(proof)
        changed[folder]['versions'][0][field] = value
        assert not subject.worker_deployments_complete('all', changed), field
    gradual = copy.deepcopy(proof)
    first = gradual[folder]['versions'][0]
    first['percentage'] = 40
    gradual[folder]['versions'].append(dict(first, versionID=str(uuid.uuid4()), percentage=60))
    assert subject.worker_deployments_complete('all', gradual)
    gradual[folder]['versions'][1]['sourceDigest'] = 'b' * 64
    assert not subject.worker_deployments_complete('all', gradual)
    calls = []
    def cli(name, *arguments):
        calls.append((name, arguments))
        row = proof[name]
        if arguments == ('deployments', 'status'):
            return {'id': row['deploymentID'], 'versions': [{'version_id': item['versionID'],
                'percentage': item['percentage']} for item in row['versions']]}
        identifier = arguments[-1]
        return {'id': identifier, 'annotations': {'workers/message': subject.WORKER_SOURCE_PREFIX + row['sourceDigest']}}
    with patch.object(subject, 'worker_cli_json', cli):
        assert subject.capture_worker_deployments('all') == proof
        assert len(calls) == 6
        calls.clear()
        assert subject.capture_worker_deployments('school') == {} and calls == []
        with patch.object(subject, 'worker_source_digest', return_value='b' * 64):
            try: subject.capture_worker_deployments('all')
            except ValueError: pass
            else: raise AssertionError('旧部署需要拒绝新源码证据。')
    with patch.object(subject.subprocess, 'run', return_value=SimpleNamespace(returncode=0,
            stdout=json.dumps({'id': 'deployment'}))) as run:
        assert subject.worker_cli_json(folder, 'deployments', 'status') == {'id': 'deployment'}
        assert run.call_args.args[0][1:4] == ['deployments', 'status', '--json']
        assert run.call_args.kwargs['env']['WRANGLER_LOG_PATH'] == str(subject.ROOT / '.build/release-network-smoke/console.log')
    with patch.object(subject.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='')):
        try: subject.worker_cli_json(folder, 'deployments', 'status')
        except ValueError: pass
        else: raise AssertionError('认证失败需要传播读取失败。')
    report_path = Path('/fixture/release-network-smoke.json')
    report = {'scope': 'all', 'passed': True}
    for changed in (False, True):
        snapshot = copy.deepcopy(proof)
        if changed: snapshot[folder]['deploymentID'] = str(uuid.uuid4())
        with patch.object(sys, 'argv', ['worker', 'worker-attach', str(report_path), json.dumps(proof)]), \
                patch.object(Path, 'read_text', return_value=json.dumps(report)), patch.object(Path, 'write_text') as write, \
                patch.object(subject, 'capture_worker_deployments', return_value=snapshot), redirect_stderr(StringIO()):
            try: status = subject.worker_main()
            except SystemExit as error: status = error.code
            assert status == int(changed)
            if changed: write.assert_not_called()
            else: assert json.loads(write.call_args.args[0])['workerDeployments'] == proof
    with patch.object(subject, 'worker_source_digest', return_value='a' * 64), \
            patch.object(sys, 'argv', ['worker', 'deploy-worker', folder]), patch.object(subject.subprocess, 'run') as deploy:
        assert subject.worker_main() == 0
        assert deploy.call_args.args[0][1:4] == ['deploy', '--message', subject.WORKER_SOURCE_PREFIX + 'a' * 64]


def run_self_test(recorder) -> None:
    worker_deployment_self_test()
    module = sys.modules[recorder.__module__]
    check_group_bundle_self_test(module)
    summary = {"passed": True, "totalTests": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
    for group, start, run_id, artifact, expected in (
        ("audit", "", "run", None, 1),
        ("audit", "current", "", None, 1),
        ("audit", "current", "run", None, 0),
        ("all", "current", "run", "验证输入：old\n验证运行：run\n", 1),
        ("all", "current", "run", "验证输入：current\n验证运行：old\n", 1),
        ("all", "current", "run", "验证输入：current\n验证运行：run\n", 0),
        ("ui", "current", "run", "验证输入：current\n验证运行：run\n", 0),
        ("network", "current", "run", json.dumps({"runID": "old"}), 1),
        ("network", "current", "run", json.dumps({"runID": "run"}), 0),
    ):
        values = [artifact, '{"groups":{}}'] if artifact is not None else ['{"groups":{}}']
        with patch.object(module, "source_digest", return_value="current"), \
                patch.object(module, "complete_environment", return_value=True), \
                patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "write_report") as saved, \
                patch.object(module, "test_summary", return_value=summary), patch.object(module, "smoke_summary", return_value=summary), \
                patch.object(module, "complete_summary", return_value=True), patch.object(module, "environment_context", return_value={}), \
                patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", side_effect=values), \
                patch.object(module.subprocess, "check_output", return_value="head"), \
                patch("validation_performance.bundle_digest", return_value="a" * 64), patch("validation_performance.current_commit", return_value="head"), \
                patch("validation_performance.extract_measurements", return_value={"records": {}}), \
                patch.dict(os.environ, BIT101_VALIDATION_RUN_ID=run_id, BIT101_VALIDATION_STARTED_AT=utc_now().isoformat()), redirect_stderr(StringIO()):
            assert recorder(group, 0, "full", start) == expected, (group, artifact)
            assert saved.call_args.args[0]["groups"][group]["exitCode"] == expected
            if group in {"all", "ui"} and expected == 0:
                assert saved.call_args.args[0]["groups"][group]["resultBundleSHA256"] == "a" * 64
                assert saved.call_args.args[0]["groups"][group]["sourceCommit"] == "head"
    group_row = {"scope": "full", "exitCode": 0, "runID": "run", "inputDigest": "current", "summary": summary}
    for digest, expected in (("current", 0), ("changed", 1)):
        with patch.object(sys, "argv", ["validation_evidence.py", "check-group", "all"]), \
                patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "complete_summary", return_value=True), \
                patch.object(module, "source_digest", return_value=digest), patch.object(Path, "is_file", return_value=True), \
                patch.object(Path, "read_text", return_value=json.dumps({"groups": {"all": group_row}})), redirect_stderr(StringIO()):
            assert module.main() == expected
    selected = dict(group_row, scope='selected', lastFullRun=group_row)
    for status in (0, 1):
        selected['exitCode'] = status
        with patch.object(sys, 'argv', ['validation_evidence.py', 'check-group', 'all']), \
                patch.object(module, 'report_lock', side_effect=nullcontext), patch.object(module, 'complete_summary', return_value=True), \
                patch.object(module, 'source_digest', return_value='current'), patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_text', return_value=json.dumps({'groups': {'all': selected}})), redirect_stderr(StringIO()):
            assert module.main() == status
    artifact_lock_self_test(module)
    selected_coverage_self_test(module)
    baseline_policy_self_test(module)
    report_budget_self_test(module)
    aggregate_failure_self_test(module)
    complete_run_reuse_self_test()
    check_group_coverage_policy_self_test(module)
    now = utc_now()
    fresh = {"startedAt": (now - timedelta(minutes=2)).isoformat(), "finishedAt": (now - timedelta(minutes=1)).isoformat()}
    assert sampling_evidence_current(fresh, now)
    assert not sampling_evidence_current(dict(fresh, startedAt=(now - timedelta(days=2)).isoformat()), now)
    for group in LIVE_GROUPS:
        assert evidence_current(group, fresh)
        assert not evidence_current(group, dict(fresh, startedAt=(now - timedelta(days=2)).isoformat()))
    assert not sampling_evidence_current(fresh, now + timedelta(days=1))
    assert not sampling_evidence_current(dict(fresh, finishedAt=(now + timedelta(minutes=1)).isoformat()), now)
    assert not sampling_evidence_current(dict(fresh, startedAt=now.isoformat()), now)
    assert not sampling_evidence_current({"startedAt": "invalid", "finishedAt": "invalid"}, now)
    assert not sampling_evidence_current({}, now)
    for group in ("audit", "network", "icloud", "manual-device"):
      for summary, expected, label in ((fresh, 0, "通过"),
            (dict(fresh, finishedAt=(now - timedelta(days=2)).isoformat()), 1, "待复验")):
          row = dict(group_row, summary=dict(summary, passed=True))
          report = json.dumps({"groups": {group: row}})
          with patch.object(module, "source_digest", return_value="current"), \
                  patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "complete_summary", return_value=True), \
                  patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", return_value=report), \
                  patch.object(sys, "argv", ["validation_evidence.py", "check-group", group]), redirect_stderr(StringIO()):
              assert module.main() == expected
              output = StringIO()
              with redirect_stdout(output), patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}):
                  assert module.inspect_report(SimpleNamespace(action="summary", recorded_environment=False)) == 0
              assert f"| {group} | full | {label} |" in output.getvalue()


def check_group_bundle_self_test(module) -> None:
    from validation_performance import result_bundle_findings
    for group in ('all', 'ui'):
        for stored, raw in (('a' * 64, 'a' * 64), ('b' * 64, 'a' * 64), ('invalid', 'a' * 64), ('a' * 64, None)):
            row = {'scope': 'full', 'exitCode': 0, 'runID': 'run', 'inputDigest': 'current',
                'resultBundleSHA256': stored, 'summary': {'passed': True}}
            report = {'groups': {group: row}}
            with patch.object(module, 'report_lock', side_effect=nullcontext), \
                    patch.object(module, 'source_digest', return_value='current'), \
                    patch.object(module, 'complete_summary', return_value=True), \
                    patch('validation_coverage.policy_floors', return_value={}), \
                    patch.object(module, 'result_bundle_findings', wraps=result_bundle_findings), \
                    patch('validation_performance.bundle_digest', side_effect=lambda path: raw
                        if raw else (_ for _ in ()).throw(ValueError('absent result bundle'))), \
                    patch.object(Path, 'is_file', return_value=True), \
                    patch.object(Path, 'read_text', return_value=json.dumps(report)), \
                    patch.object(sys, 'argv', ['evidence', 'check-group', group]), redirect_stderr(StringIO()):
                assert module.main() == int(stored != raw)


def image_resource_self_test() -> None:
    import hashlib
    from network_request_contracts import complete
    def request(url):
        from urllib.parse import urlsplit
        parts = urlsplit(url)
        endpoint = parts._replace(query='', fragment='').geturl()
        return dict(method='GET', endpoint=endpoint, endpointDigest=hashlib.sha256(url.encode()).hexdigest(),
            finalMethod='GET', finalEndpoint=endpoint, statusCode=200, query={}, finalQuery={})
    urls = ['https://cdn.example/image.png?token=first', 'https://cdn.example/other.png']
    rows = [request(url) for url in urls]
    expected = {'resourceDigests': ','.join(sorted(row['endpointDigest'] for row in rows))}
    for probe in ('gallery.image', 'paper.image'):
        assert complete(probe, rows, expected)
        assert not complete(probe, rows, {})
        assert not complete(probe, rows[:1], expected)
        assert not complete(probe, [request('https://unrelated.example/wrong-image.png')], expected)
        assert not complete(probe, [request(urls[0].replace('first', 'second')), rows[1]], expected)
        assert not complete(probe, rows + [request('https://cdn.example/extra.png')], expected)


def check_group_coverage_policy_self_test(module) -> None:
    for group in ('modules', 'all', 'ui', 'catalyst'):
        name = 'GalleryFeature' if group == 'modules' else 'Catalyst/GalleryFeature' if group == 'catalyst' else 'iOS/GalleryFeature'
        for selected in (False, True):
            for floor, covered, expected in ((70, 74, 0), (75, 74, 1), (75, 75, 0)):
                full = {'scope': 'full', 'exitCode': 0, 'runID': 'full', 'inputDigest': 'current',
                    'environment': {}, 'summary': {'passed': True, 'coverage': {
                        name: {'coveredLines': covered, 'executableLines': 100}}}}
                row = dict(full, scope='selected', lastFullRun=full,
                    summary={'passed': True, 'coverage': {name: {'coveredLines': 100, 'executableLines': 100}}}) if selected else full
                report = {'groups': {group: row}, 'coveragePolicy': {
                    'modules' if group == 'modules' else 'all': {'GalleryFeature': floor}}}
                with patch.object(module, 'source_digest', return_value='current'), \
                        patch.object(module, 'report_lock', side_effect=nullcontext), \
                        patch.object(module, 'complete_summary', return_value=True), \
                        patch('validation_policy.MODULE_COVERAGE_FLOORS', {'GalleryFeature': 70}), \
                        patch('validation_policy.IOS_MODULE_COVERAGE_FLOORS', {'GalleryFeature': 70}), \
                        patch('validation_policy.UI_PRODUCTION_MODULES', frozenset({'GalleryFeature'})), \
                        patch.object(Path, 'is_file', return_value=True), \
                        patch.object(Path, 'read_text', return_value=json.dumps(report)), \
                        patch.object(sys, 'argv', ['validation_evidence.py', 'check-group', group]), redirect_stderr(StringIO()):
                    assert module.main() == expected, (group, selected, floor, covered)


def artifact_lock_self_test(module) -> None:
    source = (module.ROOT / "Scripts/validation_artifacts.py").read_text()
    import fcntl
    diagnostics = module.ROOT / '.build/extended-automation/diagnostics'
    for leftover in (False, True):
        with patch.object(sys, 'argv', ['validation_artifacts.py', str(module.ROOT)]), \
                patch.dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD='1'), \
                patch.object(Path, 'exists', lambda path: leftover and path == diagnostics), \
                patch.object(Path, 'open', return_value=nullcontext(BytesIO())), \
                patch.object(os, 'walk', return_value=[]), \
                patch.object(fcntl, 'flock', side_effect=BlockingIOError), redirect_stdout(StringIO()):
            status = 0
            try: exec(compile(source, 'validation_artifacts.py', 'exec'), {'__name__': '__main__'})
            except SystemExit as error: status = error.code
            assert status == int(leftover), '父工作流持锁时诊断残留仍需进入产物门禁'
    definition = next(node for node in ast.parse(source).body if isinstance(node, ast.FunctionDef) and node.name == "committed_children")
    harness = "from pathlib import Path\nimport fcntl, sys\n" + ast.get_source_segment(source, definition)
    harness += '\nprint("ready", flush=True)\nchildren = committed_children(Path(sys.argv[1]))\nassert all(path.suffix != ".incoming" for path in children)\nprint("committed", flush=True)\n'
    for report in (module.REPORT, module.ROOT / '.build/icloud-cross-device-smoke/report.json',
                   module.ROOT / '.build/static-audit/compilation-conditions.json'):
        incoming = report.with_suffix(".incoming")
        with module.report_lock(path=report):
            incoming.write_text("pending atomic report")
            child = subprocess.Popen([sys.executable, "-B", "-c", harness, str(report.parent)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert child.stdout.readline().strip() == "ready"
                try: child.communicate(timeout=0.2)
                except subprocess.TimeoutExpired: pass
                else: raise AssertionError("产物扫描需要等待验证报告原子写入锁")
            finally:
                incoming.unlink()
        output, error = child.communicate(timeout=10)
        assert child.returncode == 0 and output.strip() == "committed", error


def baseline_policy_self_test(module) -> None:
    report = {'coverageBaseCommit': 'target', 'coveragePolicy': {'modules': {'Feature': 80}, 'all': {'Feature': 70}},
        'groups': {}}
    for fault in ('none', 'commit', 'missing', 'value', 'extra'):
        candidate = json.loads(json.dumps(report))
        if fault == 'commit': candidate['coverageBaseCommit'] = 'other'
        if fault == 'missing': candidate['coveragePolicy'].pop('all')
        if fault == 'value': candidate['coveragePolicy']['all']['Feature'] = True
        if fault == 'extra': candidate['coveragePolicy']['audit'] = {'Feature': 70}
        with patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_text', return_value=json.dumps(candidate)), \
                patch.object(module, 'write_report') as saved, redirect_stderr(StringIO()):
            assert module.inspect_report(SimpleNamespace(action='baseline', group='target')) == (0 if fault == 'none' else 1)
        if fault == 'none':
            actual = saved.call_args.args[0]
            assert actual['groups'] == {} and actual['coveragePolicy'] == report['coveragePolicy']
            from validation_coverage import regressions, policy_floors
            with patch('validation_policy.IOS_MODULE_COVERAGE_FLOORS', {'Feature': 60}):
                assert regressions({'iOS/Feature': {'coveredLines': 69, 'executableLines': 100}},
                    policy_floors('all', actual['coveragePolicy'])) == ['iOS/Feature: 69% < 70%']
        else: saved.assert_not_called()


def selected_coverage_self_test(module) -> None:
    full = {"scope": "full", "exitCode": 0, "inputDigest": "digest", "runID": "full",
        "summary": {"passed": True, "coverage": {"iOS/Feature": {"coveredLines": 95, "executableLines": 100}}}}
    report = {"groups": {"all": full}}
    for scope, expected in (("selected", 0), ("selected", 0), ("full", 0), ("full", 1)):
        if expected: report['coveragePolicy'] = {'all': {'Feature': 95}}
        summary = {"passed": True, "totalTests": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
            "executedTests": ["Suite/testRun"], "coverage": {"iOS/Feature": {"coveredLines": 94, "executableLines": 100}}}
        with patch.object(module, "source_digest", return_value="digest"), patch.object(module, "complete_environment", return_value=True), \
                patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "write_report") as saved, \
                patch.object(module, "test_summary", return_value=summary), patch.object(module, "complete_summary", return_value=True), \
                patch.object(Path, "is_file", return_value=True), \
                patch.object(Path, "read_text", side_effect=['验证输入：digest\n验证运行：run\n', json.dumps(report)]), \
                patch.object(subprocess, "check_output", return_value="head"), \
                patch("validation_performance.bundle_digest", return_value="a" * 64), patch("validation_performance.current_commit", return_value="head"), \
                patch('validation_policy.IOS_MODULE_COVERAGE_FLOORS', {'Feature': 94}), \
                patch('validation_performance.extract_measurements', return_value={}), \
                patch.dict(os.environ, BIT101_VALIDATION_RUN_ID="run", BIT101_VALIDATION_EXPECTED_TESTS='["Suite/testRun"]'), redirect_stderr(StringIO()):
            assert module.record("all", 0, scope, "digest") == expected
        report = saved.call_args.args[0]
        row = report['groups']['all']
        assert 'coverageBaseline' not in row
        if scope == 'selected': assert row['lastFullRun'] == full
        elif expected: assert row['summary']['coverageRegressions'] and row['summary']['passed'] is False
        else: assert row['summary']['passed'] is True


def report_budget_self_test(module) -> None:
    for limit, accepted in ((16, False), (64, True)):
        stream = BytesIO()
        with patch('validation_policy.MAXIMUM_REPORT_BYTES', limit), patch.object(Path, 'open', return_value=nullcontext(stream)), \
                patch.object(Path, 'replace') as committed, patch.object(Path, 'unlink') as cleanup:
            try: module.write_report({'evidence': 'x' * 17})
            except ValueError: assert not accepted
            else:
                assert accepted and json.loads(stream.getvalue()) == {'evidence': 'x' * 17}
            assert committed.called == accepted
            assert stream.tell() <= limit
            cleanup.assert_called_once_with(missing_ok=True)
    import shutil
    fixture = module.ROOT / '.build/static-audit/report-write-self-test'
    fixture.mkdir(parents=True, exist_ok=True)
    destination = fixture / 'report.json'
    original = json.dumps({'runID': 'retained-cloud-owner', 'stages': []}).encode()
    try:
        for failure in ('write', 'replace'):
            destination.write_bytes(original)
            original_open = Path.open
            class InterruptedStream:
                def __enter__(self):
                    self.stream = original_open(destination.with_suffix('.incoming'), 'wb')
                    return self
                def write(self, data):
                    self.stream.write(data[:1])
                    raise OSError('interrupted report write')
                def __exit__(self, *args): self.stream.close()
            override = patch.object(Path, 'open', return_value=InterruptedStream()) if failure == 'write' \
                else patch.object(Path, 'replace', side_effect=OSError('interrupted report commit'))
            with override:
                try: module.write_report({'runID': 'new-owner', 'stages': []}, path=destination)
                except OSError: pass
                else: raise AssertionError('写入故障需要保留原恢复记录')
            assert destination.read_bytes() == original
            assert json.loads(destination.read_text())['runID'] == 'retained-cloud-owner'
            assert not destination.with_suffix('.incoming').exists()
        module.write_report({'runID': 'new-owner', 'stages': []}, path=destination)
        assert json.loads(destination.read_text())['runID'] == 'new-owner'
    finally:
        shutil.rmtree(fixture)


def aggregate_failure_self_test(module) -> None:
    import re
    source = (module.ROOT / "Scripts/run-extended-tests.sh").read_text()
    step = re.search(r"(?ms)^  verify_step\(\) \{.*?^  \}", source)[0]
    for command_status, evidence_status in ((0, 0), (7, 0), (0, 7)):
        harness = f'''ROOT_DIR=/repo
SECONDS=0
completed_result_groups=()
command() {{ return {command_status}; }}
python3() {{ if [[ "$2" == check-group ]]; then return {evidence_status}; fi; return 0; }}
'''
        result = subprocess.run(["zsh", "-c", harness + step + "\nverify_step all command\nprint next-group"], capture_output=True, text=True)
        assert (result.returncode == 0) == (command_status == evidence_status == 0)
        assert ("next-group" in result.stdout) == (result.returncode == 0)


def complete_run_reuse_self_test() -> None:
    from copy import deepcopy
    from validation_provenance import complete_group_row
    full = {'scope': 'full', 'exitCode': 0, 'summary': {'passed': True}, 'inputDigest': 'same', 'environment': {'device': 'phone'}}
    selected = dict(full, scope='selected', lastFullRun=full)
    assert complete_group_row(selected) is full
    for name, value in [('exitCode', 1), ('inputDigest', 'changed'), ('environment', {'device': 'other'}), ('summary', {'passed': False})]:
        changed = dict(selected, **{name: value})
        assert complete_group_row(changed) is changed
    changed = deepcopy(selected)
    changed['lastFullRun']['exitCode'] = 1
    assert complete_group_row(changed) is changed
    from validation_environment import exchange_identity
    context = {'developer': '/fixture/Xcode', 'device': {'identifier': 'phone'}}
    shared_full = dict(full, environment=exchange_identity(context))
    selected = dict(full, scope='selected', environment=context, lastFullRun=shared_full)
    assert complete_group_row(selected) is shared_full
    changed = dict(selected, environment=context | {'device': {'identifier': 'other'}})
    assert complete_group_row(changed) is changed


def network_trace_fixture(value: dict) -> dict:
    from network_request_contracts import contracts_for, SELECTORS, VISIBLE_PARAMETERS
    value['workerDeployments'] = worker_deployment_fixture(value.get('scope'))
    def example(pattern, identifier=1):
        import re
        pattern = re.sub(r'\(\?:([^()]*)\)', lambda match: match[1].split('|')[0], pattern)
        return pattern.replace('[0-9a-f]+', 'a').replace(r'[1-9]\d*', str(identifier)).replace(r'\d+', str(identifier)).replace(r'\.', '.').replace(r'\-', '-').replace(r'\+', '+').replace('.+', 'fixture').replace('?', '')
    rows = []
    for name in value.get('requiredProbes', []):
        contracts = contracts_for(name)
        assert contracts, name
        requests = []
        expected = {'XNXQDM': value.get('validatedTerm', 'fixture-current')} if name in {'schedule.sync', 'classroom.occupancy'} else {}
        if name == 'classroom.occupancy':
            year, _, semester = expected['XNXQDM'].rpartition('-')
            expected.update(JXLDM='fixture-building', RQ='2026-09-07', XQDM=semester, XNDM=year)
        for contract in contracts:
            for index in range(max(contract.minimum, 2 if contract.paging else 1)):
                query = {key: example(pattern) if key in VISIBLE_PARAMETERS else '[REDACTED]'
                    for key, pattern in contract.query.items() if pattern is not None}
                query.update({key: item for key, item in expected.items() if key != 'path'})
                if contract.paging == 'page': query['page'] = str(index)
                if contract.paging == 'last_id': query['last_id'] = str(sys.maxsize) if index == 0 else '1'
                request = {'method': contract.method, 'endpoint': 'https://' + example(contract.host) + example(contract.path),
                    'statusCode': next(iter(contract.statuses)), 'query': query}
                if contract.paging == 'last_id': request['responseMinimumID'] = '0'
                if name in {'eclass.authentication', 'eclass.ddl'}: request['responseCourseIDs'] = []
                if name == 'update.emergency': request['responseConfiguration'] = {'digest': 'a' * 64, 'enabled': False}
                if name == 'community.writes':
                    if contract.method == 'DELETE' and contract.path == r'/reaction/comments/\d+':
                        request['endpoint'] = 'https://' + example(contract.host) + example(contract.path, index + 1)
                    if contract.method == 'POST' and contract.path == '/reaction/comments' and query['obj'].startswith('comment'):
                        query['obj'] = 'comment' + str(index // 2 + 1)
                request.update(finalEndpoint=('https://' + example(contract.final_host) + example(contract.final_path))
                    if contract.final_host else request['endpoint'], finalMethod=request['method'], finalQuery=dict(query))
                assert contract.matches(request), (name, request)
                for key in SELECTORS.get(name, set()) - set(expected):
                    from urllib.parse import unquote, urlsplit
                    expected[key] = unquote(urlsplit(request['endpoint']).path) if key == 'path' else request['query'][key]
                requests.append(request)
        if name == 'community.session': requests.insert(1, requests.pop())
        if name in {'gallery.image', 'paper.image'}:
            import hashlib
            for request in requests: request['endpointDigest'] = hashlib.sha256(request['endpoint'].encode()).hexdigest()
            expected['resourceDigests'] = ','.join(sorted({request['endpointDigest'] for request in requests}))
        rows.append({'probe': name, 'requests': requests, 'expectedParameters': expected})
    value['requestEvidenceRequired'] = True
    value['requestEvidence'] = rows
    return value


def network_route_identity_self_test() -> None:
    image_resource_self_test()
    from copy import deepcopy
    from validation_provenance import network_requests_complete
    from network_request_contracts import complete as check_complete
    emergency = network_trace_fixture({'requiredProbes': ['update.emergency']})['requestEvidence'][0]['requests']
    assert check_complete('update.emergency', emergency)
    for configuration in (None, {}, {'digest': 'bad', 'enabled': False}, {'digest': 'a' * 64, 'enabled': True},
                          {'digest': 'a' * 64, 'enabled': True, 'noticeID': ' '}):
        assert not check_complete('update.emergency', [dict(emergency[0], responseConfiguration=configuration)])
    assert check_complete('update.emergency', [dict(emergency[0], responseConfiguration={'digest': 'b' * 64, 'enabled': True, 'noticeID': 'maintenance'})])
    for probe, parameters in [('classroom.campuses', {'dicCode': 'unrelated-dictionary', 'SFSY': '0'}),
                              ('score.transcript', {'GPA': '0'})]:
        fixture = network_trace_fixture({'requiredProbes': [probe]})
        assert network_requests_complete({probe}, fixture)
        for key, value in parameters.items():
            for field in ('query', 'finalQuery'):
                for invalid in (value, '[REDACTED]', None):
                    changed = deepcopy(fixture)
                    target = next(row for row in changed['requestEvidence'][0]['requests'] if key in row[field])
                    if invalid is None: target[field].pop(key)
                    else: target[field][key] = invalid
                    assert not network_requests_complete({probe}, changed), (probe, key, field, invalid)
    def complete(probe, requests, expected=None):
        return check_complete(probe, [dict(row, finalEndpoint=row.get('finalEndpoint', row['endpoint']),
            finalMethod=row.get('finalMethod', row['method']), finalQuery=row.get('finalQuery', dict(row.get('query', {}))))
            for row in requests], expected)
    required = {'paper.comments'}
    proof = network_trace_fixture({'requiredProbes': sorted(required)})
    assert network_requests_complete(required, proof)
    for key in ('ambiguousParameters', 'finalAmbiguousParameters'):
        changed = deepcopy(proof)
        row = changed['requestEvidence'][0]
        row['requests'][0][key] = ['page']
        assert not complete(row['probe'], row['requests'], row['expectedParameters'])
        assert not network_requests_complete(required, changed)
    repeated = deepcopy(proof['requestEvidence'][0])
    repeated['requests'][-1]['statusCode'] = 500
    assert not network_requests_complete(required, dict(proof, requestEvidence=proof['requestEvidence'] + [repeated]))
    for key, value in [('finalEndpoint', 'https://example.invalid/reaction/comments'),
                       ('finalMethod', 'POST'), ('finalQuery', {'obj': 'paper999', 'order': 'new', 'page': '0'})]:
        changed = deepcopy(proof)
        for request in changed['requestEvidence'][0]['requests']: request[key] = value
        assert not network_requests_complete(required, changed), key
    changed = deepcopy(proof)
    del changed['requestEvidence'][0]['requests'][0]['finalEndpoint']
    assert not network_requests_complete(required, changed)
    schedule = network_trace_fixture({'requiredProbes': ['schedule.sync']})
    for request in schedule['requestEvidence'][0]['requests']: request['finalQuery']['XNXQDM'] = 'wrong-term'
    assert not network_requests_complete({'schedule.sync'}, schedule)
    for probe in ('gallery.comments', 'course.comments', 'paper.comments', 'course.list'):
        fixture = network_trace_fixture({'requiredProbes': [probe]})
        for parameter in ('order', 'search') if probe == 'course.list' else ('order',):
            changed = deepcopy(fixture)
            for row in changed['requestEvidence'][0]['requests']:
                row['query'][parameter] = row['finalQuery'][parameter] = 'invalid-order'
            assert not network_requests_complete({probe}, changed), (probe, parameter)
    from network_request_contracts import SELECTORS
    for probe, selectors in SELECTORS.items():
        selected = network_trace_fixture({'requiredProbes': [probe]})
        row = selected['requestEvidence'][0]
        assert complete(probe, row['requests'], row['expectedParameters'])
        assert not complete(probe, row['requests'])
        for key in selectors:
            changed = deepcopy(selected)
            for request in changed['requestEvidence'][0]['requests']:
                if key == 'path': request['endpoint'] = request['endpoint'].rsplit('/', 1)[0] + '/999'
                else: request['query'][key] = '999' if key == 'uid' else re.sub(r'\d+$', '999', request['query'][key]) if key == 'obj' else 'wrong'
            assert not network_requests_complete({probe}, changed), (probe, key)
    for key, value in [('endpoint', 'https://example.invalid/unrelated'), ('method', 'POST'),
                       ('endpoint', 'http://bit101.flwfdd.xyz/reaction/comments'), ('statusCode', 500),
                       ('query', {'obj': 'course1', 'page': '0'})]:
        changed = deepcopy(proof)
        for request in changed['requestEvidence'][0]['requests']: request[key] = value
        assert not network_requests_complete(required, changed)
    changed = deepcopy(proof)
    changed['requestEvidence'][0]['requests'].pop()
    assert not network_requests_complete(required, changed)
    changed = deepcopy(proof)
    changed['requestEvidence'][0]['requests'][1]['query']['page'] = '0'
    assert not network_requests_complete(required, changed)
    changed['requestEvidence'][0]['requests'][1]['query']['page'] = '999'
    assert not network_requests_complete(required, changed)
    original = proof['requestEvidence'][0]['requests']
    for pages in ((0, 99, 1), (0, 1, 1), (0, 1, 3), (0, 1, 2)):
        changed = deepcopy(proof)
        rows = [deepcopy(original[0]) for _ in pages]
        for row, page in zip(rows, pages): row['query']['page'] = row['finalQuery']['page'] = str(page)
        changed['requestEvidence'][0]['requests'] = rows
        assert network_requests_complete(required, changed) == (pages == (0, 1, 2)), pages
    cursors = network_trace_fixture({'requiredProbes': ['message.system']})
    cursor_probe = cursors['requestEvidence'][0]
    assert complete(cursor_probe['probe'], cursor_probe['requests'])
    nonempty = deepcopy(cursor_probe['requests'])
    nonempty[0]['responseMinimumID'] = '9'
    nonempty[1]['query']['last_id'] = '9'
    nonempty[1]['finalQuery']['last_id'] = '9'
    assert complete(cursor_probe['probe'], nonempty)
    for position, invalid in ((0, None), (0, '0'), (1, '0')):
        changed = deepcopy(cursor_probe['requests'])
        if invalid is None: changed[position]['query'].pop('last_id')
        else: changed[position]['query']['last_id'] = invalid
        assert not complete(cursor_probe['probe'], changed), (position, invalid)
    for invalid in ('999', None):
        changed = deepcopy(cursor_probe['requests'])
        changed[0]['responseMinimumID'] = invalid
        assert not complete(cursor_probe['probe'], changed)
    writes = network_trace_fixture({'requiredProbes': ['community.writes']})['requestEvidence'][0]['requests']
    assert complete('community.writes', writes)
    assert sum(row['endpoint'].endswith('/upload/image') for row in writes) == 4
    assert sum(row['method'] == 'POST' and row['endpoint'].endswith('/reaction/comments') for row in writes) == 9
    for endpoint, method in [('/upload/image', 'POST'), ('/reaction/comments/', 'DELETE')]:
        index = next(index for index, row in enumerate(writes) if endpoint in row['endpoint'] and row['method'] == method)
        assert not complete('community.writes', writes[:index] + writes[index + 1:])
    for endpoint, method in [('/upload/image', 'POST'), ('/reaction/comments', 'POST'),
            ('/reaction/comments/', 'DELETE'), ('/reaction/like', 'POST'), ('/user/follow/', 'POST'),
            ('/posters/', 'PUT'), ('/papers/', 'PUT')]:
        changed = [row for row in writes if not (endpoint in row['endpoint'] and row['method'] == method)]
        assert not complete('community.writes', changed), (endpoint, method)
    changed = deepcopy(writes)
    for row in changed:
        if row['method'] == 'POST' and row['endpoint'].endswith('/reaction/comments'):
            row['query']['obj'] = 'poster1'
    assert not complete('community.writes', changed)
    for probe, endpoint in [('eclass.authentication', 'https://zy-eclass.bit.edu.cn/api/my-courses'),
                            ('eclass.ddl', 'https://zy-eclass.bit.edu.cn/api/my-courses'),
                            ('lexue.calendar', 'https://lexue.bit.edu.cn/calendar/export.php')]:
        request = {'method': 'POST', 'endpoint': endpoint, 'statusCode': 200, 'query': {}}
        if probe.startswith('eclass.'): request['responseCourseIDs'] = []
        assert complete(probe, [request]), probe
        assert not complete(probe, [dict(request, method='GET')]), probe
    for probe in ('eclass.authentication', 'eclass.ddl'):
        page = {'method': 'POST', 'endpoint': 'https://zy-eclass.bit.edu.cn/api/my-courses',
            'statusCode': 200, 'query': {}, 'responseCourseIDs': ['41', '43']}
        activities = [dict(page, method='GET', endpoint=f'https://zy-eclass.bit.edu.cn/api/courses/{value}/activities') for value in (41, 43)]
        assert complete(probe, [page] + activities)
        for rows in ([page], [page, activities[0]], [dict(page, responseCourseIDs=None)] + activities,
                     [dict(page, responseCourseIDs=['0'])] + activities,
                     [page] + activities + [dict(activities[0], endpoint='https://zy-eclass.bit.edu.cn/api/courses/45/activities')],
                     [page, activities[0], dict(activities[1], finalEndpoint=activities[0]['endpoint'])]):
            assert not complete(probe, rows), (probe, rows)
        assert complete(probe, [dict(page, responseCourseIDs=['41']), dict(page, responseCourseIDs=['43'])] + activities)
        assert complete(probe, [dict(page, responseCourseIDs=[])])
    building = {'method': 'GET', 'endpoint': 'https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do',
        'statusCode': 200, 'query': {'XXXQDM': 'campus'}}
    assert complete('classroom.buildings', [building], {'XXXQDM': 'campus'})
    assert not complete('classroom.buildings', [building])
    for query in ({}, {'XXXQDM': 'other'}):
        assert not complete('classroom.buildings', [dict(building, query=query)], {'XXXQDM': 'campus'})
        assert not complete('classroom.buildings', [dict(building, finalQuery=query)], {'XXXQDM': 'campus'})
    variants = {
        'gallery.newest': {'mode': 'search', 'order': 'new', 'uid': '-1'},
        'gallery.following': {'mode': 'follow'}, 'gallery.hot': {'mode': 'hot'}, 'gallery.recommend': {},
        'gallery.bots': {'mode': 'search', 'order': 'new', 'uid': '-1'},
        'gallery.search': {'mode': 'search', 'order': 'new', 'uid': '-1', 'search': 'BIT101'},
        'paper.list.newest': {'search': 'BIT101'}, 'paper.list.like': {'order': 'like', 'search': 'BIT101'},
        'paper.list.comment': {'order': 'comment', 'search': 'BIT101'},
    }
    for probe, parameters in variants.items():
        endpoint = 'https://bit101.flwfdd.xyz/' + ('papers' if probe.startswith('paper.') else 'posters')
        requests = [{'method': 'GET', 'endpoint': endpoint, 'statusCode': 200,
                     'query': dict(parameters, page=str(page))} for page in (0, 1)]
        assert complete(probe, requests), probe
        for key in ('limit', 'claim_id', 'tags'):
            for field in ('query', 'finalQuery'):
                changed = deepcopy(requests)
                for row in changed: row[field] = dict(row.get(field, row['query']), **{key: '[REDACTED]'})
                assert not complete(probe, changed), (probe, key, field)
        for extra in (dict(requests[-1], query=dict(parameters, page='2', order='unexpected')),
                      dict(requests[-1], statusCode=500), dict(requests[-1], endpoint='https://example.invalid/other')):
            assert not complete(probe, requests + [extra]), (probe, extra)
        for key in ('order', 'search') if probe.startswith('paper.') else ('mode', 'order', 'uid', 'search', 'hide_bot'):
            changed = deepcopy(requests)
            for row in changed:
                if key in row['query']: row['query'].pop(key)
                else: row['query'][key] = 'unexpected'
            assert not complete(probe, changed), (probe, key)
    assert not complete('paper.list.未知', requests)
    for probe, parameters, selectors in [
        ('paper.list', {}, None), ('profile.posts', {'mode': 'search', 'uid': '0'}, {'uid': '0'}),
        ('user.posts', {'mode': 'search', 'uid': '42'}, {'uid': '42'}),
    ]:
        endpoint = 'https://bit101.flwfdd.xyz/' + ('papers' if probe.startswith('paper.') else 'posters')
        rows = [{'method': 'GET', 'endpoint': endpoint, 'statusCode': 200, 'query': dict(parameters, page=str(page))}
            for page in (0, 1)]
        assert complete(probe, rows, selectors), probe
        for key, value in [('order', 'hot'), ('search', 'BIT101')]:
            changed = deepcopy(rows)
            for row in changed: row['query'][key] = value
            assert not complete(probe, changed, selectors), (probe, key)
            changed = deepcopy(rows)
            for row in changed: row['finalQuery'] = dict(row['query'], **{key: value})
            assert not complete(probe, changed, selectors), (probe, key, 'redirect')
    for probe, paths, expected in [
        ('schedule.sync', ['/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do',
            '/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do', '/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do'], {'XNXQDM': '2025-2026-1'}),
        ('classroom.occupancy', ['/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do'],
            {'XNXQDM': '2025-2026-1', 'JXLDM': 'fixture-building', 'RQ': '2026-09-07', 'XQDM': '1', 'XNDM': '2025-2026'}),
    ]:
        rows = [{'method': 'POST', 'endpoint': 'https://jxzxehallapp.bit.edu.cn' + path, 'statusCode': 200, 'query': dict(expected)} for path in paths]
        assert complete(probe, rows, expected) and not complete(probe, rows)
        for key in expected:
            for field in ('query', 'finalQuery'):
                changed = deepcopy(rows)
                changed[0][field] = dict(changed[0]['query'], **{key: '2026-09-06' if key == 'RQ' else 'wrong-selection'})
                assert not complete(probe, changed, expected)
                changed[0][field].pop(key)
                assert not complete(probe, changed, expected)
        if probe == 'classroom.occupancy':
            for key, value in [('RQ', '2026-02-30'), ('XQDM', '2'), ('XNDM', '2024-2025')]:
                changed = {**expected, key: value}
                assert not complete(probe, [dict(row, query=changed) for row in rows], changed), key
    login = {'method': 'GET', 'endpoint': 'https://bit101.flwfdd.xyz/user/check', 'statusCode': 200, 'query': {}}
    paper = dict(login, endpoint='https://bit101.flwfdd.xyz/papers/17')
    comments = [dict(login, endpoint='https://bit101.flwfdd.xyz/reaction/comments',
        query={'obj': 'paper17', 'order': 'new', 'page': str(page)}) for page in (0, 1)]
    for probe, requests, selectors in [
        ('paper.detail', [login, paper], {'path': '/papers/17'}),
        ('paper.comments', [login, comments[0], login, comments[1]], {'obj': 'paper17'}),
    ]:
        assert complete(probe, requests, selectors), probe
        assert complete(probe, [row for row in requests if row is not login], selectors), probe
        assert complete(probe, [dict(login, statusCode=401)] + requests, selectors), probe
        assert not complete(probe, [login], selectors), probe
        for broken in (dict(login, statusCode=500), dict(login, statusCode=401), dict(login, method='POST'),
                dict(login, endpoint='https://example.invalid/user/check'), dict(login, endpoint='https://bit101.flwfdd.xyz/user/unrelated')):
            assert not complete(probe, requests + [broken], selectors), (probe, broken)
    write_reads = [login, dict(login, endpoint='https://bit101.flwfdd.xyz/user/info/0'),
        dict(login, endpoint='https://bit101.flwfdd.xyz/user/info/18'),
        dict(login, endpoint='https://bit101.flwfdd.xyz/courses/3'),
        dict(login, endpoint='https://bit101.flwfdd.xyz/posters/1'), paper,
        dict(login, endpoint='https://bit101.flwfdd.xyz/posters', query={'mode': 'search', 'uid': '0', 'page': '0'}),
        dict(login, endpoint='https://bit101.flwfdd.xyz/papers', query={'search': '功能验收', 'page': '0'}),
        dict(login, endpoint='https://bit101.flwfdd.xyz/reaction/comments', query={'obj': 'paper17', 'order': 'old', 'page': '0'})]
    assert complete('community.writes', write_reads + writes)
    assert not complete('community.writes', write_reads)
    for row in write_reads:
        assert not complete('community.writes', writes + [dict(row, statusCode=500)]), row
    assert not complete('community.writes', writes + [dict(login, endpoint='https://bit101.flwfdd.xyz/user/unrelated')])
    assert complete('community.login', [dict(login, statusCode=401), login])
    assert not complete('community.login', [login, dict(login, statusCode=401)])
    assert not complete('community.login', [dict(login, statusCode=500), login])
    assert not complete('community.login', [dict(login, statusCode=401, query={'order': 'old'}), login])
    authentication = dict(login, method='POST', endpoint='https://bit101.flwfdd.xyz/user/webvpn_verify')
    assert complete('community.login', [dict(login, statusCode=401), authentication, login])
    assert not complete('community.login', [dict(login, statusCode=401), dict(authentication, statusCode=500), login])
    teaching = {'method': 'GET', 'endpoint': 'https://jxzxehallapp.bit.edu.cn/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do', 'statusCode': 200, 'query': {}}
    preheat = dict(teaching, endpoint='https://jxzxehallapp.bit.edu.cn/jwapp/i18n.do')
    cookies = dict(authentication, endpoint='https://login.bit101.flwfdd.xyz/api/jxzxehall/cookies')
    assert complete('schedule.current-term', [cookies, preheat, teaching])
    redirected = dict(teaching, finalEndpoint='https://sso.bit.edu.cn/cas/login', finalMethod='GET', finalQuery={})
    assert complete('schedule.current-term', [redirected, cookies, preheat, teaching])
    assert not complete('schedule.current-term', [redirected, cookies, preheat])
    assert not complete('schedule.current-term', [dict(redirected, finalEndpoint='https://example.invalid/cas/login'), cookies, teaching])
    assert not complete('schedule.current-term', [dict(redirected, statusCode=500), cookies, teaching])
    assert complete('schedule.current-term', [dict(cookies, statusCode=503), cookies, preheat, teaching])
    assert not complete('schedule.current-term', [cookies, dict(preheat, statusCode=500), teaching])
    transcript = network_trace_fixture({'requiredProbes': ['score.transcript']})['requestEvidence'][0]
    page = {'method': 'GET', 'endpoint': 'https://jwb.bit.edu.cn/cjd/Temp/page.jpg', 'statusCode': 200, 'query': {}}
    assert complete('score.transcript', transcript['requests'] + [page])
    assert not complete('score.transcript', transcript['requests'] + [dict(page, statusCode=500)])
    assert complete('community.login', [dict(login, endpoint='https://bit101.flwfdd.xyz:443/user/check')])
    for port in ('0', '80', '8443', '65536', 'invalid'):
        assert not complete('community.login', [dict(login, endpoint='https://bit101.flwfdd.xyz:' + port + '/user/check')])
    media = network_trace_fixture({'requiredProbes': ['gallery.image']})['requestEvidence'][0]
    import hashlib
    resource = 'https://image.invalid:8443/image.png'
    digest = hashlib.sha256(resource.encode()).hexdigest()
    assert complete('gallery.image', [dict(media['requests'][0], endpoint=resource, finalEndpoint=resource,
        endpointDigest=digest)], {'resourceDigests': digest})
    for status in (100, 302, 401, 403, 500):
        assert not complete('community.login', [dict(login, statusCode=status)])
    assert not complete('community.login', [dict(login, endpoint=login['endpoint'].replace('https:', 'http:'))])
    account = dict(login, endpoint='https://bit101.flwfdd.xyz/user/info/0')
    phases = [account, dict(account, statusCode=401), account]
    assert complete('community.session', phases)
    for statuses in ((200, 200, 200), (401, 200, 200), (200, 401, 500), (200, 403, 200), (200, 401), (200, 401, 200, 200)):
        assert not complete('community.session', [dict(account, statusCode=status) for status in statuses])
