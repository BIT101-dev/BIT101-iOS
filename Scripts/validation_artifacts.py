#!/usr/bin/env python3
"""Audit fixed workflow artifacts and shared compiler caches."""
from pathlib import Path
import fcntl
import os
import shutil
import sys
from contextlib import contextmanager, ExitStack
from validation_policy import TEST_GROUPS, BUILD_HOSTS

if not __debug__:
    raise RuntimeError("验证自测需要 Python 默认优化级别；请使用 python3 -E 执行入口。")

cache_names = {"SDKExplicitPrecompiledModules", "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex", "Index.noindex"}
derived_names = cache_names | {"Build", "Logs", "SourcePackages", "info.plist"}
fixed_children = {
    ".build/compiler-cache": cache_names | {"cache.lock", "compilation-cache.json",
        "swift-syntax-indexer", "swift-syntax-indexer-inputs.json", "swift-syntax-indexer.lock"},
    ".build/static-audit": {"artifact-hygiene.log", "audit.lock", "checkers.log", "dependency-audit.log", "docs.log",
        "git-diff.log", "module-boundary.log", "python-parse.log", "shell-parse.log", "swift-parse.log", "worker-parse.log",
        "compilation-conditions.json", "compilation-conditions.lock",
        "staged-content-self-test.lock", "staged-content-self-test", "evidence-media-probe", "evidence-media-probe-inputs.json",
        "evidence-media-probe.lock", "evidence-media.mp4"},
    ".build/extended-automation": derived_names | {".buildSystem_debug", ".buildSystem_release", ".lock", "CACHEDIR.TAG",
        "TestResults", "artifacts", "checkouts", "repositories", "debug", "release", "debug.yaml", "release.yaml",
        "out", "manifest.pif", "workspace-state.json", "module-events.jsonl", "test-metrics.txt", "test-failures.txt",
        "test-results.xcresult", "ui-tests.log", "ui-tests-build.log", "failure-hierarchy.txt", "diagnostics",
        "validation-evidence.json", "validation-evidence.lock", "manual-scenarios.json", "performance-measurements.json",
        "release-receipt.json", "core-validation-evidence.json", "simulator-device.json", "simulator.log", "restore.log", "worker.log", "worker.lock"} | {name + ".log" for name in TEST_GROUPS}
        | {"build-" + name + ".log" for name in BUILD_HOSTS},
    ".build/extended-automation/diagnostics": {"test-results.xcresult"},
    ".build/icloud-cross-device-smoke": {"Phone", "Mac", "test-results.xcresult", "report.json", "report.lock", "signing.entitlements",
        "build.log", "mac-build.log", "mac-receive.log", "mac-cleanup.log", "testPhoneRoundTrip.log", "testCleanup.log"},
    ".build/release-network-smoke": derived_names | {"build.log", "console.log", "report"},
    ".build/release-network-smoke/report": {"network-smoke-summary.txt", "release-network-smoke.json",
        "raw-course-response.json", "network-smoke-request.json"},
    "build/DeviceInstall": derived_names | {"BIT101-iOS.xcarchive", "build.log", "distribution-signing.json", "restore-readiness.json", "restore-process.json"},
}
SELF_TEST_ARTIFACTS = frozenset({
    "campus-fixture-self-test", "report-inbox-self-test", "report-write-self-test", "explanatory-self-test",
    "cache-self-test", "performance-results-self-test", "workflow-lock-self-test",
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
    assert artifact_name_allowed(".build/compiler-cache", "Index.noindex")
    assert artifact_name_allowed(".build/release-network-smoke/report", "release-network-smoke.json")
    assert artifact_name_allowed(".build/extended-automation/diagnostics", "test-results.xcresult")
    assert not artifact_name_allowed(".build/extended-automation/diagnostics", "exported.log")
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


def main(root: Path) -> None:
    recover_self_test_artifacts(root)
    for name in ("swift-syntax-indexer", "swift-syntax-indexer-inputs.json", "swift-syntax-indexer.lock"):
        (root / '.build/static-audit' / name).unlink(missing_ok=True)
    clear_diagnostic_exports(root / '.build/extended-automation/diagnostics')
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


if __name__ == "__main__":
    main(Path(sys.argv[1]))
