#!/usr/bin/env python3
"""Associate workflow results with their producing run and network sampling interval."""
from datetime import datetime, timedelta, timezone
import re
import base64
import json
import os
import math
from pathlib import Path
import subprocess
import uuid
import fcntl
from functools import cache, lru_cache
import threading
from contextlib import contextmanager
from contextvars import ContextVar
from validation_inputs import includes_input, repository_input_names, is_worker_generated
from validation_environment import environment_context, exchange_identity
from urllib.parse import urlsplit
from validation_policy import NETWORK_GROUPS, CORE_GROUPS

LIVE_GROUPS = NETWORK_GROUPS | {"audit", "icloud", "icloud-cleanup", "manual-device"}
LIVE_EVIDENCE_LIFETIME = timedelta(days=1)
ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / '.build/extended-automation/validation-evidence.json'
WORKER_FOLDERS = ('OpenWorker', 'EmergencyUpdateWorker', 'ErrorReportWorker')
WRANGLER_ROOT = ROOT / 'Cloudflare/EmergencyUpdateWorker'
WORKER_LOG = ROOT / '.build/extended-automation/worker.log'
WORKER_SOURCE_PREFIX = 'bit101-source-git:'
_REPORT_THREAD_LOCK = threading.RLock()
_REPORT_LOCK_DEPTH: dict[Path, int] = {}
_REPORT_INPUTS: dict[Path, dict] = {}
_SOURCE_SNAPSHOT: ContextVar[dict | None] = ContextVar('validation_source_snapshot', default=None)


def workflow_elapsed_seconds() -> float | None:
    value = os.getenv('BIT101_VALIDATION_ELAPSED_SECONDS')
    if value is None: return None
    seconds = float(value)
    if not math.isfinite(seconds) or seconds < 0: raise ValueError('工作流耗时需要有限非负秒数。')
    return seconds


def worker_input_name(folder: str, name: str) -> bool:
    shared = {'Cloudflare/EmergencyUpdateWorker/package.json', 'Cloudflare/EmergencyUpdateWorker/package-lock.json'}
    if folder == 'OpenWorker': shared.add('BIT101-iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')
    operational = {'Cloudflare/EmergencyUpdateWorker/config/emergency-update.json',
        'Cloudflare/EmergencyUpdateWorker/Scripts/publish-emergency-update.sh'}
    return name in shared or name.startswith('Cloudflare/' + folder + '/') and Path(name).suffix != '.md' \
        and name not in operational and not is_worker_generated(Path(name))


def worker_source_inputs(folder: str) -> dict[str, bytes]:
    if folder not in WORKER_FOLDERS: raise ValueError('Worker 需要登记到部署合同。')
    try:
        return {name: (ROOT / name).read_bytes() for name in repository_input_names(ROOT) if worker_input_name(folder, name)}
    except OSError as error:
        raise ValueError('Worker 部署需要完整且已提交的源码输入。') from error


def worker_source_revision(folder: str) -> str:
    inputs = tuple(sorted(worker_source_inputs(folder).items()))
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
    return _committed_worker_revision(folder, revision, inputs)


@cache
def _committed_worker_revision(folder: str, revision: str, inputs: tuple[tuple[str, bytes], ...]) -> str:
    inputs = dict(inputs)
    paths = [f'Cloudflare/{folder}', 'Cloudflare/EmergencyUpdateWorker/package.json', 'Cloudflare/EmergencyUpdateWorker/package-lock.json']
    if folder == 'OpenWorker': paths.append('BIT101-iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=ROOT, stderr=subprocess.PIPE)
    names = {name for name in git('ls-tree', '-r', '--name-only', '-z', revision, '--', *paths).decode().split('\0')
        if name and worker_input_name(folder, name)}
    if names != set(inputs) or any(git('show', revision + ':' + name) != content for name, content in inputs.items()):
        raise ValueError('Worker 部署需要先提交当前源码、配置、资产与依赖锁。')
    source_revision = _last_input_commit(revision, lambda name: worker_input_name(folder, name), paths)
    if source_revision: return source_revision
    raise ValueError('Worker 源码需要可读取的 Git 提交身份。')


@lru_cache()
def _input_history(root: Path, revision: str, paths: tuple[str, ...]) -> tuple[str, ...]:
    history = subprocess.check_output(['git', 'log', '--first-parent', '--diff-merges=first-parent', '--no-renames',
        '--format=commit:%H', '--name-only', '-z', revision, *(['--', *paths] if paths else [])], cwd=root, stderr=subprocess.PIPE)
    return tuple(history.decode().split('\0'))


def _last_input_commit(revision: str, includes, paths=()) -> str | None:
    revision = subprocess.check_output(['git', 'rev-parse', revision], cwd=ROOT, stderr=subprocess.PIPE).decode().strip()
    source_revision = None
    for entry in _input_history(ROOT, revision, tuple(paths)):
        value = entry.lstrip('\n')
        if re.fullmatch(r'commit:(?:[0-9a-f]{40}|[0-9a-f]{64})', value): source_revision = value.removeprefix('commit:')
        elif value and includes(value):
            if source_revision: return source_revision
    return None


def worker_command(folder: str, *arguments: str) -> list[str]:
    if folder not in WORKER_FOLDERS: raise ValueError('Worker 需要登记到部署合同。')
    return [str(WRANGLER_ROOT / 'node_modules/.bin/wrangler'), *arguments,
        '--config', str(ROOT / 'Cloudflare' / folder / 'wrangler.jsonc')]


def worker_cli_json(folder: str, *arguments: str) -> dict:
    result = subprocess.run(worker_command(folder, *arguments, '--json'), cwd=WRANGLER_ROOT,
        env=worker_environment(),
        capture_output=True, text=True, timeout=60)
    if result.returncode:
        from command_output import FailureSummary
        details = FailureSummary()
        for line in result.stderr.splitlines(keepends=True): details.add(line)
        message = ''.join(details.lines()).strip()
        raise ValueError(f'{folder} 部署身份读取失败（Wrangler {result.returncode}）。'
            + (f'\n{message}' if message else '') + f'\n完整诊断：{WORKER_LOG}')
    return json.loads(result.stdout)


def worker_environment() -> dict:
    return dict(os.environ, WRANGLER_SEND_METRICS='false',
        WRANGLER_LOG_PATH=str(WORKER_LOG))


def worker_deployments_complete(scope: str, proof: dict) -> bool:
    expected = set(WORKER_FOLDERS) if scope in {'all', 'bit101'} else set()
    if not isinstance(proof, dict) or set(proof) != expected: return False
    try:
        for folder, row in proof.items():
            if not isinstance(row, dict) or str(uuid.UUID(row['deploymentID'])) != row['deploymentID'] \
                    or row['sourceRevision'] != worker_source_revision(folder): return False
            versions = row['versions']
            if not isinstance(versions, list) or not versions or any(not isinstance(version, dict) for version in versions): return False
            if len({version['versionID'] for version in versions}) != len(versions): return False
            for version in versions:
                if str(uuid.UUID(version['versionID'])) != version['versionID'] \
                        or type(version['percentage']) not in {int, float} or not 0 < version['percentage'] <= 100 \
                        or version['sourceRevision'] != row['sourceRevision']: return False
            if sum(version['percentage'] for version in versions) != 100: return False
        return True
    except (KeyError, TypeError, ValueError, AttributeError, OSError, subprocess.SubprocessError): return False


def capture_worker_deployments(scope: str) -> dict:
    proof = {}
    for folder in WORKER_FOLDERS if scope in {'all', 'bit101'} else ():
        deployment = worker_cli_json(folder, 'deployments', 'status')
        versions = []
        for traffic in deployment['versions']:
            identifier = traffic['version_id']
            version = worker_cli_json(folder, 'versions', 'view', identifier)
            if version['id'] != identifier: raise ValueError(f'{folder} 版本需要匹配实际部署。')
            message = version.get('annotations', {}).get('workers/message', '')
            if not message.startswith(WORKER_SOURCE_PREFIX): raise ValueError(f'{folder} 版本需要通过源码绑定入口部署。')
            versions.append({'versionID': identifier, 'percentage': traffic['percentage'],
                'sourceRevision': message.removeprefix(WORKER_SOURCE_PREFIX)})
        proof[folder] = {'deploymentID': deployment['id'], 'sourceRevision': worker_source_revision(folder),
            'versions': sorted(versions, key=lambda row: row['versionID'])}
    if not worker_deployments_complete(scope, proof): raise ValueError('活跃 Worker 部署需要匹配当前源码与全部流量版本。')
    return proof


def release_worker_findings(summary: dict) -> list[str]:
    from urllib.request import Request, urlopen
    errors = []
    try:
        if capture_worker_deployments('all') != summary.get('workerDeployments'):
            errors.append('发布前 Worker 活跃部署已变化，请重新执行网络验收。')
        endpoint = 'https://update.aihelpme.dev/emergency-update.json'
        with urlopen(Request(endpoint, headers={'Cache-Control': 'no-cache'}), timeout=20) as response:
            if response.status != 200 or response.geturl() != endpoint:
                raise ValueError('紧急更新配置需要由登记端点直接返回。')
            body = response.read(1_048_577)
            if len(body) > 1_048_576: raise ValueError('紧急更新配置超过响应范围。')
        current = base64.b64encode(body).decode('ascii')
        sampled = {request['responseConfiguration'].get('content')
            for probe in summary.get('requestEvidence', []) if probe.get('probe') == 'update.emergency'
            for request in probe.get('requests', []) if isinstance(request.get('responseConfiguration'), dict)}
        if sampled != {current}:
            errors.append('发布前紧急更新配置已变化，请重新执行网络验收。')
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError) as error:
        errors.append(f'发布前线上 Worker 复核需要完成：{error}')
    return errors


def worker_main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description='Bind Worker deployments and network sampling to their source inputs.')
    commands = parser.add_subparsers(dest='action', required=True)
    deploy = commands.add_parser('deploy-worker')
    deploy.add_argument('folder', choices=WORKER_FOLDERS)
    snapshot = commands.add_parser('worker-snapshot')
    snapshot.add_argument('scope')
    attach = commands.add_parser('worker-attach')
    attach.add_argument('report', type=Path)
    attach.add_argument('snapshot')
    args = parser.parse_args()
    try:
        with report_lock(path=WORKER_LOG):
            WORKER_LOG.write_text('')
            if args.action == 'deploy-worker':
                revision = worker_source_revision(args.folder)
                subprocess.run(worker_command(args.folder, 'deploy', '--message', WORKER_SOURCE_PREFIX + revision),
                    cwd=WRANGLER_ROOT, env=worker_environment(), check=True)
                if worker_source_revision(args.folder) != revision: raise ValueError('部署期间源码发生变化；请按当前输入重新部署。')
            elif args.action == 'worker-snapshot':
                print(json.dumps(capture_worker_deployments(args.scope)))
            else:
                report = json.loads(args.report.read_text())
                proof = json.loads(args.snapshot)
                if capture_worker_deployments(report['scope']) != proof: raise ValueError('Smoke 期间 Worker 部署发生变化；请重新采样。')
                report['workerDeployments'] = proof
                args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        return 0
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def producing_run_matches(value: str | dict, input_digest: str, run_id: str) -> bool:
    if not input_digest or not run_id:
        return False
    if isinstance(value, dict):
        return value.get("runID") == run_id
    return re.findall(r"^验证输入：(\S+)$", value, re.MULTILINE) == [input_digest] \
        and re.findall(r"^验证运行：(\S+)$", value, re.MULTILINE) == [run_id]


def sampling_evidence_current(summary: dict, now: datetime | None = None) -> bool:
    try:
        start, finish = (datetime.fromisoformat(summary[key].replace("Z", "+00:00"))
                         for key in ("startedAt", "finishedAt"))
        instant = now or utc_now()
        return start <= finish <= instant and timedelta() <= instant - start <= LIVE_EVIDENCE_LIFETIME
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


def evidence_current(group: str, summary: dict) -> bool:
    return group not in LIVE_GROUPS or sampling_evidence_current(summary)


def group_evidence_current(group: str, row: dict) -> bool:
    recorded = row.get('recordedAt', '')
    return evidence_current(group, row.get('summary', {})) and (group not in CORE_GROUPS
        or sampling_evidence_current({'startedAt': recorded, 'finishedAt': recorded}))


def complete_group_row(row: dict) -> dict:
    from validation_environment import exchange_identity
    full = row.get('lastFullRun', {})
    if row.get('scope') == 'selected' and row.get('exitCode') == 0 and row.get('summary', {}).get('passed') is True \
            and full.get('scope') == 'full' and full.get('exitCode') == 0 \
            and full.get('summary', {}).get('passed') is True \
            and row.get('inputDigest') and row['inputDigest'] == full.get('inputDigest') \
            and exchange_identity(row.get('environment')) == exchange_identity(full.get('environment')):
        return full
    return row


def invalidate_failed_evidence(report: dict, group: str, requested: set[str]) -> list[str]:
    failed = report['groups'][group]
    if failed.get('exitCode') == 0 and failed.get('summary', {}).get('passed') is True: return []
    network = group in NETWORK_GROUPS
    identity = (lambda probe: probe) if network else normalized_test_id
    field = 'probes' if network else 'tests'
    inventory = 'probeInventory' if network else 'executedTests'
    requested = {identity(item) for item in requested}
    if previous := failed.get('lastFullRun'):
        previous['exitCode'] = 1
        previous.setdefault('summary', {}).update(passed=False,
            failedRegression={'group': group, 'runID': failed.get('runID', ''), field: sorted(requested)})
    invalidated = []
    for name, row in report['groups'].items():
        if name == group: continue
        full = complete_group_row(row)
        available = {identity(item) for item in full.get('summary', {}).get(inventory, [])}
        overlap = available if network and not requested and name in NETWORK_GROUPS else requested & available
        if not overlap: continue
        for record in [row, *([row['lastFullRun']] if row.get('lastFullRun') else [])]:
            record['exitCode'] = 1
            record.setdefault('summary', {}).update(passed=False,
                failedRegression={'group': group, 'runID': failed.get('runID', ''), field: sorted(overlap)})
        invalidated.append(name)
    return sorted(invalidated)


def network_requests_complete(required: set[str], value: dict) -> bool:
    from network_request_contracts import complete, cleanup_requests_complete, VISIBLE_PARAMETERS
    from validation_policy import SCHOOL_SMS_PROBES
    if value.get('requestEvidenceRequired') is not True: return False
    verified, requested = value.get('verifiedSMSProbes', []), value.get('requestedSMSPurposes', [])
    if not isinstance(verified, list) or not isinstance(requested, list): return False
    sms_probes = {step.get('probe') for step in verified if isinstance(step, dict)
        and isinstance(step.get('purpose'), str) and isinstance(step.get('probe'), str)
        and step['purpose'] in requested and step['probe'] in SCHOOL_SMS_PROBES.get(step['purpose'], set())}
    rows = value.get('requestEvidence', [])
    if not isinstance(rows, list): return False
    observed = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('probe'), str) or not isinstance(row.get('requests'), list): return False
        if not row['requests']: continue
        for request in row['requests']:
            if not isinstance(request, dict): return False
            if any(request.get(key) is not None for key in ('ambiguousParameters', 'finalAmbiguousParameters')): return False
            try: final = urlsplit(request.get('finalEndpoint', ''))
            except (TypeError, ValueError): return False
            if not final.hostname or final.scheme not in {'http', 'https'} or final.username or final.password \
                    or final.query or final.fragment or request.get('finalMethod') not in {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'}: return False
            try: endpoint = urlsplit(request.get('endpoint', ''))
            except (TypeError, ValueError): return False
            if not endpoint.hostname or endpoint.scheme not in {'http', 'https'} or endpoint.username or endpoint.password \
                    or endpoint.query or endpoint.fragment or request.get('method') not in {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'} \
                    or type(request.get('statusCode')) is not int or not 100 <= request['statusCode'] < 600: return False
            if request.get('responseContentMissing') is not None and request['responseContentMissing'] is not True: return False
            query = request.get('query', {})
            cursor = request.get('responseMinimumID')
            if cursor is not None and (not isinstance(cursor, str) or re.fullmatch(r'\d+', cursor) is None): return False
            course_ids = request.get('responseCourseIDs')
            if course_ids is not None and (not isinstance(course_ids, list) or not all(isinstance(value, str)
                    and re.fullmatch(r'[1-9]\d*', value) for value in course_ids)): return False
            if not isinstance(query, dict) or not all(isinstance(key, str) and isinstance(item, str)
                    and (key in VISIBLE_PARAMETERS or item == '[REDACTED]') for key, item in query.items()): return False
            final_query = request.get('finalQuery')
            if not isinstance(final_query, dict) or not all(isinstance(key, str) and isinstance(item, str)
                    and (key in VISIBLE_PARAMETERS or item == '[REDACTED]') for key, item in final_query.items()): return False
        expected = row.get('expectedParameters', {})
        if not isinstance(expected, dict) or not set(expected) <= {'XNXQDM', 'JXLDM', 'XXXQDM', 'RQ', 'XQDM', 'XNDM', 'obj', 'uid', 'path', 'search', 'excludedSearch', 'resourceDigests'} \
                or not all(isinstance(item, str) for item in expected.values()): return False
        if value.get('validatedTerm') and expected.get('XNXQDM') != value['validatedTerm'] and 'XNXQDM' in expected: return False
        if value.get('scope') == 'community-cleanup' and row['probe'] == 'community.writes':
            if expected or not cleanup_requests_complete(row['requests']): return False
        elif not complete(row['probe'], row['requests'], expected,
                allow_sms=value.get('schoolSMSCoverage') == 'verified' and row['probe'] in sms_probes): return False
        observed.add(row['probe'])
    return bool(required) and required <= observed



@contextmanager
def report_lock(*, path: Path | None = None):
    destination = path if path is not None else REPORT
    with _REPORT_THREAD_LOCK:
        if _REPORT_LOCK_DEPTH.get(destination, 0):
            yield
            return
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            _REPORT_LOCK_DEPTH[destination] = 1
            try: yield
            finally:
                _REPORT_LOCK_DEPTH.pop(destination)
                _REPORT_INPUTS.pop(destination, None)



def write_report(report: dict, *, path: Path | None = None, preserve_inputs: bool = True) -> None:
    from validation_policy import MAXIMUM_REPORT_BYTES
    destination = path if path is not None else REPORT
    if preserve_inputs and destination in _REPORT_INPUTS:
        report['sourceInputs'] = _REPORT_INPUTS[destination]
    incoming = destination.with_suffix(".incoming")
    size = 1
    try:
        with incoming.open('wb') as stream:
            for chunk in json.JSONEncoder(ensure_ascii=False, indent=2).iterencode(report):
                data = chunk.encode()
                size += len(data)
                if size > MAXIMUM_REPORT_BYTES: raise ValueError('聚合验收证据需要控制在 128 MiB 以内。')
                stream.write(data)
            stream.write(b'\n')
        incoming.replace(destination)
    finally:
        incoming.unlink(missing_ok=True)



def normalized_test_id(identifier: str) -> str:
    parts = identifier.split("/")
    method = next((index for index, part in enumerate(parts) if "(" in part), len(parts) - 1)
    return "/".join([parts[0].rsplit(".", 1)[-1], *parts[1:method], parts[method].split("(", 1)[0]]) if method else identifier



@contextmanager
def source_snapshot():
    if _SOURCE_SNAPSHOT.get() is not None:
        yield
        return
    token = _SOURCE_SNAPSHOT.set({})
    try: yield
    finally: _SOURCE_SNAPSHOT.reset(token)


def input_identity(group: str = "", *, environment: dict | None = None) -> str:
    snapshot = _SOURCE_SNAPSHOT.get()
    if snapshot is None: snapshot = {}
    if 'files' not in snapshot:
        names = repository_input_names(ROOT)
        files = {}
        for name in sorted(set(names) - {""}):
            path = ROOT / name
            if path.is_file() and (not group or _SOURCE_SNAPSHOT.get() is not None or includes_input(name, group)):
                files[name] = {'executable': bool(path.stat().st_mode & 0o111),
                    'content': base64.b64encode(path.read_bytes()).decode('ascii')}
        snapshot.update(names=names, files=files)
    names = snapshot['names']
    files = {name: value for name, value in snapshot['files'].items() if includes_input(name, group)}
    context = _source_context(group, environment)
    return _local_source_identity(group, files, context, current_inputs=set(names),
        committed_identity=_clean_source_identity(group, context))


def committed_input_identity(group: str = "", *, environment: dict | None = None) -> str:
    identity = _clean_source_identity(group, _source_context(group, environment))
    if identity is None: raise ValueError('公开发布回执需要已提交的验证输入。')
    return identity


def _source_context(group: str, environment: dict | None) -> dict:
    context = {}
    if group:
        context = environment_context(group) if environment is None else environment
        if group == 'manual-device': context = {key: value for key, value in context.items() if key != 'device'}
        context = exchange_identity(context)
    return context


def _clean_source_identity(group: str, context: dict) -> str | None:
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=ROOT).decode()
    changed = git('diff', '--name-only', '--no-renames', '-z', 'HEAD').split('\0')
    changed += git('ls-files', '--others', '--exclude-standard', '-z').split('\0')
    if any(name and includes_input(name, group) for name in changed): return None
    commit = _last_input_commit('HEAD', lambda name: includes_input(name, group))
    if commit is None: return None
    for entry in git('ls-files', '-v', '--stage', '-z').split('\0'):
        if not entry: continue
        metadata, name = entry.split('\t', 1)
        flag, mode, _, _ = metadata.split()
        if (flag.islower() or flag.upper() == 'S') and includes_input(name, group):
            path = ROOT / name
            if not path.is_file() or bool(path.stat().st_mode & 0o111) != bool(int(mode, 8) & 0o111) \
                    or path.read_bytes() != subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT):
                return None
    environment = base64.urlsafe_b64encode(json.dumps([group, context], sort_keys=True).encode()).decode().rstrip('=')
    return f'git.{commit}.{environment}'


def _local_source_identity(group: str, files: dict, context: dict, *, current_inputs: set[str], committed_identity: str | None = None) -> str:
    with report_lock():
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        inputs = report.setdefault('sourceInputs', {'files': {}, 'groups': {}})
        _REPORT_INPUTS[REPORT] = inputs
        references = {}
        for name, content in files.items():
            previous = inputs['files'].get(name, {})
            if previous.get('content') != content:
                previous = inputs['files'][name] = {'content': content, 'identity': str(uuid.uuid4())}
            references[name] = previous['identity']
        snapshot = {'files': references, 'environment': context}
        previous = inputs['groups'].get(group, {})
        changed = previous.get('snapshot') != snapshot
        if changed:
            previous = inputs['groups'][group] = {'snapshot': snapshot, 'identity': committed_identity or str(uuid.uuid4())}
        retained = {name: row for name, row in inputs['groups'].items()
            if all(path in current_inputs and inputs['files'].get(path, {}).get('identity') == identity
                for path, identity in row['snapshot']['files'].items())}
        used = {path for row in retained.values() for path in row['snapshot']['files']}
        changed = changed or inputs['groups'] != retained or set(inputs['files']) != used
        inputs['groups'] = retained
        inputs['files'] = {name: row for name, row in inputs['files'].items() if name in used}
        if changed:
            write_report(report, preserve_inputs=False)
        return previous['identity']


if __name__ == '__main__':
    raise SystemExit(worker_main())
