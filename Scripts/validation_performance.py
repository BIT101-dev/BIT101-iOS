#!/usr/bin/env python3
"""Capture XCTest measurements and bind performance acceptance to their producing run."""
import base64
import json
import math
import re
from datetime import datetime
from pathlib import Path
import subprocess
import shutil
import sys
from copy import deepcopy
from validation_environment import complete_environment, environment_context, exchange_identity
from validation_provenance import utc_now, complete_group_row, sampling_evidence_current
from validation_policy import workflow_conditions
from validation_inputs import performance_workloads, performance_group

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / '.build/extended-automation/test-results.xcresult'
MEASUREMENTS = ROOT / '.build/extended-automation/performance-measurements.json'
METRICS = {'clockSeconds': ('com.apple.dt.XCTMetric_Clock.time.monotonic', 's', 1),
    'peakPhysicalMemoryBytes': ('com.apple.dt.XCTMetric_Memory.physical_peak', 'kB', 1000)}


def result_bundle_complete(bundle: Path) -> bool:
    return any((bundle / name).is_file() for name in ('database.sqlite3', 'Info.plist')) and not (bundle / 'Staging').exists()


def bundle_identity(bundle: Path) -> str:
    if not result_bundle_complete(bundle):
        raise ValueError('性能采样需要完整的 XCTest 结果包。')
    metadata = bundle / 'Info.plist'
    if metadata.is_file():
        return 'plist.' + base64.urlsafe_b64encode(metadata.read_bytes()).decode('ascii')
    database = bundle / 'database.sqlite3'
    with database.open('rb') as stream: header = stream.read(100)
    return 'sqlite.' + str(database.stat().st_size) + '.' + base64.urlsafe_b64encode(header).decode('ascii')


def merge_result_bundles(retained: Path, merged: Path) -> None:
    shutil.rmtree(merged, ignore_errors=True)
    try:
        subprocess.run(['xcrun', 'xcresulttool', 'merge', '--output-path', str(merged), str(retained), str(BUNDLE)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        bundle_identity(merged)
        subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(merged)])
    except BaseException:
        shutil.rmtree(merged, ignore_errors=True)
        raise
    bind_pending_result_merge(merged)
    shutil.rmtree(retained)
    shutil.rmtree(BUNDLE)
    shutil.move(str(merged), str(BUNDLE))


def recover_result_bundle() -> None:
    retained = BUNDLE.with_suffix('.retained.xcresult')
    merged = BUNDLE.with_suffix('.incoming.xcresult')
    if merged.exists():
        try:
            bundle_identity(merged)
            subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(merged)])
        except (ValueError, OSError, subprocess.CalledProcessError): pass
        else:
            bind_pending_result_merge(merged)
            shutil.rmtree(retained, ignore_errors=True)
            shutil.rmtree(BUNDLE, ignore_errors=True)
            shutil.move(str(merged), str(BUNDLE))
            return
    if BUNDLE.exists() and (retained.exists() or merged.exists()):
        try:
            bundle_identity(BUNDLE)
            subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(BUNDLE)])
        except (ValueError, OSError, subprocess.CalledProcessError):
            shutil.rmtree(BUNDLE)
    if BUNDLE.exists() and retained.exists():
        merge_result_bundles(retained, merged)
        return
    if not BUNDLE.exists() and retained.exists():
        shutil.move(str(retained), str(BUNDLE))
    shutil.rmtree(retained, ignore_errors=True)
    shutil.rmtree(merged, ignore_errors=True)


def bind_pending_result_merge(bundle: Path) -> None:
    from validation_provenance import REPORT, report_lock, write_report
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        if pending := report.get('resultMerge'):
            pending['bundleIdentity'] = bundle_identity(bundle)
            write_report(report)


def complete_pending_result_merge() -> None:
    from validation_provenance import REPORT, report_lock, write_report
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        pending = report.get('resultMerge')
        if not pending: return
        if pending.get('bundleIdentity') != bundle_identity(BUNDLE):
            raise ValueError('结果包恢复需要待发布合并包的完整摘要。')
        groups = pending['groups']
        producing = pending.get('producingGroup', groups[-1])
        if pending['currentIdentity'] and producing and (row := report.get('groups', {}).get(producing)):
            row['runResultBundleIdentity'] = pending['currentIdentity']
        report = rebind_result_records(report, groups)
        report.pop('resultMerge')
        write_report(report)


def recover_result_step() -> None:
    recover_result_bundle()
    complete_pending_result_merge()


def begin_result_step(retain_previous: bool) -> None:
    recover_result_step()
    retained = BUNDLE.with_suffix('.retained.xcresult')
    if retain_previous and BUNDLE.exists():
        shutil.move(str(BUNDLE), str(retained))
    else:
        reset_result_bundle()


def begin_selected_result_step() -> list[str]:
    from validation_provenance import REPORT, source_digest, report_lock
    recover_result_step()
    groups = []
    if BUNDLE.exists():
        try: sha = bundle_identity(BUNDLE)
        except ValueError:
            print('中断的 XCTest 结果包已进入清理与重新采样。', file=sys.stderr)
            begin_result_step(False)
            return []
        with report_lock():
            report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        for name, row in report.get('groups', {}).items():
            full = complete_group_row(row)
            if full.get('scope') == 'full' and full.get('exitCode') == 0 and full.get('summary', {}).get('passed') is True \
                    and sampling_evidence_current({'startedAt': full.get('recordedAt', ''), 'finishedAt': full.get('recordedAt', '')}) \
                    and full.get('resultBundleIdentity') == sha and full.get('inputDigest') == source_digest(name) \
                    and exchange_identity(full.get('environment')) == exchange_identity(environment_context(name)):
                groups.append(name)
    begin_result_step(bool(groups))
    return groups


def reset_result_bundle() -> None:
    if not BUNDLE.exists(): return
    from validation_provenance import REPORT, report_lock, write_report
    with report_lock():
        if REPORT.is_file():
            report = json.loads(REPORT.read_text())
            invalidated = sorted(name for name, row in report.get('groups', {}).items()
                if row.get('resultBundleIdentity') or row.get('lastFullRun', {}).get('resultBundleIdentity'))
            if invalidated:
                print('覆盖原始结果包：' + '、'.join(invalidated) + ' 的验证证据将进入重新验收。', file=sys.stderr)
            report['groups'] = {name: row for name, row in report.get('groups', {}).items() if name not in invalidated}
            report.pop('releaseCommit', None)
            report.pop('mergeCommit', None)
            report.pop('resultMerge', None)
            write_report(report)
    shutil.rmtree(BUNDLE)


def result_bundle_findings(report: dict, *, recorded_environment: bool = False,
                           groups: tuple[str, ...] = ('all', 'ui')) -> list[str]:
    try:
        rows = report.get('groups', {})
        sha = complete_group_row(rows.get(groups[0], {})).get('resultBundleIdentity') if recorded_environment else bundle_identity(BUNDLE)
        if not isinstance(sha, str) or not sha.strip(): raise ValueError('结果包需要原生元数据标识。')
        if all(complete_group_row(report.get('groups', {}).get(group, {})).get('resultBundleIdentity') == sha
               for group in groups): return []
    except (OSError, ValueError): pass
    return ['执行证据需要对应当前保留的原始 XCTest 结果包。']


def rebind_result_records(report: dict, groups: list[str]) -> dict:
    updated = deepcopy(report)
    rows = []
    for group in groups:
        row = updated.get('groups', {}).get(group)
        if not row: continue
        rows.append(row)
        if row.get('lastFullRun'): rows.append(row['lastFullRun'])
    for row in rows:
        row.setdefault('runResultBundleIdentity', row.get('resultBundleIdentity'))
        for record in row.get('performance', {}).get('records', {}).values():
            raw = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'metrics',
                '--path', str(BUNDLE), '--test-id', record['testIdentifier'] + '()'], text=True))
            device = record['execution']['environment']['device']['identifier']
            expected = normalize_metrics(record['xcresultMetrics'], record['testIdentifier'], device)
            matches = [dict(value, testRuns=[run]) for value in raw for run in value.get('testRuns', [])
                if run.get('device', {}).get('deviceId') == device]
            if sum(normalize_metrics([value], record['testIdentifier'], device) == expected for value in matches) != 1:
                raise ValueError('合并结果包需要保留所属测试组的实际性能采样。')
    sha = bundle_identity(BUNDLE)
    for row in rows:
        for record in row.get('performance', {}).get('records', {}).values():
            record['execution']['bundleIdentity'] = sha
            record['resultBundle']['identity'] = sha
        row['resultBundleIdentity'] = sha
    return updated


def retain_result_step(groups: list[str]) -> None:
    merge_result_step(groups, producing_group=groups[-1])


def merge_result_step(groups: list[str], *, producing_group: str | None = None) -> None:
    from validation_provenance import REPORT, report_lock, write_report
    retained = BUNDLE.with_suffix('.retained.xcresult')
    merged = BUNDLE.with_suffix('.incoming.xcresult')
    current_sha = bundle_identity(BUNDLE) if BUNDLE.exists() else None
    if not BUNDLE.exists() and not retained.exists(): return
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        report['resultMerge'] = {'groups': groups, 'currentIdentity': current_sha, 'producingGroup': producing_group,
            'bundleIdentity': current_sha or bundle_identity(retained)}
        write_report(report)
    validated = False
    if retained.exists():
        if BUNDLE.exists():
            merge_result_bundles(retained, merged)
            validated = True
        else:
            bind_pending_result_merge(retained)
            shutil.move(str(retained), str(BUNDLE))
    if not BUNDLE.exists(): return
    if not validated:
        subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(BUNDLE)])
        bind_pending_result_merge(BUNDLE)
    complete_pending_result_merge()


def normalize_metrics(raw: list, test: str, device: str) -> dict:
    if not isinstance(raw, list) or len(raw) != 1 or raw[0].get('testIdentifier') != test + '()':
        raise ValueError('性能指标需要对应的唯一 XCTest 用例。')
    runs = [run for run in raw[0]['testRuns'] if run['device']['deviceId'] == device]
    if len(runs) != 1:
        raise ValueError('性能指标需要来自所属实体设备。')
    result = {}
    for name, (identifier, unit, scale) in METRICS.items():
        rows = [row for row in runs[0]['metrics'] if row.get('identifier') == identifier]
        if len(rows) != 1 or rows[0].get('unitOfMeasurement') != unit:
            raise ValueError('XCTest 性能指标需要完整标识和实际计量单位。')
        values = rows[0]['measurements']
        if not values or not all(type(value) in (int, float) and math.isfinite(value) and value >= 0 for value in values):
            raise ValueError('XCTest 性能指标需要有效的原始采样值。')
        samples = [value * scale for value in values]
        result[name] = {'samples': samples, 'mean': sum(samples) / len(samples)}
    return result


def measurement_environment(context: dict, group: str = 'all') -> dict:
    from validation_policy import workflow_conditions
    device = context['device']
    return {'deviceIdentifier': device['identifier'], 'deviceModel': device['model'],
        'systemVersion': device['systemVersion'], 'systemBuild': device['systemBuild'],
        'xcodeBuild': context['xcode']['DTXcodeBuild'], 'compilerVersion': context['compiler']['version'],
        'configuration': 'Release', 'compilationConditions': sorted(workflow_conditions(group))}


def current_commit() -> str:
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, capture_output=True, check=True).stdout.strip()


def record_complete(record: dict, *, current: bool) -> bool:
    try:
        execution = record['execution']
        context = execution['environment']
        from validation_inputs import performance_workloads, performance_group
        test = record['testIdentifier']
        if test not in {row[0] for row in performance_workloads().values()}: return False
        group = performance_group(test)
        if execution.get('group') != group or not complete_environment(group, context) \
                or record['environment'] != measurement_environment(context, group) \
                or execution['sourceCommit'] != record['sourceCommit'] \
                or not execution.get('runID') or not execution.get('inputDigest') \
                or record['resultBundle']['path'] != '.build/extended-automation/test-results.xcresult' \
                or execution.get('bundleIdentity') != record['resultBundle']['identity']:
            return False
        normalized = normalize_metrics(record['xcresultMetrics'], record['testIdentifier'], context['device']['identifier'])
        if any({key: metric[key] for key in ('samples', 'mean')} != normalized[name] for name, metric in record['metrics'].items()):
            return False
        if current:
            from validation_provenance import source_digest
            if record['sourceCommit'] != current_commit() or execution['inputDigest'] != source_digest(group, environment=context): return False
        return True
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError):
        return False


def approved_baseline_complete(proof: dict) -> bool:
    from validation_inputs import performance_workloads
    try:
        if proof.get('schemaVersion') != 1 or set(proof['records']) != set(performance_workloads()): return False
        for name, record in proof['records'].items():
            test, workload = performance_workloads()[name]
            if record['testIdentifier'] != test or record['input'] != workload or not record_complete(record, current=False) \
                    or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', record['sourceCommit']) \
                    or not isinstance(record['resultBundle']['identity'], str) or not record['resultBundle']['identity'].strip() \
                    or not isinstance(record.get('approvedBy'), str) or not record['approvedBy'].strip() \
                    or set(record['metrics']) != set(METRICS): return False
            captured, approved = (datetime.fromisoformat(record[key].replace('Z', '+00:00'))
                for key in ('capturedAt', 'approvedAt'))
            if captured.tzinfo is None or approved.tzinfo is None or not captured <= approved <= utc_now(): return False
            for metric in record['metrics'].values():
                limit = metric['maximumRegressionPercent']
                if metric['mean'] <= 0 or type(limit) not in (int, float) or not math.isfinite(limit) or limit < 0: return False
        return True
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


def extract_measurements(row: dict, group: str = 'all') -> dict:
    from validation_inputs import performance_workloads, performance_group
    context = row['environment']
    summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(BUNDLE)], text=True))
    if summary.get('result') != 'Passed': raise ValueError('性能结果包需要成功执行。')
    sha = bundle_identity(BUNDLE)
    if row.get('resultBundleIdentity') != sha:
        raise ValueError('性能结果包需要匹配所属构建运行的摘要与源码提交。')
    execution = {'group': group, 'runID': row['runID'], 'inputDigest': row['inputDigest'],
        'sourceCommit': row['sourceCommit'], 'environment': context, 'bundleIdentity': sha}
    records = {}
    for name, (test, workload) in performance_workloads().items():
        if performance_group(test) != group: continue
        raw = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'metrics',
            '--path', str(BUNDLE), '--test-id', test + '()'], text=True))
        records[name] = {'testIdentifier': test, 'sourceCommit': execution['sourceCommit'], 'input': workload,
            'capturedAt': row['recordedAt'], 'environment': measurement_environment(context, group), 'execution': execution,
            'resultBundle': {'path': str(BUNDLE.relative_to(ROOT)), 'identity': sha}, 'xcresultMetrics': raw,
            'metrics': normalize_metrics(raw, test, context['device']['identifier'])}
    if bundle_identity(BUNDLE) != sha: raise ValueError('性能结果包需要保持完整采样期间的内容身份。')
    return {'schemaVersion': 1, 'records': records}


def uncommitted_inputs() -> list[str]:
    from validation_inputs import includes_input
    tracked = subprocess.check_output(['git', 'diff', '--name-only', '-z', 'HEAD', '--'], cwd=ROOT)
    untracked = subprocess.check_output(['git', 'ls-files', '-z', '--others', '--exclude-standard'], cwd=ROOT)
    return [name for name in (tracked + untracked).decode().split('\0')
        if name and any(includes_input(name, group) for group in ('all', 'ui'))]


def capture_current() -> dict:
    from validation_provenance import REPORT, source_digest
    if uncommitted_inputs(): raise ValueError('性能采样需要已提交的构建输入。')
    groups = json.loads(REPORT.read_text())['groups']
    retained_sha = bundle_identity(BUNDLE)
    from validation_inputs import performance_workloads, performance_group
    records = {}
    for group in ('all', 'ui'):
        row = complete_group_row(groups[group])
        context = environment_context(group)
        if row.get('exitCode') != 0 or row.get('scope') != 'full' or row.get('resultBundleIdentity') != retained_sha \
                or exchange_identity(row.get('environment')) != exchange_identity(context) \
                or row.get('inputDigest') != source_digest(group) or not complete_environment(group, context):
            raise ValueError('性能采样需要当前源码、工具链及实体设备上成功执行的完整行为与 UI 组。')
        proof = row['performance']
        expected = {name for name, (test, _) in performance_workloads().items() if performance_group(test) == group}
        if proof.get('schemaVersion') != 1 or set(proof['records']) != expected:
            raise ValueError('性能采样需要全部登记工作负载的原始指标。')
        for record in proof['records'].values():
            execution = record['execution']
            if not record_complete(record, current=True) or record['capturedAt'] != row['recordedAt'] \
                    or any(execution[key] != row[field]
                    for key, field in [('runID', 'runID'), ('inputDigest', 'inputDigest'), ('sourceCommit', 'sourceCommit'),
                        ('environment', 'environment'), ('bundleIdentity', 'resultBundleIdentity')]):
                raise ValueError('性能采样需要匹配所属测试组完成时提取的原始指标。')
        records.update(proof['records'])
    return {'schemaVersion': 1, 'records': records}


def validate_capture(proof: dict) -> None:
    current = capture_current()['records']
    baseline = json.loads(MEASUREMENTS.read_text())['baseline']['records']
    for name, row in proof['scenarios'].items():
        if row['measurement']['current'] != current[name] or row['measurement']['baseline'] != baseline[name]:
            raise ValueError('性能验收需要实际结果包导出的当前采样与已批准基线。')


def merge_findings(report: dict, commit: str) -> list[str]:
    from validation_inputs import performance_workloads, performance_group
    try:
        approved = report['performanceBaseline']
        if approved.get('schemaVersion') != 1 or set(approved['records']) != set(performance_workloads()):
            raise ValueError()
        errors = []
        for group in ('all', 'ui'):
            row = complete_group_row(report['groups'][group])
            proof = row['performance']
            expected = {name for name, (test, _) in performance_workloads().items() if performance_group(test) == group}
            if proof.get('schemaVersion') != 1 or set(proof['records']) != expected:
                raise ValueError()
            for name, current in proof['records'].items():
                if current['sourceCommit'] != commit or current['capturedAt'] != row['recordedAt'] \
                        or any(current['execution'][key] != row[field] for key, field in (
                            ('runID', 'runID'), ('inputDigest', 'inputDigest'), ('sourceCommit', 'sourceCommit'),
                            ('environment', 'environment'), ('bundleIdentity', 'resultBundleIdentity'))) \
                        or not performance_comparison_complete(name, {'current': current, 'baseline': approved['records'][name]}):
                    errors.append(f'{name} 需要本次完整真机采样与同环境批准基线，并满足性能退化上限。')
        return errors
    except (KeyError, TypeError, ValueError, AttributeError):
        return [f'合并验收需要 {len(performance_workloads())} 个性能场景的完整采样和维护者批准基线。']


def main(arguments: list[str]) -> int:
    if arguments == ['begin-selected']:
        print('\n'.join(begin_selected_result_step()))
        return 0
    if len(arguments) >= 2 and arguments[0] == 'retain-selected':
        retain_result_step([name for name in arguments[2:] if name != arguments[1]] + [arguments[1]])
        return 0
    if len(arguments) > 1 and arguments[0] == 'retain-evidence':
        merge_result_step(arguments[1:])
        return 0
    if arguments == ['reset-results']:
        reset_result_bundle()
        return 0
    if arguments == ['recover-batch']:
        recover_result_step()
        return 0
    if len(arguments) == 2 and arguments[0] == 'begin-batch' and arguments[1] in {'first', 'append'}:
        begin_result_step(arguments[1] == 'append')
        return 0
    if len(arguments) > 1 and arguments[0] == 'retain-batch':
        retain_result_step(arguments[1:])
        return 0
    if arguments == ['current'] or len(arguments) in {2, 3} and arguments[0] == 'baseline':
        kind = arguments[0]
        proof = capture_current()
        if kind == 'baseline':
            approver = arguments[1]
            limit = float(arguments[2]) if len(arguments) == 3 else None
            if not approver.strip() or limit is not None and (not math.isfinite(limit) or limit < 0):
                raise ValueError('性能基线需要批准人和有效退化上限。')
            for record in proof['records'].values():
                record.update(approvedBy=approver, approvedAt=utc_now().isoformat())
                raw = record['xcresultMetrics'][0]['testRuns'][0]['metrics']
                for name, metric in record['metrics'].items():
                    default = next(row['maxPercentRegression'] for row in raw if row['identifier'] == METRICS[name][0])
                    metric['maximumRegressionPercent'] = default if limit is None else limit
        from validation_provenance import REPORT, report_lock, write_report
        with report_lock():
            stored = json.loads(MEASUREMENTS.read_text()) if MEASUREMENTS.is_file() else {'schemaVersion': 1}
            stored[kind] = proof
            write_report(stored, path=MEASUREMENTS)
            if kind == 'baseline':
                report = json.loads(REPORT.read_text())
                report['performanceBaseline'] = proof
                report.pop('mergeCommit', None)
                write_report(report)
        print(MEASUREMENTS)
        return 0
    raise ValueError('性能命令：current；baseline 批准人 [最大退化百分比]。')



def performance_comparison_complete(name: str, measurement: dict) -> bool:
    from validation_environment import exchange_identity
    try:
        if not isinstance(measurement, dict): return False
        current, baseline = measurement['current'], measurement['baseline']
        test, workload = performance_workloads()[name]
        for record in (current, baseline):
            if not isinstance(record, dict) or record.get('testIdentifier') != test or record.get('input') != workload \
                    or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', record.get('sourceCommit', '')): return False
            environment = record['environment']
            if not isinstance(environment, dict) or not all(isinstance(environment.get(key), str) and environment[key].strip()
                    for key in ('deviceIdentifier', 'deviceModel', 'systemVersion', 'systemBuild', 'xcodeBuild', 'configuration', 'compilerVersion')) \
                    or environment['configuration'] != 'Release' \
                    or not isinstance(environment.get('compilationConditions'), list) \
                    or not all(isinstance(condition, str) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', condition) for condition in environment['compilationConditions']) \
                    or environment['compilationConditions'] != sorted(workflow_conditions(performance_group(test))): return False
            bundle = record['resultBundle']
            if not isinstance(bundle, dict) or not isinstance(bundle.get('path'), str) or not bundle['path'].endswith('.xcresult') \
                    or not isinstance(bundle.get('identity'), str) or not bundle['identity'].strip(): return False
            if set(record['metrics']) != {'clockSeconds', 'peakPhysicalMemoryBytes'}: return False
            for metric in record['metrics'].values():
                samples, mean = metric['samples'], metric['mean']
                if not isinstance(samples, list) or not samples or not all(type(sample) in (int, float) and math.isfinite(sample) and sample >= 0 for sample in samples) \
                        or type(mean) not in (int, float) or not math.isfinite(mean) or mean <= 0 \
                        or not math.isclose(mean, sum(samples) / len(samples)): return False
        if exchange_identity(current['environment']) != exchange_identity(baseline['environment']) or current['resultBundle']['identity'] == baseline['resultBundle']['identity'] \
                or not sampling_evidence_current({'startedAt': current['capturedAt'], 'finishedAt': current['capturedAt']}) \
                or not isinstance(baseline.get('approvedBy'), str) or not baseline['approvedBy'].strip(): return False
        times = [datetime.fromisoformat(value.replace('Z', '+00:00')) for value in
            (baseline['capturedAt'], baseline['approvedAt'], current['capturedAt'])]
        if any(value.tzinfo is None for value in times) or not times[0] <= times[1] <= times[2]: return False
        for name, metric in current['metrics'].items():
            approved = baseline['metrics'][name]
            limit = approved['maximumRegressionPercent']
            maximum = approved['mean'] * (1 + limit / 100) if type(limit) in (int, float) else math.nan
            if type(limit) not in (int, float) or not math.isfinite(limit) or limit < 0 \
                    or not math.isfinite(maximum) \
                    or len(metric['samples']) != len(approved['samples']) \
                    or metric['mean'] > maximum \
                    or max(metric['samples']) > max(approved['samples']) * (1 + limit / 100): return False
        return record_complete(current, current=True) and record_complete(baseline, current=False)
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
        return False


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors='replace').strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        print(detail, file=sys.stderr)
        raise SystemExit(1)
