"""Register validation groups and select their workflow inputs."""
from pathlib import PurePosixPath, Path
import re
import subprocess
from swift_source_index import SWIFT_SYNTAX_SOURCE_NAMES
from validation_policy import APP_TEST_GROUPS, TEST_GROUPS, NETWORK_GROUPS, RELEASE_GROUPS, BUILD_HOSTS, VERIFY_GROUPS, DEFAULT_VERIFY_GROUPS

PRODUCT_ROOTS = {"Modules", "BIT101-iOS", "BIT101-iOS.xcodeproj", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"}
PRODUCT_FILES = {"Package.swift", "AppInfo.plist"}
SHARED_TEST_FILES = {"ModuleTests/Support/FileServiceContract.swift"}
PERFORMANCE_TEST_FILES = {"BIT101-iOSTests/PerformanceWorkload.swift", "BIT101-iOSTests/PerformanceWorkloads.json"}
SWIFT_ROOTS = ("Modules", "BIT101-iOS", "BIT101-iOSTests", "BIT101-iOSUITests", "ModuleTests",
    "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets")
VALIDATION_SCRIPTS = {"validation_evidence.py", "validation_inputs.py", "validation_policy.py", "validation_coverage.py", "validation_merge.py", "validation_environment.py", "validation_provenance.py", "validation_test_areas.py", "validation_manual.py", "validation_restore.py", "validation_media.py", "ManualEvidenceProbe.swift", "validate_distribution.py", "validate_versions.py", "swift_source_index.py", "code_quality_rules.py", "audit_callback_rules.py", "ci_wiring_rules.py", "check-module-boundaries.py"} | set(SWIFT_SYNTAX_SOURCE_NAMES)
VALIDATION_SCRIPTS.add("swift_type_index.py")
VALIDATION_SCRIPTS.update({"validation_publication.py", "validation_compilation.py", "validation_performance.py", "network_capability_rules.py", "network_request_contracts.py"})
BUILD_SCRIPTS = {"script-support.sh", "build-install-device.sh", "ci_evidence.py"}
TEST_SCRIPTS = BUILD_SCRIPTS | VALIDATION_SCRIPTS | {"run-extended-tests.sh", "simulator-tests.sh"}


def repository_input_names(root: Path) -> list[str]:
    ignored = subprocess.run(["git", "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--",
        *(":(glob)" + name + "/**/*.swift" for name in SWIFT_ROOTS)], cwd=root, check=True, capture_output=True).stdout
    if ignored:
        raise ValueError("源码目录中的 Swift 文件需要纳入 Git 输入范围：" + "、".join(filter(None, ignored.decode().split("\0"))))
    names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root)
    return sorted(set(names.decode().split("\0")) - {""})


def includes_input(name: str, group: str) -> bool:
    if not group or group == "audit":
        return True
    host = group.removeprefix("build-")
    host = {"release": "all", "network-smoke": "network", "icloud-smoke": "icloud", "icloud-cleanup": "icloud"}.get(host, host)
    path = PurePosixPath(name)
    root = path.parts[0]
    product = name in PRODUCT_FILES or root in PRODUCT_ROOTS and path.suffix != ".md"
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
        tests = root == "BIT101-iOSTests" or root == "Cloudflare" and path.suffix != ".md"
        scripts = TEST_SCRIPTS | {"release-network-smoke.sh"}
    elif host == "icloud":
        tests = root == "BIT101-iOSTests"
        scripts = TEST_SCRIPTS | {"run_icloud_cross_device_smoke.sh", "icloud-smoke-support.sh"}
    elif host in {"restore", "archive", "manual-device"}:
        tests = False
        scripts = BUILD_SCRIPTS | VALIDATION_SCRIPTS
        if host == "manual-device": product = product or root == "Cloudflare" and path.suffix != ".md"
    else:
        raise ValueError(f"需要登记验证组的输入范围：{group}")
    return product or tests or name in SHARED_TEST_FILES and host in APP_TEST_GROUPS | NETWORK_GROUPS | {"icloud"} \
        or name in PERFORMANCE_TEST_FILES and host in APP_TEST_GROUPS | NETWORK_GROUPS | {"ui", "icloud"} \
        or root == "Scripts" and path.name in scripts


def self_test() -> None:
    from unittest.mock import patch
    from types import SimpleNamespace
    with patch.object(subprocess, 'run', return_value=SimpleNamespace(stdout=b'')), \
            patch.object(subprocess, 'check_output', return_value=b'BIT101-iOS/App.swift\0README.md\0BIT101-iOS/App.swift\0'):
        assert repository_input_names(Path('.')) == ['BIT101-iOS/App.swift', 'README.md']
    with patch.object(subprocess, 'run', return_value=SimpleNamespace(stdout=b'Modules/Feature/Sources/build/Probe.swift\0')):
        try: repository_input_names(Path('.'))
        except ValueError as error: assert 'Probe.swift' in str(error)
        else: raise AssertionError('忽略源码需要进入输入范围门禁。')
    for group in RELEASE_GROUPS | TEST_GROUPS | NETWORK_GROUPS | {"build-" + host for host in BUILD_HOSTS}:
        assert includes_input("Package.swift", group), group
    dispatch = (Path(__file__).with_name("run-extended-tests.sh").read_text()
        .split('for group in "${verification_groups[@]}"; do', 2)[2].split("esac", 1)[0])
    dispatched = {group for labels in re.findall(r"(?m)^\s+([a-zA-Z0-9_|-]+)\)", dispatch) for group in labels.split("|")}
    assert dispatched == set(VERIFY_GROUPS)
    assert set(DEFAULT_VERIFY_GROUPS) <= set(VERIFY_GROUPS)
    assert includes_input("README.md", "audit")
    for group in APP_TEST_GROUPS | NETWORK_GROUPS | {"modules", "ui", "icloud", "restore", "manual-device", "build-archive"}:
        assert not includes_input("README.md", group)
        assert not includes_input("AGENTS.md", group)
        assert not includes_input("Scripts/code_quality_tests.py", group)
        assert includes_input("Package.swift", group)
        assert includes_input("Modules/StorageCore/Sources/AppFileService.swift", group)
        assert includes_input("Scripts/validation_inputs.py", group)
        assert includes_input("Scripts/check-module-boundaries.py", group)
        assert includes_input("Scripts/swift_type_index.py", group)
        assert includes_input("Scripts/network_request_contracts.py", group)
        for name in SWIFT_SYNTAX_SOURCE_NAMES:
            assert includes_input("Scripts/" + name, group), (name, group)
    assert includes_input("ModuleTests/Sync/ScheduleSyncTests.swift", "modules")
    assert includes_input("BIT101-iOSTests/Fixtures/schedule-service-response.json", "modules")
    assert not includes_input("BIT101-iOS/ContentView.swift", "modules")
    assert not includes_input("ModuleTests/Sync/ScheduleSyncTests.swift", "manual-device")
    assert includes_input("docs/UI_INTERACTION_COVERAGE.md", "ui")
    for name in PERFORMANCE_TEST_FILES:
        assert includes_input(name, 'all') and includes_input(name, 'ui') and includes_input(name, 'build-ui')
    assert includes_input("Cloudflare/OpenWorker/worker.js", "network")
    for group in ("icloud", "build-icloud-smoke", "network", "build-network-smoke"):
        assert includes_input("BIT101-iOSTests/InfrastructureTests.swift", group)
        assert includes_input("BIT101-iOSTests/Fixtures/schedule-service-response.json", group)
    assert not includes_input("Cloudflare/README.md", "network")
    for name in ("Cloudflare/ErrorReportWorker/worker.js", "Cloudflare/ErrorReportWorker/wrangler.jsonc", "Cloudflare/OpenWorker/worker.js"):
        assert includes_input(name, "manual-device")
