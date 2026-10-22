"""Exercise prepare-to-run configuration through the public preflight CLI."""
import json
import os
from pathlib import Path
import shutil
import subprocess
from network_smoke_config import capture, load


def network_configuration_boundary_findings() -> list[str]:
    root = Path(__file__).resolve().parents[1]
    fixture = root / '.build/static-audit/network-configuration-self-test'
    scripts = fixture / 'Scripts'
    configuration = fixture / '.build/release-network-smoke/community-configuration.json'
    report = fixture / 'report.json'
    values = {'posterID': 1, 'courseID': 2, 'courseNumber': 'COURSE', 'paperID': 3}
    source = (root / 'Scripts/release-network-smoke.sh').read_text()
    environment = dict(os.environ, BIT101_NETWORK_SMOKE_FIXTURES='', BIT101_COMMUNITY_SMOKE_ACCOUNT='',
        BIT101_COMMUNITY_FOLLOW_TARGET='', BIT101_NETWORK_SMOKE_CAPTURE='none', BIT101_COMMUNITY_RECOVERY_CONFIRMATION='')
    def preflight(scope, **overrides):
        return subprocess.run(['zsh', '-c', source, str(scripts / 'release-network-smoke.sh'), '--check-config', scope],
            env=dict(environment, **overrides), capture_output=True, text=True)
    try:
        scripts.mkdir(parents=True, exist_ok=True)
        for name in ('script-support.sh', 'network_smoke_config.py'):
            (scripts / name).symlink_to(root / 'Scripts' / name)
        for scope in ('all', 'bit101', 'community-writes'):
            result = preflight(scope)
            assert result.returncode == 64 and 'prepare' in result.stderr and not result.stdout, (scope, result.stderr)
        report.write_text(json.dumps({'passed': True, 'communityConfiguration': {'accountID': 42, 'fixtures': values}}))
        assert capture(report, configuration)['accountID'] == 42
        report.write_text(json.dumps({'passed': True}))
        for scope in ('all', 'bit101'):
            result = preflight(scope)
            assert result.returncode == 0 and not result.stdout, result.stderr
        assert preflight('community-writes').returncode == 64
        assert preflight('community-writes', BIT101_COMMUNITY_FOLLOW_TARGET='9').returncode == 0
        assert preflight('bit101', BIT101_COMMUNITY_SMOKE_ACCOUNT='43').returncode == 64
        assert preflight('bit101', BIT101_COMMUNITY_SMOKE_ACCOUNT='43', BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(values)).returncode == 0
        saved = configuration.read_bytes()
        report.write_text(json.dumps({'passed': False, 'failures': ['session failure']}))
        try: capture(report, configuration)
        except ValueError as error: assert str(error) == 'session failure'
        else: raise AssertionError('失败的准备需要保留先前的有效配置。')
        assert configuration.read_bytes() == saved
        assert load(configuration)['fixtures'] == values
        for invalid in ({}, dict(values, posterID=True), dict(values, courseID=0), dict(values, courseNumber=' COURSE')):
            result = preflight('bit101', BIT101_COMMUNITY_SMOKE_ACCOUNT='42', BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(invalid))
            assert result.returncode == 64, result.stderr
        for account in ('0', '-1', '9223372036854775808', 'true'):
            result = preflight('bit101', BIT101_COMMUNITY_SMOKE_ACCOUNT=account, BIT101_NETWORK_SMOKE_FIXTURES=json.dumps(values))
            assert result.returncode == 64, result.stderr
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return []
