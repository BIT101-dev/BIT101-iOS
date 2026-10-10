"""Regression cases for type ownership across modules and private declaration files."""
from pathlib import Path
from swift_source_index import ROOT, swift_syntax_index_sources, declaration_conformances, canonical_type_scope
from swift_type_index import SwiftTypeIndex


def self_test():
    from io import BytesIO
    from unittest.mock import patch
    from swift_source_index import indexer_toolchain
    compiler = Path('/toolchain/usr/bin/swiftc')
    host_modules = Path('/toolchain/usr/lib/swift/host')
    artifacts = {str(compiler): b'compiler', str(host_modules / 'libSwiftSyntax.dylib'): b'syntax',
        str(host_modules / 'libSwiftParser.dylib'): b'parser', str(host_modules / 'libSwiftOperators.dylib'): b'operators'}
    with patch('validation_environment.environment_context', return_value={'compiler': {'sha256': 'frontend'}}), \
         patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'rglob', return_value=[]), \
         patch.object(Path, 'open', lambda path, *args, **kwargs: BytesIO(artifacts[str(path)])), \
         patch.object(Path, 'stat', side_effect=AssertionError('工具链指纹沿文件内容验收')):
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
