#!/usr/bin/env python3
"""Persist prepared community fixtures and resolve explicit command-line overrides."""
import argparse
import json
from pathlib import Path
import sys


def account_identifier(value) -> int:
    text = str(value)
    if len(text) > 19 or not text.isascii() or not text.isdecimal() or not 0 < int(text) <= 2**63 - 1:
        raise ValueError('社区验收需要有效账号，请执行 prepare 或设置 BIT101_COMMUNITY_SMOKE_ACCOUNT。')
    return int(text)


def fixtures(value) -> dict:
    if not isinstance(value, dict) or not all(type(value.get(key)) is int and 0 < value[key] <= 2**63 - 1
            for key in ('posterID', 'courseID', 'paperID')):
        raise ValueError('社区维护对象需要有效的 posterID、courseID 和 paperID。')
    number = value.get('courseNumber')
    if not isinstance(number, str) or not number or number != number.strip():
        raise ValueError('社区维护对象需要有效的 courseNumber。')
    return value


def load(path: Path, explicit_account: str = '', explicit_fixtures: str = '') -> dict:
    stored = None
    if not explicit_account or not explicit_fixtures:
        try: stored = json.loads(path.read_text())
        except FileNotFoundError:
            raise ValueError('社区验收配置待准备，请执行 Scripts/release-network-smoke.sh prepare。') from None
        if not isinstance(stored, dict) or stored.get('schemaVersion') != 1:
            raise ValueError('社区验收配置需要重新执行 prepare。')
        if explicit_account and not explicit_fixtures and account_identifier(explicit_account) != stored.get('accountID'):
            raise ValueError('当前指定账号与已准备配置发生变化，请重新执行 prepare 或提供该账号的完整维护对象。')
    return {'schemaVersion': 1, 'accountID': account_identifier(explicit_account or stored.get('accountID')),
        'fixtures': fixtures(json.loads(explicit_fixtures) if explicit_fixtures else stored.get('fixtures'))}


def capture(report_path: Path, path: Path) -> dict:
    report = json.loads(report_path.read_text())
    value = report.get('communityConfiguration')
    if report.get('passed') is not True or not isinstance(value, dict):
        raise ValueError('\n'.join(report.get('failures', [])) or '社区验收配置采样待完成。')
    configuration = {'schemaVersion': 1, 'accountID': account_identifier(value.get('accountID')), 'fixtures': fixtures(value.get('fixtures'))}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(configuration, ensure_ascii=False) + '\n')
    return configuration


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    resolve = commands.add_parser('load')
    resolve.add_argument('path', type=Path)
    resolve.add_argument('account')
    resolve.add_argument('fixtures')
    prepare = commands.add_parser('capture')
    prepare.add_argument('report', type=Path)
    prepare.add_argument('path', type=Path)
    validate = commands.add_parser('fixtures')
    validate.add_argument('value')
    args = parser.parse_args()
    try:
        if args.action == 'load':
            value = load(args.path, args.account, args.fixtures)
            print(value['accountID'])
            print(json.dumps(value['fixtures'], ensure_ascii=False))
        elif args.action == 'capture':
            value = capture(args.report, args.path)
            print(f'社区验收配置：账号 {value["accountID"]} · {args.path}')
        else: fixtures(json.loads(args.value))
    except (OSError, ValueError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 64
    return 0


if __name__ == '__main__': raise SystemExit(main())
