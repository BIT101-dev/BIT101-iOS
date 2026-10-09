"""Produce a public release receipt and a separate core CI exchange payload."""
import hashlib
import json
import re
from pathlib import Path
from validation_environment import environment_context, toolchain_identity
from validation_policy import RELEASE_GROUPS
from validation_provenance import evidence_current, complete_group_row
from validation_merge import CORE_GROUPS

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
            'summaryDigest': hashlib.sha256(json.dumps(summary, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            'sampling': {key: summary[key] for key in ('startedAt', 'finishedAt') if key in summary}}
    return {'schemaVersion': 1, 'tag': tag, 'releaseCommit': report['releaseCommit'], 'groups': rows}


def receipt_findings(receipt: dict, tag: str, commit: str, digest) -> list[str]:
    """Validate the maintainer's release declaration; summary digests identify locally reviewed evidence."""
    if not isinstance(receipt, dict): return ['公开发布回执需要结构化格式。']
    errors = []
    if set(receipt) != {'schemaVersion', 'tag', 'releaseCommit', 'groups'} or receipt.get('schemaVersion') != 1 \
            or receipt.get('tag') != tag or receipt.get('releaseCommit') != commit:
        errors.append('公开发布回执需要绑定当前版本标签与提交。')
    rows = receipt.get('groups', {})
    if not isinstance(rows, dict) or set(rows) != RELEASE_GROUPS:
        return errors + ['公开发布回执需要完整验收组。']
    for group, row in rows.items():
        if not isinstance(row, dict) or set(row) != {'passed', 'scope', 'toolchain', 'inputDigest', 'summaryDigest', 'sampling'}:
            errors.append(f'{group} 需要公开验收回执格式。')
            continue
        expected = toolchain_identity(environment_context(group))
        if row.get('passed') is not True or row.get('scope') != 'full' or row.get('toolchain') != expected \
                or row.get('inputDigest') != digest(group, environment=expected) \
                or not isinstance(row.get('summaryDigest'), str) or not re.fullmatch(r'[0-9a-f]{64}', row['summaryDigest']) \
                or not isinstance(row.get('sampling'), dict) or set(row['sampling']) - {'startedAt', 'finishedAt'} \
                or not evidence_current(group, row['sampling']):
            errors.append(f'{group} 需要当前源码、工具链与有效采样时间的完整验收回执。')
    return errors


def core_exchange(report: dict) -> dict:
    return {key: value for key, value in report.items() if key in {'mergeCommit', 'testedCommit', 'sourceDigest', 'performanceBaseline'}} | {
        'groups': {name: complete_group_row(row) for name, row in report.get('groups', {}).items() if name in CORE_GROUPS | {'modules'}}}


def self_test() -> None:
    from unittest.mock import patch
    from validation_provenance import utc_now
    import sys
    module = sys.modules[__name__]
    now = utc_now().isoformat()
    report = {'releaseCommit': 'commit', 'private': 'secret', 'groups': {name: {
        'environment': {'device': 'private'}, 'summary': {'private': 'secret', 'startedAt': now, 'finishedAt': now}}
        for name in RELEASE_GROUPS}}
    digest = lambda *args, **kwargs: 'a' * 64
    with patch.object(module, 'toolchain_identity', return_value={'xcode': 'fixture'}), patch.object(module, 'environment_context', return_value={}):
        receipt = release_receipt(report, 'v1.0', digest)
        assert 'secret' not in json.dumps(receipt) and '"device":' not in json.dumps(receipt)
        assert not receipt_findings(receipt, 'v1.0', 'commit', digest)
        for fault in ('commit', 'tag', 'group', 'private', 'digest', 'failed', 'stale', 'toolchain'):
            changed = json.loads(json.dumps(receipt))
            if fault == 'commit': changed['releaseCommit'] = 'other'
            if fault == 'tag': changed['tag'] = 'v2.0'
            if fault == 'group': changed['groups'].pop('manual-device')
            if fault == 'private': changed['emailBody'] = 'secret'
            if fault == 'digest': changed['groups']['all']['inputDigest'] = 'b' * 64
            if fault == 'failed': changed['groups']['all']['passed'] = False
            if fault == 'stale': changed['groups']['manual-device']['sampling']['startedAt'] = '2000-01-01T00:00:00+00:00'
            if fault == 'toolchain': changed['groups']['all']['toolchain'] = {'xcode': 'other'}
            assert receipt_findings(changed, 'v1.0', 'commit', digest), fault
    core = core_exchange(report | {'mergeCommit': 'commit', 'performanceBaseline': {'records': {'fixture': 'approved'}}})
    assert core['mergeCommit'] == 'commit' and set(core['groups']) == CORE_GROUPS | {'modules'}
    assert core['performanceBaseline'] == {'records': {'fixture': 'approved'}}
    assert 'manual-device' not in core['groups'] and 'private' not in core
