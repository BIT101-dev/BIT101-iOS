"""Shared workflow registration and platform coverage policy."""

APP_TEST_GROUPS = {"all", "release-runtime", "catalyst", "catalyst-release-runtime", "schedule", "infrastructure", "login", "extensions"}
TEST_GROUPS = APP_TEST_GROUPS | {"modules", "ui"}
NETWORK_GROUPS = {"network", "ddl", "school-sms", "community-writes", "community-cleanup"}
RELEASE_GROUPS = {"modules", "all", "release-runtime", "catalyst", "catalyst-release-runtime", "ui", "network", "school-sms", "icloud", "audit", "restore", "manual-device", "build-archive", "community-writes"}
BUILD_HOSTS = {"release", "release-runtime", "ui", "network-smoke", "icloud-smoke", "modules", "catalyst", "catalyst-release-runtime"}
VERIFY_GROUPS = ("modules", "all", "release-runtime", "catalyst", "catalyst-release-runtime", "ui", "network", "community-writes", "ddl", "icloud", "build-archive", "audit")
DEFAULT_VERIFY_GROUPS = tuple(group for group in VERIFY_GROUPS if group != "ddl")
FORMAL_RUNTIME_SUITES = {"ReleaseRuntimeContractTests", "ExtendedLoginTests", "LoginStorageTests", "LoginBootstrapTests", "NetworkClientTests"}
MODULE_COVERAGE_FLOORS = {
    "ClientCore": 63, "CommunityCore": 87, "CommunityPersistence": 97, "CommunityTransport": 79,
    "CommunityUI": 100, "CourseFeature": 65, "DesignSystemKit": 86, "GalleryFeature": 75,
    "MapFeature": 34, "MediaKit": 100, "MineFeature": 82, "PaperFeature": 79,
    "ScheduleContracts": 86, "ScheduleDomain": 75, "ScheduleFeature": 52, "ScheduleInfrastructure": 62,
    "SchedulePersistence": 77, "SchedulePorts": 35, "ScheduleSharedStore": 97, "ScheduleSync": 77,
    "ScorePorts": 95, "ScoreDomain": 92, "ScoreFeature": 73, "ScoreInfrastructure": 75, "StorageCore": 71, "TransportCore": 73,
}
IOS_MODULE_COVERAGE_FLOORS = {
    "ClientCore": 48, "CommunityCore": 47, "CommunityPersistence": 67, "CommunityTransport": 67,
    "CommunityUI": 6, "CourseFeature": 8, "DesignSystemKit": 44, "GalleryFeature": 14,
    "MapFeature": 21, "MediaKit": 53, "MineFeature": 25, "PaperFeature": 36,
    "ScheduleActivityContracts": 100, "ScheduleContracts": 88, "ScheduleDomain": 79,
    "ScheduleFeature": 30, "ScheduleInfrastructure": 26, "SchedulePersistence": 27,
    "SchedulePorts": 64, "ScheduleSharedStore": 52, "ScheduleSync": 5,
    "ScorePorts": 45, "ScoreDomain": 45, "ScoreFeature": 7, "ScoreInfrastructure": 31, "StorageCore": 75, "TransportCore": 77,
}


def coverage_registry_findings(modules: set[str]) -> list[str]:
    errors = []
    for platform, floors, expected in (("macOS", MODULE_COVERAGE_FLOORS, modules - {"ScheduleActivityContracts"}),
            ("iOS", IOS_MODULE_COVERAGE_FLOORS, modules)):
        if set(floors) != expected:
            errors.append(f"{platform} 模块覆盖率登记需要匹配生产模块：新增 {sorted(expected - floors.keys())}；清理 {sorted(floors.keys() - expected)}")
    return errors
