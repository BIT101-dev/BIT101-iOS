"""Exercise module ownership checks."""

from pathlib import Path


def owned_source(owner: str, source: str) -> str:
    return f"struct {owner} {{ func execute() {{ {source} }} }}"


def callback_execution_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from validation_test_areas import reachable_smoke_calls
    from network_capability_rules import business_methods

    cases = (
        ("let operation = { BODY }; Task(operation: operation)", True),
        ("let operation = { BODY }; let alias = operation; Task.detached(operation: alias)", True),
        ("let operation = { BODY }; Task.init(operation: operation)", True),
        ("DispatchQueue.global().async(execute: DispatchWorkItem { BODY })", True),
        ("let work = DispatchWorkItem { BODY }; DispatchQueue.main.async(execute: work)", True),
        ("let work = DispatchWorkItem { BODY }; let alias = work; alias.perform()", True),
        (
            (
                "let operation = { BODY }; DispatchQueue.main.async(execute: DispatchWorkItem(bloc"
                "k: operation))"
            ),
            True,
        ),
        ("OperationQueue.main.addOperation { BODY }", True),
        ("let operation = { BODY }; OperationQueue.main.addOperation(operation)", True),
        (
            (
                "func execute(_ operation: @escaping () -> Void) { let alias = operation; Task(ope"
                "ration: alias) }; execute { BODY }"
            ),
            True,
        ),
        (
            (
                "func forward(_ operation: @escaping () -> Void) { Task(operation: operation) }; f"
                "unc execute(_ operation: @escaping () -> Void) { let alias = operation; forward(a"
                "lias) }; execute { BODY }"
            ),
            True,
        ),
        (
            (
                "func execute(_ operation: @escaping () -> Void) { let alias = operation }; execut"
                "e { BODY }"
            ),
            False,
        ),
        ("let operation = { BODY }", False),
        ("let work = DispatchWorkItem { BODY }", False),
        ("let operation = { BODY }; if false { Task(operation: operation) }", False),
        ("let operation = { BODY }; let unused = { Task(operation: operation) }", False),
        ("let operation = { BODY }; do { let operation = {}; Task(operation: operation) }", False),
        (
            (
                "struct Queue { func addOperation(_ block: () -> Void) {} }; Queue().addOperation "
                "{ BODY }"
            ),
            False,
        ),
        ("URLSession.shared.dataTask(with: url) { _,_,_ in }.resume()", True),
        (
            "let session = URLSession.shared; session.dataTask(with: url) { _,_,_ in }.resume()",
            True,
        ),
        (
            (
                "URLSession.shared.dataTaskPublisher(for: url).sink(receiveCompletion: { _ in }, r"
                "eceiveValue: { _ in })"
            ),
            True,
        ),
        (
            (
                "let publisher = URLSession.shared.dataTaskPublisher(for: url); publisher.sink(rec"
                "eiveCompletion: { _ in }, receiveValue: { _ in })"
            ),
            True,
        ),
        ("let publisher = URLSession.shared.dataTaskPublisher(for: url)", False),
        ("let task = URLSession.shared.dataTask(with: url) { _,_,_ in }", False),
        ("Trace.$current.withValue(1) { BODY }", True),
        ("Trace.$current.withValue({ BODY }) {}", False),
        ("withExtendedLifetime(1) { BODY }", True),
        ("withExtendedLifetime({ BODY }) {}", False),
        ("let operation = { BODY }; Trace.$current.withValue(1, operation: operation)", True),
        ("let operation = { BODY }; withExtendedLifetime(1, operation)", True),
        (
            (
                "func withExtendedLifetime(_ value: Int, _ body: () -> Void) {}; withExtendedLifet"
                "ime(1) { BODY }"
            ),
            False,
        ),
        ("func ignore(_ operation: @autoclosure () -> Void) {}; ignore(BODY)", False),
        ("func execute(_ operation: @autoclosure () -> Void) { operation() }; execute(BODY)", True),
        (
            (
                "func execute(_ operation: @autoclosure () -> Void) { if false { operation() } }; "
                "execute(BODY)"
            ),
            False,
        ),
        (
            (
                "func consume(_ operation: () -> Void) { operation() }; func execute(_ operation: "
                "@autoclosure () -> Void) { consume(operation) }; execute(BODY)"
            ),
            True,
        ),
        (
            (
                "func ignore(_ operation: () -> Void) {}; func execute(_ operation: @autoclosure ("
                ") -> Void) { ignore(operation) }; execute(BODY)"
            ),
            False,
        ),
        (
            (
                "func consume(_ operation: @autoclosure () -> Void) { operation() }; func execute("
                "_ operation: @autoclosure () -> Void) { consume(operation()) }; execute(BODY)"
            ),
            True,
        ),
        (
            (
                "struct Consumer { func execute(_ operation: @autoclosure () -> Void) {} }; let co"
                "nsumer = Consumer(); consumer.execute(BODY)"
            ),
            False,
        ),
        (
            (
                "struct Consumer { func execute(_ operation: @autoclosure () -> Void) { operation("
                ") } }; let consumer = Consumer(); consumer.execute(BODY)"
            ),
            True,
        ),
    )
    for body, expected in cases:
        path = "Modules/Example/Sources/Service.swift"
        source = (
            "import Foundation; import Combine; public struct Service { public func fetch() { "
            + body.replace("BODY", "Task { _ = try? await URLSession.shared.data(from: url) }")
            + " } }"
        )
        assert bool(business_methods(swift_syntax_index_sources({path: source}))) == expected, body
        if "BODY" in body:
            source = (
                "struct ReleaseNetworkSmokeRunner { func run() { "
                + body.replace("BODY", "service.fetch()")
                + " } }"
            )
            facts = swift_syntax_index_sources({"ReleaseNetworkSmoke.swift": source})
            calls = reachable_smoke_calls(facts)["network"]
            assert any(call["calledExpression"] == "service.fetch" for call in calls) == expected, (
                body
            )
    for body in (
        "DispatchQueue.main.asyncAfter(deadline: .distantFuture) { BODY }",
        "Timer.scheduledTimer(withTimeInterval: 1_000_000_000, repeats: false) { _ in BODY }",
    ):
        path = "Modules/Example/Sources/Service.swift"
        source = (
            "import Foundation; public struct Service { public func fetch() { "
            + body.replace("BODY", "Task { _ = try? await URLSession.shared.data(from: url) }")
            + " } }"
        )
        assert business_methods(swift_syntax_index_sources({path: source})), body
        source = (
            "struct ReleaseNetworkSmokeRunner { func run() { "
            + body.replace("BODY", "service.fetch()")
            + " } }"
        )
        calls = reachable_smoke_calls(
            swift_syntax_index_sources({"ReleaseNetworkSmoke.swift": source})
        )["network"]
        assert not any(call["calledExpression"] == "service.fetch" for call in calls), body


def foundation_network_self_test() -> None:
    from pathlib import Path
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods, method_signature
    from validation_test_areas import network_capability_findings

    source = (
        "import Foundation\npublic struct UnregisteredEndpoint {\n    let client: HTTPClient\n    "
        "public func fetch(url: URL) async throws -> Data { try await client.send(URLRequest(url: "
        "url)).data }\n}"
    )
    for module in ("CourseFeature", "TransportCore", "CommunityTransport"):
        index = swift_syntax_index_sources(
            {f"Modules/{module}/Sources/UnregisteredEndpoint.swift": source}
        )
        assert {
            method_signature(method)
            for _, method in business_methods(index)[module + ".UnregisteredEndpoint"]
        } == {"fetch(url:URL)"}
        assert any("新增生产服务" in finding for finding in network_capability_findings(index)), (
            module
        )
    assert (
        business_methods(
            swift_syntax_index_sources({"ModuleTests/Support/TestFixture.swift": source})
        )
        == {}
    )
    source = (
        "import Foundation\npublic struct HTTPClient {\n    let session: URLSession\n    public fu"
        "nc send(_ request: URLRequest, accepting: Range<Int>, alsoAccepting: Set<Int>, maximumByt"
        "es: Int?) async throws -> Data {\n        try await session.data(for: request).0\n    }\n"
        "    public func fetch(url: URL) async throws -> Data { try await session.data(for: URLReq"
        "uest(url: url)).0 }\n}"
    )
    index = swift_syntax_index_sources({"Modules/TransportCore/Sources/HTTPClient.swift": source})
    assert {
        method_signature(method)
        for _, method in business_methods(index)["TransportCore.HTTPClient"]
    } == {"fetch(url:URL)"}
    root = Path(__file__).resolve().parents[1]
    sources = {
        str(path.relative_to(root)): path.read_text()
        for module in ("TransportCore", "CommunityTransport")
        for path in (root / "Modules" / module / "Sources").rglob("*.swift")
    }
    assert business_methods(swift_syntax_index_sources(sources)) == {}


def package_test_module_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from swift_type_index import SwiftTypeIndex, compilation_unit

    root = Path(__file__).resolve().parents[1]
    support = "ModuleTests/Support/MemoryFiles.swift"
    score = "ModuleTests/Score/ScoreInfrastructureTests.swift"
    assert compilation_unit(support) == "BIT101TestSupport"
    assert compilation_unit(score) == "ScoreModuleTests"
    assert compilation_unit(str(root / support)) == "BIT101TestSupport"
    index = swift_syntax_index_sources(
        {path: (root / path).read_text() for path in (support, score)}
    )
    types = SwiftTypeIndex(index)
    expected = ("BIT101TestSupport", ("ModuleScoreFiles",))
    assert types.resolve(support, "ModuleScoreFiles") == expected
    assert (
        types.resolve(score, "ModuleScoreFiles", ["ScoreInfrastructureBoundaryTests"]) == expected
    )
    assert types.resolve(score, "BIT101TestSupport.ModuleScoreFiles") == expected
    index[score]["imports"].remove("BIT101TestSupport")
    assert SwiftTypeIndex(index).resolve(score, "ModuleScoreFiles") is None


def url_reader_network_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods

    reader_path = "Modules/StorageCore/Sources/AppFileService.swift"
    for expression in (
        "Data(contentsOf: url)",
        "NSData(contentsOf: url)",
        "NSMutableData(contentsOf: url)",
        "String(contentsOf: url, encoding: .utf8)",
        "NSString(contentsOf: url, encoding: 4)",
        "NSMutableString(contentsOf: url, encoding: 4)",
        "XMLParser(contentsOf: url)",
        "Foundation.NSData(contentsOf: url)",
        "Swift.String(contentsOf: url, encoding: .utf8)",
        "Bytes(contentsOf: url)",
        "Foundation.Data.self.init(contentsOf: url)",
    ):
        for guard, expected in (
            ("", True),
            ("guard url.isFileURL else { throw Failure.invalid };", False),
        ):
            source = (
                (
                    "import Foundation; public struct LocalAppFileService { typealias Bytes = Foun"
                    "dation.Data; public func fetch(_ url: URL) throws { "
                )
                + guard
                + " _ = try "
                + expression
                + " } }"
            )
            methods = business_methods(swift_syntax_index_sources({reader_path: source}))
            assert bool(methods) == expected, (expression, guard, methods)
    for reference, kind, arguments in (
        ("Data.init(contentsOf:options:)", "(URL, Data.ReadingOptions) throws -> Data", "url, []"),
        (
            "String.init(contentsOf:encoding:)",
            "(URL, String.Encoding) throws -> String",
            "url, .utf8",
        ),
        ("NSData.init(contentsOf:)", "(URL) -> NSData?", "url"),
    ):
        for invocation, expected in (("", False), ("_ = try read(" + arguments + ")", True)):
            source = (
                (
                    "import Foundation; public struct LocalAppFileService { typealias Bytes = Foun"
                    "dation.Data; public func fetch(_ url: URL) async throws { "
                )
                + f"let read: {kind} = {reference}; "
                + invocation
                + " } }"
            )
            methods = business_methods(swift_syntax_index_sources({reader_path: source}))
            assert bool(methods) == expected, (reference, invocation, methods)
    for body in (
        "let data: Data = try .init(contentsOf: url)",
        "let text: String = try .init(contentsOf: url, encoding: .utf8)",
    ):
        for guard, expected in (
            ("", True),
            ("guard url.isFileURL else { throw Failure.invalid };", False),
        ):
            source = (
                (
                    "import Foundation; public struct LocalAppFileService { public func fetch(_ ur"
                    "l: URL) throws { "
                )
                + guard
                + body
                + " } }"
            )
            assert (
                bool(business_methods(swift_syntax_index_sources({reader_path: source})))
                == expected
            ), (body, guard)
    source = (
        "struct Data { init(contentsOf url: URL) {} }; public struct LocalAppFileService { public "
        "func fetch(_ url: URL) { _ = Data(contentsOf: url) } }"
    )
    assert not business_methods(swift_syntax_index_sources({reader_path: source}))


def module_coverage_binary_self_test() -> None:
    from unittest.mock import patch
    import validation_inputs as subject

    manifest = {
        "targets": [
            {"name": "CurrentTests", "type": "test"},
            {"name": "Library", "type": "regular"},
        ]
    }
    products = Path("/fixture/products")
    with (
        patch.object(subject, "read_manifest", return_value=manifest),
        patch.object(Path, "is_file", return_value=True),
    ):
        assert subject.module_coverage_executables(Path("/fixture"), products) == [
            products / "CurrentTests.xctest/Contents/MacOS/CurrentTests"
        ]
    with (
        patch.object(subject, "read_manifest", return_value=manifest),
        patch.object(Path, "is_file", return_value=False),
    ):
        try:
            subject.module_coverage_executables(Path("/fixture"), products)
        except ValueError:
            pass
        else:
            raise AssertionError("当前测试消费者缺失需要停止覆盖率归集")


def resource_access_self_test(rules: dict) -> None:
    compilation_type_context = rules["compilation_type_context"]
    graph_errors = rules["graph_errors"]
    ownership_errors = rules["ownership_errors"]
    for declaration, invocation, restricted in [
        (
            "func consume(_ prefs: UserDefaults, enabled: Bool = true) {}",
            "consume(.standard)",
            True,
        ),
        (
            "func consume(enabled: Bool = true, _ prefs: UserDefaults) {}",
            "consume(.standard)",
            True,
        ),
        (
            "func consume(_ enabled: Bool = true, _ prefs: UserDefaults) {}",
            "consume(.standard)",
            True,
        ),
        (
            "func consume(_ prefs: UserDefaults, enabled: Bool = true, _ value: Int) {}",
            "consume(.standard, 1)",
            True,
        ),
        ("func consume(_ prefs: UserDefaults...) {}", "consume(.standard, .standard)", True),
        (
            "struct Owner { init(_ prefs: UserDefaults, enabled: Bool = true) {} }",
            "Owner(.standard)",
            True,
        ),
        ("func consume(_ prefs: Model, enabled: Bool = true) {}", "consume(.standard)", False),
        ("func consume(prefs: UserDefaults, enabled: Bool = true) {}", "consume(.standard)", False),
    ]:
        assert (
            bool(ownership_errors("PaperFeature", declaration + "; " + invocation)) == restricted
        ), (declaration, invocation)
    default_wrapper = (
        "func consume(_ wrapper: FileWrapper, enabled: Bool = true) {}; consume(.init(url: url, op"
        "tions: []))"
    )
    assert rules["service_boundary_errors"]("BIT101-iOS/Example.swift", default_wrapper)
    from swift_type_index import SwiftBindingTypes

    source = (
        "struct Value { static var standard: Value { Value() } }; struct Other { func consume(_ va"
        "lue: Value) {} }; struct Probe { let other = Other(); func consume(_ prefs: UserDefaults)"
        " {}; func run() { other.consume(.standard) } }"
    )
    assert not ownership_errors("PaperFeature", source)
    split_path = "Modules/PaperFeature/Sources/Probe.swift"
    for signature, invocation, restricted in [
        (
            "func consume(_ prefs: UserDefaults, enabled: Bool = true) {}",
            "consume(.standard)",
            True,
        ),
        ("func consume(_ prefs: Value, enabled: Bool = true) {}", "consume(.standard)", False),
        ("private func consume(_ prefs: UserDefaults) {}", "consume(.standard)", False),
    ]:
        sources = {
            split_path: "struct Probe { func run() { " + invocation + " } }",
            "Modules/PaperFeature/Sources/Support.swift": "extension Probe { " + signature + " }",
        }
        index = rules["swift_syntax_index_sources"](sources)
        call_context = SwiftBindingTypes(index)
        assert (
            bool(
                ownership_errors(
                    "PaperFeature", sources[split_path], split_path, call_context=call_context
                )
            )
            == restricted
        )
        assert (
            bool(
                rules["service_boundary_errors"](
                    split_path, sources[split_path], call_context=call_context
                )
            )
            == restricted
        )
    service_boundary_errors = rules["service_boundary_errors"]
    for source in (
        "let data = NSData(contentsOfMappedFile: path)",
        "let data: NSData? = .init(contentsOfMappedFile: path)",
    ):
        assert service_boundary_errors("Modules/PaperFeature/Sources/Probe.swift", source)
        assert not service_boundary_errors(
            "Modules/StorageCore/Sources/AppFileService.swift",
            owned_source("LocalAppFileService", source),
        )
    for expression in (
        "CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication)",
        "CoreFoundation.CFPreferencesSetAppValue(key, value, kCFPreferencesCurrentApplication)",
    ):
        assert service_boundary_errors("Modules/PaperFeature/Sources/Probe.swift", expression)
        assert ownership_errors("PaperFeature", expression)
    for kind in (
        "SearchPathDirectory",
        "SearchPathDomainMask",
        "DirectoryEnumerationOptions",
        "VolumeEnumerationOptions",
        "URLRelationship",
        "ItemReplacementOptions",
    ):
        assert not service_boundary_errors(
            "Modules/PaperFeature/Sources/Probe.swift",
            f"struct Probe {{ let mask: FileManager.{kind} }}",
        )
    swift_syntax_index_sources = rules["swift_syntax_index_sources"]
    from validation_policy import IOS_MODULE_COVERAGE_FLOORS
    from network_capability_tests import network_capability_self_test
    from validation_test_areas import smoke_scope_self_test, smoke_scalar_self_test

    callback_execution_self_test()
    url_reader_network_self_test()
    foundation_network_self_test()
    network_capability_self_test()
    smoke_scope_self_test()
    smoke_scalar_self_test()
    exported = swift_syntax_index_sources(
        {
            "Modules/GalleryFeature/Sources/Service.swift": """
        public struct GalleryService { func internalMember() {} }
        public extension GalleryService {
            func exportedMember() { func localHelper() {}; localHelper() }
            internal func internalOverride() {}
            private func privateMember() {}
        }
        extension GalleryService { public func explicitMember() {} }
    """
        }
    )
    methods = next(iter(exported.values()))["functionRanges"]
    assert {function["name"] for function in methods if function["isExported"]} == {
        "exportedMember",
        "explicitMember",
    }
    assert graph_errors({"CourseDomain": {"ScoreDomain"}, "ScoreDomain": set()})
    assert graph_errors(
        {"ScheduleInfrastructure": {"ScoreInfrastructure"}, "ScoreInfrastructure": set()}
    )
    assert (
        graph_errors({"ScheduleInfrastructure": {"ScheduleDomain"}, "ScheduleDomain": set()}) == []
    )
    for source in ("ScoreDomain", "ScheduleContracts"):
        for dependency in ("TransportCore", "ClientCore", "StorageCore"):
            assert any(
                "pure " in error
                for error in graph_errors({source: {dependency}, dependency: set()})
            )
    assert graph_errors({"ScheduleDomain": {"ScheduleCore"}, "ScheduleCore": set()}) == []
    assert any(
        "pure domain boundary: ScheduleDomain -> TransportCore" in error
        for error in graph_errors(
            {
                "ScheduleDomain": {"ScheduleCore"},
                "ScheduleCore": {"TransportCore"},
                "TransportCore": set(),
            }
        )
    )
    for dependency in ("ScheduleDomain", "SchedulePorts", "CommunityCore"):
        assert graph_errors({"ScoreFeature": {dependency}, dependency: set()})
    assert (
        graph_errors(
            {
                "GalleryFeature": {"CommunityCore", "MediaKit"},
                "CommunityCore": set(),
                "MediaKit": set(),
            }
        )
        == []
    )
    assert graph_errors({"MapFeature": {"ScheduleContracts"}, "ScheduleContracts": set()}) == []
    assert graph_errors({"MapFeature": {"SchedulePorts"}, "SchedulePorts": set()})
    registered_modules = set(IOS_MODULE_COVERAGE_FLOORS)
    assert rules["coverage_registry_findings"](registered_modules) == []
    assert rules["coverage_registry_findings"](registered_modules | {"NewModule"})
    assert rules["coverage_registry_findings"](registered_modules - {"TransportCore"})
    from validation_policy import UI_PRODUCTION_MODULES

    assert rules["coverage_registry_findings"](registered_modules, set(UI_PRODUCTION_MODULES)) == []
    assert rules["coverage_registry_findings"](
        registered_modules, set(UI_PRODUCTION_MODULES) - {"MediaKit"}
    )
    assert rules["coverage_registry_findings"](
        registered_modules, set(UI_PRODUCTION_MODULES) | {"StorageCore"}
    )

    from unittest.mock import patch
    from development_workflow_tests import native_target_inventory_self_test

    native_target_inventory_self_test(rules)
    from swift_type_index import compilation_unit

    assert compilation_unit("/workspace/BIT101-iOS/BIT101Watch/Source.swift") == "BIT101Watch"
    module = rules["resource_facts"].__module__
    rules["resource_facts"].cache_clear()
    source = (
        "func probe() { let data = Data(); try data.write(to: url); _ = Darwin.open(path, 0); let "
        "defaults: UserDefaults = .standard }"
    )
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
        "Writer.swift": (
            "struct Writer { let payload: Data; let destination: URL }; struct Message { func writ"
            "e(to value: Int) {} }; struct Sender { let payload: Message; let destination: Int }"
        ),
        "WriterActions.swift": (
            "extension Writer { func save() throws { try payload.write(to: destination) } }"
        ),
        "WriterReferences.swift": (
            "extension Writer { func save() throws { let writer = self.payload.write(to:options:);"
            " try writer(destination, .atomic) } }"
        ),
        "SenderActions.swift": (
            "extension Sender { func send() { let writer = payload.write(to:); writer(destination)"
            " } }"
        ),
    }
    file_context = compilation_type_context(swift_syntax_index_sources(file_sources))
    for name in ("WriterActions.swift", "WriterReferences.swift"):
        assert service_boundary_errors(
            "Modules/GalleryFeature/Sources/" + name, file_sources[name], context=file_context
        ), name
    assert (
        service_boundary_errors(
            "Modules/GalleryFeature/Sources/SenderActions.swift",
            file_sources["SenderActions.swift"],
            context=file_context,
        )
        == []
    )
    for kind, restricted in (("Data", True), ("Message", False)):
        source = (
            f"struct Message {{ func write(to: URL, options: Int) {{}} }}\n           "
            f" struct Probe {{ func payload() -> "
            f"{kind}"
            f" {{ fatalError() }}; func location() -> URL {{ fatalError() }}\n        "
            f"        func save() throws {{ try self.payload().write(to: self.locat"
            f"ion(), options: .atomic) }} }}"
        )
        assert bool(service_boundary_errors(split_path, source)) == restricted
    for value, restricted in (
        ('let preferenceType = UserDefaults.self; _ = preferenceType(suiteName: "store")', True),
        (
            (
                "let preferenceType: UserDefaults.Type = UserDefaults.self; _ = preferenceType(sui"
                'teName: "store")'
            ),
            True,
        ),
        (
            (
                "let preferenceType = Foundation.UserDefaults.self; let copied = preferenceType; _"
                " = copied.standard"
            ),
            True,
        ),
        (
            (
                "let preferenceType = UserDefaults.self; do { let preferenceType = Other.self; _ ="
                " preferenceType() }"
            ),
            False,
        ),
        ("let preferenceType = UserDefaults.self; _ = other.preferenceType()", False),
    ):
        source = "struct Other {}; func run() { " + value + " }"
        assert bool(ownership_errors("PaperFeature", source)) == restricted
        assert bool(service_boundary_errors(split_path, source)) == restricted
    sources = {
        split_path: (
            "extension Probe { func save() throws { try self.payload().write(to: self.location()) "
            "} }"
        ),
        "Modules/PaperFeature/Sources/Support.swift": (
            "struct Probe { func payload() -> Data { fatalError() }; func location() -> URL { fata"
            "lError() } }"
        ),
    }
    index = swift_syntax_index_sources(sources)
    assert service_boundary_errors(
        split_path, sources[split_path], call_context=SwiftBindingTypes(index)
    )
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
        (
            "let io = Dispatch.DispatchIO(type: .stream, path: path, oflag: 0, mode: 0, queue: que"
            "ue) { _ in }"
        ),
    ):
        assert service_boundary_errors("Modules/CourseFeature/Sources/Example.swift", source), (
            source
        )
    assert (
        service_boundary_errors(
            "Modules/StorageCore/Sources/AppFileService.swift",
            owned_source("LocalAppFileService", "let io = DispatchIO(type: .stream, path: path)"),
        )
        == []
    )
    control = owned_source(
        "UITestControlServer",
        "let listener = try NWListener(using: .tcp); let connection: NWConnection = accepted",
    )
    assert service_boundary_errors("BIT101-iOS/Login/AppUITestBootstrap.swift", control) == []
    for source in (
        "let provider = CGDataProvider(url: url as CFURL)",
        "let provider = CoreGraphics.CGDataProvider(url: url as CFURL)",
        "let provider: CGDataProvider = .init(url: url as CFURL)",
        "typealias Provider = CGDataProvider; let provider: Provider = .init(url: url as CFURL)",
        "let document = CGPDFDocument(url as CFURL)",
        "let document = CoreGraphics.CGPDFDocument(url as CoreFoundation.CFURL)",
        "func load(url: CFURL) { let document = CGPDFDocument(url) }",
        "typealias Document = CGPDFDocument; let document = Document(url as CFURL)",
        "let read = CGDataProvider.init(url:)",
        "let read: (CFURL) -> CGPDFDocument? = CGPDFDocument.init",
    ):
        assert service_boundary_errors("Modules/MediaKit/Sources/Example.swift", source), source
        assert (
            service_boundary_errors(
                "Modules/StorageCore/Sources/AppFileService.swift",
                owned_source("LocalAppFileService", source),
            )
            == []
        )
    for source in (
        "let provider = CGDataProvider(data: bytes as CFData)",
        "func load(provider: CGDataProvider) { let document = CGPDFDocument(provider) }",
    ):
        assert service_boundary_errors("Modules/MediaKit/Sources/Example.swift", source) == [], (
            source
        )

    for operation in ("open", "read", "write"):
        source = (
            f"func execute("
            f"{operation}"
            f": @Sendable () throws -> Data) throws -> Data {{ try "
            f"{operation}"
            f"() }}"
        )
        assert service_boundary_errors("BIT101-iOS/Payload.swift", source) == []
        assert service_boundary_errors(
            "BIT101-iOS/Payload.swift",
            source.replace(f"try {operation}()", f"Darwin.{operation}(1)"),
        )
    split_sources = {
        "Types.swift": (
            "enum Namespace { struct Owner { var prefs: UserDefaults; var files: LocalAppFileServi"
            "ce }; struct Local { func data(for item: Int) -> Int { item } } }"
        ),
        "Init.swift": (
            "extension Namespace.Owner { init() { self.prefs = .standard; self.files = .init() } }"
        ),
        "Local.swift": "let catalog = Namespace.Local(); let value = catalog.data(for: 1)",
    }
    context = compilation_type_context(swift_syntax_index_sources(split_sources))
    assert (
        len(ownership_errors("GalleryFeature", split_sources["Init.swift"], properties=context[0]))
        == 2
    )
    assert (
        len(
            service_boundary_errors(
                "Modules/GalleryFeature/Sources/Init.swift",
                split_sources["Init.swift"],
                context=context,
            )
        )
        == 2
    )
    assert (
        service_boundary_errors(
            "Modules/GalleryFeature/Sources/Local.swift",
            split_sources["Local.swift"],
            context=context,
        )
        == []
    )
    assert (
        service_boundary_errors(
            "BIT101-iOS/Example.swift",
            (
                "struct Catalog { func data(for item: Int) -> Int { item } }; let catalog = Catalo"
                "g(); let value = catalog.data(for: 1)"
            ),
        )
        == []
    )
    assert service_boundary_errors(
        "BIT101-iOS/Example.swift",
        (
            "struct Catalog { func data(for item: Int) -> Int { item } }; let catalog = Catalog();"
            " let value = catalog.data(for: 1); let data = try await session.data(for: request)"
        ),
    )
    for source in (
        "let bytes = NSMutableData(contentsOf: url)",
        "let text = try NSMutableString(contentsOf: url, encoding: encoding)",
        "let bytes: NSMutableData = .init(contentsOf: url)",
        "let text = try NSMutableString.self.init(contentsOf: url, encoding: encoding)",
    ):
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source)
    for source in (
        "let wrapper = try FileWrapper(url: url, options: [])",
        "let wrapper = NSFileWrapper(path: path)",
        "let wrapper = try Foundation.FileWrapper.self.init(url: url, options: [])",
        "let wrapper: FileWrapper = try .init(url: url, options: [])",
        "typealias Wrapper = FileWrapper; let wrapper: Wrapper = try .init(url: url, options: [])",
        (
            "let wrapper = FileWrapper(regularFileWithContents: Data()); try wrapper.write(to: url"
            ", options: [], originalContentsURL: nil)"
        ),
        "func refresh(wrapper: FileWrapper, url: URL) { try wrapper.read(from: url, options: []) }",
        (
            "func compare(wrapper: Foundation.FileWrapper, url: URL) { _ = wrapper.matchesContents"
            "(of: url) }"
        ),
    ):
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source), (
            source
        )
        assert (
            service_boundary_errors(
                "Modules/StorageCore/Sources/AppFileService.swift",
                owned_source("LocalAppFileService", source),
            )
            == []
        )
    assert (
        service_boundary_errors(
            "Modules/GalleryFeature/Sources/Example.swift",
            "let wrapper = FileWrapper(regularFileWithContents: Data())",
        )
        == []
    )
    assert (
        service_boundary_errors(
            "Modules/GalleryFeature/Sources/Example.swift",
            (
                "struct Wrapper { func read(from item: Int) {} }; let value = Wrapper(); value.rea"
                "d(from: 1)"
            ),
        )
        == []
    )
    for source in (
        "let parser = XMLParser(contentsOf: url)",
        "let parser = Foundation.XMLParser.init(contentsOf: url)",
        "let parser = Foundation.XMLParser.self.init(contentsOfURL: url)",
        "let parser: XMLParser? = .init(contentsOf: url)",
        "func parser(url: URL) -> XMLParser? { .init(contentsOf: url) }",
        "func accept(_ parser: XMLParser?) {}; accept(.init(contentsOf: url))",
        "typealias Parser = XMLParser; let parser = Parser(contentsOf: url)",
        "NSKeyedArchiver.archiveRootObject(value, toFile: path)",
        "NSArchiver.archiveRootObject(value, toFile: path)",
        "let archive = Foundation.NSKeyedArchiver.self.archiveRootObject(_:toFile:)",
        "typealias Archive = NSKeyedArchiver; let archive = Archive.archiveRootObject",
        "NSKeyedUnarchiver.unarchiveObject(withFile: path)",
        "NSUnarchiver.unarchiveObject(withFile: path)",
        "let read = Foundation.NSKeyedUnarchiver.self.unarchiveObject(withFile:)",
        "typealias Archive = NSKeyedUnarchiver; let read = Archive.unarchiveObject(withFile:)",
    ):
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source), (
            source
        )
        assert service_boundary_errors("BIT101-iOS/Schedule/Example.swift", source), source
        assert (
            service_boundary_errors(
                "Modules/StorageCore/Sources/AppFileService.swift",
                owned_source("LocalAppFileService", source),
            )
            == []
        ), source
    for source in (
        "XMLParser(data: data)",
        "XMLParser(stream: stream)",
        "let parser: XMLParser = .init(data: data)",
        "try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)",
        "NSKeyedUnarchiver.unarchiveObject(with: data)",
        "NSUnarchiver.unarchiveObject(with: data)",
        "let read = NSKeyedUnarchiver.unarchiveObject(with:)",
        "let archive = NSArchiver.archivedData(withRootObject: value)",
        "try NSKeyedUnarchiver(forReadingFrom: data)",
        "NSKeyedArchiver(requiringSecureCoding: true)",
    ):
        assert service_boundary_errors("BIT101-iOS/Schedule/Example.swift", source) == [], source
