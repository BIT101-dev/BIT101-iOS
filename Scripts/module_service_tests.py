"""Exercise module ownership checks."""

from pathlib import Path


from module_resource_tests import owned_source


def service_access_self_test(rules: dict) -> None:
    adapter_ownership_errors = rules["adapter_ownership_errors"]
    imported_aliases = rules["imported_aliases"]
    ownership_errors = rules["ownership_errors"]
    service_boundary_errors = rules["service_boundary_errors"]
    swift_syntax_index_sources = rules["swift_syntax_index_sources"]
    type_aliases = rules["type_aliases"]
    service_path = "BIT101-iOS/Example.swift"
    verify_adapter_resource_access(service_boundary_errors, service_path)
    verify_service_transport_access(
        imported_aliases,
        ownership_errors,
        rules,
        service_boundary_errors,
        service_path,
        swift_syntax_index_sources,
        type_aliases,
    )
    verify_native_resource_access(service_boundary_errors, service_path)
    verify_external_resource_access(
        adapter_ownership_errors,
        ownership_errors,
        service_boundary_errors,
        service_path,
        swift_syntax_index_sources,
    )


def verify_adapter_resource_access(service_boundary_errors, service_path):
    for source in (
        "let session = URLSession(configuration: configuration)",
        (
            "import CoreFoundation; let createSocket = CFSocketCreate; let connectSocket = CFSocke"
            "tConnectToAddress"
        ),
        (
            "let createStreams = CFStreamCreatePairWithSocketToHost; let connectPeer = CFStreamCre"
            "atePairWithPeerSocketSignature"
        ),
        "let connection = NSURLConnection(request: request, delegate: nil)",
        (
            "let read = CFNetwork.CFReadStreamCreateForHTTPRequest; let create = CFHTTPMessageCrea"
            "teRequest"
        ),
        (
            "import Darwin; let channel = socket(AF_INET, SOCK_STREAM, 0); connect(channel, addres"
            "s, size); send(channel, bytes, size, 0)"
        ),
        "let openSocket = Darwin.socket; let sendBytes = Glibc.send",
        "getaddrinfo(host, service, hints, result)",
        "Darwin.getnameinfo(address, size, host, hostSize, service, serviceSize, flags)",
        "let lookup = Glibc.getaddrinfo",
        (
            "import CoreFoundation; let readFile = CFReadStreamCreateWithFile; let writeFile = CFW"
            "riteStreamCreateWithFile"
        ),
        "try await transport.data(for: request)",
        "session.dataTask(with: request)",
        "let manager: FileManager = .default",
        "try Data(contentsOf: url)",
        "let bytes: Data = try .init(contentsOf: url)",
        "func parse(url: URL) throws { let bytes: Data = try .init(contentsOf: url) }",
        "let image = UIImage.init(contentsOfFile: path)",
        (
            "func persist(_ image: UIImage, directory: URL) throws { try image.pngData()?.write(to"
            ': directory.appendingPathComponent("x")) }'
        ),
        (
            "func persist(_ image: UIImage, directory: URL) throws { try image.jpegData(compressio"
            'nQuality: 1)?.write(to: directory.appending(path: "x")) }'
        ),
        (
            "func exists(_ url: NSURL) throws { var value: AnyObject?; try url.getResourceValue(&v"
            "alue, forKey: .fileSizeKey) }"
        ),
        "let stream = InputStream.init(url: url)",
        "var stream: InputStream?; stream = .init(url: url)",
        "func stream() -> InputStream? { .init(url: url) }",
        "let fd = open(path, O_RDONLY); read(fd, &buffer, count)",
        "let fd = Darwin.open(path, O_RDONLY); Darwin.read(fd, &buffer, count)",
        "Glibc.fopen(path, mode)",
        "try FileHandle(forReadingFrom: url)",
        "try String.init(contentsOf: url, encoding: .utf8)",
        "func save(data: Data, url: URL) throws { try data.write(to: url) }",
        (
            "func save(data: Data, url: URL) throws { let writer = data.write(to:options:); try wr"
            "iter(url, .atomic) }"
        ),
        (
            "func save(data: Data, url: URL) throws { let writer = data.write; try writer(url, .at"
            "omic) }"
        ),
        (
            "func save(text: String, url: URL) throws { let writer = text.write(to:atomically:enco"
            "ding:); try writer(url, true, .utf8) }"
        ),
        "let writer = Foundation.Data.write(to:options:)",
        (
            "func read(file: FileWrapper, url: URL) throws { let reader = file.read(from:options:)"
            "; try reader(url, []) }"
        ),
        (
            "func check(file: FileWrapper, url: URL) { let matches = file.matchesContents(of:); _ "
            "= matches(url) }"
        ),
        'try "value".write(toFile: path, atomically: true, encoding: .utf8)',
        "let data = Data(); try data.write(to: url)",
        "func bytes() -> Data { Data() }; try bytes().write(to: url)",
        "let data: Data? = nil; try data?.write(to: url)",
        "func dump(_ data: [Data], _ target: URL) throws { try data[0].write(to: target) }",
        "func dump(_ data: [Data?], _ target: URL) throws { try data[0]?.write(to: target) }",
        (
            'func dump(_ data: Dictionary<String, Data>, _ target: URL) throws { try data["key"]?.'
            "write(to: target) }"
        ),
        (
            "func dump(_ data: [Data], _ target: URL) throws { for item in data { try item.write(t"
            "o: target) } }"
        ),
        (
            "func dump(_ data: [Data], _ target: URL) throws { try data.forEach { try $0.write(to:"
            " target) } }"
        ),
        "func save(bytes: () -> Data, target: URL) throws { try bytes().write(to: target) }",
        (
            "func dump(_ values: [Data], _ target: URL) throws { let writer = values.first!.write("
            "to:options:); try writer(target, .atomic) }"
        ),
        (
            "func dump(_ values: Array<Data>, _ target: URL) throws { let writer = values.last!.wr"
            "ite(to:options:); try writer(target, .atomic) }"
        ),
        "func dump(_ values: [Data], _ target: URL) throws { try values.first?.write(to: target) }",
        (
            "struct Snapshot { let data: Data }; func dump(_ snapshot: Snapshot, _ target: URL) th"
            "rows { try snapshot.data.write(to: target) }"
        ),
        "Darwin.readlink(path, buffer, count)",
        "Darwin.removefile(path, state, 0)",
        "Darwin.copyfile(source, destination, state, 0)",
        "Darwin.getxattr(path, key, buffer, count, 0, 0)",
        "Darwin.realpath(path, buffer)",
        "let removeFile = Darwin.removefile; let pathResolver = Darwin.realpath",
        "func read(_ message: String) {}; read(fd, buffer, count)",
        "let data = try JSONEncoder().encode(value); try data.write(to: url)",
        (
            "let encoder = PropertyListEncoder(); let data = try encoder.encode(value); try data.w"
            "rite(to: url)"
        ),
        'let data = "hello".data(using: .utf8)!; try data.write(to: url)',
        "let data = try JSONSerialization.data(withJSONObject: value); try data.write(to: url)",
        "rename(old, new)",
        "remove(path)",
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
        (
            "func pick(_ flag: Bool, _ supplied: UserDefaults) -> UserDefaults { flag ? .standard "
            ": supplied }"
        ),
        "let preferences: [UserDefaults] = [.standard]",
        (
            'func accept(_ value: UserDefaults?) {}; accept(.standard); accept(.init(suiteName: "r'
            'eview"))'
        ),
        'struct State { let prefs: UserDefaults? }; State(prefs: .init(suiteName: "review"))',
        "UserDefaults.self.standard",
        'UserDefaults.self.init(suiteName: "review")',
        "try Data.self.init(contentsOf: url)",
        "let openFile = Darwin.open; let fd = openFile(path, 0)",
        "let underlying = error.userInfo[NSUnderlyingErrorKey]",
        "let allowed = CharacterSet.urlQueryAllowed",
        r'let text = "\(try Data(contentsOf: url))"',
    ):
        assert service_boundary_errors(service_path, source), source


def verify_service_transport_access(
    imported_aliases,
    ownership_errors,
    rules,
    service_boundary_errors,
    service_path,
    swift_syntax_index_sources,
    type_aliases,
):
    assert ownership_errors(
        "GalleryFeature", "struct Store { var defaults: UserDefaults { .standard } }"
    )
    assert ownership_errors("GalleryFeature", "AppFileSystem.self.files")
    assert ownership_errors(
        "GalleryFeature",
        "struct Store { let defaults: UserDefaults; init() { defaults = .standard } }",
    )
    for source in (
        'let defaults: UserDefaults? = .init(suiteName: "module-owned")',
        "let factory: () -> UserDefaults = UserDefaults.init; let preferences = factory()",
        "let factory: () -> LocalAppFileService = LocalAppFileService.init; let files = factory()",
        "func configure(defaults: UserDefaults? = .standard) {}",
        (
            "struct Store { var defaults: Foundation.UserDefaults?; func configure() { defaults = "
            '.init(suiteName: "module-owned") } }'
        ),
        'func preferences() -> UserDefaults? { .init(suiteName: "module-owned") }',
    ):
        assert ownership_errors("GalleryFeature", source), source
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source), (
            source
        )
    for source in (
        "typealias Preferences = UserDefaults; let store = Preferences.standard",
        (
            "typealias First = Foundation.UserDefaults; typealias Second = First; let store: Secon"
            "d = .standard"
        ),
        'typealias Preferences = UserDefaults; let store = Preferences(suiteName: "module-owned")',
        (
            "struct Owner { typealias Preferences = UserDefaults }; let store = Owner.Preferences."
            "standard"
        ),
        (
            "func configure() { typealias Preferences = UserDefaults; let store = Preferences.stan"
            "dard }"
        ),
        "typealias Session = URLSession; let session = Session.shared",
        "typealias Files = FileManager; let files = Files.default",
    ):
        assert ownership_errors("GalleryFeature", source), source
        assert service_boundary_errors(service_path, source), source
    assert (
        ownership_errors(
            "GalleryFeature", "let factory: (UserDefaults) -> Model = { _ in .standard }"
        )
        == []
    )
    alias_index = swift_syntax_index_sources(
        {"aliases.swift": "typealias First = UserDefaults; typealias Second = First"}
    )
    aliases = type_aliases(alias_index)
    assert ownership_errors(
        "GalleryFeature", "let store = Second.standard", "consumer.swift", aliases
    )
    assert service_boundary_errors("consumer.swift", "let store = Second.standard", aliases)
    external = type_aliases(
        swift_syntax_index_sources(
            {
                "Modules/StorageCore/Sources/Aliases.swift": (
                    "public typealias First = UserDefaults; public typealias Second = First; inter"
                    "nal typealias Local = UserDefaults; private typealias Hidden = UserDefaults"
                )
            }
        )
    )
    imported = imported_aliases("import StorageCore", (), external)
    consumer = "Modules/GalleryFeature/Sources/Consumer.swift"
    assert ownership_errors(
        "GalleryFeature", "import StorageCore; let store = Second.standard", consumer, imported
    )
    assert service_boundary_errors(
        consumer, "import StorageCore; let store = StorageCore.Second.standard", imported
    )
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls
    from unittest.mock import patch

    aliased = (
        "typealias C=CommunitySession; public struct ExampleService { let client: C; public func f"
        "() async throws { try await client.requestVoid(request) } }"
    )
    originals = {
        "Modules/NewForumFeature/Sources/Service.swift": aliased,
        "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift": (
            "typealias C=CommunitySession; struct ReleaseNetworkSmokeRunner { let client: C; func "
            "run() { mine.fetchMyInfo() } }"
        ),
    }
    expanded = {
        path: rules["expanded_resource_source"](source, (), path)
        for path, source in originals.items()
    }
    index = swift_syntax_index_sources(expanded)
    with (
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_text", lambda path, *args, **kwargs: originals[str(path)]),
    ):
        assert "NewForumFeature.ExampleService" in business_methods(index)
        assert "mine.fetchMyInfo" in {
            call["calledExpression"] for call in reachable_smoke_calls(index)["network"]
        }
    assert (
        ownership_errors(
            "GalleryFeature",
            (
                "import StorageCore; struct Second { static let standard = 1 }; let store = Second"
                ".standard"
            ),
            consumer,
            imported,
        )
        == []
    )
    assert (
        ownership_errors(
            "GalleryFeature",
            "import StorageCore; let store = Local.standard; let hidden = Hidden.standard",
            consumer,
            imported,
        )
        == []
    )
    assert (
        ownership_errors(
            "GalleryFeature",
            'typealias Preferences = UserDefaults; let text = "Preferences.standard"',
        )
        == []
    )
    assert (
        ownership_errors(
            "GalleryFeature",
            (
                "typealias Preferences = UserDefaults; struct Model { let Preferences: Int }; let "
                "value = model.Preferences"
            ),
        )
        == []
    )
    assert (
        ownership_errors(
            "GalleryFeature",
            (
                "typealias Preferences = UserDefaults; struct Item { var standard: Int }; let Pref"
                "erences = Item(standard: 1); let value = Preferences.standard"
            ),
        )
        == []
    )


def verify_native_resource_access(service_boundary_errors, service_path):
    assert service_boundary_errors(
        service_path,
        (
            "struct Item { static let standard = Item() }; struct Store { var defaults: UserDefaul"
            "ts; func configure() { defaults = .standard }; func helper() { let defaults: Item = ."
            "standard } }"
        ),
    )
    assert service_boundary_errors(
        service_path,
        (
            "struct Item { static let standard = Item() }; struct Store { var defaults: Item; func"
            " configure() { defaults = .standard }; func helper() { let defaults: UserDefaults = ."
            "standard } }"
        ),
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Item { static let standard = Item() }; struct Store { var defaults: Item; "
                "func configure() { defaults = .standard }; func helper() { let defaults: UserDefa"
                "ults } }"
            ),
        )
        == []
    )
    for source in (
        '// URLSession.shared\nlet text = #"Data(contentsOf: url)"#',
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
    assert (
        service_boundary_errors(
            "Modules/StorageCore/Sources/AppFileService.swift",
            owned_source("LocalAppFileService", "try data.write(to: url)"),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func write(to target: Int) {} }; let message = Message(); messag"
                "e.write(to: 42)"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func encode(_ value: Int) -> Message { self }; func write(to tar"
                "get: Int) {} }; let data = Message().encode(1); data.write(to: 42)"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "func remove(_ value: Int) {}; remove(42); func rename(_ a: Int, _ b: Int) {}; ren"
                "ame(1, 2)"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            'let read = "value"; print(read); let open: (Int) -> Bool = { $0 > 0 }; open(1)',
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path, 'func read(message: String = "") {}; read(message: "hello"); read()'
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func write(to target: Int) {} }; func bytes() -> Message { Messa"
                "ge() }; bytes().write(to: 42)"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func write(to target: Int) {} }; struct Snapshot { let data: Mes"
                "sage }; func send(snapshot: Snapshot, data: [Message]) { snapshot.data.write(to: "
                "42); data[0].write(to: 42) }"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            "struct Row { init(contentsOf: [Int]) {} }; let row: Row = .init(contentsOf: [1])",
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Row { init(contentsOf: [Int]) {}; static let standard = Row(contentsOf: []"
                ") }; func accept(_ row: Row) {}; accept(.standard); accept(.init(contentsOf: [1])"
                ")"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func write(to url: URL) {} }; func send(messages: [Message], url"
                ": URL) { for message in messages { message.write(to: url) } }"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func write(to target: Int) {} }; func send(message: Message) { m"
                "essage.write(to: 42) }"
            ),
        )
        == []
    )


def verify_external_resource_access(
    adapter_ownership_errors,
    ownership_errors,
    service_boundary_errors,
    service_path,
    swift_syntax_index_sources,
):
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func write(to target: Int) {} }; func send(message: Message) { l"
                "et writer = message.write(to:); writer(42) }"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func write(to target: Int) {} }; func send(message: Message) { l"
                "et writer = message.write; writer(42) }"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "struct Message { func write(to target: Int) {} }; func send(messages: [Message]) "
                "{ let writer = messages.first!.write(to:); writer(42) }"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            "Modules/TransportCore/Sources/HTTPClient.swift",
            owned_source("HTTPClient", "try await transport.data(for: request)"),
        )
        == []
    )
    assert (
        service_boundary_errors(
            service_path,
            (
                "func socket(_ value: Int) {}; socket(1); func send(_ value: Int) {}; send(1); enu"
                "m Delivery { case send; case preflight }"
            ),
        )
        == []
    )
    assert (
        service_boundary_errors(
            "Modules/TransportCore/Sources/SecureURLTransport.swift",
            owned_source("URLSessionTransport", "URLSession(configuration: configuration)"),
        )
        == []
    )
    assert (
        service_boundary_errors(
            "Modules/TransportCore/Sources/NetworkPathState.swift",
            owned_source("NetworkPathState", "NWPathMonitor()"),
        )
        == []
    )
    assert service_boundary_errors(
        "Modules/ScheduleFeature/Sources/Example.swift", "DateFormatter()"
    )
    assert (
        service_boundary_errors(
            "Modules/TransportCore/Sources/TaskCancellation.swift",
            owned_source("ErrorChain", "error.userInfo[NSUnderlyingErrorKey]"),
        )
        == []
    )
    assert (
        service_boundary_errors(
            "Modules/TransportCore/Sources/AppURL.swift",
            owned_source("HTTPFormEncoding", "CharacterSet.urlQueryAllowed"),
        )
        == []
    )
    assert (
        ownership_errors(
            "TransportCore",
            owned_source("URLSessionTransport", "URLCache.shared"),
            "Modules/TransportCore/Sources/Relocated.swift",
        )
        == []
    )
    assert ownership_errors(
        "TransportCore", "URLCache.shared", "Modules/TransportCore/Sources/HTTPClient.swift"
    )
    assert ownership_errors(
        "AppExternalDisplayCoordinator", "WatchScheduleSyncManager.shared.activateIfNeeded()"
    )
    assert ownership_errors("AppExternalDisplayCoordinator", "activateWatch()") == []
    relocated = swift_syntax_index_sources(
        {
            "BIT101-iOS/Relocated.swift": (
                "\nstruct AppExternalDisplayCoordinator { func activate() { activateWatch() } }\ne"
                "xtension AppExternalDisplayCoordinator { func unsafe() { WatchScheduleSyncManager"
                ".shared.activateIfNeeded() } }\n"
            )
        }
    )
    assert any(adapter_ownership_errors(facts) for facts in relocated.values())
    unrelated = swift_syntax_index_sources(
        {
            "BIT101-iOS/Composition.swift": (
                "struct Composition { let manager = WatchScheduleSyncManager.shared }"
            )
        }
    )
    assert all(adapter_ownership_errors(facts) == [] for facts in unrelated.values())
    for owner in (
        "AppLocalDataService",
        "SettingsNetworkService",
        "AboutSettingsPage",
        "AccountSettingsPage",
    ):
        relocated = swift_syntax_index_sources(
            {
                "BIT101-iOS/Relocated.swift": (
                    f"struct "
                    f"{owner}"
                    f" {{}}\nextension "
                    f"{owner}"
                    f" {{ func unsafe() {{ LoginStorage.shared.clearAllLocalData() }} }}"
                )
            }
        )
        assert any(adapter_ownership_errors(facts) for facts in relocated.values())

    for module, owner, operation in (
        ("TransportCore", "HTTPClient", "try await transport.data(for: request)"),
        ("TransportCore", "URLSessionTransport", "URLSession(configuration: configuration)"),
        ("TransportCore", "NetworkPathState", "NWPathMonitor()"),
        ("TransportCore", "ErrorChain", "error.userInfo[NSUnderlyingErrorKey]"),
        ("TransportCore", "HTTPFormEncoding", "CharacterSet.urlQueryAllowed"),
        ("StorageCore", "LocalAppFileService", "let data = Data(); try data.write(to: url)"),
        ("BIT101-iOS", "AppFileDirectories", "UserDefaults.standard"),
    ):
        path = (
            f"Modules/{module}/Sources/Relocated.swift"
            if module != "BIT101-iOS"
            else "BIT101-iOS/Relocated.swift"
        )
        approved = owned_source(owner, operation)
        assert service_boundary_errors(path, approved) == [], (owner, operation)
        assert service_boundary_errors(path, owned_source("Rogue", operation)), (owner, operation)
        assert service_boundary_errors(path, approved + "\n" + owned_source("Rogue", operation)), (
            owner,
            operation,
        )
        assert service_boundary_errors(
            "Modules/GalleryFeature/Sources/Relocated.swift", approved
        ), (owner, operation)
    assert (
        service_boundary_errors(
            "Modules/StorageCore/Sources/Relocated.swift",
            (
                "struct LocalAppFileService {}; extension LocalAppFileService { func read() { try "
                "Data(contentsOf: url) } }"
            ),
        )
        == []
    )
    assert service_boundary_errors(
        "Modules/StorageCore/Sources/AppFileService.swift",
        "struct LocalAppFileService { struct Rogue { func read() { try Data(contentsOf: url) } } }",
    )
