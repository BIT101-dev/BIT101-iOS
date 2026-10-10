"""Exercise workflow ownership and bounded network evidence using memory IO substitutes."""
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from datetime import timedelta
from io import BytesIO, StringIO
import ast
import json
import subprocess
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch
from validation_provenance import LIVE_GROUPS, evidence_current, sampling_evidence_current, utc_now


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
    proof = worker_deployment_fixture()
    assert subject.worker_deployments_complete('all', proof)
    assert subject.worker_deployments_complete('school', {})
    assert not subject.worker_deployments_complete('all', {})
    folder = subject.WORKER_FOLDERS[0]
    original_read = Path.read_bytes
    source = subject.ROOT / 'Cloudflare' / folder / 'worker.js'
    with patch.object(Path, 'read_bytes', lambda path: original_read(path) + b'\nchanged\n' if path == source else original_read(path)):
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


def check_group_coverage_policy_self_test(module) -> None:
    for group in ('modules', 'all', 'ui'):
        name = 'GalleryFeature' if group == 'modules' else 'iOS/GalleryFeature'
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
    for report in (module.REPORT, module.ROOT / '.build/icloud-cross-device-smoke/report.json'):
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
