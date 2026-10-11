"""Compare coverage with versioned policy."""

COVERAGE_GROUPS = frozenset({'modules', 'all', 'ui', 'catalyst', 'catalyst-release-runtime'})

def policy_floors(group: str, policy: dict) -> dict[str, int]:
    from validation_policy import MODULE_COVERAGE_FLOORS, IOS_MODULE_COVERAGE_FLOORS, UI_PRODUCTION_MODULES
    current = MODULE_COVERAGE_FLOORS if group == 'modules' else IOS_MODULE_COVERAGE_FLOORS
    if group == 'ui': current = {name: current[name] for name in UI_PRODUCTION_MODULES}
    if group == 'catalyst': current = {name: value for name, value in current.items() if name != 'ScheduleActivityContracts'}
    if group == 'catalyst-release-runtime': return {}
    prefix = '' if group == 'modules' else 'Catalyst/' if group == 'catalyst' else 'iOS/'
    baseline_group = 'all' if group in {'ui', 'catalyst'} else group
    floors = {prefix + name: max(value, policy.get(baseline_group, {}).get(name, value)) for name, value in current.items()}
    if group in {'all', 'ui', 'catalyst'}: floors['BIT101-iOS.app'] = 35
    return floors


def percentages(coverage: dict) -> dict[str, int]:
    return {name: row['coveredLines'] * 100 // row['executableLines'] for name, row in coverage.items()
        if type(row.get('coveredLines')) is int and type(row.get('executableLines')) is int and row['executableLines'] > 0}


def regressions(coverage: dict, baseline: dict) -> list[str]:
    current = percentages(coverage)
    return [f'{name}: {current[name]}% < {floor}%' for name, floor in baseline.items() if name in current and current[name] < floor]


def self_test() -> None:
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
