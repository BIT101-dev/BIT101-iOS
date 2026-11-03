"""Check network capability discovery and execution."""

from swift_source_index import swift_syntax_index_sources
from network_capability_rules import business_methods, method_signature
from validation_test_areas import (
    MANUAL_CAPABILITY_SCENARIOS,
    NETWORK_CAPABILITIES,
    network_capability_findings,
)


def capability_surface_self_test() -> None:
    leaf = "Modules/PaperFeature/Sources/PaperService.swift"
    transport_path = "Modules/TransportCore/Sources/HTTPClient.swift"
    getter_path = "Modules/NewForumFeature/Sources/ReadService.swift"
    from unittest.mock import patch

    def assert_capability_variant(sources, harness_path, getter_path, signature, declaration):
        if signature == "init()":
            sources[harness_path] = (
                "#if RELEASE_NETWORK_SMOKE\n                        import NewForumFeature"
                "\n                        enum Factory { static var existing: ReadService"
                "; static func cached() -> ReadService { existing } }\n                   "
                "     struct ReleaseNetworkSmokeRunner { func run() { _ = Factory.cached()"
                " } }\n                        #endif"
            )
            errors = network_capability_findings(swift_syntax_index_sources(sources))
            assert any(
                "ReadService.init()" in error and "静态可达服务调用" in error for error in errors
            ), errors
        if signature == "rows()" and "get async" not in declaration:
            sources[getter_path] = sources[getter_path].replace(
                (
                    "public var rows: Task<HTTPResponse, Error> { Task { try await client."
                    "send(request) } }"
                ),
                (
                    "public var rows: Task<HTTPResponse, Error> { get { Task { try await c"
                    "lient.send(request) } } set {} }"
                ),
            )
            sources[harness_path] = (
                "#if RELEASE_NETWORK_SMOKE\n                        import NewForumFeature"
                "\n                        struct ReleaseNetworkSmokeRunner { var service:"
                " ReadService; func run() { service.rows = existingTask } }\n             "
                "           #endif"
            )
            errors = network_capability_findings(swift_syntax_index_sources(sources))
            assert any(
                "ReadService.rows()" in error and "静态可达服务调用" in error for error in errors
            ), errors

    harness_path = "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"
    for declaration, signature, invocation in [
        (
            "public var rows: HTTPResponse { get async throws { try await client.send(request) } }",
            "rows()",
            "try await service.rows",
        ),
        (
            (
                "public var rows: Task<HTTPResponse, Error> { Task { try await client.se"
                "nd(request) } }"
            ),
            "rows()",
            "service.rows",
        ),
        (
            (
                "public var operation: () async throws -> HTTPResponse { { try await client.send(r"
                "equest) } }"
            ),
            "operation()",
            "try await service.operation()",
        ),
        (
            (
                "public subscript(_ id: Int) -> Task<HTTPResponse, Error> { Task { try await clien"
                "t.send(request) } }"
            ),
            "subscript(:Int)",
            "service[1_000]",
        ),
        ("public init() { Task { try await client.send(request) } }", "init()", "ReadService()"),
    ]:
        for include_transport in (False, True):
            sources = {
                getter_path: (
                    f"import TransportCore; public struct ReadService {{ let client: HTTPClient; "
                    f"{declaration}"
                    f" }}"
                ),
                harness_path: (
                    f"#if RELEASE_NETWORK_SMOKE\nimport NewForumFeature; struct ReleaseNetworkSm"
                    f"okeRunner {{ let service: ReadService; func run() {{ _ = "
                    f"{invocation}"
                    f" }} }}\n#endif"
                ),
            }
            if include_transport:
                sources[transport_path] = (
                    "public struct HTTPClient { public func send(_ request: URLRequest) async "
                    "throws -> HTTPResponse {} }"
                )
            index = swift_syntax_index_sources(sources)
            methods = business_methods(index)
            assert [
                method_signature(function) for _, function in methods["NewForumFeature.ReadService"]
            ] == [signature], declaration
            with (
                patch.dict(
                    NETWORK_CAPABILITIES,
                    {"NewForumFeature.ReadService": {signature: "network"}},
                    clear=True,
                ),
                patch.dict(MANUAL_CAPABILITY_SCENARIOS, {}, clear=True),
            ):
                assert not network_capability_findings(index), (
                    declaration,
                    network_capability_findings(index),
                )
                sources[harness_path] = sources[harness_path].replace(
                    invocation, "service.operation" if signature == "operation()" else "0"
                )
                errors = network_capability_findings(swift_syntax_index_sources(sources))
                assert any("静态可达服务调用" in error for error in errors), (declaration, errors)
                assert_capability_variant(
                    sources, harness_path, getter_path, signature, declaration
                )
    protocol = (
        "public protocol RequestSending { func send(_ request: URLRequest) async throws -> HTTPRes"
        "ponse }; extension HTTPClient: RequestSending {}"
    )
    service = (
        "public struct ReadService { let client: any RequestSending; public func rows(_ request: U"
        "RLRequest) async throws -> HTTPResponse { try await client.send(request) } }"
    )
    index = swift_syntax_index_sources(
        {
            getter_path: "import TransportCore; " + service,
            "Modules/TransportCore/Sources/HTTPClient.swift": "public struct HTTPClient {}; "
            + protocol,
        }
    )
    assert "NewForumFeature.ReadService" in business_methods(index)
    assert any("新增生产服务" in error for error in network_capability_findings(index))
    ports_path = "Modules/Ports/Sources/Fetching.swift"
    ports = (
        "public protocol Fetching { func fetch() async throws -> Data }; public protocol RefinedFe"
        "tching: Fetching {}"
    )
    for access in ("internal", "fileprivate"):
        for annotation in ("any Fetching", "any RefinedFetching", "ForwardedFetching"):
            sources = {
                ports_path: ports,
                transport_path: "public struct HTTPClient {}",
                getter_path: (
                    f"import Ports; import TransportCore\n                typealias ForwardedFet"
                    f"ching = RefinedFetching\n                "
                    f"{access}"
                    f" struct LiveFetcher: RefinedFetching {{ let client: HTTPClient; func fetch("
                    f") async throws -> Data {{ try await client.send(request).data }} }}\n        "
                    f"        public struct ExampleService {{ let fetcher: "
                    f"{annotation}"
                    f"; public func fetch() async throws -> Data {{ try await fetcher.fetch() }} }}"
                ),
            }
            index = swift_syntax_index_sources(sources)
            assert "NewForumFeature.ExampleService" in business_methods(index), (access, annotation)
            assert any("新增生产服务" in error for error in network_capability_findings(index))
            sources[getter_path] = (
                sources[getter_path]
                .replace("let client: HTTPClient;", "")
                .replace("try await client.send(request).data", "Data()")
            )
            assert "NewForumFeature.ExampleService" not in business_methods(
                swift_syntax_index_sources(sources)
            )
    sources = {
        ports_path: ports,
        "Modules/OtherPorts/Sources/Fetching.swift": ports,
        transport_path: "public struct HTTPClient {}",
        getter_path: (
            "import Ports; import TransportCore\n            struct LiveFetcher: OtherPorts.Fetchi"
            "ng { let client: HTTPClient; func fetch() async throws -> Data { try await client.sen"
            "d(request).data } }\n            public struct ExampleService { let fetcher: any Port"
            "s.Fetching; public func fetch() async throws -> Data { try await fetcher.fetch() } }"
        ),
    }
    assert "NewForumFeature.ExampleService" not in business_methods(
        swift_syntax_index_sources(sources)
    )
    bodies = [
        (
            "public struct ExampleService<T: HTTPTransport> { let transport: T; public func fetch("
            "request: URLRequest) async throws -> Data { try await transport.data(for: request).0 "
            "} }"
        ),
        (
            "public struct ExampleService<T> where T: HTTPTransport { let transport: T; public fun"
            "c fetch(request: URLRequest) async throws -> Data { try await transport.data(for: req"
            "uest).0 } }"
        ),
        (
            "public struct ExampleService { public func fetch<T: HTTPTransport>(transport: T, requ"
            "est: URLRequest) async throws -> Data { try await transport.data(for: request).0 } }"
        ),
        (
            "public struct ExampleService { public func fetch<T>(transport: T, request: URLRequest"
            ") async throws -> Data where T: HTTPTransport { try await transport.data(for: request"
            ").0 } }"
        ),
        (
            "public struct ExampleService<T: Fetcher> where T.Client == HTTPClient { let client: T"
            ".Client; public func fetch() async throws -> Data { try await client.send(request).da"
            "ta } }"
        ),
    ]
    for body in bodies:
        index = swift_syntax_index_sources(
            {
                getter_path: "import TransportCore; " + body,
                transport_path: "public protocol HTTPTransport {}; public struct HTTPClient {}",
            }
        )
        assert "NewForumFeature.ExampleService" in business_methods(index), body
        assert any("新增生产服务" in error for error in network_capability_findings(index)), body
    shadowed = (
        "public struct ExampleService<T: HTTPTransport> { public func fetch<T>(transport: T) async"
        " {} }"
    )
    index = swift_syntax_index_sources({getter_path: shadowed})
    assert "NewForumFeature.ExampleService" not in business_methods(index)
    for injection in ("member", "parameter"):
        member = "let client: HTTPClient;" if injection == "member" else ""
        parameters = (
            "request: URLRequest"
            if injection == "member"
            else "client: HTTPClient, request: URLRequest"
        )
        source = (
            f"struct InternalService {{ "
            f"{member}"
            f" func fetch("
            f"{parameters}"
            f") async throws -> HTTPResponse {{ try await client.send(request) }} }}"
        )
        index = swift_syntax_index_sources(
            {getter_path: source, transport_path: "public struct HTTPClient {}"}
        )
        assert "NewForumFeature.InternalService" in business_methods(index), injection
        assert any("新增生产服务" in error for error in network_capability_findings(index)), (
            injection
        )
    app_path = "BIT101-iOS/Shell/BackgroundRequestService.swift"
    for body, expected in [
        ("func lookup() async { getaddrinfo(host, service, hints, result) }", True),
        ("func lookup() async { Darwin.getaddrinfo(host, service, hints, result) }", True),
        ("func lookup() { CFNetwork.CFReadStreamCreateForHTTPRequest(allocator, message) }", True),
        ("func lookup() { CFHTTPMessageCreateRequest(allocator, method, url, version) }", True),
        (
            (
                "func lookup() { let connection = NSURLConnection(request: request, delegate: nil)"
                "; connection.start() }"
            ),
            True,
        ),
        (
            (
                "func lookup() { _ = try NSURLConnection.sendSynchronousRequest(request, returning"
                ": nil) }"
            ),
            True,
        ),
        (
            (
                "func lookup() { NSURLConnection.sendAsynchronousRequest(request, queue: queue) { "
                "_, _, _ in } }"
            ),
            True,
        ),
        (
            (
                "func lookup() { resolve() }; private func resolve() { getnameinfo(address, size, "
                "host, hostSize, service, serviceSize, flags) }"
            ),
            True,
        ),
        ("func getaddrinfo(_ value: Int) {}; func lookup() async { getaddrinfo(1) }", False),
        ("func lookup(getaddrinfo: () -> Void) async { getaddrinfo() }", False),
        ("func lookup() { let deferred = { getaddrinfo(host, service, hints, result) } }", False),
    ]:
        index = swift_syntax_index_sources({app_path: "struct DNSService { " + body + " }"})
        assert ("BIT101-iOS.DNSService" in business_methods(index)) == expected, body
    for access, body, expected in [
        (
            "internal",
            (
                "func start(_ request: URLRequest) -> Task<Void, Error> { Task { _ = try await cli"
                "ent.send(request) } }"
            ),
            True,
        ),
        (
            "internal",
            "func start(_ request: URLRequest) { Task { _ = try await client.send(request) } }",
            True,
        ),
        (
            "fileprivate",
            "func start(_ request: URLRequest) { Task { _ = try await client.send(request) } }",
            False,
        ),
        (
            "private",
            (
                "func start(_ request: URLRequest) -> Task<Void, Error> { Task { _ = try await cli"
                "ent.send(request) } }"
            ),
            False,
        ),
        (
            "internal",
            (
                'func label() async -> String { "cached" }; func localDraftTitle() async -> String'
                " { await label() }"
            ),
            False,
        ),
        (
            "internal",
            (
                "func render() -> some View { Task { _ = try await client.send(URLRequest()) }; Em"
                "ptyView() }"
            ),
            False,
        ),
        (
            "internal",
            (
                "init(load: () async throws -> Void = { _ = try await HTTPClient.shared.send(URLRe"
                "quest()) }) {}"
            ),
            False,
        ),
        ("internal", "func load(_ url: URL) throws -> Data { try Data(contentsOf: url) }", True),
        (
            "internal",
            (
                "func load(_ url: URL) throws -> Data { guard url.isFileURL else { fatalError() };"
                " return try Data(contentsOf: url) }"
            ),
            False,
        ),
    ]:
        source = (
            f"import TransportCore; struct BackgroundRequestService {{ let client: HTTPClient; "
            f"{access}"
            f" "
            f"{body}"
            f" }}"
        )
        index = swift_syntax_index_sources(
            {app_path: source, transport_path: "public struct HTTPClient {}"}
        )
        assert ("BIT101-iOS.BackgroundRequestService" in business_methods(index)) == expected, (
            access,
            body,
        )
        assert (
            any(
                "新增生产服务需要网络能力验收归属：BIT101-iOS.BackgroundRequestService" in error
                for error in network_capability_findings(index)
            )
            == expected
        ), (access, body)
    for body, expected in [
        ("func start() -> Task<Int, Error> { Task { try await service.fetchPaper(id: 1) } }", True),
        ("func start() { Task { _ = try await service.fetchPaper(id: 1) } }", True),
        ("func factory() -> Callback { Callback { try await service.fetchPaper(id: 1) } }", False),
    ]:
        index = swift_syntax_index_sources(
            {
                app_path: (
                    "import PaperFeature; struct Callback { let action: () async throws -> Int }; "
                    "struct BackgroundRequestService { "
                )
                + "let service: PaperService; "
                + body
                + " }",
                leaf: (
                    "public struct PaperService { public func fetchPaper(id: Int) async throws -> "
                    "Int { id } }"
                ),
            }
        )
        assert ("BIT101-iOS.BackgroundRequestService" in business_methods(index)) == expected, body
    task_helper = "private func startRequest() { Task { _ = try await client.send(request) } }"
    for argument, expected in (
        ("root", True),
        ('root.appendingPathComponent("items")', True),
        ('"items"', False),
    ):
        source = """import TransportCore; struct NewService { let client: HTTPClient;
            func start(_ root: URL) { go(ARGUMENT) }
            private func go(_ url: URL) { Task { _ = try await client.send(URLRequest(url: url)) } }
            private func go(_ text: String) {} }""".replace("ARGUMENT", argument)
        index = swift_syntax_index_sources(
            {app_path: source, transport_path: "public struct HTTPClient {}"}
        )
        assert ("BIT101-iOS.NewService" in business_methods(index)) == expected, argument
    for body, helpers, expected in [
        ("func start() { startRequest() }", task_helper, True),
        ("func start() { self.startRequest() }", task_helper, True),
        (
            "func start() { forward() }",
            "private func forward() { startRequest() }; " + task_helper,
            True,
        ),
        (
            "func start() { Task { try await startRequest() } }",
            "private func startRequest() async throws { _ = try await client.send(request) }",
            True,
        ),
        (
            "func start() { Task { try await self.startRequest() } }",
            "private func startRequest() async throws { _ = try await client.send(request) }",
            True,
        ),
        ("func factory() -> () -> Void { { startRequest() } }", task_helper, False),
        ("func factory() -> Callback { Callback { startRequest() } }", task_helper, False),
        ("func label() { if false { startRequest() } }", task_helper, False),
        (
            'func label() { startRequest("cached") }',
            (
                "private func startRequest(_ value: String) {}; private func startRequest(_ value:"
                " Int) { Task { _ = try await client.send(request) } }"
            ),
            False,
        ),
        (
            "func start() { startRequest(42) }",
            (
                "private func startRequest(_ value: String) {}; private func startRequest(_ value:"
                " Int) { Task { _ = try await client.send(request) } }"
            ),
            True,
        ),
        ("func label() { forward() }", "private func forward() { forward() }", False),
    ]:
        source = (
            (
                "import TransportCore; struct Callback { let action: () -> Void }; struct Backgrou"
                "ndRequestService { let client: HTTPClient; "
            )
            + body
            + "; "
            + helpers
            + " }"
        )
        index = swift_syntax_index_sources(
            {app_path: source, transport_path: "public struct HTTPClient {}"}
        )
        methods = business_methods(index).get("BIT101-iOS.BackgroundRequestService", [])
        assert bool(methods) == expected, (body, helpers, methods)
        assert all(not function.get("isPrivate") for _, function in methods), methods
        assert (
            any(
                "新增生产服务需要网络能力验收归属：BIT101-iOS.BackgroundRequestService" in error
                for error in network_capability_findings(index)
            )
            == expected
        ), (body, helpers)
    extension_path = "BIT101-iOS/Shell/BackgroundRequestExtension.swift"
    index = swift_syntax_index_sources(
        {
            app_path: "import TransportCore; struct BackgroundRequestService { "
            + "let client: HTTPClient; func start() { startRequest() } }",
            extension_path: (
                "import TransportCore; extension BackgroundRequestService { func startRequest() { "
                "Task { _ = try await client.send(request) } } }"
            ),
            transport_path: "public struct HTTPClient {}",
        }
    )
    assert {
        function["name"]
        for _, function in business_methods(index)["BIT101-iOS.BackgroundRequestService"]
    } == {"start", "startRequest"}
    boundary = (
        "protocol Fetching { func fetch() async }\n        public struct RegisteredService: Fetchi"
        "ng { let client: HTTPClient; public func fetch() async {} }\n        public struct Consum"
        "er { let service: any Fetching; public func load() async { await service.fetch() } }"
    )
    with patch.dict(
        NETWORK_CAPABILITIES,
        {"NewForumFeature.RegisteredService": {"fetch()": "network"}},
        clear=True,
    ):
        assert set(business_methods(swift_syntax_index_sources({getter_path: boundary}))) == {
            "NewForumFeature.RegisteredService"
        }
    for port, expected in [
        ("(URLRequest) async throws -> HTTPResponse", True),
        ("(URLRequest) async throws -> Data", True),
        ("(URL) async throws -> Data", True),
        ("(URLRequest) async throws -> (Data, URLResponse)", True),
        ("(String) async throws -> String", False),
    ]:
        for annotation in (port, "Sending"):
            source = (
                f"typealias Sending = "
                f"{port}"
                f"; public struct ClosureService {{ let send: "
                f"{annotation}"
                f"; public func fetch() async throws {{ _ = try await send(request) }} }}"
            )
            index = swift_syntax_index_sources({getter_path: source})
            assert ("NewForumFeature.ClosureService" in business_methods(index)) == expected, (
                port,
                annotation,
            )
    for source in [
        (
            "public func fetch(client: HTTPClient, request: URLRequest) async throws -> Data { try"
            " await client.send(request).data }"
        ),
        (
            "public struct ReadService { public func fetch(_ url: URL) throws -> Data { try Data(c"
            "ontentsOf: url) } }"
        ),
    ]:
        index = swift_syntax_index_sources({getter_path: source})
        assert business_methods(index), source
        assert any("新增生产服务" in error for error in network_capability_findings(index)), source
    file_reader = (
        "public struct FileService { public func read(_ url: URL) throws -> Data { guard url.isFil"
        "eURL else { throw Failure.invalid }; return try Data(contentsOf: url) } }"
    )
    index = swift_syntax_index_sources({getter_path: file_reader})
    assert not business_methods(index), file_reader
    helper = (
        'private static func fetch() -> Data? { guard let url = URL(string: "https://example.inval'
        'id") else { return nil }; return try? Data(contentsOf: url) }'
    )
    for declaration, signature in [
        ("private let response = Self.fetch(); public init() {}", "init()"),
        ("private let response = Self.fetch()", "init()"),
        ("deinit { _ = Self.fetch() }", "deinit()"),
    ]:
        source = (
            "import Foundation; public final class NewService { "
            + declaration
            + "; "
            + helper
            + " }"
        )
        index = swift_syntax_index_sources({getter_path: source})
        assert {
            method_signature(function)
            for _, function in business_methods(index)["NewForumFeature.NewService"]
        } == {signature}, declaration
        assert any("新增生产服务" in error for error in network_capability_findings(index)), (
            declaration
        )
