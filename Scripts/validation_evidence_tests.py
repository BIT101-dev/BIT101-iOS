"""Regression contracts for evidence inputs, inventories and release summaries."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from swift_source_index import swift_syntax_index_sources

def icloud_stage_fixture(stage: str, counts: dict) -> dict:
    return dict(counts, stage=stage, runID='fixture', executedTests=['ICloudCrossDeviceSmokeTests/' + stage],
        testTargets=['BIT101-iOSTests'], destination={'platform': 'macOS' if stage.startswith('testMac') else 'iOS', 'deviceIdentifier': 'phone'})

def run_self_test(subject) -> int:
    from validation_compilation import self_test as compilation_cache_self_test
    compilation_cache_self_test()
    module_events_self_test(subject)
    network_route_identity_self_test()
    module_name = subject.__name__
    original_is_file = Path.is_file
    from unittest.mock import patch
    from validation_environment import host_environment
    from validation_environment import ci_commit_findings
    with patch.dict(os.environ, GITHUB_SHA='a' * 40):
        assert ci_commit_findings('a' * 40) == []
        assert ci_commit_findings('b' * 40)
    with patch.dict(os.environ, GITHUB_SHA='', GITHUB_ACTIONS='true'):
        assert ci_commit_findings('a' * 40)
    selected_compiler = '/fixture/Xcode/Toolchains/selected/usr/bin/swift-frontend'
    with patch.dict(os.environ, SWIFT_FRONTEND='/other/swift-frontend', SWIFT='/other/swift'), \
            patch.object(subprocess, 'check_output', return_value=selected_compiler) as lookup, patch.object(Path, 'is_file', return_value=False):
        assert host_environment.__wrapped__()['compiler']['path'] == selected_compiler
        lookup.assert_called_once_with(['xcrun', '--find', 'swift-frontend'], text=True)
    from validation_inputs import self_test as input_self_test
    fixture_environment = {'host': {'system': 'fixture'}, 'developer': '/fixture', 'xcode': {'version': 'fixture'}, 'compiler': {'path': '/fixture/swift-frontend', 'modified': 1, 'size': 100, 'sha256': 'a' * 64}, 'sdks': {'fixture': {'Version': '1'}}, 'device': {'identifier': 'fixture-phone', 'systemVersion': 'fixture-os', 'systemBuild': 'fixture-build'}}
    with patch(f'{module_name}.environment_context', return_value=fixture_environment), \
            patch('validation_merge.environment_context', return_value=fixture_environment), \
            patch('validation_merge.performance_findings', return_value=[]):
        from validation_provenance_tests import run_self_test as provenance_self_test
        from validation_test_areas import inventory_findings
        provenance_self_test(subject.record)
        from validation_manual_tests import run_self_test as manual_self_test, captured_fixture, distribution_fixture
        manual_self_test()
        from validation_restore import self_test as restore_self_test
        restore_self_test()
        from validation_coverage import self_test as coverage_self_test
        coverage_self_test()
        from ci_evidence import self_test as ci_evidence_self_test
        ci_evidence_self_test()
        from validation_publication import self_test as publication_self_test
        publication_self_test()
        from validation_merge import findings as merge_findings
        from validation_provenance import utc_now
        core = {'mergeCommit': 'commit', 'groups': {name: {'exitCode': 0, 'scope': 'full', 'summary': {},
            'inputDigest': 'digest', 'environment': fixture_environment, 'recordedAt': utc_now().isoformat()} for name in ('all', 'release-runtime', 'ui', 'restore')}}
        core['groups']['restore']['summary'] = {'runID': 'run', 'inputDigest': 'digest'}
        core['groups']['restore']['runID'] = 'run'
        assert not merge_findings(core, digest=lambda *args, **kwargs: 'digest', complete=lambda *args: True, commit='commit')
        with patch('validation_merge.performance_findings', return_value=['性能退化']):
            assert merge_findings(core, digest=lambda *args, **kwargs: 'digest', complete=lambda *args: True, commit='commit') == ['性能退化']
        for name in core['groups']:
            broken = json.loads(json.dumps(core))
            broken['groups'][name]['exitCode'] = 1
            assert merge_findings(broken, digest=lambda *args, **kwargs: 'digest', complete=lambda *args: True, commit='commit')
        assert merge_findings(core, digest=lambda *args, **kwargs: 'changed', complete=lambda *args: True, commit='commit')
        assert merge_findings(core, digest=lambda *args, **kwargs: 'digest', complete=lambda *args: True, commit='other')
        current_digest = lambda group, *, environment=None: 'digest' if environment else 'new-environment'
        assert merge_findings(core, digest=current_digest, complete=lambda *args: True, commit='commit')
        assert not merge_findings(core, digest=current_digest, complete=lambda *args: True, commit='commit', recorded_environment=True)
        relocated = dict(fixture_environment, host={'system': 'other-host'}, developer='/other/Xcode', device=None,
            compiler=dict(fixture_environment['compiler'], path='/other/swift-frontend', modified=2))
        with patch('validation_merge.environment_context', return_value=relocated):
            assert not merge_findings(core, digest=current_digest, complete=lambda *args: True, commit='commit', recorded_environment=True)
        for field, value in (('compiler', dict(fixture_environment['compiler'], sha256='b' * 64)),
                ('sdks', {'fixture': {'Version': '2'}}), ('xcode', {'version': 'other'})):
            with patch('validation_merge.environment_context', return_value=dict(fixture_environment, **{field: value})):
                assert any('当前 CI' in error for error in merge_findings(core, digest=current_digest,
                    complete=lambda *args: True, commit='commit', recorded_environment=True))
        for name in core['groups']:
            mixed = json.loads(json.dumps(core))
            mixed['groups'][name]['environment']['sdks'] = {'fixture': {'Version': '2'}}
            assert merge_findings(mixed, digest=current_digest, complete=lambda *args: True, commit='commit', recorded_environment=True)
        from contextlib import nullcontext, redirect_stderr
        from io import StringIO
        for accepted_commit, expected in (('commit', 0), ('other', 1)):
            with patch.object(sys, 'argv', ['validation_evidence.py', 'check-merge', '--recorded-environment']), \
                    patch.object(subject, 'report_lock', side_effect=nullcontext), \
                    patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_text', return_value=json.dumps(core)), \
                    patch.object(subprocess, 'check_output', return_value=accepted_commit), \
                    patch.object(subject, 'source_digest', return_value='digest'), \
                    patch.object(subject, 'complete_summary', return_value=True), redirect_stderr(StringIO()):
                assert subject.main() == expected
        from ui_inventory import self_test as ui_inventory_self_test
        ui_inventory_self_test()
        all_suites = {test.split('/', 1)[0] for test in subject.test_inventory('all')}
        assert inventory_findings(all_suites) == []
        assert inventory_findings(all_suites | {'NewFeatureTests'})
        for group in ('infrastructure', 'login'):
            assert any((test.startswith('SchoolCookieIsolationTests/') for test in subject.test_inventory(group)))
        with patch.object(sys, 'argv', ['validation_evidence.py', 'record', 'audit', '7']), patch.dict(os.environ, BIT101_VALIDATION_SOURCE_DIGEST='fixture-input'), patch(f'{module_name}.record', return_value=7) as recorder:
            assert subject.main() == 7
            recorder.assert_called_once_with('audit', 7, 'full', 'fixture-input')
        input_self_test()
        from validation_environment import toolchain_identity
        compiler = fixture_environment['compiler']
        relocated = dict(compiler, path='/other-host/swift-frontend', modified=2)
        assert toolchain_identity(fixture_environment) == toolchain_identity(dict(fixture_environment, compiler=relocated))
        assert toolchain_identity(fixture_environment) != toolchain_identity(dict(fixture_environment, compiler=dict(compiler, sha256='b' * 64)))
        from contextlib import redirect_stdout
        from io import StringIO
        output = StringIO()
        with patch.object(sys, 'argv', ['validation_evidence.py', 'verify-defaults']), redirect_stdout(output):
            assert subject.main() == 0
        assert output.getvalue().splitlines() == list(subject.DEFAULT_VERIFY_GROUPS)
        with patch.object(subprocess, 'check_output', return_value=b''):
            baseline = subject.source_digest('ui')
            for field, value in (('host', {'system': 'changed'}), ('xcode', {'version': 'changed'}), ('sdks', {'fixture': {'Version': '2'}}), ('compiler', {'modified': 2}), ('device', {'identifier': 'changed', 'systemVersion': 'fixture-os', 'systemBuild': 'fixture-build'}), ('device', {'identifier': 'fixture-phone', 'systemVersion': 'changed', 'systemBuild': 'fixture-build'})):
                with patch(f'{module_name}.environment_context', return_value=dict(fixture_environment, **{field: value})):
                    assert subject.source_digest('ui') != baseline
            assert not subject.complete_environment('ui', dict(fixture_environment, device=None))
            assert not subject.complete_environment('audit', {})
        assert subject.compilation_condition('os(macOS) && !canImport(UIKit)', 'modules')
        assert subject.compilation_condition('canImport(SwiftUI) && canImport(AppKit)', 'modules')
        for group in ('modules', 'all', 'catalyst', 'ui'):
            assert subject.compilation_condition('canImport(MapKit) && canImport(WidgetKit) && canImport(CoreLocation)', group)
        assert not subject.compilation_condition('canImport(UnregisteredFramework)', 'all')
        assert subject.compilation_condition('swift(>=5.0) && compiler(>=5.0)', 'all')
        assert subject.compilation_condition('swift(>=6.0)', 'all')
        assert not subject.compilation_condition('swift(>=6.0)', 'all', language_mode='5')
        assert subject.compilation_condition('swift(>=5.0) && !swift(>=6.0)', 'modules', language_mode='5')
        assert subject.compilation_condition('swift(>=6.0)', 'modules', language_mode='6')
        try:
            subject.compilation_condition('unsupportedPredicate(value)', 'all')
        except ValueError: pass
        else: raise AssertionError('Swift 编译器需要拒绝无效编译谓词')
        assert subject.compilation_condition('os(iOS) && targetEnvironment(macCatalyst) && canImport(UIKit)', 'catalyst')
        assert subject.compilation_condition('os(iOS) && !targetEnvironment(macCatalyst)', 'all')
        assert subject.compilation_condition('os(watchOS) && canImport(WatchKit)', 'network', platform='watchOS')
        assert not subject.compilation_condition('os(iOS)', 'network', platform='watchOS')
        assert not subject.compilation_condition('os(watchOS)', 'network', platform='iOS')
        assert subject.compilation_condition('DEBUG || RELEASE_NETWORK_SMOKE', 'all')
        assert not subject.compilation_condition('os(macOS) || targetEnvironment(macCatalyst)', 'all')
        assert subject.compilation_condition('BIT101_UI_TESTING && !targetEnvironment(macCatalyst)', 'ui')
        assert subject.compilation_condition('DEBUG && ICLOUD_CROSS_DEVICE_SMOKE', 'icloud')
        assert subject.compilation_condition('DEBUG && ICLOUD_CROSS_DEVICE_SMOKE', 'build-icloud-smoke')
        assert not subject.compilation_condition('DEBUG', 'release')
        assert subject.compilation_condition('EXTENDED_AUTOMATION && BIT101_AUTOMATED_TESTING && BIT101_UI_TESTING && !DEBUG', 'ui')
        from ui_rules import check_ui_test_inventory
        original_rglob, original_read = (Path.rglob, Path.read_text)
        ui_root = subject.ROOT / 'BIT101-iOSUITests'
        sample_path = ui_root / 'Additional/Nested.swift'
        for declaration in ('final class FormatUITests: XCTestCase {\n  func testAdded() {}\n}', 'final\nclass FormatUITests\n: XCTestCase {\n    func testAdded() {}\n}'):

            def sample_read(path, *args, **kwargs):
                if path == sample_path:
                    return declaration
                if path == subject.ROOT / 'docs/UI_INTERACTION_COVERAGE.md':
                    return ''
                return original_read(path, *args, **kwargs)
            subject.test_inventory.cache_clear()
            errors = []
            with patch.object(Path, 'rglob', lambda path, pattern: iter([sample_path]) if path == ui_root else original_rglob(path, pattern)), patch.object(Path, 'read_text', sample_read):
                check_ui_test_inventory(errors, {})
            assert 'UI interaction map missing: FormatUITests/testAdded' in errors
            selector = re.search("bit101_ui_test_selections\\(\\).*?<<'PY'\\n(.*?)\\nPY", (subject.ROOT / 'Scripts/script-support.sh').read_text(), re.DOTALL)[1]
            with patch('validation_evidence.test_inventory', return_value={'FormatUITests/testAdded'}), patch.object(sys, 'argv', ['selector', str(subject.ROOT / 'Scripts'), 'Added', 'FormatUITests']), patch('builtins.print') as output:
                exec(compile(selector, '<ui selector>', 'exec'), {})
            output.assert_called_once_with('FormatUITests/testAdded')
        subject.test_inventory.cache_clear()
        with patch.object(os, 'uname', return_value=os.uname_result(('Darwin', 'host', 'release', 'version', 'x86_64'))):
            subject.compilation_condition.cache_clear()
            for group in ('modules', 'catalyst'):
                assert subject.compilation_condition('arch(x86_64) && !arch(arm64)', group)
            assert subject.compilation_condition('arch(arm64) && !arch(x86_64)', 'all')
        subject.compilation_condition.cache_clear()
        conditional = '#if targetEnvironment(macCatalyst)\n中文手势\n#else\niOSGesture()\n#endif\n'
        active = subject.active_swift_source(conditional, 'ui')
        assert len(active.encode()) == len(conditional.encode()) and '中文手势' not in active and ('iOSGesture()' in active)
        unicode_sources = {}
        for index, separator in enumerate(['\u2028', '\u2029', '\x0b', '\x0c', '\x85']):
            source = f'// fixture{separator}// trailing\r\n#if DEBUG\r\n@Test func mustRun() {{}}\r\n#else\r\n@Test func inactive() {{}}\r\n#endif\r\n'
            filtered = subject.active_swift_source(source, 'catalyst')
            assert len(filtered.encode()) == len(source.encode())
            unicode_sources[f'unicode-inventory-{index}'] = filtered
        for facts in swift_syntax_index_sources(unicode_sources).values():
            assert not facts['hasParseErrors'] and [test['value'] for test in facts['tests']] == ['mustRun']
        for literal in ['/*\n#if DEBUG\n*/', '/* outer /* nested */\n#if DEBUG\n*/', '"""\n#if DEBUG\n"""', '#"""\n#if DEBUG\n"""#']:
            source = literal + '\n@Test func realTest() {}\n'
            assert '@Test func realTest' in subject.active_swift_source(source, 'modules')
        fixture = subject.ROOT / '.build/static-audit/source-digest-self-test.sh'
        fixture.parent.mkdir(parents=True, exist_ok=True)
        try:
            fixture.write_text('exit 0\n')
            with patch.object(subprocess, 'check_output', return_value=fixture.relative_to(subject.ROOT).as_posix().encode()):
                fixture.chmod(384)
                original = subject.source_digest()
                fixture.chmod(448)
                assert subject.source_digest() != original
        finally:
            fixture.unlink(missing_ok=True)
        from types import SimpleNamespace
        inputs = {'README.md': b'documentation', 'Modules/StorageCore/Sources/AppFileService.swift': b'product', 'ModuleTests/Sync/ScheduleSyncTests.swift': b'test'}
        with patch.object(subprocess, 'check_output', return_value='\x00'.join(inputs).encode()), patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_bytes', lambda path: inputs[path.relative_to(subject.ROOT).as_posix()]), patch.object(Path, 'stat', return_value=SimpleNamespace(st_mode=420)):
            before = {group: subject.source_digest(group) for group in ('audit', 'modules', 'manual-device')}
            inputs['README.md'] = b'updated documentation'
            assert subject.source_digest('audit') != before['audit']
            assert subject.source_digest('modules') == before['modules']
            assert subject.source_digest('manual-device') == before['manual-device']
            inputs['ModuleTests/Sync/ScheduleSyncTests.swift'] = b'updated test'
            assert subject.source_digest('modules') != before['modules']
            assert subject.source_digest('manual-device') == before['manual-device']
            inputs['Modules/StorageCore/Sources/AppFileService.swift'] = b'updated product'
            assert subject.source_digest('manual-device') != before['manual-device']
        from swift_source_index import SWIFT_SYNTAX_SOURCE_NAMES
        inputs = {'Scripts/' + name: b'indexer source' for name in SWIFT_SYNTAX_SOURCE_NAMES}
        groups = subject.RELEASE_GROUPS | subject.TEST_GROUPS | {'network', 'icloud', 'manual-device', 'build-archive'}
        with patch.object(subject, 'repository_input_names', return_value=list(inputs)), \
                patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_bytes', lambda path: inputs[path.relative_to(subject.ROOT).as_posix()]), \
                patch.object(Path, 'stat', return_value=SimpleNamespace(st_mode=420)):
            for name in inputs:
                before = {group: subject.source_digest(group, environment={}) for group in groups}
                inputs[name] += b' changed facts'
                assert all(subject.source_digest(group, environment={}) != before[group] for group in groups), name

        def icloud_summary(value):
            return subject.smoke_summary('icloud', dict(validatedDomains=sorted(subject.ICLOUD_DOMAINS), cloudKitEnvironment='Production', runID='fixture', **value))
        test = {'passed': True, 'totalTests': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}
        nested = swift_syntax_index_sources({'nested-tests': '@Suite struct Outer { @Suite struct Inner { @Testing.Test func works() {}; func testHelper() {} } }; class Base: XCTestCase {}; class Case: Base { func testActual() {}; func testArgument(_ value: Int) {}; static func testStatic() {} }; struct Ordinary { func testHelper() {} }'})['nested-tests']
        assert {item['value'] for item in nested['tests']} == {'Outer/Inner/works', 'Case/testActual'}
        aliased = swift_syntax_index_sources({'base': 'typealias BehaviorBase = XCTest.XCTestCase; enum Namespace { typealias Base = BehaviorBase }; class Direct: XCTestCase {}; typealias Indirect = Direct', 'tests': 'class MissingTests: Namespace.Base { func testRequiredBehavior() {} }; class Derived: Indirect { func testInheritedBehavior() {} }; enum Other { typealias Base = Ordinary; class Local: Base { func testHelper() {} } }; class Ordinary {}'})['tests']
        assert {item['value'] for item in aliased['tests']} == {'MissingTests/testRequiredBehavior', 'Derived/testInheritedBehavior'}
        from code_quality_rules import audit_callback_findings, audit_wiring_findings
        audit_path = subject.ROOT / 'Scripts/run-static-audit.sh'
        audit_source, original_read = (audit_path.read_text(), Path.read_text)
        assert audit_callback_findings(audit_source) == []
        for callback in ('module_boundary_audit', 'artifact_hygiene'):
            for body in ('true;', 'python3 /unrelated.py;', 'python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"; true;'):
                mutated = re.sub(r'(?m)^' + callback + r'\(\).*$', callback + '() { ' + body + ' }', audit_source)
                assert audit_callback_findings(mutated)
        for before, after in (('module_boundary_audit git_check', 'swift_parse git_check'), ('run_group artifact-hygiene artifact_hygiene', 'run_group artifact-hygiene swift_parse')):

            def mutated_read(path, *arguments, **keywords):
                return audit_source.replace(before, after) if path == audit_path else original_read(path, *arguments, **keywords)
            with patch.object(Path, 'read_text', mutated_read):
                assert any(('静态审计回调' in finding for finding in audit_wiring_findings()))
        with patch(module_name + '.test_inventory', return_value={'Outer/Inner/works'}), patch(module_name + '.coverage_complete', return_value=True):
            for identifier in ('Package.Outer/Inner/works()', 'Package.Outer/Inner/works()/Example.swift:1:1'):
                assert subject.complete_summary('schedule', dict(test, executedTests=[identifier]))
        summaries = {name: dict(test, totalTests=len(subject.test_inventory(name)), passedTests=len(subject.test_inventory(name)), executedTests=sorted(subject.test_inventory(name))) for name in ('modules', 'all', 'release-runtime', 'catalyst', 'catalyst-release-runtime', 'ui')}
        summaries['modules']['testCases'] = {'total': len(summaries['modules']['executedTests']),
            'byTest': {name: 1 for name in summaries['modules']['executedTests']}}
        summaries['modules']['coverage'] = {name: {'coveredLines': floor, 'executableLines': 100} for name, floor in subject.MODULE_COVERAGE_FLOORS.items()}
        summaries['all']['coverage'] = {'BIT101-iOS.app': {'coveredLines': 35, 'executableLines': 100}}
        summaries['all']['coverage'].update({'iOS/' + name: {'coveredLines': floor, 'executableLines': 100} for name, floor in subject.IOS_MODULE_COVERAGE_FLOORS.items()})
        summaries['ui']['coverage'] = dict(summaries['all']['coverage'])
        assert subject.coverage_complete('ui', summaries['ui'])
        assert not subject.coverage_complete('ui', dict(summaries['ui'], coverage={}))
        ui_missing = dict(summaries['ui']['coverage'])
        ui_missing['iOS/ScoreFeature'] = {'coveredLines': 0, 'executableLines': 100}
        assert not subject.coverage_complete('ui', dict(summaries['ui'], coverage=ui_missing))
        for name in ('iOS/CommunityUI', 'iOS/CourseFeature', 'iOS/ScoreFeature', 'BIT101-iOS.app'):
            weak = dict(summaries['ui']['coverage'])
            weak[name] = {'coveredLines': 1, 'executableLines': 100}
            assert not subject.coverage_complete('ui', dict(summaries['ui'], coverage=weak))
        assert subject.coverage_complete('all', summaries['all'])
        ios_missing = dict(summaries['all']['coverage'])
        ios_missing.pop('iOS/MediaKit')
        assert not subject.coverage_complete('all', dict(summaries['all'], coverage=ios_missing))
        ios_missing['iOS/MediaKit'] = {'coveredLines': 52, 'executableLines': 100}
        assert not subject.coverage_complete('all', dict(summaries['all'], coverage=ios_missing))
        assert subject.coverage_complete('modules', summaries['modules'])
        assert not subject.coverage_complete('modules', dict(summaries['modules'], coverage={}))
        missing = dict(summaries['modules']['coverage'])
        missing.pop('ScheduleSync')
        assert not subject.coverage_complete('modules', dict(summaries['modules'], coverage=missing))
        missing['ScheduleSync'] = {'coveredLines': 0, 'executableLines': 100}
        assert not subject.coverage_complete('modules', dict(summaries['modules'], coverage=missing))
        missing['ScheduleSync'] = {'coveredLines': 75, 'executableLines': 100}
        assert not subject.coverage_complete('modules', dict(summaries['modules'], coverage=missing))
        summaries['ui']['uiInventory'] = {'observed': 1, 'visited': 1, 'pending': [], 'scope': 'mounted-controls', 'unidentifiedControls': 0, 'pendingDisabled': [], 'identityScope': 'testCaseNavigationPresentationAndOccurrence'}
        summaries['audit'] = {'passed': True, 'kind': 'audit', 'startedAt': subject.utc_now().isoformat(), 'finishedAt': subject.utc_now().isoformat()}
        summaries['restore'] = dict(passed=True, kind='restore', initialized=True, sessionRecovered=True, active=True, processAlive=True, processIdentifier=1, runID='00000000-0000-4000-8000-000000000001', inputDigest=subject.source_digest('restore'), startedAt=subject.utc_now().isoformat(), finishedAt=subject.utc_now().isoformat())
        provenance = {'inputDigest': subject.source_digest('build-archive'), 'runID': 'fixture-run'}
        distribution_proof = distribution_fixture()[1]
        summaries['build-archive'] = {'passed': True, 'kind': 'build', 'archiveProvenance': provenance,
            'executables': {row['identifier']: row['executableUUIDs'] for row in distribution_proof['bundles']}}
        from validation_manual import MANUAL_DEVICE_CHECKS, capture, complete
        checks = {}
        for name in MANUAL_DEVICE_CHECKS: checks[name] = captured_fixture(name, provenance)
        summaries['manual-device'] = {'passed': True, 'checks': checks}
        assert complete(checks)
        stale = json.loads(json.dumps(checks))
        next(iter(stale.values()))['capturedAt'] = '2000-01-01T00:00:00+00:00'
        assert not complete(stale)
        original_read = Path.read_bytes
        def missing_artifact(path):
            if str(path).startswith('/evidence') or str(path) == '/missing': raise FileNotFoundError
            return original_read(path)
        with patch.object(Path, 'read_bytes', missing_artifact):
            assert complete(json.loads(json.dumps(checks)))
            try: capture('操作', '结果', Path('/missing'), 'photos', 'passed', subject.utc_now().isoformat())
            except FileNotFoundError: pass
            else: raise AssertionError('人工证据需要已有附件')
        for field, value in [('dataBase64', ''), ('dataBase64', 'bad%base64'), ('dataBase64', 'b3RoZXI='), ('sha256', 'a' * 64), ('byteCount', 1)]:
            changed = json.loads(json.dumps(checks))
            next(iter(changed.values()))['evidence'][field] = value
            assert not complete(changed)
        assert not subject.complete_summary('manual-device', {'passed': True, 'checks': {}})
        assert not subject.complete_summary('manual-device', {'passed': True, 'checks': {name: 'pass' for name in MANUAL_DEVICE_CHECKS}})
        summaries['network'] = subject.smoke_summary('network', network_trace_fixture({'passed': True, 'scope': 'all', 'executedProbes': sorted(subject.network_inventory()), 'requiredProbes': sorted(subject.network_inventory()), 'currentTerm': 'fixture-current', 'validatedTerm': 'fixture-current'}))
        sms = network_trace_fixture({'passed': True, 'scope': 'school', 'executedProbes': sorted(subject.network_inventory('school')), 'requiredProbes': sorted(subject.network_inventory('school')), 'schoolSMSCoverage': 'verified', 'verifiedSMSProbes': [{'purpose': purpose, 'probe': sorted(subject.SCHOOL_SMS_PROBES[purpose])[0]} for purpose in subject.school_sms_inventory()]})
        sms.update(authenticatedSchoolProbes=sms['verifiedSMSProbes'], requestedSMSPurposes=sorted(subject.school_sms_inventory()), currentTerm='fixture-current', validatedTerm='fixture-current')
        assert set(subject.SCHOOL_SMS_PROBES) == subject.school_sms_inventory()
        writes = network_trace_fixture({'passed': True, 'scope': 'community-writes', 'executedProbes': sorted(subject.network_inventory('community-writes')), 'requiredProbes': sorted(subject.network_inventory('community-writes')), 'communityWriteEvidence': ['验收账号 user1', '服务端确认删除 poster1', '服务端确认删除 paper2', '点赞恢复 poster1', '点赞恢复 paper2', '点赞恢复 course3', '图片提交 poster1', '图片提交 comment10', '关注恢复 user4'] + [f'服务端确认删除 comment{id}' for id in range(10, 16)] + [f'创建 comment{id} 目标 {parent}' for id, parent in [(10, 'poster1'), (11, 'comment10'), (12, 'paper2'), (13, 'comment12'), (14, 'course3'), (15, 'comment14')]]})
        assert subject.community_writes_complete(writes['communityWriteEvidence'])
        assert not subject.community_writes_complete(writes['communityWriteEvidence'][:5] + ['服务端确认删除 comment42'] * 6)
        assert not subject.community_writes_complete([item.replace('目标 comment14', '目标 comment10') for item in writes['communityWriteEvidence']])
        assert not subject.community_writes_complete([item.replace('创建 comment15', '创建 comment14') for item in writes['communityWriteEvidence']])
        cleanup = network_trace_fixture({'passed': True, 'scope': 'community-cleanup', 'executedProbes': sorted(subject.network_inventory('community-cleanup')), 'requiredProbes': sorted(subject.network_inventory('community-cleanup'))})
        assert subject.smoke_summary('community-cleanup', cleanup)['passed']
        assert not subject.smoke_summary('community-writes', cleanup, full=False)['passed']
        with patch(f'{module_name}.test_inventory', return_value={'Suite/first', 'Suite/second', 'Other/third'}):
            expected = subject.selected_test_inventory('all', ['Suite', 'Other/third()'])
            assert expected == {'Suite/first', 'Suite/second', 'Other/third'}
            try:
                subject.selected_test_inventory('all', ['Suite', 'Missing/none()'])
            except ValueError:
                pass
            else:
                raise AssertionError('手选测试需要拒绝混合失效选择')
        chosen = {'passed': True, 'totalTests': 3, 'passedTests': 3, 'failedTests': 0, 'skippedTests': 0, 'executedTests': ['Suite/first()', 'Suite/second()', 'Other/third()']}
        assert subject.selected_test_summary_complete(chosen, sorted(expected))
        assert not subject.selected_test_summary_complete(dict(chosen, totalTests=1, passedTests=1, executedTests=['Suite/first()']), sorted(expected))
        summaries['community-writes'] = subject.smoke_summary('community-writes', writes)
        assert summaries['community-writes']['passed']
        assert not subject.smoke_summary('community-writes', dict(writes, communityWriteEvidence=[]))['passed']
        summaries['school-sms'] = subject.smoke_summary('school-sms', sms)
        assert summaries['school-sms']['passed']
        authenticated = dict(sms, schoolSMSCoverage='not_required', verifiedSMSProbes=[], requestedSMSPurposes=[])
        assert subject.complete_summary('school-sms', subject.smoke_summary('school-sms', authenticated))
        assert not subject.smoke_summary('school-sms', dict(authenticated, requestedSMSPurposes=['webvpn']))['passed']
        assert not subject.smoke_summary('school-sms', dict(authenticated, authenticatedSchoolProbes=[]))['passed']
        mixed = dict(sms, requestedSMSPurposes=[sms['verifiedSMSProbes'][0]['purpose']], verifiedSMSProbes=sms['verifiedSMSProbes'][:1])
        assert subject.smoke_summary('school-sms', mixed)['passed']
        full_sms = network_trace_fixture(dict(sms, scope='all', requiredProbes=sorted(subject.network_inventory('all')), executedProbes=sorted(subject.network_inventory('all'))))
        assert subject.smoke_summary('network', full_sms)['passed']
        projected = subject.smoke_summary('school-sms', full_sms)
        assert subject.complete_summary('school-sms', projected)
        assert projected['scope'] == 'school' and set(projected['requiredProbes']) == subject.network_inventory('school')
        peripheral = dict(full_sms, passed=False, failures=['[App Store 更新接口] fixture failure'],
            coverageGaps=['必需探针缺失：App Store 更新接口'], skippedProbes=['App Store 更新接口（fixture）'])
        assert subject.complete_summary('school-sms', subject.smoke_summary('school-sms', peripheral))
        assert not subject.smoke_summary('school-sms', dict(peripheral, failures=['[当前学期] fixture failure']))['passed']
        assert not subject.smoke_summary('school-sms', dict(peripheral, failures=['网络 Smoke 报告写入失败：fixture']))['passed']
        assert not subject.smoke_summary('school-sms', dict(full_sms, passed=False))['passed']
        assert not subject.smoke_summary('school-sms', dict(full_sms, requiredProbes=sms['requiredProbes']))['passed']
        assert not subject.smoke_summary('school-sms', dict(full_sms, verifiedSMSProbes=[]))['passed']

        mismatched = [{'purpose': step['purpose'], 'probe': 'BIT101 登录状态'} for step in sms['verifiedSMSProbes']]
        assert not subject.smoke_summary('school-sms', dict(sms, verifiedSMSProbes=mismatched))['passed']
        assert subject.smoke_summary('school-sms', dict(sms, schoolSMSCoverage='preflight_only'))['passed'] is False
        assert subject.smoke_summary('school-sms', dict(sms, verifiedSMSProbes=sms['verifiedSMSProbes'][:1]))['passed'] is False
        summaries['icloud'] = icloud_summary({'exitCode': 0, 'stages': [icloud_stage_fixture(name, dict(test, totalTestCount=1, exitCode=0)) for name in ('testPhoneRoundTrip', 'testMacReceiveAndRestore')]})
        assert summaries['icloud']['cleanup']['kind'] == 'round-trip'
        assert summaries['icloud']['macCleanup']['kind'] == 'round-trip'
        assert subject.complete_summary('icloud', summaries['icloud'])
        for field, value in [('executedTests', ['Other/testAlwaysPass']), ('testTargets', ['Other']), ('destination', {'platform': 'iOS Simulator', 'deviceIdentifier': 'phone'}), ('runID', 'other')]:
            wrong = [dict(summaries['icloud']['stages'][0], **{field: value}), summaries['icloud']['stages'][1]]
            assert not subject.complete_summary('icloud', dict(summaries['icloud'], stages=wrong))
        assert not subject.complete_summary('icloud', dict(summaries['icloud'], cleanup={'exitCode': 1}))
        assert not subject.complete_summary('icloud', dict(summaries['icloud'], macCleanup={'exitCode': 1}))
        groups = {name: {'exitCode': 0, 'scope': 'full', 'summary': summary, 'inputDigest': subject.source_digest(name), 'environment': subject.environment_context(name)} for name, summary in summaries.items()}
        groups['build-archive']['runID'] = provenance['runID']
        groups['restore']['runID'] = summaries['restore']['runID']
        for name in subject.LIVE_GROUPS & groups.keys():
            groups[name]['summary'].update(startedAt=subject.utc_now().isoformat(), finishedAt=subject.utc_now().isoformat())
        report = {'sourceDigest': 'source', 'groups': groups}
        with patch('ui_rules.source_runtime_interaction_findings', return_value=[]):
            assert subject.release_findings(report, 'source') == []
            older = json.loads(json.dumps(report))
            first = next(iter(older['groups']['build-archive']['summary']['executables'].values()))
            first[0]['uuid'] = '00000000-0000-4000-8000-000000000001'
            assert any('可执行文件 UUID' in error for error in subject.release_findings(older, 'source'))
            with patch(f'{module_name}.environment_context', return_value=dict(fixture_environment, host={'system': 'changed'})):
                assert subject.release_findings(report, 'source')
                assert subject.release_findings(report, 'source', recorded_environment=True) == []
                from contextlib import nullcontext, redirect_stdout
                from io import StringIO
                for recorded, expected in ((False, '待复验'), (True, '通过')):
                    output = StringIO()
                    arguments = ['validation_evidence.py', 'summary'] + (['--recorded-environment'] if recorded else [])
                    with patch.object(subject, 'report_lock', side_effect=nullcontext), patch.object(Path, 'is_file', lambda path: path == subject.REPORT or original_is_file(path)), \
                            patch.object(Path, 'read_text', return_value=json.dumps({'groups': {'modules': groups['modules']}})), \
                            patch.object(sys, 'argv', arguments), patch.dict(os.environ, GITHUB_STEP_SUMMARY=''), redirect_stdout(output):
                        assert subject.main() == 0
                    assert f'| modules | full | {expected} |' in output.getvalue()
            with patch(f'{module_name}.environment_context', return_value=dict(fixture_environment, xcode={'version': 'changed'})):
                assert subject.release_findings(report, 'source', recorded_environment=True)
            with patch(f'{module_name}.environment_context', return_value=dict(fixture_environment, compiler=dict(compiler, sha256='b' * 64))):
                assert any('编译工具链' in error for error in subject.release_findings(report, 'source', recorded_environment=True))
        assert subject.release_findings(report, 'changed')
        groups['ui']['scope'] = 'selected'
        assert subject.release_findings(report, 'source')
        groups['ui']['scope'] = 'full'
        groups['ui']['summary']['passedTests'] = 0
        assert subject.release_findings(report, 'source')
        module = subject.test_summary('总计 3；通过 3；失败 0；跳过 0\n统计范围：macOS\n- ScheduleSync: 75.00% (3/4 lines)')
        assert module['passed'] and module['coverage']['ScheduleSync']['coveredLines'] == 3
        assert subject.test_summary('总计 4；通过 3；失败 0；跳过 1')['passed'] is False
        assert subject.test_summary('总计 0；通过 0；失败 0；跳过 0')['passed'] is False
        assert subject.complete_summary('ui', dict(test, executedTests=['Fixture/example'])) is False
        summaries['ui']['passedTests'] = summaries['ui']['totalTests']
        summaries['ui']['uiInventory']['pending'] = ['new-control']
        assert subject.complete_summary('ui', summaries['ui']) is False
        network = network_trace_fixture({'passed': True, 'scope': 'all', 'executedProbes': sorted(subject.network_inventory()), 'requiredProbes': sorted(subject.network_inventory()), 'currentTerm': 'fixture-current', 'validatedTerm': 'fixture-current'})
        assert subject.smoke_summary('network', network)['passed']
        assert not subject.smoke_summary('network', dict(network, requestedTerm='historical', validatedTerm='historical'))['passed']
        assert not subject.smoke_summary('network', dict(network, validatedTerm='other'))['passed']
        assert not subject.smoke_summary('network', dict(network, currentTerm=None))['passed']
        historical = network_trace_fixture(dict(network, requestedTerm='historical', validatedTerm='historical'))
        assert subject.smoke_summary('network', historical, full=False)['passed']
        assert subject.smoke_summary('network', {'passed': True, 'scope': 'all', 'executedProbes': ['unrelated']})['passed'] is False
        network['coverageGaps'] = ['fixture']
        network['failures'] = ['具体失败原因']
        failed_summary = subject.smoke_summary('network', network)
        assert failed_summary['diagnostics']['failures'] == ['具体失败原因']
        assert failed_summary['diagnostics']['coverageGaps'] == ['fixture']
        network['failures'] = []
        assert subject.smoke_summary('network', network)['passed'] is False
        ddl = network_trace_fixture({'passed': True, 'scope': 'ddl', 'executedProbes': sorted(subject.network_inventory('ddl')), 'requiredProbes': sorted(subject.network_inventory('ddl'))})
        assert len(subject.network_inventory('ddl')) == 4 and subject.smoke_summary('ddl', ddl)['passed']
        ddl_summary = subject.smoke_summary('ddl', ddl)
        assert subject.complete_summary('ddl', ddl_summary)
        assert not subject.smoke_summary('network', dict(network, requestEvidence=[]))['passed']
        assert not subject.smoke_summary('network', dict(network, requestEvidenceRequired=False))['passed']
        network_recording_self_test(subject, {'network': network, 'ddl': ddl, 'school-sms': sms,
            'community-writes': writes, 'community-cleanup': cleanup})

        ddl['skippedProbes'] = ['课程中心 DDL 下载']
        assert subject.smoke_summary('ddl', ddl)['passed'] is False
        assert icloud_summary({'exitCode': 0, 'stages': []})['passed'] is False
        stages = [icloud_stage_fixture(name, {'exitCode': 0, 'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}) for name in ['testPhoneRoundTrip', 'testMacReceiveAndRestore']]
        assert icloud_summary({'exitCode': 0, 'stages': stages})['passed']
        for field, value in [('executedTests', ['Other/testAlwaysPass']), ('testTargets', ['Other']), ('destination', {'platform': 'iOS Simulator', 'deviceIdentifier': 'phone'}), ('runID', 'other')]:
            wrong = [dict(stages[0], **{field: value}), stages[1]]
            assert not icloud_summary({'exitCode': 0, 'stages': wrong})['passed']
        assert subject.smoke_summary('icloud', {'exitCode': 0, 'stages': stages})['passed'] is False
        cleanup = icloud_stage_fixture('testCleanup', stages[0])
        assert icloud_summary({'exitCode': 0, 'stages': stages, 'cleanup': cleanup, 'cleanupExitCode': 0})['passed']
        assert icloud_summary({'exitCode': 0, 'stages': stages, 'cleanup': cleanup, 'cleanupExitCode': 1})['passed'] is False
        cleanup['passedTests'] = 0
        assert icloud_summary({'exitCode': 0, 'stages': stages, 'cleanup': cleanup})['passed'] is False
        assert not subject.smoke_summary('icloud-cleanup', {'cleanup': cleanup, 'cleanupExitCode': 0})['passed']
        cleanup['passedTests'] = 1
        mac_cleanup = icloud_stage_fixture('testMacCleanup', cleanup)
        restored = {'exitCode': 1, 'cleanup': cleanup, 'macCleanup': mac_cleanup, 'cleanupExitCode': 0, 'runID': 'fixture'}
        assert subject.smoke_summary('icloud-cleanup', restored)['passed']
        assert not subject.smoke_summary('icloud-cleanup', dict(restored, macCleanup={}))['passed']
        assert not icloud_summary({'exitCode': 0, 'stages': stages, 'macCleanup': dict(mac_cleanup, exitCode=1)})['passed']
        stages[1]['passedTests'] = 0
        assert icloud_summary({'exitCode': 0, 'stages': stages})['passed'] is False
        return 0


def module_events_self_test(subject) -> None:
    from unittest.mock import patch
    single = 'Consumer.Suite/single()/Tests.swift:1:1'
    parameterized = 'Consumer.Suite/parameterized(_:)/Tests.swift:2:1'
    def declaration(identifier, parameterized=False):
        return {'kind': 'test', 'payload': {'kind': 'function', 'id': identifier, 'isParameterized': parameterized}}
    def event(kind, identifier='', **fields):
        return {'kind': 'event', 'payload': dict(kind=kind, testID=identifier, **fields)}
    def encode(records): return '\n'.join(json.dumps(record) for record in records)
    records = [declaration(single), declaration(parameterized, True), event('runStarted'),
        event('testStarted', single), event('testEnded', single), event('testStarted', parameterized),
        event('testCaseStarted', parameterized, _testCase={'id': 'case-a'}), event('testCaseStarted', parameterized, _testCase={'id': 'case-b'}),
        event('testCaseEnded', parameterized, _testCase={'id': 'case-a'}), event('testCaseEnded', parameterized, _testCase={'id': 'case-b'}),
        event('testEnded', parameterized), event('runEnded')]
    result = subject.module_event_summary(encode(records))
    assert result['totalTests'] == result['passedTests'] == 2
    assert result['failedTests'] == result['skippedTests'] == 0
    assert result['testCases'] == {'total': 3, 'byTest': {single: 1, parameterized: 2}}
    assert subject.module_cases_complete(result)
    metrics = '总计 2；通过 2；失败 0；跳过 0\n已执行用例：' + json.dumps(result['executedTests']) \
        + '\n测试实例：' + json.dumps(result['testCases'])
    summary = subject.test_summary(metrics)
    with patch.object(subject, 'coverage_complete', return_value=True), \
            patch.object(subject, 'test_inventory', return_value={subject.normalized_test_id(name) for name in result['executedTests']}):
        assert subject.complete_summary('modules', summary)
        for cases in (None, {'total': 2, 'byTest': result['testCases']['byTest']},
                {'total': 1, 'byTest': {single: 1}}, {'total': 1, 'byTest': {single: 1, parameterized: 0}}):
            assert not subject.complete_summary('modules', dict(summary, testCases=cases))
    skipped = 'Consumer.Suite/skipped()/Tests.swift:3:1'
    result = subject.module_event_summary(encode(records + [declaration(skipped), event('testSkipped', skipped)]))
    assert result['totalTests'] == 3 and result['passedTests'] == 2 and result['skippedTests'] == 1
    for issue, failed in (({'isKnown': False}, 1), ({'isKnown': True}, 0), ({'isKnown': False, 'isFailure': False}, 0)):
        result = subject.module_event_summary(encode(records + [event('issueRecorded', parameterized, issue=issue)]))
        assert result['failedTests'] == failed and result['passedTests'] == 2 - failed
    for incomplete in (records[:-1], [row for index, row in enumerate(records) if index != 8],
            [row for row in records if not row['payload']['kind'].startswith('testCase')], [],
            records + [event('issueRecorded', issue={'isKnown': False})]):
        try: subject.module_event_summary(encode(incomplete))
        except ValueError: pass
        else: raise AssertionError('事件缺失、空参数及运行失败需要进入证据门禁')
    for kind, case_id in [('testCaseStarted', 'case-a'), ('testCaseEnded', 'case-a'), ('testCaseEnded', 'other'), ('testCaseEnded', None)]:
        broken = json.loads(json.dumps(records))
        broken[9] = event(kind, parameterized, _testCase={'id': case_id})
        try: subject.module_event_summary(encode(broken))
        except ValueError: pass
        else: raise AssertionError('参数实例重复、遗漏及身份错配需要验收失败')


def network_recording_self_test(subject, results) -> None:
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    from unittest.mock import patch
    from validation_environment import DEVICE_GROUPS
    assert set(results) == subject.NETWORK_GROUPS
    assert subject.NETWORK_GROUPS <= DEVICE_GROUPS
    bit101_probes = sorted(subject.network_inventory('bit101'))
    for group, result in results.items():
        for passed in (True, False):
            result = dict(result, passed=passed, coverageGaps=[], runID='network-run',
                startedAt=subject.utc_now().isoformat(), finishedAt=subject.utc_now().isoformat())
            report = {}
            def read(path, *args, **kwargs):
                return json.dumps(report if path == subject.REPORT else result)
            def save(value):
                report.update(value)
            with patch.object(subject, 'source_digest', return_value='current'), \
                    patch.object(subject, 'report_lock', side_effect=nullcontext), patch.object(subject, 'write_report', side_effect=save), \
                    patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_text', read), \
                    patch.object(subject.subprocess, 'check_output', return_value='head'), \
                    patch.dict(os.environ, BIT101_VALIDATION_RUN_ID='network-run'), redirect_stderr(StringIO()):
                assert subject.record(group, 0, 'full', 'current') == (0 if passed else 1), group
                with patch.object(sys, 'argv', ['validation_evidence.py', 'check-group', group]):
                    assert subject.main() == (0 if passed else 1), group
                if group == 'network' and passed:
                    full = report['groups'][group]
                    original = result
                    result = network_trace_fixture(dict(result, scope='bit101', requiredProbes=bit101_probes, executedProbes=bit101_probes))
                    assert subject.record(group, 0, 'selected', 'current') == 0
                    assert report['groups'][group]['lastFullRun'] == full
                    with patch.object(sys, 'argv', ['validation_evidence.py', 'check-group', group]):
                        assert subject.main() == 0
                    result = original


def network_trace_fixture(value: dict) -> dict:
    from network_request_contracts import contracts_for, SELECTORS
    def example(pattern, identifier=1):
        import re
        pattern = re.sub(r'\(\?:([^()]*)\)', lambda match: match[1].split('|')[0], pattern)
        return pattern.replace('[0-9a-f]+', 'a').replace(r'[1-9]\d*', str(identifier)).replace(r'\d+', str(identifier)).replace(r'\.', '.').replace(r'\-', '-').replace('.+', 'fixture').replace('?', '')
    rows = []
    for name in value.get('requiredProbes', []):
        contracts = contracts_for(name)
        assert contracts, name
        requests = []
        expected = {'XNXQDM': value.get('validatedTerm', 'fixture-current')} if name in {'课表、考试与首周同步', '空教室占用数据'} else {}
        if name == '空教室占用数据': expected['JXLDM'] = 'fixture-building'
        for contract in contracts:
            for index in range(max(contract.minimum, 2 if contract.paging else 1)):
                query = {key: example(pattern) for key, pattern in contract.query.items() if pattern is not None}
                query.update({key: item for key, item in expected.items() if key != 'path'})
                if contract.paging == 'page': query['page'] = str(index)
                if contract.paging == 'last_id': query['last_id'] = str(sys.maxsize) if index == 0 else '1'
                request = {'method': contract.method, 'endpoint': 'https://' + example(contract.host) + example(contract.path),
                    'statusCode': next(iter(contract.statuses)), 'query': query}
                if contract.paging == 'last_id': request['responseMinimumID'] = '0'
                if name == '社区写入与清理':
                    if contract.method == 'DELETE' and contract.path == r'/reaction/comments/\d+':
                        request['endpoint'] = 'https://' + example(contract.host) + example(contract.path, index + 1)
                    if contract.method == 'POST' and contract.path == '/reaction/comments' and query['obj'].startswith('comment'):
                        query['obj'] = 'comment' + str(index + 1)
                request.update(finalEndpoint=('https://' + example(contract.final_host) + example(contract.final_path))
                    if contract.final_host else request['endpoint'], finalMethod=request['method'], finalQuery=dict(query))
                assert contract.matches(request), (name, request)
                for key in SELECTORS.get(name, set()) - {'XNXQDM', 'JXLDM'}:
                    from urllib.parse import unquote, urlsplit
                    expected[key] = unquote(urlsplit(request['endpoint']).path) if key == 'path' else request['query'][key]
                requests.append(request)
        if name == '生产共享会话': requests.insert(1, requests.pop())
        rows.append({'probe': name, 'requests': requests, 'expectedParameters': expected})
    value['requestEvidenceRequired'] = True
    value['requestEvidence'] = rows
    return value


def network_route_identity_self_test() -> None:
    from copy import deepcopy
    from validation_provenance import network_requests_complete
    from network_request_contracts import complete as check_complete
    def complete(probe, requests, expected=None):
        return check_complete(probe, [dict(row, finalEndpoint=row.get('finalEndpoint', row['endpoint']),
            finalMethod=row.get('finalMethod', row['method']), finalQuery=row.get('finalQuery', dict(row.get('query', {}))))
            for row in requests], expected)
    required = {'文章评论'}
    proof = network_trace_fixture({'requiredProbes': sorted(required)})
    assert network_requests_complete(required, proof)
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
    schedule = network_trace_fixture({'requiredProbes': ['课表、考试与首周同步']})
    for request in schedule['requestEvidence'][0]['requests']: request['finalQuery']['XNXQDM'] = 'wrong-term'
    assert not network_requests_complete({'课表、考试与首周同步'}, schedule)
    for probe in ('话廊帖子评论', '学业课程评论', '文章评论', '学业课程列表'):
        fixture = network_trace_fixture({'requiredProbes': [probe]})
        for parameter in ('order', 'search') if probe == '学业课程列表' else ('order',):
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
    cursors = network_trace_fixture({'requiredProbes': ['消息列表-系统通知']})
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
    writes = network_trace_fixture({'requiredProbes': ['社区写入与清理']})['requestEvidence'][0]['requests']
    assert complete('社区写入与清理', writes)
    for endpoint, method in [('/upload/image', 'POST'), ('/reaction/comments', 'POST'),
            ('/reaction/comments/', 'DELETE'), ('/reaction/like', 'POST'), ('/user/follow/', 'POST'),
            ('/posters/', 'PUT'), ('/papers/', 'PUT')]:
        changed = [row for row in writes if not (endpoint in row['endpoint'] and row['method'] == method)]
        assert not complete('社区写入与清理', changed), (endpoint, method)
    changed = deepcopy(writes)
    for row in changed:
        if row['method'] == 'POST' and row['endpoint'].endswith('/reaction/comments'):
            row['query']['obj'] = 'poster1'
    assert not complete('社区写入与清理', changed)
    for probe, endpoint in [('课程中心原生认证', 'https://zy-eclass.bit.edu.cn/api/my-courses'),
                            ('课程中心 DDL 下载', 'https://zy-eclass.bit.edu.cn/api/my-courses'),
                            ('乐学日历订阅地址', 'https://lexue.bit.edu.cn/calendar/export.php')]:
        request = {'method': 'POST', 'endpoint': endpoint, 'statusCode': 200, 'query': {}}
        assert complete(probe, [request]), probe
        assert not complete(probe, [dict(request, method='GET')]), probe
    variants = {
        '话廊最新列表': {'mode': 'search', 'order': 'new', 'uid': '-1'},
        '话廊关注流': {'mode': 'follow'}, '话廊热门流': {'mode': 'hot'}, '话廊推荐流': {},
        '话廊机器人流': {'mode': 'search', 'order': 'new', 'uid': '-1'},
        '话廊搜索': {'mode': 'search', 'order': 'new', 'uid': '-1', 'search': 'BIT101'},
        '文章列表-最新': {'search': 'BIT101'}, '文章列表-高赞': {'order': 'like', 'search': 'BIT101'},
        '文章列表-热评': {'order': 'comment', 'search': 'BIT101'},
    }
    for probe, parameters in variants.items():
        endpoint = 'https://bit101.flwfdd.xyz/' + ('papers' if probe.startswith('文章') else 'posters')
        requests = [{'method': 'GET', 'endpoint': endpoint, 'statusCode': 200,
                     'query': dict(parameters, page=str(page))} for page in (0, 1)]
        assert complete(probe, requests), probe
        for extra in (dict(requests[-1], query=dict(parameters, page='2', order='unexpected')),
                      dict(requests[-1], statusCode=500), dict(requests[-1], endpoint='https://example.invalid/other')):
            assert not complete(probe, requests + [extra]), (probe, extra)
        for key in ('order', 'search') if probe.startswith('文章') else ('mode', 'order', 'uid', 'search', 'hide_bot'):
            changed = deepcopy(requests)
            for row in changed:
                if key in row['query']: row['query'].pop(key)
                else: row['query'][key] = 'unexpected'
            assert not complete(probe, changed), (probe, key)
    assert not complete('文章列表-未知', requests)
    for probe, paths, expected in [
        ('课表、考试与首周同步', ['/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do',
            '/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do', '/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do'], {'XNXQDM': '2025-2026-1'}),
        ('空教室占用数据', ['/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do'], {'XNXQDM': '2025-2026-1', 'JXLDM': 'fixture-building'}),
    ]:
        rows = [{'method': 'POST', 'endpoint': 'https://jxzxehallapp.bit.edu.cn' + path, 'statusCode': 200, 'query': dict(expected)} for path in paths]
        assert complete(probe, rows, expected) and not complete(probe, rows)
        for key in expected:
            changed = deepcopy(rows)
            changed[0]['query'][key] = 'wrong-selection'
            assert not complete(probe, changed, expected)
            changed[0]['query'].pop(key)
            assert not complete(probe, changed, expected)
    login = {'method': 'GET', 'endpoint': 'https://bit101.flwfdd.xyz/user/check', 'statusCode': 200, 'query': {}}
    assert complete('BIT101 登录状态', [dict(login, statusCode=401), login])
    assert not complete('BIT101 登录状态', [login, dict(login, statusCode=401)])
    assert not complete('BIT101 登录状态', [dict(login, statusCode=500), login])
    assert not complete('BIT101 登录状态', [dict(login, statusCode=401, query={'order': 'old'}), login])
    authentication = dict(login, method='POST', endpoint='https://bit101.flwfdd.xyz/user/webvpn_verify')
    assert complete('BIT101 登录状态', [dict(login, statusCode=401), authentication, login])
    assert not complete('BIT101 登录状态', [dict(login, statusCode=401), dict(authentication, statusCode=500), login])
    teaching = {'method': 'GET', 'endpoint': 'https://jxzxehallapp.bit.edu.cn/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do', 'statusCode': 200, 'query': {}}
    preheat = dict(teaching, endpoint='https://jxzxehallapp.bit.edu.cn/jwapp/i18n.do')
    cookies = dict(authentication, endpoint='https://login.bit101.flwfdd.xyz/api/jxzxehall/cookies')
    assert complete('当前学期', [cookies, preheat, teaching])
    redirected = dict(teaching, finalEndpoint='https://sso.bit.edu.cn/cas/login', finalMethod='GET', finalQuery={})
    assert complete('当前学期', [redirected, cookies, preheat, teaching])
    assert not complete('当前学期', [redirected, cookies, preheat])
    assert not complete('当前学期', [dict(redirected, finalEndpoint='https://example.invalid/cas/login'), cookies, teaching])
    assert not complete('当前学期', [dict(redirected, statusCode=500), cookies, teaching])
    assert complete('当前学期', [dict(cookies, statusCode=503), cookies, preheat, teaching])
    assert not complete('当前学期', [cookies, dict(preheat, statusCode=500), teaching])
    transcript = network_trace_fixture({'requiredProbes': ['可信成绩单接口']})['requestEvidence'][0]
    page = {'method': 'GET', 'endpoint': 'https://jwb.bit.edu.cn/cjd/Temp/page.jpg', 'statusCode': 200, 'query': {}}
    assert complete('可信成绩单接口', transcript['requests'] + [page])
    assert not complete('可信成绩单接口', transcript['requests'] + [dict(page, statusCode=500)])
    assert complete('BIT101 登录状态', [dict(login, endpoint='https://bit101.flwfdd.xyz:443/user/check')])
    for port in ('0', '80', '8443', '65536', 'invalid'):
        assert not complete('BIT101 登录状态', [dict(login, endpoint='https://bit101.flwfdd.xyz:' + port + '/user/check')])
    assert complete('话廊图片下载', [dict(login, endpoint='https://image.invalid:8443/image.png')])
    for status in (100, 302, 401, 403, 500):
        assert not complete('BIT101 登录状态', [dict(login, statusCode=status)])
    assert not complete('BIT101 登录状态', [dict(login, endpoint=login['endpoint'].replace('https:', 'http:'))])
    account = dict(login, endpoint='https://bit101.flwfdd.xyz/user/info/0')
    phases = [account, dict(account, statusCode=401), account]
    assert complete('生产共享会话', phases)
    for statuses in ((200, 200, 200), (401, 200, 200), (200, 401, 500), (200, 403, 200), (200, 401), (200, 401, 200, 200)):
        assert not complete('生产共享会话', [dict(account, statusCode=status) for status in statuses])
