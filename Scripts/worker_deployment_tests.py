"""Check Worker deployment configuration."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def emergency_configuration_fixture(enabled: bool = False, notice_id: str | None = None) -> dict:
    import base64, json

    payload = {"schema_version": 1, "enabled": enabled}
    if notice_id is not None:
        payload["notice_id"] = notice_id
    return {
        "content": base64.b64encode(json.dumps(payload).encode()).decode("ascii"),
        "enabled": enabled,
        "noticeID": notice_id,
    }


def worker_deployment_fixture(scope: str = "all") -> dict:
    import uuid
    from validation_provenance import WORKER_FOLDERS, worker_source_revision

    return {
        folder: {
            "deploymentID": str(uuid.UUID(int=index + 1)),
            "sourceRevision": worker_source_revision(folder),
            "versions": [
                {
                    "versionID": str(uuid.UUID(int=index + 4)),
                    "percentage": 100,
                    "sourceRevision": worker_source_revision(folder),
                }
            ],
        }
        for index, folder in enumerate(WORKER_FOLDERS)
        if scope in {"all", "bit101"}
    }


def worker_deployment_self_test(network_trace_fixture) -> None:
    import copy, json, subprocess, sys, uuid
    from contextlib import contextmanager, nullcontext, redirect_stderr
    from io import BytesIO, StringIO
    from unittest.mock import patch
    from types import SimpleNamespace
    import validation_provenance as subject

    deploy_command = json.loads((subject.WRANGLER_ROOT / "package.json").read_text())["scripts"][
        "deploy"
    ]
    dispatch = subprocess.run(
        ["zsh", "-c", 'python3() { print -rl -- "$@"; }\n' + deploy_command],
        cwd=subject.WRANGLER_ROOT,
        capture_output=True,
        text=True,
    )
    assert dispatch.returncode == 0 and dispatch.stdout.splitlines() == [
        "../../Scripts/validation_provenance.py",
        "deploy-worker",
        "EmergencyUpdateWorker",
    ]
    proof = worker_deployment_fixture()
    body = b'{"schema_version":1,"enabled":false}'
    summary = network_trace_fixture({"requiredProbes": ["update.emergency"]}) | {
        "workerDeployments": proof
    }
    summary["requestEvidence"][0]["requests"][0]["responseConfiguration"]["content"] = (
        subject.base64.b64encode(body).decode("ascii")
    )
    assert subject.network_requests_complete({"update.emergency"}, summary)

    class ConfigurationResponse(BytesIO):
        status = 200

        def geturl(self):
            return "https://update.aihelpme.dev/emergency-update.json"

    with (
        patch.object(subject, "capture_worker_deployments", return_value=proof),
        patch(
            "urllib.request.urlopen",
            side_effect=lambda *args, **kwargs: ConfigurationResponse(body),
        ),
    ):
        assert subject.release_worker_findings(summary) == []
        changed = copy.deepcopy(summary)
        changed["workerDeployments"][subject.WORKER_FOLDERS[0]]["deploymentID"] = str(uuid.uuid4())
        assert any("活跃部署已变化" in row for row in subject.release_worker_findings(changed))
        changed = copy.deepcopy(summary)
        changed["requestEvidence"][0]["requests"][0]["responseConfiguration"]["content"] = "b" * 40
        assert any("配置已变化" in row for row in subject.release_worker_findings(changed))
        for requests in ([], [{}], [{"responseConfiguration": None}]):
            changed = copy.deepcopy(summary)
            changed["requestEvidence"][0]["requests"] = requests
            assert any("配置已变化" in row for row in subject.release_worker_findings(changed))
        changed = copy.deepcopy(summary)
        request = changed["requestEvidence"][0]["requests"][0]
        changed["requestEvidence"][0]["requests"].append(
            request | {"responseConfiguration": {"content": "b" * 40}}
        )
        assert any("配置已变化" in row for row in subject.release_worker_findings(changed))
        changed = copy.deepcopy(summary)
        changed["requestEvidence"].append(
            {"probe": "other", "requests": [{"responseConfiguration": {"content": "b" * 40}}]}
        )
        assert subject.release_worker_findings(changed) == []
        changed["requestEvidence"][0] = {
            "probe": "update.emergency",
            "responseConfiguration": {"content": subject.base64.b64encode(body).decode("ascii")},
        }
        assert any("配置已变化" in row for row in subject.release_worker_findings(changed))
    with patch.object(
        subject, "capture_worker_deployments", side_effect=ValueError("authentication")
    ):
        assert subject.release_worker_findings(summary)
    assert subject.worker_deployments_complete("all", proof)
    assert subject.worker_deployments_complete("school", {})
    assert not subject.worker_deployments_complete("all", {})
    folder = subject.WORKER_FOLDERS[0]
    original_read = Path.read_bytes
    source = subject.ROOT / "Cloudflare" / folder / "worker.js"
    with patch.object(
        Path,
        "read_bytes",
        lambda path: (
            original_read(path) + b"\nchanged\n" if path == source else original_read(path)
        ),
    ):
        assert not subject.worker_deployments_complete("all", proof)
    icon = subject.ROOT / "BIT101-iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    with patch.object(
        Path,
        "read_bytes",
        lambda path: original_read(path) + b"changed" if path == icon else original_read(path),
    ):
        assert not subject.worker_deployments_complete("all", proof)
    names = subject.repository_input_names(subject.ROOT)
    for suffix in (".json", ".mjs", ".ts", ".wasm", ".html", ".css", ".png"):
        asset = subject.ROOT / "Cloudflare" / folder / ("page" + suffix)
        generated = subject.ROOT / "Cloudflare" / folder / ".wrangler/tmp/page.json"
        content = {asset: b"first", generated: b"first"}
        with (
            patch.object(
                subject,
                "repository_input_names",
                return_value=names
                + [
                    asset.relative_to(subject.ROOT).as_posix(),
                    generated.relative_to(subject.ROOT).as_posix(),
                ],
            ),
            patch.object(
                Path,
                "read_bytes",
                lambda path: content[path] if path in content else original_read(path),
            ),
        ):
            before = subject.worker_source_inputs(folder)
            content[generated] = b"second"
            assert subject.worker_source_inputs(folder) == before
            content[asset] = b"second"
            assert subject.worker_source_inputs(folder) != before, suffix
    for name in (
        "config/emergency-update.json",
        "Scripts/publish-emergency-update.sh",
        "README.md",
    ):
        operational = subject.WRANGLER_ROOT / name
        with patch.object(
            Path,
            "read_bytes",
            lambda path: b"changed" if path == operational else original_read(path),
        ):
            assert (
                subject.worker_source_revision("EmergencyUpdateWorker")
                == proof["EmergencyUpdateWorker"]["sourceRevision"]
            )
    for field, value in [
        ("deploymentID", "invalid"),
        ("sourceRevision", "b" * 40),
        ("versions", []),
    ]:
        changed = copy.deepcopy(proof)
        changed[folder][field] = value
        assert not subject.worker_deployments_complete("all", changed), field
    for field, value in [
        ("versionID", "invalid"),
        ("percentage", True),
        ("percentage", 99),
        ("percentage", float("nan")),
        ("sourceRevision", "b" * 40),
    ]:
        changed = copy.deepcopy(proof)
        changed[folder]["versions"][0][field] = value
        assert not subject.worker_deployments_complete("all", changed), field
    verify_deployment_proof_versions(folder, proof)


def verify_deployment_proof_versions(folder, proof):
    from types import SimpleNamespace
    from io import BytesIO, StringIO
    import copy, json, subprocess, sys, uuid
    from contextlib import contextmanager, nullcontext, redirect_stderr
    from unittest.mock import patch
    import validation_provenance as subject

    gradual = copy.deepcopy(proof)
    first = gradual[folder]["versions"][0]
    first["percentage"] = 40
    gradual[folder]["versions"].append(dict(first, versionID=str(uuid.uuid4()), percentage=60))
    assert subject.worker_deployments_complete("all", gradual)
    gradual[folder]["versions"][1]["sourceRevision"] = "b" * 40
    assert not subject.worker_deployments_complete("all", gradual)
    calls = []

    def cli(name, *arguments):
        calls.append((name, arguments))
        row = proof[name]
        if arguments == ("deployments", "status"):
            return {
                "id": row["deploymentID"],
                "versions": [
                    {"version_id": item["versionID"], "percentage": item["percentage"]}
                    for item in row["versions"]
                ],
            }
        identifier = arguments[-1]
        return {
            "id": identifier,
            "annotations": {
                "workers/message": subject.WORKER_SOURCE_PREFIX + row["sourceRevision"]
            },
        }

    with patch.object(subject, "worker_cli_json", cli):
        assert subject.capture_worker_deployments("all") == proof
        assert len(calls) == 6
        calls.clear()
        assert subject.capture_worker_deployments("school") == {} and calls == []
        with patch.object(subject, "worker_source_revision", return_value="b" * 40):
            try:
                subject.capture_worker_deployments("all")
            except ValueError:
                pass
            else:
                raise AssertionError("旧部署需要拒绝新源码证据。")
    with patch.object(
        subject.subprocess,
        "run",
        side_effect=lambda *args, **kwargs: SimpleNamespace(
            returncode=0,
            stdout=""
            if kwargs["env"].get("WRANGLER_LOG") == "error"
            else json.dumps({"id": "deployment"}),
        ),
    ) as run:
        assert subject.worker_cli_json(folder, "deployments", "status") == {"id": "deployment"}
        assert run.call_args.args[0][1:4] == ["deployments", "status", "--json"]
        assert run.call_args.kwargs["env"]["WRANGLER_LOG_PATH"] == str(subject.WORKER_LOG)
    with patch.object(
        subject.subprocess,
        "run",
        return_value=SimpleNamespace(
            returncode=1, stdout="", stderr="fixture authentication failed"
        ),
    ):
        try:
            subject.worker_cli_json(folder, "deployments", "status")
        except ValueError:
            pass
        else:
            raise AssertionError("认证失败需要传播读取失败。")
    report_path = Path("/fixture/release-network-smoke.json")
    report = {"scope": "all", "passed": True}
    for changed in (False, True):
        snapshot = copy.deepcopy(proof)
        if changed:
            snapshot[folder]["deploymentID"] = str(uuid.uuid4())
        with (
            patch.object(
                sys, "argv", ["worker", "worker-attach", str(report_path), json.dumps(proof)]
            ),
            patch.object(Path, "read_text", return_value=json.dumps(report)),
            patch.object(Path, "write_text") as write,
            patch.object(subject, "report_lock", side_effect=lambda **kwargs: nullcontext()),
            patch.object(subject, "capture_worker_deployments", return_value=snapshot),
            redirect_stderr(StringIO()),
        ):
            try:
                status = subject.worker_main()
            except SystemExit as error:
                status = error.code
            assert status == int(changed)
            if changed:
                assert [row.args for row in write.call_args_list] == [("",)]
            else:
                assert json.loads(write.call_args.args[0])["workerDeployments"] == proof
    console = subject.ROOT / ".build/release-network-smoke/console.log"
    logs, locked, deployments = {subject.WORKER_LOG: "previous", console: "app console"}, False, 0

    @contextmanager
    def worker_lock(*, path):
        nonlocal locked
        assert path == subject.WORKER_LOG
        locked = True
        try:
            yield
        finally:
            locked = False

    def deploy(command, **kwargs):
        nonlocal deployments
        assert locked and logs[subject.WORKER_LOG] == ""
        assert command[1:4] == ["deploy", "--message", subject.WORKER_SOURCE_PREFIX + "a" * 40]
        assert kwargs["env"]["WRANGLER_LOG_PATH"] == str(subject.WORKER_LOG)
        deployments += 1
        logs[subject.WORKER_LOG] += f"deployment {deployments}"

    with (
        patch.object(subject, "worker_source_revision", return_value="a" * 40),
        patch.object(sys, "argv", ["worker", "deploy-worker", folder]),
        patch.object(subject, "report_lock", worker_lock),
        patch.object(Path, "write_text", lambda path, text: logs.__setitem__(path, text)),
        patch.object(subject.subprocess, "run", side_effect=deploy),
    ):
        for number in (1, 2):
            assert subject.worker_main() == 0 and not locked
            assert (
                logs[subject.WORKER_LOG] == f"deployment {number}"
                and logs[console] == "app console"
            )
