"""Exercise workflow ownership and bounded network evidence using memory IO substitutes."""
from contextlib import contextmanager, nullcontext, redirect_stderr, redirect_stdout
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
from validation_manual_tests import image_resource_self_test, report_budget_self_test
from worker_contract_tests import worker_deployment_fixture, worker_deployment_self_test, emergency_configuration_fixture
from validation_provenance import LIVE_GROUPS, evidence_current, sampling_evidence_current, utc_now


def sampled_module_inputs_self_test() -> None:
    from validation_inputs import sampled_module_inputs, includes_input
    root = Path(__file__).resolve().parents[1]
    cloud = sampled_module_inputs('icloud')
    assert {'ScheduleSync', 'StorageCore', 'ScorePorts'} <= cloud and 'CommunityUI' not in cloud
    source = root / 'BIT101-iOS/Schedule/ScheduleCloudSyncManager.swift'
    original = Path.read_bytes
    try:
        with patch.object(Path, 'read_bytes', lambda path: original(path) + b'\nimport MapFeature\n' if path == source else original(path)):
            sampled_module_inputs.cache_clear()
            assert 'MapFeature' in sampled_module_inputs('icloud')
    finally: sampled_module_inputs.cache_clear()
    for host in ('network', 'community-writes', 'icloud'): sampled_module_inputs(host)
    assert includes_input('Modules/StorageCore/Sources/AppFileService.swift', 'icloud')
    assert not includes_input('Modules/CommunityUI/Sources/CommunityViews.swift', 'icloud')
    assert includes_input('Modules/CommunityUI/Sources/CommunityViews.swift', 'build-icloud-smoke')


def source_snapshot_self_test() -> None:
    from types import SimpleNamespace
    import validation_provenance as subject
    inputs = {'Package.swift': b'product', 'README.md': b'documentation'}
    reads = []
    def read(path):
        name = path.relative_to(subject.ROOT).as_posix()
        reads.append(name)
        return inputs[name]
    def identity(group, files, context, **kwargs):
        return json.dumps(files, sort_keys=True)
    with patch.object(subject, 'repository_input_names', return_value=list(inputs)) as inventory, \
            patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_bytes', read), \
            patch.object(Path, 'stat', return_value=SimpleNamespace(st_mode=0o644)), \
            patch.object(subject, '_clean_source_identity', return_value=None), patch.object(subject, '_local_source_identity', side_effect=identity):
        with subject.source_snapshot():
            full = subject.input_identity()
            with subject.source_snapshot():
                group = subject.input_identity('modules', environment={})
            assert set(json.loads(full)) == set(inputs) and set(json.loads(group)) == {'Package.swift'}
            inputs['Package.swift'] = b'changed product'
            assert subject.input_identity('modules', environment={}) == group
        assert inventory.call_count == 1 and sorted(reads) == sorted(inputs)
        assert subject.input_identity('modules', environment={}) != group
        assert inventory.call_count == 2 and reads[-1] == 'Package.swift'


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
    with patch.object(subject, 'indexed_test_sources', return_value=facts):
        try: subject.test_selectors.__wrapped__('modules')
        except ValueError as error: assert 'Probe/check' in str(error)
        else: raise AssertionError('模块前缀归一化后的歧义需要进入库存失败')
    directory = subject.ROOT / 'BIT101-iOSTests'
    test_path = directory / 'NetworkClientTests.swift'
    enum_path = subject.ROOT / 'Modules/TransportCore/Sources/SecureURLTransport.swift'
    extension_path = subject.ROOT / 'Modules/ClientCore/Sources/DateFormatters.swift'
    enum = 'enum Fixture { enum Choice: CaseIterable { case first, second; MEMBER } }'
    for member, extension, arguments, accepted in [
            ('', '', 'Fixture.Choice.allCases', True),
            ('var allCases: [Self] { [.first] }', '', 'Fixture.Choice.allCases', True),
            ('func selected() -> [Self] { let allCases = [Choice.first]; return allCases }', '', 'Fixture.Choice.allCases', True),
            ('func selected() { let (first, second) = (Choice.first, Choice.second) }', '', 'Fixture.Choice.allCases', True),
            ('static var allCases: [Self] { [.first] }', '', 'Fixture.Choice.allCases', False),
            ('static let allCases = [Choice.first, Choice.first]', '', 'Fixture.Choice.allCases', False),
            ('', 'extension Fixture.Choice { static var allCases: [Self] { [.second] } }', 'Fixture.Choice.allCases', False),
            ('', 'extension Fixture.Choice { static let allCases = [Fixture.Choice.first] }', 'Fixture.Choice.allCases', False),
            ('static var allCases: [Self] { [.first] }', '', '[Fixture.Choice.first, Fixture.Choice.second]', True)]:
        sources = {test_path: 'import Testing\nstruct Probe { @Test(arguments: ' + arguments + ') func check(_ choice: Fixture.Choice) {} }',
            enum_path: enum.replace('MEMBER', member), extension_path: extension}
        with patch.object(Path, 'rglob', lambda path, pattern: iter([test_path]) if path == directory else original_rglob(path, pattern)), \
                patch.object(Path, 'read_text', lambda path, *args, **kwargs: sources[path] if path in sources else original_read(path, *args, **kwargs)), \
                patch('validation_inputs.repository_input_names', return_value=[path.relative_to(subject.ROOT).as_posix() for path in sources]), \
                patch('validation_inputs.includes_input', return_value=True), patch.object(subject, 'test_inventory', return_value={'Probe/check'}):
            try: inventory = subject.test_case_inventory.__wrapped__('all')
            except ValueError as error:
                assert not accepted and '自动合成 allCases' in str(error), (member, extension, str(error))
            else: assert accepted and inventory == {'Probe/check': 2}, (member, extension, inventory)


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


def run_self_test(recorder) -> None:
    worker_cli_diagnostics_self_test()
    sampled_module_inputs_self_test()
    worker_deployment_self_test(network_trace_fixture)
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
        with patch.object(module, "input_identity", return_value="current"), \
                patch.object(module, "complete_environment", return_value=True), \
                patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "write_report") as saved, \
                patch.object(module, "test_summary", return_value=summary), patch.object(module, "smoke_summary", return_value=summary), \
                patch.object(module, "test_inventory", return_value={"Suite/testRun"}), \
                patch.object(module, "complete_summary", return_value=True), patch.object(module, "environment_context", return_value={}), \
                patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", side_effect=values), \
                patch.object(module.subprocess, "check_output", return_value="head"), \
                patch("validation_performance.bundle_identity", return_value="a" * 64), patch("validation_performance.current_commit", return_value="head"), \
                patch("validation_performance.extract_measurements", return_value={"records": {}}), \
                patch.dict(os.environ, BIT101_VALIDATION_RUN_ID=run_id, BIT101_VALIDATION_STARTED_AT=utc_now().isoformat(),
                    BIT101_VALIDATION_ELAPSED_SECONDS='12.5'), redirect_stderr(StringIO()):
            assert recorder(group, 0, "full", start) == expected, (group, artifact)
            assert saved.call_args.args[0]["groups"][group]["exitCode"] == expected
            assert saved.call_args.args[0]['groups'][group]['durationSeconds'] == 12.5
            if group in {"all", "ui"} and expected == 0:
                assert saved.call_args.args[0]["groups"][group]["resultBundleIdentity"] == "a" * 64
                assert saved.call_args.args[0]["groups"][group]["sourceCommit"] == "head"
    group_row = {"scope": "full", "exitCode": 0, "runID": "run", "inputDigest": "current", "summary": summary,
        "recordedAt": utc_now().isoformat(), "environment": module.environment_context('all')}
    for digest, expected in (("current", 0), ("changed", 1)):
        with patch.object(sys, "argv", ["validation_evidence.py", "check-group", "all"]), \
                patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "complete_summary", return_value=True), \
                patch.object(module, "input_identity", return_value=digest), patch.object(Path, "is_file", return_value=True), \
                patch.object(Path, "read_text", return_value=json.dumps({"groups": {"all": group_row}})), redirect_stderr(StringIO()):
            assert module.main() == expected
    selected = dict(group_row, scope='selected', lastFullRun=group_row)
    for status in (0, 1):
        selected['exitCode'] = status
        with patch.object(sys, 'argv', ['validation_evidence.py', 'check-group', 'all']), \
                patch.object(module, 'report_lock', side_effect=nullcontext), patch.object(module, 'complete_summary', return_value=True), \
                patch.object(module, 'input_identity', return_value='current'), patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_text', return_value=json.dumps({'groups': {'all': selected}})), redirect_stderr(StringIO()):
            assert module.main() == status
    artifact_lock_self_test(module)
    selected_coverage_self_test(module)
    baseline_policy_self_test(module)
    report_budget_self_test(module)
    aggregate_failure_self_test(module)
    complete_run_reuse_self_test(module)
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
          with patch.object(module, "input_identity", return_value="current"), \
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
                'resultBundleIdentity': stored, 'summary': {'passed': True}, 'recordedAt': utc_now().isoformat()}
            report = {'groups': {group: row}}
            with patch.object(module, 'report_lock', side_effect=nullcontext), \
                    patch.object(module, 'input_identity', return_value='current'), \
                    patch.object(module, 'complete_summary', return_value=True), \
                    patch.object(module, 'complete_environment', return_value=True), \
                    patch('validation_coverage.policy_floors', return_value={}), \
                    patch.object(module, 'result_bundle_findings', wraps=result_bundle_findings), \
                    patch('validation_performance.bundle_identity', side_effect=lambda path: raw
                        if raw else (_ for _ in ()).throw(ValueError('absent result bundle'))), \
                    patch.object(Path, 'is_file', return_value=True), \
                    patch.object(Path, 'read_text', return_value=json.dumps(report)), \
                    patch.object(sys, 'argv', ['evidence', 'check-group', group]), redirect_stderr(StringIO()):
                assert module.main() == int(stored != raw)


def check_group_coverage_policy_self_test(module) -> None:
    for group in ('modules', 'all', 'ui', 'catalyst'):
        name = 'GalleryFeature' if group == 'modules' else 'Catalyst/GalleryFeature' if group == 'catalyst' else 'iOS/GalleryFeature'
        for selected in (False, True):
            for floor, covered, expected in ((70, 74, 0), (75, 74, 1), (75, 75, 0)):
                full = {'scope': 'full', 'exitCode': 0, 'runID': 'full', 'inputDigest': 'current',
                    'environment': {}, 'recordedAt': utc_now().isoformat(), 'summary': {'passed': True, 'coverage': {
                        name: {'coveredLines': covered, 'executableLines': 100}}}}
                row = dict(full, scope='selected', lastFullRun=full,
                    summary={'passed': True, 'coverage': {name: {'coveredLines': 100, 'executableLines': 100}}}) if selected else full
                report = {'groups': {group: row}, 'coveragePolicy': {
                    'modules' if group == 'modules' else 'all': {'GalleryFeature': floor}}}
                with patch.object(module, 'input_identity', return_value='current'), \
                        patch.object(module, 'report_lock', side_effect=nullcontext), \
                        patch.object(module, 'complete_summary', return_value=True), \
                        patch.object(module, 'complete_environment', return_value=True), \
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
    for names in ((), ('test-results.xcresult',), ('exported.log',), ('test-results.xcresult', 'exported.log')):
        retained = set(names)
        with patch.object(sys, 'argv', ['validation_artifacts.py', str(module.ROOT)]), \
                patch.dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD='1'), \
                patch.object(Path, 'exists', lambda path: bool(names) and path == diagnostics), \
                patch.object(Path, 'is_dir', return_value=False), \
                patch.object(Path, 'iterdir', lambda path: iter(diagnostics / name for name in tuple(retained)) if path == diagnostics else iter(())), \
                patch.object(Path, 'unlink', lambda path, **kwargs: retained.discard(path.name)), \
                patch.object(Path, 'open', return_value=nullcontext(BytesIO())), \
                patch.object(os, 'walk', return_value=[]), \
                patch.object(fcntl, 'flock', side_effect=BlockingIOError), redirect_stdout(StringIO()):
            status = 0
            namespace = {'__name__': 'artifact_cleanup_fixture'}
            try:
                exec(compile(source, 'validation_artifacts.py', 'exec'), namespace)
                namespace['clear_diagnostic_exports'](diagnostics)
            except SystemExit as error: status = error.code
            assert status == 0 and retained == set(names) - {'exported.log'}, '诊断导出清理保留原始编译失败包'
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
    report = {'coverageBaseCommit': 'target', 'coveragePolicy': {'modules': {'Feature': 80}, 'all': {'Feature': 70, 'BIT101-iOS.app': 60}},
        'groups': {}}
    for fault in ('none', 'commit', 'missing', 'missing-app', 'value', 'extra'):
        candidate = json.loads(json.dumps(report))
        if fault == 'commit': candidate['coverageBaseCommit'] = 'other'
        if fault == 'missing': candidate['coveragePolicy'].pop('all')
        if fault == 'missing-app': candidate['coveragePolicy']['all'].pop('BIT101-iOS.app')
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
        summary['testCases'] = {'passed': True, 'total': 1, 'byTest': {'Suite/testRun': 1}, 'expectedByTest': {'Suite/testRun': 1},
            'destinations': [{'platform': 'iOS', 'deviceIdentifier': 'fixture-device'}], 'identifiersByTest': {'Suite/testRun': ['test://com.apple.xcode/BIT101-iOS/BIT101-iOSTests/Suite/testRun']}}
        with patch.object(module, "input_identity", return_value="digest"), patch.object(module, "complete_environment", return_value=True), \
                patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "write_report") as saved, \
                patch.object(module, "test_summary", return_value=summary), patch.object(module, "complete_summary", return_value=True), \
                patch.object(module, 'test_case_inventory', return_value={'Suite/testRun': 1}), \
                patch.object(module, 'test_inventory', return_value={'Suite/testRun'}), \
                patch.object(Path, "is_file", return_value=True), \
                patch.object(Path, "read_text", side_effect=['验证输入：digest\n验证运行：run\n', json.dumps(report)]), \
                patch.object(subprocess, "check_output", return_value="head"), \
                patch("validation_performance.bundle_identity", return_value="a" * 64), patch("validation_performance.current_commit", return_value="head"), \
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


def aggregate_failure_self_test(module) -> None:
    from script_test_support import shell_function
    support = module.ROOT / 'Scripts/script-support.sh'
    step = shell_function(support, 'bit101_check_verification_audit') + '\n' + shell_function(support, 'bit101_verify_step')
    for command_status, evidence_status in ((0, 0), (7, 0), (0, 7)):
        harness = f'''ROOT_DIR=/repo
SECONDS=0
completed_result_groups=()
command() {{ return {command_status}; }}
python3() {{ if [[ "$2" == check-group ]]; then return {evidence_status}; fi; return 0; }}
'''
        result = subprocess.run(["zsh", "-c", harness + step + "\nbit101_verify_step all command\nprint next-group"], capture_output=True, text=True)
        assert (result.returncode == 0) == (command_status == evidence_status == 0)
        assert ("next-group" in result.stdout) == (result.returncode == 0)


def complete_run_reuse_self_test(module=None) -> None:
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
    if module is None: return
    full = dict(full, environment={})
    report = {'groups': {'network': full}}
    for status, scope, reusable in ((0, 'selected', True), (1, 'selected', False), (0, 'selected', False), (0, 'full', True)):
        with patch.object(module, 'input_identity', return_value='same'), patch.object(module, 'environment_context', return_value={}), \
                patch.object(module, 'complete_environment', return_value=True), patch.object(module, 'report_lock', side_effect=nullcontext), \
                patch.object(module, 'write_report') as saved, patch.object(module, 'smoke_summary', return_value={'passed': True}), \
                patch.object(module, 'complete_summary', return_value=True), patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_text', side_effect=[json.dumps({'runID': 'fixture'}), json.dumps(report)]), \
                patch.object(module.subprocess, 'check_output', return_value='head'), \
                patch.dict(os.environ, BIT101_VALIDATION_RUN_ID='fixture'), redirect_stderr(StringIO()):
            assert module.record('network', status, scope, 'same') == status
        report = saved.call_args.args[0]
        row = report['groups']['network']
        assert (complete_group_row(row).get('scope') == 'full') == reusable, row


def community_recovery_contract_self_test() -> None:
    from copy import deepcopy
    from network_request_contracts import cleanup_requests_complete, complete
    source = (Path(__file__).resolve().parents[1] / 'BIT101-iOSTests/NetworkSessionIsolationTests.swift').read_text()
    fixture = json.loads(re.search(r'static let recovery = #"""(.*?)"""#', source, re.DOTALL)[1])
    def evidence(row):
        value = {key: item for key, item in row.items() if key != 'responseBody'}
        value.update(finalMethod=row['method'], finalEndpoint=row['endpoint'], finalQuery=dict(row['query']))
        return value
    accepted = [evidence(row) for row in fixture['accepted']]
    assert cleanup_requests_complete(accepted)
    from validation_provenance import network_requests_complete
    cleanup = network_trace_fixture({'scope': 'community-cleanup', 'requiredProbes': ['community.login', 'community.writes']})
    assert network_requests_complete(set(cleanup['requiredProbes']), cleanup | {'requestEvidenceRequired': True})
    missing = dict(cleanup, requestEvidence=cleanup['requestEvidence'][:1], requestEvidenceRequired=True)
    assert not network_requests_complete(set(cleanup['requiredProbes']), missing)
    assert not cleanup_requests_complete(accepted[1:])
    writes = network_trace_fixture({'requiredProbes': ['community.writes']})['requestEvidence'][0]['requests']
    assert complete('community.writes', writes + accepted)
    assert not cleanup_requests_complete(accepted + writes)
    for row in fixture['rejected']:
        assert not cleanup_requests_complete(accepted + [evidence(row)])
        assert not complete('community.writes', writes + [evidence(row)])
    for index, row in enumerate(accepted):
        if row.get('responseContentMissing') is not True: continue
        altered = deepcopy(accepted)
        altered[index].pop('responseContentMissing')
        assert not cleanup_requests_complete(altered)
        assert not complete('community.writes', writes + [altered[index]])


def network_trace_fixture(value: dict) -> dict:
    from network_request_contracts import community, contracts_for, SELECTORS, VISIBLE_PARAMETERS
    value['workerDeployments'] = worker_deployment_fixture(value.get('scope'))
    def example(pattern, identifier=1):
        import re
        pattern = re.sub(r'\(\?:([^()]*)\)', lambda match: match[1].split('|')[0], pattern)
        return pattern.replace('[0-9a-f]+', 'a').replace(r'[1-9]\d*', str(identifier)).replace(r'\d+', str(identifier)).replace(r'\.', '.').replace(r'\-', '-').replace(r'\+', '+').replace(r'\{', '{').replace(r'\}', '}').replace('.+', 'fixture').replace('?', '')
    rows = []
    for name in value.get('requiredProbes', []):
        requests = []
        expected = {'XNXQDM': value.get('validatedTerm', 'fixture-current')} if name in {'schedule.sync', 'classroom.occupancy'} else {}
        if name in {'gallery.search', 'course.search', 'paper.search'}:
            expected = {'search': 'fixture', 'excludedSearch': 'excludedfixture'}
        contracts = [community('/user/info/0'), community(r'/posters/\d+', method='DELETE')] if value.get('scope') == 'community-cleanup' and name == 'community.writes' else contracts_for(name, expected)
        assert contracts, name
        if name == 'classroom.occupancy':
            year, _, semester = expected['XNXQDM'].rpartition('-')
            expected.update(JXLDM='fixture-building', RQ='2026-09-07', XQDM=semester, XNDM=year)
        for contract in contracts:
            for index in range(max(contract.minimum, 2 if contract.paging else 1)):
                query = {key: example(pattern) if key in VISIBLE_PARAMETERS else '[REDACTED]'
                    for key, pattern in contract.query.items() if pattern is not None}
                query.update({key: item for key, item in expected.items() if key not in {'path', 'excludedSearch'} and (key != 'search' or 'excludedSearch' not in expected) and (name != 'gallery.search' or contract.query.get(key) is not None)})
                if contract.paging == 'page': query['page'] = str(index)
                if contract.paging == 'last_id': query['last_id'] = str(sys.maxsize) if index == 0 else '9'
                request = {'method': contract.method, 'endpoint': 'https://' + example(contract.host) + example(contract.path),
                    'statusCode': next(iter(contract.statuses)), 'query': query,
                    'bodyParameterNames': sorted(contract.required_body_parameters | (contract.body_parameter_variants[0] if contract.body_parameter_variants else frozenset())),
                    'finalBodyParameterNames': sorted(contract.required_body_parameters | (contract.body_parameter_variants[0] if contract.body_parameter_variants else frozenset()))}
                if contract.paging == 'last_id': request['responseMinimumID'] = '9' if index == 0 else '1'
                if name in {'eclass.authentication', 'eclass.ddl'}:
                    query['page'] = '1'
                    request.update(responseCourseIDs=[], responseCoursePage={'page': 1, 'pages': 1})
                if name == 'update.emergency': request['responseConfiguration'] = emergency_configuration_fixture()
                if name == 'community.writes':
                    if contract.path == '/posters' and contract.method == 'GET': query['page'] = str(index)
                    if contract.path == '/reaction/like' and query['obj'].startswith('comment'):
                        query['obj'] = 'comment' + str(index // 2 + 1)
                    if contract.method == 'DELETE' and contract.path == r'/reaction/comments/\d+':
                        request['endpoint'] = 'https://' + example(contract.host) + example(contract.path, index + 1)
                    if contract.method == 'POST' and contract.path == '/reaction/comments' and query['obj'].startswith('comment'):
                        query['obj'] = 'comment' + str(index // 2 + 1)
                        for field in ('bodyParameterNames', 'finalBodyParameterNames'): request[field] += ['reply_obj', 'reply_uid'] if index % 2 else []
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
    native_school_request_contracts_self_test()
    community_recovery_contract_self_test()
    image_resource_self_test()
    from copy import deepcopy
    from validation_provenance import network_requests_complete
    from network_request_contracts import CONTRACTS, contracts_for, complete
    unread = {'method': 'GET', 'finalMethod': 'GET', 'statusCode': 200,
        'endpoint': 'https://bit101.flwfdd.xyz/messages/unread_nums',
        'finalEndpoint': 'https://bit101.flwfdd.xyz/messages/unread_nums', 'query': {}, 'finalQuery': {}}
    assert complete('message.unread', [unread])
    assert not complete('message.unread', [dict(unread, endpoint='https://bit101.flwfdd.xyz/messages',
        finalEndpoint='https://bit101.flwfdd.xyz/messages', query={'type': 'unread'}, finalQuery={'type': 'unread'})])
    assert all(contracts_for(probe) == contracts for probe, contracts in CONTRACTS.items())
    for probe in CONTRACTS:
        trace = network_trace_fixture({'scope': 'all', 'requiredProbes': [probe]})['requestEvidence'][0]
        assert complete(probe, trace['requests'], trace['expectedParameters']), probe
        for field in ('bodyParameterNames', 'finalBodyParameterNames'):
            altered = deepcopy(trace['requests'])
            altered[0][field] = ['unexpected_filter']
            assert not complete(probe, altered, trace['expectedParameters']), (probe, field)
        for contract in contracts_for(probe):
            sample = next((row for row in trace['requests'] if contract.matches(row)), None)
            if sample is None: continue
            allowed = sorted((contract.body_parameters | contract.required_body_parameters) - set().union(*contract.body_parameter_variants)
                | (contract.body_parameter_variants[0] if contract.body_parameter_variants else set()))
            assert contract.matches(dict(sample, bodyParameterNames=allowed, finalBodyParameterNames=allowed))
            if allowed:
                assert not contract.matches(dict(sample, bodyParameterNames=allowed + allowed[:1]))
            for field in ('bodyParameterNames', 'finalBodyParameterNames'):
                if contract.required_body_parameters:
                    assert not contract.matches(dict(sample, **{field: []}))
                for name in contract.required_body_parameters:
                    assert not contract.matches(dict(sample, **{field: sorted(set(sample[field]) - {name})}))
                for names, valid in (({'challenge_id'}, True), ({'username', 'password'}, True),
                        (set(), False), ({'username'}, False), ({'password'}, False), ({'challenge_id', 'username'}, False)):
                    if contract.body_parameter_variants and {'challenge_id', 'username', 'password'} <= contract.body_parameters:
                        assert contract.matches(dict(sample, **{field: sorted(contract.required_body_parameters | names)})) == valid
    from network_request_contracts import complete as check_complete
    emergency = network_trace_fixture({'requiredProbes': ['update.emergency']})['requestEvidence'][0]['requests']
    assert check_complete('update.emergency', emergency)
    for configuration in (None, {}, {'content': 'bad', 'enabled': False}, emergency_configuration_fixture(True),
                          emergency_configuration_fixture(True, ' '), emergency_configuration_fixture() | {'enabled': True}):
        assert not check_complete('update.emergency', [dict(emergency[0], responseConfiguration=configuration)])
    assert check_complete('update.emergency', [dict(emergency[0], responseConfiguration=emergency_configuration_fixture(True, 'maintenance'))])
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
        changed['requestEvidence'][0]['requests'] = rows + [deepcopy(row) for row in original if row['query'].get('order') != original[0]['query'].get('order')]
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
    for invalid in ('0', '999', None):
        changed = deepcopy(cursor_probe['requests'])
        changed[0]['responseMinimumID'] = invalid
        assert not complete(cursor_probe['probe'], changed)
    for invalid in ('0', '9', '10', None):
        changed = deepcopy(cursor_probe['requests'])
        changed[1]['responseMinimumID'] = invalid
        assert not complete(cursor_probe['probe'], changed), invalid
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
        request = network_trace_fixture({'requiredProbes': [probe]})['requestEvidence'][0]['requests'][0]
        request.update(endpoint=endpoint, finalEndpoint=endpoint)
        assert complete(probe, [request]), probe
        assert not complete(probe, [dict(request, method='GET')]), probe
    for probe in ('eclass.authentication', 'eclass.ddl'):
        page = {'method': 'POST', 'endpoint': 'https://zy-eclass.bit.edu.cn/api/my-courses',
            'statusCode': 200, 'query': {'page': '1', 'page_size': '100', 'fields': 'id,name', 'conditions': '{}'}, 'bodyParameterNames': ['page', 'page_size', 'fields', 'conditions'],
            'finalBodyParameterNames': ['page', 'page_size', 'fields', 'conditions'],
            'responseCourseIDs': ['41', '43'], 'responseCoursePage': {'page': 1, 'pages': 1}}
        activities = [dict(page, method='GET', query={}, bodyParameterNames=[], finalBodyParameterNames=[],
            endpoint=f'https://zy-eclass.bit.edu.cn/api/courses/{value}/activities') for value in (41, 43)]
        assert complete(probe, [page] + activities)
        for key, value in (('page_size', '1'), ('fields', 'id'), ('conditions', '[REDACTED]')):
            for field in ('query', 'finalQuery'):
                assert not complete(probe, [dict(page, **{field: {**page['query'], key: value}})] + activities)
                assert not complete(probe, [dict(page, **{field: {name: value for name, value in page['query'].items() if name != key}})] + activities)
        for rows in ([page], [page, activities[0]], [dict(page, responseCourseIDs=None)] + activities,
                     [dict(page, responseCourseIDs=['0'])] + activities,
                     [page] + activities + [dict(activities[0], endpoint='https://zy-eclass.bit.edu.cn/api/courses/45/activities')],
                     [page, activities[0], dict(activities[1], finalEndpoint=activities[0]['endpoint'])]):
            assert not complete(probe, rows), (probe, rows)
        two_pages = [dict(page, responseCourseIDs=['41'], responseCoursePage={'page': 1, 'pages': 2}),
            dict(page, query={**page['query'], 'page': '2'}, responseCourseIDs=['43'], responseCoursePage={'page': 2, 'pages': 2})]
        assert complete(probe, two_pages + activities)
        for metadata in (None, {'page': 99, 'pages': 1}, {'page': 1, 'pages': 2}, {'page': 1, 'pages': True}):
            assert not complete(probe, [dict(page, responseCoursePage=metadata)] + activities)
        for rows in (two_pages[:1], two_pages[1:], two_pages[::-1], [two_pages[0], two_pages[0]]):
            assert not complete(probe, rows + activities)
        assert not complete(probe, [dict(page, query={'page': '99'})] + activities)
        assert complete(probe, [dict(page, responseCoursePage={})] + activities)
        assert not complete(probe, [dict(page, responseCourseIDs=[str(value) for value in range(1, 101)], responseCoursePage={})] + activities)
        assert complete(probe, [dict(page, responseCourseIDs=[])])
    building = {'method': 'GET', 'endpoint': 'https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do',
        'statusCode': 200, 'query': {'XXXQDM': 'campus'}}
    assert complete('classroom.buildings', [building], {'XXXQDM': 'campus'})
    assert not complete('classroom.buildings', [building])
    for query in ({}, {'XXXQDM': 'other'}):
        assert not complete('classroom.buildings', [dict(building, query=query)], {'XXXQDM': 'campus'})
        assert not complete('classroom.buildings', [dict(building, finalQuery=query)], {'XXXQDM': 'campus'})
    for probe in ('gallery.search', 'course.search', 'paper.search'):
        trace = network_trace_fixture({'scope': 'bit101', 'requiredProbes': [probe]})['requestEvidence'][0]
        rows, selected = trace['requests'], trace['expectedParameters']
        assert complete(probe, rows, selected)
        assert network_requests_complete({probe}, {'requestEvidenceRequired': True, 'requestEvidence': [trace]})
        assert not complete(probe, rows, {})
        assert not complete(probe, rows[:1], selected)
        for keyword in selected.values():
            assert not complete(probe, [row for row in rows if row['query'].get('search') != keyword], selected)
        assert not complete(probe, rows, dict(selected, excludedSearch=selected['search']))
        for field in ('query', 'finalQuery'):
            for keyword in ('', 'wrong keyword', None):
                changed = deepcopy(rows)
                for row in changed:
                    if keyword is None: row[field].pop('search', None)
                    else: row[field]['search'] = keyword
                assert not complete(probe, changed, selected), (probe, field, keyword)
    variants = {
        'gallery.newest': {'mode': 'search', 'order': 'new', 'uid': '-1'},
        'gallery.following': {'mode': 'follow'}, 'gallery.hot': {'mode': 'hot'}, 'gallery.recommend': {},
        'gallery.bots': {'mode': 'search', 'order': 'new', 'uid': '-1'},
        'gallery.search': {'mode': 'search', 'order': 'new', 'uid': '-1', 'search': 'BIT101'},
        'paper.list.newest': {}, 'paper.list.like': {'order': 'like'},
        'paper.list.comment': {'order': 'comment'},
    }
    for probe, parameters in variants.items():
        endpoint = 'https://bit101.flwfdd.xyz/' + ('papers' if probe.startswith('paper.') else 'posters')
        queries = [dict(parameters, order=order) for order in ('new', 'similar', 'like')] if probe == 'gallery.search' else [parameters]
        if probe == 'gallery.search': queries += [dict(query, search='excludedfixture') for query in queries]
        if probe == 'gallery.search': queries += [{key: value for key, value in dict(parameters, order=order).items() if key != 'search'} for order in ('new', 'like')]
        requests = [{'method': 'GET', 'endpoint': endpoint, 'statusCode': 200,
                     'query': dict(query, page=str(page))} for query in queries for page in (0, 1)]
        assert complete(probe, requests, {'search': 'BIT101', 'excludedSearch': 'excludedfixture'} if probe == 'gallery.search' else None), probe
        if probe == 'gallery.search': assert not complete(probe, requests[:6], {'search': 'BIT101', 'excludedSearch': 'excludedfixture'})
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
    for probe, endpoint in [('web.share-icon', 'https://open.aihelpme.dev/share-icon.jpg'),
                            ('web.association', 'https://open.aihelpme.dev/.well-known/apple-app-site-association'),
                            ('lexue.ddl', 'https://lexue.bit.edu.cn/calendar/export_execute.php')]:
        row = {'method': 'GET', 'endpoint': endpoint, 'statusCode': 200, 'query': {}}
        assert complete(probe, [row])
        for field in ('endpoint', 'finalEndpoint'):
            altered = endpoint[:endpoint.index('/', 8)] + endpoint[endpoint.index('/', 8):].replace('.', 'X')
            assert not complete(probe, [dict(row, **{field: altered})]), (probe, field)
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
        rows = network_trace_fixture({'requiredProbes': [probe], 'validatedTerm': expected['XNXQDM']})['requestEvidence'][0]['requests']
        for row, path in zip(rows, paths): row.update(endpoint='https://jxzxehallapp.bit.edu.cn' + path, finalEndpoint='https://jxzxehallapp.bit.edu.cn' + path, query=dict(expected), finalQuery=dict(expected))
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
                assert not complete(probe, [dict(row, query=changed, finalQuery=changed) for row in rows], changed), key
    login = {'method': 'GET', 'endpoint': 'https://bit101.flwfdd.xyz/user/check', 'statusCode': 200, 'query': {}}
    paper = dict(login, endpoint='https://bit101.flwfdd.xyz/papers/17')
    comments = [dict(login, endpoint='https://bit101.flwfdd.xyz/reaction/comments',
        query={'obj': 'paper17', 'order': order, 'page': str(page)}) for order in ('new', 'old', 'like') for page in (0, 1)]
    assert not complete('paper.comments', [login] + comments[:2], {'obj': 'paper17'})
    for probe, requests, selectors in [
        ('paper.detail', [login, paper], {'path': '/papers/17'}),
        ('paper.comments', [login, comments[0], login] + comments[1:], {'obj': 'paper17'}),
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
    authentication = dict(login, method='POST', endpoint='https://bit101.flwfdd.xyz/user/webvpn_verify', **{field: ['sid', 'password', 'execution', 'cookie', 'salt', 'captcha'] for field in ('bodyParameterNames', 'finalBodyParameterNames')})
    assert complete('community.login', [dict(login, statusCode=401), authentication, login])
    assert not complete('community.login', [dict(login, statusCode=401), dict(authentication, statusCode=500), login])
    teaching = {'method': 'GET', 'endpoint': 'https://jxzxehallapp.bit.edu.cn/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do', 'statusCode': 200, 'query': {}}
    preheat = dict(teaching, endpoint='https://jxzxehallapp.bit.edu.cn/jwapp/i18n.do', query={'appName': 'wdkbby', 'EMAP_LANG': 'zh'})
    for query in ({'appName': 'other', 'EMAP_LANG': 'zh'}, {'appName': 'wdkbby', 'EMAP_LANG': 'en'}, {}):
        assert not complete('schedule.current-term', [dict(preheat, query=query), teaching])
    gate = dict(teaching, endpoint='https://sso.bit.edu.cn/gate/cas-success/', statusCode=401, query={'ticket': '[REDACTED]'})
    assert complete('eclass.authentication', [gate] + network_trace_fixture({'requiredProbes': ['eclass.authentication']})['requestEvidence'][0]['requests'])
    lexue = network_trace_fixture({'requiredProbes': ['lexue.calendar']})['requestEvidence'][0]['requests']
    vpn = dict(teaching, endpoint='https://webvpn.bit.edu.cn/https/a/', finalEndpoint='https://webvpn.bit.edu.cn/https/b/cas/login', finalQuery={'service': '[REDACTED]'})
    assert complete('lexue.calendar', [vpn] + lexue)
    assert not complete('lexue.calendar', [dict(vpn, finalEndpoint='https://example.invalid/cas/login')] + lexue)
    cookies = dict(authentication, endpoint='https://login.bit101.flwfdd.xyz/api/jxzxehall/cookies', **{field: ['username', 'password'] for field in ('bodyParameterNames', 'finalBodyParameterNames')})
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
    for field in ('query', 'finalQuery'):
        for value in (None, 'true', '0', '[REDACTED]'):
            broken = deepcopy(transcript['requests'])
            request = next(row for row in broken if row['endpoint'].endswith('/cjd/cookies'))
            query = dict(request.get(field, request['query']))
            if value is None: query.pop('detailed', None)
            else: query['detailed'] = value
            request[field] = query
            assert not complete('score.transcript', broken)
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


def native_school_request_contracts_self_test() -> None:
    from network_request_contracts import complete, auxiliary_contracts, NATIVE_CONTRACTS
    def request(path, *, host='jwms.bit.edu.cn', method='GET', status=200, body=(), query=None):
        endpoint = 'https://' + host + path
        return dict(endpoint=endpoint, finalEndpoint=endpoint, method=method, finalMethod=method,
            statusCode=status, query=query or {}, finalQuery=query or {}, bodyParameterNames=list(body), finalBodyParameterNames=list(body))
    landing = request('/jsxsd/framework/main.jsp')
    grades = request('/jsxsd/kscj/cjcx_list', method='POST', body=('kksj', 'kcxz', 'kcmc', 'xsfs'))
    detail = request('/jsxsd/kscj/cjpm_list.do', query={'id': '[REDACTED]'})
    cas = request('/cas/login', host='sso.bit.edu.cn', status=302, query={'service': '[REDACTED]'})
    assert complete('score.authentication', [cas, landing])
    assert complete('score.brief', [grades])
    assert complete('score.detail', [grades, detail])
    session_redirect = request('/http/abcdef/;jsessionid=fixture-session', host='webvpn.bit.edu.cn', status=302)
    assert complete('score.authentication', [session_redirect, landing])
    assert not complete('score.authentication', [session_redirect])
    analysis = request('/http/abcdef/jsxsd/kscj/cjfx', host='webvpn.bit.edu.cn', query={'kch': '[REDACTED]'})
    assert complete('score.detail', [grades, analysis])
    assert complete('score.detail', [analysis])
    assert not complete('score.detail', [dict(analysis, statusCode=500)])
    assert not complete('score.detail', [dict(analysis, finalEndpoint='https://outside.invalid/score')])
    for probe in ('school.session', 'schedule.teaching-center'):
        trace = network_trace_fixture({'requiredProbes': [probe]})['requestEvidence'][0]
        callbacks = [request('/auth-protocol-core/loginSuccess', host='jxzxehall.bit.edu.cn', status=302),
            request('/jwapp/sys/wdkbby/*default/index.do', host='jxzxehallapp.bit.edu.cn', status=302),
            request('/jwapp/sys/wdkbby/*default/index.do', host='jxzxehallapp.bit.edu.cn')]
        assert complete(probe, trace['requests'] + callbacks, trace['expectedParameters'])
        assert not complete(probe, trace['requests'] + [dict(callbacks[0], finalEndpoint='https://outside.invalid/callback')], trace['expectedParameters'])
    for probe in ('score.brief', 'score.detail'):
        assert not complete(probe, [dict(grades, bodyParameterNames=['xsfs'])])
        assert not complete(probe, [dict(grades, finalBodyParameterNames=['xsfs'])])
        assert not complete(probe, [dict(grades, statusCode=500)])
        assert not complete(probe, [request('/jsxsd/kscj/cjcx_list', host='outside.invalid', method='POST', body=('kksj', 'kcxz', 'kcmc', 'xsfs'))])
    assert not complete('score.detail', [detail])
    entry = request('/cjd/Account/ExternalLogin', host='jwb.bit.edu.cn', status=302)
    report = request('/cjd/ScoreReport2/Index', host='jwb.bit.edu.cn', query={'GPA': '1'})
    page = request('/cjd/Temp/page.jpg', host='jwb.bit.edu.cn')
    assert complete('score.transcript', [entry, cas, report, page])
    assert not complete('score.transcript', [entry, cas, report, dict(page, statusCode=500)])
    assert not complete('score.transcript', [entry, cas, dict(report, query={'GPA': '0'}), page])
    risk = next(contract for contract in auxiliary_contracts('score.authentication', NATIVE_CONTRACTS['score.authentication'])
        if contract.path == '/ustc-rba-front/fp')
    fingerprint = request(risk.path, host='sso.bit.edu.cn', method='POST', status=404, body=risk.body_parameters)
    assert complete('score.authentication', [fingerprint, cas, landing])
    assert not complete('score.authentication', [dict(fingerprint, statusCode=500), cas, landing])
    assert not complete('score.authentication', [fingerprint, cas])
    courses = network_trace_fixture({'requiredProbes': ['eclass.authentication']})['requestEvidence'][0]['requests']
    index = request('/user/index', host='zy-eclass.bit.edu.cn')
    redirected = dict(index, finalEndpoint='https://sso.bit.edu.cn/cas//login', finalQuery={'service': '[REDACTED]'})
    sms = request('/cas//login', host='sso.bit.edu.cn', method='POST', body=('username', 'password', 'type', 'trustDevice'),
        query={'service': '[REDACTED]', 'type': 'smsLogin'})
    sms.update(finalEndpoint=index['endpoint'], finalMethod='GET', finalQuery={}, finalBodyParameterNames=[])
    recovered = [dict(courses[0], statusCode=401), redirected, sms, index] + courses
    assert complete('eclass.authentication', recovered, allow_sms=True)
    assert not complete('eclass.authentication', recovered)
    assert not complete('eclass.authentication', [redirected, sms, index], allow_sms=True)
    assert not complete('eclass.authentication', [dict(sms, finalEndpoint='https://outside.invalid/')] + courses, allow_sms=True)


def worker_cli_diagnostics_self_test() -> None:
    from validation_provenance import worker_cli_json, workflow_elapsed_seconds, WORKER_LOG
    result = subprocess.CompletedProcess([], 1, '', 'ERROR: fixture authentication requires a configured credential\n')
    with patch.object(subprocess, 'run', return_value=result):
        try: worker_cli_json('ErrorReportWorker', 'deployments', 'status')
        except ValueError as error:
            assert 'fixture authentication' in str(error) and str(WORKER_LOG) in str(error)
        else: raise AssertionError('CLI failure needs its actionable diagnostic')
    for value, expected in [('0', 0), ('12.5', 12.5), ('nan', None), ('-1', None)]:
        with patch.dict(os.environ, BIT101_VALIDATION_ELAPSED_SECONDS=value):
            if expected is None:
                try: workflow_elapsed_seconds()
                except ValueError: pass
                else: raise AssertionError('Workflow timing requires finite nonnegative seconds')
            else: assert workflow_elapsed_seconds() == expected
