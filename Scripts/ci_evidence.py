#!/usr/bin/env python3
"""Exchange fixed validation evidence through commit-scoped GitHub Actions and release assets."""
import argparse
import ast
import json
import os
import re
import subprocess
import sys
import shutil
import zipfile
from types import SimpleNamespace
from pathlib import Path
from validation_publication import RECEIPT, CORE_REPORT, release_receipt, receipt_findings, core_exchange
from validate_versions import PROJECT_PATH, extract_versions, validate_release_tag

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / '.build/extended-automation/validation-evidence.json'
ARTIFACT = 'validation-evidence'
REQUIRED_JOBS = {'static-audit', 'release-build', 'catalyst-tests', 'ios-tests'}
CACHE_FLAVORS = {'release-build', 'catalyst-tests', 'simulator-app', 'simulator-ui', 'simulator-release-runtime'}
CACHE_ROOT = ROOT / '.build/compiler-cache'
CACHE_STORE = 'CompilationCache.noindex'
CACHE_METADATA = 'compilation-cache.json'


def cache_identity() -> dict:
    from validation_environment import environment_context, toolchain_identity
    context = environment_context('build-release')
    return dict(toolchain=toolchain_identity(context), architecture=context['host']['architecture'])


def export_cache(flavor: str) -> None:
    if flavor not in CACHE_FLAVORS: raise ValueError('编译缓存需要登记的构建分组。')
    if not (CACHE_ROOT / CACHE_STORE).is_dir(): raise ValueError('编译完成后需要生成原生缓存。')
    (CACHE_ROOT / CACHE_METADATA).write_text(json.dumps(dict(identity=cache_identity(), flavor=flavor)))


def restore_cache_payload(payload: bytes, flavor: str) -> bool:
    import io
    import zipfile
    from pathlib import PurePosixPath
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        metadata = json.loads(archive.read(CACHE_METADATA))
        if metadata != dict(identity=cache_identity(), flavor=flavor): return False
        members = [row for row in archive.infolist() if row.filename != CACHE_METADATA]
        if not any(not row.is_dir() for row in members): raise ValueError('原生缓存需要包含编译数据。')
        for row in members:
            path = PurePosixPath(row.filename)
            if path.is_absolute() or '..' in path.parts or path.parts[:1] != (CACHE_STORE,) \
                    or not row.is_dir() and len(path.parts) < 2 or (row.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('缓存产物需要保持固定目录及普通文件。')
        destination = CACHE_ROOT / CACHE_STORE
        try:
            for row in members:
                target = CACHE_ROOT / row.filename
                if row.is_dir(): target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(row) as source, target.open('wb') as output: shutil.copyfileobj(source, output)
        except BaseException:
            shutil.rmtree(destination, ignore_errors=True)
            raise
    return True


def restore_cache(flavor: str) -> None:
    import fcntl
    if flavor not in CACHE_FLAVORS: raise ValueError('编译缓存需要登记的构建分组。')
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    with (CACHE_ROOT / 'cache.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (CACHE_ROOT / CACHE_STORE).exists():
            print('编译缓存：复用工作区原生产物。')
            return
        repo = repository()
        artifacts = [row for page in api_pages(f'repos/{repo}/actions/artifacts?name=compilation-cache-{flavor}&per_page=100')
            for row in page['artifacts'] if row['name'] == 'compilation-cache-' + flavor and not row['expired']]
        for artifact in sorted(artifacts, key=lambda row: row['id'], reverse=True):
            run = json.loads(subprocess.check_output(['gh', 'api', f"repos/{repo}/actions/runs/{artifact['workflow_run']['id']}"], text=True))
            if run['event'] not in {'push', 'workflow_dispatch'} or run['head_branch'] != 'main' \
                    or run['head_repository']['full_name'] != repo or run['path'] != '.github/workflows/ci.yml': continue
            commit = run['head_sha']
            if not re.fullmatch('[0-9a-f]{40}', commit): continue
            if subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'HEAD'], cwd=ROOT, capture_output=True).returncode: continue
            payload = subprocess.check_output(['gh', 'api', f"repos/{repo}/actions/artifacts/{artifact['id']}/zip"])
            print('编译缓存：' + ('已恢复工具链匹配的原生数据。' if restore_cache_payload(payload, flavor) else '当前工具链重新建立缓存。'))
            return
        print('编译缓存：首次建立当前分组的原生数据。')


def prune_caches() -> None:
    repo = repository()
    artifacts = [row for page in api_pages(f'repos/{repo}/actions/artifacts?per_page=100') for row in page['artifacts']]
    retained = set()
    for row in sorted(artifacts, key=lambda value: value['id'], reverse=True):
        if row.get('expired') or row['name'] not in {'compilation-cache-' + flavor for flavor in CACHE_FLAVORS}: continue
        if row['name'] in retained:
            subprocess.run(['gh', 'api', '-X', 'DELETE', f"repos/{repo}/actions/artifacts/{row['id']}"], check=True)
        else: retained.add(row['name'])


def cache_self_test() -> None:
    import io
    import zipfile
    from contextlib import redirect_stdout
    from unittest.mock import patch
    module = sys.modules[__name__]
    identity = {'toolchain': 'compiler'}
    def payload(name=CACHE_STORE + '/data', *, context=identity, link=False):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr(CACHE_METADATA, json.dumps(dict(identity=context, flavor='simulator-ui')))
            entry = zipfile.ZipInfo(name)
            if link: entry.external_attr = 0o120777 << 16
            archive.writestr(entry, b'compiled')
        return buffer.getvalue()
    transferred = []
    with patch.object(module, 'cache_identity', return_value=identity), patch.object(Path, 'mkdir'), \
            patch.object(Path, 'open'), patch.object(shutil, 'copyfileobj', side_effect=lambda source, target: transferred.append(source.read())) as copied:
        assert restore_cache_payload(payload(), 'simulator-ui')
        assert transferred == [b'compiled']
        copied.reset_mock()
        assert not restore_cache_payload(payload(context={}), 'simulator-ui')
        assert not restore_cache_payload(payload(), 'simulator-app')
        copied.assert_not_called()
    with patch.object(module, 'cache_identity', return_value=identity), patch.object(Path, 'is_dir', return_value=True), \
            patch.object(Path, 'write_text') as saved:
        export_cache('simulator-ui')
        assert json.loads(saved.call_args.args[0]) == dict(identity=identity, flavor='simulator-ui')
        for name, link in [('../escape', False), ('/escape', False), (CACHE_STORE + '/../escape', False),
                           (CACHE_STORE, False), (CACHE_STORE + '/link', True)]:
            try: restore_cache_payload(payload(name, link=link), 'simulator-ui')
            except ValueError: pass
            else: raise AssertionError(name)
        copied.assert_not_called()
    trusted = dict(event='push', head_branch='main', head_repository={'full_name': 'owner/repo'},
        path='.github/workflows/ci.yml', head_sha='a' * 40)
    artifact = dict(id=1, name='compilation-cache-simulator-ui', expired=False, workflow_run={'id': 1})
    for change, ancestor, accepted in [({}, 0, True), ({'event': 'workflow_dispatch'}, 0, True), ({'event': 'pull_request'}, 0, False),
            ({'head_branch': 'feature'}, 0, False), ({'head_repository': {'full_name': 'fork/repo'}}, 0, False),
            ({'path': 'other.yml'}, 0, False), ({'head_sha': 'invalid'}, 0, False), ({}, 1, False)]:
        def response(command, **kwargs):
            return payload() if command[-1].endswith('/zip') else json.dumps(dict(trusted, **change))
        with patch.object(module, 'repository', return_value='owner/repo'), \
                patch.object(module, 'api_pages', return_value=[{'artifacts': [artifact]}]), \
                patch.object(Path, 'mkdir'), patch.object(Path, 'open'), patch.object(Path, 'exists', return_value=False), \
                patch('fcntl.flock'), patch.object(subprocess, 'check_output', side_effect=response), \
                patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=ancestor)), \
                patch.object(module, 'restore_cache_payload', return_value=True) as restored, redirect_stdout(io.StringIO()):
            restore_cache('simulator-ui')
            assert restored.called == accepted, (change, ancestor)
    artifacts = [dict(id=index, name=name, expired=False) for index, name in [
        (1, 'compilation-cache-simulator-ui'), (2, 'validation-evidence'), (3, 'compilation-cache-simulator-ui'),
        (4, 'compilation-cache-simulator-app')]]
    with patch.object(module, 'repository', return_value='owner/repo'), \
            patch.object(module, 'api_pages', return_value=[{'artifacts': artifacts}]), patch.object(subprocess, 'run') as deleted:
        prune_caches()
        assert [call.args[0][-1] for call in deleted.call_args_list] == ['repos/owner/repo/actions/artifacts/1']


def repository() -> str:
    value = os.getenv('GITHUB_REPOSITORY') or subprocess.check_output(
        ['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', value): raise ValueError('证据交换需要有效 GitHub 仓库身份。')
    return value


def api_pages(endpoint: str) -> list[dict]:
    return json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp', endpoint], cwd=ROOT, text=True))


def download_core(run: int, repo: str) -> dict:
    if type(run) is not int or run <= 0: raise ValueError('证据需要所属工作流运行。')
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    CORE_REPORT.unlink(missing_ok=True)
    subprocess.run(['gh', 'run', 'download', str(run), '--repo', repo, '--name', ARTIFACT, '--dir', str(REPORT.parent)],
        cwd=ROOT, capture_output=True, text=True, check=True)
    return core_exchange(json.loads(CORE_REPORT.read_text()))


def import_baseline(run: int) -> None:
    if type(run) is not int or run <= 0: raise ValueError('基线迁移需要所属 CI 运行编号。')
    repo = repository()
    metadata = api_pages(f'repos/{repo}/actions/runs/{run}')[0]
    if metadata.get('path') != '.github/workflows/ci.yml' or metadata.get('status') != 'completed' \
            or metadata.get('conclusion') != 'success' or metadata.get('head_repository', {}).get('full_name') != repo:
        raise ValueError('基线迁移需要本仓库成功完成的 CI 工作流。')
    from validation_provenance import report_lock, write_report
    from validation_performance import approved_baseline_complete, MEASUREMENTS
    from validation_inputs import performance_workloads
    with report_lock():
        proof = download_core(run, repo).get('performanceBaseline', {})
        if not approved_baseline_complete(proof): raise ValueError(f'基线迁移需要 {len(performance_workloads())} 个场景的完整原始采样与批准记录。')
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        stored = json.loads(MEASUREMENTS.read_text()) if MEASUREMENTS.is_file() else {'schemaVersion': 1}
        stored['baseline'] = proof
        write_report(stored, path=MEASUREMENTS)
        report['performanceBaseline'] = proof
        report.pop('mergeCommit', None)
        write_report(report)


def export_core() -> None:
    from validation_provenance import report_lock
    with report_lock():
        CORE_REPORT.write_text(json.dumps(core_exchange(json.loads(REPORT.read_text())), ensure_ascii=False, indent=2) + '\n')


def check_release() -> None:
    import validation_evidence
    receipt = json.loads(RECEIPT.read_text())
    tag = receipt.get('tag', '') if isinstance(receipt, dict) else ''
    version_tag(tag)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    errors = receipt_findings(receipt, tag, commit, validation_evidence.source_digest)
    if errors: raise ValueError('\n'.join(errors))
    print('公开发布回执通过：维护者确认、源码、工具链及采样时间。')


def baseline(commit: str) -> None:
    if not commit:
        from validation_provenance import report_lock, write_report
        with report_lock():
            report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
            report.update(coverageBaseCommit='', coveragePolicy={})
            write_report(report)
        return
    if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', commit): raise ValueError('覆盖率基准需要目标提交 SHA。')
    source = subprocess.check_output(['git', 'show', f'{commit}:Scripts/validation_policy.py'], cwd=ROOT, text=True)
    names = {'MODULE_COVERAGE_FLOORS': 'modules', 'IOS_MODULE_COVERAGE_FLOORS': 'all'}
    policy = {}
    app_floor = 35
    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) \
                and node.targets[0].id == 'APP_COVERAGE_FLOOR':
            app_floor = ast.literal_eval(node.value)
            if type(app_floor) is not int or not 0 <= app_floor <= 100:
                raise ValueError('目标提交需要有效的 App 覆盖率阈值。')
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) \
                and node.targets[0].id in names:
            value = ast.literal_eval(node.value)
            if not isinstance(value, dict) or not value or any(not isinstance(key, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9]*', key)
                    or type(floor) is not int or not 0 <= floor <= 100 for key, floor in value.items()):
                raise ValueError('目标提交需要有效的模块覆盖率阈值。')
            policy[names[node.targets[0].id]] = value
    if set(policy) != set(names.values()): raise ValueError('目标提交需要 macOS 与 iOS 两组覆盖率基准。')
    policy['all']['BIT101-iOS.app'] = app_floor
    from validation_provenance import report_lock, write_report
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        report.update(coverageBaseCommit=commit, coveragePolicy=policy)
        write_report(report)


def review_pr(number: int, commit: str | None = None) -> str:
    if type(number) is not int or number <= 0: raise ValueError('审查验收需要有效 PR 编号。')
    commit = commit or subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    pull = api_pages(f'repos/{repository()}/pulls/{number}')[0]
    if pull.get('state') != 'open' or pull.get('merge_commit_sha') != commit:
        raise ValueError('审查分支需要指向当前 PR 的 GitHub 合并提交；请重新获取 refs/pull/编号/merge。')
    return pull['base']['sha']


def current(results: str) -> None:
    from validation_environment import ci_commit_findings
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if errors := ci_commit_findings(commit): raise ValueError('\n'.join(errors))
    states = results.split(',')
    if len(states) == len(REQUIRED_JOBS) and all(state == 'success' for state in states):
        return
    raise ValueError('常规 CI 需要静态、编译、Catalyst 与完整模拟器任务全部通过。')


def version_tag(tag: str) -> None:
    version, _ = extract_versions(PROJECT_PATH.read_text())
    validate_release_tag(tag, version)
    commit = subprocess.check_output(['git', 'rev-list', '-n', '1', tag], cwd=ROOT, text=True).strip()
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if commit != head: raise ValueError('发布证据标签需要指向当前验收提交。')


def release(tag: str, *, publish: bool = False) -> None:
    version_tag(tag)
    import validation_evidence
    if publish:
        with validation_evidence.report_lock():
            if validation_evidence.inspect_report(SimpleNamespace(action='check', recorded_environment=False)):
                raise ValueError('发布证据需要完整发布验收与提交绑定。')
            receipt = release_receipt(json.loads(REPORT.read_text()), tag, validation_evidence.source_digest)
            RECEIPT.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
            subprocess.run(['gh', 'release', 'upload', tag, str(RECEIPT), '--repo', repository(), '--clobber'],
                cwd=ROOT, capture_output=True, text=True, check=True)
        return
    with validation_evidence.report_lock():
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        RECEIPT.unlink(missing_ok=True)
        command = ['gh', 'release', 'download', tag, '--repo', repository(), '--pattern', RECEIPT.name,
            '--dir', str(REPORT.parent), '--clobber']
        subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=True)


def read_native_summary(bundle: Path, group: str) -> dict:
    from validation_evidence import native_case_summary
    def read(kind):
        return json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', kind,
            '--path', str(bundle)], text=True))
    raw, tree = read('summary'), read('tests')
    cases = native_case_summary(tree, group, simulator=True)
    return {'passed': raw.get('result') == 'Passed', 'totalTests': raw.get('totalTestCount'),
        'passedTests': raw.get('passedTests'), 'failedTests': raw.get('failedTests'), 'skippedTests': raw.get('skippedTests'),
        'executedTests': sorted(cases['byTest']), 'testCases': cases}


def download_simulator_shard(run: str, operation: str, index: int) -> None:
    root = ROOT / '.build/extended-automation'
    for name in ('simulator.log', 'all.log', 'release-runtime.log', 'ui.log',
            'build-release.log', 'restore.log', 'test-metrics.txt'):
        (root / name).unlink(missing_ok=True)
    (ROOT / '.build/screenshot.png').unlink(missing_ok=True)
    subprocess.run(['gh', 'run', 'download', run, '--name', f'validation-ios-test-shards-{operation}-{index}',
        '--dir', str(ROOT / '.build')], check=True, capture_output=True, text=True)


def merge_simulator_ci() -> None:
    from validation_evidence import ROOT, REPORT, selected_test_summary_complete, coverage_complete, test_inventory
    from validation_coverage import SIMULATOR_SHARDS, shard_inventory, combined_line_coverage, regressions, policy_floors
    from validation_environment import ci_commit_findings
    root = ROOT / '.build/extended-automation'
    bundle = root / 'test-results.xcresult'
    retained = bundle.with_suffix('.retained.xcresult')
    incoming = bundle.with_suffix('.incoming.xcresult')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if errors := ci_commit_findings(commit): raise ValueError('\n'.join(errors))
    policy = json.loads(REPORT.read_text()).get('coveragePolicy', {})
    run = os.environ['GITHUB_RUN_ID']
    subprocess.run(['gh', 'run', 'download', run, '--name', 'validation-static-audit',
        '--dir', str(ROOT / '.build')], check=True, capture_output=True, text=True)
    indexer = ROOT / '.build/static-audit/swift-syntax-indexer'
    indexer.chmod(indexer.stat().st_mode | 0o100)
    report = []
    for group in ('all', 'ui'):
        line_shards = []
        shutil.rmtree(bundle, ignore_errors=True)
        for index in range(SIMULATOR_SHARDS[group]):
            if bundle.exists(): shutil.move(str(bundle), str(retained))
            operation = 'app' if group == 'all' else group
            download_simulator_shard(run, operation, index)
            metrics = (root / 'test-metrics.txt').read_text()
            metadata = json.loads(next(row.removeprefix('分片：') for row in metrics.splitlines() if row.startswith('分片：')))
            expected = shard_inventory(group, index, SIMULATOR_SHARDS[group])
            if metadata['identity'] != {'group': group, 'index': index, 'count': SIMULATOR_SHARDS[group],
                    'commit': commit, 'run': run}:
                raise ValueError('分片需要绑定当前运行、提交及所属库存。')
            summary = read_native_summary(bundle, group)
            if not selected_test_summary_complete(summary, expected, group=group, simulator=True):
                raise ValueError('每个模拟器分片需要完整执行分配的测试及实例。')
            line_shards.append(metadata['coverageLines'])
            if retained.exists():
                subprocess.run(['xcrun', 'xcresulttool', 'merge', '--output-path', str(incoming), str(retained), str(bundle)],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                shutil.rmtree(retained)
                shutil.rmtree(bundle)
                shutil.move(str(incoming), str(bundle))
        summary = read_native_summary(bundle, group)
        summary['coverage'] = combined_line_coverage(line_shards)
        failures = regressions(summary['coverage'], policy_floors(group, policy))
        if not selected_test_summary_complete(summary, sorted(test_inventory(group)), group=group, simulator=True) \
                or not coverage_complete(group, summary) or failures:
            raise ValueError('模拟器合并验收需要完整库存及版本化覆盖率：' + '；'.join(failures))
        report.append(f"{group} 完整分片验收通过：{summary['passedTests']} 项；覆盖率：" + json.dumps(summary['coverage']))
        print(f"{group} 完整分片验收通过：{summary['passedTests']} 项。")
    (root / 'test-metrics.txt').write_text('\n'.join(report) + '\n')

def self_test() -> None:
    from unittest.mock import patch
    with patch.dict(os.environ, GITHUB_ACTIONS='false', GITHUB_SHA=''):
        _self_test()
        cache_self_test()


def _self_test() -> None:
    from io import StringIO
    from unittest.mock import patch
    module = sys.modules[__name__]
    root = Path('/fixture')
    metrics = root / '.build/extended-automation/test-metrics.txt'
    preserved = {root / '.build/static-audit/swift-syntax-indexer',
        root / '.build/extended-automation/modules.log',
        root / '.build/extended-automation/test-results.retained.xcresult'}
    files = preserved | {metrics, root / '.build/extended-automation/simulator.log'}
    def download(command, **kwargs):
        assert command[:4] == ['gh', 'run', 'download', '7']
        assert metrics not in files
        assert root / '.build/extended-automation/simulator.log' not in files
        assert preserved <= files
        files.update({metrics, root / '.build/extended-automation/simulator.log'})
    with patch.object(module, 'ROOT', root), \
            patch.object(Path, 'unlink', lambda path, **kwargs: files.discard(path)), \
            patch.object(subprocess, 'run', side_effect=download) as command:
        for operation, index in (('app', 0), ('ui', 0), ('ui', 1)):
            download_simulator_shard('7', operation, index)
            assert command.call_args.args[0][5] == f'validation-ios-test-shards-{operation}-{index}'
    commit = 'a' * 40
    from contextlib import nullcontext
    retained = {'releaseCommit': commit, 'coveragePolicy': {'all': {'Feature': 70}},
        'groups': {name: {'inputDigest': 'retained-' + name} for name in ('network', 'icloud', 'manual-device', 'build-archive', 'audit', 'catalyst', 'all')}}
    policy_source = 'APP_COVERAGE_FLOOR = 60\nMODULE_COVERAGE_FLOORS = {"Feature": 80}\nIOS_MODULE_COVERAGE_FLOORS = {"Feature": 70}\n'
    for cached in ({}, retained):
        with patch.object(subprocess, 'check_output') as git, patch('validation_provenance.report_lock', side_effect=nullcontext), \
                patch('validation_provenance.write_report') as save, patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_text', return_value=json.dumps(cached)):
            baseline('')
            assert save.call_args.args[0] == cached | {'coverageBaseCommit': '', 'coveragePolicy': {}}
            git.assert_not_called()
            import validation_evidence
            from contextlib import redirect_stderr
            from io import StringIO
            with patch.object(Path, 'read_text', return_value=json.dumps(save.call_args.args[0])):
                assert validation_evidence.inspect_report(argparse.Namespace(action='baseline', group='')) == 0
            with patch.object(Path, 'read_text', return_value=json.dumps(retained)), redirect_stderr(StringIO()):
                assert validation_evidence.inspect_report(argparse.Namespace(action='baseline', group='')) == 1
    with patch.object(subprocess, 'check_output', return_value=policy_source) as git, \
            patch('validation_provenance.report_lock', side_effect=nullcontext), patch('validation_provenance.write_report') as save, \
            patch.object(Path, 'is_file', return_value=False), patch.object(module, 'api_pages') as api:
        baseline(commit)
        git.assert_called_once_with(['git', 'show', f'{commit}:Scripts/validation_policy.py'], cwd=ROOT, text=True)
        assert save.call_args.args[0] == {'coverageBaseCommit': commit, 'coveragePolicy': {'modules': {'Feature': 80}, 'all': {'Feature': 70, 'BIT101-iOS.app': 60}}}
        api.assert_not_called()
    with patch.dict(os.environ, GITHUB_SHA=commit), \
            patch.object(subprocess, 'check_output', return_value=commit), patch.object(module, 'api_pages') as api:
        current('success,success,success,success')
        api.assert_not_called()
        for states in ('success,success,success', 'success,success,skipped,success', 'failure,success,success,success',
                'success,success,success,success,success'):
            try: current(states)
            except ValueError: pass
            else: raise AssertionError('全部常规 Job 共同参与验收')
    for source in ('MODULE_COVERAGE_FLOORS = {}', policy_source.replace('60', '101'), policy_source.replace('60', 'True'),
                   policy_source.replace('80', '101'), policy_source.replace('80', 'True'),
                   policy_source.replace('{"Feature": 80}', 'execute()')):
        with patch.object(subprocess, 'check_output', return_value=source), patch('validation_provenance.write_report') as save:
            try: baseline(commit)
            except ValueError: pass
            else: raise AssertionError('目标提交需要有效的版本化阈值')
            save.assert_not_called()
    for pull, accepted in (({'state': 'open', 'merge_commit_sha': commit, 'base': {'sha': 'b' * 40}}, True),
            ({'state': 'closed', 'merge_commit_sha': commit}, False),
            ({'state': 'open', 'merge_commit_sha': 'c' * 40}, False)):
        with patch.object(module, 'repository', return_value='owner/repo'), \
                patch.object(module, 'api_pages', return_value=[pull]), patch.object(subprocess, 'check_output', return_value=commit):
            try: result = review_pr(12)
            except ValueError: assert not accepted
            else: assert accepted and result == 'b' * 40
    with patch.dict(os.environ, GITHUB_SHA=commit), patch.object(subprocess, 'check_output', return_value='b' * 40):
        try: current('success,success,success,success')
        except ValueError: pass
        else: raise AssertionError('CI 需要验收事件提交')
    for changed in (b'', b' M Scripts/ci_evidence.py\0'):
        with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_ACTIONS='true'), \
                patch.object(subprocess, 'check_output', side_effect=[commit, changed]):
            try: current('success,success,success,success')
            except ValueError: assert changed
            else: assert not changed
    with patch.object(module, 'version_tag'), patch.object(module, 'repository', return_value='owner/repo'), \
            patch.object(Path, 'mkdir'), patch.object(subprocess, 'run') as command, \
            patch.object(Path, 'read_text', return_value='{}'), patch.object(Path, 'write_text'), patch.object(Path, 'unlink'), \
            patch.object(module, 'release_receipt', return_value={'schemaVersion': 1}), \
            patch('validation_evidence.inspect_report', return_value=0), patch('validation_provenance.report_lock'):
        release('v1.0', publish=True)
        assert command.call_args.args[0][:4] == ['gh', 'release', 'upload', 'v1.0']
        assert command.call_args.args[0][4] == str(RECEIPT)
        release('v1.0')
        assert command.call_args.args[0][:4] == ['gh', 'release', 'download', 'v1.0']
        assert RECEIPT.name in command.call_args.args[0]
    for target, accepted in (('commit', True), ('other', False)):
        with patch.object(module, 'extract_versions', return_value=('1.0.0', 1)), \
                patch.object(Path, 'read_text', return_value='project'), \
                patch.object(subprocess, 'check_output', side_effect=[target, 'commit']):
            try: version_tag('v1.0.0')
            except ValueError: assert not accepted
            else: assert accepted
    for tag in ('v1.0', 'v2.0.0', 'refs/tags/v1.0.0'):
        with patch.object(module, 'extract_versions', return_value=('1.0.0', 1)), \
                patch.object(Path, 'read_text', return_value='project'), patch.object(subprocess, 'check_output') as git:
            try: version_tag(tag)
            except ValueError: pass
            else: raise AssertionError('发布回执标签需要对应工程完整版本')
            git.assert_not_called()
    with patch.object(module, 'version_tag'), patch.object(subprocess, 'run') as upload, \
            patch('validation_evidence.inspect_report', return_value=1), patch('validation_provenance.report_lock'):
        try: release('v1.0', publish=True)
        except ValueError: pass
        else: raise AssertionError('完整验收失败需要终止证据上传')
        upload.assert_not_called()
    for arguments, operation, expected in (
        (['baseline', commit], 'baseline', ((commit,), {})),
        (['current', '--results', 'success,success,success,success'], 'current', (('success,success,success,success',), {})),
        (['review-pr', '12'], 'review_pr', ((12,), {})),
        (['release', 'v1.0'], 'release', (('v1.0',), {'publish': False})),
        (['publish', 'v1.0'], 'release', (('v1.0',), {'publish': True})),
        (['check-release'], 'check_release', ((), {})),
        (['export-core'], 'export_core', ((), {})),
        (['simulator-merge'], 'merge_simulator_ci', ((), {})),
        (['import-baseline', '7'], 'import_baseline', ((7,), {})),
        (['cache-restore', 'simulator-ui'], 'restore_cache', (('simulator-ui',), {})),
        (['cache-export', 'simulator-ui'], 'export_cache', (('simulator-ui',), {})),
        (['cache-prune'], 'prune_caches', ((), {})),
    ):
        with patch.object(sys, 'argv', ['ci_evidence.py', *arguments]), patch.object(module, operation, return_value='b' * 40) as execute, \
                patch.object(sys, 'stdout', StringIO()) as output:
            assert main() == 0
            if operation == 'review_pr': assert output.getvalue() == 'b' * 40 + '\n'
            assert (execute.call_args.args, execute.call_args.kwargs) == expected
            execute.side_effect = ValueError('验收证据需要有效输入')
            with patch.object(sys, 'stderr', StringIO()): assert main() == 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('baseline', 'current', 'review-pr', 'release', 'publish', 'check-release', 'export-core', 'import-baseline', 'simulator-merge', 'cache-restore', 'cache-export', 'cache-prune'))
    parser.add_argument('identity', nargs='?', default='')
    parser.add_argument('--results', default='')
    args = parser.parse_args()
    try:
        if args.action == 'baseline': baseline(args.identity)
        elif args.action == 'current': current(args.results)
        elif args.action == 'review-pr': print(review_pr(int(args.identity)))
        elif args.action == 'check-release': check_release()
        elif args.action == 'export-core': export_core()
        elif args.action == 'simulator-merge': merge_simulator_ci()
        elif args.action == 'import-baseline': import_baseline(int(args.identity))
        elif args.action == 'cache-restore': restore_cache(args.identity)
        elif args.action == 'cache-export': export_cache(args.identity)
        elif args.action == 'cache-prune': prune_caches()
        else: release(args.identity, publish=args.action == 'publish')
        return 0
    except (ValueError, SyntaxError, KeyError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else None
        if isinstance(detail, bytes): detail = detail.decode(errors='replace')
        print(detail.strip() if detail else str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
