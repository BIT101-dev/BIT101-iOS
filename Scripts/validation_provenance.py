#!/usr/bin/env python3
"""Associate workflow results with their producing run and network sampling interval."""
from datetime import datetime, timedelta, timezone
import re
import hashlib
import base64
import json
import os
from pathlib import Path
import subprocess
import uuid
import fcntl
import threading
from contextlib import contextmanager
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
WORKER_SOURCE_PREFIX = 'bit101-source-sha256:'
_REPORT_THREAD_LOCK = threading.RLock()
_REPORT_LOCK_DEPTH: dict[Path, int] = {}
_REPORT_INPUTS: dict[Path, dict] = {}


def worker_source_digest(folder: str) -> str:
    if folder not in WORKER_FOLDERS: raise ValueError('Worker 需要登记到部署合同。')
    paths = [WRANGLER_ROOT / 'package.json', WRANGLER_ROOT / 'package-lock.json']
    if folder == 'OpenWorker': paths.append(ROOT / 'BIT101-iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')
    operational_inputs = {'Cloudflare/EmergencyUpdateWorker/config/emergency-update.json',
        'Cloudflare/EmergencyUpdateWorker/Scripts/publish-emergency-update.sh'}
    paths.extend(ROOT / name for name in repository_input_names(ROOT)
        if name.startswith('Cloudflare/' + folder + '/') and Path(name).suffix != '.md'
        and name not in operational_inputs and not is_worker_generated(Path(name)))
    digest = hashlib.sha256()
    for path in sorted(set(paths)):
        digest.update(path.relative_to(ROOT).as_posix().encode() + b'\0' + path.read_bytes() + b'\0')
    return digest.hexdigest()


def worker_command(folder: str, *arguments: str) -> list[str]:
    if folder not in WORKER_FOLDERS: raise ValueError('Worker 需要登记到部署合同。')
    return [str(WRANGLER_ROOT / 'node_modules/.bin/wrangler'), *arguments,
        '--config', str(ROOT / 'Cloudflare' / folder / 'wrangler.jsonc')]


def worker_cli_json(folder: str, *arguments: str) -> dict:
    result = subprocess.run(worker_command(folder, *arguments, '--json'), cwd=WRANGLER_ROOT,
        env=worker_environment(),
        capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f'{folder} 部署身份读取失败；请核对 Wrangler 认证与线上部署。')
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
                    or row['sourceDigest'] != worker_source_digest(folder): return False
            versions = row['versions']
            if not isinstance(versions, list) or not versions or any(not isinstance(version, dict) for version in versions): return False
            if len({version['versionID'] for version in versions}) != len(versions): return False
            for version in versions:
                if str(uuid.UUID(version['versionID'])) != version['versionID'] \
                        or type(version['percentage']) not in {int, float} or not 0 < version['percentage'] <= 100 \
                        or version['sourceDigest'] != row['sourceDigest']: return False
            if sum(version['percentage'] for version in versions) != 100: return False
        return True
    except (KeyError, TypeError, ValueError, AttributeError): return False


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
                'sourceDigest': message.removeprefix(WORKER_SOURCE_PREFIX)})
        proof[folder] = {'deploymentID': deployment['id'], 'sourceDigest': worker_source_digest(folder),
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
        current = hashlib.sha256(body).hexdigest()
        sampled = {request['responseConfiguration'].get('digest')
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
                digest = worker_source_digest(args.folder)
                subprocess.run(worker_command(args.folder, 'deploy', '--message', WORKER_SOURCE_PREFIX + digest),
                    cwd=WRANGLER_ROOT, env=worker_environment(), check=True)
                if worker_source_digest(args.folder) != digest: raise ValueError('部署期间源码发生变化；请按当前输入重新部署。')
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



def source_digest(group: str = "", *, environment: dict | None = None) -> str:
    names = repository_input_names(ROOT)
    context = {}
    if group:
        context = environment_context(group) if environment is None else environment
        if group == 'manual-device': context = {key: value for key, value in context.items() if key != 'device'}
        context = exchange_identity(context)
    if identity := _clean_source_identity(group, context): return identity
    files = {}
    for name in sorted(set(names) - {""}):
        path = ROOT / name
        if path.is_file() and includes_input(name, group):
            files[name] = {'executable': bool(path.stat().st_mode & 0o111),
                'content': base64.b64encode(path.read_bytes()).decode('ascii')}
    return _local_source_identity(group, files, context)


def _clean_source_identity(group: str, context: dict) -> str | None:
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=ROOT).decode().strip()
    changed = git('diff', '--name-only', '--no-renames', '-z', 'HEAD').split('\0')
    changed += git('ls-files', '--others', '--exclude-standard', '-z').split('\0')
    if any(name and includes_input(name, group) for name in changed): return None
    commit = git('rev-parse', 'HEAD')
    if re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', commit) is None: return None
    environment = base64.urlsafe_b64encode(json.dumps([group, context], sort_keys=True).encode()).decode().rstrip('=')
    return f'git.{commit}.{environment}'


def _local_source_identity(group: str, files: dict, context: dict) -> str:
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
        if previous.get('snapshot') != snapshot:
            previous = inputs['groups'][group] = {'snapshot': snapshot, 'identity': str(uuid.uuid4())}
            write_report(report, preserve_inputs=False)
        return previous['identity']


if __name__ == '__main__':
    raise SystemExit(worker_main())
