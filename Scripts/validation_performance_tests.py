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


def producing_run_capture_self_test() -> None:
    import json
    from validation_manual import PERFORMANCE_WORKLOADS
    environment = {'device': {'identifier': 'phone', 'model': 'iPhone', 'systemVersion': '17', 'systemBuild': 'build'},
        'xcode': {'DTXcodeBuild': 'xcode'}, 'compiler': {'sha256': 'a' * 64}}
    row = {'exitCode': 0, 'scope': 'full', 'inputDigest': 'digest', 'runID': 'run', 'sourceCommit': 'commit',
        'recordedAt': 'captured', 'environment': environment, 'resultBundleSHA256': 'b' * 64}
    def exported(command, **kwargs):
        if 'summary' in command: return '{"result":"Passed"}'
        return json.dumps([{'testIdentifier': command[-1], 'testRuns': [{'device': {'deviceId': 'phone'}, 'metrics': [
            {'identifier': identifier, 'unitOfMeasurement': unit, 'measurements': [1, 2]}
            for identifier, unit, _ in subject.METRICS.values()]}]}])
    with patch.object(subject.subprocess, 'check_output', side_effect=exported), \
            patch.object(subject, 'bundle_digest', return_value='b' * 64):
        row['performance'] = subject.extract_measurements(row)
    assert set(row['performance']['records']) == set(PERFORMANCE_WORKLOADS)
    with patch.object(Path, 'read_text', return_value=json.dumps({'groups': {'all': row}})), \
            patch.object(subject, 'environment_context', return_value=environment), \
            patch.object(subject, 'complete_environment', return_value=True), \
            patch.object(subject, 'uncommitted_inputs', return_value=[]), \
            patch.object(subject, 'record_complete', return_value=True), \
            patch('validation_evidence.source_digest', return_value='digest'), \
            patch.object(subject.subprocess, 'check_output', side_effect=AssertionError('后续宿主的结果包沿独立运行继续复用')):
        assert subject.capture_current() == row['performance']
        for field, value in [('runID', 'other'), ('resultBundleSHA256', 'c' * 64), ('sourceCommit', 'other')]:
            changed = deepcopy(row)
            changed[field] = value
            with patch.object(Path, 'read_text', return_value=json.dumps({'groups': {'all': changed}})):
                try: subject.capture_current()
                except ValueError: pass
                else: raise AssertionError('采样需要匹配完成时的生产运行')
