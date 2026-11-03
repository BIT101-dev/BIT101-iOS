"""Exchange and test shared CI compilation caches."""

import json
import os
import re
import subprocess
import sys
import shutil
import zipfile
from types import SimpleNamespace
from pathlib import Path
from functools import cache

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".build/extended-automation/validation-evidence.json"
REQUIRED_JOBS = {"validation-plan", "static-audit", "release-build", "catalyst-tests", "ios-tests"}
CACHE_FLAVORS = {"release-build", "catalyst-tests", "simulator-app"}
CACHE_ROOT = ROOT / ".build/compiler-cache"
CACHE_STORE = "CompilationCache.noindex"
CACHE_METADATA = "compilation-cache.json"
CACHE_TOOLS = frozenset({"swift-syntax-indexer", "swift-syntax-indexer-inputs.json"})
RESULT_FILE = ROOT / ".build/extended-automation/ci-validation-result.json"


@cache
def read_validation_result(repo: str, artifact_id: int) -> dict | None:
    from io import BytesIO

    try:
        payload = subprocess.check_output(
            ["gh", "api", f"repos/{repo}/actions/artifacts/{artifact_id}/zip"]
        )
        with zipfile.ZipFile(BytesIO(payload)) as archive:
            value = json.loads(archive.read(RESULT_FILE.name))
        return value
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError):
        return None


@cache
def cache_identity() -> dict:
    from validation_environment import environment_context, toolchain_identity

    context = environment_context("build-release")
    return dict(toolchain=toolchain_identity(context), architecture=context["host"]["architecture"])


def export_cache(flavor: str) -> None:
    from validation_artifacts import update_cache_metadata

    if flavor not in CACHE_FLAVORS:
        raise ValueError("编译缓存需要登记的构建分组。")
    if not (CACHE_ROOT / CACHE_STORE).is_dir():
        raise ValueError("编译完成后需要生成原生缓存。")
    update_cache_metadata(
        CACHE_ROOT / CACHE_METADATA, dict(identity=cache_identity(), flavor=flavor)
    )
    files = [
        *(CACHE_ROOT / CACHE_STORE).rglob("*"),
        *(CACHE_ROOT / name for name in CACHE_TOOLS | {CACHE_METADATA}),
    ]
    size = sum(path.stat().st_size for path in files if path.is_file())
    print(f"编译缓存原始文件：{size / 1024**3:.2f} GiB。")


def extract_cache_member(archive: zipfile.ZipFile, row: zipfile.ZipInfo, target: Path) -> None:
    if row.is_dir():
        target.mkdir(parents=True, exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(row) as source, target.open("wb") as output:
            shutil.copyfileobj(source, output)
        if row.filename == "swift-syntax-indexer":
            target.chmod(0o755)


def restore_cache_payload(payload, flavor: str) -> bool:
    import zipfile
    from pathlib import PurePosixPath

    with zipfile.ZipFile(payload) as archive:
        metadata = json.loads(archive.read(CACHE_METADATA))
        if metadata.get("identity") != cache_identity() or metadata.get("flavor") != flavor:
            return False
        members = [row for row in archive.infolist() if row.filename != CACHE_METADATA]
        if not any(not row.is_dir() for row in members):
            raise ValueError("原生缓存需要包含编译数据。")
        tools = CACHE_TOOLS.intersection(row.filename for row in members)
        if tools and tools != CACHE_TOOLS:
            raise ValueError("检查工具与输入指纹需要成对恢复。")
        for row in members:
            path = PurePosixPath(row.filename)
            if (
                path.is_absolute()
                or ".." in path.parts
                or not (
                    path.parts[:1] == (CACHE_STORE,)
                    and (row.is_dir() or len(path.parts) >= 2)
                    or row.filename in CACHE_TOOLS
                    and not row.is_dir()
                )
                or (row.external_attr >> 16) & 0o170000 == 0o120000
            ):
                raise ValueError("缓存产物需要保持固定目录及普通文件。")
        destination = CACHE_ROOT / CACHE_STORE
        try:
            for row in members:
                extract_cache_member(archive, row, CACHE_ROOT / row.filename)
        except BaseException:
            shutil.rmtree(destination, ignore_errors=True)
            for name in CACHE_TOOLS:
                (CACHE_ROOT / name).unlink(missing_ok=True)
            raise
    return True


def trusted_cache_run(run: dict, repo: str) -> bool:
    return (
        run.get("event") in {"push", "workflow_dispatch"}
        and run.get("head_branch") == "main"
        and (run.get("head_repository") or {}).get("full_name") == repo
        and run.get("path") == ".github/workflows/ci.yml"
    )


def native_cache_available(path: Path) -> bool:
    return path.is_dir() and any(
        item.is_file()
        and (item.name == "data" or item.name.startswith("data."))
        and item.stat().st_size
        for item in path.rglob("*")
    )


def restore_cache(flavor: str) -> None:
    import fcntl

    if flavor not in CACHE_FLAVORS:
        raise ValueError("编译缓存需要登记的构建分组。")
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    with (CACHE_ROOT / "cache.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (CACHE_ROOT / "compilation-cache-download").unlink(missing_ok=True)
        if native_cache_available(CACHE_ROOT / CACHE_STORE):
            print("编译缓存：复用工作区原生产物。")
            return
        try:
            (CACHE_ROOT / "compilation-cache.log").write_text("")
            restore_remote_cache(flavor)
        except (
            subprocess.SubprocessError,
            OSError,
            ValueError,
            KeyError,
            zipfile.BadZipFile,
        ) as error:
            from command_output import bounded_text, character_limit

            detail = getattr(error, "stderr", None) or str(error)
            if isinstance(detail, bytes):
                detail = detail.decode(errors="replace")
            diagnostic = CACHE_ROOT / "compilation-cache.log"
            try:
                with diagnostic.open("a") as log:
                    log.write(detail + "\n")
            except OSError as log_error:
                detail += f"；诊断保存受阻：{log_error}"
            reason, _ = bounded_text(detail.strip().replace("\n", " "), character_limit())
            print(f"编译缓存：沿当前源码重新编译（{reason}）；诊断：{diagnostic}")


def restore_remote_cache(flavor: str) -> None:
    repo = repository()
    artifacts = [
        row
        for page in api_pages(
            f"repos/{repo}/actions/artifacts?name=compilation-cache-{flavor}&per_page=100"
        )
        for row in page["artifacts"]
        if row["name"] == "compilation-cache-" + flavor and not row["expired"]
    ]
    for artifact in sorted(artifacts, key=lambda row: row["id"], reverse=True):
        run = json.loads(
            subprocess.check_output(
                ["gh", "api", f"repos/{repo}/actions/runs/{artifact['workflow_run']['id']}"],
                text=True,
            )
        )
        if not trusted_cache_run(run, repo):
            continue
        commit = run["head_sha"]
        if not re.fullmatch("[0-9a-f]{40}", commit):
            continue
        if subprocess.run(
            ["git", "merge-base", "--is-ancestor", commit, "HEAD"], cwd=ROOT, capture_output=True
        ).returncode:
            continue
        if not cache_result_matches(repo, run, flavor):
            continue
        payload = CACHE_ROOT / "compilation-cache-download"
        try:
            download_cache_payload(repo, artifact["id"], payload)
            if restore_cache_payload(payload, flavor):
                print("编译缓存：已恢复工具链匹配的原生数据。")
                return
        finally:
            payload.unlink(missing_ok=True)
    print("编译缓存：首次建立当前分组的原生数据。")


def cache_result_matches(repo: str, run: dict, flavor: str) -> bool | None:
    from validation_inputs import CI_RESULT_ARTIFACTS

    group = {"release-build": "release", "catalyst-tests": "catalyst", "simulator-app": "app"}[
        flavor
    ]
    artifact_name = CI_RESULT_ARTIFACTS[group]
    artifact = next(
        (
            row
            for page in api_pages(f"repos/{repo}/actions/runs/{run['id']}/artifacts")
            for row in page["artifacts"]
            if row["name"] == artifact_name and not row.get("expired")
        ),
        None,
    )
    if artifact is None:
        return False
    result = read_validation_result(repo, artifact["id"])
    if result is None:
        return None
    if (
        not isinstance(result, dict)
        or result.get("schemaVersion") != 1
        or result.get("commit") != run["head_sha"]
        or result.get("run") != str(run["id"])
    ):
        return False
    groups = result.get("groups")
    if not isinstance(groups, dict):
        return False
    row = groups.get(group)
    if not isinstance(row, dict) or not isinstance(row.get("environment"), dict):
        return False
    environment = row["environment"]
    if not isinstance(environment.get("host"), dict):
        return False
    identity = cache_identity()
    return (
        row.get("passed") is True
        and environment.get("toolchain") == identity["toolchain"]
        and environment.get("host", {}).get("architecture") == identity["architecture"]
    )


def prune_caches() -> None:
    repo = repository()
    artifacts = [
        row
        for page in api_pages(f"repos/{repo}/actions/artifacts?per_page=100")
        for row in page["artifacts"]
    ]
    retained, runs = set(), {}
    for row in sorted(artifacts, key=lambda value: value["id"], reverse=True):
        shared_host = row["name"] == "ui-test-host" and str(row["workflow_run"]["id"]) == os.getenv(
            "GITHUB_RUN_ID"
        )
        if row.get("expired") or not (shared_host or row["name"].startswith("compilation-cache-")):
            continue
        run_id = row["workflow_run"]["id"]
        if not shared_host and run_id not in runs:
            runs[run_id] = json.loads(
                subprocess.check_output(
                    ["gh", "api", f"repos/{repo}/actions/runs/{run_id}"], text=True
                )
            )
        if (
            not shared_host
            and str(run_id) != os.getenv("GITHUB_RUN_ID")
            and runs[run_id].get("status")
            in {"queued", "in_progress", "waiting", "requested", "pending"}
        ):
            continue
        flavor = row["name"].removeprefix("compilation-cache-")
        remove = (
            shared_host
            or flavor not in CACHE_FLAVORS
            or not trusted_cache_run(runs[run_id], repo)
            or row["name"] in retained
        )
        if not remove:
            matches = cache_result_matches(repo, runs[run_id], flavor)
            if matches is None:
                continue
            remove = not matches
        if remove:
            deleted = subprocess.run(
                ["gh", "api", "-X", "DELETE", f"repos/{repo}/actions/artifacts/{row['id']}"],
                capture_output=True,
                text=True,
            )
            if deleted.returncode and "(HTTP 404)" not in deleted.stderr:
                deleted.check_returncode()
        else:
            retained.add(row["name"])


def download_cache_payload(repo: str, artifact_id: int, destination: Path) -> None:
    import io
    import time
    from concurrent.futures import ThreadPoolExecutor

    endpoint = f"repos/{repo}/actions/artifacts/{artifact_id}/zip"
    deadline = time.monotonic() + 5 * 60
    length = stream_cache_range(endpoint, 0, 0, io.BytesIO(), deadline)
    count = min(os.cpu_count() or 1, length)
    with destination.open("wb") as output:
        output.truncate(length)

    def read_part(index):
        start, end = length * index // count, length * (index + 1) // count - 1
        with destination.open("r+b") as output:
            output.seek(start)
            stream_cache_range(endpoint, start, end, output, deadline, total=length)

    with ThreadPoolExecutor() as pool:
        list(pool.map(read_part, range(count)))


def stream_cache_range(
    endpoint: str, start: int, end: int, output, deadline: float, *, total: int | None = None
) -> int:
    import http.client
    import shutil
    import time
    from threading import Timer

    command = [
        "gh",
        "api",
        "--allow-escape-sequences",
        "--include",
        "-H",
        f"Range: bytes={start}-{end}",
        endpoint,
    ]
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    with (
        (CACHE_ROOT / "compilation-cache.log").open("ab") as diagnostic,
        subprocess.Popen(command, stdout=subprocess.PIPE, stderr=diagnostic) as process,
    ):
        timer = Timer(max(0, deadline - time.monotonic()), process.kill)
        timer.start()
        try:
            status = process.stdout.readline(http.client._MAXLINE + 1).split()
            if len(status) < 2 or status[1] != b"206":
                observed = status[1].decode(errors="replace") if len(status) > 1 else "未收到状态"
                raise ValueError(f"编译缓存响应需要 HTTP 206，实际为 {observed}。")
            headers = http.client.parse_headers(process.stdout)
            size = re.fullmatch(
                rf"bytes {start}-{end}/([1-9][0-9]*)", headers.get("Content-Range", "")
            )
            if size is None or int(size[1]) <= end or total is not None and int(size[1]) != total:
                raise ValueError("编译缓存响应需要匹配请求的分段范围。")
            remaining = end - start + 1
            while remaining:
                block = process.stdout.read(min(shutil.COPY_BUFSIZE, remaining))
                if not block:
                    raise ValueError("编译缓存分段需要包含请求的全部字节。")
                output.write(block)
                remaining -= len(block)
            if process.stdout.read(1):
                raise ValueError("编译缓存分段需要遵循请求的字节边界。")
            process.wait(timeout=max(0, deadline - time.monotonic()))
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, command)
            return int(size[1])
        except (http.client.HTTPException, ValueError) as error:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(command, 0) from error
            if isinstance(error, http.client.HTTPException):
                raise ValueError("编译缓存响应需要完整且有界的 HTTP 头。") from error
            raise
        finally:
            timer.cancel()
            if process.poll() is None:
                process.kill()


def cache_download_self_test() -> None:
    import io
    import time
    from unittest.mock import patch

    data = b"0123456789ab\x1b[31m"
    destination = ROOT / ".build/static-audit/cache-download-self-test"
    destination.parent.mkdir(parents=True, exist_ok=True)
    observed = []

    class Body(io.BytesIO):
        reads = 0

        def read(self, *args):
            self.reads += 1
            return super().read(*args)

    class Probe:
        returncode = 0

        def __init__(self, raw):
            self.stdout = Body(raw)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.stdout.close()

        def poll(self):
            return self.returncode

        def wait(self, **kwargs):
            return self.returncode

        def kill(self):
            self.returncode = -9

    def response(command, **kwargs):
        assert "--allow-escape-sequences" in command and "--include" in command
        assert command[-1] == "repos/owner/repo/actions/artifacts/7/zip"
        match = re.fullmatch(r"Range: bytes=(\d+)-(\d+)", command[command.index("-H") + 1])
        start, end = map(int, match.groups())
        observed.append((start, end))
        return Probe(
            (
                f"HTTP/2.0 206 Partial Content\r\nContent-Range: bytes "
                f"{start}"
                f"-"
                f"{end}"
                f"/"
                f"{len(data)}"
                f"\r\n\r\n"
            ).encode()
            + data[start : end + 1]
        )

    probe = b"HTTP/2.0 206 Partial Content\r\nContent-Range: bytes 0-0/17\r\n\r\n0"
    try:
        for cores in (1, 3, 32):
            observed.clear()
            with (
                patch.object(os, "cpu_count", return_value=cores),
                patch.object(subprocess, "Popen", side_effect=response),
            ):
                download_cache_payload("owner/repo", 7, destination)
                assert destination.read_bytes() == data
            assert observed.pop(0) == (0, 0)
            assert [
                offset for start, end in sorted(observed) for offset in range(start, end + 1)
            ] == list(range(len(data)))
        for invalid in (
            probe.replace(b"206", b"200"),
            probe.replace(b"0-0/17", b"0-1/17"),
            probe[:-1],
        ):
            process = Probe(invalid)
            with patch.object(subprocess, "Popen", return_value=process):
                try:
                    download_cache_payload("owner/repo", 7, destination)
                except ValueError:
                    pass
                else:
                    raise AssertionError("分段协议需要有效状态、范围与完整数据。")
            if b"200" in invalid:
                assert process.stdout.reads == 0
        for suffix in (b"", b"overflow"):

            def invalid_segment(command, **kwargs):
                process = response(command, **kwargs)
                if len(observed) > 1:
                    raw = process.stdout.getvalue()
                    process.stdout = Body(raw[:-1] if not suffix else raw + suffix)
                return process

            observed.clear()
            with (
                patch.object(os, "cpu_count", return_value=3),
                patch.object(subprocess, "Popen", side_effect=invalid_segment),
            ):
                try:
                    download_cache_payload("owner/repo", 7, destination)
                except ValueError:
                    pass
                else:
                    raise AssertionError("分段需要按字节边界结束恢复。")
            assert destination.stat().st_size == len(data)
        original = subprocess.Popen
        for initial in (probe, b""):

            def stalled(command, **kwargs):
                return original(
                    [
                        sys.executable,
                        "-c",
                        (
                            f"import sys,time; sys.stdout.buffer.write("
                            f"{initial!r}"
                            f"); sys.stdout.flush(); time.sleep(60)"
                        ),
                    ],
                    **kwargs,
                )

            started = time.monotonic()
            with patch.object(subprocess, "Popen", side_effect=stalled):
                try:
                    stream_cache_range("fixture", 0, 0, io.BytesIO(), started + 0.2)
                except subprocess.SubprocessError:
                    pass
                else:
                    raise AssertionError("缓存下载需要在共享期限内结束。")
            assert time.monotonic() - started < 5
    finally:
        destination.unlink(missing_ok=True)


def cache_self_test() -> None:
    import io
    import zipfile
    from contextlib import redirect_stdout
    from unittest.mock import patch

    module = sys.modules[__name__]
    cache_download_self_test()
    for failure in (
        subprocess.CalledProcessError(1, ["gh", "api"], stderr="Forbidden (HTTP 403)"),
        subprocess.TimeoutExpired(["gh", "api"], 1),
        OSError("cache unavailable"),
        ValueError("invalid metadata"),
        KeyError("cache metadata"),
        zipfile.BadZipFile("truncated cache"),
    ):
        with (
            patch.object(Path, "mkdir"),
            patch.object(Path, "open"),
            patch.object(Path, "exists", return_value=False),
            patch("fcntl.flock"),
            patch.object(module, "native_cache_available", return_value=False),
            patch.object(module, "restore_remote_cache", side_effect=failure) as restore,
            redirect_stdout(io.StringIO()) as output,
        ):
            restore_cache("simulator-app")
            restore.assert_called_once_with("simulator-app")
            assert "沿当前源码重新编译" in output.getvalue()
            if isinstance(failure, subprocess.CalledProcessError):
                assert (
                    "Forbidden (HTTP 403)" in output.getvalue()
                    and "compilation-cache.log" in output.getvalue()
                )
    with (
        patch.object(Path, "mkdir"),
        patch.object(Path, "open"),
        patch.object(Path, "exists", return_value=True),
        patch("fcntl.flock"),
        patch.object(module, "native_cache_available", return_value=True),
        patch.object(module, "restore_remote_cache") as restore,
        redirect_stdout(io.StringIO()),
    ):
        restore_cache("simulator-app")
        restore.assert_not_called()
    identity = {"toolchain": "compiler", "architecture": "arm64"}

    def payload(
        name=CACHE_STORE + "/data", *, context=identity, link=False, tools=False, space=None
    ):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
            metadata = dict(identity=context, flavor="simulator-app")
            if space is not None:
                metadata["space"] = space
            archive.writestr(CACHE_METADATA, json.dumps(metadata))
            entry = zipfile.ZipInfo(name)
            if link:
                entry.external_attr = 0o120777 << 16
            archive.writestr(entry, b"compiled")
            if tools:
                for tool in sorted(CACHE_TOOLS):
                    archive.writestr(tool, tool.encode())
        buffer.seek(0)
        return buffer

    transferred = []
    with (
        patch.object(module, "cache_identity", return_value=identity),
        patch.object(Path, "mkdir"),
        patch.object(Path, "open"),
        patch.object(Path, "chmod") as permissions,
        patch.object(
            shutil,
            "copyfileobj",
            side_effect=lambda source, target: transferred.append(source.read()),
        ) as copied,
    ):
        assert restore_cache_payload(payload(), "simulator-app")
        assert transferred == [b"compiled"]
        assert restore_cache_payload(payload(tools=True), "simulator-app")
        assert transferred[1:] == [b"compiled", *(name.encode() for name in sorted(CACHE_TOOLS))]
        permissions.assert_called_once_with(0o755)
        assert restore_cache_payload(payload(space={"projectBytes": 123}), "simulator-app")
        copied.reset_mock()
        assert not restore_cache_payload(payload(context={}), "simulator-app")
        assert not restore_cache_payload(payload(), "catalyst-tests")
        copied.assert_not_called()
    with (
        patch.object(module, "cache_identity", return_value=identity),
        patch.object(Path, "is_dir", return_value=True),
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_text", return_value='{"space":{"projectBytes":123}}'),
        patch.object(Path, "rglob", return_value=[]),
        patch.object(Path, "stat", return_value=type("Stat", (), {"st_size": 1})()),
        patch.object(Path, "write_text") as saved,
        redirect_stdout(io.StringIO()),
    ):
        export_cache("simulator-app")
        assert json.loads(saved.call_args.args[0]) == dict(
            identity=identity, flavor="simulator-app", space={"projectBytes": 123}
        )
        for name, link in [
            ("../escape", False),
            ("/escape", False),
            (CACHE_STORE + "/../escape", False),
            (CACHE_STORE, False),
            (CACHE_STORE + "/link", True),
            ("swift-syntax-indexer", False),
            ("swift-syntax-indexer/escape", False),
        ]:
            try:
                restore_cache_payload(payload(name, link=link), "simulator-app")
            except ValueError:
                pass
            else:
                raise AssertionError(name)
        copied.assert_not_called()
    trusted = dict(
        event="push",
        head_branch="main",
        head_repository={"full_name": "owner/repo"},
        path=".github/workflows/ci.yml",
        head_sha="a" * 40,
        id=1,
    )
    artifact = dict(
        id=1, name="compilation-cache-simulator-app", expired=False, workflow_run={"id": 1}
    )
    for change, ancestor, accepted in [
        ({}, 0, True),
        ({"event": "workflow_dispatch"}, 0, True),
        ({"event": "pull_request"}, 0, False),
        ({"head_branch": "feature"}, 0, False),
        ({"head_repository": None}, 0, False),
        ({"head_repository": {"full_name": "fork/repo"}}, 0, False),
        ({"path": "other.yml"}, 0, False),
        ({"head_sha": "invalid"}, 0, False),
        ({}, 1, False),
    ]:

        def response(command, **kwargs):
            return (
                payload() if command[-1].endswith("/zip") else json.dumps(dict(trusted, **change))
            )

        with (
            patch.object(module, "repository", return_value="owner/repo"),
            patch.object(module, "api_pages", return_value=[{"artifacts": [artifact]}]),
            patch.object(Path, "mkdir"),
            patch.object(Path, "open"),
            patch.object(Path, "exists", return_value=False),
            patch("fcntl.flock"),
            patch.object(module, "native_cache_available", return_value=False),
            patch.object(subprocess, "check_output", side_effect=response),
            patch.object(module, "download_cache_payload", return_value=payload()) as downloaded,
            patch.object(module, "cache_result_matches", return_value=True),
            patch.object(subprocess, "run", return_value=SimpleNamespace(returncode=ancestor)),
            patch.object(module, "restore_cache_payload", return_value=True) as restored,
            redirect_stdout(io.StringIO()),
        ):
            restore_cache("simulator-app")
            assert restored.called == downloaded.called == accepted, (change, ancestor)
    with (
        patch.object(module, "repository", return_value="owner/repo"),
        patch.object(
            module, "api_pages", return_value=[{"artifacts": [artifact, dict(artifact, id=2)]}]
        ),
        patch.object(subprocess, "check_output", return_value=json.dumps(trusted)),
        patch.object(subprocess, "run", return_value=SimpleNamespace(returncode=0)),
        patch.object(module, "download_cache_payload") as downloaded,
        patch.object(Path, "unlink") as cleanup,
        patch.object(module, "cache_result_matches", side_effect=[False, True]),
        patch.object(module, "restore_cache_payload", return_value=True) as restored,
        redirect_stdout(io.StringIO()),
    ):
        restore_remote_cache("simulator-app")
        assert [call.args[1] for call in downloaded.call_args_list] == [1]
        assert restored.call_count == cleanup.call_count == 1
    result = {
        "schemaVersion": 1,
        "commit": trusted["head_sha"],
        "run": "1",
        "groups": {
            "app": {
                "passed": True,
                "environment": {
                    "toolchain": identity["toolchain"],
                    "host": {"architecture": identity["architecture"]},
                },
            }
        },
    }
    for fault in ("none", "toolchain", "architecture", "commit", "run", "failed", "missing"):
        import copy

        changed = copy.deepcopy(result)
        if fault in {"toolchain", "architecture"}:
            environment = changed["groups"]["app"]["environment"]
            if fault == "toolchain":
                environment["toolchain"] = {}
            else:
                environment["host"]["architecture"] = "other"
        elif fault in {"commit", "run"}:
            changed[fault] = "other"
        elif fault == "failed":
            changed["groups"]["app"]["passed"] = False
        with (
            patch.object(
                module,
                "api_pages",
                return_value=[
                    {"artifacts": [{"id": 2, "name": "verified-result-ios", "expired": False}]}
                ],
            ),
            patch.object(
                module,
                "read_validation_result",
                return_value=None if fault == "missing" else changed,
            ),
            patch.object(module, "cache_identity", return_value=identity),
        ):
            assert cache_result_matches("owner/repo", trusted, "simulator-app") == (
                None if fault == "missing" else fault == "none"
            ), fault
    artifacts = [
        dict(id=index, name=name, expired=False, workflow_run={"id": 1})
        for index, name in [
            (1, "compilation-cache-simulator-app"),
            (2, "validation-static-audit"),
            (3, "compilation-cache-simulator-app"),
            (4, "compilation-cache-catalyst-tests"),
        ]
    ]
    artifacts.append(
        dict(id=5, name="compilation-cache-simulator-app", expired=False, workflow_run={"id": 2})
    )
    artifacts.append(
        dict(id=6, name="compilation-cache-unused", expired=False, workflow_run={"id": 1})
    )
    artifacts.extend(
        dict(id=index, name="ui-test-host", expired=False, workflow_run={"id": run})
        for index, run in ((7, 1), (8, 2))
    )

    def producer(command, **kwargs):
        return json.dumps(
            dict(trusted, head_repository={"full_name": "fork/repo"})
            if command[-1].endswith("/2")
            else trusted
        )

    with (
        patch.dict(os.environ, GITHUB_RUN_ID="1"),
        patch.object(module, "repository", return_value="owner/repo"),
        patch.object(module, "api_pages", return_value=[{"artifacts": artifacts}]),
        patch.object(subprocess, "check_output", side_effect=producer),
        patch.object(module, "cache_result_matches", return_value=True),
        patch.object(subprocess, "run", return_value=SimpleNamespace(returncode=0)) as deleted,
    ):
        prune_caches()
        assert [call.args[0][-1] for call in deleted.call_args_list] == [
            f"repos/owner/repo/actions/artifacts/{index}" for index in (7, 6, 5, 1)
        ]
    for code, error in (
        (1, "gh: Not Found (HTTP 404)"),
        (1, "gh: Forbidden (HTTP 403)"),
        (1, "connection failed"),
    ):

        def deleted_artifact(command, **kwargs):
            return subprocess.CompletedProcess(command, code, "", error)

        with (
            patch.object(module, "repository", return_value="owner/repo"),
            patch.object(module, "api_pages", return_value=[{"artifacts": artifacts}]),
            patch.object(subprocess, "check_output", side_effect=producer),
            patch.object(module, "cache_result_matches", return_value=True),
            patch.object(subprocess, "run", side_effect=deleted_artifact),
        ):
            try:
                prune_caches()
            except subprocess.CalledProcessError as failure:
                assert failure.stderr == error and "(HTTP 404)" not in error
            else:
                assert "(HTTP 404)" in error


def repository() -> str:
    value = (
        os.getenv("GITHUB_REPOSITORY")
        or subprocess.check_output(
            ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            cwd=ROOT,
            text=True,
        ).strip()
    )
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", value):
        raise ValueError("证据交换需要有效 GitHub 仓库身份。")
    return value


def api_pages(endpoint: str) -> list[dict]:
    return json.loads(
        subprocess.check_output(
            ["gh", "api", "--paginate", "--slurp", endpoint], cwd=ROOT, text=True
        )
    )
