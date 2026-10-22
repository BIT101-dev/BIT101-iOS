"""Exercise report archives and administrative operations with local fixtures."""
from pathlib import Path
from io import StringIO, BytesIO
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch
import json, os, re, subprocess, sys, shutil
from code_quality_rules import ROOT, SCRIPT_ROOT
from script_test_support import heredoc_body


def report_inbox_boundary_findings() -> list[str]:
    "验证反馈正文、附件、旧键和重复拉取的保存合同。"

    source = (SCRIPT_ROOT / "fetch-issues-and-reports.sh").read_text()
    from report_inbox import archive_reports
    fixture = ROOT / ".build/static-audit/report-inbox-self-test"
    staging = fixture / ".incoming"
    keys_path, processed_path = fixture / "keys.json", fixture / "report-keys.txt"
    reports = {"report:2000-01-01T10:20:30.000Z:old": {"report": {"isDevelopmentBuild": False,
        "attachments": [{"data": "aW1hZ2U=", "contentType": "image/jpeg"}, {"data": "aW1hZ2U=", "contentType": []}]}},
        "report:2000-01-02T10:20:30.000Z:new": {"report": {"mode": "suggestion"}}}
    import weakref
    live_results = weakref.WeakSet()
    calls = []
    findings = []
    fetch_failures = {}
    def fetch(arguments, **_):
        calls.append(arguments)
        result = subprocess.CompletedProcess(arguments, *fetch_failures.get(arguments[4], (0, json.dumps(reports[arguments[4]]), "")))
        live_results.add(result)
        assert len(live_results) <= 4, "整批报告正文驻留内存"
        return result
    def execute():
        staging.mkdir(parents=True, exist_ok=True)
        keys_path.write_text(json.dumps([{"name": key} for key in reports]))
        output = StringIO()
        with patch.object(sys, "argv", ["inbox", str(keys_path), str(staging), "/worker", "namespace", str(processed_path)]), \
                patch.object(subprocess, "run", fetch), redirect_stdout(output):
            archive_reports(sys.argv[1:])
        return int(output.getvalue())
    try:
        namespace_configuration_self_test(source, fixture)
        deletion_boundary_self_test(source, fixture)
        assert execute() == 2
        saved = {path.relative_to(fixture): path.read_bytes() for path in fixture.glob("*/*/*") if path.is_file()}
        attachment = next(fixture.glob("*/*/*_附件/*.jpg"))
        assert attachment.read_bytes() == b"image" and next(fixture.glob("*/*/*_附件/*.bin")).read_bytes() == b"image"
        assert execute() == 0
        assert all((fixture / path).read_bytes() == data for path, data in saved.items())
        archive = next(path for path in fixture.glob("*/*/report_*.json")
            if json.loads(path.read_text()).get("report", {}).get("attachments"))
        archived = json.loads(archive.read_text())
        assert all("data" not in item and (archive.parent / item["localFile"]).is_file()
            for item in archived["report"]["attachments"])
        old_key = next(key for key in reports if key.endswith(":old"))
        remote = reports.pop(old_key)
        for item in archived["report"]["attachments"]:
            item["data"] = "bmV3"
            item.pop("fileModified"); item.pop("localFile")
        archive.write_text(json.dumps(archived))
        assert execute() == 0
        assert json.loads(archive.read_text())["report"]["attachments"][0]["data"] == "bmV3"
        for item in archived["report"]["attachments"]: item["data"] = "aW1hZ2U="
        archive.write_text(json.dumps(archived))
        assert execute() == 0
        assert all("data" not in item for item in json.loads(archive.read_text())["report"]["attachments"])
        compacted = archive.read_bytes()
        assert execute() == 0 and archive.read_bytes() == compacted
        reports[old_key] = remote
        next(fixture.glob("*/*/report_*.json")).unlink()
        assert execute() == 1 and len(calls) == 3
        assert all(arguments[3] == "get" for arguments in calls)
        attachment.unlink()
        assert execute() == 1 and attachment.read_bytes() == b"image"
        attachment.write_bytes(b"wrong")
        assert execute() == 1 and attachment.read_bytes() == b"image"
        reports["report:delivery"] = {"report": {"mode": "suggestion"}, "emailDelivery": {"status": "pending", "attempts": 1}}
        assert execute() == 1
        reports["report:delivery"]["emailDelivery"]["attempts"] = 2
        assert execute() == 1
        delivery_path = next(fixture.glob("*/*/report_delivery.json"))
        assert json.loads(delivery_path.read_text())["emailDelivery"]["attempts"] == 2
        reports["report:delivery"]["emailDelivery"]["status"] = "sent"
        assert execute() == 1 and execute() == 0
        reports.update({f"report:2000-01-03:batch-{index}": {"report": {"comment": "x" * 8192}} for index in range(40)})
        assert execute() == 40
        reports["report:invalid-attachment"] = {"report": {"attachments": [
            {"data": "invalid%base64", "contentType": "image/png", "name": "原附件"}, "legacy-invalid"]}}
        try:
            with redirect_stderr(StringIO()):
                execute()
        except SystemExit as error:
            assert error.code == 1
        else:
            raise AssertionError("异常附件需要返回部分失败")
        invalid_path = next(fixture.glob("*/*/report_invalid-attachment.json"))
        archived = json.loads(invalid_path.read_text())
        assert archived["inboxAttachmentErrors"] == 2
        assert archived["report"]["attachments"][0]["data"] == "invalid%base64"
        assert archived["report"]["attachments"][1]["original"] == "legacy-invalid"
        assert "report:invalid-attachment" not in processed_path.read_text()
        reports["report:invalid-attachment"] = {"report": {"attachments": []}}
        assert execute() == 1
        assert "report:invalid-attachment" in processed_path.read_text()
        reports.update({"report:partial-success": {"report": {"comment": "archived"}},
                        "report:request-failure": {}, "report:json-failure": {}})
        fetch_failures.update({"report:request-failure": (17, "", "fixture failure"), "report:json-failure": (0, "{partial", "")})
        with redirect_stderr(StringIO()):
            try: execute()
            except SystemExit as error: assert error.code == 1
            else: raise AssertionError("单份失败需要传播部分失败")
        assert next(fixture.glob("*/*/report_partial-success.json")).is_file()
        assert "report:partial-success" in processed_path.read_text()
        assert "report:request-failure" not in processed_path.read_text() and "report:json-failure" not in processed_path.read_text()
        fetch_failures.clear()
        reports["report:request-failure"] = reports["report:json-failure"] = {"report": {"comment": "recovered"}}
        assert execute() == 2
        import shlex
        tool_dir = fixture / "bin"
        tool_dir.mkdir(exist_ok=True)
        fake_gh = tool_dir / "gh"
        fake_gh.write_text(r'''#!/bin/zsh
if [[ "$1" == api ]]; then
  if [[ "$INBOX_SELF_TEST_MODE" == listing-failure ]]; then print partial; exit 17; fi
  print '[]'
elif [[ "$2" == list ]]; then
  if [[ "$INBOX_SELF_TEST_MODE" == listing-failure ]]; then print partial; exit 18; fi
  if [[ "$INBOX_SELF_TEST_MODE" == log-failure || "$INBOX_SELF_TEST_MODE" == log-success ]]; then
    print '[{"databaseId":1,"updatedAt":"new","headSha":"head"}]'
  else print '[]'; fi
elif [[ "$2" == view ]]; then
  if [[ "$INBOX_SELF_TEST_MODE" == log-success ]]; then
    python3 -c 'print("error: first diagnostic"); print("context" * 10000); print("final diagnostic")'
  else print -ru2 'fixture log failure'; exit 19; fi
else exit 99; fi
''')
        fake_gh.chmod(0o700)
        shell_source = source.replace('OUTPUT_DIR="$ROOT_DIR/.build/issue-report-inbox"', 'OUTPUT_DIR=' + shlex.quote(str(fixture)))
        stubs = '''bit101_acquire_script_lock() { :; }
mock_wrangler() { [[ "$INBOX_SELF_TEST_MODE" != cloudflare-list-failure ]] || return 21; print '[]'; }
node() { [[ "$INBOX_SELF_TEST_MODE" != cloudflare-config-failure ]] || return 22; command node "$@"; }
'''
        shell_source = shell_source.replace('source "$ROOT_DIR/Scripts/script-support.sh"', stubs)
        shell_source = shell_source.replace('WRANGLER="$WRANGLER_DIR/node_modules/.bin/wrangler"', 'WRANGLER=mock_wrangler')
        issue_path, ci_path = fixture / "github-issues.json", fixture / "github-ci.json"
        old_issue = '[{"number":1,"state":"open","title":"cached issue","url":"fixture"}]'
        old_ci = '[{"databaseId":1,"updatedAt":"old","headSha":"head","failedLog":"cached log"}]'
        issue_path.write_text(old_issue)
        ci_path.write_text(old_ci)
        def run_fetch(mode):
            return subprocess.run(["zsh", "-c", shell_source, str(SCRIPT_ROOT / "fetch-issues-and-reports.sh"), "fetch"],
                env=dict(os.environ, PATH=str(tool_dir) + os.pathsep + os.environ["PATH"], INBOX_SELF_TEST_MODE=mode),
                capture_output=True, text=True)
        assert run_fetch("listing-failure").returncode == 1
        assert issue_path.read_text() == old_issue and ci_path.read_text() == old_ci
        assert "failed" in (fixture / "summary.txt").read_text()
        assert run_fetch("log-failure").returncode == 1
        partial = json.loads(ci_path.read_text())[0]
        assert partial["previousFailedLog"] == "cached log" and "failedLogError" in partial
        assert run_fetch("log-failure").returncode == 1
        repeated = json.loads(ci_path.read_text())[0]
        assert repeated["previousFailedLog"] == "cached log" and "failedLogError" in repeated
        for mode in ('cloudflare-config-failure', 'cloudflare-list-failure'):
            result = run_fetch(mode)
            assert result.returncode == 1 and (fixture / 'summary.txt').is_file(), result.stderr
            assert 'GitHub Issues：' in result.stdout and 'failed' in result.stdout
            assert not staging.exists()
        assert run_fetch("log-success").returncode == 0
        complete = json.loads(ci_path.read_text())[0]["failedLog"]
        assert len(complete) > 30000 and complete.startswith("error: first diagnostic\n")
        assert complete.endswith("final diagnostic\n")
        assert "error: first diagnostic" in (fixture / "summary.txt").read_text()
        assert run_fetch("log-failure").returncode == 0
        assert json.loads(ci_path.read_text())[0]["failedLog"] == complete
        ci_path.write_text('[{"databaseId":1,"updatedAt":"new","headSha":"head","failedLogTail":"truncated"}]')
        assert run_fetch("log-success").returncode == 0
        assert json.loads(ci_path.read_text())[0]["failedLog"] == complete
        assert run_fetch("success").returncode == 0
        assert json.loads(issue_path.read_text()) == json.loads(ci_path.read_text()) == []
        rows = [{'name': f'report:{index:04}', 'metadata': {'value': index}} for index in range(1000)]
        rows.append({'name': 'other:entry'})
        keys_listing = fixture / 'error-report-keys.json'
        listing = json.dumps(rows)
        keys_listing.write_text(listing)
        result = subprocess.run([sys.executable, '-c', heredoc_body(source, 'PYKEYS'), str(keys_listing), str(SCRIPT_ROOT)],
            capture_output=True, text=True)
        assert result.returncode == 0 and len(result.stdout.splitlines()) == 41, result.stderr
        assert result.stdout.startswith('report:0999 ') and 'report:0000 ' in result.stdout
        assert 'other:entry' not in result.stdout and keys_listing.read_text() == listing
        network = (SCRIPT_ROOT / 'release-network-smoke.sh').read_text()
        emit = re.search(r'(?ms)^emit_output\(\) \{.*?^\}', network)[0]
        payload = ''.join(f'probe {index}\n' for index in range(1000)).rstrip('\n')
        network_report = fixture / 'network-smoke-summary.txt'
        result = subprocess.run(['zsh', '-c', 'ROOT_DIR=' + shlex.quote(str(ROOT)) + '\n' + emit
            + '\nemit_output "$1" result "$2"', 'output-contract', str(network_report), payload],
            capture_output=True, text=True)
        assert result.returncode == 0 and len(result.stdout.splitlines()) == 41, result.stderr
        assert 'probe 0\n' in result.stdout and 'probe 999\n' in result.stdout
        assert network_report.read_text() == payload + '\n'
        orphan = fixture / '正式版/错误报告/report_orphan_附件'
        orphan.mkdir(parents=True, exist_ok=True)
        (orphan / 'image.png').write_bytes(b'image')
        result = subprocess.run(['zsh', '-c', shell_source, str(SCRIPT_ROOT / 'fetch-issues-and-reports.sh'), 'clear-archive'],
            capture_output=True, text=True)
        assert result.returncode == 0 and '本地反馈归档已清理' in result.stdout, result.stderr
        assert not list(fixture.glob('*/*/report_*.json')) and not orphan.exists()
        assert not processed_path.exists() and not (fixture / 'summary.txt').exists()
        assert issue_path.exists() and ci_path.exists()
    except (AssertionError, OSError) as error:
        import traceback
        location = traceback.extract_tb(error.__traceback__)[-1]
        findings.append(f"反馈收件箱自测：{location.name}:{location.lineno} · {type(error).__name__} {error}")
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def namespace_configuration_self_test(source: str, fixture: Path) -> None:
    path = fixture / 'wrangler.jsonc'
    fixture.mkdir(parents=True, exist_ok=True)
    for identifier in ('initial-namespace', 'migrated-namespace'):
        path.write_text('// JSONC configuration\n{"kv_namespaces":[{"binding":"OTHER","id":"other"},'
            '{"binding":"ERROR_REPORTS","id":' + json.dumps(identifier) + '},],'
            '"routes":[{"pattern":"feedback.example","custom_domain":true},],}')
        result = subprocess.run(['node', '-', str(path)], input=heredoc_body(source, 'NODECONFIG'),
            cwd=ROOT / 'Cloudflare/EmergencyUpdateWorker', capture_output=True, text=True, check=True)
        assert result.stdout.splitlines() == [identifier, 'feedback.example']
    path.unlink()


def deletion_boundary_self_test(source: str, fixture: Path) -> None:
    from urllib.request import Request
    from urllib.error import HTTPError
    block = heredoc_body(source, "PYDELETE")
    key = 'report:received:00000000-0000-4000-8000-000000000001'
    path = fixture / 'delete-authorization.json'
    fixture.mkdir(parents=True, exist_ok=True)
    for outcome in ('success', 'unavailable', 'delayed', 'expired'):
        commands = []
        clock, attempts = [0], [0]
        def run(arguments, **options):
            commands.append(arguments)
            assert arguments[-3:] == ['--remote', '--namespace-id', 'namespace']
            if arguments[3] == 'put':
                assert json.loads(path.read_text()) == {'key': key}
                assert '--ttl' in arguments
            return subprocess.CompletedProcess(arguments, 0)
        def open_request(request: Request, **options):
            attempts[0] += 1
            assert request.get_method() == 'DELETE' and 0 < options['timeout'] <= 30
            payload = json.loads(request.data)
            assert payload['key'] == key and commands[0][4] == 'report-delete-grant:' + payload['grant']
            if outcome == 'unavailable': raise OSError('delivery unavailable')
            if outcome == 'expired' or outcome == 'delayed' and attempts[0] < 3:
                raise HTTPError(request.full_url, 403, 'grant pending', {}, BytesIO())
            return BytesIO(b'{"deleted":true}')
        def sleep(duration):
            assert 0 < duration <= 30
            clock[0] += duration
        with patch.object(sys, 'argv', ['delete', key, '/wrangler', str(ROOT / 'Cloudflare/EmergencyUpdateWorker'), 'namespace', str(path), 'feedback.example']), \
                patch.object(subprocess, 'run', run), patch('urllib.request.urlopen', open_request), \
                patch('time.monotonic', lambda: clock[0]), patch('time.sleep', sleep), redirect_stdout(StringIO()):
            try: exec(compile(block, 'report-delete-self-test', 'exec'), {})
            except OSError: assert outcome in {'unavailable', 'expired'}
            else: assert outcome in {'success', 'delayed'}
        assert attempts[0] == (3 if outcome == 'delayed' else 10 if outcome == 'expired' else 1)
        assert len(commands) == 2 and commands[-1][3] == 'delete' and commands[-1][4] == commands[0][4]
        assert not path.exists()


def community_recovery_self_test() -> list[str]:
    from validation_evidence import recover_community_smoke, record
    directory = Path("/community-recovery-self-test")
    report = directory / "report/release-network-smoke.json"
    console = directory / "console.log"
    findings = []
    for original_status, cleanup_status in ((1, 0), (130, 0), (1, 7), (1, 8), (1, 9)):
        parent = {"runID": "parent", "scope": "community-writes", "passed": False, "failures": ["edit failed"],
            "communityWriteEvidence": ["created poster1"]}
        files = {report: json.dumps(parent).encode(), console: b"original failure", directory / "build.log": b"original build"}
        def clean(*args, **kwargs):
            assert kwargs['env']['BIT101_NETWORK_SMOKE_CAPTURE'] == 'none'
            assert kwargs['env']['BIT101_NETWORK_SMOKE_TERM'] == kwargs['env']['BIT101_NETWORK_SMOKE_FIXTURES'] == ''
            if cleanup_status == 9: return subprocess.CompletedProcess(args[0], cleanup_status)
            files[report] = json.dumps({"runID": "cleanup", "scope": "community-cleanup", "passed": cleanup_status == 0}).encode()
            if cleanup_status == 8: files[report] = b"partial report"
            files[console] = b"cleanup outcome"
            files[directory / "build.log"] = b"cleanup build"
            return subprocess.CompletedProcess(args[0], cleanup_status)
        with patch.object(Path, "exists", lambda path: path in files), patch.object(Path, "read_bytes", lambda path: files[path]), \
            patch.object(Path, "read_text", lambda path: files[path].decode()), patch.object(Path, "write_bytes", lambda path, data: files.__setitem__(path, data)), \
            patch.object(Path, "write_text", lambda path, data: files.__setitem__(path, data.encode())), patch.object(subprocess, "run", clean):
            status = recover_community_smoke(Path("/network-smoke"), directory, "parent", original_status)
        restored = json.loads(files[report])
        if status != cleanup_status or restored["scope"] != "community-writes" or restored["failures"] != ["edit failed"] \
            or restored["communityWriteEvidence"] != ["created poster1"] or restored["communityCleanup"]["exitStatus"] != cleanup_status \
            or files[console].count(b"original failure") != 1 or cleanup_status != 9 and b"cleanup outcome" not in files[console] \
            or restored["communityCleanup"].get("scope") != "community-cleanup" or files[directory / "build.log"] != b"original build":
            findings.append("社区恢复自测：原始失败、创建证据与清理结果共同保留")
    from contextlib import nullcontext
    from io import StringIO
    from contextlib import redirect_stderr
    from validation_evidence_tests import network_trace_fixture
    cleanup = network_trace_fixture({"runID": "fixture-run", "scope": "community-cleanup", "passed": True,
        "requiredProbes": ["community.login"], "executedProbes": ["community.login"]})
    write_row = {"exitCode": 0, "scope": "full", "summary": {"passed": True}}
    previous = {"sourceDigest": "source", "groups": {"community-writes": write_row}}
    cleanup_environment = {"host": {"system": "fixture"}, "developer": "/fixture", "xcode": {"version": "fixture"},
        "compiler": {"modified": 1, "size": 100, "version": "a" * 64}, "sdks": {"fixture": {"Version": "1"}}, "device": {
        "identifier": "fixture-phone", "systemVersion": "fixture-os", "systemBuild": "fixture-build"}}
    with patch(f"validation_evidence.source_digest", return_value="source"), patch(f"validation_evidence.network_inventory", return_value={"community.login"}), \
            patch(f"validation_evidence.environment_context", return_value=cleanup_environment), \
            patch.dict(os.environ, BIT101_VALIDATION_RUN_ID="fixture-run"), \
            patch(f"validation_evidence.report_lock", side_effect=nullcontext), patch(f"validation_evidence.write_report") as saved, \
            patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", side_effect=[json.dumps(cleanup), json.dumps(previous)]), \
            patch.object(subprocess, "check_output", return_value="head"), redirect_stderr(StringIO()):
        result = record("community-cleanup", 0, "full", "source")
    if result or saved.call_args.args[0]["groups"]["community-writes"] != write_row:
        findings.append("社区恢复自测：成功清理沿独立范围记录并保留完整写入证据")
    return findings
