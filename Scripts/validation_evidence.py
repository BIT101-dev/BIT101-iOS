#!/usr/bin/env python3
"""Bind executed validation groups to the repository contents and release commit."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
RELEASE_GROUPS = {"modules", "all", "catalyst", "ui", "network", "icloud", "audit"}


def source_digest() -> str:
    names = subprocess.check_output([
        "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"
    ], cwd=ROOT).decode().split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(names) - {""}):
        path = ROOT / name
        if path.is_file():
            digest.update(name.encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def test_summary(text: str) -> dict:
    counts = re.search(r"总计 (\d+)；通过 (\d+)；失败 (\d+)；跳过 (\d+)", text)
    module_count = re.search(r"测试通过：(\d+) 项", text)
    if counts:
        total, passed, failed, skipped = map(int, counts.groups())
    elif module_count:
        total = passed = int(module_count[1])
        failed = skipped = 0
    else:
        raise ValueError("测试摘要需要包含实际执行数量。")
    coverage = {}
    for name, percent, covered, executable in re.findall(
        r"^- ([^:\n]+): ([\d.]+)% \((\d+)/(\d+) lines\)", text, re.MULTILINE
    ):
        coverage[name] = {"percent": float(percent), "coveredLines": int(covered), "executableLines": int(executable)}
    return {"totalTests": total, "passedTests": passed, "failedTests": failed, "skippedTests": skipped,
            "passed": total > 0 and passed == total and failed == skipped == 0, "coverage": coverage,
            "coverageScope": next((line for line in text.splitlines() if line.startswith("统计范围：")), "宿主报告范围")}


def smoke_summary(group: str, value: dict) -> dict:
    if group == "network":
        return {"passed": value.get("passed") is True and value.get("scope") == "all"
                and not any(value.get(name) for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")),
                "scope": value.get("scope"), "executedProbes": len(value.get("executedProbes", [])),
                **{name: len(value.get(name, [])) for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes")}}
    stages = [{name: row.get(name, 0) for name in
               ("stage", "exitCode", "totalTestCount", "passedTests", "failedTests", "skippedTests")}
              for row in value.get("stages", [])]
    expected = {"testPhoneRoundTrip", "testMacReceiveAndRestore"}
    passed = value.get("exitCode") == 0 and {row["stage"] for row in stages} == expected and all(
        row["exitCode"] == 0 and row["totalTestCount"] == row["passedTests"] > 0
        and row["failedTests"] == row["skippedTests"] == 0 for row in stages)
    return {"passed": passed, "stages": stages}


def successful_test_counts(summary: dict) -> bool:
    total = summary.get("totalTests", summary.get("totalTestCount", 0))
    return total > 0 and total == summary.get("passedTests") and summary.get("failedTests") == summary.get("skippedTests") == 0


def complete_summary(group: str, summary: dict) -> bool:
    if summary.get("passed") is not True:
        return False
    if group in {"modules", "all", "catalyst", "ui"}:
        return successful_test_counts(summary)
    if group == "network":
        return summary.get("scope") == "all" and summary.get("executedProbes", 0) > 0 and all(
            summary.get(name) == 0 for name in ("failures", "coverageGaps", "authenticationBlockers", "skippedProbes"))
    if group == "icloud":
        stages = summary.get("stages", [])
        return len(stages) == 2 and {row.get("stage") for row in stages} == {"testPhoneRoundTrip", "testMacReceiveAndRestore"} and all(
            row.get("exitCode") == 0 and successful_test_counts(row) for row in stages)
    return summary.get("kind") == "audit"


def release_findings(report: dict, digest: str) -> list[str]:
    errors = []
    if report.get("sourceDigest") != digest:
        errors.append("验证源码摘要与当前仓库内容存在差异。")
    for name in sorted(RELEASE_GROUPS):
        row = report.get("groups", {}).get(name, {})
        if row.get("exitCode") != 0 or row.get("scope") != "full" or not complete_summary(name, row.get("summary", {})):
            errors.append(f"{name} 需要完整执行并通过，并保留结果摘要。")
    return errors


def record(group: str, status: int, scope: str, started_digest: str) -> int:
    digest = source_digest()
    if started_digest and digest != started_digest:
        status = status or 1
        print("验证期间源码变更，请按当前源码重新执行该组。", file=sys.stderr)
    row = {"exitCode": status, "scope": scope}
    if group in {"modules", "all", "catalyst", "ui"}:
        row["report"] = ".build/extended-automation/test-metrics.txt"
        metrics = ROOT / row["report"]
        if metrics.is_file():
            try:
                row["summary"] = test_summary(metrics.read_text())
            except ValueError:
                if status == 0:
                    raise
    elif group in {"network", "icloud"}:
        row["report"] = ".build/release-network-smoke/report/release-network-smoke.json" if group == "network" else ".build/icloud-cross-device-smoke/report.json"
        if (ROOT / row["report"]).is_file():
            row["summary"] = smoke_summary(group, json.loads((ROOT / row["report"]).read_text()))
    else:
        row["summary"] = {"passed": status == 0, "kind": "build" if group.startswith("build-") else "audit"}
    if status == 0 and not row.get("summary", {}).get("passed"):
        status = row["exitCode"] = 1
        print(f"{group} 的执行摘要需要确认完整通过。", file=sys.stderr)
    if os.getenv("GITHUB_RUN_ID"):
        row["ciRun"] = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    with REPORT.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
        if report.get("sourceDigest") != digest:
            report = {"sourceDigest": digest, "groups": {}}
        report.pop("releaseCommit", None)
        report["groups"][group] = row
        report["testedCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["digest", "record", "bind", "check", "summary", "self-test"])
    parser.add_argument("group", nargs="?", default="")
    parser.add_argument("status", nargs="?", type=int, default=0)
    parser.add_argument("scope", nargs="?", default="full")
    args = parser.parse_args()
    if args.action == "digest":
        print(source_digest())
        return 0
    if args.action == "self-test":
        test = {"passed": True, "totalTests": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        summaries = {name: dict(test) for name in ("modules", "all", "catalyst", "ui")}
        summaries["audit"] = {"passed": True, "kind": "audit"}
        summaries["network"] = smoke_summary("network", {"passed": True, "scope": "all", "executedProbes": ["fixture"]})
        summaries["icloud"] = smoke_summary("icloud", {"exitCode": 0, "stages": [
            dict(test, stage=name, totalTestCount=1, exitCode=0) for name in ("testPhoneRoundTrip", "testMacReceiveAndRestore")]})
        groups = {name: {"exitCode": 0, "scope": "full", "summary": summary} for name, summary in summaries.items()}
        report = {"sourceDigest": "source", "groups": groups}
        assert release_findings(report, "source") == []
        assert release_findings(report, "changed")
        groups["ui"]["scope"] = "selected"
        assert release_findings(report, "source")
        groups["ui"]["scope"] = "full"
        groups["ui"]["summary"]["passedTests"] = 0
        assert release_findings(report, "source")
        module = test_summary("测试通过：3 项\n统计范围：macOS\n- ScheduleSync: 75.00% (3/4 lines)")
        assert module["passed"] and module["coverage"]["ScheduleSync"]["coveredLines"] == 3
        assert test_summary("总计 4；通过 3；失败 0；跳过 1")["passed"] is False
        assert test_summary("总计 0；通过 0；失败 0；跳过 0")["passed"] is False
        network = {"passed": True, "scope": "all", "executedProbes": ["fixture"]}
        assert smoke_summary("network", network)["passed"]
        network["coverageGaps"] = ["fixture"]
        assert smoke_summary("network", network)["passed"] is False
        assert smoke_summary("icloud", {"exitCode": 0, "stages": []})["passed"] is False
        stages = [{"stage": name, "exitCode": 0, "totalTestCount": 1, "passedTests": 1}
                  for name in ["testPhoneRoundTrip", "testMacReceiveAndRestore"]]
        assert smoke_summary("icloud", {"exitCode": 0, "stages": stages})["passed"]
        stages[1]["passedTests"] = 0
        assert smoke_summary("icloud", {"exitCode": 0, "stages": stages})["passed"] is False
        return 0
    if args.action == "record":
        return record(args.group, args.status, args.scope, os.getenv("BIT101_VALIDATION_SOURCE_DIGEST", ""))
    supplied = os.getenv("BIT101_RELEASE_EVIDENCE", "") if args.action == "check" else ""
    report = json.loads(supplied) if supplied else json.loads(REPORT.read_text()) if REPORT.is_file() else {}
    if args.action in {"bind", "check"}:
        errors = release_findings(report, source_digest())
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        if args.action == "check" and report.get("releaseCommit") != commit:
            errors.append("发布验证证据需要绑定当前提交。")
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        if args.action == "bind":
            report["releaseCommit"] = commit
            REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    rows = ["| 验证组 | 范围 | 结果 | 用例 / 探针 | 覆盖率模块 |", "| --- | --- | --- | ---: | ---: |"]
    for name, row in sorted(report.get("groups", {}).items()):
        result = row.get("summary", {})
        passed = row.get("exitCode") == 0 and result.get("passed") is True
        count = result.get("passedTests", result.get("executedProbes", sum(stage["passedTests"] for stage in result.get("stages", []))))
        rows.append(f"| {name} | {row.get('scope', '?')} | {'通过' if passed else '待处理'} | {count} | {len(result.get('coverage', {}))} |")
    if report.get("releaseCommit"):
        rows.append(f"\n发布提交：{report['releaseCommit']}")
    text = "\n".join(rows)
    summary = os.getenv("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a") as stream:
            stream.write("\n验证证据\n\n" + text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
