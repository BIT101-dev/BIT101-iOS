"""Exercise workflow ownership and bounded network evidence using memory IO substitutes."""
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from datetime import timedelta
from io import StringIO
import ast
import json
import subprocess
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch
from validation_provenance import LIVE_GROUPS, evidence_current, sampling_evidence_current, utc_now


def run_self_test(recorder) -> None:
    module = sys.modules[recorder.__module__]
    summary = {"passed": True, "totalTests": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
    for group, start, run_id, artifact, expected in (
        ("audit", "", "run", None, 1),
        ("audit", "current", "", None, 1),
        ("audit", "current", "run", None, 0),
        ("all", "current", "run", "验证输入：old\n验证运行：run\n", 1),
        ("all", "current", "run", "验证输入：current\n验证运行：old\n", 1),
        ("all", "current", "run", "验证输入：current\n验证运行：run\n", 0),
        ("network", "current", "run", json.dumps({"runID": "old"}), 1),
        ("network", "current", "run", json.dumps({"runID": "run"}), 0),
    ):
        values = [artifact, '{"groups":{}}'] if artifact is not None else ['{"groups":{}}']
        with patch.object(module, "source_digest", return_value="current"), \
                patch.object(module, "complete_environment", return_value=True), \
                patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "write_report") as saved, \
                patch.object(module, "test_summary", return_value=summary), patch.object(module, "smoke_summary", return_value=summary), \
                patch.object(module, "complete_summary", return_value=True), patch.object(module, "environment_context", return_value={}), \
                patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", side_effect=values), \
                patch.object(module.subprocess, "check_output", return_value="head"), \
                patch.dict(os.environ, BIT101_VALIDATION_RUN_ID=run_id), redirect_stderr(StringIO()):
            assert recorder(group, 0, "full", start) == expected, (group, artifact)
            assert saved.call_args.args[0]["groups"][group]["exitCode"] == expected
    group_row = {"scope": "full", "exitCode": 0, "runID": "run", "inputDigest": "current", "summary": summary}
    for digest, expected in (("current", 0), ("changed", 1)):
        with patch.object(sys, "argv", ["validation_evidence.py", "check-group", "all"]), \
                patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "complete_summary", return_value=True), \
                patch.object(module, "source_digest", return_value=digest), patch.object(Path, "is_file", return_value=True), \
                patch.object(Path, "read_text", return_value=json.dumps({"groups": {"all": group_row}})), redirect_stderr(StringIO()):
            assert module.main() == expected
    artifact_lock_self_test(module)
    now = utc_now()
    fresh = {"startedAt": (now - timedelta(minutes=2)).isoformat(), "finishedAt": (now - timedelta(minutes=1)).isoformat()}
    assert sampling_evidence_current(fresh, now)
    assert not sampling_evidence_current(dict(fresh, startedAt=(now - timedelta(days=2)).isoformat()), now)
    for group in LIVE_GROUPS:
        assert evidence_current(group, fresh)
        assert not evidence_current(group, dict(fresh, startedAt=(now - timedelta(days=2)).isoformat()))
    assert not sampling_evidence_current(fresh, now + timedelta(days=1))
    assert not sampling_evidence_current(dict(fresh, finishedAt=(now + timedelta(minutes=1)).isoformat()), now)
    assert not sampling_evidence_current(dict(fresh, startedAt=now.isoformat()), now)
    assert not sampling_evidence_current({"startedAt": "invalid", "finishedAt": "invalid"}, now)
    assert not sampling_evidence_current({}, now)
    for group in ("network", "icloud", "manual-device"):
      for summary, expected, label in ((fresh, 0, "通过"),
            (dict(fresh, finishedAt=(now - timedelta(days=2)).isoformat()), 1, "待复验")):
          row = dict(group_row, summary=dict(summary, passed=True))
          report = json.dumps({"groups": {group: row}})
          with patch.object(module, "source_digest", return_value="current"), \
                  patch.object(module, "report_lock", side_effect=nullcontext), patch.object(module, "complete_summary", return_value=True), \
                  patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", return_value=report), \
                  patch.object(sys, "argv", ["validation_evidence.py", "check-group", group]), redirect_stderr(StringIO()):
              assert module.main() == expected
              output = StringIO()
              with redirect_stdout(output), patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}):
                  assert module.inspect_report(SimpleNamespace(action="summary", recorded_environment=False)) == 0
              assert f"| {group} | full | {label} |" in output.getvalue()


def artifact_lock_self_test(module) -> None:
    source = (module.ROOT / "Scripts/validation_artifacts.py").read_text()
    definition = next(node for node in ast.parse(source).body if isinstance(node, ast.FunctionDef) and node.name == "committed_children")
    harness = "from pathlib import Path\nimport fcntl, sys\n" + ast.get_source_segment(source, definition)
    harness += '\nprint("ready", flush=True)\nchildren = committed_children(Path(sys.argv[1]))\nassert all(path.name != "validation-evidence.incoming" for path in children)\nprint("committed", flush=True)\n'
    incoming = module.REPORT.with_suffix(".incoming")
    with module.report_lock():
        incoming.write_text("pending atomic report")
        child = subprocess.Popen([sys.executable, "-B", "-c", harness, str(module.REPORT.parent)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert child.stdout.readline().strip() == "ready"
            try: child.communicate(timeout=0.2)
            except subprocess.TimeoutExpired: pass
            else: raise AssertionError("产物扫描需要等待验证报告原子写入锁")
        finally:
            incoming.unlink()
    output, error = child.communicate(timeout=10)
    assert child.returncode == 0 and output.strip() == "committed", error
