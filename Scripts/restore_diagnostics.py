"""Collect App startup diagnostics."""

import json
import subprocess
import os
import plistlib
import signal
import time
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


def mac_app_pids(app: Path | None = None) -> list[int]:
    expected = str(app / "Contents/MacOS/BIT101-iOS") if app else None
    processes = subprocess.check_output(
        [("/bin/ps"), ("-ww"), ("-u"), str(os.getuid()), ("-o"), ("pid=,comm=")], text=True
    )
    result = []
    for line in processes.splitlines():
        pid, _, executable = line.lstrip().partition(" ")
        executable = executable.strip()
        if expected is not None:
            matches = executable == expected
        else:
            matches = False
            if Path(executable).is_absolute() and executable.endswith(
                (".app/Contents/MacOS/BIT101-iOS")
            ):
                info = Path(executable).parents[1] / "Info.plist"
                try:
                    identifier = plistlib.loads(info.read_bytes()).get("CFBundleIdentifier")
                    matches = identifier == "BIT101-dev.BIT101-iOS"
                except (OSError, ValueError):
                    pass
        if matches:
            result.append(int(pid))
    return result


def mac_app_session(action: str, installed: str, restore: str = "0") -> None:
    app = Path(installed)
    was_open = bool(mac_app_pids(app)) if action == "mac-pause" else restore == "1"
    running = mac_app_pids()
    for pid in running:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while mac_app_pids():
        if time.monotonic() >= deadline:
            raise RuntimeError("101 仍在退出，请稍后重试。")
        time.sleep(0.1)
    if action == "mac-pause":
        print(int(was_open))
    elif was_open:
        subprocess.run(["open", "-n", str(app)], check=True)
