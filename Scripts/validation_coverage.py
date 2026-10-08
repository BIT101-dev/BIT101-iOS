"""Keep full-run coverage at the strongest recorded whole-percent baseline."""


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
