"""Contracts for physical observations and final distribution signature evidence."""
from contextlib import nullcontext
import copy
import base64
import hashlib
from datetime import timedelta
from io import BytesIO
import json
from pathlib import Path
import plistlib
import struct
import subprocess
from types import SimpleNamespace
from unittest.mock import patch
from validation_performance_tests import source_identity_fixture
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
            'entitlements': entitlements, 'signatureVerified': True,
            'compilationConditions': [], 'testHostMarkers': [],
            'sha256': hashlib.sha256(('executable:' + identifier).encode()).hexdigest(), 'bundleSHA256': 'b' * 64,
            'privacyManifestDigest': distribution.privacy_manifest_digest(distribution.ROOT / 'BIT101-iOS'),
            'platform': 'watchos' if value['platform'] == 'watchOS' else 'iphoneos',
            'supportedPlatforms': ['WatchOS' if value['platform'] == 'watchOS' else 'iPhoneOS'],
            'minimumOSVersion': value['minimumOSVersion'],
            'provisioningProfile': {'uuid': str(uuid.uuid5(uuid.NAMESPACE_URL, identifier)),
                'teamIdentifiers': [value['team']], 'entitlements': entitlements | {'beta-reports-active': True},
                'expirationDate': (utc_now() + timedelta(days=1)).isoformat(),
                'hasProvisionedDevices': False, 'provisionsAllDevices': False},
            'executableUUIDs': [{'architecture': 'arm64', 'uuid': str(uuid.uuid5(uuid.NAMESPACE_URL, identifier)).upper()}],
            'containerIdentifier': max(parents, key=len) if parents else '', 'companionIdentifier': main if identifier != main and not value['extension'] else ''})
    return contracts, {'schemaVersion': 1, 'verifiedAt': utc_now().isoformat(),
        'archiveProvenance': {'inputDigest': 'a' * 64, 'runID': 'fixture-run'}, 'bundles': rows}


def captured_media_fixture() -> dict:
    data = evidence_fixture('_media')
    return {'path': '/evidence/media',
        'byteCount': len(data), 'dataBase64': base64.b64encode(data).decode()}


def evidence_fixture(check: str) -> bytes:
    from validation_manual import MANUAL_SCENARIOS
    from validation_test_areas import manual_capabilities
    def observations(scenario):
        return {name: {'operation': '实际调用', 'result': '观察响应', 'outcome': 'passed'}
            for name in manual_capabilities(check, scenario)}
    if check in MANUAL_SCENARIOS:
        scenarios = {name: {'operation': '实际操作', 'result': '观察结果', 'outcome': 'passed',
            'capturedAt': utc_now().isoformat(), 'evidence': captured_media_fixture(),
            'capabilities': observations(name)} for name in MANUAL_SCENARIOS[check]}
        if check == 'ipad-layout':
            for name, size in [('portrait', (768, 1024)), ('landscape', (1024, 768)), ('split-view', (512, 768)), ('resize', (640, 768))]:
                scenarios[name]['windowSize'] = dict(zip(('width', 'height'), size))
            scenarios['split-view']['screenWidth'] = 1024
            scenarios['resize']['previousWindowSize'] = {'width': 512, 'height': 768}
        if check != 'performance-baseline':
            from validation_compilation import compilation_settings
            from validation_provenance import source_digest
            contract = next((identifier, row) for identifier, row in distribution.distribution_contracts().items()
                if row['platform'] == ('watchOS' if check == 'watch' else 'iOS') and not row['extension'])
            identifier, row = contract
            bundle = next(value for value in distribution_fixture()[1]['bundles'] if value['identifier'] == identifier)
            desktop = check == 'catalyst-desktop'
            platform = 'macCatalyst' if desktop else 'watchOS' if check == 'watch' else 'iOS'
            minimum = compilation_settings('macOS' if desktop else platform)[1]
            if desktop:
                scenarios['window-resize'].update(windowSize={'width': 1024, 'height': 768}, previousWindowSize={'width': 800, 'height': 600})
                for name, actions in {'menu-actions': ('app-menu', 'window-menu'), 'keyboard-navigation': ('tab', 'return', 'escape'),
                        'permission-dialogs': ('photos', 'calendar', 'notifications')}.items():
                    scenarios[name]['actions'] = {action: {'operation': '实际操作', 'result': '观察结果', 'outcome': 'passed'} for action in actions}
            return json.dumps({'schemaVersion': 1, 'platform': platform,
                'deviceIdentifier': 'fixture-mac' if desktop else 'fixture-pad', 'deviceModel': 'Mac' if desktop else 'iPad', 'deviceFamily': 'iPad',
                'systemVersion': minimum, 'systemBuild': 'fixture-build', 'inputDigest': source_digest('manual-device', environment={}),
                'application': {'identifier': identifier, 'version': row['version'], 'build': row['build'], 'configuration': 'Release',
                    'testHostMarkers': [], 'minimumOSVersion': minimum, 'sha256': 'a' * 64 if desktop else bundle['sha256'],
                    **({} if desktop else {'distributionChannel': 'testflight'}),
                    'executableUUIDs': bundle['executableUUIDs']},
                'scenarios': scenarios}).encode()
        if check == 'performance-baseline':
            from validation_manual import PERFORMANCE_WORKLOADS, performance_group
            from validation_policy import workflow_conditions
            for name, row in scenarios.items():
                test, workload = PERFORMANCE_WORKLOADS[name]
                group = performance_group(test)
                current = {'testIdentifier': test, 'sourceCommit': 'a' * 40, 'input': workload, 'capturedAt': row['capturedAt'],
                    'environment': {'deviceIdentifier': 'fixture-phone', 'deviceModel': 'iPhone', 'systemVersion': '26.0',
                        'systemBuild': 'fixture', 'xcodeBuild': 'fixture', 'configuration': 'Release', 'compilerVersion': 'a' * 64,
                        'compilationConditions': ['DEBUG', 'BIT101_AUTOMATED_TESTING']},
                    'resultBundle': {'path': '.build/extended-automation/test-results.xcresult', 'identity': 'a' * 64},
                    'metrics': {'clockSeconds': {'samples': [0.1] * 10, 'mean': 0.1},
                        'peakPhysicalMemoryBytes': {'samples': [1024] * 10, 'mean': 1024}}}
                from validation_performance import current_commit
                from validation_provenance import source_digest
                context = {'host': {'system': 'fixture'}, 'developer': '/fixture',
                    'xcode': {'DTXcodeBuild': 'fixture'}, 'compiler': {'modified': 1, 'size': 1, 'version': 'a' * 64},
                    'sdks': {'iPhoneOS': {'Version': '26.0'}},
                    'device': {'identifier': 'fixture-phone', 'model': 'iPhone', 'systemVersion': '26.0', 'systemBuild': 'fixture'}}
                current['sourceCommit'] = current_commit()
                current['environment']['compilationConditions'] = sorted(workflow_conditions(group))
                from validation_performance import normalize_metrics
                current['execution'] = {'group': group, 'runID': 'fixture-run', 'environment': context,
                    'sourceCommit': current['sourceCommit'], 'inputDigest': source_digest(group, environment=context), 'bundleIdentity': 'a' * 64}
                current['xcresultMetrics'] = [{'testIdentifier': test + '()', 'testRuns': [{'device': {'deviceId': 'fixture-phone'},
                    'metrics': [{'identifier': 'com.apple.dt.XCTMetric_Clock.time.monotonic', 'unitOfMeasurement': 's', 'measurements': [0.1] * 10},
                        {'identifier': 'com.apple.dt.XCTMetric_Memory.physical_peak', 'unitOfMeasurement': 'kB', 'measurements': [1.024] * 10}]}]}]
                current['metrics'] = normalize_metrics(current['xcresultMetrics'], test, 'fixture-phone')
                baseline = copy.deepcopy(current)
                baseline.update(capturedAt=(utc_now() - timedelta(days=1)).isoformat(), approvedAt=(utc_now() - timedelta(hours=1)).isoformat(), approvedBy='maintainer')
                baseline['resultBundle']['identity'] = 'b' * 64
                baseline['execution']['bundleIdentity'] = 'b' * 64
                for metric in baseline['metrics'].values(): metric['maximumRegressionPercent'] = 10
                row['measurement'] = {'current': current, 'baseline': baseline}
        return json.dumps({'schemaVersion': 1, 'deviceFamily': 'iPad', 'deviceIdentifier': 'fixture-pad', 'scenarios': scenarios}).encode()
    if check == 'distribution-signing': return json.dumps(distribution_fixture()[1]).encode()
    if check == 'minimum-platforms':
        from validation_manual import BASELINE_CHECKS
        contracts = distribution.distribution_contracts()
        bundles = distribution_fixture()[1]['bundles']
        platforms = {}
        for platform, checks in BASELINE_CHECKS.items():
            version = max((value['minimumOSVersion'] for value in contracts.values() if value['platform'] == platform),
                key=distribution.minimum_os_version)
            platforms[platform] = {'deviceIdentifier': platform + '-fixture', 'deviceModel': platform + '-device',
                'systemVersion': version, 'systemBuild': 'fixture-build', 'capturedAt': utc_now().isoformat(),
                'installedBundles': [{key: bundle[key] for key in ('identifier', 'version', 'build', 'sha256', 'executableUUIDs')} | {'distributionChannel': 'testflight'}
                    for bundle in bundles if contracts[bundle['identifier']]['platform'] == platform],
                'checks': {name: {'operation': '实际操作', 'result': '观察结果', 'outcome': 'passed'} for name in checks},
                'evidence': captured_media_fixture()}
        return json.dumps({'schemaVersion': 1, 'platforms': platforms}).encode()
    if check == 'feedback-delivery':
        from email.utils import format_datetime
        identifier = '00000000-0000-4000-8000-000000000001'
        received_time = utc_now()
        received = received_time.isoformat()
        configuration = json.loads((Path(__file__).resolve().parents[1] / 'Cloudflare/ErrorReportWorker/wrangler.jsonc').read_text())
        recipient = next(binding['destination_address'] for binding in configuration['send_email'] if binding['name'] == 'REPORT_EMAIL')
        return json.dumps({'reportID': identifier, 'storageKey': 'report:' + received + ':' + identifier, 'capabilities': observations('delivery'),
            'storedReport': {'id': identifier, 'receivedAt': received,
                'report': {'mode': 'sanitized', 'isDevelopmentBuild': False, 'errorTitle': 'fixture', 'errorMessage': 'fixture failure'},
                'emailDelivery': {'status': 'sent', 'attempts': 1, 'messageID': 'provider-fixture'}}, 'emailRecipient': recipient,
            'emailHeaders': {'To': recipient, 'Message-ID': '<receipt@example.invalid>', 'X-BIT101-Report-ID': identifier,
                'Date': format_datetime(received_time)},
            'emailMessageID': '<receipt@example.invalid>', 'emailBody': '报告编号：' + identifier + '\n接收时间：' + received}).encode()
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
    with patch.object(Path, 'open', lambda value, *args, **kwargs: BytesIO(data) if value == path else original(value, *args, **kwargs)), patch('validation_performance.validate_capture'):
        return capture('实际操作', '观察结果', path, check, 'passed', utc_now().isoformat())


@patch('validation_provenance._local_source_identity', new=source_identity_fixture())
def registration_self_test(subject) -> None:
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import sys
    checks = {name: captured_fixture(name) for name in MANUAL_DEVICE_CHECKS}
    state = {'groups': {'manual-device': {'summary': {'checks': checks}}}}
    environment = {'device': {'identifier': 'phone'}}
    original_read, original_is_file = Path.read_text, Path.is_file
    def save(report): state.update(copy.deepcopy(report))
    with patch.object(subject, 'report_lock', side_effect=nullcontext), \
            patch.object(subject, 'environment_context', return_value=environment), \
            patch('validation_provenance.environment_context', return_value=environment), \
            patch.object(subject, 'complete_environment', return_value=True), \
            patch.object(Path, 'is_file', lambda path: path == subject.REPORT or original_is_file(path)), \
            patch.object(Path, 'read_text', lambda path, *args, **kwargs: json.dumps(state)
                if path == subject.REPORT else original_read(path, *args, **kwargs)), \
            patch.object(subject, 'write_report', side_effect=save), \
            patch('validation_manual.capture', return_value=checks['photos']), \
            patch.object(sys, 'argv', ['evidence', 'manual', 'photos', '--evidence', '/fixture']), redirect_stderr(StringIO()):
        state['groups']['manual-device']['inputDigest'] = subject.source_digest('manual-device')
        assert subject.main() == 0
        original_digest = state['groups']['manual-device']['inputDigest']
        original_restore = subject.source_digest('restore')
        environment['device'] = {'identifier': 'tablet', 'systemVersion': 'other', 'systemBuild': 'other-build'}
        assert subject.source_digest('manual-device') == original_digest
        assert subject.source_digest('restore') != original_restore
        assert subject.main() == 0
        assert set(state['groups']['manual-device']['summary']['checks']) == set(checks)
        assert state['groups']['manual-device']['environment']['device']['identifier'] == 'tablet'
        row = state['groups']['manual-device']
        assert str(uuid.UUID(row['runID'])) == row['runID']
        with patch.object(sys, 'argv', ['evidence', 'check-group', 'manual-device']):
            assert subject.main() == 0
            for field, value in [('runID', ''), ('exitCode', 2), ('inputDigest', 'stale')]:
                original = row[field]
                row[field] = value
                assert subject.main() == 1
                row[field] = original
        environment['xcode'] = {'version': 'changed-toolchain'}
        assert subject.main() == 0
        assert state['groups']['manual-device']['inputDigest'] != original_digest
        assert set(state['groups']['manual-device']['summary']['checks']) == {'photos'}
        assert state['groups']['manual-device']['summary']['passed'] is False


def manual_artifact_encoding_self_test() -> None:
    from validation_manual import artifact_bytes, artifact_complete
    raw = evidence_fixture('photos')
    path = Path('/evidence/encoding')
    original_open = Path.open
    with patch.object(Path, 'open', lambda selected, *args, **kwargs: BytesIO(raw) if selected == path else original_open(selected, *args, **kwargs)):
        observation = capture('实际操作', '观察结果', path, 'photos', 'passed', utc_now().isoformat())
    artifact = observation['evidence']
    assert artifact['dataUTF8'].encode() == raw and 'dataBase64' not in artifact
    assert artifact_bytes(artifact) == raw
    assert artifact_complete(artifact, 'photos', observed_at=observation['capturedAt'])
    media = captured_media_fixture()
    assert 'dataUTF8' not in media and artifact_bytes(media) == evidence_fixture('_media')
    assert artifact_complete(media, 'photos', media_only=True)
    binary = dict(artifact)
    binary.pop('dataUTF8')
    binary['dataBase64'] = base64.b64encode(raw).decode()
    assert artifact_complete(binary, 'photos', observed_at=observation['capturedAt'])
    assert len(json.dumps(artifact)) < len(json.dumps(binary))
    for altered in (dict(artifact, dataBase64=binary['dataBase64']), dict(artifact, dataUTF8='altered'),
            dict(artifact, byteCount=artifact['byteCount'] + 1),
            dict(artifact, dataUTF8='\ud800')):
        assert not artifact_complete(altered, 'photos', observed_at=observation['capturedAt'])
    with patch('validation_manual.MAXIMUM_ATTACHMENT_BYTES', len(raw) - 1):
        assert not artifact_complete(artifact, 'photos', observed_at=observation['capturedAt'])
    with patch('validation_manual.MAXIMUM_REPORT_BYTES', 1): assert not complete({'photos': observation})


@patch('validation_provenance.source_digest', side_effect=lambda group='', *, environment=None: json.dumps([group, environment], sort_keys=True))
def run_self_test(_source_identity) -> None:
    manual_artifact_encoding_self_test()
    application = Path('/identity/BIT101-iOS.app')
    info = {'CFBundleIdentifier': 'BIT101-dev.BIT101-iOS', 'CFBundleShortVersionString': '1.0',
        'CFBundleVersion': '1', 'CFBundleExecutable': 'BIT101-iOS'}
    executable = application / 'Contents/MacOS/BIT101-iOS'
    output = f'UUID: 00000000-0000-4000-8000-000000000001 (arm64) {executable}'
    with patch.object(Path, 'read_bytes', side_effect=lambda: b'executable'), \
            patch.object(distribution.plistlib, 'loads', return_value=info), \
            patch.object(distribution.subprocess, 'check_output', return_value=output) as uuids:
        identity = distribution.catalyst_application_identity(application)
        assert identity == {'identifier': info['CFBundleIdentifier'], 'version': '1.0', 'build': '1',
            'sha256': distribution.hashlib.sha256(b'executable').hexdigest(),
            'executableUUIDs': [{'architecture': 'arm64', 'uuid': '00000000-0000-4000-8000-000000000001'}]}
        assert uuids.call_args.args[0] == ['xcrun', 'dwarfdump', '--uuid', str(executable)]
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
    metadata = {'BIT101WorkflowConditions': '', 'CFBundleExecutable': 'application'}
    with patch.object(Path, 'read_bytes', return_value=b'production'):
        assert distribution.production_build_metadata(Path('/app'), metadata) == {'compilationConditions': [], 'testHostMarkers': []}
        for conditions in (None, 'DEBUG', 'RELEASE_NETWORK_SMOKE'):
            try: distribution.production_build_metadata(Path('/app'), dict(metadata, BIT101WorkflowConditions=conditions))
            except ValueError: pass
            else: raise AssertionError(conditions)
    for marker in ('behavior-test-host', 'release-network-smoke-host', 'icloud-cross-device-smoke-host',
            'The UI automation App requires its isolated launch configuration'):
        with patch.object(Path, 'read_bytes', return_value=marker.encode()):
            try: distribution.production_build_metadata(Path('/app'), metadata)
            except ValueError: pass
            else: raise AssertionError(marker)
    assert len(contracts) == 4 and distribution.distribution_complete(report, contracts)
    with patch.object(Path, 'read_text', return_value='const AASA = { appID: "OLD.BIT101-dev.BIT101-iOS" };'):
        assert not distribution.distribution_complete(report, contracts)
    for index, row in enumerate(report['bundles']):
        for key, value in [('signatureVerified', False), ('version', '0.0.0'), ('build', '0'), ('team', 'other'),
                ('containerIdentifier', 'wrong'), ('sha256', 'invalid'), ('bundleSHA256', None), ('bundleSHA256', 'invalid'), ('executableUUIDs', []),
                ('privacyManifestDigest', None), ('privacyManifestDigest', 'a' * 64)]:
            if key == 'containerIdentifier' and not row['containerIdentifier']: continue
            changed = copy.deepcopy(report)
            changed['bundles'][index][key] = value
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        for key, value in [('compilationConditions', ['DEBUG']), ('testHostMarkers', ['behavior-test-host'])]:
            changed = copy.deepcopy(report)
            changed['bundles'][index][key] = value
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        for key, value in [('platform', 'macosx'), ('supportedPlatforms', ['iPhoneSimulator']),
                ('minimumOSVersion', '99.0'), ('minimumOSVersion', None), ('provisioningProfile', None)]:
            changed = copy.deepcopy(report)
            changed['bundles'][index][key] = value
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        for key, value in [('uuid', 'invalid'), ('teamIdentifiers', ['other']), ('hasProvisionedDevices', True),
                ('provisionsAllDevices', True), ('expirationDate', utc_now().isoformat()), ('expirationDate', 'invalid')]:
            changed = copy.deepcopy(report)
            changed['bundles'][index]['provisioningProfile'][key] = value
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        for key, value in [('application-identifier', 'wrong'), ('com.apple.developer.team-identifier', 'other'),
                ('beta-reports-active', False), ('get-task-allow', True)]:
            changed = copy.deepcopy(report)
            changed['bundles'][index]['provisioningProfile']['entitlements'][key] = value
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        for key, value in [('get-task-allow', True), ('com.apple.developer.team-identifier', 'other'),
                ('application-identifier', 'wrong'), ('com.apple.security.application-groups', [])]:
            changed = copy.deepcopy(report)
            changed['bundles'][index]['entitlements'][key] = value
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        for key in row['entitlements']:
            changed = copy.deepcopy(report)
            changed['bundles'][index]['provisioningProfile']['entitlements'].pop(key)
            assert not distribution.distribution_complete(changed, contracts), (index, key)
        if 'com.apple.developer.icloud-services' in row['entitlements']:
            changed = copy.deepcopy(report)
            changed['bundles'][index]['entitlements']['com.apple.developer.icloud-container-environment'] = 'Development'
            assert not distribution.distribution_complete(changed, contracts)
    assert not distribution.distribution_complete(report | {'verifiedAt': '2000-01-01T00:00:00+00:00'}, contracts)
    for allowed, claimed, expected in [(['*'], ['applinks:example.invalid'], True),
            (['TEAM.*'], ['TEAM.app', 'OTHER.app'], False), ('TEAM.*', 'TEAM.app', True),
            (['CloudKit'], ['CloudKit'], True), (False, 0, False), (['group.app'], ['group.other'], False)]:
        assert distribution.profile_entitlement_allows(allowed, claimed) == expected
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
    privacy_bytes = (distribution.ROOT / 'BIT101-iOS/PrivacyInfo.xcprivacy').read_bytes()
    def read(path):
        if path.name == 'PrivacyInfo.xcprivacy': return privacy_bytes
        row = by_path[path.parent]
        if path.name == 'application': return ('executable:' + row['identifier']).encode()
        return plistlib.dumps({'CFBundleIdentifier': row['identifier'], 'CFBundleShortVersionString': row['version'],
            'CFBundleVersion': row['build'], 'WKCompanionAppBundleIdentifier': row['companionIdentifier'], 'CFBundleExecutable': 'application',
            'DTPlatformName': row['platform'], 'CFBundleSupportedPlatforms': row['supportedPlatforms'], 'MinimumOSVersion': row['minimumOSVersion'],
            'BIT101WorkflowConditions': '', 'BIT101ArchiveInputDigest': report['archiveProvenance']['inputDigest'], 'BIT101ArchiveRunIdentifier': report['archiveProvenance']['runID']})
    def signed(command, **kwargs):
        path = Path(command[-1])
        if command[:3] == ['security', 'cms', '-D']:
            profile = by_path[path.parent]['provisioningProfile']
            payload = {'UUID': profile['uuid'], 'TeamIdentifier': profile['teamIdentifiers'], 'Entitlements': profile['entitlements'],
                'ExpirationDate': distribution.datetime.fromisoformat(profile['expirationDate']).replace(tzinfo=None)}
            if profile['hasProvisionedDevices']: payload['ProvisionedDevices'] = ['device']
            if profile['provisionsAllDevices']: payload['ProvisionsAllDevices'] = True
            return SimpleNamespace(stdout=plistlib.dumps(payload))
        if command[:2] == ['xcrun', 'dwarfdump']:
            row = by_path[path.parent]
            return SimpleNamespace(stdout='UUID: ' + row['executableUUIDs'][0]['uuid'] + ' (arm64) application', stderr='')
        row = by_path[path]
        return SimpleNamespace(stdout=plistlib.dumps(row['entitlements']) if '--entitlements' in command else b'', stderr='TeamIdentifier=' + row['team'])
    with patch.object(Path, 'is_dir', return_value=True), patch.object(Path, 'rglob', return_value=list(by_path)[1:]), \
            patch.object(Path, 'read_bytes', read), patch.object(distribution, 'bundle_digest', return_value='b' * 64), \
            patch.object(distribution, 'distribution_contracts', return_value=contracts), patch.object(subprocess, 'run', side_effect=signed) as commands:
        collected_distribution = distribution.inspect_application(root)
        assert distribution.distribution_complete(collected_distribution, contracts)
        for row in collected_distribution['bundles']:
            expected = next(value for value in report['bundles'] if value['identifier'] == row['identifier'])
            assert row['sha256'] == expected['sha256'] and row['sha256'] != row['bundleSHA256']
        build = distribution.archive_build_summary(root)
        assert build['archiveProvenance'] == report['archiveProvenance']
        assert build['executables'] == {row['identifier']: row['executableUUIDs'] for row in report['bundles']}
        assert build['privacyManifests'] == {row['identifier']: row['privacyManifestDigest'] for row in report['bundles']}
        assert sum('--verify' in call.args[0] and '--deep' in call.args[0] and '--strict' in call.args[0] for call in commands.call_args_list) == 4
        assert sum(call.args[0][:3] == ['security', 'cms', '-D'] for call in commands.call_args_list) == 4
        altered = plistlib.loads(privacy_bytes)
        altered['NSPrivacyAccessedAPITypes'][0]['NSPrivacyAccessedAPITypeReasons'] = []
        for bundle in by_path:
            manifest_path = bundle / 'PrivacyInfo.xcprivacy'
            for value in (None, b'invalid plist', b'<?xml version="1.0"?><plist><dict>', plistlib.dumps(altered)):
                def corrupt(path):
                    if path != manifest_path: return read(path)
                    if value is None: raise FileNotFoundError(path)
                    return value
                with patch.object(Path, 'read_bytes', side_effect=corrupt, autospec=True):
                    for inspect in (distribution.archive_build_summary, distribution.inspect_application):
                        try: inspect(root)
                        except ValueError: pass
                        else: raise AssertionError(f'归档及分发需要验收实际隐私清单：{bundle}')
            with patch.object(Path, 'read_bytes', side_effect=lambda path: plistlib.dumps(plistlib.loads(privacy_bytes),
                    fmt=plistlib.FMT_BINARY) if path == manifest_path else read(path), autospec=True):
                assert distribution.archive_build_summary(root)['privacyManifests'][by_path[bundle]['identifier']] == by_path[bundle]['privacyManifestDigest']
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
    for check in ('system-autofill', 'photos', 'calendar-permissions', 'location-permissions', 'notifications', 'external-handoff', 'widget', 'watch'):
        assert not evidence_content_complete(check, evidence_fixture('_media')), check
    assert complete(checks)
    from validation_manual import scenarios_match_distribution, baseline_matches_distribution
    collected_observation = copy.deepcopy(checks['distribution-signing'])
    encoded = json.dumps(collected_distribution).encode()
    collected_observation['evidence'].update(dataUTF8=encoded.decode(),
        byteCount=len(encoded), sha256=hashlib.sha256(encoded).hexdigest())
    assert scenarios_match_distribution(checks, collected_observation)
    assert baseline_matches_distribution(checks['minimum-platforms'], collected_observation)
    receipt = json.loads(evidence_fixture('feedback-delivery'))
    assert not evidence_content_complete('feedback-delivery', json.dumps(receipt).encode(),
        observed_at=(utc_now() - timedelta(hours=1)).isoformat())
    from email.utils import format_datetime
    for moment in (utc_now() - timedelta(days=2), utc_now() + timedelta(days=1)):
        changed = copy.deepcopy(receipt)
        received = moment.isoformat()
        changed['storedReport']['receivedAt'] = received
        changed['storageKey'] = 'report:' + received + ':' + changed['reportID']
        changed['emailBody'] = '报告编号：' + changed['reportID'] + '\n接收时间：' + received
        changed['emailHeaders']['Date'] = format_datetime(moment)
        assert not evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    for date in (format_datetime(utc_now() - timedelta(days=2)), format_datetime(utc_now() + timedelta(days=1)), 'invalid'):
        changed = copy.deepcopy(receipt)
        changed['emailHeaders']['Date'] = date
        assert not evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    changed = copy.deepcopy(receipt)
    changed['emailHeaders']['Date'] = changed['emailHeaders']['Date'].replace('+0000', '-0000')
    assert evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    for key, value in [('status', 'pending'), ('status', 'failed'), ('attempts', 0), ('messageID', '')]:
        changed = copy.deepcopy(receipt)
        changed['storedReport']['emailDelivery'][key] = value
        assert not evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    for location, key, value in [('emailHeaders', 'To', 'different@example.invalid'),
            ('emailHeaders', 'Message-ID', '<other@example.invalid>'), ('emailHeaders', 'X-BIT101-Report-ID', str(uuid.uuid4())),
            ('report', 'mode', 'error'), ('report', 'errorTitle', ''), ('report', 'isDevelopmentBuild', True)]:
        changed = copy.deepcopy(receipt)
        (changed['storedReport']['report'] if location == 'report' else changed[location])[key] = value
        assert not evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    for key, value in [('emailRecipient', 'different@example.invalid'), ('emailBody', receipt['reportID'])]:
        changed = dict(receipt, **{key: value})
        assert not evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    changed = copy.deepcopy(receipt)
    changed['storedReport']['report'] = {}
    assert not evidence_content_complete('feedback-delivery', json.dumps(changed).encode())
    from validation_manual import scenario_complete, MANUAL_SCENARIOS
    for check in ('system-autofill', 'photos', 'calendar-permissions', 'location-permissions', 'notifications', 'external-handoff', 'widget', 'watch'):
        assert len(MANUAL_SCENARIOS[check]) >= 2 and 'observation' not in MANUAL_SCENARIOS[check]
        proof = json.loads(evidence_fixture(check))
        proof['scenarios'] = {'observation': next(iter(proof['scenarios'].values()))}
        assert not scenario_complete(check, proof)
    for check in MANUAL_SCENARIOS:
        proof = json.loads(evidence_fixture(check))
        for name in proof['scenarios']:
            changed = copy.deepcopy(proof)
            del changed['scenarios'][name]
            assert not scenario_complete(check, changed)
            for key, value in [('outcome', 'failed'), ('evidence', {}), ('capturedAt', '2000-01-01T00:00:00+00:00')]:
                changed = copy.deepcopy(proof)
                changed['scenarios'][name][key] = value
                assert not scenario_complete(check, changed)
            for capability in proof['scenarios'][name]['capabilities']:
                for fault in ('missing', 'failed', 'empty'):
                    changed = copy.deepcopy(proof)
                    observations = changed['scenarios'][name]['capabilities']
                    if fault == 'missing': del observations[capability]
                    elif fault == 'failed': observations[capability]['outcome'] = 'failed'
                    else: observations[capability]['result'] = ''
                    assert not scenario_complete(check, changed)
    from validation_test_areas import NETWORK_CAPABILITIES, MANUAL_CAPABILITY_SCENARIOS
    profile = json.loads(evidence_fixture('profile-writes'))
    owner = 'BIT101-iOS.SettingsNetworkService'
    with patch.dict(NETWORK_CAPABILITIES[owner], {'newProfileWrite()': 'profile-writes'}), \
            patch.dict(MANUAL_CAPABILITY_SCENARIOS[owner], {'newProfileWrite()': 'nickname-save'}):
        assert not scenario_complete('profile-writes', profile)
    feedback = json.loads(evidence_fixture('feedback-delivery'))
    feedback.pop('capabilities')
    assert not evidence_content_complete('feedback-delivery', json.dumps(feedback).encode())
    performance = json.loads(evidence_fixture('performance-baseline'))
    for name, row in performance['scenarios'].items():
        changed = copy.deepcopy(performance)
        del changed['scenarios'][name]['measurement']
        assert not scenario_complete('performance-baseline', changed)
        from validation_manual import performance_comparison_complete
        measurement = row['measurement']
        for field, value in [('deviceIdentifier', 'other-phone'), ('configuration', 'Debug'), ('compilerVersion', '')]:
            changed = copy.deepcopy(measurement)
            changed['current']['environment'][field] = value
            assert not performance_comparison_complete(name, changed)
        for field, value in [('sourceCommit', 'invalid'), ('input', {}), ('resultBundle', {}), ('metrics', {})]:
            changed = copy.deepcopy(measurement)
            changed['current'][field] = value
            assert not performance_comparison_complete(name, changed)
        for metric in measurement['current']['metrics']:
            for values in ({'samples': [10000] * 10, 'mean': 10000}, {'samples': [float('nan')], 'mean': float('nan')},
                    {'samples': [0.1] * 10, 'mean': 999}, {'samples': [], 'mean': 0}):
                changed = copy.deepcopy(measurement)
                changed['current']['metrics'][metric] = values
                assert not performance_comparison_complete(name, changed)
        changed = copy.deepcopy(measurement)
        changed['baseline']['approvedBy'] = ''
        assert not performance_comparison_complete(name, changed)
        for field, value in [('sourceCommit', '0' * 40), ('resultBundle', {'path': '/does-not-exist/current.xcresult', 'identity': 'a' * 64})]:
            changed = copy.deepcopy(measurement)
            changed['current'][field] = value
            assert not performance_comparison_complete(name, changed)
        changed = copy.deepcopy(measurement)
        for kind in ('current', 'baseline'): changed[kind]['environment']['deviceIdentifier'] = 'unrelated-device'
        assert not performance_comparison_complete(name, changed)
    desktop = json.loads(evidence_fixture('catalyst-desktop'))
    from validation_manual import APPLICATION_SCENARIOS, scenarios_match_distribution
    assert scenarios_match_distribution(checks, checks['distribution-signing'])
    for check in APPLICATION_SCENARIOS - {'catalyst-desktop'}:
        proof = json.loads(evidence_fixture(check))
        assert scenario_complete(check, proof), check
        for field in ('application', 'inputDigest', 'platform', 'deviceIdentifier'):
            changed = dict(proof)
            changed.pop(field)
            assert not scenario_complete(check, changed), (check, field)
        changed = copy.deepcopy(proof)
        changed['application']['testHostMarkers'] = ['BIT101_AUTOMATED_TESTING']
        assert not scenario_complete(check, changed), check
        changed = copy.deepcopy(proof)
        changed['application']['distributionChannel'] = 'development'
        assert not scenario_complete(check, changed), check
        for field, value in [('sha256', 'b' * 64), ('executableUUIDs', [{'architecture': 'arm64', 'uuid': str(uuid.uuid4()).upper()}])]:
            changed = copy.deepcopy(proof)
            changed['application'][field] = value
            observation = copy.deepcopy(checks[check])
            data = json.dumps(changed).encode()
            observation['evidence'].update(dataUTF8=data.decode(), byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
            mutated = checks | {check: observation}
            assert scenario_complete(check, changed), (check, field)
            assert scenarios_match_distribution(mutated, checks['distribution-signing']) == (field == 'sha256'), (check, field)
            assert complete(mutated) == (field == 'sha256'), (check, field)
    assert scenario_complete('catalyst-desktop', desktop)
    from validation_manual import catalyst_matches_runtime
    runtime = {'exitCode': 0, 'scope': 'full', 'summary': {'passed': True}, 'application': desktop['application']}
    assert catalyst_matches_runtime(checks['catalyst-desktop'], runtime)
    for key, value in [('sha256', 'b' * 64), ('executableUUIDs', [{'architecture': 'arm64', 'uuid': str(uuid.uuid4()).upper()}])]:
        changed = copy.deepcopy(runtime)
        changed['application'][key] = value
        assert not catalyst_matches_runtime(checks['catalyst-desktop'], changed), key
    for key, value in [('exitCode', 1), ('scope', 'selected'), ('summary', {'passed': False}), ('application', {})]:
        assert not catalyst_matches_runtime(checks['catalyst-desktop'], runtime | {key: value}), key
    for key, value in [('platform', 'iOS'), ('systemVersion', '99.0'), ('inputDigest', 'stale'), ('deviceIdentifier', '')]:
        assert not scenario_complete('catalyst-desktop', desktop | {key: value}), key
    for key, value in [('version', 'other'), ('configuration', 'Debug'), ('testHostMarkers', ['BIT101_AUTOMATED_TESTING']),
            ('minimumOSVersion', '99.0'), ('sha256', 'invalid'), ('executableUUIDs', [])]:
        assert not scenario_complete('catalyst-desktop', desktop | {'application': desktop['application'] | {key: value}}), key
    for name in ('menu-actions', 'keyboard-navigation', 'permission-dialogs'):
        changed = copy.deepcopy(desktop)
        changed['scenarios'][name]['actions'].pop(next(iter(changed['scenarios'][name]['actions'])))
        assert not scenario_complete('catalyst-desktop', changed), name
    changed = copy.deepcopy(desktop)
    changed['scenarios']['window-resize']['previousWindowSize'] = changed['scenarios']['window-resize']['windowSize']
    assert not scenario_complete('catalyst-desktop', changed)
    pad = json.loads(evidence_fixture('ipad-layout'))
    assert scenario_complete('ipad-layout', pad)
    assert not scenario_complete('ipad-layout', pad | {'deviceFamily': 'iPhone'})
    for key, value in [('platform', 'macCatalyst'), ('systemVersion', '1.0'), ('inputDigest', 'stale'), ('deviceIdentifier', '')]:
        assert not scenario_complete('ipad-layout', pad | {key: value}), key
    for key, value in [('version', 'old'), ('build', 'old'), ('configuration', 'Debug'), ('testHostMarkers', ['BIT101_AUTOMATED_TESTING']),
            ('minimumOSVersion', '99.0'), ('sha256', 'invalid'), ('executableUUIDs', [])]:
        assert not scenario_complete('ipad-layout', pad | {'application': pad['application'] | {key: value}}), key
    for key in ('application', 'inputDigest'):
        changed = dict(pad)
        changed.pop(key)
        assert not scenario_complete('ipad-layout', changed), key
    for name in pad['scenarios']:
        changed = copy.deepcopy(pad)
        changed['scenarios'][name]['windowSize'] = {'width': 0, 'height': 0}
        assert not scenario_complete('ipad-layout', changed)
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
    from validation_manual import baseline_matches_distribution
    assert baseline_matches_distribution(checks['minimum-platforms'], checks['distribution-signing'])
    for platform in baseline['platforms']:
        major, minor, _ = distribution.minimum_os_version(baseline['platforms'][platform]['systemVersion'])
        later_minor = f'{major}.{minor + 1}'
        for key, value in [('systemVersion', '99.0'), ('systemVersion', 'invalid'), ('systemBuild', ''),
                ('systemVersion', later_minor),
                ('deviceIdentifier', ''), ('checks', {}), ('evidence', {}), ('installedBundles', []),
                ('capturedAt', '2000-01-01T00:00:00+00:00')]:
            changed = copy.deepcopy(baseline)
            changed['platforms'][platform][key] = value
            assert not evidence_content_complete('minimum-platforms', json.dumps(changed).encode()), (platform, key)
        for field, value in [('version', '0'), ('build', '0'), ('sha256', 'invalid'), ('executableUUIDs', []), ('distributionChannel', 'development')]:
            changed = copy.deepcopy(baseline)
            changed['platforms'][platform]['installedBundles'][0][field] = value
            assert not evidence_content_complete('minimum-platforms', json.dumps(changed).encode()), (platform, field)
    for field, value in [('sha256', 'b' * 64), ('executableUUIDs', [{'architecture': 'arm64', 'uuid': str(uuid.uuid4()).upper()}])]:
        changed = copy.deepcopy(baseline)
        changed['platforms']['iOS']['installedBundles'][0][field] = value
        data = json.dumps(changed).encode()
        assert evidence_content_complete('minimum-platforms', data)
        observation = copy.deepcopy(checks['minimum-platforms'])
        observation['evidence'].update(dataUTF8=data.decode(), byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
        assert baseline_matches_distribution(observation, checks['distribution-signing']) == (field == 'sha256'), field
    for platform in baseline['platforms']:
        major, minor, _ = distribution.minimum_os_version(baseline['platforms'][platform]['systemVersion'])
        contracts = distribution.distribution_contracts()
        for contract in contracts.values():
            if contract['platform'] == platform: contract['minimumOSVersion'] = f'{major}.{minor}.2'
        with patch('validate_distribution.distribution_contracts', return_value=contracts):
            for candidate, accepted in [(f'{major}.{minor}.1', False), (f'{major}.{minor}.2', True), (f'{major}.{minor}.3', True)]:
                changed = copy.deepcopy(baseline)
                changed['platforms'][platform]['systemVersion'] = candidate
                assert evidence_content_complete('minimum-platforms', json.dumps(changed).encode()) == accepted
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


def image_resource_self_test() -> None:
    import hashlib
    from network_request_contracts import complete
    def request(url):
        from urllib.parse import urlsplit
        parts = urlsplit(url)
        endpoint = parts._replace(query='', fragment='').geturl()
        return dict(method='GET', endpoint=endpoint, endpointDigest=hashlib.sha256(url.encode()).hexdigest(),
            finalMethod='GET', finalEndpoint=endpoint, statusCode=200, query={}, finalQuery={})
    urls = ['https://cdn.example/image.png?token=first', 'https://cdn.example/other.png']
    rows = [request(url) for url in urls]
    expected = {'resourceDigests': ','.join(sorted(row['endpointDigest'] for row in rows))}
    for probe in ('gallery.image', 'paper.image'):
        assert complete(probe, rows, expected)
        assert not complete(probe, rows, {})
        assert not complete(probe, rows[:1], expected)
        assert not complete(probe, [request('https://unrelated.example/wrong-image.png')], expected)
        assert not complete(probe, [request(urls[0].replace('first', 'second')), rows[1]], expected)
        assert not complete(probe, rows + [request('https://cdn.example/extra.png')], expected)


def report_budget_self_test(module) -> None:
    for limit, accepted in ((16, False), (64, True)):
        stream = BytesIO()
        with patch('validation_policy.MAXIMUM_REPORT_BYTES', limit), patch.object(Path, 'open', return_value=nullcontext(stream)), \
                patch.object(Path, 'replace') as committed, patch.object(Path, 'unlink') as cleanup:
            try: module.write_report({'evidence': 'x' * 17})
            except ValueError: assert not accepted
            else:
                assert accepted and json.loads(stream.getvalue()) == {'evidence': 'x' * 17}
            assert committed.called == accepted
            assert stream.tell() <= limit
            cleanup.assert_called_once_with(missing_ok=True)
    import shutil
    fixture = module.ROOT / '.build/static-audit/report-write-self-test'
    fixture.mkdir(parents=True, exist_ok=True)
    destination = fixture / 'report.json'
    original = json.dumps({'runID': 'retained-cloud-owner', 'stages': []}).encode()
    try:
        for failure in ('write', 'replace'):
            destination.write_bytes(original)
            original_open = Path.open
            class InterruptedStream:
                def __enter__(self):
                    self.stream = original_open(destination.with_suffix('.incoming'), 'wb')
                    return self
                def write(self, data):
                    self.stream.write(data[:1])
                    raise OSError('interrupted report write')
                def __exit__(self, *args): self.stream.close()
            override = patch.object(Path, 'open', return_value=InterruptedStream()) if failure == 'write' \
                else patch.object(Path, 'replace', side_effect=OSError('interrupted report commit'))
            with override:
                try: module.write_report({'runID': 'new-owner', 'stages': []}, path=destination)
                except OSError: pass
                else: raise AssertionError('写入故障需要保留原恢复记录')
            assert destination.read_bytes() == original
            assert json.loads(destination.read_text())['runID'] == 'retained-cloud-owner'
            assert not destination.with_suffix('.incoming').exists()
        module.write_report({'runID': 'new-owner', 'stages': []}, path=destination)
        assert json.loads(destination.read_text())['runID'] == 'new-owner'
    finally:
        shutil.rmtree(fixture)
