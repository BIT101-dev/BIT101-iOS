#!/usr/bin/env python3
"""Exchange fixed validation evidence through commit-scoped GitHub Actions and release assets."""
import argparse
import json
import os
import re
import subprocess
import sys
from types import SimpleNamespace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / '.build/extended-automation/validation-evidence.json'
ARTIFACT = 'validation-evidence'
REQUIRED_JOBS = {'static-audit', 'release-build', 'catalyst-tests', 'physical-device'}
REVIEW_JOB_NAMES = {'Static audit (Apple toolchain)', 'Release app and extension builds',
    'Mac Catalyst behavior tests', 'Physical-device behavior and UI acceptance'}


def repository() -> str:
    value = os.getenv('GITHUB_REPOSITORY') or subprocess.check_output(
        ['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', value): raise ValueError('证据交换需要有效 GitHub 仓库身份。')
    return value


def api_pages(endpoint: str) -> list[dict]:
    return json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp', endpoint], cwd=ROOT, text=True))


def download_run(run: int, repo: str) -> None:
    if type(run) is not int or run <= 0: raise ValueError('证据需要所属工作流运行。')
    from validation_evidence import report_lock
    with report_lock():
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.unlink(missing_ok=True)
        subprocess.run(['gh', 'run', 'download', str(run), '--repo', repo, '--name', ARTIFACT, '--dir', str(REPORT.parent)],
            cwd=ROOT, capture_output=True, text=True, check=True)


def baseline(commit: str) -> None:
    if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', commit): raise ValueError('覆盖率基准需要目标提交 SHA。')
    repo = repository()
    pages = api_pages(f'repos/{repo}/actions/workflows/ci.yml/runs?head_sha={commit}&status=completed')
    runs = [run for page in pages for run in page['workflow_runs'] if run['head_sha'] == commit
        and run['status'] == 'completed' and run['conclusion'] == 'success' and run['event'] in {'push', 'workflow_dispatch'}]
    if not runs: raise ValueError('目标提交需要完成 iOS CI 真机验收；请在目标分支执行工作流。')
    run = max(runs, key=lambda row: row['id'])['id']
    artifacts = [artifact for page in api_pages(f'repos/{repo}/actions/runs/{run}/artifacts') for artifact in page['artifacts']]
    if not any(row['name'] == ARTIFACT and row['expired'] is False for row in artifacts):
        raise ValueError('目标提交的真机证据需要有效工作流产物；请重新执行目标分支工作流。')
    download_run(run, repo)


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


def current(results: str) -> None:
    states = results.split(',')
    if len(states) == len(REQUIRED_JOBS) and all(state == 'success' for state in states):
        download_run(int(os.environ['GITHUB_RUN_ID']), repository())
        return
    if len(states) == len(REQUIRED_JOBS) and states.count('success') == 3 and states.count('skipped') == 1 and os.getenv('GITHUB_EVENT_NAME') == 'pull_request':
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        pull = event['pull_request']
        if pull['head']['repo']['full_name'] != repository():
            fork_review(os.environ['GITHUB_SHA'], pull['number'])
            return
    raise ValueError('合并验收需要当前编译 Job 成功及所属提交的完整真机证据。')


def version_tag(tag: str) -> None:
    if not re.fullmatch(r'v\d+(?:\.\d+){1,2}', tag): raise ValueError('发布证据需要公开版本标签。')
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
            subprocess.run(['gh', 'release', 'upload', tag, str(REPORT), '--repo', repository(), '--clobber'],
                cwd=ROOT, capture_output=True, text=True, check=True)
        return
    with validation_evidence.report_lock():
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        command = ['gh', 'release', 'download', tag, '--repo', repository(), '--pattern', REPORT.name,
            '--dir', str(REPORT.parent), '--clobber']
        subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=True)


def self_test() -> None:
    from io import StringIO
    from unittest.mock import patch
    module = sys.modules[__name__]
    commit = 'a' * 40
    run = {'id': 7, 'head_sha': commit, 'status': 'completed', 'conclusion': 'success', 'event': 'push'}
    artifacts = [{'artifacts': [{'name': ARTIFACT, 'expired': False}]}]
    with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo', GITHUB_RUN_ID='9', GITHUB_EVENT_NAME='push'), \
            patch.object(module, 'api_pages', side_effect=[[{'workflow_runs': [dict(run, id=6), dict(run, id=100, head_sha='b' * 40)]},
                {'workflow_runs': [run]}], artifacts]) as requests, patch.object(module, 'download_run') as download:
        baseline(commit)
        download.assert_called_once_with(7, 'owner/repo')
        assert 'head_sha=' + commit in requests.call_args_list[0].args[0]
        download.reset_mock()
        current('success,success,success,success')
        download.assert_called_once_with(9, 'owner/repo')
        for states in ('success,success,success', 'success,success,skipped,success', 'failure,success,success,success'):
            try: current(states)
            except ValueError: pass
            else: raise AssertionError('全部前置 Job 共同参与合并门禁')
    for runs, items in (([], artifacts), ([run], [{'artifacts': [{'name': ARTIFACT, 'expired': True}]}])):
        with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo'), \
                patch.object(module, 'api_pages', side_effect=[[{'workflow_runs': runs}], items]), patch.object(module, 'download_run') as download:
            try: baseline(commit)
            except ValueError: pass
            else: raise AssertionError('目标提交需要有效成功产物')
            download.assert_not_called()
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
        event = {'pull_request': {'number': 12, 'head': {'repo': {'full_name': 'fork/repo'}}}}
        with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo', GITHUB_EVENT_NAME='pull_request',
                GITHUB_SHA=commit, GITHUB_EVENT_PATH='/ci-event'), patch.object(Path, 'read_text', return_value=json.dumps(event)), \
                patch.object(module, 'api_pages', side_effect=[[pull], [{'workflow_runs': [reviewed]}], [{'jobs': jobs}], items]), \
                patch.object(module, 'download_run') as download:
            try: current('success,success,skipped,success')
            except ValueError: assert fault != 'none'
            else:
                assert fault == 'none'
                download.assert_called_once_with(7, 'owner/repo')
            if fault != 'none': download.assert_not_called()
    with patch.object(module, 'version_tag'), patch.object(module, 'repository', return_value='owner/repo'), \
            patch.object(Path, 'mkdir'), patch.object(subprocess, 'run') as command, \
            patch('validation_evidence.inspect_report', return_value=0), patch('validation_evidence.report_lock'):
        release('v1.0', publish=True)
        assert command.call_args.args[0][:4] == ['gh', 'release', 'upload', 'v1.0']
        release('v1.0')
        assert command.call_args.args[0][:4] == ['gh', 'release', 'download', 'v1.0']
    for target, accepted in (('commit', True), ('other', False)):
        with patch.object(subprocess, 'check_output', side_effect=[target, 'commit']):
            try: version_tag('v1.0')
            except ValueError: assert not accepted
            else: assert accepted
    with patch.object(module, 'version_tag'), patch.object(subprocess, 'run') as upload, \
            patch('validation_evidence.inspect_report', return_value=1), patch('validation_evidence.report_lock'):
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
    parser.add_argument('action', choices=('baseline', 'current', 'review-pr', 'release', 'publish'))
    parser.add_argument('identity', nargs='?', default='')
    parser.add_argument('--results', default='')
    args = parser.parse_args()
    try:
        if args.action == 'baseline': baseline(args.identity)
        elif args.action == 'current': current(args.results)
        elif args.action == 'review-pr': print(review_pr(int(args.identity)))
        else: release(args.identity, publish=args.action == 'publish')
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
