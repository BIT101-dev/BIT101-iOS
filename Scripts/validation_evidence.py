#!/usr/bin/env python3
"""Bind executed validation groups to the repository contents and release commit."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
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


def release_findings(report: dict, digest: str) -> list[str]:
    errors = []
    if report.get("sourceDigest") != digest:
        errors.append("验证源码摘要与当前仓库内容存在差异。")
    groups = report.get("groups", {})
    for name in sorted(RELEASE_GROUPS):
        row = groups.get(name, {})
        if row.get("exitCode") != 0 or row.get("scope") != "full":
            errors.append(f"{name} 需要完整执行并通过。")
        if name in {"modules", "all", "catalyst", "ui"} and row.get("passedTests", 0) == 0:
            errors.append(f"{name} 需要已通过用例的执行证据。")
    return errors


def record(group: str, status: int, scope: str, started_digest: str) -> int:
    digest = source_digest()
    if started_digest and digest != started_digest:
        status = status or 1
        print("验证期间源码变更，请按当前源码重新执行该组。", file=sys.stderr)
    row = {"exitCode": status, "scope": scope}
    metrics = ROOT / ".build/extended-automation/test-metrics.txt"
    if status == 0 and group in {"modules", "all", "catalyst", "ui"} and metrics.is_file():
        import re
        text = metrics.read_text()
        match = re.search(r"测试通过：(\d+) 项|通过 (\d+)；", text)
        if match:
            row["passedTests"] = int(next(value for value in match.groups() if value is not None))
    if group == "network":
        row["report"] = ".build/release-network-smoke/report/release-network-smoke.json"
    elif group == "icloud":
        row["report"] = ".build/icloud-cross-device-smoke/report.json"
    elif group != "audit":
        row["report"] = ".build/extended-automation/test-metrics.txt"
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
    parser.add_argument("action", choices=["digest", "record", "bind", "summary", "self-test"])
    parser.add_argument("group", nargs="?", default="")
    parser.add_argument("status", nargs="?", type=int, default=0)
    parser.add_argument("scope", nargs="?", default="full")
    args = parser.parse_args()
    if args.action == "digest":
        print(source_digest())
        return 0
    if args.action == "self-test":
        groups = {name: {"exitCode": 0, "scope": "full", "passedTests": 1} for name in RELEASE_GROUPS}
        report = {"sourceDigest": "source", "groups": groups}
        assert release_findings(report, "source") == []
        assert release_findings(report, "changed")
        groups["ui"]["scope"] = "selected"
        assert release_findings(report, "source")
        groups["ui"]["scope"] = "full"
        groups["ui"]["passedTests"] = 0
        assert release_findings(report, "source")
        return 0
    if args.action == "record":
        return record(args.group, args.status, args.scope, os.getenv("BIT101_VALIDATION_SOURCE_DIGEST", ""))
    report = json.loads(REPORT.read_text()) if REPORT.is_file() else {}
    if args.action == "bind":
        errors = release_findings(report, source_digest())
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        report["releaseCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    text = json.dumps(report, ensure_ascii=False, indent=2)
    summary = os.getenv("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a") as stream:
            stream.write("\n验证证据\n\n```json\n" + text + "\n```\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
