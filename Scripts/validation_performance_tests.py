"""Regression contracts for real XCTest performance extraction and capture identity."""
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch
from uuid import UUID
import validation_performance as subject
from validation_provenance import _local_source_identity


def source_identity_fixture():
    snapshots = []
    def identify(group, files, context):
        snapshot = [group, deepcopy(files), deepcopy(context)]
        if snapshot not in snapshots: snapshots.append(snapshot)
        return str(UUID(int=snapshots.index(snapshot) + 1))
    return identify


def source_identity_registry_self_test() -> None:
    import json
    from contextlib import nullcontext
    import validation_provenance as provenance
    state = {'groups': {'audit': {'exitCode': 0}}}
    def save(report, **kwargs):
        state.clear()
        state.update(deepcopy(report))
    with patch.object(provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(Path, 'is_file', return_value=True), \
            patch.object(Path, 'read_text', side_effect=lambda: json.dumps(state)), \
            patch.object(provenance, 'write_report', side_effect=save):
        files = {'source.swift': {'executable': False, 'content': 'first'}}
        initial = _local_source_identity('modules', files, {})
        assert _local_source_identity('modules', files, {}) == initial
        files['source.swift']['content'] = 'other'
        changed = _local_source_identity('modules', files, {})
        assert changed != initial
        files['source.swift']['executable'] = True
        executable = _local_source_identity('modules', files, {})
        assert executable != changed
        assert _local_source_identity('modules', files, {'compiler': 'other'}) != executable
        assert _local_source_identity('modules', {}, {}) != executable
        assert state['groups']['audit']['exitCode'] == 0
        assert set(state['sourceInputs']['files']) == {'source.swift'}
    provenance._REPORT_INPUTS.pop(provenance.REPORT, None)


def run_self_test() -> None:
    source_identity_registry_self_test()
    committed_source_identity_self_test()
    static_audit_cancellation_self_test()
    failed_regression_self_test()
    with patch.object(subject.subprocess, 'check_output', side_effect=[b'Modules/StorageCore/Sources/AppFileService.swift\0', b'']) as git:
        assert subject.uncommitted_inputs() == ['Modules/StorageCore/Sources/AppFileService.swift']
        assert git.call_args_list[0].args[0] == ['git', 'diff', '--name-only', '-z', 'HEAD', '--']
    test = 'MaintenancePerformanceTests/testCommunityPaginationPerformance'
    raw = [{'testIdentifier': test + '()', 'testRuns': [{'device': {'deviceId': 'phone'}, 'metrics': [
        {'identifier': 'com.apple.dt.XCTMetric_Clock.time.monotonic', 'unitOfMeasurement': 's', 'measurements': [0.1, 0.2]},
        {'identifier': 'com.apple.dt.XCTMetric_Memory.physical_peak', 'unitOfMeasurement': 'kB', 'measurements': [1024, 2048]},
        {'identifier': 'com.apple.dt.XCTMetric_Memory.physical', 'unitOfMeasurement': 'kB', 'measurements': [0, 0]}]}]}]
    normalized = subject.normalize_metrics(raw, test, 'phone')
    assert normalized['peakPhysicalMemoryBytes']['samples'] == [1_024_000, 2_048_000]
    assert normalized['clockSeconds']['samples'] == [0.1, 0.2]
    for altered in ([], raw + raw, [{'testIdentifier': 'other', 'testRuns': raw[0]['testRuns']}]):
        try: subject.normalize_metrics(altered, test, 'phone')
        except ValueError: pass
        else: raise AssertionError('指标需要匹配唯一测试用例')
    for key, value in [('deviceId', 'other'), ('unitOfMeasurement', 'MB'), ('measurements', [])]:
        changed = deepcopy(raw)
        target = changed[0]['testRuns'][0]['device'] if key == 'deviceId' else changed[0]['testRuns'][0]['metrics'][1]
        target[key] = value
        try: subject.normalize_metrics(changed, test, 'phone')
        except ValueError: pass
        else: raise AssertionError('指标需要匹配实际设备、单位及原始采样')
    try: subject.bundle_identity(Path('/does-not-exist/current.xcresult'))
    except ValueError: pass
    else: raise AssertionError('性能捕获需要实际结果包')
    current = {'pagination': {'testIdentifier': test, 'metrics': normalized}}
    baseline = {'pagination': {'testIdentifier': test, 'approvedBy': 'maintainer'}}
    proof = {'scenarios': {'pagination': {'measurement': {'current': current['pagination'], 'baseline': baseline['pagination']}}}}
    with patch.object(subject, 'capture_current', return_value={'records': current}), \
            patch.object(Path, 'read_text', return_value='{"baseline":{"records":{"pagination":{"testIdentifier":"' + test + '","approvedBy":"maintainer"}}}}'):
        subject.validate_capture(proof)
        changed = deepcopy(proof)
        changed['scenarios']['pagination']['measurement']['current']['metrics']['clockSeconds']['samples'] = [0.01]
        try: subject.validate_capture(changed)
        except ValueError: pass
        else: raise AssertionError('手填采样需要匹配实际 xcresult 指标')
    producing_run_capture_self_test()
    result_replacement_self_test()
    selected_result_retention_self_test()
    batch_retention_self_test(raw, test)
    merge_regression_self_test()
    baseline_migration_self_test()


def committed_source_identity_self_test() -> None:
    import validation_provenance as provenance
    commit = b'a' * 40
    with patch.object(provenance.subprocess, 'check_output', side_effect=[b'', b'', commit]) as git:
        identity = provenance._clean_source_identity('manual-device', {'compiler': 'fixture'})
        assert identity.startswith('git.' + commit.decode() + '.')
        assert git.call_args.args[0] == ['git', 'rev-parse', 'HEAD']
    for tracked, untracked in ((b'Modules/Feature/Sources/File.swift\0', b''), (b'', b'Modules/Feature/Sources/File.swift\0')):
        with patch.object(provenance.subprocess, 'check_output', side_effect=[tracked, untracked]):
            assert provenance._clean_source_identity('manual-device', {}) is None
    with patch.object(provenance.subprocess, 'check_output', side_effect=[b'README.md\0', b'', commit]):
        assert provenance._clean_source_identity('manual-device', {})


def static_audit_cancellation_self_test() -> None:
    import os
    import signal
    import subprocess
    import sys
    from time import monotonic
    source = (subject.ROOT / 'Scripts/run-static-audit.sh').read_text()
    finish = 'finish_audit() {' + source.split('finish_audit() {', 1)[1].split('\ntrap finish_audit EXIT', 1)[0]
    stop = finish.split("<<'PYSTOP'\n", 1)[1].split('\nPYSTOP', 1)[0]
    def signal_probe(pid, signum):
        if signum == 0: raise PermissionError('completed process group')
    with patch.object(sys, 'argv', ['stop', '123']), patch.object(os, 'killpg', side_effect=signal_probe) as send:
        exec(compile(stop, 'audit-group-stop', 'exec'), {})
        assert [call.args[1] for call in send.call_args_list] == [signal.SIGTERM, 0]
    for ignores_term in (False, True):
        worker = subprocess.Popen([sys.executable, '-c',
            'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print("ready", flush=True); time.sleep(60)'
            if ignores_term else 'import time; print("ready", flush=True); time.sleep(60)'],
            stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            assert worker.stdout.readline().strip() == 'ready'
            prefix = f'''ROOT_DIR=/fixture AUDIT_STARTED=$SECONDS
group_processes=({worker.pid} 0)
python3() {{
  if [[ "$1" == /fixture/Scripts/validation_evidence.py ]]; then print -r -- "RECORD $*"; return 0; fi
  command python3 "$@"
}}
'''
            started = monotonic()
            result = subprocess.run(['zsh', '-c', prefix + finish + '\ntrap finish_audit EXIT\nexit 143'],
                text=True, capture_output=True, timeout=15)
            assert result.returncode == 143 and 'record audit 143' in result.stdout
            assert worker.wait(timeout=1) == (-signal.SIGKILL if ignores_term else -signal.SIGTERM)
            assert monotonic() - started < 10
        finally:
            if worker.poll() is None: os.killpg(worker.pid, signal.SIGKILL)
            worker.wait()
            worker.stdout.close()


def selected_result_retention_self_test() -> None:
    import json
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import validation_provenance
    sha = 'a' * 64
    environment = {'device': {'identifier': 'phone'}}
    full = {'scope': 'full', 'exitCode': 0, 'summary': {'passed': True}, 'inputDigest': 'same',
        'environment': environment, 'resultBundleIdentity': sha, 'recordedAt': subject.utc_now().isoformat()}
    with redirect_stderr(StringIO()) as diagnostic, patch.object(subject, 'recover_result_step'), patch.object(subject, 'begin_result_step') as begin, \
            patch.object(subject, 'bundle_identity', side_effect=ValueError('incomplete')), patch.object(Path, 'exists', return_value=True):
        assert subject.begin_selected_result_step() == []
        begin.assert_called_once_with(False)
        assert diagnostic.getvalue() == '中断的 XCTest 结果包已进入清理与重新采样。\n'
    for changed, retained in (({}, ['all']), ({'inputDigest': 'changed'}, []), ({'exitCode': 1}, []),
            ({'recordedAt': ''}, []), ({'recordedAt': '2000-01-01T00:00:00Z'}, []), ({'recordedAt': '2200-01-01T00:00:00Z'}, []),
            ({'environment': {'device': {'identifier': 'other'}}}, []), ({'resultBundleIdentity': 'b' * 64}, [])):
        row = dict(full, **changed)
        with patch.object(subject, 'recover_result_step'), patch.object(subject, 'begin_result_step') as begin, \
                patch.object(subject, 'bundle_identity', return_value=sha), patch.object(subject, 'environment_context', return_value=environment), \
                patch.object(validation_provenance, 'source_digest', return_value='same'), \
                patch.object(validation_provenance, 'report_lock', side_effect=nullcontext), patch.object(Path, 'exists', return_value=True), \
                patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_text', return_value=json.dumps({'groups': {'all': row}})):
            assert subject.begin_selected_result_step() == retained
            begin.assert_called_once_with(bool(retained))
    with patch.object(subject, 'retain_result_step') as retain:
        assert subject.main(['retain-selected', 'all', 'all', 'ui']) == 0
        retain.assert_called_once_with(['ui', 'all'])


def failed_regression_self_test() -> None:
    from validation_provenance import invalidate_failed_evidence, complete_group_row
    method = 'ScheduleCourseEditorTests/changeWeeks'
    full = dict(scope='full', exitCode=0, inputDigest='input', environment={},
        resultBundleIdentity='a' * 64, summary={'passed': True, 'executedTests': [method + '()']})
    for scope in ('selected', 'full'):
        for failure in ({'exitCode': 1, 'summary': {}}, {'exitCode': 0, 'summary': {'passed': False}}):
            parent = deepcopy(full) if scope == 'full' else dict(deepcopy(full), scope=scope, lastFullRun=deepcopy(full))
            report = {'groups': {'all': parent, 'ui': dict(deepcopy(full), summary={'passed': True, 'executedTests': ['UITests/render']}),
                'schedule': dict(failure, scope='selected', runID='regression')}}
            assert invalidate_failed_evidence(report, 'schedule', {method}) == ['all']
            assert complete_group_row(report['groups']['all'])['exitCode'] == 1
            assert report['groups']['all']['summary']['passed'] is False
            if scope == 'selected': assert report['groups']['all']['lastFullRun']['exitCode'] == 1
            assert report['groups']['ui']['summary']['passed'] is True
            report['groups']['schedule'].update(exitCode=0, summary={'passed': True})
            assert invalidate_failed_evidence(report, 'schedule', {method}) == []
            assert complete_group_row(report['groups']['all'])['exitCode'] == 1
    report = {'groups': {'all': deepcopy(full), 'schedule': {'exitCode': 1}}}
    assert invalidate_failed_evidence(report, 'schedule', {'OtherTests/method'}) == []
    assert report['groups']['all']['summary']['passed'] is True
    report['groups']['all'] = dict(deepcopy(full), scope='selected', exitCode=1, lastFullRun=deepcopy(full))
    assert invalidate_failed_evidence(report, 'all', {method}) == []
    report['groups']['all'].update(exitCode=0, summary={'passed': True})
    assert complete_group_row(report['groups']['all'])['scope'] == 'selected'
    recorded_failure_self_test(full, method)
    from validation_evidence import network_inventory
    for group, scope in (('ddl', 'ddl'), ('school-sms', 'school'), ('network', 'bit101')):
        probes = network_inventory(scope)
        full = dict(scope='full', exitCode=0, inputDigest='input', environment={},
            summary={'passed': True, 'probeInventory': sorted(network_inventory('all'))})
        report = {'groups': {'network': deepcopy(full), 'ui': {'exitCode': 0, 'summary': {'passed': True}},
            group: {'exitCode': 1, 'scope': 'selected', 'runID': 'regression'}}}
        if group == 'network': report['groups'][group]['lastFullRun'] = deepcopy(full)
        assert invalidate_failed_evidence(report, group, probes) == ([] if group == 'network' else ['network'])
        assert report['groups']['ui']['exitCode'] == 0
        failed = report['groups']['network'].get('lastFullRun', report['groups']['network'])
        assert failed['exitCode'] == 1 and failed['summary']['failedRegression']['probes'] == sorted(probes)


def recorded_failure_self_test(full: dict, method: str) -> None:
    import json
    import os
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import validation_evidence
    report = {'groups': {'all': deepcopy(full), 'ui': dict(deepcopy(full), summary={'passed': True, 'executedTests': ['UITests/render']})}}
    with patch.object(validation_evidence, 'source_digest', return_value='input'), \
            patch.object(validation_evidence, 'environment_context', return_value={}), \
            patch.object(validation_evidence, 'report_lock', side_effect=nullcontext), \
            patch.object(validation_evidence, 'write_report', side_effect=lambda value: report.update(value)), \
            patch.object(Path, 'is_file', return_value=True), \
            patch.object(Path, 'read_text', new=lambda path, *args, **kwargs: json.dumps(report) if path == validation_evidence.REPORT else 'metrics'), \
            patch.object(validation_evidence, 'test_summary', return_value={'passed': False, 'executedTests': [method]}), \
            patch.object(validation_evidence.subprocess, 'check_output', return_value='commit'), \
            patch.dict(os.environ, BIT101_VALIDATION_RUN_ID='failed-run', BIT101_VALIDATION_EXPECTED_TESTS=json.dumps([method])), redirect_stderr(StringIO()):
        assert validation_evidence.record('schedule', 1, 'selected', 'input') == 1
    assert report['groups']['all']['exitCode'] == 1 and report['groups']['all']['summary']['passed'] is False
    assert report['groups']['ui']['exitCode'] == 0


def result_replacement_self_test() -> None:
    import json
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import validation_provenance
    sha = 'a' * 64
    report = {'releaseCommit': 'commit', 'mergeCommit': 'commit', 'resultMerge': {'groups': ['all']}, 'groups': {
        'all': {'resultBundleIdentity': sha},
        'ui': {'lastFullRun': {'resultBundleIdentity': sha}},
        'catalyst': {'resultBundleIdentity': sha}, 'modules': {'runID': 'modules'}},
        'performanceBaseline': {'approvedBy': 'maintainer'}}
    output = StringIO()
    with redirect_stderr(output), patch.object(Path, 'exists', return_value=True), patch.object(Path, 'is_file', return_value=True), \
            patch.object(Path, 'read_text', return_value=json.dumps(report)), \
            patch.object(validation_provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(subject.shutil, 'rmtree') as remove, \
            patch.object(validation_provenance, 'write_report') as save:
        save.side_effect = lambda value: remove.assert_not_called()
        assert subject.main(['reset-results']) == 0
        assert output.getvalue() == '覆盖原始结果包：all、catalyst、ui 的验证证据将进入重新验收。\n'
        updated = save.call_args.args[0]
        assert updated['groups'] == {'modules': {'runID': 'modules'}}
        assert 'releaseCommit' not in updated and 'mergeCommit' not in updated
        assert 'resultMerge' not in updated
        assert updated['performanceBaseline'] == report['performanceBaseline']
        remove.assert_called_once_with(subject.BUNDLE)
        remove.reset_mock(); save.reset_mock()
        save.side_effect = OSError('report write failure')
        try: subject.reset_result_bundle()
        except OSError: pass
        else: raise AssertionError('证据写入失败需要保留原始结果包')
        remove.assert_not_called()
        with patch.object(Path, 'exists', return_value=False): subject.reset_result_bundle()
        assert save.call_count == 1
    rows = {group: {'resultBundleIdentity': sha} for group in ('all', 'ui')}
    with patch.object(subject, 'bundle_identity', return_value=sha) as digest:
        assert not subject.result_bundle_findings({'groups': rows})
        changed = deepcopy(rows); changed['ui']['resultBundleIdentity'] = 'b' * 64
        assert subject.result_bundle_findings({'groups': changed})
        for value in ('b' * 64, None):
            with patch.object(subject, 'bundle_identity', return_value=value):
                assert subject.result_bundle_findings({'groups': rows})
        with patch.object(subject, 'bundle_identity', side_effect=ValueError('missing bundle')):
            assert subject.result_bundle_findings({'groups': rows})
        digest.reset_mock()
        assert not subject.result_bundle_findings({'groups': rows}, recorded_environment=True)
        digest.assert_not_called()
        assert subject.result_bundle_findings({'groups': changed}, recorded_environment=True)
        assert subject.result_bundle_findings({'groups': {}}, recorded_environment=True)
        complete = dict(rows['all'], scope='full', exitCode=0, inputDigest='input', summary={'passed': True})
        selected = dict(complete, scope='selected', resultBundleIdentity='b' * 64, lastFullRun=complete)
        assert not subject.result_bundle_findings({'groups': rows | {'all': selected}})


def baseline_migration_self_test() -> None:
    import json
    from contextlib import nullcontext
    import ci_evidence
    from validation_manual_tests import evidence_fixture
    scenarios = json.loads(evidence_fixture('performance-baseline'))['scenarios']
    proof = {'schemaVersion': 1, 'records': {name: row['measurement']['baseline'] for name, row in scenarios.items()}}
    assert subject.approved_baseline_complete(proof)
    for field, value in [('approvedBy', ''), ('approvedAt', 'invalid'), ('metrics', {}), ('input', 'other')]:
        changed = deepcopy(proof)
        changed['records'][next(iter(changed['records']))][field] = value
        assert not subject.approved_baseline_complete(changed)
    assert subject.approved_baseline_complete(__import__('validation_publication').core_exchange({'performanceBaseline': proof, 'groups': {}})['performanceBaseline'])
    metadata = {'path': '.github/workflows/ci.yml', 'status': 'completed', 'conclusion': 'success', 'head_repository': {'full_name': 'owner/repo'}}
    retained = {'mergeCommit': 'candidate', 'sourceDigest': 'candidate', 'groups': {'all': {'inputDigest': 'candidate'}}}
    for fault in ('none', 'foreign', 'failed', 'workflow', 'approval'):
        incoming = deepcopy(proof)
        run = deepcopy(metadata)
        if fault == 'foreign': run['head_repository']['full_name'] = 'fork/repo'
        if fault == 'failed': run['conclusion'] = 'failure'
        if fault == 'workflow': run['path'] = '.github/workflows/other.yml'
        if fault == 'approval': incoming['records'][next(iter(incoming['records']))]['approvedBy'] = ''
        with patch.object(ci_evidence, 'repository', return_value='owner/repo'), patch.object(ci_evidence, 'api_pages', return_value=[run]), \
                patch.object(ci_evidence, 'download_core', return_value={'performanceBaseline': incoming, 'groups': {'all': {'inputDigest': 'old'}}}), \
                patch('validation_provenance.report_lock', side_effect=nullcontext), patch('validation_provenance.write_report') as save, \
                patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_text', autospec=True,
                    side_effect=lambda path: json.dumps(retained if path == ci_evidence.REPORT else {'schemaVersion': 1, 'current': 'retained'})), \
                patch.object(Path, 'write_text') as measurements:
            try: ci_evidence.import_baseline(7)
            except ValueError: assert fault != 'none'
            else:
                assert fault == 'none'
                assert save.call_args.args[0] == {key: value for key, value in retained.items() if key != 'mergeCommit'} | {'performanceBaseline': proof}
                assert save.call_args_list[0].kwargs == {'path': subject.MEASUREMENTS}
                assert save.call_args_list[0].args[0]['current'] == 'retained'
                measurements.assert_not_called()
            if fault != 'none':
                save.assert_not_called(); measurements.assert_not_called()


def producing_run_capture_self_test() -> None:
    import json
    from validation_manual import PERFORMANCE_WORKLOADS, performance_group
    environment = {'device': {'identifier': 'phone', 'model': 'iPhone', 'systemVersion': '17', 'systemBuild': 'build'},
        'xcode': {'DTXcodeBuild': 'xcode'}, 'compiler': {'version': 'a' * 64}}
    rows = {group: {'exitCode': 0, 'scope': 'full', 'inputDigest': 'digest', 'runID': group, 'sourceCommit': 'commit',
        'recordedAt': 'captured', 'environment': environment, 'resultBundleIdentity': 'b' * 64} for group in ('all', 'ui')}
    def exported(command, **kwargs):
        if 'summary' in command: return '{"result":"Passed"}'
        return json.dumps([{'testIdentifier': command[-1], 'testRuns': [{'device': {'deviceId': 'phone'}, 'metrics': [
            {'identifier': identifier, 'unitOfMeasurement': unit, 'measurements': [1, 2]}
            for identifier, unit, _ in subject.METRICS.values()]}]}])
    combined = {}
    with patch.object(subject.subprocess, 'check_output', side_effect=exported), \
            patch.object(subject, 'bundle_identity', return_value='b' * 64):
        for group, row in rows.items():
            row['performance'] = subject.extract_measurements(row, group)
            expected = {name for name, (test, _) in PERFORMANCE_WORKLOADS.items() if performance_group(test) == group}
            assert set(row['performance']['records']) == expected
            assert all(record['execution']['group'] == group for record in row['performance']['records'].values())
            combined.update(row['performance']['records'])
    assert set(combined) == set(PERFORMANCE_WORKLOADS)
    with patch.object(Path, 'read_text', return_value=json.dumps({'groups': rows})), \
            patch.object(subject, 'environment_context', return_value=environment), \
            patch.object(subject, 'complete_environment', return_value=True), \
            patch.object(subject, 'uncommitted_inputs', return_value=[]), \
            patch.object(subject, 'record_complete', return_value=True), \
            patch.object(subject, 'bundle_identity', return_value='b' * 64), \
            patch('validation_provenance.source_digest', return_value='digest'), \
            patch.object(subject.subprocess, 'check_output', side_effect=AssertionError('后续宿主沿固定结果包继续运行')):
        assert subject.capture_current() == {'schemaVersion': 1, 'records': combined}
        from validation_publication import core_exchange
        shared = core_exchange({'groups': rows})
        with patch.object(Path, 'read_text', return_value=json.dumps(shared)):
            assert subject.capture_current()['records'] == shared['groups']['all']['performance']['records'] | shared['groups']['ui']['performance']['records']
        for group in rows:
            for field, value in [('runID', 'other'), ('resultBundleIdentity', 'c' * 64), ('sourceCommit', 'other')]:
                changed = deepcopy(rows)
                changed[group][field] = value
                with patch.object(Path, 'read_text', return_value=json.dumps({'groups': changed})):
                    try: subject.capture_current()
                    except ValueError: pass
                    else: raise AssertionError('采样需要匹配完成时的生产运行')


def batch_retention_self_test(raw: list, test: str) -> None:
    import json
    import shutil
    import subprocess
    import sys
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import validation_provenance
    fixture = subject.ROOT / '.build/static-audit/performance-results-self-test'
    bundle = fixture / '.build/extended-automation/test-results.xcresult'
    retained = bundle.with_suffix('.retained.xcresult')
    incoming = bundle.with_suffix('.incoming.xcresult')
    report_path = fixture / 'report.json'
    audit_run = subprocess.run
    def artifact_status():
        return audit_run([sys.executable, '-B', str(subject.ROOT / 'Scripts/validation_artifacts.py'), str(fixture)],
            capture_output=True, text=True).returncode
    record = {'testIdentifier': test, 'xcresultMetrics': raw,
        'execution': {'environment': {'device': {'identifier': 'phone'}}, 'bundleIdentity': 'original', 'runID': 'run'},
        'resultBundle': {'identity': 'original'}}
    report = {'groups': {'all': {'resultBundleIdentity': 'original', 'performance': {'records': {'sample': record}}},
        'ui': {'runID': 'ui'}}, 'performanceBaseline': deepcopy(record)}
    foreign = deepcopy(raw[0]['testRuns'][0])
    foreign['device']['deviceId'] = 'mac'
    combined = deepcopy(raw)
    combined[0]['testRuns'].append(foreign)
    assert subject.normalize_metrics(combined, test, 'phone') == subject.normalize_metrics(raw, test, 'phone')
    duplicate = deepcopy(raw)
    duplicate[0]['testRuns'] += deepcopy(raw[0]['testRuns'])
    try: subject.normalize_metrics(duplicate, test, 'phone')
    except ValueError: pass
    else: raise AssertionError('所属设备需要唯一的性能运行')
    with patch.object(subject.subprocess, 'check_output', return_value=json.dumps(combined)), \
            patch.object(subject, 'bundle_identity', return_value='aggregate') as digest:
        updated = subject.rebind_result_records(report, ['all', 'ui'])
        digest.assert_called_once_with(subject.BUNDLE)
    assert report['groups']['all']['resultBundleIdentity'] == 'original'
    assert updated['groups']['all']['runResultBundleIdentity'] == 'original'
    assert updated['groups']['all']['performance']['records']['sample']['execution']['bundleIdentity'] == 'aggregate'
    assert updated['groups']['all']['performance']['records']['sample']['resultBundle']['identity'] == 'aggregate'
    assert updated['performanceBaseline'] == report['performanceBaseline']
    selected = deepcopy(report)
    selected['groups']['all']['lastFullRun'] = deepcopy(report['groups']['all'])
    selected['groups']['all'].pop('performance')
    repeated = deepcopy(raw)
    repeated[0]['testRuns'].append(deepcopy(raw[0]['testRuns'][0]))
    repeated[0]['testRuns'][-1]['metrics'][0]['measurements'] = [99]
    with patch.object(subject.subprocess, 'check_output', return_value=json.dumps(repeated)), patch.object(subject, 'bundle_identity', return_value='aggregate'):
        rebound = subject.rebind_result_records(selected, ['all'])
    assert rebound['groups']['all']['lastFullRun']['resultBundleIdentity'] == 'aggregate'
    assert rebound['groups']['all']['lastFullRun']['runResultBundleIdentity'] == 'original'
    altered = deepcopy(raw)
    altered[0]['testRuns'][0]['metrics'][0]['measurements'] = [99]
    for value in (altered, duplicate):
        with patch.object(subject.subprocess, 'check_output', return_value=json.dumps(value)):
            try: subject.rebind_result_records(report, ['all'])
            except ValueError: pass
            else: raise AssertionError('合并结果包需要保留所属运行的原始采样')
        assert report['groups']['all']['resultBundleIdentity'] == 'original'
    def create(path, data):
        path.mkdir(parents=True)
        (path / 'database.sqlite3').write_bytes(data)
    def merge(command, **kwargs):
        assert command[:3] == ['xcrun', 'xcresulttool', 'merge']
        assert command[3:5] == ['--output-path', str(incoming)]
        assert command[5:] == [str(retained), str(bundle)]
        create(incoming, (retained / 'database.sqlite3').read_bytes() + (bundle / 'database.sqlite3').read_bytes())
        (incoming / 'database.sqlite3').rename(incoming / 'Info.plist')
    def exported(command, **kwargs):
        candidate = Path(command[command.index('--path') + 1]) if '--path' in command else bundle
        if 'summary' in command and (candidate / 'Info.plist').exists() and not (candidate / 'database.sqlite3').exists():
            (candidate / 'database.sqlite3').write_bytes((candidate / 'Info.plist').read_bytes())
        return json.dumps(combined)
    try:
        shutil.rmtree(fixture, ignore_errors=True)
        create(bundle, b'first')
        (bundle / 'database.sqlite3').rename(bundle / 'Info.plist')
        assert subject.bundle_identity(bundle)
        (bundle / 'Staging').mkdir()
        try: subject.bundle_identity(bundle)
        except ValueError: pass
        else: raise AssertionError('结果包完成写入后提供采样摘要')
        (bundle / 'Staging').rmdir()
        (bundle / 'Info.plist').rename(bundle / 'database.sqlite3')
        with patch.object(subject, 'BUNDLE', bundle), patch.object(validation_provenance, 'REPORT', report_path), \
                patch.object(validation_provenance, 'report_lock', side_effect=nullcontext), \
                patch.object(validation_provenance, 'write_report',
                    side_effect=lambda value: report_path.write_text(json.dumps(value))) as writer, \
                patch.object(subject.subprocess, 'run', side_effect=merge), \
                patch.object(subject.subprocess, 'check_output', side_effect=exported), redirect_stderr(StringIO()):
            first_sha = subject.bundle_identity(bundle)
            report['groups']['all']['resultBundleIdentity'] = first_sha
            report_path.write_text(json.dumps(report))
            assert subject.main(['begin-batch', 'append']) == 0
            assert retained.is_dir() and not bundle.exists()
            assert subject.main(['reset-results']) == 0
            writer.assert_not_called()
            create(bundle, b'second')
            second_sha = subject.bundle_identity(bundle)
            assert subject.main(['retain-batch', 'all', 'ui']) == 0
            saved = writer.call_args.args[0]
            assert (bundle / 'database.sqlite3').read_bytes() == b'firstsecond'
            assert not retained.exists() and not incoming.exists()
            assert saved['groups']['all']['runResultBundleIdentity'] == first_sha
            assert saved['groups']['ui']['runResultBundleIdentity'] == second_sha
            assert all(row['resultBundleIdentity'] == subject.bundle_identity(bundle) for row in saved['groups'].values())
            assert (bundle / 'Info.plist').is_file() and (bundle / 'database.sqlite3').is_file()
            writer.reset_mock()
            assert subject.main(['begin-batch', 'append']) == 0
            assert subject.main(['retain-batch', 'all', 'ui', 'release-runtime']) == 0
            assert (bundle / 'database.sqlite3').read_bytes() == b'firstsecond' and not retained.exists()
            report_path.write_text(json.dumps({'groups': {'catalyst': {'runID': 'catalyst'}}}))
            assert subject.main(['begin-batch', 'append']) == 0
            create(bundle, b'catalyst')
            assert subject.main(['retain-batch', 'catalyst']) == 0
            assert writer.call_args.args[0]['groups']['catalyst']['resultBundleIdentity'] == subject.bundle_identity(bundle)
            assert (bundle / 'database.sqlite3').is_file()
            assert subject.main(['begin-batch', 'append']) == 0
            create(bundle, b'failed')
            report_path.write_text(json.dumps(report))
            for failure in ('merge', 'summary', 'interrupt'):
                for path in (bundle, retained, incoming): shutil.rmtree(path, ignore_errors=True)
                create(retained, b'previous')
                create(bundle, b'failed')
                writer.reset_mock()
                def failing_merge(command, **kwargs):
                    if failure != 'summary':
                        create(incoming, b'partial')
                        if failure == 'interrupt': raise KeyboardInterrupt()
                        raise subprocess.CalledProcessError(1, command)
                    merge(command, **kwargs)
                def failing_export(command, **kwargs):
                    if failure == 'summary' and str(incoming) in command: raise subprocess.CalledProcessError(1, command)
                    return exported(command, **kwargs)
                with patch.object(subject.subprocess, 'run', side_effect=failing_merge), \
                        patch.object(subject.subprocess, 'check_output', side_effect=failing_export):
                    try: subject.retain_result_step(['all', 'ui'])
                    except (subprocess.CalledProcessError, KeyboardInterrupt): pass
                    else: raise AssertionError('结果合并失败与中断需要传播')
                assert json.loads(report_path.read_text())['resultMerge']['groups'] == ['all', 'ui']
                assert bundle.is_dir() and retained.is_dir() and not incoming.exists()
                assert (bundle / 'database.sqlite3').read_bytes() == b'failed'
                assert (retained / 'database.sqlite3').read_bytes() == b'previous'
                subject.recover_result_step()
                assert (bundle / 'database.sqlite3').read_bytes() == b'previousfailed'
                subject.recover_result_step()
                assert (bundle / 'database.sqlite3').read_bytes() == b'previousfailed'
            remove = shutil.rmtree
            move = shutil.move
            for interrupted in ('retained', 'current', 'publish-before', 'publish-after'):
                for path in (bundle, retained, incoming): remove(path, ignore_errors=True)
                create(retained, b'previous')
                create(bundle, b'current')
                writer.reset_mock()
                def interrupted_remove(path, **kwargs):
                    if path == (retained if interrupted == 'retained' else bundle) and interrupted in {'retained', 'current'}:
                        (path / 'database.sqlite3').unlink()
                        raise KeyboardInterrupt()
                    return remove(path, **kwargs)
                def interrupted_move(source, destination, **kwargs):
                    if interrupted == 'publish-before': raise KeyboardInterrupt()
                    result = move(source, destination, **kwargs)
                    if interrupted == 'publish-after': raise KeyboardInterrupt()
                    return result
                with patch.object(subject.shutil, 'rmtree', side_effect=interrupted_remove), \
                        patch.object(subject.shutil, 'move', side_effect=interrupted_move):
                    try: subject.retain_result_step(['all', 'ui'])
                    except KeyboardInterrupt: pass
                    else: raise AssertionError('结果包提交中断需要传播')
                assert json.loads(report_path.read_text())['resultMerge']['groups'] == ['all', 'ui']
                with patch.object(subject.subprocess, 'run') as repeated_merge:
                    subject.recover_result_step()
                    subject.recover_result_step()
                    repeated_merge.assert_not_called()
                assert (bundle / 'database.sqlite3').read_bytes() == b'previouscurrent'
                assert not retained.exists() and not incoming.exists()
                recovered = json.loads(report_path.read_text())
                assert 'resultMerge' not in recovered
                assert recovered['groups']['all']['resultBundleIdentity'] == subject.bundle_identity(bundle)
            for path in (bundle, retained, incoming): remove(path, ignore_errors=True)
            create(retained, b'previous'); create(bundle, b'current')
            def fail_report_publish(value):
                if 'resultMerge' not in value: raise OSError('report publish failure')
                report_path.write_text(json.dumps(value))
            writer.side_effect = fail_report_publish
            try: subject.merge_result_step(['all', 'ui'])
            except OSError: pass
            else: raise AssertionError('报告发布失败需要保留待恢复合并身份')
            assert (bundle / 'database.sqlite3').read_bytes() == b'previouscurrent'
            assert 'resultMerge' in json.loads(report_path.read_text())
            writer.side_effect = lambda value: report_path.write_text(json.dumps(value))
            subject.recover_result_step()
            recovered = json.loads(report_path.read_text())
            assert 'resultMerge' not in recovered
            assert recovered['groups']['all']['resultBundleIdentity'] == subject.bundle_identity(bundle)
            for publication in (2, 3):
                for path in (bundle, retained, incoming): remove(path, ignore_errors=True)
                create(bundle, b'first')
                report_path.write_text(json.dumps(report))
                writes = 0
                def fail_first_publication(value):
                    nonlocal writes
                    writes += 1
                    if writes == publication: raise OSError('first bundle publication failure')
                    report_path.write_text(json.dumps(value))
                writer.side_effect = fail_first_publication
                try: subject.merge_result_step(['all'])
                except OSError: pass
                else: raise AssertionError('首包推广登记与报告发布中断需要传播')
                writer.side_effect = lambda value: report_path.write_text(json.dumps(value))
                subject.recover_result_step()
                recovered = json.loads(report_path.read_text())
                assert 'resultMerge' not in recovered
                assert recovered['groups']['all']['resultBundleIdentity'] == subject.bundle_identity(bundle)
                assert recovered['groups']['all']['runResultBundleIdentity'] == subject.bundle_identity(bundle)
            for fault in ('current', 'current-only', 'published-current', 'published-missing', 'retained', 'merged', 'partial', 'unreadable',
                          'current-partial', 'current-missing', 'current-unreadable', 'current-merged'):
                for path in (bundle, retained, incoming): shutil.rmtree(path, ignore_errors=True)
                create(retained, b'previous')
                create(incoming, b'merged')
                if fault.startswith('current') or fault == 'published-current':
                    create(bundle, b'current')
                    if fault in {'current-partial', 'current-merged'}: (bundle / 'Staging').mkdir()
                    if fault == 'current-missing': (bundle / 'database.sqlite3').unlink()
                if fault in {'retained', 'current-only'}: shutil.rmtree(incoming)
                if fault.startswith('published'): shutil.rmtree(retained)
                if fault in {'partial', 'current-partial', 'current-missing'}: (incoming / 'Staging').mkdir()
                assert artifact_status() == 1, fault
                def recover_export(command, **kwargs):
                    assert '--path' in command and command[-1] in {str(bundle), str(incoming)}
                    if fault in {'unreadable', 'current-unreadable'}: raise subprocess.CalledProcessError(1, command)
                    return exported(command, **kwargs)
                with patch.object(subject.subprocess, 'check_output', side_effect=recover_export):
                    assert subject.main(['recover-batch']) == 0
                expected = b'previouscurrent' if fault == 'current-only' else b'merged' if fault in {'current', 'merged', 'current-merged', 'published-current', 'published-missing'} else b'previous'
                assert (bundle / 'database.sqlite3').read_bytes() == expected, fault
                assert not retained.exists() and not incoming.exists(), fault
                assert artifact_status() == 0, fault
                subject.recover_result_step()
                assert (bundle / 'database.sqlite3').read_bytes() == expected, fault
            assert subject.main(['begin-batch', 'first']) == 0
            assert not any(path.exists() for path in (bundle, retained, incoming))
        result = subprocess.run([sys.executable, '-B', str(subject.ROOT / 'Scripts/validation_performance.py'), 'invalid'],
            text=True, capture_output=True)
        assert result.returncode == 1 and '性能命令' in result.stderr
    finally:
        shutil.rmtree(fixture, ignore_errors=True)


def merge_regression_self_test() -> None:
    import json
    from contextlib import nullcontext, redirect_stdout
    from io import StringIO
    import validation_provenance
    from validation_manual_tests import evidence_fixture
    measurements = json.loads(evidence_fixture('performance-baseline'))['scenarios']
    report = {'groups': {}, 'performanceBaseline': {'schemaVersion': 1, 'records': {}}}
    for name, scenario in measurements.items():
        current, baseline = scenario['measurement']['current'], scenario['measurement']['baseline']
        execution = current['execution']
        row = report['groups'].setdefault(execution['group'], dict(execution,
            recordedAt=current['capturedAt'], resultBundleIdentity=execution['bundleIdentity'],
            performance={'schemaVersion': 1, 'records': {}}))
        current['capturedAt'] = row['recordedAt']
        row['performance']['records'][name] = current
        report['performanceBaseline']['records'][name] = baseline
    commit = subject.current_commit()
    assert not subject.merge_findings(report, commit)
    from validation_publication import core_exchange
    shared = core_exchange(report)
    assert not subject.merge_findings(shared, commit)
    assert not subject.merge_findings(report | {'performanceBaseline': shared['performanceBaseline']}, commit)
    assert shared['groups']['all']['performance']['records']['pagination']['execution']['inputDigest'] \
        == report['groups']['all']['performance']['records']['pagination']['execution']['inputDigest']
    for fault in ('missing-baseline', 'missing-current', 'run', 'clock-regression', 'memory-regression', 'clock-tail', 'memory-tail', 'approver', 'environment', 'raw-metrics', 'commit'):
        changed = deepcopy(report)
        current = changed['groups']['all']['performance']['records']['pagination']
        baseline = changed['performanceBaseline']['records']['pagination']
        if fault == 'missing-baseline': changed.pop('performanceBaseline')
        if fault == 'missing-current': changed['groups']['ui']['performance']['records'].pop('startup')
        if fault == 'run': current['execution']['runID'] = 'other'
        if fault in {'clock-regression', 'memory-regression', 'clock-tail', 'memory-tail'}:
            metric_name = 'clockSeconds' if fault.startswith('clock') else 'peakPhysicalMemoryBytes'
            identifier, _, factor = subject.METRICS[metric_name]
            samples = [sample * 4 for sample in current['metrics'][metric_name]['samples']]
            if fault.endswith('tail'):
                approved = baseline['metrics'][metric_name]['samples']
                samples = [min(approved) * 0.1] * (len(approved) - 1) + [max(approved) * 2]
            current['metrics'][metric_name].update(samples=samples, mean=sum(samples) / len(samples))
            raw = current['xcresultMetrics'][0]['testRuns'][0]['metrics']
            next(metric for metric in raw if metric['identifier'] == identifier)['measurements'] = [sample / factor for sample in samples]
            assert subject.record_complete(current, current=True)
            assert subject.record_complete(baseline, current=False)
            assert not subject.performance_comparison_complete('pagination', dict(current=current, baseline=baseline)), fault
        if fault == 'approver': baseline['approvedBy'] = ''
        if fault == 'environment': baseline['environment']['systemBuild'] = 'other'
        if fault == 'raw-metrics': current['xcresultMetrics'][0]['testRuns'][0]['metrics'][0]['measurements'] = [0.01] * 10
        if fault == 'commit': current['sourceCommit'] = '0' * 40
        assert subject.merge_findings(changed, commit), fault
    approved = deepcopy(report['performanceBaseline'])
    for record in approved['records'].values():
        for metric in record['xcresultMetrics'][0]['testRuns'][0]['metrics']: metric['maxPercentRegression'] = 10
    with patch.object(subject, 'capture_current', return_value=approved), \
            patch.object(Path, 'is_file', return_value=True), \
            patch.object(Path, 'read_text', return_value='{"mergeCommit":"old","groups":{}}'), \
            patch.object(Path, 'write_text'), patch.object(validation_provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(validation_provenance, 'write_report') as writer, redirect_stdout(StringIO()):
        assert subject.main(['baseline', 'maintainer']) == 0
        assert writer.call_args_list[0].kwargs == {'path': subject.MEASUREMENTS}
        saved = writer.call_args.args[0]
        assert 'mergeCommit' not in saved and set(saved['performanceBaseline']['records']) == set(measurements)
        assert all(record['approvedBy'] == 'maintainer' for record in saved['performanceBaseline']['records'].values())
