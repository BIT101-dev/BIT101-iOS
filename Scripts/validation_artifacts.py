"""Audit fixed workflow artifacts and shared compiler caches."""
from pathlib import Path
import fcntl
import os
import sys
from validation_policy import TEST_GROUPS, BUILD_HOSTS

if not __debug__:
    raise RuntimeError("验证自测需要 Python 默认优化级别；请使用 python3 -E 执行入口。")

cache_names = {"SDKExplicitPrecompiledModules", "ModuleCache.noindex", "SDKStatCaches.noindex", "CompilationCache.noindex"}
derived_names = cache_names | {"Build", "Logs", "SourcePackages", "info.plist"}
fixed_children = {
    ".build/compiler-cache": cache_names | {"cache.lock"},
    ".build/static-audit": {"artifact-hygiene.log", "audit.lock", "checkers.log", "dependency-audit.log", "docs.log",
        "git-diff.log", "module-boundary.log", "python-parse.log", "shell-parse.log", "swift-parse.log", "worker-parse.log",
        "swift-syntax-indexer", "swift-syntax-indexer-inputs.json", "swift-syntax-indexer.lock",
        "compilation-conditions.json", "compilation-conditions.lock",
        "staged-content-self-test.lock", "staged-content-self-test", "evidence-media-probe", "evidence-media-probe-inputs.json",
        "evidence-media-probe.lock", "evidence-media.mp4"},
    ".build/extended-automation": derived_names | {".buildSystem_debug", ".buildSystem_release", ".lock", "CACHEDIR.TAG",
        "TestResults", "artifacts", "checkouts", "repositories", "debug", "release", "debug.yaml", "release.yaml",
        "out", "manifest.pif", "workspace-state.json", "module-events.jsonl", "test-metrics.txt", "test-failures.txt",
        "test-results.xcresult", "ui-tests.log", "ui-tests-build.log", "failure-hierarchy.txt", "diagnostics",
        "validation-evidence.json", "validation-evidence.lock", "manual-scenarios.json", "performance-measurements.json",
        "release-receipt.json", "core-validation-evidence.json", "simulator-device.json", "simulator.log", "restore.log"} | {name + ".log" for name in TEST_GROUPS}
        | {"build-" + name + ".log" for name in BUILD_HOSTS},
    ".build/icloud-cross-device-smoke": {"Phone", "Mac", "test-results.xcresult", "report.json", "signing.entitlements",
        "build.log", "mac-build.log", "mac-receive.log", "mac-cleanup.log", "testPhoneRoundTrip.log", "testCleanup.log"},
    ".build/release-network-smoke": derived_names | {"build.log", "console.log", "report"},
    ".build/release-network-smoke/report": {"network-smoke-summary.txt", "release-network-smoke.json",
        "raw-course-response.json", "network-smoke-request.json"},
    "build/DeviceInstall": derived_names | {"BIT101-iOS.xcarchive", "build.log", "distribution-signing.json", "restore-readiness.json", "restore-process.json"},
}


def artifact_name_allowed(parent: str, name: str) -> bool:
    return name == ".DS_Store" or name in fixed_children[parent]


def committed_children(folder: Path) -> list[Path]:
    if folder.name == "extended-automation":
        with (folder / "validation-evidence.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
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
    assert artifact_name_allowed(".build/release-network-smoke/report", "release-network-smoke.json")
    assert compressed_artifact("cache/diagnostics.ZIP")
    assert not compressed_artifact("cache/module.pcm")


self_test()
root = Path(sys.argv[1])
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
with (root / ".build/extended-automation.lock").open("a") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        if (root / ".build/extended-automation/diagnostics").exists():
            violations.append(".build/extended-automation/diagnostics: 诊断处理完成后应清除导出副本")
if violations:
    print("[失败] 产物目录不符合固定路径规则：")
    print("\n".join(violations))
    raise SystemExit(1)
