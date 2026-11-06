"""Check network capability discovery and execution."""

from validation_test_areas import (
    network_capability_findings,
)


from network_surface_tests import capability_surface_self_test


def network_discovery_self_test() -> None:
    verify_request_shapes()
    watch_only = verify_platform_ownership()
    verify_request_callbacks(watch_only)
    compound_path = verify_request_polymorphism()
    verify_exported_request_members(compound_path)


def verify_request_shapes():
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods

    for body, expected in (
        ("try await performRequest(request)", True),
        ("Task { try await performRequest(request) }", True),
        (
            (
                "await withTaskGroup(of: Void.self) { group in group.addTask { try await performRe"
                "quest(request) } }"
            ),
            True,
        ),
        (
            (
                "try await withThrowingTaskGroup(of: Void.self) { group in group.addTaskUnlessCanc"
                "elled { try await performRequest(request) } }"
            ),
            True,
        ),
        ("[request].forEach { request in Task { try await performRequest(request) } }", True),
        ("[request].map { request in Task { try await performRequest(request) } }", True),
        ("DispatchQueue.main.async { Task { try await performRequest(request) } }", True),
        (
            (
                "DispatchQueue.global().asyncAfter(deadline: .now()) { Task { try await performReq"
                "uest(request) } }"
            ),
            True,
        ),
        (
            (
                "Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in Task { try await"
                " performRequest(request) } }"
            ),
            True,
        ),
        ("Just(()).sink { _ in Task { try await performRequest(request) } }", True),
        (
            (
                "try await withTaskCancellationHandler(operation: { try await performRequest(reque"
                "st) }, onCancel: {})"
            ),
            True,
        ),
        (
            (
                "await withTaskCancellationHandler(operation: {}, onCancel: { Task { try await per"
                "formRequest(request) } })"
            ),
            True,
        ),
        ("let unused = { try await performRequest(request) }", False),
    ):
        source = (
            (
                "import Foundation; import Combine; struct ExampleService { func fetch(request: UR"
                "LRequest) async throws { "
            )
            + body
            + (
                " }; private func performRequest(_ request: URLRequest) async throws { _ = try awa"
                "it URLSession.shared.data(for: request) } }"
            )
        )
        methods = business_methods(
            swift_syntax_index_sources({"Modules/Example/Sources/Service.swift": source})
        )
        assert bool(methods) == expected, body
        if expected:
            assert [row["name"] for rows in methods.values() for _, row in rows] == ["fetch"], body
    for execution, expected in (
        ("await operation()", True),
        ("", False),
        ("let unused = { await operation() }", False),
        ("await forward(operation)", True),
    ):
        source = (
            (
                "import Foundation; struct ExampleService { func fetch(request: URLRequest) async "
                "{ await execute { await performRequest(request) } }; private func execute(_ opera"
                "tion: () async -> Void) async { "
            )
            + execution
            + (
                " }; private func forward(_ operation: () async -> Void) async { await operation()"
                " }; private func performRequest(_ request: URLRequest) async { _ = try? await URL"
                "Session.shared.data(for: request) } }"
            )
        )
        methods = business_methods(
            swift_syntax_index_sources({"Modules/Example/Sources/Service.swift": source})
        )
        assert bool(methods) == expected, execution
    pure_path = "Modules/CourseFeature/Sources/CourseService.swift"
    for request in (
        "try await client.send(request)",
        "try await URLSession.shared.data(for: request)",
        'try Data(contentsOf: URL(string: "https://example.invalid")!)',
    ):
        sources = {
            pure_path: (
                "import Foundation; public struct CourseService { let client: HTTPClient; public f"
                "unc noop(request: URLRequest) { let unused = { "
            )
            + request
            + " } } }",
            "Modules/TransportCore/Sources/HTTPClient.swift": (
                "public struct HTTPClient { public func send(_ request: URLRequest) async throws {"
                "} }"
            ),
        }
        assert not business_methods(swift_syntax_index_sources(sources)), request
    pure_source = (
        "public struct CourseService {\n        public func normalizedTitle(title: String) -> Stri"
        "ng { title.trimmingCharacters(in: .whitespaces) }\n        public func fetch(courseID: In"
        "t) async throws -> Int { courseID }\n        public func refresh() { Task { _ = try await"
        " URLSession.shared.data(from: url) } }\n    }"
    )
    pure_methods = business_methods(swift_syntax_index_sources({pure_path: pure_source}))
    assert {function["name"] for _, function in pure_methods["CourseFeature.CourseService"]} == {
        "refresh"
    }
    path = "BIT101-iOS/NewService.swift"
    for helper, body in (
        ("", "_ = try await URLSession.shared.data(from: url)"),
        (
            "private func fetch() async throws { _ = try await URLSession.shared.data(from: url) }",
            "try await fetch()",
        ),
        (
            "private func makeSession() -> URLSession { URLSession.shared }",
            "_ = try await makeSession().data(from: url)",
        ),
        ("", "let session = URLSession.shared; _ = try await session.data(from: url)"),
        ("", "let fetch = URLSession.shared.data; _ = try await fetch(from: url)"),
        (
            "",
            (
                "let session = URLSession.shared; let fetch = session.data; _ = try await fetch(fr"
                "om: url)"
            ),
        ),
    ):
        source = helper + "\nstruct NewService { func load() async throws { " + body + " } }"
        assert "BIT101-iOS.NewService" in business_methods(
            swift_syntax_index_sources({path: source})
        ), body


def verify_platform_ownership():
    from network_capability_rules import business_methods, method_signature
    from swift_source_index import swift_syntax_index_sources

    for request_type in ("URLRequest", "Foundation.URLRequest"):
        path = "Modules/NewGalleryFeature/Sources/NewService.swift"
        source = (
            """import Foundation; import TransportCore
            public struct NewService: HTTPTransport {
                let client: HTTPClient
                public func fetch() async throws { try await client.send(request) }
                public func data(for request: """
            + request_type
            + """) async throws -> (Data, URLResponse) {
                    try await URLSession.shared.data(for: request)
                }
                public func data(for request: """
            + request_type
            + """, maximumBytes: Swift.Int?) async throws -> (Data, URLResponse) {
                    try await URLSession.shared.data(for: request)
                }
            }"""
        )
        methods = business_methods(swift_syntax_index_sources({path: source}))
        assert [row["name"] for rows in methods.values() for _, row in rows] == ["fetch"], (
            request_type
        )
        methods = business_methods(
            swift_syntax_index_sources({path: source.replace("maximumBytes:", "attempts:")})
        )
        assert [row["name"] for rows in methods.values() for _, row in rows] == ["fetch", "data"], (
            request_type
        )
    for declaration in ("public struct ProbeClient", "public struct MediaEnvironment"):
        source = (
            "import Foundation; "
            + declaration
            + (
                " {\n            public func fetch() async throws -> Data { try await URLSession.s"
                "hared.data(from: url).0 }\n        }"
            )
        )
        methods = business_methods(
            swift_syntax_index_sources({"Modules/MediaKit/Sources/Probe.swift": source})
        )
        assert methods and any(
            function["name"] == "fetch" for rows in methods.values() for _, function in rows
        ), declaration
    for inheritance, expected in [
        ("App", False),
        ("Scene", False),
        ("View", False),
        ("LocalApp", True),
    ]:
        source = (
            "import SwiftUI; import TransportCore; protocol LocalApp {}; struct Composition: "
            + inheritance
            + """ {
            let client: HTTPClient
            init() { Task { try await client.send(request) } }
        }"""
        )
        assert (
            bool(
                business_methods(
                    swift_syntax_index_sources({"BIT101-iOS/Composition.swift": source})
                )
            )
            == expected
        ), inheritance
    from validation_test_areas import reachable_smoke_calls

    path = "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"
    for used in [True, False]:
        source = (
            """struct ReleaseNetworkSmokeRunner { func run() { forward { service.fetch() } } }
            func forward(load: () -> Void) { outer { load() } }
            func outer(load: () -> Void) { inner { load() } }
            func inner(load: () -> Void) { """
            + ("load()" if used else "")
            + """ }"""
        )
        calls = reachable_smoke_calls(swift_syntax_index_sources({path: source}))["network"]
        assert any(call["calledExpression"] == "service.fetch" for call in calls) == used, used
    watch_only = (
        "import Foundation\n        struct WatchService {\n        #if os(watchOS)\n            fu"
        'nc fetch() async throws -> Data { try await URLSession.shared.data(from: URL(string: "htt'
        'ps://fixture.invalid")!).0 }\n        #else\n            func label() -> String { "fixtur'
        'e" }\n        #endif\n        }'
    )
    for path, expected in [
        ("BIT101Watch/WatchService.swift", True),
        ("BIT101WatchWidgets/WatchService.swift", True),
        ("Modules/WatchService/Sources/WatchService.swift", True),
        ("BIT101-iOS/WatchService.swift", False),
    ]:
        source = (
            watch_only.replace("struct WatchService", "public struct WatchService").replace(
                "func fetch()", "public func fetch()"
            )
            if path.startswith("Modules/")
            else watch_only
        )
        assert bool(business_methods(swift_syntax_index_sources({path: source}))) == expected, path
    from validation_compilation import active_network_source, available_local_modules

    architecture_path = "BIT101Watch/WatchService.swift"
    architecture_source = """import Foundation; struct WatchService {
        #if arch(arm64_32)
        func fetchSmall() async throws { _ = try await URLSession.shared.data(from: url) }
        #elseif arch(arm64)
        func fetchLarge() async throws { _ = try await URLSession.shared.data(from: url) }
        #endif
    }"""
    active_architectures = active_network_source(architecture_source, architecture_path)
    assert "fetchSmall" in active_architectures and "fetchLarge" in active_architectures
    methods = business_methods(swift_syntax_index_sources({architecture_path: architecture_source}))
    assert {row["name"] for rows in methods.values() for _, row in rows} == {
        "fetchSmall",
        "fetchLarge",
    }
    desktop_source = architecture_source.replace("arch(arm64_32)", "arch(arm64)").replace(
        "#elseif arch(arm64)", "#elseif arch(x86_64)"
    )
    for desktop_path in (
        "BIT101-iOS/ArchitectureService.swift",
        "Modules/TransportCore/Sources/ArchitectureService.swift",
    ):
        active = active_network_source(desktop_source, desktop_path)
        assert "fetchSmall" in active and "fetchLarge" in active
    for condition, expected in [
        ("!RELEASE_NETWORK_SMOKE", True),
        ("RELEASE_NETWORK_SMOKE", True),
        ("DEBUG", False),
    ]:
        source = watch_only.replace("os(watchOS)", condition)
        path = "BIT101-iOS/WatchService.swift"
        assert ("func fetch()" in active_network_source(source, path)) == expected, condition
        assert bool(business_methods(swift_syntax_index_sources({path: source}))) == expected, (
            condition
        )
    for condition, modules, app, watch in [
        ("os(macOS)", True, False, False),
        ("targetEnvironment(macCatalyst)", True, True, False),
        ("os(iOS)", True, True, False),
        ("os(watchOS)", True, False, True),
    ]:
        source = watch_only.replace("os(watchOS)", condition)
        for path, expected in [
            ("Modules/GalleryFeature/Sources/Service.swift", modules),
            ("BIT101-iOS/Service.swift", app),
            ("BIT101Watch/Service.swift", watch),
        ]:
            assert ("func fetch()" in active_network_source(source, path)) == expected, (
                condition,
                path,
            )
    return watch_only


def verify_request_callbacks(watch_only):
    from validation_compilation import active_network_source, available_local_modules

    assert {"CommunityCore", "StorageCore", "TransportCore"} <= available_local_modules(
        "Modules/GalleryFeature/Sources/Service.swift"
    )
    assert "ScoreInfrastructure" not in available_local_modules(
        "Modules/GalleryFeature/Sources/Service.swift"
    )
    assert "PaperFeature" in available_local_modules("BIT101-iOS/Shell/Service.swift")
    assert "PaperFeature" not in available_local_modules("BIT101Watch/Service.swift")
    assert "PaperFeature" in available_local_modules(
        "ModuleTests/Community/ServiceContractTests.swift"
    )
    for condition, expected in [
        ("canImport(CommunityCore)", True),
        ("canImport(StorageCore)", True),
        ("canImport(ScoreInfrastructure)", False),
        ("canImport(UnregisteredFramework)", False),
    ]:
        source = watch_only.replace("os(watchOS)", condition)
        assert (
            "func fetch()"
            in active_network_source(source, "Modules/GalleryFeature/Sources/Service.swift")
        ) == expected
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods, method_signature

    leaf = "Modules/PaperFeature/Sources/PaperService.swift"
    wrapper = "BIT101-iOS/Shell/NewService.swift"
    for annotation in ("", ": PaperService"):
        for initializer in ("PaperService()", "Factory.make()"):
            facts = swift_syntax_index_sources(
                {
                    leaf: (
                        "public struct PaperService { public func fetchPaper(id: Int) async throws"
                        " -> Int { id } }"
                    ),
                    wrapper: (
                        f"import PaperFeature\nenum Factory {{ static func make() -> PaperService"
                        f" {{ PaperService() }} }}\nstruct NewService {{ private let paper"
                        f"{annotation}"
                        f" = "
                        f"{initializer}"
                        f"; func fetch(id: Int) async throws -> Int {{ try await paper.fetchPaper"
                        f"(id: id) }} }}"
                    ),
                }
            )
            assert "BIT101-iOS.NewService" in business_methods(facts), (annotation, initializer)
    utility_path = "Modules/ClientCore/Sources/Parser.swift"
    transport_path = "Modules/TransportCore/Sources/HTTPClient.swift"
    transport = (
        "public struct HTTPClient { public static func message(from data: Data) -> String? { nil }"
        "; public static func make() -> HTTPClient { HTTPClient() }; public static func fetch() as"
        "ync -> Data { Data() } }"
    )
    for call, expected in [
        ("HTTPClient.message(from: data)", False),
        ("HTTPClient.make()", True),
        ("await HTTPClient.fetch()", True),
        ("HTTPClient.shared.send(request)", True),
    ]:
        source = (
            f"import TransportCore; public struct Parser {{ public func parse(data: Data) async {{"
            f" _ = "
            f"{call}"
            f" }} }}"
        )
        facts = swift_syntax_index_sources({utility_path: source, transport_path: transport})
        assert ("ClientCore.Parser" in business_methods(facts)) == expected, call
    from network_capability_rules import matching_api_calls

    for expression, expected in [
        ("Service.fetch()", True),
        ("Service().fetch()", False),
        ("instance.fetch()", False),
        ("metatype.fetch()", True),
        ("Alias.fetch()", True),
    ]:
        path = "Modules/GalleryFeature/Sources/Service.swift"
        index = swift_syntax_index_sources(
            {
                path: (
                    "typealias Alias = Service\n            public struct Service { let client: HT"
                    "TPClient; public static func fetch() -> Int { 1 }; public func fetch() -> Int"
                    " { 2 } }\n            func smoke(instance: Service, metatype: Service.Type) {"
                    " let _ = "
                )
                + expression
                + " }"
            }
        )
        functions = [(path, row) for row in index[path]["functionRanges"] if row["name"] == "fetch"]
        call = next(
            row for row in index[path]["invocations"] if row["calledExpression"].endswith(".fetch")
        )
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert len(matches) == 1 and matches[0][1]["isStatic"] == expected, expression
        assert {method_signature(row) for _, row in functions} == {"fetch()", "static fetch()"}
    for body, expected in [
        ("let value: Int = Service().fetch()", "Int"),
        ("let value: String = Service().fetch()", "String"),
        ("return Service().fetch()", "Int"),
        ("let _ = Service().fetch()", None),
    ]:
        path = "Modules/GalleryFeature/Sources/Service.swift"
        index = swift_syntax_index_sources(
            {
                path: (
                    "public struct Service { let client: HTTPClient\n            public func fetch"
                    "() -> Int { Task { _ = try await client.send(request) }; return 1 }\n        "
                    "    public func fetch() -> String { Task { _ = try await client.send(request)"
                    ' }; return "value" } }\n            func smoke() -> Int { '
                )
                + body
                + " }"
            }
        )
        methods = business_methods(index)
        functions = methods["GalleryFeature.Service"]
        assert {method_signature(row) for _, row in functions} == {
            "fetch()->Int",
            "fetch()->String",
        }
        call = next(
            row for row in index[path]["invocations"] if row["calledExpression"].endswith(".fetch")
        )
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert (
            ([row["returnType"] for _, row in matches] == [expected]) if expected else not matches
        ), body


def verify_request_polymorphism():
    from network_capability_rules import business_methods, method_signature
    from network_capability_rules import matching_api_calls
    from swift_source_index import swift_syntax_index_sources

    for declarations, alternatives, argument, expected in [
        ("protocol Port {}; struct Concrete: Port {}", ["Port", "Int"], "Concrete()", "Port"),
        (
            "protocol Port {}; struct Concrete: Port {}",
            ["Port", "Concrete"],
            "Concrete()",
            "Concrete",
        ),
        ("class Base {}; class Concrete: Base {}", ["Base", "Int"], "Concrete()", "Base"),
        (
            "protocol Port {}; protocol Child: Port {}; struct Concrete: Child {}",
            ["Port", "Child"],
            "Concrete()",
            "Child",
        ),
        (
            "protocol Port {}; struct Concrete {}; extension Concrete: Port {}",
            ["Port", "Int"],
            "Concrete()",
            "Port",
        ),
        (
            "protocol Port {}; struct Concrete: Port {}; typealias Injected = Concrete",
            ["any Port", "Int"],
            "Injected()",
            "any Port",
        ),
        ("protocol Port {}; struct Concrete: Port {}", ["Port?", "Int"], "Concrete()", "Port?"),
        ("protocol Port {}; struct Concrete: Port {}", ["Port", "Int"], "optional", None),
    ]:
        path = "Modules/GalleryFeature/Sources/Client.swift"
        source = (
            declarations
            + "; struct Client { "
            + "; ".join(f"func fetch(using port: {kind}) {{}}" for kind in alternatives)
            + (
                f" }}; func smoke() {{ let optional: Concrete? = nil; Client().fetch(using: "
                f"{argument}"
                f") }}"
            )
        )
        index = swift_syntax_index_sources({path: source})
        functions = [(path, row) for row in index[path]["functionRanges"] if row["name"] == "fetch"]
        call = next(
            row for row in index[path]["invocations"] if row["calledExpression"].endswith(".fetch")
        )
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert (
            ([row["parameters"][0]["type"] for _, row in matches] == [expected])
            if expected
            else not matches
        ), (declarations, alternatives, argument, matches)
    for kind, method in [
        ("URLSessionWebSocketTask", "send"),
        ("URLSessionWebSocketTask", "receive"),
        ("URLSessionDataTask", "resume"),
        ("NWConnection", "send"),
        ("NWConnection", "start"),
        ("NWConnectionGroup", "receiveMessage"),
        ("NWListener", "start"),
        ("WKWebView", "load"),
        ("WKWebView", "reload"),
        ("WKWebView", "loadHTMLString"),
    ]:
        path = "BIT101-iOS/Shared/Client/SocketClient.swift"
        source = (
            f"import Foundation; import Network; import WebKit; struct SocketClient {{ let task: "
            f"{kind}"
            f"; func exchange() {{ task."
            f"{method}"
            f"() }} }}"
        )
        index = swift_syntax_index_sources({path: source})
        discovered = business_methods(index)
        assert any(identity.endswith(".SocketClient") for identity in discovered), (kind, method)
    for parameters, invocation in [
        ("name: KIND, page: Int = 0", 'name: "hello"'),
        ("page: Int = 0, name: KIND", 'name: "hello"'),
        ("name: KIND...", 'name: "hello", "world"'),
    ]:
        source = (
            "public struct Client { "
            + "; ".join(
                f"public func fetch({parameters.replace('KIND', kind)}) {{}}"
                for kind in ("String", "Int")
            )
            + f" }}; func smoke() {{ Client().fetch({invocation}) }}"
        )
        path = "Modules/GalleryFeature/Sources/Client.swift"
        index = swift_syntax_index_sources({path: source})
        functions = [
            (path, function)
            for function in index[path]["functionRanges"]
            if function["name"] == "fetch"
        ]
        call = next(
            call
            for call in index[path]["invocations"]
            if call["calledExpression"].endswith(".fetch")
        )
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert len(matches) == 1 and any(
            parameter["type"] == "String" for parameter in matches[0][1]["parameters"]
        ), parameters
    for first, second, argument in [
        ("Int?", "String?", "42"),
        ("Swift.Int?", "Swift.String?", "42"),
        ("Number?", "Text?", "42"),
        ("MaybeNumber", "Text?", "value"),
        ("Int", "Int?", "42"),
        ("Optional<Int>", "Optional<String>", "42"),
    ]:
        path = "Modules/GalleryFeature/Sources/Client.swift"
        source = (
            f"typealias Number = Int; typealias Text = String; typealias MaybeNumber = Int?\n   "
            f"         public struct Client {{ public func fetch(id: "
            f"{first}"
            f") {{}}; public func fetch(id: "
            f"{second}"
            f") {{}} }}\n            func smoke() {{ let value: Number = 42; Client().fetch(id: "
            f"{argument}"
            f") }}"
        )
        index = swift_syntax_index_sources({path: source})
        functions = [
            (path, function)
            for function in index[path]["functionRanges"]
            if function["name"] == "fetch"
        ]
        call = next(
            call
            for call in index[path]["invocations"]
            if call["calledExpression"].endswith(".fetch")
        )
        matches = matching_api_calls(index, functions, dict(call, path=path))
        assert len(matches) == 1 and matches[0][1]["parameters"][0]["type"] == first, (
            first,
            second,
            argument,
        )
    compound_path = "Modules/NewForumFeature/Sources/Service.swift"
    return compound_path


def verify_exported_request_members(compound_path):
    from network_capability_rules import business_methods, method_signature
    from swift_source_index import swift_syntax_index_sources

    for kind, expression in [
        ("(HTTPClient, String)", "context.0"),
        ("[HTTPClient]", "context[0]"),
        ("Dictionary<String, HTTPClient>", 'context["first"]!'),
        ("Context", "context.0"),
    ]:
        source = (
            f"typealias Context = (HTTPClient, String); public struct CompositeService {{\n      "
            f"      private let context: "
            f"{kind}"
            f"\n            public func fetch(request: URLRequest) async throws -> Data {{ try aw"
            f"ait "
            f"{expression}"
            f".send(request).data }}\n        }}"
        )
        index = swift_syntax_index_sources({compound_path: source})
        assert "NewForumFeature.CompositeService" in business_methods(index), kind
        assert any("新增生产服务" in error for error in network_capability_findings(index)), kind
    for module, name in [
        ("GalleryFeature", "NewGalleryClient"),
        ("NewForumFeature", "PostRepository"),
    ]:
        path = f"Modules/{module}/Sources/Client.swift"
        for kind in ("HTTPClient", "Requester", "NestedRequester"):
            for injection in ("member", "parameter"):
                member = f"let client: {kind};" if injection == "member" else ""
                parameters = "" if injection == "member" else f"client: {kind}, request: URLRequest"
                source = (
                    f"import TransportCore; typealias Requester = HTTPClient; typealias NestedRe"
                    f"quester = Requester; public struct "
                    f"{name}"
                    f" {{ "
                    f"{member}"
                    f" public func fetchItems("
                    f"{parameters}"
                    f") async throws {{ _ = try await client.send(request) }} }}"
                )
                index = swift_syntax_index_sources({path: source})
                assert f"{module}.{name}" in business_methods(index), (kind, injection)
                assert any(
                    "新增生产服务" in error for error in network_capability_findings(index)
                ), (kind, injection)
    getter_path = "Modules/NewForumFeature/Sources/ReadService.swift"
    for access, exported in [("public", True), ("private", False), ("internal", True)]:
        getter = (
            f"public struct ReadService {{ let client: HTTPClient; "
            f"{access}"
            f" var rows: HTTPResponse {{ get async throws {{ try await client.send(r"
            f"equest) }} }} }}"
        )
        index = swift_syntax_index_sources({getter_path: getter})
        methods = business_methods(index)
        assert ("NewForumFeature.ReadService" in methods) == exported, access
        if exported:
            assert methods["NewForumFeature.ReadService"][0][1]["name"] == "rows"
            assert any("新增生产服务" in error for error in network_capability_findings(index))
    capability_surface_self_test()
