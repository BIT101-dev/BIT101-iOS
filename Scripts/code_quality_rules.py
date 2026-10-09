"""Production code, script and workflow quality rules."""
from __future__ import annotations

from pathlib import Path
import ast
import fcntl
import json
import os
import re
import shlex
import stat
import subprocess
import sys
from swift_source_index import declaration_conformances, expected_argument_types, scope_contains_type, swift_syntax_index, swift_code
from contextlib import contextmanager
from ui_source_facts import explanatory_text_report

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_ROOTS = tuple(ROOT / name for name in (
    "Modules", "BIT101-iOS", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"
))
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
    if os.environ.get("BIT101_STATIC_AUDIT_LOCK_HELD") == "1":
        yield
        return
    path = ROOT / ".build/static-audit/audit.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def ast_has_identifier(facts: dict, name: str) -> bool:
    return name in facts["identifiers"]


def ast_has_view_request(facts: dict, type_index: dict | None = None, context: dict[str, dict] | None = None, *, resolver=None) -> bool:
    return ast_has_view_construction(facts, {"URLRequest", "Foundation.URLRequest"}, type_index, context, resolver=resolver)


def ast_has_view_construction(facts: dict, constructed_types: set[str], type_index: dict | None = None,
                              context: dict[str, dict] | None = None, *, resolver=None) -> bool:
    from swift_type_index import SwiftTypeIndex
    context = {"source": facts} if context is None else context
    origin = next((path for path, entry in context.items() if entry is facts), "source")
    resolver = resolver or SwiftTypeIndex({path: dict(entry, typeAliases=[alias for alias in entry.get('typeAliases', [])
        if not alias.get('lexicalScope')]) for path, entry in context.items()})
    conformances = declaration_conformances({"source": facts}) if type_index is None else type_index
    view_types = {owner for owner, bases in conformances.items() if any(base.rsplit(".", 1)[-1] == "View" for base in bases)}
    def canonical_type(value, reference):
        seen = set()
        reference_file = origin
        while (reference_file, value) not in seen:
            seen.add((reference_file, value))
            value = re.sub(r"\s+", "", mask_literals_and_comments(value)).rstrip("?!")
            if value.startswith("[") and value.endswith("]"): value = value[1:-1]
            if match := re.fullmatch(r"(?:Swift\.)?Array<(.+)>", value): value = match[1]
            parts = value.split(".")
            aliases = [alias for alias in context[reference_file].get('typeAliases', []) if alias['name'] == parts[-1]
                and alias.get('lexicalScope') and (alias["scope"] == parts[:-1] if len(parts) > 1
                     else reference["scope"][:len(alias["scope"])] == alias["scope"])
                and reference.get("lexicalScope", [])[:len(alias.get("lexicalScope", []))] == alias.get("lexicalScope", [])]
            if aliases:
                reference = max(aliases, key=lambda alias: (len(alias['scope']), len(alias['lexicalScope'])))
                value = reference['type']
                continue
            key = resolver.resolve(reference_file, value, reference['scope'], aliases=False)
            if key is None: return value in constructed_types
            if key not in resolver.aliases: return False
            reference_file = resolver.paths[key]
            reference = {'scope': list(key[1][:-1]), 'lexicalScope': []}
            value = resolver.aliases[key]
        return False
    for call in facts["calls"]:
        if not scope_contains_type(call["scope"], view_types): continue
        called = re.sub(r"\s+", "", mask_literals_and_comments(call["value"]))
        if canonical_type(called.removesuffix(".init").removesuffix(".self"), call): return True
        if called != ".init": continue
        if any(canonical_type(value, call) for value in expected_argument_types(facts, call)): return True
        bindings = [(binding, re.match(r"\w+\s*:\s*([\w.?!]+)", binding["value"]))
            for binding in facts.get("bindings", [])
            if binding["start"] <= call["start"] < binding["start"] + len(binding["value"].encode())]
        typed = [(binding, match[1]) for binding, match in bindings if match]
        if typed:
            binding, value = max(typed, key=lambda entry: entry[0]["start"])
            if canonical_type(value, binding): return True
        else:
            functions = [function for function in facts.get("functionRanges", [])
                if function["start"] <= call["start"] < function["end"] and function.get("returnType")]
            if functions and canonical_type(max(functions, key=lambda function: function["start"])["returnType"], call): return True
    return False


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


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
    return re.search(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b",
        code,
    ) is not None


def view_declaration_ranges(code: str) -> list[tuple[int, int]]:
    """返回真实 View 声明的范围，避免把同文件的缓存/Loader 当成 View。"""
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


def owner_scopes(syntax_index: dict[str, dict], owner: str) -> list[tuple[dict, list[str]]]:
    return [
        (facts, declaration["scope"] + [declaration["name"]])
        for facts in syntax_index.values()
        for declaration in facts["declarations"]
        if declaration["name"] == owner
        and declaration["kind"] in {"struct", "class", "actor", "extension"}
    ]


def owner_has_call(syntax_index: dict[str, dict], owner: str, call_name: str) -> bool:
    return any(
        any(
            (call["value"] == call_name or call["value"].endswith("." + call_name))
            and call["scope"] == scope
            for call in facts["calls"]
        )
        for facts, scope in owner_scopes(syntax_index, owner)
    )


def uses_application_support_storage(member: dict) -> bool:
    return any(
        entry in member["value"]
        for entry in (
            "AppFileDirectories.applicationSupport",
            "AppFileDirectories.accountSupportFileURL",
        )
    )


def client_source_findings(path: Path, source: str, facts: dict | None = None, context: dict | None = None, *, resolver=None) -> list[str]:
    if not any(path.is_relative_to(root) for root in PRODUCTION_ROOTS):
        return []
    errors: list[str] = []
    name = relative(path)
    code = mask_literals_and_comments(source)
    if name not in STDOUT_EXCEPTIONS:
        add_matches(errors, path, code, DIRECT_STDOUT_LOG, "诊断输出使用所属模块的 Logger")
    community_roots = tuple(ROOT / "Modules" / module for module in ("CourseFeature", "GalleryFeature", "PaperFeature", "MineFeature", "CommunityUI"))
    if any(path.is_relative_to(root) for root in community_roots) and is_view_source(path, code):
        if facts is None:
            from swift_source_index import swift_syntax_index_sources
            facts = swift_syntax_index_sources({str(path): source})[str(path)]
        formatter_types = {prefix + name for prefix in ("", "Foundation.")
            for name in ("DateFormatter", "ISO8601DateFormatter", "RelativeDateTimeFormatter")}
        if ast_has_view_construction(facts, formatter_types, context=context, resolver=resolver):
            errors.append(f"{name}: 社区日期解析统一使用 AppDateText")
    return errors


def cancellation_findings(path: Path, source: str, facts: dict | None) -> list[str]:
    if not any(path.is_relative_to(root) for root in PRODUCTION_ROOTS):
        return []
    findings = []
    code = mask_literals_and_comments(source)
    for match in re.finditer(r"\b(?:is\b|as\b\s*[?!]?)\s*(?:Swift\s*\.\s*)?CancellationError\b", code):
        start = len(source[:match.start()].encode())
        end = len(source[:match.end()].encode())
        owned = path.is_relative_to(ROOT / "Modules/TransportCore") and any(
            item["value"] == "CancellationError" and item["scope"] == ["TaskCancellation"]
            and start <= item["start"] < end
            for item in (facts or {}).get("scopedIdentifiers", [])
        )
        if not owned:
            findings.append(f"{relative(path)}:{line_number(source, match.start())}: 任务取消必须通过 TaskCancellation.matches 统一识别")
    return findings


def discarded_file_write_findings(path: Path, source: str, facts: dict) -> list[str]:
    if any(path.is_relative_to(ROOT / name) for name in ("BIT101-iOSTests", "BIT101-iOSUITests", "ModuleTests")): return []
    cache_paths = {ROOT / "Modules/MediaKit/Sources/RemoteImageCache.swift", ROOT / "Modules/MediaKit/Sources/CachedRemoteImage.swift"}
    if path in cache_paths: return []
    errors = []
    for clause in facts.get("discardedOptionalTries", []):
        end = clause["start"] + len(clause["value"].encode())
        calls = [call for call in facts.get("invocations", []) if clause["start"] <= call["start"] < end]
        def mutates_file(call):
            name = call['calledExpression'].rsplit('.', 1)[-1]
            return name in {'removeItem', 'writeData', 'createDirectory', 'moveItem', 'copyItem', 'replaceItemAt'} \
                or name == 'write' and bool({'to', 'contentsOf'}.intersection(call.get('argumentLabels', [])))
        if any(mutates_file(call) for call in calls):
            line = source.encode()[:clause["start"]].count(b"\n") + 1
            errors.append(f"{path.relative_to(ROOT)}:{line}: 文件写入与删除需要处理错误或记录诊断")
    return errors


def source_findings(syntax_index: dict[str, dict] | None = None) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    review: list[str] = []
    unsafe_concurrency_escape = re.compile(
        r"\bnonisolated\s*\(\s*unsafe\s*\)|@\s*unchecked\s+Sendable"
    )

    large_files: list[str] = []
    from swift_type_index import SwiftTypeIndex
    types = SwiftTypeIndex(syntax_index or {})
    request_types = SwiftTypeIndex({path: dict(facts, typeAliases=[alias for alias in facts.get('typeAliases', [])
        if not alias.get('lexicalScope')]) for path, facts in (syntax_index or {}).items()})
    type_indexes = {path: types.conformances(path) for path in (syntax_index or {})}
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        masked_source = mask_literals_and_comments(source)
        name = relative(path)

        errors.extend(client_source_findings(path, source, syntax_index.get(str(path)) if syntax_index else None,
            syntax_index, resolver=request_types))

        if source and not source.endswith("\n"):
            errors.append(f"{name}: 文件末尾缺少换行")
        if "\t" in source:
            errors.append(f"{name}: Swift 源码不得使用 Tab 缩进")
        if any(line.rstrip() != line for line in source.splitlines()):
            errors.append(f"{name}: 存在行尾空白")
        import_branches = [set()]
        for line, text in enumerate(masked_source.split("\n"), 1):
            if re.match(r"\s*#if\b", text):
                import_branches.append(set())
            elif re.match(r"\s*#(?:else|elseif)\b", text):
                import_branches[-1].clear()
            elif re.match(r"\s*#endif\b", text):
                if len(import_branches) > 1: import_branches.pop()
            else:
                for match in re.finditer(r"(?:^|;)\s*import\s+([^;\n]+)", text):
                    module = " ".join(match.group(1).split())
                    if any(module in branch for branch in import_branches):
                        errors.append(f"{name}:{line}: 重复 import {module}")
                    import_branches[-1].add(module)

        if re.search(r"^\s*#if\s+false\b", masked_source, re.MULTILINE):
            errors.append(f"{name}: 不应保留 #if false 死代码块")
        add_matches(errors, path, mask_literals_and_comments(source, keep_comments=True),
                    re.compile(r"\b(?:TODO|FIXME|HACK)\b"), "请清理遗留 TODO/FIXME/HACK")

        errors.extend(cancellation_findings(path, source, syntax_index.get(str(path)) if syntax_index else None))
        add_matches(errors, path, masked_source, unsafe_concurrency_escape, "禁止绕过 Swift 并发安全检查：请表达真实隔离或使用锁/Actor")
        facts = syntax_index.get(str(path)) if syntax_index else None
        if facts: errors.extend(discarded_file_write_findings(path, source, facts))
        for clause in (facts or {}).get("emptyCatchClauses", []):
            line = source.encode()[:clause["start"]].count(b"\n") + 1
            errors.append(f"{name}:{line}: 禁止静默吞掉异常；请记录诊断或显式处理错误")
        if facts and ast_has_view_request(facts, type_indexes.get(str(path)), syntax_index, resolver=request_types):
            errors.append(f"{name}: View 不应直接构造 URLRequest；请求移到 Service")
        elif facts is None:
            for match in view_request_matches(masked_source):
                errors.append(
                    f"{name}:{line_number(source, match.start())}: "
                    "View 不应直接构造 URLRequest；请求移到 Service"
                )

        force_count = len(facts["forceUnwraps"]) if facts else 0
        if force_count:
            errors.append(f"{name}: 禁止强制解包，共 {force_count} 处；请改用 guard/if let/#require")
        source_line_count = len(source.splitlines())
        if source_line_count > 800:
            large_files.append(name)

    if large_files:
        review.append("大型文件候选（按独立生命周期拆分，不因长度机械拆分）：" + ", ".join(large_files))
    return errors, review


def script_findings() -> list[str]:
    errors: list[str] = []
    for path in sorted(SCRIPT_ROOT.glob("*")):
        if path.suffix not in {".sh", ".py"} or not path.is_file():
            continue
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source) if path.suffix == ".py" else None
        entry = path.suffix == ".sh" or any(
            isinstance(node, ast.If) and any(isinstance(item, ast.Name) and item.id == "__name__"
                for item in ast.walk(node.test)) for node in tree.body
        )
        if entry and not source.startswith("#!"):
            errors.append(f"{relative(path)}: 入口脚本需要 shebang")
        if entry and not (path.stat().st_mode & stat.S_IXUSR):
            errors.append(f"{relative(path)}: 入口脚本需要用户可执行权限")
        if tree and any(isinstance(node, ast.Import) and any(alias.name == "py_compile" for alias in node.names)
                        for node in ast.walk(tree)):
            errors.append(f"{relative(path)}: Python 语法检查使用内存 compile")
        if path.suffix == ".sh" and re.search(
            r"(?:mktemp|date[^\n]*%|uuidgen|\$\$)\s*[^\n]*(?:/|PATH|DIR|FILE|OUTPUT)", source
        ):
            errors.append(f"{relative(path)}: 输出路径需要固定类别名称")
    return errors


def automatic_school_fetch_findings(syntax_index: dict[str, dict]) -> list[str]:
    """核对生命周期调用链与学校业务请求入口。"""
    errors: list[str] = []
    forbidden_identifiers = (
        "SchoolDataRefreshCoordinator",
        "refreshOnEntry",
        "ScheduleAutoRefreshPreferences",
        "ScoreAutomaticRefreshPolicy",
        "autoRefreshCourses",
        "prepareClassroomIfNeeded",
        "refreshClassroomMetaInBackgroundIfNeeded",
        "claimAutomaticPreparation",
    )
    forbidden_literals = ("schedule.auto-refresh", "silent-refresh")
    for name, facts in syntax_index.items():
        path = Path(name)
        for term in forbidden_identifiers:
            if ast_has_identifier(facts, term):
                errors.append(f"{relative(path)}: 不得重新引入学校/WebVPN 自动请求：{term}")
        for term in forbidden_literals:
            if any(term in literal["value"] for literal in facts["stringSegments"]):
                errors.append(f"{relative(path)}: 不得重新引入学校/WebVPN 自动请求：{term}")

    if owner_has_call(syntax_index, "ScoreListPage", "bootstrapIfNeeded"):
        errors.append("ScoreListPage: 成绩页不得自动触发学校查询")

    school_protocols = {"ScheduleCourseServicing", "ScheduleDDLServicing", "ScheduleClassroomServicing",
                        "ScoreListServicing", "TrustedTranscriptServicing"}
    from swift_type_index import SwiftTypeIndex
    types = SwiftTypeIndex(syntax_index)
    protocols = {types.resolve(path, '.'.join(declaration['scope'] + [declaration['name']]), aliases=False)
        for path, facts in syntax_index.items() for declaration in facts.get('declarations', [])
        if declaration['kind'] == 'protocol'}
    school_owners = {owner for owner in protocols if owner and owner[1][-1] in school_protocols}
    while inherited := {owner for owner in protocols - school_owners if owner and any(
            types.resolve(types.paths[owner], base, owner[1][:-1]) in school_owners for base in types.records[owner])}:
        school_owners.update(inherited)
    school_scopes = {(namespace,) + scope for namespace, scope in school_owners}
    school_operations = {function["name"] for path, facts in syntax_index.items()
        for function in facts.get("functionRanges", []) if types.function_scope(path, function['scope']) in school_scopes}
    school_operations.update({"loadAvailableTerms", "refreshSchoolDDL"})
    functions = {}
    callable_names = {function["name"] for facts in syntax_index.values()
        for category in ("callableRanges", "functionRanges") for function in facts.get(category, [])}
    from swift_type_index import SwiftBindingTypes
    bindings = SwiftBindingTypes(syntax_index, types)
    type_ids, variable_types, aliases = bindings.type_ids, bindings.variable_types, bindings.aliases
    variable_scope, receiver_type = bindings.variable_scope, bindings.receiver_type
    canonical_type, reference_paths = bindings.canonical_type, bindings.reference_paths
    call_ids = {id(call) for facts in syntax_index.values() for call in facts["calls"]}

    explicit_initializers = {types.function_scope(path, function["scope"]) for path, facts in syntax_index.items()
        for function in facts.get("initializers", []) if function.get("isExplicitInitializer")}
    callback_declarations = [function for facts in syntax_index.values()
        for category in ("functionRanges", "initializers") for function in facts.get(category, [])]
    function_paths = {id(function): path for path, facts in syntax_index.items()
        for category in ("functionRanges", "initializers") for function in facts.get(category, [])}
    callback_declarations_by_name = {}
    for function in callback_declarations:
        callback_declarations_by_name.setdefault(function["name"], []).append(function)
    execution_calls = {}
    for path, facts in syntax_index.items():
        for call in facts["calls"]:
            execution_calls.setdefault((path, tuple(call["scope"]), call["value"]), []).append((facts, call))
    eager_parameters = set()

    def registered_callbacks(path, facts):
        registered, stored, executed = [], [], []
        calls = {(call["start"], call["value"]): call for call in facts["calls"]}
        for invocation in facts.get("invocations", []):
            call = calls.get((invocation["start"], invocation.get("calledExpression")))
            if call is None: continue
            scope = variable_scope(path, call)
            value = call["value"].removesuffix(".init")
            identity = types.resolve(path, value, call["scope"])
            owner = (identity[0],) + identity[1] if identity else types.function_scope(path, value.split("."))
            signature = next((variable_types[(scope[:length], value.removeprefix("self."))]
                for length in range(len(scope), -1, -1) if (scope[:length], value.removeprefix("self.")) in variable_types), None)
            escaping = set().union(*(set(alias.get("escapingParameters", [])) for alias_path, alias, alias_scope in aliases
                if signature == alias["name"] and (not alias.get("isFilePrivate") or alias_path == path)
                and scope[:len(alias_scope)] == alias_scope))
            receiver = receiver_type(call)
            receiver_id = type_ids.get(receiver)
            receiver_owner = (receiver_id[0],) + receiver_id[1] if receiver_id else None
            method = value.rsplit(".", 1)[-1]
            declarations = [function for function in callback_declarations_by_name.get("init" if method[:1].isupper() else method, [])
                if (types.function_scope(function_paths[id(function)], function["scope"]) == owner if method[:1].isupper()
                    else types.function_scope(function_paths[id(function)], function["scope"]) == receiver_owner if receiver
                    else variable_scope(path, call)[:len(types.function_scope(function_paths[id(function)], function["scope"]))]
                        == types.function_scope(function_paths[id(function)], function["scope"]))]
            arguments = list(invocation.get("closureArguments", []))
            arguments += [[index, *bounds] for index, (argument, bounds) in enumerate(zip(
                invocation.get("arguments", []), invocation.get("argumentRanges", [])))
                if re.fullmatch(r"(?:[\w?$]+\.)*\w+", argument)]
            for index, start, end in arguments:
                labels = invocation.get("argumentLabels", [])
                label = labels[index] if index < len(labels) else ""
                property_type = variable_types.get((owner, label), "")
                memberwise = owner not in explicit_initializers and "->" in property_type
                parameters = [(function, parameter) for function in declarations
                    for parameter_index, parameter in enumerate(function["parameters"])
                    if (parameter["label"] == label if label else parameter_index == index)
                    and "@escaping" in parameter["type"]]
                held = parameters and all(function.get("bodyStart") is not None
                    and (id(function), parameter.get("name", parameter["label"])) not in eager_parameters
                    for function, parameter in parameters)
                if parameters and not held: executed.append((start, end))
                if memberwise or index in escaping or held:
                    callback = {"name": label, "scope": list(owner[1:]), "ownerNamespace": owner[0], "lexicalScope": [], "start": start, "end": end}
                    registered.append(callback)
                    if memberwise: stored.append(callback)
        return registered, stored, executed

    while True:
        callback_ranges = {path: registered_callbacks(path, facts) for path, facts in syntax_index.items()}
        observed = set(eager_parameters)
        for function in callback_declarations:
            path = function_paths[id(function)]
            facts = syntax_index[path]
            deferred = facts.get("callableRanges", []) + callback_ranges[path][0]
            for parameter in function["parameters"]:
                name = parameter.get("name", parameter["label"])
                calls = execution_calls.get((path, tuple(function["scope"]), name), [])
                references = [reference for reference in facts.get("scopedIdentifiers", [])
                    if reference.get("isExpressionReference") and reference["value"] == name and reference["scope"] == function["scope"]
                    and any(start <= reference["start"] < end for start, end in callback_ranges[path][2])]
                if any(function.get("bodyStart", function["start"]) <= reference["start"] < function["end"]
                        and not any(boundary["start"] <= reference["start"] < boundary["end"] for boundary in deferred)
                        for reference in [call for _, call in calls] + references):
                    observed.add((id(function), name))
        if observed == eager_parameters: break
        eager_parameters = observed

    roots = []
    for path, facts in syntax_index.items():
        if "Tests/" in path or "UITest" in Path(path).name or "ReleaseNetworkSmoke" in Path(path).name: continue
        identifier_ids = {id(reference) for reference in facts.get("scopedIdentifiers", [])}
        member_ranges = [(member["start"], member["start"] + len(member["value"].encode())) for member in facts.get("members", [])]
        assignments = [(expression["start"], expression["start"] + len(match[1].encode()))
            for expression in facts.get("expressions", [])
            if (match := re.match(r"((?:self\.)?\w+\s*)=(?!=)", expression["value"]))]
        discarded = [(expression["start"], expression["start"] + len(expression["value"].encode()))
            for expression in facts.get("expressions", []) if re.fullmatch(r"_\s*=(?!=)\s*[\w?.]+", expression["value"])]
        references = [reference for reference in facts["calls"] + facts.get("members", [])
            + [node for node in facts.get("scopedIdentifiers", []) if node.get("isExpressionReference")]
            if (re.fullmatch(r"(?:[\w?$]+\.)*\w+", reference["value"]) or reference["value"] == ".init" or reference.get("receiverCall"))
            and not (id(reference) in identifier_ids and any(start <= reference["start"] < end for start, end in member_ranges))
            and not any(start <= reference["start"] < end for start, end in discarded)
            and not any(start <= reference["start"] < end for start, end in assignments)
            and ("." in reference["value"] or reference["value"] in callable_names
                or (variable_scope(path, reference), reference["value"]) not in variable_types)]
        registered, stored, _ = callback_ranges[path]
        deferred_ranges = facts.get("callableRanges", []) + registered
        range_sets = [facts.get(category, []) for category in ("functionRanges", "callableRanges", "initializers")] + [stored]
        for ranges in range_sets:
            for function in ranges:
                key = (variable_scope(path, function), function["name"])
                functions.setdefault(function["name"], []).append((key, [reference for reference in references
                    if function.get("bodyStart", function["start"]) <= reference["start"] < function["end"]
                    and not any(deferred["start"] <= reference["start"] < deferred["end"]
                        and deferred is not function for deferred in deferred_ranges)]))
        for declaration in facts["declarations"]:
            if "App" in {value.rsplit(".", 1)[-1] for value in declaration["inheritedTypes"]} \
                    or declaration["name"].endswith("Lifecycle") or declaration["name"] == "ScheduleReminderBackgroundRefresh":
                scope = declaration["scope"] + [declaration["name"]]
                roots.extend(call for call in references if call["scope"][:len(scope)] == scope
                    and not any(deferred["start"] <= call["start"] < deferred["end"] for deferred in deferred_ranges))
        for lifecycle in facts.get("lifecycleRanges", []):
            roots.extend(reference for reference in references
                if lifecycle["start"] <= reference["start"] < lifecycle["end"]
                and not any(deferred["start"] <= reference["start"] < deferred["end"] for deferred in deferred_ranges))

    implementations_by_receiver = {}
    for identity in types.records:
        namespace, owner = identity
        for base in types.bases(identity):
            receiver = canonical_type(base, (namespace,) + owner, types.paths[identity])
            implementations_by_receiver.setdefault(receiver, set()).add((namespace,) + owner)

    def targets(call):
        name = call["value"].rsplit(".", 1)[-1]
        candidates = functions.get(name, [])
        if name[:1].isupper():
            if id(call) not in call_ids: return []
            constructed = canonical_type(call["value"], variable_scope(reference_paths.get(id(call), ""), call), reference_paths.get(id(call), ""))
            identity = type_ids.get(constructed)
            owner = (identity[0],) + identity[1] if identity else None
            return [entry for entry in functions.get("init", []) if entry[0][0] == owner]
        receiver = receiver_type(call)
        if receiver:
            identity = type_ids.get(receiver)
            receiver_owner = (identity[0],) + identity[1] if identity else None
            implementations = implementations_by_receiver.get(receiver, ())
            return [entry for entry in candidates if receiver_owner and entry[0][0][:len(receiver_owner)] == receiver_owner
                or any(entry[0][0][:len(owner)] == owner for owner in implementations)]
        if call["value"] == ".init":
            path = reference_paths[id(call)]
            facts = syntax_index[path]
            contexts = expected_argument_types(facts, call)
            contexts.extend(match[1] for binding in facts.get("bindings", [])
                if binding["start"] <= call["start"] < binding["start"] + len(binding["value"].encode())
                and (match := re.match(r"\w+\s*:\s*([^={]+)", binding["value"])))
            identities = [type_ids.get(canonical_type(context, variable_scope(path, call), path)) for context in contexts]
            owners = {(identity[0],) + identity[1] for identity in identities if identity}
            return [entry for entry in candidates if entry[0][0] in owners]
        scope = variable_scope(reference_paths.get(id(call), ""), call)
        owned = [entry for entry in candidates if scope[:len(entry[0][0])] == entry[0][0]]
        if owned: return [entry for entry in owned if len(entry[0][0]) == max(len(item[0][0]) for item in owned)]
        receiver_name = call["value"].replace("?", "").split(".")[0]
        visible_units = {types.units[reference_paths[id(call)]], *syntax_index[reference_paths[id(call)]].get("imports", [])}
        candidates = [entry for entry in candidates if entry[0][0][0].split("@", 1)[0] in visible_units]
        named = [entry for entry in candidates if any(receiver_name.lower() in owner.lower() for owner in entry[0][0])]
        return named or candidates if "." in call["value"] else [entry for entry in candidates if len(entry[0][0]) == 1]

    reasons = {}
    predecessors = {}
    cloud_operation = "refreshFromCloudIfNeeded"
    def restricted(call):
        operation = call["value"].rsplit(".", 1)[-1].strip()
        if operation in school_operations: return True
        if operation != cloud_operation: return False
        preference = receiver_type(call) in {"BIT101-iOS.ExperimentalPreferenceCloudSync", "fixture.ExperimentalPreferenceCloudSync"} \
            or "ExperimentalPreferenceCloudSync" in call["scope"] and types.units[reference_paths[id(call)]] in {"BIT101-iOS", "fixture"}
        return not preference
    for entries in functions.values():
        for key, children in entries:
            for child in children:
                operation = child["value"].rsplit(".", 1)[-1].strip()
                if restricted(child):
                    reasons.setdefault(key, {})[operation] = [child["value"]]
                for target, _ in targets(child):
                    predecessors.setdefault(target, set()).add(key)
    pending = [(key, operation) for key, routes in reasons.items() for operation in routes]
    while pending:
        target, operation = pending.pop()
        for key in predecessors.get(target, set()):
            if operation in reasons.setdefault(key, {}): continue
            reasons[key][operation] = [".".join(target[0] + (target[1],))] + reasons[target][operation]
            pending.append((key, operation))
    exceptions = {("ScheduleTermPickerPage", "loadAvailableTerms"): {"loadAvailableTerms", "fetchAvailableTerms"},
        ("ScheduleRootView", "startClassroomPageRefresh"): {"fetchCurrentTermOnly", "prepareTeachingCenterAccess", "fetchCampuses", "fetchBuildings", "fetchClassrooms"},
        ("TrustedTranscriptPage", "applyIfNeeded"): {"fetchTrustedTranscriptPages"}}
    for call in roots:
        name = call["value"].rsplit(".", 1)[-1].strip()
        allowed = set().union(*(operations for (owner, entry), operations in exceptions.items() if owner in call["scope"] and entry == name))
        routes = [reason for key, _ in targets(call) for operation, reason in reasons.get(key, {}).items() if operation not in allowed]
        if restricted(call) and name not in allowed or routes:
            errors.append(f"{'/'.join(call['scope'])}: 生命周期业务拉取需要明确用户操作：{call['value']}" + (" → " + " → ".join(routes[0]) if routes else ""))

    return list(dict.fromkeys(errors))


from audit_callback_rules import audit_callback_findings
from ci_wiring_rules import ci_wiring_findings, ci_trigger_shell_self_test


def audit_wiring_findings() -> list[str]:
    """检查统一静态审计入口与 CI 门禁。"""
    errors: list[str] = []
    audit_path = ROOT / "Scripts/run-static-audit.sh"
    audit_source = audit_path.read_text(encoding="utf-8")
    errors.extend(audit_callback_findings(audit_source))
    groups = re.search(r"(?ms)^group_names=\((.*?)\)(?=[ \t]*(?:\n|$))", audit_source)
    commands = re.search(r"(?ms)^group_commands=\((.*?)\)(?=[ \t]*(?:\n|$))", audit_source)
    group_names = shlex.split(groups[1], comments=True) if groups else []
    group_commands = shlex.split(commands[1], comments=True) if commands else []
    wiring = dict(zip(group_names, group_commands)) if len(group_names) == len(group_commands) else {}
    expected = {"swift-parse": "swift_parse", "shell-parse": "shell_parse", "python-parse": "python_parse",
        "worker-parse": "worker_parse", "dependency-audit": "dependency_audit", "module-boundary": "module_boundary_audit",
        "git-diff": "git_check", "docs": "docs_check", "checkers": "checker_audit"}
    if wiring != expected or len(group_names) != len(expected):
        errors.append("Scripts/run-static-audit.sh: 静态审计回调需要逐组接入完整契约")
    if "check-docs.py --all" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入文档引用检查")
    if not re.search(r"(?m)^\s*run_group\s+artifact-hygiene\s+artifact_hygiene(?:\s|$)", audit_source):
        errors.append("Scripts/run-static-audit.sh: 静态审计回调需要接入产物清理检查")
    if "npm audit --audit-level=high" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 依赖漏洞审计门槛缺失")
    if "release-network-smoke" in audit_source:
        errors.append("Scripts/run-static-audit.sh: 静态审计不得调用网络 smoke")

    workflow_path = ROOT / ".github/workflows/ci.yml"
    if not workflow_path.is_file():
        errors.append(".github/workflows/ci.yml: CI 工作流不存在")
    else:
        errors.extend(ci_wiring_findings(workflow_path.read_text(encoding="utf-8")))
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(ROOT / "BIT101-iOS.xcodeproj/project.pbxproj"),
    ], text=True))
    errors.extend(scheme_inventory_findings({path.name: path.read_text() for path in
        (ROOT / "BIT101-iOS.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme")}))
    errors.extend(extension_dependency_findings(project))
    for configuration in project["objects"].values():
        if configuration.get("isa") == "XCBuildConfiguration" and "SWIFT_COMPILATION_MODE" in configuration.get("buildSettings", {}):
            if "$(BIT101_WORKFLOW_CONDITIONS)" not in configuration["buildSettings"].get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""):
                errors.append("App 工程编译条件需要接入工作流变量")
    for name in ("run-extended-tests.sh", "run_icloud_cross_device_smoke.sh", "release-network-smoke.sh"):
        if "SWIFT_ACTIVE_COMPILATION_CONDITIONS=" in (SCRIPT_ROOT / name).read_text():
            errors.append(f"{name}: 工作流条件需要限定在 App 工程")

    test_script = ROOT / "Scripts/run-extended-tests.sh"
    if not test_script.is_file():
        errors.append("Scripts/run-extended-tests.sh: 真机测试入口不存在")
    else:
        test_source = test_script.read_text(encoding="utf-8")
        required_test_metrics = (
            ("-enableCodeCoverage YES", "真机测试未启用代码覆盖率"),
            ("ENABLE_CODE_COVERAGE=YES", "Release 测试构建未覆盖项目级关闭项"),
            ("xccov", "真机测试未提取代码覆盖率"),
            ("test-metrics.txt", "真机测试指标未写入固定报告"),
            ("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "发布测试编译需要 Swift 警告门禁"),
            ("GCC_TREAT_WARNINGS_AS_ERRORS=YES", "发布测试编译需要 Clang 警告门禁"),
            ("--enable-code-coverage", "模块测试需要生产源码覆盖率"),
            ("generic/platform=iOS", "测试编译需要通用 iOS 目的地"),
            ("extensions)", "缺少扩展共享逻辑测试分组"),
            ("ExternalScheduleInfrastructureTests", "扩展共享逻辑分组未执行对应测试套件"),
        )
        for marker, message in required_test_metrics:
            if marker not in test_source:
                errors.append(f"Scripts/run-extended-tests.sh: {message}")

    hook_path = ROOT / ".githooks/pre-commit"
    if not hook_path.is_file() or "Scripts/check-docs.py --all" not in hook_path.read_text(encoding="utf-8"):
        errors.append(".githooks/pre-commit: 提交前必须检查文档引用")
    return errors


def native_project_targets(project: dict, root: Path) -> list[tuple[str, set[str], set[Path]]]:
    objects = project["objects"]
    paths: dict[str, Path] = {}
    def visit(identifier, parent):
        item = objects[identifier]
        tree = item.get("sourceTree", "<group>")
        base = root if tree == "SOURCE_ROOT" else parent
        path = base / item.get("path", "")
        paths[identifier] = path
        for child in item.get("children", []): visit(child, path)
    visit(objects[project["rootObject"]]["mainGroup"], root)
    result = []
    for identifier, target in objects.items():
        if target.get("isa") != "PBXNativeTarget": continue
        declared = {objects[product]["productName"] for product in target.get("packageProductDependencies", [])}
        sources = set()
        for group_id in target.get("fileSystemSynchronizedGroups", []):
            group = objects[group_id]
            directory = paths.get(group_id, root / group["path"])
            excluded = {name for exception in group.get("exceptions", []) if objects[exception].get("target") == identifier
                        for name in objects[exception].get("membershipExceptions", [])}
            sources.update(path for path in directory.rglob("*.swift") if path.relative_to(directory).as_posix() not in excluded)
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            if phase.get("isa") != "PBXSourcesBuildPhase": continue
            for build_file in phase.get("files", []):
                reference = objects[build_file]["fileRef"]
                if reference not in paths: raise ValueError(f"源文件需要工程路径归属：{reference}")
                if paths[reference].suffix == ".swift": sources.add(paths[reference])
        result.append((target["name"], declared, sources))
    return result


def extension_dependency_findings(project: dict) -> list[str]:
    objects = project["objects"]
    targets = {value["name"]: key for key, value in objects.items() if value.get("isa") == "PBXNativeTarget"}
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
        if parent == "BIT101-iOS":
            for dependency in dependencies:
                edge = objects[dependency]
                if edge.get("target") == targets.get(child) and edge.get("platformFilter") != "ios":
                    errors.append(f"project.pbxproj: {child} 的 App 依赖应限定为 iOS 平台")
    return errors


def scheme_inventory_findings(schemes: dict[str, str]) -> list[str]:
    from xml.etree import ElementTree
    def signature(node):
        return (node.tag, tuple(sorted((key, value) for key, value in node.attrib.items() if key != "LastUpgradeVersion")),
                (node.text or "").strip(), tuple(signature(child) for child in node))
    errors, owners = [], {}
    for name, content in sorted(schemes.items()):
        try:
            key = signature(ElementTree.fromstring(content))
        except ElementTree.ParseError:
            errors.append(f"{name}: 共享 Scheme 需要有效 XML")
            continue
        if key in owners:
            errors.append(f"{name}: 共享 Scheme 与 {owners[key]} 的运行合同重复")
        else:
            owners[key] = name
    return errors


def cross_file_view_request_self_test() -> list[str]:
    from swift_source_index import swift_syntax_index_sources
    sources = {
        "View.swift": "enum Namespace { struct Screen: SwiftUI.View {}; struct Helper {} }",
        "Actions.swift": "extension Namespace.Screen { func load() { _ = URLRequest(url: url) } }",
        "Other.swift": "extension Namespace.Helper { func load() { _ = URLRequest(url: url) } }",
    }
    index = swift_syntax_index_sources(sources)
    for action in ('await cloud.refreshFromCloudIfNeeded()', 'await Bootstrap().start()', 'await Bootstrap.init().start()',
            'await Bootstrap.make().start()', 'await makeBootstrap().start()', 'let work = Bootstrap().start; await work()'):
        cloud = swift_syntax_index_sources({
            'App.swift': 'struct BIT101_iOSApp: App { let cloud: ScheduleCloudSyncManager; var body: some Scene { WindowGroup { Text("sample").task { ACTION } } } }'.replace('ACTION', action),
            'Bootstrap.swift': 'struct Bootstrap { let cloud: ScheduleCloudSyncManager; static func make() -> Bootstrap { Bootstrap() }; func start() async { await cloud.refreshFromCloudIfNeeded() } }; func makeBootstrap() -> Bootstrap { Bootstrap() }',
            'Cloud.swift': 'class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }'})
        if not automatic_school_fetch_findings(cloud):
            return ['代码质量规则边界自检失败：云拉取的生命周期传递调用']
    cloud['App.swift'] = swift_syntax_index_sources({'App.swift':
        'struct SampleApp: App { var body: some Scene { WindowGroup { Text("sample").task { let work = Bootstrap().start; _ = work } } } }'})['App.swift']
    if automatic_school_fetch_findings(cloud):
        return ['代码质量规则边界自检失败：待用户操作的方法引用']
    for action, invoked in (('_ = actions', False), ('await actions.start()', True)):
        stored = swift_syntax_index_sources({'App.swift':
            'class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; struct Actions { let refresh: () async -> Void; func start() async { await refresh() } }; struct SampleApp: App { let cloud: ScheduleCloudSyncManager; var body: some Scene { WindowGroup { Text("sample").task { let actions = Actions(refresh: { await cloud.refreshFromCloudIfNeeded() }); ACTION } } } }'.replace('ACTION', action)})
        if bool(automatic_school_fetch_findings(stored)) != invoked:
            return ['代码质量规则边界自检失败：成员构造器保存闭包与后续调用']
    for action, invoked in (('_ = actions', False), ('await actions.start()', True)):
        stored = swift_syntax_index_sources({'App.swift':
            'protocol ScheduleCourseServicing { func syncCourses(term: String) async }; struct Service: ScheduleCourseServicing { func syncCourses(term: String) async {} }; struct Actions { let syncCourses: (String) async -> Void; func start() async { await syncCourses("term") } }; struct SampleApp: App { let service: Service; var body: some Scene { WindowGroup { Text("sample").task { let actions = Actions(syncCourses: { await service.syncCourses(term: $0) }); ACTION } } } }'.replace('ACTION', action)})
        if bool(automatic_school_fetch_findings(stored)) != invoked:
            return ['代码质量规则边界自检失败：同名参数标签与实际执行引用']
    registered = swift_syntax_index_sources({'App.swift':
        'typealias Presenter = (_ resolve: @escaping () async -> Void) -> Void; class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; struct Bootstrap { let cloud: ScheduleCloudSyncManager; let present: Presenter; func start() { present { await cloud.refreshFromCloudIfNeeded() } } }; struct SampleApp: App { var body: some Scene { WindowGroup { Text("sample").task { Bootstrap().start() } } } }'})
    if automatic_school_fetch_findings(registered):
        return ['代码质量规则边界自检失败：交互回调的登记边界']
    for operation, executed in (('_ = action', False), ('await action()', True), ('await forward(action)', True),
            ('_ = Actions(refresh: action)', False)):
        callbacks = swift_syntax_index_sources({'App.swift':
            'class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; struct Actions { let refresh: () async -> Void }; func forward(_ action: @escaping () async -> Void) async { await action() }; struct Bootstrap { func run(action: @escaping () async -> Void) async { OPERATION } }; struct SampleApp: App { let cloud: ScheduleCloudSyncManager; var body: some Scene { WindowGroup { Text("sample").task { await Bootstrap().run(action: cloud.refreshFromCloudIfNeeded) } } } }'.replace('OPERATION', operation)})
        if bool(automatic_school_fetch_findings(callbacks)) != executed:
            return ['代码质量规则边界自检失败：回调保存、直接执行与传递执行']
    for method, restricted in (('preferences', False), ('business', True)):
        isolated = swift_syntax_index_sources({'App.swift':
            'class ExperimentalPreferenceCloudSync { func refreshFromCloudIfNeeded() async {} }; class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; struct Bootstrap { let pref: ExperimentalPreferenceCloudSync; let cloud: ScheduleCloudSyncManager; func perform(operation: @escaping () async -> Void) async { await operation() }; func preferences() async { await perform(operation: { await pref.refreshFromCloudIfNeeded() }) }; func business() async { await perform(operation: { await cloud.refreshFromCloudIfNeeded() }) } }; struct SampleApp: App { var body: some Scene { WindowGroup { Text("sample").task { await Bootstrap().METHOD() } } } }'.replace('METHOD', method)})
        if bool(automatic_school_fetch_findings(isolated)) != restricted:
            return ['代码质量规则边界自检失败：同名执行参数的调用归属']
    preference = swift_syntax_index_sources({
        'App.swift': 'struct SampleApp: App { let bootstrap: Bootstrap; var body: some Scene { WindowGroup { Text("sample").task { await bootstrap.start() } } } }',
        'Bootstrap.swift': 'struct Bootstrap { let cloud: ExperimentalPreferenceCloudSync; func start() async { await cloud.refreshFromCloudIfNeeded() } }; class ExperimentalPreferenceCloudSync { func refreshFromCloudIfNeeded() async {} }'})
    if automatic_school_fetch_findings(preference):
        return ['代码质量规则边界自检失败：已启用偏好同步的生命周期协调']
    types = declaration_conformances(index)
    if not ast_has_view_request(index["Actions.swift"], types, index) or ast_has_view_request(index["Other.swift"], types, index):
        return ["代码质量规则边界自检失败：跨文件 View 扩展与完整类型作用域"]
    for target in ("Foundation.URLRequest", "Leaf"):
        sources["Aliases.swift"] = f"private typealias Leaf = Foundation.URLRequest; typealias Request = {target}"
        sources["Actions.swift"] = "private typealias Leaf = Model; extension Namespace.Screen { func load() { _ = Request(url: url) } }"
        aliases = swift_syntax_index_sources(sources)
        if not ast_has_view_request(aliases["Actions.swift"], declaration_conformances(aliases), aliases):
            return ["代码质量规则边界自检失败：跨文件请求别名与别名声明文件归属"]
    for method in ("fetchScores", "`fetchScores`"):
        school = swift_syntax_index_sources({"School.swift": f"protocol ScoreListServicing {{ func fetchScores() async }}; struct Screen: View {{ let service: any ScoreListServicing; var body: some View {{ Text(\"sample\").task {{ await service.{method}() }} }} }}"})
        if not automatic_school_fetch_findings(school):
            return ["代码质量规则边界自检失败：生命周期学校请求的转义标识符"]
    for setup, preparation, action in (
        ("", "let refresh = service.syncCourses;", "try? await refresh()"),
        ("var refresh: () async throws -> Void { service.syncCourses };", "", "try? await refresh()"),
        ("", "", "_ = Model(service: service)"),
        ("", "", "_ = Model.init(service: service)"),
        ("", "", "let model: Model = .init(service: service); _ = model"),
    ):
        school = swift_syntax_index_sources({"School.swift": "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Model { init(service: any ScheduleCourseServicing) { Task { try? await service.syncCourses() } } }; struct Screen: View { let service: any ScheduleCourseServicing; " + setup + " var body: some View { " + preparation + " Text(\"sample\").task { " + action + " } } }"})
        if not automatic_school_fetch_findings(school):
            return ["代码质量规则边界自检失败：生命周期初始化器与方法引用调用链"]
        safe = swift_syntax_index_sources({"Safe.swift": "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Screen: View { let service: any ScheduleCourseServicing; " + setup + " var body: some View { " + preparation + " Text(\"sample\").task { _ = 1 } } }"})
        if automatic_school_fetch_findings(safe): return ["代码质量规则边界自检失败：手动调用引用作用域"]
    safe = swift_syntax_index_sources({"Safe.swift": "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Model { init(service: any ScheduleCourseServicing) { Task { try? await service.syncCourses() } } }; struct Screen: View { var body: some View { Text(\"sample\").task { let model: Model? = nil; _ = model } } }"})
    if automatic_school_fetch_findings(safe): return ["代码质量规则边界自检失败：类型声明与构造调用区分"]
    for property in ("let work = Task { try? await Service().syncCourses() }", "let work = Task { try? await Service().syncCourses() }; init() {}"):
        school = swift_syntax_index_sources({"School.swift": "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Service: ScheduleCourseServicing { func syncCourses() async throws {} }; class Model { " + property + " }; struct Screen: View { var body: some View { Text(\"sample\").task { _ = Model() } } }"})
        if not automatic_school_fetch_findings(school): return ["代码质量规则边界自检失败：构造执行实例属性初始化"]
    for construction in ("var manualRefresh: () async throws -> Void; init(service: any ScheduleCourseServicing) { manualRefresh = { try await service.syncCourses() } }", "let manualRefresh = Service().syncCourses", "let manualRefresh = { try await Service().syncCourses() }"):
        fixture = "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Service: ScheduleCourseServicing { func syncCourses() async throws {} }; class Model { " + construction + " }; struct Screen: View { var body: some View { Text(\"sample\").task { let model = Model(service: Service()); ACTION } } }"
        safe = swift_syntax_index_sources({"Safe.swift": fixture.replace("ACTION", "_ = model")})
        if automatic_school_fetch_findings(safe): return ["代码质量规则边界自检失败：构造保存手动回调"]
        invoked = swift_syntax_index_sources({"School.swift": fixture.replace("ACTION", "try? await model.manualRefresh()")})
        if not automatic_school_fetch_findings(invoked): return ["代码质量规则边界自检失败：生命周期调用已保存回调"]
    return []
