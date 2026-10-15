"""Compare coverage with versioned policy and combine complete Simulator shards."""
from pathlib import Path

COVERAGE_GROUPS = frozenset({'modules', 'all', 'ui', 'catalyst', 'catalyst-release-runtime'})
SIMULATOR_SHARDS = {'all': 1, 'ui': 1, 'release-runtime': 1}
SIMULATOR_WORKERS = {'app': 2, 'ui': 3, 'release-runtime': 2}


def shard_inventory(group: str, index: int, count: int) -> list[str]:
    from validation_test_areas import test_inventory
    if group not in SIMULATOR_SHARDS or count != SIMULATOR_SHARDS[group] or not 0 <= index < count:
        raise ValueError('模拟器分片需要匹配登记的完整库存分配。')
    return sorted(test_inventory(group))[index::count]


def lcov_lines(source: str, root: Path) -> dict[str, dict[str, list[int]]]:
    files, path, lines = {}, None, {}
    for row in source.splitlines():
        if row.startswith('SF:'):
            path, lines = Path(row[3:]), {}
        elif row.startswith('DA:'):
            number, hits, *_ = row[3:].split(',')
            lines[int(number)] = int(hits)
        elif row == 'end_of_record' and path is not None and path.is_relative_to(root):
            name = path.relative_to(root).as_posix()
            files[name] = {'executable': sorted(lines), 'covered': sorted(line for line, hits in lines.items() if hits > 0)}
    if not files: raise ValueError('分片覆盖率需要包含生产源码行。')
    return files


def combined_line_coverage(shards: list[dict]) -> dict:
    if not shards: raise ValueError('覆盖率汇总需要完整分片。')
    reference = {name: row['executable'] for name, row in shards[0].items()}
    covered = {name: set() for name in reference}
    for shard in shards:
        if {name: row['executable'] for name, row in shard.items()} != reference:
            raise ValueError('分片覆盖率需要来自相同的可执行源码行。')
        for name, row in shard.items():
            if not set(row['covered']) <= set(reference[name]): raise ValueError('覆盖行需要归属于可执行源码行。')
            covered[name].update(row['covered'])
    result = {}
    for name, executable in reference.items():
        targets = ['BIT101-iOS.app']
        if name.startswith('Modules/') and '/Sources/' in name: targets.append('iOS/' + name.split('/')[1])
        for target in targets:
            row = result.setdefault(target, {'coveredLines': 0, 'executableLines': 0})
            row['coveredLines'] += len(covered[name])
            row['executableLines'] += len(executable)
    return result


def policy_floors(group: str, policy: dict) -> dict[str, int]:
    from validation_policy import APP_COVERAGE_FLOOR, MODULE_COVERAGE_FLOORS, IOS_MODULE_COVERAGE_FLOORS, UI_PRODUCTION_MODULES
    current = MODULE_COVERAGE_FLOORS if group == 'modules' else IOS_MODULE_COVERAGE_FLOORS
    if group == 'ui': current = {name: current[name] for name in UI_PRODUCTION_MODULES}
    if group == 'catalyst': current = {name: value for name, value in current.items() if name != 'ScheduleActivityContracts'}
    if group == 'catalyst-release-runtime': return {}
    prefix = '' if group == 'modules' else 'Catalyst/' if group == 'catalyst' else 'iOS/'
    baseline_group = 'all' if group in {'ui', 'catalyst'} else group
    floors = {prefix + name: max(value, policy.get(baseline_group, {}).get(name, value)) for name, value in current.items()}
    if group in {'all', 'ui', 'catalyst'}:
        floors['BIT101-iOS.app'] = max(APP_COVERAGE_FLOOR, policy.get('all', {}).get('BIT101-iOS.app', APP_COVERAGE_FLOOR))
    return floors


def percentages(coverage: dict) -> dict[str, int]:
    return {name: row['coveredLines'] * 100 // row['executableLines'] for name, row in coverage.items()
        if type(row.get('coveredLines')) is int and type(row.get('executableLines')) is int and row['executableLines'] > 0}


def regressions(coverage: dict, baseline: dict) -> list[str]:
    current = percentages(coverage)
    return [f'{name}: {current[name]}% < {floor}%' for name, floor in baseline.items() if name in current and current[name] < floor]


def policy_findings(report: dict, group: str) -> list[str]:
    if group not in COVERAGE_GROUPS: return []
    from validation_provenance import complete_group_row
    row = complete_group_row(report.get('groups', {}).get(group, {}))
    return [f'{group} 覆盖率退化：{problem}' for problem in regressions(
        row.get('summary', {}).get('coverage', {}), policy_floors(group, report.get('coveragePolicy', {})))]


def self_test() -> None:
    from validation_policy import workflow_timeout_seconds
    assert workflow_timeout_seconds(('network', 'community-writes')) == 95 * 60
    assert workflow_timeout_seconds(('all', 'all')) == 50 * 60
    for group in ('all', 'ui', 'catalyst'):
        assert policy_floors(group, {'all': {'BIT101-iOS.app': 60}})['BIT101-iOS.app'] == 60
        assert policy_floors(group, {'all': {'BIT101-iOS.app': 1}})['BIT101-iOS.app'] == 35
    assert policy_floors('catalyst', {'all': {'TransportCore': 90}})['Catalyst/TransportCore'] == 90
    assert 'Catalyst/ScheduleActivityContracts' not in policy_floors('catalyst', {})
    assert policy_floors('ui', {'all': {'GalleryFeature': 40}})['iOS/GalleryFeature'] == 40
    assert policy_floors('ui', {'all': {'GalleryFeature': 1}})['iOS/GalleryFeature'] == 14
    assert 'iOS/StorageCore' not in policy_floors('ui', {'all': {'StorageCore': 90}})
    for name in ('MediaKit', 'DesignSystemKit'):
        floors = policy_floors('ui', {'all': {name: 90}})
        assert floors['iOS/' + name] == 90
        assert regressions({'iOS/' + name: {'coveredLines': 89, 'executableLines': 100}}, floors)
    assert regressions({'iOS/GalleryFeature': {'coveredLines': 39, 'executableLines': 100}},
        policy_floors('ui', {'all': {'GalleryFeature': 40}}))
    assert regressions({'Feature': {'coveredLines': 79, 'executableLines': 100}}, {'Feature': 80})
    assert not regressions({'Feature': {'coveredLines': 801, 'executableLines': 1001}}, {'Feature': 80})
    from unittest.mock import patch
    with patch('validation_test_areas.test_inventory', return_value={'a', 'b', 'c', 'd', 'e'}):
        parts = [shard_inventory('ui', 0, 1)]
        assert sorted(test for part in parts for test in part) == ['a', 'b', 'c', 'd', 'e']
        for index, count in ((-1, 1), (1, 1), (0, 3)):
            try: shard_inventory('ui', index, count)
            except ValueError: pass
            else: raise AssertionError('分片边界及登记数量需要严格匹配。')
    first = lcov_lines('SF:/repo/Modules/Feature/Sources/A.swift\nDA:1,1\nDA:2,0\nDA:3,0\nend_of_record', Path('/repo'))
    second = lcov_lines('SF:/repo/Modules/Feature/Sources/A.swift\nDA:1,2\nDA:2,1\nDA:3,0\nend_of_record', Path('/repo'))
    assert combined_line_coverage([first, second]) == {name: {'coveredLines': 2, 'executableLines': 3}
        for name in ('iOS/Feature', 'BIT101-iOS.app')}
    assert combined_line_coverage([first, first])['iOS/Feature']['coveredLines'] == 1
    for invalid in ({}, {'Modules/Feature/Sources/A.swift': {'executable': [1, 2], 'covered': [1]}},
            {'Modules/Feature/Sources/A.swift': {'executable': [1, 2, 3], 'covered': [4]}}):
        try: combined_line_coverage([first, invalid])
        except ValueError: pass
        else: raise AssertionError('覆盖率汇总需要验证源码行身份。')
