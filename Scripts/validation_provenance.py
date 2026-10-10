#!/usr/bin/env python3
"""Associate workflow results with their producing run and network sampling interval."""
from datetime import datetime, timedelta, timezone
import re
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid
from urllib.parse import urlsplit
from validation_policy import NETWORK_GROUPS

LIVE_GROUPS = NETWORK_GROUPS | {"audit", "icloud", "icloud-cleanup", "manual-device"}
LIVE_EVIDENCE_LIFETIME = timedelta(days=1)
ROOT = Path(__file__).resolve().parents[1]
WORKER_FOLDERS = ('OpenWorker', 'EmergencyUpdateWorker', 'ErrorReportWorker')
WRANGLER_ROOT = ROOT / 'Cloudflare/EmergencyUpdateWorker'
WORKER_SOURCE_PREFIX = 'bit101-source-sha256:'


def worker_source_digest(folder: str) -> str:
    if folder not in WORKER_FOLDERS: raise ValueError('Worker 需要登记到部署合同。')
    paths = [WRANGLER_ROOT / 'package.json', WRANGLER_ROOT / 'package-lock.json']
    for directory, children, files in os.walk(ROOT / 'Cloudflare' / folder):
        children[:] = [name for name in children if name not in {'node_modules', '.wrangler', '.git'}]
        paths.extend(Path(directory) / name for name in files if Path(name).suffix in {'.js', '.jsonc'})
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
        env=dict(worker_environment(), WRANGLER_LOG='error'),
        capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f'{folder} 部署身份读取失败；请核对 Wrangler 认证与线上部署。')
    return json.loads(result.stdout)


def worker_environment() -> dict:
    return dict(os.environ, WRANGLER_SEND_METRICS='false',
        WRANGLER_LOG_PATH=str(ROOT / '.build/release-network-smoke/console.log'))


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
            if version['id'] != identifier: raise ValueError('Worker 版本需要匹配实际部署。')
            message = version.get('annotations', {}).get('workers/message', '')
            if not message.startswith(WORKER_SOURCE_PREFIX): raise ValueError('Worker 版本需要通过源码绑定入口部署。')
            versions.append({'versionID': identifier, 'percentage': traffic['percentage'],
                'sourceDigest': message.removeprefix(WORKER_SOURCE_PREFIX)})
        proof[folder] = {'deploymentID': deployment['id'], 'sourceDigest': worker_source_digest(folder),
            'versions': sorted(versions, key=lambda row: row['versionID'])}
    if not worker_deployments_complete(scope, proof): raise ValueError('活跃 Worker 部署需要匹配当前源码与全部流量版本。')
    return proof


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


def network_requests_complete(required: set[str], value: dict) -> bool:
    from network_request_contracts import complete
    if value.get('requestEvidenceRequired') is not True: return False
    if value.get('scope') == 'community-cleanup': required = required - {'社区写入与清理'}
    rows = value.get('requestEvidence', [])
    if not isinstance(rows, list): return False
    observed = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('probe'), str) or not isinstance(row.get('requests'), list): return False
        if not row['requests']: continue
        for request in row['requests']:
            if not isinstance(request, dict): return False
            try: final = urlsplit(request.get('finalEndpoint', ''))
            except (TypeError, ValueError): return False
            if not final.hostname or final.scheme not in {'http', 'https'} or final.username or final.password \
                    or final.query or final.fragment or request.get('finalMethod') not in {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'}: return False
            try: endpoint = urlsplit(request.get('endpoint', ''))
            except (TypeError, ValueError): return False
            if not endpoint.hostname or endpoint.scheme not in {'http', 'https'} or endpoint.username or endpoint.password \
                    or endpoint.query or endpoint.fragment or request.get('method') not in {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'} \
                    or type(request.get('statusCode')) is not int or not 100 <= request['statusCode'] < 600: return False
            query = request.get('query', {})
            cursor = request.get('responseMinimumID')
            if cursor is not None and (not isinstance(cursor, str) or re.fullmatch(r'\d+', cursor) is None): return False
            course_ids = request.get('responseCourseIDs')
            if course_ids is not None and (not isinstance(course_ids, list) or not all(isinstance(value, str)
                    and re.fullmatch(r'[1-9]\d*', value) for value in course_ids)): return False
            if not isinstance(query, dict) or not set(query) <= {'page', 'last_id', 'obj', 'order', 'mode', 'type', 'uid', 'detail', 'search', 'hide_bot', 'XNXQDM', 'JXLDM', 'XXXQDM'} \
                    or not all(isinstance(key, str) and isinstance(item, str) for key, item in query.items()): return False
            final_query = request.get('finalQuery')
            if not isinstance(final_query, dict) or not set(final_query) <= {'page', 'last_id', 'obj', 'order', 'mode', 'type', 'uid', 'detail', 'search', 'hide_bot', 'XNXQDM', 'JXLDM', 'XXXQDM'} \
                    or not all(isinstance(key, str) and isinstance(item, str) for key, item in final_query.items()): return False
        expected = row.get('expectedParameters', {})
        if not isinstance(expected, dict) or not set(expected) <= {'XNXQDM', 'JXLDM', 'XXXQDM', 'obj', 'uid', 'path'} \
                or not all(isinstance(item, str) for item in expected.values()): return False
        if value.get('validatedTerm') and expected.get('XNXQDM') != value['validatedTerm'] and 'XNXQDM' in expected: return False
        if complete(row['probe'], row['requests'], expected): observed.add(row['probe'])
        elif row['probe'] in required: return False
    return bool(required) and required <= observed


if __name__ == '__main__':
    raise SystemExit(worker_main())
