"""Collect App startup diagnostics."""

import json
import subprocess
from pathlib import Path


def simulator_startup_diagnostics(device: str, process: int) -> None:
    import sys

    subprocess.run(
        [
            "xcrun",
            "simctl",
            "spawn",
            device,
            "log",
            "show",
            "--style",
            "compact",
            "--info",
            "--last",
            "2m",
            "--predicate",
            (
                'subsystem == "BIT101" AND (category == "RestoreReadiness" OR category == "LoginKe'
                'ychain" OR category == "PersistentBackup")'
            ),
        ],
        check=False,
        stdout=sys.stderr,
        stderr=sys.stderr,
    )
    reports = Path.home() / "Library/Logs/DiagnosticReports"
    for report in reports.glob("BIT101-iOS-*.ips"):
        try:
            payload = json.loads(report.read_text().partition("\n")[2])
            if not isinstance(payload, dict) or payload.get("pid") != process:
                continue
            print(
                f"启动崩溃：{report} · {json.dumps(payload.get('exception'), ensure_ascii=False)}",
                file=sys.stderr,
            )
            thread = payload.get("threads", [])[payload.get("faultingThread", 0)]
            for frame in thread.get("frames", []):
                print("  " + str(frame.get("symbol") or frame.get("imageOffset")), file=sys.stderr)
            break
        except (OSError, ValueError, TypeError, IndexError):
            continue
