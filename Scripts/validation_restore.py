#!/usr/bin/env python3
"""Validate normal App readiness and its live process after installation."""
import json
import plistlib
import uuid
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit
from validation_provenance import sampling_evidence_current

ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / 'build/DeviceInstall/restore-readiness.json'
PROCESS = ROOT / 'build/DeviceInstall/restore-process.json'


def invalidate() -> None:
    from validation_provenance import REPORT, report_lock, write_report
    with report_lock():
        if not REPORT.is_file(): return
        report = json.loads(REPORT.read_text())
        report.get('groups', {}).pop('restore', None)
        for key in ('mergeCommit', 'releaseCommit'): report.pop(key, None)
        write_report(report)


def valid_identity(proof: dict) -> bool:
    try:
        return str(uuid.UUID(proof['runID'])).lower() == proof['runID'].lower() and bool(re.fullmatch(r'[0-9a-f]{64}', proof['inputDigest']))
    except (ValueError, TypeError, KeyError, AttributeError): return False


def complete(proof: dict) -> bool:
    return proof.get('kind') == 'restore' and proof.get('initialized') is True and proof.get('sessionRecovered') is True and proof.get('active') is True \
        and proof.get('processAlive') is True and type(proof.get('processIdentifier')) is int and proof['processIdentifier'] > 0 \
        and valid_identity(proof) and sampling_evidence_current(proof)


def matches_app(proof: dict, info: dict, run_id: str, digest: str) -> bool:
    return proof.get('schemaVersion') == 1 and proof.get('runID') == run_id \
        and proof.get('inputDigest') == digest == info.get('BIT101RestoreInputDigest') \
        and all(proof.get(key) == info.get(field) for key, field in
            [('bundleIdentifier', 'CFBundleIdentifier'), ('version', 'CFBundleShortVersionString'), ('build', 'CFBundleVersion')])


def executable_path(value) -> str | None:
    if not isinstance(value, str) or not value: return None
    parsed = urlsplit(value)
    if parsed.scheme and (parsed.scheme != 'file' or parsed.netloc not in {'', 'localhost'}): return None
    path = unquote(parsed.path)
    if not path.startswith('/'): return None
    if path.startswith('/var/'): path = '/private' + path
    return path


def owned_process_alive(proof: dict, processes: list[dict]) -> bool:
    expected = executable_path(proof.get('executablePath'))
    return expected is not None and any(row.get('processIdentifier') == proof.get('processIdentifier')
        and executable_path(row.get('executable')) == expected for row in processes)


def summary(run_id: str, digest: str) -> dict:
    proof = json.loads(PROOF.read_text())
    processes = json.loads(PROCESS.read_text())['result']['runningProcesses']
    info_path = ROOT / 'build/DeviceInstall/Build/Products/Release-iphoneos/BIT101-iOS.app/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    proof = dict(proof, kind='restore', startedAt=proof.get('readyAt'), finishedAt=proof.get('readyAt'),
        processAlive=owned_process_alive(proof, processes))
    proof['passed'] = complete(proof) and matches_app(proof, info, run_id, digest)
    return proof


def mac_ready(app: Path, proof_path: Path, run_id: str, digest: str) -> bool:
    proof = json.loads(proof_path.read_text())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    process = subprocess.run(['/bin/ps', '-p', str(proof['processIdentifier']), '-o', 'comm='],
        capture_output=True, text=True, check=False)
    proof = dict(proof, kind='restore', startedAt=proof.get('readyAt'), finishedAt=proof.get('readyAt'),
        processAlive=process.returncode == 0 and process.stdout.strip() == str(app / 'Contents/MacOS/BIT101-iOS'))
    return complete(proof) and matches_app(proof, info, run_id, digest)


def self_test() -> None:
    from validation_provenance import utc_now
    row = dict(kind='restore', initialized=True, sessionRecovered=True, active=True, processAlive=True, processIdentifier=1,
        runID='00000000-0000-4000-8000-000000000001', inputDigest='a' * 64, startedAt=utc_now().isoformat(), finishedAt=utc_now().isoformat())
    assert complete(row)
    for key, value in [('sessionRecovered', False), ('initialized', False), ('active', False), ('processAlive', False), ('processIdentifier', 0),
            ('runID', ''), ('inputDigest', ''), ('startedAt', '2000-01-01T00:00:00+00:00')]:
        assert not complete(dict(row, **{key: value}))
    from unittest.mock import patch
    ready = dict(row, schemaVersion=1, readyAt=utc_now().isoformat(), bundleIdentifier='app', version='1', build='1',
        executablePath='/private/var/containers/Bundle/Application/fixture/BIT101-iOS.app/BIT101-iOS')
    info = dict(CFBundleIdentifier='app', CFBundleShortVersionString='1', CFBundleVersion='1', BIT101RestoreInputDigest='a' * 64)
    app = Path('/Applications/BIT101-iOS.app')
    from types import SimpleNamespace
    with patch.object(Path, 'read_text', return_value=json.dumps(ready)), patch.object(Path, 'read_bytes', return_value=plistlib.dumps(info)), \
            patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=str(app / 'Contents/MacOS/BIT101-iOS') + '\n')) as process:
        assert mac_ready(app, PROOF, ready['runID'], 'a' * 64)
        assert not mac_ready(app, PROOF, ready['runID'], 'b' * 64)
        process.return_value.returncode = 1
        assert not mac_ready(app, PROOF, ready['runID'], 'a' * 64)
        process.return_value.returncode = 0
        process.return_value.stdout = '/Applications/Other.app/Contents/MacOS/Other'
        assert not mac_ready(app, PROOF, ready['runID'], 'a' * 64)
    def contents(path):
        return json.dumps(ready if path == PROOF else {'result': {'runningProcesses': [{'processIdentifier': 1, 'executable': ready['executablePath']}]}})
    with patch.object(Path, 'read_text', contents), patch.object(Path, 'read_bytes', return_value=plistlib.dumps(info)):
        assert summary(ready['runID'], 'a' * 64)['passed']
        assert not summary(str(uuid.uuid4()), 'a' * 64)['passed']
        assert not summary(ready['runID'], 'b' * 64)['passed']
        ready['processIdentifier'] = 2
        assert not summary(ready['runID'], 'a' * 64)['passed']
    for executable in ['/usr/libexec/unrelated-process', None, '', 'https://example.invalid/App']:
        assert not owned_process_alive(ready, [dict(processIdentifier=ready['processIdentifier'], executable=executable)])
    assert owned_process_alive(ready, [dict(processIdentifier=ready['processIdentifier'], executable='file://' + ready['executablePath'])])
    assert owned_process_alive(ready, [dict(processIdentifier=ready['processIdentifier'], executable=ready['executablePath'].removeprefix('/private'))])
    from contextlib import nullcontext
    import validation_provenance
    retained = {'sourceDigest': 'source', 'mergeCommit': 'commit', 'releaseCommit': 'commit',
        'groups': {'restore': {'summary': ready, 'lastFullRun': row}, 'all': {'runID': 'test'}}}
    with patch.object(validation_provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(Path, 'is_file', return_value=True), \
            patch.object(Path, 'read_text', side_effect=lambda *_: json.dumps(retained)), \
            patch.object(validation_provenance, 'write_report', side_effect=lambda report: retained.update(report)) as saved:
        invalidate()
        current = saved.call_args.args[0]
        assert current == {'sourceDigest': 'source', 'groups': {'all': {'runID': 'test'}}}
        retained = current
        invalidate()
        assert saved.call_args.args[0] == current
    with patch.object(validation_provenance, 'report_lock', side_effect=nullcontext), \
            patch.object(Path, 'is_file', return_value=False), patch.object(validation_provenance, 'write_report') as saved:
        invalidate()
        saved.assert_not_called()


if __name__ == '__main__':
    import sys
    try:
        if sys.argv[1:] == ['invalidate']:
            invalidate()
            sys.exit(0)
        if sys.argv[1:2] == ['mac-ready']:
            sys.exit(0 if mac_ready(Path(sys.argv[2]), Path(sys.argv[3]), *sys.argv[4:]) else 1)
        result = summary(*sys.argv[1:])
        sys.exit(0 if result['passed'] else 1)
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit(1)
