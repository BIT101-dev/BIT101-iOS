"""Register validation groups and select their workflow inputs."""
from pathlib import PurePosixPath, Path
import re
from validation_policy import APP_TEST_GROUPS, TEST_GROUPS, NETWORK_GROUPS, RELEASE_GROUPS, BUILD_HOSTS, VERIFY_GROUPS, DEFAULT_VERIFY_GROUPS

PRODUCT_ROOTS = {"Modules", "BIT101-iOS", "BIT101-iOS.xcodeproj", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"}
PRODUCT_FILES = {"Package.swift", "AppInfo.plist"}
VALIDATION_SCRIPTS = {"validation_evidence.py", "validation_inputs.py", "validation_policy.py", "validation_environment.py", "validation_provenance.py", "validation_test_areas.py", "validation_manual.py", "validation_media.py", "ManualEvidenceProbe.swift", "validate_distribution.py", "validate_versions.py", "swift_source_index.py", "SwiftSyntaxIndexer.swift", "code_quality_rules.py", "check-module-boundaries.py"}
BUILD_SCRIPTS = {"script-support.sh", "build-install-device.sh"}
TEST_SCRIPTS = BUILD_SCRIPTS | VALIDATION_SCRIPTS | {"run-extended-tests.sh"}


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
        scripts = TEST_SCRIPTS | {"ui_source_facts.py", "ui_rules.py", "ui_design_contracts.py"}
    elif host in NETWORK_GROUPS:
        tests = name == "BIT101-iOSTests/ReleaseNetworkSmokeTests.swift" or root == "Cloudflare" and path.suffix != ".md"
        scripts = TEST_SCRIPTS | {"release-network-smoke.sh"}
    elif host == "icloud":
        tests = name == "BIT101-iOSTests/ManualICloudCrossDeviceSmokeTests.swift"
        scripts = TEST_SCRIPTS | {"run_icloud_cross_device_smoke.sh", "icloud-smoke-support.sh"}
    elif host in {"restore", "archive", "manual-device"}:
        tests = False
        scripts = BUILD_SCRIPTS | VALIDATION_SCRIPTS
        if host == "manual-device": product = product or root == "Cloudflare" and path.suffix != ".md"
    else:
        raise ValueError(f"需要登记验证组的输入范围：{group}")
    return product or tests or root == "Scripts" and path.name in scripts


def self_test() -> None:
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
    assert includes_input("ModuleTests/Sync/ScheduleSyncTests.swift", "modules")
    assert includes_input("BIT101-iOSTests/Fixtures/schedule-service-response.json", "modules")
    assert not includes_input("BIT101-iOS/ContentView.swift", "modules")
    assert not includes_input("ModuleTests/Sync/ScheduleSyncTests.swift", "manual-device")
    assert includes_input("docs/UI_INTERACTION_COVERAGE.md", "ui")
    assert includes_input("Cloudflare/OpenWorker/worker.js", "network")
    assert not includes_input("Cloudflare/README.md", "network")
    for name in ("Cloudflare/ErrorReportWorker/worker.js", "Cloudflare/ErrorReportWorker/wrangler.jsonc", "Cloudflare/OpenWorker/worker.js"):
        assert includes_input(name, "manual-device")
