"""Production code, script and workflow quality rules."""
from __future__ import annotations

from pathlib import Path
import ast
import importlib.util
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
from swift_source_index import declaration_conformances, expected_argument_types, scope_contains_type, swift_syntax_index
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

DIRECT_DATE_FORMATTER = re.compile(
    r"\b(?:DateFormatter|ISO8601DateFormatter|RelativeDateTimeFormatter)\s*\("
)

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


def ast_has_view_request(facts: dict, type_index: dict | None = None, context: dict[str, dict] | None = None) -> bool:
    context = {"source": facts} if context is None else context
    origin = next((path for path, entry in context.items() if entry is facts), "source")
    aliases_by_file = [(path, alias) for path, entry in context.items() for alias in entry.get("typeAliases", [])]
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
            aliases = [(path, alias) for path, alias in aliases_by_file if alias["name"] == parts[-1]
                and (path == reference_file or not alias.get("isFilePrivate") and not alias.get("lexicalScope"))
                and (alias["scope"] == parts[:-1] if len(parts) > 1
                     else reference["scope"][:len(alias["scope"])] == alias["scope"])
                and reference.get("lexicalScope", [])[:len(alias.get("lexicalScope", []))] == alias.get("lexicalScope", [])]
            if not aliases: return value in {"URLRequest", "Foundation.URLRequest"}
            reference_file, reference = max(aliases, key=lambda entry: (len(entry[1]["scope"]),
                len(entry[1].get("lexicalScope", [])), entry[0] == reference_file))
            value = reference["type"]
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
    return sorted(
        path
        for source_root in SOURCE_ROOTS
        if source_root.is_dir()
        for path in source_root.rglob("*.swift")
    )


def line_number(source: str, position: int) -> int:
    return source.count("\n", 0, position) + 1


def _blank_segment(output: list[str], source: str, start: int, end: int) -> None:
    for index in range(start, min(end, len(source))):
        if source[index] != "\n":
            output[index] = " "


def mask_literals_and_comments(source: str, *, keep_comments: bool = False) -> str:
    """复用模块检查器的 Swift 词法扫描，保留插值表达式与源码位置。"""
    name = "check_module_boundaries_lexer"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, SCRIPT_ROOT / "check-module-boundaries.py")
        if spec is None or spec.loader is None:
            raise RuntimeError("Swift 词法扫描器加载失败")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name].swift_code(source, keep_comments=keep_comments)


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


def client_source_findings(path: Path, source: str, facts: dict | None = None) -> list[str]:
    if not any(path.is_relative_to(root) for root in PRODUCTION_ROOTS):
        return []
    errors: list[str] = []
    name = relative(path)
    code = mask_literals_and_comments(source)
    if name not in STDOUT_EXCEPTIONS:
        add_matches(errors, path, code, DIRECT_STDOUT_LOG, "诊断输出使用所属模块的 Logger")
    community_roots = tuple(ROOT / "Modules" / module for module in ("CourseFeature", "GalleryFeature", "PaperFeature", "MineFeature", "CommunityUI"))
    if any(path.is_relative_to(root) for root in community_roots) and is_view_source(path, code):
        add_matches(errors, path, code, DIRECT_DATE_FORMATTER, "社区日期解析统一使用 AppDateText")
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


def source_findings(syntax_index: dict[str, dict] | None = None) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    review: list[str] = []
    unsafe_concurrency_escape = re.compile(
        r"\bnonisolated\s*\(\s*unsafe\s*\)|@\s*unchecked\s+Sendable"
    )

    large_files: list[str] = []
    def unit(path):
        parts = Path(path).relative_to(ROOT).parts
        return parts[:2] if parts[0] in {"Modules", "ModuleTests"} else parts[:1]
    unit_facts: dict[tuple, dict] = {}
    for path, facts in (syntax_index or {}).items():
        unit_facts.setdefault(unit(path), {})[path] = facts
    type_indexes = {owner: declaration_conformances(facts) for owner, facts in unit_facts.items()}
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        masked_source = mask_literals_and_comments(source)
        name = relative(path)

        errors.extend(client_source_findings(path, source, syntax_index.get(str(path)) if syntax_index else None))

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
        for clause in (facts or {}).get("emptyCatchClauses", []):
            line = source.encode()[:clause["start"]].count(b"\n") + 1
            errors.append(f"{name}:{line}: 禁止静默吞掉异常；请记录诊断或显式处理错误")
        if facts and ast_has_view_request(facts, type_indexes.get(unit(path)), unit_facts.get(unit(path))):
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

    if owner_has_call(syntax_index, "BIT101_iOSApp", "refreshFromCloudIfNeeded"):
        errors.append("BIT101_iOSApp: 启动生命周期不得自动拉取 iCloud 数据")
    if owner_has_call(syntax_index, "ScheduleViewModel", "refreshFromCloudIfNeeded"):
        errors.append("ScheduleViewModel: 日程页面本地恢复不得自动拉取 iCloud")
    if owner_has_call(syntax_index, "ScoreListPage", "bootstrapIfNeeded"):
        errors.append("ScoreListPage: 成绩页不得自动触发学校查询")

    school_protocols = {"ScheduleCourseServicing", "ScheduleDDLServicing", "ScheduleClassroomServicing",
                        "ScoreListServicing", "TrustedTranscriptServicing"}
    school_operations = {function["name"] for facts in syntax_index.values()
        for function in facts.get("functionRanges", []) if school_protocols.intersection(function["scope"])}
    school_operations.update({"loadAvailableTerms", "refreshSchoolDDL"})
    functions = {}
    callable_names = {function["name"] for facts in syntax_index.values()
        for category in ("callableRanges", "functionRanges") for function in facts.get(category, [])}
    return_types = {(tuple(function["scope"]), function["name"]): function["returnType"]
        for facts in syntax_index.values() for function in facts.get("functionRanges", []) if function.get("returnType")}
    reference_paths = {id(node): path for path, facts in syntax_index.items()
        for node in facts["calls"] + facts.get("members", []) + facts.get("scopedIdentifiers", [])}
    call_ids = {id(call) for facts in syntax_index.values() for call in facts["calls"]}

    def variable_scope(path, node):
        return tuple(node["scope"]) + tuple(f"@{path}:{start}" for start in node.get("lexicalScope", []))

    aliases = [(path, alias, variable_scope(path, alias)) for path, facts in syntax_index.items()
        for alias in facts.get("typeAliases", [])]

    def canonical_type(value, scope, path):
        visited = set()
        while value not in visited:
            visited.add(value)
            value = re.sub(r"\s+", "", value.replace("any ", "")).replace("?", "").split("<", 1)[0]
            parts = value.split(".")
            matching = [(owner, alias, alias_scope) for owner, alias, alias_scope in aliases
                if alias["name"] == parts[-1]
                and (tuple(alias["scope"]) == tuple(parts[:-1]) if len(parts) > 1 else scope[:len(alias_scope)] == alias_scope)
                and (not alias.get("isFilePrivate") or owner == path)
                and (not alias.get("lexicalScope") or owner == path)]
            if not matching: return parts[-1]
            _, alias, scope = max(matching, key=lambda item: (item[0] == path, len(item[2])))
            value = alias["type"]
        return value.rsplit(".", 1)[-1]

    variable_types = {}
    for path, facts in syntax_index.items():
        for variable in facts.get("typedVariables", []):
            variable_types[(variable_scope(path, variable), variable["name"])] = variable["type"]
        for binding in facts.get("bindings", []):
            scope = variable_scope(path, binding)
            initializer = re.match(r"(\w+)\s*=\s*(?:try\??\s+)?(?:await\s+)?([A-Z]\w*)[.(]", binding["value"])
            if initializer: variable_types[(scope, initializer[1])] = initializer[2]
            returned = re.match(r"(\w+)\s*=\s*(?:try\??\s+)?(?:await\s+)?(\w+)\.(\w+)\(", binding["value"])
            if returned and ((returned[2],), returned[3]) in return_types:
                variable_types[(scope, returned[1])] = return_types[((returned[2],), returned[3])]
            decoded = re.match(r"(\w+)\s*=.*?\.decode\(\s*(\w+)\.self", binding["value"])
            if decoded: variable_types[(scope, decoded[1])] = decoded[2]

    def receiver_type(call):
        parts = call["value"].replace("?", "").split(".")[:-1]
        scope = variable_scope(reference_paths.get(id(call), ""), call)
        if parts and parts[0] == "self":
            parts.pop(0)
            scope = tuple(call["scope"])
        resolved = None
        for part in parts:
            if part == "shared" and resolved: continue
            if resolved is None and part[:1].isupper():
                resolved = part
                continue
            lookup_scopes = [scope[:length] for length in range(len(scope), -1, -1)] if resolved is None \
                else [owner for owner, field in variable_types if owner and owner[-1] == resolved and field == part]
            resolved = next((variable_types[(owner, part)] for owner in lookup_scopes if (owner, part) in variable_types), None)
            if resolved is None: return None
            resolved = canonical_type(resolved, scope, reference_paths.get(id(call), ""))
        return resolved

    roots = []
    for path, facts in syntax_index.items():
        if "Tests/" in path or "UITest" in Path(path).name or "ReleaseNetworkSmoke" in Path(path).name: continue
        assignments = [(expression["start"], expression["start"] + len(match[1].encode()))
            for expression in facts.get("expressions", [])
            if (match := re.match(r"((?:self\.)?\w+\s*)=(?!=)", expression["value"]))]
        references = [reference for reference in facts["calls"] + facts.get("members", []) + facts.get("scopedIdentifiers", [])
            if (re.fullmatch(r"(?:[\w?$]+\.)*\w+", reference["value"]) or reference["value"] == ".init")
            and not any(start <= reference["start"] < end for start, end in assignments)
            and ("." in reference["value"] or reference["value"] in callable_names
                or (variable_scope(path, reference), reference["value"]) not in variable_types)]
        for category in ("functionRanges", "callableRanges", "initializers"):
            for function in facts.get(category, []):
                key = (variable_scope(path, function), function["name"])
                functions.setdefault(function["name"], []).append((key, [reference for reference in references
                    if function["start"] <= reference["start"] < function["end"]
                    and not any(deferred["start"] <= reference["start"] < deferred["end"]
                        and deferred is not function for deferred in facts.get("callableRanges", []))]))
        for declaration in facts["declarations"]:
            if "App" in {value.rsplit(".", 1)[-1] for value in declaration["inheritedTypes"]} \
                    or declaration["name"].endswith("Lifecycle") or declaration["name"] == "ScheduleReminderBackgroundRefresh":
                scope = declaration["scope"] + [declaration["name"]]
                roots.extend(call for call in references if call["scope"][:len(scope)] == scope
                    and not any(deferred["start"] <= call["start"] < deferred["end"] for deferred in facts.get("callableRanges", [])))
        for lifecycle in facts.get("lifecycleRanges", []):
            roots.extend(reference for reference in references
                if lifecycle["start"] <= reference["start"] < lifecycle["end"]
                and not any(deferred["start"] <= reference["start"] < deferred["end"] for deferred in facts.get("callableRanges", [])))

    def targets(call):
        name = call["value"].rsplit(".", 1)[-1]
        candidates = functions.get(name, [])
        if name[:1].isupper():
            if id(call) not in call_ids: return []
            constructed = canonical_type(call["value"], variable_scope(reference_paths.get(id(call), ""), call), reference_paths.get(id(call), ""))
            return [entry for entry in functions.get("init", []) if constructed in entry[0][0]]
        receiver = receiver_type(call)
        if receiver: return [entry for entry in candidates if receiver in entry[0][0]]
        if call["value"] == ".init":
            path = reference_paths[id(call)]
            facts = syntax_index[path]
            contexts = expected_argument_types(facts, call)
            contexts.extend(match[1] for binding in facts.get("bindings", [])
                if binding["start"] <= call["start"] < binding["start"] + len(binding["value"].encode())
                and (match := re.match(r"\w+\s*:\s*([^={]+)", binding["value"])))
            owners = {canonical_type(context, variable_scope(path, call), path) for context in contexts}
            return [entry for entry in candidates if owners.intersection(entry[0][0])]
        scope = variable_scope(reference_paths.get(id(call), ""), call)
        owned = [entry for entry in candidates if scope[:len(entry[0][0])] == entry[0][0]]
        if owned: return [entry for entry in owned if len(entry[0][0]) == max(len(item[0][0]) for item in owned)]
        receiver_name = call["value"].replace("?", "").split(".")[0]
        named = [entry for entry in candidates if any(receiver_name.lower() in owner.lower() for owner in entry[0][0])]
        return named or candidates if "." in call["value"] else [entry for entry in candidates if not entry[0][0]]

    reasons = {}
    predecessors = {}
    for entries in functions.values():
        for key, children in entries:
            for child in children:
                operation = child["value"].rsplit(".", 1)[-1].strip()
                if operation in school_operations:
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
        if name in school_operations - allowed or routes:
            errors.append(f"{'/'.join(call['scope'])}: 生命周期调用链触发学校请求：{call['value']}" + (" → " + " → ".join(routes[0]) if routes else ""))

    return list(dict.fromkeys(errors))


def audit_wiring_findings() -> list[str]:
    """检查统一静态审计入口与 CI 门禁。"""
    errors: list[str] = []
    audit_path = ROOT / "Scripts/run-static-audit.sh"
    audit_source = audit_path.read_text(encoding="utf-8")
    groups = re.search(r"^group_names=\(([^\n]+)\)$", audit_source, re.MULTILINE)
    commands = re.search(r"^group_commands=\(([^\n]+)\)$", audit_source, re.MULTILINE)
    wiring = dict(zip(groups[1].split(), commands[1].split())) if groups and commands and len(groups[1].split()) == len(commands[1].split()) else {}
    expected = {"swift-parse": "swift_parse", "shell-parse": "shell_parse", "python-parse": "python_parse",
        "worker-parse": "worker_parse", "dependency-audit": "dependency_audit", "module-boundary": "module_boundary_audit",
        "git-diff": "git_check", "docs": "docs_check", "checkers": "checker_audit"}
    if wiring != expected or len(groups[1].split()) != len(expected):
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


def ci_wiring_findings(workflow_source: str) -> list[str]:
    errors: list[str] = []
    try:
        # YAML 1.1 将裸 on 识别为布尔值；保留 GitHub 工作流的事件键。
        source = re.sub(r'(?m)^on(?=\s*:)', '"on"', workflow_source)
        parsed = subprocess.run(
            ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(STDIN.read, aliases: true))"],
            input=source, capture_output=True, text=True, check=True,
        )
        workflow = json.loads(parsed.stdout)
        if not isinstance(workflow, dict): raise ValueError("工作流需要映射")
    except (OSError, subprocess.CalledProcessError, ValueError):
        return [".github/workflows/ci.yml: CI 工作流需要有效 YAML"]

    def mapping(value):
        return value if isinstance(value, dict) else {}

    events = workflow.get("on", {})
    events = {events} if isinstance(events, str) else events if isinstance(events, (list, dict)) else {}
    if not {"pull_request", "push"}.issubset(events):
        errors.append(".github/workflows/ci.yml: CI 需要 pull_request 和 push 自动触发")
    jobs = mapping(workflow.get("jobs"))
    default_shell = mapping(mapping(workflow.get("defaults")).get("run")).get("shell", "bash")

    def run_commands(job):
        commands = []
        shell = mapping(mapping(job.get("defaults")).get("run")).get("shell", default_shell)
        steps = job.get("steps", [])
        for step in steps if isinstance(steps, list) else []:
            step = mapping(step)
            if "run" not in step: continue
            if step.get("shell", shell) != "bash":
                errors.append(".github/workflows/ci.yml: CI 执行步骤需要 bash shell")
                continue
            if "if" in step or step.get("continue-on-error", False) is not False: continue
            command = step["run"]
            if isinstance(command, str): commands.append((command.strip(), step))
        return commands

    commands = {}
    for name in ("static-audit", "release-build", "catalyst-tests"):
        job = mapping(jobs.get(name))
        if not job:
            errors.append(f".github/workflows/ci.yml: CI 缺少 {name} Job")
            continue
        if "if" in job or job.get("continue-on-error", False) is not False:
            errors.append(f".github/workflows/ci.yml: {name} 需要默认执行并传播失败")
        commands[name] = run_commands(job)
        if name != "static-audit" and job.get("needs") not in ("static-audit", ["static-audit"]):
            label = "Release 编译 Job 必须依赖静态审计" if name == "release-build" else "Mac Catalyst 行为 Job 需要依赖静态审计"
            errors.append(f".github/workflows/ci.yml: {label}")
    static_commands = commands.get("static-audit", [])
    audit_index = next((index for index, (command, _) in enumerate(static_commands) if command == "Scripts/run-static-audit.sh"), -1)
    setup_index = next((index for index, (command, step) in enumerate(static_commands)
                        if command == "npm ci" and step.get("working-directory") == "Cloudflare/EmergencyUpdateWorker"), -1)
    if audit_index < 0: errors.append(".github/workflows/ci.yml: 静态审计 Job 缺少执行入口")
    if setup_index < 0 or audit_index < 0 or setup_index >= audit_index:
        errors.append(".github/workflows/ci.yml: Worker 锁定依赖需要在静态审计前安装并传播失败")
    required = {
        "static-audit": (("Scripts/run-extended-tests.sh modules", "模块行为测试需要默认执行并传播失败"),),
        "catalyst-tests": (("Scripts/run-extended-tests.sh catalyst", "Mac Catalyst 行为 Job 需要执行行为用例"),),
        "release-build": (
            ("Scripts/build-install-device.sh archive", "CI 需要正式归档编译模式验证"),
            ("Scripts/run-extended-tests.sh build release", "CI 需要通用 iOS Release 测试构建"),
            ("Scripts/run-extended-tests.sh build ui", "CI 需要 UI 宿主与测试构建"),
            ("Scripts/run-extended-tests.sh build network-smoke", "CI 需要网络 Smoke 编译条件构建"),
            ("Scripts/run-extended-tests.sh build icloud-smoke", "CI 需要 iCloud Smoke 编译条件构建"),
        ),
    }
    for name, rules in required.items():
        executed = {command for command, _ in commands.get(name, [])}
        for marker, message in rules:
            if marker not in executed: errors.append(f".github/workflows/ci.yml: {message}")
    return errors


def cross_file_view_request_self_test() -> list[str]:
    from swift_source_index import swift_syntax_index_sources
    sources = {
        "View.swift": "enum Namespace { struct Screen: SwiftUI.View {}; struct Helper {} }",
        "Actions.swift": "extension Namespace.Screen { func load() { _ = URLRequest(url: url) } }",
        "Other.swift": "extension Namespace.Helper { func load() { _ = URLRequest(url: url) } }",
    }
    index = swift_syntax_index_sources(sources)
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


def ci_trigger_shell_self_test(workflow_source: str) -> list[str]:
    source = workflow_source
    mutations = [
        re.sub(r"(?m)^  pull_request:.*\n", "", source),
        re.sub(r"(?m)^  push:\n    branches:.*\n", "", source),
        source.replace("jobs:", "defaults:\n  run:\n    shell: echo {0}\njobs:", 1),
        source.replace("    steps:", "    defaults:\n      run:\n        shell: echo {0}\n    steps:", 1),
    ]
    findings = ["代码质量规则边界自检失败：CI 自动触发与 shell 继承门禁"
                for changed in mutations if not ci_wiring_findings(changed)]
    if not ci_wiring_findings(workflow_source.replace("run: npm ci", "run: echo skipped", 1)):
        findings.append("代码质量规则边界自检失败：Worker 冷启动依赖准备")
    for command in ("Scripts/run-static-audit.sh", "Scripts/run-extended-tests.sh modules",
                    "Scripts/run-extended-tests.sh build ui", "Scripts/run-extended-tests.sh catalyst"):
        for modifier in ("if: false", "continue-on-error: true", "shell: echo {0}"):
            skipped = workflow_source.replace(f"        run: {command}", f"        {modifier}\n        run: {command}")
            if not ci_wiring_findings(skipped):
                findings.append("代码质量规则边界自检失败：CI 步骤条件与失败传播门禁")
    detached_release = workflow_source.replace("needs: static-audit", "needs: []", 1)
    if not any("必须依赖静态审计" in item for item in ci_wiring_findings(detached_release)):
        findings.append("代码质量规则边界自检失败：Release Job 与静态审计依赖识别")
    misplaced_audit = workflow_source.replace("run: Scripts/run-static-audit.sh", "run: echo skipped", 1)
    misplaced_audit += "\n# Scripts/run-static-audit.sh\n"
    if not any("静态审计 Job 缺少执行入口" in item for item in ci_wiring_findings(misplaced_audit)):
        findings.append("代码质量规则边界自检失败：CI 注释中的审计标记隔离")
    detached_catalyst = re.sub(r"(?s)(  catalyst-tests:.*?)    needs: static-audit", r"\1    needs: []", workflow_source, count=1)
    if not any("Catalyst 行为 Job 需要依赖静态审计" in item for item in ci_wiring_findings(detached_catalyst)):
        findings.append("代码质量规则边界自检失败：Catalyst Job 与静态审计依赖识别")
    skipped_catalyst = workflow_source.replace("run: Scripts/run-extended-tests.sh catalyst", "run: echo skipped", 1)
    if not any("Catalyst 行为 Job 需要执行" in item for item in ci_wiring_findings(skipped_catalyst)):
        findings.append("代码质量规则边界自检失败：并行 Catalyst 行为用例执行门禁")
    return findings


def main(shared_syntax: dict[str, dict] | None = None, boundary_findings: list[str] | None = None) -> int:
    from code_quality_tests import checker_boundary_findings
    if sys.argv[1:] == ["--swift-syntax-index"]:
        try:
            print(json.dumps(swift_syntax_index(swift_files()), ensure_ascii=False))
            return 0
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            print(f"SwiftSyntax 索引失败：{error}", file=sys.stderr)
            return 1

    if sys.argv[1:] == ["--self-test"]:
        findings = checker_boundary_findings()
        if findings:
            print("[失败] 代码质量检查器自测：", file=sys.stderr)
            print("\n".join(findings), file=sys.stderr)
            return 1
        print("[通过] 代码质量检查器自测")
        return 0

    errors: list[str] = []
    if shared_syntax is None:
        try:
            syntax_index = swift_syntax_index(swift_files())
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            syntax_index = {}
            errors.append(f"SwiftSyntax 索引失败：{error}")
    else:
        syntax_index = shared_syntax
    source_errors, review = source_findings(syntax_index or None)
    errors.extend(source_errors)
    errors.extend(checker_boundary_findings() if boundary_findings is None else boundary_findings)
    errors.extend(script_findings())
    if syntax_index:
        errors.extend(automatic_school_fetch_findings(syntax_index))
    errors.extend(audit_wiring_findings())

    report_lines = [
        "# 逐份源码质量审查",
        "",
        f"扫描 Swift 文件：{len(swift_files())} 个",
        "",
        "## 需要修复",
        *(errors or ["无"]),
        "",
        "## 人工审查候选",
        *(review or ["无"]),
        "",
    ]
    report = "\n".join(report_lines)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(report, encoding="utf-8")
    findings = [*errors, *review]
    if len(findings) <= 1000:
        if findings:
            print("\n".join(findings))
    else:
        print(f"代码质量检查共 {len(findings)} 项 · {relative(REPORT_PATH)}")

    if errors:
        return 1
    return 0




def combined_main() -> int:
    from code_quality_tests import checker_boundary_findings
    try:
        syntax_index = swift_syntax_index(swift_files())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"[失败] SwiftSyntax 索引：{error}", file=sys.stderr)
        return 1
    ui_path = SCRIPT_ROOT / "check-ui-consistency.py"
    spec = importlib.util.spec_from_file_location("check_ui_consistency", ui_path)
    if spec is None or spec.loader is None:
        print(f"[失败] UI 检查器加载：{ui_path}", file=sys.stderr)
        return 1
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    quality_boundaries = checker_boundary_findings()
    ui_boundaries = [
        *module.ast_marker_boundary_findings(),
        *module.source_boundary_findings(),
        *module.map_theme_color_contract_findings(),
    ]
    ui_status = module.main(syntax_index, ui_boundaries)
    quality_status = main(syntax_index, quality_boundaries)
    explanatory_text_report()
    return int(ui_status != 0 or quality_status != 0)
