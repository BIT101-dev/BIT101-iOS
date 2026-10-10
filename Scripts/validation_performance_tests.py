"""Regression contracts for real XCTest performance extraction and capture identity."""
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch
import validation_performance as subject


def run_self_test() -> None:
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
    try: subject.bundle_digest(Path('/does-not-exist/current.xcresult'))
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
    merge_regression_self_test()


def producing_run_capture_self_test() -> None:
    import json
    from validation_manual import PERFORMANCE_WORKLOADS, performance_group
    environment = {'device': {'identifier': 'phone', 'model': 'iPhone', 'systemVersion': '17', 'systemBuild': 'build'},
        'xcode': {'DTXcodeBuild': 'xcode'}, 'compiler': {'sha256': 'a' * 64}}
    rows = {group: {'exitCode': 0, 'scope': 'full', 'inputDigest': 'digest', 'runID': group, 'sourceCommit': 'commit',
        'recordedAt': 'captured', 'environment': environment, 'resultBundleSHA256': 'b' * 64} for group in ('all', 'ui')}
    def exported(command, **kwargs):
        if 'summary' in command: return '{"result":"Passed"}'
        return json.dumps([{'testIdentifier': command[-1], 'testRuns': [{'device': {'deviceId': 'phone'}, 'metrics': [
            {'identifier': identifier, 'unitOfMeasurement': unit, 'measurements': [1, 2]}
            for identifier, unit, _ in subject.METRICS.values()]}]}])
    combined = {}
    with patch.object(subject.subprocess, 'check_output', side_effect=exported), \
            patch.object(subject, 'bundle_digest', return_value='b' * 64):
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
            patch('validation_evidence.source_digest', return_value='digest'), \
            patch.object(subject.subprocess, 'check_output', side_effect=AssertionError('后续宿主沿固定结果包继续运行')):
        assert subject.capture_current() == {'schemaVersion': 1, 'records': combined}
        from validation_publication import core_exchange
        shared = core_exchange({'groups': rows})
        with patch.object(Path, 'read_text', return_value=json.dumps(shared)):
            assert subject.capture_current()['records'] == shared['groups']['all']['performance']['records'] | shared['groups']['ui']['performance']['records']
        for group in rows:
            for field, value in [('runID', 'other'), ('resultBundleSHA256', 'c' * 64), ('sourceCommit', 'other')]:
                changed = deepcopy(rows)
                changed[group][field] = value
                with patch.object(Path, 'read_text', return_value=json.dumps({'groups': changed})):
                    try: subject.capture_current()
                    except ValueError: pass
                    else: raise AssertionError('采样需要匹配完成时的生产运行')


def merge_regression_self_test() -> None:
    import json
    from contextlib import nullcontext, redirect_stdout
    from io import StringIO
    import validation_evidence
    from validation_manual_tests import evidence_fixture
    measurements = json.loads(evidence_fixture('performance-baseline'))['scenarios']
    report = {'groups': {}, 'performanceBaseline': {'schemaVersion': 1, 'records': {}}}
    for name, scenario in measurements.items():
        current, baseline = scenario['measurement']['current'], scenario['measurement']['baseline']
        execution = current['execution']
        row = report['groups'].setdefault(execution['group'], dict(execution,
            recordedAt=current['capturedAt'], resultBundleSHA256=execution['bundleSHA256'],
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
    for fault in ('missing-baseline', 'missing-current', 'run', 'regression', 'approver', 'environment', 'raw-metrics', 'commit'):
        changed = deepcopy(report)
        current = changed['groups']['all']['performance']['records']['pagination']
        baseline = changed['performanceBaseline']['records']['pagination']
        if fault == 'missing-baseline': changed.pop('performanceBaseline')
        if fault == 'missing-current': changed['groups']['ui']['performance']['records'].pop('startup')
        if fault == 'run': current['execution']['runID'] = 'other'
        if fault == 'regression':
            baseline['metrics']['clockSeconds'].update(samples=[0.01] * 10, mean=0.01)
            baseline['xcresultMetrics'][0]['testRuns'][0]['metrics'][0]['measurements'] = [0.01] * 10
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
            patch.object(Path, 'write_text'), patch.object(validation_evidence, 'report_lock', side_effect=nullcontext), \
            patch.object(validation_evidence, 'write_report') as writer, redirect_stdout(StringIO()):
        assert subject.main(['baseline', 'maintainer']) == 0
        saved = writer.call_args.args[0]
        assert 'mergeCommit' not in saved and set(saved['performanceBaseline']['records']) == set(measurements)
        assert all(record['approvedBy'] == 'maintainer' for record in saved['performanceBaseline']['records'].values())
