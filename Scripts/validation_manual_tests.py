"""Contracts for physical observations and final distribution signature evidence."""
import copy
from io import BytesIO
import json
from pathlib import Path
import plistlib
import struct
import subprocess
from types import SimpleNamespace
from unittest.mock import patch
import zlib
import uuid
from validation_manual import MANUAL_DEVICE_CHECKS, capture, complete, evidence_content_complete
from validation_provenance import utc_now
import validate_distribution as distribution


def distribution_fixture() -> tuple[dict, dict]:
    contracts = distribution.distribution_contracts()
    main = next(identifier for identifier, value in contracts.items() if 'com.apple.developer.icloud-services' in value['entitlements'])
    rows = []
    for identifier, value in contracts.items():
        entitlements = copy.deepcopy(value['entitlements'])
        entitlements = {key: item.replace('$(TeamIdentifierPrefix)', value['team'] + '.') if isinstance(item, str) else item for key, item in entitlements.items()}
        entitlements.update({'application-identifier': value['team'] + '.' + identifier,
            'com.apple.developer.team-identifier': value['team'], 'get-task-allow': False})
        if identifier == main: entitlements['com.apple.developer.icloud-container-environment'] = 'Production'
        parents = [key for key, contract in contracts.items() if not contract['extension'] and identifier.startswith(key + '.')]
        rows.append({'identifier': identifier, 'team': value['team'], 'version': value['version'], 'build': value['build'],
            'entitlements': entitlements, 'signatureVerified': True, 'sha256': 'a' * 64,
            'executableUUIDs': [{'architecture': 'arm64', 'uuid': str(uuid.uuid5(uuid.NAMESPACE_URL, identifier)).upper()}],
            'containerIdentifier': max(parents, key=len) if parents else '', 'companionIdentifier': main if identifier != main and not value['extension'] else ''})
    return contracts, {'schemaVersion': 1, 'verifiedAt': utc_now().isoformat(),
        'archiveProvenance': {'inputDigest': 'a' * 64, 'runID': 'fixture-run'}, 'bundles': rows}


def evidence_fixture(check: str) -> bytes:
    if check == 'distribution-signing': return json.dumps(distribution_fixture()[1]).encode()
    if check == 'minimum-platforms':
        from validation_manual import BASELINE_CHECKS
        contracts = distribution.distribution_contracts()
        platforms = {}
        for platform, checks in BASELINE_CHECKS.items():
            version = min(value['minimumOSVersion'] for value in contracts.values() if value['platform'] == platform)
            platforms[platform] = {'deviceIdentifier': platform + '-fixture', 'deviceModel': platform + '-device',
                'systemVersion': version, 'systemBuild': 'fixture-build', 'capturedAt': utc_now().isoformat(),
                'checks': {name: {'operation': '实际操作', 'result': '观察结果', 'outcome': 'passed'} for name in checks},
                'evidence': captured_fixture('photos')['evidence']}
        return json.dumps({'schemaVersion': 1, 'platforms': platforms}).encode()
    if check == 'feedback-delivery':
        identifier = '00000000-0000-4000-8000-000000000001'
        return json.dumps({'reportID': identifier, 'storageKey': 'report:received:' + identifier,
            'storedReport': {'id': identifier, 'report': {'mode': 'error'}}, 'emailRecipient': 'recipient@example.invalid',
            'emailMessageID': '<receipt@example.invalid>', 'emailBody': '报告编号 ' + identifier}).encode()
    def chunk(kind, content):
        return struct.pack('>I', len(content)) + kind + content + struct.pack('>I', zlib.crc32(kind + content))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(b'\0\0\0\0')) + chunk(b'IEND', b'')


def captured_fixture(check: str, provenance: dict | None = None) -> dict:
    data = evidence_fixture(check)
    if check == 'distribution-signing' and provenance is not None:
        proof = json.loads(data)
        proof['archiveProvenance'] = provenance
        data = json.dumps(proof).encode()
    path = Path('/evidence/' + check)
    original = Path.open
    with patch.object(Path, 'open', lambda value, *args, **kwargs: BytesIO(data) if value == path else original(value, *args, **kwargs)):
        return capture('实际操作', '观察结果', path, check, 'passed', utc_now().isoformat())


def run_self_test() -> None:
    from validation_media import run_probe
    assert run_probe(b'', self_test=True)
    from validation_media import decode_probe
    with patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('fixture', 30)), patch.object(Path, 'unlink') as cleanup:
        assert not decode_probe(Path('/fixture/evidence-media-probe'), [], b'data')
        cleanup.assert_called_once_with(missing_ok=True)
    from validation_manual import artifact_complete
    with patch('validation_manual.MAXIMUM_ATTACHMENT_BYTES', 16), patch.object(Path, 'open', return_value=BytesIO(b'x' * 17)), \
            patch('validation_manual.media_complete') as decoder:
        try: capture('操作', '结果', Path('/fixture'), 'photos', 'passed', utc_now().isoformat())
        except ValueError: pass
        else: raise AssertionError('附件读取需要字节预算')
        decoder.assert_not_called()
        with patch('validation_manual.base64.b64decode') as decode:
            assert not artifact_complete({'byteCount': 17, 'dataBase64': 'x' * 24}, 'photos')
            assert not artifact_complete({'byteCount': 16, 'dataBase64': 'x' * 25}, 'photos')
            decode.assert_not_called()
    for malformed in (bytes.fromhex('ffd8ffffd9'), b'%PDF-\n%%EOF', b'\0\0\0\x18ftypisom\0\0\0\0moov'):
        assert not evidence_content_complete('widget', malformed)
    contracts, report = distribution_fixture()
    assert len(contracts) == 4 and distribution.distribution_complete(report, contracts)
    for index, row in enumerate(report['bundles']):
        for key, value in [('signatureVerified', False), ('version', '0.0.0'), ('build', '0'), ('team', 'other'),
                ('containerIdentifier', 'wrong'), ('sha256', 'invalid'), ('executableUUIDs', [])]:
            if key == 'containerIdentifier' and not row['containerIdentifier']: continue
            changed = copy.deepcopy(report)
            changed['bundles'][index][key] = value
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        for key, value in [('get-task-allow', True), ('com.apple.developer.team-identifier', 'other'),
                ('application-identifier', 'wrong'), ('com.apple.security.application-groups', [])]:
            changed = copy.deepcopy(report)
            changed['bundles'][index]['entitlements'][key] = value
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        if 'com.apple.developer.icloud-services' in row['entitlements']:
            changed = copy.deepcopy(report)
            changed['bundles'][index]['entitlements']['com.apple.developer.icloud-container-environment'] = 'Development'
            assert not distribution.distribution_complete(changed, contracts)
    assert not distribution.distribution_complete(report | {'verifiedAt': '2000-01-01T00:00:00+00:00'}, contracts)
    assert not distribution.distribution_complete(report | {'bundles': report['bundles'][:-1]}, contracts)
    assert not distribution.distribution_complete(report | {'bundles': [1]}, contracts)
    main = next(row for row in report['bundles'] if not row['containerIdentifier'])
    root = Path('/export/Payload/BIT101-iOS.app')
    paths = {main['identifier']: root}
    for row in report['bundles']:
        if row is main: continue
        if not contracts[row['identifier']]['extension']: paths[row['identifier']] = root / 'Watch' / 'Watch.app'
    for row in report['bundles']:
        if contracts[row['identifier']]['extension']: paths[row['identifier']] = paths[row['containerIdentifier']] / 'PlugIns' / (row['identifier'] + '.appex')
    by_path = {path: next(row for row in report['bundles'] if row['identifier'] == identifier) for identifier, path in paths.items()}
    def read(path):
        row = by_path[path.parent]
        return plistlib.dumps({'CFBundleIdentifier': row['identifier'], 'CFBundleShortVersionString': row['version'],
            'CFBundleVersion': row['build'], 'WKCompanionAppBundleIdentifier': row['companionIdentifier'], 'CFBundleExecutable': 'application',
            'BIT101ArchiveInputDigest': report['archiveProvenance']['inputDigest'], 'BIT101ArchiveRunIdentifier': report['archiveProvenance']['runID']})
    def signed(command, **kwargs):
        path = Path(command[-1])
        if command[:2] == ['xcrun', 'dwarfdump']:
            row = by_path[path.parent]
            return SimpleNamespace(stdout='UUID: ' + row['executableUUIDs'][0]['uuid'] + ' (arm64) application', stderr='')
        row = by_path[path]
        return SimpleNamespace(stdout=plistlib.dumps(row['entitlements']) if '--entitlements' in command else b'', stderr='TeamIdentifier=' + row['team'])
    with patch.object(Path, 'is_dir', return_value=True), patch.object(Path, 'rglob', return_value=list(by_path)[1:]), \
            patch.object(Path, 'read_bytes', read), patch.object(distribution, 'bundle_digest', return_value='a' * 64), \
            patch.object(distribution, 'distribution_contracts', return_value=contracts), patch.object(subprocess, 'run', side_effect=signed) as commands:
        assert distribution.distribution_complete(distribution.inspect_application(root), contracts)
        build = distribution.archive_build_summary(root)
        assert build['archiveProvenance'] == report['archiveProvenance']
        assert build['executables'] == {row['identifier']: row['executableUUIDs'] for row in report['bundles']}
        assert sum('--verify' in call.args[0] and '--deep' in call.args[0] and '--strict' in call.args[0] for call in commands.call_args_list) == 4
        commands.side_effect = subprocess.CalledProcessError(1, 'codesign')
        try: distribution.inspect_application(root)
        except subprocess.CalledProcessError: pass
        else: raise AssertionError('签名验证失败需要传播')
    checks = {}
    for name in MANUAL_DEVICE_CHECKS:
        data = evidence_fixture(name)
        assert evidence_content_complete(name, data)
        assert not evidence_content_complete(name, b'x')
        checks[name] = captured_fixture(name)
    assert complete(checks)
    with patch('validation_manual.MAXIMUM_REPORT_BYTES', 1): assert not complete(checks)
    failed = copy.deepcopy(checks)
    for row in failed.values(): row["outcome"] = "failed"
    assert not complete(failed)
    old = copy.deepcopy(checks)
    for row in old.values(): row["capturedAt"] = "2000-01-01T00:00:00+00:00"
    assert not complete(old)
    missing = copy.deepcopy(checks)
    for row in missing.values(): del row["outcome"]
    assert not complete(missing)
    from validation_manual import distribution_matches_archive
    archive = {'exitCode': 0, 'scope': 'full', 'summary': build, **report['archiveProvenance']}
    assert distribution_matches_archive(checks['distribution-signing'], archive)
    changed = copy.deepcopy(archive)
    changed['inputDigest'] = 'b' * 64
    changed['summary']['archiveProvenance']['inputDigest'] = 'b' * 64
    assert not distribution_matches_archive(checks['distribution-signing'], changed)
    changed = copy.deepcopy(archive)
    changed['summary']['executables'][main['identifier']][0]['uuid'] = str(uuid.uuid4()).upper()
    assert not distribution_matches_archive(checks['distribution-signing'], changed)
    duplicated = {name: copy.deepcopy(checks['photos']) for name in checks}
    assert not complete(duplicated)
    baseline = json.loads(evidence_fixture('minimum-platforms'))
    for platform in baseline['platforms']:
        for key, value in [('systemVersion', '99.0'), ('systemVersion', 'invalid'), ('systemBuild', ''),
                ('deviceIdentifier', ''), ('checks', {}), ('evidence', {}), ('capturedAt', '2000-01-01T00:00:00+00:00')]:
            changed = copy.deepcopy(baseline)
            changed['platforms'][platform][key] = value
            assert not evidence_content_complete('minimum-platforms', json.dumps(changed).encode()), (platform, key)
    failed_baseline = copy.deepcopy(baseline)
    next(iter(failed_baseline['platforms']['iOS']['checks'].values()))['outcome'] = 'failed'
    assert not evidence_content_complete('minimum-platforms', json.dumps(failed_baseline).encode())
    feedback = json.loads(evidence_fixture('feedback-delivery'))
    for field in feedback:
        changed = dict(feedback)
        del changed[field]
        assert not evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    feedback['storageKey'] = 'smoke:temporary'
    assert not evidence_content_complete('feedback-delivery', json.dumps(feedback).encode())
