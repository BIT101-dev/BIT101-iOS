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
    batch_retention_self_test(raw, test)
    merge_regression_self_test()
    baseline_migration_self_test()


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
                patch('validation_evidence.report_lock', side_effect=nullcontext), patch('validation_evidence.write_report') as save, \
                patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'read_text', autospec=True,
                    side_effect=lambda path: json.dumps(retained if path == ci_evidence.REPORT else {'schemaVersion': 1, 'current': 'retained'})), \
                patch.object(Path, 'write_text') as measurements:
            try: ci_evidence.import_baseline(7)
            except ValueError: assert fault != 'none'
            else:
                assert fault == 'none'
                assert save.call_args.args[0] == {key: value for key, value in retained.items() if key != 'mergeCommit'} | {'performanceBaseline': proof}
                assert json.loads(measurements.call_args.args[0])['current'] == 'retained'
            if fault != 'none':
                save.assert_not_called(); measurements.assert_not_called()


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
            patch.object(subject, 'bundle_digest', return_value='b' * 64), \
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


def batch_retention_self_test(raw: list, test: str) -> None:
    import json
    import shutil
    import subprocess
    import sys
    from contextlib import nullcontext
    import validation_evidence
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
        'execution': {'environment': {'device': {'identifier': 'phone'}}, 'bundleSHA256': 'original', 'runID': 'run'},
        'resultBundle': {'sha256': 'original'}}
    report = {'groups': {'all': {'resultBundleSHA256': 'original', 'performance': {'records': {'sample': record}}},
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
            patch.object(subject, 'bundle_digest', return_value='aggregate') as digest:
        updated = subject.rebind_result_records(report, ['all', 'ui'])
        digest.assert_called_once_with(subject.BUNDLE)
    assert report['groups']['all']['resultBundleSHA256'] == 'original'
    assert updated['groups']['all']['runResultBundleSHA256'] == 'original'
    assert updated['groups']['all']['performance']['records']['sample']['execution']['bundleSHA256'] == 'aggregate'
    assert updated['groups']['all']['performance']['records']['sample']['resultBundle']['sha256'] == 'aggregate'
    assert updated['performanceBaseline'] == report['performanceBaseline']
    altered = deepcopy(raw)
    altered[0]['testRuns'][0]['metrics'][0]['measurements'] = [99]
    for value in (altered, duplicate):
        with patch.object(subject.subprocess, 'check_output', return_value=json.dumps(value)):
            try: subject.rebind_result_records(report, ['all'])
            except ValueError: pass
            else: raise AssertionError('合并结果包需要保留所属运行的原始采样')
        assert report['groups']['all']['resultBundleSHA256'] == 'original'
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
        assert subject.bundle_digest(bundle)
        (bundle / 'Staging').mkdir()
        try: subject.bundle_digest(bundle)
        except ValueError: pass
        else: raise AssertionError('结果包完成写入后提供采样摘要')
        (bundle / 'Staging').rmdir()
        (bundle / 'Info.plist').rename(bundle / 'database.sqlite3')
        with patch.object(subject, 'BUNDLE', bundle), patch.object(validation_evidence, 'REPORT', report_path), \
                patch.object(validation_evidence, 'report_lock', side_effect=nullcontext), \
                patch.object(validation_evidence, 'write_report') as writer, \
                patch.object(subject.subprocess, 'run', side_effect=merge), \
                patch.object(subject.subprocess, 'check_output', side_effect=exported):
            first_sha = subject.bundle_digest(bundle)
            report['groups']['all']['resultBundleSHA256'] = first_sha
            report_path.write_text(json.dumps(report))
            assert subject.main(['begin-batch', 'append']) == 0
            assert retained.is_dir() and not bundle.exists()
            create(bundle, b'second')
            second_sha = subject.bundle_digest(bundle)
            assert subject.main(['retain-batch', 'all', 'ui']) == 0
            saved = writer.call_args.args[0]
            assert (bundle / 'database.sqlite3').read_bytes() == b'firstsecond'
            assert not retained.exists() and not incoming.exists()
            assert saved['groups']['all']['runResultBundleSHA256'] == first_sha
            assert saved['groups']['ui']['runResultBundleSHA256'] == second_sha
            assert all(row['resultBundleSHA256'] == subject.bundle_digest(bundle) for row in saved['groups'].values())
            assert (bundle / 'Info.plist').is_file() and (bundle / 'database.sqlite3').is_file()
            writer.reset_mock()
            assert subject.main(['begin-batch', 'append']) == 0
            assert subject.main(['retain-batch', 'all', 'ui', 'release-runtime']) == 0
            assert (bundle / 'database.sqlite3').read_bytes() == b'firstsecond' and not retained.exists()
            report_path.write_text(json.dumps({'groups': {'catalyst': {'runID': 'catalyst'}}}))
            assert subject.main(['begin-batch', 'append']) == 0
            create(bundle, b'catalyst')
            assert subject.main(['retain-batch', 'catalyst']) == 0
            assert writer.call_args.args[0]['groups']['catalyst']['resultBundleSHA256'] == subject.bundle_digest(bundle)
            assert (bundle / 'database.sqlite3').is_file()
            assert subject.main(['begin-batch', 'append']) == 0
            create(bundle, b'failed')
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
                writer.assert_not_called()
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
                writer.assert_not_called()
                with patch.object(subject.subprocess, 'run') as repeated_merge:
                    subject.recover_result_step()
                    subject.recover_result_step()
                    repeated_merge.assert_not_called()
                assert (bundle / 'database.sqlite3').read_bytes() == b'previouscurrent'
                assert not retained.exists() and not incoming.exists()
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
