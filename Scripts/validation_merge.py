"""Require current core physical-device evidence before merging product changes."""
from validation_provenance import sampling_evidence_current, complete_group_row
from validation_environment import complete_environment, toolchain_identity
from validation_performance import merge_findings as performance_findings

CORE_GROUPS = {'all', 'release-runtime', 'ui', 'restore'}


def findings(report: dict, *, digest, complete, commit: str, recorded_environment: bool = False) -> list[str]:
    errors = []
    if report.get('mergeCommit', report.get('releaseCommit')) != commit:
        errors.append('合并验收需要绑定当前提交。')
    reference = complete_group_row(report.get('groups', {}).get('all', {})).get('environment', {})
    for group in sorted(CORE_GROUPS):
        row = complete_group_row(report.get('groups', {}).get(group, {}))
        recorded = row.get('recordedAt', '')
        if group == 'restore' and any(row.get('summary', {}).get(key) != row.get(key) for key in ('runID', 'inputDigest')):
            errors.append('restore 的就绪信号需要对应所属运行与输入摘要。')
        inputs = digest(group, environment=row.get('environment', {})) if recorded_environment else digest(group)
        if recorded_environment and toolchain_identity(row.get('environment', {})) \
                != toolchain_identity(reference):
            errors.append('核心真机验收的编译工具链及 SDK 需要一致。')
        if row.get('inputDigest') != inputs \
                or not complete_environment(group, row.get('environment', {})) \
                or row.get('scope') != 'full' or row.get('exitCode') != 0 or not complete(group, row.get('summary', {})) \
                or not sampling_evidence_current({'startedAt': recorded, 'finishedAt': recorded}):
            errors.append(f'{group} 需要当前输入的完整真机验收，并在 24 小时内执行。')
    errors.extend(performance_findings(report, commit))
    return list(dict.fromkeys(errors))
