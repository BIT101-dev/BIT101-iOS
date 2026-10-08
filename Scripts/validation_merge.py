"""Require current core physical-device evidence before merging product changes."""
from validation_provenance import sampling_evidence_current
from validation_environment import complete_environment

CORE_GROUPS = {'all', 'ui', 'restore'}


def findings(report: dict, *, digest, complete, commit: str) -> list[str]:
    errors = []
    if report.get('mergeCommit', report.get('releaseCommit')) != commit:
        errors.append('合并验收需要绑定当前提交。')
    for group in sorted(CORE_GROUPS):
        row = report.get('groups', {}).get(group, {})
        recorded = row.get('recordedAt', '')
        if group == 'restore' and any(row.get('summary', {}).get(key) != row.get(key) for key in ('runID', 'inputDigest')):
            errors.append('restore 的就绪信号需要对应所属运行与输入摘要。')
        if row.get('inputDigest') != digest(group, environment=row.get('environment', {})) \
                or not complete_environment(group, row.get('environment', {})) \
                or row.get('scope') != 'full' or row.get('exitCode') != 0 or not complete(group, row.get('summary', {})) \
                or not sampling_evidence_current({'startedAt': recorded, 'finishedAt': recorded}):
            errors.append(f'{group} 需要当前输入的完整真机验收，并在 24 小时内执行。')
    return errors
