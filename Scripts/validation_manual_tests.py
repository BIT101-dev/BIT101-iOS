"""Contracts for physical observations and final distribution signature evidence."""
import copy
from datetime import timedelta
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


def evidence_fixture(check: str) -> bytes:
    from validation_manual import MANUAL_SCENARIOS
    from validation_test_areas import manual_capabilities
    def observations(scenario):
        return {name: {'operation': '实际调用', 'result': '观察响应', 'outcome': 'passed'}
            for name in manual_capabilities(check, scenario)}
    if check in MANUAL_SCENARIOS:
        scenarios = {name: {'operation': '实际操作', 'result': '观察结果', 'outcome': 'passed',
            'capturedAt': utc_now().isoformat(), 'evidence': captured_fixture('photos')['evidence'],
            'capabilities': observations(name)} for name in MANUAL_SCENARIOS[check]}
        if check == 'ipad-layout':
            for name, size in [('portrait', (768, 1024)), ('landscape', (1024, 768)), ('split-view', (512, 768)), ('resize', (640, 768))]:
                scenarios[name]['windowSize'] = dict(zip(('width', 'height'), size))
            scenarios['split-view']['screenWidth'] = 1024
            scenarios['resize']['previousWindowSize'] = {'width': 512, 'height': 768}
        if check in {'catalyst-desktop', 'ipad-layout'}:
            from validation_compilation import compilation_settings
            from validation_provenance import source_digest
            contract = next((identifier, row) for identifier, row in distribution.distribution_contracts().items()
                if row['platform'] == 'iOS' and not row['extension'])
            identifier, row = contract
            desktop = check == 'catalyst-desktop'
            minimum = compilation_settings('macOS' if desktop else 'iOS')[1]
            if desktop:
                scenarios['window-resize'].update(windowSize={'width': 1024, 'height': 768}, previousWindowSize={'width': 800, 'height': 600})
                for name, actions in {'menu-actions': ('app-menu', 'window-menu'), 'keyboard-navigation': ('tab', 'return', 'escape'),
                        'permission-dialogs': ('photos', 'calendar', 'notifications')}.items():
                    scenarios[name]['actions'] = {action: {'operation': '实际操作', 'result': '观察结果', 'outcome': 'passed'} for action in actions}
            return json.dumps({'schemaVersion': 1, 'platform': 'macCatalyst' if desktop else 'iOS',
                'deviceIdentifier': 'fixture-mac' if desktop else 'fixture-pad', 'deviceModel': 'Mac' if desktop else 'iPad', 'deviceFamily': 'iPad',
                'systemVersion': minimum, 'systemBuild': 'fixture-build', 'inputDigest': source_digest('manual-device', environment={}),
                'application': {'identifier': identifier, 'version': row['version'], 'build': row['build'], 'configuration': 'Release',
                    'testHostMarkers': [], 'minimumOSVersion': minimum, 'sha256': 'a' * 64,
                    'executableUUIDs': [{'architecture': 'arm64', 'uuid': '00000000-0000-4000-8000-000000000001'}]},
                'scenarios': scenarios}).encode()
        if check == 'performance-baseline':
            from validation_manual import PERFORMANCE_WORKLOADS, performance_group
            from validation_policy import workflow_conditions
            for name, row in scenarios.items():
                test, workload = PERFORMANCE_WORKLOADS[name]
                group = performance_group(test)
                current = {'testIdentifier': test, 'sourceCommit': 'a' * 40, 'input': workload, 'capturedAt': row['capturedAt'],
                    'environment': {'deviceIdentifier': 'fixture-phone', 'deviceModel': 'iPhone', 'systemVersion': '26.0',
                        'systemBuild': 'fixture', 'xcodeBuild': 'fixture', 'configuration': 'Release', 'compilerSHA256': 'a' * 64,
                        'compilationConditions': ['DEBUG', 'BIT101_AUTOMATED_TESTING']},
                    'resultBundle': {'path': '.build/extended-automation/test-results.xcresult', 'sha256': 'a' * 64},
                    'metrics': {'clockSeconds': {'samples': [0.1] * 10, 'mean': 0.1},
                        'peakPhysicalMemoryBytes': {'samples': [1024] * 10, 'mean': 1024}}}
                from validation_performance import current_commit
                from validation_evidence import source_digest
                context = {'host': {'system': 'fixture'}, 'developer': '/fixture',
                    'xcode': {'DTXcodeBuild': 'fixture'}, 'compiler': {'modified': 1, 'size': 1, 'sha256': 'a' * 64},
                    'sdks': {'iPhoneOS': {'Version': '26.0'}},
                    'device': {'identifier': 'fixture-phone', 'model': 'iPhone', 'systemVersion': '26.0', 'systemBuild': 'fixture'}}
                current['sourceCommit'] = current_commit()
                current['environment']['compilationConditions'] = sorted(workflow_conditions(group))
                from validation_performance import normalize_metrics
                current['execution'] = {'group': group, 'runID': 'fixture-run', 'environment': context,
                    'sourceCommit': current['sourceCommit'], 'inputDigest': source_digest(group, environment=context), 'bundleSHA256': 'a' * 64}
                current['xcresultMetrics'] = [{'testIdentifier': test + '()', 'testRuns': [{'device': {'deviceId': 'fixture-phone'},
                    'metrics': [{'identifier': 'com.apple.dt.XCTMetric_Clock.time.monotonic', 'unitOfMeasurement': 's', 'measurements': [0.1] * 10},
                        {'identifier': 'com.apple.dt.XCTMetric_Memory.physical_peak', 'unitOfMeasurement': 'kB', 'measurements': [1.024] * 10}]}]}]
                current['metrics'] = normalize_metrics(current['xcresultMetrics'], test, 'fixture-phone')
                baseline = copy.deepcopy(current)
                baseline.update(capturedAt=(utc_now() - timedelta(days=1)).isoformat(), approvedAt=(utc_now() - timedelta(hours=1)).isoformat(), approvedBy='maintainer')
                baseline['resultBundle']['sha256'] = 'b' * 64
                baseline['execution']['bundleSHA256'] = 'b' * 64
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
                'installedBundles': [{key: bundle[key] for key in ('identifier', 'version', 'build', 'sha256', 'executableUUIDs')}
                    for bundle in bundles if contracts[bundle['identifier']]['platform'] == platform],
                'checks': {name: {'operation': '实际操作', 'result': '观察结果', 'outcome': 'passed'} for name in checks},
                'evidence': captured_fixture('photos')['evidence']}
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


def registration_self_test(subject) -> None:
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import sys
    checks = {name: captured_fixture(name) for name in MANUAL_DEVICE_CHECKS}
    state = {'groups': {'manual-device': {'summary': {'checks': checks}}}}
    original_read, original_is_file = Path.read_text, Path.is_file
    def save(report): state.update(copy.deepcopy(report))
    with patch.object(subject, 'report_lock', side_effect=nullcontext), \
            patch.object(subject, 'environment_context', return_value={'device': {'identifier': 'phone'}}), \
            patch.object(subject, 'complete_environment', return_value=True), \
            patch.object(Path, 'is_file', lambda path: path == subject.REPORT or original_is_file(path)), \
            patch.object(Path, 'read_text', lambda path, *args, **kwargs: json.dumps(state)
                if path == subject.REPORT else original_read(path, *args, **kwargs)), \
            patch.object(subject, 'write_report', side_effect=save), \
            patch('validation_manual.capture', return_value=checks['photos']), \
            patch.object(sys, 'argv', ['evidence', 'manual', 'photos', '--evidence', '/fixture']), redirect_stderr(StringIO()):
        state['groups']['manual-device']['inputDigest'] = subject.source_digest('manual-device')
        assert subject.main() == 0
        row = state['groups']['manual-device']
        assert str(uuid.UUID(row['runID'])) == row['runID']
        with patch.object(sys, 'argv', ['evidence', 'check-group', 'manual-device']):
            assert subject.main() == 0
            for field, value in [('runID', ''), ('exitCode', 2), ('inputDigest', 'stale')]:
                original = row[field]
                row[field] = value
                assert subject.main() == 1
                row[field] = original


def run_self_test() -> None:
    from validation_performance_tests import run_self_test as performance_self_test
    performance_self_test()
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
    with patch.object(Path, 'read_text', return_value='const AASA = { appID: "OLD.BIT101-dev.BIT101-iOS" };'):
        assert not distribution.distribution_complete(report, contracts)
    for index, row in enumerate(report['bundles']):
        for key, value in [('signatureVerified', False), ('version', '0.0.0'), ('build', '0'), ('team', 'other'),
                ('containerIdentifier', 'wrong'), ('sha256', 'invalid'), ('executableUUIDs', [])]:
            if key == 'containerIdentifier' and not row['containerIdentifier']: continue
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
            'DTPlatformName': row['platform'], 'CFBundleSupportedPlatforms': row['supportedPlatforms'], 'MinimumOSVersion': row['minimumOSVersion'],
            'BIT101ArchiveInputDigest': report['archiveProvenance']['inputDigest'], 'BIT101ArchiveRunIdentifier': report['archiveProvenance']['runID']})
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
            patch.object(Path, 'read_bytes', read), patch.object(distribution, 'bundle_digest', return_value='a' * 64), \
            patch.object(distribution, 'distribution_contracts', return_value=contracts), patch.object(subprocess, 'run', side_effect=signed) as commands:
        assert distribution.distribution_complete(distribution.inspect_application(root), contracts)
        build = distribution.archive_build_summary(root)
        assert build['archiveProvenance'] == report['archiveProvenance']
        assert build['executables'] == {row['identifier']: row['executableUUIDs'] for row in report['bundles']}
        assert sum('--verify' in call.args[0] and '--deep' in call.args[0] and '--strict' in call.args[0] for call in commands.call_args_list) == 4
        assert sum(call.args[0][:3] == ['security', 'cms', '-D'] for call in commands.call_args_list) == 4
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
        for field, value in [('deviceIdentifier', 'other-phone'), ('configuration', 'Debug'), ('compilerSHA256', '')]:
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
        for field, value in [('sourceCommit', '0' * 40), ('resultBundle', {'path': '/does-not-exist/current.xcresult', 'sha256': 'a' * 64})]:
            changed = copy.deepcopy(measurement)
            changed['current'][field] = value
            assert not performance_comparison_complete(name, changed)
        changed = copy.deepcopy(measurement)
        for kind in ('current', 'baseline'): changed[kind]['environment']['deviceIdentifier'] = 'unrelated-device'
        assert not performance_comparison_complete(name, changed)
    desktop = json.loads(evidence_fixture('catalyst-desktop'))
    assert scenario_complete('catalyst-desktop', desktop)
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
        for field, value in [('version', '0'), ('build', '0'), ('sha256', 'invalid'), ('executableUUIDs', [])]:
            changed = copy.deepcopy(baseline)
            changed['platforms'][platform]['installedBundles'][0][field] = value
            assert not evidence_content_complete('minimum-platforms', json.dumps(changed).encode()), (platform, field)
    for field, value in [('sha256', 'b' * 64), ('executableUUIDs', [{'architecture': 'arm64', 'uuid': str(uuid.uuid4()).upper()}])]:
        changed = copy.deepcopy(baseline)
        changed['platforms']['iOS']['installedBundles'][0][field] = value
        data = json.dumps(changed).encode()
        assert evidence_content_complete('minimum-platforms', data)
        import base64, hashlib
        observation = copy.deepcopy(checks['minimum-platforms'])
        observation['evidence'].update(dataBase64=base64.b64encode(data).decode(), byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
        assert not baseline_matches_distribution(observation, checks['distribution-signing'])
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
