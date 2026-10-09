"""Regression cases for the module and resource ownership rules."""
import re
from pathlib import Path


def run_self_test(rules: dict) -> None:
    adapter_ownership_errors = rules["adapter_ownership_errors"]
    adapter_roles = rules["adapter_roles"]
    compilation_type_context = rules["compilation_type_context"]
    graph_errors = rules["graph_errors"]
    imported_aliases = rules["imported_aliases"]
    imports_in_text = rules["imports_in_text"]
    manifest_targets = rules["manifest_targets"]
    ownership_errors = rules["ownership_errors"]
    platform_errors = rules["platform_errors"]
    raw_imports = rules["raw_imports"]
    service_boundary_errors = rules["service_boundary_errors"]
    swift_code = rules["swift_code"]
    swift_syntax_index_sources = rules["swift_syntax_index_sources"]
    type_aliases = rules["type_aliases"]
    from validation_policy import IOS_MODULE_COVERAGE_FLOORS
    from validation_test_areas import network_capability_self_test
    network_capability_self_test()
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
    for dependency in ('ScheduleDomain', 'SchedulePorts', 'CommunityCore'):
        assert graph_errors({'ScoreFeature': {dependency}, dependency: set()})
    assert graph_errors({'GalleryFeature': {'CommunityCore', 'MediaKit'}, 'CommunityCore': set(), 'MediaKit': set()}) == []
    assert graph_errors({'MapFeature': {'ScheduleContracts'}, 'ScheduleContracts': set()}) == []
    assert graph_errors({'MapFeature': {'SchedulePorts'}, 'SchedulePorts': set()})
    registered_modules = set(IOS_MODULE_COVERAGE_FLOORS)
    assert rules["coverage_registry_findings"](registered_modules) == []
    assert rules["coverage_registry_findings"](registered_modules | {"NewModule"})
    assert rules["coverage_registry_findings"](registered_modules - {"TransportCore"})

    from unittest.mock import patch
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
    for source in (
        "let group = NWConnectionGroup(with: descriptor, using: .udp); group.send(content: data)",
        "let group = Network.NWConnectionGroup(with: descriptor, using: .udp)",
        "typealias Group = NWConnectionGroup; let group = Group(with: descriptor, using: .udp)",
        "let io = DispatchIO(type: .stream, path: path, oflag: 0, mode: 0, queue: queue) { _ in }",
        "let io = Dispatch.DispatchIO(type: .stream, path: path, oflag: 0, mode: 0, queue: queue) { _ in }",
    ):
        assert service_boundary_errors("Modules/CourseFeature/Sources/Example.swift", source), source
    assert service_boundary_errors("Modules/StorageCore/Sources/AppFileService.swift", "let io = DispatchIO(type: .stream, path: path)") == []

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
        assert service_boundary_errors("Modules/StorageCore/Sources/AppFileService.swift", source) == []
    assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", "let wrapper = FileWrapper(regularFileWithContents: Data())") == []
    assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", "struct Wrapper { func read(from item: Int) {} }; let value = Wrapper(); value.read(from: 1)") == []
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
        "import Darwin; let channel = socket(AF_INET, SOCK_STREAM, 0); connect(channel, address, size); send(channel, bytes, size, 0)",
        "let openSocket = Darwin.socket; let sendBytes = Glibc.send",
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
        "struct Snapshot { let data: Data }; func dump(_ snapshot: Snapshot, _ target: URL) throws { try snapshot.data.write(to: target) }",
        "Darwin.readlink(path, buffer, count)",
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
    assert service_boundary_errors("Modules/StorageCore/Sources/AppFileService.swift", "try data.write(to: url)") == []
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
    assert service_boundary_errors("Modules/TransportCore/Sources/HTTPClient.swift", "try await transport.data(for: request)") == []
    assert service_boundary_errors(service_path, "func socket(_ value: Int) {}; socket(1); func send(_ value: Int) {}; send(1); enum Delivery { case send; case preflight }") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/SecureURLTransport.swift", "URLSession(configuration: configuration)") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/NetworkPathState.swift", "NWPathMonitor()") == []
    assert service_boundary_errors("Modules/ScheduleFeature/Sources/Example.swift", "DateFormatter()")
    assert service_boundary_errors("Modules/TransportCore/Sources/TaskCancellation.swift", "error.userInfo[NSUnderlyingErrorKey]") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/AppURL.swift", "CharacterSet.urlQueryAllowed") == []
    assert ownership_errors("TransportCore", "URLCache.shared", "Modules/TransportCore/Sources/SecureURLTransport.swift") == []
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
