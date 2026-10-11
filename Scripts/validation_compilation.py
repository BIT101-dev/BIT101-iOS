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
from swift_source_index import swift_code as mask_literals_and_comments

ROOT = Path(__file__).resolve().parents[1]


@cache
def project_configuration() -> tuple[dict, dict, dict]:
    import importlib.util
    spec = importlib.util.spec_from_file_location('module_boundaries', ROOT / 'Scripts/check-module-boundaries.py')
    boundaries = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(boundaries)
    package = boundaries.read_manifest(ROOT)
    targets = boundaries.manifest_targets(package)
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
        str(ROOT / 'BIT101-iOS.xcodeproj/project.pbxproj')], text=True))
    return package, project, targets


@cache
def local_dependency_graph() -> tuple[dict, dict]:
    from validation_inputs import native_project_targets
    package, project, targets = project_configuration()
    native = {name: {module for product in package['products'] if product['name'] in declared for module in product['targets']}
        for name, declared, _ in native_project_targets(project, ROOT)}
    return targets, native


def compilation_settings(platform: str, path: str = '') -> tuple[str, str]:
    from swift_type_index import compilation_unit
    package, project, _ = project_configuration()
    language_modes = package.get('swiftLanguageVersions')
    language = max(language_modes, key=lambda value: tuple(map(int, value.split('.')))) if language_modes \
        else package['toolsVersion']['_version'].split('.')[0]
    key = {'iOS': 'ios', 'watchOS': 'watchos', 'macOS': 'macos', 'macCatalyst': 'ios'}[platform]
    deployment = next(row['version'] for row in package['platforms'] if row['platformName'] == key)
    unit = compilation_unit(path)
    objects = project['objects']
    target = next((row for row in objects.values() if row.get('isa') == 'PBXNativeTarget' and row['name'] == unit), None)
    if target:
        def release_settings(row):
            return next(objects[identifier]['buildSettings']
                for identifier in objects[row['buildConfigurationList']]['buildConfigurations']
                if objects[identifier]['name'] == 'Release')
        settings = release_settings(objects[project['rootObject']]) | release_settings(target)
        language = settings['SWIFT_VERSION']
        deployment = settings[{'ios': 'IPHONEOS_DEPLOYMENT_TARGET', 'watchos': 'WATCHOS_DEPLOYMENT_TARGET',
                               'macos': 'MACOSX_DEPLOYMENT_TARGET'}[key]]
    return language.removesuffix('.0'), deployment


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
    recorded = {key: value for key, value in recorded.items() if key in {'modules', 'build-ui'}
        and isinstance(value, dict) and isinstance(value.get('environment'), str) and isinstance(value.get('results'), dict)} \
        if isinstance(recorded, dict) else {}
    for context in recorded.values():
        context['results'] = {key: row for key, row in context['results'].items() if isinstance(row, dict)
            and isinstance(row.get('condition'), str) and row['condition'] in conditions and type(row.get('value')) is bool}
    if recorded.get(group, {}).get('environment') != environment:
        recorded[group] = {'environment': environment, 'results': {}}
    return recorded


def read_cache(path: Path) -> dict:
    path.with_suffix('.incoming').unlink(missing_ok=True)
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError): return {}


def write_cache(path: Path, recorded: dict) -> None:
    incoming = path.with_suffix('.incoming')
    try:
        incoming.write_text(json.dumps(recorded, sort_keys=True) + '\n')
        incoming.replace(path)
    finally:
        incoming.unlink(missing_ok=True)


@cache
def compilation_condition(condition: str, group: str, *, language_mode: str | None = None, platform: str | None = None, path: str = '') -> bool:
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
    configured_language, deployment = compilation_settings('macOS' if native else 'watchOS' if watch else 'macCatalyst' if catalyst else 'iOS', path)
    language_mode = language_mode or configured_language
    target = f"{architecture}-apple-macosx{deployment}" if native else f"{architecture}-apple-watchos{deployment}" if watch else f"{architecture}-apple-ios{deployment}" + ("-macabi" if catalyst else "")
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
        recorded = read_cache(cache_path)
        conditions = repository_conditions()
        recorded = prepare_cache(recorded, environment_group, context_signature, conditions)
        results = recorded[environment_group]['results']
        if signature in results:
            write_cache(cache_path, recorded)
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
        write_cache(cache_path, recorded)
        return value


def source_platforms(path: str) -> tuple[str, ...]:
    from swift_type_index import compilation_unit
    unit = compilation_unit(path)
    if unit in {'BIT101Watch', 'BIT101WatchWidgets'}: return ('watchOS',)
    if 'Modules' in Path(path).parts: return ('iOS', 'watchOS', 'macOS', 'macCatalyst')
    if unit == 'BIT101-iOS': return ('iOS', 'macCatalyst')
    return ('iOS',)


def active_network_source(source: str, path: str) -> str:
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
    for invalid in (None, [], {'modules': None}, {'modules': {'environment': 'compiler', 'results': None}}):
        assert prepare_cache(invalid, 'modules', 'compiler', {'DEBUG'}) == {'modules': {'environment': 'compiler', 'results': {}}}
    malformed = {'modules': {'environment': 'compiler', 'results': {'bad': {'condition': 'DEBUG', 'value': 1}, 'missing': {}}}}
    assert prepare_cache(malformed, 'modules', 'compiler', {'DEBUG'})['modules']['results'] == {}
    from unittest.mock import patch
    package = {'platforms': [{'platformName': 'ios', 'version': '18.0'}, {'platformName': 'watchos', 'version': '11.0'},
        {'platformName': 'macos', 'version': '15.0'}], 'swiftLanguageVersions': ['5', '6'], 'toolsVersion': {'_version': '6.2.0'}}
    objects = {'project': {'buildConfigurationList': 'project-list'}, 'project-list': {'buildConfigurations': ['project-release']},
        'project-release': {'name': 'Release', 'buildSettings': {'SWIFT_VERSION': '5.0', 'IPHONEOS_DEPLOYMENT_TARGET': '18.1'}},
        'app': {'isa': 'PBXNativeTarget', 'name': 'BIT101-iOS', 'buildConfigurationList': 'app-list'},
        'app-list': {'buildConfigurations': ['app-release']}, 'app-release': {'name': 'Release', 'buildSettings': {'SWIFT_VERSION': '6.0'}}}
    with patch(f'{__name__}.project_configuration', return_value=(package, {'rootObject': 'project', 'objects': objects}, {})):
        assert compilation_settings('macOS') == ('6', '15.0')
        assert compilation_settings('watchOS') == ('6', '11.0')
        assert compilation_settings('iOS', 'Modules/StorageCore/Sources/Storage.swift') == ('6', '18.0')
        assert compilation_settings('macCatalyst', 'BIT101-iOS/App.swift') == ('6', '18.1')
        package['swiftLanguageVersions'] = None
        package['toolsVersion']['_version'] = '5.9.0'
        assert compilation_settings('iOS') == ('5', '18.0')
        objects['app-release']['buildSettings']['SWIFT_VERSION'] = '5.0'
        assert compilation_settings('iOS', 'BIT101-iOS/App.swift') == ('5', '18.1')
    cache_transaction_self_test()


def cache_transaction_self_test() -> None:
    from contextlib import nullcontext
    from io import BytesIO
    from types import SimpleNamespace
    from unittest.mock import patch
    path = ROOT / '.build/static-audit/compilation-conditions.json'
    incoming = path.with_suffix('.incoming')
    original_read = Path.read_text
    source = Path(__file__).read_text()
    files = {}
    fault = None
    def read(target, *args, **kwargs):
        if target == Path(__file__): return source
        if target != path: return original_read(target, *args, **kwargs)
        if target not in files: raise FileNotFoundError(str(target))
        return files[target].decode()
    def write(target, text, *args, **kwargs):
        files[target] = text.encode()
        if fault == 'write':
            files[target] = b'{'
            raise OSError('interrupted write')
        if fault == 'interrupt': raise KeyboardInterrupt()
        return len(text)
    def replace(target, destination):
        if fault == 'replace': raise OSError('interrupted commit')
        files[destination] = files.pop(target)
        return destination
    with patch.object(Path, 'read_text', read), patch.object(Path, 'write_text', write), \
            patch.object(Path, 'replace', replace), patch.object(Path, 'unlink', lambda target, **_: files.pop(target, None)):
        for content in (b'', b'{', b'\xff', b'[]', b'null'):
            files[path], files[incoming] = content, b'pending'
            assert read_cache(path) == {} and incoming not in files
        files.clear()
        assert read_cache(path) == {}
        for fault in ('write', 'replace', 'interrupt', None):
            files[path] = b'{"modules":{}}'
            try: write_cache(path, {'build-ui': {}})
            except (OSError, KeyboardInterrupt): assert fault is not None
            else: assert fault is None
            assert json.loads(files[path]) == ({'modules': {}} if fault else {'build-ui': {}})
            assert incoming not in files
        files[path] = b'{'
        with patch.object(Path, 'mkdir'), patch.object(Path, 'open', return_value=nullcontext(BytesIO())), \
                patch.object(fcntl, 'flock'), patch(f'{__name__}.environment_context', return_value={}), \
                patch(f'{__name__}.repository_conditions', return_value={'DEBUG'}), \
                patch(f'{__name__}.local_import_conditions', side_effect=lambda condition, *_: condition), \
                patch(f'{__name__}.compilation_settings', return_value=('6', '14.0')), \
                patch.object(subprocess, 'check_output', side_effect=['/compiler', '/sdk']), \
                patch.object(subprocess, 'run', return_value=SimpleNamespace(stderr='error: BIT101_CONDITION_FALSE')) as compiler:
            assert compilation_condition.__wrapped__('DEBUG', 'modules') is False
            compiler.assert_called_once()
            assert next(iter(json.loads(files[path])['modules']['results'].values()))['value'] is False


def active_swift_source(source: str, group: str, *, platform: str | None = None, path: str = '') -> str:
    levels = [(True, False)]
    active = []
    code_lines = mask_literals_and_comments(source).split("\n")
    for line, code in zip(source.split("\n"), code_lines):
        masked = re.sub(r"[^\r\n]", lambda match: " " * len(match[0].encode()), line)
        directive = re.match(r"\s*#(if|elseif|else|endif)\b(.*)", code)
        if directive:
            kind, condition = directive.groups()
            if kind in {"if", "elseif"}:
                selected = compilation_condition(condition, group, platform=platform, path=path)
                if kind == "if": levels.append((levels[-1][0] and selected, selected))
                else:
                    _, taken = levels.pop()
                    levels.append((levels[-1][0] and not taken and selected, taken or selected))
            elif kind == "else":
                _, taken = levels.pop()
                levels.append((levels[-1][0] and not taken, True))
            else: levels.pop()
            active.append(masked)
        else: active.append(line if levels[-1][0] else masked)
    return "\n".join(active)
