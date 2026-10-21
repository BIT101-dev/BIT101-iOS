"""Produce a public release receipt and a separate core CI exchange payload."""
import json
import re
from pathlib import Path
from validation_environment import environment_context, toolchain_identity, exchange_identity
from validation_policy import RELEASE_GROUPS, CORE_GROUPS
from validation_provenance import group_evidence_current, complete_group_row

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = ROOT / '.build/extended-automation/release-receipt.json'
CORE_REPORT = ROOT / '.build/extended-automation/core-validation-evidence.json'


def release_receipt(report: dict, tag: str, digest) -> dict:
    rows = {}
    for group in sorted(RELEASE_GROUPS):
        original = complete_group_row(report['groups'][group])
        summary = original['summary']
        toolchain = toolchain_identity(original['environment'])
        rows[group] = {'passed': True, 'scope': 'full', 'toolchain': toolchain,
            'inputDigest': digest(group, environment=toolchain),
            'sampling': {key: summary[key] for key in ('startedAt', 'finishedAt') if key in summary}}
        if group in CORE_GROUPS: rows[group]['recordedAt'] = original['recordedAt']
        if group == 'audit': rows[group]['releaseVersionChecked'] = summary.get('releaseVersionChecked') is True
    return {'schemaVersion': 3, 'tag': tag, 'releaseCommit': report['releaseCommit'], 'groups': rows}


def receipt_findings(receipt: dict, tag: str, commit: str, digest) -> list[str]:
    """Validate the maintainer's release declaration and its producing inputs."""
    if not isinstance(receipt, dict): return ['公开发布回执需要结构化格式。']
    errors = []
    if set(receipt) != {'schemaVersion', 'tag', 'releaseCommit', 'groups'} or receipt.get('schemaVersion') != 3 \
            or receipt.get('tag') != tag or receipt.get('releaseCommit') != commit:
        errors.append('公开发布回执需要绑定当前版本标签与提交。')
    rows = receipt.get('groups', {})
    if not isinstance(rows, dict) or set(rows) != RELEASE_GROUPS:
        return errors + ['公开发布回执需要完整验收组。']
    for group, row in rows.items():
        fields = {'passed', 'scope', 'toolchain', 'inputDigest', 'sampling'} \
            | ({'recordedAt'} if group in CORE_GROUPS else set()) | ({'releaseVersionChecked'} if group == 'audit' else set())
        if not isinstance(row, dict) or set(row) != fields:
            errors.append(f'{group} 需要公开验收回执格式。')
            continue
        expected = toolchain_identity(environment_context(group))
        if row.get('passed') is not True or row.get('scope') != 'full' or row.get('toolchain') != expected \
                or group == 'audit' and row.get('releaseVersionChecked') is not True \
                or row.get('inputDigest') != digest(group, environment=expected) \
                or not isinstance(row.get('sampling'), dict) or set(row['sampling']) - {'startedAt', 'finishedAt'} \
                or not group_evidence_current(group, {'summary': row['sampling'], 'recordedAt': row.get('recordedAt')}):
            errors.append(f'{group} 需要当前源码、工具链与有效采样时间的完整验收回执。')
    return errors


def core_exchange(report: dict) -> dict:
    payload = {key: value for key, value in report.items() if key in {
        'mergeCommit', 'testedCommit', 'sourceDigest', 'performanceBaseline', 'coverageBaseCommit', 'coveragePolicy'}} | {
        'groups': {name: complete_group_row(row) for name, row in report.get('groups', {}).items() if name in CORE_GROUPS | {'modules'}}}
    if inputs := report.get('sourceInputs'):
        groups = {name: row for name, row in inputs['groups'].items() if name in CORE_GROUPS | {'modules', ''}}
        names = {name for row in groups.values() for name in row['snapshot']['files']}
        payload['sourceInputs'] = {'groups': groups, 'files': {name: row for name, row in inputs['files'].items() if name in names}}
    return exchange_identity(payload)


def self_test() -> None:
    from unittest.mock import patch
    from validation_provenance import utc_now
    import sys
    module = sys.modules[__name__]
    now = utc_now().isoformat()
    report = {'releaseCommit': 'commit', 'private': 'secret', 'groups': {name: {
        'environment': {'device': 'private'}, 'recordedAt': now, 'summary': {'private': 'secret', 'startedAt': now, 'finishedAt': now}}
        for name in RELEASE_GROUPS}}
    report['groups']['audit']['summary']['releaseVersionChecked'] = True
    digest = lambda *args, **kwargs: 'a' * 64
    with patch.object(module, 'toolchain_identity', return_value={'xcode': 'fixture'}), patch.object(module, 'environment_context', return_value={}):
        receipt = release_receipt(report, 'v1.0', digest)
        assert 'secret' not in json.dumps(receipt) and '"device":' not in json.dumps(receipt)
        assert not receipt_findings(receipt, 'v1.0', 'commit', digest)
        for fault in ('commit', 'tag', 'group', 'private', 'digest', 'failed', 'stale', 'stale-audit', 'ordinary-audit', 'missing-release-check', 'toolchain'):
            changed = json.loads(json.dumps(receipt))
            if fault == 'commit': changed['releaseCommit'] = 'other'
            if fault == 'tag': changed['tag'] = 'v2.0'
            if fault == 'group': changed['groups'].pop('manual-device')
            if fault == 'private': changed['emailBody'] = 'secret'
            if fault == 'digest': changed['groups']['all']['inputDigest'] = 'b' * 64
            if fault == 'failed': changed['groups']['all']['passed'] = False
            if fault == 'stale': changed['groups']['manual-device']['sampling']['startedAt'] = '2000-01-01T00:00:00+00:00'
            if fault == 'stale-audit': changed['groups']['audit']['sampling']['startedAt'] = '2000-01-01T00:00:00+00:00'
            if fault == 'ordinary-audit': changed['groups']['audit']['releaseVersionChecked'] = False
            if fault == 'missing-release-check': changed['groups']['audit'].pop('releaseVersionChecked')
            if fault == 'toolchain': changed['groups']['all']['toolchain'] = {'xcode': 'other'}
            assert receipt_findings(changed, 'v1.0', 'commit', digest), fault
        for group in CORE_GROUPS:
            for recorded in (None, '2000-01-01T00:00:00+00:00', '2999-01-01T00:00:00+00:00'):
                changed = json.loads(json.dumps(receipt))
                if recorded is None: changed['groups'][group].pop('recordedAt')
                else: changed['groups'][group]['recordedAt'] = recorded
                assert receipt_findings(changed, 'v1.0', 'commit', digest), (group, recorded)
    core = core_exchange(report | {'mergeCommit': 'commit', 'performanceBaseline': {'records': {'fixture': 'approved'}},
        'coverageBaseCommit': 'base', 'coveragePolicy': {'all': {'GalleryFeature': 50}}})
    assert core['mergeCommit'] == 'commit' and set(core['groups']) == CORE_GROUPS | {'modules'}
    assert core['performanceBaseline'] == {'records': {'fixture': 'approved'}}
    assert core['coverageBaseCommit'] == 'base' and core['coveragePolicy'] == {'all': {'GalleryFeature': 50}}
    assert 'manual-device' not in core['groups'] and 'private' not in core
    context = {'developer': '/Users/fixture/Xcode', 'compiler': {'path': '/Users/fixture/compiler', 'version': 'a' * 64},
        'device': {'identifier': 'fixture-udid', 'model': 'iPhone', 'systemVersion': '27', 'systemBuild': 'fixture-build'},
        'sdks': {'iPhoneOS': {'path': '/Users/fixture/sdk', 'Version': '27'}}}
    original = {'groups': {'all': {'environment': context, 'performance': {
        'execution': {'environment': context}, 'environment': {'deviceIdentifier': 'fixture-udid'},
        'xcresultMetrics': [{'testRuns': [{'device': {'deviceId': 'fixture-udid', 'deviceName': 'Owner phone'}}]}]}}}}
    shared = core_exchange(original)
    assert all(value not in json.dumps(shared) for value in ('/Users/fixture', 'fixture-udid', 'Owner phone'))
    assert core_exchange(shared) == shared and original['groups']['all']['environment'] == context
    performance = shared['groups']['all']['performance']
    identity = shared['groups']['all']['environment']['device']['identifier']
    assert identity == performance['environment']['deviceIdentifier'] == performance['xcresultMetrics'][0]['testRuns'][0]['device']['deviceId']
    from validation_provenance import source_digest
    with patch('validation_provenance.repository_input_names', return_value=[]):
        assert source_digest('all', environment=context) == source_digest('all', environment=shared['groups']['all']['environment'])
        assert source_digest('all', environment=context) != source_digest('all', environment=context | {'device': context['device'] | {'identifier': 'other'}})
