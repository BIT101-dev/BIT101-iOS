"""Exercise report archives and administrative operations with local fixtures."""
from pathlib import Path
from io import StringIO, BytesIO
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch
import json, os, re, subprocess, sys, shutil
from code_quality_rules import ROOT, SCRIPT_ROOT


def report_inbox_boundary_findings() -> list[str]:
    "验证反馈正文、附件、旧键和重复拉取的保存合同。"

    source = (SCRIPT_ROOT / "fetch-issues-and-reports.sh").read_text()
    block = next(match[1] for match in re.finditer(r"<<'PY'\n(.*?)^PY$", source, re.MULTILINE | re.DOTALL)
                 if "processed_path =" in match[1])
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
            exec(compile(block, "report-inbox-self-test", "exec"), {})
        return int(output.getvalue())
    try:
        deletion_boundary_self_test(source, fixture)
        assert execute() == 2
        saved = {path.relative_to(fixture): path.read_bytes() for path in fixture.glob("*/*/*") if path.is_file()}
        attachment = next(fixture.glob("*/*/*_附件/*.jpg"))
        assert attachment.read_bytes() == b"image" and next(fixture.glob("*/*/*_附件/*.bin")).read_bytes() == b"image"
        assert execute() == 0
        assert all((fixture / path).read_bytes() == data for path, data in saved.items())
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
        shell_source = shell_source.replace('source "$ROOT_DIR/Scripts/script-support.sh"', 'bit101_acquire_script_lock() { :; }\nmock_wrangler() { print \'[]\'; }')
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
    except (AssertionError, OSError) as error:
        findings.append(f"反馈收件箱自测：{error}")
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def deletion_boundary_self_test(source: str, fixture: Path) -> None:
    from urllib.request import Request
    block = source.split("<<'PYDELETE'\n", 1)[1].split("\nPYDELETE", 1)[0]
    key = 'report:received:00000000-0000-4000-8000-000000000001'
    path = fixture / 'delete-authorization.json'
    fixture.mkdir(parents=True, exist_ok=True)
    for failure in (False, True):
        commands = []
        def run(arguments, **options):
            commands.append(arguments)
            assert arguments[-3:] == ['--remote', '--namespace-id', 'namespace']
            if arguments[3] == 'put':
                assert json.loads(path.read_text()) == {'key': key}
                assert '--ttl' in arguments
            return subprocess.CompletedProcess(arguments, 0)
        def open_request(request: Request, **options):
            assert request.get_method() == 'DELETE' and options['timeout'] == 30
            payload = json.loads(request.data)
            assert payload['key'] == key and commands[0][4] == 'report-delete-grant:' + payload['grant']
            if failure: raise OSError('delivery unavailable')
            return BytesIO(b'{"deleted":true}')
        with patch.object(sys, 'argv', ['delete', key, '/wrangler', str(ROOT / 'Cloudflare/EmergencyUpdateWorker'), 'namespace', str(path)]), \
                patch.object(subprocess, 'run', run), patch('urllib.request.urlopen', open_request), redirect_stdout(StringIO()):
            try: exec(compile(block, 'report-delete-self-test', 'exec'), {})
            except OSError: assert failure
            else: assert not failure
        assert len(commands) == 2 and commands[-1][3] == 'delete' and commands[-1][4] == commands[0][4]
        assert not path.exists()
