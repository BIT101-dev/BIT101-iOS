"""Regression cases for the module and resource ownership rules."""

import re
from pathlib import Path

from module_resource_tests import (
    resource_access_self_test as resource_access_self_test,
    owned_source as owned_source,
    callback_execution_self_test as callback_execution_self_test,
    foundation_network_self_test as foundation_network_self_test,
    package_test_module_self_test as package_test_module_self_test,
    url_reader_network_self_test as url_reader_network_self_test,
    module_coverage_binary_self_test as module_coverage_binary_self_test,
)
from module_manifest_tests import (
    module_types_self_test as module_types_self_test,
)
from module_service_tests import (
    service_access_self_test as service_access_self_test,
)


def callable_network_api_self_test(rules: dict) -> None:
    from network_capability_rules import business_methods, matching_api_calls, method_signature
    from validation_test_areas import network_capability_findings

    path = "Modules/NewForumFeature/Sources/ClosureService.swift"
    for body, expected in [
        (
            (
                "public var fetch: () async throws -> HTTPResponse; public init(http: HTTPClient, "
                "request: URLRequest) { fetch = { try await http.send(request) } }"
            ),
            True,
        ),
        (
            (
                "public var fetch: (URLRequest) async throws -> HTTPResponse = { request in try aw"
                "ait HTTPClient().send(request) }"
            ),
            True,
        ),
        ("public var fetch = { try await HTTPClient().send(request) }", True),
        ("private var fetch = { try await HTTPClient().send(request) }", False),
        (
            (
                "public var fetch = { 1 }; public init(http: HTTPClient, request: URLRequest) { le"
                "t fetch = { try await http.send(request) } }"
            ),
            False,
        ),
        (
            (
                "public func make(http: HTTPClient, request: URLRequest) -> () async throws -> HTT"
                "PResponse { { try await http.send(request) } }"
            ),
            True,
        ),
        ("public var fetch: () async -> Int { { 1 } }", False),
    ]:
        source = "import TransportCore; public struct ClosureService { " + body + " }"
        index = rules["swift_syntax_index_sources"](
            {
                path: source,
                "Modules/TransportCore/Sources/HTTPClient.swift": "public struct HTTPClient {}",
            }
        )
        methods = business_methods(index)
        assert bool(methods) == expected, (body, methods)
        if not (expected):
            continue
        assert network_capability_findings(index), body
        functions = methods["NewForumFeature.ClosureService"]
        for _, function in functions:
            arguments = ["request"] * len(function.get("parameters", []))
            call = dict(
                path=path,
                calledExpression="service." + function["name"],
                scope=[],
                start=len(source.encode()),
                arguments=arguments,
                argumentLabels=[""] * len(arguments),
            )
            if function["name"] == "make":
                call["argumentLabels"] = ["http", "request"]
            assert matching_api_calls(index, functions, call), (
                body,
                method_signature(function),
            )
            call["isMemberRead"] = True
            assert matching_api_calls(index, functions, call) == [], body

    from network_capability_rules import NETWORK_HARNESS_TYPES

    for registration, expected in (
        ("UIView.animate(withDuration: 1, animations: {}) { _ in BODY }", True),
        ("animator.addCompletion { _ in BODY }", True),
        ("framework.registerCallback { BODY }", True),
        ("ExternalExecutor { BODY }", True),
        ("DispatchWorkItem { BODY }", False),
        ("storeCallback { BODY }", False),
    ):
        source = (
            "import UIKit; import Foundation; func storeCallback(_ callback: () -> Void) {};"
            + " public struct CallbackService { public func fetch() { "
            + registration.replace(
                "BODY", "Task { _ = try await URLSession.shared.data(from: url) }"
            )
            + " } }"
        )
        index = rules["swift_syntax_index_sources"]({path: source})
        assert bool(business_methods(index)) == expected, source
    for function in ("connectx", "disconnectx", "sendfile", "sockatmark"):
        for prefix, expression, expected in (
            ("", function + "(1)", True),
            ("", "Darwin." + function + "(1)", True),
            ("func " + function + "(_ value: Int) {}; ", function + "(1)", False),
        ):
            source = (
                "import Darwin; "
                + prefix
                + "public struct SocketService { public func fetch() { "
                + expression
                + " } }"
            )
            index = rules["swift_syntax_index_sources"]({path: source})
            assert bool(rules["service_boundary_errors"](path, source)) == expected, source
            assert bool(business_methods(index)) == expected, source
    for kind, method in (
        ("NetService", "publish()"),
        ("NetService", "resolve(withTimeout: 1)"),
        ("NetService", "startMonitoring()"),
        ("NetServiceBrowser", 'searchForServices(ofType: "_http._tcp", inDomain: "local.")'),
    ):
        for declared, expected in (("Foundation." + kind, True), (kind, True), ("Local", False)):
            source = (
                "import Foundation; struct Local { func "
                + method.split("(")[0]
                + "() {} }; public struct BonjourService { public func fetch(service: "
                + declared
                + ") { service."
                + method
                + " } }"
            )
            index = rules["swift_syntax_index_sources"]({path: source})
            assert bool(rules["service_boundary_errors"](path, source)) == expected, source
            assert bool(business_methods(index)) == expected, source
    for owner, harness_path in NETWORK_HARNESS_TYPES.items():
        name = owner.split(".")[-1]
        body = (
            "import TransportCore; public struct "
            + name
            + (
                " { let http: HTTPClient; public func fetch(request: URLRequest) async throws -> H"
                "TTPResponse { try await http.send(request) } }"
            )
        )
        for selected_path, guarded, exempt in (
            (harness_path, True, True),
            (harness_path, False, False),
            ("BIT101-iOS/Shared/Client/OtherService.swift", True, False),
            (path, True, False),
        ):
            source = "#if DEBUG || RELEASE_NETWORK_SMOKE\n" + body + "\n#endif" if guarded else body
            index = rules["swift_syntax_index_sources"](
                {
                    selected_path: source,
                    "Modules/TransportCore/Sources/HTTPClient.swift": "public struct HTTPClient {}",
                }
            )
            assert bool(business_methods(index)) != exempt, (
                owner,
                selected_path,
                guarded,
                business_methods(index),
            )


def build_cache_exit_self_test() -> list[str]:
    import subprocess

    source = (Path(__file__).parent / "script-support.sh").read_text()
    cache = (
        "bit101_build_cache() {"
        + source.split("bit101_build_cache() {", 1)[1].split("\nbit101_run_logged()", 1)[0]
    )
    findings = []
    for status in (0, 79):
        for maintenance in ("", "--maintenance"):
            harness = (
                f"python3() {{ print CALL; return {status}; }}\n"
                + cache
                + "\nif bit101_build_cache "
                + maintenance
                + "; then exit 0; else exit $?; fi"
            )
            result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
            if result.returncode != status or result.stdout.count("CALL") != (
                2 if maintenance and status == 0 else 1
            ):
                findings.append(
                    "构建缓存委托需要在条件调用中保留编译失败，并沿成功状态执行缓存维护。"
                )
    return findings


def streaming_transport_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from network_capability_rules import business_methods
    from code_quality_rules import ROOT, view_transport_findings

    for expression in (
        "session.bytes(for: request)",
        "session.bytes(from: url)",
        "session.bytes(for:)",
    ):
        for kind, expected in (("URLSession", True), ("Local", False)):
            declarations = (
                "import Foundation; struct Local { func bytes(for request: URLRequest) async {} }; "
            )
            body = (
                "let session: "
                + kind
                + "; public func fetch() { Task { _ = try await "
                + expression
                + " } }"
            )
            service = swift_syntax_index_sources(
                {
                    "Modules/NewForumFeature/Sources/Service.swift": declarations
                    + "public struct Service { "
                    + body
                    + " }"
                }
            )
            assert bool(business_methods(service)) == expected, (expression, kind)
            view = swift_syntax_index_sources(
                {
                    str(ROOT / "BIT101-iOS/Example.swift"): declarations
                    + "struct Example: View { let session: "
                    + kind
                    + '; var body: some View { Text("").task { _ = try await '
                    + expression
                    + " } } }"
                }
            )
            assert bool(view_transport_findings(view)) == expected, (expression, kind)


def stream_network_self_test(rules: dict) -> None:
    from network_capability_rules import business_methods
    from validation_test_areas import network_capability_findings

    path = "Modules/NewForumFeature/Sources/StreamService.swift"
    operation = (
        'var input: InputStream?; var output: OutputStream?; %s.getStreamsToHost(withName: "exampl'
        'e.invalid", port: 443, inputStream: &input, outputStream: &output); input?.open(); output'
        "?.open()"
    )
    for prefix, receiver, expected in (
        ("", "Stream", True),
        ("", "Foundation.Stream", True),
        ("typealias Socket = Foundation.Stream;", "Socket", True),
        ("let Socket = Stream.self;", "Socket", True),
        ("class Socket: Foundation.Stream {};", "Socket", True),
        (
            (
                "struct Stream { static func getStreamsToHost(withName: String, port: Int, inputSt"
                "ream: inout InputStream?, outputStream: inout OutputStream?) {} };"
            ),
            "Stream",
            False,
        ),
    ):
        source = (
            "import Foundation; "
            + prefix
            + " public struct StreamService { public func connect() { "
            + operation % receiver
            + " } }"
        )
        index = rules["swift_syntax_index_sources"]({path: source})
        assert bool(rules["service_boundary_errors"](path, source)) == expected, source
        assert bool(business_methods(index)) == expected, source
        assert (
            any(
                "NewForumFeature.StreamService" in row for row in network_capability_findings(index)
            )
            == expected
        ), source
    for operation in (
        "let input = InputStream(data: Data()); input.open()",
        (
            "var input: InputStream?; var output: OutputStream?; Stream.getBoundStreams(withBuffer"
            "Size: 100, inputStream: &input, outputStream: &output)"
        ),
    ):
        source = (
            "import Foundation; public struct StreamService { public func connect() { "
            + operation
            + " } }"
        )
        index = rules["swift_syntax_index_sources"]({path: source})
        assert rules["service_boundary_errors"](path, source) == [], source
        assert business_methods(index) == {}, source
    source = (
        "import Foundation; let Socket = Stream.self; struct LocalStream { func getStreamsToHost()"
        " {} }; public struct StreamService { public func connect(Socket: LocalStream) { Socket.ge"
        "tStreamsToHost() } }"
    )
    index = rules["swift_syntax_index_sources"]({path: source})
    assert rules["service_boundary_errors"](path, source) == [], source
    assert business_methods(index) == {}, source


def subprocess_resource_self_test(rules: dict) -> None:
    path = "Modules/SampleDomain/Sources/Service.swift"
    for expression in (
        "let process = Foundation.Process(); try process.run()",
        "let process = NSTask(); process.launch()",
        "typealias Runner = Foundation.Process; let process = Runner()",
        "let kind = Process.self; let process = kind.init()",
        'system("curl https://example.invalid")',
        "Darwin.posix_spawn(nil, nil, nil, nil, nil, nil)",
        'let execute = system; execute("curl https://example.invalid")',
    ):
        assert rules["service_boundary_errors"](path, expression), expression
    for source in (
        "struct Process { func run() {} }; let value = Process(); value.run()",
        "struct NSTask { func launch() {} }; let value = NSTask(); value.launch()",
        'func system(_ value: String) {}; system("literal")',
        "let identifier = ProcessInfo.processInfo.processIdentifier",
    ):
        assert not rules["service_boundary_errors"](path, source), source


def local_resource_self_test(rules: dict) -> None:
    from swift_type_index import SwiftBindingTypes

    path = "Modules/PaperFeature/Sources/Probe.swift"
    for name, access in (
        ("FileManager", "default"),
        ("UserDefaults", "standard"),
        ("URLCache", "shared"),
    ):
        declaration = f"struct {name} {{ static let `{access}` = {name}() }}"
        expression = f"let local = {name}.{access}"
        for sources in (
            {path: declaration + "; " + expression},
            {path: expression, "Modules/PaperFeature/Sources/Memory.swift": declaration},
            {path: "struct Scope { " + declaration + "; func run() { " + expression + " } }"},
        ):
            context = SwiftBindingTypes(rules["swift_syntax_index_sources"](sources))
            source = sources[path]
            assert rules["service_boundary_errors"](path, source, call_context=context) == [], (
                name,
                sources,
            )
            assert (
                rules["ownership_errors"]("PaperFeature", source, path, call_context=context) == []
            ), (name, sources)
            real = source + f"; let actual = Foundation.{name}.{access}"
            assert rules["service_boundary_errors"](path, real, call_context=context), name
            assert rules["ownership_errors"]("PaperFeature", real, path, call_context=context), name
        if name == "UserDefaults":
            for use in (
                "let value: UserDefaults = .standard",
                "let value: UserDefaults = .init()",
                "func consume(_ value: UserDefaults) {}; consume(.standard)",
            ):
                source = declaration + "; " + use
                assert rules["service_boundary_errors"](path, source) == [], use
                assert rules["ownership_errors"]("PaperFeature", source, path) == [], use
        alias = f"typealias {name} = Foundation.{name}; {expression}"
        assert rules["service_boundary_errors"](path, alias), name
        assert rules["ownership_errors"]("PaperFeature", alias, path), name
    source = "class FileManager: Foundation.FileManager {}; let value = FileManager.default"
    assert rules["service_boundary_errors"](path, source)
    assert rules["ownership_errors"]("PaperFeature", source, path)
    source = "extension UserDefaults { static func make() -> UserDefaults { .standard } }"
    assert rules["service_boundary_errors"](path, source)
    assert rules["ownership_errors"]("PaperFeature", source, path)
    for kind in ("UserDefaults", "Foundation.UserDefaults"):
        sources = {
            path: "extension Probe { func run() { value = .standard } }",
            "Modules/PaperFeature/Sources/Memory.swift": (
                "struct UserDefaults { static let standard = UserDefaults() }; struct Probe { var "
                "value: "
            )
            + kind
            + " }",
        }
        index = rules["swift_syntax_index_sources"](sources)
        context = SwiftBindingTypes(index)
        unit = rules["compilation_type_context"](index, path)
        assert bool(
            rules["service_boundary_errors"](
                path, sources[path], context=unit, call_context=context
            )
        ) == kind.startswith("Foundation.")
        assert bool(
            rules["ownership_errors"](
                "PaperFeature", sources[path], path, properties=unit[0], call_context=context
            )
        ) == kind.startswith("Foundation.")
    for method in (
        "resourceValues",
        "setResourceValues",
        "getResourceValue",
        "setResourceValue",
        "resolvingSymlinksInPath",
        "checkResourceIsReachable",
    ):
        declaration = f"struct Preferences {{ func {method}(forKeys keys: [Int]) {{}} }}"
        source = (
            declaration
            + f"; func run(preferences: Preferences) {{ preferences.{method}(forKeys: []) }}"
        )
        assert rules["service_boundary_errors"](path, source) == [], method
        source += f"; func real(url: Foundation.URL) {{ url.{method}(forKeys: []) }}"
        assert rules["service_boundary_errors"](path, source), method


def manifest_lock_self_test(read_manifest) -> None:
    import fcntl
    import os
    import subprocess
    from threading import Event, Thread
    from types import SimpleNamespace
    from unittest.mock import patch
    import shutil

    root = Path(__file__).resolve().parents[1] / ".build/static-audit/module-manifest-lock"
    root.mkdir(parents=True, exist_ok=True)
    try:
        for name, inherited in (
            (".build/extended-automation.lock", False),
            (".build/compiler-cache/cache.lock", False),
            (".build/extended-automation.lock", True),
        ):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            called = Event()
            completed = Event()
            errors = []

            def evaluate():
                try:
                    assert read_manifest(root) == {"targets": []}
                except BaseException as error:
                    errors.append(error)
                finally:
                    completed.set()

            def compile_manifest(*args, **kwargs):
                called.set()
                return SimpleNamespace(returncode=0, stdout='{"targets": []}', stderr="")

            with (
                path.open("a") as owner,
                patch.dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1" if inherited else "0"),
                patch.object(subprocess, "run", side_effect=compile_manifest),
            ):
                fcntl.flock(owner, fcntl.LOCK_EX)
                worker = Thread(target=evaluate, daemon=True)
                worker.start()
                try:
                    assert called.wait(0.1) == inherited, (name, inherited)
                finally:
                    fcntl.flock(owner, fcntl.LOCK_UN)
                    assert completed.wait(5), (name, inherited)
                    worker.join()
                assert called.is_set() and errors == [], errors
    finally:
        shutil.rmtree(root)


def run_self_test(rules: dict) -> None:
    from swift_type_index_tests import (
        foundation_collection_self_test,
        resource_audit_execution_self_test,
    )

    foundation_collection_self_test(rules["service_boundary_errors"])
    resource_audit_execution_self_test(rules)
    module_coverage_binary_self_test()
    package_test_module_self_test()
    callable_network_api_self_test(rules)
    stream_network_self_test(rules)
    streaming_transport_self_test()
    local_resource_self_test(rules)
    subprocess_resource_self_test(rules)
    manifest_lock_self_test(rules["read_manifest"])
    resource_access_self_test(rules)
    module_types_self_test(rules)
    service_access_self_test(rules)
