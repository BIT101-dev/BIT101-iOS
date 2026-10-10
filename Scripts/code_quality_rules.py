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
from contextlib import contextmanager, ExitStack
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
    flags = ('BIT101_EXTENDED_TESTS_LOCK_HELD', 'BIT101_STATIC_AUDIT_LOCK_HELD')
    previous = {flag: os.environ.get(flag) for flag in flags}
    def restore():
        for flag, value in previous.items():
            if value is None: os.environ.pop(flag, None)
            else: os.environ[flag] = value
    with ExitStack() as locks:
        locks.callback(restore)
        for name, flag in zip(('.build/extended-automation.lock', '.build/static-audit/audit.lock'), flags):
            if os.environ.get(flag) == '1': continue
            path = ROOT / name
            path.parent.mkdir(parents=True, exist_ok=True)
            lock = locks.enter_context(path.open('a'))
            fcntl.flock(lock, fcntl.LOCK_EX)
            os.environ[flag] = '1'
        yield


def ast_has_identifier(facts: dict, name: str) -> bool:
    return name in facts["identifiers"]


def ast_has_view_request(facts: dict, type_index: dict | None = None, context: dict[str, dict] | None = None, *, resolver=None) -> bool:
    return ast_has_view_construction(facts, {"URLRequest", "Foundation.URLRequest"}, type_index, context, resolver=resolver)


def ast_has_view_construction(facts: dict, constructed_types: set[str], type_index: dict | None = None,
                              context: dict[str, dict] | None = None, *, resolver=None) -> bool:
    from swift_type_index import SwiftTypeIndex, SwiftBindingTypes
    if context is None:
        context, resolver = {"source": facts}, None
    origin = next((path for path, entry in context.items() if entry is facts), "source")
    resolver = resolver or SwiftTypeIndex({path: dict(entry, typeAliases=[alias for alias in entry.get('typeAliases', [])
        if not alias.get('lexicalScope')]) for path, entry in context.items()})
    call_context = SwiftBindingTypes(context, resolver)
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
        if any(canonical_type(value, call) for value in expected_argument_types(facts, call, context=call_context, path=origin)): return True
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


def view_transport_findings(index: dict) -> list[str]:
    from swift_type_index import SwiftTypeIndex, SwiftBindingTypes, receiver_resolver
    from network_capability_rules import NETWORK_TRANSPORT_TYPES, NETWORK_TRANSPORT_METHODS
    types = SwiftTypeIndex(index)
    bindings = SwiftBindingTypes(index, types)
    resolve = receiver_resolver(index)
    errors = []
    for path, facts in index.items():
        if not relative(Path(path)).startswith(('BIT101-iOS/', 'Modules/', 'BIT101ScheduleWidgets/', 'BIT101WatchWidgets/', 'BIT101Watch/')): continue
        owners = {owner for owner, bases in types.conformances(path).items()
            if any(base.rsplit('.', 1)[-1] in {'View', 'ViewModifier'} for base in bases)}
        factories = [fn for fn in facts.get('functionRanges', []) if fn.get('returnsView') and fn.get('bodyStart') is not None]
        for call in facts.get('invocations', []):
            if not scope_contains_type(call['scope'], owners) and not any(
                    fn['bodyStart'] <= call['start'] < fn['end'] for fn in factories): continue
            method = call['calledExpression'].rsplit('.', 1)[-1]
            if method not in NETWORK_TRANSPORT_METHODS: continue
            owner = resolve(dict(call, path=path))
            kind = owner or bindings.receiver_type(call, path) or ''
            target = types.resolve(path, kind, call['scope'])
            if kind.rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES or target and any(
                    base.rsplit('.', 1)[-1] == 'HTTPTransport' for base in types.bases(target)):
                line = facts['source'].encode()[:call['start']].count(b'\n') + 1
                errors.append(f'{relative(Path(path))}:{line}: 视图网络传输沿注入的业务服务执行')
    return errors


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


def file_write_calls(index: dict) -> dict[str, set[int]]:
    from swift_type_index import SwiftTypeIndex, SwiftBindingTypes, receiver_resolver
    from swift_source_index import matching_functions
    from network_capability_rules import matching_api_calls
    types, resolve = SwiftTypeIndex(index), receiver_resolver(index)
    bindings = SwiftBindingTypes(index, types)
    methods, functions, calls = {}, {}, {}
    writes = {path: set() for path in index}
    for path, facts in index.items():
        for function in facts.get('functionRanges', []):
            key = (path, function['start'])
            functions[key] = function
            owner = '.'.join(types.function_scope(path, function['scope']))
            if not function.get('lexicalScope'):
                methods.setdefault((owner, function['name']), []).append((path, function))
    edges, owners = {}, {}
    for path, facts in index.items():
        for call in facts.get('invocations', []):
            key = (path, call['start'])
            calls[key] = call
            name = call['calledExpression'].rsplit('.', 1)[-1]
            kind = bindings.receiver_type(call, path)
            kind = re.sub(r'\bany\s+|\s+', '', kind) if kind else None
            if kind is None:
                receiver_name = call['calledExpression'].rsplit('.', 1)[0]
                if receiver_name in {'FileManager.default', 'Foundation.FileManager.default'} \
                        and types.resolve(path, receiver_name.removesuffix('.default'), call['scope']) is None:
                    kind = 'Foundation.FileManager'
            owner_type = types.resolve(path, kind or '', call['scope'])
            bases = {types.terminal_name(types.paths[owner_type], base, owner_type[1][:-1])
                for base in types.bases(owner_type)} if owner_type else set()
            service = bool(({kind} | bases) & {'AppFileService', 'StorageCore.AppFileService', 'StorageCore.LocalAppFileService'})
            manager = kind in {'FileManager', 'Foundation.FileManager'}
            writer = kind in {'Data', 'String', 'NSData', 'NSMutableData', 'NSString', 'NSMutableString', 'FileWrapper',
                'NSFileWrapper', 'FileHandle', 'NSFileHandle'} or (kind or '').removeprefix('Foundation.') in {
                'Data', 'String', 'NSData', 'NSMutableData', 'NSString', 'NSMutableString', 'FileWrapper', 'NSFileWrapper', 'FileHandle', 'NSFileHandle'}
            if (service or manager) and name in {'removeItem', 'writeData', 'createDirectory', 'moveItem', 'copyItem', 'replaceItemAt'} \
                    or writer and name == 'write' and {'to', 'contentsOf'}.intersection(call.get('argumentLabels', [])):
                writes[path].add(call['start'])
            enclosing = [function for function in facts.get('functionRanges', [])
                if function.get('bodyStart') is not None and function['bodyStart'] <= call['start'] < function['end']]
            if enclosing:
                owner = max(enclosing, key=lambda function: function['start'])
                owners[key] = (path, owner['start'])
            receiver = resolve(dict(call, path=path))
            candidates = list(methods.get((receiver, name), [])) if receiver else []
            if '.' not in call['calledExpression'].removeprefix('self.'):
                candidates += [(path, function) for function in matching_functions(facts, name, call)]
                owner = '.'.join(types.function_scope(path, call['scope']))
                candidates += methods.get((owner, name), [])
            unique = {(source, function['start']): (source, function) for source, function in candidates}
            edges[key] = {(source, function['start']) for source, function in
                matching_api_calls(index, list(unique.values()), dict(call, path=path), types=types, conservative=True)}
    affected = set()
    changed = True
    while changed:
        changed = False
        for key, call in calls.items():
            if edges[key] & affected and key[1] not in writes[key[0]]:
                writes[key[0]].add(key[1]); changed = True
            owner = owners.get(key)
            if key[1] in writes[key[0]] and owner and owner not in affected:
                function = functions[owner]
                if function.get('isThrowing'):
                    affected.add(owner); changed = True
    return writes


def discarded_file_write_findings(path: Path, source: str, facts: dict, writes: dict | None = None) -> list[str]:
    if any(path.is_relative_to(ROOT / name) for name in ("BIT101-iOSTests", "BIT101-iOSUITests", "ModuleTests")): return []
    cache_paths = {ROOT / "Modules/MediaKit/Sources/RemoteImageCache.swift", ROOT / "Modules/MediaKit/Sources/CachedRemoteImage.swift"}
    if path in cache_paths: return []
    if writes is None: writes = file_write_calls({str(path): facts})
    errors = []
    for clause in facts.get("discardedOptionalTries", []):
        end = clause["start"] + len(clause["value"].encode())
        calls = [call for call in facts.get("invocations", []) if clause["start"] <= call["start"] < end]
        if any(call['start'] in writes.get(str(path), set()) for call in calls):
            line = source.encode()[:clause["start"]].count(b"\n") + 1
            errors.append(f"{path.relative_to(ROOT)}:{line}: 文件写入与删除需要处理错误或记录诊断")
    return errors


def asynchronous_test_wait_findings(path: Path, source: str, facts: dict) -> list[str]:
    name = relative(path)
    if not name.startswith(('ModuleTests/', 'BIT101-iOSTests/', 'BIT101-iOSUITests/')): return []
    helper = [row for row in facts.get('functions', []) if not row.get('scope')
        and re.search(r'\bfunc\s+waitForTestEvent\b', row['value'])]
    findings = []
    for row in facts.get('controlFlow', []):
        value = mask_literals_and_comments(row['value'])
        if not re.match(r'while\b', value) or not re.search(r'\bTask\s*\.\s*yield\s*\(', value): continue
        if name == 'ModuleTests/Support/FileServiceContract.swift' and any(
                owner['start'] <= row['start'] < owner['start'] + len(owner['value'].encode()) for owner in helper): continue
        line = source.encode()[:row['start']].count(b'\n') + 1
        findings.append(f'{name}:{line}: 异步事件等待统一沿共享 waitForTestEvent 核对取消与期限')
    for function in facts.get('functionRanges', []):
        if not function['name'].startswith(('waitFor', 'waitUntil')): continue
        if any(function['bodyStart'] <= call['start'] < function['end']
                and call['calledExpression'] in {'withCheckedContinuation', 'withCheckedThrowingContinuation'}
                for call in facts.get('invocations', [])):
            line = source.encode()[:function['start']].count(b'\n') + 1
            findings.append(f'{name}:{line}: 异步事件观察沿共享 waitForTestEvent 核对取消与期限')
    return findings


def source_findings(syntax_index: dict[str, dict] | None = None) -> tuple[list[str], list[str]]:
    errors: list[str] = view_transport_findings(syntax_index or {})
    review: list[str] = []
    writes = file_write_calls(syntax_index or {})
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
        if facts: errors.extend(asynchronous_test_wait_findings(path, source, facts))
        if facts: errors.extend(discarded_file_write_findings(path, source, facts, writes))
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
    from network_capability_rules import call_can_execute
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
    school_receivers = set(school_owners)
    while inherited := {owner for owner in types.records.keys() - school_receivers if any(
            types.resolve(types.paths[owner], base, owner[1][:-1]) in school_receivers for base in types.records[owner])}:
        school_receivers.update(inherited)
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
            if not call_can_execute(facts, call): continue
            execution_calls.setdefault((path, tuple(call["scope"]), call["value"]), []).append((facts, call))
    eager_parameters = set()

    def registered_callbacks(path, facts):
        registered, stored, executed = [], [], []
        calls = {(call["start"], call["value"]): call for call in facts["calls"]}
        for invocation in facts.get("invocations", []):
            call = calls.get((invocation["start"], invocation.get("calledExpression")))
            if call is None or not call_can_execute(facts, call): continue
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
                        and call_can_execute(facts, reference)
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
            and call_can_execute(facts, reference)
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
        if operation in school_operations:
            receiver = type_ids.get(receiver_type(call))
            scope = variable_scope(reference_paths[id(call)], call)
            return receiver in school_receivers or receiver is None and "." not in call["value"] and any(
                scope[:len(owner) + 1] == (namespace,) + owner for namespace, owner in school_receivers)
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
from ci_wiring_rules import audit_wiring_findings as ci_audit_wiring_findings, ci_trigger_shell_self_test


def audit_wiring_findings() -> list[str]:
    return ci_audit_wiring_findings(ROOT, scheme_inventory_findings, extension_dependency_findings)


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
    fixture = ('protocol ScheduleCourseServicing { func fetchCurrentTermOnly() async throws -> String }; '
        'struct Service: ScheduleCourseServicing { func fetchCurrentTermOnly() async throws -> String { "term" } }; '
        'struct CachedTermReader { func fetchCurrentTermOnly() async throws -> String { "cached" } }; '
        'struct Screen: View { @Environment(\\.scenePhase) var phase; let service: RECEIVER; '
        'var body: some View { Text("sample").MODIFIER { ACTION } } }')
    for receiver, modifier, action, expected in (
            ('Service', 'onChange(of: phase)', 'Task { try await service.fetchCurrentTermOnly() }', True),
            ('any ScheduleCourseServicing', 'onChange(of: accountID)', 'try await service.fetchCurrentTermOnly()', True),
            ('CachedTermReader', 'task', 'try await service.fetchCurrentTermOnly()', False),
            ('Service', 'task', 'if false { try await service.fetchCurrentTermOnly() }', False),
            ('Service', 'task', 'return; try await service.fetchCurrentTermOnly()', False)):
        source = fixture.replace('RECEIVER', receiver).replace('MODIFIER', modifier).replace('ACTION', action)
        if bool(automatic_school_fetch_findings(swift_syntax_index_sources({'School.swift': source}))) != expected:
            return ['代码质量规则边界自检失败：变更回调、接收者归属与不可执行分支']
    return []
