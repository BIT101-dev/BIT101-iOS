"""Register validation groups and select their workflow inputs."""
from pathlib import PurePosixPath, Path
import re
import ast
import json
import subprocess
import fcntl
import os
from contextlib import ExitStack
from functools import cache
from validation_policy import SWIFT_SYNTAX_SOURCE_NAMES, NETWORK_CAPABILITIES
from validation_policy import APP_TEST_GROUPS, TEST_GROUPS, NETWORK_GROUPS, RELEASE_GROUPS, BUILD_HOSTS, VERIFY_GROUPS, DEFAULT_VERIFY_GROUPS

NATIVE_PRODUCT_ROOTS = ("BIT101-iOS", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets")
NATIVE_TEST_ROOTS = ("BIT101-iOSTests", "BIT101-iOSUITests")
PRODUCT_ROOTS = {"Modules", "BIT101-iOS.xcodeproj"} | set(NATIVE_PRODUCT_ROOTS)
PRODUCT_FILES = {"Package.swift", "AppInfo.plist"}
SHARED_TEST_FILES = {"ModuleTests/Support/FileServiceContract.swift"}
PERFORMANCE_TEST_FILES = {"BIT101-iOSTests/PerformanceWorkload.swift", "BIT101-iOSTests/PerformanceWorkloads.json"}
SWIFT_ROOTS = ("Modules", "ModuleTests", *NATIVE_PRODUCT_ROOTS, *NATIVE_TEST_ROOTS)
VALIDATION_SCRIPTS = {"validation_evidence.py", "validation_inputs.py", "validation_policy.py", "validation_coverage.py", "validation_merge.py", "validation_environment.py", "validation_provenance.py", "validation_test_areas.py", "validation_manual.py", "validation_restore.py", "validation_media.py", "ManualEvidenceProbe.swift", "validate_distribution.py", "validate_versions.py", "swift_source_index.py", "code_quality_rules.py", "audit_callback_rules.py", "ci_wiring_rules.py", "check-module-boundaries.py"} | set(SWIFT_SYNTAX_SOURCE_NAMES)
VALIDATION_SCRIPTS.add("swift_type_index.py")
VALIDATION_SCRIPTS.update({"validation_publication.py", "validation_compilation.py", "validation_performance.py", "network_capability_rules.py", "network_request_contracts.py"})
BUILD_SCRIPTS = {"script-support.sh", "build-install-device.sh", "ci_evidence.py", "validation_artifacts.py"}
TEST_SCRIPTS = BUILD_SCRIPTS | VALIDATION_SCRIPTS | {"run-extended-tests.sh", "simulator-tests.sh"}
INPUT_TRANSACTION_FILES = {'BIT101-iOSTests/Fixtures/campus-map-locations.lock', 'BIT101-iOSTests/Fixtures/campus-map-locations.incoming'}
WORKER_GENERATED_DIRECTORIES = frozenset({'node_modules', '.wrangler', '.git'})
CI_VALIDATION_GROUPS = {
    'modules': (('modules',), ('Static audit (Apple toolchain)',), ('validation-static-audit',)),
    'release': (('build-archive', 'build-network-smoke', 'build-icloud-smoke'),
        ('Release app and extension builds',), ('validation-release-build',)),
    'catalyst': (('catalyst', 'catalyst-release-runtime'),
        ('Mac Catalyst behavior tests',), ('validation-catalyst-tests',)),
    'app': (('all', 'release-runtime'),
        ('iOS Simulator app and formal runtime',), ('validation-ios-test-shards-app-0',)),
    'ui': (('ui',), ('Build shared iOS UI test host', *(f'iOS Simulator ui ({index})' for index in range(3))),
        tuple(f'validation-ios-test-shards-ui-{index}' for index in range(3))),
}


def ci_validation_affected(names: list[str], group: str) -> bool:
    return any(name == '.github/workflows/ci.yml' or any(includes_input(name, scope)
        for scope in CI_VALIDATION_GROUPS[group][0]) for name in names)


def is_worker_generated(path: PurePosixPath) -> bool:
    return path.parts[0] == 'Cloudflare' and bool(WORKER_GENERATED_DIRECTORIES.intersection(path.parts[1:-1]))


def manifest_targets(package: dict) -> dict[str, dict]:
    """Consume SwiftPM's evaluated manifest, including computed and conditional declarations."""
    targets = {}
    for target in package["targets"]:
        name = target["name"]
        path = target.get("path")
        if not isinstance(path, str):
            raise ValueError(f"{name} requires an explicit source path")
        if target.get('exclude') or target.get('sources') is not None:
            raise ValueError(f"{name} requires SwiftPM's default source discovery within its registered path")
        dependencies = set()
        for dependency in target["dependencies"]:
            value = dependency.get("byName") or dependency.get("target")
            if not value or not isinstance(value[0], str):
                raise ValueError(f"{name} requires local target dependencies: {dependency}")
            dependencies.add(value[0])
        if name in targets:
            raise ValueError(f"duplicate target: {name}")
        targets[name] = {"path": path, "type": target["type"], "dependencies": dependencies}
    return targets


def read_manifest(root: Path) -> dict:
    environment = dict(os.environ)
    environment["CLANG_MODULE_CACHE_PATH"] = str(root / ".build/compiler-cache/ModuleCache.noindex")
    with ExitStack() as locks:
        paths = [root / ".build/compiler-cache/cache.lock"]
        if environment.get("BIT101_EXTENDED_TESTS_LOCK_HELD") != "1":
            paths.insert(0, root / ".build/extended-automation.lock")
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            lock = locks.enter_context(path.open("a"))
            fcntl.flock(lock, fcntl.LOCK_EX)
        result = subprocess.run([
            "xcrun", "swift", "package", "--package-path", str(root),
            "--scratch-path", str(root / ".build/extended-automation"), "dump-package",
        ], capture_output=True, text=True, env=environment)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "SwiftPM manifest evaluation failed")
    return json.loads(result.stdout)


def module_coverage_executables(root: Path, products: Path) -> list[Path]:
    targets = sorted(row['name'] for row in read_manifest(root)['targets'] if row['type'] == 'test')
    executables = [products / (name + '.xctest') / 'Contents/MacOS' / name for name in targets]
    if not executables or any(not path.is_file() for path in executables):
        raise ValueError('模块覆盖率需要当前 manifest 全部测试消费者的可执行文件。')
    return executables


def repository_input_names(root: Path) -> list[str]:
    ignored = subprocess.run(["git", "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--",
        *(":(glob)" + name + "/**" for name in (*SWIFT_ROOTS, 'Scripts', 'Cloudflare', '.githooks'))],
        cwd=root, check=True, capture_output=True).stdout
    omitted = sorted(name for name in ignored.decode().split("\0") if name
        and PurePosixPath(name).name != '.DS_Store' and name not in INPUT_TRANSACTION_FILES
        and not is_worker_generated(PurePosixPath(name))
        and (PurePosixPath(name).parts[0] in SWIFT_ROOTS or PurePosixPath(name).parts[0] == '.githooks'
             or PurePosixPath(name).suffix in {'.py', '.sh', '.swift', '.js', '.rb'}))
    if omitted:
        raise ValueError("源码、资源与执行脚本需要纳入 Git 输入范围：" + "、".join(omitted))
    names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root)
    return sorted(set(names.decode().split("\0")) - {""})


def repository_script_paths(root: Path, suffixes: set[str]) -> list[Path]:
    paths = {path for directory in ('Scripts', 'Cloudflare', '.githooks') for path in (root / directory).rglob('*')
             if (path.suffix in suffixes or directory == '.githooks' and not path.suffix and '.sh' in suffixes)
             and path.is_file() and not is_worker_generated(PurePosixPath(path.relative_to(root)))}
    return sorted(paths)


def python_import_dependencies(sources: dict[str, str]) -> dict[str, set[str]]:
    graph = {}
    for name, source in sources.items():
        imports = set()
        package = name if any(other.startswith(name + '.') for other in sources) else name.rpartition('.')[0]
        def add(module):
            parts = module.split('.')
            imports.update(dependency for length in range(1, len(parts) + 1)
                           if (dependency := '.'.join(parts[:length])) != name or module == name)
        for node in ast.walk(ast.parse(source)):
            if isinstance(node, ast.ImportFrom):
                base = '.'.join(package.split('.')[:len(package.split('.')) - node.level + 1]) if node.level else ''
                module = '.'.join(filter(None, (base, node.module)))
                if module and not (node.level and module == name): add(module)
                for alias in node.names:
                    if alias.name != '*': add('.'.join(filter(None, (module, alias.name))))
            elif isinstance(node, ast.Import):
                for alias in node.names: add(alias.name)
        graph[name] = imports & sources.keys()
    return graph


def python_execution_modules(modules: dict, directory: str) -> dict:
    resolved = dict(modules)
    if directory:
        resolved.update({module.removeprefix(directory + '.'): value for module, value in modules.items()
            if module.startswith(directory + '.')})
    return resolved


def script_dependency_closure(seeds: frozenset[str], sources: dict[str, str]) -> set[str]:
    paths = {'.'.join(PurePosixPath(name).with_suffix('').parts[:-1] if name.endswith('/__init__.py')
        else PurePosixPath(name).with_suffix('').parts): name for name in sources
        if name.endswith('.py') and not name.endswith('_tests.py')}
    selected = set(seeds)
    pending_shell = list(seeds)
    while pending_shell:
        name = pending_shell.pop()
        if not name.endswith('.sh'): continue
        source = '\n'.join(line for line in sources.get(name, '').splitlines() if not line.lstrip().startswith('#'))
        references = re.findall(r'(?:\bScripts/|\$(?:SCRIPT_ROOT|\{SCRIPT_ROOT\})/)([A-Za-z0-9_./-]+\.(?:sh|py))', source)
        for dependency in references:
            dependency = PurePosixPath(dependency).as_posix()
            if dependency in sources and dependency not in selected:
                selected.add(dependency)
                pending_shell.append(dependency)
    for directory in {PurePosixPath(seed).parent for seed in selected if seed in sources and seed.endswith('.py')}:
        prefix = '.'.join(directory.parts)
        resolved = python_execution_modules(paths, prefix)
        graph = python_import_dependencies({module: sources[path] for module, path in resolved.items()})
        pending = [module for module, path in resolved.items() if path in selected and PurePosixPath(path).parent == directory]
        visited = set()
        while pending:
            module = pending.pop()
            if module in visited: continue
            visited.add(module)
            selected.add(resolved[module])
            pending.extend(graph[module] - visited)
    return selected


@cache
def script_inputs(seeds: frozenset[str]) -> set[str]:
    root = Path(__file__).resolve().parent
    sources = {path.relative_to(root).as_posix(): path.read_text() for suffix in ('*.py', '*.sh') for path in root.rglob(suffix)}
    return script_dependency_closure(seeds, sources)


def swift_module_imports(source: str) -> set[str]:
    return set(re.findall(r'\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?`?(\w+)', source))


@cache
def sampled_module_inputs(host: str) -> frozenset[str]:
    root = Path(__file__).resolve().parents[1]
    modules = {path.name: path for path in (root / 'Modules').iterdir() if path.is_dir()}
    graph = {name: set().union(*(swift_module_imports(path.read_bytes().decode('utf-8'))
        for path in (directory / 'Sources').rglob('*.swift'))) & modules.keys() for name, directory in modules.items()}
    if host == 'icloud':
        roots = set().union(*(swift_module_imports(path.read_bytes().decode('utf-8'))
            for path in (root / 'BIT101-iOS').rglob('*.swift')
            if 'Cloud' in path.name)) & modules.keys()
        roots |= swift_module_imports((root / 'BIT101-iOSTests/ManualICloudCrossDeviceSmokeTests.swift').read_bytes().decode('utf-8')) & modules.keys()
        if not roots: raise ValueError('iCloud 采样需要明确的生产模块依赖。')
    else:
        route = 'community-writes' if host == 'community-writes' else 'network'
        roots = {owner.split('.')[0] for owner, methods in NETWORK_CAPABILITIES.items()
            if route in methods.values()} & modules.keys()
    pending, included = list(roots), set()
    while pending:
        name = pending.pop()
        if name in included: continue
        included.add(name)
        pending.extend(graph[name] - included)
    return frozenset(included)


def includes_input(name: str, group: str) -> bool:
    if not group or group == "audit":
        return True
    build = group.startswith("build-")
    host = group.removeprefix("build-")
    host = {"release": "all", "network-smoke": "network", "icloud-smoke": "icloud", "icloud-cleanup": "icloud"}.get(host, host)
    path = PurePosixPath(name)
    root = path.parts[0]
    product = name in PRODUCT_FILES or root in PRODUCT_ROOTS and path.suffix != ".md"
    if root == 'Modules' and not build and host in NETWORK_GROUPS | {'icloud'}:
        product = product and len(path.parts) > 1 and path.parts[1] in sampled_module_inputs(host)
    fixture = name.startswith("BIT101-iOSTests/Fixtures/")
    scripts = set()
    if host == "modules":
        product = name == "Package.swift" or root == "Modules" and path.suffix != ".md"
        tests = root == "ModuleTests" or fixture
        scripts = TEST_SCRIPTS
    elif host in APP_TEST_GROUPS:
        tests = root == "BIT101-iOSTests"
        scripts = TEST_SCRIPTS
    elif host == "ui":
        tests = root == "BIT101-iOSUITests" or name == "docs/UI_INTERACTION_COVERAGE.md"
        scripts = TEST_SCRIPTS | {"ui_source_facts.py", "ui_explanatory_text.py", "ui_rules.py", "ui_native_interactions.py", "ui_design_contracts.py", "ui_inventory.py"}
    elif host in NETWORK_GROUPS:
        tests = root == "Cloudflare" and path.suffix != ".md" or (build or group == "network-smoke") and root == "BIT101-iOSTests"
        scripts = BUILD_SCRIPTS | VALIDATION_SCRIPTS | {"run-extended-tests.sh", "release-network-smoke.sh"}
    elif host == "icloud":
        tests = root == "BIT101-iOSTests" if build else name == "BIT101-iOSTests/ManualICloudCrossDeviceSmokeTests.swift"
        scripts = BUILD_SCRIPTS | VALIDATION_SCRIPTS | {"run-extended-tests.sh"} | {"run_icloud_cross_device_smoke.sh", "icloud-smoke-support.sh"}
    elif host == "manual-device":
        tests = False
        scripts = {"ManualEvidenceProbe.swift"}
        product = product or root == "Cloudflare" and path.suffix != ".md"
    elif host in {"restore", "archive"}:
        tests = False
        scripts = BUILD_SCRIPTS | VALIDATION_SCRIPTS
    else:
        raise ValueError(f"需要登记验证组的输入范围：{group}")
    compiled_tests = (build or group == "network-smoke") and host in NETWORK_GROUPS | {"icloud"}
    return product or tests or name in SHARED_TEST_FILES and (host in APP_TEST_GROUPS or compiled_tests) \
        or name in PERFORMANCE_TEST_FILES and (host in APP_TEST_GROUPS | {"ui"} or compiled_tests) \
        or root == "Scripts" and PurePosixPath(*path.parts[1:]).as_posix() in script_inputs(frozenset(scripts))


def verification_dispatch(source: str) -> set[str]:
    branches = [body for body in re.findall(r'\bcase\s+"?\$group"?\s+in\b(.*?)\besac\b', source, re.DOTALL)
        if re.search(r'\bverify_step\b', body)]
    if len(branches) != 1: raise ValueError('聚合验证需要唯一的逐组执行分派。')
    return {group for labels in re.findall(r'(?m)^\s*([a-zA-Z0-9_|-]+)\)', branches[0]) for group in labels.split('|')}


def self_test() -> None:
    shell_sources = {
        'entry.sh': 'source "$ROOT_DIR/Scripts/helper.sh"\n# Scripts/unused.sh\n',
        'helper.sh': 'python3 "$SCRIPT_ROOT/helper.py"\nsource "${SCRIPT_ROOT}/nested/child.sh"',
        'nested/child.sh': 'source "$ROOT_DIR/Scripts/helper.sh"',
        'helper.py': 'import dependency', 'dependency.py': 'value = 1', 'unused.sh': 'exit 1',
    }
    assert script_dependency_closure(frozenset({'entry.sh'}), shell_sources) == {
        'entry.sh', 'helper.sh', 'nested/child.sh', 'helper.py', 'dependency.py'}
    from unittest.mock import patch
    from types import SimpleNamespace
    root = Path('/fixture')
    sources = {'entry.py': 'from pkg import helper', 'pkg/__init__.py': 'from . import helper',
        'pkg/helper.py': 'from .port import value\nimport json', 'pkg/port.py': 'import shared',
        'shared.py': 'value = 1', 'pkg/json.py': 'pass', 'unused.py': 'pass', 'entry_tests.py': 'import unused'}
    assert script_dependency_closure(frozenset({'entry.py', 'runner.sh'}), sources) == {
        'entry.py', 'runner.sh', 'pkg/__init__.py', 'pkg/helper.py', 'pkg/port.py', 'shared.py'}
    direct = {'pkg/entry.py': 'import helper', 'pkg/helper.py': 'import sibling',
        'pkg/sibling.py': 'value = 1', 'helper.py': 'value = 2', 'unused.py': 'pass'}
    assert script_dependency_closure(frozenset({'pkg/entry.py'}), direct) == {
        'pkg/entry.py', 'pkg/helper.py', 'pkg/sibling.py'}
    nested = root / 'Scripts/nested/check.py'
    shell = root / 'Cloudflare/Worker/Scripts/publish.sh'
    dependency = root / 'Cloudflare/Worker/node_modules/helper.py'
    generated = [root / f'Cloudflare/Worker/.wrangler/tmp/helper{suffix}' for suffix in ('.py', '.sh', '.js')]
    hook = root / '.githooks/pre-push'
    hook_python, hook_shell = root / '.githooks/helpers/check.py', root / '.githooks/helpers/check.sh'
    inventory = {'Scripts': [nested], 'Cloudflare': [shell, dependency, *generated], '.githooks': [hook, hook_python, hook_shell]}
    with patch.object(Path, 'rglob', lambda path, pattern: iter(inventory[path.name])), \
            patch.object(Path, 'is_file', return_value=True):
        assert repository_script_paths(root, {'.py'}) == [hook_python, nested]
        assert repository_script_paths(root, {'.sh'}) == [hook_shell, hook, shell]
    with patch.object(subprocess, 'run', return_value=SimpleNamespace(stdout=b'')), \
            patch.object(subprocess, 'check_output', return_value=b'BIT101-iOS/App.swift\0README.md\0BIT101-iOS/App.swift\0'):
        assert repository_input_names(Path('.')) == ['BIT101-iOS/App.swift', 'README.md']
    for omitted in ('Modules/Feature/Sources/build/Probe.swift',
            'BIT101-iOS/Assets.xcassets/Icon.imageset/build/icon.png',
            'BIT101-iOS/Assets.xcassets/Icon.imageset/.build/Contents.json',
            'BIT101-iOSTests/Fixtures/build/response.json', 'Scripts/build/helper.py',
            'Cloudflare/Worker/.build/check.sh', 'Scripts/.wrangler/helper.py', '.githooks/build/pre-push'):
        with patch.object(subprocess, 'run', return_value=SimpleNamespace(stdout=(omitted + '\0').encode())):
            try: repository_input_names(Path('.'))
            except ValueError as error: assert omitted in str(error)
            else: raise AssertionError('忽略源码、资源与执行脚本需要进入输入范围门禁。')
    with patch.object(subprocess, 'run', return_value=SimpleNamespace(stdout=
            ('BIT101-iOS/.DS_Store\0Scripts/__pycache__/helper.pyc\0Cloudflare/Worker/node_modules/helper.js\0'
             + '\0'.join([*INPUT_TRANSACTION_FILES, *(path.relative_to(root).as_posix() for path in generated)]) + '\0').encode())), \
            patch.object(subprocess, 'check_output', return_value=b'BIT101-iOS/App.swift\0'):
        assert repository_input_names(Path('.')) == ['BIT101-iOS/App.swift']
    for group in RELEASE_GROUPS | TEST_GROUPS | NETWORK_GROUPS | {"build-" + host for host in BUILD_HOSTS}:
        assert includes_input("Package.swift", group), group
        assert includes_input("Scripts/validation_artifacts.py", group) == (group != "manual-device"), group
    dispatch = Path(__file__).with_name('run-extended-tests.sh').read_text()
    for source in (dispatch, dispatch.replace('for group in', 'for  group in'),
            dispatch.replace('case "$group" in', 'case\t$group\tin')):
        assert verification_dispatch(source) == set(VERIFY_GROUPS)
    assert verification_dispatch(dispatch.replace('audit) verify_step audit', 'obsolete) verify_step audit')) != set(VERIFY_GROUPS)
    assert set(DEFAULT_VERIFY_GROUPS) <= set(VERIFY_GROUPS)
    assert includes_input("README.md", "audit")
    assert includes_input("BIT101-iOSTests/NetworkSmokeRegressionTests.swift", "network-smoke")
    assert includes_input("BIT101-iOSTests/PerformanceWorkload.swift", "network-smoke")
    for group in APP_TEST_GROUPS | NETWORK_GROUPS | {"modules", "ui", "icloud", "restore", "manual-device", "build-archive"}:
        assert not includes_input("README.md", group)
        assert not includes_input("AGENTS.md", group)
        assert not includes_input("Scripts/code_quality_tests.py", group)
        assert includes_input("Package.swift", group)
        assert includes_input("Modules/StorageCore/Sources/AppFileService.swift", group)
        for name in {"validation_inputs.py", "check-module-boundaries.py", "swift_type_index.py",
                "network_request_contracts.py", "ui_source_facts.py", *SWIFT_SYNTAX_SOURCE_NAMES}:
            assert includes_input("Scripts/" + name, group) == (group != "manual-device"), (name, group)
    assert includes_input("ModuleTests/Sync/ScheduleSyncTests.swift", "modules")
    assert includes_input("BIT101-iOSTests/Fixtures/schedule-service-response.json", "modules")
    assert not includes_input("BIT101-iOS/ContentView.swift", "modules")
    assert not includes_input("ModuleTests/Sync/ScheduleSyncTests.swift", "manual-device")
    assert includes_input("Scripts/ManualEvidenceProbe.swift", "manual-device")
    assert includes_input("docs/UI_INTERACTION_COVERAGE.md", "ui")
    for name in PERFORMANCE_TEST_FILES:
        assert includes_input(name, 'all') and includes_input(name, 'ui') and includes_input(name, 'build-ui')
    assert includes_input("Cloudflare/OpenWorker/worker.js", "network")
    for group in ("build-icloud-smoke", "build-network-smoke"):
        assert includes_input("BIT101-iOSTests/InfrastructureTests.swift", group)
        assert includes_input("BIT101-iOSTests/Fixtures/schedule-service-response.json", group)
        assert includes_input("ModuleTests/Support/FileServiceContract.swift", group)
        assert includes_input("BIT101-iOSTests/PerformanceWorkloads.json", group)
    for group in NETWORK_GROUPS | {"icloud"}:
        assert not includes_input("BIT101-iOSTests/InfrastructureTests.swift", group)
        assert not includes_input("BIT101-iOSTests/Fixtures/schedule-service-response.json", group)
        assert includes_input("Scripts/simulator-tests.sh", group)
        assert not includes_input("ModuleTests/Support/FileServiceContract.swift", group)
        assert not includes_input("BIT101-iOSTests/PerformanceWorkloads.json", group)
    assert includes_input("BIT101-iOSTests/ManualICloudCrossDeviceSmokeTests.swift", "icloud")
    assert includes_input("BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift", "network")
    assert includes_input("Modules/ScheduleInfrastructure/Sources/ScheduleServiceLexue.swift", "school-sms")
    assert not includes_input("Cloudflare/README.md", "network")
    for name in ("Cloudflare/ErrorReportWorker/worker.js", "Cloudflare/ErrorReportWorker/wrangler.jsonc", "Cloudflare/OpenWorker/worker.js"):
        assert includes_input(name, "manual-device")


def native_project_paths(project: dict, root: Path) -> dict[str, Path]:
    objects = project["objects"]
    paths: dict[str, Path] = {}
    def visit(identifier, parent):
        item = objects[identifier]
        tree = item.get("sourceTree", "<group>")
        if tree not in {'<group>', 'SOURCE_ROOT', '<absolute>'}: return
        base = root if tree == "SOURCE_ROOT" else parent
        path = base / item.get("path", "")
        paths[identifier] = path
        for child in item.get("children", []): visit(child, path)
    visit(objects[project["rootObject"]]["mainGroup"], root)
    return paths


def native_project_targets(project: dict, root: Path) -> list[tuple[str, set[str], set[Path]]]:
    objects = project["objects"]
    paths = native_project_paths(project, root)
    result = []
    for identifier, target in objects.items():
        if target.get("isa") != "PBXNativeTarget": continue
        declared = {objects[product]["productName"] for product in target.get("packageProductDependencies", [])}
        sources = set()
        for group_id in target.get("fileSystemSynchronizedGroups", []):
            group = objects[group_id]
            directory = paths.get(group_id, root / group["path"])
            excluded = {name for exception in group.get("exceptions", []) if objects[exception].get("target") == identifier
                        for name in objects[exception].get("membershipExceptions", [])}
            sources.update(path for path in directory.rglob("*.swift") if path.relative_to(directory).as_posix() not in excluded)
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            if phase.get("isa") != "PBXSourcesBuildPhase": continue
            for build_file in phase.get("files", []):
                reference = objects[build_file]["fileRef"]
                if reference not in paths: raise ValueError(f"源文件需要工程路径归属：{reference}")
                if paths[reference].suffix == ".swift": sources.add(paths[reference])
        result.append((target["name"], declared, sources))
    return result



@cache
def performance_workloads() -> dict:
    return {name: (row['testIdentifier'], row['input']) for name, row in
        json.loads((Path(__file__).resolve().parents[1] / 'BIT101-iOSTests/PerformanceWorkloads.json').read_text()).items()}



def performance_group(test: str) -> str:
    return 'ui' if test.startswith('MaintenancePerformanceUITests/') else 'all'
