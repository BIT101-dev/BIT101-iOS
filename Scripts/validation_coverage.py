"""Compare coverage with versioned policy and retain local whole-percent observations."""


def policy_floors(group: str, policy: dict) -> dict[str, int]:
    from validation_policy import MODULE_COVERAGE_FLOORS, IOS_MODULE_COVERAGE_FLOORS
    current = MODULE_COVERAGE_FLOORS if group == 'modules' else IOS_MODULE_COVERAGE_FLOORS
    prefix = '' if group == 'modules' else 'iOS/'
    floors = {prefix + name: max(value, policy.get(group, {}).get(name, value)) for name, value in current.items()}
    if group == 'all': floors['BIT101-iOS.app'] = 35
    return floors


def percentages(coverage: dict) -> dict[str, int]:
    return {name: row['coveredLines'] * 100 // row['executableLines'] for name, row in coverage.items()
        if type(row.get('coveredLines')) is int and type(row.get('executableLines')) is int and row['executableLines'] > 0}


def regressions(coverage: dict, baseline: dict) -> list[str]:
    current = percentages(coverage)
    return [f'{name}: {current[name]}% < {floor}%' for name, floor in baseline.items() if name in current and current[name] < floor]


def advance(coverage: dict, baseline: dict) -> dict[str, int]:
    return {name: max(value, baseline.get(name, value)) for name, value in percentages(coverage).items()}


def self_test() -> None:
    high = {'Feature': {'coveredLines': 80, 'executableLines': 100}}
    assert advance(high, {}) == {'Feature': 80}
    assert regressions({'Feature': {'coveredLines': 79, 'executableLines': 100}}, {'Feature': 80})
    assert not regressions({'Feature': {'coveredLines': 801, 'executableLines': 1001}}, {'Feature': 80})
