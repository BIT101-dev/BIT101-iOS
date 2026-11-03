"""Exercise bounded development artifacts through their public Python APIs."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
from contextlib import closing, redirect_stdout, redirect_stderr
from io import StringIO
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]

from workflow_result_tests import (
    incremental_archives as incremental_archives,
    focused_result_retention as focused_result_retention,
    full_result_batches as full_result_batches,
    result_readers as result_readers,
    archive_prune_then_fetch as archive_prune_then_fetch,
    cache_cleanup_after_failure as cache_cleanup_after_failure,
    audit_failure_summary as audit_failure_summary,
    changed_staged_scripts as changed_staged_scripts,
    immediate_audit_output as immediate_audit_output,
    native_target_inventory_self_test as native_target_inventory_self_test,
)


def development_workflow_self_test() -> None:
    fixture = ROOT / ".build/static-audit/development-workflow-self-test"
    shutil.rmtree(fixture, ignore_errors=True)
    fixture.mkdir(parents=True)
    try:
        interrupted_self_test_recovery(fixture)
        cache_and_ui_products(fixture)
        incremental_archives(fixture)
        focused_result_retention(fixture)
        full_result_batches(fixture)
        shared_source_facts(fixture)
        audit_self_test_selection()
        result_readers(fixture)
        archive_prune_then_fetch(fixture)
        cache_cleanup_after_failure()
        audit_failure_summary(fixture)
        changed_staged_scripts(fixture)
        immediate_audit_output(fixture)
        ci_diagnostic_selection(fixture)
        readiness_diagnostics(fixture)
        mac_process_identity(fixture)
    finally:
        shutil.rmtree(fixture, ignore_errors=True)


def interrupted_self_test_recovery(fixture: Path) -> None:
    from validation_artifacts import main as audit_artifacts

    folder = fixture / ".build/static-audit"
    for name in ("source-identity-self-test", "simulator-startup-self-test"):
        residual = folder / name
        residual.mkdir(parents=True)
        (residual / "interrupted.log").write_text("interrupted producer")
    retained = folder / "checkers.log"
    retained.write_text("current diagnostics")
    audit_artifacts(fixture)
    assert sorted(path.name for path in folder.iterdir()) == [
        "checkers.log",
        "compilation-conditions.lock",
    ]
    assert retained.read_text() == "current diagnostics"


def shared_source_facts(fixture: Path) -> None:
    import fcntl
    import sqlite3
    from copy import deepcopy
    import swift_source_index as subject

    cache = fixture / "source-facts.sqlite"
    path = ROOT / "Modules/CommunityCore/Sources/CommunityTextLimits.swift"
    source = path.read_text()
    with closing(sqlite3.connect(cache)) as database, database:
        database.execute("CREATE TABLE facts (path TEXT PRIMARY KEY, content TEXT)")
        database.execute("INSERT INTO facts VALUES (?, ?)", (str(path), "legacy facts"))
    with (
        patch.dict(os.environ, BIT101_SOURCE_FACTS_CACHE=str(cache)),
        patch.object(
            subject, "_run_swift_syntax_index", wraps=subject._run_swift_syntax_index
        ) as parse,
    ):
        first = subject.swift_syntax_index_sources({str(path): source})[str(path)]
        expected = deepcopy(first)
        original_scope = list(first["invocations"][0]["scope"])
        first["calls"][0]["scope"].append("ChangedCall")
        assert first["invocations"][0]["scope"] == original_scope
        first["declarations"].append(first["declarations"][0])
        assert subject.swift_syntax_index_sources({str(path): source})[str(path)] == expected
        first = expected
        with closing(sqlite3.connect(cache)) as database:
            stored = database.execute(
                "SELECT content FROM facts WHERE path = ?", (str(path),)
            ).fetchone()[0]
        assert (
            all(type(position) is int for position in json.loads(stored)["calls"])
            and "$source" in stored
        )
        with closing(sqlite3.connect(cache)) as database, database:
            database.execute(
                "INSERT INTO facts VALUES (?, ?, ?)", ("unrequested.swift", "", "invalid JSON")
            )
        relative = str(path.relative_to(ROOT))
        assert (
            subject.swift_syntax_index_sources({relative: source})[relative] == first
            and parse.call_count == 1
        )
        with patch.dict(os.environ), patch.object(subject, "DEFAULT_FACTS_CACHE", cache):
            os.environ.pop("BIT101_SOURCE_FACTS_CACHE", None)
            assert (
                subject.swift_syntax_index_sources({relative: source})[relative] == first
                and parse.call_count == 1
            )
        aliases = subject.swift_syntax_index_sources({str(path): source, relative: source})
        assert aliases[str(path)] == aliases[relative] == first
        aliases[str(path)]["calls"][0]["scope"].append("ChangedAlias")
        assert aliases[relative] == first
        with closing(sqlite3.connect(cache)) as database:
            assert (
                database.execute(
                    "SELECT path FROM facts WHERE path = 'unrequested.swift'"
                ).fetchone()
                is None
            )
        assert (
            subject.swift_syntax_index_sources({relative: source + "\n"})[relative]["source"]
            == source + "\n"
        )
        assert parse.call_count == 2
        assert (
            subject.swift_syntax_index_sources({relative: source})[relative] == first
            and parse.call_count == 2
        )
        program = f"""import fcntl,sys
sys.path.insert(0, {str(ROOT / "Scripts")!r})
import swift_source_index as source
original = fcntl.flock
def observe(lock, operation):
    print('locking', flush=True)
    return original(lock, operation)
fcntl.flock = observe
def unexpected_parse(*args, **kwargs): raise AssertionError('shared facts')
source._run_swift_syntax_index = unexpected_parse
assert source.swift_syntax_index([source.Path({str(path)!r})])
print('done', flush=True)
"""
        with cache.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with closing(sqlite3.connect(cache)) as database, database:
                database.execute("UPDATE facts SET content = ? WHERE path = ?", ("{", str(path)))
            reader = subprocess.Popen(
                [os.sys.executable, "-B", "-c", program],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                assert reader.stdout.readline().strip() == "locking"
                with closing(sqlite3.connect(cache)) as database, database:
                    database.execute(
                        "UPDATE facts SET content = ? WHERE path = ?", (stored, str(path))
                    )
                fcntl.flock(lock, fcntl.LOCK_UN)
                output, error = reader.communicate(timeout=5)
                assert reader.returncode == 0 and output.strip() == "done", error
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                if reader.poll() is None:
                    reader.kill()
                reader.communicate(timeout=5)
        base = ROOT / "BIT101-iOSUITests/UIAutomationTestCase.swift"
        derived = ROOT / "BIT101-iOSUITests/CommunityPublishingUITests.swift"
        derived_source = {str(derived): derived.read_text()}
        assert not subject.swift_syntax_index_sources(derived_source)[str(derived)]["tests"]

        calls = parse.call_count
        with patch.object(subject, "source_facts_signature", return_value="changed indexer"):
            assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
            assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
            assert parse.call_count == calls + 1
        assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        assert parse.call_count == calls + 2
        read_bytes = Path.read_bytes
        changed = source + "\n"
        with patch.object(
            Path, "read_bytes", lambda file: changed.encode() if file == path else read_bytes(file)
        ):
            assert (
                subject.swift_syntax_index_sources({relative: changed})[relative]["source"]
                == changed
            )
            assert (
                subject.swift_syntax_index_sources({relative: changed})[relative]["source"]
                == changed
            )
            assert parse.call_count == calls + 3
        assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        assert parse.call_count == calls + 4
        joined = subject.swift_syntax_index_sources(derived_source | {str(base): base.read_text()})
        assert joined[str(derived)]["tests"]
        assert not subject.swift_syntax_index_sources(derived_source)[str(derived)]["tests"]

        transformed = source + "\n"
        calls = parse.call_count
        for _ in range(2):
            for context, version in (
                ("tests:app", transformed),
                ("tests:release", transformed + "\n"),
            ):
                assert (
                    subject.swift_syntax_index_sources({relative: version}, cache_context=context)[
                        relative
                    ]["source"]
                    == version
                )
            assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        assert parse.call_count == calls + 2
        cache.write_bytes(b"invalid SQLite cache")
        assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        with closing(sqlite3.connect(cache)) as database, database:
            database.execute("UPDATE facts SET content = ? WHERE path = ?", ("{", str(path)))
        assert subject.swift_syntax_index_sources({relative: source})[relative] == expected
        retained = cache.read_bytes()
        failure = sqlite3.OperationalError("read-only cache")
        failure.sqlite_errorcode = sqlite3.SQLITE_READONLY
        with patch.object(sqlite3, "connect", side_effect=failure):
            try:
                subject.swift_syntax_index_sources({relative: source})
            except sqlite3.OperationalError:
                pass
            else:
                raise AssertionError("缓存存储权限故障需要保留诊断。")
        assert cache.read_bytes() == retained

    source = """struct Access {
        subscript(index: Int) -> Int { index }
        func `subscript`(_ index: Int) -> Int { index }
        func read() { _ = self[0]; _ = self.`subscript`(1); print("中文") }
    }"""
    facts = subject.swift_syntax_index_sources({"call-kind-fixture.swift": source})[
        "call-kind-fixture.swift"
    ]
    assert len([call for call in facts["calls"] if call["value"] == "self.subscript"]) == 1
    assert (
        len([call for call in facts["invocations"] if call["calledExpression"] == "self.subscript"])
        == 2
    )
    assert facts["source"] == source and any(
        row["value"] == "中文" for row in facts["stringSegments"]
    )


def audit_self_test_selection() -> None:
    from script_test_support import shell_function

    function = shell_function(ROOT / "Scripts/script-support.sh", "bit101_checker_audit")
    for enabled in ("0", "1"):
        script = (
            f"ROOT_DIR=/fixture BIT101_AUDIT_SELF_TESTS="
            f"{enabled}"
            f'\npython3() {{ print -r -- "$*"; }}\n'
        )
        result = subprocess.run(
            ["zsh", "-c", script + function + "\nbit101_checker_audit"],
            capture_output=True,
            text=True,
            check=True,
        )
        assert "check-code-quality.py --combined" in result.stdout
        assert ("validation_evidence.py self-test" in result.stdout) == (enabled == "1")
        assert ("--combined --self-test" in result.stdout) == (enabled == "1")
    script = (
        'ROOT_DIR=/fixture BIT101_AUDIT_SELF_TESTS=1\npython3() { case "$1" in */validation_eviden'
        "ce.py) return 7;; */check-code-quality.py) return 137;; esac; }\n"
    )
    failed = subprocess.run(
        ["zsh", "-c", script + function + "\nbit101_checker_audit"], capture_output=True, text=True
    )
    assert failed.returncode == 1
    assert "[失败] 验证证据自测 · 退出状态 7" in failed.stderr
    assert "[失败] 源码与 UI 检查 · 退出状态 137" in failed.stderr
    source = (ROOT / "Scripts/run-static-audit.sh").read_text()
    parser = source[source.index("set -euo pipefail") : source.index("\nROOT_DIR=")]
    lock_selection = source[
        source.index("if (( run_artifacts ||") : source.index(
            'bit101_acquire_script_lock "$ROOT_DIR/.build/static-audit/audit.lock"'
        )
    ]
    for arguments, expected in [
        ([], True),
        (["docs", "python-parse"], False),
        (["--self-test", "docs"], False),
        (["shell-parse", "worker-parse", "dependency-audit", "git-diff"], False),
        (["swift-parse"], True),
        (["module-boundary"], True),
        (["checkers"], True),
        (["artifact-hygiene"], True),
    ]:
        result = subprocess.run(
            [
                "zsh",
                "-c",
                parser + "\nbit101_acquire_artifact_lock() { print acquired; }\n" + lock_selection,
                "audit-lock-selection",
                *arguments,
            ],
            env=dict(os.environ, GITHUB_ACTIONS="false", BIT101_RELEASE_CHECK="false"),
            capture_output=True,
            text=True,
            check=True,
        )
        assert ("acquired" in result.stdout) == expected, (arguments, result.stdout)
    for arguments, expected in [
        ([], "1:9:9:0"),
        (["docs", "python-parse", "docs"], "0:2:2:0"),
        (["artifact-hygiene"], "0:0:0:0"),
        (["--self-test", "docs"], "0:1:1:1"),
    ]:
        result = subprocess.run(
            [
                "zsh",
                "-c",
                parser
                + (
                    '\nprint -r -- "$full_audit:${#group_names}:${#group_commands}:$self_tests_req'
                    'uested"'
                ),
                "audit-selection",
                *arguments,
            ],
            env=dict(os.environ, GITHUB_ACTIONS="false", BIT101_RELEASE_CHECK="false"),
            capture_output=True,
            text=True,
            check=True,
        )
        assert result.stdout.strip() == expected, result.stdout
    for arguments, environment in [
        (["unknown-group"], {}),
        (["prepare", "docs"], {}),
        (["docs"], {"GITHUB_ACTIONS": "true"}),
        (["docs"], {"BIT101_RELEASE_CHECK": "true"}),
    ]:
        result = subprocess.run(
            ["zsh", str(ROOT / "Scripts/run-static-audit.sh"), *arguments],
            env=dict(os.environ, **environment),
            capture_output=True,
            text=True,
        )
        assert result.returncode == 64, (arguments, result.stdout, result.stderr)


def ci_diagnostic_selection(fixture: Path) -> None:
    import ci_diagnostics as subject

    log = fixture / "compiler.log"
    log.write_text("[1/2] error: fixture compiler failure\n" + "progress\n" * 200)
    private = fixture / "private.txt"
    private.write_text("fixture private attachment")
    bundle = fixture / "test-results.xcresult"
    bundle.mkdir()
    (bundle / "data.txt").write_text("fixture binary bundle")
    excerpt = subject.cancellation_excerpt("compiler.log\ntest-results.xcresult", root=fixture)
    assert "fixture compiler failure" in excerpt
    assert "fixture private attachment" not in excerpt and "fixture binary bundle" not in excerpt
    log.write_text("error: " + "x" * (subject.BYTE_LIMIT * 2))
    assert (
        len(subject.cancellation_excerpt("compiler.log", root=fixture).encode())
        <= subject.BYTE_LIMIT
    )
    for cancelled, expected in [
        ("true", subject.REPORT),
        ("false", "compiler.log\ntest-results.xcresult"),
    ]:
        output = fixture / "workflow-output"
        output.write_text("")
        with (
            patch.object(subject, "ROOT", fixture),
            patch.dict(
                os.environ,
                BIT101_DIAGNOSTIC_PATHS="compiler.log\ntest-results.xcresult",
                BIT101_CI_CANCELLED=cancelled,
                GITHUB_OUTPUT=str(output),
            ),
        ):
            subject.main()
        assert (
            output.read_text()
            == "paths<<BIT101_DIAGNOSTIC_PATHS\n" + expected + "\nBIT101_DIAGNOSTIC_PATHS\n"
        )
        assert (fixture / subject.REPORT).exists() == (cancelled == "true")


def mac_process_identity(fixture: Path) -> None:
    import sys

    app = fixture / "Mac App [fixture].app"
    executable = app / "Contents/MacOS/BIT101-iOS"
    executable.parent.mkdir(parents=True)
    shutil.copyfile("/bin/sleep", executable)
    executable.chmod(0o755)
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", str(executable)],
        capture_output=True,
        check=True,
    )
    owned = subprocess.Popen(
        [str(executable), "60"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    decoy = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)", str(executable)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        result = subprocess.run(
            [sys.executable, str(ROOT / "Scripts/validation_restore.py"), "mac-pids", str(app)],
            capture_output=True,
            text=True,
            check=True,
        )
        assert list(map(int, result.stdout.split())) == [owned.pid] and not result.stderr
    finally:
        owned.terminate()
        decoy.terminate()
        owned.wait(timeout=5)
        decoy.wait(timeout=5)


def readiness_diagnostics(fixture: Path) -> None:
    import shlex
    import sys
    from textwrap import dedent
    import validation_restore as subject

    missing = fixture / "missing-readiness.json"
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "Scripts/validation_restore.py"),
            "mac-ready",
            "/fixture/App.app",
            str(missing),
            "run",
            "source",
        ],
        capture_output=True,
        text=True,
    )
    assert (
        result.returncode == 1
        and "FileNotFoundError" in result.stderr
        and str(missing) in result.stderr
    )
    ready = dict(
        schemaVersion=1,
        runID="fixture",
        initialized=False,
        sessionRecovered=False,
        active=False,
        processIdentifier=1,
        readyAt="2000-01-01T00:00:00Z",
    )
    with (
        patch.object(Path, "read_text", return_value=json.dumps(ready)),
        patch.object(Path, "read_bytes", return_value=plistlib.dumps({})),
        patch.object(subject.subprocess, "run", return_value=Mock(returncode=1, stdout="")),
        redirect_stderr(diagnostic := StringIO()),
    ):
        assert not subject.mac_ready(
            Path("/fixture/App.app"), missing, "run", "source", diagnose=True
        )
    state = json.loads(diagnostic.getvalue().split("：", 1)[1])
    assert (
        state["App身份"] is False
        and state["初始化"] is False
        and state["进程存活"] is False
        and state["采样有效"] is False
    )
    source = (ROOT / "Scripts/build-install-device.sh").read_text()
    device = source[source.index("restore_deadline=") :]
    mac = dedent(source[source.index("  mac_deadline=") : source.index("\nfi\n\nBUILD_OVERRIDES=")])
    log = fixture / "restore.log"
    for platform, block, failures in [
        ("device", device, ("copy", "process", "probe", "success")),
        ("mac", mac, ("probe", "success")),
    ]:
        for failure in failures:
            log.write_text("old readiness failure")
            harness = (
                f"set -euo pipefail\nROOT_DIR="
                f"{shlex.quote(str(ROOT))}"
                f" RESTORE_LOG="
                f"{shlex.quote(str(log))}"
                f" DERIVED_DATA="
                f"{shlex.quote(str(fixture))}"
                f"\nBIT101_DEVICETCL_DEVICE_ID=fixture BIT101_VALIDATION_RUN_ID=fi"
                f"xture BIT101_VALIDATION_INPUT_IDENTITY=fixture BIT101_DEVICE_NAM"
                f"E=fixture\nINSTALL_PATH=/fixture/App.app MAC_READINESS=/fixture/"
                f"proof MAC_RUN_ID=fixture MAC_INPUT_DIGEST=fixture\nfailure="
                f"{shlex.quote(failure)}"
                f"""\nxcrun() {{\n  if [[ "$failure" == copy && "$*" == *'copy from"""
                f"'* ]]; then print -u2 'fixture copy failed'; return 1; fi\n  if "
                f"""[[ "$failure" == process && "$*" == *'info processes'* ]]; the"""
                f"n print -u2 'fixture process sample failed'; return 1; fi\n  ret"
                f'urn 0\n}}\npython3() {{\n  if [[ "$1" == */validation_restore.py ]'
                f"""]; then\n    if [[ "$failure" == probe ]]; then print -u2 'fixt"""
                f"ure initialization pending'; return 1; fi\n    return 0\n  fi\n "
                f' command python3 "$@"\n}}\nsleep() {{ SECONDS=$(( SECONDS + 60 ));'
                f" }}\n"
            )
            result = subprocess.run(["zsh", "-c", harness + block], capture_output=True, text=True)
            assert result.returncode == (0 if failure == "success" else 1), (
                platform,
                failure,
                result.stderr,
            )
            assert "old readiness failure" not in log.read_text()
            if failure == "success":
                assert result.stderr == ""
            else:
                expected = {
                    "copy": "fixture copy failed",
                    "process": "fixture process sample failed",
                    "probe": "fixture initialization pending",
                }[failure]
                assert expected in result.stderr and str(log) in result.stderr, (
                    platform,
                    failure,
                    result.stderr,
                )


@patch.object(shutil, "disk_usage", new=lambda _: Mock(free=4 * 1024**3))
def cache_and_ui_products(fixture: Path) -> None:
    import ctypes
    from ci_evidence import native_cache_available
    from validation_artifacts import prune_native_cache_storage
    from test_results import ui_host_product_paths

    cache = fixture / "cache"
    native = cache / "CompilationCache.noindex"
    native.mkdir(parents=True)
    assert not native_cache_available(native)
    (native / "lock").touch()
    (native / "v1.validation").write_text("metadata")
    (native / ".DS_Store").write_text("Finder metadata")
    assert not native_cache_available(native)
    data = native / "generic/v1.1/data.v1"
    data.parent.mkdir(parents=True)
    data.write_bytes(b"active compilation records")
    assert native_cache_available(native)
    (cache / "Index.noindex/DataStore").mkdir(parents=True)
    library = Mock()
    library.indexstore_store_create.return_value = 1
    library.swiftscan_cas_options_create.return_value = 1
    library.swiftscan_cas_create_from_options.return_value = 2
    library.swiftscan_cas_get_ondisk_size.return_value = 1024
    library.swiftscan_cas_set_ondisk_size_limit.return_value = False

    def output(command, **kwargs):
        return "/active/usr/bin/swiftc\n" if command[0] == "xcrun" else "1\t" + str(native) + "\n"

    with (
        patch.object(subprocess, "run") as prune,
        patch.object(subprocess, "check_output", side_effect=output),
        patch.object(ctypes, "CDLL", return_value=library) as load,
    ):
        prune_native_cache_storage(cache)
    prune.assert_called_once_with(
        ["xcrun", "llvm-cas", "--cas=" + str(native / "generic"), "--prune"],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    assert [entry.args[0] for entry in load.call_args_list] == [
        "/active/usr/lib/swift/host/compiler/lib_InternalSwiftScan.dylib",
        "/active/usr/lib/libIndexStore.dylib",
    ]
    from validation_artifacts import CAS_STORE_LIMIT

    assert library.swiftscan_cas_set_ondisk_size_limit.call_args.args[1] == CAS_STORE_LIMIT
    library.swiftscan_cas_dispose.assert_called_once_with(2)
    library.indexstore_store_purge_stale_data.assert_called_once_with(1)
    library.indexstore_store_dispose.assert_called_once_with(1)
    assert data.read_bytes() == b"active compilation records"
    from compiler_cache import run_cache

    with (
        patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)),
        patch("validation_artifacts.cache_space_report", return_value={"projectBytes": 1}),
        patch("validation_artifacts.prune_compilation_cache", return_value=(0, 0)),
        patch("validation_artifacts.prune_native_storage") as automatic,
    ):
        try:
            run_cache([str(fixture), "build.log", "build", "xcodebuild", "build"])
        except SystemExit as status:
            assert status.code == 0
    automatic.assert_not_called()
    assert (
        json.loads((fixture / ".build/compiler-cache/compilation-cache.json").read_text())["space"][
            "projectBytes"
        ]
        > 0
    )
    import ci_cache_evidence as ci_evidence

    metadata = fixture / ".build/compiler-cache/compilation-cache.json"
    identity = {"toolchain": "compiler", "architecture": "arm64"}
    from validation_artifacts import record_cache_space

    with (
        patch.object(ci_evidence, "CACHE_ROOT", metadata.parent),
        patch.object(ci_evidence, "cache_identity", return_value=identity),
        redirect_stdout(StringIO()),
    ):
        ci_evidence.export_cache("simulator-app")
    saved = json.loads(metadata.read_text())
    assert (
        saved["identity"] == identity
        and saved["flavor"] == "simulator-app"
        and saved["space"]["projectBytes"] > 0
    )
    current = record_cache_space(fixture)
    saved = json.loads(metadata.read_text())
    assert (
        saved["identity"] == identity
        and saved["flavor"] == "simulator-app"
        and saved["space"] == current
    )
    assert saved["sampleFreeBytes"] > 0
    from validation_artifacts import cache_space_report

    measured = cache_space_report(fixture)
    assert measured["projectBytes"] > 0 and measured["casStoreLimitBytes"] == CAS_STORE_LIMIT
    original_run = subprocess.run

    def sample_after_build():
        def execute(command, **kwargs):
            return (
                subprocess.CompletedProcess(command, 0)
                if command[0] == "zsh"
                else original_run(command, **kwargs)
            )

        with (
            patch.object(subprocess, "run", side_effect=execute),
            patch("validation_artifacts.cache_maintenance_needed", return_value=True),
            patch("validation_artifacts.prune_compilation_cache", return_value=(0, 0)),
        ):
            try:
                run_cache([str(fixture), "build.log", "build", "xcodebuild", "build"])
            except SystemExit as status:
                assert status.code == 0
        return json.loads((fixture / ".build/compiler-cache/compilation-cache.json").read_text())[
            "space"
        ]

    before = sample_after_build()
    for name in (
        ".build/release-network-smoke/Build",
        ".build/icloud-cross-device-smoke/Phone/Build",
        ".build/icloud-cross-device-smoke/Mac/Build",
    ):
        product = fixture / name / "product"
        product.parent.mkdir(parents=True, exist_ok=True)
        product.write_bytes(b"product" * 4096)
    after = sample_after_build()
    assert (
        after["buildBytes"] > before["buildBytes"]
        and after["projectBytes"] > before["projectBytes"]
    )
    assert (
        json.loads((fixture / ".build/compiler-cache/compilation-cache.json").read_text())["space"]
        == after
    )
    for name in (
        ".build/extended-automation/test-results.xcresult",
        ".build/icloud-cross-device-smoke/test-results.xcresult",
    ):
        result = fixture / name / "result"
        result.parent.mkdir(parents=True, exist_ok=True)
        result.write_bytes(b"result" * 4096)
    assert sample_after_build()["diagnosticBytes"] > after["diagnosticBytes"]
    cache_maintenance_self_test(fixture)
    from compiler_cache import cache_layout_ready
    from validation_artifacts import cache_names

    derived = fixture / "ready"
    derived.mkdir()
    for name in cache_names:
        (derived / name).symlink_to(
            fixture / ".build/compiler-cache" / name, target_is_directory=True
        )
    assert cache_layout_ready(fixture / ".build/compiler-cache", [derived], ["xcodebuild", "build"])
    (derived / "Index.noindex").unlink()
    assert not cache_layout_ready(
        fixture / ".build/compiler-cache", [derived], ["xcodebuild", "build"]
    )
    from validation_artifacts import main as audit_artifacts
    import fcntl

    def locked_prune(shared):
        with (shared / "cache.lock").open("a") as other:
            try:
                fcntl.flock(other, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("原生回收持有缓存写锁。")
        raise OSError("cache busy")

    with (
        patch("validation_artifacts.cache_maintenance_needed", return_value=False),
        patch("validation_artifacts.prune_native_storage") as automatic,
        patch("validation_artifacts.record_cache_space") as sample,
    ):
        audit_artifacts(fixture)
    automatic.assert_not_called()
    sample.assert_not_called()
    with (
        patch("validation_artifacts.cache_maintenance_needed", return_value=True),
        patch("validation_artifacts.prune_native_storage", side_effect=locked_prune) as automatic,
        redirect_stderr(output := StringIO()),
    ):
        audit_artifacts(fixture)
    automatic.assert_called_once_with(fixture / ".build/compiler-cache")
    assert "缓存回收待重试" in output.getvalue()
    products = fixture / "products"
    products.mkdir()
    app = products / "Release-iphonesimulator/App.app"
    runner = products / "Release-iphonesimulator/Runner.app"
    watch = products / "Release-watchsimulator/Watch.app"
    unrelated = products / "Release-maccatalyst/Other.app"
    for path in (app, runner, watch, unrelated):
        path.mkdir(parents=True)
    target = dict(
        TestHostPath="__TESTROOT__/Release-iphonesimulator/Runner.app",
        UITargetAppPath="__TESTROOT__/Release-iphonesimulator/App.app",
        DependentProductPaths=[
            "__TESTROOT__/Release-watchsimulator/Watch.app",
            "__TESTROOT__/Release-iphonesimulator/Runner.app/PlugIns/tests.xctest",
        ],
    )
    plan = products / "BIT101-iOS-UIAutomation_fixture_iphonesimulator.xctestrun"
    plan.write_bytes(plistlib.dumps(dict(TestConfigurations=[dict(TestTargets=[target])])))
    assert set(ui_host_product_paths(products)) == {plan, app, runner, watch}
    target["TestHostPath"] = "__TESTROOT__/../Other.app"
    plan.write_bytes(plistlib.dumps(dict(TestConfigurations=[dict(TestTargets=[target])])))
    try:
        ui_host_product_paths(products)
    except ValueError:
        pass
    else:
        raise AssertionError("运行文件需要位于当前产品目录")
    from compiler_cache import discard_corrupt_compilation_cache

    log = fixture / "build.log"
    retained = cache / "Index.noindex/DataStore/active"
    retained.write_text("retained module metadata")
    log.write_text("error: unrelated compiler failure\n")
    assert not discard_corrupt_compilation_cache(cache, log)
    assert data.read_bytes() == b"active compilation records"
    log.write_text("LLVM ERROR: OnDiskCAS: corrupt internal reference\n")
    with redirect_stdout(StringIO()):
        assert discard_corrupt_compilation_cache(cache, log)
    assert native.is_dir() and list(native.iterdir()) == []
    assert retained.read_text() == "retained module metadata"

    def successful_build(command, **kwargs):
        return (
            subprocess.CompletedProcess(command, 0)
            if command[0] == "zsh"
            else original_run(command, **kwargs)
        )

    for free, requested, expected in (
        (4 * 1024**3, [], "YES"),
        (4 * 1024**3 - 1, [], "NO"),
        (0, ["COMPILATION_CACHE_ENABLE_CACHING=YES"], "YES"),
    ):
        with (
            patch.object(shutil, "disk_usage", return_value=Mock(free=free)),
            patch.object(subprocess, "run", side_effect=successful_build) as build,
            patch("validation_artifacts.cache_maintenance_needed", return_value=False),
            patch("validation_artifacts.prune_compilation_cache", return_value=(0, 0)),
            redirect_stdout(StringIO()),
        ):
            try:
                run_cache([str(fixture), "build.log", "build", "xcodebuild", "build", *requested])
            except SystemExit as status:
                assert status.code == 0
        commands = [call.args[0] for call in build.call_args_list if call.args[0][0] == "zsh"]
        assert len(commands) == 1 and f"COMPILATION_CACHE_ENABLE_CACHING={expected}" in commands[0]


def cache_maintenance_self_test(fixture: Path) -> None:
    import sqlite3
    import validation_artifacts as artifacts
    from compiler_cache import run_cache

    metadata = fixture / ".build/compiler-cache/compilation-cache.json"
    saved = json.loads(metadata.read_text())
    free = saved["sampleFreeBytes"]
    with patch.object(shutil, "disk_usage", return_value=type("Disk", (), {"free": free})()):
        assert not artifacts.cache_maintenance_needed(fixture)
    with patch.object(
        shutil,
        "disk_usage",
        return_value=type("Disk", (), {"free": free - artifacts.CACHE_GROWTH_INTERVAL})(),
    ):
        assert not artifacts.cache_maintenance_needed(fixture)
    with patch.object(
        artifacts,
        "build_database_bytes",
        return_value=saved["space"]["buildDatabaseBytes"] + artifacts.CACHE_GROWTH_INTERVAL,
    ):
        assert artifacts.cache_maintenance_needed(fixture)
    with (
        patch.object(
            subprocess,
            "check_output",
            return_value=str(
                (saved["space"]["casBytes"] + artifacts.CACHE_GROWTH_INTERVAL) // 1024
            ),
        ),
        patch.object(shutil, "disk_usage", return_value=type("Disk", (), {"free": free})()),
    ):
        assert artifacts.cache_maintenance_needed(fixture)
    for exit_code, needed, crashed in ((0, False, False), (7, True, True), (0, True, True)):
        with (
            patch.object(
                subprocess, "run", return_value=subprocess.CompletedProcess([], exit_code)
            ),
            patch.object(artifacts, "cache_maintenance_needed", return_value=needed),
            patch.object(
                artifacts, "prune_compilation_cache", side_effect=RuntimeError("native signal 11")
            ) as prune,
            patch.object(artifacts, "record_cache_space") as sample,
            redirect_stderr(StringIO()),
        ):
            try:
                run_cache([str(fixture), "build.log", "build", "xcodebuild", "build"])
            except SystemExit as status:
                assert status.code == exit_code
            assert prune.called == crashed
            sample.assert_not_called()
    for exit_code in (-11, 1, 124):
        with patch(
            "workflow_processes.capture_command",
            return_value=subprocess.CompletedProcess([], exit_code, "", "native failure"),
        ):
            try:
                artifacts.prune_compilation_cache(fixture / "cache")
            except RuntimeError as error:
                assert str(exit_code) in str(error) and "native failure" in str(error)
            else:
                raise AssertionError("原生维护失败应回到父进程处理。")
    derived = fixture / "database"
    for relative in artifacts.BUILD_DATABASE_RELATIVES:
        database = derived / relative
        database.parent.mkdir(parents=True)
        connection = sqlite3.connect(database)
        try:
            connection.execute("CREATE TABLE incremental (id INTEGER PRIMARY KEY, value BLOB)")
            connection.executemany(
                "INSERT INTO incremental VALUES (?, ?)", [(i, b"x" * 4096) for i in range(100)]
            )
            connection.execute("DELETE FROM incremental WHERE id > 2")
            connection.commit()
            rows = connection.execute("SELECT * FROM incremental").fetchall()
        finally:
            connection.close()
        before = database.stat().st_size
        with patch.object(artifacts, "CACHE_GROWTH_INTERVAL", 1):
            artifacts.compact_build_databases([derived])
        connection = sqlite3.connect(database)
        try:
            assert connection.execute("SELECT * FROM incremental").fetchall() == rows
        finally:
            connection.close()
        assert database.stat().st_size < before
    with patch.object(artifacts, "DERIVED_ROOT_NAMES", ("database",)):
        assert artifacts.build_database_bytes(fixture) == sum(
            path.stat().st_size for path in artifacts.build_databases([derived])
        )
    metadata.write_text("{")
    assert artifacts.cache_maintenance_needed(fixture)
    artifacts.update_cache_metadata(metadata, saved)
