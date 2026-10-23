"""Declare App test inventories and verify smoke capability coverage."""
from pathlib import Path
from functools import cache, lru_cache
import re
from validation_policy import FORMAL_RUNTIME_SUITES, NETWORK_CAPABILITIES, MANUAL_CAPABILITY_SCENARIOS, manual_capabilities
from validation_compilation import active_swift_source
from validation_provenance import normalized_test_id
from swift_source_index import swift_syntax_index_sources

ROOT = Path(__file__).resolve().parents[1]


def fixture_resource_findings(path: Path, facts: dict) -> list[str]:
    if not any(path.is_relative_to(ROOT / root) for root in ('ModuleTests', 'BIT101-iOSTests', 'BIT101-iOSUITests')):
        return []
    from swift_type_index import SwiftTypeIndex, receiver_resolver
    from swift_source_index import matching_functions
    from network_capability_rules import matching_api_calls
    index = {str(path): facts}
    types, resolve = SwiftTypeIndex(index), receiver_resolver(index)
    def system_name(name, reference):
        return types.terminal_name(str(path), name, reference['scope']).removeprefix('Foundation.').removeprefix('Swift.')
    random_calls = set()
    for call in facts.get('invocations', []):
        expression = call['calledExpression'].removesuffix('.init')
        kind = system_name(expression, call)
        if kind in {'UUID', 'Date'} and (kind == 'UUID' or not call.get('arguments')):
            random_calls.add(call['start'])
        receiver, _, method = expression.rpartition('.')
        if method == 'random' and system_name(receiver, call) in {
                'Int', 'Int8', 'Int16', 'Int32', 'Int64', 'UInt', 'UInt8', 'UInt16', 'UInt32', 'UInt64', 'Float', 'Double', 'Bool'}:
            random_calls.add(call['start'])
        if expression in {'Darwin.arc4random', 'Darwin.arc4random_uniform', 'CoreFoundation.CFAbsoluteTimeGetCurrent'}:
            random_calls.add(call['start'])
    for member in facts.get('members', []):
        receiver, _, name = member['value'].rpartition('.')
        if name == 'now' and system_name(receiver, member) == 'Date' or name in {'globallyUniqueString', 'systemUptime'} \
                and receiver.endswith('.processInfo') and system_name(receiver.removesuffix('.processInfo'), member) == 'ProcessInfo':
            random_calls.add(member['start'])
    if not random_calls: return []
    bindings = facts.get('bindings', [])

    def random_value(bounds, reference, seen=frozenset()):
        if any(bounds[0] <= position < bounds[1] for position in random_calls): return True
        for identifier in facts.get('scopedIdentifiers', []):
            if not identifier.get('isExpressionReference') or not bounds[0] <= identifier['start'] < bounds[1]: continue
            candidates = [binding for binding in bindings if binding.get('bindingName') == identifier['value']
                and binding['start'] < identifier['start'] and binding['start'] not in seen
                and identifier['scope'][:len(binding['scope'])] == binding['scope']
                and identifier['lexicalScope'][:len(binding['lexicalScope'])] == binding['lexicalScope']]
            if not candidates: continue
            binding = max(candidates, key=lambda item: (len(item['scope']), len(item['lexicalScope']), item['start']))
            if random_value((binding['start'], binding['start'] + len(binding['value'].encode())),
                    binding, seen | {binding['start']}): return True
        for call in facts.get('invocations', []):
            if not bounds[0] <= call['start'] < bounds[1]: continue
            receiver, _, name = call['calledExpression'].rpartition('.')
            candidates = matching_functions(facts, name, call) if not receiver else [function
                for function in facts.get('functionRanges', []) if
                '.'.join(types.function_scope(str(path), function['scope'])) == resolve(dict(call, path=str(path)))]
            for _, function in matching_api_calls(index, [(str(path), function) for function in candidates],
                    dict(call, path=str(path)), types=types, conservative=True):
                if function['start'] in seen: continue
                for returned in facts.get('functionReturns', []):
                    if function['bodyStart'] <= returned['start'] < function['end'] and returned['name'] == function['name'] \
                            and random_value((returned['start'], returned['start'] + len(returned['value'].encode())),
                                returned, seen | {function['start']}): return True
        return False

    errors = []
    for call in facts.get('invocations', []):
        method = call['calledExpression'].removesuffix('.init').split('.')[-1]
        labels = {'createDirectory': {'at', 'atPath'}, 'writeData': {'to'},
            'ScoreCacheDiskRepository': {'storageRoot'}, 'UserDefaults': {'suiteName'}, 'URL': {'fileURLWithPath'}}.get(method, set())
        if any(label in labels and random_value(bounds, call)
                for label, bounds in zip(call.get('argumentLabels', []), call.get('argumentRanges', []))):
            line = facts['source'].encode()[:call['start']].count(b'\n') + 1
            errors.append(f'{path.relative_to(ROOT)}:{line}: 磁盘测试资源与偏好域使用固定用途名称')
    return errors


def fixture_resource_self_test() -> None:
    path = ROOT / 'BIT101-iOSTests/Fixture.swift'
    for statement, expected in (
            (r'let root = files.temporaryDirectoryURL.appending(path: "quota-\(UUID().uuidString)"); try files.createDirectory(at: root)', 1),
            (r'let suffix = Foundation.UUID().uuidString; let domain = "suite.\(suffix)"; let alias = domain; _ = UserDefaults(suiteName: alias)', 1),
            (r'let root = URL(fileURLWithPath: "/test/\(UUID().uuidString)")', 1),
            (r'let suffix = Date().timeIntervalSince1970; _ = UserDefaults(suiteName: "suite.\(suffix)")', 1),
            (r'let root = URL(fileURLWithPath: "/test/\(Date.now.timeIntervalSince1970)")', 1),
            (r'let suffix = ProcessInfo.processInfo.globallyUniqueString; let alias = suffix; _ = UserDefaults(suiteName: alias)', 1),
            (r'let suffix = Int.random(in: 1...100); let root = URL(fileURLWithPath: "/test/\(suffix)")', 1),
            (r'let suffix = Swift.Double.random(in: 0...1); _ = UserDefaults(suiteName: "suite.\(suffix)")', 1),
            (r'let suffix = Date(timeIntervalSince1970: 42).timeIntervalSince1970; _ = UserDefaults(suiteName: "suite.\(suffix)")', 0),
            ('struct Date {}; _ = UserDefaults(suiteName: String(describing: Date()))', 0),
            ('typealias Identifier = Foundation.UUID; _ = UserDefaults(suiteName: Identifier().uuidString)', 1),
            (r'typealias Clock = Date; _ = UserDefaults(suiteName: "suite.\(Clock.now.timeIntervalSince1970)")', 1),
            (r'typealias Number = Swift.Int; _ = UserDefaults(suiteName: "suite.\(Number.random(in: 1...100))")', 1),
            ('struct Int { static func random(in range: ClosedRange<Int>) -> String { "fixed" } }; _ = UserDefaults(suiteName: Int.random(in: 1...100))', 0),
            (r'let root = files.temporaryDirectoryURL.appending(path: "quota-\(UUID().uuidString)"); _ = ScoreCacheDiskRepository(files: files, storageRoot: root)', 1),
            ('let identity = UUID(); let domain = "fixed"; _ = UserDefaults(suiteName: domain)', 0),
            (r'let suffix = UUID().uuidString; if enabled { let suffix = "fixed"; _ = UserDefaults(suiteName: "suite.\(suffix)") }', 0),
            ('struct UUID { var uuidString: String { "fixed" } }; _ = UserDefaults(suiteName: UUID().uuidString)', 0),
            ('_ = UserDefaults(suiteName: "UUID().uuidString") // UUID()', 0),
            ('func name() -> String { UUID().uuidString }; _ = UserDefaults(suiteName: name())', 1),
            ('func name() -> String { let value = UUID().uuidString; return value }; let domain = name(); _ = UserDefaults(suiteName: domain)', 1),
            ('func name() -> String { _ = UUID(); return "fixed" }; _ = UserDefaults(suiteName: name())', 0),
            ('func name() -> String { UUID().uuidString }; func alias() -> String { name() }; _ = UserDefaults(suiteName: alias())', 1),
            ('func name() -> String { name() }; _ = UserDefaults(suiteName: name())', 0),
            ('func name(_ value: Int) -> String { UUID().uuidString }; func name(_ value: String) -> String { "fixed" }; _ = UserDefaults(suiteName: name("fixed"))', 0)):
        source = 'import Foundation; func fixture() { ' + statement + '\n}'
        facts = swift_syntax_index_sources({str(path): source})[str(path)]
        assert len(fixture_resource_findings(path, facts)) == expected, statement

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
        "AppDeepLinkRouteTests", "AppLocalDataOwnershipTests", "AppLocalDataResourceTests", "AppSettingsPersistenceBoundaryTests",
        "AppUpdateCheckerTests", "CampusMapLocationTests", "ComposerDraftStorageTests",
        "ErrorReportAndSchedulePolicyTests", "ErrorReportURLRedactionTests", "ExperimentalPreferenceCloudSyncTests", "ExtendedInfrastructureTests",
        "ExternalScheduleInfrastructureTests", "CommunityRecoveryCompositionTests", "FeatureCompositionTests", "GalleryContentFilterTests",
        "GalleryRecommendationPrefetchTests", "ICloudSmokeEvidenceTests", "ImageCacheDiskQuotaTests",
        "InfrastructureTests", "KeyboardAccessoryOwnershipTests", "MediaAvailabilityTests", "MediaDependencyTests", "MediaPresentationTests", "NetworkClientTests", "NetworkSmokeSMSPromptTests",
        "PaperCommentPagingTests", "PaperContentRecoveryTests", "NetworkEvidenceProjectionTests", "NetworkSmokeCoverageTests", "NetworkSmokeExternalContentTests",
        "NetworkSmokeRegressionContractTests", "NetworkBusinessDiagnosticsTests", "TrustedTranscriptRecoveryTests",
        "MaintenancePerformanceTests",
        "PersistentBackupPreparationTests", "PreferenceCloudPayloadTests", "PreferenceMergeTests", "ReleaseNetworkSmokeLifecycleTests",
        "SchoolCookieIsolationTests", "ScoreCacheDiskRepositoryTests", "ScorePresentationTests",
        "SettingsDependencyOwnershipTests", "SuggestionDependencyTests", "UIInventoryIdentityTests",
    },
    "login": {"CommunitySessionRecoveryTests", "ExtendedLoginTests", "LoginBootstrapTests", "LoginLogicTests", "LoginStorageTests", "NativeLoginTests", "SchoolCookieIsolationTests"},
    "extensions": {"AppExternalDisplayTests", "ExternalScheduleInfrastructureTests", "ExternalScheduleWatchStatusTests"},
}


def inventory_findings(suites: set[str]) -> list[str]:
    registered = set().union(*TEST_AREA_SUITES.values())
    errors = [f"行为测试 suite 需要领域归属：{suite}" for suite in sorted(suites - registered)] \
        + [f"行为测试领域归属需要清理：{suite}" for suite in sorted(registered - suites)]
    for group in ('release-runtime', 'catalyst-release-runtime'):
        raw = set(raw_test_selectors(group))
        regular = set(raw_test_selectors('catalyst' if group == 'catalyst-release-runtime' else 'all'))
        errors.extend(formal_inventory_findings(raw, regular, group))
    return errors


def formal_inventory_findings(raw: set[str], regular: set[str], group: str) -> list[str]:
    raw_suites = {test.split('/', 1)[0] for test in raw}
    missing = {test for test in raw - regular if test.split('/', 1)[0] not in FORMAL_RUNTIME_SUITES}
    return [f"正式运行时测试需要登记：{group} · {test}" for test in sorted(missing)] \
        + [f"正式运行时 suite 需要清理：{group} · {suite}" for suite in sorted(FORMAL_RUNTIME_SUITES - raw_suites)]


def formal_inventory_self_test() -> None:
    source = """import Testing
struct ExistingRegularTests { @Test func existing() {} }
#if !DEBUG && !BIT101_AUTOMATED_TESTING
struct NewProductionTests { @Test func newProductionContract() {} }
extension ExistingRegularTests { @Test func productionOnly() {} }
#endif
"""
    path = str(ROOT / 'BIT101-iOSTests/ReleaseRuntimeContractTests.swift')
    def tests(group):
        facts = swift_syntax_index_sources({path: active_swift_source(source, group, path=path)})
        return {test['value'] for test in facts[path]['tests']}
    raw, regular = tests('release-runtime'), tests('all')
    assert 'NewProductionTests/newProductionContract' in raw - regular
    assert any('NewProductionTests' in row for row in formal_inventory_findings(raw, regular, 'release-runtime'))
    assert any('ExistingRegularTests/productionOnly' in row for row in formal_inventory_findings(raw, regular, 'release-runtime'))
    assert not any('ExistingRegularTests/existing' in row for row in formal_inventory_findings(raw, regular, 'release-runtime'))
    original = ((path, source),)
    facts = indexed_test_sources(original)
    assert indexed_test_sources(original) is facts
    updated = indexed_test_sources(((path, source + '\n@Test func addedContract() {}'),))
    assert {test['value'] for test in updated[path]['tests']} - {test['value'] for test in facts[path]['tests']} == {'addedContract'}



def reachable_smoke_calls(index: dict) -> dict[str, list[dict]]:
    from validation_compilation import source_platforms
    platforms = {platform for path, facts in index.items()
        if any(function['scope'] == ['ReleaseNetworkSmokeRunner'] and function['name'] == 'run'
            for function in facts.get('functionRanges', [])) for platform in source_platforms(path)}
    platforms &= {'iOS'}
    result, seen = {'network': [], 'community-writes': []}, {'network': set(), 'community-writes': set()}
    for platform in sorted(platforms):
        for root_route in ('network', 'community-writes'):
            for route, calls in platform_smoke_calls(index, platform, root_route).items():
                for call in calls:
                    key = (call['path'], call.get('start'), call.get('end'), call['calledExpression'])
                    if key in seen[route]: continue
                    seen[route].add(key)
                    result[route].append(call)
    return result


def platform_smoke_calls(index: dict, platform: str, root_route: str = "network") -> dict[str, list[dict]]:
    from network_capability_rules import branch_value, execution_index
    bound_scope = "all" if root_route == "network" else "communityWrites"
    index = execution_index(index)
    from pathlib import Path
    import re
    from validation_compilation import source_platforms
    from network_capability_rules import api_argument_bindings, api_invocations, call_can_execute as evaluate_call, callback_body_ranges, executed_callback_positions, matching_api_calls, stored_callback_bindings
    from swift_type_index import SwiftTypeIndex, compilation_unit, receiver_resolver
    types, resolve_receiver = SwiftTypeIndex(index), receiver_resolver(index)
    execution_cache = {}
    def call_can_execute(facts, call):
        identity = (id(facts), id(call))
        if identity not in execution_cache:
            execution_cache[identity] = (facts, call, evaluate_call(facts, call))
        return execution_cache[identity][2]
    units = {compilation_unit(path) for path, facts in index.items()
        if any(function['scope'] == ['ReleaseNetworkSmokeRunner'] and function['name'] == 'run'
            for function in facts.get('functionRanges', []))}
    files = {path for path in index if platform in source_platforms(path)
        and (compilation_unit(path) in units or 'Modules' in Path(path).parts)}
    nodes, by_name, active_sources, callables, stored_callables = {}, {}, {}, set(), {}
    for path, facts in index.items():
        if path not in files: continue
        active = active_swift_source(facts['source'], 'network', platform=platform, path=path).encode() if 'source' in facts else None
        active_sources[path] = active
        closures = facts.get('callableRanges', []) + facts.get('inlineClosureRanges', [])
        for function in facts.get('functionRanges', []) + facts.get('accessorRanges', []) + closures + [
                node for node in facts.get('initializers', []) if node.get('isExplicitInitializer')]:
            if active is not None and active[function['start']:function['start'] + 1] in {b' ', b'\n', b'\r'}: continue
            key = (path, function['start'], function['end'])
            nodes[key] = function
            if function in closures: callables.add(key)
            name = '.'.join([*function['scope'], function['name']])
            by_name.setdefault(name, set()).add(key)
            by_name.setdefault(compilation_unit(path) + '.' + name, set()).add(key)
            by_name.setdefault('.'.join([*types.function_scope(path, function['scope']), function['name']]), set()).add(key)
    for (owner, name), bindings in stored_callback_bindings(index, types).items():
        for path, closure, call in bindings:
            key = (path, closure['start'], closure['end'])
            if key not in nodes: continue
            parents = [parent for parent in nodes if parent[0] == path and parent[1] <= call['start'] < parent[2]]
            if not parents: continue
            stored_callables.setdefault(key, []).append((min(parents, key=lambda item: item[2] - item[1]), call))
            by_name.setdefault(owner.split('.', 1)[1] + '.' + name, set()).add(key)
            by_name.setdefault(owner + '.' + name, set()).add(key)
    edges = {key: set() for key in nodes}
    edge_calls = {}
    def connect(caller, targets, call=None):
        for target in targets:
            edges[caller].add(target)
            evidence = edge_calls.setdefault((caller, target), [])
            if call not in evidence: evidence.append(call)
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
                connect(key, by_name.get(target, set()))
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
                if nominal: constructed_types.setdefault(nominal, []).append((key, fact))
            owner = '.'.join(nodes[key]['scope'])
            candidates = {expression, owner + '.' + expression.removeprefix('Self.')}
            constructor = types.resolve(path, expression.removesuffix('.init'), fact['scope'])
            if constructor: candidates.add('.'.join([constructor[0], *constructor[1], 'init']))
            callbacks = set()
            if expression.startswith('dependencies.'):
                candidates.add('ReleaseNetworkSmokeDependencies.' + expression.split('.', 1)[1])
            if fact.get('receiverCall'):
                candidates.add(fact['receiverCall'] + '.' + expression.rsplit('.', 1)[-1])
            if resolved := resolve_receiver(dict(fact, path=path)):
                candidates.add(resolved + '.' + expression.rsplit('.', 1)[-1])
                method = expression.rsplit('.', 1)[-1]
                concrete = {target for target in implementations.get(resolved, set())
                    if '.'.join([target[0], *target[1], method]) in by_name}
                for target in concrete:
                    name = '.'.join([target[0], *target[1], method])
                    matches = matching_api_calls(index, [(node[0], nodes[node]) for node in by_name[name]], dict(fact, path=path), types=types)
                    for source_path, function in matches:
                        implementation_edges.setdefault(key, set()).add(((source_path, function['start'], function['end']), target))
            project_call = False
            for target in candidates:
                target_keys = {target_key for target_key in by_name.get(target, set())
                    if (compilation_unit(target_key[0]) == compilation_unit(path) or target.split('.', 1)[0] in types.module_names)
                    and (target_key in stored_callables or not nodes[target_key].get('lexicalScope') or target_key[0] == path
                    and fact.get('lexicalScope', [])[:len(nodes[target_key]['lexicalScope'])] == nodes[target_key]['lexicalScope']
                    and not fact.get('calledExpression', '').startswith(('self.', 'Self.')))}
                if target_keys:
                    depth = max(len(nodes[target_key].get('lexicalScope', [])) for target_key in target_keys)
                    target_keys = {target_key for target_key in target_keys if len(nodes[target_key].get('lexicalScope', [])) == depth}
                if not fact.get('isMemberRead'): connect(key, target_keys & callables, fact)
                targets = [(target_key[0], nodes[target_key]) for target_key in target_keys - callables]
                matches = matching_api_calls(index, targets, dict(fact, path=path, calledExpression=target,
                    receiverExpression=fact['calledExpression']), types=types)
                project_call = project_call or bool(matches)
                connect(key, ((target_path, function['start'], function['end']) for target_path, function in matches), fact)
                for target_path, function in matches:
                    bindings = api_argument_bindings(function, fact)
                    if len(bindings) == 1:
                        callback_calls.append((key, (target_path, function['start'], function['end']), fact, bindings[0]))
            callback_positions = executed_callback_positions(fact, project_call=project_call)
            if expression in {'runInParallel', 'probe', 'NetworkSmokePaging.batch', 'NetworkSmokePaging.arrayPage', 'NetworkSmokePaging.messages'}:
                callback_positions.update(range(len(fact.get('arguments', []))))
                callback_positions.update(position for position, _, _ in fact.get('closureArguments', []))
            for position, argument in enumerate(fact.get('arguments', [])):
                if position in callback_positions: callbacks.update({argument, owner + '.' + argument})
            references = set()
            connect(key, ((path, start, end) for start, end in callback_body_ranges(facts, fact, callback_positions, references=references)
                if (path, start, end) in nodes), fact)
            for target in callbacks: connect(key, by_name.get(target, set()) - callables, fact)
            if 'calledExpression' in fact: calls[key].append(dict(fact, path=path, executedCallbackReferences=references))
    parameter_names = {key: {parameter.get('name') for parent in
        (nodes_by_path[key[0]] if key in callables else (key,))
        if parent == key or key in callables and parent[0] == key[0] and parent[1] <= key[1] and key[2] <= parent[2]
        for parameter in nodes[parent].get('parameters', [])} for key in nodes}
    executed_parameters = {key: {name for name in parameter_names[key]
        if any(call['calledExpression'] == name and not call.get('isMemberRead') or
            name in call.get('executedCallbackReferences', set()) for call in calls[key])} for key in nodes}
    callback_guards = {}
    changed = True
    while changed:
        changed = False
        for caller, targets in edges.items():
            for target in targets & callables:
                if caller[0] == target[0] and caller[1] <= target[1] and target[2] <= caller[2]:
                    additions = executed_parameters[target] & parameter_names[caller] - executed_parameters[caller]
                    if additions: executed_parameters[caller].update(additions); changed = True
        for caller, callee, call, bindings in callback_calls:
            positions = {position for position, parameter in enumerate(bindings)
                if parameter.get('name') in executed_parameters[callee]}
            references = set()
            callback_body_ranges(index[caller[0]], call, positions, references=references)
            additions = references & parameter_names[caller] - executed_parameters[caller]
            if additions: executed_parameters[caller].update(additions); changed = True
        for caller, callee, call, bindings in callback_calls:
            for position, parameter in enumerate(bindings):
                if parameter.get('name') not in executed_parameters[callee]: continue
                targets = {(caller[0], start, end) for start, end in callback_body_ranges(index[caller[0]], call, {position})
                    if (caller[0], start, end) in nodes}
                for target in targets:
                    guard = (callee, parameter['name'], call)
                    guards = callback_guards.setdefault((caller, target), [])
                    if guard not in guards: guards.append(guard)
                additions = targets - edges[caller]
                if additions: connect(caller, additions, call); changed = True
    @cache
    def contextual_facts(key, context):
        return dict(index[key[0]], smokeScopeBindings={(start, name): value
            for path, start, name, value in context if path == key[0]})
    context_cache = {}
    def target_context(caller, target, context, call):
        identity = (caller, target, context, id(call))
        if identity not in context_cache:
            context_cache[identity] = (call, evaluate_context(caller, target, context, call))
        return context_cache[identity][1]
    def evaluate_context(caller, target, context, call):
        retained = {entry for entry in context if entry[0] == target[0]
            and entry[1] <= target[1] and any(function['start'] == entry[1] and target[2] <= function['end']
                for function in index[target[0]].get('functionRanges', []))}
        function = nodes[target]
        bindings = api_argument_bindings(function, call) if call is not None and target not in callables else []
        for parameter in function.get('parameters', []):
            kind = types.terminal_name(target[0], parameter.get('type', ''), function['scope']).rsplit('.', 1)[-1]
            if not re.fullmatch(r'NetworkSmokeScope|Bool|String|U?Int(?:8|16|32|64)?|Double', kind): continue
            position = next((position for position, bound in enumerate(bindings[0])
                if bound.get('name') == parameter.get('name')), None) if len(bindings) == 1 else None
            arguments = call.get('arguments', []) if call else []
            value = branch_value(contextual_facts(caller, context), call, arguments[position]) \
                if position is not None and position < len(arguments) else None
            if position is None and (bounds := parameter.get('defaultExpressionRange')):
                facts = contextual_facts(target, context)
                expression = facts['source'].encode()[bounds[0]:bounds[1]].decode()
                value = branch_value(facts, dict(function, start=bounds[0]), expression)
            retained = {entry for entry in retained if entry[:3] != (target[0], target[1], parameter['name'])}
            if type(value) in {bool, int, float, str}:
                retained.add((target[0], target[1], parameter['name'], value))
        return tuple(sorted(retained))
    callback_calls_by_caller = {}
    for row in callback_calls: callback_calls_by_caller.setdefault(row[0], []).append(row)
    @cache
    def parameter_executes(key, context, name):
        return parameter_reachable(key, context, name, set())
    def parameter_reachable(key, context, name, seen):
        identity = (key, context, name)
        if identity in seen: return False
        seen.add(identity)
        facts = contextual_facts(key, context)
        if any(call_can_execute(facts, call) and (call['calledExpression'] == name and not call.get('isMemberRead')
            or name in call.get('executedCallbackReferences', set())) for call in calls[key]): return True
        for target in edges[key] & callables:
            if target[0] != key[0] or not key[1] <= target[1] < target[2] <= key[2]: continue
            if any((call is None or call_can_execute(facts, call)) and
                parameter_reachable(target, target_context(key, target, context, call), name, seen)
                for call in edge_calls.get((key, target), [])): return True
        for caller, callee, call, bindings in callback_calls_by_caller.get(key, []):
            if not call_can_execute(facts, call): continue
            for position, parameter in enumerate(bindings):
                references = set()
                callback_body_ranges(index[key[0]], call, {position}, references=references)
                if name in references and parameter_reachable(callee,
                    target_context(key, callee, context, call), parameter.get('name'), seen): return True
        return False
    reached = {(key, root_route, ((key[0], key[1], 'scope', bound_scope),))
        for key in by_name.get('ReleaseNetworkSmokeRunner.run', set())}
    changed = True
    while changed:
        additions = set()
        for key, route, context in reached:
            facts = contextual_facts(key, context)
            targets = edges[key] | {target for target, nominal in implementation_edges.get(key, set())
                if any(creator == reached_key and route == reached_route
                    and call_can_execute(contextual_facts(creator, reached_context), call)
                    for creator, call in constructed_types.get(nominal, [])
                    for reached_key, reached_route, reached_context in reached)}
            for target in targets:
                target_route = 'community-writes' if nodes[target]['scope'][:1] == ['CommunityWriteSmoke'] else route
                if target in stored_callables and not any(parent == creator and parent_route == target_route
                    and call_can_execute(contextual_facts(parent, parent_context), constructor)
                    for creator, constructor in stored_callables[target]
                    for parent, parent_route, parent_context in reached): continue
                evidence = edge_calls.get((key, target), [call for call in calls[key]
                    if call.get('calledExpression', '').rsplit('.', 1)[-1] == nodes[target]['name']])
                for call in evidence:
                    if call is not None and not call_can_execute(facts, call): continue
                    guards = [guard for guard in callback_guards.get((key, target), []) if guard[2] == call]
                    if guards and not any(parameter_executes(callee, target_context(key, callee, context, call), name)
                        for callee, name, _ in guards): continue
                    additions.add((target, target_route, target_context(key, target, context, call)))
        additions -= reached
        changed = bool(additions)
        reached.update(additions)
    result = {'network': [], 'community-writes': []}
    for key, route, context in reached:
        result[route].extend(call for call in calls[key] if call_can_execute(contextual_facts(key, context), call))
    return result


def smoke_receiver_resolver(index: dict):
    from swift_type_index import receiver_resolver
    return receiver_resolver(index)


def network_capability_findings(index: dict) -> list[str]:
    from pathlib import Path
    from swift_type_index import SwiftTypeIndex
    from validation_manual import MANUAL_DEVICE_CHECKS, MANUAL_SCENARIOS
    from network_capability_rules import api_invocations, business_methods, method_signature, matching_api_calls, call_can_execute, execution_index
    index = execution_index(index)
    actual = business_methods(index)
    types = SwiftTypeIndex(index)
    receiver_owner = smoke_receiver_resolver(index)
    reachable_capabilities = {'network': set(), 'community-writes': set()}
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
            if len(matches) == 1: reachable_capabilities[route].add((owner, method_signature(matches[0][1])))
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
    for calls in reachable_capabilities.values():
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
            if route not in reachable_capabilities.keys() | MANUAL_DEVICE_CHECKS:
                errors.append(f'网络能力需要有效验收入口：{name}.{signature} → {route}')
            elif route in reachable_capabilities and (name, signature) not in reachable_capabilities[route]:
                errors.append(f'网络能力需要对应入口中的静态可达服务调用：{name}.{signature} → {route}')
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
    for mode in sorted(feed_cases - modes): errors.append(f'话廊分栏需要静态网络探针入口：{mode}')
    return errors


CRITICAL_CONTRACTS = {
    "all": {
        "已确认评论在刷新故障中持续展示": "GalleryRecommendationPrefetchTests/confirmedCommentsAppearThroughTheFollowingRefreshFailure",
        "失败预取沿恢复后的网络重新请求": "GalleryRecommendationPrefetchTests/recoveredNetworkReplacesAFailedBackgroundPrefetch",
        "文章读取直接保留业务请求": "FeatureCompositionTests/authenticatedPaperReadsKeepTheirBusinessRoutes",
        "成绩单补页持续展示已有页面": "TrustedTranscriptRecoveryTests/retriesKeepVisiblePagesAndLoadTheMissingPageFromTheSameReport",
        "成绩单来源替换保留完整结果": "TrustedTranscriptRecoveryTests/aPartialReplacementKeepsTheFullerCoherentReport",
        "缓存写入故障维持静态与动画图片": "MediaAvailabilityTests/cacheWriteFailureKeepsDownloadedImagesAvailable",
        "媒体内存压力释放临时内容": "MediaAvailabilityTests/memoryPressureReleasesTransientEncodedImages",
        "成绩业务失败回写请求诊断": "NetworkBusinessDiagnosticsTests/scoreValidationAmendsOneRequestAndKeepsItsFailureAfterImageTraffic",
        "登录解析诊断保留字段路径": "NetworkBusinessDiagnosticsTests/loginParsingFailureKeepsItsFieldPathInTheRequestDiagnostic",
        "账号切换后恢复请求维持归属": "LoginStorageTests/schoolRestoreKeepsItsCapturedAccountAcrossBothNetworkWaits",
        "后台验证维持新会话": "LoginStorageTests/backgroundCookieValidationKeepsTheNewlyRenewedSameAccountSession",
        "凭据写入原子发布": "LoginStorageTests/credentialWriteFailurePreservesThePublishedIdentity",
        "学校密码共享输入按等待者取消": "LoginLogicTests/schoolPasswordWaitersCancelIndependently",
        "文章评论独立展示已完成结果": "PaperCommentPagingTests/commentsAppearWhilePaperDetailsArePending",
        "帖子评论独立展示已完成结果": "GalleryRecommendationPrefetchTests/completedCommentsAppearWhilePosterDetailsArePending",
        "网络提示期间请求持续可用": "NetworkClientTests/networkWarningKeepsTransportAvailable",
        "响应解码保留字段路径": "NetworkClientTests/schoolResponseDecodingRetainsItsFieldPathAndUserMessage",
        "网络诊断保留故障与近期上下文": "ErrorReportAndSchedulePolicyTests/testDiagnosticsRetainFailuresAndAuthenticationContextThroughSuccessfulTraffic",
        "登录取消收敛": "ExtendedLoginTests/cancelledLogin",
        "分页时钟与内存测量": "MaintenancePerformanceTests/testCommunityPaginationPerformance",
        "图片解码时钟与内存测量": "MaintenancePerformanceTests/testStillImageDecodingPerformance",
        "离线宿主资源与网络隔离": "InfrastructureTests/behaviorHostIsolation",
        "共享预览存储维持活动文件": "MediaDependencyTests/sharedPreviewStorageRetainsFilesAcrossEnvironmentCleanupAndClosing",
        "预览创建与登记阻止并发清理": "MediaDependencyTests/previewCreationAndRegistrationExcludeConcurrentCleanup",
        "远程图片复制与登记阻止并发清理": "MediaDependencyTests/remotePreviewCopyPinsBeforeConcurrentCleanup",
        "账号设置独立恢复": "AppSettingsPersistenceBoundaryTests/corruptSettingsRetainTheirSourceThroughLoadEditsAndAccountReload",
        "建议提交与草稿清理解耦": "SuggestionDependencyTests/confirmedSuggestionCompletesWhileCleanupFails",
        "建议暂存受阻期间持续受理": "SuggestionDependencyTests/suggestionPersistenceFailureKeepsDeliveryAvailableAndPreservesTheDraft",
    },
    "modules": {
        "云端冲突决策写入基线": "ScheduleSyncTests/keepingLocalConflictPersistsTheNewBaselineThroughTheProductionRepository",
        "云端冲突选择保留双端独立记录": "ScheduleSyncTests/conflictChoicesPreserveIndependentRecordsThroughTheProductionRepository",
        "恢复快照等待本机确认后同步": "ScheduleSyncTests/recoveredLocalSnapshotsWaitForLocalConfirmationBeforeCloudActivity",
        "损坏日程根结构保留原文": "SchedulePersistenceTests/unrecognizedCacheRootsPreserveTheirBytesAndRejectOverwrites",
        "字段恢复保留学校数据与同步选择": "ScheduleRecoveryTests/damagedFieldsKeepSchoolSchedulesAndCloudConsentUntilRecoveryConfirmation",
        "云端写入期间编辑保留待同步状态": "ScheduleSyncTests/localEditsDuringCloudSaveKeepTheirDirtyStateAndReceiveTheBaseline",
        "云端读取遵循账号代际": "ScheduleSyncTests/delayedRemoteReadHonorsTheAccountGenerationAcrossRoundTripSwitches",
        "云端上传失败支持恢复": "ScheduleSyncTests/mergedChangesStayPendingOnDiskAfterUploadFailureAndRetrySuccessfully",
        "成绩认证各阶段维持账号归属": "ScoreInfrastructureBoundaryTests/eachScoreAndTranscriptStageRejectsAnAccountOrGenerationChange",
        "成绩云端比较完整快照": "ScoreInfrastructureBoundaryTests/cloudApplyComparesTheCompleteLocalSnapshotInsideTheRepository",
        "成绩缓存受阻期间持续提供在线与页面恢复": "ScoreFeatureTests/unreadableCacheKeepsOnlineScoresVisible",
        "取消详细成绩刷新保留完整快照": "ScoreFeatureTests/cancelledDetailsKeepThePriorCompleteSnapshotVisible",
        "文章预取保留离线读取能力": "ServiceContractTests/prefetchedPaperBodyStaysReadableThroughOfflineListRefresh",
        "日程存储受阻期间保留编辑并恢复保存": "ScheduleRepositoryReconciliationTests/inaccessibleStorageKeepsVisibleEditsAndResumesSaving",
        "消息正文独立于未读摘要恢复": "CommunityDependencyBoundaryTests/failedUnreadSummariesKeepReadStateAndRecoverBeforeAcknowledgingMessages",
        "消息首屏独立于挂起的未读摘要": "GalleryMessageAvailabilityTests/historyAppearsWhileInitialAndRetriedUnreadSummariesArePending",
        "课程评论独立展示已完成结果": "CourseDetailTests/commentsAppearWhileCourseDetailsArePending",
        "草稿图片局部恢复": "ComposerRecoveryTests/missingImageKeepsTheTextAndOtherImagesUntilAnExplicitSave",
        "发帖成功与草稿清理解耦": "ComposerLifecycleTests/confirmedPublicationCompletesWhileCleanupFails",
        "日程记录局部恢复与原文保留": "ScheduleRecoveryTests/damagedRecordsKeepTheirValidNeighborsAndOriginalBytes",
    },
}


def critical_findings(inventories: dict[str, set[str]]) -> list[str]:
    return [f"关键状态转换测试登记需要保留：{behavior} → {test}" for group, contracts in CRITICAL_CONTRACTS.items()
        for behavior, test in contracts.items() if test not in inventories[group]]


def smoke_scalar_self_test() -> None:
    for kind, condition, operation, expected in (
        ('Bool = false', 'value', 'service.load(value: false)', False),
        ('Bool = false', 'value', 'service.load(value: true)', True),
        ('Bool = false', 'value', 'service.load()', False),
        ('Bool = true', 'value', 'service.load()', True),
        ('Bool', 'value', 'let enabled = false; service.load(value: enabled)', False),
        ('Bool', 'value', 'service.forward(false)', False),
        ('Bool', 'value', 'service.forward(true)', True),
        ('Int', 'value > 0', 'service.load(value: 0)', False),
        ('Int', 'value > 0', 'service.load(value: 1)', True),
        ('String', 'value == "online"', 'service.load(value: "offline")', False),
        ('String', 'value == "online"', 'service.load(value: "online")', True),
        ('Int', 'authorization != nil, value > 0, [500, 502].contains(status)', 'service.load(value: 0)', False),
        ('Int', 'authorization != nil, value > 0, [500, 502].contains(status)', 'service.load(value: 1)', True),
        ('Bool', 'let decoded = decode("a,b"), value', 'service.load(value: false)', False),
        ('Bool', 'ready(flag: true, fallback: false), value', 'service.load(value: false)', False),
    ):
        parameter_type = kind.split(' = ')[0]
        sources = {
            'ReleaseNetworkSmoke.swift': 'import Example; struct ReleaseNetworkSmokeRunner { let service: CourseService; func run() async throws { ' + operation.replace('service.', 'try await service.') + ' } }',
            'Modules/Example/Sources/Service.swift': 'import Foundation; public struct CourseService { public func load(value: ' + kind + ') async throws { if ' + condition + ' { try await fetch() } }; public func forward(_ value: ' + parameter_type + ') async throws { try await load(value: value) }; public func fetch() async throws { _ = try await URLSession.shared.data(from: url) } }',
        }
        calls = reachable_smoke_calls(swift_syntax_index_sources(sources))['network']
        assert any(call['calledExpression'] == 'URLSession.shared.data' for call in calls) == expected, (kind, operation)
    import network_capability_rules as rules
    original_value = rules.branch_value
    evaluations = 0
    def bounded_value(*arguments):
        nonlocal evaluations
        evaluations += 1
        assert evaluations <= 50, '有界重试的上下文需要在零次剩余重试时停止'
        return original_value(*arguments)
    sources = {
        'ReleaseNetworkSmoke.swift': 'import Example; struct ReleaseNetworkSmokeRunner { let service: CourseService; func run() { service.load() } }',
        'Modules/Example/Sources/Service.swift': '''import Foundation
            public struct CourseService {
                public func load(remaining: Int = 2) {
                    if authorization != nil, remaining > 0, [500, 502].contains(status) { load(remaining: remaining - 1) }
                    _ = URLSession.shared.data(from: url)
                }
            }''',
    }
    rules.branch_value = bounded_value
    try:
        calls = platform_smoke_calls(swift_syntax_index_sources(sources), 'iOS')['network']
        assert sum(call['calledExpression'] == 'URLSession.shared.data' and not call.get('isMemberRead') for call in calls) == 3
    finally: rules.branch_value = original_value


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
    positive = swift_syntax_index_sources({path: source.replace("scope == .communityWrites || scope == .communityCleanup", "scope == .all")})
    assert any(call["calledExpression"] == "service.fetch" for call in reachable_smoke_calls(positive)["network"])
    helper = """enum NetworkSmokeScope { case all, communityWrites, communityCleanup }
class ReleaseNetworkSmokeRunner {
 func run(scope: NetworkSmokeScope) { CALL }
 func helper(mode: NetworkSmokeScope) { if mode == .communityWrites { service.fetch() } }
}
"""
    for call, expected in (
            ('helper(mode: .communityWrites)', True), ('helper(mode: scope)', False),
            ('helper(mode: .all)', False), ('helper(mode: .all); helper(mode: .communityWrites)', True),
            ('let forwarded: NetworkSmokeScope = .communityWrites; helper(mode: forwarded)', True),
            ('if scope == .communityWrites { helper(mode: .communityWrites) }', False)):
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: helper.replace('CALL', call)}))
        assert any(item['calledExpression'] == 'service.fetch' for item in calls['network']) == expected, call
    for condition, expected in (('scope == .communityWrites', True), ('scope == .all', False)):
        same_name = helper.replace('mode', 'scope').replace('scope == .communityWrites', condition)
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: same_name.replace('CALL', 'helper(scope: .communityWrites)')}))
        assert any(item['calledExpression'] == 'service.fetch' for item in calls['network']) == expected, condition
    callback = helper.replace('func helper(mode: NetworkSmokeScope)',
        'func helper(mode: NetworkSmokeScope, action: () -> Void)').replace('service.fetch()', 'action()')
    for value, expected in (('.all', False), ('.communityWrites', True), ('scope', False)):
        call = 'helper(mode: ' + value + ', action: { service.fetch() })'
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: callback.replace('CALL', call)}))['network']
        assert any(item['calledExpression'] == 'service.fetch' for item in calls) == expected, value
        forwarded = callback.replace('CALL',
            'forward(mode: ' + value + ', action: { service.fetch() })').replace('\n}',
            '\n func forward(mode: NetworkSmokeScope, action: () -> Void) { helper(mode: mode, action: action) }\n}')
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: forwarded}))['network']
        assert any(item['calledExpression'] == 'service.fetch' for item in calls) == expected, value
    protocol_source = """protocol Servicing { func fetch() }
struct Service: Servicing { func fetch() { client.read() } }
struct Alternative: Servicing { func fetch() { client.alternativeRead() } }
class ReleaseNetworkSmokeRunner {
 var alternative = false
 func makeService() -> any Servicing { if alternative { return Alternative() }; return Service() }
 func run() { let service = makeService(); service.fetch() }
}
"""
    calls = reachable_smoke_calls(swift_syntax_index_sources({path: protocol_source}))['network']
    assert {'client.read', 'client.alternativeRead'} <= {call['calledExpression'] for call in calls}
    dormant = protocol_source.replace('if alternative { return Alternative() };', '')
    calls = reachable_smoke_calls(swift_syntax_index_sources({path: dormant}))['network']
    assert 'client.alternativeRead' not in {call['calledExpression'] for call in calls}
    from network_capability_rules import business_methods
    observer_path = str(ROOT / "Modules/CourseFeature/Sources/Observer.swift")
    for function in ('CFSocketCreate', 'CFSocketCreateWithNative', 'CFSocketCreateWithSocketSignature',
            'CFSocketCreateConnectedToSocketSignature', 'CFSocketSetAddress', 'CFSocketConnectToAddress', 'CFSocketSendData',
            'CFStreamCreatePairWithSocket', 'CFStreamCreatePairWithSocketToHost', 'CFStreamCreatePairWithPeerSocketSignature',
            'CFStreamCreatePairWithSocketToCFHost', 'CFStreamCreatePairWithSocketToNetService'):
        for qualification in ('', 'CoreFoundation.', 'CFNetwork.'):
            source = 'import CoreFoundation; public struct Service { public func fetch() { ' + qualification + function + '() } }'
            assert 'CourseFeature.Service' in business_methods(swift_syntax_index_sources({observer_path: source})), qualification + function
        shadow = 'func ' + function + '() {}; public struct Service { public func fetch() { ' + function + '() } }'
        assert not business_methods(swift_syntax_index_sources({observer_path: shadow})), function
    for function in ('CFSocketGetTypeID', 'CFReadStreamGetTypeID', 'CFReadStreamCreateWithFile', 'CFReadStreamOpen'):
        source = 'import CoreFoundation; public struct Service { public func fetch() { ' + function + '() } }'
        assert not business_methods(swift_syntax_index_sources({observer_path: source})), function
    observer = """import Foundation
import TransportCore
public final class Observer {
 private let httpClient: HTTPClient
 public func begin() {
  _ = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { _ in
   Task { _ = try await self.httpClient.send(URLRequest(url: URL(string: "https://example.invalid")!)) }
  }
 }
}
"""
    assert 'CourseFeature.Observer' in business_methods(swift_syntax_index_sources({observer_path: observer}))
    dormant = observer.replace('public func begin() {', 'public func begin() {}\n private func dormant() {')
    assert not business_methods(swift_syntax_index_sources({observer_path: dormant}))
    stored = observer.replace('_ = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { _ in',
        'let callback: @Sendable (Notification) -> Void = { _ in').replace('  }\n }',
        '  }\n  _ = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil, using: callback)\n }')
    assert 'CourseFeature.Observer' in business_methods(swift_syntax_index_sources({observer_path: stored}))
    for body, smoke_executed in (
            ('Task<Void, Never> { BODY }', True), ('_Concurrency.Task { BODY }', True),
            ('_Concurrency.Task<Void, Never>.init { BODY }', True),
            ('Task<Void, Never>.detached { BODY }', True),
            ('let operation = { BODY }; Task<Void, Never>(operation: operation)', True),
            ('let stream = AsyncStream<Int> { _ in BODY }', True),
            ('let stream = _Concurrency.AsyncThrowingStream<Int, Error> { _ in BODY }', True),
            ('let stream = AsyncStream<Int>(unfolding: { BODY; return nil })', False),
            ('let stream = AsyncThrowingStream<Int, Error>(unfolding: { BODY; return nil })', False),
            ('let stream = AsyncStream<Int>(unfolding: { nil }, onCancel: { BODY })', False),
            ('OperationQueue.main.addBarrierBlock { BODY }', True),
            ('DispatchQueue.concurrentPerform(iterations: 1) { _ in BODY }', True),
            ('await withTaskCancellationHandler(operation: {}, onCancel: { BODY })', False),
            ('let cancelled = { BODY }; await _Concurrency.withTaskCancellationHandler(operation: {}, onCancel: cancelled)', False)):
        production = ('import Foundation; import TransportCore; public struct CallbackService { let client: HTTPClient; '
            'public func fetch() async { ' + body.replace('BODY',
                'Task { _ = try await client.send(URLRequest(url: URL(string: "https://example.invalid")!)) }') + ' } }')
        assert 'CourseFeature.CallbackService' in business_methods(swift_syntax_index_sources({observer_path: production})), body
        smoke = 'class ReleaseNetworkSmokeRunner { func run() async { ' + body.replace('BODY', 'service.fetch()') + ' } }'
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: smoke}))['network']
        assert any(call['calledExpression'] == 'service.fetch' for call in calls) == smoke_executed, body
    for execution, expected in (('', False), ('operation()', True)):
        declaration = f'struct Task<S, F> {{ init(operation: () -> Void) {{ {execution} }} }}; '
        production = (declaration + 'import Foundation; public struct Service { public func fetch() { '
            'Task<Void, Never>(operation: { _ = try? Data(contentsOf: URL(string: "https://example.invalid")!) }) } }')
        assert bool(business_methods(swift_syntax_index_sources({observer_path: production}))) == expected, execution
        smoke = declaration + 'class ReleaseNetworkSmokeRunner { func run() { Task<Void, Never>(operation: { service.fetch() }) } }'
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: smoke}))['network']
        assert any(call['calledExpression'] == 'service.fetch' for call in calls) == expected, execution


@lru_cache
def indexed_test_sources(sources: tuple[tuple[str, str], ...]) -> dict:
    return swift_syntax_index_sources(dict(sources))


def raw_test_selectors(group: str) -> dict[str, str]:
    if group in TEST_AREA_SUITES:
        return {test: selector for test, selector in test_selectors("all").items()
                if test.split("/", 1)[0] in TEST_AREA_SUITES[group]}
    directory = ROOT / ("ModuleTests" if group == "modules" else "BIT101-iOSUITests" if group == "ui" else "BIT101-iOSTests")
    sources = {}
    for path in sorted(directory.rglob("*.swift")):
        sources[str(path)] = active_swift_source(path.read_text(), group, path=str(path))
    selectors = {}
    origins = {}
    for path, facts in indexed_test_sources(tuple(sorted(sources.items()))).items():
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
    return selectors


@cache
def test_selectors(group: str) -> dict[str, str]:
    selectors = raw_test_selectors(group)
    return {test: selector for test, selector in selectors.items() if test.split("/", 1)[0] in FORMAL_RUNTIME_SUITES} \
        if group in {"release-runtime", "catalyst-release-runtime"} else selectors


@cache
def test_inventory(group: str) -> set[str]:
    return set(test_selectors(group))


@cache
def test_case_inventory(group: str) -> dict[str, int]:
    from validation_inputs import repository_input_names, includes_input
    effective = 'all' if group in TEST_AREA_SUITES else group
    directory = ROOT / ('BIT101-iOSUITests' if effective == 'ui' else 'BIT101-iOSTests')
    sources = {str(path): active_swift_source(path.read_text(), effective, path=str(path))
        for path in directory.rglob('*.swift')}
    index = indexed_test_sources(tuple(sorted(sources.items())))
    expected, enum_index = {}, None
    for path, facts in index.items():
        for test in facts['tests']:
            count = test.get('testCaseCount')
            if count is None:
                arguments = test.get('arguments', [])
                if len(arguments) != 1 or not (match := re.fullmatch(r'([\w.]+)\.allCases', arguments[0])):
                    raise ValueError(f"参数库存需要字面量数组或 CaseIterable 枚举：{test['value']}")
                if enum_index is None:
                    names = {argument.removesuffix('.allCases').rsplit('.', 1)[-1]
                        for source in index.values() for entry in source['tests'] for argument in entry.get('arguments', [])
                        if re.fullmatch(r'[\w.]+\.allCases', argument)}
                    referenced_enum = re.compile(r'\b(?:' + '|'.join(map(re.escape, sorted(names))) + r')\b')
                    enum_sources = {}
                    for name in repository_input_names(ROOT):
                        if not name.endswith('.swift') or not includes_input(name, effective): continue
                        path = ROOT / name
                        try: source = path.read_text()
                        except FileNotFoundError: continue
                        if referenced_enum.search(source) and re.search(r'\benum\s+|\ballCases\b', source):
                            enum_sources[str(path)] = active_swift_source(source, effective, path=name)
                    enum_index = swift_syntax_index_sources(enum_sources)
                scope = match[1].split('.')
                candidates = [(node, sum(case['scope'] == node['scope'] + [node['name']] for case in enum_facts['enumCases']))
                    for enum_facts in enum_index.values() for node in enum_facts['declarations']
                    if node['kind'] == 'enum' and (node['scope'] + [node['name']])[-len(scope):] == scope
                    and any(base.rsplit('.', 1)[-1] == 'CaseIterable' for base in node['inheritedTypes'])]
                if len(candidates) != 1: raise ValueError(f"参数库存需要唯一枚举定义：{test['value']}")
                node, count = candidates[0]
                enum_scope = '.'.join(node['scope'] + [node['name']])
                if any(binding.get('bindingName') == 'allCases' and binding.get('isStaticBinding') is True
                        and '.'.join(binding['scope']) == enum_scope
                        for enum_facts in enum_index.values() for binding in enum_facts['bindings']):
                    raise ValueError(f"参数库存支持自动合成 allCases 和字面量数组：{test['value']}")
            if type(count) is not int or count <= 0: raise ValueError(f"参数库存需要有效测试实例：{test['value']}")
            expected[normalized_test_id(test['value'])] = count
    return {name: count for name, count in expected.items() if name in test_inventory(group)}
