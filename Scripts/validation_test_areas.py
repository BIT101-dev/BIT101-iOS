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
 'BIT101-iOS.BIT101APIClient': {
     'fetchSchoolLoginContext()': 'first-login',
     'loginSchool(studentID:String,password:String,salt:String,execution:String)': 'first-login',
     'webVPNVerifyInit(studentID:String)': 'first-login',
     'webVPNVerify(studentID:String,password:String,execution:String,cookie:String,salt:String)': 'first-login',
     'register(password:String,token:String,code:String)': 'first-login',
     'checkBIT101Login(fakeCookie:String)': 'account-lifecycle'},
 'BIT101-iOS.FeedbackSubmissionClient': {'submit(:Payload)': 'feedback-delivery', 'submitNetworkSmoke(runID:String)': 'network'},
 'BIT101-iOS.NetworkDiagnosisRunner': {'run()': 'web-interactions'},
 'BIT101-iOS.AppUpdatePromptCoordinator': {'noticeToPresentAtLaunch()': 'web-interactions', 'checkManually()': 'web-interactions'},
 'BIT101-iOS.AppUpdateChecker': {'releaseToPresentAtLaunch()': 'web-interactions',
                                 'checkManually()': 'web-interactions'},
 'BIT101-iOS.EmergencyUpdateChecker': {'noticeToPresentAtLaunch()': 'web-interactions'},
 'BIT101-iOS.LoginService': {'checkLogin()': 'network',
                             'restoreSchoolSessionIfNeeded()': 'network',
                             'login(studentID:String,password:String)': 'first-login',
                             'renewCommunitySession(expectedIdentity:CommunitySessionIdentity)': 'account-lifecycle'},
 'BIT101-iOS.SettingsNetworkService': {'fetchMyInfo()': 'profile-writes',
                                       'updateUser(nickname:String?,motto:String?,avatarMid:String?)': 'profile-writes',
                                       'uploadAvatar(data:Data,filename:String)': 'profile-writes',
                                       'checkLogin()': 'account-lifecycle'},
 'CourseFeature.CourseService': {'fetchCourses(search:String,page:Int)': 'network',
                                 'fetchCourse(id:Int)': 'network',
                                 'fetchCourseHistories(number:String)': 'network',
                                 'fetchComments(courseID:Int,page:Int?)': 'network',
                                 'like(objectID:String)': 'community-writes',
                                 'createComment(objectID:String,text:String,replyObjectID:String?,replyUID:Int?,anonymous:Bool,rate:Int?)': 'community-writes'},
 'GalleryFeature.GalleryService': {'fetchFeed(kind:GalleryFeedKind,page:Int?)': 'network',
                                   'fetchRecommendPage(sourcePage:Int)': 'network',
                                   'searchPosters(query:GallerySearchQuery,page:Int?)': 'network',
                                   'fetchBotFeed(startPage:Int)': 'network',
                                   'fetchClaims()': 'network',
                                   'uploadImage(data:Data,filename:String)': 'community-writes',
                                   'createPoster(title:String,text:String,imageMids:[String],anonymous:Bool,tags:[String],claimID:Int,isPublic:Bool)': 'community-writes',
                                   'fetchPoster(id:Int)': 'network',
                                   'deletePoster(id:Int)': 'community-writes',
                                   'updatePoster(id:Int,title:String,text:String,imageMids:[String],plugins:String,anonymous:Bool,tags:[String],claimID:Int,isPublic:Bool)': 'community-writes',
                                   'fetchReportTypes()': 'network',
                                   'report(objectID:String,typeID:Int,text:String)': 'gallery-report',
                                   'fetchComments(objectID:String,order:CommunityCommentOrder,page:Int?)': 'network',
                                   'fetchRawComments(objectID:String,order:CommunityCommentOrder,page:Int?)': 'community-writes',
                                   'like(objectID:String)': 'community-writes',
                                   'createComment(objectID:String,text:String,replyObjectID:String?,replyUID:Int?,anonymous:Bool,imageMids:[String])': 'community-writes',
                                   'uploadCommentImage(data:Data,filename:String)': 'community-writes',
                                   'deleteComment(id:Int)': 'community-writes',
                                   'fetchMessageUnreadCounts()': 'network',
                                   'fetchMessages(type:GalleryMessageType,lastID:Int?)': 'network'},
 'MineFeature.MineService': {'fetchMyInfo()': 'network',
                             'fetchUserInfo(id:Int)': 'network',
                             'followUser(id:Int)': 'community-writes',
                             'fetchFollowings(page:Int)': 'network',
                             'fetchFollowers(page:Int)': 'network',
                             'fetchMyPosters(page:Int)': 'network',
                             'fetchUserPosters(userID:Int,page:Int)': 'network'},
 'PaperFeature.PaperService': {'fetchPapers(search:String?,order:PaperSortOrder,page:Int)': 'network',
                               'fetchPaper(id:Int)': 'network',
                               'fetchComments(paperID:Int,order:CommunityCommentOrder,page:Int?)': 'network',
                               'likePaper(id:Int)': 'community-writes',
                               'sendLike(objectID:String)': 'community-writes',
                               'createComment(objectID:String,text:String,replyObjectID:String?,replyUID:Int?,anonymous:Bool)': 'community-writes',
                               'createPaper(title:String,intro:String,content:String,anonymous:Bool,publicEdit:Bool)': 'community-writes',
                               'updatePaper(id:Int,title:String,intro:String,content:String,anonymous:Bool,publicEdit:Bool,lastUpdatedAt:String)': 'community-writes',
                               'deletePaper(id:Int)': 'community-writes'},
 'ScheduleInfrastructure.ScheduleService': {'fetchEclassDDLEvents(schoolSMSCodeHandler:SchoolSMSCodeHandler?)': 'network',
                                            'fetchEclassDDLEventsForPreflight()': 'network',
                                            'syncCourses(term:String?)': 'network',
                                            'fetchAvailableTerms()': 'network',
                                            'submitSMSCode(:String,for:BITLoginAuthenticationChallenge,term:String?)': 'web-interactions',
                                            'submitSMSCodeForTeachingCenterAuthentication(:String,for:BITLoginAuthenticationChallenge)': 'network',
                                            'fetchCurrentTermOnly()': 'network',
                                            'prepareTeachingCenterAccess()': 'network',
                                            'fetchCampuses()': 'network',
                                            'fetchBuildings(campusCode:String?)': 'network',
                                            'fetchClassrooms(buildingID:String,term:String)': 'network',
                                            'syncDDLEvents(existingEvents:[DDLEventRecord],storedURL:String,schoolSMSCodeHandler:SchoolSMSCodeHandler?)': 'web-interactions',
                                            'syncDDLEventsForPreflight(existingEvents:[DDLEventRecord],storedURL:String)': 'network',
                                            'refreshLexueCalendarURL(schoolSMSCodeHandler:SchoolSMSCodeHandler?)': 'web-interactions',
                                            'refreshLexueCalendarURLForPreflight()': 'network'},
 'ScoreInfrastructure.ScoreService': {'startScoreChallenge()': 'network',
                                      'fetchScores(detail:Bool,authenticatedBy:BITLoginAuthenticationChallenge)': 'network',
                                      'submitScoreSMSCode(:String,for:BITLoginAuthenticationChallenge)': 'network',
                                      'fetchTrustedTranscriptPages()': 'network',
                                      'submitTranscriptSMSCode(:String,for:BITLoginAuthenticationChallenge)': 'network'}}

MANUAL_CAPABILITY_SCENARIOS = {
 'BIT101-iOS.BIT101APIClient': {
    'fetchSchoolLoginContext()': 'registered-account',
    'loginSchool(studentID:String,password:String,salt:String,execution:String)': 'registered-account',
    'webVPNVerifyInit(studentID:String)': 'registered-account',
    'webVPNVerify(studentID:String,password:String,execution:String,cookie:String,salt:String)': 'registered-account',
    'register(password:String,token:String,code:String)': 'new-account-registration',
    'checkBIT101Login(fakeCookie:String)': 'sign-in-a'},
 'BIT101-iOS.FeedbackSubmissionClient': {'submit(:Payload)': 'delivery'},
 'BIT101-iOS.NetworkDiagnosisRunner': {'run()': 'network-diagnosis'},
 'BIT101-iOS.AppUpdatePromptCoordinator': {'noticeToPresentAtLaunch()': 'update-launch', 'checkManually()': 'update-manual'},
 'BIT101-iOS.AppUpdateChecker': {'releaseToPresentAtLaunch()': 'update-launch', 'checkManually()': 'update-manual'},
 'BIT101-iOS.EmergencyUpdateChecker': {'noticeToPresentAtLaunch()': 'update-launch'},
 'BIT101-iOS.LoginService': {'login(studentID:String,password:String)': 'registered-account',
    'renewCommunitySession(expectedIdentity:CommunitySessionIdentity)': 'refresh-credentials-a'},
 'BIT101-iOS.SettingsNetworkService': {'fetchMyInfo()': 'restore-profile',
    'updateUser(nickname:String?,motto:String?,avatarMid:String?)': 'nickname-save',
    'uploadAvatar(data:Data,filename:String)': 'avatar-bind', 'checkLogin()': 'sign-in-b'},
 'GalleryFeature.GalleryService': {'report(objectID:String,typeID:Int,text:String)': 'submit-and-confirm'},
 'ScheduleInfrastructure.ScheduleService': {
    'submitSMSCode(:String,for:BITLoginAuthenticationChallenge,term:String?)': 'school-sms',
    'syncDDLEvents(existingEvents:[DDLEventRecord],storedURL:String,schoolSMSCodeHandler:SchoolSMSCodeHandler?)': 'school-calendar',
    'refreshLexueCalendarURL(schoolSMSCodeHandler:SchoolSMSCodeHandler?)': 'school-calendar'},
}


def manual_capabilities(check: str, scenario: str) -> set[str]:
    return {f'{owner}.{method}' for owner, methods in MANUAL_CAPABILITY_SCENARIOS.items()
        for method, assigned in methods.items() if assigned == scenario
        and NETWORK_CAPABILITIES.get(owner, {}).get(method) == check}


def reachable_smoke_calls(index: dict) -> dict[str, list[dict]]:
    from pathlib import Path
    from validation_evidence import active_swift_source
    from network_capability_rules import call_can_execute
    files = {'ReleaseNetworkSmoke.swift', 'ReleaseNetworkSmokeModels.swift',
        'NetworkSmokeProductionSession.swift', 'CommunityWriteSmoke.swift'}
    nodes, by_name, active_sources = {}, {}, {}
    for path, facts in index.items():
        if Path(path).name not in files: continue
        active = active_swift_source(Path(path).read_text(), 'network').encode() if Path(path).is_file() else None
        active_sources[path] = active
        for function in facts.get('functionRanges', []) + facts.get('callableRanges', []):
            if active is not None and active[function['start']:function['start'] + 1] in {b' ', b'\n', b'\r'}: continue
            key = (path, function['start'], function['end'])
            nodes[key] = function
            name = '.'.join([*function['scope'], function['name']])
            by_name.setdefault(name, set()).add(key)
    edges = {key: set() for key in nodes}
    calls = {key: [] for key in nodes}
    for key, function in nodes.items():
        if reference := function.get('referenceTarget'):
            owner = '.'.join(function['scope'])
            for target in {reference, owner + '.' + reference.removeprefix('Self.').removeprefix('self.')}:
                edges[key].update(by_name.get(target, set()))
    for path, facts in index.items():
        if Path(path).name not in files: continue
        active = active_sources[path]
        for fact in facts.get('invocations', []):
            if active is not None and active[fact['start']:fact['start'] + 1] in {b' ', b'\n', b'\r'}: continue
            if not call_can_execute(facts, fact): continue
            containing = [key for key in nodes if key[0] == path and key[1] <= fact['start'] < key[2]]
            if not containing: continue
            key = min(containing, key=lambda item: item[2] - item[1])
            expression = fact.get('calledExpression', fact.get('value', '')).removeprefix('self.')
            owner = '.'.join(nodes[key]['scope'])
            candidates = {expression, owner + '.' + expression.removeprefix('Self.')}
            if expression in {'runInParallel', 'probe', 'NetworkSmokePaging.batch', 'NetworkSmokePaging.arrayPage', 'NetworkSmokePaging.messages'}:
                for argument in fact.get('arguments', []): candidates.update({argument, owner + '.' + argument})
            if expression.startswith('dependencies.'):
                candidates.add('ReleaseNetworkSmokeDependencies.' + expression.split('.', 1)[1])
            if fact.get('receiverCall'):
                candidates.add(fact['receiverCall'] + '.' + expression.rsplit('.', 1)[-1])
            for target in candidates: edges[key].update(by_name.get(target, set()))
            if 'calledExpression' in fact: calls[key].append(dict(fact, path=path))
    reached = set(by_name.get('ReleaseNetworkSmokeRunner.run', set()))
    waiting = list(reached)
    while waiting:
        for target in edges[waiting.pop()] - reached:
            reached.add(target); waiting.append(target)
    result = {'network': [], 'community-writes': []}
    for key in reached:
        route = 'community-writes' if Path(key[0]).name == 'CommunityWriteSmoke.swift' else 'network'
        result[route].extend(calls[key])
    return result


def smoke_receiver_resolver(index: dict):
    from swift_type_index import receiver_resolver
    return receiver_resolver(index)


def network_capability_findings(index: dict) -> list[str]:
    from pathlib import Path
    from validation_manual import MANUAL_DEVICE_CHECKS, MANUAL_SCENARIOS
    from validation_policy import NETWORK_GROUPS
    from network_capability_rules import business_methods, method_signature, matching_api_calls, call_can_execute
    actual = business_methods(index)
    receiver_owner = smoke_receiver_resolver(index)
    observed = {'network': set(), 'community-writes': set()}
    edges = {}
    all_functions = {}
    for owner in actual:
        scope = owner.split('.')[1:]
        all_functions[owner] = [(path, function) for path, facts in index.items() for function in facts.get('functionRanges', [])
            if function['scope'] == scope and (Path(path).parts[Path(path).parts.index('Modules') + 1] == owner.split('.')[0]
                if 'Modules' in Path(path).parts else owner.startswith('BIT101-iOS.'))]
    for route, calls in reachable_smoke_calls(index).items():
        for call in calls:
            owner = receiver_owner(call)
            matches = matching_api_calls(index, all_functions.get(owner, []), call)
            if len(matches) == 1: observed[route].add((owner, method_signature(matches[0][1])))
    for owner, functions in all_functions.items():
        for path, function in functions:
            key = (owner, method_signature(function))
            edges[key] = set()
            for call in index[path].get('invocations', []):
                if not function['start'] <= call['start'] < function['end'] or not call_can_execute(index[path], call): continue
                expression = (call.get('calledExpression') or '').removeprefix('self.')
                if '.' in expression: continue
                matches = matching_api_calls(index, functions, dict(call, path=path))
                if len(matches) == 1: edges[key].add((owner, method_signature(matches[0][1])))
    for calls in observed.values():
        waiting = list(calls)
        while waiting:
            for target in edges.get(waiting.pop(), set()) - calls:
                calls.add(target); waiting.append(target)
    errors = [f'新增生产服务需要网络能力验收归属：{owner}' for owner in actual.keys() - NETWORK_CAPABILITIES.keys()]
    expected_manual = {(owner, method) for owner, methods in NETWORK_CAPABILITIES.items()
        for method, route in methods.items() if route in MANUAL_DEVICE_CHECKS}
    registered_manual = {(owner, method) for owner, methods in MANUAL_CAPABILITY_SCENARIOS.items() for method in methods}
    if expected_manual != registered_manual:
        errors.append('人工网络能力需要逐方法登记验收场景：' + str(sorted(expected_manual ^ registered_manual)))
    for name, routes in NETWORK_CAPABILITIES.items():
        signatures = {method_signature(function) for _, function in actual.get(name, [])}
        if signatures != set(routes):
            errors.append(f'网络能力需要验收归属：{name} 新增 {sorted(signatures - routes.keys())}；清理 {sorted(routes.keys() - signatures)}')
        for signature, route in routes.items():
            if route not in NETWORK_GROUPS | MANUAL_DEVICE_CHECKS:
                errors.append(f'网络能力需要有效验收入口：{name}.{signature} → {route}')
            elif route in observed and (name, signature) not in observed[route]:
                errors.append(f'网络能力需要对应入口中的实际服务调用：{name}.{signature} → {route}')
            elif route in MANUAL_DEVICE_CHECKS and MANUAL_CAPABILITY_SCENARIOS.get(name, {}).get(signature) \
                    not in MANUAL_SCENARIOS.get(route, {'delivery'} if route == 'feedback-delivery' else set()):
                errors.append(f'人工网络能力需要有效验收场景：{name}.{signature} → {route}')
    feed_cases = {case['name'] for facts in index.values() for case in facts.get('enumCases', []) if case['scope'] == ['GalleryFeedKind']}
    modes = set()
    for call in reachable_smoke_calls(index)['network']:
        if receiver_owner(call) != 'GalleryFeature.GalleryService': continue
        method = call['calledExpression'].rsplit('.', 1)[-1]
        if method in {'fetchRecommendPage', 'fetchBotFeed'}: modes.add('recommend' if method == 'fetchRecommendPage' else 'bot')
        if method == 'fetchFeed' and 'kind' in call.get('argumentLabels', []):
            value = call['arguments'][call['argumentLabels'].index('kind')]
            if value.startswith('.'): modes.add(value[1:])
    for mode in sorted(feed_cases - modes): errors.append(f'话廊分栏需要实际网络探针：{mode}')
    return errors


def network_capability_self_test() -> None:
    from unittest.mock import patch
    from validation_evidence import compilation_condition
    assert compilation_condition('RELEASE_NETWORK_SMOKE', 'network')
    assert not compilation_condition('DEBUG', 'network')
    from network_capability_rules import signature_function
    index = {f'Modules/{name.split(".")[0]}/Sources/{name.split(".")[1]}.swift': {
        'declarations': [{'kind': 'struct', 'name': name.split('.')[1], 'scope': [], 'inheritedTypes': [], 'isExported': True}],
        'functionRanges': [{**signature_function(method, [name.split(".")[1]]), 'isExported': True, 'isAsync': True, 'start': 0, 'end': 1}
        for method in methods]} for name, methods in NETWORK_CAPABILITIES.items()}
    bindings = {owner.split('.')[1]: owner.split('.')[1].removesuffix('Service').lower() for owner in NETWORK_CAPABILITIES}; bindings['GalleryService'] = 'gallery'
    entries = (('network', 'ReleaseNetworkSmoke.swift', ['ReleaseNetworkSmokeRunner'], 'run'),
        ('community-writes', 'CommunityWriteSmoke.swift', ['CommunityWriteSmoke', 'Operations'], 'production'))
    for route, file, scope, entry in entries:
        calls = [{'calledExpression': bindings[owner.split('.')[1]] + '.' + method.split('(')[0], 'argumentLabels': [p['label'] for p in signature_function(method, [])['parameters']], 'arguments': [p['type'] + '()' for p in signature_function(method, [])['parameters']], 'start': 10, 'scope': scope}
            for owner, methods in NETWORK_CAPABILITIES.items() for method, target in methods.items() if target == route]
        index[file] = {'functionRanges': [{'name': entry, 'scope': scope, 'start': 0, 'end': 100}], 'invocations': calls,
            'typedVariables': [{'name': bindings[owner.split('.')[1]], 'type': owner, 'scope': scope, 'start': 0}
                for owner in NETWORK_CAPABILITIES]}
    index['ReleaseNetworkSmoke.swift']['invocations'].append({'calledExpression': 'CommunityWriteSmoke.Operations.production', 'start': 10, 'scope': ['ReleaseNetworkSmokeRunner']})
    assert network_capability_findings(index) == []
    with patch.dict(MANUAL_CAPABILITY_SCENARIOS['BIT101-iOS.NetworkDiagnosisRunner'], {}, clear=True):
        assert any('逐方法登记' in error for error in network_capability_findings(index))
    with patch.dict(MANUAL_CAPABILITY_SCENARIOS['BIT101-iOS.NetworkDiagnosisRunner'], {'run()': 'unknown-scene'}):
        assert any('有效验收场景' in error for error in network_capability_findings(index))
    from copy import deepcopy
    unbound = deepcopy(index)
    unbound['ReleaseNetworkSmoke.swift']['typedVariables'] = []
    assert any('实际服务调用' in error for error in network_capability_findings(unbound))
    renamed = deepcopy(index)
    for facts in (renamed['ReleaseNetworkSmoke.swift'], renamed['CommunityWriteSmoke.swift']):
        for variable in facts['typedVariables']:
            if variable['name'] == 'gallery': variable['name'] = 'feedClient'
        for call in facts['invocations']:
            call['calledExpression'] = call['calledExpression'].replace('gallery.', 'feedClient.')
    assert not network_capability_findings(renamed)
    unused = deepcopy(index)
    unused['ReleaseNetworkSmoke.swift']['functionRanges'][0]['scope'] = ['UnusedHelper']
    assert any('实际服务调用' in error for error in network_capability_findings(unused))
    nested = deepcopy(index)
    nested['ReleaseNetworkSmoke.swift']['functionRanges'].append({'name': 'unused', 'scope': ['ReleaseNetworkSmokeRunner'], 'start': 5, 'end': 20})
    assert any('实际服务调用' in error for error in network_capability_findings(nested))
    queued = deepcopy(index)
    queued['ReleaseNetworkSmoke.swift']['callableRanges'] = [{'name': 'queued', 'scope': ['ReleaseNetworkSmokeRunner'], 'start': 5, 'end': 20}]
    assert any('实际服务调用' in error for error in network_capability_findings(queued))
    invocation = {'calledExpression': 'runInParallel', 'start': 30, 'arguments': ['queued'], 'scope': ['ReleaseNetworkSmokeRunner']}
    queued['ReleaseNetworkSmoke.swift']['invocations'].append(invocation)
    assert not network_capability_findings(queued)
    invocation['calledExpression'] = 'storeCallback'
    assert any('实际服务调用' in error for error in network_capability_findings(queued))
    from pathlib import Path
    from swift_source_index import swift_syntax_index_sources
    receiver_sources = {
        'Modules/GalleryFeature/Sources/Service.swift': 'public struct GalleryService {}',
        'BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift': 'import GalleryFeature; struct Dependencies { var makeFeed: () -> GalleryService = { GalleryService() } }',
        'BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift': '''import GalleryFeature
            struct Dummy {}; struct ReleaseNetworkSmokeRunner { let dependencies: Dependencies
                func run() { let feedClient = dependencies.makeFeed(); feedClient.fetchFeed()
                    let alias = feedClient; alias.fetchFeed()
                    do { let feedClient = Dummy(); feedClient.fetchFeed() }
                    unknown.fetchFeed(); GalleryFeature.GalleryService().fetchFeed()
                }
            }''',
    }
    receiver_index = swift_syntax_index_sources(receiver_sources)
    receiver_owner = smoke_receiver_resolver(receiver_index)
    receiver_path = 'BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift'
    owners = [receiver_owner(dict(call, path=receiver_path)) for call in receiver_index[receiver_path]['invocations']
        if call['calledExpression'].endswith('.fetchFeed')]
    assert owners == ['GalleryFeature.GalleryService', 'GalleryFeature.GalleryService', 'BIT101-iOS.Dummy', None, 'GalleryFeature.GalleryService']
    overload_sources = {
        'Modules/GalleryFeature/Sources/Service.swift': 'public struct GalleryService { public func fetchFeed(id: Int) {}; public func fetchFeed(id: String) {} }',
        'BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift': 'import GalleryFeature; struct ReleaseNetworkSmokeRunner { func run() { let service = GalleryService(); service.fetchFeed(id: 1); service.fetchFeed(id: "one") } }',
    }
    with patch.dict(NETWORK_CAPABILITIES, {'GalleryFeature.GalleryService': {'fetchFeed(id:Int)': 'network', 'fetchFeed(id:String)': 'network'}}, clear=True), \
            patch.dict(MANUAL_CAPABILITY_SCENARIOS, {}, clear=True):
        assert not network_capability_findings(swift_syntax_index_sources(overload_sources))
        overload_sources['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift'] = overload_sources['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift'].replace('service.fetchFeed(id: "one")', '')
        assert any('fetchFeed(id:String)' in error for error in network_capability_findings(swift_syntax_index_sources(overload_sources)))
    sources = {
        'ReleaseNetworkSmoke.swift': 'struct ReleaseNetworkSmokeRunner { func run() { dependencies.productionSessionProbe() } }',
        'ReleaseNetworkSmokeModels.swift': 'struct ReleaseNetworkSmokeDependencies { var productionSessionProbe: () -> Void = NetworkSmokeProductionSession.run }',
        'NetworkSmokeProductionSession.swift': 'enum NetworkSmokeProductionSession { static func run() { mine.fetchMyInfo() } }',
    }
    def reached(expressions):
        facts = swift_syntax_index_sources(expressions)
        original_is_file, original_read = Path.is_file, Path.read_text
        with patch.object(Path, 'is_file', lambda path: str(path) in expressions or original_is_file(path)), \
                patch.object(Path, 'read_text', lambda path, *args, **kwargs: expressions[str(path)] if str(path) in expressions else original_read(path, *args, **kwargs)):
            return {call['calledExpression'] for call in reachable_smoke_calls(facts)['network']}
    assert 'mine.fetchMyInfo' in reached(sources)
    inactive = dict(sources)
    inactive['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace('dependencies.productionSessionProbe()', '\n#if DEBUG\ndependencies.productionSessionProbe()\n#endif\n')
    assert 'mine.fetchMyInfo' not in reached(inactive)
    unused_reference = dict(sources)
    unused_reference['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace('dependencies.productionSessionProbe()', 'let unused = dependencies.productionSessionProbe')
    assert 'mine.fetchMyInfo' not in reached(unused_reference)
    for statement in ('if', 'while'):
        for condition, expected in [('false', False), ('!true', False), ('true', True), ('!false', True)]:
            branch = dict(sources)
            branch['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
                'dependencies.productionSessionProbe()', f'{statement} {condition} {{ dependencies.productionSessionProbe() }}')
            assert ('mine.fetchMyInfo' in reached(branch)) == expected, (statement, condition)
    disabled = dict(sources)
    disabled['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
        'dependencies.productionSessionProbe()', 'let enabled = false; if enabled { dependencies.productionSessionProbe() }')
    assert 'mine.fetchMyInfo' not in reached(disabled)
    disabled['ReleaseNetworkSmoke.swift'] = disabled['ReleaseNetworkSmoke.swift'].replace('let enabled', 'var enabled')
    assert 'mine.fetchMyInfo' in reached(disabled)
    disabled['ReleaseNetworkSmoke.swift'] = disabled['ReleaseNetworkSmoke.swift'].replace('var enabled', 'let enabled').replace('if enabled', 'while enabled')
    assert 'mine.fetchMyInfo' not in reached(disabled)
    for statement in ('return', 'throw URLError(.cancelled)'):
        terminated = dict(sources)
        terminated['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
            'dependencies.productionSessionProbe()', statement + '; dependencies.productionSessionProbe()')
        assert 'mine.fetchMyInfo' not in reached(terminated), statement
    conditional = dict(sources)
    conditional['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
        'dependencies.productionSessionProbe()', 'if condition { return }; dependencies.productionSessionProbe()')
    assert 'mine.fetchMyInfo' in reached(conditional)
    hoisted = dict(sources)
    hoisted['ReleaseNetworkSmoke.swift'] = 'struct ReleaseNetworkSmokeRunner { func run() { helper(); return; func helper() { dependencies.productionSessionProbe() } } }'
    assert 'mine.fetchMyInfo' in reached(hoisted)
    courses = index['Modules/CourseFeature/Sources/CourseService.swift']['functionRanges']
    courses.append({'name': 'newEndpoint', 'scope': ['CourseService'], 'isExported': True, 'start': 0, 'end': 1})
    assert network_capability_findings(index)
    with patch.dict(NETWORK_CAPABILITIES['CourseFeature.CourseService'], **{'newEndpoint()': 'network'}):
        assert any('实际服务调用' in error for error in network_capability_findings(index))
    courses.pop()
    courses.append({'name': 'fetchComments', 'scope': ['CourseService'], 'isExported': True, 'start': 2, 'end': 3,
        'parameters': [{'label': 'includeReplies', 'type': 'Bool', 'hasDefault': False, 'variadic': False}]})
    assert any('fetchComments(includeReplies:Bool)' in error for error in network_capability_findings(index))
    with patch.dict(NETWORK_CAPABILITIES['CourseFeature.CourseService'], **{'fetchComments(includeReplies:Bool)': 'gallery-report'}):
        assert any('逐方法登记' in error for error in network_capability_findings(index))
        with patch.dict(MANUAL_CAPABILITY_SCENARIOS, {'CourseFeature.CourseService': {'fetchComments(includeReplies:Bool)': 'submit-and-confirm'}}):
            assert not network_capability_findings(index)
    courses.pop()
    course_facts = index['Modules/CourseFeature/Sources/CourseService.swift']
    course_facts['typedVariables'] = [{'name': 'client', 'type': 'HTTPClient', 'scope': ['NewService'], 'start': 0}]
    courses.append({'name': 'fetchCourse', 'scope': ['NewService'], 'isExported': True, 'start': 0, 'end': 1})
    assert any('新增生产服务' in error for error in network_capability_findings(index))
    courses.pop()
    course_facts.pop('typedVariables')
    network_discovery_self_test()
    scores = index['Modules/ScoreInfrastructure/Sources/ScoreService.swift']['functionRanges']
    scores.append({'name': 'newEndpoint', 'scope': ['ScoreService'], 'isExported': True, 'start': 0, 'end': 1})
    assert any('ScoreService' in error and 'newEndpoint()' in error for error in network_capability_findings(index))
    scores.pop()
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
        "共享预览存储维持活动文件": "MediaDependencyTests/sharedPreviewStorageRetainsFilesAcrossEnvironmentCleanupAndClosing",
        "预览创建与登记阻止并发清理": "MediaDependencyTests/previewCreationAndRegistrationExcludeConcurrentCleanup",
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


def network_discovery_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods
    leaf = 'Modules/PaperFeature/Sources/PaperService.swift'
    wrapper = 'BIT101-iOS/Shell/NewService.swift'
    for annotation in ('', ': PaperService'):
        for initializer in ('PaperService()', 'Factory.make()'):
            facts = swift_syntax_index_sources({leaf: 'public struct PaperService { public func fetchPaper(id: Int) async throws -> Int { id } }',
                wrapper: f'''import PaperFeature
enum Factory {{ static func make() -> PaperService {{ PaperService() }} }}
struct NewService {{ private let paper{annotation} = {initializer}; func fetch(id: Int) async throws -> Int {{ try await paper.fetchPaper(id: id) }} }}'''
            })
            assert 'BIT101-iOS.NewService' in business_methods(facts), (annotation, initializer)
    utility_path = 'Modules/ClientCore/Sources/Parser.swift'
    transport_path = 'Modules/TransportCore/Sources/HTTPClient.swift'
    transport = 'public struct HTTPClient { public static func message(from data: Data) -> String? { nil }; public static func make() -> HTTPClient { HTTPClient() }; public static func fetch() async -> Data { Data() } }'
    for call, expected in [('HTTPClient.message(from: data)', False), ('HTTPClient.make()', True), ('await HTTPClient.fetch()', True), ('HTTPClient.shared.send(request)', True)]:
        source = f'import TransportCore; public struct Parser {{ public func parse(data: Data) async {{ _ = {call} }} }}'
        facts = swift_syntax_index_sources({utility_path: source, transport_path: transport})
        assert ('ClientCore.Parser' in business_methods(facts)) == expected, call
    from network_capability_rules import matching_api_calls
    for parameters, invocation in [('name: KIND, page: Int = 0', 'name: "hello"'),
                                   ('page: Int = 0, name: KIND', 'name: "hello"'),
                                   ('name: KIND...', 'name: "hello", "world"')]:
        source = 'public struct Client { ' + '; '.join(
            f'public func fetch({parameters.replace("KIND", kind)}) {{}}' for kind in ('String', 'Int')) \
            + f' }}; func smoke() {{ Client().fetch({invocation}) }}'
        path = 'Modules/GalleryFeature/Sources/Client.swift'
        index = swift_syntax_index_sources({path: source})
        functions = [(path, function) for function in index[path]['functionRanges'] if function['name'] == 'fetch']
        call = next(call for call in index[path]['invocations'] if call['calledExpression'].endswith('.fetch'))
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert len(matches) == 1 and any(parameter['type'] == 'String' for parameter in matches[0][1]['parameters']), parameters
    for module, name in [('GalleryFeature', 'NewGalleryClient'), ('NewForumFeature', 'PostRepository')]:
        path = f'Modules/{module}/Sources/Client.swift'
        for kind in ('HTTPClient', 'Requester', 'NestedRequester'):
            for injection in ('member', 'parameter'):
                member = f'let client: {kind};' if injection == 'member' else ''
                parameters = '' if injection == 'member' else f'client: {kind}, request: URLRequest'
                source = f'import TransportCore; typealias Requester = HTTPClient; typealias NestedRequester = Requester; public struct {name} {{ {member} public func fetchItems({parameters}) async throws {{ _ = try await client.send(request) }} }}'
                index = swift_syntax_index_sources({path: source})
                assert f'{module}.{name}' in business_methods(index), (kind, injection)
                assert any('新增生产服务' in error for error in network_capability_findings(index)), (kind, injection)
