#!/usr/bin/env python3
"""Audit fixed workflow artifacts and shared compiler caches."""
from pathlib import Path
import fcntl
import os
import shutil
import sys
import subprocess
import json
from contextlib import contextmanager, ExitStack, closing
from validation_policy import TEST_GROUPS, BUILD_HOSTS

if not __debug__:
    raise RuntimeError("验证自测需要 Python 默认优化级别；请使用 python3 -E 执行入口。")

cache_names = {"SDKExplicitPrecompiledModules", "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex", "Index.noindex"}
DERIVED_ROOT_NAMES = ('.build/extended-automation', 'build/DeviceInstall', '.build/release-network-smoke',
    '.build/icloud-cross-device-smoke/Phone', '.build/icloud-cross-device-smoke/Mac', '.build/extended-automation/out')
BUILD_DATABASE_RELATIVE = 'Build/Intermediates.noindex/XCBuildData/build.db'
derived_names = cache_names | {"Build", "Logs", "SourcePackages", "info.plist"}
fixed_children = {
    ".build/compiler-cache": cache_names | {"cache.lock", "compilation-cache.json",
        "compilation-cache.log", "swift-syntax-indexer", "swift-syntax-indexer-inputs.json", "swift-syntax-indexer.lock"},
    ".build/static-audit": {"artifact-hygiene.log", "audit.lock", "checkers.log", "dependency-audit.log", "docs.log",
        "git-diff.log", "module-boundary.log", "python-parse.log", "shell-parse.log", "swift-parse.log", "worker-parse.log",
        "compilation-conditions.json", "compilation-conditions.lock", "source-facts.sqlite", "source-facts.sqlite-journal", "source-facts.lock",
        "staged-content-self-test.lock", "staged-content-self-test", "evidence-media-probe", "evidence-media-probe-inputs.json",
        "evidence-media-probe.lock", "evidence-media.mp4"},
    ".build/extended-automation": derived_names | {".buildSystem_debug", ".buildSystem_release", ".lock", "CACHEDIR.TAG",
        "TestResults", "artifacts", "checkouts", "repositories", "debug", "release", "debug.yaml", "release.yaml",
        "out", "manifest.pif", "workspace-state.json", "module-events.jsonl", "test-metrics.txt", "test-failures.txt",
        "test-results.xcresult", "ui-tests.log", "ui-tests-build.log", "failure-hierarchy.txt", "diagnostics",
        "validation-evidence.json", "validation-evidence.lock", "ci-validation-result.json", "ci-diagnostics.txt", "manual-scenarios.json", "performance-measurements.json",
        "release-receipt.json", "simulator-device.json", "simulator.log", "runtime.log", "restore.log", "worker.log", "worker.lock"} | {name + ".log" for name in TEST_GROUPS}
        | {"build-" + name + ".log" for name in BUILD_HOSTS},
    ".build/icloud-cross-device-smoke": {"Phone", "Mac", "test-results.xcresult", "report.json", "report.lock", "signing.entitlements",
        "build.log", "mac-build.log", "mac-receive.log", "mac-cleanup.log", "testPhoneRoundTrip.log", "testCleanup.log"},
    ".build/release-network-smoke": derived_names | {"build.log", "console.log", "report", "community-configuration.json"},
    ".build/release-network-smoke/report": {"network-smoke-summary.txt", "release-network-smoke.json",
        "raw-course-response.json", "network-smoke-request.json"},
    "build/DeviceInstall": derived_names | {"BIT101-iOS.xcarchive", "build.log", "distribution-signing.json", "restore-readiness.json", "restore-process.json"},
}
SELF_TEST_ARTIFACTS = frozenset({
    "network-configuration-self-test",
    "test-results-self-test",
    "campus-fixture-self-test", "report-inbox-self-test", "report-write-self-test", "explanatory-self-test",
    "cache-self-test", "cache-download-self-test", "development-workflow-self-test", "performance-results-self-test", "workflow-lock-self-test", "audit-cancellation-self-test",
    "source-identity-self-test", "simulator-startup-self-test",
    "row-color-self-test.swift", "source-digest-self-test.sh", "module-manifest-lock", "script-snapshot.sh",
})


@contextmanager
def static_audit_lock(root: Path):
    flags = ('BIT101_EXTENDED_TESTS_LOCK_HELD', 'BIT101_STATIC_AUDIT_LOCK_HELD')
    previous = {flag: os.environ.get(flag) for flag in flags}
    def restore():
        for flag, value in previous.items():
            if value is None: os.environ.pop(flag, None)
            else: os.environ[flag] = value
    with ExitStack() as locks:
        locks.callback(restore)
        for name, flag in zip(('.build/extended-automation.lock', '.build/static-audit/audit.lock'), flags):
            if os.environ.get(flag) == '1': continue
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            lock = locks.enter_context(path.open('a'))
            fcntl.flock(lock, fcntl.LOCK_EX)
            os.environ[flag] = '1'
        yield


def artifact_name_allowed(parent: str, name: str) -> bool:
    return name == ".DS_Store" or name in fixed_children[parent]


def committed_children(folder: Path) -> list[Path]:
    if folder.name == 'static-audit':
        with (folder / 'compilation-conditions.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            (folder / 'compilation-conditions.incoming').unlink(missing_ok=True)
            return list(folder.iterdir())
    report_name = {'extended-automation': 'validation-evidence', 'icloud-cross-device-smoke': 'report'}.get(folder.name)
    if report_name:
        with (folder / (report_name + '.lock')).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            (folder / (report_name + '.incoming')).unlink(missing_ok=True)
            return list(folder.iterdir())
    return list(folder.iterdir())


def compressed_artifact(name: str) -> bool:
    return name.lower().endswith((".zip", ".gz", ".tgz", ".bz2", ".xz", ".tar", ".zst", ".7z"))


def self_test() -> None:
    for parent, name in ((".build/extended-automation", "latest.log"),
            (".build/release-network-smoke/report", "second-report.json"),
            (".build/compiler-cache", "diagnostics.zip")):
        assert not artifact_name_allowed(parent, name)
    assert artifact_name_allowed(".build/extended-automation", "modules.log")
    assert artifact_name_allowed(".build/extended-automation", "ci-validation-result.json")
    assert artifact_name_allowed(".build/compiler-cache", "Index.noindex")
    assert artifact_name_allowed(".build/release-network-smoke/report", "release-network-smoke.json")
    assert artifact_name_allowed(".build/release-network-smoke", "community-configuration.json")
    assert compressed_artifact("cache/diagnostics.ZIP")
    assert not compressed_artifact("cache/module.pcm")
    from unittest.mock import mock_open, patch
    root = Path('/fixture')
    for symbolic in (False, True):
        removed = []
        with patch.object(Path, 'is_symlink', lambda path: symbolic and path.name == 'module-manifest-lock'), \
                patch.object(Path, 'is_file', lambda path: path.name == 'script-snapshot.sh'), \
                patch.object(Path, 'is_dir', lambda path: path.name == 'module-manifest-lock'), \
                patch.object(Path, 'unlink', lambda path: removed.append(('file', path.name))), \
                patch.object(shutil, 'rmtree', lambda path: removed.append(('directory', path.name))):
            recover_self_test_artifacts(root)
        assert set(removed) == {('file', 'script-snapshot.sh'),
            ('file' if symbolic else 'directory', 'module-manifest-lock')}, removed
    for name, incoming in (('static-audit', 'compilation-conditions.incoming'),
            ('extended-automation', 'validation-evidence.incoming'), ('icloud-cross-device-smoke', 'report.incoming')):
        folder = root / '.build' / name
        children = [folder / 'report.json', folder / 'report.lock']
        events = []
        with patch.object(Path, 'open', mock_open()), \
                patch.object(fcntl, 'flock', lambda *args: events.append('lock')), \
                patch.object(Path, 'unlink', lambda path, *, missing_ok: events.append(('remove', path.name, missing_ok))), \
                patch.object(Path, 'iterdir', lambda path: events.append('read') or iter(children)):
            assert committed_children(folder) == children
        assert events == ['lock', ('remove', incoming, True), 'read'], events



def clear_diagnostic_exports(folder: Path) -> None:
    if not folder.exists(): return
    for path in folder.iterdir():
        if path.name == "test-results.xcresult": continue
        if path.is_dir(): shutil.rmtree(path)
        else: path.unlink()


def recover_self_test_artifacts(root: Path) -> None:
    for name in SELF_TEST_ARTIFACTS:
        path = root / ".build/static-audit" / name
        if path.is_symlink() or path.is_file(): path.unlink()
        elif path.is_dir(): shutil.rmtree(path)


CAS_STORE_LIMIT = 2 * 1024 ** 3
CACHE_GROWTH_INTERVAL = 64 * 1024 ** 2


def prune_compilation_cache(shared: Path, compiler: Path | None = None) -> tuple[int, int]:
    return native_cache_process(shared, 'cas', compiler)


def native_cache_process(shared: Path, operation: str, compiler: Path | None = None) -> tuple[int, int]:
    from workflow_processes import capture_command
    command = [sys.executable, '-B', '-E', str(Path(__file__).resolve()), '--native-cache', operation, str(shared)]
    if compiler is not None: command.append(str(compiler))
    result = capture_command(command)
    if result.returncode:
        raise RuntimeError(f'原生缓存维护退出 {result.returncode}：{result.stderr.strip()}')
    before, after = json.loads(result.stdout)
    return before, after


def prune_cas_storage(shared: Path, compiler: Path | None = None) -> tuple[int, int]:
    import ctypes
    stores = [path for path in (shared / 'CompilationCache.noindex').iterdir()
              if path.is_dir() and any(path.glob('v*'))] if (shared / 'CompilationCache.noindex').is_dir() else []
    if not stores: return (0, 0)
    compiler = compiler or Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    library = ctypes.CDLL(str(compiler.parent.parent / 'lib/swift/host/compiler/lib_InternalSwiftScan.dylib'))
    class NativeString(ctypes.Structure):
        _fields_ = [('data', ctypes.c_void_p), ('length', ctypes.c_size_t)]
    for name, arguments, result in (
        ('options_create', [], ctypes.c_void_p), ('options_dispose', [ctypes.c_void_p], None),
        ('options_set_ondisk_path', [ctypes.c_void_p, ctypes.c_char_p], None),
        ('create_from_options', [ctypes.c_void_p, ctypes.POINTER(NativeString)], ctypes.c_void_p),
        ('get_ondisk_size', [ctypes.c_void_p, ctypes.POINTER(NativeString)], ctypes.c_int64),
        ('set_ondisk_size_limit', [ctypes.c_void_p, ctypes.c_int64, ctypes.POINTER(NativeString)], ctypes.c_bool),
        ('dispose', [ctypes.c_void_p], None)):
        function = getattr(library, 'swiftscan_cas_' + name)
        function.argtypes = arguments; function.restype = result
    library.swiftscan_string_dispose.argtypes = [NativeString]
    library.swiftscan_string_dispose.restype = None
    def failure(error):
        message = ctypes.string_at(error.data, error.length).decode() if error.data else 'CAS 容量 API 返回错误'
        library.swiftscan_string_dispose(error)
        raise RuntimeError(message)
    before = 0
    for store in stores:
        generic = store / 'generic'
        created_generic = not generic.exists()
        options = library.swiftscan_cas_options_create()
        library.swiftscan_cas_options_set_ondisk_path(options, os.fsencode(store))
        error = NativeString()
        cas = library.swiftscan_cas_create_from_options(options, ctypes.byref(error))
        library.swiftscan_cas_options_dispose(options)
        if not cas: failure(error)
        try:
            size = library.swiftscan_cas_get_ondisk_size(cas, ctypes.byref(error))
            if size < 0: failure(error)
            before += size
            if library.swiftscan_cas_set_ondisk_size_limit(cas, CAS_STORE_LIMIT, ctypes.byref(error)): failure(error)
        finally:
            library.swiftscan_cas_dispose(cas)
            if created_generic and generic.exists(): shutil.rmtree(generic)
        subprocess.run(['xcrun', 'llvm-cas', '--cas=' + str(store), '--prune'], check=True, stdout=subprocess.DEVNULL)
    after = sum(int(line.split()[0]) * 1024 for line in subprocess.check_output(
        ['du', '-sk', str(shared / 'CompilationCache.noindex')], text=True).splitlines())
    return before, after


def build_database_bytes(root: Path) -> int:
    return sum(path.stat().st_size for name in DERIVED_ROOT_NAMES
        for path in [root / name / BUILD_DATABASE_RELATIVE] if path.is_file())


def cache_space_report(root: Path) -> dict:
    values = {}
    for line in subprocess.check_output(['du', '-k', '-d', '4', str(root)], text=True).splitlines():
        size, name = line.split('\t', 1)
        values[Path(name).relative_to(root).as_posix()] = int(size) * 1024
    def size(name): return values.get(name, 0)
    shared = '.build/compiler-cache/'
    return {'projectBytes': size('.'), 'casBytes': size(shared + 'CompilationCache.noindex'),
        'sdkBytes': size(shared + 'SDKExplicitPrecompiledModules') + size(shared + 'SDKStatCaches.noindex'),
        'modulesBytes': size(shared + 'ModuleCache.noindex'), 'indexBytes': size(shared + 'Index.noindex'),
        'buildBytes': sum(size(name) for name in ('.build/extended-automation/Build', '.build/extended-automation/out',
            'build/DeviceInstall', '.build/release-network-smoke/Build',
            '.build/icloud-cross-device-smoke/Phone/Build', '.build/icloud-cross-device-smoke/Mac/Build')),
        'auditBytes': size('.build/static-audit'),
        'diagnosticBytes': sum(size(name) for name in ('.build/extended-automation/diagnostics',
            '.build/extended-automation/test-results.xcresult', '.build/icloud-cross-device-smoke/test-results.xcresult')),
        'casStoreLimitBytes': CAS_STORE_LIMIT, 'buildDatabaseBytes': build_database_bytes(root)}


def update_cache_metadata(output: Path, fields: dict) -> dict:
    try: metadata = json.loads(output.read_text())
    except (OSError, ValueError): metadata = {}
    if not isinstance(metadata, dict): metadata = {}
    metadata.update(fields)
    output.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    return metadata


def record_cache_space(root: Path) -> dict:
    output = root / '.build/compiler-cache/compilation-cache.json'
    report = cache_space_report(root)
    update_cache_metadata(output, {'space': report, 'sampleFreeBytes': shutil.disk_usage(root).free})
    return report


def cache_maintenance_needed(root: Path) -> bool:
    shared = root / '.build/compiler-cache'
    try:
        metadata = json.loads((shared / 'compilation-cache.json').read_text())
        sampled_cas = metadata['space']['casBytes']
        sampled_database = metadata['space']['buildDatabaseBytes']
        if not isinstance(sampled_cas, int) or not isinstance(sampled_database, int): return True
    except (OSError, ValueError, TypeError, KeyError):
        return True
    cas = shared / 'CompilationCache.noindex'
    size = int(subprocess.check_output(['du', '-sk', str(cas)], text=True).split()[0]) * 1024 if cas.is_dir() else 0
    return max(size - sampled_cas, build_database_bytes(root) - sampled_database) >= CACHE_GROWTH_INTERVAL


def compact_build_databases(derived_roots: list[Path]) -> None:
    import sqlite3
    for derived in derived_roots:
        database = derived / BUILD_DATABASE_RELATIVE
        if not database.is_file(): continue
        try:
            with closing(sqlite3.connect(database, timeout=0)) as connection:
                page_size = connection.execute('PRAGMA page_size').fetchone()[0]
                free_pages = connection.execute('PRAGMA freelist_count').fetchone()[0]
                if page_size * free_pages >= CACHE_GROWTH_INTERVAL and shutil.disk_usage(database.parent).free > database.stat().st_size:
                    connection.execute('VACUUM')
        except sqlite3.Error as error:
            raise RuntimeError(f'构建数据库维护：{database}：{error}') from error


def prune_native_storage(shared: Path) -> None:
    native_cache_process(shared, 'all')


def prune_native_cache_storage(shared: Path, compiler: Path | None = None) -> tuple[int, int]:
    # v<格式>.<代际> 的主代与上游代共享引用关系，交由原生工具沿父目录回收。
    compiler = compiler or Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    sizes = prune_cas_storage(shared, compiler)
    index = shared / 'Index.noindex/DataStore'
    if index.is_dir():
        import ctypes
        library = ctypes.CDLL(str(compiler.parent.parent / 'lib/libIndexStore.dylib'))
        library.indexstore_store_create.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        library.indexstore_store_create.restype = ctypes.c_void_p
        library.indexstore_store_dispose.argtypes = [ctypes.c_void_p]
        library.indexstore_store_dispose.restype = None
        library.indexstore_store_purge_stale_data.argtypes = [ctypes.c_void_p]
        library.indexstore_store_purge_stale_data.restype = None
        error = ctypes.c_void_p()
        store = library.indexstore_store_create(os.fsencode(index), ctypes.byref(error))
        if not store: raise RuntimeError('索引缓存需要可读取的原生存储。')
        try: library.indexstore_store_purge_stale_data(store)
        finally: library.indexstore_store_dispose(store)
    return sizes


def maintain_native_storage(shared: Path) -> None:
    if not shared.is_dir(): return
    with (shared / 'cache.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            root = shared.parent.parent
            if cache_maintenance_needed(root):
                prune_native_storage(shared)
                record_cache_space(root)
        except (OSError, ValueError, RuntimeError, AttributeError, subprocess.SubprocessError) as error:
            print(f'缓存回收待重试：{error}', file=sys.stderr)



def main(root: Path) -> None:
    recover_self_test_artifacts(root)
    for name in ("swift-syntax-indexer", "swift-syntax-indexer-inputs.json", "swift-syntax-indexer.lock"):
        (root / '.build/static-audit' / name).unlink(missing_ok=True)
    self_test()
    allowed_root_files = {
      ".build/extended-automation.lock",
      ".build/code-quality-report.txt",
      ".build/explanatory-text-report.txt",
      ".build/ui-consistency-report.txt",
      ".build/screenshot.png",
    }
    allowed_dirs = {
        "build/DeviceInstall",
        ".build/compiler-cache",
        ".build/static-audit",
        ".build/extended-automation",
        ".build/icloud-cross-device-smoke",
        ".build/release-" + "network-smoke",
        ".build/issue-report-inbox",
    }
    violations = []
    if (root / ".build/static-audit/package-build").exists():
        violations.append("SwiftPM 构建产物应统一保存到 .build/extended-automation")
    for relative, names in fixed_children.items():
        folder = root / relative
        if folder.exists():
            for child in committed_children(folder):
                if not artifact_name_allowed(relative, child.name):
                    violations.append(f"{child.relative_to(root)}: 工作流产物需要使用固定类别清单")
    for parent in (root / "build", root / ".build"):
        if not parent.exists():
            continue
        for child in parent.iterdir():
            if child.name == ".DS_Store":
                continue
            relative = child.relative_to(root).as_posix()
            if child.is_file():
                if relative not in allowed_root_files:
                    violations.append(f"{relative}: 根目录产物必须使用固定类别文件名")
            elif relative not in allowed_dirs:
                violations.append(f"{relative}: 同类产物不得创建第二个平行目录")
    shared = root / ".build/compiler-cache"
    for parent in (root / ".build", root / "build"):
        for directory, children, files in os.walk(parent):
            if Path(directory).is_relative_to(root / ".build/issue-report-inbox"):
                children.clear()
                continue
            for name in files:
                if compressed_artifact(name):
                    violations.append(f"{(Path(directory) / name).relative_to(root)}: 缓存与诊断产物应保留原始格式")
            for name in (set(children) | set(files)) & cache_names:
                cache = Path(directory) / name
                if cache == shared / name:
                    continue
                if name in children:
                    children.remove(name)
                if not cache.is_symlink() or cache.resolve() != (shared / name).resolve():
                    violations.append(f"{cache.relative_to(root)}: 公共编译缓存应链接到唯一共享目录")
    if violations:
        print("[失败] 产物目录不符合固定路径规则：")
        print("\n".join(violations))
        raise SystemExit(1)
    maintain_native_storage(shared)


if __name__ == "__main__":
    if sys.argv[1:2] == ['--native-cache']:
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        operation = {'cas': prune_cas_storage, 'all': prune_native_cache_storage}[sys.argv[2]]
        print(json.dumps(operation(Path(sys.argv[3]), Path(sys.argv[4]) if len(sys.argv) > 4 else None)))
    else:
        main(Path(sys.argv[1]))
