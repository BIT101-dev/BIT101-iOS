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
REQUIRED_JOBS = {'validation-plan', 'static-audit', 'release-build', 'catalyst-tests', 'ios-tests'}
CACHE_FLAVORS = {'release-build', 'catalyst-tests', 'simulator-app', 'simulator-ui'}
CACHE_ROOT = ROOT / '.build/compiler-cache'
CACHE_STORE = 'CompilationCache.noindex'
CACHE_METADATA = 'compilation-cache.json'
CACHE_TOOLS = frozenset({'swift-syntax-indexer', 'swift-syntax-indexer-inputs.json'})


def cache_identity() -> dict:
    from validation_environment import environment_context, toolchain_identity
    context = environment_context('build-release')
    return dict(toolchain=toolchain_identity(context), architecture=context['host']['architecture'])


def export_cache(flavor: str) -> None:
    if flavor not in CACHE_FLAVORS: raise ValueError('编译缓存需要登记的构建分组。')
    if not (CACHE_ROOT / CACHE_STORE).is_dir(): raise ValueError('编译完成后需要生成原生缓存。')
    (CACHE_ROOT / CACHE_METADATA).write_text(json.dumps(dict(identity=cache_identity(), flavor=flavor)))
    files = [*(CACHE_ROOT / CACHE_STORE).rglob('*'), *(CACHE_ROOT / name for name in CACHE_TOOLS | {CACHE_METADATA})]
    size = sum(path.stat().st_size for path in files if path.is_file())
    print(f'编译缓存原始文件：{size / 1024**3:.2f} GiB。')


def restore_cache_payload(payload, flavor: str) -> bool:
    import zipfile
    from pathlib import PurePosixPath
    with zipfile.ZipFile(payload) as archive:
        metadata = json.loads(archive.read(CACHE_METADATA))
        if metadata != dict(identity=cache_identity(), flavor=flavor): return False
        members = [row for row in archive.infolist() if row.filename != CACHE_METADATA]
        if not any(not row.is_dir() for row in members): raise ValueError('原生缓存需要包含编译数据。')
        tools = CACHE_TOOLS.intersection(row.filename for row in members)
        if tools and tools != CACHE_TOOLS: raise ValueError('检查工具与输入指纹需要成对恢复。')
        for row in members:
            path = PurePosixPath(row.filename)
            if path.is_absolute() or '..' in path.parts \
                    or not (path.parts[:1] == (CACHE_STORE,) and (row.is_dir() or len(path.parts) >= 2)
                            or row.filename in CACHE_TOOLS and not row.is_dir()) \
                    or (row.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('缓存产物需要保持固定目录及普通文件。')
        destination = CACHE_ROOT / CACHE_STORE
        try:
            for row in members:
                target = CACHE_ROOT / row.filename
                if row.is_dir(): target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(row) as source, target.open('wb') as output: shutil.copyfileobj(source, output)
                    if row.filename == 'swift-syntax-indexer': target.chmod(0o755)
        except BaseException:
            shutil.rmtree(destination, ignore_errors=True)
            for name in CACHE_TOOLS: (CACHE_ROOT / name).unlink(missing_ok=True)
            raise
    return True


def trusted_cache_run(run: dict, repo: str) -> bool:
    return run.get('event') in {'push', 'workflow_dispatch'} and run.get('head_branch') == 'main' \
        and (run.get('head_repository') or {}).get('full_name') == repo and run.get('path') == '.github/workflows/ci.yml'


def select_validation_plan(commit: str, run_id: str, candidates, changed_files, *, full: bool = False) -> dict:
    from validation_inputs import CI_VALIDATION_GROUPS, ci_validation_affected
    jobs = {group: {'execute': True, 'reason': '完整验收' if full else '建立当前输入的成功结果'}
        for group in CI_VALIDATION_GROUPS}
    pending = set() if full else set(jobs)
    for candidate in (() if full else candidates):
        changed = changed_files(candidate['head_sha'])
        observed = {job['name']: job for job in candidate['jobs']}
        artifacts = {row['name'] for row in candidate['artifacts'] if not row.get('expired')}
        for group in tuple(pending):
            _, names, required = CI_VALIDATION_GROUPS[group]
            sources = [observed.get(name, {}) for name in names]
            if any(job.get('conclusion') not in {'success', 'cancelled', 'skipped', None} for job in sources):
                jobs[group]['reason'] = '上次任务需要复验'
                pending.remove(group)
            elif any(job.get('conclusion') != 'success' for job in sources):
                continue
            elif ci_validation_affected(changed, group):
                jobs[group]['reason'] = '验证输入发生变化'
                pending.remove(group)
            elif set(required) <= artifacts:
                jobs[group] = {'execute': False, 'run': str(candidate['id']), 'commit': candidate['head_sha'],
                    'reason': '输入内容一致，复用成功结果'}
                pending.remove(group)
        if not pending: break
    return {'commit': commit, 'run': run_id, 'jobs': jobs}


def validation_plan() -> None:
    from validation_environment import ci_commit_findings
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if errors := ci_commit_findings(commit): raise ValueError('\n'.join(errors))
    repo, run_id = repository(), os.environ['GITHUB_RUN_ID']
    full = os.getenv('BIT101_FULL_CHECK') == 'true'
    def candidates():
        runs = json.loads(subprocess.check_output(['gh', 'api',
            f'repos/{repo}/actions/workflows/ci.yml/runs?branch=main'], text=True))['workflow_runs']
        for run in runs:
            if str(run['id']) == run_id or run.get('status') != 'completed' or not trusted_cache_run(run, repo): continue
            if subprocess.run(['git', 'merge-base', '--is-ancestor', run['head_sha'], commit],
                    cwd=ROOT, capture_output=True).returncode: continue
            yield run | {'jobs': [job for page in api_pages(f'repos/{repo}/actions/runs/{run["id"]}/jobs') for job in page['jobs']],
                'artifacts': [row for page in api_pages(f'repos/{repo}/actions/runs/{run["id"]}/artifacts') for row in page['artifacts']]}
    def changed_files(source):
        return [name for name in subprocess.check_output(['git', 'diff', '--name-only', '-z', '--no-renames',
            source, commit], cwd=ROOT).decode().split('\0') if name]
    plan = select_validation_plan(commit, run_id, candidates(), changed_files, full=full)
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output: output.write('plan=' + json.dumps(plan) + '\n')
    for group, row in plan['jobs'].items(): print(f'{group}：{row["reason"]}')


def read_validation_plan() -> dict:
    plan = json.loads(os.environ['BIT101_CI_PLAN'])
    from validation_inputs import CI_VALIDATION_GROUPS
    if plan.get('commit') != os.environ['GITHUB_SHA'] or plan.get('run') != os.environ['GITHUB_RUN_ID'] \
            or set(plan.get('jobs', {})) != set(CI_VALIDATION_GROUPS):
        raise ValueError('增量计划需要绑定当前提交、运行及完整验证组。')
    for row in plan['jobs'].values():
        if type(row.get('execute')) is not bool or not row['execute'] and (
                not re.fullmatch('[0-9a-f]{40}', row.get('commit', '')) or not re.fullmatch('[1-9][0-9]*', row.get('run', ''))):
            raise ValueError('复用结果需要有效的来源提交与运行。')
    return plan


def reuse_validation(group: str) -> None:
    row = read_validation_plan()['jobs'][group]
    if row['execute']: raise ValueError('当前验证组需要执行测试。')
    message = f'{group}：复用提交 {row["commit"]} 的成功结果：https://github.com/{repository()}/actions/runs/{row["run"]}'
    print(message)
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as summary: summary.write(message + '\n')


def restore_cache(flavor: str) -> None:
    import fcntl
    if flavor not in CACHE_FLAVORS: raise ValueError('编译缓存需要登记的构建分组。')
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    with (CACHE_ROOT / 'cache.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (CACHE_ROOT / 'compilation-cache-download').unlink(missing_ok=True)
        if (CACHE_ROOT / CACHE_STORE).exists():
            print('编译缓存：复用工作区原生产物。')
            return
        try:
            restore_remote_cache(flavor)
        except (subprocess.CalledProcessError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
            print(f'编译缓存：沿当前源码重新编译（{type(error).__name__}）。')


def restore_remote_cache(flavor: str) -> None:
    repo = repository()
    artifacts = [row for page in api_pages(f'repos/{repo}/actions/artifacts?name=compilation-cache-{flavor}&per_page=100')
        for row in page['artifacts'] if row['name'] == 'compilation-cache-' + flavor and not row['expired']]
    for artifact in sorted(artifacts, key=lambda row: row['id'], reverse=True):
        run = json.loads(subprocess.check_output(['gh', 'api', f"repos/{repo}/actions/runs/{artifact['workflow_run']['id']}"], text=True))
        if not trusted_cache_run(run, repo): continue
        commit = run['head_sha']
        if not re.fullmatch('[0-9a-f]{40}', commit): continue
        if subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'HEAD'], cwd=ROOT, capture_output=True).returncode: continue
        payload = CACHE_ROOT / 'compilation-cache-download'
        try:
            download_cache_payload(repo, artifact['id'], payload)
            if restore_cache_payload(payload, flavor):
                print('编译缓存：已恢复工具链匹配的原生数据。')
                return
        finally:
            payload.unlink(missing_ok=True)
    print('编译缓存：首次建立当前分组的原生数据。')


def prune_caches() -> None:
    repo = repository()
    artifacts = [row for page in api_pages(f'repos/{repo}/actions/artifacts?per_page=100') for row in page['artifacts']]
    retained, runs = set(), {}
    for row in sorted(artifacts, key=lambda value: value['id'], reverse=True):
        shared_host = row['name'] == 'ui-test-host' and str(row['workflow_run']['id']) == os.getenv('GITHUB_RUN_ID')
        if row.get('expired') or not (shared_host or row['name'].startswith('compilation-cache-')): continue
        run_id = row['workflow_run']['id']
        if not shared_host and run_id not in runs:
            runs[run_id] = json.loads(subprocess.check_output(['gh', 'api', f'repos/{repo}/actions/runs/{run_id}'], text=True))
        if shared_host or row['name'] not in {'compilation-cache-' + flavor for flavor in CACHE_FLAVORS} \
                or not trusted_cache_run(runs[run_id], repo) or row['name'] in retained:
            deleted = subprocess.run(['gh', 'api', '-X', 'DELETE', f"repos/{repo}/actions/artifacts/{row['id']}"], capture_output=True, text=True)
            if deleted.returncode and '(HTTP 404)' not in deleted.stderr: deleted.check_returncode()
        else: retained.add(row['name'])


def download_cache_payload(repo: str, artifact_id: int, destination: Path) -> None:
    import io
    import http.client
    from concurrent.futures import ThreadPoolExecutor
    endpoint = f'repos/{repo}/actions/artifacts/{artifact_id}/zip'
    probe = io.BytesIO(subprocess.check_output(['gh', 'api', '--allow-escape-sequences', '--include', '-H', 'Range: bytes=0-0', endpoint]))
    status = probe.readline().split()
    headers = http.client.parse_headers(probe)
    size = re.fullmatch(r'bytes 0-0/([1-9][0-9]*)', headers.get('Content-Range', ''))
    if len(status) < 2 or status[1] != b'206' or size is None or len(probe.read()) != 1:
        raise ValueError('编译缓存响应需要包含完整的 HTTP 分段范围。')
    length = int(size[1])
    count = min(os.cpu_count() or 1, length)
    with destination.open('wb') as output: output.truncate(length)
    def read_part(index):
        start, end = length * index // count, length * (index + 1) // count - 1
        with destination.open('r+b') as output:
            output.seek(start)
            subprocess.run(['gh', 'api', '--allow-escape-sequences', '-H', f'Range: bytes={start}-{end}', endpoint],
                stdout=output, stderr=subprocess.PIPE, check=True)
            if output.tell() != end + 1: raise ValueError('编译缓存分段需要包含请求的全部字节。')
    with ThreadPoolExecutor() as pool:
        list(pool.map(read_part, range(count)))


def cache_download_self_test() -> None:
    from unittest.mock import patch
    data = b'0123456789ab\x1b[31m'
    probe = b'HTTP/2.0 206 Partial Content\r\nContent-Range: bytes 0-0/17\r\n\r\n0'
    observed = []
    destination = ROOT / '.build/static-audit/cache-download-self-test'
    destination.parent.mkdir(parents=True, exist_ok=True)
    def response(command, **kwargs):
        assert '--allow-escape-sequences' in command
        assert command[-1] == 'repos/owner/repo/actions/artifacts/7/zip'
        assert '--include' in command
        return probe
    def transfer(command, **kwargs):
        assert kwargs['check'] and kwargs['stdout'].fileno() >= 0
        assert '--allow-escape-sequences' in command
        assert command[-1] == 'repos/owner/repo/actions/artifacts/7/zip'
        match = re.fullmatch(r'Range: bytes=(\d+)-(\d+)', command[command.index('-H') + 1])
        start, end = map(int, match.groups())
        observed.append((start, end))
        kwargs['stdout'].write(data[start:end + 1])
    try:
        for cores in (1, 3, 32):
            observed.clear()
            with patch.object(os, 'cpu_count', return_value=cores), patch.object(subprocess, 'check_output', side_effect=response), \
                    patch.object(subprocess, 'run', side_effect=transfer):
                download_cache_payload('owner/repo', 7, destination)
                assert destination.read_bytes() == data
            assert [offset for start, end in sorted(observed) for offset in range(start, end + 1)] == list(range(len(data)))
        for invalid in (probe.replace(b'206', b'200'), probe.replace(b'0-0/17', b'0-1/17'), probe[:-1]):
            with patch.object(subprocess, 'check_output', return_value=invalid):
                try: download_cache_payload('owner/repo', 7, destination)
                except ValueError: pass
                else: raise AssertionError('分段协议需要有效状态、范围与完整数据。')
        def truncated(command, **kwargs):
            match = re.fullmatch(r'Range: bytes=(\d+)-(\d+)', command[command.index('-H') + 1])
            start, end = map(int, match.groups())
            kwargs['stdout'].write(data[start:end])
        with patch.object(os, 'cpu_count', return_value=3), patch.object(subprocess, 'check_output', side_effect=response), \
                patch.object(subprocess, 'run', side_effect=truncated):
            try: download_cache_payload('owner/repo', 7, destination)
            except ValueError: pass
            else: raise AssertionError('缺少字节的分段需要结束恢复。')
    finally:
        destination.unlink(missing_ok=True)


def cache_self_test() -> None:
    import io
    import zipfile
    from contextlib import redirect_stdout
    from unittest.mock import patch
    module = sys.modules[__name__]
    cache_download_self_test()
    for failure in (subprocess.CalledProcessError(1, ['gh', 'api']), OSError('cache unavailable'),
            ValueError('invalid metadata'), KeyError('cache metadata'), zipfile.BadZipFile('truncated cache')):
        with patch.object(Path, 'mkdir'), patch.object(Path, 'open'), patch.object(Path, 'exists', return_value=False), \
                patch('fcntl.flock'), patch.object(module, 'restore_remote_cache', side_effect=failure) as restore, \
                redirect_stdout(io.StringIO()) as output:
            restore_cache('simulator-ui')
            restore.assert_called_once_with('simulator-ui')
            assert '沿当前源码重新编译' in output.getvalue()
    with patch.object(Path, 'mkdir'), patch.object(Path, 'open'), patch.object(Path, 'exists', return_value=True), \
            patch('fcntl.flock'), patch.object(module, 'restore_remote_cache') as restore, redirect_stdout(io.StringIO()):
        restore_cache('simulator-ui')
        restore.assert_not_called()
    identity = {'toolchain': 'compiler'}
    def payload(name=CACHE_STORE + '/data', *, context=identity, link=False, tools=False):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr(CACHE_METADATA, json.dumps(dict(identity=context, flavor='simulator-ui')))
            entry = zipfile.ZipInfo(name)
            if link: entry.external_attr = 0o120777 << 16
            archive.writestr(entry, b'compiled')
            if tools:
                for tool in sorted(CACHE_TOOLS): archive.writestr(tool, tool.encode())
        buffer.seek(0)
        return buffer
    transferred = []
    with patch.object(module, 'cache_identity', return_value=identity), patch.object(Path, 'mkdir'), \
            patch.object(Path, 'open'), patch.object(Path, 'chmod') as permissions, \
            patch.object(shutil, 'copyfileobj', side_effect=lambda source, target: transferred.append(source.read())) as copied:
        assert restore_cache_payload(payload(), 'simulator-ui')
        assert transferred == [b'compiled']
        assert restore_cache_payload(payload(tools=True), 'simulator-ui')
        assert transferred[1:] == [b'compiled', *(name.encode() for name in sorted(CACHE_TOOLS))]
        permissions.assert_called_once_with(0o755)
        copied.reset_mock()
        assert not restore_cache_payload(payload(context={}), 'simulator-ui')
        assert not restore_cache_payload(payload(), 'simulator-app')
        copied.assert_not_called()
    with patch.object(module, 'cache_identity', return_value=identity), patch.object(Path, 'is_dir', return_value=True), \
            patch.object(Path, 'write_text') as saved, redirect_stdout(io.StringIO()):
        export_cache('simulator-ui')
        assert json.loads(saved.call_args.args[0]) == dict(identity=identity, flavor='simulator-ui')
        for name, link in [('../escape', False), ('/escape', False), (CACHE_STORE + '/../escape', False),
                           (CACHE_STORE, False), (CACHE_STORE + '/link', True),
                           ('swift-syntax-indexer', False), ('swift-syntax-indexer/escape', False)]:
            try: restore_cache_payload(payload(name, link=link), 'simulator-ui')
            except ValueError: pass
            else: raise AssertionError(name)
        copied.assert_not_called()
    trusted = dict(event='push', head_branch='main', head_repository={'full_name': 'owner/repo'},
        path='.github/workflows/ci.yml', head_sha='a' * 40)
    artifact = dict(id=1, name='compilation-cache-simulator-ui', expired=False, workflow_run={'id': 1})
    for change, ancestor, accepted in [({}, 0, True), ({'event': 'workflow_dispatch'}, 0, True), ({'event': 'pull_request'}, 0, False),
            ({'head_branch': 'feature'}, 0, False), ({'head_repository': None}, 0, False), ({'head_repository': {'full_name': 'fork/repo'}}, 0, False),
            ({'path': 'other.yml'}, 0, False), ({'head_sha': 'invalid'}, 0, False), ({}, 1, False)]:
        def response(command, **kwargs):
            return payload() if command[-1].endswith('/zip') else json.dumps(dict(trusted, **change))
        with patch.object(module, 'repository', return_value='owner/repo'), \
                patch.object(module, 'api_pages', return_value=[{'artifacts': [artifact]}]), \
                patch.object(Path, 'mkdir'), patch.object(Path, 'open'), patch.object(Path, 'exists', return_value=False), \
                patch('fcntl.flock'), patch.object(subprocess, 'check_output', side_effect=response), \
                patch.object(module, 'download_cache_payload', return_value=payload()) as downloaded, \
                patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=ancestor)), \
                patch.object(module, 'restore_cache_payload', return_value=True) as restored, redirect_stdout(io.StringIO()):
            restore_cache('simulator-ui')
            assert restored.called == downloaded.called == accepted, (change, ancestor)
    with patch.object(module, 'repository', return_value='owner/repo'), \
            patch.object(module, 'api_pages', return_value=[{'artifacts': [artifact, dict(artifact, id=2)]}]), \
            patch.object(subprocess, 'check_output', return_value=json.dumps(trusted)), \
            patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0)), \
            patch.object(module, 'download_cache_payload') as downloaded, patch.object(Path, 'unlink') as cleanup, \
            patch.object(module, 'restore_cache_payload', side_effect=[False, True]) as restored, redirect_stdout(io.StringIO()):
        restore_remote_cache('simulator-ui')
        assert [call.args[1] for call in downloaded.call_args_list] == [2, 1]
        assert restored.call_count == cleanup.call_count == 2
    artifacts = [dict(id=index, name=name, expired=False, workflow_run={'id': 1}) for index, name in [
        (1, 'compilation-cache-simulator-ui'), (2, 'validation-evidence'), (3, 'compilation-cache-simulator-ui'),
        (4, 'compilation-cache-simulator-app')]]
    artifacts.append(dict(id=5, name='compilation-cache-simulator-ui', expired=False, workflow_run={'id': 2}))
    artifacts.append(dict(id=6, name='compilation-cache-unused', expired=False, workflow_run={'id': 1}))
    artifacts.extend(dict(id=index, name='ui-test-host', expired=False, workflow_run={'id': run}) for index, run in ((7, 1), (8, 2)))
    def producer(command, **kwargs):
        return json.dumps(dict(trusted, head_repository={'full_name': 'fork/repo'}) if command[-1].endswith('/2') else trusted)
    with patch.dict(os.environ, GITHUB_RUN_ID='1'), patch.object(module, 'repository', return_value='owner/repo'), \
            patch.object(module, 'api_pages', return_value=[{'artifacts': artifacts}]), \
            patch.object(subprocess, 'check_output', side_effect=producer), \
            patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as deleted:
        prune_caches()
        assert [call.args[0][-1] for call in deleted.call_args_list] == [f'repos/owner/repo/actions/artifacts/{index}' for index in (7, 6, 5, 1)]
    for code, error in ((1, 'gh: Not Found (HTTP 404)'), (1, 'gh: Forbidden (HTTP 403)'), (1, 'connection failed')):
        def deleted_artifact(command, **kwargs):
            return subprocess.CompletedProcess(command, code, '', error)
        with patch.object(module, 'repository', return_value='owner/repo'), \
                patch.object(module, 'api_pages', return_value=[{'artifacts': artifacts}]), \
                patch.object(subprocess, 'check_output', side_effect=producer), \
                patch.object(subprocess, 'run', side_effect=deleted_artifact):
            try: prune_caches()
            except subprocess.CalledProcessError as failure: assert failure.stderr == error and '(HTTP 404)' not in error
            else: assert '(HTTP 404)' in error


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
    receipt = json.loads(RECEIPT.read_text())
    tag = receipt.get('tag', '') if isinstance(receipt, dict) else ''
    version_tag(tag)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    from validation_provenance import committed_source_digest
    errors = receipt_findings(receipt, tag, commit, committed_source_digest)
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
    jobs = json.loads(results)
    native = os.environ['BIT101_NATIVE_CHECK'] == 'true'
    expected = {name: 'success' if native or name == 'static-audit' else 'skipped' for name in REQUIRED_JOBS}
    if not isinstance(jobs, dict) or {name: job.get('result') if isinstance(job, dict) else None
            for name, job in jobs.items()} != expected:
        raise ValueError('CI 验收需要静态审计通过，并按所选范围核对完整验收任务状态。')
    print('完整编译、行为与 UI 验收通过。' if native else '静态审计验收通过。')


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
            from validation_provenance import committed_source_digest
            receipt = release_receipt(json.loads(REPORT.read_text()), tag, committed_source_digest)
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
    shutil.rmtree(root / 'test-results.xcresult', ignore_errors=True)
    for name in ('simulator.log', 'all.log', 'release-runtime.log', 'ui.log',
            'build-release.log', 'restore.log', 'test-metrics.txt'):
        (root / name).unlink(missing_ok=True)
    (ROOT / '.build/screenshot.png').unlink(missing_ok=True)
    subprocess.run(['gh', 'run', 'download', run, '--name', f'validation-ios-test-shards-{operation}-{index}',
        '--dir', str(ROOT)], check=True, capture_output=True, text=True)


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
    plan = read_validation_plan()['jobs'] if os.getenv('BIT101_CI_PLAN') else {}
    subprocess.run(['gh', 'run', 'download', run, '--name', 'validation-static-audit',
        '--dir', str(ROOT / '.build')], check=True, capture_output=True, text=True)
    indexer = ROOT / '.build/compiler-cache/swift-syntax-indexer'
    indexer.chmod(indexer.stat().st_mode | 0o100)
    report = []
    for group in ('all', 'ui'):
        source = plan.get('app' if group == 'all' else group, {'execute': True})
        source_run = run if source['execute'] else source['run']
        source_commit = commit if source['execute'] else source['commit']
        line_shards = []
        shutil.rmtree(bundle, ignore_errors=True)
        for index in range(SIMULATOR_SHARDS[group]):
            if bundle.exists(): shutil.move(str(bundle), str(retained))
            operation = 'app' if group == 'all' else group
            download_simulator_shard(source_run, operation, index)
            metrics = (root / 'test-metrics.txt').read_text()
            metadata = json.loads(next(row.removeprefix('分片：') for row in metrics.splitlines() if row.startswith('分片：')))
            expected = shard_inventory(group, index, SIMULATOR_SHARDS[group])
            if metadata['identity'] != {'group': group, 'index': index, 'count': SIMULATOR_SHARDS[group],
                    'commit': source_commit, 'run': source_run}:
                raise ValueError('分片需要绑定计划中的来源运行、提交及所属库存。')
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
        report.append(f"{group} 完整分片验收通过：{summary['passedTests']} 项；来源：{source_commit} / {source_run}；覆盖率：" + json.dumps(summary['coverage']))
        print(f"{group} 完整分片验收通过：{summary['passedTests']} 项。")
    (root / 'test-metrics.txt').write_text('\n'.join(report) + '\n')

def self_test() -> None:
    from unittest.mock import patch
    with patch.dict(os.environ, GITHUB_ACTIONS='false', GITHUB_SHA=''):
        _self_test()
        cache_self_test()
        validation_plan_self_test()


def validation_plan_self_test() -> None:
    from copy import deepcopy
    from unittest.mock import patch
    from validation_inputs import CI_VALIDATION_GROUPS
    commit = 'a' * 40
    candidate = {'id': 7, 'head_sha': 'b' * 40,
        'jobs': [{'name': name, 'conclusion': 'success'} for _, names, _ in CI_VALIDATION_GROUPS.values() for name in names],
        'artifacts': [{'name': name, 'expired': False} for _, _, names in CI_VALIDATION_GROUPS.values() for name in names]}
    for names, required in (([], set()), (['README.md'], set()),
            (['BIT101-iOSUITests/InteractionCoverageCommunityUITests.swift'], {'ui'}),
            (['BIT101-iOSTests/AccountTests.swift'], {'release', 'app', 'catalyst'}),
            (['BIT101-iOSTests/PerformanceWorkloads.json'], {'release', 'app', 'catalyst', 'ui'}),
            (['BIT101-iOS/Feature.swift'], {'release', 'app', 'catalyst', 'ui'}),
            (['Modules/Feature/Sources/Feature.swift'], set(CI_VALIDATION_GROUPS)),
            (['.github/workflows/ci.yml'], set(CI_VALIDATION_GROUPS)),
            (['Scripts/simulator-tests.sh'], set(CI_VALIDATION_GROUPS))):
        plan = select_validation_plan(commit, '8', [candidate], lambda _: names)
        assert {group for group, row in plan['jobs'].items() if row['execute']} == required, names
        assert all(row['run'] == '7' and row['commit'] == 'b' * 40 for row in plan['jobs'].values() if not row['execute'])
    for conclusion in ('failure', 'timed_out', 'action_required', 'cancelled', 'skipped', None):
        failed = deepcopy(candidate)
        next(job for job in failed['jobs'] if job['name'] == 'iOS Simulator ui (1)')['conclusion'] = conclusion
        older = candidate | {'id': 6}
        plan = select_validation_plan(commit, '8', [failed, older], lambda _: [])
        assert not plan['jobs']['app']['execute']
        if conclusion in ('failure', 'timed_out', 'action_required'):
            assert plan['jobs']['ui']['execute']
        else:
            assert not plan['jobs']['ui']['execute'] and plan['jobs']['ui']['run'] == '6'
            failed['head_sha'] = 'c' * 40
            plan = select_validation_plan(commit, '8', [failed, older],
                lambda source: ['BIT101-iOS/Feature.swift'] if source == failed['head_sha'] else [])
            assert plan['jobs']['ui']['run'] == '6'
            plan = select_validation_plan(commit, '8', [failed, older], lambda _: ['BIT101-iOS/Feature.swift'])
            assert plan['jobs']['ui']['execute']
            plan = select_validation_plan(commit, '8', [failed], lambda _: [])
            assert plan['jobs']['ui']['execute']
    absent = deepcopy(candidate)
    absent['jobs'] = [job for job in absent['jobs'] if job['name'] != 'iOS Simulator ui (1)']
    assert select_validation_plan(commit, '8', [absent, older], lambda _: [])['jobs']['ui']['run'] == '6'
    missing = deepcopy(candidate)
    next(row for row in missing['artifacts'] if row['name'] == 'validation-ios-test-shards-app-0')['expired'] = True
    plan = select_validation_plan(commit, '8', [missing], lambda _: [])
    assert plan['jobs']['app']['execute'] and not plan['jobs']['ui']['execute']
    plan = select_validation_plan(commit, '8', [missing, candidate | {'id': 6}], lambda _: [])
    assert plan['jobs']['app']['run'] == '6'
    def unused():
        raise AssertionError('发布全量验收沿当前运行执行。')
        yield
    assert all(row['execute'] for row in select_validation_plan(commit, '8', unused(), lambda _: [], full=True)['jobs'].values())
    from contextlib import redirect_stdout
    from io import StringIO
    module = sys.modules[__name__]
    for environment, full in (({}, False), ({'BIT101_FULL_CHECK': 'true'}, True),
            ({'BIT101_FULL_CHECK': 'false'}, False), ({'BIT101_RELEASE_CHECK': 'true'}, False),
            ({'GITHUB_REF': 'refs/tags/v1.0'}, False)):
        context = dict(BIT101_FULL_CHECK='false', BIT101_RELEASE_CHECK='false', GITHUB_REF='refs/heads/main',
            GITHUB_RUN_ID='8', GITHUB_OUTPUT='plan') | environment
        with patch.dict(os.environ, context), patch('validation_environment.ci_commit_findings', return_value=[]), \
                patch.object(module, 'repository', return_value='owner/repo'), patch.object(Path, 'open') as output, \
                patch.object(subprocess, 'check_output', side_effect=[commit, '{"workflow_runs": []}']) as requests, \
                redirect_stdout(StringIO()):
            validation_plan()
            written = json.loads(output.return_value.__enter__.return_value.write.call_args.args[0].removeprefix('plan='))
            assert written['commit'] == commit and written['run'] == '8'
            assert all(row['execute'] and (row['reason'] == '完整验收') == full for row in written['jobs'].values())
            assert requests.call_count == (1 if full else 2), environment
    def affected():
        yield candidate
        raise AssertionError('受影响的验证组沿当前运行执行。')
    assert all(row['execute'] for row in select_validation_plan(commit, '8', affected(),
        lambda _: ['.github/workflows/ci.yml'])['jobs'].values())
    valid = select_validation_plan(commit, '8', [candidate], lambda _: [])
    with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_RUN_ID='8', BIT101_CI_PLAN=json.dumps(valid)):
        assert read_validation_plan() == valid
    for key, value in (('commit', 'c' * 40), ('run', '9'), ('jobs', {})):
        with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_RUN_ID='8', BIT101_CI_PLAN=json.dumps(valid | {key: value})):
            try: read_validation_plan()
            except ValueError: pass
            else: raise AssertionError('来源计划需要匹配当前运行与全部验证组。')
    for key, value in (('execute', 'false'), ('commit', 'invalid'), ('run', '0')):
        malformed = deepcopy(valid)
        malformed['jobs']['ui'][key] = value
        with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_RUN_ID='8', BIT101_CI_PLAN=json.dumps(malformed)):
            try: read_validation_plan()
            except ValueError: pass
            else: raise AssertionError('复用来源需要有效的执行状态与身份。')


def _self_test() -> None:
    from io import StringIO
    from unittest.mock import patch
    module = sys.modules[__name__]
    root = Path('/fixture')
    metrics = root / '.build/extended-automation/test-metrics.txt'
    preserved = {root / '.build/compiler-cache/swift-syntax-indexer',
        root / '.build/extended-automation/modules.log',
        root / '.build/extended-automation/test-results.retained.xcresult'}
    files = preserved | {metrics, root / '.build/extended-automation/simulator.log'}
    def download(command, **kwargs):
        assert command[:4] == ['gh', 'run', 'download', '7']
        assert command[6:] == ['--dir', str(root)]
        assert metrics not in files
        assert root / '.build/extended-automation/simulator.log' not in files
        assert preserved <= files
        files.update({metrics, root / '.build/extended-automation/simulator.log'})
    with patch.object(module, 'ROOT', root), \
            patch.object(Path, 'unlink', lambda path, **kwargs: files.discard(path)), \
            patch.object(shutil, 'rmtree') as clear, \
            patch.object(subprocess, 'run', side_effect=download) as command:
        for operation, index in (('app', 0), ('ui', 0), ('ui', 1)):
            download_simulator_shard('7', operation, index)
            assert command.call_args.args[0][5] == f'validation-ios-test-shards-{operation}-{index}'
            clear.assert_called_with(root / '.build/extended-automation/test-results.xcresult', ignore_errors=True)
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
    full_results = {name: {'result': 'success'} for name in REQUIRED_JOBS}
    static_results = {name: {'result': 'success' if name == 'static-audit' else 'skipped'} for name in REQUIRED_JOBS}
    for native, results in (('false', static_results), ('true', full_results)):
        with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_ACTIONS='false', BIT101_NATIVE_CHECK=native), \
                patch.object(subprocess, 'check_output', return_value=commit), patch.object(module, 'api_pages') as api, \
                patch.object(sys, 'stdout', StringIO()):
            current(json.dumps(results))
            api.assert_not_called()
            rejected = [[], {}, results | {'extra': {'result': 'success'}},
                {name: job for name, job in results.items() if name != 'static-audit'}]
            for name in REQUIRED_JOBS:
                rejected.extend(results | {name: {'result': state}} for state in
                    ('success', 'skipped', 'failure', 'cancelled', None) if state != results[name]['result'])
            for states in rejected:
                try: current(json.dumps(states))
                except ValueError: pass
                else: raise AssertionError('静态与完整验收需要分别核对每项任务的执行状态')
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
        try: current(json.dumps(full_results))
        except ValueError: pass
        else: raise AssertionError('CI 需要验收事件提交')
    for changed in (b'', b' M Scripts/ci_evidence.py\0'):
        with patch.dict(os.environ, GITHUB_SHA=commit, GITHUB_ACTIONS='true', BIT101_NATIVE_CHECK='true'), \
                patch.object(subprocess, 'check_output', side_effect=[commit, changed]), patch.object(sys, 'stdout', StringIO()):
            try: current(json.dumps(full_results))
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
        (['current', '--results', json.dumps(full_results)], 'current', ((json.dumps(full_results),), {})),
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
        (['plan'], 'validation_plan', ((), {})),
        (['reuse', 'ui'], 'reuse_validation', (('ui',), {})),
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
    parser.add_argument('action', choices=('baseline', 'current', 'review-pr', 'release', 'publish', 'check-release', 'export-core', 'import-baseline', 'simulator-merge', 'cache-restore', 'cache-export', 'cache-prune', 'plan', 'reuse'))
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
        elif args.action == 'plan': validation_plan()
        elif args.action == 'reuse': reuse_validation(args.identity)
        else: release(args.identity, publish=args.action == 'publish')
        return 0
    except (ValueError, SyntaxError, KeyError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else None
        if isinstance(detail, bytes): detail = detail.decode(errors='replace')
        print(detail.strip() if detail else str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
