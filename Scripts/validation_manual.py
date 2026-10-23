"""Capture structured observations and local evidence for physical-device acceptance."""
import base64
import json
import math
import re
import uuid
from validation_provenance import sampling_evidence_current, utc_now, LIVE_EVIDENCE_LIFETIME
from pathlib import Path
from datetime import datetime, timedelta, timezone
from validate_distribution import valid_archive_provenance
from validation_media import media_complete
from validation_policy import MAXIMUM_ATTACHMENT_BYTES, MAXIMUM_REPORT_BYTES, workflow_conditions, manual_capabilities
from validation_inputs import performance_workloads, performance_group
from validation_performance import performance_comparison_complete

MANUAL_DEVICE_CHECKS = {"system-autofill", "photos", "calendar-permissions", "notifications", "external-handoff", "web-interactions", "widget", "watch", "feedback-delivery", "distribution-signing", "minimum-platforms"}
MANUAL_SCENARIOS = {
    'first-login': {'registered-account', 'new-account-registration'},
    'installation-paths': {'clean-install', 'app-store-upgrade'},
    'profile-writes': {'nickname-save', 'avatar-bind', 'restore-profile'},
    'gallery-report': {'submit-and-confirm'},
    'message-read': {'first-open', 'interrupted-paging', 'local-save-failure'},
    'account-lifecycle': {'sign-in-a', 'refresh-credentials-a', 'sign-out-a', 'sign-in-b', 'restore-a'},
    'community-variants': {'course-search', 'gallery-search-filters', 'comment-sorting', 'directed-replies', 'anonymous-poster', 'anonymous-paper', 'public-poster', 'public-edit-paper', 'poster-tags-claim', 'restore-content'},
    'web-interactions': {'network-diagnosis', 'update-launch', 'update-manual', 'school-sms', 'school-calendar',
        'gallery-login', 'gallery-account-switch', 'gallery-sign-out'},
    'catalyst-desktop': {'window-resize', 'menu-actions', 'keyboard-navigation', 'permission-dialogs', 'minimum-system'},
    'ipad-layout': {'portrait', 'landscape', 'split-view', 'resize'},
    'system-autofill': {'fill-credentials', 'dismiss-selection'},
    'photos': {'select-images', 'cancel-selection', 'load-failure', 'reopen-selection'},
    'calendar-permissions': {'authorized-write', 'denied-access', 'revoked-access'},
    'location-permissions': {'authorized-center', 'denied-access', 'revoked-access', 'location-failure'},
    'notifications': {'authorized-delivery', 'denied-access', 'revoked-access'},
    'external-handoff': {'open-target', 'return-to-app', 'share-page-open-app'},
    'widget': {'snapshot-render', 'account-switch', 'sign-out-clear'},
    'watch': {'snapshot-receive', 'account-switch', 'sign-out-clear', 'disconnect-reconnect'},
}
MANUAL_DEVICE_CHECKS.update(MANUAL_SCENARIOS)
APPLICATION_SCENARIOS = set(MANUAL_SCENARIOS)
INSTALLATION_ACTIONS = {
    'clean-install': {'first-launch', 'single-login', 'keychain-residue', 'school-features', 'community-features', 'cold-start'},
    'app-store-upgrade': {'install-over-store', 'preserve-login', 'preserve-schedule', 'preserve-ddl', 'preserve-settings',
        'school-features', 'community-features', 'cold-start'},
}
BASELINE_CHECKS = {'iOS': {'cold-start-session', 'offline-persistence', 'media-and-navigation'},
    'watchOS': {'snapshot-receive', 'timeline-render', 'clear-and-retry'}}
CATALYST_ACTIONS = {'menu-actions': {'app-menu', 'window-menu'}, 'keyboard-navigation': {'tab', 'return', 'escape'},
    'permission-dialogs': {'photos', 'calendar', 'notifications'}}
PERFORMANCE_WORKLOADS = performance_workloads()
MANUAL_SCENARIOS['performance-baseline'] = set(PERFORMANCE_WORKLOADS)
MANUAL_DEVICE_CHECKS.add('performance-baseline')


def capture(operation: str, result: str, evidence: Path, check: str, outcome: str, observed_at: str) -> dict:
    if not operation.strip() or not result.strip():
        raise ValueError("人工验收需要实际操作和观察结果")
    if outcome not in {"passed", "failed"} or not sampling_evidence_current({"startedAt": observed_at, "finishedAt": observed_at}):
        raise ValueError("人工验收需要明确结果状态和实际观察时间")
    with evidence.open('rb') as stream: data = stream.read(MAXIMUM_ATTACHMENT_BYTES + 1)
    if len(data) > MAXIMUM_ATTACHMENT_BYTES: raise ValueError('人工附件需要控制在 32 MiB 以内。')
    if not (failed_evidence_complete(data) if outcome == "failed" else evidence_content_complete(check, data, observed_at=observed_at)):
        if outcome == 'passed' and check in MANUAL_SCENARIOS:
            raise ValueError(manual_evidence_problem(check, data))
        raise ValueError("验收附件需要有效影像、PDF 或所属专项的结构化证据")
    if check == 'performance-baseline' and outcome == 'passed':
        from validation_performance import validate_capture
        validate_capture(json.loads(data))
    try:
        text = data.decode('utf-8')
        json.loads(text)
        payload = {'dataUTF8': text}
    except (UnicodeDecodeError, ValueError): payload = {'dataBase64': base64.b64encode(data).decode('ascii')}
    return {"check": check, "operation": operation.strip(), "result": result.strip(), "outcome": outcome, "capturedAt": observed_at, "registeredAt": utc_now().isoformat(),
        "evidence": {"path": str(evidence.resolve()), "byteCount": len(data), **payload}}


def failed_evidence_complete(data: bytes) -> bool:
    if not data or len(data) > MAXIMUM_ATTACHMENT_BYTES: return False
    if media_content_complete(data): return True
    try:
        value = json.loads(data)
        return isinstance(value, dict) and bool(value)
    except (ValueError, TypeError): return False


def artifact_bytes(artifact: dict) -> bytes:
    if type(artifact.get('byteCount')) is not int or not 0 < artifact['byteCount'] <= MAXIMUM_ATTACHMENT_BYTES:
        raise ValueError('验收附件需要符合字节预算。')
    fields = {'dataUTF8', 'dataBase64'} & artifact.keys()
    if len(fields) != 1: raise ValueError('验收附件需要唯一的数据编码。')
    field = fields.pop()
    limit = MAXIMUM_ATTACHMENT_BYTES if field == 'dataUTF8' else 4 * ((MAXIMUM_ATTACHMENT_BYTES + 2) // 3)
    if not isinstance(artifact[field], str) or len(artifact[field]) > limit:
        raise ValueError('验收附件编码需要符合字节预算。')
    data = artifact[field].encode('utf-8') if field == 'dataUTF8' else base64.b64decode(artifact[field], validate=True)
    if len(data) != artifact['byteCount']:
        raise ValueError('验收附件需要匹配原始字节数。')
    return data


def artifact_complete(artifact: dict, check: str, *, observed_at: str | None = None, media_only: bool = False) -> bool:
    try:
        data = artifact_bytes(artifact)
        content_valid = media_content_complete(data) if media_only else evidence_content_complete(check, data, observed_at=observed_at)
        return content_valid and isinstance(artifact["path"], str) and bool(artifact["path"].strip())
    except (KeyError, TypeError, ValueError):
        return False


def evidence_content_complete(check: str, data: bytes, *, observed_at: str | None = None) -> bool:
    if not data or len(data) > MAXIMUM_ATTACHMENT_BYTES: return False
    if check not in MANUAL_DEVICE_CHECKS: return False
    if check in MANUAL_SCENARIOS:
        try: return scenario_complete(check, json.loads(data))
        except (ValueError, TypeError, KeyError, OSError): return False
    if check == 'minimum-platforms':
        try: return baseline_complete(json.loads(data))
        except (ValueError, TypeError, KeyError, OSError): return False
    if check == 'distribution-signing':
        from validate_distribution import distribution_complete
        try:
            proof = json.loads(data)
            return isinstance(proof, dict) and distribution_complete(proof)
        except (ValueError, TypeError, KeyError, OSError): return False
    if check == 'feedback-delivery':
        try:
            from email.utils import getaddresses, parsedate_to_datetime
            proof = json.loads(data)
            if not isinstance(proof, dict) or not all(isinstance(proof.get(field), str) for field in
                    ('reportID', 'storageKey', 'emailRecipient', 'emailMessageID', 'emailBody')): return False
            report = str(uuid.UUID(proof['reportID']))
            stored = proof['storedReport']
            payload = stored['report']
            delivery = stored['emailDelivery']
            if not isinstance(payload, dict): return False
            mode = payload.get('mode')
            fields = ('comment',) if mode == 'suggestion' else ('errorTitle', 'errorMessage')
            if mode not in {'sanitized', 'raw', 'suggestion'} or payload.get('isDevelopmentBuild') is not False \
                    or not all(isinstance(payload.get(field), str) and payload[field].strip() for field in fields): return False
            if not all(payload.get(field) is None or isinstance(payload[field], str) for field in
                    ('appVersion', 'build', 'deviceModel', 'systemVersion', 'networkStatus', 'contact')): return False
            headers = proof['emailHeaders']
            if not isinstance(headers, dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in headers.items()): return False
            normalized = {key.casefold(): value.strip() for key, value in headers.items()}
            if len(normalized) != len(headers): return False
            configuration = json.loads((Path(__file__).resolve().parents[1] / 'Cloudflare/ErrorReportWorker/wrangler.jsonc').read_text())
            recipient = configuration['vars']['REPORT_EMAIL_RECIPIENT']
            received = stored['receivedAt']
            received_time = datetime.fromisoformat(received.replace('Z', '+00:00'))
            email_time = parsedate_to_datetime(normalized['date'])
            if email_time.utcoffset() is None and normalized['date'].endswith('-0000'):
                email_time = email_time.replace(tzinfo=timezone.utc)
            instant = utc_now()
            observation = datetime.fromisoformat(observed_at.replace('Z', '+00:00')) if observed_at is not None else instant
            if received_time.utcoffset() is None or email_time.utcoffset() is None \
                    or not timedelta() <= instant - received_time <= LIVE_EVIDENCE_LIFETIME \
                    or observation.utcoffset() is None or not received_time <= observation <= instant \
                    or not received_time.replace(microsecond=0) <= email_time <= observation: return False
            return capability_observations_complete(check, 'delivery', proof.get('capabilities')) \
                and proof['reportID'] == report and proof['storageKey'] == 'report:' + received + ':' + report and stored['id'] == report \
                and isinstance(delivery, dict) and delivery.get('status') == 'sent' \
                and type(delivery.get('attempts')) is int and delivery['attempts'] > 0 \
                and isinstance(delivery.get('messageID'), str) and bool(delivery['messageID'].strip()) \
                and proof['emailRecipient'].casefold() == recipient.casefold() \
                and [address.casefold() for _, address in getaddresses([normalized['to']])] == [recipient.casefold()] \
                and bool(re.fullmatch(r'<[^\s<>@]+@[^\s<>@]+>', proof['emailMessageID'])) \
                and normalized['message-id'] == proof['emailMessageID'] and normalized['x-bit101-report-id'] == report \
                and '报告编号：' + report in proof['emailBody'] and '接收时间：' + received in proof['emailBody']
        except (ValueError, TypeError, KeyError, AttributeError, OSError, StopIteration): return False
    return False


def media_content_complete(data: bytes) -> bool:
    if not data or len(data) > MAXIMUM_ATTACHMENT_BYTES: return False
    recognized = data.startswith(b'\x89PNG\r\n\x1a\n') or data.startswith(b'\xff\xd8\xff') and data.endswith(b'\xff\xd9') \
        or data.startswith(b'%PDF-') and data.rstrip().endswith(b'%%EOF') \
        or len(data) >= 16 and data[4:8] == b'ftyp' and b'moov' in data
    return recognized and media_complete(data)


def capability_observations_complete(check: str, scenario: str, observations) -> bool:
    required = manual_capabilities(check, scenario)
    if not required: return True
    return isinstance(observations, dict) and set(observations) == required and all(
        isinstance(row, dict) and row.get('outcome') == 'passed'
        and all(isinstance(row.get(key), str) and row[key].strip() for key in ('operation', 'result'))
        for row in observations.values())


def scenario_complete(check: str, proof: dict) -> bool:
    if not isinstance(proof, dict) or type(proof.get('schemaVersion')) is not int or proof.get('schemaVersion') != 1 \
            or not isinstance(proof.get('scenarios'), dict) or set(proof['scenarios']) != MANUAL_SCENARIOS[check]: return False
    platform = 'macCatalyst' if check == 'catalyst-desktop' else 'watchOS' if check == 'watch' else 'iOS'
    if check in APPLICATION_SCENARIOS and not application_identity_complete(proof, platform): return False
    if check == 'ipad-layout' and proof.get('deviceFamily') != 'iPad': return False
    return all(scenario_row_complete(check, name, row, proof) for name, row in proof['scenarios'].items())


def scenario_row_complete(check: str, name: str, row, proof: dict) -> bool:
    if not isinstance(row, dict) or row.get('outcome') != 'passed' \
            or not all(isinstance(row.get(key), str) and row[key].strip() for key in ('operation', 'result', 'capturedAt')) \
            or not sampling_evidence_current({'startedAt': row['capturedAt'], 'finishedAt': row['capturedAt']}) \
            or not isinstance(row.get('evidence'), dict) or not artifact_complete(row['evidence'], 'photos', media_only=True) \
            or not capability_observations_complete(check, name, row.get('capabilities')): return False
    if check == 'performance-baseline' and not performance_comparison_complete(name, row.get('measurement')): return False
    if check == 'installation-paths' and not installation_path_complete(name, row, proof['application']): return False
    if check == 'catalyst-desktop':
        required = CATALYST_ACTIONS.get(name)
        if required and (not isinstance(row.get('actions'), dict) or set(row['actions']) != required
                or not all(isinstance(action, dict) and action.get('outcome') == 'passed'
                    and all(isinstance(action.get(key), str) and action[key].strip() for key in ('operation', 'result'))
                    for action in row['actions'].values())): return False
    if check == 'ipad-layout' or check == 'catalyst-desktop' and name == 'window-resize':
        size = row.get('windowSize', {})
        if not isinstance(size, dict) or not all(type(size.get(axis)) is int and size[axis] > 0 for axis in ('width', 'height')): return False
        if name == 'portrait' and size['width'] >= size['height']: return False
        if name == 'landscape' and size['width'] <= size['height']: return False
        if name == 'split-view' and (type(row.get('screenWidth')) is not int or size['width'] >= row['screenWidth']): return False
        if name in {'resize', 'window-resize'} and (not isinstance(row.get('previousWindowSize'), dict)
                or not all(type(row['previousWindowSize'].get(axis)) is int and row['previousWindowSize'][axis] > 0 for axis in ('width', 'height'))
                or row['previousWindowSize'] == size): return False
    return True


def manual_structure(check: str) -> dict:
    if check not in MANUAL_SCENARIOS: raise ValueError('场景结构查询需要已登记的场景专项。')
    observation = {'outcome': 'passed', 'operation': '实际操作文本', 'result': '实际观察文本'}
    structure = {'schemaVersion': '整数 1'}
    if check in APPLICATION_SCENARIOS:
        structure.update({key: '实际设备与分发应用的标识文本' for key in (
            'platform', 'deviceIdentifier', 'deviceModel', 'systemVersion', 'systemBuild', 'inputDigest')})
        structure['application'] = {key: '当前分发二进制的对应值' for key in (
            'identifier', 'version', 'build', 'configuration', 'testHostMarkers', 'minimumOSVersion', 'executableUUIDs')}
        structure['application'].update(configuration='Release', testHostMarkers=[],
            executableUUIDs=[{'architecture': '实际体系结构', 'uuid': '实际可执行 UUID'}])
        if check != 'catalyst-desktop': structure['application']['distributionChannel'] = 'testflight 或 app-store'
    if check == 'ipad-layout': structure['deviceFamily'] = 'iPad'
    scenarios = {}
    for name in sorted(MANUAL_SCENARIOS[check]):
        row = dict(observation, capturedAt='实际观察的 ISO 8601 时间', evidence={
            'path': '原始影像或 PDF 路径', 'byteCount': '实际字节数，最大 32 MiB',
            'dataBase64': '原始附件的 Base64；UTF-8 附件也可使用 dataUTF8'})
        capabilities = manual_capabilities(check, name)
        if capabilities: row['capabilities'] = {key: dict(observation) for key in sorted(capabilities)}
        if check == 'performance-baseline': row['measurement'] = '所属性能场景的完整测量与基线对象'
        if check == 'installation-paths':
            row['actions'] = {key: dict(observation) for key in sorted(INSTALLATION_ACTIONS[name])}
            if name == 'app-store-upgrade':
                row['sourceApplication'] = {key: '升级前商店应用的对应值' for key in ('identifier', 'version', 'build', 'distributionChannel')}
                row['appStoreLookup'] = {key: '对应商店记录值' for key in ('trackId', 'bundleId', 'version')}
        actions = CATALYST_ACTIONS.get(name) if check == 'catalyst-desktop' else None
        if actions: row['actions'] = {key: dict(observation) for key in sorted(actions)}
        if check == 'ipad-layout' or check == 'catalyst-desktop' and name == 'window-resize':
            row['windowSize'] = {'width': '正整数', 'height': '正整数'}
            if name == 'split-view': row['screenWidth'] = '屏幕宽度正整数'
            if name in {'resize', 'window-resize'}: row['previousWindowSize'] = {'width': '正整数', 'height': '正整数'}
        scenarios[name] = row
    structure['scenarios'] = scenarios
    return structure


def first_missing_field(value, structure: dict, prefix: str = '') -> str | None:
    if not isinstance(value, dict): return prefix or '$'
    for key, description in structure.items():
        if key == 'dataBase64' and 'dataUTF8' in value: continue
        path = prefix + '.' + key if prefix else key
        if key not in value: return path
        if isinstance(description, dict) and (missing := first_missing_field(value[key], description, path)):
            return missing
    return None


def manual_evidence_problem(check: str, data: bytes) -> str:
    try: proof = json.loads(data)
    except (ValueError, UnicodeError) as error: return f'{check}: 附件需要场景 JSON；{error}'
    if missing := first_missing_field(proof, manual_structure(check)):
        return f'{missing}: 需要该字段；结构查询：python3 Scripts/validation_evidence.py manual-schema {check}'
    if type(proof.get('schemaVersion')) is not int or proof['schemaVersion'] != 1: return 'schemaVersion: 需要整数 1。'
    if set(proof['scenarios']) != MANUAL_SCENARIOS[check]: return f'scenarios: 需要精确覆盖 {check} 的登记场景。'
    if check == 'ipad-layout' and proof.get('deviceFamily') != 'iPad': return 'deviceFamily: 需要 iPad。'
    if check in APPLICATION_SCENARIOS:
        platform = 'macCatalyst' if check == 'catalyst-desktop' else 'watchOS' if check == 'watch' else 'iOS'
        if not application_identity_complete(proof, platform): return 'application: 需要对应当前输入、平台与分发二进制的实际标识。'
    for name, row in proof['scenarios'].items():
        if not scenario_row_complete(check, name, row, proof):
            return f'scenarios.{name}: 需要通过的观察、有效时间、原始附件及所属专项记录。'
    return f'{check}: 需要完整的场景验收记录。'


def installation_path_complete(name: str, row: dict, application: dict) -> bool:
    actions = row.get('actions')
    if not isinstance(actions, dict) or set(actions) != INSTALLATION_ACTIONS[name] or not all(
            isinstance(action, dict) and action.get('outcome') == 'passed'
            and all(isinstance(action.get(key), str) and action[key].strip() for key in ('operation', 'result'))
            for action in actions.values()): return False
    if name == 'clean-install': return True
    source = row.get('sourceApplication')
    lookup = row.get('appStoreLookup')
    return isinstance(source, dict) and isinstance(lookup, dict) \
        and source.get('distributionChannel') == 'app-store' and source.get('identifier') == application['identifier'] \
        and all(isinstance(source.get(key), str) and source[key].strip() for key in ('version', 'build')) \
        and lookup.get('trackId') == 6761147125 and lookup.get('bundleId') == source['identifier'] \
        and lookup.get('version') == source['version']


def application_identity_complete(proof: dict, platform: str) -> bool:
    from validation_compilation import compilation_settings
    from validation_provenance import source_digest
    from validate_distribution import distribution_contracts, minimum_os_version, valid_executable_uuids
    application = proof.get('application')
    minimum = minimum_os_version(compilation_settings('macOS' if platform == 'macCatalyst' else platform)[1])
    version = minimum_os_version(proof.get('systemVersion'))
    if proof.get('platform') != platform or not all(isinstance(proof.get(key), str) and proof[key].strip()
            for key in ('deviceIdentifier', 'deviceModel', 'systemBuild')) or version is None \
            or version < minimum or platform == 'macCatalyst' and version[:2] != minimum[:2] \
            or not isinstance(application, dict): return False
    contracts = distribution_contracts()
    contract = contracts.get(application.get('identifier'))
    return bool(contract) and not contract['extension'] and contract['platform'] == ('watchOS' if platform == 'watchOS' else 'iOS') \
        and application.get('version') == contract['version'] and application.get('build') == contract['build'] \
        and application.get('configuration') == 'Release' and application.get('testHostMarkers') == [] \
        and minimum_os_version(application.get('minimumOSVersion')) == minimum \
        and valid_executable_uuids(application.get('executableUUIDs')) \
        and (platform == 'macCatalyst' or application.get('distributionChannel') in {'testflight', 'app-store'}) \
        and proof.get('inputDigest') == source_digest('manual-device', environment={})


def baseline_complete(proof: dict) -> bool:
    from validate_distribution import distribution_contracts, minimum_os_version, valid_executable_uuids
    if not isinstance(proof, dict) or proof.get('schemaVersion') != 1 or not isinstance(proof.get('platforms'), dict) \
            or set(proof['platforms']) != set(BASELINE_CHECKS): return False
    contracts = distribution_contracts()
    for platform, required in BASELINE_CHECKS.items():
        row = proof['platforms'][platform]
        minimum = max(minimum_os_version(contract['minimumOSVersion']) for contract in contracts.values() if contract['platform'] == platform)
        if not isinstance(row, dict) or not all(isinstance(row.get(key), str) and row[key].strip() for key in
                ('deviceIdentifier', 'deviceModel', 'systemVersion', 'systemBuild', 'capturedAt')) \
                or not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', row['systemVersion']) \
                or minimum_os_version(row['systemVersion'])[:2] != minimum[:2] \
                or minimum_os_version(row['systemVersion']) < minimum \
                or not sampling_evidence_current({'startedAt': row['capturedAt'], 'finishedAt': row['capturedAt']}) \
                or not isinstance(row.get('checks'), dict) or set(row['checks']) != required \
                or not all(isinstance(check, dict) and check.get("outcome") == "passed" and all(isinstance(check.get(key), str) and check[key].strip()
                    for key in ('operation', 'result')) for check in row['checks'].values()) \
                or not isinstance(row.get('evidence'), dict) or not artifact_complete(row['evidence'], 'photos', media_only=True): return False
        bundles = row.get('installedBundles')
        expected = {identifier for identifier, value in contracts.items() if value['platform'] == platform}
        if not isinstance(bundles, list) or len(bundles) != len(expected) \
                or any(not isinstance(bundle, dict) or not isinstance(bundle.get('identifier'), str) for bundle in bundles) \
                or {bundle.get('identifier') for bundle in bundles} != expected: return False
        for bundle in bundles:
            contract = contracts[bundle['identifier']]
            if bundle.get('version') != contract['version'] or bundle.get('build') != contract['build'] \
                    or not valid_executable_uuids(bundle.get('executableUUIDs')): return False
            if bundle.get('distributionChannel') not in {'testflight', 'app-store'}: return False
    return True


def complete(checks: dict) -> bool:
    if not isinstance(checks, dict): return False
    try:
        encoded_bytes = 0
        for part in json.JSONEncoder(indent=2).iterencode(checks):
            encoded_bytes += len(part)
            if encoded_bytes > MAXIMUM_REPORT_BYTES: return False
    except (TypeError, ValueError): return False
    valid = set(checks) == MANUAL_DEVICE_CHECKS and all(
        isinstance(row, dict) and row.get('check') == check and row.get('outcome') == 'passed'
        and all(isinstance(row.get(field), str) and row[field].strip() for field in ("operation", "result", "capturedAt"))
        and isinstance(row.get("evidence"), dict) and artifact_complete(row["evidence"], check, observed_at=row['capturedAt'])
        and sampling_evidence_current({"startedAt": row["capturedAt"], "finishedAt": row["capturedAt"]}) for check, row in checks.items())
    return valid and baseline_matches_distribution(checks['minimum-platforms'], checks['distribution-signing']) \
        and scenarios_match_distribution(checks, checks['distribution-signing'])


def installed_bundle_matches_distribution(installed: dict, exported: dict | None) -> bool:
    from validate_distribution import valid_executable_uuids
    return isinstance(exported, dict) and all(installed.get(key) == exported.get(key)
        for key in ('identifier', 'version', 'build')) \
        and installed.get('distributionChannel') in {'testflight', 'app-store'} \
        and valid_executable_uuids(installed.get('executableUUIDs')) \
        and all(item in exported.get('executableUUIDs', []) for item in installed['executableUUIDs'])


def scenarios_match_distribution(checks: dict, distribution_observation: dict) -> bool:
    try:
        distribution = json.loads(artifact_bytes(distribution_observation['evidence']))
        expected = {row['identifier']: row for row in distribution['bundles']}
        for check in APPLICATION_SCENARIOS - {'catalyst-desktop'}:
            proof = json.loads(artifact_bytes(checks[check]['evidence']))
            application = proof['application']
            if not installed_bundle_matches_distribution(application, expected.get(application['identifier'])): return False
        return True
    except (KeyError, ValueError, TypeError, AttributeError): return False


def distribution_matches_archive(observation: dict, archive: dict) -> bool:
    try:
        if not artifact_complete(observation.get('evidence', {}), 'distribution-signing'): return False
        proof = json.loads(artifact_bytes(observation['evidence']))
        summary = archive['summary']
        provenance = summary['archiveProvenance']
        expected = {'inputDigest': archive['inputDigest'], 'runID': archive['runID']}
        if archive.get('exitCode') != 0 or archive.get('scope') != 'full' or summary.get('passed') is not True \
                or provenance != expected or not valid_archive_provenance(provenance) or proof.get('archiveProvenance') != provenance:
            return False
        rows = proof['bundles']
        executables = summary['executables']
        if {row['identifier'] for row in rows} != set(executables): return False
        return all(row['executableUUIDs'] and all(item in executables[row['identifier']] for item in row['executableUUIDs']) for row in rows)
    except (KeyError, ValueError, TypeError, AttributeError): return False


def catalyst_matches_runtime(observation: dict, runtime: dict) -> bool:
    try:
        if not artifact_complete(observation.get('evidence', {}), 'catalyst-desktop') \
                or runtime.get('exitCode') != 0 or runtime.get('scope') != 'full' \
                or runtime.get('summary', {}).get('passed') is not True: return False
        proof = json.loads(artifact_bytes(observation['evidence']))
        fields = ('identifier', 'version', 'build', 'executableUUIDs')
        return {key: proof['application'][key] for key in fields} == {key: runtime['application'][key] for key in fields}
    except (KeyError, ValueError, TypeError, AttributeError): return False


def baseline_matches_distribution(observation: dict, distribution_observation: dict) -> bool:
    try:
        if not artifact_complete(observation.get('evidence', {}), 'minimum-platforms') \
                or not artifact_complete(distribution_observation.get('evidence', {}), 'distribution-signing'): return False
        proof = json.loads(artifact_bytes(observation['evidence']))
        distribution = json.loads(artifact_bytes(distribution_observation['evidence']))
        expected = {row['identifier']: row for row in distribution['bundles']}
        installed = {row['identifier']: row
            for platform in proof['platforms'].values() for row in platform['installedBundles']}
        return installed.keys() == expected.keys() and all(installed_bundle_matches_distribution(row, expected.get(identifier))
            for identifier, row in installed.items())
    except (KeyError, ValueError, TypeError, AttributeError): return False
