"""Declare App test inventories and verify smoke capability coverage."""
from pathlib import Path
from functools import cache
from validation_policy import FORMAL_RUNTIME_SUITES, NETWORK_CAPABILITIES, MANUAL_CAPABILITY_SCENARIOS, manual_capabilities
from validation_compilation import active_swift_source
from validation_provenance import normalized_test_id
from swift_source_index import swift_syntax_index_sources

ROOT = Path(__file__).resolve().parents[1]

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
        "PaperCommentPagingTests", "NetworkEvidenceProjectionTests", "NetworkSmokeCoverageTests", "NetworkSmokeExternalContentTests",
        "MaintenancePerformanceTests",
        "PreferenceCloudPayloadTests", "PreferenceMergeTests", "ReleaseNetworkSmokeLifecycleTests",
        "SchoolCookieIsolationTests", "ScoreCacheDiskRepositoryTests", "ScorePresentationTests",
        "SettingsDependencyOwnershipTests", "SuggestionDependencyTests", "UIInventoryIdentityTests",
    },
    "login": {"ExtendedLoginTests", "LoginBootstrapTests", "LoginLogicTests", "LoginStorageTests", "SchoolCookieIsolationTests"},
    "extensions": {"AppExternalDisplayTests", "ExternalScheduleInfrastructureTests", "ExternalScheduleWatchStatusTests"},
}


def inventory_findings(suites: set[str]) -> list[str]:
    registered = set().union(*TEST_AREA_SUITES.values())
    return [f"行为测试 suite 需要领域归属：{suite}" for suite in sorted(suites - registered)] \
        + [f"行为测试领域归属需要清理：{suite}" for suite in sorted(registered - suites)]


def reachable_smoke_calls(index: dict) -> dict[str, list[dict]]:
    from validation_compilation import source_platforms
    platforms = {platform for path, facts in index.items()
        if any(function['scope'] == ['ReleaseNetworkSmokeRunner'] and function['name'] == 'run'
            for function in facts.get('functionRanges', [])) for platform in source_platforms(path)}
    result, seen = {'network': [], 'community-writes': []}, {'network': set(), 'community-writes': set()}
    for platform in sorted(platforms):
        for route, calls in platform_smoke_calls(index, platform).items():
            for call in calls:
                key = (call['path'], call.get('start'), call.get('end'), call['calledExpression'])
                if key in seen[route]: continue
                seen[route].add(key)
                result[route].append(call)
    return result


def platform_smoke_calls(index: dict, platform: str) -> dict[str, list[dict]]:
    from pathlib import Path
    import re
    from validation_compilation import source_platforms
    from network_capability_rules import api_argument_bindings, api_invocations, call_can_execute, matching_api_calls
    from swift_type_index import SwiftTypeIndex, compilation_unit, receiver_resolver
    types, resolve_receiver = SwiftTypeIndex(index), receiver_resolver(index)
    units = {compilation_unit(path) for path, facts in index.items()
        if any(function['scope'] == ['ReleaseNetworkSmokeRunner'] and function['name'] == 'run'
            for function in facts.get('functionRanges', []))}
    files = {path for path in index if platform in source_platforms(path)
        and (compilation_unit(path) in units or 'Modules' in Path(path).parts)}
    nodes, by_name, active_sources, callables, stored_callables = {}, {}, {}, set(), {}
    task_locals = {(types.resolve(path, '.'.join(variable['scope']), aliases=False), variable['name'])
        for path, facts in index.items() for variable in facts.get('typedVariables', []) if variable.get('isTaskLocal')}
    for path, facts in index.items():
        if path not in files: continue
        active = active_swift_source(facts['source'], 'network', platform=platform, path=path).encode() if 'source' in facts else None
        active_sources[path] = active
        closures = facts.get('callableRanges', []) + facts.get('inlineClosureRanges', [])
        for function in facts.get('functionRanges', []) + facts.get('accessorRanges', []) + closures:
            if active is not None and active[function['start']:function['start'] + 1] in {b' ', b'\n', b'\r'}: continue
            key = (path, function['start'], function['end'])
            nodes[key] = function
            if function in closures: callables.add(key)
            name = '.'.join([*function['scope'], function['name']])
            by_name.setdefault(name, set()).add(key)
            by_name.setdefault(compilation_unit(path) + '.' + name, set()).add(key)
    for path in files:
        facts = index[path]
        for call in facts.get('invocations', []):
            if not call.get('closureArguments'): continue
            expression = call['calledExpression'].removesuffix('.init')
            target = types.resolve(path, '.'.join(call['scope']) if expression == 'Self' else expression, call['scope'])
            if not target: continue
            properties = {node['name'] for source_path, source in index.items() for node in source.get('typedVariables', [])
                if not node.get('lexicalScope') and '->' in node.get('type', '')
                and types.resolve(source_path, '.'.join(node['scope']), aliases=False) == target}
            initializers = [(source_path, function) for source_path, source in index.items() for function in source.get('initializers', [])
                if function.get('isExplicitInitializer') and types.resolve(source_path, '.'.join(function['scope']), aliases=False) == target]
            for position, start, end in call.get('closureArguments', []):
                labels = call.get('argumentLabels', [])
                key = (path, start, end)
                names = {labels[position]} & properties if position < len(labels) and not initializers else set()
                for source_path, function in initializers:
                    for binding in api_argument_bindings(function, call):
                        if position >= len(binding): continue
                        parameter = binding[position].get('name', '')
                        for assignment in index[source_path].get('expressions', []):
                            if function['start'] <= assignment['start'] < function['end']:
                                if match := re.fullmatch(r'self\.(\w+)\s*=\s*' + re.escape(parameter), assignment['value']):
                                    names.update({match[1]} & properties)
                if key not in nodes or not names: continue
                parents = [parent for parent in nodes if parent[0] == path and parent[1] <= call['start'] < parent[2]]
                if not parents: continue
                stored_callables[key] = min(parents, key=lambda item: item[2] - item[1])
                for name in names:
                    by_name.setdefault('.'.join([*target[1], name]), set()).add(key)
                    by_name.setdefault('.'.join([target[0], *target[1], name]), set()).add(key)
    edges = {key: set() for key in nodes}
    calls = {key: [] for key in nodes}
    callback_calls = []
    constructed_types, implementation_edges, implementations = {}, {}, {}
    for target in types.records:
        for base in types.bases(target):
            if protocol := types.resolve(types.paths[target], base, target[1][:-1]):
                implementations.setdefault('.'.join([protocol[0], *protocol[1]]), set()).add(target)
    nodes_by_path = {path: [key for key in nodes if key[0] == path] for path in files}
    for key, function in nodes.items():
        if reference := function.get('referenceTarget'):
            owner = '.'.join(function['scope'])
            for target in {reference, owner + '.' + reference.removeprefix('Self.').removeprefix('self.')}:
                edges[key].update(by_name.get(target, set()))
    for path, facts in index.items():
        if path not in files: continue
        active = active_sources[path]
        for fact in api_invocations(facts):
            if active is not None and active[fact['start']:fact['start'] + 1] in {b' ', b'\n', b'\r'}: continue
            if not call_can_execute(facts, fact): continue
            containing = [key for key in nodes_by_path[path] if key[1] <= fact['start'] < key[2]]
            if not containing: continue
            key = min(containing, key=lambda item: item[2] - item[1])
            expression = fact.get('calledExpression', fact.get('value', '')).removeprefix('self.')
            if not fact.get('isMemberRead'):
                nominal = types.resolve(path, '.'.join(fact['scope']) if expression == 'Self' else expression.removesuffix('.init'), fact['scope'])
                if nominal: constructed_types.setdefault(nominal, set()).add(key)
            owner = '.'.join(nodes[key]['scope'])
            candidates = {expression, owner + '.' + expression.removeprefix('Self.')}
            callbacks = set()
            executes_callbacks = expression in {'runInParallel', 'probe', 'NetworkSmokePaging.batch', 'NetworkSmokePaging.arrayPage', 'NetworkSmokePaging.messages', 'Task', 'Task.init', 'Task.detached', 'withTaskGroup', 'withThrowingTaskGroup', 'withTaskCancellationHandler', 'withCheckedContinuation', 'withCheckedThrowingContinuation'}
            if executes_callbacks:
                for position, argument in enumerate(fact.get('arguments', [])):
                    if expression != 'withTaskCancellationHandler' or position == 0: callbacks.update({argument, owner + '.' + argument})
                edges[key].update((path, start, end) for position, start, end in fact.get('closureArguments', [])
                    if (expression != 'withTaskCancellationHandler' or position == 0) and (path, start, end) in nodes)
            if expression.endswith('.withValue') and '.$' in expression:
                receiver, _, property_name = expression.removesuffix('.withValue').rpartition('.$')
                if (types.resolve(path, receiver, fact['scope']), property_name) in task_locals:
                    edges[key].update((path, start, end) for position, start, end in fact.get('closureArguments', [])
                        if position == 1 and (path, start, end) in nodes)
                    if len(fact.get('arguments', [])) > 1:
                        argument = fact['arguments'][1]
                        callbacks.update({argument, owner + '.' + argument})
            if expression.startswith('dependencies.'):
                candidates.add('ReleaseNetworkSmokeDependencies.' + expression.split('.', 1)[1])
            if fact.get('receiverCall'):
                candidates.add(fact['receiverCall'] + '.' + expression.rsplit('.', 1)[-1])
            if resolved := resolve_receiver(dict(fact, path=path)):
                candidates.add(resolved + '.' + expression.rsplit('.', 1)[-1])
                method = expression.rsplit('.', 1)[-1]
                concrete = {target for target in implementations.get(resolved, set())
                    if '.'.join([target[0], *target[1], method]) in by_name}
                if len(concrete) == 1:
                    target = concrete.pop()
                    name = '.'.join([target[0], *target[1], method])
                    matches = matching_api_calls(index, [(node[0], nodes[node]) for node in by_name[name]], dict(fact, path=path), types=types)
                    for source_path, function in matches:
                        implementation_edges.setdefault(key, set()).add(((source_path, function['start'], function['end']), target))
            for target in candidates:
                target_keys = {target_key for target_key in by_name.get(target, set())
                    if (compilation_unit(target_key[0]) == compilation_unit(path) or target.split('.', 1)[0] in types.module_names)
                    and (target_key in stored_callables or not nodes[target_key].get('lexicalScope') or target_key[0] == path
                    and fact.get('lexicalScope', [])[:len(nodes[target_key]['lexicalScope'])] == nodes[target_key]['lexicalScope']
                    and not fact.get('calledExpression', '').startswith(('self.', 'Self.')))}
                if target_keys:
                    depth = max(len(nodes[target_key].get('lexicalScope', [])) for target_key in target_keys)
                    target_keys = {target_key for target_key in target_keys if len(nodes[target_key].get('lexicalScope', [])) == depth}
                if not fact.get('isMemberRead'): edges[key].update(target_keys & callables)
                targets = [(target_key[0], nodes[target_key]) for target_key in target_keys - callables]
                matches = matching_api_calls(index, targets, dict(fact, path=path, calledExpression=target,
                    receiverExpression=fact['calledExpression']), types=types)
                edges[key].update((target_path, function['start'], function['end']) for target_path, function in matches)
                for target_path, function in matches:
                    bindings = api_argument_bindings(function, fact)
                    if len(bindings) == 1:
                        callback_calls.append((key, (target_path, function['start'], function['end']), fact, bindings[0]))
            for target in callbacks: edges[key].update(by_name.get(target, set()))
            if 'calledExpression' in fact: calls[key].append(dict(fact, path=path))
    parameter_names = {key: {parameter.get('name') for parent, function in nodes.items()
        if parent == key or key in callables and parent[0] == key[0] and parent[1] <= key[1] and key[2] <= parent[2]
        for parameter in function.get('parameters', [])} for key in nodes}
    executed_parameters = {key: {name for name in parameter_names[key]
        if any(call['calledExpression'] == name and not call.get('isMemberRead') for call in calls[key])} for key in nodes}
    changed = True
    while changed:
        changed = False
        for caller, targets in edges.items():
            for target in targets & callables:
                if caller[0] == target[0] and caller[1] <= target[1] and target[2] <= caller[2]:
                    additions = executed_parameters[target] & parameter_names[caller] - executed_parameters[caller]
                    if additions: executed_parameters[caller].update(additions); changed = True
        for caller, callee, call, bindings in callback_calls:
            for argument, parameter in zip(call.get('arguments', []), bindings):
                if parameter.get('name') in executed_parameters[callee] and argument in {
                        item for item in parameter_names[caller]} \
                        and argument not in executed_parameters[caller]:
                    executed_parameters[caller].add(argument); changed = True
    for caller, callee, call, bindings in callback_calls:
        owner = '.'.join(nodes[caller]['scope'])
        for position, parameter in enumerate(bindings):
            if parameter.get('name') not in executed_parameters[callee]: continue
            edges[caller].update((caller[0], start, end) for index, start, end in call.get('closureArguments', [])
                if index == position and (caller[0], start, end) in nodes)
            if position < len(call.get('arguments', [])):
                argument = call['arguments'][position]
                for target in {argument, owner + '.' + argument}: edges[caller].update(by_name.get(target, set()) & callables)
    reached = {(key, 'network') for key in by_name.get('ReleaseNetworkSmokeRunner.run', set())}
    changed = True
    while changed:
        additions = set()
        for key, route in reached:
            targets = edges[key] | {target for target, nominal in implementation_edges.get(key, set())
                if any((creator, route) in reached for creator in constructed_types.get(nominal, set()))}
            for target in targets:
                target_route = 'community-writes' if nodes[target]['scope'][:1] == ['CommunityWriteSmoke'] else route
                if target in stored_callables and (stored_callables[target], target_route) not in reached: continue
                additions.add((target, target_route))
        additions -= reached
        changed = bool(additions)
        reached.update(additions)
    result = {'network': [], 'community-writes': []}
    for key, route in reached:
        result[route].extend(calls[key])
    return result


def smoke_receiver_resolver(index: dict):
    from swift_type_index import receiver_resolver
    return receiver_resolver(index)


def network_capability_findings(index: dict) -> list[str]:
    from pathlib import Path
    from swift_type_index import SwiftTypeIndex
    from validation_manual import MANUAL_DEVICE_CHECKS, MANUAL_SCENARIOS
    from validation_policy import NETWORK_GROUPS
    from network_capability_rules import api_invocations, business_methods, method_signature, matching_api_calls, call_can_execute
    actual = business_methods(index)
    types = SwiftTypeIndex(index)
    receiver_owner = smoke_receiver_resolver(index)
    observed = {'network': set(), 'community-writes': set()}
    edges = {}
    all_functions = {}
    reachable = reachable_smoke_calls(index)
    for owner in actual:
        scope = owner.split('.')[1:]
        all_functions[owner] = [(path, function) for path, facts in index.items()
            for function in facts.get('functionRanges', []) + facts.get('accessorRanges', []) + facts.get('initializers', [])
            if function['scope'] == scope and (Path(path).parts[Path(path).parts.index('Modules') + 1] == owner.split('.')[0]
                if 'Modules' in Path(path).parts else owner.startswith('BIT101-iOS.'))]
    for route, calls in reachable.items():
        for call in calls:
            owner = receiver_owner(call)
            matches = matching_api_calls(index, all_functions.get(owner, []), call, types=types)
            if not matches and not call.get('isMemberRead') and types.resolve(call['path'], call['calledExpression'], call['scope']):
                constructor = dict(call, calledExpression=call['calledExpression'] + '.init')
                constructor_owner = receiver_owner(constructor)
                matches = matching_api_calls(index, all_functions.get(constructor_owner, []), constructor, types=types)
                if matches: owner = constructor_owner
            if len(matches) == 1: observed[route].add((owner, method_signature(matches[0][1])))
    for owner, functions in all_functions.items():
        for path, function in functions:
            key = (owner, method_signature(function))
            edges[key] = set()
            for call in api_invocations(index[path]):
                if not function['start'] <= call['start'] < function['end'] or not call_can_execute(index[path], call): continue
                expression = (call.get('calledExpression') or '').removeprefix('self.')
                if '.' in expression: continue
                matches = matching_api_calls(index, functions, dict(call, path=path), types=types)
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
    for call in reachable['network']:
        if receiver_owner(call) != 'GalleryFeature.GalleryService': continue
        method = call['calledExpression'].rsplit('.', 1)[-1]
        if method in {'fetchRecommendPage', 'fetchBotFeed'}: modes.add('recommend' if method == 'fetchRecommendPage' else 'bot')
        if method == 'fetchFeed' and 'kind' in call.get('argumentLabels', []):
            value = call['arguments'][call['argumentLabels'].index('kind')]
            if value.startswith('.'): modes.add(value[1:])
    for mode in sorted(feed_cases - modes): errors.append(f'话廊分栏需要实际网络探针：{mode}')
    return errors


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
        "远程图片复制与登记阻止并发清理": "MediaDependencyTests/remotePreviewCopyPinsBeforeConcurrentCleanup",
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
    return [f"关键状态转换测试登记需要保留：{behavior} → {test}" for group, contracts in CRITICAL_CONTRACTS.items()
        for behavior, test in contracts.items() if test not in inventories[group]]


def network_capability_self_test() -> None:
    from network_capability_tests import network_capability_self_test as run
    run()


@cache
def test_selectors(group: str) -> dict[str, str]:
    if group in TEST_AREA_SUITES:
        return {test: selector for test, selector in test_selectors("all").items()
                if test.split("/", 1)[0] in TEST_AREA_SUITES[group]}
    directory = ROOT / ("ModuleTests" if group == "modules" else "BIT101-iOSUITests" if group == "ui" else "BIT101-iOSTests")
    sources = {}
    for path in sorted(directory.rglob("*.swift")):
        sources[str(path)] = active_swift_source(path.read_text(), group, path=str(path))
    selectors = {}
    origins = {}
    for path, facts in swift_syntax_index_sources(sources).items():
        functions = {function['start']: function for function in facts['functionRanges']}
        for test in facts['tests']:
            selector = test['value']
            if test.get('isTestingTest'):
                parameters = functions[test['start']]['parameters']
                selector += '(' + ''.join((parameter['label'] or '_') + ':' for parameter in parameters) + ')'
            identity = normalized_test_id(test['value'])
            if identity in origins:
                raise ValueError(f"测试库存需要唯一 Suite/method：{identity}（{origins[identity]} 与 {path}: {selector}）。")
            origins[identity] = f"{path}: {selector}"
            selectors[test['value']] = selector
    return {test: selector for test, selector in selectors.items() if test.split("/", 1)[0] in FORMAL_RUNTIME_SUITES} \
        if group in {"release-runtime", "catalyst-release-runtime"} else selectors


@cache
def test_inventory(group: str) -> set[str]:
    return set(test_selectors(group))
