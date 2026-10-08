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


def current(results: str) -> None:
    states = results.split(',')
    if len(states) != len(REQUIRED_JOBS) or any(state != 'success' for state in states):
        raise ValueError('合并验收需要静态审计、编译、Catalyst 与真机 Job 全部成功。')
    download_run(int(os.environ['GITHUB_RUN_ID']), repository())


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
    with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo', GITHUB_RUN_ID='9'), \
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
        (['release', 'v1.0'], 'release', (('v1.0',), {'publish': False})),
        (['publish', 'v1.0'], 'release', (('v1.0',), {'publish': True})),
    ):
        with patch.object(sys, 'argv', ['ci_evidence.py', *arguments]), patch.object(module, operation) as execute:
            assert main() == 0
            assert (execute.call_args.args, execute.call_args.kwargs) == expected
            execute.side_effect = ValueError('验收证据需要有效输入')
            with patch.object(sys, 'stderr', StringIO()): assert main() == 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('baseline', 'current', 'release', 'publish'))
    parser.add_argument('identity', nargs='?', default='')
    parser.add_argument('--results', default='')
    args = parser.parse_args()
    try:
        if args.action == 'baseline': baseline(args.identity)
        elif args.action == 'current': current(args.results)
        else: release(args.identity, publish=args.action == 'publish')
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
