#!/usr/bin/env python3
"""Share compiler caches and reclaim native storage through its owning tools."""
import fcntl
from contextlib import nullcontext
import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import signal

sys.dont_write_bytecode = True


def cache_layout_ready(shared: Path, derived_roots: list[Path], command: list[str]) -> bool:
    from validation_artifacts import cache_names
    for option in ('-derivedDataPath', '--scratch-path'):
        if option in command and not Path(command[command.index(option) + 1]).is_dir(): return False
    if any(not (shared / name).is_dir() for name in cache_names): return False
    for derived in derived_roots:
        if not derived.is_dir(): continue
        for name in cache_names:
            source = derived / name
            if not source.is_symlink() or source.resolve() != (shared / name).resolve(): return False
        for framework in (derived / 'Build/Products').glob('*/PackageFrameworks/*.framework'):
            if (framework.parent.parent / (framework.stem + '.swiftmodule')).is_dir(): return False
    return True


def report_cache_space(root: Path, report: dict) -> None:
    names = {'projectBytes': '项目总计', 'casBytes': '历史编译缓存', 'sdkBytes': 'SDK 缓存',
        'modulesBytes': '模块缓存', 'indexBytes': '索引', 'buildBytes': '增量构建与产物',
        'auditBytes': '静态审计', 'diagnosticBytes': '诊断导出'}
    print(' · '.join(f'{title} {report[name] / 1024 ** 3:.2f} GiB' for name, title in names.items()))


def run_cache(arguments: list[str]) -> None:
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    root = Path(arguments[0])
    sys.path.insert(0, str(root / "Scripts"))
    from validation_artifacts import (clear_diagnostic_exports, prune_native_storage, prune_compilation_cache,
        cache_space_report, record_cache_space, cache_maintenance_needed, compact_build_databases)
    arguments = arguments[1:]
    maintenance = arguments == ["--maintenance"]
    shared = root / ".build/compiler-cache"
    shared.mkdir(parents=True, exist_ok=True)
    if arguments == ['--info']:
        report_cache_space(root, cache_space_report(root))
        return
    cache_names = ("SDKExplicitPrecompiledModules", "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex", "Index.noindex")
    derived_roots = [root / name for name in (
        ".build/extended-automation", "build/DeviceInstall", ".build/release-network-smoke",
        ".build/icloud-cross-device-smoke/Phone", ".build/icloud-cross-device-smoke/Mac",
        ".build/extended-automation/out",
    )]

    def occupied_kib():
        paths = [str(root / name) for name in (".build", "build") if (root / name).exists()]
        return sum(int(line.split()[0]) for line in subprocess.check_output(["du", "-sk", *paths], text=True).splitlines())

    def share_cache(source, destination):
        if source.is_symlink():
            if source.resolve() != destination.resolve():
                raise SystemExit(f"缓存链接目标需要核对：{source}")
            return
        if source.exists():
            if not source.is_dir():
                raise SystemExit(f"编译缓存应为目录：{source}")
            if source.name == "CompilationCache.noindex":
                def occupied_blocks(path):
                    return sum(item.stat().st_blocks for item in path.rglob("*") if item.is_file())
                # CAS 的索引、动作与数据属于同一命名空间，整体保留已有内容较多的目录。
                if occupied_blocks(source) > occupied_blocks(destination):
                    shutil.rmtree(destination)
                    source.replace(destination)
                else:
                    shutil.rmtree(source)
                source.symlink_to(destination, target_is_directory=True)
                return
            for directory, children, files in os.walk(source, topdown=False):
                directory = Path(directory)
                target = destination / directory.relative_to(source)
                target.mkdir(parents=True, exist_ok=True)
                for name in files:
                    original, retained = directory / name, target / name
                    if retained.exists() and retained.stat().st_mtime_ns >= original.stat().st_mtime_ns:
                        original.unlink()
                    else:
                        original.replace(retained)
                for name in children:
                    child = directory / name
                    if child.is_symlink():
                        raise SystemExit(f"缓存内部链接需要核对：{child}")
                directory.rmdir()
        source.symlink_to(destination, target_is_directory=True)

    with ((root / ".build/extended-automation.lock").open("a")
          if maintenance and os.environ.get("BIT101_EXTENDED_TESTS_LOCK_HELD") != "1" else nullcontext()) as results_lock, \
            (shared / "cache.lock").open("a") as lock:
        if results_lock is not None:
            fcntl.flock(results_lock, fcntl.LOCK_EX)
        fcntl.flock(lock, fcntl.LOCK_EX if maintenance else fcntl.LOCK_SH)
        owns_structure = maintenance
        if not maintenance and not cache_layout_ready(shared, derived_roots, arguments[2:]):
            fcntl.flock(lock, fcntl.LOCK_EX)
            owns_structure = True
        before = occupied_kib() if maintenance else 0
        if not maintenance:
            command = arguments[2:]
            if command[0] == "xcodebuild" and any(action in command for action in ("build", "build-for-testing", "test", "archive")):
                defaults = ["SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "GCC_TREAT_WARNINGS_AS_ERRORS=YES", "COMPILATION_CACHE_ENABLE_CACHING=YES",
                            "SWIFT_ENABLE_PREFIX_MAPPING=YES", "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES",
                            "CLANG_ENABLE_PREFIX_MAPPING=YES", "CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES"]
                for setting in defaults:
                    if not any(value.startswith(setting.split("=", 1)[0] + "=") for value in command):
                        arguments.append(setting)
            if command[:2] == ["xcrun", "swift"] and command[2:3] in (["build"], ["test"]):
                for option, value in (("-Xswiftc", "-warnings-as-errors"), ("-Xcc", "-Werror")):
                    if value not in command: arguments.extend((option, value))
            for option in ("-derivedDataPath", "--scratch-path"):
                if option in command:
                    requested = Path(command[command.index(option) + 1])
                    if requested not in derived_roots:
                        raise SystemExit(f"构建缓存入口需要登记：{requested}")
                    requested.mkdir(parents=True, exist_ok=True)
                    if command[0] == "xcodebuild" and owns_structure:
                        # SwiftPM 的静态与框架布局共用中间产物，旧平面模块会遮蔽框架内的新模块。
                        for framework in (requested / "Build/Products").glob("*/PackageFrameworks/*.framework"):
                            flat_module = framework.parent.parent / f"{framework.stem}.swiftmodule"
                            if flat_module.is_dir():
                                shutil.rmtree(flat_module)
                                flat_module.with_suffix(".o").unlink(missing_ok=True)
        if owns_structure:
            for name in cache_names:
                (shared / name).mkdir(exist_ok=True)
            for derived in derived_roots:
                if derived.is_dir():
                    for name in cache_names:
                        share_cache(derived / name, shared / name)
            for name in ("testPhoneUpload.log", "testPhoneVerifyAndCleanup.log"):
                (root / ".build/icloud-cross-device-smoke" / name).unlink(missing_ok=True)
        if maintenance:
            shutil.rmtree(root / ".build/static-audit/package-build", ignore_errors=True)
            shutil.rmtree(root / ".build/ui-authorization.logarchive", ignore_errors=True)
            clear_diagnostic_exports(root / ".build/extended-automation/diagnostics")
            (shared / "compression-stage").unlink(missing_ok=True)
            for derived in derived_roots:
                for build in (derived / "Build", derived):
                    for parent in (build / "Products", build / "Intermediates.noindex"):
                        if parent.is_dir():
                            if parent.name == "Products":
                                for symbols in parent.rglob("*.dSYM"):
                                    bundled = any(path.suffix in (".app", ".appex", ".framework", ".xctest")
                                                  for path in symbols.relative_to(parent).parents)
                                    product_name = symbols.name.removesuffix('.dSYM')
                                    has_product = (symbols.parent / product_name).exists() or any(
                                        (app / nested / product_name).exists()
                                        for app in symbols.parent.glob('*.app') for nested in ('PlugIns', 'Frameworks'))
                                    if symbols.is_dir() and not bundled and not has_product:
                                        shutil.rmtree(symbols)
                for diagnostic in (derived / 'Logs/Test').glob('*'):
                    if diagnostic.name == 'test-results.xcresult': continue
                    if diagnostic.is_dir(): shutil.rmtree(diagnostic)
                    else: diagnostic.unlink()
            referenced = set()
            maps_complete = True
            for derived in derived_roots:
                for source in derived.rglob("*dependencies*.json"):
                    try:
                        dependency_map = json.loads(source.read_text())
                    except (ValueError, UnicodeError):
                        maps_complete = False
                        continue
                    pending = [dependency_map]
                    while pending:
                        value = pending.pop()
                        if isinstance(value, dict):
                            pending.extend(value.values())
                        elif isinstance(value, list):
                            pending.extend(value)
                        elif isinstance(value, str) and value.endswith(".pcm"):
                            path = Path(value).resolve()
                            if path.is_relative_to(shared):
                                referenced.add(path)
            if maps_complete and referenced:
                cache = shared / 'SDKExplicitPrecompiledModules'
                if any(path.is_relative_to(cache) for path in referenced):
                    for module in cache.rglob('*.pcm'):
                        if module not in referenced: module.unlink()
            prune_native_storage(shared)
            compact_build_databases(derived_roots)
            after = occupied_kib()
            print(f"缓存整理：{before / 1048576:.2f} → {after / 1048576:.2f} GiB；释放 {(before - after) / 1048576:.2f} GiB")
            report_cache_space(root, record_cache_space(root))
        else:
            fcntl.flock(lock, fcntl.LOCK_SH)
            result = subprocess.run(["zsh", "-c",
                'ROOT_DIR="$1"; source "$ROOT_DIR/Scripts/script-support.sh"; shift; bit101_log_command "$@"',
                "cache-build", str(root), *arguments])
            fcntl.flock(lock, fcntl.LOCK_UN)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                try:
                    if result.returncode == 0 and cache_maintenance_needed(root):
                        before_cas, after_cas = prune_compilation_cache(shared)
                        compact_build_databases(derived_roots)
                        report = record_cache_space(root)
                        if before_cas - after_cas >= 64 * 1024 ** 2:
                            print(f"自动缓存回收：释放 {(before_cas - after_cas) / 1024 ** 3:.2f} GiB；项目 {report['projectBytes'] / 1024 ** 3:.2f} GiB")
                except (OSError, ValueError, RuntimeError, AttributeError, subprocess.SubprocessError) as error:
                    print(f'缓存回收待重试：{error}', file=sys.stderr)
            raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)


if __name__ == '__main__':
    run_cache(sys.argv[1:])
