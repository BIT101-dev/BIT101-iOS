"""Contracts for physical observations and final distribution signature evidence."""
import copy
import json
from pathlib import Path
import plistlib
import struct
import subprocess
from types import SimpleNamespace
from unittest.mock import patch
import zlib
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
            'containerIdentifier': max(parents, key=len) if parents else '', 'companionIdentifier': main if identifier != main and not value['extension'] else ''})
    return contracts, {'schemaVersion': 1, 'verifiedAt': utc_now().isoformat(), 'bundles': rows}


def evidence_fixture(check: str) -> bytes:
    if check == 'distribution-signing': return json.dumps(distribution_fixture()[1]).encode()
    if check == 'feedback-delivery':
        identifier = '00000000-0000-4000-8000-000000000001'
        return json.dumps({'reportID': identifier, 'storageKey': 'report:received:' + identifier,
            'storedReport': {'id': identifier, 'report': {'mode': 'error'}}, 'emailRecipient': 'recipient@example.invalid',
            'emailMessageID': '<receipt@example.invalid>', 'emailBody': '报告编号 ' + identifier}).encode()
    def chunk(kind, content):
        return struct.pack('>I', len(content)) + kind + content + struct.pack('>I', zlib.crc32(kind + content))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(b'\0\0\0\0')) + chunk(b'IEND', b'')


def captured_fixture(check: str) -> dict:
    data = evidence_fixture(check)
    path = Path('/evidence/' + check)
    original = Path.read_bytes
    with patch.object(Path, 'read_bytes', lambda value: data if value == path else original(value)):
        return capture('实际操作', '观察结果', path, check)


def run_self_test() -> None:
    contracts, report = distribution_fixture()
    assert len(contracts) == 4 and distribution.distribution_complete(report, contracts)
    for index, row in enumerate(report['bundles']):
        for key, value in [('signatureVerified', False), ('version', '0.0.0'), ('build', '0'), ('team', 'other'),
                ('containerIdentifier', 'wrong'), ('sha256', 'invalid')]:
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
            'CFBundleVersion': row['build'], 'WKCompanionAppBundleIdentifier': row['companionIdentifier']})
    def signed(command, **kwargs):
        row = by_path[Path(command[-1])]
        return SimpleNamespace(stdout=plistlib.dumps(row['entitlements']) if '--entitlements' in command else b'', stderr='TeamIdentifier=' + row['team'])
    with patch.object(Path, 'is_dir', return_value=True), patch.object(Path, 'rglob', return_value=list(by_path)[1:]), \
            patch.object(Path, 'read_bytes', read), patch.object(distribution, 'bundle_digest', return_value='a' * 64), \
            patch.object(distribution, 'distribution_contracts', return_value=contracts), patch.object(subprocess, 'run', side_effect=signed) as commands:
        assert distribution.distribution_complete(distribution.inspect_application(root), contracts)
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
    duplicated = {name: copy.deepcopy(checks['photos']) for name in checks}
    assert not complete(duplicated)
    feedback = json.loads(evidence_fixture('feedback-delivery'))
    for field in feedback:
        changed = dict(feedback)
        del changed[field]
        assert not evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    feedback['storageKey'] = 'smoke:temporary'
    assert not evidence_content_complete('feedback-delivery', json.dumps(feedback).encode())
