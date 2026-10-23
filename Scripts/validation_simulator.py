"""Record simulator producers and validate complete CI inventories independently of device evidence."""
import json
import os
import shutil
import subprocess
from pathlib import Path

METADATA_PREFIX = '模拟器记录：'


def result_metadata(group: str, scope: str, commit: str, device: str, coverage_lines=None) -> dict:
    from validation_environment import environment_context, toolchain_identity
    from validation_provenance import workflow_elapsed_seconds
    context = environment_context('build-release')
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True))
    runtime_id = next(name for name, devices in inventory['devices'].items()
        if any(row['udid'] == device for row in devices))
    runtime = next(row for row in inventory['runtimes'] if row['identifier'] == runtime_id and row['isAvailable'])
    index, count = map(int, os.environ['BIT101_CI_SHARD'].split('/')) if scope == 'shard' else (0, 1)
    value = dict(identity=dict(group=group, index=index, count=count, commit=commit,
        run=os.getenv('GITHUB_RUN_ID', '')), scope=scope, environment=dict(host=context['host'],
        toolchain=toolchain_identity(context), platform=dict(systemVersion=runtime['version'], systemBuild=runtime['buildversion'])))
    if coverage_lines is not None: value['coverageLines'] = coverage_lines
    if (seconds := workflow_elapsed_seconds()) is not None: value['durationSeconds'] = seconds
    return value


def write_result_metadata(path: Path, group: str, scope: str, commit: str, device: str, coverage_lines=None) -> None:
    value = result_metadata(group, scope, commit, device, coverage_lines)
    with path.open('a') as metrics: metrics.write(METADATA_PREFIX + json.dumps(value) + '\n')


def validated_scope(group: str, record: dict, commit: str, run: str, policy: dict, matches) -> dict:
    from validation_evidence import selected_test_summary_complete, test_inventory, coverage_complete
    from validation_coverage import COVERAGE_GROUPS, regressions, policy_floors
    if not isinstance(record, dict) or record.get('identity') != dict(group=group, commit=commit, run=run):
        raise ValueError('模拟器完整验收需要绑定来源运行、提交与库存。')
    summary, environment = record.get('summary'), record.get('environment')
    name = 'ui' if group == 'ui' else 'app'
    if not isinstance(environment, dict) or not matches(name, environment):
        raise ValueError('模拟器验收环境需要对应当前工具链、SDK、宿主与系统运行时。')
    if not isinstance(summary, dict) or not selected_test_summary_complete(summary,
            sorted(test_inventory(group)), group=group, simulator=True):
        raise ValueError('模拟器完整验收需要执行全部测试及参数实例。')
    if group in COVERAGE_GROUPS and (not coverage_complete(group, summary)
            or regressions(summary['coverage'], policy_floors(group, policy))):
        raise ValueError('模拟器完整验收需要满足版本化覆盖率。')
    return environment


def result_rows(report: dict, plan: dict, commit: str, run: str, matches) -> dict:
    from validation_inputs import CI_VALIDATION_GROUPS
    rows = {}
    for name in ('app', 'ui'):
        if not plan['jobs'][name]['execute']: continue
        scopes = CI_VALIDATION_GROUPS[name][0]
        environments = [validated_scope(scope, report.get('simulatorResults', {}).get(scope), commit, run,
            report.get('coveragePolicy', {}), matches) for scope in scopes]
        if any(environment != environments[0] for environment in environments):
            raise ValueError('同组模拟器验收需要同一执行环境。')
        rows[name] = dict(passed=True, scopes=list(scopes), environment=environments[0])
    return rows


def merge_ci_results(ci) -> None:
    from validation_evidence import selected_test_summary_complete, test_inventory
    from validation_coverage import SIMULATOR_SHARDS, shard_inventory, combined_line_coverage
    from validation_environment import ci_commit_findings
    from validation_provenance import report_lock, write_report
    root = ci.ROOT / '.build/extended-automation'
    bundle = root / 'test-results.xcresult'
    retained, incoming = bundle.with_suffix('.retained.xcresult'), bundle.with_suffix('.incoming.xcresult')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ci.ROOT, text=True).strip()
    if errors := ci_commit_findings(commit): raise ValueError('\n'.join(errors))
    policy = json.loads(ci.REPORT.read_text()).get('coveragePolicy', {})
    run = os.environ['GITHUB_RUN_ID']
    plan = ci.read_validation_plan()['jobs']
    subprocess.run(['gh', 'run', 'download', run, '--name', 'validation-static-audit',
        '--dir', str(ci.ROOT / '.build')], check=True, capture_output=True, text=True)
    indexer = ci.ROOT / '.build/compiler-cache/swift-syntax-indexer'
    indexer.chmod(indexer.stat().st_mode | 0o100)
    records, metrics = {}, []
    for group in ('all', 'release-runtime', 'ui'):
        name = 'ui' if group == 'ui' else 'app'
        source = plan[name]
        source_run, source_commit = (run, commit) if source['execute'] else (source['run'], source['commit'])
        count = SIMULATOR_SHARDS.get(group, 1)
        line_shards, environments = [], []
        shutil.rmtree(bundle, ignore_errors=True)
        for index in range(count):
            if bundle.exists(): shutil.move(str(bundle), str(retained))
            operation = 'app' if group == 'all' else group
            ci.download_simulator_shard(source_run, operation, index)
            lines = (root / 'test-metrics.txt').read_text().splitlines()
            values = [json.loads(row.removeprefix(METADATA_PREFIX)) for row in lines if row.startswith(METADATA_PREFIX)]
            if len(values) != 1: raise ValueError('每份模拟器结果需要唯一的生产环境记录。')
            metadata = values[0]
            scope = 'full' if group == 'release-runtime' else 'shard'
            if metadata.get('identity') != dict(group=group, index=index, count=count, commit=source_commit, run=source_run) \
                    or metadata.get('scope') != scope:
                raise ValueError('模拟器结果需要绑定计划中的来源运行、提交及所属库存。')
            environment = metadata.get('environment')
            if not isinstance(environment, dict) or not ci.result_environment_matches(name, environment):
                raise ValueError('模拟器生产环境需要对应当前任务的工具链和运行时。')
            environments.append(environment)
            expected = sorted(test_inventory(group)) if group == 'release-runtime' else shard_inventory(group, index, count)
            summary = ci.read_native_summary(bundle, group)
            if not selected_test_summary_complete(summary, expected, group=group, simulator=True):
                raise ValueError('每个模拟器结果需要完整执行分配的测试及实例。')
            if group != 'release-runtime': line_shards.append(metadata['coverageLines'])
            if retained.exists():
                subprocess.run(['xcrun', 'xcresulttool', 'merge', '--output-path', str(incoming), str(retained), str(bundle)],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                shutil.rmtree(retained)
                shutil.rmtree(bundle)
                shutil.move(str(incoming), str(bundle))
        summary = ci.read_native_summary(bundle, group)
        if line_shards: summary['coverage'] = combined_line_coverage(line_shards)
        record = dict(identity=dict(group=group, commit=source_commit, run=source_run), summary=summary,
            environment=environments[0])
        if any(environment != environments[0] for environment in environments):
            raise ValueError('模拟器分片需要同一执行环境。')
        validated_scope(group, record, source_commit, source_run, policy, ci.result_environment_matches)
        records[group] = record
        metrics.append(f"{group} 完整验收通过：{summary['passedTests']} 项；来源：{source_commit} / {source_run}；覆盖率："
            + json.dumps(summary.get('coverage', {})))
        print(f"{group} 完整验收通过：{summary['passedTests']} 项。")
    if records['all']['environment'] != records['release-runtime']['environment']:
        raise ValueError('App 行为与正式组装需要同一模拟器环境。')
    with report_lock(path=ci.REPORT):
        report = json.loads(ci.REPORT.read_text())
        report['simulatorResults'] = records
        write_report(report, path=ci.REPORT)
    (root / 'test-metrics.txt').write_text('\n'.join(metrics) + '\n')
