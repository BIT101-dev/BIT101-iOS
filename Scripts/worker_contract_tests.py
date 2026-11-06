"""Exercise deployed Worker contracts in the local Workers runtime."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

from worker_deployment_tests import (
    emergency_configuration_fixture as emergency_configuration_fixture,
    worker_deployment_fixture as worker_deployment_fixture,
    worker_deployment_self_test as worker_deployment_self_test,
)


def emergency_notice_identity_self_test() -> None:
    import json, sys
    from contextlib import nullcontext, redirect_stdout
    from io import StringIO
    from unittest.mock import patch

    source = (
        ROOT / "Cloudflare/EmergencyUpdateWorker/Scripts/publish-emergency-update.sh"
    ).read_text()
    stub = source.replace(
        'source "$ROOT_DIR/../../Scripts/script-support.sh"',
        "bit101_acquire_script_lock() { exit 91; }",
    )
    for arguments, expected in [
        (["--help"], 0),
        ([], 64),
        (["-1", "title", "body"], 64),
        (["1", " ", "body"], 64),
        (["9007199254740992", "title", "body"], 64),
        (["--disable"], 91),
        (["1", "title", "body"], 91),
    ]:
        result = subprocess.run(
            [
                "zsh",
                "-c",
                stub,
                str(ROOT / "Cloudflare/EmergencyUpdateWorker/Scripts/publish-emergency-update.sh"),
                *arguments,
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == expected, (arguments, result.stderr)
    body = source.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    identities = []
    for build, title, message in [
        ("41", "公告", "正文"),
        ("41", "公告", "正文"),
        ("41", "新公告", "正文"),
        ("41", "公告", "新正文"),
        ("42", "公告", "正文"),
    ]:
        output, console = StringIO(), StringIO()
        with (
            patch.object(sys, "argv", ["publish", "/fixture/notice.json", build, title, message]),
            patch("builtins.open", return_value=nullcontext(output)),
            redirect_stdout(console),
        ):
            exec(compile(body, "emergency-notice-payload", "exec"), {})
        payload = json.loads(output.getvalue())
        assert payload["notice_id"] == console.getvalue().strip() and payload[
            "maximum_affected_build"
        ] == int(build)
        identities.append(payload["notice_id"])
    assert identities[0] == identities[1] and len(set(identities)) == 4


def worker_boundary_findings() -> list[str]:
    "通过 Workers 本地 runtime 验证跨域预检、并发配额及 Smoke 约束。"
    emergency_notice_identity_self_test()
    script = ROOT / "Cloudflare/EmergencyUpdateWorker/Scripts/worker-behavior-tests.js"
    result = subprocess.run(
        ["node", str(script)],
        capture_output=True,
        text=True,
        cwd=ROOT / "Cloudflare/EmergencyUpdateWorker",
        timeout=60,
    )
    return [f"Worker 行为复测：{result.stderr}"] if result.returncode else []
