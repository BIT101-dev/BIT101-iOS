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


def local_import_conditions(condition: str) -> str:
    return re.sub(r"\bcanImport\(\s*([A-Za-z_]\w*)\s*\)",
        lambda match: "true" if (ROOT / "Modules" / match[1]).is_dir() else match[0], condition)


@cache
def repository_conditions() -> set[str]:
    from swift_source_index import repository_swift_files
    return {local_import_conditions(match[1].strip()) for path in repository_swift_files()
        for match in re.finditer(r"(?m)^\s*#(?:if|elseif)[ \t]+([^\r\n]+)", path.read_text())}


def prepare_cache(recorded: dict, group: str, environment: str, conditions: set[str]) -> dict:
    recorded = {key: value for key, value in recorded.items() if key in {'modules', 'build-ui'}}
    for context in recorded.values():
        context['results'] = {key: row for key, row in context['results'].items() if row['condition'] in conditions}
    if recorded.get(group, {}).get('environment') != environment:
        recorded[group] = {'environment': environment, 'results': {}}
    return recorded


@cache
def compilation_condition(condition: str, group: str) -> bool:
    condition = condition.strip()
    group = group.removeprefix("build-")
    group = {"network-smoke": "network", "icloud-smoke": "icloud"}.get(group, group)
    if any(character in condition for character in "\n\r#;{}"):
        raise ValueError(f"编译条件需要单行 Swift 表达式：{condition}")
    enabled = set(workflow_conditions(group))
    catalyst = group in {"catalyst", "catalyst-release-runtime"}
    native = group == "modules"
    architecture = os.uname().machine if native or catalyst else "arm64"
    sdk_name = "macosx" if native or catalyst else "iphoneos"
    target = f"{architecture}-apple-macosx14.0" if native else f"{architecture}-apple-ios17.0" + ("-macabi" if catalyst else "")
    # 本地包模块由项目依赖图提供；系统框架由所选 SDK 与编译器求值。
    condition = local_import_conditions(condition)
    environment_group = "modules" if native else "build-ui"
    environment = environment_context(environment_group)
    context_signature = hashlib.sha256(json.dumps([environment, Path(__file__).read_text()], sort_keys=True).encode()).hexdigest()
    signature = hashlib.sha256(json.dumps([condition, target, sorted(enabled)], sort_keys=True).encode()).hexdigest()
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
            result = subprocess.run([compiler, "-typecheck", "-target", target, "-sdk", sdk,
                "-module-cache-path", str(module_cache), *frameworks, *[flag for value in sorted(enabled) for flag in ("-D", value)], "-"],
                input=source, capture_output=True, text=True)
        errors = set(re.findall(r"error: ([^\n]+)", result.stderr))
        if errors not in ({"BIT101_CONDITION_TRUE"}, {"BIT101_CONDITION_FALSE"}):
            raise ValueError(f"Swift 编译条件求值失败：{condition}\n{result.stderr.strip()}")
        value = errors == {"BIT101_CONDITION_TRUE"}
        if condition in conditions: results[signature] = {'condition': condition, 'value': value}
        cache_path.write_text(json.dumps(recorded, sort_keys=True) + "\n")
        return value


def self_test() -> None:
    recorded = {'old-signature': True, 'modules': {'environment': 'compiler', 'results': {
        'live': {'condition': 'DEBUG', 'value': True}, 'removed': {'condition': 'REMOVED', 'value': False}}}}
    kept = prepare_cache(recorded, 'build-ui', 'sdk', {'DEBUG'})
    assert set(kept) == {'modules', 'build-ui'} and set(kept['modules']['results']) == {'live'}
    assert kept['build-ui'] == {'environment': 'sdk', 'results': {}}
    changed = prepare_cache(kept, 'modules', 'new-compiler', {'DEBUG'})
    assert changed['modules']['results'] == {} and changed['build-ui']['environment'] == 'sdk'
