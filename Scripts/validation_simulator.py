"""Record simulator producers and validate complete CI inventories independently of device evidence."""
import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

METADATA_PREFIX = '模拟器记录：'


def clean_device_caches(identifiers: list[str]) -> None:
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
    devices = {device['udid']: device for rows in inventory['devices'].values() for device in rows}
    if not identifiers or set(identifiers) - devices.keys():
        raise ValueError('缓存清理需要指定实际存在的设备。')
    root = Path.home() / 'Library/Developer/CoreSimulator/Devices'
    removed = 0
    for identifier in dict.fromkeys(identifiers):
        if devices[identifier]['state'] != 'Shutdown':
            subprocess.run(['xcrun', 'simctl', 'shutdown', identifier], check=True, capture_output=True)
        data = root / identifier / 'data'
        folders = [data / 'Library/Caches', data / 'tmp']
        for container in (data / 'Containers/Data/Application').glob('*'):
            folders.extend([container / 'Library/Caches', container / 'tmp'])
        for folder in folders:
            if not folder.is_dir(): continue
            removed += int(subprocess.check_output(['du', '-sk', str(folder)], text=True).split()[0]) * 1024
            for child in folder.iterdir():
                if child.is_symlink() or child.is_file(): child.unlink()
                else: shutil.rmtree(child)
    print(f'模拟器缓存与临时文件已回收：{removed / 1024 ** 3:.2f} GiB；App、登录与设置数据保留。')


def remove_devices(identifiers: list[str]) -> None:
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True))
    devices = {device['udid']: device for rows in inventory['devices'].values() for device in rows}
    selected = list(dict.fromkeys(identifiers))
    if not selected or set(selected) - devices.keys():
        raise ValueError('设备移除需要列出实际存在的目标设备。')
    if any(devices[identifier]['state'] != 'Shutdown' for identifier in selected):
        raise ValueError('请先关闭所选设备，再执行移除。')
    for identifier in selected:
        subprocess.run(['xcrun', 'simctl', 'delete', identifier], check=True, capture_output=True)
    print(f'已移除指定模拟器：{len(selected)} 台。')


def remove_runtime_images(identifiers: set[str]) -> None:
    images = json.loads(subprocess.check_output(['xcrun', 'simctl', 'runtime', 'list', '--json'], text=True))
    removed = 0
    for identifier, image in images.items():
        if image['runtimeIdentifier'] in identifiers:
            subprocess.run(['xcrun', 'simctl', 'runtime', 'delete', identifier], check=True)
            removed += image['sizeBytes']
    print(f'运行时已回收，系统登记大小 {removed / 1024 ** 3:.2f} GiB。')


def manage_runtimes(action: str, version: str, platform_name: str = 'iOS', identifiers: list[str] | None = None) -> None:
    if platform_name not in {'iOS', 'watchOS', 'tvOS', 'visionOS'}:
        raise ValueError('运行时维护需要指定 iOS、watchOS、tvOS 或 visionOS。')
    def inventory():
        return json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True))

    def version_tuple(value):
        return tuple(map(int, value.split('.')))

    def platform(runtime):
        return runtime['name'].split()[0]

    data = inventory()
    target_version = version_tuple(version)
    selected = [row for row in data['runtimes'] if platform(row) == platform_name]
    targets = [row for row in selected if row['isAvailable'] and row['version'] == version]
    if not targets:
        raise ValueError(f'{platform_name} {version} 运行时需要先安装并可用。')
    older = [row for row in selected if version_tuple(row['version']) < target_version]
    if action == 'upgrade':
        devices = {device['udid']: runtime for runtime, rows in data['devices'].items() for device in rows}
        allowed = {row['identifier'] for row in [*older, *targets]}
        if not identifiers or any(devices.get(identifier) not in allowed for identifier in identifiers):
            raise ValueError('运行时升级需要列出所选平台的目标设备。')
        plan = []
        for runtime in older:
            for device in data['devices'].get(runtime['identifier'], []):
                if device['udid'] not in identifiers: continue
                matches = [row for row in targets if platform(row) == platform(runtime)
                    and any(kind['identifier'] == device['deviceTypeIdentifier'] for kind in row['supportedDeviceTypes'])]
                if not matches:
                    raise ValueError(f"{device['name']} 的目标运行时需要支持 {device['deviceTypeIdentifier']}。")
                plan.append((device, max(matches, key=lambda row: row['buildversion'])))
        for device, target in plan:
            if device['state'] == 'Booted':
                subprocess.run(['xcrun', 'simctl', 'shutdown', device['udid']], check=True, capture_output=True)
            subprocess.run(['xcrun', 'simctl', 'upgrade', device['udid'], target['identifier']], check=True)
            print(f"已升级 {device['name']} → {target['name']}，保留设备数据。", flush=True)
        refreshed = inventory()
        actual = {row['udid']: runtime for runtime, rows in refreshed['devices'].items() for row in rows}
        if any(actual.get(device['udid']) != target['identifier'] for device, target in plan):
            raise ValueError('设备升级需要保留原标识并进入目标运行时。')
        record = Path(__file__).resolve().parent.parent / '.build/extended-automation/simulator-device.json'
        if record.is_file():
            owned = json.loads(record.read_text())
            if runtime := actual.get(owned['identifier']):
                owned['runtime'] = runtime
                record.write_text(json.dumps(owned) + '\n')
        print(f'运行时迁移完成：{len(plan)} 台设备。')
        if all(not refreshed['devices'].get(row['identifier']) for row in older):
            manage_runtimes('prune', version, platform_name)
    elif action == 'prune':
        if any(data['devices'].get(row['identifier']) for row in older):
            raise ValueError('旧运行时的全部设备需要先完成迁移。')
        remove_runtime_images({row['identifier'] for row in older})
    else:
        raise ValueError('运行时维护动作需要为 upgrade 或 prune。')


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
    for name in ('app',):
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
    shutil.rmtree(retained, ignore_errors=True)
    shutil.rmtree(incoming, ignore_errors=True)
    records, metrics = {}, []
    for group in ('all', 'release-runtime'):
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
                try:
                    subprocess.run(['xcrun', 'xcresulttool', 'merge', '--output-path', str(incoming), str(retained), str(bundle)],
                        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                except BaseException:
                    shutil.rmtree(incoming, ignore_errors=True)
                    raise
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
