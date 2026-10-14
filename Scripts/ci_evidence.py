#!/usr/bin/env python3
"""Exchange fixed validation evidence through commit-scoped GitHub Actions and release assets."""
import argparse
import ast
import json
import os
import re
import subprocess
import sys
from types import SimpleNamespace
from pathlib import Path
from validation_publication import RECEIPT, CORE_REPORT, release_receipt, receipt_findings, core_exchange
from validate_versions import PROJECT_PATH, extract_versions, validate_release_tag
from validation_policy import REVIEW_JOB_NAMES

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / '.build/extended-automation/validation-evidence.json'
ARTIFACT = 'validation-evidence'
REQUIRED_JOBS = {'static-audit', 'release-build', 'catalyst-tests', 'physical-device'}


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


def download_run(run: int, repo: str) -> None:
    from validation_provenance import report_lock
    with report_lock():
        from validation_provenance import write_report
        incoming = download_core(run, repo)
        from validation_environment import ci_commit_findings
        if errors := ci_commit_findings(incoming.get('mergeCommit', '')):
            raise ValueError('\n'.join(errors))
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        groups = report.get('groups', {}) | incoming.pop('groups')
        write_report(report | incoming | {'groups': groups})


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


def fork_review(commit: str, number: int) -> None:
    review_pr(number, commit)
    repo = repository()
    pages = api_pages(f'repos/{repo}/actions/workflows/ci.yml/runs?head_sha={commit}&event=workflow_dispatch&status=completed')
    runs = [run for page in pages for run in page['workflow_runs'] if run['head_sha'] == commit
        and run['status'] == 'completed' and run['conclusion'] == 'success' and run['event'] == 'workflow_dispatch'
        and run.get('display_title') == f'iOS CI review PR {number}' and run.get('head_repository', {}).get('full_name') == repo]
    for run in sorted(runs, key=lambda row: row['id'], reverse=True):
        jobs = [job for page in api_pages(f'repos/{repo}/actions/runs/{run["id"]}/jobs') for job in page['jobs']]
        succeeded = {job['name'] for job in jobs if job['status'] == 'completed' and job['conclusion'] == 'success'}
        if not REVIEW_JOB_NAMES <= succeeded: continue
        artifacts = [item for page in api_pages(f'repos/{repo}/actions/runs/{run["id"]}/artifacts') for item in page['artifacts']]
        if not any(item['name'] == ARTIFACT and item['expired'] is False for item in artifacts): continue
        download_run(run['id'], repo)
        return
    raise ValueError('fork PR 需要维护者审查当前合并提交并完成 review_pr 手动工作流，再重新运行合并验收 Job。')


def physical_inputs_changed(base: str) -> bool:
    from validation_inputs import includes_input
    from validation_merge import CORE_GROUPS
    if not base: return True
    if not re.fullmatch(r'[0-9a-f]{40}', base): raise ValueError('变更范围需要目标分支的完整提交 SHA。')
    names = subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', '-z', base, 'HEAD', '--'], cwd=ROOT)
    return any(name.startswith('.github/workflows/') or name == 'Scripts/ci_evidence.py'
        or any(includes_input(name, group) for group in CORE_GROUPS) for name in names.decode().split('\0') if name)


def current(results: str) -> None:
    from validation_environment import ci_commit_findings
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if errors := ci_commit_findings(commit): raise ValueError('\n'.join(errors))
    states = results.split(',')
    if len(states) == len(REQUIRED_JOBS) and all(state == 'success' for state in states):
        download_run(int(os.environ['GITHUB_RUN_ID']), repository())
        return
    if len(states) == len(REQUIRED_JOBS) and states.count('success') == 3 and states.count('skipped') == 1 and os.getenv('GITHUB_EVENT_NAME') == 'pull_request':
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        pull = event['pull_request']
        if not physical_inputs_changed(pull['base']['sha']): return
        if pull['head']['repo']['full_name'] != repository():
            fork_review(os.environ['GITHUB_SHA'], pull['number'])
            return
    raise ValueError('合并验收需要当前编译 Job 成功及所属提交的完整真机证据。')


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


def self_test() -> None:
    from unittest.mock import patch
    with patch.dict(os.environ, GITHUB_ACTIONS='false', GITHUB_SHA=''):
        _self_test()


def _self_test() -> None:
    from io import StringIO
    from unittest.mock import patch
    module = sys.modules[__name__]
    commit = 'a' * 40
    run = {'id': 7, 'head_sha': commit, 'status': 'completed', 'conclusion': 'success', 'event': 'push'}
    from contextlib import nullcontext
    retained = {'releaseCommit': commit, 'coveragePolicy': {'all': {'Feature': 70}},
        'groups': {name: {'inputDigest': 'retained-' + name} for name in ('network', 'icloud', 'manual-device', 'build-archive', 'audit', 'catalyst', 'all')}}
    incoming = {'mergeCommit': commit, 'sourceDigest': 'current', 'groups': {'all': {'inputDigest': 'current-all'}}}
    with patch('validation_provenance.report_lock', side_effect=nullcontext), patch('validation_provenance.write_report') as save, \
            patch.object(Path, 'read_text', autospec=True, side_effect=lambda path: json.dumps(incoming if path == CORE_REPORT else retained)), \
            patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'unlink'), \
            patch.object(subprocess, 'run') as download:
        download_run(7, 'owner/repo')
        result = save.call_args.args[0]
        assert result['mergeCommit'] == commit and result['sourceDigest'] == 'current'
        assert result['coveragePolicy'] == retained['coveragePolicy'] and result['releaseCommit'] == commit
        assert result['groups'] == retained['groups'] | incoming['groups']
        download.assert_called_once()
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
    with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo', GITHUB_RUN_ID='9', GITHUB_EVENT_NAME='push', GITHUB_SHA=commit), \
            patch.object(subprocess, 'check_output', return_value=commit), patch.object(module, 'download_run') as download:
        current('success,success,success,success')
        download.assert_called_once_with(9, 'owner/repo')
        for states in ('success,success,success', 'success,success,skipped,success', 'failure,success,success,success'):
            try: current(states)
            except ValueError: pass
            else: raise AssertionError('全部前置 Job 共同参与合并门禁')
    for source in ('MODULE_COVERAGE_FLOORS = {}', policy_source.replace('60', '101'), policy_source.replace('60', 'True'),
                   policy_source.replace('80', '101'), policy_source.replace('80', 'True'),
                   policy_source.replace('{"Feature": 80}', 'execute()')):
        with patch.object(subprocess, 'check_output', return_value=source), patch('validation_provenance.write_report') as save:
            try: baseline(commit)
            except ValueError: pass
            else: raise AssertionError('目标提交需要有效的版本化阈值')
            save.assert_not_called()
    for fault in ('none', 'commit', 'number', 'repository', 'event', 'job', 'expired', 'stale-pr'):
        reviewed = dict(run, event='workflow_dispatch', display_title='iOS CI review PR 12', head_repository={'full_name': 'owner/repo'})
        pull = {'state': 'open', 'merge_commit_sha': commit, 'base': {'sha': 'b' * 40}}
        jobs = [{'name': name, 'status': 'completed', 'conclusion': 'success'} for name in REVIEW_JOB_NAMES]
        items = [{'artifacts': [{'name': ARTIFACT, 'expired': fault == 'expired'}]}]
        if fault == 'commit': reviewed['head_sha'] = 'c' * 40
        if fault == 'number': reviewed['display_title'] = 'iOS CI review PR 13'
        if fault == 'repository': reviewed['head_repository'] = {'full_name': 'fork/repo'}
        if fault == 'event': reviewed['event'] = 'push'
        if fault == 'job': jobs[0]['conclusion'] = 'skipped'
        if fault == 'stale-pr': pull['merge_commit_sha'] = 'c' * 40
        event = {'pull_request': {'number': 12, 'base': {'sha': 'b' * 40}, 'head': {'repo': {'full_name': 'fork/repo'}}}}
        with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo', GITHUB_EVENT_NAME='pull_request',
                GITHUB_SHA=commit, GITHUB_EVENT_PATH='/ci-event'), patch.object(Path, 'read_text', return_value=json.dumps(event)), \
                patch.object(subprocess, 'check_output', return_value=commit), \
                patch.object(module, 'physical_inputs_changed', return_value=True), \
                patch.object(module, 'api_pages', side_effect=[[pull], [{'workflow_runs': [reviewed]}], [{'jobs': jobs}], items]), \
                patch.object(module, 'download_run') as download:
            try: current('success,success,skipped,success')
            except ValueError: assert fault != 'none'
            else:
                assert fault == 'none'
                download.assert_called_once_with(7, 'owner/repo')
            if fault != 'none': download.assert_not_called()
    with patch.dict(os.environ, GITHUB_SHA=commit), \
            patch.object(subprocess, 'check_output', return_value='b' * 40), patch.object(module, 'download_run') as download:
        try: current('success,success,success,success')
        except ValueError: pass
        else: raise AssertionError('CI 需要验收事件合并提交')
        download.assert_not_called()
    with patch.dict(os.environ, GITHUB_SHA='b' * 40), \
            patch('validation_provenance.report_lock', side_effect=nullcontext), patch('validation_provenance.write_report') as save, \
            patch.object(Path, 'read_text', return_value=json.dumps(incoming)), patch.object(Path, 'unlink'), \
            patch.object(subprocess, 'run'):
        try: download_run(7, 'owner/repo')
        except ValueError: pass
        else: raise AssertionError('下载证据需要绑定事件合并提交')
        save.assert_not_called()
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
    for names, expected in [('README.md\0docs/TESTING.md\0', False),
            ('Cloudflare/ErrorReportWorker/worker.js\0', False), ('BIT101-iOS/ContentView.swift\0', True),
            ('Modules/ScheduleDomain/Sources/Course.swift\0', True), ('BIT101-iOSTests/BehaviorTests.swift\0', True),
            ('Scripts/validation_policy.py\0', True), ('.github/workflows/ci.yml\0', True),
            ('docs/UI_INTERACTION_COVERAGE.md\0', True), ('', False)]:
        with patch.object(subprocess, 'check_output', return_value=names.encode()):
            assert physical_inputs_changed(commit) == expected, names
    assert physical_inputs_changed('')
    with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo', GITHUB_EVENT_NAME='pull_request', GITHUB_SHA=commit,
            GITHUB_EVENT_PATH='/ci-event'), patch.object(subprocess, 'check_output', return_value=commit), \
            patch.object(Path, 'read_text', return_value=json.dumps(event)), \
            patch.object(module, 'physical_inputs_changed', return_value=False), patch.object(module, 'download_run') as download:
        current('success,success,success,skipped')
        download.assert_not_called()
        for states in ('success,failure,success,skipped', 'success,success,skipped,skipped'):
            try: current(states)
            except ValueError: pass
            else: raise AssertionError('外围变更需要全部编译与静态 Job 成功')
    for arguments, operation, expected in (
        (['baseline', commit], 'baseline', ((commit,), {})),
        (['current', '--results', 'success,success,success,success'], 'current', (('success,success,success,success',), {})),
        (['review-pr', '12'], 'review_pr', ((12,), {})),
        (['release', 'v1.0'], 'release', (('v1.0',), {'publish': False})),
        (['publish', 'v1.0'], 'release', (('v1.0',), {'publish': True})),
        (['check-release'], 'check_release', ((), {})),
        (['export-core'], 'export_core', ((), {})),
        (['import-baseline', '7'], 'import_baseline', ((7,), {})),
        (['physical-scope', commit], 'physical_inputs_changed', ((commit,), {})),
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
    parser.add_argument('action', choices=('baseline', 'current', 'review-pr', 'release', 'publish', 'check-release', 'export-core', 'import-baseline', 'physical-scope'))
    parser.add_argument('identity', nargs='?', default='')
    parser.add_argument('--results', default='')
    args = parser.parse_args()
    try:
        if args.action == 'baseline': baseline(args.identity)
        elif args.action == 'current': current(args.results)
        elif args.action == 'review-pr': print(review_pr(int(args.identity)))
        elif args.action == 'check-release': check_release()
        elif args.action == 'export-core': export_core()
        elif args.action == 'import-baseline': import_baseline(int(args.identity))
        elif args.action == 'physical-scope': print('required=' + str(physical_inputs_changed(args.identity)).lower())
        else: release(args.identity, publish=args.action == 'publish')
        return 0
    except (ValueError, SyntaxError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
