"""Regression contracts for evidence inputs, inventories and release summaries."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from swift_source_index import swift_syntax_index_sources

def run_self_test(subject) -> int:
    module_name = subject.__name__
    from unittest.mock import patch
    from validation_inputs import self_test as input_self_test
    fixture_environment = {'host': {'system': 'fixture'}, 'developer': '/fixture', 'xcode': {'version': 'fixture'}, 'compiler': {'modified': 1}, 'sdks': {'fixture': {'Version': '1'}}, 'device': {'identifier': 'fixture-phone', 'systemVersion': 'fixture-os', 'systemBuild': 'fixture-build'}}
    with patch(f'{module_name}.environment_context', return_value=fixture_environment):
        from validation_provenance_tests import run_self_test as provenance_self_test
        from validation_test_areas import inventory_findings
        provenance_self_test(subject.record)
        from validation_manual_tests import run_self_test as manual_self_test, captured_fixture
        manual_self_test()
        all_suites = {test.split('/', 1)[0] for test in subject.test_inventory('all')}
        assert inventory_findings(all_suites) == []
        assert inventory_findings(all_suites | {'NewFeatureTests'})
        for group in ('infrastructure', 'login'):
            assert any((test.startswith('SchoolCookieIsolationTests/') for test in subject.test_inventory(group)))
        with patch.object(sys, 'argv', ['validation_evidence.py', 'record', 'audit', '7']), patch.dict(os.environ, BIT101_VALIDATION_SOURCE_DIGEST='fixture-input'), patch(f'{module_name}.record', return_value=7) as recorder:
            assert subject.main() == 7
            recorder.assert_called_once_with('audit', 7, 'full', 'fixture-input')
        input_self_test()
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
        try:
            subject.compilation_condition('canImport(UnregisteredFramework)', 'all')
        except ValueError:
            pass
        else:
            raise AssertionError('未知框架需要明确登记可用性')
        assert subject.compilation_condition('os(iOS) && targetEnvironment(macCatalyst) && canImport(UIKit)', 'catalyst')
        assert subject.compilation_condition('os(iOS) && !targetEnvironment(macCatalyst)', 'all')
        assert subject.compilation_condition('DEBUG || RELEASE_NETWORK_SMOKE', 'all')
        assert not subject.compilation_condition('os(macOS) || targetEnvironment(macCatalyst)', 'all')
        assert subject.compilation_condition('BIT101_UI_TESTING && !targetEnvironment(macCatalyst)', 'ui')
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

        def icloud_summary(value):
            return subject.smoke_summary('icloud', dict(validatedDomains=sorted(subject.ICLOUD_DOMAINS), cloudKitEnvironment='Production', **value))
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
        summaries['modules']['coverage'] = {name: {'coveredLines': floor, 'executableLines': 100} for name, floor in subject.MODULE_COVERAGE_FLOORS.items()}
        summaries['all']['coverage'] = {'BIT101-iOS.app': {'coveredLines': 35, 'executableLines': 100}}
        summaries['all']['coverage'].update({'iOS/' + name: {'coveredLines': floor, 'executableLines': 100} for name, floor in subject.IOS_MODULE_COVERAGE_FLOORS.items()})
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
        summaries['audit'] = {'passed': True, 'kind': 'audit'}
        summaries['restore'] = {'passed': True, 'kind': 'restore'}
        summaries['build-archive'] = {'passed': True, 'kind': 'build'}
        from validation_manual import capture, complete
        checks = {}
        for name in subject.MANUAL_DEVICE_CHECKS: checks[name] = captured_fixture(name)
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
            try: capture('操作', '结果', Path('/missing'), 'photos')
            except FileNotFoundError: pass
            else: raise AssertionError('人工证据需要已有附件')
        for field, value in [('dataBase64', ''), ('dataBase64', 'bad%base64'), ('dataBase64', 'b3RoZXI='), ('sha256', 'a' * 64), ('byteCount', 1)]:
            changed = json.loads(json.dumps(checks))
            next(iter(changed.values()))['evidence'][field] = value
            assert not complete(changed)
        assert not subject.complete_summary('manual-device', {'passed': True, 'checks': {}})
        assert not subject.complete_summary('manual-device', {'passed': True, 'checks': {name: 'pass' for name in subject.MANUAL_DEVICE_CHECKS}})
        summaries['network'] = subject.smoke_summary('network', {'passed': True, 'scope': 'all', 'executedProbes': sorted(subject.network_inventory()), 'requiredProbes': sorted(subject.network_inventory())})
        sms = {'passed': True, 'scope': 'school', 'executedProbes': sorted(subject.network_inventory('school')), 'requiredProbes': sorted(subject.network_inventory('school')), 'schoolSMSCoverage': 'verified', 'verifiedSMSProbes': [{'purpose': purpose, 'probe': sorted(subject.SCHOOL_SMS_PROBES[purpose])[0]} for purpose in subject.school_sms_inventory()]}
        sms.update(authenticatedSchoolProbes=sms['verifiedSMSProbes'], requestedSMSPurposes=sorted(subject.school_sms_inventory()))
        assert set(subject.SCHOOL_SMS_PROBES) == subject.school_sms_inventory()
        writes = {'passed': True, 'scope': 'community-writes', 'executedProbes': sorted(subject.network_inventory('community-writes')), 'requiredProbes': sorted(subject.network_inventory('community-writes')), 'communityWriteEvidence': ['服务端确认删除 poster1', '服务端确认删除 paper2', '点赞恢复 poster1', '点赞恢复 paper2', '点赞恢复 course3'] + [f'服务端确认删除 comment{id}' for id in range(10, 16)] + [f'创建 comment{id} 目标 {parent}' for id, parent in [(10, 'poster1'), (11, 'comment10'), (12, 'paper2'), (13, 'comment12'), (14, 'course3'), (15, 'comment14')]]}
        assert subject.community_writes_complete(writes['communityWriteEvidence'])
        assert not subject.community_writes_complete(writes['communityWriteEvidence'][:5] + ['服务端确认删除 comment42'] * 6)
        assert not subject.community_writes_complete([item.replace('目标 comment14', '目标 comment10') for item in writes['communityWriteEvidence']])
        assert not subject.community_writes_complete([item.replace('创建 comment15', '创建 comment14') for item in writes['communityWriteEvidence']])
        cleanup = {'passed': True, 'scope': 'community-cleanup', 'executedProbes': sorted(subject.network_inventory('community-cleanup')), 'requiredProbes': sorted(subject.network_inventory('community-cleanup'))}
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
        full_sms = dict(sms, scope='all', requiredProbes=sorted(subject.network_inventory('all')), executedProbes=sorted(subject.network_inventory('all')))
        assert subject.smoke_summary('network', full_sms)['passed']
        projected = subject.smoke_summary('school-sms', full_sms)
        assert subject.complete_summary('school-sms', projected)
        assert projected['scope'] == 'school' and set(projected['requiredProbes']) == subject.network_inventory('school')
        assert not subject.smoke_summary('school-sms', dict(full_sms, requiredProbes=sms['requiredProbes']))['passed']
        assert not subject.smoke_summary('school-sms', dict(full_sms, verifiedSMSProbes=[]))['passed']

        mismatched = [{'purpose': step['purpose'], 'probe': 'BIT101 登录状态'} for step in sms['verifiedSMSProbes']]
        assert not subject.smoke_summary('school-sms', dict(sms, verifiedSMSProbes=mismatched))['passed']
        assert subject.smoke_summary('school-sms', dict(sms, schoolSMSCoverage='preflight_only'))['passed'] is False
        assert subject.smoke_summary('school-sms', dict(sms, verifiedSMSProbes=sms['verifiedSMSProbes'][:1]))['passed'] is False
        summaries['icloud'] = icloud_summary({'exitCode': 0, 'stages': [dict(test, stage=name, totalTestCount=1, exitCode=0) for name in ('testPhoneRoundTrip', 'testMacReceiveAndRestore')]})
        assert summaries['icloud']['cleanup']['kind'] == 'round-trip'
        assert not subject.complete_summary('icloud', dict(summaries['icloud'], cleanup={'exitCode': 1}))
        groups = {name: {'exitCode': 0, 'scope': 'full', 'summary': summary, 'inputDigest': subject.source_digest(name), 'environment': subject.environment_context(name)} for name, summary in summaries.items()}
        for name in subject.LIVE_GROUPS & groups.keys():
            groups[name]['summary'].update(startedAt=subject.utc_now().isoformat(), finishedAt=subject.utc_now().isoformat())
        report = {'sourceDigest': 'source', 'groups': groups}
        with patch('ui_rules.source_runtime_interaction_findings', return_value=[]):
            assert subject.release_findings(report, 'source') == []
            with patch(f'{module_name}.environment_context', return_value=dict(fixture_environment, host={'system': 'changed'})):
                assert subject.release_findings(report, 'source')
                assert subject.release_findings(report, 'source', recorded_environment=True) == []
                from contextlib import nullcontext, redirect_stdout
                from io import StringIO
                for recorded, expected in ((False, '待复验'), (True, '通过')):
                    output = StringIO()
                    arguments = ['validation_evidence.py', 'summary'] + (['--recorded-environment'] if recorded else [])
                    with patch.object(subject, 'report_lock', side_effect=nullcontext), patch.object(Path, 'is_file', return_value=True), \
                            patch.object(Path, 'read_text', return_value=json.dumps({'groups': {'modules': groups['modules']}})), \
                            patch.object(sys, 'argv', arguments), patch.dict(os.environ, GITHUB_STEP_SUMMARY=''), redirect_stdout(output):
                        assert subject.main() == 0
                    assert f'| modules | full | {expected} |' in output.getvalue()
            with patch(f'{module_name}.environment_context', return_value=dict(fixture_environment, xcode={'version': 'changed'})):
                assert subject.release_findings(report, 'source', recorded_environment=True)
        assert subject.release_findings(report, 'changed')
        groups['ui']['scope'] = 'selected'
        assert subject.release_findings(report, 'source')
        groups['ui']['scope'] = 'full'
        groups['ui']['summary']['passedTests'] = 0
        assert subject.release_findings(report, 'source')
        module = subject.test_summary('测试通过：3 项\n统计范围：macOS\n- ScheduleSync: 75.00% (3/4 lines)')
        assert module['passed'] and module['coverage']['ScheduleSync']['coveredLines'] == 3
        assert subject.test_summary('总计 4；通过 3；失败 0；跳过 1')['passed'] is False
        assert subject.test_summary('总计 0；通过 0；失败 0；跳过 0')['passed'] is False
        assert subject.complete_summary('ui', dict(test, executedTests=['Fixture/example'])) is False
        summaries['ui']['passedTests'] = summaries['ui']['totalTests']
        summaries['ui']['uiInventory']['pending'] = ['new-control']
        assert subject.complete_summary('ui', summaries['ui']) is False
        network = {'passed': True, 'scope': 'all', 'executedProbes': sorted(subject.network_inventory()), 'requiredProbes': sorted(subject.network_inventory())}
        assert subject.smoke_summary('network', network)['passed']
        assert subject.smoke_summary('network', {'passed': True, 'scope': 'all', 'executedProbes': ['unrelated']})['passed'] is False
        network['coverageGaps'] = ['fixture']
        assert subject.smoke_summary('network', network)['passed'] is False
        ddl = {'passed': True, 'scope': 'ddl', 'executedProbes': sorted(subject.network_inventory('ddl')), 'requiredProbes': sorted(subject.network_inventory('ddl'))}
        assert len(subject.network_inventory('ddl')) == 5 and subject.smoke_summary('ddl', ddl)['passed']
        ddl_summary = subject.smoke_summary('ddl', ddl)
        assert subject.complete_summary('ddl', ddl_summary)
        network_recording_self_test(subject, {'network': network, 'ddl': ddl, 'school-sms': sms,
            'community-writes': writes, 'community-cleanup': cleanup})

        ddl['skippedProbes'] = ['课程中心 DDL 下载']
        assert subject.smoke_summary('ddl', ddl)['passed'] is False
        assert icloud_summary({'exitCode': 0, 'stages': []})['passed'] is False
        stages = [{'stage': name, 'exitCode': 0, 'totalTestCount': 1, 'passedTests': 1} for name in ['testPhoneRoundTrip', 'testMacReceiveAndRestore']]
        assert icloud_summary({'exitCode': 0, 'stages': stages})['passed']
        assert subject.smoke_summary('icloud', {'exitCode': 0, 'stages': stages})['passed'] is False
        cleanup = dict(stages[0], stage='testCleanup', failedTests=0, skippedTests=0)
        assert icloud_summary({'exitCode': 0, 'stages': stages, 'cleanup': cleanup, 'cleanupExitCode': 0})['passed']
        assert icloud_summary({'exitCode': 0, 'stages': stages, 'cleanup': cleanup, 'cleanupExitCode': 1})['passed'] is False
        cleanup['passedTests'] = 0
        assert icloud_summary({'exitCode': 0, 'stages': stages, 'cleanup': cleanup})['passed'] is False
        assert not subject.smoke_summary('icloud-cleanup', {'cleanup': cleanup, 'cleanupExitCode': 0})['passed']
        cleanup['passedTests'] = 1
        assert subject.smoke_summary('icloud-cleanup', {'exitCode': 1, 'cleanup': cleanup, 'cleanupExitCode': 0})['passed']
        stages[1]['passedTests'] = 0
        assert icloud_summary({'exitCode': 0, 'stages': stages})['passed'] is False
        return 0


def network_recording_self_test(subject, results) -> None:
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    from unittest.mock import patch
    from validation_environment import DEVICE_GROUPS
    assert set(results) == subject.NETWORK_GROUPS
    assert subject.NETWORK_GROUPS <= DEVICE_GROUPS
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
