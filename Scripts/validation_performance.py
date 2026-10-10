#!/usr/bin/env python3
"""Capture XCTest measurements and bind performance acceptance to their producing run."""
import hashlib
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
from validation_provenance import utc_now, complete_group_row

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / '.build/extended-automation/test-results.xcresult'
MEASUREMENTS = ROOT / '.build/extended-automation/performance-measurements.json'
METRICS = {'clockSeconds': ('com.apple.dt.XCTMetric_Clock.time.monotonic', 's', 1),
    'peakPhysicalMemoryBytes': ('com.apple.dt.XCTMetric_Memory.physical_peak', 'kB', 1000)}


def bundle_digest(bundle: Path) -> str:
    if not any((bundle / name).is_file() for name in ('database.sqlite3', 'Info.plist')) or (bundle / 'Staging').exists():
        raise ValueError('性能采样需要完整的 XCTest 结果包。')
    digest = hashlib.sha256()
    for path in sorted(value for value in bundle.rglob('*') if value.is_file()):
        digest.update(path.relative_to(bundle).as_posix().encode() + b'\0')
        with path.open('rb') as stream:
            while data := stream.read(1024 * 1024): digest.update(data)
        digest.update(b'\0')
    return digest.hexdigest()


def merge_result_bundles(retained: Path, merged: Path) -> None:
    shutil.rmtree(merged, ignore_errors=True)
    try:
        subprocess.run(['xcrun', 'xcresulttool', 'merge', '--output-path', str(merged), str(retained), str(BUNDLE)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        bundle_digest(merged)
        subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(merged)])
    except BaseException:
        shutil.rmtree(merged, ignore_errors=True)
        raise
    shutil.rmtree(retained)
    shutil.rmtree(BUNDLE)
    shutil.move(str(merged), str(BUNDLE))


def recover_result_step() -> None:
    retained = BUNDLE.with_suffix('.retained.xcresult')
    merged = BUNDLE.with_suffix('.incoming.xcresult')
    if merged.exists():
        try:
            bundle_digest(merged)
            subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(merged)])
        except (ValueError, OSError, subprocess.CalledProcessError): pass
        else:
            shutil.rmtree(retained, ignore_errors=True)
            shutil.rmtree(BUNDLE, ignore_errors=True)
            shutil.move(str(merged), str(BUNDLE))
            return
    if BUNDLE.exists() and (retained.exists() or merged.exists()):
        try:
            bundle_digest(BUNDLE)
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


def begin_result_step(retain_previous: bool) -> None:
    recover_result_step()
    retained = BUNDLE.with_suffix('.retained.xcresult')
    if retain_previous and BUNDLE.exists():
        shutil.move(str(BUNDLE), str(retained))
    else:
        reset_result_bundle()


def reset_result_bundle() -> None:
    if not BUNDLE.exists(): return
    from validation_evidence import REPORT, report_lock, write_report
    with report_lock():
        if REPORT.is_file():
            report = json.loads(REPORT.read_text())
            report['groups'] = {name: row for name, row in report.get('groups', {}).items()
                if not row.get('resultBundleSHA256') and not row.get('lastFullRun', {}).get('resultBundleSHA256')}
            report.pop('releaseCommit', None)
            report.pop('mergeCommit', None)
            write_report(report)
    shutil.rmtree(BUNDLE)


def result_bundle_findings(report: dict, *, recorded_environment: bool = False) -> list[str]:
    try:
        rows = report.get('groups', {})
        sha = complete_group_row(rows.get('all', {})).get('resultBundleSHA256') if recorded_environment else bundle_digest(BUNDLE)
        if not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{64}', sha): raise ValueError('结果包需要完整摘要。')
        if all(complete_group_row(report.get('groups', {}).get(group, {})).get('resultBundleSHA256') == sha
               for group in ('all', 'ui')): return []
    except (OSError, ValueError): pass
    return ['完整行为及 UI 证据需要对应当前保留的原始 XCTest 结果包。']


def rebind_result_records(report: dict, groups: list[str]) -> dict:
    updated = deepcopy(report)
    rows = []
    for group in groups:
        row = updated.get('groups', {}).get(group)
        if not row: continue
        rows.append(row)
        row.setdefault('runResultBundleSHA256', row.get('resultBundleSHA256'))
        for record in row.get('performance', {}).get('records', {}).values():
            raw = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'metrics',
                '--path', str(BUNDLE), '--test-id', record['testIdentifier'] + '()'], text=True))
            device = record['execution']['environment']['device']['identifier']
            if normalize_metrics(raw, record['testIdentifier'], device) != normalize_metrics(
                    record['xcresultMetrics'], record['testIdentifier'], device):
                raise ValueError('合并结果包需要保留所属测试组的实际性能采样。')
            record['xcresultMetrics'] = raw
    sha = bundle_digest(BUNDLE)
    for row in rows:
        for record in row.get('performance', {}).get('records', {}).values():
            record['execution']['bundleSHA256'] = sha
            record['resultBundle']['sha256'] = sha
        row['resultBundleSHA256'] = sha
    return updated


def retain_result_step(groups: list[str]) -> None:
    merge_result_step(groups)


def merge_result_step(groups: list[str]) -> None:
    from validation_evidence import REPORT, report_lock, write_report
    retained = BUNDLE.with_suffix('.retained.xcresult')
    merged = BUNDLE.with_suffix('.incoming.xcresult')
    current_sha = bundle_digest(BUNDLE) if BUNDLE.exists() else None
    validated = False
    if retained.exists():
        if BUNDLE.exists():
            merge_result_bundles(retained, merged)
            validated = True
        else:
            shutil.move(str(retained), str(BUNDLE))
    if not BUNDLE.exists(): return
    if not validated:
        subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(BUNDLE)])
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        if current_sha and (row := report.get('groups', {}).get(groups[-1])):
            row['runResultBundleSHA256'] = current_sha
        write_report(rebind_result_records(report, groups))


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
        'xcodeBuild': context['xcode']['DTXcodeBuild'], 'compilerSHA256': context['compiler']['sha256'],
        'configuration': 'Release', 'compilationConditions': sorted(workflow_conditions(group))}


def current_commit() -> str:
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, capture_output=True, check=True).stdout.strip()


def record_complete(record: dict, *, current: bool) -> bool:
    try:
        execution = record['execution']
        context = execution['environment']
        from validation_manual import PERFORMANCE_WORKLOADS, performance_group
        test = record['testIdentifier']
        if test not in {row[0] for row in PERFORMANCE_WORKLOADS.values()}: return False
        group = performance_group(test)
        if execution.get('group') != group or not complete_environment(group, context) \
                or record['environment'] != measurement_environment(context, group) \
                or execution['sourceCommit'] != record['sourceCommit'] \
                or not execution.get('runID') or not execution.get('inputDigest') \
                or record['resultBundle']['path'] != '.build/extended-automation/test-results.xcresult' \
                or execution.get('bundleSHA256') != record['resultBundle']['sha256']:
            return False
        normalized = normalize_metrics(record['xcresultMetrics'], record['testIdentifier'], context['device']['identifier'])
        if any({key: metric[key] for key in ('samples', 'mean')} != normalized[name] for name, metric in record['metrics'].items()):
            return False
        if current:
            from validation_evidence import source_digest
            if record['sourceCommit'] != current_commit() or execution['inputDigest'] != source_digest(group, environment=context): return False
        return True
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError):
        return False


def approved_baseline_complete(proof: dict) -> bool:
    from validation_manual import PERFORMANCE_WORKLOADS
    try:
        if proof.get('schemaVersion') != 1 or set(proof['records']) != set(PERFORMANCE_WORKLOADS): return False
        for name, record in proof['records'].items():
            test, workload = PERFORMANCE_WORKLOADS[name]
            if record['testIdentifier'] != test or record['input'] != workload or not record_complete(record, current=False) \
                    or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', record['sourceCommit']) \
                    or not re.fullmatch(r'[0-9a-f]{64}', record['resultBundle']['sha256']) \
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
    from validation_manual import PERFORMANCE_WORKLOADS, performance_group
    context = row['environment']
    summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(BUNDLE)], text=True))
    if summary.get('result') != 'Passed': raise ValueError('性能结果包需要成功执行。')
    sha = bundle_digest(BUNDLE)
    if row.get('resultBundleSHA256') != sha:
        raise ValueError('性能结果包需要匹配所属构建运行的摘要与源码提交。')
    execution = {'group': group, 'runID': row['runID'], 'inputDigest': row['inputDigest'],
        'sourceCommit': row['sourceCommit'], 'environment': context, 'bundleSHA256': sha}
    records = {}
    for name, (test, workload) in PERFORMANCE_WORKLOADS.items():
        if performance_group(test) != group: continue
        raw = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'metrics',
            '--path', str(BUNDLE), '--test-id', test + '()'], text=True))
        records[name] = {'testIdentifier': test, 'sourceCommit': execution['sourceCommit'], 'input': workload,
            'capturedAt': row['recordedAt'], 'environment': measurement_environment(context, group), 'execution': execution,
            'resultBundle': {'path': str(BUNDLE.relative_to(ROOT)), 'sha256': sha}, 'xcresultMetrics': raw,
            'metrics': normalize_metrics(raw, test, context['device']['identifier'])}
    if bundle_digest(BUNDLE) != sha: raise ValueError('性能结果包需要保持完整采样期间的内容身份。')
    return {'schemaVersion': 1, 'records': records}


def uncommitted_inputs() -> list[str]:
    from validation_inputs import includes_input
    tracked = subprocess.check_output(['git', 'diff', '--name-only', '-z', 'HEAD', '--'], cwd=ROOT)
    untracked = subprocess.check_output(['git', 'ls-files', '-z', '--others', '--exclude-standard'], cwd=ROOT)
    return [name for name in (tracked + untracked).decode().split('\0')
        if name and any(includes_input(name, group) for group in ('all', 'ui'))]


def capture_current() -> dict:
    from validation_evidence import REPORT, source_digest
    if uncommitted_inputs(): raise ValueError('性能采样需要已提交的构建输入。')
    groups = json.loads(REPORT.read_text())['groups']
    retained_sha = bundle_digest(BUNDLE)
    from validation_manual import PERFORMANCE_WORKLOADS, performance_group
    records = {}
    for group in ('all', 'ui'):
        row = complete_group_row(groups[group])
        context = environment_context(group)
        if row.get('exitCode') != 0 or row.get('scope') != 'full' or row.get('resultBundleSHA256') != retained_sha \
                or exchange_identity(row.get('environment')) != exchange_identity(context) \
                or row.get('inputDigest') != source_digest(group) or not complete_environment(group, context):
            raise ValueError('性能采样需要当前源码、工具链及实体设备上成功执行的完整行为与 UI 组。')
        proof = row['performance']
        expected = {name for name, (test, _) in PERFORMANCE_WORKLOADS.items() if performance_group(test) == group}
        if proof.get('schemaVersion') != 1 or set(proof['records']) != expected:
            raise ValueError('性能采样需要全部登记工作负载的原始指标。')
        for record in proof['records'].values():
            execution = record['execution']
            if not record_complete(record, current=True) or record['capturedAt'] != row['recordedAt'] \
                    or any(execution[key] != row[field]
                    for key, field in [('runID', 'runID'), ('inputDigest', 'inputDigest'), ('sourceCommit', 'sourceCommit'),
                        ('environment', 'environment'), ('bundleSHA256', 'resultBundleSHA256')]):
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
    from validation_manual import PERFORMANCE_WORKLOADS, performance_group, performance_comparison_complete
    try:
        approved = report['performanceBaseline']
        if approved.get('schemaVersion') != 1 or set(approved['records']) != set(PERFORMANCE_WORKLOADS):
            raise ValueError()
        errors = []
        for group in ('all', 'ui'):
            row = complete_group_row(report['groups'][group])
            proof = row['performance']
            expected = {name for name, (test, _) in PERFORMANCE_WORKLOADS.items() if performance_group(test) == group}
            if proof.get('schemaVersion') != 1 or set(proof['records']) != expected:
                raise ValueError()
            for name, current in proof['records'].items():
                if current['sourceCommit'] != commit or current['capturedAt'] != row['recordedAt'] \
                        or any(current['execution'][key] != row[field] for key, field in (
                            ('runID', 'runID'), ('inputDigest', 'inputDigest'), ('sourceCommit', 'sourceCommit'),
                            ('environment', 'environment'), ('bundleSHA256', 'resultBundleSHA256'))) \
                        or not performance_comparison_complete(name, {'current': current, 'baseline': approved['records'][name]}):
                    errors.append(f'{name} 需要本次完整真机采样与同环境批准基线，并满足性能退化上限。')
        return errors
    except (KeyError, TypeError, ValueError, AttributeError):
        return [f'合并验收需要 {len(PERFORMANCE_WORKLOADS)} 个性能场景的完整采样和维护者批准基线。']


def main(arguments: list[str]) -> int:
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
        from validation_evidence import REPORT, report_lock, write_report
        with report_lock():
            stored = json.loads(MEASUREMENTS.read_text()) if MEASUREMENTS.is_file() else {'schemaVersion': 1}
            stored[kind] = proof
            MEASUREMENTS.write_text(json.dumps(stored, ensure_ascii=False, indent=2) + '\n')
            if kind == 'baseline':
                report = json.loads(REPORT.read_text())
                report['performanceBaseline'] = proof
                report.pop('mergeCommit', None)
                write_report(report)
        print(MEASUREMENTS)
        return 0
    raise ValueError('性能命令：current；baseline 批准人 [最大退化百分比]。')


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors='replace').strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        print(detail, file=sys.stderr)
        raise SystemExit(1)
