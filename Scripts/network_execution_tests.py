"""Check network capability discovery and execution."""

from pathlib import Path
from unittest.mock import patch
from swift_source_index import swift_syntax_index_sources
from validation_test_areas import (
    reachable_smoke_calls,
)


def smoke_execution_self_test() -> None:
    sources = {
        "ReleaseNetworkSmoke.swift": (
            "struct ReleaseNetworkSmokeRunner { func run() { dependencies.productionSessionProbe()"
            " } }"
        ),
        "ReleaseNetworkSmokeModels.swift": (
            "struct ReleaseNetworkSmokeDependencies { var productionSessionProbe: () -> Void = Net"
            "workSmokeProductionSession.run }"
        ),
        "NetworkSmokeProductionSession.swift": (
            "enum NetworkSmokeProductionSession { static func run() { mine.fetchMyInfo() } }"
        ),
    }

    def reached(expressions):
        facts = swift_syntax_index_sources(expressions)
        original_is_file, original_read = Path.is_file, Path.read_text
        with (
            patch.object(
                Path, "is_file", lambda path: str(path) in expressions or original_is_file(path)
            ),
            patch.object(
                Path,
                "read_text",
                lambda path, *args, **kwargs: (
                    expressions[str(path)]
                    if str(path) in expressions
                    else original_read(path, *args, **kwargs)
                ),
            ),
        ):
            return {call["calledExpression"] for call in reachable_smoke_calls(facts)["network"]}

    assert "mine.fetchMyInfo" in reached(sources)
    for body in (
        "[1].forEach { _ in BODY }",
        "[1].map { _ in BODY }",
        "DispatchQueue.main.async { BODY }",
        "DispatchQueue.global().asyncAfter(deadline: .now()) { BODY }",
        "Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in BODY }",
        "Just(()).sink { _ in BODY }",
        "Empty<Int, Never>().sink { _ in BODY }",
        "subject.sink { _ in BODY }",
        "[Int]().forEach { _ in BODY }",
        "[].map { _ in BODY }",
        (
            "NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { _ in "
            "BODY }"
        ),
        "Array<Int>(repeating: 1, count: 0).forEach { _ in BODY }",
        "values.forEach { _ in BODY }",
        "DispatchQueue.concurrentPerform(iterations: 0) { _ in BODY }",
    ):
        callbacks = dict(sources)
        callbacks["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
            "dependencies.productionSessionProbe()",
            body.replace("BODY", "dependencies.productionSessionProbe()"),
        )
        executed = not body.startswith(
            (
                "Empty",
                "subject.",
                "[Int]()",
                "[].",
                "NotificationCenter.",
                "Array",
                "values.",
                "DispatchQueue.concurrentPerform",
                "DispatchQueue.global().asyncAfter",
                "Timer.scheduledTimer",
            )
        )
        assert ("mine.fetchMyInfo" in reached(callbacks)) == executed, body
        public_source = (
            (
                "import Foundation; import Combine; public struct CourseService { public func refr"
                "esh() { "
            )
            + body.replace("BODY", "Task { _ = try await URLSession.shared.data(from: url) }")
            + " } }"
        )
        from network_capability_rules import business_methods

        methods = business_methods(
            swift_syntax_index_sources(
                {"Modules/CourseFeature/Sources/CourseService.swift": public_source}
            )
        )
        assert {function["name"] for rows in methods.values() for _, function in rows} == {
            "refresh"
        }, body
    for method in ("async", "sync", "asyncAfter", "scheduledTimer", "sink", "map", "forEach"):
        for execution, expected in (
            ("", False),
            ("body()", True),
            ("DispatchQueue.main.async(execute: body)", True),
        ):
            custom = {
                "ReleaseNetworkSmoke.swift": "struct Scheduler { func "
                + method
                + "(_ body: @escaping () -> Void) { "
                + execution
                + (
                    " } }; struct ReleaseNetworkSmokeRunner { let scheduler: Scheduler; func run()"
                    " { scheduler."
                )
                + method
                + " { service.fetchCourses() } } }"
            }
            assert ("service.fetchCourses" in reached(custom)) == expected, (method, execution)
            custom_source = (
                custom["ReleaseNetworkSmoke.swift"]
                .replace("ReleaseNetworkSmokeRunner", "CourseService")
                .replace("func run()", "public func refresh()")
                .replace(
                    "service.fetchCourses()",
                    "Task { _ = try await URLSession.shared.data(from: url) }",
                )
            )
            methods = business_methods(
                swift_syntax_index_sources(
                    {"Modules/CourseFeature/Sources/CourseService.swift": custom_source}
                )
            )
            assert (
                any(
                    function["name"] == "refresh"
                    for rows in methods.values()
                    for _, function in rows
                )
                == expected
            ), (method, execution)
    platform_sources = {
        "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift": """
        struct ReleaseNetworkSmokeRunner {
            func run() {
                #if targetEnvironment(macCatalyst)
                service.catalystRead()
                #else
                helper()
                #endif
            }
            func helper() {
                #if targetEnvironment(macCatalyst)
                service.unreachableAcrossHosts()
                #else
                service.iosRead()
                #endif
            }
        }"""
    }
    platform_calls = reached(platform_sources)
    assert "service.iosRead" in platform_calls and "service.catalystRead" not in platform_calls
    from validation_test_areas import platform_smoke_calls

    catalyst_calls = platform_smoke_calls(
        swift_syntax_index_sources(platform_sources), "macCatalyst"
    )["network"]
    assert any(call["calledExpression"] == "service.catalystRead" for call in catalyst_calls)
    assert "service.unreachableAcrossHosts" not in platform_calls
    for body, expected in [
        ("", False),
        ("callback()", True),
        ("forward(callback)", True),
        ("Task { callback() }", True),
        ("let idle = { callback() }", False),
    ]:
        inline = {
            "ReleaseNetworkSmoke.swift": f"""struct ReleaseNetworkSmokeRunner {{
            func run() {{ register {{ service.fetch() }} }}
            func register(_ callback: () -> Void) {{ {body} }}
            func forward(_ callback: () -> Void) {{ callback() }}
        }}"""
        }
        assert ("service.fetch" in reached(inline)) == expected, body
    for invocation in (
        "probe { service.fetch() }",
        "Task { service.fetch() }",
        "Task.detached { service.fetch() }",
        "runInParallel([{ service.fetch() }])",
    ):
        assert "service.fetch" in reached(
            {
                "ReleaseNetworkSmoke.swift": (
                    f"struct ReleaseNetworkSmokeRunner {{ func run() {{ {invocation} }} }}"
                )
            }
        ), invocation
    for body in (
        (
            "withTaskCancellationHandler(operation: { service.live() }, onCancel: { Task { service"
            ".idle() } })"
        ),
        (
            "withTaskCancellationHandler { service.live() } onCancel: { Task.detached { service.id"
            "le() } }"
        ),
        (
            "let operation = { service.live() }; let cancellation = { Task { service.idle() } }; w"
            "ithTaskCancellationHandler(operation: operation, onCancel: cancellation)"
        ),
    ):
        calls = reached(
            {
                "ReleaseNetworkSmoke.swift": (
                    f"struct ReleaseNetworkSmokeRunner {{ func run() async {{ {body} }} }}"
                )
            }
        )
        assert "service.live" in calls and "service.idle" not in calls, (body, calls)
    task_local = {
        "ReleaseNetworkSmoke.swift": """enum Trace { @TaskLocal static var current: (() -> Void)? }
        struct ReleaseNetworkSmokeRunner {
            func run() { invoke { service.fetch() } }
            func invoke(_ operation: () -> Void, count: Int = 0) {
                Trace.$current.withValue({ service.idle() }) { operation() }
            }
        }"""
    }
    calls = reached(task_local)
    assert "service.fetch" in calls and "service.idle" not in calls, calls
    stored = {
        "ReleaseNetworkSmoke.swift": """struct Operations { var callback: () -> Void }
        struct ReleaseNetworkSmokeRunner {
            func run() { let operations: Operations = make(); operations.callback() }
            func make() -> Operations { Operations(callback: { service.live() }) }
            func unused() -> Operations { Operations(callback: { service.idle() }) }
        }"""
    }
    calls = reached(stored)
    assert "service.live" in calls and "service.idle" not in calls, calls
    stored["ReleaseNetworkSmoke.swift"] = stored["ReleaseNetworkSmoke.swift"].replace(
        "operations.callback()", ""
    )
    assert "service.live" not in reached(stored)
    protocol = {
        "Modules/Ports/Sources/Restoring.swift": "public protocol Restoring { func restore() }",
        "ReleaseNetworkSmoke.swift": """import Ports
            struct Adapter: Restoring {
                let operation: () -> Void
                init(operation: @escaping () -> Void) { self.operation = operation }
                func restore() { operation() }
            }
            struct ReleaseNetworkSmokeRunner {
                let restorer: any Restoring
                func run() { build(); restorer.restore() }
                func build() { _ = Adapter { service.fetch() } }
            }""",
    }
    assert "service.fetch" in reached(protocol)
    protocol["ReleaseNetworkSmoke.swift"] = protocol["ReleaseNetworkSmoke.swift"].replace(
        "build(); restorer.restore()", "restorer.restore()"
    )
    assert "service.fetch" not in reached(protocol)
    for literal in ("1000", "1_000", "0x3e8", "0b1111101000", "0o1750", "-1_000", "+1000"):
        numeric = {
            "ReleaseNetworkSmoke.swift": f"""struct ReleaseNetworkSmokeRunner {{
            func run() {{ helper(id: {literal}) }}
            func helper(id: Int) {{ service.read() }}
            func helper(id: String) {{ service.write() }}
        }}"""
        }
        calls = reached(numeric)
        assert "service.read" in calls and "service.write" not in calls, (literal, calls)
    numeric["ReleaseNetworkSmoke.swift"] = numeric["ReleaseNetworkSmoke.swift"].replace(
        "+1000", "unknown"
    )
    assert not {"service.read", "service.write"} & reached(numeric)
    for literal in ("1.0", "1_000.5", "1e3", "0x1.fp2", "-1.5"):
        numeric["ReleaseNetworkSmoke.swift"] = f"""struct ReleaseNetworkSmokeRunner {{
            func run() {{ helper(id: {literal}) }}
            func helper(id: Double) {{ service.read() }}
            func helper(id: String) {{ service.write() }}
        }}"""
        calls = reached(numeric)
        assert "service.read" in calls and "service.write" not in calls, (literal, calls)
    for parameters, argument in (
        (("flag: Bool", "text: String"), "flag: true"),
        (("value: Int?", "value: String?"), "value: 42"),
    ):
        overloaded = {
            "ReleaseNetworkSmoke.swift": f"""struct ReleaseNetworkSmokeRunner {{
            func run() {{ helper({argument}) }}
            func helper({parameters[0]}) {{ service.read() }}
            func helper({parameters[1]}) {{ service.write() }}
        }}"""
        }
        calls = reached(overloaded)
        assert "service.read" in calls and "service.write" not in calls, (parameters, calls)
    scoped = {
        "ReleaseNetworkSmoke.swift": """struct ReleaseNetworkSmokeRunner {
        func run() { helper(flag: true) }
        func helper(flag: Bool) { service.read() }
        func unused() { func helper(flag: Bool) { service.write() }; helper(flag: true) }
    }"""
    }
    assert "service.read" in reached(scoped) and "service.write" not in reached(scoped)
    scoped["ReleaseNetworkSmoke.swift"] = scoped["ReleaseNetworkSmoke.swift"].replace(
        "func run() { helper(flag: true) }",
        "func run() { func helper(flag: Bool) { service.local() }; helper(flag: true) }",
    )
    assert "service.local" in reached(scoped) and "service.read" not in reached(scoped)
    split = dict(sources)
    split["NetworkSmokeExtra.swift"] = split.pop("NetworkSmokeProductionSession.swift")
    assert reached(split) == reached(sources)
    split["BIT101Watch/NetworkSmokeExtra.swift"] = split["NetworkSmokeExtra.swift"].replace(
        "mine.fetchMyInfo()", "mine.fetchWatchInfo()"
    )
    assert "mine.fetchWatchInfo" not in reached(split)
    writes = {
        "ReleaseNetworkSmoke.swift": (
            "struct ReleaseNetworkSmokeRunner { func run() { CommunityWriteSmoke.run() } }"
        ),
        "CommunityWriteSmoke.swift": (
            "enum CommunityWriteSmoke { static func run() { WriteProbes.send() } }"
        ),
        "NetworkSmokeExtra.swift": (
            "enum WriteProbes { static func send() { service.createPaper() } }"
        ),
    }
    write_facts = swift_syntax_index_sources(writes)
    assert "service.createPaper" in {
        call["calledExpression"] for call in reachable_smoke_calls(write_facts)["community-writes"]
    }
    assert "service.createPaper" not in {
        call["calledExpression"] for call in reachable_smoke_calls(write_facts)["network"]
    }
    inactive = dict(sources)
    inactive["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
        "dependencies.productionSessionProbe()",
        "\n#if DEBUG\ndependencies.productionSessionProbe()\n#endif\n",
    )
    assert "mine.fetchMyInfo" not in reached(inactive)
    unused_reference = dict(sources)
    unused_reference["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
        "dependencies.productionSessionProbe()", "let unused = dependencies.productionSessionProbe"
    )
    assert "mine.fetchMyInfo" not in reached(unused_reference)
    for statement in ("if", "while"):
        for condition, expected in [
            ("false", False),
            ("!true", False),
            ("true", True),
            ("!false", True),
            ("false && true", False),
            ("true || false", True),
            ("!(true || false)", False),
            ("(true || false) && false", False),
            ("condition && false", False),
            ("condition || true", True),
        ]:
            branch = dict(sources)
            branch["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
                "dependencies.productionSessionProbe()",
                f"{statement} {condition} {{ dependencies.productionSessionProbe() }}",
            )
            assert ("mine.fetchMyInfo" in reached(branch)) == expected, (statement, condition)
    for prefix, sequence, expected in [
        ("", "0..<0", False),
        ("", "0..<1", True),
        ("", "-1..<(-1)", False),
        ("", "1...1", True),
        ("", "[]", False),
        ("", "[Int]()", False),
        ("", "Array<Int>()", False),
        ("", "[1, 2].prefix(0)", False),
        ("", "[1, 2].prefix(1)", True),
        ("", "[1].dropFirst()", False),
        ("", "[1] where false", False),
        ("", "[1] where true", True),
        ("let size = 0; ", "0..<size", False),
        ("let size = 1; ", "0..<size", True),
        ("let size = 0; ", "((0)..<(size * (1 + 1)))", False),
        ("struct Array<T> {}; ", "Array<Int>()", True),
        ("let items: [Int] = []; ", "items", False),
        ("var items: [Int] = []; ", "items", True),
        ("let items: [Int] = [1]; ", "items", True),
        ("let items: Custom = []; ", "items", True),
        ("let items: [Int] = []; let alias = items; ", "alias", False),
    ]:
        loop = dict(sources)
        loop["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
            "dependencies.productionSessionProbe()",
            f"{prefix}for _ in {sequence} {{ dependencies.productionSessionProbe() }}",
        )
        assert ("mine.fetchMyInfo" in reached(loop)) == expected, sequence
    disabled = dict(sources)
    disabled["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
        "dependencies.productionSessionProbe()",
        "let enabled = false; if enabled { dependencies.productionSessionProbe() }",
    )
    assert "mine.fetchMyInfo" not in reached(disabled)
    disabled["ReleaseNetworkSmoke.swift"] = disabled["ReleaseNetworkSmoke.swift"].replace(
        "let enabled", "var enabled"
    )
    assert "mine.fetchMyInfo" in reached(disabled)
    disabled["ReleaseNetworkSmoke.swift"] = (
        disabled["ReleaseNetworkSmoke.swift"]
        .replace("var enabled", "let enabled")
        .replace("if enabled", "while enabled")
    )
    assert "mine.fetchMyInfo" not in reached(disabled)
    from network_capability_rules import call_can_execute, execution_index

    custom_sources = [
        (
            "struct Int: ExpressibleByIntegerLiteral, Equatable { init(integerLiteral: Swift.Int) "
            "{}; static func ==(lhs: Int, rhs: Int) -> Bool { true } }"
        ),
        (
            "struct Int: ExpressibleByIntegerLiteral, Equatable { let value: Swift.Int; init(integ"
            "erLiteral: Swift.Int) { value = 0 } }"
        ),
        (
            "typealias Int = Number; struct Number: ExpressibleByIntegerLiteral, Equatable { let v"
            "alue: Swift.Int; init(integerLiteral: Swift.Int) { value = 0 } }"
        ),
        "func ~= (pattern: Swift.Int, value: Swift.Int) -> Swift.Bool { true }",
        "func == (lhs: Swift.Int, rhs: Swift.Int) -> Swift.Bool { true }",
        "func ..< (lhs: Swift.Int, rhs: Swift.Int) -> [Swift.Int] { [1] }",
    ]
    for declarations in custom_sources:
        body = (
            "for _ in 2..<1 { service.fetch() }"
            if "func ..<" in declarations
            else (
                "switch 1 { case 2: service.fetch(); default: break }"
                if "func ~=" in declarations
                else "let value: Int = 1; if value == 2 { service.fetch() }"
            )
        )
        direct = swift_syntax_index_sources(
            {"custom": declarations + "\nfunc run() { " + body + " }"}
        )["custom"]
        call = next(
            row for row in direct["invocations"] if row["calledExpression"] == "service.fetch"
        )
        assert call_can_execute(direct, call), declarations
        root = "/fixture/Modules"
        consumer = root + "/Consumer/Sources/Run.swift"
        imported = execution_index(
            swift_syntax_index_sources(
                {
                    root + "/Symbols/Sources/Symbols.swift": declarations,
                    root + "/Forward/Sources/Imports.swift": "import Symbols",
                    consumer: "import Forward\nfunc run() { " + body + " }",
                }
            )
        )
        facts = imported[consumer]
        call = next(
            row for row in facts["invocations"] if row["calledExpression"] == "service.fetch"
        )
        assert call_can_execute(facts, call), declarations
    expressions = [
        ("false && service.fetch()", False),
        ("true && service.fetch()", True),
        ("true || service.fetch()", False),
        ("false || service.fetch()", True),
        ("false ? service.fetch() : true", False),
        ("true ? service.fetch() : false", True),
        ("true ? false : service.fetch()", False),
        ("false ? true : service.fetch()", True),
        ("runtime && service.fetch()", True),
        ("runtime ? service.fetch() : false", True),
        ("false && runtime || service.fetch()", True),
        ("true || runtime && service.fetch()", False),
        ("(false || false) && service.fetch()", False),
        ("false ? true : false && service.fetch()", False),
        ("false && service.fetch() ? true : false", False),
        ("true ? false : runtime ? service.fetch() : true", False),
        ("enabled && service.fetch()", False),
        ("mutable && service.fetch()", True),
        ("{ let enabled = true; return enabled && service.fetch() }()", True),
        ("service.fetch() && false", True),
        ("service.fetch() || true", True),
    ]
    expression_index = swift_syntax_index_sources(
        {
            body: "func run(runtime: Bool) { let enabled = false; var mutable = false; let _ = "
            + body
            + " }"
            for body, _ in expressions
        }
    )
    for body, expected in expressions:
        facts = expression_index[body]
        call = next(
            row for row in facts["invocations"] if row["calledExpression"] == "service.fetch"
        )
        assert call_can_execute(facts, call) == expected, body
    switches = [
        ("switch false { case true: service.fetch(); default: break }", False),
        ("switch false { case false: service.fetch(); default: break }", True),
        ("switch true { case true: break; default: service.fetch() }", False),
        ("switch 2 { case 1, 3: service.fetch(); default: break }", False),
        ("switch 2 { case 1, 2: service.fetch(); default: break }", True),
        (
            "switch 9007199254740992.0 { case 9007199254740993: service.fetch(); default: break }",
            True,
        ),
        ('switch "é" { case "é": service.fetch(); default: break }', True),
        ("let flag = false; switch flag { case true: service.fetch(); default: break }", False),
        ("var flag = false; switch flag { case true: service.fetch(); default: break }", True),
        ("switch 2 { case 2 where false: service.fetch(); default: break }", False),
        ("switch 2 { case 2 where condition: service.fetch(); default: break }", True),
        ("switch 2 { case let value where value == 2: service.fetch(); default: break }", True),
        ("switch value { case .active where false: service.fetch(); default: break }", False),
        ("switch 2 { case let value where false: service.fetch(); default: break }", False),
        ("switch true { case false: fallthrough; default: service.fetch() }", True),
        ("switch true { case true: fallthrough; case false: service.fetch() }", True),
        (
            (
                "switch true { case true: if false { fallthrough }; break; case false: service.fet"
                "ch() }"
            ),
            False,
        ),
        (
            (
                "switch true { case true: if condition { fallthrough }; break; case false: service"
                ".fetch() }"
            ),
            True,
        ),
        (
            (
                "switch false { case true: func helper() { service.fetch() }; helper(); default: b"
                "reak }"
            ),
            False,
        ),
    ]
    switch_index = swift_syntax_index_sources(
        {body: f"func run(condition: Bool) {{ {body} }}" for body, _ in switches}
    )
    for body, expected in switches:
        facts = switch_index[body]
        call = next(
            row for row in facts["invocations"] if row["calledExpression"] == "service.fetch"
        )
        assert call_can_execute(facts, call) == expected, body
    dead_switch = dict(sources)
    dead_switch["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
        "dependencies.productionSessionProbe()",
        "switch false { case true: dependencies.productionSessionProbe(); default: break }",
    )
    assert "mine.fetchMyInfo" not in reached(dead_switch)
    comparisons = [
        ("true == false", False),
        ("false != false", False),
        ("true != false", True),
        ("(true == false) || false", False),
        ("enabled == false", True),
        ("1 == 2", False),
        ("1 != 1", False),
        ("-1 >= 0", False),
        ("1_000 < 1", False),
        ("1.5 > 2", False),
        ("0x10 == 16", True),
        ("9007199254740993 == 9007199254740992.0", True),
        ('"a" == "b"', False),
        ('"a" != "a"', False),
        ("1 + 1 == 3", False),
        ("3 % 2 == 0", False),
        ("2 * (3 - 1) == 4", True),
        ("5 / 2 == 2", True),
        ("-5 / 2 == -2", True),
        ("5 / -2 == -2", True),
        ("-9 % 4 == -1", True),
        ("9 % -4 == 1", True),
        ("-9 % -4 == 3", False),
        ("1 / 2 == 0.5", True),
        ("(1 / 2) + 0.5 == 1.0", True),
        ("2.5 * 2 == 4", False),
        ('"e" + "́" == "é"', True),
        ("1 / 0 == 0", True),
        ("9223372036854775807 + 1 == 0", True),
        ('"true" == "True"', False),
        ('"!" == " not "', False),
        ('"&&" == " and "', False),
        ('"é" != "é"', False),
        (r'"row.\(enabled)" == "fixed"', True),
        ("1 == enabled", True),
        (r'"\01" != "\001"', True),
        (r'"\01" == "\001"', False),
        (r'"\u{e9}" == "é"', True),
        (r'"row.\\(enabled)" == "fixed"', False),
        (r'"\u{0}1" == "\01"', True),
    ]
    comparison_sources = {
        condition: f"func run(enabled: Bool) {{ if {condition} {{ service.fetch() }} }}"
        for condition, _ in comparisons
    }
    comparison_index = swift_syntax_index_sources(comparison_sources)
    for condition, expected in comparisons:
        facts = comparison_index[condition]
        call = next(
            row for row in facts["invocations"] if row["calledExpression"] == "service.fetch"
        )
        assert call_can_execute(facts, call) == expected, condition
        branch = dict(sources)
        branch["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
            "dependencies.productionSessionProbe()",
            f"if {condition} {{ dependencies.productionSessionProbe() }}",
        )
        assert ("mine.fetchMyInfo" in reached(branch)) == expected, condition
    initializers = [
        ("let value = 1; let alias = value; if alias == 2", False),
        ("let value: Int = 1; let flag = value == 2; if flag", False),
        ('let value = "first"; let alias = value; if alias == "second"', False),
        ("var value = 1; value = 2; if value == 2", True),
        ("let value = input; if value == 2", True),
        ("let value = value; if value == 2", True),
        ("let value: Custom = 1; if value == 2", True),
        ("let value: Double = 9007199254740993; if value == 9007199254740992", True),
        ("let value = 1 + 1; if value == 3", False),
        ("let value = -9 % 4; if value == 1", False),
        ("let value: Double = 1 / 2; if value == 0.5", True),
        ("let value: Double = 1 / 2; if value == 0", False),
        ("let value: Float = 16777217; if value == 16777216", True),
    ]
    initializer_index = swift_syntax_index_sources(
        {
            prefix: f"func run(input: Int) {{ {prefix} {{ service.fetch() }} }}"
            for prefix, _ in initializers
        }
    )
    for prefix, expected in initializers:
        facts = initializer_index[prefix]
        call = next(
            row for row in facts["invocations"] if row["calledExpression"] == "service.fetch"
        )
        assert call_can_execute(facts, call) == expected, prefix
    for outer in ("true", "false"):
        for body, expected in [
            ("func run(enabled: Bool) { if enabled { service.fetch() } }", True),
            (
                "func run(enabled: Bool) { let enabled = false; if enabled { service.fetch() } }",
                False,
            ),
            (
                "func run(enabled: Bool) { let enabled = true; if enabled { service.fetch() } }",
                True,
            ),
            (
                (
                    "func run() { let closure = { (enabled: Bool) in if enabled { servic"
                    "e.fetch() } } }"
                ),
                True,
            ),
            ("func run() { let closure = { enabled in if enabled { service.fetch() } } }", True),
            ("func run() { let closure = { (enabled) in if enabled { service.fetch() } } }", True),
            ("func run() { if enabled { service.fetch() } }", outer == "true"),
        ]:
            facts = swift_syntax_index_sources(
                {"shadowing": f"struct Runner {{ let enabled = {outer}; {body} }}"}
            )["shadowing"]
            call = next(
                call for call in facts["invocations"] if call["calledExpression"] == "service.fetch"
            )
            assert call_can_execute(facts, call) == expected, (outer, body)
    patterns = [
        ("for flag in [true] { if flag { service.fetch() } }", True),
        ("for (flag, _) in [(true, 1)] { if flag { service.fetch() } }", True),
        ("switch true { case let flag: if flag { service.fetch() } }", True),
        (
            "switch input { case .some(let flag): if flag { service.fetch() }; default: break }",
            True,
        ),
        ("if case .some(let flag) = input { if flag { service.fetch() } }", True),
        ("while case .some(let flag) = input { if flag { service.fetch() } }", True),
        ("guard case .some(let flag) = input else { return }; if flag { service.fetch() }", True),
        ("let (flag, _) = (true, 1); if flag { service.fetch() }", True),
        ("for flag in [true] {}; if flag { service.fetch() }", False),
        ("if case .some(let flag) = input {} else { if flag { service.fetch() } }", False),
        (
            "switch input { case .some(let flag): break; default: if flag { service.fetch() } }",
            False,
        ),
    ]
    pattern_index = swift_syntax_index_sources(
        {body: "func run() { let flag = false; " + body + " }" for body, _ in patterns}
    )
    for body, expected in patterns:
        facts = pattern_index[body]
        call = next(
            row for row in facts["invocations"] if row["calledExpression"] == "service.fetch"
        )
        assert call_can_execute(facts, call) == expected, body
    for statement in ("return", "throw URLError(.cancelled)"):
        terminated = dict(sources)
        terminated["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
            "dependencies.productionSessionProbe()",
            statement + "; dependencies.productionSessionProbe()",
        )
        assert "mine.fetchMyInfo" not in reached(terminated), statement
    conditional = dict(sources)
    conditional["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
        "dependencies.productionSessionProbe()",
        "if condition { return }; dependencies.productionSessionProbe()",
    )
    assert "mine.fetchMyInfo" in reached(conditional)
    successors = [
        ("guard false else { return }", False),
        ("guard true else { return }", True),
        ("guard condition else { return }", True),
        ("if true { return }", False),
        ("if false { return }", True),
        ("if condition { return } else { throw URLError(.cancelled) }", False),
        ("if condition { return } else if true { return }", False),
        ("if condition { return } else if other { return }", True),
        ("if true { if true { return } }", False),
        ("if true { let closure = { return } }", True),
        ("while true { return }", False),
        ("while false { return }", True),
        ("while condition { return }", True),
        ("while true { break }", True),
        ("while true { continue }", False),
        ("while true {}", False),
        ("while true { if false { break } }", False),
        ("while true { if condition { break } }", True),
        ("while true { while true { break } }", False),
        ("outer: while true { while true { break outer } }", True),
        ("outer: while true { switch value { default: break outer } }", True),
        ("outer: while condition { while true { continue outer } }", True),
        ("repeat { return } while false", False),
        ("repeat { continue } while false", True),
        ("repeat { break } while true", True),
        ("repeat {} while true", False),
        ("do { return } catch { return }", False),
        ("do { return } catch { consume() }", True),
        ("do { throw error } catch { return }", False),
        ("do { consume() } catch { return }", True),
        ("switch value { case .a: return; case .b: return }", False),
        ("switch value { case .a: return; default: break }", True),
        ("switch value { case .a: fallthrough; default: return }", False),
        ("switch value { case .a: fallthrough; default: consume() }", True),
        ("switch false { case true: break; case false: return }", False),
        ("switch false { case true: return; case false: break }", True),
        ("switch true { case true: fallthrough; case false: return }", False),
        ("switch true { case true: fallthrough; case false: fallthrough; default: return }", False),
        ("switch true { case true: if condition { fallthrough }; return; default: return }", False),
        ("while true { switch value { case .a: break; default: break } }", False),
    ]
    fixtures = {
        prefix: "func run() { " + prefix + "; service.fetch() }" for prefix, _ in successors
    }
    successor_index = swift_syntax_index_sources(fixtures)
    for prefix, expected in successors:
        facts = successor_index[prefix]
        call = next(
            row for row in facts["invocations"] if row["calledExpression"] == "service.fetch"
        )
        assert call_can_execute(facts, call) == expected, prefix
    for prefix in (
        "guard false else { return }",
        "if true { return }",
        "while true { return }",
        "repeat { return } while false",
        "do { return } catch { return }",
        "switch value { case .a: return; default: return }",
    ):
        terminated = dict(sources)
        terminated["ReleaseNetworkSmoke.swift"] = sources["ReleaseNetworkSmoke.swift"].replace(
            "dependencies.productionSessionProbe()",
            prefix + "; dependencies.productionSessionProbe()",
        )
        assert "mine.fetchMyInfo" not in reached(terminated), prefix
    hoisted = dict(sources)
    hoisted["ReleaseNetworkSmoke.swift"] = (
        "struct ReleaseNetworkSmokeRunner { func run() { helper(); return; func helper() { dep"
        "endencies.productionSessionProbe() } } }"
    )
    assert "mine.fetchMyInfo" in reached(hoisted)
    hoisted["ReleaseNetworkSmoke.swift"] = hoisted["ReleaseNetworkSmoke.swift"].replace(
        "helper(); return;", "helper(); if true { return };"
    )
    assert "mine.fetchMyInfo" in reached(hoisted)
