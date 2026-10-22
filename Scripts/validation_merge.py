"""Require current core physical-device evidence before merging product changes."""
from validation_provenance import group_evidence_current, complete_group_row
from validation_environment import complete_environment, environment_context, toolchain_identity, ci_commit_findings
from validation_performance import merge_findings as performance_findings, result_bundle_findings
from validation_coverage import policy_findings

from validation_policy import CORE_GROUPS


def findings(report: dict, *, digest, complete, commit: str, recorded_environment: bool = False) -> list[str]:
    errors = ci_commit_findings(commit)
    if report.get('mergeCommit', report.get('releaseCommit')) != commit:
        errors.append('合并验收需要绑定当前提交。')
    reference = complete_group_row(report.get('groups', {}).get('all', {})).get('environment', {})
    if recorded_environment and toolchain_identity(reference) != toolchain_identity(environment_context('build-release')):
        errors.append('核心真机验收需要匹配当前 CI 编译工具链及 SDK。')
    for group in sorted(CORE_GROUPS):
        errors.extend(policy_findings(report, group))
        row = complete_group_row(report.get('groups', {}).get(group, {}))
        if group == 'restore' and any(row.get('summary', {}).get(key) != row.get(key) for key in ('runID', 'inputDigest')):
            errors.append('restore 的就绪信号需要对应所属运行与输入摘要。')
        inputs = digest(group, environment=row.get('environment', {})) if recorded_environment else digest(group)
        if recorded_environment and toolchain_identity(row.get('environment', {})) \
                != toolchain_identity(reference):
            errors.append('核心真机验收的编译工具链及 SDK 需要一致。')
        if row.get('inputDigest') != inputs \
                or not complete_environment(group, row.get('environment', {})) \
                or row.get('scope') != 'full' or row.get('exitCode') != 0 or not complete(group, row.get('summary', {})) \
                or not group_evidence_current(group, row):
            errors.append(f'{group} 需要当前输入的完整真机验收，并在 24 小时内执行。')
    errors.extend(performance_findings(report))
    errors.extend(result_bundle_findings(report, recorded_environment=recorded_environment))
    return list(dict.fromkeys(errors))
