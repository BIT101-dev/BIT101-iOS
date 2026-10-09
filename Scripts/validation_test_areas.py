"""Declare the ownership of every App behavior test suite."""

TEST_AREA_SUITES = {
    "schedule": {
        "AppScheduleCacheEffectsTests", "ClassroomAvailabilityCalculatorTests", "CloudPromptTests",
        "CloudSyncPresentationTests", "CourseLookupMatcherTests", "CourseScheduleRowParserTests",
        "ErrorReportAndSchedulePolicyTests", "ExtendedSchedulePolicyTests", "ReminderContextTests",
        "ReminderPlannerTests", "ScheduleCacheMigrationTests", "ScheduleCalendarLayerOrderingTests",
        "ScheduleCalendarTransactionTests", "ScheduleClassroomCoordinatorTests", "ScheduleCourseEditorTests",
        "ScheduleCourseSyncCoordinatorTests", "ScheduleDDLEditorTests", "ScheduleICSParserTests",
        "ScheduleModuleBoundaryTests", "ScheduleNotificationTimeZoneTests", "ScheduleShareCodeCodecTests",
        "ScheduleSystemCalendarEventBuilderTests", "ScheduleTimelineViewportTests", "SmallTermWeekNormalizerTests",
    },
    "infrastructure": {
        "AppDeepLinkRouteTests", "AppLocalDataOwnershipTests", "AppSettingsPersistenceBoundaryTests",
        "AppUpdateCheckerTests", "CampusMapLocationTests", "ComposerDraftStorageTests",
        "ErrorReportAndSchedulePolicyTests", "ExperimentalPreferenceCloudSyncTests", "ExtendedInfrastructureTests",
        "ExternalScheduleInfrastructureTests", "FeatureCompositionTests", "GalleryContentFilterTests",
        "GalleryRecommendationPrefetchTests", "ICloudSmokeEvidenceTests", "ImageCacheDiskQuotaTests",
        "InfrastructureTests", "MediaDependencyTests", "NetworkClientTests", "NetworkSmokeSMSPromptTests",
        "PaperCommentPagingTests", "NetworkSmokeCoverageTests",
        "MaintenancePerformanceTests",
        "PreferenceCloudPayloadTests", "PreferenceMergeTests", "ReleaseNetworkSmokeLifecycleTests",
        "SchoolCookieIsolationTests", "ScoreCacheDiskRepositoryTests", "ScorePresentationTests",
        "SettingsDependencyOwnershipTests", "SuggestionDependencyTests",
    },
    "login": {"ExtendedLoginTests", "LoginBootstrapTests", "LoginLogicTests", "LoginStorageTests", "SchoolCookieIsolationTests"},
    "extensions": {"AppExternalDisplayTests", "ExternalScheduleInfrastructureTests", "ExternalScheduleWatchStatusTests"},
}


def inventory_findings(suites: set[str]) -> list[str]:
    registered = set().union(*TEST_AREA_SUITES.values())
    return [f"行为测试 suite 需要领域归属：{suite}" for suite in sorted(suites - registered)] \
        + [f"行为测试领域归属需要清理：{suite}" for suite in sorted(registered - suites)]


NETWORK_CAPABILITIES = {
    'GalleryFeature.GalleryService': {
        'fetchFeed': 'network', 'fetchRecommendPage': 'network', 'searchPosters': 'network', 'fetchBotFeed': 'network',
        'fetchClaims': 'network', 'fetchPoster': 'network', 'fetchReportTypes': 'network', 'fetchComments': 'network',
        'fetchMessageUnreadCounts': 'network', 'fetchMessages': 'network', 'report': 'gallery-report',
        'uploadImage': 'community-writes', 'createPoster': 'community-writes', 'deletePoster': 'community-writes',
        'updatePoster': 'community-writes', 'fetchRawComments': 'community-writes', 'like': 'community-writes',
        'createComment': 'community-writes', 'uploadCommentImage': 'community-writes', 'deleteComment': 'community-writes',
    },
    'CourseFeature.CourseService': {
        'fetchCourses': 'network', 'fetchCourse': 'network', 'fetchCourseHistories': 'network', 'fetchComments': 'network',
        'like': 'community-writes', 'createComment': 'community-writes',
    },
    'PaperFeature.PaperService': {
        'fetchPapers': 'network', 'fetchPaper': 'network', 'fetchComments': 'network', 'likePaper': 'community-writes',
        'sendLike': 'community-writes', 'createComment': 'community-writes', 'createPaper': 'community-writes',
        'updatePaper': 'community-writes', 'deletePaper': 'community-writes',
    },
    'MineFeature.MineService': {
        'fetchMyInfo': 'network', 'fetchUserInfo': 'network', 'followUser': 'community-writes',
        'fetchFollowings': 'network', 'fetchFollowers': 'network', 'fetchMyPosters': 'network', 'fetchUserPosters': 'network',
    },
}


def network_capability_findings(index: dict) -> list[str]:
    from pathlib import Path
    from validation_manual import MANUAL_SCENARIOS
    from validation_policy import NETWORK_GROUPS
    actual = {name: set() for name in NETWORK_CAPABILITIES}
    bindings = {'gallery': 'GalleryFeature.GalleryService', 'courses': 'CourseFeature.CourseService',
        'papers': 'PaperFeature.PaperService', 'mine': 'MineFeature.MineService'}
    services = {owner.split('.')[1]: owner for owner in actual}
    observed = {'network': set(), 'community-writes': set()}
    edges = {}
    for path, facts in index.items():
        parts = Path(path).parts
        if Path(path).name in {'ReleaseNetworkSmoke.swift', 'NetworkSmokeProductionSession.swift', 'CommunityWriteSmoke.swift'}:
            route = 'community-writes' if Path(path).name == 'CommunityWriteSmoke.swift' else 'network'
            for call in facts.get('invocations', []):
                expression = call.get('calledExpression') or ''
                method = expression.rsplit('.', 1)[-1]
                receiver = expression.split('.', 1)[0]
                owner = bindings.get(receiver) or services.get(call.get('receiverCall'))
                if owner: observed[route].add((owner, method))
        if 'Modules' not in parts: continue
        module = parts[parts.index('Modules') + 1]
        for function in facts['functionRanges']:
            owner = '.'.join([module, *function['scope']])
            if owner in actual and function.get('isExported'): actual[owner].add(function['name'])
            elif module in {'GalleryFeature', 'CourseFeature', 'PaperFeature', 'MineFeature'} and function.get('isExported') \
                    and function['scope'] and function['scope'][-1].endswith('Service') and owner not in actual:
                actual.setdefault(owner, set()).add(function['name'])
            if owner in NETWORK_CAPABILITIES:
                key = (owner, function['name'])
                edges[key] = {(owner, (call.get('calledExpression') or '').removeprefix('self.'))
                    for call in facts.get('invocations', []) if function['start'] <= call['start'] < function['end']
                    and '.' not in (call.get('calledExpression') or '').removeprefix('self.')}
    for calls in observed.values():
        waiting = list(calls)
        while waiting:
            for target in edges.get(waiting.pop(), set()) - calls:
                calls.add(target); waiting.append(target)
    errors = []
    for owner in actual.keys() - NETWORK_CAPABILITIES.keys():
        errors.append(f'新增生产服务需要网络能力验收归属：{owner}')
    for name, routes in NETWORK_CAPABILITIES.items():
        if actual[name] != set(routes):
            errors.append(f'网络能力需要验收归属：{name} 新增 {sorted(actual[name] - routes.keys())}；清理 {sorted(routes.keys() - actual[name])}')
        for method, route in routes.items():
            if route not in NETWORK_GROUPS | MANUAL_SCENARIOS.keys():
                errors.append(f'网络能力需要有效验收入口：{name}.{method} → {route}')
            elif route in observed and (name, method) not in observed[route]:
                errors.append(f'网络能力需要对应入口中的实际服务调用：{name}.{method} → {route}')
    return errors


def network_capability_self_test() -> None:
    from unittest.mock import patch
    index = {f'Modules/{name.split(".")[0]}/Sources/Service.swift': {'functionRanges': [{'name': method, 'scope': [name.split(".")[1]], 'isExported': True, 'start': 0, 'end': 1}
        for method in methods]} for name, methods in NETWORK_CAPABILITIES.items()}
    bindings = {'GalleryService': 'gallery', 'CourseService': 'courses', 'PaperService': 'papers', 'MineService': 'mine'}
    for route, file in (('network', 'ReleaseNetworkSmoke.swift'), ('community-writes', 'CommunityWriteSmoke.swift')):
        index[file] = {'functionRanges': [], 'invocations': [{'calledExpression': bindings[owner.split('.')[1]] + '.' + method}
            for owner, methods in NETWORK_CAPABILITIES.items() for method, target in methods.items() if target == route]}
    assert network_capability_findings(index) == []
    courses = index['Modules/CourseFeature/Sources/Service.swift']['functionRanges']
    courses.append({'name': 'newEndpoint', 'scope': ['CourseService'], 'isExported': True, 'start': 0, 'end': 1})
    assert network_capability_findings(index)
    with patch.dict(NETWORK_CAPABILITIES['CourseFeature.CourseService'], newEndpoint='network'):
        assert any('实际服务调用' in error for error in network_capability_findings(index))
    courses.pop()
    courses.append({'name': 'fetchCourse', 'scope': ['NewService'], 'isExported': True, 'start': 0, 'end': 1})
    assert any('新增生产服务' in error for error in network_capability_findings(index))
    courses.pop()
    with patch.dict(NETWORK_CAPABILITIES, {'CourseFeature.CourseService': {'fetchCourses': 'missing-check'}}):
        assert network_capability_findings(index)


CRITICAL_CONTRACTS = {
    "all": {
        "账号切换后恢复请求维持归属": "LoginStorageTests/schoolRestoreKeepsItsCapturedAccountAcrossBothNetworkWaits",
        "后台验证维持新会话": "LoginStorageTests/backgroundCookieValidationKeepsTheNewlyRenewedSameAccountSession",
        "凭据写入原子发布": "LoginStorageTests/credentialWriteFailurePreservesThePublishedIdentity",
        "登录取消收敛": "ExtendedLoginTests/cancelledLogin",
        "分页时钟与内存测量": "MaintenancePerformanceTests/testCommunityPaginationPerformance",
        "图片解码时钟与内存测量": "MaintenancePerformanceTests/testStillImageDecodingPerformance",
        "离线宿主资源与网络隔离": "InfrastructureTests/behaviorHostIsolation",
    },
    "modules": {
        "云端冲突决策写入基线": "ScheduleSyncTests/keepingLocalConflictPersistsTheNewBaselineThroughTheProductionRepository",
        "云端写入期间编辑保留待同步状态": "ScheduleSyncTests/localEditsDuringCloudSaveKeepTheirDirtyStateAndReceiveTheBaseline",
        "云端读取遵循账号代际": "ScheduleSyncTests/delayedRemoteReadHonorsTheAccountGenerationAcrossRoundTripSwitches",
        "云端上传失败支持恢复": "ScheduleSyncTests/mergedChangesStayPendingOnDiskAfterUploadFailureAndRetrySuccessfully",
        "成绩认证各阶段维持账号归属": "ScoreInfrastructureBoundaryTests/eachScoreAndTranscriptStageRejectsAnAccountOrGenerationChange",
        "成绩云端比较完整快照": "ScoreInfrastructureBoundaryTests/cloudApplyComparesTheCompleteLocalSnapshotInsideTheRepository",
    },
}


def critical_findings(inventories: dict[str, set[str]]) -> list[str]:
    return [f"关键状态转换合同需要保留测试：{behavior} → {test}" for group, contracts in CRITICAL_CONTRACTS.items()
        for behavior, test in contracts.items() if test not in inventories[group]]
