"""Regression cases for the module and resource ownership rules."""
import re
from pathlib import Path


def callable_network_api_self_test(rules: dict) -> None:
    from network_capability_rules import business_methods, matching_api_calls, method_signature
    from validation_test_areas import network_capability_findings
    path = 'Modules/NewForumFeature/Sources/ClosureService.swift'
    for body, expected in [
        ('public var fetch: () async throws -> HTTPResponse; public init(http: HTTPClient, request: URLRequest) { fetch = { try await http.send(request) } }', True),
        ('public var fetch: (URLRequest) async throws -> HTTPResponse = { request in try await HTTPClient().send(request) }', True),
        ('public var fetch = { try await HTTPClient().send(request) }', True),
        ('private var fetch = { try await HTTPClient().send(request) }', False),
        ('public var fetch = { 1 }; public init(http: HTTPClient, request: URLRequest) { let fetch = { try await http.send(request) } }', False),
        ('public func make(http: HTTPClient, request: URLRequest) -> () async throws -> HTTPResponse { { try await http.send(request) } }', True),
        ('public var fetch: () async -> Int { { 1 } }', False),
    ]:
        source = 'import TransportCore; public struct ClosureService { ' + body + ' }'
        index = rules['swift_syntax_index_sources']({path: source,
            'Modules/TransportCore/Sources/HTTPClient.swift': 'public struct HTTPClient {}'})
        methods = business_methods(index)
        assert bool(methods) == expected, (body, methods)
        if expected:
            assert network_capability_findings(index), body
            functions = methods['NewForumFeature.ClosureService']
            for _, function in functions:
                arguments = ['request'] * len(function.get('parameters', []))
                call = dict(path=path, calledExpression='service.' + function['name'], scope=[], start=len(source.encode()),
                    arguments=arguments, argumentLabels=[''] * len(arguments))
                if function['name'] == 'make': call['argumentLabels'] = ['http', 'request']
                assert matching_api_calls(index, functions, call), (body, method_signature(function))
                call['isMemberRead'] = True
                assert matching_api_calls(index, functions, call) == [], body

    from network_capability_rules import NETWORK_HARNESS_TYPES
    for registration, expected in (('UIView.animate(withDuration: 1, animations: {}) { _ in BODY }', True),
            ('animator.addCompletion { _ in BODY }', True), ('framework.registerCallback { BODY }', True),
            ('ExternalExecutor { BODY }', True), ('DispatchWorkItem { BODY }', False),
            ('storeCallback { BODY }', False)):
        source = 'import UIKit; import Foundation; func storeCallback(_ callback: () -> Void) {};' \
            + ' public struct CallbackService { public func fetch() { ' + registration.replace('BODY',
                'Task { _ = try await URLSession.shared.data(from: url) }') + ' } }'
        index = rules['swift_syntax_index_sources']({path: source})
        assert bool(business_methods(index)) == expected, source
    for function in ('connectx', 'disconnectx', 'sendfile', 'sockatmark'):
        for prefix, expression, expected in (('', function + '(1)', True), ('', 'Darwin.' + function + '(1)', True),
                ('func ' + function + '(_ value: Int) {}; ', function + '(1)', False)):
            source = 'import Darwin; ' + prefix + 'public struct SocketService { public func fetch() { ' + expression + ' } }'
            index = rules['swift_syntax_index_sources']({path: source})
            assert bool(rules['service_boundary_errors'](path, source)) == expected, source
            assert bool(business_methods(index)) == expected, source
    for kind, method in (('NetService', 'publish()'), ('NetService', 'resolve(withTimeout: 1)'),
            ('NetService', 'startMonitoring()'), ('NetServiceBrowser', 'searchForServices(ofType: "_http._tcp", inDomain: "local.")')):
        for declared, expected in (('Foundation.' + kind, True), (kind, True), ('Local', False)):
            source = 'import Foundation; struct Local { func ' + method.split('(')[0] + '() {} }; public struct BonjourService { public func fetch(service: ' + declared + ') { service.' + method + ' } }'
            index = rules['swift_syntax_index_sources']({path: source})
            assert bool(rules['service_boundary_errors'](path, source)) == expected, source
            assert bool(business_methods(index)) == expected, source
    for owner, harness_path in NETWORK_HARNESS_TYPES.items():
        name = owner.split('.')[-1]
        body = 'import TransportCore; public struct ' + name + ' { let http: HTTPClient; public func fetch(request: URLRequest) async throws -> HTTPResponse { try await http.send(request) } }'
        for selected_path, guarded, exempt in ((harness_path, True, True), (harness_path, False, False),
                ('BIT101-iOS/Shared/Client/OtherService.swift', True, False), (path, True, False)):
            source = '#if DEBUG || RELEASE_NETWORK_SMOKE\n' + body + '\n#endif' if guarded else body
            index = rules['swift_syntax_index_sources']({selected_path: source,
                'Modules/TransportCore/Sources/HTTPClient.swift': 'public struct HTTPClient {}'})
            assert bool(business_methods(index)) != exempt, (owner, selected_path, guarded, business_methods(index))


def build_cache_exit_self_test() -> list[str]:
    import subprocess
    source = (Path(__file__).parent / 'script-support.sh').read_text()
    cache = 'bit101_build_cache() {' + source.split('bit101_build_cache() {', 1)[1].split('\nbit101_run_logged()', 1)[0]
    findings = []
    for status in (0, 79):
        for maintenance in ('', '--maintenance'):
            harness = f'python3() {{ print CALL; return {status}; }}\n' + cache \
                + '\nif bit101_build_cache ' + maintenance + '; then exit 0; else exit $?; fi'
            result = subprocess.run(['zsh', '-c', harness], capture_output=True, text=True)
            if result.returncode != status or result.stdout.count('CALL') != (2 if maintenance and status == 0 else 1):
                findings.append('构建缓存委托需要在条件调用中保留编译失败，并沿成功状态执行缓存维护。')
    return findings


def streaming_transport_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods
    from code_quality_rules import ROOT, view_transport_findings
    for expression in ('session.bytes(for: request)', 'session.bytes(from: url)', 'session.bytes(for:)'):
        for kind, expected in (('URLSession', True), ('Local', False)):
            declarations = 'import Foundation; struct Local { func bytes(for request: URLRequest) async {} }; '
            body = 'let session: ' + kind + '; public func fetch() { Task { _ = try await ' + expression + ' } }'
            service = swift_syntax_index_sources({'Modules/NewForumFeature/Sources/Service.swift':
                declarations + 'public struct Service { ' + body + ' }'})
            assert bool(business_methods(service)) == expected, (expression, kind)
            view = swift_syntax_index_sources({str(ROOT / 'BIT101-iOS/Example.swift'): declarations +
                'struct Example: View { let session: ' + kind + '; var body: some View { Text("").task { _ = try await ' + expression + ' } } }'})
            assert bool(view_transport_findings(view)) == expected, (expression, kind)


def stream_network_self_test(rules: dict) -> None:
    from network_capability_rules import business_methods
    from validation_test_areas import network_capability_findings
    path = 'Modules/NewForumFeature/Sources/StreamService.swift'
    operation = 'var input: InputStream?; var output: OutputStream?; %s.getStreamsToHost(withName: "example.invalid", port: 443, inputStream: &input, outputStream: &output); input?.open(); output?.open()'
    for prefix, receiver, expected in (
            ('', 'Stream', True), ('', 'Foundation.Stream', True),
            ('typealias Socket = Foundation.Stream;', 'Socket', True), ('let Socket = Stream.self;', 'Socket', True),
            ('class Socket: Foundation.Stream {};', 'Socket', True),
            ('struct Stream { static func getStreamsToHost(withName: String, port: Int, inputStream: inout InputStream?, outputStream: inout OutputStream?) {} };', 'Stream', False)):
        source = 'import Foundation; ' + prefix + ' public struct StreamService { public func connect() { ' + operation % receiver + ' } }'
        index = rules['swift_syntax_index_sources']({path: source})
        assert bool(rules['service_boundary_errors'](path, source)) == expected, source
        assert bool(business_methods(index)) == expected, source
        assert any('NewForumFeature.StreamService' in row for row in network_capability_findings(index)) == expected, source
    for operation in ('let input = InputStream(data: Data()); input.open()',
            'var input: InputStream?; var output: OutputStream?; Stream.getBoundStreams(withBufferSize: 100, inputStream: &input, outputStream: &output)'):
        source = 'import Foundation; public struct StreamService { public func connect() { ' + operation + ' } }'
        index = rules['swift_syntax_index_sources']({path: source})
        assert rules['service_boundary_errors'](path, source) == [], source
        assert business_methods(index) == {}, source
    source = 'import Foundation; let Socket = Stream.self; struct LocalStream { func getStreamsToHost() {} }; public struct StreamService { public func connect(Socket: LocalStream) { Socket.getStreamsToHost() } }'
    index = rules['swift_syntax_index_sources']({path: source})
    assert rules['service_boundary_errors'](path, source) == [], source
    assert business_methods(index) == {}, source


def subprocess_resource_self_test(rules: dict) -> None:
    path = 'Modules/SampleDomain/Sources/Service.swift'
    for expression in ('let process = Foundation.Process(); try process.run()',
            'let process = NSTask(); process.launch()', 'typealias Runner = Foundation.Process; let process = Runner()',
            'let kind = Process.self; let process = kind.init()',
            'system("curl https://example.invalid")', 'Darwin.posix_spawn(nil, nil, nil, nil, nil, nil)',
            'let execute = system; execute("curl https://example.invalid")'):
        assert rules['service_boundary_errors'](path, expression), expression
    for source in ('struct Process { func run() {} }; let value = Process(); value.run()',
            'struct NSTask { func launch() {} }; let value = NSTask(); value.launch()',
            'func system(_ value: String) {}; system("literal")', 'let identifier = ProcessInfo.processInfo.processIdentifier'):
        assert not rules['service_boundary_errors'](path, source), source


def local_resource_self_test(rules: dict) -> None:
    from swift_type_index import SwiftBindingTypes
    path = 'Modules/PaperFeature/Sources/Probe.swift'
    for name, access in (('FileManager', 'default'), ('UserDefaults', 'standard'), ('URLCache', 'shared')):
        declaration = f'struct {name} {{ static let `{access}` = {name}() }}'
        expression = f'let local = {name}.{access}'
        for sources in ({path: declaration + '; ' + expression},
                {path: expression, 'Modules/PaperFeature/Sources/Memory.swift': declaration},
                {path: 'struct Scope { ' + declaration + '; func run() { ' + expression + ' } }'}):
            context = SwiftBindingTypes(rules['swift_syntax_index_sources'](sources))
            source = sources[path]
            assert rules['service_boundary_errors'](path, source, call_context=context) == [], (name, sources)
            assert rules['ownership_errors']('PaperFeature', source, path, call_context=context) == [], (name, sources)
            real = source + f'; let actual = Foundation.{name}.{access}'
            assert rules['service_boundary_errors'](path, real, call_context=context), name
            assert rules['ownership_errors']('PaperFeature', real, path, call_context=context), name
        if name == 'UserDefaults':
            for use in ('let value: UserDefaults = .standard', 'let value: UserDefaults = .init()',
                    'func consume(_ value: UserDefaults) {}; consume(.standard)'):
                source = declaration + '; ' + use
                assert rules['service_boundary_errors'](path, source) == [], use
                assert rules['ownership_errors']('PaperFeature', source, path) == [], use
        alias = f'typealias {name} = Foundation.{name}; {expression}'
        assert rules['service_boundary_errors'](path, alias), name
        assert rules['ownership_errors']('PaperFeature', alias, path), name
    source = 'class FileManager: Foundation.FileManager {}; let value = FileManager.default'
    assert rules['service_boundary_errors'](path, source)
    assert rules['ownership_errors']('PaperFeature', source, path)
    source = 'extension UserDefaults { static func make() -> UserDefaults { .standard } }'
    assert rules['service_boundary_errors'](path, source)
    assert rules['ownership_errors']('PaperFeature', source, path)
    for kind in ('UserDefaults', 'Foundation.UserDefaults'):
        sources = {path: 'extension Probe { func run() { value = .standard } }',
            'Modules/PaperFeature/Sources/Memory.swift': 'struct UserDefaults { static let standard = UserDefaults() }; struct Probe { var value: ' + kind + ' }'}
        index = rules['swift_syntax_index_sources'](sources)
        context = SwiftBindingTypes(index)
        unit = rules['compilation_type_context'](index, path)
        assert bool(rules['service_boundary_errors'](path, sources[path], context=unit, call_context=context)) == kind.startswith('Foundation.')
        assert bool(rules['ownership_errors']('PaperFeature', sources[path], path, properties=unit[0], call_context=context)) == kind.startswith('Foundation.')
    for method in ('resourceValues', 'setResourceValues', 'getResourceValue', 'setResourceValue', 'resolvingSymlinksInPath', 'checkResourceIsReachable'):
        declaration = f'struct Preferences {{ func {method}(forKeys keys: [Int]) {{}} }}'
        source = declaration + f'; func run(preferences: Preferences) {{ preferences.{method}(forKeys: []) }}'
        assert rules['service_boundary_errors'](path, source) == [], method
        source += f'; func real(url: Foundation.URL) {{ url.{method}(forKeys: []) }}'
        assert rules['service_boundary_errors'](path, source), method


def manifest_lock_self_test(read_manifest) -> None:
    import fcntl
    import os
    import subprocess
    from threading import Event, Thread
    from types import SimpleNamespace
    from unittest.mock import patch
    import shutil
    root = Path(__file__).resolve().parents[1] / '.build/static-audit/module-manifest-lock'
    root.mkdir(parents=True, exist_ok=True)
    try:
        for name, inherited in (('.build/extended-automation.lock', False),
                                ('.build/compiler-cache/cache.lock', False),
                                ('.build/extended-automation.lock', True)):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            called = Event()
            completed = Event()
            errors = []
            def evaluate():
                try:
                    assert read_manifest(root) == {'targets': []}
                except BaseException as error:
                    errors.append(error)
                finally:
                    completed.set()
            def compile_manifest(*args, **kwargs):
                called.set()
                return SimpleNamespace(returncode=0, stdout='{"targets": []}', stderr='')
            with path.open('a') as owner, patch.dict(os.environ,
                    BIT101_EXTENDED_TESTS_LOCK_HELD='1' if inherited else '0'), \
                    patch.object(subprocess, 'run', side_effect=compile_manifest):
                fcntl.flock(owner, fcntl.LOCK_EX)
                worker = Thread(target=evaluate, daemon=True)
                worker.start()
                try:
                    assert called.wait(.1) == inherited, (name, inherited)
                finally:
                    fcntl.flock(owner, fcntl.LOCK_UN)
                    assert completed.wait(5), (name, inherited)
                    worker.join()
                assert called.is_set() and errors == [], errors
    finally:
        shutil.rmtree(root)


def owned_source(owner: str, source: str) -> str:
    return f"struct {owner} {{ func execute() {{ {source} }} }}"


def run_self_test(rules: dict) -> None:
    from swift_type_index_tests import foundation_collection_self_test, resource_audit_execution_self_test
    foundation_collection_self_test(rules['service_boundary_errors'])
    resource_audit_execution_self_test(rules)
    module_coverage_binary_self_test()
    package_test_module_self_test()
    callable_network_api_self_test(rules)
    stream_network_self_test(rules)
    streaming_transport_self_test()
    local_resource_self_test(rules)
    subprocess_resource_self_test(rules)
    manifest_lock_self_test(rules['read_manifest'])
    adapter_ownership_errors = rules["adapter_ownership_errors"]
    adapter_roles = rules["adapter_roles"]
    compilation_type_context = rules["compilation_type_context"]
    graph_errors = rules["graph_errors"]
    imported_aliases = rules["imported_aliases"]
    imports_in_text = rules["imports_in_text"]
    manifest_targets = rules["manifest_targets"]
    ownership_errors = rules["ownership_errors"]
    for declaration, invocation, restricted in [
        ('func consume(_ prefs: UserDefaults, enabled: Bool = true) {}', 'consume(.standard)', True),
        ('func consume(enabled: Bool = true, _ prefs: UserDefaults) {}', 'consume(.standard)', True),
        ('func consume(_ enabled: Bool = true, _ prefs: UserDefaults) {}', 'consume(.standard)', True),
        ('func consume(_ prefs: UserDefaults, enabled: Bool = true, _ value: Int) {}', 'consume(.standard, 1)', True),
        ('func consume(_ prefs: UserDefaults...) {}', 'consume(.standard, .standard)', True),
        ('struct Owner { init(_ prefs: UserDefaults, enabled: Bool = true) {} }', 'Owner(.standard)', True),
        ('func consume(_ prefs: Model, enabled: Bool = true) {}', 'consume(.standard)', False),
        ('func consume(prefs: UserDefaults, enabled: Bool = true) {}', 'consume(.standard)', False),
    ]:
        assert bool(ownership_errors('PaperFeature', declaration + '; ' + invocation)) == restricted, (declaration, invocation)
    default_wrapper = 'func consume(_ wrapper: FileWrapper, enabled: Bool = true) {}; consume(.init(url: url, options: []))'
    assert rules['service_boundary_errors']('BIT101-iOS/Example.swift', default_wrapper)
    from swift_type_index import SwiftBindingTypes
    source = 'struct Value { static var standard: Value { Value() } }; struct Other { func consume(_ value: Value) {} }; struct Probe { let other = Other(); func consume(_ prefs: UserDefaults) {}; func run() { other.consume(.standard) } }'
    assert not ownership_errors('PaperFeature', source)
    split_path = 'Modules/PaperFeature/Sources/Probe.swift'
    for signature, invocation, restricted in [
        ('func consume(_ prefs: UserDefaults, enabled: Bool = true) {}', 'consume(.standard)', True),
        ('func consume(_ prefs: Value, enabled: Bool = true) {}', 'consume(.standard)', False),
        ('private func consume(_ prefs: UserDefaults) {}', 'consume(.standard)', False),
    ]:
        sources = {split_path: 'struct Probe { func run() { ' + invocation + ' } }',
            'Modules/PaperFeature/Sources/Support.swift': 'extension Probe { ' + signature + ' }'}
        index = rules['swift_syntax_index_sources'](sources)
        call_context = SwiftBindingTypes(index)
        assert bool(ownership_errors('PaperFeature', sources[split_path], split_path, call_context=call_context)) == restricted
        assert bool(rules['service_boundary_errors'](split_path, sources[split_path], call_context=call_context)) == restricted
    platform_errors = rules["platform_errors"]
    raw_imports = rules["raw_imports"]
    service_boundary_errors = rules["service_boundary_errors"]
    for source in ('let data = NSData(contentsOfMappedFile: path)', 'let data: NSData? = .init(contentsOfMappedFile: path)'):
        assert service_boundary_errors('Modules/PaperFeature/Sources/Probe.swift', source)
        assert not service_boundary_errors('Modules/StorageCore/Sources/AppFileService.swift', owned_source('LocalAppFileService', source))
    for expression in ('CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication)',
            'CoreFoundation.CFPreferencesSetAppValue(key, value, kCFPreferencesCurrentApplication)'):
        assert service_boundary_errors('Modules/PaperFeature/Sources/Probe.swift', expression)
        assert ownership_errors('PaperFeature', expression)
    for kind in ('SearchPathDirectory', 'SearchPathDomainMask', 'DirectoryEnumerationOptions',
            'VolumeEnumerationOptions', 'URLRelationship', 'ItemReplacementOptions'):
        assert not service_boundary_errors('Modules/PaperFeature/Sources/Probe.swift', f'struct Probe {{ let mask: FileManager.{kind} }}')
    swift_code = rules["swift_code"]
    swift_syntax_index_sources = rules["swift_syntax_index_sources"]
    type_aliases = rules["type_aliases"]
    from validation_policy import IOS_MODULE_COVERAGE_FLOORS
    from network_capability_tests import network_capability_self_test
    from validation_test_areas import smoke_scope_self_test, smoke_scalar_self_test
    callback_execution_self_test()
    url_reader_network_self_test()
    foundation_network_self_test()
    network_capability_self_test()
    smoke_scope_self_test()
    smoke_scalar_self_test()
    exported = swift_syntax_index_sources({'Modules/GalleryFeature/Sources/Service.swift': '''
        public struct GalleryService { func internalMember() {} }
        public extension GalleryService {
            func exportedMember() { func localHelper() {}; localHelper() }
            internal func internalOverride() {}
            private func privateMember() {}
        }
        extension GalleryService { public func explicitMember() {} }
    '''})
    methods = next(iter(exported.values()))['functionRanges']
    assert {function['name'] for function in methods if function['isExported']} == {'exportedMember', 'explicitMember'}
    assert graph_errors({'CourseDomain': {'ScoreDomain'}, 'ScoreDomain': set()})
    assert graph_errors({'ScheduleInfrastructure': {'ScoreInfrastructure'}, 'ScoreInfrastructure': set()})
    assert graph_errors({'ScheduleInfrastructure': {'ScheduleDomain'}, 'ScheduleDomain': set()}) == []
    for source in ('ScoreDomain', 'ScheduleContracts'):
        for dependency in ('TransportCore', 'ClientCore', 'StorageCore'):
            assert any('pure ' in error for error in graph_errors({source: {dependency}, dependency: set()}))
    assert graph_errors({'ScheduleDomain': {'ScheduleCore'}, 'ScheduleCore': set()}) == []
    assert any('pure domain boundary: ScheduleDomain -> TransportCore' in error for error in graph_errors({
        'ScheduleDomain': {'ScheduleCore'}, 'ScheduleCore': {'TransportCore'}, 'TransportCore': set()}))
    for dependency in ('ScheduleDomain', 'SchedulePorts', 'CommunityCore'):
        assert graph_errors({'ScoreFeature': {dependency}, dependency: set()})
    assert graph_errors({'GalleryFeature': {'CommunityCore', 'MediaKit'}, 'CommunityCore': set(), 'MediaKit': set()}) == []
    assert graph_errors({'MapFeature': {'ScheduleContracts'}, 'ScheduleContracts': set()}) == []
    assert graph_errors({'MapFeature': {'SchedulePorts'}, 'SchedulePorts': set()})
    registered_modules = set(IOS_MODULE_COVERAGE_FLOORS)
    assert rules["coverage_registry_findings"](registered_modules) == []
    assert rules["coverage_registry_findings"](registered_modules | {"NewModule"})
    assert rules["coverage_registry_findings"](registered_modules - {"TransportCore"})
    from validation_policy import UI_PRODUCTION_MODULES
    assert rules["coverage_registry_findings"](registered_modules, set(UI_PRODUCTION_MODULES)) == []
    assert rules["coverage_registry_findings"](registered_modules, set(UI_PRODUCTION_MODULES) - {'MediaKit'})
    assert rules["coverage_registry_findings"](registered_modules, set(UI_PRODUCTION_MODULES) | {'StorageCore'})

    from unittest.mock import patch
    from development_workflow_tests import native_target_inventory_self_test
    native_target_inventory_self_test(rules)
    from swift_type_index import compilation_unit
    assert compilation_unit('/workspace/BIT101-iOS/BIT101Watch/Source.swift') == 'BIT101Watch'
    module = rules["resource_facts"].__module__
    rules["resource_facts"].cache_clear()
    source = "func probe() { let data = Data(); try data.write(to: url); _ = Darwin.open(path, 0); let defaults: UserDefaults = .standard }"
    with patch(f"{module}.swift_syntax_index_sources", wraps=swift_syntax_index_sources) as indexer:
        rules["file_member_accesses"](source)
        rules["implicit_file_accesses"](source)
        rules["implicit_resource_accesses"](source)
        assert indexer.call_count == 1

    facts = rules["resource_facts"](source)
    original_variables = list(facts["typedVariables"])
    rules["implicit_resource_accesses"](source, properties=(((), "shared", "UserDefaults"),))
    rules["file_member_accesses"](source, properties=(((), "shared", "Data"),))
    assert facts["typedVariables"] == original_variables
    file_sources = {
        "Writer.swift": "struct Writer { let payload: Data; let destination: URL }; struct Message { func write(to value: Int) {} }; struct Sender { let payload: Message; let destination: Int }",
        "WriterActions.swift": "extension Writer { func save() throws { try payload.write(to: destination) } }",
        "WriterReferences.swift": "extension Writer { func save() throws { let writer = self.payload.write(to:options:); try writer(destination, .atomic) } }",
        "SenderActions.swift": "extension Sender { func send() { let writer = payload.write(to:); writer(destination) } }",
    }
    file_context = compilation_type_context(swift_syntax_index_sources(file_sources))
    for name in ("WriterActions.swift", "WriterReferences.swift"):
        assert service_boundary_errors("Modules/GalleryFeature/Sources/" + name, file_sources[name], context=file_context), name
    assert service_boundary_errors("Modules/GalleryFeature/Sources/SenderActions.swift", file_sources["SenderActions.swift"], context=file_context) == []
    for kind, restricted in (('Data', True), ('Message', False)):
        source = f'''struct Message {{ func write(to: URL, options: Int) {{}} }}
            struct Probe {{ func payload() -> {kind} {{ fatalError() }}; func location() -> URL {{ fatalError() }}
                func save() throws {{ try self.payload().write(to: self.location(), options: .atomic) }} }}'''
        assert bool(service_boundary_errors(split_path, source)) == restricted
    for value, restricted in (
        ('let preferenceType = UserDefaults.self; _ = preferenceType(suiteName: "store")', True),
        ('let preferenceType: UserDefaults.Type = UserDefaults.self; _ = preferenceType(suiteName: "store")', True),
        ('let preferenceType = Foundation.UserDefaults.self; let copied = preferenceType; _ = copied.standard', True),
        ('let preferenceType = UserDefaults.self; do { let preferenceType = Other.self; _ = preferenceType() }', False),
        ('let preferenceType = UserDefaults.self; _ = other.preferenceType()', False),
    ):
        source = 'struct Other {}; func run() { ' + value + ' }'
        assert bool(ownership_errors('PaperFeature', source)) == restricted
        assert bool(service_boundary_errors(split_path, source)) == restricted
    sources = {split_path: 'extension Probe { func save() throws { try self.payload().write(to: self.location()) } }',
        'Modules/PaperFeature/Sources/Support.swift': 'struct Probe { func payload() -> Data { fatalError() }; func location() -> URL { fatalError() } }'}
    index = swift_syntax_index_sources(sources)
    assert service_boundary_errors(split_path, sources[split_path], call_context=SwiftBindingTypes(index))
    for source in (
        "let group = NWConnectionGroup(with: descriptor, using: .udp); group.send(content: data)",
        "let group = Network.NWConnectionGroup(with: descriptor, using: .udp)",
        "typealias Group = NWConnectionGroup; let group = Group(with: descriptor, using: .udp)",
        "let browser = NWBrowser(for: descriptor, using: .tcp); browser.start(queue: queue)",
        "let browser = Network.NWBrowser(for: descriptor, using: .tcp)",
        "typealias Browser = NWBrowser; let browser = Browser(for: descriptor, using: .tcp)",
        "func send(task: URLSessionWebSocketTask) { task.send(message) }",
        "func read(task: Foundation.URLSessionStreamTask) { task.resume() }",
        "let io = DispatchIO(type: .stream, path: path, oflag: 0, mode: 0, queue: queue) { _ in }",
        "let io = Dispatch.DispatchIO(type: .stream, path: path, oflag: 0, mode: 0, queue: queue) { _ in }",
    ):
        assert service_boundary_errors("Modules/CourseFeature/Sources/Example.swift", source), source
    assert service_boundary_errors("Modules/StorageCore/Sources/AppFileService.swift", owned_source('LocalAppFileService', "let io = DispatchIO(type: .stream, path: path)")) == []
    control = owned_source('UITestControlServer', 'let listener = try NWListener(using: .tcp); let connection: NWConnection = accepted')
    assert service_boundary_errors('BIT101-iOS/Login/AppUITestBootstrap.swift', control) == []
    for source in ('let provider = CGDataProvider(url: url as CFURL)',
            'let provider = CoreGraphics.CGDataProvider(url: url as CFURL)',
            'let provider: CGDataProvider = .init(url: url as CFURL)',
            'typealias Provider = CGDataProvider; let provider: Provider = .init(url: url as CFURL)',
            'let document = CGPDFDocument(url as CFURL)',
            'let document = CoreGraphics.CGPDFDocument(url as CoreFoundation.CFURL)',
            'func load(url: CFURL) { let document = CGPDFDocument(url) }',
            'typealias Document = CGPDFDocument; let document = Document(url as CFURL)',
            'let read = CGDataProvider.init(url:)',
            'let read: (CFURL) -> CGPDFDocument? = CGPDFDocument.init'):
        assert service_boundary_errors('Modules/MediaKit/Sources/Example.swift', source), source
        assert service_boundary_errors('Modules/StorageCore/Sources/AppFileService.swift', owned_source('LocalAppFileService', source)) == []
    for source in ('let provider = CGDataProvider(data: bytes as CFData)',
            'func load(provider: CGDataProvider) { let document = CGPDFDocument(provider) }'):
        assert service_boundary_errors('Modules/MediaKit/Sources/Example.swift', source) == [], source

    for operation in ("open", "read", "write"):
        source = f"func execute({operation}: @Sendable () throws -> Data) throws -> Data {{ try {operation}() }}"
        assert service_boundary_errors("BIT101-iOS/Payload.swift", source) == []
        assert service_boundary_errors("BIT101-iOS/Payload.swift", source.replace(f"try {operation}()", f"Darwin.{operation}(1)"))
    split_sources = {"Types.swift": "enum Namespace { struct Owner { var prefs: UserDefaults; var files: LocalAppFileService }; struct Local { func data(for item: Int) -> Int { item } } }",
        "Init.swift": "extension Namespace.Owner { init() { self.prefs = .standard; self.files = .init() } }",
        "Local.swift": "let catalog = Namespace.Local(); let value = catalog.data(for: 1)"}
    context = compilation_type_context(swift_syntax_index_sources(split_sources))
    assert len(ownership_errors("GalleryFeature", split_sources["Init.swift"], properties=context[0])) == 2
    assert len(service_boundary_errors("Modules/GalleryFeature/Sources/Init.swift", split_sources["Init.swift"], context=context)) == 2
    assert service_boundary_errors("Modules/GalleryFeature/Sources/Local.swift", split_sources["Local.swift"], context=context) == []
    assert service_boundary_errors("BIT101-iOS/Example.swift", "struct Catalog { func data(for item: Int) -> Int { item } }; let catalog = Catalog(); let value = catalog.data(for: 1)") == []
    assert service_boundary_errors("BIT101-iOS/Example.swift", "struct Catalog { func data(for item: Int) -> Int { item } }; let catalog = Catalog(); let value = catalog.data(for: 1); let data = try await session.data(for: request)")
    for source in ("let bytes = NSMutableData(contentsOf: url)", "let text = try NSMutableString(contentsOf: url, encoding: encoding)",
                   "let bytes: NSMutableData = .init(contentsOf: url)", "let text = try NSMutableString.self.init(contentsOf: url, encoding: encoding)"):
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source)
    for source in (
        "let wrapper = try FileWrapper(url: url, options: [])",
        "let wrapper = NSFileWrapper(path: path)",
        "let wrapper = try Foundation.FileWrapper.self.init(url: url, options: [])",
        "let wrapper: FileWrapper = try .init(url: url, options: [])",
        "typealias Wrapper = FileWrapper; let wrapper: Wrapper = try .init(url: url, options: [])",
        "let wrapper = FileWrapper(regularFileWithContents: Data()); try wrapper.write(to: url, options: [], originalContentsURL: nil)",
        "func refresh(wrapper: FileWrapper, url: URL) { try wrapper.read(from: url, options: []) }",
        "func compare(wrapper: Foundation.FileWrapper, url: URL) { _ = wrapper.matchesContents(of: url) }",
    ):
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source), source
        assert service_boundary_errors("Modules/StorageCore/Sources/AppFileService.swift", owned_source('LocalAppFileService', source)) == []
    assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", "let wrapper = FileWrapper(regularFileWithContents: Data())") == []
    assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", "struct Wrapper { func read(from item: Int) {} }; let value = Wrapper(); value.read(from: 1)") == []
    for source in ('let parser = XMLParser(contentsOf: url)', 'let parser = Foundation.XMLParser.init(contentsOf: url)',
            'let parser = Foundation.XMLParser.self.init(contentsOfURL: url)',
            'let parser: XMLParser? = .init(contentsOf: url)',
            'func parser(url: URL) -> XMLParser? { .init(contentsOf: url) }',
            'func accept(_ parser: XMLParser?) {}; accept(.init(contentsOf: url))',
            'typealias Parser = XMLParser; let parser = Parser(contentsOf: url)',
            'NSKeyedArchiver.archiveRootObject(value, toFile: path)', 'NSArchiver.archiveRootObject(value, toFile: path)',
            'let archive = Foundation.NSKeyedArchiver.self.archiveRootObject(_:toFile:)',
            'typealias Archive = NSKeyedArchiver; let archive = Archive.archiveRootObject',
            'NSKeyedUnarchiver.unarchiveObject(withFile: path)', 'NSUnarchiver.unarchiveObject(withFile: path)',
            'let read = Foundation.NSKeyedUnarchiver.self.unarchiveObject(withFile:)',
            'typealias Archive = NSKeyedUnarchiver; let read = Archive.unarchiveObject(withFile:)'):
        assert service_boundary_errors('Modules/GalleryFeature/Sources/Example.swift', source), source
        assert service_boundary_errors('BIT101-iOS/Schedule/Example.swift', source), source
        assert service_boundary_errors('Modules/StorageCore/Sources/AppFileService.swift', owned_source('LocalAppFileService', source)) == [], source
    for source in ('XMLParser(data: data)', 'XMLParser(stream: stream)', 'let parser: XMLParser = .init(data: data)',
            'try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)',
            'NSKeyedUnarchiver.unarchiveObject(with: data)', 'NSUnarchiver.unarchiveObject(with: data)',
            'let read = NSKeyedUnarchiver.unarchiveObject(with:)', 'let archive = NSArchiver.archivedData(withRootObject: value)',
            'try NSKeyedUnarchiver(forReadingFrom: data)', 'NSKeyedArchiver(requiringSecureCoding: true)'):
        assert service_boundary_errors('BIT101-iOS/Schedule/Example.swift', source) == [], source
    targets = manifest_targets({"targets": [
        {"name": "NewCore", "path": "Modules/NewCore/Sources", "type": "regular", "dependencies": []},
        {"name": "NewFeature", "path": "Modules/NewFeature/Sources", "type": "regular",
         "dependencies": [{"byName": ["NewCore", None]}]},
        {"name": "ConsumerTests", "path": "ModuleTests/Consumer", "type": "test",
         "dependencies": [{"target": ["NewFeature", {"platformNames": ["macos"]}]}]},
    ]})
    assert targets["NewFeature"]["dependencies"] == {"NewCore"}
    assert targets["ConsumerTests"]["dependencies"] == {"NewFeature"}
    assert graph_errors({name: info["dependencies"] for name, info in targets.items() if info["type"] == "regular"}) == []
    for invalid in (
        {"name": "MissingCore", "type": "regular", "dependencies": []},
        {"name": "ExcludedCore", "path": "Modules/ExcludedCore/Sources", "type": "regular", "dependencies": [], "exclude": ["Implementation.swift"]},
        {"name": "SelectedCore", "path": "Modules/SelectedCore/Sources", "type": "regular", "dependencies": [], "sources": ["Unused.swift"]},
        {"name": "EmptyCore", "path": "Modules/EmptyCore/Sources", "type": "regular", "dependencies": [], "sources": []},
        {"name": "ExternalCore", "path": "Modules/ExternalCore/Sources", "type": "regular",
         "dependencies": [{"product": ["Remote", "Package", None]}]},
    ):
        try:
            manifest_targets({"targets": [invalid]})
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid manifest target accepted: {invalid}")
    assert imports_in_text("@testable import ScoreFeature\n@preconcurrency public import TransportCore\nimport SwiftUI") == {"ScoreFeature", "TransportCore"}
    assert raw_imports("@_implementationOnly import UIKit\n@_spi(Internal) import StorageCore") == {"UIKit", "StorageCore"}
    for access in ("public", "internal", "fileprivate", "private", "package"):
        assert raw_imports(f"{access} import UIKit") == {"UIKit"}
        assert platform_errors("ScheduleDomain", raw_imports(f"@preconcurrency {access} import struct UIKit.UIColor"))
    assert raw_imports("@_spi(Internal)\n@preconcurrency public import class Foundation.Date") == {"Foundation"}
    assert raw_imports("import Foundation; import UIKit; @_spi(Internal) import StorageCore") == {"Foundation", "UIKit", "StorageCore"}
    assert platform_errors("ScheduleDomain", raw_imports("#if os(iOS)\nimport Foundation; import UIKit\n#endif"))
    assert platform_errors("ScheduleDomain", raw_imports("import `UIKit`"))
    for source in ("Foundation.UserDefaults.`standard`", "`UserDefaults`.standard", "let prefs: `UserDefaults` = .`standard`"):
        assert ownership_errors("GalleryFeature", source) and service_boundary_errors("BIT101-iOS/Example.swift", source)
    assert graph_errors({"ScheduleLeafCore": set(), "ScheduleFirstCore": {"ScheduleLeafCore"}, "ScheduleSecondCore": {"ScheduleLeafCore"}}) == []
    assert graph_errors({'ScheduleDomain': {'ScheduleHelpers'}, 'ScheduleHelpers': {'ScoreFeature'}, 'ScoreFeature': set()}) \
        == ['ScheduleHelpers requires a declared architectural layer suffix']
    assert any("cycle" in error for error in graph_errors({"First": {"Second"}, "Second": {"First"}}))
    assert any("feature boundary" in error for error in graph_errors({"FirstFeature": {"SecondFeature"}, "SecondFeature": set()}))
    assert any("infrastructure boundary" in error for error in graph_errors({"ScoreInfrastructure": {"ScoreFeature"}, "ScoreFeature": set()}))


    assert graph_errors({"TransportCore": {"ScoreFeature"}, "ScoreFeature": set()})
    assert ownership_errors("CommunityUI", "let screen = UIApplication . shared")
    assert ownership_errors("ScoreFeature", "let store: ScoreCacheStore")
    assert ownership_errors("GalleryFeature", "let store: ComposerDraftStore")
    for factory in ("URLSessionTransport.make(configuration: .ephemeral)", "URLSessionTransport.self.make(configuration: .ephemeral)", "typealias Factory = URLSessionTransport; Factory.make(configuration: .ephemeral)"):
        assert ownership_errors("GalleryFeature", factory)
        assert service_boundary_errors("Modules/GalleryFeature/Sources/GalleryService.swift", factory)
    assert ownership_errors("CommunityUI", "let store: GalleryMessageReadStore")
    assert ownership_errors("ScoreFeature", "// ScoreCacheStore\nlet text = #\"URLSession.shared\"#") == []
    assert ownership_errors("AppLocalDataService", "LoginStorage.shared.clearAllLocalData()")
    assert ownership_errors("AppScheduleCacheEffects", "ScheduleCloudSyncManager.shared.pushLatestLocalCacheIfNeeded()")
    renamed = swift_syntax_index_sources({"renamed.swift": 'struct RenamedEffects: SchedulePlatformActions { func enable() { ScheduleCloudSyncManager.shared.push() } }; struct RenamedCleanup { func resetAllLocalData() { LoginStorage.shared.clear() } }'})
    assert len(adapter_ownership_errors(renamed["renamed.swift"])) >= 2
    split = swift_syntax_index_sources({
        "Types.swift": "enum Namespace { struct RenamedEffects: SchedulePlatformActions {}; struct Composition {} }",
        "Effects.swift": "extension Namespace.RenamedEffects { func enable() { ScheduleCloudSyncManager.shared.push() } }",
        "Composition.swift": "extension Namespace.Composition { func enable() { ScheduleCloudSyncManager.shared.push() } }",
    })
    roles = adapter_roles(split)
    assert adapter_ownership_errors(split["Effects.swift"], roles=roles)
    assert adapter_ownership_errors(split["Composition.swift"], roles=roles) == []
    for body, expected in (
            ('loadAccountStorage()', True), ('let load = loadAccountStorage; load()', True),
            ('if false { loadAccountStorage() }', False), ('loadAccountStorage(1)', False)):
        sources = {
            'BIT101-iOS/Effects.swift': 'struct AppScheduleCacheEffects { func changed() { ' + body + ' } }',
            'BIT101-iOS/Helpers.swift': 'func loadAccountStorage() { indirect() }; '
                'func indirect() { AppAccountSession.storage }; func loadAccountStorage(_ value: Int) {}',
        }
        index = swift_syntax_index_sources(sources)
        call_roles = rules['adapter_call_roles'](index)
        errors = [error for path, facts in index.items() for error in adapter_ownership_errors(
            facts, path, adapter_roles(index, path), call_roles=call_roles)]
        assert bool(errors) == expected, (body, errors)
        if expected:
            assert len(errors) == 1 and errors[0].startswith('BIT101-iOS/Helpers.swift:1:'), errors
    direct = swift_syntax_index_sources({'Effects.swift':
        'struct AppScheduleCacheEffects { func changed() { AppAccountSession.storage } }'})
    assert len(adapter_ownership_errors(direct['Effects.swift'], 'Effects.swift')) == 1
    renamed_settings = swift_syntax_index_sources({"settings.swift": 'struct RenamedScreen: View { var body: some View { AppMedia.shared } }'})
    assert adapter_ownership_errors(renamed_settings["settings.swift"], "BIT101-iOS/Settings/Renamed.swift")
    assert platform_errors("ScheduleDomain", {"UIKit"})
    assert platform_errors("ScheduleDomain", {"Foundation", "Compression"}) == []
    assert platform_errors("ScheduleActivityContracts", {"Foundation", "ActivityKit"}) == []
    interpolation_sources = (
        r'let text = "\(UserDefaults.standard.string(forKey: "key"))"',
        r'let text = #"\#(UserDefaults.standard)"#',
        'let text = """\n\\(UserDefaults.standard)\n"""',
        r'let text = "\("nested \(UserDefaults.standard)")"',
    )
    for source in interpolation_sources:
        assert ownership_errors("GalleryFeature", source)
        assert len(swift_code(source)) == len(source)
    assert ownership_errors("GalleryFeature", r'let text = "\\(UserDefaults.standard)"') == []
    assert ownership_errors("GalleryFeature", r'let text = #"\(UserDefaults.standard)"#') == []
    assert ownership_errors("GalleryFeature", r'let text = "\(value /* UserDefaults.standard */)"') == []
    assert imports_in_text('/* import GalleryFeature\n/* import ScoreFeature */ */\nimport TransportCore') == {"TransportCore"}
    assert imports_in_text('let text = #"""\nimport GalleryFeature\n"""#\nimport struct StorageCore.AppStorageSession') == {"StorageCore"}
    service_path = "BIT101-iOS/Example.swift"
    for source in ('let files = AppFileSystem.files', 'let files = LocalAppFileService()', 'let preferences = UserDefaults(suiteName: "global")'):
        assert ownership_errors("GalleryFeature", source)
    for source in ('LocalAppFileService.init()', 'let files: LocalAppFileService = .init()', 'let prefs: Swift.Optional<UserDefaults> = .standard', 'let prefs: Swift.Array<UserDefaults> = [.standard]', 'let prefs: Swift.Dictionary<String, UserDefaults> = ["prefs": .standard]'):
        assert ownership_errors("ScheduleFeature", source) and service_boundary_errors("Modules/ScheduleFeature/Sources/Example.swift", source), source
    assert ownership_errors("GalleryFeature", "URLSessionTransport.clearSharedCache()") and service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", "URLSessionTransport.clearSharedCache()")
    for source in ('let regex = /FileManager.default/', 'let regex = #/UserDefaults.standard [a/b]/#', 'let regex = flag ? /URLSession.shared/ : /safe/',
                   'if /URLSession/.wholeMatch(in: input) != nil { consume() }',
                   'while /UserDefaults.standard/.wholeMatch(in: input) != nil { break }',
                   'guard /FileManager.default/.wholeMatch(in: input) != nil else { return }',
                   'let 中文 = "文字"; if /URLSession/.wholeMatch(in: 中文) != nil { consume() }',
                   'let regex = /a\\/\\/URLSession/; consume(regex)'):
        assert ownership_errors("GalleryFeature", source) == []
        assert service_boundary_errors(service_path, source) == []
        assert len(swift_code(source)) == len(source)
    assert service_boundary_errors(service_path, 'let regex = /a\\/\\/safe/; let value = URLSession.shared')
    assert ownership_errors("GalleryFeature", "let result = amount / UserDefaults.standard.integer(forKey: key)")
    for source in (
        "let session = URLSession(configuration: configuration)",
        "import CoreFoundation; let createSocket = CFSocketCreate; let connectSocket = CFSocketConnectToAddress",
        "let createStreams = CFStreamCreatePairWithSocketToHost; let connectPeer = CFStreamCreatePairWithPeerSocketSignature",
        "let connection = NSURLConnection(request: request, delegate: nil)",
        "let read = CFNetwork.CFReadStreamCreateForHTTPRequest; let create = CFHTTPMessageCreateRequest",
        "import Darwin; let channel = socket(AF_INET, SOCK_STREAM, 0); connect(channel, address, size); send(channel, bytes, size, 0)",
        "let openSocket = Darwin.socket; let sendBytes = Glibc.send",
        "getaddrinfo(host, service, hints, result)",
        "Darwin.getnameinfo(address, size, host, hostSize, service, serviceSize, flags)",
        "let lookup = Glibc.getaddrinfo",
        "import CoreFoundation; let readFile = CFReadStreamCreateWithFile; let writeFile = CFWriteStreamCreateWithFile",
        "try await transport.data(for: request)",
        "session.dataTask(with: request)",
        "let manager: FileManager = .default",
        "try Data(contentsOf: url)",
        "let bytes: Data = try .init(contentsOf: url)",
        "func parse(url: URL) throws { let bytes: Data = try .init(contentsOf: url) }",
        "let image = UIImage.init(contentsOfFile: path)",
        'func persist(_ image: UIImage, directory: URL) throws { try image.pngData()?.write(to: directory.appendingPathComponent("x")) }',
        'func persist(_ image: UIImage, directory: URL) throws { try image.jpegData(compressionQuality: 1)?.write(to: directory.appending(path: "x")) }',
        'func exists(_ url: NSURL) throws { var value: AnyObject?; try url.getResourceValue(&value, forKey: .fileSizeKey) }',
        "let stream = InputStream.init(url: url)",
        "var stream: InputStream?; stream = .init(url: url)",
        "func stream() -> InputStream? { .init(url: url) }",
        "let fd = open(path, O_RDONLY); read(fd, &buffer, count)",
        "let fd = Darwin.open(path, O_RDONLY); Darwin.read(fd, &buffer, count)",
        "Glibc.fopen(path, mode)",
        "try FileHandle(forReadingFrom: url)",
        "try String.init(contentsOf: url, encoding: .utf8)",
        "func save(data: Data, url: URL) throws { try data.write(to: url) }",
        "func save(data: Data, url: URL) throws { let writer = data.write(to:options:); try writer(url, .atomic) }",
        "func save(data: Data, url: URL) throws { let writer = data.write; try writer(url, .atomic) }",
        "func save(text: String, url: URL) throws { let writer = text.write(to:atomically:encoding:); try writer(url, true, .utf8) }",
        "let writer = Foundation.Data.write(to:options:)",
        "func read(file: FileWrapper, url: URL) throws { let reader = file.read(from:options:); try reader(url, []) }",
        "func check(file: FileWrapper, url: URL) { let matches = file.matchesContents(of:); _ = matches(url) }",
        'try "value".write(toFile: path, atomically: true, encoding: .utf8)',
        "let data = Data(); try data.write(to: url)",
        "func bytes() -> Data { Data() }; try bytes().write(to: url)",
        "let data: Data? = nil; try data?.write(to: url)",
        "func dump(_ data: [Data], _ target: URL) throws { try data[0].write(to: target) }",
        "func dump(_ data: [Data?], _ target: URL) throws { try data[0]?.write(to: target) }",
        'func dump(_ data: Dictionary<String, Data>, _ target: URL) throws { try data["key"]?.write(to: target) }',
        "func dump(_ data: [Data], _ target: URL) throws { for item in data { try item.write(to: target) } }",
        "func dump(_ data: [Data], _ target: URL) throws { try data.forEach { try $0.write(to: target) } }",
        "func save(bytes: () -> Data, target: URL) throws { try bytes().write(to: target) }",
        "func dump(_ values: [Data], _ target: URL) throws { let writer = values.first!.write(to:options:); try writer(target, .atomic) }",
        "func dump(_ values: Array<Data>, _ target: URL) throws { let writer = values.last!.write(to:options:); try writer(target, .atomic) }",
        "func dump(_ values: [Data], _ target: URL) throws { try values.first?.write(to: target) }",
        "struct Snapshot { let data: Data }; func dump(_ snapshot: Snapshot, _ target: URL) throws { try snapshot.data.write(to: target) }",
        "Darwin.readlink(path, buffer, count)",
        "Darwin.removefile(path, state, 0)", "Darwin.copyfile(source, destination, state, 0)",
        "Darwin.getxattr(path, key, buffer, count, 0, 0)", "Darwin.realpath(path, buffer)",
        "let removeFile = Darwin.removefile; let pathResolver = Darwin.realpath",
        "func read(_ message: String) {}; read(fd, buffer, count)",
        "let data = try JSONEncoder().encode(value); try data.write(to: url)",
        "let encoder = PropertyListEncoder(); let data = try encoder.encode(value); try data.write(to: url)",
        'let data = "hello".data(using: .utf8)!; try data.write(to: url)',
        "let data = try JSONSerialization.data(withJSONObject: value); try data.write(to: url)",
        "rename(old, new)", "remove(path)",
        "try url.resourceValues(forKeys: [.fileSizeKey])",
        "url.resolvingSymlinksInPath()",
        "let image = UIImage(contentsOfFile: path)",
        "let monitor = NWPathMonitor()",
        "let defaults: UserDefaults = .standard",
        "let factory: () -> UserDefaults = { .standard }",
        "let factory: (Model) -> UserDefaults = { _ in .standard }",
        'let factory: () -> UserDefaults = { .init(suiteName: "fixture")! }',
        "func choose() -> Optional<UserDefaults> { .standard }",
        'let map: [String: UserDefaults] = ["fixture": .standard]',
        'let defaults: UserDefaults? = .init(suiteName: "module-owned")',
        "func configure(defaults: UserDefaults = .standard) {}",
        "func configure(defaults: UserDefaults? = . standard) {}",
        "struct Store { var defaults: UserDefaults { .standard } }",
        "struct Store { let defaults: UserDefaults; init() { defaults = .standard } }",
        "func preferences() -> UserDefaults { .standard }",
        "func pick(_ flag: Bool, _ supplied: UserDefaults) -> UserDefaults { flag ? .standard : supplied }",
        "let preferences: [UserDefaults] = [.standard]",
        'func accept(_ value: UserDefaults?) {}; accept(.standard); accept(.init(suiteName: "review"))',
        'struct State { let prefs: UserDefaults? }; State(prefs: .init(suiteName: "review"))',
        'UserDefaults.self.standard', 'UserDefaults.self.init(suiteName: "review")',
        'try Data.self.init(contentsOf: url)',
        'let openFile = Darwin.open; let fd = openFile(path, 0)',
        "let underlying = error.userInfo[NSUnderlyingErrorKey]",
        "let allowed = CharacterSet.urlQueryAllowed",
        r'let text = "\(try Data(contentsOf: url))"',
    ):
        assert service_boundary_errors(service_path, source), source
    assert ownership_errors("GalleryFeature", "struct Store { var defaults: UserDefaults { .standard } }")
    assert ownership_errors("GalleryFeature", "AppFileSystem.self.files")
    assert ownership_errors("GalleryFeature", "struct Store { let defaults: UserDefaults; init() { defaults = .standard } }")
    for source in ('let defaults: UserDefaults? = .init(suiteName: "module-owned")',
                   "let factory: () -> UserDefaults = UserDefaults.init; let preferences = factory()",
                   "let factory: () -> LocalAppFileService = LocalAppFileService.init; let files = factory()",
                   "func configure(defaults: UserDefaults? = .standard) {}",
                   'struct Store { var defaults: Foundation.UserDefaults?; func configure() { defaults = .init(suiteName: "module-owned") } }',
                   'func preferences() -> UserDefaults? { .init(suiteName: "module-owned") }'):
        assert ownership_errors("GalleryFeature", source), source
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source), source
    for source in (
        "typealias Preferences = UserDefaults; let store = Preferences.standard",
        "typealias First = Foundation.UserDefaults; typealias Second = First; let store: Second = .standard",
        'typealias Preferences = UserDefaults; let store = Preferences(suiteName: "module-owned")',
        "struct Owner { typealias Preferences = UserDefaults }; let store = Owner.Preferences.standard",
        "func configure() { typealias Preferences = UserDefaults; let store = Preferences.standard }",
        "typealias Session = URLSession; let session = Session.shared",
        "typealias Files = FileManager; let files = Files.default",
    ):
        assert ownership_errors("GalleryFeature", source), source
        assert service_boundary_errors(service_path, source), source
    assert ownership_errors("GalleryFeature", "let factory: (UserDefaults) -> Model = { _ in .standard }") == []
    alias_index = swift_syntax_index_sources({"aliases.swift": "typealias First = UserDefaults; typealias Second = First"})
    aliases = type_aliases(alias_index)
    assert ownership_errors("GalleryFeature", "let store = Second.standard", "consumer.swift", aliases)
    assert service_boundary_errors("consumer.swift", "let store = Second.standard", aliases)
    external = type_aliases(swift_syntax_index_sources({
        "Modules/StorageCore/Sources/Aliases.swift": "public typealias First = UserDefaults; public typealias Second = First; internal typealias Local = UserDefaults; private typealias Hidden = UserDefaults"}))
    imported = imported_aliases("import StorageCore", (), external)
    consumer = "Modules/GalleryFeature/Sources/Consumer.swift"
    assert ownership_errors("GalleryFeature", "import StorageCore; let store = Second.standard", consumer, imported)
    assert service_boundary_errors(consumer, "import StorageCore; let store = StorageCore.Second.standard", imported)
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls
    from unittest.mock import patch
    aliased = "typealias C=CommunitySession; public struct ExampleService { let client: C; public func f() async throws { try await client.requestVoid(request) } }"
    originals = {"Modules/NewForumFeature/Sources/Service.swift": aliased,
        "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift":
            "typealias C=CommunitySession; struct ReleaseNetworkSmokeRunner { let client: C; func run() { mine.fetchMyInfo() } }"}
    expanded = {path: rules["expanded_resource_source"](source, (), path) for path, source in originals.items()}
    index = swift_syntax_index_sources(expanded)
    with patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", lambda path, *args, **kwargs: originals[str(path)]):
        assert "NewForumFeature.ExampleService" in business_methods(index)
        assert "mine.fetchMyInfo" in {call["calledExpression"] for call in reachable_smoke_calls(index)["network"]}
    assert ownership_errors("GalleryFeature", "import StorageCore; struct Second { static let standard = 1 }; let store = Second.standard", consumer, imported) == []
    assert ownership_errors("GalleryFeature", "import StorageCore; let store = Local.standard; let hidden = Hidden.standard", consumer, imported) == []
    assert ownership_errors("GalleryFeature", 'typealias Preferences = UserDefaults; let text = "Preferences.standard"') == []
    assert ownership_errors("GalleryFeature", "typealias Preferences = UserDefaults; struct Model { let Preferences: Int }; let value = model.Preferences") == []
    assert ownership_errors("GalleryFeature", "typealias Preferences = UserDefaults; struct Item { var standard: Int }; let Preferences = Item(standard: 1); let value = Preferences.standard") == []
    assert service_boundary_errors(service_path, "struct Item { static let standard = Item() }; struct Store { var defaults: UserDefaults; func configure() { defaults = .standard }; func helper() { let defaults: Item = .standard } }")
    assert service_boundary_errors(service_path, "struct Item { static let standard = Item() }; struct Store { var defaults: Item; func configure() { defaults = .standard }; func helper() { let defaults: UserDefaults = .standard } }")
    assert service_boundary_errors(service_path, "struct Item { static let standard = Item() }; struct Store { var defaults: Item; func configure() { defaults = .standard }; func helper() { let defaults: UserDefaults } }") == []
    for source in (
        "// URLSession.shared\nlet text = #\"Data(contentsOf: url)\"#",
        "try files.writeData(data, to: url, options: [.atomic])",
        "try await client.send(request)",
        "func read(value: Data) -> Data { value }; let bytes = read(value: input)",
        "struct Reader { func read() {}; func run() { read() } }",
        "struct Item { init(url: URL) {} }; let item: Item = .init(url: url)",
        'struct Item { init(suiteName: String) {} }; let item: Item = .init(suiteName: "business")',
        "FileHandle.standardOutput.write(data)",
        "FileHandle.standardError.write(data)",
        "defaults.data(forKey: key)",
        "let directory: FileManager.SearchPathDirectory = .cachesDirectory",
        "let options: FileManager.DirectoryEnumerationOptions = []",
        "struct Store { var defaults: UserDefaults { log(.standard); return supplied } }",
    ):
        assert service_boundary_errors(service_path, source) == [], source
    assert service_boundary_errors("Modules/StorageCore/Sources/AppFileService.swift", owned_source('LocalAppFileService', "try data.write(to: url)")) == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; let message = Message(); message.write(to: 42)") == []
    assert service_boundary_errors(service_path, "struct Message { func encode(_ value: Int) -> Message { self }; func write(to target: Int) {} }; let data = Message().encode(1); data.write(to: 42)") == []
    assert service_boundary_errors(service_path, "func remove(_ value: Int) {}; remove(42); func rename(_ a: Int, _ b: Int) {}; rename(1, 2)") == []
    assert service_boundary_errors(service_path, 'let read = "value"; print(read); let open: (Int) -> Bool = { $0 > 0 }; open(1)') == []
    assert service_boundary_errors(service_path, "func read(message: String = \"\") {}; read(message: \"hello\"); read()") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; func bytes() -> Message { Message() }; bytes().write(to: 42)") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; struct Snapshot { let data: Message }; func send(snapshot: Snapshot, data: [Message]) { snapshot.data.write(to: 42); data[0].write(to: 42) }") == []
    assert service_boundary_errors(service_path, "struct Row { init(contentsOf: [Int]) {} }; let row: Row = .init(contentsOf: [1])") == []
    assert service_boundary_errors(service_path, 'struct Row { init(contentsOf: [Int]) {}; static let standard = Row(contentsOf: []) }; func accept(_ row: Row) {}; accept(.standard); accept(.init(contentsOf: [1]))') == []
    assert service_boundary_errors(service_path, "struct Message { func write(to url: URL) {} }; func send(messages: [Message], url: URL) { for message in messages { message.write(to: url) } }") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; func send(message: Message) { message.write(to: 42) }") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; func send(message: Message) { let writer = message.write(to:); writer(42) }") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; func send(message: Message) { let writer = message.write; writer(42) }") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; func send(messages: [Message]) { let writer = messages.first!.write(to:); writer(42) }") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/HTTPClient.swift", owned_source('HTTPClient', "try await transport.data(for: request)")) == []
    assert service_boundary_errors(service_path, "func socket(_ value: Int) {}; socket(1); func send(_ value: Int) {}; send(1); enum Delivery { case send; case preflight }") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/SecureURLTransport.swift", owned_source('URLSessionTransport', "URLSession(configuration: configuration)")) == []
    assert service_boundary_errors("Modules/TransportCore/Sources/NetworkPathState.swift", owned_source('NetworkPathState', "NWPathMonitor()")) == []
    assert service_boundary_errors("Modules/ScheduleFeature/Sources/Example.swift", "DateFormatter()")
    assert service_boundary_errors("Modules/TransportCore/Sources/TaskCancellation.swift", owned_source('ErrorChain', "error.userInfo[NSUnderlyingErrorKey]")) == []
    assert service_boundary_errors("Modules/TransportCore/Sources/AppURL.swift", owned_source('HTTPFormEncoding', "CharacterSet.urlQueryAllowed")) == []
    assert ownership_errors("TransportCore", owned_source("URLSessionTransport", "URLCache.shared"), "Modules/TransportCore/Sources/Relocated.swift") == []
    assert ownership_errors("TransportCore", "URLCache.shared", "Modules/TransportCore/Sources/HTTPClient.swift")
    assert ownership_errors("AppExternalDisplayCoordinator", "WatchScheduleSyncManager.shared.activateIfNeeded()")
    assert ownership_errors("AppExternalDisplayCoordinator", "activateWatch()") == []
    relocated = swift_syntax_index_sources({"BIT101-iOS/Relocated.swift": """
struct AppExternalDisplayCoordinator { func activate() { activateWatch() } }
extension AppExternalDisplayCoordinator { func unsafe() { WatchScheduleSyncManager.shared.activateIfNeeded() } }
"""})
    assert any(adapter_ownership_errors(facts) for facts in relocated.values())
    unrelated = swift_syntax_index_sources({"BIT101-iOS/Composition.swift": "struct Composition { let manager = WatchScheduleSyncManager.shared }"})
    assert all(adapter_ownership_errors(facts) == [] for facts in unrelated.values())
    for owner in ("AppLocalDataService", "SettingsNetworkService", "AboutSettingsPage", "AccountSettingsPage"):
        relocated = swift_syntax_index_sources({"BIT101-iOS/Relocated.swift":
            f"struct {owner} {{}}\nextension {owner} {{ func unsafe() {{ LoginStorage.shared.clearAllLocalData() }} }}"})
        assert any(adapter_ownership_errors(facts) for facts in relocated.values())

    for module, owner, operation in (
        ('TransportCore', 'HTTPClient', 'try await transport.data(for: request)'),
        ('TransportCore', 'URLSessionTransport', 'URLSession(configuration: configuration)'),
        ('TransportCore', 'NetworkPathState', 'NWPathMonitor()'),
        ('TransportCore', 'ErrorChain', 'error.userInfo[NSUnderlyingErrorKey]'),
        ('TransportCore', 'HTTPFormEncoding', 'CharacterSet.urlQueryAllowed'),
        ('StorageCore', 'LocalAppFileService', 'let data = Data(); try data.write(to: url)'),
        ('BIT101-iOS', 'AppFileDirectories', 'UserDefaults.standard'),
    ):
        path = f'Modules/{module}/Sources/Relocated.swift' if module != 'BIT101-iOS' else 'BIT101-iOS/Relocated.swift'
        approved = owned_source(owner, operation)
        assert service_boundary_errors(path, approved) == [], (owner, operation)
        assert service_boundary_errors(path, owned_source('Rogue', operation)), (owner, operation)
        assert service_boundary_errors(path, approved + '\n' + owned_source('Rogue', operation)), (owner, operation)
        assert service_boundary_errors('Modules/GalleryFeature/Sources/Relocated.swift', approved), (owner, operation)
    assert service_boundary_errors('Modules/StorageCore/Sources/Relocated.swift',
        'struct LocalAppFileService {}; extension LocalAppFileService { func read() { try Data(contentsOf: url) } }') == []
    assert service_boundary_errors('Modules/StorageCore/Sources/AppFileService.swift',
        'struct LocalAppFileService { struct Rogue { func read() { try Data(contentsOf: url) } } }')


def callback_execution_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from validation_test_areas import reachable_smoke_calls
    from network_capability_rules import business_methods
    cases = (
        ('let operation = { BODY }; Task(operation: operation)', True),
        ('let operation = { BODY }; let alias = operation; Task.detached(operation: alias)', True),
        ('let operation = { BODY }; Task.init(operation: operation)', True),
        ('DispatchQueue.global().async(execute: DispatchWorkItem { BODY })', True),
        ('let work = DispatchWorkItem { BODY }; DispatchQueue.main.async(execute: work)', True),
        ('let work = DispatchWorkItem { BODY }; let alias = work; alias.perform()', True),
        ('let operation = { BODY }; DispatchQueue.main.async(execute: DispatchWorkItem(block: operation))', True),
        ('OperationQueue.main.addOperation { BODY }', True),
        ('let operation = { BODY }; OperationQueue.main.addOperation(operation)', True),
        ('func execute(_ operation: @escaping () -> Void) { let alias = operation; Task(operation: alias) }; execute { BODY }', True),
        ('func forward(_ operation: @escaping () -> Void) { Task(operation: operation) }; func execute(_ operation: @escaping () -> Void) { let alias = operation; forward(alias) }; execute { BODY }', True),
        ('func execute(_ operation: @escaping () -> Void) { let alias = operation }; execute { BODY }', False),
        ('let operation = { BODY }', False), ('let work = DispatchWorkItem { BODY }', False),
        ('let operation = { BODY }; if false { Task(operation: operation) }', False),
        ('let operation = { BODY }; let unused = { Task(operation: operation) }', False),
        ('let operation = { BODY }; do { let operation = {}; Task(operation: operation) }', False),
        ('struct Queue { func addOperation(_ block: () -> Void) {} }; Queue().addOperation { BODY }', False),
        ('URLSession.shared.dataTask(with: url) { _,_,_ in }.resume()', True),
        ('let session = URLSession.shared; session.dataTask(with: url) { _,_,_ in }.resume()', True),
        ('URLSession.shared.dataTaskPublisher(for: url).sink(receiveCompletion: { _ in }, receiveValue: { _ in })', True),
        ('let publisher = URLSession.shared.dataTaskPublisher(for: url); publisher.sink(receiveCompletion: { _ in }, receiveValue: { _ in })', True),
        ('let publisher = URLSession.shared.dataTaskPublisher(for: url)', False),
        ('let task = URLSession.shared.dataTask(with: url) { _,_,_ in }', False),
        ('Trace.$current.withValue(1) { BODY }', True),
        ('Trace.$current.withValue({ BODY }) {}', False),
        ('withExtendedLifetime(1) { BODY }', True),
        ('withExtendedLifetime({ BODY }) {}', False),
        ('let operation = { BODY }; Trace.$current.withValue(1, operation: operation)', True),
        ('let operation = { BODY }; withExtendedLifetime(1, operation)', True),
        ('func withExtendedLifetime(_ value: Int, _ body: () -> Void) {}; withExtendedLifetime(1) { BODY }', False),
        ('func ignore(_ operation: @autoclosure () -> Void) {}; ignore(BODY)', False),
        ('func execute(_ operation: @autoclosure () -> Void) { operation() }; execute(BODY)', True),
        ('func execute(_ operation: @autoclosure () -> Void) { if false { operation() } }; execute(BODY)', False),
        ('func consume(_ operation: () -> Void) { operation() }; func execute(_ operation: @autoclosure () -> Void) { consume(operation) }; execute(BODY)', True),
        ('func ignore(_ operation: () -> Void) {}; func execute(_ operation: @autoclosure () -> Void) { ignore(operation) }; execute(BODY)', False),
        ('func consume(_ operation: @autoclosure () -> Void) { operation() }; func execute(_ operation: @autoclosure () -> Void) { consume(operation()) }; execute(BODY)', True),
        ('struct Consumer { func execute(_ operation: @autoclosure () -> Void) {} }; let consumer = Consumer(); consumer.execute(BODY)', False),
        ('struct Consumer { func execute(_ operation: @autoclosure () -> Void) { operation() } }; let consumer = Consumer(); consumer.execute(BODY)', True),
    )
    for body, expected in cases:
        path = 'Modules/Example/Sources/Service.swift'
        source = 'import Foundation; import Combine; public struct Service { public func fetch() { ' + body.replace(
            'BODY', 'Task { _ = try? await URLSession.shared.data(from: url) }') + ' } }'
        assert bool(business_methods(swift_syntax_index_sources({path: source}))) == expected, body
        if 'BODY' in body:
            source = 'struct ReleaseNetworkSmokeRunner { func run() { ' + body.replace('BODY', 'service.fetch()') + ' } }'
            facts = swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': source})
            calls = reachable_smoke_calls(facts)['network']
            assert any(call['calledExpression'] == 'service.fetch' for call in calls) == expected, body
    for body in ('DispatchQueue.main.asyncAfter(deadline: .distantFuture) { BODY }',
                 'Timer.scheduledTimer(withTimeInterval: 1_000_000_000, repeats: false) { _ in BODY }'):
        path = 'Modules/Example/Sources/Service.swift'
        source = 'import Foundation; public struct Service { public func fetch() { ' + body.replace(
            'BODY', 'Task { _ = try? await URLSession.shared.data(from: url) }') + ' } }'
        assert business_methods(swift_syntax_index_sources({path: source})), body
        source = 'struct ReleaseNetworkSmokeRunner { func run() { ' + body.replace('BODY', 'service.fetch()') + ' } }'
        calls = reachable_smoke_calls(swift_syntax_index_sources({'ReleaseNetworkSmoke.swift': source}))['network']
        assert not any(call['calledExpression'] == 'service.fetch' for call in calls), body


def foundation_network_self_test() -> None:
    from pathlib import Path
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods, method_signature
    from validation_test_areas import network_capability_findings
    source = '''import Foundation
public struct UnregisteredEndpoint {
    let client: HTTPClient
    public func fetch(url: URL) async throws -> Data { try await client.send(URLRequest(url: url)).data }
}'''
    for module in ('CourseFeature', 'TransportCore', 'CommunityTransport'):
        index = swift_syntax_index_sources({f'Modules/{module}/Sources/UnregisteredEndpoint.swift': source})
        assert {method_signature(method) for _, method in business_methods(index)[module + '.UnregisteredEndpoint']} == {'fetch(url:URL)'}
        assert any('新增生产服务' in finding for finding in network_capability_findings(index)), module
    assert business_methods(swift_syntax_index_sources({'ModuleTests/Support/TestFixture.swift': source})) == {}
    source = '''import Foundation
public struct HTTPClient {
    let session: URLSession
    public func send(_ request: URLRequest, accepting: Range<Int>, alsoAccepting: Set<Int>, maximumBytes: Int?) async throws -> Data {
        try await session.data(for: request).0
    }
    public func fetch(url: URL) async throws -> Data { try await session.data(for: URLRequest(url: url)).0 }
}'''
    index = swift_syntax_index_sources({'Modules/TransportCore/Sources/HTTPClient.swift': source})
    assert {method_signature(method) for _, method in business_methods(index)['TransportCore.HTTPClient']} == {'fetch(url:URL)'}
    root = Path(__file__).resolve().parents[1]
    sources = {str(path.relative_to(root)): path.read_text() for module in ('TransportCore', 'CommunityTransport')
        for path in (root / 'Modules' / module / 'Sources').rglob('*.swift')}
    assert business_methods(swift_syntax_index_sources(sources)) == {}


def package_test_module_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from swift_type_index import SwiftTypeIndex, compilation_unit
    root = Path(__file__).resolve().parents[1]
    support = 'ModuleTests/Support/MemoryFiles.swift'
    score = 'ModuleTests/Score/ScoreInfrastructureTests.swift'
    assert compilation_unit(support) == 'BIT101TestSupport'
    assert compilation_unit(score) == 'ScoreModuleTests'
    assert compilation_unit(str(root / support)) == 'BIT101TestSupport'
    index = swift_syntax_index_sources({path: (root / path).read_text() for path in (support, score)})
    types = SwiftTypeIndex(index)
    expected = ('BIT101TestSupport', ('ModuleScoreFiles',))
    assert types.resolve(support, 'ModuleScoreFiles') == expected
    assert types.resolve(score, 'ModuleScoreFiles', ['ScoreInfrastructureBoundaryTests']) == expected
    assert types.resolve(score, 'BIT101TestSupport.ModuleScoreFiles') == expected
    index[score]['imports'].remove('BIT101TestSupport')
    assert SwiftTypeIndex(index).resolve(score, 'ModuleScoreFiles') is None


def url_reader_network_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods
    reader_path = 'Modules/StorageCore/Sources/AppFileService.swift'
    for expression in ('Data(contentsOf: url)', 'NSData(contentsOf: url)', 'NSMutableData(contentsOf: url)',
            'String(contentsOf: url, encoding: .utf8)', 'NSString(contentsOf: url, encoding: 4)',
            'NSMutableString(contentsOf: url, encoding: 4)', 'XMLParser(contentsOf: url)',
            'Foundation.NSData(contentsOf: url)', 'Swift.String(contentsOf: url, encoding: .utf8)',
            'Bytes(contentsOf: url)', 'Foundation.Data.self.init(contentsOf: url)'):
        for guard, expected in (('', True), ('guard url.isFileURL else { throw Failure.invalid };', False)):
            source = ('import Foundation; public struct LocalAppFileService { typealias Bytes = Foundation.Data; public func fetch(_ url: URL) throws { '
                + guard + ' _ = try ' + expression + ' } }')
            methods = business_methods(swift_syntax_index_sources({reader_path: source}))
            assert bool(methods) == expected, (expression, guard, methods)
    for reference, kind, arguments in (
            ('Data.init(contentsOf:options:)', '(URL, Data.ReadingOptions) throws -> Data', 'url, []'),
            ('String.init(contentsOf:encoding:)', '(URL, String.Encoding) throws -> String', 'url, .utf8'),
            ('NSData.init(contentsOf:)', '(URL) -> NSData?', 'url')):
        for invocation, expected in (('', False), ('_ = try read(' + arguments + ')', True)):
            source = ('import Foundation; public struct LocalAppFileService { typealias Bytes = Foundation.Data; public func fetch(_ url: URL) async throws { '
                + f'let read: {kind} = {reference}; ' + invocation + ' } }')
            methods = business_methods(swift_syntax_index_sources({reader_path: source}))
            assert bool(methods) == expected, (reference, invocation, methods)
    for body in ('let data: Data = try .init(contentsOf: url)',
            'let text: String = try .init(contentsOf: url, encoding: .utf8)'):
        for guard, expected in (('', True), ('guard url.isFileURL else { throw Failure.invalid };', False)):
            source = 'import Foundation; public struct LocalAppFileService { public func fetch(_ url: URL) throws { ' + guard + body + ' } }'
            assert bool(business_methods(swift_syntax_index_sources({reader_path: source}))) == expected, (body, guard)
    source = 'struct Data { init(contentsOf url: URL) {} }; public struct LocalAppFileService { public func fetch(_ url: URL) { _ = Data(contentsOf: url) } }'
    assert not business_methods(swift_syntax_index_sources({reader_path: source}))


def module_coverage_binary_self_test() -> None:
    from unittest.mock import patch
    import validation_inputs as subject
    manifest = {'targets': [{'name': 'CurrentTests', 'type': 'test'}, {'name': 'Library', 'type': 'regular'}]}
    products = Path('/fixture/products')
    with patch.object(subject, 'read_manifest', return_value=manifest), patch.object(Path, 'is_file', return_value=True):
        assert subject.module_coverage_executables(Path('/fixture'), products) == [
            products / 'CurrentTests.xctest/Contents/MacOS/CurrentTests']
    with patch.object(subject, 'read_manifest', return_value=manifest), patch.object(Path, 'is_file', return_value=False):
        try: subject.module_coverage_executables(Path('/fixture'), products)
        except ValueError: pass
        else: raise AssertionError('当前测试消费者缺失需要停止覆盖率归集')
