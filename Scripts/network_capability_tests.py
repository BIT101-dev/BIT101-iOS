"""Regression contracts for network capability discovery and reachable smoke calls."""
from validation_test_areas import (MANUAL_CAPABILITY_SCENARIOS, NETWORK_CAPABILITIES,
    network_capability_findings, reachable_smoke_calls, smoke_receiver_resolver)


def network_capability_self_test() -> None:
    from unittest.mock import patch
    from validation_evidence import compilation_condition
    assert compilation_condition('RELEASE_NETWORK_SMOKE', 'network')
    assert not compilation_condition('DEBUG', 'network')
    from network_capability_rules import signature_function, method_signature
    for signature in ('fetch(values:Dictionary<String,Int>)', 'fetch(context:(Int,String))',
            'fetch(callback:(Int,String)->Void)', 'fetch(values:Dictionary<String,(Int,String)>,callback:(Int,String)->Void)',
            'static fetch()', 'fetch()->Int', 'static fetch(callback:()->Void)->(Int,String)'):
        assert method_signature(signature_function(signature, ['Service'])) == signature
    index = {f'Modules/{name.split(".")[0]}/Sources/{name.split(".")[1]}.swift': {
        'declarations': [{'kind': 'struct', 'name': name.split('.')[1], 'scope': [], 'inheritedTypes': [], 'isExported': True}],
        'functionRanges': [{**signature_function(method, [name.split(".")[1]]), 'isExported': True, 'isAsync': True, 'start': 0, 'end': 1}
        for method in methods]} for name, methods in NETWORK_CAPABILITIES.items()}
    bindings = {owner.split('.')[1]: owner.split('.')[1].removesuffix('Service').lower() for owner in NETWORK_CAPABILITIES}; bindings['GalleryService'] = 'gallery'
    entries = (('network', 'BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift', ['ReleaseNetworkSmokeRunner'], 'run'),
        ('community-writes', 'BIT101-iOS/Shared/Client/CommunityWriteSmoke.swift', ['CommunityWriteSmoke', 'Operations'], 'production'))
    for route, file, scope, entry in entries:
        calls = [{'calledExpression': (owner.split('.')[1] if signature_function(method, [])['isStatic'] else bindings[owner.split('.')[1]])
            + '.' + signature_function(method, [])['name'], 'argumentLabels': [p['label'] for p in signature_function(method, [])['parameters']],
            'arguments': [p['type'] + '()' for p in signature_function(method, [])['parameters']], 'start': 10, 'scope': scope}
            for owner, methods in NETWORK_CAPABILITIES.items() for method, target in methods.items() if target == route]
        index[file] = {'functionRanges': [{'name': entry, 'scope': scope, 'start': 0, 'end': 100}], 'invocations': calls,
            'typedVariables': [{'name': bindings[owner.split('.')[1]], 'type': owner, 'scope': scope, 'start': 0}
                for owner in NETWORK_CAPABILITIES]}
    index['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift']['invocations'].append({'calledExpression': 'CommunityWriteSmoke.Operations.production', 'start': 10, 'scope': ['ReleaseNetworkSmokeRunner']})
    assert network_capability_findings(index) == []
    with patch.dict(MANUAL_CAPABILITY_SCENARIOS['BIT101-iOS.NetworkDiagnosisRunner'], {}, clear=True):
        assert any('逐方法登记' in error for error in network_capability_findings(index))
    with patch.dict(MANUAL_CAPABILITY_SCENARIOS['BIT101-iOS.NetworkDiagnosisRunner'], {'run()': 'unknown-scene'}):
        assert any('有效验收场景' in error for error in network_capability_findings(index))
    from copy import deepcopy
    unbound = deepcopy(index)
    unbound['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift']['typedVariables'] = []
    assert any('实际服务调用' in error for error in network_capability_findings(unbound))
    renamed = deepcopy(index)
    for facts in (renamed['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift'], renamed['BIT101-iOS/Shared/Client/CommunityWriteSmoke.swift']):
        for variable in facts['typedVariables']:
            if variable['name'] == 'gallery': variable['name'] = 'feedClient'
        for call in facts['invocations']:
            call['calledExpression'] = call['calledExpression'].replace('gallery.', 'feedClient.')
    assert not network_capability_findings(renamed)
    unused = deepcopy(index)
    unused['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift']['functionRanges'][0]['scope'] = ['UnusedHelper']
    assert any('实际服务调用' in error for error in network_capability_findings(unused))
    nested = deepcopy(index)
    nested['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift']['functionRanges'].append({'name': 'unused', 'scope': ['ReleaseNetworkSmokeRunner'], 'start': 5, 'end': 20})
    assert any('实际服务调用' in error for error in network_capability_findings(nested))
    queued = deepcopy(index)
    queued['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift']['callableRanges'] = [{'name': 'queued', 'scope': ['ReleaseNetworkSmokeRunner'], 'start': 5, 'end': 20}]
    assert any('实际服务调用' in error for error in network_capability_findings(queued))
    invocation = {'calledExpression': 'runInParallel', 'start': 30, 'arguments': ['queued'], 'scope': ['ReleaseNetworkSmokeRunner']}
    queued['BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift']['invocations'].append(invocation)
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
    platform_sources = {'BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift': '''
        struct ReleaseNetworkSmokeRunner {
            func run() {
                #if targetEnvironment(macCatalyst)
                service.catalystRead()
                #else
                helper()
                #endif
            }
            func helper() {
                #if targetEnvironment(macCatalyst)
                service.unreachableAcrossHosts()
                #else
                service.iosRead()
                #endif
            }
        }'''}
    platform_calls = reached(platform_sources)
    assert {'service.catalystRead', 'service.iosRead'} <= platform_calls
    assert 'service.unreachableAcrossHosts' not in platform_calls
    for body, expected in [('', False), ('callback()', True),
            ('forward(callback)', True), ('Task { callback() }', True), ('let idle = { callback() }', False)]:
        inline = {'ReleaseNetworkSmoke.swift': f'''struct ReleaseNetworkSmokeRunner {{
            func run() {{ register {{ service.fetch() }} }}
            func register(_ callback: () -> Void) {{ {body} }}
            func forward(_ callback: () -> Void) {{ callback() }}
        }}'''}
        assert ('service.fetch' in reached(inline)) == expected, body
    for invocation in ('probe { service.fetch() }', 'Task { service.fetch() }',
            'Task.detached { service.fetch() }', 'runInParallel([{ service.fetch() }])'):
        assert 'service.fetch' in reached({'ReleaseNetworkSmoke.swift':
            f'struct ReleaseNetworkSmokeRunner {{ func run() {{ {invocation} }} }}'}), invocation
    for body in (
        'withTaskCancellationHandler(operation: { service.live() }, onCancel: { Task { service.idle() } })',
        'withTaskCancellationHandler { service.live() } onCancel: { Task.detached { service.idle() } }',
        'let operation = { service.live() }; let cancellation = { Task { service.idle() } }; withTaskCancellationHandler(operation: operation, onCancel: cancellation)',
    ):
        calls = reached({'ReleaseNetworkSmoke.swift': f'struct ReleaseNetworkSmokeRunner {{ func run() async {{ {body} }} }}'})
        assert 'service.live' in calls and 'service.idle' not in calls, (body, calls)
    task_local = {'ReleaseNetworkSmoke.swift': '''enum Trace { @TaskLocal static var current: (() -> Void)? }
        struct ReleaseNetworkSmokeRunner {
            func run() { invoke { service.fetch() } }
            func invoke(_ operation: () -> Void, count: Int = 0) {
                Trace.$current.withValue({ service.idle() }) { operation() }
            }
        }'''}
    calls = reached(task_local)
    assert 'service.fetch' in calls and 'service.idle' not in calls, calls
    stored = {'ReleaseNetworkSmoke.swift': '''struct Operations { var callback: () -> Void }
        struct ReleaseNetworkSmokeRunner {
            func run() { let operations: Operations = make(); operations.callback() }
            func make() -> Operations { Operations(callback: { service.live() }) }
            func unused() -> Operations { Operations(callback: { service.idle() }) }
        }'''}
    calls = reached(stored)
    assert 'service.live' in calls and 'service.idle' not in calls, calls
    stored['ReleaseNetworkSmoke.swift'] = stored['ReleaseNetworkSmoke.swift'].replace('operations.callback()', '')
    assert 'service.live' not in reached(stored)
    protocol = {'Modules/Ports/Sources/Restoring.swift': 'public protocol Restoring { func restore() }',
        'ReleaseNetworkSmoke.swift': '''import Ports
            struct Adapter: Restoring {
                let operation: () -> Void
                init(operation: @escaping () -> Void) { self.operation = operation }
                func restore() { operation() }
            }
            struct ReleaseNetworkSmokeRunner {
                let restorer: any Restoring
                func run() { build(); restorer.restore() }
                func build() { _ = Adapter { service.fetch() } }
            }'''}
    assert 'service.fetch' in reached(protocol)
    protocol['ReleaseNetworkSmoke.swift'] = protocol['ReleaseNetworkSmoke.swift'].replace('build(); restorer.restore()', 'restorer.restore()')
    assert 'service.fetch' not in reached(protocol)
    for literal in ('1000', '1_000', '0x3e8', '0b1111101000', '0o1750', '-1_000', '+1000'):
        numeric = {'ReleaseNetworkSmoke.swift': f'''struct ReleaseNetworkSmokeRunner {{
            func run() {{ helper(id: {literal}) }}
            func helper(id: Int) {{ service.read() }}
            func helper(id: String) {{ service.write() }}
        }}'''}
        calls = reached(numeric)
        assert 'service.read' in calls and 'service.write' not in calls, (literal, calls)
    numeric['ReleaseNetworkSmoke.swift'] = numeric['ReleaseNetworkSmoke.swift'].replace('+1000', 'unknown')
    assert not {'service.read', 'service.write'} & reached(numeric)
    for literal in ('1.0', '1_000.5', '1e3', '0x1.fp2', '-1.5'):
        numeric['ReleaseNetworkSmoke.swift'] = f'''struct ReleaseNetworkSmokeRunner {{
            func run() {{ helper(id: {literal}) }}
            func helper(id: Double) {{ service.read() }}
            func helper(id: String) {{ service.write() }}
        }}'''
        calls = reached(numeric)
        assert 'service.read' in calls and 'service.write' not in calls, (literal, calls)
    for parameters, argument in ((('flag: Bool', 'text: String'), 'flag: true'),
            (('value: Int?', 'value: String?'), 'value: 42')):
        overloaded = {'ReleaseNetworkSmoke.swift': f'''struct ReleaseNetworkSmokeRunner {{
            func run() {{ helper({argument}) }}
            func helper({parameters[0]}) {{ service.read() }}
            func helper({parameters[1]}) {{ service.write() }}
        }}'''}
        calls = reached(overloaded)
        assert 'service.read' in calls and 'service.write' not in calls, (parameters, calls)
    scoped = {'ReleaseNetworkSmoke.swift': '''struct ReleaseNetworkSmokeRunner {
        func run() { helper(flag: true) }
        func helper(flag: Bool) { service.read() }
        func unused() { func helper(flag: Bool) { service.write() }; helper(flag: true) }
    }'''}
    assert 'service.read' in reached(scoped) and 'service.write' not in reached(scoped)
    scoped['ReleaseNetworkSmoke.swift'] = scoped['ReleaseNetworkSmoke.swift'].replace(
        'func run() { helper(flag: true) }', 'func run() { func helper(flag: Bool) { service.local() }; helper(flag: true) }')
    assert 'service.local' in reached(scoped) and 'service.read' not in reached(scoped)
    split = dict(sources)
    split['NetworkSmokeExtra.swift'] = split.pop('NetworkSmokeProductionSession.swift')
    assert reached(split) == reached(sources)
    split['BIT101Watch/NetworkSmokeExtra.swift'] = split['NetworkSmokeExtra.swift'].replace('mine.fetchMyInfo()', 'mine.fetchWatchInfo()')
    assert 'mine.fetchWatchInfo' not in reached(split)
    writes = {'ReleaseNetworkSmoke.swift': 'struct ReleaseNetworkSmokeRunner { func run() { CommunityWriteSmoke.run() } }',
        'CommunityWriteSmoke.swift': 'enum CommunityWriteSmoke { static func run() { WriteProbes.send() } }',
        'NetworkSmokeExtra.swift': 'enum WriteProbes { static func send() { service.createPaper() } }'}
    write_facts = swift_syntax_index_sources(writes)
    assert 'service.createPaper' in {call['calledExpression'] for call in reachable_smoke_calls(write_facts)['community-writes']}
    assert 'service.createPaper' not in {call['calledExpression'] for call in reachable_smoke_calls(write_facts)['network']}
    inactive = dict(sources)
    inactive['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace('dependencies.productionSessionProbe()', '\n#if DEBUG\ndependencies.productionSessionProbe()\n#endif\n')
    assert 'mine.fetchMyInfo' not in reached(inactive)
    unused_reference = dict(sources)
    unused_reference['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace('dependencies.productionSessionProbe()', 'let unused = dependencies.productionSessionProbe')
    assert 'mine.fetchMyInfo' not in reached(unused_reference)
    for statement in ('if', 'while'):
        for condition, expected in [('false', False), ('!true', False), ('true', True), ('!false', True),
                ('false && true', False), ('true || false', True), ('!(true || false)', False),
                ('(true || false) && false', False), ('condition && false', False), ('condition || true', True)]:
            branch = dict(sources)
            branch['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
                'dependencies.productionSessionProbe()', f'{statement} {condition} {{ dependencies.productionSessionProbe() }}')
            assert ('mine.fetchMyInfo' in reached(branch)) == expected, (statement, condition)
    for sequence, expected in [('0..<0', False), ('0..<1', True), ('-1..<(-1)', False), ('1...1', True), ('[]', False)]:
        loop = dict(sources)
        loop['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
            'dependencies.productionSessionProbe()', f'for _ in {sequence} {{ dependencies.productionSessionProbe() }}')
        assert ('mine.fetchMyInfo' in reached(loop)) == expected, sequence
    disabled = dict(sources)
    disabled['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
        'dependencies.productionSessionProbe()', 'let enabled = false; if enabled { dependencies.productionSessionProbe() }')
    assert 'mine.fetchMyInfo' not in reached(disabled)
    disabled['ReleaseNetworkSmoke.swift'] = disabled['ReleaseNetworkSmoke.swift'].replace('let enabled', 'var enabled')
    assert 'mine.fetchMyInfo' in reached(disabled)
    disabled['ReleaseNetworkSmoke.swift'] = disabled['ReleaseNetworkSmoke.swift'].replace('var enabled', 'let enabled').replace('if enabled', 'while enabled')
    assert 'mine.fetchMyInfo' not in reached(disabled)
    from network_capability_rules import call_can_execute
    expressions = [
        ('false && service.fetch()', False), ('true && service.fetch()', True),
        ('true || service.fetch()', False), ('false || service.fetch()', True),
        ('false ? service.fetch() : true', False), ('true ? service.fetch() : false', True),
        ('true ? false : service.fetch()', False), ('false ? true : service.fetch()', True),
        ('runtime && service.fetch()', True), ('runtime ? service.fetch() : false', True),
        ('false && runtime || service.fetch()', True), ('true || runtime && service.fetch()', False),
        ('(false || false) && service.fetch()', False), ('false ? true : false && service.fetch()', False),
        ('false && service.fetch() ? true : false', False),
        ('true ? false : runtime ? service.fetch() : true', False),
        ('enabled && service.fetch()', False), ('mutable && service.fetch()', True),
        ('{ let enabled = true; return enabled && service.fetch() }()', True),
        ('service.fetch() && false', True), ('service.fetch() || true', True),
    ]
    expression_index = swift_syntax_index_sources({body:
        'func run(runtime: Bool) { let enabled = false; var mutable = false; let _ = ' + body + ' }'
        for body, _ in expressions})
    for body, expected in expressions:
        facts = expression_index[body]
        call = next(row for row in facts['invocations'] if row['calledExpression'] == 'service.fetch')
        assert call_can_execute(facts, call) == expected, body
    switches = [
        ('switch false { case true: service.fetch(); default: break }', False),
        ('switch false { case false: service.fetch(); default: break }', True),
        ('switch true { case true: break; default: service.fetch() }', False),
        ('switch 2 { case 1, 3: service.fetch(); default: break }', False),
        ('switch 2 { case 1, 2: service.fetch(); default: break }', True),
        ('switch 9007199254740992.0 { case 9007199254740993: service.fetch(); default: break }', True),
        ('switch "é" { case "é": service.fetch(); default: break }', True),
        ('let flag = false; switch flag { case true: service.fetch(); default: break }', False),
        ('var flag = false; switch flag { case true: service.fetch(); default: break }', True),
        ('switch 2 { case 2 where false: service.fetch(); default: break }', False),
        ('switch 2 { case 2 where condition: service.fetch(); default: break }', True),
        ('switch 2 { case let value where value == 2: service.fetch(); default: break }', True),
        ('switch value { case .active where false: service.fetch(); default: break }', False),
        ('switch 2 { case let value where false: service.fetch(); default: break }', False),
        ('switch true { case false: fallthrough; default: service.fetch() }', True),
        ('switch true { case true: fallthrough; case false: service.fetch() }', True),
        ('switch true { case true: if false { fallthrough }; break; case false: service.fetch() }', False),
        ('switch true { case true: if condition { fallthrough }; break; case false: service.fetch() }', True),
        ('switch false { case true: func helper() { service.fetch() }; helper(); default: break }', False),
    ]
    switch_index = swift_syntax_index_sources({body: f'func run(condition: Bool) {{ {body} }}' for body, _ in switches})
    for body, expected in switches:
        facts = switch_index[body]
        call = next(row for row in facts['invocations'] if row['calledExpression'] == 'service.fetch')
        assert call_can_execute(facts, call) == expected, body
    dead_switch = dict(sources)
    dead_switch['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
        'dependencies.productionSessionProbe()', 'switch false { case true: dependencies.productionSessionProbe(); default: break }')
    assert 'mine.fetchMyInfo' not in reached(dead_switch)
    comparisons = [('true == false', False), ('false != false', False), ('true != false', True),
        ('(true == false) || false', False), ('enabled == false', True), ('1 == 2', False), ('1 != 1', False),
        ('-1 >= 0', False), ('1_000 < 1', False), ('1.5 > 2', False), ('0x10 == 16', True),
        ('9007199254740993 == 9007199254740992.0', True), ('"a" == "b"', False), ('"a" != "a"', False),
        ('1 + 1 == 3', False), ('3 % 2 == 0', False), ('2 * (3 - 1) == 4', True),
        ('5 / 2 == 2', True), ('-5 / 2 == -2', True), ('5 / -2 == -2', True),
        ('-9 % 4 == -1', True), ('9 % -4 == 1', True), ('-9 % -4 == 3', False),
        ('1 / 2 == 0.5', True), ('(1 / 2) + 0.5 == 1.0', True), ('2.5 * 2 == 4', False),
        ('"e" + "́" == "é"', True), ('1 / 0 == 0', True), ('9223372036854775807 + 1 == 0', True),
        ('"true" == "True"', False), ('"!" == " not "', False), ('"&&" == " and "', False),
        ('"é" != "é"', False), (r'"row.\(enabled)" == "fixed"', True), ('1 == enabled', True),
        (r'"\01" != "\001"', True), (r'"\01" == "\001"', False), (r'"\u{e9}" == "é"', True),
        (r'"row.\\(enabled)" == "fixed"', False), (r'"\u{0}1" == "\01"', True)]
    comparison_sources = {condition: f'func run(enabled: Bool) {{ if {condition} {{ service.fetch() }} }}'
        for condition, _ in comparisons}
    comparison_index = swift_syntax_index_sources(comparison_sources)
    for condition, expected in comparisons:
        facts = comparison_index[condition]
        call = next(row for row in facts['invocations'] if row['calledExpression'] == 'service.fetch')
        assert call_can_execute(facts, call) == expected, condition
        branch = dict(sources)
        branch['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
            'dependencies.productionSessionProbe()', f'if {condition} {{ dependencies.productionSessionProbe() }}')
        assert ('mine.fetchMyInfo' in reached(branch)) == expected, condition
    initializers = [
        ('let value = 1; let alias = value; if alias == 2', False),
        ('let value: Int = 1; let flag = value == 2; if flag', False),
        ('let value = "first"; let alias = value; if alias == "second"', False),
        ('var value = 1; value = 2; if value == 2', True),
        ('let value = input; if value == 2', True),
        ('let value = value; if value == 2', True),
        ('let value: Custom = 1; if value == 2', True),
        ('let value: Double = 9007199254740993; if value == 9007199254740992', True),
        ('let value = 1 + 1; if value == 3', False),
        ('let value = -9 % 4; if value == 1', False),
        ('let value: Double = 1 / 2; if value == 0.5', True),
        ('let value: Double = 1 / 2; if value == 0', False),
        ('let value: Float = 16777217; if value == 16777216', True),
    ]
    initializer_index = swift_syntax_index_sources({prefix: f'func run(input: Int) {{ {prefix} {{ service.fetch() }} }}'
        for prefix, _ in initializers})
    for prefix, expected in initializers:
        facts = initializer_index[prefix]
        call = next(row for row in facts['invocations'] if row['calledExpression'] == 'service.fetch')
        assert call_can_execute(facts, call) == expected, prefix
    for outer in ('true', 'false'):
        for body, expected in [
            ('func run(enabled: Bool) { if enabled { service.fetch() } }', True),
            ('func run(enabled: Bool) { let enabled = false; if enabled { service.fetch() } }', False),
            ('func run(enabled: Bool) { let enabled = true; if enabled { service.fetch() } }', True),
            ('func run() { let closure = { (enabled: Bool) in if enabled { service.fetch() } } }', True),
            ('func run() { let closure = { enabled in if enabled { service.fetch() } } }', True),
            ('func run() { let closure = { (enabled) in if enabled { service.fetch() } } }', True),
            ('func run() { if enabled { service.fetch() } }', outer == 'true'),
        ]:
            facts = swift_syntax_index_sources({'shadowing': f'struct Runner {{ let enabled = {outer}; {body} }}'})['shadowing']
            call = next(call for call in facts['invocations'] if call['calledExpression'] == 'service.fetch')
            assert call_can_execute(facts, call) == expected, (outer, body)
    for statement in ('return', 'throw URLError(.cancelled)'):
        terminated = dict(sources)
        terminated['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
            'dependencies.productionSessionProbe()', statement + '; dependencies.productionSessionProbe()')
        assert 'mine.fetchMyInfo' not in reached(terminated), statement
    conditional = dict(sources)
    conditional['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
        'dependencies.productionSessionProbe()', 'if condition { return }; dependencies.productionSessionProbe()')
    assert 'mine.fetchMyInfo' in reached(conditional)
    successors = [
        ('guard false else { return }', False), ('guard true else { return }', True),
        ('guard condition else { return }', True), ('if true { return }', False), ('if false { return }', True),
        ('if condition { return } else { throw URLError(.cancelled) }', False),
        ('if condition { return } else if true { return }', False),
        ('if condition { return } else if other { return }', True),
        ('if true { if true { return } }', False), ('if true { let closure = { return } }', True),
        ('while true { return }', False), ('while false { return }', True), ('while condition { return }', True),
        ('while true { break }', True), ('while true { continue }', False), ('while true {}', False),
        ('while true { if false { break } }', False), ('while true { if condition { break } }', True),
        ('while true { while true { break } }', False),
        ('repeat { return } while false', False), ('repeat { continue } while false', True),
        ('repeat { break } while true', True), ('repeat {} while true', False),
        ('do { return } catch { return }', False), ('do { return } catch { consume() }', True),
        ('do { throw error } catch { return }', False), ('do { consume() } catch { return }', True),
        ('switch value { case .a: return; case .b: return }', False),
        ('switch value { case .a: return; default: break }', True),
        ('switch value { case .a: fallthrough; default: return }', False),
        ('switch value { case .a: fallthrough; default: consume() }', True),
        ('switch false { case true: break; case false: return }', False),
        ('switch false { case true: return; case false: break }', True),
        ('switch true { case true: fallthrough; case false: return }', False),
        ('switch true { case true: fallthrough; case false: fallthrough; default: return }', False),
        ('switch true { case true: if condition { fallthrough }; return; default: return }', False),
        ('while true { switch value { case .a: break; default: break } }', False),
    ]
    fixtures = {prefix: 'func run() { ' + prefix + '; service.fetch() }' for prefix, _ in successors}
    successor_index = swift_syntax_index_sources(fixtures)
    for prefix, expected in successors:
        facts = successor_index[prefix]
        call = next(row for row in facts['invocations'] if row['calledExpression'] == 'service.fetch')
        assert call_can_execute(facts, call) == expected, prefix
    for prefix in ('guard false else { return }', 'if true { return }', 'while true { return }',
                   'repeat { return } while false', 'do { return } catch { return }',
                   'switch value { case .a: return; default: return }'):
        terminated = dict(sources)
        terminated['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(
            'dependencies.productionSessionProbe()', prefix + '; dependencies.productionSessionProbe()')
        assert 'mine.fetchMyInfo' not in reached(terminated), prefix
    hoisted = dict(sources)
    hoisted['ReleaseNetworkSmoke.swift'] = 'struct ReleaseNetworkSmokeRunner { func run() { helper(); return; func helper() { dependencies.productionSessionProbe() } } }'
    assert 'mine.fetchMyInfo' in reached(hoisted)
    hoisted['ReleaseNetworkSmoke.swift'] = hoisted['ReleaseNetworkSmoke.swift'].replace('helper(); return;', 'helper(); if true { return };')
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


def network_discovery_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods
    watch_only = '''import Foundation
        struct WatchService {
        #if os(watchOS)
            func fetch() async throws -> Data { try await URLSession.shared.data(from: URL(string: "https://fixture.invalid")!).0 }
        #else
            func label() -> String { "fixture" }
        #endif
        }'''
    for path, expected in [('BIT101Watch/WatchService.swift', True), ('BIT101WatchWidgets/WatchService.swift', True),
            ('Modules/WatchService/Sources/WatchService.swift', True), ('BIT101-iOS/WatchService.swift', False)]:
        source = watch_only.replace('struct WatchService', 'public struct WatchService').replace('func fetch()', 'public func fetch()') if path.startswith('Modules/') else watch_only
        assert bool(business_methods(swift_syntax_index_sources({path: source}))) == expected, path
    from validation_compilation import active_network_source, available_local_modules
    for condition, modules, app, watch in [('os(macOS)', True, False, False),
            ('targetEnvironment(macCatalyst)', True, True, False), ('os(iOS)', True, True, False),
            ('os(watchOS)', True, False, True)]:
        source = watch_only.replace('os(watchOS)', condition)
        for path, expected in [('Modules/GalleryFeature/Sources/Service.swift', modules),
                ('BIT101-iOS/Service.swift', app), ('BIT101Watch/Service.swift', watch)]:
            assert ('func fetch()' in active_network_source(source, path)) == expected, (condition, path)
    assert {'CommunityCore', 'StorageCore', 'TransportCore'} <= available_local_modules('Modules/GalleryFeature/Sources/Service.swift')
    assert 'ScoreInfrastructure' not in available_local_modules('Modules/GalleryFeature/Sources/Service.swift')
    assert 'PaperFeature' in available_local_modules('BIT101-iOS/Shell/Service.swift')
    assert 'PaperFeature' not in available_local_modules('BIT101Watch/Service.swift')
    assert 'PaperFeature' in available_local_modules('ModuleTests/Community/ServiceContractTests.swift')
    for condition, expected in [('canImport(CommunityCore)', True), ('canImport(StorageCore)', True),
            ('canImport(ScoreInfrastructure)', False), ('canImport(UnregisteredFramework)', False)]:
        source = watch_only.replace('os(watchOS)', condition)
        assert ('func fetch()' in active_network_source(source, 'Modules/GalleryFeature/Sources/Service.swift')) == expected
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods, method_signature
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
    for expression, expected in [('Service.fetch()', True), ('Service().fetch()', False),
            ('instance.fetch()', False), ('metatype.fetch()', True), ('Alias.fetch()', True)]:
        path = 'Modules/GalleryFeature/Sources/Service.swift'
        index = swift_syntax_index_sources({path: '''typealias Alias = Service
            public struct Service { let client: HTTPClient; public static func fetch() -> Int { 1 }; public func fetch() -> Int { 2 } }
            func smoke(instance: Service, metatype: Service.Type) { let _ = ''' + expression + ' }'})
        functions = [(path, row) for row in index[path]['functionRanges'] if row['name'] == 'fetch']
        call = next(row for row in index[path]['invocations'] if row['calledExpression'].endswith('.fetch'))
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert len(matches) == 1 and matches[0][1]['isStatic'] == expected, expression
        assert {method_signature(row) for _, row in functions} == {'fetch()', 'static fetch()'}
    for body, expected in [('let value: Int = Service().fetch()', 'Int'),
            ('let value: String = Service().fetch()', 'String'), ('return Service().fetch()', 'Int'),
            ('let _ = Service().fetch()', None)]:
        path = 'Modules/GalleryFeature/Sources/Service.swift'
        index = swift_syntax_index_sources({path: '''public struct Service { let client: HTTPClient
            public func fetch() -> Int { 1 }; public func fetch() -> String { "value" } }
            func smoke() -> Int { ''' + body + ' }'})
        methods = business_methods(index)
        functions = methods['GalleryFeature.Service']
        assert {method_signature(row) for _, row in functions} == {'fetch()->Int', 'fetch()->String'}
        call = next(row for row in index[path]['invocations'] if row['calledExpression'].endswith('.fetch'))
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert ([row['returnType'] for _, row in matches] == [expected]) if expected else not matches, body
    for declarations, alternatives, argument, expected in [
        ('protocol Port {}; struct Concrete: Port {}', ['Port', 'Int'], 'Concrete()', 'Port'),
        ('protocol Port {}; struct Concrete: Port {}', ['Port', 'Concrete'], 'Concrete()', 'Concrete'),
        ('class Base {}; class Concrete: Base {}', ['Base', 'Int'], 'Concrete()', 'Base'),
        ('protocol Port {}; protocol Child: Port {}; struct Concrete: Child {}', ['Port', 'Child'], 'Concrete()', 'Child'),
        ('protocol Port {}; struct Concrete {}; extension Concrete: Port {}', ['Port', 'Int'], 'Concrete()', 'Port'),
        ('protocol Port {}; struct Concrete: Port {}; typealias Injected = Concrete', ['any Port', 'Int'], 'Injected()', 'any Port'),
        ('protocol Port {}; struct Concrete: Port {}', ['Port?', 'Int'], 'Concrete()', 'Port?'),
        ('protocol Port {}; struct Concrete: Port {}', ['Port', 'Int'], 'optional', None),
    ]:
        path = 'Modules/GalleryFeature/Sources/Client.swift'
        source = declarations + '; struct Client { ' + '; '.join(f'func fetch(using port: {kind}) {{}}' for kind in alternatives) \
            + f' }}; func smoke() {{ let optional: Concrete? = nil; Client().fetch(using: {argument}) }}'
        index = swift_syntax_index_sources({path: source})
        functions = [(path, row) for row in index[path]['functionRanges'] if row['name'] == 'fetch']
        call = next(row for row in index[path]['invocations'] if row['calledExpression'].endswith('.fetch'))
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert ([row['parameters'][0]['type'] for _, row in matches] == [expected]) if expected else not matches, (declarations, alternatives, argument, matches)
    for kind, method in [('URLSessionWebSocketTask', 'send'), ('URLSessionWebSocketTask', 'receive'),
            ('URLSessionDataTask', 'resume'), ('NWConnection', 'send'), ('NWConnection', 'start'),
            ('NWConnectionGroup', 'receiveMessage'), ('NWListener', 'start')]:
        path = 'BIT101-iOS/Shared/Client/SocketClient.swift'
        source = f'import Foundation; import Network; struct SocketClient {{ let task: {kind}; func exchange() {{ task.{method}() }} }}'
        index = swift_syntax_index_sources({path: source})
        discovered = business_methods(index)
        assert any(identity.endswith('.SocketClient') for identity in discovered), (kind, method)
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
    for first, second, argument in [('Int?', 'String?', '42'), ('Swift.Int?', 'Swift.String?', '42'),
            ('Number?', 'Text?', '42'), ('MaybeNumber', 'Text?', 'value'), ('Int', 'Int?', '42'),
            ('Optional<Int>', 'Optional<String>', '42')]:
        path = 'Modules/GalleryFeature/Sources/Client.swift'
        source = f'''typealias Number = Int; typealias Text = String; typealias MaybeNumber = Int?
            public struct Client {{ public func fetch(id: {first}) {{}}; public func fetch(id: {second}) {{}} }}
            func smoke() {{ let value: Number = 42; Client().fetch(id: {argument}) }}'''
        index = swift_syntax_index_sources({path: source})
        functions = [(path, function) for function in index[path]['functionRanges'] if function['name'] == 'fetch']
        call = next(call for call in index[path]['invocations'] if call['calledExpression'].endswith('.fetch'))
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert len(matches) == 1 and matches[0][1]['parameters'][0]['type'] == first, (first, second, argument)
    compound_path = 'Modules/NewForumFeature/Sources/Service.swift'
    for kind, expression in [('(HTTPClient, String)', 'context.0'), ('[HTTPClient]', 'context[0]'),
            ('Dictionary<String, HTTPClient>', 'context["first"]!'), ('Context', 'context.0')]:
        source = f'''typealias Context = (HTTPClient, String); public struct CompositeService {{
            private let context: {kind}
            public func fetch(request: URLRequest) async throws -> Data {{ try await {expression}.send(request).data }}
        }}'''
        index = swift_syntax_index_sources({compound_path: source})
        assert 'NewForumFeature.CompositeService' in business_methods(index), kind
        assert any('新增生产服务' in error for error in network_capability_findings(index)), kind
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
    getter_path = 'Modules/NewForumFeature/Sources/ReadService.swift'
    for access, exported in [('public', True), ('private', False), ('internal', False)]:
        getter = f'public struct ReadService {{ let client: HTTPClient; {access} var rows: HTTPResponse {{ get async throws {{ try await client.send(request) }} }} }}'
        index = swift_syntax_index_sources({getter_path: getter})
        methods = business_methods(index)
        assert ('NewForumFeature.ReadService' in methods) == exported, access
        if exported:
            assert methods['NewForumFeature.ReadService'][0][1]['name'] == 'rows'
            assert any('新增生产服务' in error for error in network_capability_findings(index))
    from unittest.mock import patch
    for declaration, signature, invocation in [
        ('public var rows: HTTPResponse { get async throws { try await client.send(request) } }', 'rows()', 'try await service.rows'),
        ('public var rows: Task<HTTPResponse, Error> { Task { try await client.send(request) } }', 'rows()', 'service.rows'),
        ('public var operation: () async throws -> HTTPResponse { { try await client.send(request) } }', 'operation()', 'try await service.operation()'),
        ('public subscript(_ id: Int) -> Task<HTTPResponse, Error> { Task { try await client.send(request) } }', 'subscript(:Int)', 'service[1_000]'),
        ('public init() { Task { try await client.send(request) } }', 'init()', 'ReadService()'),
    ]:
        for include_transport in (False, True):
            sources = {getter_path: f'import TransportCore; public struct ReadService {{ let client: HTTPClient; {declaration} }}',
                'ReleaseNetworkSmoke.swift': f'import NewForumFeature; struct ReleaseNetworkSmokeRunner {{ let service: ReadService; func run() {{ _ = {invocation} }} }}'}
            if include_transport:
                sources[transport_path] = 'public struct HTTPClient { public func send(_ request: URLRequest) async throws -> HTTPResponse {} }'
            index = swift_syntax_index_sources(sources)
            methods = business_methods(index)
            assert [method_signature(function) for _, function in methods['NewForumFeature.ReadService']] == [signature], declaration
            with patch.dict(NETWORK_CAPABILITIES, {'NewForumFeature.ReadService': {signature: 'network'}}, clear=True), \
                    patch.dict(MANUAL_CAPABILITY_SCENARIOS, {}, clear=True):
                assert not network_capability_findings(index), (declaration, network_capability_findings(index))
                sources['ReleaseNetworkSmoke.swift'] = sources['ReleaseNetworkSmoke.swift'].replace(invocation,
                    'service.operation' if signature == 'operation()' else '0')
                errors = network_capability_findings(swift_syntax_index_sources(sources))
                assert any('实际服务调用' in error for error in errors), (declaration, errors)
                if signature == 'init()':
                    sources['ReleaseNetworkSmoke.swift'] = '''import NewForumFeature
                        enum Factory { static var existing: ReadService; static func cached() -> ReadService { existing } }
                        struct ReleaseNetworkSmokeRunner { func run() { _ = Factory.cached() } }'''
                    errors = network_capability_findings(swift_syntax_index_sources(sources))
                    assert any('ReadService.init()' in error and '实际服务调用' in error for error in errors), errors
                if signature == 'rows()' and 'get async' not in declaration:
                    sources[getter_path] = sources[getter_path].replace(
                        'public var rows: Task<HTTPResponse, Error> { Task { try await client.send(request) } }',
                        'public var rows: Task<HTTPResponse, Error> { get { Task { try await client.send(request) } } set {} }')
                    sources['ReleaseNetworkSmoke.swift'] = '''import NewForumFeature
                        struct ReleaseNetworkSmokeRunner { var service: ReadService; func run() { service.rows = existingTask } }'''
                    errors = network_capability_findings(swift_syntax_index_sources(sources))
                    assert any('ReadService.rows()' in error and '实际服务调用' in error for error in errors), errors
    protocol = 'public protocol RequestSending { func send(_ request: URLRequest) async throws -> HTTPResponse }; extension HTTPClient: RequestSending {}'
    service = 'public struct ReadService { let client: any RequestSending; public func rows(_ request: URLRequest) async throws -> HTTPResponse { try await client.send(request) } }'
    index = swift_syntax_index_sources({getter_path: 'import TransportCore; ' + service,
        'Modules/TransportCore/Sources/HTTPClient.swift': 'public struct HTTPClient {}; ' + protocol})
    assert 'NewForumFeature.ReadService' in business_methods(index)
    assert any('新增生产服务' in error for error in network_capability_findings(index))
    ports_path = 'Modules/Ports/Sources/Fetching.swift'
    ports = 'public protocol Fetching { func fetch() async throws -> Data }; public protocol RefinedFetching: Fetching {}'
    for access in ('internal', 'fileprivate'):
        for annotation in ('any Fetching', 'any RefinedFetching', 'ForwardedFetching'):
            sources = {ports_path: ports, transport_path: 'public struct HTTPClient {}', getter_path: f'''import Ports; import TransportCore
                typealias ForwardedFetching = RefinedFetching
                {access} struct LiveFetcher: RefinedFetching {{ let client: HTTPClient; func fetch() async throws -> Data {{ try await client.send(request).data }} }}
                public struct ExampleService {{ let fetcher: {annotation}; public func fetch() async throws -> Data {{ try await fetcher.fetch() }} }}'''}
            index = swift_syntax_index_sources(sources)
            assert 'NewForumFeature.ExampleService' in business_methods(index), (access, annotation)
            assert any('新增生产服务' in error for error in network_capability_findings(index))
            sources[getter_path] = sources[getter_path].replace('let client: HTTPClient;', '').replace('try await client.send(request).data', 'Data()')
            assert 'NewForumFeature.ExampleService' not in business_methods(swift_syntax_index_sources(sources))
    sources = {ports_path: ports, 'Modules/OtherPorts/Sources/Fetching.swift': ports,
        transport_path: 'public struct HTTPClient {}', getter_path: '''import Ports; import TransportCore
            struct LiveFetcher: OtherPorts.Fetching { let client: HTTPClient; func fetch() async throws -> Data { try await client.send(request).data } }
            public struct ExampleService { let fetcher: any Ports.Fetching; public func fetch() async throws -> Data { try await fetcher.fetch() } }'''}
    assert 'NewForumFeature.ExampleService' not in business_methods(swift_syntax_index_sources(sources))
    bodies = [
        'public struct ExampleService<T: HTTPTransport> { let transport: T; public func fetch(request: URLRequest) async throws -> Data { try await transport.data(for: request).0 } }',
        'public struct ExampleService<T> where T: HTTPTransport { let transport: T; public func fetch(request: URLRequest) async throws -> Data { try await transport.data(for: request).0 } }',
        'public struct ExampleService { public func fetch<T: HTTPTransport>(transport: T, request: URLRequest) async throws -> Data { try await transport.data(for: request).0 } }',
        'public struct ExampleService { public func fetch<T>(transport: T, request: URLRequest) async throws -> Data where T: HTTPTransport { try await transport.data(for: request).0 } }',
        'public struct ExampleService<T: Fetcher> where T.Client == HTTPClient { let client: T.Client; public func fetch() async throws -> Data { try await client.send(request).data } }',
    ]
    for body in bodies:
        index = swift_syntax_index_sources({getter_path: 'import TransportCore; ' + body,
            transport_path: 'public protocol HTTPTransport {}; public struct HTTPClient {}'})
        assert 'NewForumFeature.ExampleService' in business_methods(index), body
        assert any('新增生产服务' in error for error in network_capability_findings(index)), body
    shadowed = 'public struct ExampleService<T: HTTPTransport> { public func fetch<T>(transport: T) async {} }'
    index = swift_syntax_index_sources({getter_path: shadowed})
    assert 'NewForumFeature.ExampleService' not in business_methods(index)
    app_path = 'BIT101-iOS/Shell/BackgroundRequestService.swift'
    for access, body, expected in [
        ('internal', 'func start(_ request: URLRequest) -> Task<Void, Error> { Task { _ = try await client.send(request) } }', True),
        ('internal', 'func start(_ request: URLRequest) { Task { _ = try await client.send(request) } }', True),
        ('fileprivate', 'func start(_ request: URLRequest) { Task { _ = try await client.send(request) } }', False),
        ('private', 'func start(_ request: URLRequest) -> Task<Void, Error> { Task { _ = try await client.send(request) } }', False),
        ('internal', 'func label() -> String { "cached" }', False),
        ('internal', 'func render() -> some View { Task { _ = try await client.send(URLRequest()) }; EmptyView() }', False),
        ('internal', 'init(load: () async throws -> Void = { _ = try await HTTPClient.shared.send(URLRequest()) }) {}', False),
        ('internal', 'func load(_ url: URL) throws -> Data { try Data(contentsOf: url) }', True),
        ('internal', 'func load(_ url: URL) throws -> Data { guard url.isFileURL else { fatalError() }; return try Data(contentsOf: url) }', False),
    ]:
        source = f'import TransportCore; struct BackgroundRequestService {{ let client: HTTPClient; {access} {body} }}'
        index = swift_syntax_index_sources({app_path: source, transport_path: 'public struct HTTPClient {}'})
        assert ('BIT101-iOS.BackgroundRequestService' in business_methods(index)) == expected, (access, body)
        assert any('新增生产服务需要网络能力验收归属：BIT101-iOS.BackgroundRequestService' in error
            for error in network_capability_findings(index)) == expected, (access, body)
    for body, expected in [('func start() -> Task<Int, Error> { Task { try await service.fetchPaper(id: 1) } }', True),
                 ('func start() { Task { _ = try await service.fetchPaper(id: 1) } }', True),
                 ('func factory() -> Callback { Callback { try await service.fetchPaper(id: 1) } }', False)]:
        index = swift_syntax_index_sources({app_path: 'import PaperFeature; struct BackgroundRequestService { '
            + 'let service: PaperService; ' + body + ' }',
            leaf: 'public struct PaperService { public func fetchPaper(id: Int) async throws -> Int { id } }'})
        assert ('BIT101-iOS.BackgroundRequestService' in business_methods(index)) == expected, body
    task_helper = 'private func startRequest() { Task { _ = try await client.send(request) } }'
    for body, helpers, expected in [
        ('func start() { startRequest() }', task_helper, True),
        ('func start() { self.startRequest() }', task_helper, True),
        ('func start() { forward() }', 'private func forward() { startRequest() }; ' + task_helper, True),
        ('func start() { Task { try await startRequest() } }',
            'private func startRequest() async throws { _ = try await client.send(request) }', True),
        ('func start() { Task { try await self.startRequest() } }',
            'private func startRequest() async throws { _ = try await client.send(request) }', True),
        ('func factory() -> () -> Void { { startRequest() } }', task_helper, False),
        ('func factory() -> Callback { Callback { startRequest() } }', task_helper, False),
        ('func label() { if false { startRequest() } }', task_helper, False),
        ('func label() { startRequest("cached") }',
            'private func startRequest(_ value: String) {}; private func startRequest(_ value: Int) { Task { _ = try await client.send(request) } }', False),
        ('func start() { startRequest(42) }',
            'private func startRequest(_ value: String) {}; private func startRequest(_ value: Int) { Task { _ = try await client.send(request) } }', True),
        ('func label() { forward() }', 'private func forward() { forward() }', False),
    ]:
        source = 'import TransportCore; struct BackgroundRequestService { let client: HTTPClient; ' + body + '; ' + helpers + ' }'
        index = swift_syntax_index_sources({app_path: source, transport_path: 'public struct HTTPClient {}'})
        methods = business_methods(index).get('BIT101-iOS.BackgroundRequestService', [])
        assert bool(methods) == expected, (body, helpers, methods)
        assert all(not function.get('isPrivate') for _, function in methods), methods
        assert any('新增生产服务需要网络能力验收归属：BIT101-iOS.BackgroundRequestService' in error
            for error in network_capability_findings(index)) == expected, (body, helpers)
    extension_path = 'BIT101-iOS/Shell/BackgroundRequestExtension.swift'
    index = swift_syntax_index_sources({app_path: 'import TransportCore; struct BackgroundRequestService { '
        + 'let client: HTTPClient; func start() { startRequest() } }',
        extension_path: 'import TransportCore; extension BackgroundRequestService { func startRequest() { Task { _ = try await client.send(request) } } }',
        transport_path: 'public struct HTTPClient {}'})
    assert {function['name'] for _, function in business_methods(index)['BIT101-iOS.BackgroundRequestService']} == {'start', 'startRequest'}
    boundary = '''protocol Fetching { func fetch() async }
        public struct RegisteredService: Fetching { let client: HTTPClient; public func fetch() async {} }
        public struct Consumer { let service: any Fetching; public func load() async { await service.fetch() } }'''
    with patch.dict(NETWORK_CAPABILITIES, {'NewForumFeature.RegisteredService': {'fetch()': 'network'}}, clear=True):
        assert set(business_methods(swift_syntax_index_sources({getter_path: boundary}))) == {'NewForumFeature.RegisteredService'}
    for port, expected in [('(URLRequest) async throws -> HTTPResponse', True),
                           ('(URLRequest) async throws -> Data', True), ('(URL) async throws -> Data', True),
                           ('(URLRequest) async throws -> (Data, URLResponse)', True),
                           ('(String) async throws -> String', False)]:
        for annotation in (port, 'Sending'):
            source = f'typealias Sending = {port}; public struct ClosureService {{ let send: {annotation}; public func fetch() async throws {{ _ = try await send(request) }} }}'
            index = swift_syntax_index_sources({getter_path: source})
            assert ('NewForumFeature.ClosureService' in business_methods(index)) == expected, (port, annotation)
    for source in ['public func fetch(client: HTTPClient, request: URLRequest) async throws -> Data { try await client.send(request).data }',
                   'public struct ReadService { public func fetch(_ url: URL) throws -> Data { try Data(contentsOf: url) } }']:
        index = swift_syntax_index_sources({getter_path: source})
        assert business_methods(index), source
        assert any('新增生产服务' in error for error in network_capability_findings(index)), source
    file_reader = 'public struct FileService { public func read(_ url: URL) throws -> Data { guard url.isFileURL else { throw Failure.invalid }; return try Data(contentsOf: url) } }'
    index = swift_syntax_index_sources({getter_path: file_reader})
    assert not business_methods(index), file_reader
