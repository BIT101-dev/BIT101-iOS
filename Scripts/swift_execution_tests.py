"""Focused checks for swift execution tests."""

from swift_source_index import (
    ROOT,
    swift_syntax_index_sources,
)
from swift_type_index import SwiftTypeIndex


def asynchronous_wait_self_test(wait_path) -> None:
    from code_quality_rules import ROOT, asynchronous_test_wait_findings
    from swift_source_index import swift_syntax_index_sources

    findings = []
    for body, expected in (
        ("while pending == nil { await Task.yield() }", 1),
        ("while true { try? await Task.sleep(for: .milliseconds(10)) }", 1),
        ("while !done { try? await Task.sleep(for: .milliseconds(10)) }", 1),
        ("while true { try await Task.sleep(for: .milliseconds(10)) }", 0),
        ("while pending == nil { try Task.checkCancellation(); await Task.yield() }", 1),
        ("try await waitForTestEvent { pending != nil }", 0),
        ("for _ in 0..<3 { await Task.yield() }", 0),
        ('while pending == nil { consume("Task.yield()") }', 0),
        ("await withCheckedContinuation { response = $0 }", 0),
    ):
        source = "func testEvent() async throws { " + body + " }"
        facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
        if len(asynchronous_test_wait_findings(wait_path, source, facts)) != expected:
            findings.append("异步事件等待自测：取消检查与有限等待入口需要共同验收")
    for body, expected in (
        ("await withCheckedContinuation { started = $0 }", 1),
        ("try await waitForTestEvent { pending != nil }", 0),
    ):
        source = "func waitUntilRequested() async throws { " + body + " }"
        facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
        if len(asynchronous_test_wait_findings(wait_path, source, facts)) != expected:
            findings.append("异步事件观察自测：请求到达门闩沿共享期限与取消入口验收")
    for body in (
        "await helper.receive()",
        "_ = await iterator.next()",
        "for await event in events { if event { break } }",
        "let pending = Task { await helper.request() }; await pending.value",
        "let pending = Task { await helper.request() }; #expect(await pending.value == 41)",
        "let pending = Task { await helper.request() }; await pending?.value",
        "await sync.refreshFromCloudIfNeeded()?.value",
        "await (pending).value",
        (
            "await withTaskCancellationHandler { await withCheckedContinuation { started = $0 } } "
            "onCancel: { release() }"
        ),
    ):
        for attribute, expected in (("@Test", 1), ("@Test(.timeLimit(.minutes(1)))", 0)):
            source = attribute + " func eventReceipt() async { " + body + " }"
            facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
            assert len(asynchronous_test_wait_findings(wait_path, source, facts)) == expected
            source = (
                "@Suite(.timeLimit(.minutes(1))) struct Outer { @Suite struct Inner { "
                + source
                + " } }"
            )
            facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
            assert asynchronous_test_wait_findings(wait_path, source, facts) == []
    for limit, expected in (("", 1), (".timeLimit(.minutes(1))", 0)):
        source = (
            "@Suite("
            + limit
            + (
                ") struct Case { @Test func hangs() async { await forward() }; func forward() asyn"
                "c { await observeEvent() }; func observeEvent() async { await withCheckedContinua"
                "tion { continuation in } } }"
            )
        )
        facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
        assert len(asynchronous_test_wait_findings(wait_path, source, facts)) == expected
    source = (
        "@Test func hangs() async { let ignored = TimeLimitTrait.timeLimit(.minutes(1)); await wit"
        "hCheckedContinuation { continuation in } }"
    )
    facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
    assert len(asynchronous_test_wait_findings(wait_path, source, facts)) == 2
    for body in (
        "await withCheckedContinuation { started = $0 }",
        "if ready { await withCheckedContinuation { started = $0 } }",
        "try await withCheckedThrowingContinuation { started = $0 }",
    ):
        source = "@Test(.timeLimit(.minutes(1))) func timerFires() async { " + body + " }"
        facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
        assert len(asynchronous_test_wait_findings(wait_path, source, facts)) == 1
    source = (
        "@Test(.timeLimit(.minutes(1))) func fixture() async throws { let client = Client { await "
        "withCheckedContinuation { gate = $0 } }; try await waitForTestEvent { gate != nil } }"
    )
    facts = swift_syntax_index_sources({str(wait_path): source})[str(wait_path)]
    assert asynchronous_test_wait_findings(wait_path, source, facts) == []
    support = ROOT / "ModuleTests/Support/FileServiceContract.swift"
    source = support.read_text()
    facts = swift_syntax_index_sources({str(support): source})[str(support)]
    if asynchronous_test_wait_findings(support, source, facts):
        findings.append("异步事件等待自测：共享等待实现沿行为回归验收")
    source += "\nfunc other() async { while pending == nil { await Task.yield() } }\n"
    facts = swift_syntax_index_sources({str(support): source})[str(support)]
    if len(asynchronous_test_wait_findings(support, source, facts)) != 1:
        findings.append("异步事件等待自测：共享文件中的其他函数遵循调用入口")
    assert findings == [], findings


def collection_callback_self_test() -> None:
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls

    for setup, body, expected in (
        (
            "let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]",
            "for action in actions { try await action() }",
            True,
        ),
        (
            "let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]",
            "for action in actions { _ = action }",
            False,
        ),
        (
            "let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]",
            "if false { for action in actions { try await action() } }",
            False,
        ),
        (
            "let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]",
            "for action in actions { let action = {}; action() }",
            False,
        ),
        (
            (
                "let actions: [() async throws -> Void] = [{ _ = try await client.send(request) }]"
                "; let copy = actions"
            ),
            "for action in copy { try await action() }",
            True,
        ),
        ("", "for action in [{ _ = try await client.send(request) }] { try await action() }", True),
    ):
        setup = setup + ";" if setup else ""
        source = (
            f"public struct Service {{ let client: HTTPClient; let request: URLRequest; public fu"
            f"nc load() async throws {{ "
            f"{setup}"
            f" "
            f"{body}"
            f" }} }}"
        )
        methods = business_methods(
            swift_syntax_index_sources({"Modules/CourseFeature/Sources/Service.swift": source})
        )
        assert (
            any(function["name"] == "load" for rows in methods.values() for _, function in rows)
            == expected
        ), (body, methods)
        runtime = source.replace("Service", "ReleaseNetworkSmokeRunner").replace(
            "func load()", "func run()"
        )
        calls = reachable_smoke_calls(
            swift_syntax_index_sources({"ReleaseNetworkSmoke.swift": runtime})
        )["network"]
        assert any(call["calledExpression"] == "client.send" for call in calls) == expected, (
            body,
            calls,
        )
    source = (
        "struct ReleaseNetworkSmokeRunner {\n        func run() async {\n            var actions: "
        "[@MainActor () async -> Void] = [{ await service.first() }, { await service.second() }]\n"
        "            for item in Kind.allCases { actions.append { await service.third(item) } }\n "
        "           if false { actions.append { await service.idle() } }\n            await runInP"
        "arallel(actions)\n        }\n        func runInParallel(_ operations: [@MainActor () asyn"
        "c -> Void]) async {\n            await withTaskGroup(of: Void.self) { group in\n         "
        "       for operation in operations { group.addTask { await operation() } }\n            }"
        "\n        }\n    }"
    )
    for invocation, expected in [
        ("await runInParallel(actions)", {"service.first", "service.second", "service.third"}),
        ("_ = actions", set()),
    ]:
        index = swift_syntax_index_sources(
            {
                "ReleaseNetworkSmoke.swift": source.replace(
                    "await runInParallel(actions)", invocation
                )
            }
        )
        expressions = {call["calledExpression"] for call in reachable_smoke_calls(index)["network"]}
        assert (
            expressions & {"service.first", "service.second", "service.third", "service.idle"}
            == expected
        ), expressions


def network_composition_self_test() -> None:
    from network_capability_rules import business_methods

    path = "Modules/ClientCore/Sources/Composition.swift"
    transport = "Modules/TransportCore/Sources/HTTPClient.swift"
    for body, expected in [
        ("self.transport = transport", False),
        ("self.transport = transport; Task { _ = try await transport.data(for: request) }", True),
    ]:
        sources = {
            transport: (
                "public struct HTTPClient { let transport: HTTPTransport; public init(transport: H"
                "TTPTransport) { "
            )
            + body
            + " } }",
            path: (
                "import TransportCore; public struct Composition { public func build(transport: HT"
                "TPTransport) { _ = HTTPClient(transport: transport) } }"
            ),
        }
        assert (
            "ClientCore.Composition" in business_methods(swift_syntax_index_sources(sources))
        ) == expected, body
    for declaration, expected in [
        ("extension View { func helper() {} }", False),
        ("protocol View {}", True),
    ]:
        source = declaration + (
            "; public struct Screen: View { public func load() { Task { _ = try await URLSessi"
            "on.shared.data(from: url) } } }"
        )
        assert (
            bool(business_methods(swift_syntax_index_sources({"BIT101-iOS/Screen.swift": source})))
            == expected
        ), declaration
    import runpy

    rules = runpy.run_path(str(ROOT / "Scripts/check-module-boundaries.py"))
    for owner, permitted in [
        ("GalleryWebCoordinator", True),
        ("GalleryRootViewScene.GalleryWebView", True),
        ("OtherView", False),
    ]:
        parts = owner.split(".")
        source = (
            "struct " + parts[0] + " { " + ("struct " + parts[1] + " { " if len(parts) == 2 else "")
        )
        source += "func make() { _ = WKWebView() }" + " }" * len(parts)
        errors = rules["service_boundary_errors"](
            "Modules/GalleryFeature/Sources/GalleryRootView.swift", source
        )
        assert bool(errors) != permitted, (owner, errors)
    source = (
        "struct GalleryWebCoordinator { func make() { _ = URLSession(configuration: configuration)"
        " } }"
    )
    assert rules["service_boundary_errors"](
        "Modules/GalleryFeature/Sources/GalleryRootView.swift", source
    )
    source = """public struct Service {
        private let loadData: (URLRequest) async throws -> Data
        public init(loadData: @escaping (URLRequest) async throws -> Data = {
            try await URLSession.shared.data(for: $0).0
        }) { self.loadData = loadData }
        public func fetch(request: URLRequest) async throws -> Data { try await loadData(request) }
    }"""
    from network_capability_rules import method_signature

    methods = business_methods(swift_syntax_index_sources({path: source}))
    assert {method_signature(function) for rows in methods.values() for _, function in rows} == {
        "fetch(request:URLRequest)"
    }, methods
    source = source.replace("loadData", "download").replace("(URLRequest)", "(URL)")
    methods = business_methods(swift_syntax_index_sources({path: source}))
    assert {function["name"] for rows in methods.values() for _, function in rows} == {"fetch"}, (
        methods
    )
    from validation_test_areas import reachable_smoke_calls

    for returned in ("Self(create: create)", "self"):
        source = """struct ReleaseNetworkSmokeRunner { struct Operations { var create: () -> Void
            func scoped() -> Self { RETURNED } }
            func run() { let original = Operations(create: { service.live() })
                let operations = original.scoped(); operations.create() }
        }""".replace("RETURNED", returned)
        calls = reachable_smoke_calls(
            swift_syntax_index_sources({"ReleaseNetworkSmoke.swift": source})
        )["network"]
        assert any(call["calledExpression"] == "service.live" for call in calls), returned


def standard_callback_self_test() -> None:
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls

    for name in (
        "withCheckedContinuation",
        "withCheckedThrowingContinuation",
        "withUnsafeContinuation",
        "withUnsafeThrowingContinuation",
        "autoreleasepool",
        "withUnsafePointer",
        "withUnsafeMutablePointer",
        "withUnsafeTemporaryAllocation",
        "data.withUnsafeBytes",
        "data.withUnsafeMutableBytes",
        "data.withUnsafeBufferPointer",
        "data.withUnsafeMutableBufferPointer",
    ):
        for conditional, expected in (("", True), ("if false", False)):
            body = f"{name} {{ Task {{ _ = try? await client.send(request) }} }}"
            if conditional:
                body = conditional + " { " + body + " }"
            source = (
                (
                    "public struct Service { let client: HTTPClient; let request: URLRequest; publ"
                    "ic func load() async { "
                )
                + body
                + " } }"
            )
            methods = business_methods(
                swift_syntax_index_sources({"Modules/CourseFeature/Sources/Service.swift": source})
            )
            assert (
                any(function["name"] == "load" for rows in methods.values() for _, function in rows)
                == expected
            ), name
            source = source.replace("Service", "ReleaseNetworkSmokeRunner").replace(
                "func load()", "func run()"
            )
            calls = reachable_smoke_calls(
                swift_syntax_index_sources({"ReleaseNetworkSmoke.swift": source})
            )["network"]
            assert any(call["calledExpression"] == "client.send" for call in calls) == expected, (
                name,
                calls,
            )


def extension_protocol_self_test() -> None:
    for imported in (False, True):
        sources = {
            "Modules/SupportCore/Sources/Protocols.swift": (
                "public protocol ParentProtocol {}; public protocol ChildProtocol: ParentProtocol "
                "{}"
            ),
            "Modules/CourseFeature/Sources/Loader.swift": "public struct Loader {}",
            "Modules/CourseFeature/Sources/LoaderPort.swift": (
                "import SupportCore; " if imported else ""
            )
            + "extension Loader: ChildProtocol {}",
        }
        index = swift_syntax_index_sources(sources)
        types = SwiftTypeIndex(index)
        bases = types.conformances("Modules/CourseFeature/Sources/Loader.swift")[("Loader",)]
        assert ("ParentProtocol" in bases) == imported, (imported, bases)
        assert "ChildProtocol" in bases


def literal_masking_self_test() -> None:
    from unittest.mock import patch
    from swift_source_index import swift_code

    source = 'let address = "https://literal-boundary.example/path"; /* /comment/ */\nlet value = 1'
    with patch(
        "swift_source_index._run_swift_syntax_index",
        side_effect=AssertionError("文字与注释沿词法边界处理"),
    ):
        masked = swift_code(source)
    assert "literal-boundary" not in masked and masked.endswith("let value = 1")
    expression = 'let expression = #/a"//b/#; let value = 1'
    masked = swift_code(expression)
    assert (
        "let expression =" in masked
        and masked.endswith("; let value = 1")
        and 'a"//b' not in masked
    )


def foundation_collection_self_test(service_boundary_errors) -> None:
    literal_masking_self_test()
    from network_capability_rules import business_methods

    path = "Modules/CommunityPersistence/Sources/Store.swift"
    reader_path = "Modules/StorageCore/Sources/AppFileService.swift"
    callbacks = (
        "func collect(read: () -> Int, write: (Int) -> Void) { write(read()) }; func run() { colle"
        "ct(read: { 1 }, write: { _ in }) }"
    )
    assert not service_boundary_errors(path, callbacks)
    assert service_boundary_errors(
        path, callbacks + "; func unsafe() { _ = Darwin.read(0, nil, 0) }"
    )
    aliases = "let openSocket = Darwin.socket; let sendBytes = Glibc.send"
    facts = swift_syntax_index_sources({path: aliases})[path]
    assert all(member["isExpressionReference"] for member in facts["members"])
    assert service_boundary_errors(path, aliases)
    for kind in ("NSDictionary", "NSMutableDictionary", "NSArray", "NSMutableArray"):
        for body in (
            f"_ = {kind}(contentsOf: url)",
            f"_ = Foundation.{kind}.init(contentsOfFile: file)",
            f"_ = Foundation.{kind}.self.init(contentsOf: url)",
            "let value = Collection(contentsOf: url)",
            f"let value: {kind}? = .init(contentsOf: url)",
            "_ = value.write(to: url)",
            "_ = value.write(toFile: file, atomically: true)",
            "let write = value.write(to:atomically:)",
            f"let read: (URL) -> {kind}? = {kind}.init(contentsOf:)",
        ):
            source = (
                f"import Foundation; typealias Collection = Foundation."
                f"{kind}"
                f"; public struct Store {{ "
            ) + (
                f"public func fetch(_ url: URL, file: String, value: {kind}) throws {{ {body} }} }}"
            )
            assert service_boundary_errors(path, source), (kind, body)
            approved = source.replace("struct Store", "struct LocalAppFileService")
            assert service_boundary_errors(reader_path, approved) == [], (kind, body)
        for body in (
            f"_ = {kind}(contentsOf: url)",
            "let value = Collection(contentsOf: url)",
            f"let value: {kind}? = .init(contentsOf: url)",
            f"let read: (URL) -> {kind}? = {kind}.init(contentsOf:); _ = read(url)",
        ):
            for guard, expected in (("", True), ("guard url.isFileURL else { return };", False)):
                source = (
                    f"import Foundation; typealias Collection = Foundation."
                    f"{kind}"
                    f"; public struct LocalAppFileService {{ "
                ) + f"public func fetch(_ url: URL) {{ {guard} {body} }} }}"
                assert (
                    bool(business_methods(swift_syntax_index_sources({reader_path: source})))
                    == expected
                ), (kind, body, guard)
        for body in (
            f"_ = {kind}(contentsOfFile: file)",
            f"let read: (URL) -> {kind}? = {kind}.init(contentsOf:)",
            "_ = value.write(to: url)",
        ):
            source = (
                "import Foundation; public struct LocalAppFileService { public func fetch(_ ur"
                "l: URL, "
            ) + f"file: String, value: {kind}) {{ {body} }} }}"
            assert business_methods(swift_syntax_index_sources({reader_path: source})) == {}, (
                kind,
                body,
            )
        for calls, expected in (
            ("read(url)", False),
            ("read(other)", True),
            ("read(url); read(other)", True),
        ):
            source = (
                "import Foundation; public struct LocalAppFileService { public func fetch(_ ur"
                "l: URL, other: URL) { "
            ) + (
                f"let read: (URL) -> "
                f"{kind}"
                f"? = "
                f"{kind}"
                f".init(contentsOf:); guard url.isFileURL else {{ return }}; "
                f"{calls}"
                f" }} }}"
            )
            assert (
                bool(business_methods(swift_syntax_index_sources({reader_path: source})))
                == expected
            ), (kind, calls)
        source = (
            f"struct {kind} {{ init(contentsOf url: URL) {{}}; func write(to url: URL) {{}} }}; "
            + f"public struct Store {{ public func fetch(_ url: URL, value: {kind}) {{ "
            + f"_ = {kind}(contentsOf: url); value.write(to: url) }} }}"
        )
        assert service_boundary_errors(path, source) == [], kind
        assert business_methods(swift_syntax_index_sources({path: source})) == {}, kind


def resource_audit_execution_self_test(rules) -> None:
    from unittest.mock import patch
    import swift_source_index
    import network_capability_rules

    artwork = "Modules/GalleryFeature/Sources/Artwork.swift"
    for expression in (
        "AsyncImage(url: url)",
        "SwiftUI.AsyncImage(url: url)",
        "let load = AsyncImage.self; load(url: url)",
    ):
        source = (
            "import SwiftUI; struct Artwork: View { let url: URL; var body: some View { "
            + expression
            + " } }"
        )
        errors = rules["service_boundary_errors"](artwork, source)
        assert any("load remote images through MediaKit" in error for error in errors), expression
    source = (
        "struct AsyncImage { init(url: URL) {} }; struct Artwork { func make(url: URL) { _ = Async"
        "Image(url: url) } }"
    )
    assert rules["service_boundary_errors"](artwork, source) == []
    source = (
        "public struct Local {\n"
        + "\n".join(f"func hop{i}() {{ hop{i + 1}(); hop{i + 1}() }}" for i in range(12))
        + "\nfunc hop12() {} }"
    )
    with patch.object(
        network_capability_rules,
        "call_can_execute",
        wraps=network_capability_rules.call_can_execute,
    ) as execute:
        assert (
            network_capability_rules.business_methods(
                swift_syntax_index_sources(
                    {"Modules/CourseInfrastructure/Sources/Local.swift": source}
                )
            )
            == {}
        )
    assert execute.call_count < 13**2 * 2, execute.call_count
    from swift_type_index import custom_constant_symbols

    facts = {"source": "func load() {}"}
    assert not custom_constant_symbols(facts)
    facts["source"] = "func load<Int>() {}"
    assert custom_constant_symbols(facts)
    facts["source"] = "func load() {}"
    facts["functionRanges"] = [{"name": "=="}]
    assert custom_constant_symbols(facts)
    facts["functionRanges"] = []
    facts["typeAliases"] = [{"name": "Bool"}]
    assert custom_constant_symbols(facts)
    facts["typeAliases"] = []
    assert not custom_constant_symbols(facts)
    import swift_type_index

    path = "Modules/CourseInfrastructure/Sources/Store.swift"
    source = (
        "struct NetworkPort {}; struct OtherPort {}; struct Store { let client: NetworkPort; "
        "func load() { let client = OtherPort(); client.send(); self.client.send() } }"
    )
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    calls = [
        dict(call, path=path)
        for call in index[path]["invocations"]
        if call["calledExpression"].endswith(".send")
    ]
    with patch.object(
        swift_type_index, "visible_variables", wraps=swift_type_index.visible_variables
    ) as lookup:
        for _ in range(10):
            assert resolve(calls[0]).endswith(".OtherPort")
            assert resolve(calls[1]).endswith(".NetworkPort")
    assert lookup.call_count <= 3, lookup.call_count
    source = (
        "struct Port {}; struct Owner { static let provider = Port(); static let client = prov"
        "ider; func inspect() { let client = foreignValue; client.send(); Self.client.send() }"
        " }"
    )
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    calls = [
        dict(call, path=path)
        for call in index[path]["invocations"]
        if call["calledExpression"].endswith(".send")
    ]
    assert resolve(calls[0]) is None
    assert resolve(calls[1]).endswith(".Port")
    source = (
        "struct Port {}; protocol Placeholder {}; struct Owner { var client: Placeholder?; "
        "func configure() { let source = Port(); client = source }; "
        "func inspect() { guard let client = client else { return }; client.send() } }"
    )
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    call = next(
        call for call in index[path]["invocations"] if call["calledExpression"] == "client.send"
    )
    assert resolve(dict(call, path=path)).endswith(".Port")
    source = (
        "protocol Placeholder {}; struct OtherPort {}; struct Owner { var client: Placeholder;"
        " func inspect() { var other = foreignValue; let value = OtherPort(); other.client = v"
        "alue; client.send() } }"
    )
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    call = next(
        call for call in index[path]["invocations"] if call["calledExpression"] == "client.send"
    )
    assert resolve(dict(call, path=path)).endswith(".Placeholder")
    source = (
        "protocol Placeholder {}; struct OtherPort {}; struct Owner { var client: Placeholder;"
        " func inspect(client: Placeholder) { let other = OtherPort(); self.client = other; cl"
        "ient.send() } }"
    )
    index = swift_syntax_index_sources({path: source})
    resolve = swift_type_index.receiver_resolver(index)
    call = next(
        call for call in index[path]["invocations"] if call["calledExpression"] == "client.send"
    )
    assert resolve(dict(call, path=path)).endswith(".Placeholder")
    source = (
        "// 中文 / source prefix\nstruct Reader { "
        "func fetch(_ url: URL, first: Data, second: NSArray) { "
        "let ignored = #/NSData(contentsOf: url)/#; _ = Data(contentsOf: url) } }"
    )
    with patch.object(
        swift_source_index,
        "_run_swift_syntax_index",
        wraps=swift_source_index._run_swift_syntax_index,
    ) as parser:
        errors = rules["service_boundary_errors"](
            "Modules/CommunityPersistence/Sources/Reader.swift", source
        )
    assert len(errors) == 1, errors
    assert sum(bool(call.kwargs.get("regex_only")) for call in parser.call_args_list) <= 1, (
        parser.call_count
    )
    effects = "BIT101-iOS/Effects.swift"
    helpers = "BIT101-iOS/Helpers.swift"
    for custom_path, imported in (
        (None, ""),
        ("BIT101-iOS/Operators.swift", ""),
        ("Modules/SupportCore/Sources/Operators.swift", "import SupportCore; "),
    ):
        sources = {
            effects: imported
            + (
                "struct AppScheduleCacheEffects { func changed() { if 1 == 2 { loadAccountStorage("
                ") } } }"
            ),
            helpers: "func loadAccountStorage() { AppAccountSession.storage }",
        }
        if custom_path:
            sources[custom_path] = "func == (lhs: Int, rhs: Int) -> Bool { true }"
        index = swift_syntax_index_sources(sources)
        roles = rules["adapter_call_roles"](index)
        errors = rules["adapter_ownership_errors"](
            index[helpers], helpers, rules["adapter_roles"](index, helpers), call_roles=roles
        )
        assert bool(errors) == bool(custom_path), (custom_path, errors)


def receiver_parameter_self_test() -> None:
    from swift_type_index import receiver_resolver

    path = "Modules/Example/Sources/Example.swift"
    sources = {
        path: """
        protocol Port { func fetch() }
        struct Service: Port { func fetch() {} }
        struct Host {
            let source = Service()
            func run() { helper(source) }
            func helper(_ service: any Port) { service.fetch() }
        }
    """
    }
    index = swift_syntax_index_sources(sources)
    call = next(
        call for call in index[path]["invocations"] if call["calledExpression"] == "service.fetch"
    )
    declared = receiver_resolver(index)
    concrete = receiver_resolver(index, follow_parameters=True)
    assert declared(dict(call, path=path)) == "Example.Port"
    assert concrete(dict(call, path=path)) == "Example.Service"
