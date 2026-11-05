"""Production code, script and workflow quality rules."""

from __future__ import annotations

from pathlib import Path
from functools import cache
from validation_inputs import native_project_targets, repository_script_paths
import ast
import re
import stat
import sys
from swift_source_index import (
    declaration_conformances,
    expected_argument_types,
    scope_contains_type,
    swift_syntax_index,
    swift_code,
)
from contextlib import contextmanager
from validation_artifacts import static_audit_lock as workflow_audit_lock
from ui_source_facts import explanatory_text_report, view_transport_findings, view_helper_ranges

from source_fact_queries import relative, owner_scopes, owner_has_call, ast_has_identifier
from school_request_rules import automatic_school_fetch_findings

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_ROOTS = tuple(
    ROOT / name
    for name in (
        "Modules",
        "BIT101-iOS",
        "BIT101ScheduleWidgets",
        "BIT101Watch",
        "BIT101WatchWidgets",
    )
)
SOURCE_ROOTS = (
    ROOT / "Modules",
    ROOT / "BIT101-iOS",
    ROOT / "BIT101-iOSTests",
    ROOT / "BIT101-iOSUITests",
    ROOT / "ModuleTests",
    ROOT / "BIT101ScheduleWidgets",
    ROOT / "BIT101Watch",
    ROOT / "BIT101WatchWidgets",
)
SCRIPT_ROOT = ROOT / "Scripts"
REPORT_PATH = ROOT / ".build/code-quality-report.txt"

DIRECT_STDOUT_LOG = re.compile(r"\b(?:print|debugPrint|NSLog)\s*\(")

DIRECT_VIEW_REQUEST = re.compile(r"\bURLRequest\s*\(")

STDOUT_EXCEPTIONS = {"BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"}


@contextmanager
def static_audit_lock():
    with workflow_audit_lock(ROOT):
        yield


def ast_has_view_request(
    facts: dict,
    type_index: dict | None = None,
    context: dict[str, dict] | None = None,
    *,
    resolver=None,
) -> bool:
    return ast_has_view_construction(
        facts, {"URLRequest", "Foundation.URLRequest"}, type_index, context, resolver=resolver
    )


def ast_has_view_construction(
    facts: dict,
    constructed_types: set[str],
    type_index: dict | None = None,
    context: dict[str, dict] | None = None,
    *,
    resolver=None,
) -> bool:
    from swift_type_index import SwiftTypeIndex, SwiftBindingTypes

    if context is None:
        context, resolver = {"source": facts}, None
    origin = next((path for path, entry in context.items() if entry is facts), "source")
    resolver = resolver or SwiftTypeIndex(
        {
            path: dict(
                entry,
                typeAliases=[
                    alias for alias in entry.get("typeAliases", []) if not alias.get("lexicalScope")
                ],
            )
            for path, entry in context.items()
        }
    )
    call_context = getattr(resolver, "_view_bindings", None)
    if call_context is None or call_context.index is not context:
        call_context = SwiftBindingTypes(context, resolver)
        resolver._view_bindings = call_context
    conformances = declaration_conformances({"source": facts}) if type_index is None else type_index
    view_types = {
        owner
        for owner, bases in conformances.items()
        if any(
            base.rsplit(".", 1)[-1] in {"View", "ViewModifier", "App", "Scene"} for base in bases
        )
    }

    def canonical_type(value, reference, reference_file=origin):
        seen = set()
        while (reference_file, value) not in seen:
            seen.add((reference_file, value))
            value = re.sub(r"\s+", "", mask_literals_and_comments(value)).rstrip("?!")
            if value.startswith("[") and value.endswith("]"):
                value = value[1:-1]
            if match := re.fullmatch(r"(?:Swift\.)?Array<(.+)>", value):
                value = match[1]
            parts = value.split(".")
            aliases = [
                alias
                for alias in context[reference_file].get("typeAliases", [])
                if alias["name"] == parts[-1]
                and alias.get("lexicalScope")
                and (
                    alias["scope"] == parts[:-1]
                    if len(parts) > 1
                    else reference["scope"][: len(alias["scope"])] == alias["scope"]
                )
                and reference.get("lexicalScope", [])[: len(alias.get("lexicalScope", []))]
                == alias.get("lexicalScope", [])
            ]
            if aliases:
                reference = max(
                    aliases, key=lambda alias: (len(alias["scope"]), len(alias["lexicalScope"]))
                )
                value = reference["type"]
                continue
            key = resolver.resolve(reference_file, value, reference["scope"], aliases=False)
            if key is None:
                return value in constructed_types
            if key not in resolver.aliases:
                return False
            reference_file = resolver.paths[key]
            reference = {"scope": list(key[1][:-1]), "lexicalScope": []}
            value = resolver.aliases[key]
        return False

    helpers = view_helper_ranges(context, resolver, origin=origin)
    calls = [
        (origin, facts, call)
        for call in facts["calls"]
        if scope_contains_type(call["scope"], view_types)
    ]
    helper_paths = [path for path, ranges in helpers.items() if ranges]
    calls += [
        (path, context[path], call)
        for path in helper_paths
        for call in context[path]["calls"]
        if any(start <= call["start"] < end for start, end in helpers[path])
    ]
    for reference_file, source_facts, call in calls:
        called = re.sub(r"\s+", "", mask_literals_and_comments(call["value"]))
        if canonical_type(called.removesuffix(".init").removesuffix(".self"), call, reference_file):
            return True
        if called != ".init":
            continue
        if any(
            canonical_type(value, call, reference_file)
            for value in expected_argument_types(
                source_facts, call, context=call_context, path=reference_file
            )
        ):
            return True
        bindings = [
            (binding, re.match(r"\w+\s*:\s*([\w.?!]+)", binding["value"]))
            for binding in source_facts.get("bindings", [])
            if binding["start"] <= call["start"] < binding["start"] + len(binding["value"].encode())
        ]
        typed = [(binding, match[1]) for binding, match in bindings if match]
        if typed:
            binding, value = max(typed, key=lambda entry: entry[0]["start"])
            if canonical_type(value, binding, reference_file):
                return True
        else:
            functions = [
                function
                for function in source_facts.get("functionRanges", [])
                if function["start"] <= call["start"] < function["end"]
                and function.get("returnType")
            ]
            if functions and canonical_type(
                max(functions, key=lambda function: function["start"])["returnType"],
                call,
                reference_file,
            ):
                return True
    return False


def swift_files() -> list[Path]:
    from swift_source_index import repository_swift_files

    return repository_swift_files()


def line_number(source: str, position: int) -> int:
    return source.count("\n", 0, position) + 1


def mask_literals_and_comments(source: str, *, keep_comments: bool = False) -> str:
    return swift_code(source, keep_comments=keep_comments)


def is_view_source(path: Path, code: str) -> bool:
    if path.name.endswith(("View.swift", "Views.swift", "Screen.swift", "Screens.swift")):
        return True
    return (
        re.search(
            r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b",
            code,
        )
        is not None
    )


def view_declaration_ranges(code: str) -> list[tuple[int, int]]:
    """按 View 声明定位源码范围。"""
    ranges: list[tuple[int, int]] = []
    declaration = re.compile(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b[^{}]*\{"
    )
    for match in declaration.finditer(code):
        opening = code.find("{", match.start(), match.end())
        depth = 0
        for index in range(opening, len(code)):
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
                if depth == 0:
                    ranges.append((match.start(), index + 1))
                    break
    return ranges


def view_request_matches(code: str) -> list[re.Match[str]]:
    ranges = view_declaration_ranges(code)
    return [
        match
        for match in DIRECT_VIEW_REQUEST.finditer(code)
        if any(start <= match.start() < end for start, end in ranges)
    ]


def add_matches(
    findings: list[str],
    path: Path,
    source: str,
    pattern: re.Pattern[str],
    message: str,
) -> None:
    for match in pattern.finditer(source):
        findings.append(f"{relative(path)}:{line_number(source, match.start())}: {message}")


def uses_application_support_storage(member: dict) -> bool:
    return any(
        entry in member["value"]
        for entry in (
            "AppFileDirectories.applicationSupport",
            "AppFileDirectories.accountSupportFileURL",
        )
    )


def client_source_findings(
    path: Path,
    source: str,
    facts: dict | None = None,
    context: dict | None = None,
    *,
    resolver=None,
) -> list[str]:
    if not any(path.is_relative_to(root) for root in PRODUCTION_ROOTS):
        return []
    errors: list[str] = []
    name = relative(path)
    code = mask_literals_and_comments(source)
    add_matches(
        errors,
        path,
        code,
        re.compile(r"\.\s*loadTransferable\s*\(\s*type\s*:\s*(?:Foundation\.)?Data\s*\.\s*self"),
        "照片原始数据读取使用 loadBoundedImageData 的容量预算",
    )
    if name not in STDOUT_EXCEPTIONS:
        add_matches(errors, path, code, DIRECT_STDOUT_LOG, "诊断输出使用所属模块的 Logger")
    community_roots = tuple(
        ROOT / "Modules" / module
        for module in (
            "CourseFeature",
            "GalleryFeature",
            "PaperFeature",
            "MineFeature",
            "CommunityUI",
        )
    )
    if any(path.is_relative_to(root) for root in community_roots) and is_view_source(path, code):
        if facts is None:
            from swift_source_index import swift_syntax_index_sources

            facts = swift_syntax_index_sources({str(path): source})[str(path)]
        formatter_types = {
            prefix + name
            for prefix in ("", "Foundation.")
            for name in ("DateFormatter", "ISO8601DateFormatter", "RelativeDateTimeFormatter")
        }
        if ast_has_view_construction(facts, formatter_types, context=context, resolver=resolver):
            errors.append(f"{name}: 社区日期解析统一使用 AppDateText")
    return errors


def cancellation_findings(
    path: Path, source: str, facts: dict | None, *, resolver=None
) -> list[str]:
    if not any(path.is_relative_to(root) for root in PRODUCTION_ROOTS):
        return []
    findings = []
    code = mask_literals_and_comments(source)
    from swift_type_index import SwiftTypeIndex

    types = resolver or SwiftTypeIndex({str(path): facts or {}})
    for match in re.finditer(
        r"\b(?:is\b|as\b\s*[?!]?)\s*([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*)", code
    ):
        start = len(source[: match.start()].encode())
        end = len(source[: match.end()].encode())
        identifiers = [
            item
            for item in (facts or {}).get("scopedIdentifiers", [])
            if start <= item["start"] < end
        ]
        scope = identifiers[-1]["scope"] if identifiers else []
        if (
            types.terminal_name(str(path), match[1], scope).removeprefix("Swift.")
            != "CancellationError"
        ):
            continue
        owned = path.is_relative_to(ROOT / "Modules/TransportCore") and scope == [
            "TaskCancellation"
        ]
        if not owned:
            findings.append(
                (
                    f"{relative(path)}"
                    f":"
                    f"{line_number(source, match.start())}"
                    f": 任务取消必须通过 TaskCancellation.matches 统一识别"
                )
            )
    return findings


def enclosing_functions(functions: list[dict], start: int) -> list[dict]:
    result = []
    for function in functions:
        start_offset = function.get("bodyStart")
        if start_offset is None:
            start_offset = function["start"]
        if start_offset <= start < function["end"]:
            result.append(function)
    return result


def file_write_calls(index: dict) -> dict[str, set[int]]:
    from swift_type_index import (
        SwiftTypeIndex,
        SwiftBindingTypes,
        receiver_resolver,
        callable_effect_index,
        visible_callable_ranges,
    )
    from swift_source_index import matching_functions
    from network_capability_rules import matching_api_calls

    index = callable_effect_index(index)
    types, resolve = SwiftTypeIndex(index), receiver_resolver(index)
    bindings = SwiftBindingTypes(index, types)
    methods, functions, calls = {}, {}, {}
    writes = {path: set() for path in index}
    for path, facts in index.items():
        for function in facts.get("functionRanges", []):
            key = (path, function["start"])
            functions[key] = function
            owner = ".".join(types.function_scope(path, function["scope"]))
            if not function.get("lexicalScope"):
                methods.setdefault((owner, function["name"]), []).append((path, function))
    edges, owners = {}, {}
    for path, facts in index.items():
        for call in facts.get("invocations", []):
            key = (path, call["start"])
            calls[key] = call
            name = call["calledExpression"].rsplit(".", 1)[-1]
            kind = bindings.receiver_type(call, path)
            kind = re.sub(r"\bany\s+|\s+", "", kind) if kind else None
            if kind is None:
                receiver_name = call["calledExpression"].rsplit(".", 1)[0]
                if (
                    receiver_name in {"FileManager.default", "Foundation.FileManager.default"}
                    and types.resolve(path, receiver_name.removesuffix(".default"), call["scope"])
                    is None
                ):
                    kind = "Foundation.FileManager"
            receiver_types = bindings.receiver_components(call, path) | {kind}
            owner_types = {
                owner
                for name in receiver_types
                if (owner := types.resolve(path, name or "", call["scope"]))
            }
            bases = {
                types.terminal_name(types.paths[owner], base, owner[1][:-1])
                for owner in owner_types
                for base in types.bases(owner)
            }
            service = bool(
                (receiver_types | bases)
                & {
                    "AppFileService",
                    "StorageCore.AppFileService",
                    "StorageCore.LocalAppFileService",
                }
            )
            manager = kind in {"FileManager", "Foundation.FileManager"}
            writer = kind in {
                "Data",
                "String",
                "NSData",
                "NSMutableData",
                "NSString",
                "NSMutableString",
                "FileWrapper",
                "NSFileWrapper",
                "FileHandle",
                "NSFileHandle",
            } or (kind or "").removeprefix("Foundation.") in {
                "Data",
                "String",
                "NSData",
                "NSMutableData",
                "NSString",
                "NSMutableString",
                "FileWrapper",
                "NSFileWrapper",
                "FileHandle",
                "NSFileHandle",
            }
            if (
                (service or manager)
                and name
                in {
                    "removeItem",
                    "writeData",
                    "createDirectory",
                    "moveItem",
                    "copyItem",
                    "replaceItemAt",
                    "setPrivateFileProtection",
                    "setBackupExcluded",
                    "setModificationDate",
                }
                or writer
                and name == "write"
                and {"to", "contentsOf"}.intersection(call.get("argumentLabels", []))
            ):
                writes[path].add(call["start"])
            enclosing = enclosing_functions(facts.get("functionRanges", []), call["start"])
            if enclosing:
                owner = max(enclosing, key=lambda function: function["start"])
                owners[key] = (path, owner["start"])
            receiver = resolve(dict(call, path=path))
            candidates = list(methods.get((receiver, name), [])) if receiver else []
            if "." not in call["calledExpression"].removeprefix("self."):
                candidates += [
                    (path, function) for function in matching_functions(facts, name, call)
                ]
                owner = ".".join(types.function_scope(path, call["scope"]))
                candidates += methods.get((owner, name), [])
            unique = {
                (source, function["start"]): (source, function) for source, function in candidates
            }
            edges[key] = {
                (source, function["start"])
                for source, function in matching_api_calls(
                    index,
                    list(unique.values()),
                    dict(call, path=path),
                    types=types,
                    conservative=True,
                )
            }
            if "." not in call["calledExpression"].removeprefix("self."):
                edges[key].update(
                    (path, alias["start"]) for alias in visible_callable_ranges(facts, name, call)
                )
    callable_keys = {
        (path, alias["start"])
        for path, facts in index.items()
        for alias in facts.get("callableRanges", [])
    }
    affected = set()
    changed = True
    while changed:
        changed = False
        for key, call in calls.items():
            if edges[key] & affected and key[1] not in writes[key[0]]:
                writes[key[0]].add(key[1])
                changed = True
            owner = owners.get(key)
            if not (key[1] in writes[key[0]] and owner and (owner not in affected)):
                continue
            function = functions[owner]
            if function.get("isThrowing") or owner in callable_keys:
                affected.add(owner)
                changed = True
    return writes


def discarded_file_write_findings(
    path: Path, source: str, facts: dict, writes: dict | None = None
) -> list[str]:
    cache_paths = {
        ROOT / "Modules/MediaKit/Sources/RemoteImageCache.swift",
        ROOT / "Modules/MediaKit/Sources/CachedRemoteImage.swift",
    }
    if path in cache_paths:
        return []
    if writes is None:
        writes = file_write_calls({str(path): facts})
    errors = []
    for clause in facts.get("discardedOptionalTries", []):
        end = clause["start"] + len(clause["value"].encode())
        calls = [
            call for call in facts.get("invocations", []) if clause["start"] <= call["start"] < end
        ]
        if any(call["start"] in writes.get(str(path), set()) for call in calls):
            line = source.encode()[: clause["start"]].count(b"\n") + 1
            errors.append(f"{path.relative_to(ROOT)}:{line}: 文件写入与删除需要处理错误或记录诊断")
    return errors


def asynchronous_test_wait_findings(path: Path, source: str, facts: dict) -> list[str]:
    name = relative(path)
    if not name.startswith(("ModuleTests/", "BIT101-iOSTests/", "BIT101-iOSUITests/")):
        return []
    helper = [
        row
        for row in facts.get("functions", [])
        if not row.get("scope") and re.search(r"\bfunc\s+waitForTestEvent\b", row["value"])
    ]
    findings = []
    for row in facts.get("controlFlow", []):
        if not re.match(r"while\b", row["value"]):
            continue
        value = mask_literals_and_comments(row["value"])
        polling = re.search(r"\bTask\s*\.\s*yield\s*\(", value)
        swallowed_sleep = re.search(r"\btry\s*\?\s*await\s+Task\s*\.\s*sleep\s*\(", value)
        if not polling and not (
            swallowed_sleep
            and not re.search(
                r"\b(?:break|return|throw)\b|\bTask\s*\.\s*(?:isCancelled|checkCancellation)\b",
                value,
            )
        ):
            continue
        if name == "ModuleTests/Support/FileServiceContract.swift" and any(
            owner["start"] <= row["start"] < owner["start"] + len(owner["value"].encode())
            for owner in helper
        ):
            continue
        line = source.encode()[: row["start"]].count(b"\n") + 1
        findings.append(f"{name}:{line}: 异步事件等待统一沿共享 waitForTestEvent 核对取消与期限")
    tests = {row["start"] for row in facts.get("tests", []) if row.get("isTestingTest")}
    closures = facts.get("inlineClosureRanges", []) + facts.get("callableRanges", [])
    for function in facts.get("functionRanges", []):
        observer = function["name"].startswith(("waitFor", "waitUntil"))
        if not observer and function["start"] not in tests:
            continue
        waits = [
            call
            for call in facts.get("invocations", [])
            if function["bodyStart"] <= call["start"] < function["end"]
            and call["calledExpression"]
            in {"withCheckedContinuation", "withCheckedThrowingContinuation"}
        ]
        waits = [
            call
            for call in waits
            if observer
            or not any(
                function["start"] < closure["start"] <= call["start"] < closure["end"]
                for closure in closures + facts.get("functionRanges", [])
            )
        ]
        waits = [
            call
            for call in waits
            if not any(
                guard["calledExpression"] == "withTaskCancellationHandler"
                and guard["start"] <= call["start"] < guard["start"] + len(guard["value"].encode())
                for guard in facts.get("invocations", [])
            )
        ]
        if waits:
            line = source.encode()[: function["start"]].count(b"\n") + 1
            findings.append(f"{name}:{line}: 异步事件观察沿共享 waitForTestEvent 核对取消与期限")
    asynchronous = {row["start"] for row in facts.get("functionRanges", []) if row.get("isAsync")}
    masked = mask_literals_and_comments(source)
    source_bytes = source.encode()
    suite_limits = [
        call["scope"]
        for call in facts.get("invocations", [])
        if call["calledExpression"] == ".timeLimit"
        and re.search(
            r"@(?:Testing\.)?Suite\s*\([^{}]*$",
            masked[: len(source_bytes[: call["start"]].decode())],
        )
    ]
    for function in facts.get("functions", []):
        if function["start"] not in tests or function["start"] not in asynchronous:
            continue
        attributes = re.split(
            r"\bfunc\b", mask_literals_and_comments(function["value"]), maxsplit=1
        )[0]
        limited = re.search(r"\.\s*timeLimit\s*\(", attributes) or any(
            function["scope"][: len(scope)] == scope for scope in suite_limits
        )
        if not limited:
            line = source.encode()[: function["start"]].count(b"\n") + 1
            findings.append(f"{name}:{line}: Swift Testing 异步测试需要 timeLimit 期限")
    return findings


def check_duplicate_swift_imports(name: str, masked_source: str, errors: list[str]) -> None:
    import_branches = [set()]
    for line, text in enumerate(masked_source.split("\n"), 1):
        if re.match(r"\s*#if\b", text):
            import_branches.append(set())
            continue
        if re.match(r"\s*#(?:else|elseif)\b", text):
            import_branches[-1].clear()
            continue
        if re.match(r"\s*#endif\b", text):
            if len(import_branches) > 1:
                import_branches.pop()
            continue
        for match in re.finditer(r"(?:^|;)\s*import\s+([^;\n]+)", text):
            module = " ".join(match.group(1).split())
            if any(module in branch for branch in import_branches):
                errors.append(f"{name}:{line}: 重复 import {module}")
            import_branches[-1].add(module)


def source_findings(syntax_index: dict[str, dict] | None = None) -> tuple[list[str], list[str]]:
    errors: list[str] = view_transport_findings(syntax_index or {})
    review: list[str] = []
    writes = file_write_calls(syntax_index or {})
    unsafe_concurrency_escape = re.compile(r"\bnonisolated\s*\(\s*unsafe\s*\)|@\s*`?unchecked\b`?")

    large_files: list[str] = []
    from swift_type_index import SwiftTypeIndex

    types = SwiftTypeIndex(syntax_index or {})
    request_types = SwiftTypeIndex(
        {
            path: dict(
                facts,
                typeAliases=[
                    alias for alias in facts.get("typeAliases", []) if not alias.get("lexicalScope")
                ],
            )
            for path, facts in (syntax_index or {}).items()
        }
    )
    type_indexes = {path: types.conformances(path) for path in (syntax_index or {})}
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        masked_source = mask_literals_and_comments(source)
        name = relative(path)

        errors.extend(
            client_source_findings(
                path,
                source,
                syntax_index.get(str(path)) if syntax_index else None,
                syntax_index,
                resolver=request_types,
            )
        )

        if source and not source.endswith("\n"):
            errors.append(f"{name}: 文件末尾缺少换行")
        if "\t" in source:
            errors.append(f"{name}: Swift 源码请使用空格缩进")
        if any(line.rstrip() != line for line in source.splitlines()):
            errors.append(f"{name}: 存在行尾空白")
        check_duplicate_swift_imports(name, masked_source, errors)

        if re.search(r"^\s*#if\s+false\b", masked_source, re.MULTILINE):
            errors.append(f"{name}: 请删除 #if false 死代码块")
        add_matches(
            errors,
            path,
            mask_literals_and_comments(source, keep_comments=True),
            re.compile(r"\b(?:TODO|FIXME|HACK)\b"),
            "请清理遗留 TODO/FIXME/HACK",
        )

        errors.extend(
            cancellation_findings(
                path, source, syntax_index.get(str(path)) if syntax_index else None, resolver=types
            )
        )
        add_matches(
            errors,
            path,
            masked_source,
            unsafe_concurrency_escape,
            "Swift 并发访问请声明真实隔离或使用锁/Actor",
        )
        facts = syntax_index.get(str(path)) if syntax_index else None
        from validation_test_areas import fixture_resource_findings

        if facts:
            errors.extend(fixture_resource_findings(path, facts))
        if facts:
            errors.extend(asynchronous_test_wait_findings(path, source, facts))
        if facts:
            errors.extend(discarded_file_write_findings(path, source, facts, writes))
        for clause in (facts or {}).get("emptyCatchClauses", []):
            line = source.encode()[: clause["start"]].count(b"\n") + 1
            errors.append(f"{name}:{line}: 请记录诊断或显式处理错误")
        if facts and ast_has_view_request(
            facts, type_indexes.get(str(path)), syntax_index, resolver=request_types
        ):
            errors.append(f"{name}: 请将 URLRequest 构造移到 Service")
        elif facts is None:
            for match in view_request_matches(masked_source):
                errors.append(
                    f"{name}:{line_number(source, match.start())}: 请将 URLRequest 构造移到 Service"
                )

        force_count = len(facts["forceUnwraps"]) if facts else 0
        if force_count:
            errors.append(f"{name}: 发现 {force_count} 处强制解包，请改用 guard/if let/#require")
        source_line_count = len(source.splitlines())
        if source_line_count > 800:
            large_files.append(name)

    if large_files:
        review.append(
            "大型文件候选（按独立生命周期拆分，不因长度机械拆分）：" + ", ".join(large_files)
        )
    return errors, review


def script_findings() -> list[str]:
    errors: list[str] = []
    for path in repository_script_paths(ROOT, {".sh", ".py"}):
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source) if path.suffix == ".py" else None
        entry = path.suffix != ".py" or any(
            isinstance(node, ast.If)
            and any(
                isinstance(item, ast.Name) and item.id == "__name__" for item in ast.walk(node.test)
            )
            for node in tree.body
        )
        if entry and not source.startswith("#!"):
            errors.append(f"{relative(path)}: 入口脚本需要 shebang")
        if entry and not (path.stat().st_mode & stat.S_IXUSR):
            errors.append(f"{relative(path)}: 入口脚本需要用户可执行权限")
        if tree and any(
            isinstance(node, ast.Import) and any(alias.name == "py_compile" for alias in node.names)
            for node in ast.walk(tree)
        ):
            errors.append(f"{relative(path)}: Python 语法检查使用内存 compile")
        if path.suffix == ".sh" and re.search(
            r"(?:mktemp|date[^\n]*%|uuidgen|\$\$)\s*[^\n]*(?:/|PATH|DIR|FILE|OUTPUT)", source
        ):
            errors.append(f"{relative(path)}: 输出路径需要固定类别名称")
    return errors


from audit_callback_rules import audit_callback_findings
from ci_wiring_rules import (
    audit_wiring_findings as ci_audit_wiring_findings,
    ci_trigger_shell_self_test,
)


def audit_wiring_findings() -> list[str]:
    return ci_audit_wiring_findings(ROOT, scheme_inventory_findings, extension_dependency_findings)


def extension_dependency_findings(project: dict) -> list[str]:
    objects = project["objects"]
    targets = {
        value["name"]: key
        for key, value in objects.items()
        if value.get("isa") == "PBXNativeTarget"
    }
    errors = []
    for parent, child in (
        ("BIT101-iOS", "BIT101ScheduleWidgets"),
        ("BIT101-iOS", "BIT101Watch"),
        ("BIT101Watch", "BIT101WatchWidgets"),
    ):
        dependencies = objects.get(targets.get(parent), {}).get("dependencies", [])
        children = {objects[dependency].get("target") for dependency in dependencies}
        if targets.get(child) is None or targets[child] not in children:
            errors.append(f"project.pbxproj: {parent} 必须通过 target 依赖编译 {child}")
        if not (parent == "BIT101-iOS"):
            continue
        for dependency in dependencies:
            edge = objects[dependency]
            if edge.get("target") == targets.get(child) and edge.get("platformFilter") != "ios":
                errors.append(f"project.pbxproj: {child} 的 App 依赖应限定为 iOS 平台")
    return errors


def scheme_inventory_findings(schemes: dict[str, str]) -> list[str]:
    from xml.etree import ElementTree

    def signature(node):
        return (
            node.tag,
            tuple(
                sorted(
                    (key, value)
                    for key, value in node.attrib.items()
                    if key != "LastUpgradeVersion"
                )
            ),
            (node.text or "").strip(),
            tuple(signature(child) for child in node),
        )

    errors, owners = [], {}
    for name, content in sorted(schemes.items()):
        try:
            key = signature(ElementTree.fromstring(content))
        except ElementTree.ParseError:
            errors.append(f"{name}: 共享 Scheme 需要有效 XML")
            continue
        if key in owners:
            errors.append(f"{name}: 共享 Scheme 与 {owners[key]} 的运行约定重复")
        else:
            owners[key] = name
    return errors
