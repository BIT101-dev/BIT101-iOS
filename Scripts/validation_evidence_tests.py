#!/usr/bin/env python3
"""Regression contracts for evidence inputs, inventories and release summaries."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch
from swift_source_index import swift_syntax_index_sources
from validation_provenance_tests import network_trace_fixture, network_route_identity_self_test

def request_body_shape_self_test() -> None:
    from copy import deepcopy
    from network_request_contracts import complete
    cases = (
        ('feedback.recovery', '/api/error-reports', {'mode', 'runID'}),
        ('schedule.sync', 'cxzkbrq.do', {'requestParamStr', 'requestParamStr.XNXQDM', 'requestParamStr.ZC'}),
        ('schedule.sync', 'cxxsksap.do', {'XNXQDM', '*order'}),
        ('community.writes', '/reaction/comments', {'obj', 'text', 'anonymous', 'image_mids', 'rate'}),
        ('community.writes', '/reaction/like', {'obj'}),
        ('lexue.calendar', 'export.php', {'sesskey', '_qf__core_calendar_export_form', 'events[exportevents]', 'period[timeperiod]', 'generateurl'}))
    for probe, suffix, required in cases:
        trace = network_trace_fixture({'requiredProbes': [probe]})['requestEvidence'][0]
        assert complete(probe, trace['requests'], trace['expectedParameters'])
        if probe == 'feedback.recovery':
            assert not complete(probe, [dict(trace['requests'][0], query={'mode': 'raw'}, finalQuery={'mode': 'raw'})])
        for field in ('bodyParameterNames', 'finalBodyParameterNames'):
            for name in required:
                rows = deepcopy(trace['requests'])
                changed = [row for row in rows if row['method'] == 'POST' and row['endpoint'].endswith(suffix)
                    and (name != 'rate' or row.get('query', {}).get('obj', '').startswith('course'))]
                assert changed, (probe, name)
                for row in changed: row[field] = sorted(set(row[field]) - {name})
                assert not complete(probe, rows, trace['expectedParameters']), (probe, field, name)
    trace = network_trace_fixture({'requiredProbes': ['community.writes']})['requestEvidence'][0]
    for missing in ({'reply_obj'}, {'reply_uid'}, {'reply_obj', 'reply_uid'}):
        rows = deepcopy(trace['requests'])
        for row in rows:
            if row['method'] == 'POST' and row.get('query', {}).get('obj', '').startswith('comment'):
                for field in ('bodyParameterNames', 'finalBodyParameterNames'): row[field] = sorted(set(row[field]) - missing)
        assert not complete('community.writes', rows, trace['expectedParameters']), missing

def package_condition_self_test() -> None:
    from validation_compilation import compilation_condition, active_network_source
    from network_capability_rules import business_methods
    path = 'Modules/GalleryFeature/Sources/Service.swift'
    assert compilation_condition('SWIFT_PACKAGE && !Xcode && !SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE', 'modules', path=path)
    for platform in ('iOS', 'watchOS', 'macCatalyst'):
        assert compilation_condition('SWIFT_PACKAGE && Xcode && SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE', 'restore', platform=platform, path=path)
    assert not compilation_condition('SWIFT_PACKAGE || Xcode || SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE', 'restore', path='BIT101-iOS/Shell/AppAccountLifecycle.swift')
    for condition in ('SWIFT_PACKAGE', 'Xcode', 'SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE'):
        source = 'import Foundation\npublic struct Service {\npublic func fetch() async throws {\n#if ' + condition + '\n_ = try await URLSession.shared.data(from: url)\n#endif\n}\n}'
        assert 'URLSession.shared.data' in active_network_source(source, path)
        assert 'GalleryFeature.Service' in business_methods(swift_syntax_index_sources({path: source})), condition

def additional_network_probe_self_test() -> None:
    from copy import deepcopy
    from validation_provenance import network_requests_complete
    required = {'profile.mine'}
    proof = network_trace_fixture({'requiredProbes': sorted(required)})
    extra = network_trace_fixture({'requiredProbes': ['message.comment']})['requestEvidence'][0]
    assert network_requests_complete(required, dict(proof, requestEvidence=proof['requestEvidence'] + [extra]))
    for probe in ('unregistered.write', 'message.unknown', 'message.comment'):
        changed = deepcopy(extra)
        changed['probe'] = probe
        if probe != 'message.unknown':
            for request in changed['requests']:
                request.update(endpoint='https://unregistered.invalid/write', finalEndpoint='https://unregistered.invalid/write',
                    method='POST', finalMethod='POST', query={}, finalQuery={})
        assert not network_requests_complete(required, dict(proof, requestEvidence=proof['requestEvidence'] + [changed])), probe

def sms_request_mode_self_test() -> None:
    from copy import deepcopy
    from network_request_contracts import complete
    from validation_provenance import network_requests_complete
    for probe, endpoint, fields, purpose in (
            ('profile.mine', 'https://sso.bit.edu.cn/cas/api/protected/sms/publicNoToken/sendSmsCode', ['phone', 'businessNo'], 'school_sso_second_factor'),
            ('eclass.authentication', 'https://sso.bit.edu.cn/cas/api/protected/sms/publicNoToken/sendSmsCode', ['phone', 'businessNo'], 'school_sso_second_factor'),
            ('eclass.authentication', 'https://sso.bit.edu.cn/cas/api/protected/sms/checkToken', ['phone', 'token', 'delete', 'trustDevice'], 'school_sso_second_factor'),
            ('score.authentication', 'https://login.bit101.flwfdd.xyz/api/auth/fixture/sms', ['code'], 'jwb')):
        required = {probe}
        proof = network_trace_fixture({'requiredProbes': [probe]})
        row = proof['requestEvidence'][0]
        row['requests'].append(dict(endpoint=endpoint, finalEndpoint=endpoint, method='POST', finalMethod='POST',
            query={}, finalQuery={}, statusCode=200, bodyParameterNames=fields, finalBodyParameterNames=fields))
        assert not complete(probe, row['requests'], row['expectedParameters'])
        assert not network_requests_complete(required, proof)
        proof.update(schoolSMSCoverage='verified', requestedSMSPurposes=[purpose],
            verifiedSMSProbes=[{'probe': probe, 'purpose': purpose}])
        allowed = probe != 'profile.mine'
        assert complete(probe, row['requests'], row['expectedParameters'], allow_sms=True) == allowed
        assert network_requests_complete(required, proof) == allowed
        if allowed:
            for changes in ({'schoolSMSCoverage': 'preflight_only'}, {'verifiedSMSProbes': []},
                    {'requestedSMSPurposes': []}, {'verifiedSMSProbes': [{'probe': 'profile.mine', 'purpose': purpose}]}):
                assert not network_requests_complete(required, dict(deepcopy(proof), **changes))

def icloud_stage_fixture(stage: str, counts: dict) -> dict:
    return dict(counts, stage=stage, runID='fixture', executedTests=['ICloudCrossDeviceSmokeTests/' + stage],
        testTargets=['BIT101-iOSTests'], destination={'platform': 'macOS' if stage.startswith('testMac') else 'iOS', 'deviceIdentifier': 'phone'})

@patch.dict(os.environ, GITHUB_ACTIONS='false', GITHUB_SHA='')
def run_self_test(subject) -> int:
    from validation_provenance_tests import test_identity_self_test, probe_identity_self_test
    test_identity_self_test()
    probe_identity_self_test(subject)
    package_condition_self_test()
    additional_network_probe_self_test()
    sms_request_mode_self_test()
    from validation_manual_tests import registration_self_test
    registration_self_test(subject)
    network_scope_boolean_self_test(subject)
    developer_directory_self_test()
    from validation_compilation import self_test as compilation_cache_self_test
    compilation_cache_self_test()
    module_events_self_test(subject)
    native_cases_self_test(subject)
    summary_status_self_test(subject)
    from validation_test_areas import formal_inventory_self_test
    formal_inventory_self_test()
    network_route_identity_self_test()
    request_body_shape_self_test()
    module_name = subject.__name__
    original_is_file = Path.is_file
    from validation_environment import host_environment
    from validation_environment import ci_commit_findings
    with patch.dict(os.environ, GITHUB_SHA='a' * 40):
        assert ci_commit_findings('a' * 40) == []
        assert ci_commit_findings('b' * 40)
    with patch.dict(os.environ, GITHUB_SHA='', GITHUB_ACTIONS='true'):
        assert ci_commit_findings('a' * 40)
    for changed in (b'', b' M Modules/Feature/Sources/Service.swift\0', b'?? Modules/Feature/Sources/Residual.swift\0'):
        with patch.dict(os.environ, GITHUB_SHA='a' * 40, GITHUB_ACTIONS='true'), patch.object(subprocess, 'check_output', return_value=changed):
            assert bool(ci_commit_findings('a' * 40)) == bool(changed)
    selected_compiler = '/fixture/Xcode/Toolchains/selected/usr/bin/swift-frontend'
    with patch.dict(os.environ, SWIFT_FRONTEND='/other/swift-frontend', SWIFT='/other/swift'), \
            patch.object(subprocess, 'check_output', return_value=selected_compiler) as lookup, patch.object(Path, 'is_file', return_value=False):
        assert host_environment.__wrapped__()['compiler']['path'] == selected_compiler
        lookup.assert_called_once_with(['xcrun', '--find', 'swift-frontend'], text=True)
    from validation_inputs import self_test as input_self_test
    fixture_environment = {'host': {'system': 'fixture'}, 'developer': '/fixture', 'xcode': {'version': 'fixture'}, 'compiler': {'path': '/fixture/swift-frontend', 'modified': 1, 'size': 100, 'sha256': 'a' * 64}, 'sdks': {'fixture': {'Version': '1'}}, 'device': {'identifier': 'fixture-phone', 'systemVersion': 'fixture-os', 'systemBuild': 'fixture-build'}}
    fixture_environment['runtimes'] = {name: 'fixture-version' for name in ('python', 'ruby', 'node', 'npm', 'ruff')}
    with patch(f'{module_name}.environment_context', return_value=fixture_environment), \
            patch('validation_merge.environment_context', return_value=fixture_environment), \
            patch('validation_provenance.environment_context', return_value=fixture_environment), \
            patch('validation_merge.result_bundle_findings', side_effect=lambda *args, **kwargs: []), \
            patch(f'{module_name}.result_bundle_findings', side_effect=lambda *args, **kwargs: []), \
            patch('validation_merge.performance_findings', return_value=[]):
        from validation_provenance_tests import run_self_test as provenance_self_test
        from validation_test_areas import inventory_findings
        provenance_self_test(subject.record)
        from validation_manual_tests import run_self_test as manual_self_test, captured_fixture, distribution_fixture
        manual_self_test()
        from validation_performance_tests import run_self_test as performance_self_test
        performance_self_test()
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
        regressed = json.loads(json.dumps(core))
        regressed['coverageBaseCommit'] = 'base'
        regressed['coveragePolicy'] = {'all': {'GalleryFeature': 50}}
        regressed['groups']['ui']['runID'] = 'ui-run'
        regressed['groups']['ui']['summary'] = {'passed': True,
            'coverage': {'iOS/GalleryFeature': {'coveredLines': 20, 'executableLines': 100}}}
        assert any('ui 覆盖率退化' in error for error in merge_findings(regressed,
            digest=lambda *args, **kwargs: 'digest', complete=lambda *args: True, commit='commit'))
        from contextlib import nullcontext, redirect_stderr, redirect_stdout
        from io import StringIO
        for action, expected in (('check-group', 1), ('summary', 0)):
            output = StringIO()
            arguments = ['validation_evidence.py', action] + (['ui'] if action == 'check-group' else [])
            with patch.object(subject, 'report_lock', side_effect=nullcontext), patch.object(Path, 'is_file', return_value=True), \
                    patch.object(Path, 'read_text', return_value=json.dumps(regressed)), patch.object(sys, 'argv', arguments), \
                    patch.object(subject, 'source_digest', return_value='digest'), patch.object(subject, 'evidence_current', return_value=True), \
                    patch.object(subject, 'complete_summary', return_value=True), patch.dict(os.environ, GITHUB_STEP_SUMMARY=''), \
                    redirect_stdout(output), redirect_stderr(output):
                assert subject.main() == expected
            if action == 'summary': assert '| ui | full | 待处理 |' in output.getvalue()
        from validation_restore import invalidate as invalidate_restore
        from contextlib import nullcontext
        import validation_provenance as evidence_state
        with patch.object(evidence_state, 'report_lock', side_effect=nullcontext), patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_text', return_value=json.dumps(core)), patch.object(evidence_state, 'write_report') as saved:
            invalidate_restore()
            interrupted = saved.call_args.args[0]
            assert any(error.startswith('restore ') for error in merge_findings(interrupted,
                digest=lambda *args, **kwargs: 'digest', complete=lambda *args: True, commit='commit'))
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
                with patch('validation_provenance.environment_context', return_value=dict(fixture_environment, **{field: value})):
                    assert subject.source_digest('ui') != baseline
            assert not subject.complete_environment('ui', dict(fixture_environment, device=None))
            assert not subject.complete_environment('audit', {})
            audit_digest = subject.source_digest('audit')
            for name in fixture_environment['runtimes']:
                runtimes = dict(fixture_environment['runtimes'], **{name: 'changed-version'})
                with patch('validation_provenance.environment_context', return_value=dict(fixture_environment, runtimes=runtimes)):
                    assert subject.source_digest('audit') != audit_digest
                for value in ('', None):
                    assert not subject.complete_environment('audit', dict(fixture_environment,
                        runtimes=dict(runtimes, **{name: value})))
                del runtimes[name]
                assert not subject.complete_environment('audit', dict(fixture_environment, runtimes=runtimes))
        assert subject.compilation_condition('os(macOS) && !canImport(UIKit)', 'modules')
        assert subject.compilation_condition('canImport(SwiftUI) && canImport(AppKit)', 'modules')
        for group in ('modules', 'all', 'catalyst', 'ui'):
            assert subject.compilation_condition('canImport(MapKit) && canImport(WidgetKit) && canImport(CoreLocation)', group)
        assert not subject.compilation_condition('canImport(UnregisteredFramework)', 'all')
        from validation_compilation import local_import_conditions
        for condition in ('canImport(StorageCore, _version: 0.0)', 'canImport(StorageCore, _version: 1.0)',
                          'canImport(StorageCore, _underlyingVersion: 1.0)'):
            try:
                local_import_conditions(condition, 'Modules/MediaKit/Sources/MediaEnvironment.swift')
            except ValueError as error:
                assert '显式版本编译上下文' in str(error)
            else:
                raise AssertionError('本地版本条件应进入显式诊断')
        assert local_import_conditions('canImport(Foundation, _version: 0.0)') == 'canImport(Foundation, _version: 0.0)'
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
            subject.test_selectors.cache_clear()
            subject.test_inventory.cache_clear()
            errors = []
            with patch.object(Path, 'rglob', lambda path, pattern: iter([sample_path]) if path == ui_root else original_rglob(path, pattern)), patch.object(Path, 'read_text', sample_read):
                check_ui_test_inventory(errors, {})
            assert 'UI interaction map missing: FormatUITests/testAdded' in errors
            selector = re.search("bit101_ui_test_selections\\(\\).*?<<'PY'\\n(.*?)\\nPY", (subject.ROOT / 'Scripts/script-support.sh').read_text(), re.DOTALL)[1]
            with patch('validation_evidence.test_inventory', return_value={'FormatUITests/testAdded'}), patch.object(sys, 'argv', ['selector', str(subject.ROOT / 'Scripts'), 'Added', 'FormatUITests']), patch('builtins.print') as output:
                exec(compile(selector, '<ui selector>', 'exec'), {})
            output.assert_called_once_with('FormatUITests/testAdded')
        subject.test_selectors.cache_clear()
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
        with patch('validation_provenance.repository_input_names', return_value=list(inputs)), \
                patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_bytes', lambda path: inputs[path.relative_to(subject.ROOT).as_posix()]), \
                patch.object(Path, 'stat', return_value=SimpleNamespace(st_mode=420)):
            for name in inputs:
                before = {group: subject.source_digest(group, environment={}) for group in groups}
                inputs[name] += b' changed facts'
                assert all((subject.source_digest(group, environment={}) != before[group]) == (group != 'manual-device') for group in groups), name

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
        with patch(module_name + '.test_inventory', return_value={'Outer/Inner/works'}), patch(module_name + '.test_case_inventory', return_value={'Outer/Inner/works': 1}), patch(module_name + '.coverage_complete', return_value=True):
            for identifier in ('Package.Outer/Inner/works()', 'Package.Outer/Inner/works()/Example.swift:1:1'):
                assert subject.complete_summary('schedule', native_case_fixture(dict(test, executedTests=[identifier]), {'Outer/Inner/works': 1}))
        summaries = {name: dict(test, totalTests=len(subject.test_inventory(name)), passedTests=len(subject.test_inventory(name)), executedTests=sorted(subject.test_inventory(name))) for name in ('modules', 'all', 'release-runtime', 'catalyst', 'catalyst-release-runtime', 'ui')}
        for name in summaries.keys() - {'modules'}:
            summaries[name] = native_case_fixture(summaries[name], subject.test_case_inventory(name), name)
        summaries['modules']['testCases'] = {'total': len(summaries['modules']['executedTests']),
            'byTest': {name: 1 for name in summaries['modules']['executedTests']},
            'expectedByTest': {name: 1 for name in summaries['modules']['executedTests']}}
        summaries['modules']['coverage'] = {name: {'coveredLines': floor, 'executableLines': 100} for name, floor in subject.MODULE_COVERAGE_FLOORS.items()}
        summaries['all']['coverage'] = {'BIT101-iOS.app': {'coveredLines': 35, 'executableLines': 100}}
        summaries['all']['coverage'].update({'iOS/' + name: {'coveredLines': floor, 'executableLines': 100} for name, floor in subject.IOS_MODULE_COVERAGE_FLOORS.items()})
        summaries['ui']['coverage'] = dict(summaries['all']['coverage'])
        summaries['catalyst']['coverage'] = {'BIT101-iOS.app': {'coveredLines': 35, 'executableLines': 100}}
        summaries['catalyst']['coverage'].update({'Catalyst/' + name: {'coveredLines': floor, 'executableLines': 100}
            for name, floor in subject.IOS_MODULE_COVERAGE_FLOORS.items() if name != 'ScheduleActivityContracts'})
        summaries['catalyst-release-runtime']['coverage'] = dict(summaries['catalyst']['coverage'])
        for group in ('catalyst', 'catalyst-release-runtime'):
            assert subject.coverage_complete(group, summaries[group])
            assert not subject.coverage_complete(group, dict(summaries[group], coverage={}))
            for name in ('BIT101-iOS.app', 'Catalyst/TransportCore', 'Catalyst/StorageCore'):
                changed = dict(summaries[group]['coverage'])
                changed[name] = {'coveredLines': 0, 'executableLines': 100}
                assert not subject.coverage_complete(group, dict(summaries[group], coverage=changed))
        assert subject.coverage_complete('ui', summaries['ui'])
        assert not subject.coverage_complete('ui', dict(summaries['ui'], coverage={}))
        ui_missing = dict(summaries['ui']['coverage'])
        ui_missing['iOS/ScoreFeature'] = {'coveredLines': 0, 'executableLines': 100}
        assert not subject.coverage_complete('ui', dict(summaries['ui'], coverage=ui_missing))
        for name in ('iOS/CommunityUI', 'iOS/CourseFeature', 'iOS/ScoreFeature', 'iOS/MediaKit', 'iOS/DesignSystemKit', 'BIT101-iOS.app'):
            weak = dict(summaries['ui']['coverage'])
            weak[name] = {'coveredLines': 1, 'executableLines': 100}
            assert not subject.coverage_complete('ui', dict(summaries['ui'], coverage=weak))
            weak.pop(name)
            assert not subject.coverage_complete('ui', dict(summaries['ui'], coverage=weak))
        assert subject.coverage_complete('all', summaries['all'])
        ios_missing = dict(summaries['all']['coverage'])
        ios_missing.pop('iOS/MediaKit')
        assert not subject.coverage_complete('all', dict(summaries['all'], coverage=ios_missing))
        ios_missing['iOS/MediaKit'] = {'coveredLines': 52, 'executableLines': 100}
        assert not subject.coverage_complete('all', dict(summaries['all'], coverage=ios_missing))
        assert subject.coverage_complete('modules', summaries['modules'])
        for group in ('modules', 'all', 'ui'):
            for field in ('coveredLines', 'executableLines'):
                for value in (True, False, 1.0, '1', None):
                    malformed = {name: dict(row, **{field: value}) for name, row in summaries[group]['coverage'].items()}
                    assert not subject.coverage_complete(group, dict(summaries[group], coverage=malformed)), (group, field, value)
        for field in ('totalTests', 'passedTests', 'failedTests', 'skippedTests'):
            counts = {'totalTests': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}
            assert subject.successful_test_counts(counts)
            assert not subject.successful_test_counts(dict(counts, **{field: bool(counts[field])})), field
        assert not subject.coverage_complete('modules', dict(summaries['modules'], coverage={}))
        missing = dict(summaries['modules']['coverage'])
        missing.pop('ScheduleSync')
        assert not subject.coverage_complete('modules', dict(summaries['modules'], coverage=missing))
        missing['ScheduleSync'] = {'coveredLines': 0, 'executableLines': 100}
        assert not subject.coverage_complete('modules', dict(summaries['modules'], coverage=missing))
        missing['ScheduleSync'] = {'coveredLines': 75, 'executableLines': 100}
        assert not subject.coverage_complete('modules', dict(summaries['modules'], coverage=missing))
        summaries['ui']['uiInventory'] = {'observed': 1, 'visited': 1, 'pending': [], 'scope': 'mounted-controls', 'unidentifiedControls': 0, 'pendingDisabled': [], 'identityScope': 'testCaseNavigationPresentationAndOccurrence'}
        summaries['audit'] = {'passed': True, 'kind': 'audit', 'releaseVersionChecked': True,
            'startedAt': subject.utc_now().isoformat(), 'finishedAt': subject.utc_now().isoformat()}
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
        writes = network_trace_fixture({'passed': True, 'scope': 'community-writes', 'executedProbes': sorted(subject.network_inventory('community-writes')), 'requiredProbes': sorted(subject.network_inventory('community-writes')), 'communityWriteEvidence': ['验收账号 user1', '服务端确认删除 poster1', '服务端确认删除 paper2', '点赞恢复 poster1', '点赞恢复 paper2', '点赞恢复 course3', '图片提交 poster1', '图片提交 comment10', '关注恢复 user4', '定向回复 poster 目标 comment11', '定向回复 paper 目标 comment14', '定向回复 course 目标 comment17'] + [f'服务端确认删除 comment{id}' for id in range(10, 19)] + [f'创建 comment{id} 目标 {parent}' for id, parent in [(10, 'poster1'), (11, 'comment10'), (12, 'comment10'), (13, 'paper2'), (14, 'comment13'), (15, 'comment13'), (16, 'course3'), (17, 'comment16'), (18, 'comment16')]]})
        assert subject.community_writes_complete(writes['communityWriteEvidence'])
        write_test = {'ReleaseNetworkSmokeLifecycleTests/communityWritesCleanAfterLostResponsesCancellationAndResume'}
        attachment = {'attachments': [{'name': 'community-write-contract.json', 'payloadId': 'proof'}]}
        with patch.object(subject.subprocess, 'check_output', side_effect=[json.dumps(attachment), json.dumps(writes['communityWriteEvidence'])]):
            subject.validate_community_write_test_output(Path('/fixture'), write_test)
        subject.validate_community_write_test_output(Path('/fixture'), set())
        for activities, evidence in [({}, '[]'), (attachment, '[]'), (attachment, 'invalid')]:
            with patch.object(subject.subprocess, 'check_output', side_effect=[json.dumps(activities), evidence]):
                try: subject.validate_community_write_test_output(Path('/fixture'), write_test)
                except ValueError: pass
                else: raise AssertionError('Swift 与 Python 需要共同确认实际写入证据')
        assert not subject.community_writes_complete(writes['communityWriteEvidence'][:5] + ['服务端确认删除 comment42'] * 9)
        assert not subject.community_writes_complete([item.replace('目标 comment16', '目标 comment10') for item in writes['communityWriteEvidence']])
        assert not subject.community_writes_complete([item.replace('创建 comment18', '创建 comment17') for item in writes['communityWriteEvidence']])
        assert not subject.community_writes_complete([item for item in writes['communityWriteEvidence'] if not item.startswith('定向回复 course')])
        assert not subject.community_writes_complete([item.replace('定向回复 course 目标 comment17', '定向回复 course 目标 comment11') for item in writes['communityWriteEvidence']])
        assert not subject.community_writes_complete([item for item in writes['communityWriteEvidence'] if item not in {'创建 comment12 目标 comment10', '创建 comment15 目标 comment13', '创建 comment18 目标 comment16', '服务端确认删除 comment12', '服务端确认删除 comment15', '服务端确认删除 comment18'}])
        cleanup = network_trace_fixture({'passed': True, 'scope': 'community-cleanup', 'executedProbes': sorted(subject.network_inventory('community-cleanup')), 'requiredProbes': sorted(subject.network_inventory('community-cleanup'))})
        assert subject.smoke_summary('community-cleanup', cleanup)['passed']
        assert not subject.smoke_summary('community-writes', cleanup, full=False)['passed']
        selection_source = '''import Testing; import XCTest
            struct Suite { @Test func first() {}; @Test(arguments: [1]) func second(_ value: Int) {} }
            class Other: XCTestCase { func testThird() {} }'''
        with patch.object(Path, 'rglob', return_value=[Path('selection-contract.swift')]), \
                patch.object(Path, 'read_text', return_value=selection_source):
            selectors = subject.test_selectors.__wrapped__('all')
        assert selectors == {'Suite/first': 'Suite/first()', 'Suite/second': 'Suite/second(_:)', 'Other/testThird': 'Other/testThird'}
        with patch(f'{module_name}.test_selectors', return_value=selectors), \
                patch(f'{module_name}.test_inventory', return_value=set(selectors)):
            assert subject.xcode_test_selections('all', ['Suite/first', 'Suite/second', 'Other/testThird']) \
                == ['Suite/first()', 'Suite/second(_:)', 'Other/testThird']
            assert subject.xcode_test_selections('all', ['Suite', 'Suite/first()', 'Suite/first']) == ['Suite', 'Suite/first()']
            try:
                subject.xcode_test_selections('all', ['Suite/missing'])
            except ValueError:
                pass
            else:
                raise AssertionError('Xcode 筛选需要匹配源码库存')
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
        with patch(module_name + '.test_case_inventory', return_value={name: 1 for name in expected}):
            chosen = native_case_fixture(chosen, {name: 1 for name in expected})
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
        assert not subject.smoke_summary('network', dict(full_sms, workerDeployments={}))['passed']
        projected = subject.smoke_summary('school-sms', full_sms)
        assert subject.complete_summary('school-sms', projected)
        assert projected['scope'] == 'school' and set(projected['requiredProbes']) == subject.network_inventory('school')
        peripheral = dict(full_sms, passed=False, failures=['[update.app-store] fixture failure'],
            coverageGaps=['必需探针缺失：update.app-store'], skippedProbes=['update.app-store（fixture）'])
        assert subject.complete_summary('school-sms', subject.smoke_summary('school-sms', peripheral))
        assert not subject.smoke_summary('school-sms', dict(peripheral, schoolSMSCoverage='pending'))['passed']
        assert not subject.smoke_summary('school-sms', dict(peripheral, authenticatedSchoolProbes=[]))['passed']
        assert not subject.smoke_summary('school-sms', dict(peripheral, failures=['[schedule.current-term] fixture failure']))['passed']
        assert not subject.smoke_summary('school-sms', dict(peripheral, failures=['网络 Smoke 报告写入失败：fixture']))['passed']
        assert not subject.smoke_summary('school-sms', dict(full_sms, passed=False))['passed']
        assert not subject.smoke_summary('school-sms', dict(full_sms, requiredProbes=sms['requiredProbes']))['passed']
        assert not subject.smoke_summary('school-sms', dict(full_sms, verifiedSMSProbes=[]))['passed']

        mismatched = [{'purpose': step['purpose'], 'probe': 'community.login'} for step in sms['verifiedSMSProbes']]
        assert not subject.smoke_summary('school-sms', dict(sms, verifiedSMSProbes=mismatched))['passed']
        assert subject.smoke_summary('school-sms', dict(sms, schoolSMSCoverage='preflight_only'))['passed'] is False
        assert subject.smoke_summary('school-sms', dict(sms, verifiedSMSProbes=sms['verifiedSMSProbes'][:1]))['passed'] is False
        summaries['icloud'] = icloud_summary({'exitCode': 0, 'stages': [icloud_stage_fixture(name, dict(test, totalTestCount=1, exitCode=0)) for name in ('testPhoneRoundTrip', 'testMacReceiveAndRestore')]})
        assert summaries['icloud']['cleanup']['kind'] == 'round-trip'
        assert summaries['icloud']['macCleanup']['kind'] == 'round-trip'
        assert summaries['icloud']['macCleanup']['kvsDeletion'] == 'peer-observed'
        assert subject.complete_summary('icloud', summaries['icloud'])
        for field, value in [('executedTests', ['Other/testAlwaysPass']), ('testTargets', ['Other']), ('destination', {'platform': 'iOS Simulator', 'deviceIdentifier': 'phone'}), ('runID', 'other')]:
            wrong = [dict(summaries['icloud']['stages'][0], **{field: value}), summaries['icloud']['stages'][1]]
            assert not subject.complete_summary('icloud', dict(summaries['icloud'], stages=wrong))
        assert not subject.complete_summary('icloud', dict(summaries['icloud'], cleanup={'exitCode': 1}))
        assert not subject.complete_summary('icloud', dict(summaries['icloud'], macCleanup={'exitCode': 1}))
        groups = {name: {'exitCode': 0, 'scope': 'full', 'summary': summary, 'runID': 'fixture', 'recordedAt': subject.utc_now().isoformat(),
            'inputDigest': subject.source_digest(name), 'environment': subject.environment_context(name)} for name, summary in summaries.items()}
        groups['build-archive']['runID'] = provenance['runID']
        groups['restore']['runID'] = summaries['restore']['runID']
        from validation_manual import artifact_bytes
        groups['catalyst-release-runtime']['application'] = json.loads(artifact_bytes(
            summaries['manual-device']['checks']['catalyst-desktop']['evidence']))['application']
        for name in subject.LIVE_GROUPS & groups.keys():
            groups[name]['summary'].update(startedAt=subject.utc_now().isoformat(), finishedAt=subject.utc_now().isoformat())
        report = {'sourceDigest': 'source', 'groups': groups}
        with patch('ui_rules.source_runtime_interaction_findings', return_value=[]):
            findings = subject.release_findings(report, 'source')
            assert not findings, findings
            regressed = json.loads(json.dumps(report))
            regressed['coveragePolicy'] = {'all': {'GalleryFeature': 50}}
            regressed['groups']['ui']['summary']['coverage']['iOS/GalleryFeature'] = {'coveredLines': 20, 'executableLines': 100}
            assert subject.coverage_complete('ui', regressed['groups']['ui']['summary'])
            assert any('ui 覆盖率退化' in error for error in subject.release_findings(regressed, 'source'))
            ordinary_audit = json.loads(json.dumps(report))
            ordinary_audit['groups']['audit']['summary']['releaseVersionChecked'] = False
            assert any('App Store 版本核对' in row for row in subject.release_findings(ordinary_audit, 'source'))
            for key, value in [('sha256', 'b' * 64), ('executableUUIDs', [])]:
                mismatched = json.loads(json.dumps(report))
                mismatched['groups']['catalyst-release-runtime']['application'][key] = value
                assert any('Catalyst 桌面专项' in error for error in subject.release_findings(mismatched, 'source'))
            older = json.loads(json.dumps(report))
            first = next(iter(older['groups']['build-archive']['summary']['executables'].values()))
            first[0]['uuid'] = '00000000-0000-4000-8000-000000000001'
            assert any('可执行文件 UUID' in error for error in subject.release_findings(older, 'source'))
            with patch(f'{module_name}.environment_context', return_value=dict(fixture_environment, host={'system': 'changed'})), \
                    patch('validation_provenance.environment_context', return_value=dict(fixture_environment, host={'system': 'changed'})):
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
        assert not subject.smoke_summary('network', dict(network, requestedTerm='2024-2025-1', validatedTerm='2024-2025-1'))['passed']
        assert not subject.smoke_summary('network', dict(network, validatedTerm='other'))['passed']
        assert not subject.smoke_summary('network', dict(network, currentTerm=None))['passed']
        historical = network_trace_fixture(dict(network, requestedTerm='2024-2025-1', validatedTerm='2024-2025-1'))
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

        ddl['skippedProbes'] = ['eclass.ddl']
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
        assert subject.smoke_summary('icloud-cleanup', restored)['macCleanup']['kvsDeletion'] == 'requested'
        assert subject.smoke_summary('icloud-cleanup', restored)['macCleanup']['cloudKitDeletion'] == 'server-confirmed'
        from datetime import datetime, timedelta, timezone
        instant = datetime.now(timezone.utc)
        restored.update(cleanupStartedAt=(instant - timedelta(minutes=3)).isoformat(), cleanupFinishedAt=instant.isoformat())
        for mac_first in (True, False):
            restored['cleanup']['recordedAt'] = (instant - timedelta(seconds=30 if mac_first else 90)).isoformat()
            restored['macCleanup']['recordedAt'] = (instant - timedelta(seconds=90 if mac_first else 30)).isoformat()
            summary = subject.smoke_summary('icloud-cleanup', restored)
            assert summary['passed'] and subject.complete_summary('icloud-cleanup', summary)
            for key in ('cleanup', 'macCleanup'):
                for field in ('executedTests', 'testTargets', 'destination', 'runID'):
                    partial = dict(summary[key]); partial.pop(field)
                    assert not subject.complete_summary('icloud-cleanup', dict(summary, **{key: partial}))
                assert not subject.complete_summary('icloud-cleanup', dict(summary, **{key: dict(summary[key], runID='other')}))
            assert subject.evidence_current('icloud-cleanup', summary)
        assert not subject.evidence_current('icloud-cleanup', subject.smoke_summary('icloud-cleanup',
            dict(restored, cleanupFinishedAt=restored['cleanupStartedAt'], cleanupStartedAt=restored['cleanupFinishedAt'])))
        assert not subject.smoke_summary('icloud-cleanup', dict(restored, macCleanup={}))['passed']
        assert not icloud_summary({'exitCode': 0, 'stages': stages, 'macCleanup': dict(mac_cleanup, exitCode=1)})['passed']
        stages[1]['passedTests'] = 0
        assert icloud_summary({'exitCode': 0, 'stages': stages})['passed'] is False
        return 0

def summary_status_self_test(subject) -> None:
    from contextlib import redirect_stdout
    from copy import deepcopy
    from io import StringIO
    from types import SimpleNamespace
    from unittest.mock import patch
    method = 'Suite/test'
    valid = native_case_fixture({'passed': True, 'totalTests': 1, 'passedTests': 1, 'failedTests': 0,
        'skippedTests': 0, 'executedTests': [method], 'coverage': {'Fixture': {'coveredLines': 1, 'executableLines': 1}}}, {method: 1})
    row = {'scope': 'full', 'exitCode': 0, 'runID': 'run', 'inputDigest': 'digest',
        'recordedAt': subject.utc_now().isoformat(), 'summary': valid}
    cases = [(row, '通过', [])]
    for changes, label in [({'summary': dict(valid, executedTests=[], coverage={})}, '待处理'),
            ({'summary': dict(valid, coverage={})}, '待处理'), ({'runID': ''}, '待处理'),
            ({'environment': {}}, '待处理'), ({'inputDigest': 'changed'}, '待复验'),
            ({'recordedAt': '2000-01-01T00:00:00Z'}, '待复验'),
            ({'scope': 'selected', 'expectedTests': [method]}, '定向通过'),
            ({'scope': 'selected', 'expectedTests': []}, '待处理')]:
        cases.append((dict(row, **changes), label, []))
    cases.append((row, '待处理', ['结果包已变化']))
    for candidate, label, bundle_errors in cases:
        candidate = deepcopy(candidate)
        candidate.setdefault('environment', {'fixture': True})
        report = {'groups': {'all': candidate}}
        output = StringIO()
        with patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_text', return_value=json.dumps(report)), \
                patch.object(subject, 'source_digest', return_value='digest'), patch.object(subject, 'test_inventory', return_value={method}), \
                patch.object(subject, 'test_case_inventory', return_value={method: 1}), \
                patch.object(subject, 'coverage_complete', side_effect=lambda group, summary: bool(summary.get('coverage'))), \
                patch.object(subject, 'complete_environment', side_effect=lambda group, environment: bool(environment)), \
                patch.object(subject, 'result_bundle_findings', return_value=bundle_errors), \
                patch.dict(os.environ, GITHUB_STEP_SUMMARY=''), redirect_stdout(output):
            assert subject.inspect_report(SimpleNamespace(action='summary', recorded_environment=False)) == 0
            assert f'| all | {candidate["scope"]} | {label} |' in output.getvalue(), output.getvalue()
            if candidate['scope'] == 'full': assert subject.group_complete(report, 'all') == (label == '通过')

def native_case_fixture(summary, counts, group='all'):
    from hashlib import sha256
    return dict(summary, testCases={'passed': True, 'total': sum(counts.values()), 'byTest': counts,
        'destinations': [{'platform': 'macOS' if group in {'catalyst', 'catalyst-release-runtime'} else 'iOS', 'deviceIdentifier': 'fixture-device'}],
        'expectedByTest': counts, 'identifiersByTest': {name: ['test://com.apple.xcode/BIT101-iOS/' + ('BIT101-iOSUITests' if group == 'ui' else 'BIT101-iOSTests') + '/' + name + '?args=' + sha256(str(index).encode()).hexdigest()
            for index in range(count)] for name, count in counts.items()}})

def native_cases_self_test(subject) -> None:
    from copy import deepcopy
    from hashlib import sha256
    from unittest.mock import patch
    method = 'Suite/image'
    identity = 'test://com.apple.xcode/BIT101-iOS/BIT101-iOSTests/' + method
    row = {'devices': [{'platform': 'iOS', 'deviceId': 'fixture-device'}], 'nodeType': 'Test Case', 'nodeIdentifier': method + '(stage:)', 'nodeIdentifierURL': identity, 'result': 'Passed',
        'children': [{'nodeType': 'Arguments', 'nodeIdentifierURL': identity + '?args=' + sha256(str(index).encode()).hexdigest(), 'result': 'Passed'} for index in range(5)]}
    summary = {'passed': True, 'totalTests': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0, 'executedTests': [method]}
    with patch.object(subject, 'test_case_inventory', return_value={method: 5}), patch.object(subject, 'test_inventory', return_value={method}), \
            patch.object(subject, 'coverage_complete', return_value=True):
        summary['testCases'] = subject.native_case_summary(row, 'all')
        assert subject.selected_test_summary_complete(summary, [method]) and subject.complete_summary('all', summary)
        for project, target in [('ForeignProject', 'BIT101-iOSTests'), ('BIT101-iOS', 'ForeignTarget'), ('BIT101-iOS', 'BIT101-iOSUITests')]:
            forged = deepcopy(summary)
            forged['testCases']['identifiersByTest'][method] = [value.replace('/BIT101-iOS/BIT101-iOSTests/', f'/{project}/{target}/')
                for value in summary['testCases']['identifiersByTest'][method]]
            assert not subject.selected_test_summary_complete(forged, [method])
        for devices in ([], [{'platform': 'macOS', 'deviceId': 'fixture-device'}], [{'platform': 'iOS', 'deviceId': ''}],
                [{'platform': 'iOS', 'deviceId': 'other-device'}], [{'platform': 'iOS Simulator', 'deviceId': 'fixture-device'}]):
            changed = dict(summary, testCases=subject.native_case_summary(dict(row, devices=devices), 'all', device_identifier='fixture-device'))
            assert not subject.selected_test_summary_complete(changed, [method])
        simulated = dict(summary, testCases=subject.native_case_summary(dict(row, devices=[{'platform': 'iOS Simulator', 'deviceId': 'fixture-device'}]), 'all', simulator=True))
        assert subject.selected_test_summary_complete(simulated, [method], simulator=True)
        assert not subject.complete_summary('all', simulated)
        encoded = deepcopy(summary)
        encoded['testCases']['identifiersByTest'][method] = [identity + '?args=' + value.encode().hex()
            for value in ['.currentAccount', '.otherAccounts', '.first', '.second', '.third']]
        assert subject.selected_test_summary_complete(encoded, [method])
        partial = deepcopy(row); partial['children'] = partial['children'][:1]
        duplicated = deepcopy(row); duplicated['children'][1]['nodeIdentifierURL'] = duplicated['children'][0]['nodeIdentifierURL']
        failed = deepcopy(row); failed['children'][1]['result'] = 'Failed'
        skipped = deepcopy(row); skipped['children'][1]['result'] = 'Skipped'
        for broken in (partial, duplicated, failed, skipped):
            changed = dict(summary, testCases=subject.native_case_summary(broken, 'all'))
            assert not subject.selected_test_summary_complete(changed, [method]) and not subject.complete_summary('all', changed)
        forged = native_case_fixture(summary, {method: 1})
        assert not subject.selected_test_summary_complete(forged, [method])
        for values in ([str(index) for index in range(5)], [identity.replace('/Suite/', '/OtherSuite/') + '?args=' + sha256(str(index).encode()).hexdigest() for index in range(5)],
                [identity + '?args=' + str(index) for index in range(5)]):
            forged = deepcopy(summary); forged['testCases']['identifiersByTest'][method] = values
            assert not subject.selected_test_summary_complete(forged, [method])
    facts = subject.swift_syntax_index_sources({'parameter-count': 'import Testing; struct Suite { @Test(arguments: [1, 2], [true, false, true]) func image(_: Int, _: Bool) {} }'})['parameter-count']
    assert facts['tests'][0]['testCaseCount'] == 6

def developer_directory_self_test() -> None:
    from io import BytesIO
    from types import SimpleNamespace
    from unittest.mock import patch
    import validation_environment as environment
    developer = Path('/chosen/Xcode.app/Contents/Developer')
    def plist(path, keys):
        if path == developer.parent / 'Info.plist': return {'CFBundleShortVersionString': 'fixture', 'CFBundleVersion': '1'}
        if path == developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.plist': return {'Version': 'fixture'}
        return {}
    try:
        with patch.object(environment.subprocess, 'check_output', side_effect=lambda args, **kwargs:
                '/chosen/swift-frontend\n' if args[0] == 'xcrun' else args[0] + ' fixture-version\n'), \
                patch.object(environment, 'plist_values', side_effect=plist), \
                patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'stat', return_value=SimpleNamespace(st_size=8, st_mtime_ns=1)), \
                patch.object(Path, 'open', side_effect=lambda *args, **kwargs: BytesIO(b'compiler')):
            contexts = []
            for selected in ('/chosen/Xcode.app', str(developer)):
                with patch.dict(os.environ, DEVELOPER_DIR=selected):
                    environment.host_environment.cache_clear()
                    environment.environment_context.cache_clear()
                    context = environment.environment_context('audit')
                    assert environment.complete_environment('audit', context), selected
                    assert context['runtimes'] == {'python': sys.version,
                        **{name: name + ' fixture-version' for name in ('ruby', 'node', 'npm', 'ruff')}}
                    assert not environment.complete_environment('audit', context | {'runtimes': {
                        name: value for name, value in context['runtimes'].items() if name != 'ruff'}})
                    contexts.append(context)
            assert contexts[0] == contexts[1]
    finally:
        environment.host_environment.cache_clear()
        environment.environment_context.cache_clear()
    from validation_provenance import source_digest
    context = contexts[0]
    assert source_digest('audit', environment=context) != source_digest('audit', environment=context | {
        'runtimes': context['runtimes'] | {'ruff': 'changed-version'}})

def module_events_self_test(subject) -> None:
    from unittest.mock import patch
    single = 'Consumer.Suite/single()/Tests.swift:1:1'
    parameterized = 'Consumer.Suite/parameterized(_:)/Tests.swift:2:1'
    def declaration(identifier, parameterized=False):
        return {'kind': 'test', 'payload': {'kind': 'function', 'id': identifier, 'isParameterized': parameterized,
            '_testCases': [{'id': 'case-a'}, {'id': 'case-b'}] if parameterized else []}}
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
    assert result['testCases'] == {'total': 3, 'byTest': {single: 1, parameterized: 2}, 'expectedByTest': {single: 1, parameterized: 2}}
    assert subject.module_cases_complete(result)
    for broken in (
            records[:3] + [records[4], records[3]] + records[5:],
            records[:4] + [records[3]] + records[4:],
            records[:5] + [records[4]] + records[5:],
            records[:3] + [records[-1]] + records[3:-1],
            records[:3] + [records[2]] + records[3:],
            records[:3] + [records[6]] + records[3:],
            records + [records[4]],
            records[:4] + [event('testCaseStarted', single, _testCase={'id': 'one'}),
                event('testCaseEnded', single, _testCase={'id': 'one'}),
                event('testCaseStarted', single, _testCase={'id': 'two'}),
                event('testCaseEnded', single, _testCase={'id': 'two'})] + records[4:]):
        try: subject.module_event_summary(encode(broken))
        except ValueError: pass
        else: raise AssertionError('普通函数和运行事件需要唯一且有序的起止配对')
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
    for issue, failed in (({'isKnown': False}, 1), ({'isKnown': True}, 1), ({'isKnown': True, 'isFailure': True}, 1),
            ({'isKnown': False, 'isFailure': False}, 0), ({'isKnown': True, 'isFailure': False}, 0)):
        result = subject.module_event_summary(encode(records + [event('issueRecorded', parameterized, issue=issue)]))
        assert result['failedTests'] == failed and result['passedTests'] == 2 - failed
    for incomplete in (records[:-1], [row for index, row in enumerate(records) if index != 8],
            [row for row in records if row['payload'].get('_testCase', {}).get('id') != 'case-b'],
            [row for row in records if not row['payload']['kind'].startswith('testCase')], [],
            records + [event('issueRecorded', issue={'isKnown': False})]):
        try: subject.module_event_summary(encode(incomplete))
        except ValueError: pass
        else: raise AssertionError('事件缺失、空参数及运行失败需要进入证据门禁')
    for declared in (None, [], [{'id': 'case-a'}], [{'id': 'case-a'}, {'id': 'case-a'}], [{}]):
        broken = json.loads(json.dumps(records))
        broken[1]['payload']['_testCases'] = declared
        try: subject.module_event_summary(encode(broken))
        except ValueError: pass
        else: raise AssertionError('参数实例需要完整且唯一的框架清单')
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
    check_output = subject.subprocess.check_output
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
                    patch.object(subject.subprocess, 'check_output', side_effect=lambda command, *args, **kwargs:
                        'head' if command == ['git', 'rev-parse', 'HEAD'] else check_output(command, *args, **kwargs)), \
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

def network_scope_boolean_self_test(subject) -> None:
    from unittest.mock import patch
    path = subject.ROOT / 'BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift'
    source, read = path.read_text(), Path.read_text
    baseline = {scope: subject.network_inventory(scope) for scope in ('all', 'bit101', 'school', 'transcript', 'schedule', 'ddl', 'community-writes', 'community-cleanup')}
    assert len(baseline['all']) == 63 and {'course.search', 'paper.search'} <= baseline['all'] and 'community.writes' not in baseline['all']
    fixtures = [('all', 'area != .communityWrites', baseline['all']),
        ('all', '!(area == .communityWrites)', baseline['all']),
        ('all', 'area != .communityWrites && (area == .authentication || area != .authentication)', baseline['all']),
        ('bit101', '!(area != .authentication && area != .bit101)', baseline['bit101']),
        ('transcript', 'area == NetworkSmokeArea.transcript', baseline['transcript']),
        ('schedule', 'false', set()), ('schedule', 'true', baseline['all'] | {'community.writes'})]
    try:
        for scope, expression, expected in fixtures:
            rewritten, count = re.subn(r'(?ms)(case \.' + scope + r':\s*\n).*?(?=^\s*case \.)',
                lambda match: match[1] + '            return ' + expression + '\n', source, count=1)
            assert count == 1
            def fixture_read(candidate, *args, **kwargs):
                return rewritten if candidate == path else read(candidate, *args, **kwargs)
            subject.network_inventory.cache_clear()
            with patch.object(Path, 'read_text', fixture_read):
                assert subject.network_inventory(scope) == expected, (scope, expression)
        rewritten = source.replace('_ area: NetworkSmokeArea', '_ topic: NetworkSmokeArea').replace('area ==', 'topic ==')
        subject.network_inventory.cache_clear()
        with patch.object(Path, 'read_text', fixture_read):
            assert subject.network_inventory('all') == baseline['all']
        rewritten = source.replace('case .communityWrites:\n            return area == .authentication || area == .communityWrites || area == .communityWriteImages\n        case .communityCleanup:',
            'case .communityWrites, .communityCleanup:')
        assert rewritten != source
        subject.network_inventory.cache_clear()
        with patch.object(Path, 'read_text', fixture_read):
            assert subject.network_inventory('community-writes') == baseline['community-cleanup']
            assert subject.network_inventory('community-cleanup') == baseline['community-cleanup']
    finally:
        subject.network_inventory.cache_clear()

if __name__ == '__main__':
    import validation_evidence
    raise SystemExit(run_self_test(validation_evidence))
