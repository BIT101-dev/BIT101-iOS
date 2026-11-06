"""Declare App test inventories and verify smoke capability coverage."""

from pathlib import Path
from functools import cache, lru_cache
import re
from validation_policy import (
    FORMAL_RUNTIME_SUITES,
    NETWORK_CAPABILITIES,
    MANUAL_CAPABILITY_SCENARIOS,
    manual_capabilities,
)
from validation_compilation import active_swift_source
from validation_provenance import normalized_test_id
from swift_source_index import swift_syntax_index_sources
from validation_resource_rules import (
    fixture_resource_findings as fixture_resource_findings,
    fixture_resource_self_test as fixture_resource_self_test,
)
from smoke_call_graph import (
    _collect_platform_calls as _collect_platform_calls,
    reachable_smoke_calls as reachable_smoke_calls,
    _resolve_implementation_edges as _resolve_implementation_edges,
    _filter_target_keys as _filter_target_keys,
    _select_candidate_target_keys as _select_candidate_target_keys,
    _process_candidate_target as _process_candidate_target,
    _key_parameter_names as _key_parameter_names,
    _propagate_callback_guards as _propagate_callback_guards,
    _has_constructed_type_match as _has_constructed_type_match,
    _resolve_implementation_targets as _resolve_implementation_targets,
    _stored_callable_reachable as _stored_callable_reachable,
    _find_edge_evidence as _find_edge_evidence,
    _guards_can_execute as _guards_can_execute,
    _process_evidence_call as _process_evidence_call,
    _collect_target_additions as _collect_target_additions,
    _is_owner_path as _is_owner_path,
    _build_enum_syntax_index as _build_enum_syntax_index,
    _resolve_case_iterable_count as _resolve_case_iterable_count,
    platform_smoke_calls as platform_smoke_calls,
    smoke_receiver_resolver as smoke_receiver_resolver,
)


ROOT = Path(__file__).resolve().parents[1]


TEST_AREA_SUITES = {
    "schedule": {
        "AppScheduleCacheEffectsTests",
        "ClassroomAvailabilityCalculatorTests",
        "CloudPromptTests",
        "CloudSyncPresentationTests",
        "CourseLookupMatcherTests",
        "CourseScheduleRowParserTests",
        "ErrorReportAndSchedulePolicyTests",
        "ExtendedSchedulePolicyTests",
        "ReminderContextTests",
        "ReminderPlannerTests",
        "ScheduleCacheMigrationTests",
        "ScheduleCalendarLayerOrderingTests",
        "ScheduleCalendarTransactionTests",
        "ScheduleClassroomCoordinatorTests",
        "ScheduleCourseEditorTests",
        "ScheduleCourseSyncCoordinatorTests",
        "ScheduleDDLEditorTests",
        "ScheduleICSParserTests",
        "ScheduleModuleBoundaryTests",
        "ScheduleNotificationTimeZoneTests",
        "ScheduleShareCodeCodecTests",
        "ScheduleSystemCalendarEventBuilderTests",
        "ScheduleTimelineViewportTests",
        "ScheduleCardTextLayoutTests",
        "SmallTermWeekNormalizerTests",
    },
    "infrastructure": {
        "AccountSettingsTests",
        "AccountProfileMutationTests",
        "AdaptivePageLifetimeTests",
        "AppDeepLinkRouteTests",
        "AppLocalDataOwnershipTests",
        "AppLocalDataResourceTests",
        "AppPageInteractionTests",
        "AppSettingsPersistenceBoundaryTests",
        "AppUpdateCheckerTests",
        "CampusMapLocationTests",
        "ComposerDraftStorageTests",
        "ErrorReportAndSchedulePolicyTests",
        "ErrorReportURLRedactionTests",
        "ExperimentalPreferenceCloudSyncTests",
        "NetworkDiagnosticSupportTests",
        "ExternalScheduleInfrastructureTests",
        "CommunityRecoveryCompositionTests",
        "FeatureCompositionTests",
        "GalleryRecommendationPrefetchTests",
        "ICloudSmokeEvidenceTests",
        "ImageCacheDiskQuotaTests",
        "InfrastructureTests",
        "KeyboardAccessoryOwnershipTests",
        "MediaAvailabilityTests",
        "MediaDependencyTests",
        "MediaPresentationTests",
        "NetworkClientTests",
        "NetworkSmokeSMSPromptTests",
        "PaperCommentPagingTests",
        "PaperContentRecoveryTests",
        "NetworkEvidenceProjectionTests",
        "NetworkSmokeCoverageTests",
        "NetworkSmokeExternalContentTests",
        "NetworkSmokeRegressionContractTests",
        "NetworkBusinessDiagnosticsTests",
        "TrustedTranscriptRecoveryTests",
        "MaintenancePerformanceTests",
        "PersistentBackupPreparationTests",
        "PreferenceCloudPayloadTests",
        "PreferenceMergeTests",
        "ReleaseNetworkSmokeLifecycleTests",
        "SchoolCookieIsolationTests",
        "ScoreCacheDiskRepositoryTests",
        "ScorePresentationTests",
        "SettingsDependencyOwnershipTests",
        "SuggestionDependencyTests",
        "UIInventoryIdentityTests",
    },
    "login": {
        "CommunitySessionRecoveryTests",
        "ExtendedLoginTests",
        "LoginBootstrapTests",
        "LoginLogicTests",
        "LoginStorageTests",
        "NativeLoginTests",
        "SchoolCookieIsolationTests",
    },
    "extensions": {
        "AppExternalDisplayTests",
        "ExternalScheduleInfrastructureTests",
        "ExternalScheduleWatchStatusTests",
    },
}


def inventory_findings(suites: set[str]) -> list[str]:
    registered = set().union(*TEST_AREA_SUITES.values())
    errors = [f"行为测试 suite 需要领域归属：{suite}" for suite in sorted(suites - registered)] + [
        f"行为测试领域归属需要清理：{suite}" for suite in sorted(registered - suites)
    ]
    for group in ("release-runtime", "catalyst-release-runtime"):
        raw = set(raw_test_selectors(group))
        regular = set(
            raw_test_selectors("catalyst" if group == "catalyst-release-runtime" else "all")
        )
        errors.extend(formal_inventory_findings(raw, regular, group))
    return errors


def formal_inventory_findings(raw: set[str], regular: set[str], group: str) -> list[str]:
    raw_suites = {test.split("/", 1)[0] for test in raw}
    missing = {test for test in raw - regular if test.split("/", 1)[0] not in FORMAL_RUNTIME_SUITES}
    return [f"正式运行时测试需要登记：{group} · {test}" for test in sorted(missing)] + [
        f"正式运行时 suite 需要清理：{group} · {suite}"
        for suite in sorted(FORMAL_RUNTIME_SUITES - raw_suites)
    ]


def formal_inventory_self_test() -> None:
    source = """import Testing
struct ExistingRegularTests { @Test func existing() {} }
#if !DEBUG && !BIT101_AUTOMATED_TESTING
struct NewProductionTests { @Test func newProductionContract() {} }
extension ExistingRegularTests { @Test func productionOnly() {} }
#endif
"""
    path = str(ROOT / "BIT101-iOSTests/ReleaseRuntimeContractTests.swift")

    def tests(group):
        facts = swift_syntax_index_sources({path: active_swift_source(source, group, path=path)})
        return {test["value"] for test in facts[path]["tests"]}

    raw, regular = tests("release-runtime"), tests("all")
    assert "NewProductionTests/newProductionContract" in raw - regular
    assert any(
        "NewProductionTests" in row
        for row in formal_inventory_findings(raw, regular, "release-runtime")
    )
    assert any(
        "ExistingRegularTests/productionOnly" in row
        for row in formal_inventory_findings(raw, regular, "release-runtime")
    )
    assert not any(
        "ExistingRegularTests/existing" in row
        for row in formal_inventory_findings(raw, regular, "release-runtime")
    )
    original = ((path, source),)
    facts = indexed_test_sources(original)
    assert indexed_test_sources(original) is facts
    updated = indexed_test_sources(((path, source + "\n@Test func addedContract() {}"),))
    assert {test["value"] for test in updated[path]["tests"]} - {
        test["value"] for test in facts[path]["tests"]
    } == {"addedContract"}


def network_capability_findings(index: dict) -> list[str]:
    from pathlib import Path
    from swift_type_index import SwiftTypeIndex
    from validation_manual import MANUAL_DEVICE_CHECKS, MANUAL_SCENARIOS
    from network_capability_rules import (
        api_invocations,
        business_methods,
        method_signature,
        matching_api_calls,
        call_can_execute,
        execution_index,
    )

    index = execution_index(index)
    actual = business_methods(index)
    types = SwiftTypeIndex(index)
    receiver_owner = smoke_receiver_resolver(index)
    reachable_capabilities = {"network": set(), "community-writes": set()}
    edges = {}
    all_functions = {}
    reachable = reachable_smoke_calls(index)
    for owner in actual:
        scope = owner.split(".")[1:]
        all_functions[owner] = [
            (path, function)
            for path, facts in index.items()
            for function in facts.get("functionRanges", [])
            + facts.get("accessorRanges", [])
            + facts.get("initializers", [])
            if function["scope"] == scope and _is_owner_path(path, owner)
        ]
    for route, calls in reachable.items():
        for call in calls:
            owner = receiver_owner(call)
            matches = matching_api_calls(index, all_functions.get(owner, []), call, types=types)
            if (
                not matches
                and not call.get("isMemberRead")
                and types.resolve(call["path"], call["calledExpression"], call["scope"])
            ):
                constructor = dict(call, calledExpression=call["calledExpression"] + ".init")
                constructor_owner = receiver_owner(constructor)
                matches = matching_api_calls(
                    index, all_functions.get(constructor_owner, []), constructor, types=types
                )
                if matches:
                    owner = constructor_owner
            if len(matches) == 1:
                reachable_capabilities[route].add((owner, method_signature(matches[0][1])))
    for owner, functions in all_functions.items():
        for path, function in functions:
            key = (owner, method_signature(function))
            edges[key] = set()
            for call in api_invocations(index[path]):
                if not function["start"] <= call["start"] < function["end"] or not call_can_execute(
                    index[path], call
                ):
                    continue
                expression = (call.get("calledExpression") or "").removeprefix("self.")
                if "." in expression:
                    continue
                matches = matching_api_calls(index, functions, dict(call, path=path), types=types)
                if len(matches) == 1:
                    edges[key].add((owner, method_signature(matches[0][1])))
    for calls in reachable_capabilities.values():
        waiting = list(calls)
        while waiting:
            for target in edges.get(waiting.pop(), set()) - calls:
                calls.add(target)
                waiting.append(target)
    errors = [
        f"新增生产服务需要网络能力验收归属：{owner}"
        for owner in actual.keys() - NETWORK_CAPABILITIES.keys()
    ]
    expected_manual = {
        (owner, method)
        for owner, methods in NETWORK_CAPABILITIES.items()
        for method, route in methods.items()
        if route in MANUAL_DEVICE_CHECKS
    }
    registered_manual = {
        (owner, method)
        for owner, methods in MANUAL_CAPABILITY_SCENARIOS.items()
        for method in methods
    }
    if expected_manual != registered_manual:
        errors.append(
            "人工网络能力需要逐方法登记验收场景："
            + str(sorted(expected_manual ^ registered_manual))
        )
    for name, routes in NETWORK_CAPABILITIES.items():
        signatures = {method_signature(function) for _, function in actual.get(name, [])}
        if signatures != set(routes):
            errors.append(
                (
                    f"网络能力需要验收归属："
                    f"{name}"
                    f" 新增 "
                    f"{sorted(signatures - routes.keys())}"
                    f"；清理 "
                    f"{sorted(routes.keys() - signatures)}"
                )
            )
        for signature, route in routes.items():
            if route not in reachable_capabilities.keys() | MANUAL_DEVICE_CHECKS:
                errors.append(f"网络能力需要有效验收入口：{name}.{signature} → {route}")
            elif (
                route in reachable_capabilities
                and (name, signature) not in reachable_capabilities[route]
            ):
                errors.append(
                    f"网络能力需要对应入口中的静态可达服务调用：{name}.{signature} → {route}"
                )
            elif route in MANUAL_DEVICE_CHECKS and MANUAL_CAPABILITY_SCENARIOS.get(name, {}).get(
                signature
            ) not in MANUAL_SCENARIOS.get(
                route, {"delivery"} if route == "feedback-delivery" else set()
            ):
                errors.append(f"人工网络能力需要有效验收场景：{name}.{signature} → {route}")
    feed_cases = {
        case["name"]
        for facts in index.values()
        for case in facts.get("enumCases", [])
        if case["scope"] == ["GalleryFeedKind"]
    }
    modes = set()
    for call in reachable["network"]:
        if receiver_owner(call) != "GalleryFeature.GalleryService":
            continue
        method = call["calledExpression"].rsplit(".", 1)[-1]
        if method in {"fetchRecommendPage", "fetchBotFeed"}:
            modes.add("recommend" if method == "fetchRecommendPage" else "bot")
        if not (method == "fetchFeed" and "kind" in call.get("argumentLabels", [])):
            continue
        value = call["arguments"][call["argumentLabels"].index("kind")]
        if value.startswith("."):
            modes.add(value[1:])
    for mode in sorted(feed_cases - modes):
        errors.append(f"话廊分栏需要静态网络采样入口：{mode}")
    return errors


CRITICAL_CONTRACTS = {
    "all": {
        "已确认评论在刷新故障中持续展示": "GalleryRecommendationPrefetchTests/confirmedCommentsAppearFailure",
        "失败预取沿恢复后的网络重新请求": (
            "GalleryRecommendationPrefetchTests/recoveredNetworkReplacesFailedPrefetch"
        ),
        "文章读取直接保留业务请求": "FeatureCompositionTests/authedPaperReadsKeepTheirBusinessRoutes",
        "成绩单补页持续展示已有页面": "TrustedTranscriptRecoveryTests/retriesKeepVisiblePages",
        "成绩单来源替换保留完整结果": "TrustedTranscriptRecoveryTests/partialReplacementKeepsReport",
        "缓存写入故障维持静态与动画图片": "MediaAvailabilityTests/cacheWriteFailureKeepsDownloadedAvailable",
        "媒体内存压力释放临时内容": "MediaAvailabilityTests/memoryPressureReleasesTransientImages",
        "成绩业务失败回写请求诊断": "NetworkBusinessDiagnosticsTests/scoreValidationAmendsKeepsFailureFailure",
        "登录解析诊断保留字段路径": "NetworkBusinessDiagnosticsTests/loginParsingFailureKeepsFieldDiagnostic",
        "账号切换后恢复请求维持归属": "LoginStorageTests/schoolRestoreKeepsCapturedWaits",
        "后台验证维持新会话": "LoginStorageTests/backgroundCookieValidationKeepsSession",
        "凭据写入原子发布": "LoginStorageTests/credentialWriteFailurePreservesIdentity",
        "学校密码共享输入按等待者取消": "LoginLogicTests/schoolPasswordWaitersCancelIndependently",
        "文章评论独立展示已完成结果": "PaperCommentPagingTests/commentsAppearWhilePaperDetailsArePending",
        "帖子评论独立展示已完成结果": "GalleryRecommendationPrefetchTests/completedCommentsAppearArePending",
        "网络提示期间请求持续可用": "NetworkClientTests/networkWarningKeepsTransportAvailable",
        "响应解码保留字段路径": "NetworkClientTests/schoolResponseDecodingRetainsFieldPath",
        "网络诊断保留故障与近期上下文": "ErrorReportAndSchedulePolicyTests/testDiagnosticsRetainFailures",
        "登录取消收敛": "ExtendedLoginTests/cancelledLogin",
        "分页时钟与内存测量": "MaintenancePerformanceTests/testCommunityPaginationPerformance",
        "图片解码时钟与内存测量": "MaintenancePerformanceTests/testStillImageDecodingPerformance",
        "离线宿主资源与网络隔离": "InfrastructureTests/behaviorHostIsolation",
        "共享预览存储维持活动文件": "MediaDependencyTests/previewStorageRetainsFilesAcrossCleanup",
        "预览创建与登记阻止并发清理": "MediaDependencyTests/previewCreation",
        "远程图片复制与登记阻止并发清理": "MediaDependencyTests/remotePreviewCopyPins",
        "账号设置独立恢复": "AppSettingsPersistenceBoundaryTests/corruptSettingsRetainTheirSourceLoadEdits",
        "建议提交与草稿清理解耦": "SuggestionDependencyTests/confirmedSuggestionCompletes",
        "建议暂存受阻期间持续受理": "SuggestionDependencyTests/suggestionPersistenceFailureKeepsAvailable",
    },
    "modules": {
        "云端冲突决策写入参照快照": "ScheduleSyncTests/keepingConflictPersistsRepository",
        "云端冲突选择保留双端独立记录": "ScheduleSyncTests/conflictChoicesPreserveRecordsRepository",
        "恢复快照等待本机确认后同步": "ScheduleSyncTests/recoveredSnapshotsWaitConfirmation",
        "损坏日程根结构保留原文": "SchedulePersistenceTests/unrecognizedCacheRootsPreserveTheirBytes",
        "字段恢复保留学校数据与同步选择": "ScheduleRecoveryTests/damagedFieldsKeepSchoolSchedules",
        "云端写入期间编辑保留待同步状态": "ScheduleSyncTests/editsDuringCloudSaveKeepTheirDirtyState",
        "云端读取遵循账号代际": "ScheduleSyncTests/delayedReadHonorsSwitches",
        "云端上传失败支持恢复": "ScheduleSyncTests/mergedChangesStayOnDiskRetrySuccessfully",
        "成绩认证各阶段维持账号归属": "ScoreInfrastructureBoundaryTests/eachScoreAndRejectsAccountOrChange",
        "成绩云端比较完整快照": "ScoreInfrastructureBoundaryTests/cloudApplyComparesCompleteRepository",
        "成绩缓存受阻期间持续提供在线与页面恢复": "ScoreFeatureTests/unreadableCacheKeepsOnlineScoresVisible",
        "取消详细成绩刷新保留完整快照": "ScoreFeatureTests/cancelledDetailsKeepVisible",
        "文章预取保留离线读取能力": "ServiceContractTests/prefetchedPaperBodyRefresh",
        "日程存储受阻期间保留编辑并恢复保存": (
            "ScheduleRepositoryReconciliationTests/inaccessibleStorageKeepsVisibleEdits"
        ),
        "消息正文独立于未读摘要恢复": "CommunityDependencyBoundaryTests/failedUnreadSummariesRecover",
        "消息首屏独立于挂起的未读摘要": "GalleryMessageAvailabilityTests/historyAppearsArePending",
        "课程评论独立展示已完成结果": "CourseDetailTests/commentsAppearWhileCourseDetailsArePending",
        "草稿图片局部恢复": "ComposerRecoveryTests/missingImageKeepsText",
        "发帖成功与草稿清理解耦": "ComposerLifecycleTests/confirmedPublishCompletes",
        "日程记录局部恢复与原文保留": "ScheduleRecoveryTests/damagedRecordsKeepTheirValidNeighbors",
    },
}


def critical_findings(inventories: dict[str, set[str]]) -> list[str]:
    return [
        f"关键状态转换测试登记需要保留：{behavior} → {test}"
        for group, contracts in CRITICAL_CONTRACTS.items()
        for behavior, test in contracts.items()
        if test not in inventories[group]
    ]


def smoke_scalar_self_test() -> None:
    for kind, condition, operation, expected in (
        ("Bool = false", "value", "service.load(value: false)", False),
        ("Bool = false", "value", "service.load(value: true)", True),
        ("Bool = false", "value", "service.load()", False),
        ("Bool = true", "value", "service.load()", True),
        ("Bool", "value", "let enabled = false; service.load(value: enabled)", False),
        ("Bool", "value", "service.forward(false)", False),
        ("Bool", "value", "service.forward(true)", True),
        ("Int", "value > 0", "service.load(value: 0)", False),
        ("Int", "value > 0", "service.load(value: 1)", True),
        ("String", 'value == "online"', 'service.load(value: "offline")', False),
        ("String", 'value == "online"', 'service.load(value: "online")', True),
        (
            "Int",
            "authorization != nil, value > 0, [500, 502].contains(status)",
            "service.load(value: 0)",
            False,
        ),
        (
            "Int",
            "authorization != nil, value > 0, [500, 502].contains(status)",
            "service.load(value: 1)",
            True,
        ),
        ("Bool", 'let decoded = decode("a,b"), value', "service.load(value: false)", False),
        ("Bool", "ready(flag: true, fallback: false), value", "service.load(value: false)", False),
    ):
        parameter_type = kind.split(" = ")[0]
        sources = {
            "ReleaseNetworkSmoke.swift": (
                "import Example; struct ReleaseNetworkSmokeRunner { let service: CourseService; fu"
                "nc run() async throws { "
            )
            + operation.replace("service.", "try await service.")
            + " } }",
            "Modules/Example/Sources/Service.swift": (
                "import Foundation; public struct CourseService { public func load(value: "
            )
            + kind
            + ") async throws { if "
            + condition
            + " { try await fetch() } }; public func forward(_ value: "
            + parameter_type
            + (
                ") async throws { try await load(value: value) }; public func fetch() async throws"
                " { _ = try await URLSession.shared.data(from: url) } }"
            ),
        }
        calls = reachable_smoke_calls(swift_syntax_index_sources(sources))["network"]
        assert (
            any(call["calledExpression"] == "URLSession.shared.data" for call in calls) == expected
        ), (kind, operation)
    import network_capability_rules as rules

    original_value = rules.branch_value
    evaluations = 0

    def bounded_value(*arguments):
        nonlocal evaluations
        evaluations += 1
        assert evaluations <= 50, "有界重试的上下文需要在零次剩余重试时停止"
        return original_value(*arguments)

    sources = {
        "ReleaseNetworkSmoke.swift": (
            "import Example; struct ReleaseNetworkSmokeRunner { let service: CourseService; func r"
            "un() { service.load() } }"
        ),
        "Modules/Example/Sources/Service.swift": (
            "import Foundation\n            public struct CourseService {\n                public "
            "func load(remaining: Int = 2) {\n                    if authorization != nil, remaini"
            "ng > 0, [500, 502].contains(status) { load(remaining: remaining - 1) }\n             "
            "       _ = URLSession.shared.data(from: url)\n                }\n            }"
        ),
    }
    rules.branch_value = bounded_value
    try:
        calls = platform_smoke_calls(swift_syntax_index_sources(sources), "iOS")["network"]
        assert (
            sum(
                call["calledExpression"] == "URLSession.shared.data"
                and not call.get("isMemberRead")
                for call in calls
            )
            == 3
        )
    finally:
        rules.branch_value = original_value


def smoke_scope_self_test() -> None:
    path = str(ROOT / "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift")
    source = """enum NetworkSmokeScope { case all, communityWrites, communityCleanup }
struct Service { func fetch() {} }
class ReleaseNetworkSmokeRunner {
 let service = Service()
 func run(scope: NetworkSmokeScope) {
  if scope == .communityWrites || scope == .communityCleanup { service.fetch(); return }
 }
}
"""
    facts = swift_syntax_index_sources({path: source})
    calls = reachable_smoke_calls(facts)
    assert not any(call["calledExpression"] == "service.fetch" for call in calls["network"])
    assert any(call["calledExpression"] == "service.fetch" for call in calls["community-writes"])
    positive = swift_syntax_index_sources(
        {
            path: source.replace(
                "scope == .communityWrites || scope == .communityCleanup", "scope == .all"
            )
        }
    )
    assert any(
        call["calledExpression"] == "service.fetch"
        for call in reachable_smoke_calls(positive)["network"]
    )
    helper = """enum NetworkSmokeScope { case all, communityWrites, communityCleanup }
class ReleaseNetworkSmokeRunner {
 func run(scope: NetworkSmokeScope) { CALL }
 func helper(mode: NetworkSmokeScope) { if mode == .communityWrites { service.fetch() } }
}
"""
    for call, expected in (
        ("helper(mode: .communityWrites)", True),
        ("helper(mode: scope)", False),
        ("helper(mode: .all)", False),
        ("helper(mode: .all); helper(mode: .communityWrites)", True),
        ("let forwarded: NetworkSmokeScope = .communityWrites; helper(mode: forwarded)", True),
        ("if scope == .communityWrites { helper(mode: .communityWrites) }", False),
    ):
        calls = reachable_smoke_calls(
            swift_syntax_index_sources({path: helper.replace("CALL", call)})
        )
        assert (
            any(item["calledExpression"] == "service.fetch" for item in calls["network"])
            == expected
        ), call
    for condition, expected in (("scope == .communityWrites", True), ("scope == .all", False)):
        same_name = helper.replace("mode", "scope").replace("scope == .communityWrites", condition)
        calls = reachable_smoke_calls(
            swift_syntax_index_sources(
                {path: same_name.replace("CALL", "helper(scope: .communityWrites)")}
            )
        )
        assert (
            any(item["calledExpression"] == "service.fetch" for item in calls["network"])
            == expected
        ), condition
    callback = helper.replace(
        "func helper(mode: NetworkSmokeScope)",
        "func helper(mode: NetworkSmokeScope, action: () -> Void)",
    ).replace("service.fetch()", "action()")
    for value, expected in ((".all", False), (".communityWrites", True), ("scope", False)):
        call = "helper(mode: " + value + ", action: { service.fetch() })"
        calls = reachable_smoke_calls(
            swift_syntax_index_sources({path: callback.replace("CALL", call)})
        )["network"]
        assert any(item["calledExpression"] == "service.fetch" for item in calls) == expected, value
        forwarded = callback.replace(
            "CALL", "forward(mode: " + value + ", action: { service.fetch() })"
        ).replace(
            "\n}",
            (
                "\n func forward(mode: NetworkSmokeScope, action: () -> Void) { helper(mode: mode,"
                " action: action) }\n}"
            ),
        )
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: forwarded}))["network"]
        assert any(item["calledExpression"] == "service.fetch" for item in calls) == expected, value
    protocol_source = """protocol Servicing { func fetch() }
struct Service: Servicing { func fetch() { client.read() } }
struct Alternative: Servicing { func fetch() { client.alternativeRead() } }
class ReleaseNetworkSmokeRunner {
 var alternative = false
 func makeService() -> any Servicing { if alternative { return Alternative() }; return Service() }
 func run() { let service = makeService(); service.fetch() }
}
"""
    calls = reachable_smoke_calls(swift_syntax_index_sources({path: protocol_source}))["network"]
    assert {"client.read", "client.alternativeRead"} <= {call["calledExpression"] for call in calls}
    dormant = protocol_source.replace("if alternative { return Alternative() };", "")
    calls = reachable_smoke_calls(swift_syntax_index_sources({path: dormant}))["network"]
    assert "client.alternativeRead" not in {call["calledExpression"] for call in calls}
    from network_capability_rules import business_methods

    observer_path = str(ROOT / "Modules/CourseFeature/Sources/Observer.swift")
    for function in (
        "CFSocketCreate",
        "CFSocketCreateWithNative",
        "CFSocketCreateWithSocketSignature",
        "CFSocketCreateConnectedToSocketSignature",
        "CFSocketSetAddress",
        "CFSocketConnectToAddress",
        "CFSocketSendData",
        "CFStreamCreatePairWithSocket",
        "CFStreamCreatePairWithSocketToHost",
        "CFStreamCreatePairWithPeerSocketSignature",
        "CFStreamCreatePairWithSocketToCFHost",
        "CFStreamCreatePairWithSocketToNetService",
    ):
        for qualification in ("", "CoreFoundation.", "CFNetwork."):
            source = (
                "import CoreFoundation; public struct Service { public func fetch() { "
                + qualification
                + function
                + "() } }"
            )
            assert "CourseFeature.Service" in business_methods(
                swift_syntax_index_sources({observer_path: source})
            ), qualification + function
        shadow = (
            "func "
            + function
            + "() {}; public struct Service { public func fetch() { "
            + function
            + "() } }"
        )
        assert not business_methods(swift_syntax_index_sources({observer_path: shadow})), function
    for function in (
        "CFSocketGetTypeID",
        "CFReadStreamGetTypeID",
        "CFReadStreamCreateWithFile",
        "CFReadStreamOpen",
    ):
        source = (
            "import CoreFoundation; public struct Service { public func fetch() { "
            + function
            + "() } }"
        )
        assert not business_methods(swift_syntax_index_sources({observer_path: source})), function
    observer = (
        "import Foundation\nimport TransportCore\npublic final class Observer {\n private let http"
        "Client: HTTPClient\n public func begin() {\n  _ = NotificationCenter.default.addObserver("
        "forName: nil, object: nil, queue: nil) { _ in\n   Task { _ = try await self.httpClient.se"
        'nd(URLRequest(url: URL(string: "https://example.invalid")!)) }\n  }\n }\n}\n'
    )
    assert "CourseFeature.Observer" in business_methods(
        swift_syntax_index_sources({observer_path: observer})
    )
    dormant = observer.replace(
        "public func begin() {", "public func begin() {}\n private func dormant() {"
    )
    assert not business_methods(swift_syntax_index_sources({observer_path: dormant}))
    verify_observer_execution_scope(observer, observer_path, path)


@lru_cache
def indexed_test_sources(sources: tuple[tuple[str, str], ...], group: str = "all") -> dict:
    return swift_syntax_index_sources(dict(sources), cache_context="tests:" + group)


def raw_test_selectors(group: str) -> dict[str, str]:
    if group in TEST_AREA_SUITES:
        return {
            test: selector
            for test, selector in test_selectors("all").items()
            if test.split("/", 1)[0] in TEST_AREA_SUITES[group]
        }
    directory = ROOT / (
        "ModuleTests"
        if group == "modules"
        else "BIT101-iOSUITests"
        if group == "ui"
        else "BIT101-iOSTests"
    )
    sources = {}
    for path in sorted(directory.rglob("*.swift")):
        sources[str(path)] = active_swift_source(path.read_text(), group, path=str(path))
    selectors = {}
    origins = {}
    for path, facts in indexed_test_sources(tuple(sorted(sources.items())), group).items():
        functions = {function["start"]: function for function in facts["functionRanges"]}
        for test in facts["tests"]:
            selector = test["value"]
            if test.get("isTestingTest"):
                parameters = functions[test["start"]]["parameters"]
                selector += (
                    "("
                    + "".join((parameter["label"] or "_") + ":" for parameter in parameters)
                    + ")"
                )
            identity = normalized_test_id(test["value"])
            if identity in origins:
                raise ValueError(
                    f"测试库存需要唯一 Suite/method：{identity}（{origins[identity]} 与 {path}: {selector}）。"
                )
            origins[identity] = f"{path}: {selector}"
            selectors[test["value"]] = selector
    return selectors


@cache
def test_selectors(group: str) -> dict[str, str]:
    selectors = raw_test_selectors(group)
    return (
        {
            test: selector
            for test, selector in selectors.items()
            if test.split("/", 1)[0] in FORMAL_RUNTIME_SUITES
        }
        if group in {"release-runtime", "catalyst-release-runtime"}
        else selectors
    )


@cache
def test_inventory(group: str) -> set[str]:
    return set(test_selectors(group))


@cache
def test_case_inventory(group: str) -> dict[str, int]:
    from validation_inputs import repository_input_names, includes_input

    effective = "all" if group in TEST_AREA_SUITES else group
    directory = ROOT / ("BIT101-iOSUITests" if effective == "ui" else "BIT101-iOSTests")
    sources = {
        str(path): active_swift_source(path.read_text(), effective, path=str(path))
        for path in directory.rglob("*.swift")
    }
    index = indexed_test_sources(tuple(sorted(sources.items())), effective)
    expected, enum_index = {}, None
    for path, facts in index.items():
        for test in facts["tests"]:
            count = test.get("testCaseCount")
            if count is None:
                arguments = test.get("arguments", [])
                match = (
                    re.fullmatch(r"([\w.]+)\.allCases", arguments[0])
                    if len(arguments) == 1
                    else None
                )
                if not match:
                    raise ValueError(f"参数库存需要字面量数组或 CaseIterable 枚举：{test['value']}")
                if enum_index is None:
                    enum_index = _build_enum_syntax_index(index, effective)
                scope = match[1].split(".")
                count = _resolve_case_iterable_count(test, scope, enum_index)
            if type(count) is not int or count <= 0:
                raise ValueError(f"参数库存需要有效测试实例：{test['value']}")
            expected[normalized_test_id(test["value"])] = count
    return {name: count for name, count in expected.items() if name in test_inventory(group)}


def verify_observer_execution_scope(observer, observer_path, path):
    from network_capability_rules import business_methods

    stored = observer.replace(
        "_ = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { _ in",
        "let callback: @Sendable (Notification) -> Void = { _ in",
    ).replace(
        "  }\n }",
        (
            "  }\n  _ = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: n"
            "il, using: callback)\n }"
        ),
    )
    assert "CourseFeature.Observer" in business_methods(
        swift_syntax_index_sources({observer_path: stored})
    )
    for body, smoke_executed in (
        ("Task<Void, Never> { BODY }", True),
        ("_Concurrency.Task { BODY }", True),
        ("_Concurrency.Task<Void, Never>.init { BODY }", True),
        ("Task<Void, Never>.detached { BODY }", True),
        ("let operation = { BODY }; Task<Void, Never>(operation: operation)", True),
        ("let stream = AsyncStream<Int> { _ in BODY }", True),
        ("let stream = _Concurrency.AsyncThrowingStream<Int, Error> { _ in BODY }", True),
        ("let stream = AsyncStream<Int>(unfolding: { BODY; return nil })", False),
        ("let stream = AsyncThrowingStream<Int, Error>(unfolding: { BODY; return nil })", False),
        ("let stream = AsyncStream<Int>(unfolding: { nil }, onCancel: { BODY })", False),
        ("OperationQueue.main.addBarrierBlock { BODY }", True),
        ("DispatchQueue.concurrentPerform(iterations: 1) { _ in BODY }", True),
        ("await withTaskCancellationHandler(operation: {}, onCancel: { BODY })", False),
        (
            (
                "let cancelled = { BODY }; await _Concurrency.withTaskCancellationHandler(operatio"
                "n: {}, onCancel: cancelled)"
            ),
            False,
        ),
    ):
        production = (
            (
                "import Foundation; import TransportCore; public struct CallbackService { let clie"
                "nt: HTTPClient; public func fetch() async { "
            )
            + body.replace(
                "BODY",
                (
                    'Task { _ = try await client.send(URLRequest(url: URL(string: "https://example'
                    '.invalid")!)) }'
                ),
            )
            + " } }"
        )
        assert "CourseFeature.CallbackService" in business_methods(
            swift_syntax_index_sources({observer_path: production})
        ), body
        smoke = (
            "class ReleaseNetworkSmokeRunner { func run() async { "
            + body.replace("BODY", "service.fetch()")
            + " } }"
        )
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: smoke}))["network"]
        assert (
            any(call["calledExpression"] == "service.fetch" for call in calls) == smoke_executed
        ), body
    for execution, expected in (("", False), ("operation()", True)):
        declaration = f"struct Task<S, F> {{ init(operation: () -> Void) {{ {execution} }} }}; "
        production = declaration + (
            "import Foundation; public struct Service { public func fetch() { Task<Void, Never"
            '>(operation: { _ = try? Data(contentsOf: URL(string: "https://example.invalid")!)'
            " }) } }"
        )
        assert (
            bool(business_methods(swift_syntax_index_sources({observer_path: production})))
            == expected
        ), execution
        smoke = declaration + (
            "class ReleaseNetworkSmokeRunner { func run() { Task<Void, Never>(operation: { ser"
            "vice.fetch() }) } }"
        )
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: smoke}))["network"]
        assert any(call["calledExpression"] == "service.fetch" for call in calls) == expected, (
            execution
        )
