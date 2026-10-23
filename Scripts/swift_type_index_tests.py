"""Regression cases for type ownership across modules and private declaration files."""
from pathlib import Path
from swift_source_index import ROOT, swift_syntax_index_sources, declaration_conformances, canonical_type_scope
from swift_type_index import SwiftTypeIndex


def contextual_overload_self_test():
    from network_capability_rules import matching_api_calls, execution_index, call_can_execute
    cases = [
        ('', 'Int32', 'String', '1', 'Int32'), ('', 'UInt32', 'String', '0x10', 'UInt32'),
        ('', 'Float', 'String', '1.25', 'Float'), ('', 'CGFloat', 'String', '1.25', 'CGFloat'),
        ('typealias Narrow = Int32', 'Narrow', 'String', '1', 'Narrow'),
        ('struct Number: ExpressibleByIntegerLiteral { init(integerLiteral: Int) {} }', 'Number', 'String', '1', 'Number'),
        ('', 'Int?', 'String', 'nil', 'Int?'), ('typealias Number = Int32?', 'Number', 'String', 'nil', 'Number'),
        ('enum State { case active }', 'State', 'String', '.active', 'State'),
        ('enum State { case active }; typealias Selection = State', 'Selection', 'String', '.active', 'Selection'),
        ('', 'Int', 'Int32', '1', 'Int'), ('', 'Double', 'Float', '1.25', 'Double'),
    ]
    for declarations, first, second, value, expected in cases:
        path = 'BIT101-iOS/Context.swift'
        source = declarations + f'''\nstruct Service {{ func fetch(id: {first}) {{}}; func fetch(id: {second}) {{}} }}
            struct Use {{ let service: Service; func run() {{ service.fetch(id: {value}) }} }}'''
        index = swift_syntax_index_sources({path: source})
        facts = index[path]
        call = next(node for node in facts['invocations'] if node['calledExpression'] == 'service.fetch')
        functions = [(path, function) for function in facts['functionRanges'] if function['scope'] == ['Service']]
        matched = matching_api_calls(index, functions + functions, dict(call, path=path))
        assert [function['parameters'][0]['type'] for _, function in matched] == [expected], (value, first, second, matched)
    sources = {'Modules/Tokens/Sources/Token.swift': '''public struct Token: Equatable {
        public static func ==(lhs: Token, rhs: Token) -> Bool { true } }''',
        'BIT101-iOS/Use.swift': '''import Tokens
        struct Use { func run() { if ((false)) { service.dead() }; if true { service.live() } } }'''}
    index = execution_index(swift_syntax_index_sources(sources))
    facts = index['BIT101-iOS/Use.swift']
    assert not facts['constantFoldingAllowed']
    calls = {node['calledExpression'] for node in facts['invocations'] if call_can_execute(facts, node)}
    assert 'service.live' in calls and 'service.dead' not in calls


def indexer_environment_self_test():
    from unittest.mock import patch
    import validation_environment as environment
    from swift_source_index import indexer_toolchain
    environment.environment_context.cache_clear()
    indexer_toolchain.cache_clear()
    try:
        with patch.object(environment, 'host_environment', return_value={'developer': '/toolchain', 'compiler': {'version': 'frontend'}}), \
             patch.object(environment, 'plist_values', return_value={'Version': 'sdk'}), \
             patch.object(environment.subprocess, 'check_output', side_effect=AssertionError('Swift 索引沿编译依赖采集环境')), \
             patch.object(Path, 'is_file', return_value=False), patch.object(Path, 'rglob', return_value=[]):
            context = indexer_toolchain(Path('/toolchain/swiftc'), Path('/toolchain/host'))['environment']
            assert set(context['sdks']) == {'MacOSX'} and context['compiler']['version'] == 'frontend'
            assert 'runtimes' not in context
    finally:
        environment.environment_context.cache_clear()
        indexer_toolchain.cache_clear()


def lifecycle_execution_self_test():
    from code_quality_rules import automatic_school_fetch_findings
    service = 'protocol ScheduleCourseServicing { func syncCourses() async }; struct Service: ScheduleCourseServicing { func syncCourses() async {} }'
    cases = [
        ('struct Loader { func load(_ value: Int) async {}; func load(_ value: String) async { await Service().syncCourses() } }', 'await loader.load(1)', False),
        ('struct Loader { func load(_ value: Int) async {}; func load(_ value: String) async { await Service().syncCourses() } }', 'await loader.load("school")', True),
        ('struct Loader { func load(_ value: Int) async {}; func load(_ value: String) async { await Service().syncCourses() } }', 'await loader.load(unknown)', True),
        ('struct Loader { func load(local value: Int) async {}; func load(remote value: Int) async { await Service().syncCourses() } }', 'await loader.load(local: 1)', False),
        ('struct Loader { func load(local value: Int) async {}; func load(remote value: Int) async { await Service().syncCourses() } }', 'await loader.load(remote: 1)', True),
        ('struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader { func load(_ value: Model = Model()) {} }', 'loader.load()', True),
        ('struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader { func load(_ value: Model = Model()) {} }', 'loader.load(existing)', False),
        ('struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader { func load(_ value: Model = Model()) {} }', 'loader.load(Model())', True),
        ('struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader { init(_ value: Model = Model()) {} }', '_ = Loader()', True),
        ('struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader { init(_ value: Model = Model()) {} }', '_ = Loader(existing)', False),
        ('struct Loader { var value: Int { get async { await Service().syncCourses(); return 1 } } }', '_ = await loader.value', True),
        ('struct Loader { var value: Int { Task { await Service().syncCourses() }; return 1 } }', '_ = loader.value', True),
        ('struct Loader { func value() { Task { await Service().syncCourses() } } }', '_ = loader.value', False),
        ('struct Loader { var value: Int { 1 } }', '_ = loader.value', False),
        ('class Loader { deinit { Task { await Service().syncCourses() } } }', '_ = loader', True),
        ('class Loader { deinit { record() } }', '_ = loader', False),
        ('class Parent { func load() async { await Service().syncCourses() } }; class Loader: Parent { func run() async { await self.load() } }', 'await loader.run()', True),
        ('struct Loader { let start: Int }; struct Bootstrap { func start() async { await Service().syncCourses() } }', 'record(loader.start)', False),
        ('struct Loader { var start: Int { Task { await Service().syncCourses() }; return 1 } }', 'record(loader.start)', True),
        ('struct Loader { func load<T>(_ value: T) async { await Service().syncCourses() }; func load(_ value: Int) async {} }', 'await loader.load("school")', True),
        ('struct Loader { func load<T>(_ value: T) async { await Service().syncCourses() }; func load(_ value: Int) async {} }', 'await loader.load(1)', False),
        ('struct Loader { func load<T>(_ value: T) async { await Service().syncCourses() }; func load(_ value: Int) async {} }', 'await loader.load(unknown)', True),
    ]
    for declarations, operation, expected in cases:
        path = str(ROOT / 'BIT101-iOS/Lifecycle.swift')
        source = service + '\n' + declarations + '\nstruct Screen: View { let loader: Loader; let existing: Model; var body: some View { Text("sample").task { ' + operation + ' } } }'
        findings = automatic_school_fetch_findings(swift_syntax_index_sources({path: source}))
        assert bool(findings) == expected, (declarations, operation, findings)
    for module, expected in [('ScheduleSync', False), ('OtherSync', True)]:
        sources = {
            str(ROOT / f'Modules/{module}/Sources/Cloud.swift'): 'public class ScheduleCloudSyncManager { public static let shared = ScheduleCloudSyncManager(); public func refreshFromCloudIfNeeded() async {} }',
            path: f'import {module}\nstruct Screen: View {{ var body: some View {{ Text("sample").task {{ await ScheduleCloudSyncManager.shared.refreshFromCloudIfNeeded() }} }} }}',
        }
        findings = automatic_school_fetch_findings(swift_syntax_index_sources(sources))
        assert bool(findings) == expected, (module, findings)
        for kind, callback in [('class', 'Task { await self.refreshFromCloudIfNeeded() }'),
                               ('actor', 'Task { [weak self] in await self?.refreshFromCloudIfNeeded() }')]:
            sources[str(ROOT / f'Modules/{module}/Sources/Cloud.swift')] = f'public {kind} ScheduleCloudSyncManager {{ public static let shared = ScheduleCloudSyncManager(); public func refreshFromCloudIfNeeded() async {{ {callback} }} }}'
            findings = automatic_school_fetch_findings(swift_syntax_index_sources(sources))
            assert bool(findings) == expected, (module, kind, findings)


def stored_network_callback_self_test():
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls
    service_path = 'Modules/CommunityTransport/Sources/ClosureClient.swift'
    caller_path = 'BIT101-iOS/ClosureClientUsage.swift'
    for initializer in ('public init(load: @escaping () async throws -> Data) { self.load = load }', ''):
        for body, expected in [('try await load()', True), ('try await self.load()', True),
                ('try await Task { try await load() }.value', True),
                ('if false { return try await load() }; return Data()', False),
                ('Data()', False), ('let load = { Data() }; return load()', False)]:
            for argument in ('{ try await http.send(request).data }', 'operation'):
                for supplied, network in [('try await http.send(request).data', True), ('Data()', False)]:
                    closure = argument.replace('try await http.send(request).data', supplied)
                    sources = {service_path: f'''public struct ClosureClient {{
                        let load: () async throws -> Data
                        {initializer}
                        public func fetch() async throws -> Data {{ {body} }}
                    }}''', caller_path: f'''import CommunityTransport
                        func useClosureClient(http: HTTPClient, request: URLRequest) async throws -> Data {{
                            let operation = {{ {supplied} }}
                            let client = ClosureClient(load: {closure})
                            return try await client.fetch()
                        }}'''}
                    index = swift_syntax_index_sources(sources)
                    assert all(not facts.get('parseErrors') for facts in index.values())
                    methods = business_methods(index)
                    found = {function['name'] for path, function in methods.get('CommunityTransport.ClosureClient', [])}
                    assert ('fetch' in found) == (expected and network), (initializer, body, argument, supplied, methods)
    for construction, expected in [
            ('Operations(callback: callback)', True),
            ('if false { return Operations(callback: callback) }; return Operations(callback: {})', False)]:
        expression = 'return ' + construction if expected else construction
        source = f'''struct Operations {{ var callback: () -> Void }}
            struct ReleaseNetworkSmokeRunner {{
                func run() {{ let operations = make(); operations.callback() }}
                func make() -> Operations {{ let callback = {{ service.live() }}; {expression} }}
                func unused() -> Operations {{ let callback = {{ service.idle() }}; return Operations(callback: callback) }}
            }}'''
        index = swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': source})
        types = SwiftTypeIndex(index)
        assert types.resolve('ReleaseNetworkSmoke.swift', 'Self', ['ReleaseNetworkSmokeRunner', 'Operations', 1]) \
            == types.resolve('ReleaseNetworkSmoke.swift', 'ReleaseNetworkSmokeRunner.Operations')
        calls = reachable_smoke_calls(index)['network']
        names = {call['calledExpression'] for call in calls}
        assert ('service.live' in names) == expected and 'service.idle' not in names, (construction, names)


def dynamic_network_callback_self_test():
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls
    path = 'Modules/CourseFeature/Sources/Observer.swift'
    for selector in ('#selector(refresh)', '#selector(Observer.refresh)', 'Selector("refresh")',
            'NSSelectorFromString("refresh")', 'Foundation.Selector(#"refresh"#)',
            'Foundation.NSSelectorFromString("refresh")', 'callback', 'alias'):
        for registration, expected in [
                ('NotificationCenter.default.addObserver(self, selector: SELECTOR, name: nil, object: nil)', True),
                ('if false { NotificationCenter.default.addObserver(self, selector: SELECTOR, name: nil, object: nil) }', False),
                ('let unused = SELECTOR; _ = unused', False), ('ignore(SELECTOR)', False)]:
            source = f'''import Foundation; import TransportCore
                public class Observer: NSObject {{
                    let http: HTTPClient; let request: URLRequest
                    public func begin() {{ let callback = #selector(refresh); let alias = callback;
                        {registration.replace('SELECTOR', selector)} }}
                    private func ignore(_ selector: Selector) {{}}
                    @objc private func refresh() {{ Task {{ _ = try await http.send(request) }} }}
                }}'''
            index = swift_syntax_index_sources({path: source})
            assert not index[path].get('parseErrors')
            methods = business_methods(index)
            assert any(function['name'] == 'begin' for rows in methods.values() for _, function in rows) == expected, (selector, registration, methods)
    for optional, declaration in [('', 'private var action: () -> Void = {}'), ('?', 'private var action: (() -> Void)?')]:
        source = f'''import TransportCore
            public class Worker {{ let http: HTTPClient; let request: URLRequest; {declaration}
                public func begin() {{ action = {{ Task {{ _ = try await http.send(request) }} }}; action{optional}() }}
            }}'''
        methods = business_methods(swift_syntax_index_sources({path: source}))
        assert any(function['name'] == 'begin' for rows in methods.values() for _, function in rows), (optional, methods)
        runtime = source.replace('Worker', 'ReleaseNetworkSmokeRunner').replace('func begin()', 'func run()')
        calls = reachable_smoke_calls(swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': runtime}))['network']
        assert any(call['calledExpression'] == 'http.send' for call in calls), optional


def callable_object_network_self_test():
    collection_callback_self_test()
    standard_callback_self_test()
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls
    fetcher = '''private struct Fetcher { let client: HTTPClient; let request: URLRequest
        fileprivate func callAsFunction() async throws { _ = try await client.send(request) } }'''
    for body, expected in [('try await fetcher()', True), ('try await self.fetcher()', True),
            ('try await fetcher.callAsFunction()', True), ('_ = fetcher', False),
            ('let fetcher = Fetcher(client: client, request: request); try await fetcher()', True),
            ('_ = Fetcher(client: client, request: request)', False), ('func fetcher() {}; fetcher()', False)]:
        source = fetcher + f'''\npublic struct Service {{
            private let fetcher: Fetcher; let client: HTTPClient; let request: URLRequest
            public func fetch() async throws {{ {body} }} }}'''
        methods = business_methods(swift_syntax_index_sources({'Modules/CourseFeature/Sources/Service.swift': source}))
        assert any(function['name'] == 'fetch' for rows in methods.values() for _, function in rows) == expected, (body, methods)
        runtime = source.replace('Service', 'ReleaseNetworkSmokeRunner').replace('func fetch()', 'func run()')
        calls = reachable_smoke_calls(swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': runtime}))['network']
        assert any(call['calledExpression'] == 'client.send' for call in calls) == expected, (body, calls)


def self_test():
    network_composition_self_test()
    extension_protocol_self_test()
    lifecycle_execution_self_test()
    indexer_environment_self_test()
    contextual_overload_self_test()
    from io import BytesIO
    from unittest.mock import patch
    from swift_source_index import indexer_toolchain
    compiler = Path('/toolchain/usr/bin/swiftc')
    host_modules = Path('/toolchain/usr/lib/swift/host')
    artifacts = {str(compiler): b'compiler', str(host_modules / 'libSwiftSyntax.dylib'): b'syntax',
        str(host_modules / 'libSwiftParser.dylib'): b'parser', str(host_modules / 'libSwiftOperators.dylib'): b'operators'}
    with patch('validation_environment.environment_context', return_value={'compiler': {'version': 'frontend'}}), \
         patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'rglob', return_value=[]), \
         patch.object(Path, 'open', lambda path, *args, **kwargs: BytesIO(artifacts[str(path)])), \
         patch.object(Path, 'stat', new=lambda path: __import__('types').SimpleNamespace(st_size=len(artifacts[str(path)]), st_mtime_ns=1)):
        indexer_toolchain.cache_clear()
        original = indexer_toolchain(compiler, host_modules)
        for module in ('SwiftSyntax', 'SwiftParser', 'SwiftOperators'):
            artifacts[str(host_modules / f'lib{module}.dylib')] = b'updated-' + module.encode()
            indexer_toolchain.cache_clear()
            updated = indexer_toolchain(compiler, host_modules)
            assert updated != original, module
            original = updated
        indexer_toolchain.cache_clear()
    from code_quality_rules import automatic_school_fetch_findings, ast_has_view_request
    from swift_type_index import SwiftBindingTypes
    local_path = 'BIT101-iOS/Local.swift'
    local = swift_syntax_index_sources({local_path: 'protocol LocalPort { func fetch() }; struct Owner { let service: any LocalPort; func load() { service.fetch() } }'})
    bindings = SwiftBindingTypes(local)
    call = next(call for call in local[local_path]['calls'] if call['value'] == 'service.fetch')
    assert bindings.receiver_components(call) == {'BIT101-iOS.LocalPort'}
    from ui_rules import native_interaction_inventory
    request_path = str(ROOT / 'BIT101-iOS/RequestView.swift')
    request_support = str(ROOT / 'BIT101-iOS/RequestSupport.swift')
    for parameter, expected in [('URLRequest', True), ('Model', False)]:
        context = swift_syntax_index_sources({request_path: 'struct Screen: View { func load() { consume(.init(url: url)) } }',
            request_support: 'extension Screen { func consume(_ value: ' + parameter + ', enabled: Bool = true) {} }'})
        assert ast_has_view_request(context[request_path], context=context) == expected
    factories = ['func makeBootstrap(_ value: Int) -> SchoolBootstrap { SchoolBootstrap() }',
        'func makeBootstrap(_ value: String) -> SafeBootstrap { SafeBootstrap() }']
    for declarations in (factories, list(reversed(factories))):
        for argument, restricted in [('1', True), ('"safe"', False), ('unknown', True)]:
            source = '''
class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }
struct SchoolBootstrap { let cloud = ScheduleCloudSyncManager(); func start() async { await cloud.refreshFromCloudIfNeeded() } }
struct SafeBootstrap { func start() async {} }
''' + '\n'.join(declarations) + f'''
struct OverloadedApp: App {{ var body: some Scene {{ WindowGroup {{ Text("sample").task {{ await makeBootstrap({argument}).start() }} }} }} }}
'''
            facts = swift_syntax_index_sources({str(ROOT / 'BIT101-iOS/Overloaded.swift'): source})
            assert bool(automatic_school_fetch_findings(facts)) == restricted, (declarations, argument)
    assert canonical_type_scope(['Module.Wrapper<(Int) -> Void>.Holder<[Other.Model]>.Control']) == ('Module', 'Wrapper', 'Holder', 'Control')
    generic_path = str(ROOT / 'BIT101-iOS/Generic.swift')
    generics = swift_syntax_index_sources({generic_path: '''
class Wrapper<T> { class Control: UIButton {}; class Holder<U> { class Control: UISwitch {} } }
typealias Native = Wrapper<(Int) -> Void>.Control
typealias Nested = Wrapper<[Int]>.Holder<String>.Control
struct Use { func build() { _ = Native(); _ = Nested() } }
'''})
    assert native_interaction_inventory(generics)['BIT101-iOS/Generic.swift:Use'] == {'UIButton': 1, 'UISwitch': 1}
    generic_fetch = swift_syntax_index_sources({generic_path: '''
class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }
class Wrapper<T> { struct Service { let cloud = ScheduleCloudSyncManager(); func start() async { await cloud.refreshFromCloudIfNeeded() } } }
typealias Service = Wrapper<(Int) -> Void>.Service
struct GenericApp: App { var body: some Scene { WindowGroup { Text("sample").task { await Service().start() } } } }
'''})
    assert len(automatic_school_fetch_findings(generic_fetch)) == 1
    from code_quality_rules import discarded_file_write_findings, file_write_calls
    ports = str(ROOT / 'Modules/SchedulePorts/Sources/ScheduleServicing.swift')
    storage = str(ROOT / 'Modules/StorageCore/Sources/AppFileService.swift')
    for parameter, constraint in [('S: ScheduleCourseServicing', ''), ('S', 'where S: ScheduleCourseServicing'),
                                  ('S: ScheduleCourseServicing & Sendable', ''), ('S, U: ScheduleCourseServicing', 'where S == U')]:
        source = f'struct Review<{parameter}>: View {constraint} {{ let service: S; var body: some View {{ Text("").task {{ await service.fetchCurrentTermOnly() }} }} }}'
        facts = swift_syntax_index_sources({generic_path: 'import SchedulePorts; ' + source,
            ports: 'public protocol ScheduleCourseServicing { func fetchCurrentTermOnly() async throws -> String }'})
        assert automatic_school_fetch_findings(facts), (parameter, constraint)
    for parameter, constraint in [('F: AppFileService', ''), ('F', 'where F: AppFileService'),
                                  ('F: AppFileService & Sendable', '')]:
        source = f'import StorageCore; func drop<{parameter}>(_ files: F) {constraint} {{ try? files.removeItem(at: url) }}'
        facts = swift_syntax_index_sources({generic_path: source,
            storage: 'public protocol AppFileService { func removeItem(at url: URL) throws }'})
        assert discarded_file_write_findings(Path(generic_path), source, facts[generic_path], file_write_calls(facts))
    shadowed = swift_syntax_index_sources({generic_path: 'import SchedulePorts; struct Review<S: ScheduleCourseServicing> { func local<S>(_ service: S) { service.fetchCurrentTermOnly() } }',
        ports: 'public protocol ScheduleCourseServicing { func fetchCurrentTermOnly() async throws -> String }'})
    from swift_type_index import SwiftBindingTypes
    bindings = SwiftBindingTypes(shadowed)
    call = next(call for call in shadowed[generic_path]['invocations'] if call['calledExpression'] == 'service.fetchCurrentTermOnly')
    assert not bindings.receiver_components(call, generic_path)
    extensions = swift_syntax_index_sources({'TestClass.swift': 'class Journey: XCTestCase {}',
        'TestMethods.swift': 'extension Journey { func testRoute() {} }'})
    assert [test['value'] for test in extensions['TestMethods.swift']['tests']] == ['Journey/testRoute']
    sources = {
        'Modules/AlphaFeature/Sources/Model.swift': 'public class Model: UIButton {}; public struct Screen: View {}; public typealias Native = Model; class TestHarness: XCTestCase { func testAlpha() {} }',
        'Modules/BetaCore/Sources/Model.swift': 'public class Model: Sendable {}; public struct Screen: Sendable {}; class TestHarness: Sendable { func testExample() {} }',
        'Modules/AlphaFeature/Sources/Use.swift': 'struct Use { func build() { _ = Model() } }',
        'Modules/BetaCore/Sources/Use.swift': 'struct Use { func build() { _ = Model() } }; extension Screen { func load() { _ = URLRequest(url: url) } }',
        'BIT101-iOS/PrivateA.swift': 'private class Model: UIButton {}; struct UseA { func build() { _ = Model() } }',
        'BIT101-iOS/PrivateB.swift': 'private class Model: Sendable {}; struct UseB { func build() { _ = Model() } }',
        'BIT101-iOS/Imported.swift': 'import AlphaFeature; struct Imported { func build() { _ = Native(); _ = AlphaFeature.Model() } }',
    }
    indexed = swift_syntax_index_sources({str(ROOT / path): source for path, source in sources.items()})
    types = SwiftTypeIndex(indexed)
    alpha = str(ROOT / 'Modules/AlphaFeature/Sources/Model.swift')
    beta = str(ROOT / 'Modules/BetaCore/Sources/Model.swift')
    assert types.conformances(alpha)[('Model',)] == {'UIButton'}
    assert types.conformances(beta)[('Model',)] == {'Sendable'}
    assert indexed[beta]['tests'] == []
    assert [test['value'] for test in indexed[alpha]['tests']] == ['TestHarness/testAlpha']
    assert ('AlphaFeature', 'Model') in declaration_conformances(indexed)
    use = str(ROOT / 'Modules/BetaCore/Sources/Use.swift')
    assert not ast_has_view_request(indexed[use], types.conformances(use), indexed)
    view = 'BIT101-iOS/RequestView.swift'
    other = 'Modules/Unrelated/Sources/Local.swift'
    for imported, exported, expected in [(False, False, True), (False, True, True), (True, False, True), (True, True, False)]:
        request_sources = {
            view: ('import Unrelated; ' if imported else '') + 'import Foundation; struct Screen: View { func load() { _ = URLRequest(url: url) } }',
            other: ('public ' if exported else '') + 'typealias URLRequest = LocalModel; public struct LocalModel {}',
        }
        requests = swift_syntax_index_sources(request_sources)
        assert ast_has_view_request(requests[view], context=requests) == expected, (imported, exported)
        request_sources[view] = request_sources[view].replace('URLRequest(url:', 'Foundation.URLRequest(url:')
        requests = swift_syntax_index_sources(request_sources)
        assert ast_has_view_request(requests[view], context=requests)
    for imported, exported in [(False, True), (True, False), (True, True)]:
        requests = swift_syntax_index_sources({
            view: ('import Unrelated; ' if imported else '') + 'struct Screen: View { func load() { _ = Request(url: url) } }',
            other: ('public ' if exported else '') + 'typealias Request = Foundation.URLRequest',
        })
        assert ast_has_view_request(requests[view], context=requests) == (imported and exported)
    for request, expected in [
        ('func load() { typealias URLRequest = Model; _ = URLRequest() }', False),
        ('func helper() { typealias URLRequest = Model }; func load() { _ = URLRequest(url: url) }', True),
        ('func load() { typealias Request = Foundation.URLRequest; _ = Request(url: url) }', True),
    ]:
        requests = swift_syntax_index_sources({view: 'struct Model {}; struct Screen: View { ' + request + ' }'})
        assert ast_has_view_request(requests[view], context=requests) == expected, request
    controls = native_interaction_inventory(indexed)
    assert controls['Modules/AlphaFeature/Sources/Use.swift:Use']['UIButton'] == 1
    assert controls['BIT101-iOS/PrivateA.swift:UseA']['UIButton'] == 1
    assert controls['BIT101-iOS/Imported.swift:Imported']['UIButton'] == 2
    assert all('BetaCore' not in key and 'PrivateB' not in key for key in controls)
    for module in ('AlphaFeature', 'BetaCore'):
        services = {
            'Modules/AlphaFeature/Sources/Service.swift': 'class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; public struct Model { let cloud = ScheduleCloudSyncManager(); public func start() async { await cloud.refreshFromCloudIfNeeded() } }; public enum Factory { public static func make() -> Model { Model() } }',
            'Modules/BetaCore/Sources/Service.swift': 'public struct Model { public func start() async {} }; public enum Factory { public static func make() -> Model { Model() } }',
            'BIT101-iOS/App.swift': f'import {module}; struct SampleApp: App {{ var body: some Scene {{ WindowGroup {{ Text("sample").task {{ await Factory.make().start() }} }} }} }}',
        }
        facts = swift_syntax_index_sources({str(ROOT / path): source for path, source in services.items()})
        assert bool(automatic_school_fetch_findings(facts)) == (module == 'AlphaFeature')
    private_sources = {
        'BIT101-iOS/First.swift': 'class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; private struct Model { let cloud = ScheduleCloudSyncManager(); func start() async { await cloud.refreshFromCloudIfNeeded() } }; private enum Factory { static func make() -> Model { Model() } }; struct FirstApp: App { var body: some Scene { WindowGroup { Text("sample").task { await Factory.make().start() } } } }',
        'BIT101-iOS/Second.swift': 'private struct Model { func start() async {} }; private enum Factory { static func make() -> Model { Model() } }; struct SecondApp: App { var body: some Scene { WindowGroup { Text("sample").task { await Factory.make().start() } } } }',
    }
    facts = swift_syntax_index_sources({str(ROOT / path): source for path, source in private_sources.items()})
    issues = automatic_school_fetch_findings(facts)
    assert len(issues) == 1 and 'FirstApp' in issues[0]


def asynchronous_wait_self_test(wait_path) -> None:
    from code_quality_rules import ROOT, asynchronous_test_wait_findings
    from swift_source_index import swift_syntax_index_sources
    findings = []
    for body, expected in (
        ('while pending == nil { await Task.yield() }', 1),
        ('while true { try? await Task.sleep(for: .milliseconds(10)) }', 1), ('while !done { try? await Task.sleep(for: .milliseconds(10)) }', 1), ('while true { try await Task.sleep(for: .milliseconds(10)) }', 0),
        ('while pending == nil { try Task.checkCancellation(); await Task.yield() }', 1),
        ('try await waitForTestEvent { pending != nil }', 0),
        ('for _ in 0..<3 { await Task.yield() }', 0),
        ('while pending == nil { consume("Task.yield()") }', 0),
        ('await withCheckedContinuation { response = $0 }', 0),
    ):
        source = 'func testEvent() async throws { ' + body + ' }'
        facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
        if len(asynchronous_test_wait_findings(wait_path, source, facts)) != expected:
            findings.append('异步事件等待自测：取消检查与有限等待入口需要共同验收')
    for body, expected in (('await withCheckedContinuation { started = $0 }', 1),
                           ('try await waitForTestEvent { pending != nil }', 0)):
        source = 'func waitUntilRequested() async throws { ' + body + ' }'
        facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
        if len(asynchronous_test_wait_findings(wait_path, source, facts)) != expected:
            findings.append('异步事件观察自测：请求到达门闩沿共享期限与取消入口验收')
    for body in ('await helper.receive()', '_ = await iterator.next()', 'for await event in events { if event { break } }',
                 'let pending = Task { await helper.request() }; await pending.value',
                 'let pending = Task { await helper.request() }; #expect(await pending.value == 41)',
                 'let pending = Task { await helper.request() }; await pending?.value',
                 'await sync.refreshFromCloudIfNeeded()?.value', 'await (pending).value',
                 'await withTaskCancellationHandler { await withCheckedContinuation { started = $0 } } onCancel: { release() }'):
        for attribute, expected in (('@Test', 1), ('@Test(.timeLimit(.minutes(1)))', 0)):
            source = attribute + ' func eventReceipt() async { ' + body + ' }'
            facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
            assert len(asynchronous_test_wait_findings(wait_path, source, facts)) == expected
            source = '@Suite(.timeLimit(.minutes(1))) struct Outer { @Suite struct Inner { ' + source + ' } }'
            facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
            assert asynchronous_test_wait_findings(wait_path, source, facts) == []
    for limit, expected in (('', 1), ('.timeLimit(.minutes(1))', 0)):
        source = '@Suite(' + limit + ') struct Case { @Test func hangs() async { await forward() }; func forward() async { await observeEvent() }; func observeEvent() async { await withCheckedContinuation { continuation in } } }'
        facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
        assert len(asynchronous_test_wait_findings(wait_path, source, facts)) == expected
    source = '@Test func hangs() async { let ignored = TimeLimitTrait.timeLimit(.minutes(1)); await withCheckedContinuation { continuation in } }'
    facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
    assert len(asynchronous_test_wait_findings(wait_path, source, facts)) == 2
    for body in ('await withCheckedContinuation { started = $0 }', 'if ready { await withCheckedContinuation { started = $0 } }', 'try await withCheckedThrowingContinuation { started = $0 }'):
        source = '@Test(.timeLimit(.minutes(1))) func timerFires() async { ' + body + ' }'
        facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
        assert len(asynchronous_test_wait_findings(wait_path, source, facts)) == 1
    source = '@Test(.timeLimit(.minutes(1))) func fixture() async throws { let client = Client { await withCheckedContinuation { gate = $0 } }; try await waitForTestEvent { gate != nil } }'
    facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
    assert asynchronous_test_wait_findings(wait_path, source, facts) == []
    support = ROOT / 'ModuleTests/Support/FileServiceContract.swift'
    source = support.read_text()
    facts = swift_syntax_index_sources({str(support): source})[str(support)]
    if asynchronous_test_wait_findings(support, source, facts):
        findings.append('异步事件等待自测：共享等待实现沿行为回归验收')
    source += '\nfunc other() async { while pending == nil { await Task.yield() } }\n'
    facts = swift_syntax_index_sources({str(support): source})[str(support)]
    if len(asynchronous_test_wait_findings(support, source, facts)) != 1:
        findings.append('异步事件等待自测：共享文件中的其他函数遵循调用入口')
    assert findings == [], findings


def collection_callback_self_test() -> None:
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls
    for setup, body, expected in (
            ('let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]', 'for action in actions { try await action() }', True),
            ('let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]', 'for action in actions { _ = action }', False),
            ('let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]', 'if false { for action in actions { try await action() } }', False),
            ('let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]', 'for action in actions { let action = {}; action() }', False),
            ('let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]; let copy = actions', 'for action in copy { try await action() }', True),
            ('', 'for action in [{ _ = try await client.send(request) }] { try await action() }', True)):
        setup = setup + ';' if setup else ''
        source = f'public struct Service {{ let client: HTTPClient; let request: URLRequest; public func load() async throws {{ {setup} {body} }} }}'
        methods = business_methods(swift_syntax_index_sources({'Modules/CourseFeature/Sources/Service.swift': source}))
        assert any(function['name'] == 'load' for rows in methods.values() for _, function in rows) == expected, (body, methods)
        runtime = source.replace('Service', 'ReleaseNetworkSmokeRunner').replace('func load()', 'func run()')
        calls = reachable_smoke_calls(swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': runtime}))['network']
        assert any(call['calledExpression'] == 'client.send' for call in calls) == expected, (body, calls)
    source = '''struct ReleaseNetworkSmokeRunner {
        func run() async {
            var actions: [@MainActor () async -> Void] = [{ await service.first() }, { await service.second() }]
            for item in Kind.allCases { actions.append { await service.third(item) } }
            if false { actions.append { await service.idle() } }
            await runInParallel(actions)
        }
        func runInParallel(_ operations: [@MainActor () async -> Void]) async {
            await withTaskGroup(of: Void.self) { group in
                for operation in operations { group.addTask { await operation() } }
            }
        }
    }'''
    for invocation, expected in [('await runInParallel(actions)', {'service.first', 'service.second', 'service.third'}),
                                 ('_ = actions', set())]:
        index = swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': source.replace('await runInParallel(actions)', invocation)})
        expressions = {call['calledExpression'] for call in reachable_smoke_calls(index)['network']}
        assert expressions & {'service.first', 'service.second', 'service.third', 'service.idle'} == expected, expressions


def network_composition_self_test() -> None:
    from network_capability_rules import business_methods
    path = 'Modules/ClientCore/Sources/Composition.swift'
    transport = 'Modules/TransportCore/Sources/HTTPClient.swift'
    for body, expected in [('self.transport = transport', False),
                           ('self.transport = transport; Task { _ = try await transport.data(for: request) }', True)]:
        sources = {transport: 'public struct HTTPClient { let transport: HTTPTransport; public init(transport: HTTPTransport) { ' + body + ' } }',
            path: 'import TransportCore; public struct Composition { public func build(transport: HTTPTransport) { _ = HTTPClient(transport: transport) } }'}
        assert ('ClientCore.Composition' in business_methods(swift_syntax_index_sources(sources))) == expected, body
    for declaration, expected in [('extension View { func helper() {} }', False), ('protocol View {}', True)]:
        source = declaration + '; public struct Screen: View { public func load() { Task { _ = try await URLSession.shared.data(from: url) } } }'
        assert bool(business_methods(swift_syntax_index_sources({'BIT101-iOS/Screen.swift': source}))) == expected, declaration
    import runpy
    rules = runpy.run_path(str(ROOT / 'Scripts/check-module-boundaries.py'))
    for owner, permitted in [('GalleryWebCoordinator', True), ('GalleryRootViewScene.GalleryWebView', True), ('OtherView', False)]:
        parts = owner.split('.')
        source = 'struct ' + parts[0] + ' { ' + ('struct ' + parts[1] + ' { ' if len(parts) == 2 else '')
        source += 'func make() { _ = WKWebView() }' + ' }' * len(parts)
        errors = rules['service_boundary_errors']('Modules/GalleryFeature/Sources/GalleryRootView.swift', source)
        assert bool(errors) != permitted, (owner, errors)
    source = 'struct GalleryWebCoordinator { func make() { _ = URLSession(configuration: configuration) } }'
    assert rules['service_boundary_errors']('Modules/GalleryFeature/Sources/GalleryRootView.swift', source)
    source = '''public struct Service {
        private let loadData: (URLRequest) async throws -> Data
        public init(loadData: @escaping (URLRequest) async throws -> Data = {
            try await URLSession.shared.data(for: $0).0
        }) { self.loadData = loadData }
        public func fetch(request: URLRequest) async throws -> Data { try await loadData(request) }
    }'''
    from network_capability_rules import method_signature
    methods = business_methods(swift_syntax_index_sources({path: source}))
    assert {method_signature(function) for rows in methods.values() for _, function in rows} == {'fetch(request:URLRequest)'}, methods
    source = source.replace('loadData', 'download').replace('(URLRequest)', '(URL)')
    methods = business_methods(swift_syntax_index_sources({path: source}))
    assert {function['name'] for rows in methods.values() for _, function in rows} == {'fetch'}, methods
    from validation_test_areas import reachable_smoke_calls
    for returned in ('Self(create: create)', 'self'):
        source = '''struct ReleaseNetworkSmokeRunner { struct Operations { var create: () -> Void
            func scoped() -> Self { RETURNED } }
            func run() { let original = Operations(create: { service.live() })
                let operations = original.scoped(); operations.create() }
        }'''.replace('RETURNED', returned)
        calls = reachable_smoke_calls(swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': source}))['network']
        assert any(call['calledExpression'] == 'service.live' for call in calls), returned


def standard_callback_self_test() -> None:
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls
    for name in ('withCheckedContinuation', 'withCheckedThrowingContinuation', 'withUnsafeContinuation',
                 'withUnsafeThrowingContinuation', 'autoreleasepool', 'withUnsafePointer', 'withUnsafeMutablePointer',
                 'withUnsafeTemporaryAllocation', 'data.withUnsafeBytes', 'data.withUnsafeMutableBytes',
                 'data.withUnsafeBufferPointer', 'data.withUnsafeMutableBufferPointer'):
        for conditional, expected in (('', True), ('if false', False)):
            body = f'{name} {{ Task {{ _ = try? await client.send(request) }} }}'
            if conditional: body = conditional + ' { ' + body + ' }'
            source = 'public struct Service { let client: HTTPClient; let request: URLRequest; public func load() async { ' + body + ' } }'
            methods = business_methods(swift_syntax_index_sources({'Modules/CourseFeature/Sources/Service.swift': source}))
            assert any(function['name'] == 'load' for rows in methods.values() for _, function in rows) == expected, name
            source = source.replace('Service', 'ReleaseNetworkSmokeRunner').replace('func load()', 'func run()')
            calls = reachable_smoke_calls(swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': source}))['network']
            assert any(call['calledExpression'] == 'client.send' for call in calls) == expected, (name, calls)


def extension_protocol_self_test() -> None:
    for imported in (False, True):
        sources = {'Modules/SupportCore/Sources/Protocols.swift': 'public protocol ParentProtocol {}; public protocol ChildProtocol: ParentProtocol {}',
            'Modules/CourseFeature/Sources/Loader.swift': 'public struct Loader {}',
            'Modules/CourseFeature/Sources/LoaderPort.swift': ('import SupportCore; ' if imported else '') + 'extension Loader: ChildProtocol {}'}
        index = swift_syntax_index_sources(sources)
        types = SwiftTypeIndex(index)
        bases = types.conformances('Modules/CourseFeature/Sources/Loader.swift')[('Loader',)]
        assert ('ParentProtocol' in bases) == imported, (imported, bases)
        assert 'ChildProtocol' in bases


def literal_masking_self_test() -> None:
    from unittest.mock import patch
    from swift_source_index import swift_code
    source = 'let address = "https://literal-boundary.example/path"; /* /comment/ */\nlet value = 1'
    with patch('swift_source_index._run_swift_syntax_index', side_effect=AssertionError('文字与注释沿词法边界处理')):
        masked = swift_code(source)
    assert 'literal-boundary' not in masked and masked.endswith('let value = 1')
    expression = 'let expression = #/a"//b/#; let value = 1'
    masked = swift_code(expression)
    assert 'let expression =' in masked and masked.endswith('; let value = 1') and 'a"//b' not in masked


def foundation_collection_self_test(service_boundary_errors) -> None:
    literal_masking_self_test()
    from network_capability_rules import business_methods
    path = 'Modules/CommunityPersistence/Sources/Store.swift'
    reader_path = 'Modules/StorageCore/Sources/AppFileService.swift'
    callbacks = "func collect(read: () -> Int, write: (Int) -> Void) { write(read()) }; func run() { collect(read: { 1 }, write: { _ in }) }"
    assert not service_boundary_errors(path, callbacks)
    assert service_boundary_errors(path, callbacks + "; func unsafe() { _ = Darwin.read(0, nil, 0) }")
    aliases = 'let openSocket = Darwin.socket; let sendBytes = Glibc.send'
    facts = swift_syntax_index_sources({path: aliases})[path]
    assert all(member['isExpressionReference'] for member in facts['members'])
    assert service_boundary_errors(path, aliases)
    for kind in ('NSDictionary', 'NSMutableDictionary', 'NSArray', 'NSMutableArray'):
        for body in (
                f'_ = {kind}(contentsOf: url)', f'_ = Foundation.{kind}.init(contentsOfFile: file)',
                f'_ = Foundation.{kind}.self.init(contentsOf: url)',
                'let value = Collection(contentsOf: url)', f'let value: {kind}? = .init(contentsOf: url)',
                f'_ = value.write(to: url)', f'_ = value.write(toFile: file, atomically: true)',
                'let write = value.write(to:atomically:)',
                f'let read: (URL) -> {kind}? = {kind}.init(contentsOf:)'):
            source = (f'import Foundation; typealias Collection = Foundation.{kind}; public struct Store {{ '
                + f'public func fetch(_ url: URL, file: String, value: {kind}) throws {{ {body} }} }}')
            assert service_boundary_errors(path, source), (kind, body)
            approved = source.replace('struct Store', 'struct LocalAppFileService')
            assert service_boundary_errors(reader_path, approved) == [], (kind, body)
        for body in (f'_ = {kind}(contentsOf: url)', 'let value = Collection(contentsOf: url)',
                f'let value: {kind}? = .init(contentsOf: url)',
                f'let read: (URL) -> {kind}? = {kind}.init(contentsOf:); _ = read(url)'):
            for guard, expected in (('', True), ('guard url.isFileURL else { return };', False)):
                source = (f'import Foundation; typealias Collection = Foundation.{kind}; public struct LocalAppFileService {{ '
                    + f'public func fetch(_ url: URL) {{ {guard} {body} }} }}')
                assert bool(business_methods(swift_syntax_index_sources({reader_path: source}))) == expected, (kind, body, guard)
        for body in (f'_ = {kind}(contentsOfFile: file)',
                f'let read: (URL) -> {kind}? = {kind}.init(contentsOf:)',
                f'_ = value.write(to: url)'):
            source = (f'import Foundation; public struct LocalAppFileService {{ public func fetch(_ url: URL, '
                + f'file: String, value: {kind}) {{ {body} }} }}')
            assert business_methods(swift_syntax_index_sources({reader_path: source})) == {}, (kind, body)
        for calls, expected in (('read(url)', False), ('read(other)', True), ('read(url); read(other)', True)):
            source = (f'import Foundation; public struct LocalAppFileService {{ public func fetch(_ url: URL, other: URL) {{ '
                + f'let read: (URL) -> {kind}? = {kind}.init(contentsOf:); guard url.isFileURL else {{ return }}; {calls} }} }}')
            assert bool(business_methods(swift_syntax_index_sources({reader_path: source}))) == expected, (kind, calls)
        source = (f'struct {kind} {{ init(contentsOf url: URL) {{}}; func write(to url: URL) {{}} }}; '
            + f'public struct Store {{ public func fetch(_ url: URL, value: {kind}) {{ '
            + f'_ = {kind}(contentsOf: url); value.write(to: url) }} }}')
        assert service_boundary_errors(path, source) == [], kind
        assert business_methods(swift_syntax_index_sources({path: source})) == {}, kind


def resource_audit_execution_self_test(rules) -> None:
    from unittest.mock import patch
    import swift_source_index
    import network_capability_rules
    artwork = 'Modules/GalleryFeature/Sources/Artwork.swift'
    for expression in ('AsyncImage(url: url)', 'SwiftUI.AsyncImage(url: url)',
            'let load = AsyncImage.self; load(url: url)'):
        source = 'import SwiftUI; struct Artwork: View { let url: URL; var body: some View { ' + expression + ' } }'
        errors = rules['service_boundary_errors'](artwork, source)
        assert any('load remote images through MediaKit' in error for error in errors), expression
    source = 'struct AsyncImage { init(url: URL) {} }; struct Artwork { func make(url: URL) { _ = AsyncImage(url: url) } }'
    assert rules['service_boundary_errors'](artwork, source) == []
    source = 'public struct Local {\n' + '\n'.join(
        f'func hop{i}() {{ hop{i + 1}(); hop{i + 1}() }}' for i in range(12)) + '\nfunc hop12() {} }'
    with patch.object(network_capability_rules, 'call_can_execute', wraps=network_capability_rules.call_can_execute) as execute:
        assert network_capability_rules.business_methods(swift_syntax_index_sources({
            'Modules/CourseInfrastructure/Sources/Local.swift': source})) == {}
    assert execute.call_count < 13 ** 2 * 2, execute.call_count
    from swift_type_index import custom_constant_symbols
    facts = {'source': 'func load() {}'}
    assert not custom_constant_symbols(facts)
    facts['source'] = 'func load<Int>() {}'
    assert custom_constant_symbols(facts)
    facts['source'] = 'func load() {}'
    facts['functionRanges'] = [{'name': '=='}]
    assert custom_constant_symbols(facts)
    facts['functionRanges'] = []
    facts['typeAliases'] = [{'name': 'Bool'}]
    assert custom_constant_symbols(facts)
    facts['typeAliases'] = []
    assert not custom_constant_symbols(facts)
    import swift_type_index
    path = 'Modules/CourseInfrastructure/Sources/Store.swift'
    source = ('struct NetworkPort {}; struct OtherPort {}; struct Store { let client: NetworkPort; '
        'func load() { let client = OtherPort(); client.send(); self.client.send() } }')
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    calls = [dict(call, path=path) for call in index[path]['invocations'] if call['calledExpression'].endswith('.send')]
    with patch.object(swift_type_index, 'visible_variables', wraps=swift_type_index.visible_variables) as lookup:
        for _ in range(10):
            assert resolve(calls[0]).endswith('.OtherPort')
            assert resolve(calls[1]).endswith('.NetworkPort')
    assert lookup.call_count <= 3, lookup.call_count
    source = ('struct Port {}; struct Owner { static let provider = Port(); static let client = provider; '
        'func inspect() { let client = foreignValue; client.send(); Self.client.send() } }')
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    calls = [dict(call, path=path) for call in index[path]['invocations'] if call['calledExpression'].endswith('.send')]
    assert resolve(calls[0]) is None
    assert resolve(calls[1]).endswith('.Port')
    source = ('struct Port {}; protocol Placeholder {}; struct Owner { var client: Placeholder?; '
        'func configure() { let source = Port(); client = source }; '
        'func inspect() { guard let client = client else { return }; client.send() } }')
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    call = next(call for call in index[path]['invocations'] if call['calledExpression'] == 'client.send')
    assert resolve(dict(call, path=path)).endswith('.Port')
    source = ('protocol Placeholder {}; struct OtherPort {}; struct Owner { var client: Placeholder; '
        'func inspect() { var other = foreignValue; let value = OtherPort(); other.client = value; client.send() } }')
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    call = next(call for call in index[path]['invocations'] if call['calledExpression'] == 'client.send')
    assert resolve(dict(call, path=path)).endswith('.Placeholder')
    source = ('protocol Placeholder {}; struct OtherPort {}; struct Owner { var client: Placeholder; '
        'func inspect(client: Placeholder) { let other = OtherPort(); self.client = other; client.send() } }')
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    call = next(call for call in index[path]['invocations'] if call['calledExpression'] == 'client.send')
    assert resolve(dict(call, path=path)).endswith('.Placeholder')
    source = ('// 中文 / source prefix\nstruct Reader { '
        'func fetch(_ url: URL, first: Data, second: NSArray) { '
        'let ignored = #/NSData(contentsOf: url)/#; _ = Data(contentsOf: url) } }')
    with patch.object(swift_source_index, '_run_swift_syntax_index', wraps=swift_source_index._run_swift_syntax_index) as parser:
        errors = rules['service_boundary_errors']('Modules/CommunityPersistence/Sources/Reader.swift', source)
    assert len(errors) == 1, errors
    assert sum(bool(call.kwargs.get('regex_only')) for call in parser.call_args_list) <= 1, parser.call_count
    effects = 'BIT101-iOS/Effects.swift'
    helpers = 'BIT101-iOS/Helpers.swift'
    for custom_path, imported in ((None, ''), ('BIT101-iOS/Operators.swift', ''),
            ('Modules/SupportCore/Sources/Operators.swift', 'import SupportCore; ')):
        sources = {effects: imported + 'struct AppScheduleCacheEffects { func changed() { if 1 == 2 { loadAccountStorage() } } }',
            helpers: 'func loadAccountStorage() { AppAccountSession.storage }'}
        if custom_path: sources[custom_path] = 'func == (lhs: Int, rhs: Int) -> Bool { true }'
        index = swift_syntax_index_sources(sources)
        roles = rules['adapter_call_roles'](index)
        errors = rules['adapter_ownership_errors'](index[helpers], helpers,
            rules['adapter_roles'](index, helpers), call_roles=roles)
        assert bool(errors) == bool(custom_path), (custom_path, errors)
