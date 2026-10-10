"""Evaluate Swift conditional compilation with the selected production toolchain."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from functools import cache
from validation_environment import environment_context
from validation_policy import workflow_conditions

ROOT = Path(__file__).resolve().parents[1]


@cache
def local_dependency_graph() -> tuple[dict, dict]:
    import importlib.util
    from code_quality_rules import native_project_targets
    spec = importlib.util.spec_from_file_location('module_boundaries', ROOT / 'Scripts/check-module-boundaries.py')
    boundaries = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(boundaries)
    package = boundaries.read_manifest(ROOT)
    targets = boundaries.manifest_targets(package)
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
        str(ROOT / 'BIT101-iOS.xcodeproj/project.pbxproj')], text=True))
    native = {name: {module for product in package['products'] if product['name'] in declared for module in product['targets']}
        for name, declared, _ in native_project_targets(project, ROOT)}
    return targets, native


def available_local_modules(path: str) -> set[str]:
    from swift_type_index import compilation_unit
    targets, native = local_dependency_graph()
    relative = Path(path)
    if relative.is_absolute(): relative = relative.relative_to(ROOT)
    owner = next((name for name, target in targets.items()
        if relative.is_relative_to(target['path'])), None)
    pending = list(targets[owner]['dependencies'] if owner else native.get(compilation_unit(path), set()))
    available = set()
    while pending:
        name = pending.pop()
        if name in available: continue
        available.add(name)
        pending.extend(targets.get(name, {}).get('dependencies', set()))
    return available


def local_import_conditions(condition: str, path: str = '') -> str:
    def replace(match):
        if not (ROOT / 'Modules' / match[1]).is_dir(): return match[0]
        return 'true' if path and match[1] in available_local_modules(path) else 'false'
    return re.sub(r"\bcanImport\(\s*([A-Za-z_]\w*)\s*\)", replace, condition)


@cache
def repository_conditions() -> set[str]:
    from swift_source_index import repository_swift_files
    return {local_import_conditions(match[1].strip(), str(path)) for path in repository_swift_files()
        for match in re.finditer(r"(?m)^\s*#(?:if|elseif)[ \t]+([^\r\n]+)", path.read_text())}


def prepare_cache(recorded: dict, group: str, environment: str, conditions: set[str]) -> dict:
    recorded = {key: value for key, value in recorded.items() if key in {'modules', 'build-ui'}}
    for context in recorded.values():
        context['results'] = {key: row for key, row in context['results'].items() if row['condition'] in conditions}
    if recorded.get(group, {}).get('environment') != environment:
        recorded[group] = {'environment': environment, 'results': {}}
    return recorded


@cache
def compilation_condition(condition: str, group: str, *, language_mode: str = '6', platform: str | None = None, path: str = '') -> bool:
    condition = condition.strip()
    group = group.removeprefix("build-")
    group = {"network-smoke": "network", "icloud-smoke": "icloud"}.get(group, group)
    if any(character in condition for character in "\n\r#;{}"):
        raise ValueError(f"编译条件需要单行 Swift 表达式：{condition}")
    enabled = set(workflow_conditions(group))
    catalyst = platform == 'macCatalyst' or group in {"catalyst", "catalyst-release-runtime"}
    native = platform == 'macOS' or group == "modules" and platform is None
    architecture = os.uname().machine if native or catalyst else "arm64"
    watch = platform == 'watchOS'
    sdk_name = "macosx" if native or catalyst else "watchos" if watch else "iphoneos"
    target = f"{architecture}-apple-macosx14.0" if native else f"{architecture}-apple-watchos10.0" if watch else f"{architecture}-apple-ios17.0" + ("-macabi" if catalyst else "")
    # 本地包模块由项目依赖图提供；系统框架由所选 SDK 与编译器求值。
    condition = local_import_conditions(condition, path)
    environment_group = "modules" if native else "build-ui"
    environment = environment_context(environment_group)
    context_signature = hashlib.sha256(json.dumps([environment, Path(__file__).read_text()], sort_keys=True).encode()).hexdigest()
    signature = hashlib.sha256(json.dumps([condition, target, sorted(enabled), language_mode], sort_keys=True).encode()).hexdigest()
    cache_root = ROOT / ".build/static-audit"
    cache_root.mkdir(parents=True, exist_ok=True)
    with (cache_root / "compilation-conditions.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache_path = cache_root / "compilation-conditions.json"
        recorded = json.loads(cache_path.read_text()) if cache_path.is_file() else {}
        conditions = repository_conditions()
        recorded = prepare_cache(recorded, environment_group, context_signature, conditions)
        results = recorded[environment_group]['results']
        if signature in results:
            cache_path.write_text(json.dumps(recorded, sort_keys=True) + "\n")
            return results[signature]['value']
        compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip()
        sdk_path = Path(sdk)
        frameworks = ["-F", str(sdk_path.parent.parent / "Library/Frameworks")]
        if catalyst:
            frameworks += ["-F", str(sdk_path / "System/iOSSupport/System/Library/Frameworks"),
                "-I", str(sdk_path / "System/iOSSupport/usr/include")]
        module_cache = ROOT / ".build/compiler-cache/ModuleCache.noindex"
        module_cache.mkdir(parents=True, exist_ok=True)
        source = f'#if {condition}\n#error("BIT101_CONDITION_TRUE")\n#else\n#error("BIT101_CONDITION_FALSE")\n#endif\n'
        with (module_cache.parent / "cache.lock").open("a") as compiler_lock:
            fcntl.flock(compiler_lock, fcntl.LOCK_EX)
            result = subprocess.run([compiler, "-typecheck", "-swift-version", language_mode, "-target", target, "-sdk", sdk,
                "-module-cache-path", str(module_cache), *frameworks, *[flag for value in sorted(enabled) for flag in ("-D", value)], "-"],
                input=source, capture_output=True, text=True)
        errors = set(re.findall(r"error: ([^\n]+)", result.stderr))
        if errors not in ({"BIT101_CONDITION_TRUE"}, {"BIT101_CONDITION_FALSE"}):
            raise ValueError(f"Swift 编译条件求值失败：{condition}\n{result.stderr.strip()}")
        value = errors == {"BIT101_CONDITION_TRUE"}
        if condition in conditions: results[signature] = {'condition': condition, 'value': value}
        cache_path.write_text(json.dumps(recorded, sort_keys=True) + "\n")
        return value


def source_platforms(path: str) -> tuple[str, ...]:
    from swift_type_index import compilation_unit
    unit = compilation_unit(path)
    if unit in {'BIT101Watch', 'BIT101WatchWidgets'}: return ('watchOS',)
    if 'Modules' in Path(path).parts: return ('iOS', 'watchOS', 'macOS', 'macCatalyst')
    if unit == 'BIT101-iOS': return ('iOS', 'macCatalyst')
    return ('iOS',)


def active_network_source(source: str, path: str) -> str:
    from validation_evidence import active_swift_source
    sources = [active_swift_source(source, 'network', platform=platform, path=path).encode() for platform in source_platforms(path)]
    return bytes(next((row[index] for row in sources if row[index] not in b' \r\n'), sources[0][index])
        for index in range(len(sources[0]))).decode()


def self_test() -> None:
    recorded = {'old-signature': True, 'modules': {'environment': 'compiler', 'results': {
        'live': {'condition': 'DEBUG', 'value': True}, 'removed': {'condition': 'REMOVED', 'value': False}}}}
    kept = prepare_cache(recorded, 'build-ui', 'sdk', {'DEBUG'})
    assert set(kept) == {'modules', 'build-ui'} and set(kept['modules']['results']) == {'live'}
    assert kept['build-ui'] == {'environment': 'sdk', 'results': {}}
    changed = prepare_cache(kept, 'modules', 'new-compiler', {'DEBUG'})
    assert changed['modules']['results'] == {} and changed['build-ui']['environment'] == 'sdk'
