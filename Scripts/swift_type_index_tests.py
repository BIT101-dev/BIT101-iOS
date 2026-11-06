"""Regression cases for type ownership across modules and private declaration files."""

from pathlib import Path
from swift_source_index import (
    ROOT,
    swift_syntax_index_sources,
    declaration_conformances,
    canonical_type_scope,
)
from swift_type_index import SwiftTypeIndex

from swift_execution_tests import (
    receiver_parameter_self_test,
    asynchronous_wait_self_test as asynchronous_wait_self_test,
    collection_callback_self_test as collection_callback_self_test,
    network_composition_self_test as network_composition_self_test,
    standard_callback_self_test as standard_callback_self_test,
    extension_protocol_self_test as extension_protocol_self_test,
    literal_masking_self_test as literal_masking_self_test,
    foundation_collection_self_test as foundation_collection_self_test,
    resource_audit_execution_self_test as resource_audit_execution_self_test,
)


def recursive_network_reachability_self_test():
    from network_capability_rules import business_methods

    for names in [("first", "second"), ("second", "first")]:
        for enabled in ("true", "false"):
            entries = "\n".join(
                "public func "
                + name
                + "() async throws { try await "
                + ("helperA" if name == "first" else "helperB")
                + "() }"
                for name in names
            )
            source = (
                (
                    "import Foundation\n                public struct ReachabilitySe"
                    "rvice {\n                    ENTRIES\n                    publi"
                    "c func quiet() async throws { if false { try await request() } "
                    "}\n                    private func helperA() async throws {\n "
                    "                       if Bool.random() { try await helperB() }"
                    "\n                        try await request()\n                "
                    "    }\n                    private func helperB() async throws "
                    "{ if Bool.random() { try await helperA() } }\n                 "
                    "   private func request() async throws {\n                     "
                    "   if ENABLED { _ = try await URLSession.shared.data(from: URL("
                    'string: "https://example.invalid")!) }\n                    }\n'
                    "                }"
                )
                .replace("ENTRIES", entries)
                .replace("ENABLED", enabled)
            )
            index = swift_syntax_index_sources(
                {"Modules/NewForumFeature/Sources/ReachabilityService.swift": source}
            )
            methods = business_methods(index).get("NewForumFeature.ReachabilityService", [])
            assert {function["name"] for _, function in methods} == (
                set(names) if enabled == "true" else set()
            ), (names, enabled, methods)


def contextual_overload_self_test():
    from network_capability_rules import matching_api_calls, execution_index, call_can_execute

    cases = [
        ("", "Int32", "String", "1", "Int32"),
        ("", "UInt32", "String", "0x10", "UInt32"),
        ("", "Float", "String", "1.25", "Float"),
        ("", "CGFloat", "String", "1.25", "CGFloat"),
        ("typealias Narrow = Int32", "Narrow", "String", "1", "Narrow"),
        (
            "struct Number: ExpressibleByIntegerLiteral { init(integerLiteral: Int) {} }",
            "Number",
            "String",
            "1",
            "Number",
        ),
        ("", "Int?", "String", "nil", "Int?"),
        ("typealias Number = Int32?", "Number", "String", "nil", "Number"),
        ("enum State { case active }", "State", "String", ".active", "State"),
        (
            "enum State { case active }; typealias Selection = State",
            "Selection",
            "String",
            ".active",
            "Selection",
        ),
        ("", "Int", "Int32", "1", "Int"),
        ("", "Double", "Float", "1.25", "Double"),
    ]
    for declarations, first, second, value, expected in cases:
        path = "BIT101-iOS/Context.swift"
        source = (
            declarations
            + f"""\nstruct Service {{ func fetch(id: {first}) {{}}; func fetch(id: {second}) {{}} }}
            struct Use {{ let service: Service; func run() {{ service.fetch(id: {value}) }} }}"""
        )
        index = swift_syntax_index_sources({path: source})
        facts = index[path]
        call = next(
            node for node in facts["invocations"] if node["calledExpression"] == "service.fetch"
        )
        functions = [
            (path, function)
            for function in facts["functionRanges"]
            if function["scope"] == ["Service"]
        ]
        matched = matching_api_calls(index, functions + functions, dict(call, path=path))
        assert [function["parameters"][0]["type"] for _, function in matched] == [expected], (
            value,
            first,
            second,
            matched,
        )
    sources = {
        "Modules/Tokens/Sources/Token.swift": """public struct Token: Equatable {
        public static func ==(lhs: Token, rhs: Token) -> Bool { true } }""",
        "BIT101-iOS/Use.swift": (
            "import Tokens\n        struct Use { func run() { if ((false)) { service.dea"
            "d() }; if true { service.live() } } }"
        ),
    }
    index = execution_index(swift_syntax_index_sources(sources))
    facts = index["BIT101-iOS/Use.swift"]
    assert not facts["constantFoldingAllowed"]
    calls = {
        node["calledExpression"] for node in facts["invocations"] if call_can_execute(facts, node)
    }
    assert "service.live" in calls and "service.dead" not in calls


def indexer_environment_self_test():
    from unittest.mock import patch
    import validation_environment as environment
    from swift_source_index import indexer_toolchain

    environment.environment_context.cache_clear()
    indexer_toolchain.cache_clear()
    try:
        with (
            patch.object(
                environment,
                "host_environment",
                return_value={"developer": "/toolchain", "compiler": {"version": "frontend"}},
            ),
            patch.object(environment, "plist_values", return_value={"Version": "sdk"}),
            patch.object(
                environment.subprocess,
                "check_output",
                side_effect=AssertionError("Swift 索引沿编译依赖采集环境"),
            ),
            patch.object(Path, "is_file", return_value=False),
            patch.object(Path, "rglob", return_value=[]),
        ):
            context = indexer_toolchain(Path("/toolchain/swiftc"), Path("/toolchain/host"))[
                "environment"
            ]
            assert (
                set(context["sdks"]) == {"MacOSX"} and context["compiler"]["version"] == "frontend"
            )
            assert "runtimes" not in context
    finally:
        environment.environment_context.cache_clear()
        indexer_toolchain.cache_clear()


def lifecycle_execution_self_test():
    from code_quality_rules import automatic_school_fetch_findings

    service = (
        "protocol ScheduleCourseServicing { func syncCourses() async }; struct Service: ScheduleCo"
        "urseServicing { func syncCourses() async {} }"
    )
    cases = [
        (
            (
                "struct Loader { func load(_ value: Int) async {}; func load(_ value: String) asyn"
                "c { await Service().syncCourses() } }"
            ),
            "await loader.load(1)",
            False,
        ),
        (
            (
                "struct Loader { func load(_ value: Int) async {}; func load(_ value: String) asyn"
                "c { await Service().syncCourses() } }"
            ),
            'await loader.load("school")',
            True,
        ),
        (
            (
                "struct Loader { func load(_ value: Int) async {}; func load(_ value: String) asyn"
                "c { await Service().syncCourses() } }"
            ),
            "await loader.load(unknown)",
            True,
        ),
        (
            (
                "struct Loader { func load(local value: Int) async {}; func load(remote value: Int"
                ") async { await Service().syncCourses() } }"
            ),
            "await loader.load(local: 1)",
            False,
        ),
        (
            (
                "struct Loader { func load(local value: Int) async {}; func load(remote value: Int"
                ") async { await Service().syncCourses() } }"
            ),
            "await loader.load(remote: 1)",
            True,
        ),
        (
            (
                "struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader"
                " { func load(_ value: Model = Model()) {} }"
            ),
            "loader.load()",
            True,
        ),
        (
            (
                "struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader"
                " { func load(_ value: Model = Model()) {} }"
            ),
            "loader.load(existing)",
            False,
        ),
        (
            (
                "struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader"
                " { func load(_ value: Model = Model()) {} }"
            ),
            "loader.load(Model())",
            True,
        ),
        (
            (
                "struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader"
                " { init(_ value: Model = Model()) {} }"
            ),
            "_ = Loader()",
            True,
        ),
        (
            (
                "struct Model { init() { Task { await Service().syncCourses() } } }; struct Loader"
                " { init(_ value: Model = Model()) {} }"
            ),
            "_ = Loader(existing)",
            False,
        ),
        (
            (
                "struct Loader { var value: Int { get async { await Service().syncCourses(); retur"
                "n 1 } } }"
            ),
            "_ = await loader.value",
            True,
        ),
        (
            "struct Loader { var value: Int { Task { await Service().syncCourses() }; return 1 } }",
            "_ = loader.value",
            True,
        ),
        (
            "struct Loader { func value() { Task { await Service().syncCourses() } } }",
            "_ = loader.value",
            False,
        ),
        ("struct Loader { var value: Int { 1 } }", "_ = loader.value", False),
        ("class Loader { deinit { Task { await Service().syncCourses() } } }", "_ = loader", True),
        ("class Loader { deinit { record() } }", "_ = loader", False),
        (
            (
                "class Parent { func load() async { await Service().syncCourses() } }; class Loade"
                "r: Parent { func run() async { await self.load() } }"
            ),
            "await loader.run()",
            True,
        ),
        (
            (
                "struct Loader { let start: Int }; struct Bootstrap { func start() async { await S"
                "ervice().syncCourses() } }"
            ),
            "record(loader.start)",
            False,
        ),
        (
            "struct Loader { var start: Int { Task { await Service().syncCourses() }; return 1 } }",
            "record(loader.start)",
            True,
        ),
        (
            (
                "struct Loader { func load<T>(_ value: T) async { await Service().syncCourses() };"
                " func load(_ value: Int) async {} }"
            ),
            'await loader.load("school")',
            True,
        ),
        (
            (
                "struct Loader { func load<T>(_ value: T) async { await Service().syncCourses() };"
                " func load(_ value: Int) async {} }"
            ),
            "await loader.load(1)",
            False,
        ),
        (
            (
                "struct Loader { func load<T>(_ value: T) async { await Service().syncCourses() };"
                " func load(_ value: Int) async {} }"
            ),
            "await loader.load(unknown)",
            True,
        ),
    ]
    for declarations, operation, expected in cases:
        path = str(ROOT / "BIT101-iOS/Lifecycle.swift")
        source = (
            service
            + "\n"
            + declarations
            + (
                "\nstruct Screen: View { let loader: Loader; let existing: Model; var body: some V"
                'iew { Text("sample").task { '
            )
            + operation
            + " } } }"
        )
        findings = automatic_school_fetch_findings(swift_syntax_index_sources({path: source}))
        assert bool(findings) == expected, (declarations, operation, findings)
    for module, expected in [("ScheduleSync", False), ("OtherSync", True)]:
        sources = {
            str(ROOT / f"Modules/{module}/Sources/Cloud.swift"): (
                "public class ScheduleCloudSyncManager { public static let shared = ScheduleCloudS"
                "yncManager(); public func refreshFromCloudIfNeeded() async {} }"
            ),
            path: (
                f"import "
                f"{module}"
                f'\nstruct Screen: View {{ var body: some View {{ Text("sample").task {{ await Sche'
                f"duleCloudSyncManager.shared.refreshFromCloudIfNeeded() }} }} }}"
            ),
        }
        findings = automatic_school_fetch_findings(swift_syntax_index_sources(sources))
        assert bool(findings) == expected, (module, findings)
        for kind, callback in [
            ("class", "Task { await self.refreshFromCloudIfNeeded() }"),
            ("actor", "Task { [weak self] in await self?.refreshFromCloudIfNeeded() }"),
        ]:
            sources[str(ROOT / f"Modules/{module}/Sources/Cloud.swift")] = (
                f"public "
                f"{kind}"
                f" ScheduleCloudSyncManager {{ public static let shared = ScheduleCloudSyncMa"
                f"nager(); public func refreshFromCloudIfNeeded() async {{ "
                f"{callback}"
                f" }} }}"
            )
            findings = automatic_school_fetch_findings(swift_syntax_index_sources(sources))
            assert bool(findings) == expected, (module, kind, findings)


def stored_network_callback_self_test():
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls

    def check_closure_case(sources, initializer, body, argument, supplied, expected, network):
        index = swift_syntax_index_sources(sources)
        assert all(not facts.get("parseErrors") for facts in index.values())
        methods = business_methods(index)
        found = {
            function["name"]
            for path, function in methods.get("CommunityTransport.ClosureClient", [])
        }
        assert ("fetch" in found) == (expected and network), (
            initializer,
            body,
            argument,
            supplied,
            methods,
        )

    service_path = "Modules/CommunityTransport/Sources/ClosureClient.swift"
    caller_path = "BIT101-iOS/ClosureClientUsage.swift"
    for initializer in (
        "public init(load: @escaping () async throws -> Data) { self.load = load }",
        "",
    ):
        for body, expected in [
            ("try await load()", True),
            ("try await self.load()", True),
            ("try await Task { try await load() }.value", True),
            ("if false { return try await load() }; return Data()", False),
            ("Data()", False),
            ("let load = { Data() }; return load()", False),
        ]:
            for argument in ("{ try await http.send(request).data }", "operation"):
                for supplied, network in [
                    ("try await http.send(request).data", True),
                    ("Data()", False),
                ]:
                    closure = argument.replace("try await http.send(request).data", supplied)
                    sources = {
                        service_path: f"""public struct ClosureClient {{
                        let load: () async throws -> Data
                        {initializer}
                        public func fetch() async throws -> Data {{ {body} }}
                    }}""",
                        caller_path: (
                            f"import CommunityTransport\n                        func useClosure"
                            f"Client(http: HTTPClient, request: URLRequest) async throws -> Data"
                            f" {{\n                            let operation = {{ "
                            f"{supplied}"
                            f" }}\n                            let client = ClosureClient(load: "
                            f"{closure}"
                            f")\n                            return try await client.fetch()\n  "
                            f"                      }}"
                        ),
                    }
                    check_closure_case(
                        sources, initializer, body, argument, supplied, expected, network
                    )
    for construction, expected in [
        ("Operations(callback: callback)", True),
        (
            "if false { return Operations(callback: callback) }; return Operations(callback: {})",
            False,
        ),
    ]:
        expression = "return " + construction if expected else construction
        source = (
            f"struct Operations {{ var callback: () -> Void }}\n            struct ReleaseNetworkS"
            f"mokeRunner {{\n                func run() {{ let operations = make(); operations.cal"
            f"lback() }}\n                func make() -> Operations {{ let callback = {{ service.li"
            f"ve() }}; "
            f"{expression}"
            f" }}\n                func unused() -> Operations {{ let callback = {{ service.idle() "
            f"}}; return Operations(callback: callback) }}\n            }}"
        )
        index = swift_syntax_index_sources({"ReleaseNetworkSmoke.swift": source})
        types = SwiftTypeIndex(index)
        assert types.resolve(
            "ReleaseNetworkSmoke.swift", "Self", ["ReleaseNetworkSmokeRunner", "Operations", 1]
        ) == types.resolve("ReleaseNetworkSmoke.swift", "ReleaseNetworkSmokeRunner.Operations")
        calls = reachable_smoke_calls(index)["network"]
        names = {call["calledExpression"] for call in calls}
        assert ("service.live" in names) == expected and "service.idle" not in names, (
            construction,
            names,
        )


def dynamic_network_callback_self_test():
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls

    path = "Modules/CourseFeature/Sources/Observer.swift"
    for selector in (
        "#selector(refresh)",
        "#selector(Observer.refresh)",
        'Selector("refresh")',
        'NSSelectorFromString("refresh")',
        'Foundation.Selector(#"refresh"#)',
        'Foundation.NSSelectorFromString("refresh")',
        "callback",
        "alias",
    ):
        for registration, expected in [
            (
                (
                    "NotificationCenter.default.addObserver(self, selector: SELECTOR, name: nil, o"
                    "bject: nil)"
                ),
                True,
            ),
            (
                (
                    "if false { NotificationCenter.default.addObserver(self, selector: SELECTOR, n"
                    "ame: nil, object: nil) }"
                ),
                False,
            ),
            ("let unused = SELECTOR; _ = unused", False),
            ("ignore(SELECTOR)", False),
        ]:
            source = f"""import Foundation; import TransportCore
                public class Observer: NSObject {{
                    let http: HTTPClient; let request: URLRequest
                    public func begin() {{ let callback = #selector(refresh); let alias = callback;
                        {registration.replace("SELECTOR", selector)} }}
                    private func ignore(_ selector: Selector) {{}}
                    @objc private func refresh() {{ Task {{ _ = try await http.send(request) }} }}
                }}"""
            index = swift_syntax_index_sources({path: source})
            assert not index[path].get("parseErrors")
            methods = business_methods(index)
            assert (
                any(
                    function["name"] == "begin" for rows in methods.values() for _, function in rows
                )
                == expected
            ), (selector, registration, methods)
    for optional, declaration in [
        ("", "private var action: () -> Void = {}"),
        ("?", "private var action: (() -> Void)?"),
    ]:
        source = (
            f"import TransportCore\n            public class Worker {{ let http: HTTPClient; let "
            f"request: URLRequest; "
            f"{declaration}"
            f"\n                public func begin() {{ action = {{ Task {{ _ = try await http.send("
            f"request) }} }}; action"
            f"{optional}"
            f"() }}\n            }}"
        )
        methods = business_methods(swift_syntax_index_sources({path: source}))
        assert any(
            function["name"] == "begin" for rows in methods.values() for _, function in rows
        ), (optional, methods)
        runtime = source.replace("Worker", "ReleaseNetworkSmokeRunner").replace(
            "func begin()", "func run()"
        )
        calls = reachable_smoke_calls(
            swift_syntax_index_sources({"ReleaseNetworkSmoke.swift": runtime})
        )["network"]
        assert any(call["calledExpression"] == "http.send" for call in calls), optional


def callable_object_network_self_test():
    collection_callback_self_test()
    standard_callback_self_test()
    from network_capability_rules import business_methods
    from validation_test_areas import reachable_smoke_calls

    fetcher = """private struct Fetcher { let client: HTTPClient; let request: URLRequest
        fileprivate func callAsFunction() async throws { _ = try await client.send(request) } }"""
    for body, expected in [
        ("try await fetcher()", True),
        ("try await self.fetcher()", True),
        ("try await fetcher.callAsFunction()", True),
        ("_ = fetcher", False),
        ("let fetcher = Fetcher(client: client, request: request); try await fetcher()", True),
        ("_ = Fetcher(client: client, request: request)", False),
        ("func fetcher() {}; fetcher()", False),
    ]:
        source = (
            fetcher
            + f"""\npublic struct Service {{
            private let fetcher: Fetcher; let client: HTTPClient; let request: URLRequest
            public func fetch() async throws {{ {body} }} }}"""
        )
        methods = business_methods(
            swift_syntax_index_sources({"Modules/CourseFeature/Sources/Service.swift": source})
        )
        assert (
            any(function["name"] == "fetch" for rows in methods.values() for _, function in rows)
            == expected
        ), (body, methods)
        runtime = source.replace("Service", "ReleaseNetworkSmokeRunner").replace(
            "func fetch()", "func run()"
        )
        calls = reachable_smoke_calls(
            swift_syntax_index_sources({"ReleaseNetworkSmoke.swift": runtime})
        )["network"]
        assert any(call["calledExpression"] == "client.send" for call in calls) == expected, (
            body,
            calls,
        )


def self_test():
    generic_path, ports, storage = verify_type_and_receiver_index()
    indexed, view = verify_generic_and_view_receivers(generic_path, ports, storage)
    verify_request_target_resolution(indexed, view)


def verify_type_and_receiver_index():
    receiver_parameter_self_test()
    network_composition_self_test()
    extension_protocol_self_test()
    lifecycle_execution_self_test()
    indexer_environment_self_test()
    contextual_overload_self_test()
    from io import BytesIO
    from unittest.mock import patch
    from swift_source_index import indexer_toolchain

    compiler = Path("/toolchain/usr/bin/swiftc")
    host_modules = Path("/toolchain/usr/lib/swift/host")
    artifacts = {
        str(compiler): b"compiler",
        str(host_modules / "libSwiftSyntax.dylib"): b"syntax",
        str(host_modules / "libSwiftParser.dylib"): b"parser",
        str(host_modules / "libSwiftOperators.dylib"): b"operators",
    }
    with (
        patch(
            "validation_environment.environment_context",
            return_value={"compiler": {"version": "frontend"}},
        ),
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "rglob", return_value=[]),
        patch.object(Path, "open", lambda path, *args, **kwargs: BytesIO(artifacts[str(path)])),
        patch.object(
            Path,
            "stat",
            new=lambda path: __import__("types").SimpleNamespace(
                st_size=len(artifacts[str(path)]), st_mtime_ns=1
            ),
        ),
    ):
        indexer_toolchain.cache_clear()
        original = indexer_toolchain(compiler, host_modules)
        for module in ("SwiftSyntax", "SwiftParser", "SwiftOperators"):
            artifacts[str(host_modules / f"lib{module}.dylib")] = b"updated-" + module.encode()
            indexer_toolchain.cache_clear()
            updated = indexer_toolchain(compiler, host_modules)
            assert updated != original, module
            original = updated
        indexer_toolchain.cache_clear()
    from code_quality_rules import automatic_school_fetch_findings, ast_has_view_request
    from swift_type_index import SwiftBindingTypes

    local_path = "BIT101-iOS/Local.swift"
    local = swift_syntax_index_sources(
        {
            local_path: (
                "protocol LocalPort { func fetch() }; struct Owner { let service: any LocalPort; f"
                "unc load() { service.fetch() } }"
            )
        }
    )
    bindings = SwiftBindingTypes(local)
    call = next(call for call in local[local_path]["calls"] if call["value"] == "service.fetch")
    assert bindings.receiver_components(call) == {"BIT101-iOS.LocalPort"}
    from ui_rules import native_interaction_inventory

    request_path = str(ROOT / "BIT101-iOS/RequestView.swift")
    request_support = str(ROOT / "BIT101-iOS/RequestSupport.swift")
    for parameter, expected in [("URLRequest", True), ("Model", False)]:
        context = swift_syntax_index_sources(
            {
                request_path: "struct Screen: View { func load() { consume(.init(url: url)) } }",
                request_support: "extension Screen { func consume(_ value: "
                + parameter
                + ", enabled: Bool = true) {} }",
            }
        )
        assert ast_has_view_request(context[request_path], context=context) == expected
    factories = [
        "func makeBootstrap(_ value: Int) -> SchoolBootstrap { SchoolBootstrap() }",
        "func makeBootstrap(_ value: String) -> SafeBootstrap { SafeBootstrap() }",
    ]
    for declarations in (factories, list(reversed(factories))):
        for argument, restricted in [("1", True), ('"safe"', False), ("unknown", True)]:
            source = (
                (
                    "\nclass ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }"
                    "\nstruct SchoolBootstrap { let cloud = ScheduleCloudSyncManager(); func start"
                    "() async { await cloud.refreshFromCloudIfNeeded() } }\nstruct SafeBootstrap {"
                    " func start() async {} }\n"
                )
                + "\n".join(declarations)
                + (
                    f'\nstruct OverloadedApp: App {{ var body: some Scene {{ WindowGroup {{ Text("s'
                    f'ample").task {{ await makeBootstrap('
                    f"{argument}"
                    f").start() }} }} }} }}\n"
                )
            )
            facts = swift_syntax_index_sources({str(ROOT / "BIT101-iOS/Overloaded.swift"): source})
            assert bool(automatic_school_fetch_findings(facts)) == restricted, (
                declarations,
                argument,
            )
    assert canonical_type_scope(
        ["Module.Wrapper<(Int) -> Void>.Holder<[Other.Model]>.Control"]
    ) == ("Module", "Wrapper", "Holder", "Control")
    generic_path = str(ROOT / "BIT101-iOS/Generic.swift")
    generics = swift_syntax_index_sources(
        {
            generic_path: """
class Wrapper<T> { class Control: UIButton {}; class Holder<U> { class Control: UISwitch {} } }
typealias Native = Wrapper<(Int) -> Void>.Control
typealias Nested = Wrapper<[Int]>.Holder<String>.Control
struct Use { func build() { _ = Native(); _ = Nested() } }
"""
        }
    )
    assert native_interaction_inventory(generics)["BIT101-iOS/Generic.swift:Use"] == {
        "UIButton": 1,
        "UISwitch": 1,
    }
    generic_fetch = swift_syntax_index_sources(
        {
            generic_path: (
                "\nclass ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }\ncl"
                "ass Wrapper<T> { struct Service { let cloud = ScheduleCloudSyncManager(); func st"
                "art() async { await cloud.refreshFromCloudIfNeeded() } } }\ntypealias Service = W"
                "rapper<(Int) -> Void>.Service\nstruct GenericApp: App { var body: some Scene { Wi"
                'ndowGroup { Text("sample").task { await Service().start() } } } }\n'
            )
        }
    )
    assert len(automatic_school_fetch_findings(generic_fetch)) == 1
    from code_quality_rules import discarded_file_write_findings, file_write_calls

    ports = str(ROOT / "Modules/SchedulePorts/Sources/ScheduleServicing.swift")
    storage = str(ROOT / "Modules/StorageCore/Sources/AppFileService.swift")
    return generic_path, ports, storage


def verify_generic_and_view_receivers(generic_path, ports, storage):
    from code_quality_rules import automatic_school_fetch_findings, ast_has_view_request
    from code_quality_rules import discarded_file_write_findings, file_write_calls

    for parameter, constraint in [
        ("S: ScheduleCourseServicing", ""),
        ("S", "where S: ScheduleCourseServicing"),
        ("S: ScheduleCourseServicing & Sendable", ""),
        ("S, U: ScheduleCourseServicing", "where S == U"),
    ]:
        source = (
            f"struct Review<"
            f"{parameter}"
            f">: View "
            f"{constraint}"
            f' {{ let service: S; var body: some View {{ Text("").task {{ await service.fetchCurren'
            f"tTermOnly() }} }} }}"
        )
        facts = swift_syntax_index_sources(
            {
                generic_path: "import SchedulePorts; " + source,
                ports: (
                    "public protocol ScheduleCourseServicing { func fetchCurrentTermOnly() async t"
                    "hrows -> String }"
                ),
            }
        )
        assert automatic_school_fetch_findings(facts), (parameter, constraint)
    for parameter, constraint in [
        ("F: AppFileService", ""),
        ("F", "where F: AppFileService"),
        ("F: AppFileService & Sendable", ""),
    ]:
        source = (
            f"import StorageCore; func drop<"
            f"{parameter}"
            f">(_ files: F) "
            f"{constraint}"
            f" {{ try? files.removeItem(at: url) }}"
        )
        facts = swift_syntax_index_sources(
            {
                generic_path: source,
                storage: "public protocol AppFileService { func removeItem(at url: URL) throws }",
            }
        )
        assert discarded_file_write_findings(
            Path(generic_path), source, facts[generic_path], file_write_calls(facts)
        )
    shadowed = swift_syntax_index_sources(
        {
            generic_path: (
                "import SchedulePorts; struct Review<S: ScheduleCourseServicing> { func local<S>(_"
                " service: S) { service.fetchCurrentTermOnly() } }"
            ),
            ports: (
                "public protocol ScheduleCourseServicing { func fetchCurrentTermOnly() async throw"
                "s -> String }"
            ),
        }
    )
    from swift_type_index import SwiftBindingTypes

    bindings = SwiftBindingTypes(shadowed)
    call = next(
        call
        for call in shadowed[generic_path]["invocations"]
        if call["calledExpression"] == "service.fetchCurrentTermOnly"
    )
    assert not bindings.receiver_components(call, generic_path)
    extensions = swift_syntax_index_sources(
        {
            "TestClass.swift": "class Journey: XCTestCase {}",
            "TestMethods.swift": "extension Journey { func testRoute() {} }",
        }
    )
    assert [test["value"] for test in extensions["TestMethods.swift"]["tests"]] == [
        "Journey/testRoute"
    ]
    sources = {
        "Modules/AlphaFeature/Sources/Model.swift": (
            "public class Model: UIButton {}; public struct Screen: View {}; public typealias Nati"
            "ve = Model; class TestHarness: XCTestCase { func testAlpha() {} }"
        ),
        "Modules/BetaCore/Sources/Model.swift": (
            "public class Model: Sendable {}; public struct Screen: Sendable {}; class TestHarness"
            ": Sendable { func testExample() {} }"
        ),
        "Modules/AlphaFeature/Sources/Use.swift": "struct Use { func build() { _ = Model() } }",
        "Modules/BetaCore/Sources/Use.swift": (
            "struct Use { func build() { _ = Model() } }; extension Screen { func load() { _ = URL"
            "Request(url: url) } }"
        ),
        "BIT101-iOS/PrivateA.swift": (
            "private class Model: UIButton {}; struct UseA { func build() { _ = Model() } }"
        ),
        "BIT101-iOS/PrivateB.swift": (
            "private class Model: Sendable {}; struct UseB { func build() { _ = Model() } }"
        ),
        "BIT101-iOS/Imported.swift": (
            "import AlphaFeature; struct Imported { func build() { _ = Native(); _ = AlphaFeature."
            "Model() } }"
        ),
    }
    indexed = swift_syntax_index_sources(
        {str(ROOT / path): source for path, source in sources.items()}
    )
    types = SwiftTypeIndex(indexed)
    alpha = str(ROOT / "Modules/AlphaFeature/Sources/Model.swift")
    beta = str(ROOT / "Modules/BetaCore/Sources/Model.swift")
    assert types.conformances(alpha)[("Model",)] == {"UIButton"}
    assert types.conformances(beta)[("Model",)] == {"Sendable"}
    assert indexed[beta]["tests"] == []
    assert [test["value"] for test in indexed[alpha]["tests"]] == ["TestHarness/testAlpha"]
    assert ("AlphaFeature", "Model") in declaration_conformances(indexed)
    use = str(ROOT / "Modules/BetaCore/Sources/Use.swift")
    assert not ast_has_view_request(indexed[use], types.conformances(use), indexed)
    view = "BIT101-iOS/RequestView.swift"
    other = "Modules/Unrelated/Sources/Local.swift"
    for imported, exported, expected in [
        (False, False, True),
        (False, True, True),
        (True, False, True),
        (True, True, False),
    ]:
        request_sources = {
            view: ("import Unrelated; " if imported else "")
            + "import Foundation; struct Screen: View { func load() { _ = URLRequest(url: url) } }",
            other: ("public " if exported else "")
            + "typealias URLRequest = LocalModel; public struct LocalModel {}",
        }
        requests = swift_syntax_index_sources(request_sources)
        assert ast_has_view_request(requests[view], context=requests) == expected, (
            imported,
            exported,
        )
        request_sources[view] = request_sources[view].replace(
            "URLRequest(url:", "Foundation.URLRequest(url:"
        )
        requests = swift_syntax_index_sources(request_sources)
        assert ast_has_view_request(requests[view], context=requests)
    for imported, exported in [(False, True), (True, False), (True, True)]:
        requests = swift_syntax_index_sources(
            {
                view: ("import Unrelated; " if imported else "")
                + "struct Screen: View { func load() { _ = Request(url: url) } }",
                other: ("public " if exported else "")
                + "typealias Request = Foundation.URLRequest",
            }
        )
        assert ast_has_view_request(requests[view], context=requests) == (imported and exported)
    return indexed, view


def verify_request_target_resolution(indexed, view):
    from code_quality_rules import automatic_school_fetch_findings, ast_has_view_request
    from ui_rules import native_interaction_inventory

    for request, expected in [
        ("func load() { typealias URLRequest = Model; _ = URLRequest() }", False),
        (
            (
                "func helper() { typealias URLRequest = Model }; func load() { _ = URLRequest(url:"
                " url) }"
            ),
            True,
        ),
        ("func load() { typealias Request = Foundation.URLRequest; _ = Request(url: url) }", True),
    ]:
        requests = swift_syntax_index_sources(
            {view: "struct Model {}; struct Screen: View { " + request + " }"}
        )
        assert ast_has_view_request(requests[view], context=requests) == expected, request
    controls = native_interaction_inventory(indexed)
    assert controls["Modules/AlphaFeature/Sources/Use.swift:Use"]["UIButton"] == 1
    assert controls["BIT101-iOS/PrivateA.swift:UseA"]["UIButton"] == 1
    assert controls["BIT101-iOS/Imported.swift:Imported"]["UIButton"] == 2
    assert all("BetaCore" not in key and "PrivateB" not in key for key in controls)
    for module in ("AlphaFeature", "BetaCore"):
        services = {
            "Modules/AlphaFeature/Sources/Service.swift": (
                "class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; publ"
                "ic struct Model { let cloud = ScheduleCloudSyncManager(); public func start() asy"
                "nc { await cloud.refreshFromCloudIfNeeded() } }; public enum Factory { public sta"
                "tic func make() -> Model { Model() } }"
            ),
            "Modules/BetaCore/Sources/Service.swift": (
                "public struct Model { public func start() async {} }; public enum Factory { publi"
                "c static func make() -> Model { Model() } }"
            ),
            "BIT101-iOS/App.swift": (
                f"import "
                f"{module}"
                f'; struct SampleApp: App {{ var body: some Scene {{ WindowGroup {{ Text("sample").'
                f"task {{ await Factory.make().start() }} }} }} }}"
            ),
        }
        facts = swift_syntax_index_sources(
            {str(ROOT / path): source for path, source in services.items()}
        )
        assert bool(automatic_school_fetch_findings(facts)) == (module == "AlphaFeature")
    private_sources = {
        "BIT101-iOS/First.swift": (
            "class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; private "
            "struct Model { let cloud = ScheduleCloudSyncManager(); func start() async { await clo"
            "ud.refreshFromCloudIfNeeded() } }; private enum Factory { static func make() -> Model"
            ' { Model() } }; struct FirstApp: App { var body: some Scene { WindowGroup { Text("sam'
            'ple").task { await Factory.make().start() } } } }'
        ),
        "BIT101-iOS/Second.swift": (
            "private struct Model { func start() async {} }; private enum Factory { static func ma"
            "ke() -> Model { Model() } }; struct SecondApp: App { var body: some Scene { WindowGro"
            'up { Text("sample").task { await Factory.make().start() } } } }'
        ),
    }
    facts = swift_syntax_index_sources(
        {str(ROOT / path): source for path, source in private_sources.items()}
    )
    issues = automatic_school_fetch_findings(facts)
    assert len(issues) == 1 and "FirstApp" in issues[0]
