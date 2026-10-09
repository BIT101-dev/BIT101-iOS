"""Capture XCTest measurements and bind performance acceptance to their producing run."""
import hashlib
import json
import math
from pathlib import Path
import subprocess
from validation_environment import complete_environment, environment_context
from validation_provenance import utc_now

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / '.build/extended-automation/test-results.xcresult'
MEASUREMENTS = ROOT / '.build/extended-automation/performance-measurements.json'
METRICS = {'clockSeconds': ('com.apple.dt.XCTMetric_Clock.time.monotonic', 's', 1),
    'peakPhysicalMemoryBytes': ('com.apple.dt.XCTMetric_Memory.physical_peak', 'kB', 1000)}


def bundle_digest(bundle: Path) -> str:
    if not (bundle / 'database.sqlite3').is_file() or (bundle / 'Staging').exists():
        raise ValueError('性能采样需要完整的 XCTest 结果包。')
    digest = hashlib.sha256()
    for path in sorted(value for value in bundle.rglob('*') if value.is_file()):
        digest.update(path.relative_to(bundle).as_posix().encode() + b'\0')
        with path.open('rb') as stream:
            while data := stream.read(1024 * 1024): digest.update(data)
        digest.update(b'\0')
    return digest.hexdigest()


def normalize_metrics(raw: list, test: str, device: str) -> dict:
    if not isinstance(raw, list) or len(raw) != 1 or raw[0].get('testIdentifier') != test + '()':
        raise ValueError('性能指标需要对应的唯一 XCTest 用例。')
    runs = raw[0]['testRuns']
    if len(runs) != 1 or runs[0]['device']['deviceId'] != device:
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


def measurement_environment(context: dict) -> dict:
    device = context['device']
    return {'deviceIdentifier': device['identifier'], 'deviceModel': device['model'],
        'systemVersion': device['systemVersion'], 'systemBuild': device['systemBuild'],
        'xcodeBuild': context['xcode']['DTXcodeBuild'], 'compilerSHA256': context['compiler']['sha256'],
        'configuration': 'Release', 'compilationConditions': ['BIT101_AUTOMATED_TESTING', 'DEBUG', 'EXTENDED_AUTOMATION']}


def current_commit() -> str:
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, capture_output=True, check=True).stdout.strip()


def record_complete(record: dict, *, current: bool) -> bool:
    try:
        execution = record['execution']
        context = execution['environment']
        if execution.get('group') != 'all' or not complete_environment('all', context) \
                or record['environment'] != measurement_environment(context) \
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
            if record['sourceCommit'] != current_commit() or execution['inputDigest'] != source_digest('all', environment=context): return False
        return True
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError):
        return False


def extract_measurements(row: dict) -> dict:
    from validation_manual import PERFORMANCE_WORKLOADS
    context = row['environment']
    summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(BUNDLE)], text=True))
    if summary.get('result') != 'Passed': raise ValueError('性能结果包需要成功执行。')
    sha = bundle_digest(BUNDLE)
    if row.get('resultBundleSHA256') != sha:
        raise ValueError('性能结果包需要匹配所属构建运行的摘要与源码提交。')
    execution = {'group': 'all', 'runID': row['runID'], 'inputDigest': row['inputDigest'],
        'sourceCommit': row['sourceCommit'], 'environment': context, 'bundleSHA256': sha}
    records = {}
    for name, (test, workload) in PERFORMANCE_WORKLOADS.items():
        raw = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'metrics',
            '--path', str(BUNDLE), '--test-id', test + '()'], text=True))
        records[name] = {'testIdentifier': test, 'sourceCommit': execution['sourceCommit'], 'input': workload,
            'capturedAt': row['recordedAt'], 'environment': measurement_environment(context), 'execution': execution,
            'resultBundle': {'path': str(BUNDLE.relative_to(ROOT)), 'sha256': sha}, 'xcresultMetrics': raw,
            'metrics': normalize_metrics(raw, test, context['device']['identifier'])}
    if bundle_digest(BUNDLE) != sha: raise ValueError('性能结果包需要保持完整采样期间的内容身份。')
    return {'schemaVersion': 1, 'records': records}


def uncommitted_inputs() -> list[str]:
    from validation_inputs import includes_input
    tracked = subprocess.check_output(['git', 'diff', '--name-only', '-z', 'HEAD', '--'], cwd=ROOT)
    untracked = subprocess.check_output(['git', 'ls-files', '-z', '--others', '--exclude-standard'], cwd=ROOT)
    return [name for name in (tracked + untracked).decode().split('\0') if name and includes_input(name, 'all')]


def capture_current() -> dict:
    from validation_evidence import REPORT, source_digest
    row = json.loads(REPORT.read_text())['groups']['all']
    context = environment_context('all')
    if row.get('exitCode') != 0 or row.get('scope') != 'full' or row.get('environment') != context \
            or row.get('inputDigest') != source_digest('all') or not complete_environment('all', context):
        raise ValueError('性能采样需要当前源码、工具链及实体设备上成功执行的完整行为组。')
    if uncommitted_inputs(): raise ValueError('性能采样需要已提交的构建输入。')
    proof = row['performance']
    from validation_manual import PERFORMANCE_WORKLOADS
    if proof.get('schemaVersion') != 1 or set(proof['records']) != set(PERFORMANCE_WORKLOADS):
        raise ValueError('性能采样需要全部登记工作负载的原始指标。')
    for record in proof['records'].values():
        execution = record['execution']
        if not record_complete(record, current=True) or record['capturedAt'] != row['recordedAt'] \
                or any(execution[key] != row[field]
                for key, field in [('runID', 'runID'), ('inputDigest', 'inputDigest'), ('sourceCommit', 'sourceCommit'),
                    ('environment', 'environment'), ('bundleSHA256', 'resultBundleSHA256')]):
            raise ValueError('性能采样需要匹配所属行为组完成时提取的原始指标。')
    return proof


def validate_capture(proof: dict) -> None:
    current = capture_current()['records']
    baseline = json.loads(MEASUREMENTS.read_text())['baseline']['records']
    for name, row in proof['scenarios'].items():
        if row['measurement']['current'] != current[name] or row['measurement']['baseline'] != baseline[name]:
            raise ValueError('性能验收需要实际结果包导出的当前采样与已批准基线。')


def main(arguments: list[str]) -> int:
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
        stored = json.loads(MEASUREMENTS.read_text()) if MEASUREMENTS.is_file() else {'schemaVersion': 1}
        stored[kind] = proof
        MEASUREMENTS.write_text(json.dumps(stored, ensure_ascii=False, indent=2) + '\n')
        print(MEASUREMENTS)
        return 0
    raise ValueError('性能命令：current；baseline 批准人 [最大退化百分比]。')
