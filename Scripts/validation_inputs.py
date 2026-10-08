"""Select the inputs that can affect each validation workflow."""
from pathlib import PurePosixPath

PRODUCT_ROOTS = {"Modules", "BIT101-iOS", "BIT101-iOS.xcodeproj", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"}
PRODUCT_FILES = {"Package.swift", "AppInfo.plist"}
VALIDATION_SCRIPTS = {"validation_evidence.py", "validation_inputs.py", "swift_source_index.py", "SwiftSyntaxIndexer.swift", "code_quality_rules.py"}
BUILD_SCRIPTS = {"script-support.sh", "build-install-device.sh"}
TEST_SCRIPTS = BUILD_SCRIPTS | VALIDATION_SCRIPTS | {"run-extended-tests.sh"}
APP_TEST_GROUPS = {"all", "release-runtime", "catalyst", "catalyst-release-runtime", "schedule", "infrastructure", "login", "extensions"}
NETWORK_GROUPS = {"network", "ddl", "school-sms", "community-writes", "community-cleanup"}


def includes_input(name: str, group: str) -> bool:
    if not group or group == "audit":
        return True
    host = group.removeprefix("build-")
    host = {"release": "all", "network-smoke": "network", "icloud-smoke": "icloud"}.get(host, host)
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
        scripts = TEST_SCRIPTS | {"run_icloud_cross_device_smoke.sh"}
    elif host in {"restore", "archive", "manual-device"}:
        tests = False
        scripts = BUILD_SCRIPTS | VALIDATION_SCRIPTS
    else:
        raise ValueError(f"需要登记验证组的输入范围：{group}")
    return product or tests or root == "Scripts" and path.name in scripts


def self_test() -> None:
    assert includes_input("README.md", "audit")
    for group in APP_TEST_GROUPS | NETWORK_GROUPS | {"modules", "ui", "icloud", "restore", "manual-device", "build-archive"}:
        assert not includes_input("README.md", group)
        assert not includes_input("AGENTS.md", group)
        assert not includes_input("Scripts/code_quality_tests.py", group)
        assert includes_input("Package.swift", group)
        assert includes_input("Modules/StorageCore/Sources/AppFileService.swift", group)
        assert includes_input("Scripts/validation_inputs.py", group)
    assert includes_input("ModuleTests/Sync/ScheduleSyncTests.swift", "modules")
    assert includes_input("BIT101-iOSTests/Fixtures/schedule-service-response.json", "modules")
    assert not includes_input("BIT101-iOS/ContentView.swift", "modules")
    assert not includes_input("ModuleTests/Sync/ScheduleSyncTests.swift", "manual-device")
    assert includes_input("docs/UI_INTERACTION_COVERAGE.md", "ui")
    assert includes_input("Cloudflare/OpenWorker/worker.js", "network")
    assert not includes_input("Cloudflare/README.md", "network")
