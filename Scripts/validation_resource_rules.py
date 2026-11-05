"""Inspect validation source coverage."""

from pathlib import Path
from swift_source_index import swift_syntax_index_sources

ROOT = Path(__file__).resolve().parents[1]


def fixture_resource_findings(path: Path, facts: dict) -> list[str]:
    if not any(
        path.is_relative_to(ROOT / root)
        for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")
    ):
        return []
    from swift_type_index import SwiftTypeIndex, receiver_resolver
    from swift_source_index import matching_functions
    from network_capability_rules import matching_api_calls

    index = {str(path): facts}
    types = SwiftTypeIndex(index)
    resolve = receiver_resolver(index, types=types)

    def system_name(name, reference):
        return (
            types.terminal_name(str(path), name, reference["scope"])
            .removeprefix("Foundation.")
            .removeprefix("Swift.")
        )

    random_calls = set()
    for call in facts.get("invocations", []):
        expression = call["calledExpression"].removesuffix(".init")
        kind = system_name(expression, call)
        if kind in {"UUID", "Date"} and (kind == "UUID" or not call.get("arguments")):
            random_calls.add(call["start"])
        receiver, _, method = expression.rpartition(".")
        if method == "random" and system_name(receiver, call) in {
            "Int",
            "Int8",
            "Int16",
            "Int32",
            "Int64",
            "UInt",
            "UInt8",
            "UInt16",
            "UInt32",
            "UInt64",
            "Float",
            "Double",
            "Bool",
        }:
            random_calls.add(call["start"])
        if expression in {
            "Darwin.arc4random",
            "Darwin.arc4random_uniform",
            "CoreFoundation.CFAbsoluteTimeGetCurrent",
        }:
            random_calls.add(call["start"])
    for member in facts.get("members", []):
        receiver, _, name = member["value"].rpartition(".")
        if (
            name == "now"
            and system_name(receiver, member) == "Date"
            or name in {"globallyUniqueString", "systemUptime"}
            and receiver.endswith(".processInfo")
            and system_name(receiver.removesuffix(".processInfo"), member) == "ProcessInfo"
        ):
            random_calls.add(member["start"])
    if not random_calls:
        return []
    bindings = facts.get("bindings", [])

    def random_value(bounds, reference, seen=frozenset()):
        if any(bounds[0] <= position < bounds[1] for position in random_calls):
            return True
        for identifier in facts.get("scopedIdentifiers", []):
            if (
                not identifier.get("isExpressionReference")
                or not bounds[0] <= identifier["start"] < bounds[1]
            ):
                continue
            candidates = [
                binding
                for binding in bindings
                if binding.get("bindingName") == identifier["value"]
                and binding["start"] < identifier["start"]
                and binding["start"] not in seen
                and identifier["scope"][: len(binding["scope"])] == binding["scope"]
                and identifier["lexicalScope"][: len(binding["lexicalScope"])]
                == binding["lexicalScope"]
            ]
            if not candidates:
                continue
            binding = max(
                candidates,
                key=lambda item: (len(item["scope"]), len(item["lexicalScope"]), item["start"]),
            )
            if random_value(
                (binding["start"], binding["start"] + len(binding["value"].encode())),
                binding,
                seen | {binding["start"]},
            ):
                return True
        for call in facts.get("invocations", []):
            if not bounds[0] <= call["start"] < bounds[1]:
                continue
            receiver, _, name = call["calledExpression"].rpartition(".")
            candidates = (
                matching_functions(facts, name, call)
                if not receiver
                else [
                    function
                    for function in facts.get("functionRanges", [])
                    if ".".join(types.function_scope(str(path), function["scope"]))
                    == resolve(dict(call, path=str(path)))
                ]
            )
            for _, function in matching_api_calls(
                index,
                [(str(path), function) for function in candidates],
                dict(call, path=str(path)),
                types=types,
                conservative=True,
            ):
                if function["start"] in seen:
                    continue
                for returned in facts.get("functionReturns", []):
                    if (
                        function["bodyStart"] <= returned["start"] < function["end"]
                        and returned["name"] == function["name"]
                        and random_value(
                            (
                                returned["start"],
                                returned["start"] + len(returned["value"].encode()),
                            ),
                            returned,
                            seen | {function["start"]},
                        )
                    ):
                        return True
        return False

    errors = []
    for call in facts.get("invocations", []):
        method = call["calledExpression"].removesuffix(".init").split(".")[-1]
        labels = {
            "createDirectory": {"at", "atPath"},
            "writeData": {"to"},
            "ScoreCacheDiskRepository": {"storageRoot"},
            "UserDefaults": {"suiteName"},
            "URL": {"fileURLWithPath"},
        }.get(method, set())
        if any(
            label in labels and random_value(bounds, call)
            for label, bounds in zip(call.get("argumentLabels", []), call.get("argumentRanges", []))
        ):
            line = facts["source"].encode()[: call["start"]].count(b"\n") + 1
            errors.append(f"{path.relative_to(ROOT)}:{line}: 磁盘测试资源与偏好域使用固定用途名称")
    return errors


def fixture_resource_self_test() -> None:
    path = ROOT / "BIT101-iOSTests/Fixture.swift"
    for statement, expected in (
        (
            (
                'let root = files.temporaryDirectoryURL.appending(path: "quota-\\(UUID().uuidStrin'
                'g)"); try files.createDirectory(at: root)'
            ),
            1,
        ),
        (
            (
                'let suffix = Foundation.UUID().uuidString; let domain = "suite.\\(suffix)"; let a'
                "lias = domain; _ = UserDefaults(suiteName: alias)"
            ),
            1,
        ),
        (r'let root = URL(fileURLWithPath: "/test/\(UUID().uuidString)")', 1),
        (
            (
                'let suffix = Date().timeIntervalSince1970; _ = UserDefaults(suiteName: "suite.\\('
                'suffix)")'
            ),
            1,
        ),
        (r'let root = URL(fileURLWithPath: "/test/\(Date.now.timeIntervalSince1970)")', 1),
        (
            (
                "let suffix = ProcessInfo.processInfo.globallyUniqueString; let alias = suffix; _ "
                "= UserDefaults(suiteName: alias)"
            ),
            1,
        ),
        (
            (
                'let suffix = Int.random(in: 1...100); let root = URL(fileURLWithPath: "/test/\\(s'
                'uffix)")'
            ),
            1,
        ),
        (
            (
                'let suffix = Swift.Double.random(in: 0...1); _ = UserDefaults(suiteName: "suite.'
                '\\(suffix)")'
            ),
            1,
        ),
        (
            (
                "let suffix = Date(timeIntervalSince1970: 42).timeIntervalSince1970; _ = UserDefau"
                'lts(suiteName: "suite.\\(suffix)")'
            ),
            0,
        ),
        ("struct Date {}; _ = UserDefaults(suiteName: String(describing: Date()))", 0),
        (
            (
                "typealias Identifier = Foundation.UUID; _ = UserDefaults(suiteName: Identifier()."
                "uuidString)"
            ),
            1,
        ),
        (
            (
                'typealias Clock = Date; _ = UserDefaults(suiteName: "suite.\\(Clock.now.timeInter'
                'valSince1970)")'
            ),
            1,
        ),
        (
            (
                'typealias Number = Swift.Int; _ = UserDefaults(suiteName: "suite.\\(Number.random'
                '(in: 1...100))")'
            ),
            1,
        ),
        (
            (
                'struct Int { static func random(in range: ClosedRange<Int>) -> String { "fixed" }'
                " }; _ = UserDefaults(suiteName: Int.random(in: 1...100))"
            ),
            0,
        ),
        (
            (
                'let root = files.temporaryDirectoryURL.appending(path: "quota-\\(UUID().uuidStrin'
                'g)"); _ = ScoreCacheDiskRepository(files: files, storageRoot: root)'
            ),
            1,
        ),
        ('let identity = UUID(); let domain = "fixed"; _ = UserDefaults(suiteName: domain)', 0),
        (
            (
                'let suffix = UUID().uuidString; if enabled { let suffix = "fixed"; _ = UserDefaul'
                'ts(suiteName: "suite.\\(suffix)") }'
            ),
            0,
        ),
        (
            (
                'struct UUID { var uuidString: String { "fixed" } }; _ = UserDefaults(suiteName: U'
                "UID().uuidString)"
            ),
            0,
        ),
        ('_ = UserDefaults(suiteName: "UUID().uuidString") // UUID()', 0),
        ("func name() -> String { UUID().uuidString }; _ = UserDefaults(suiteName: name())", 1),
        (
            (
                "func name() -> String { let value = UUID().uuidString; return value }; let domain"
                " = name(); _ = UserDefaults(suiteName: domain)"
            ),
            1,
        ),
        (
            (
                'func name() -> String { _ = UUID(); return "fixed" }; _ = UserDefaults(suiteName:'
                " name())"
            ),
            0,
        ),
        (
            (
                "func name() -> String { UUID().uuidString }; func alias() -> String { name() }; _"
                " = UserDefaults(suiteName: alias())"
            ),
            1,
        ),
        ("func name() -> String { name() }; _ = UserDefaults(suiteName: name())", 0),
        (
            (
                "func name(_ value: Int) -> String { UUID().uuidString }; func name(_ value: Strin"
                'g) -> String { "fixed" }; _ = UserDefaults(suiteName: name("fixed"))'
            ),
            0,
        ),
    ):
        source = "import Foundation; func fixture() { " + statement + "\n}"
        facts = swift_syntax_index_sources({str(path): source})[str(path)]
        assert len(fixture_resource_findings(path, facts)) == expected, statement
