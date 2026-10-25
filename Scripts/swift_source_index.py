#!/usr/bin/env python3
"""Shared SwiftSyntax source facts and the fixed, reusable compiler artifact."""
from __future__ import annotations
import fcntl
import json
import os
import re
import sqlite3
import subprocess
from functools import cache
from contextlib import closing
from pathlib import Path
from swift_type_index import canonical_type_scope, visible_variables, argument_parameter_bindings
from validation_policy import SWIFT_SYNTAX_SOURCE_NAMES
from ui_design_contracts import SWIFTUI_INTERACTION_KINDS

if not __debug__:
    raise RuntimeError("验证自测需要 Python 默认优化级别；请使用 python3 -E 执行入口。")

ROOT = Path(__file__).resolve().parents[1]
REGEX_RANGES_BY_SOURCE: dict[str, dict[int, int]] = {}


def repository_swift_files() -> list[Path]:
    from validation_inputs import SWIFT_ROOTS, repository_input_names
    return [ROOT / name for name in repository_input_names(ROOT)
        if Path(name).suffix == '.swift' and Path(name).parts[0] in SWIFT_ROOTS and (ROOT / name).is_file()]


@cache
def indexer_toolchain(compiler: Path, host_modules: Path) -> dict:
    from validation_environment import environment_context
    files = [compiler, *(host_modules / f"lib{module}.dylib" for module in ("SwiftSyntax", "SwiftParser", "SwiftOperators"))]
    for module in ("SwiftSyntax", "SwiftParser", "SwiftOperators"):
        files.extend(sorted((host_modules / (module + ".swiftmodule")).rglob("*")))
    artifacts = {}
    for path in files:
        if path.is_file():
            stat = path.stat()
            artifacts[str(path)] = {"size": stat.st_size, "modified": stat.st_mtime_ns}
    return {"environment": environment_context("build-modules"), "artifacts": artifacts}


@cache
def indexer_swift_path(environment: tuple[tuple[str, str], ...]) -> Path:
    return Path(subprocess.check_output(['xcrun', '--find', 'swift'], text=True).strip()).absolute()


@cache
def indexer_signature(compiler: Path, host_modules: Path, module_cache: Path, sources: tuple[tuple[str, str], ...]) -> str:
    return json.dumps({'sources': dict(sources), 'toolchain': indexer_toolchain(compiler, host_modules),
        'moduleCache': str(module_cache)}, sort_keys=True)


@cache
def source_facts_signature() -> str:
    swift = indexer_swift_path(tuple((name, os.environ.get(name, '')) for name in ('DEVELOPER_DIR', 'TOOLCHAINS', 'PATH')))
    sources = [ROOT / 'Scripts' / name for name in SWIFT_SYNTAX_SOURCE_NAMES] + [Path(__file__)]
    signature = indexer_signature(swift.with_name('swiftc'), swift.parent.parent / 'lib/swift/host',
        ROOT / '.build/compiler-cache/ModuleCache.noindex', tuple((str(path), path.read_text()) for path in sources))
    return json.dumps({'indexer': signature, 'interactionNames': sorted(SWIFTUI_INTERACTION_KINDS | {'LabeledContent'})}, sort_keys=True)


def _run_swift_syntax_index(request: dict, *, regex_only: bool = False, resolve_tests: bool = True) -> dict[str, dict]:
    request = dict(request, interactionNames=sorted(SWIFTUI_INTERACTION_KINDS | {"LabeledContent"}))
    swift_path = indexer_swift_path(tuple((name, os.environ.get(name, '')) for name in ('DEVELOPER_DIR', 'TOOLCHAINS', 'PATH')))
    host_modules = swift_path.parent.parent / "lib/swift/host"
    if not (host_modules / "SwiftSyntax.swiftmodule").is_dir():
        raise RuntimeError(f"Xcode SwiftSyntax modules not found: {host_modules}")
    cache = ROOT / ".build/compiler-cache"
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "swift-syntax-indexer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sources = [ROOT / "Scripts" / name for name in SWIFT_SYNTAX_SOURCE_NAMES]
        (cache / "swift-syntax-indexer.swift").unlink(missing_ok=True)
        signature_file = cache / "swift-syntax-indexer-inputs.json"
        executable = cache / "swift-syntax-indexer"
        compiler = swift_path.with_name("swiftc")
        compiler_cache = ROOT / ".build/compiler-cache"
        module_cache = compiler_cache / "ModuleCache.noindex"
        module_cache.mkdir(parents=True, exist_ok=True)
        signature = indexer_signature(compiler, host_modules, module_cache,
            tuple((str(source), source.read_text()) for source in [*sources, Path(__file__)]))
        source_changed = not signature_file.exists() or signature_file.read_text() != signature
        if source_changed or not executable.exists():
            executable.unlink(missing_ok=True)
            sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
            environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(module_cache))
            with (compiler_cache / "cache.lock").open("a") as compilation_lock:
                fcntl.flock(compilation_lock, fcntl.LOCK_SH)
                compilation = subprocess.run([
                    str(compiler), "-target", f"{os.uname().machine}-apple-macosx14.0", "-sdk", sdk,
                    "-j", str(os.cpu_count() or 1),
                    "-module-cache-path", str(module_cache), "-warnings-as-errors",
                    "-I", str(host_modules), "-L", str(host_modules),
                    "-lSwiftSyntax", "-lSwiftParser", "-lSwiftOperators", "-Xlinker", "-rpath", "-Xlinker", str(host_modules),
                    *(str(source) for source in sources), "-o", str(executable),
                ], capture_output=True, text=True, env=environment)
            if compilation.returncode:
                executable.unlink(missing_ok=True)
                raise RuntimeError(compilation.stderr.strip() or "SwiftSyntax indexer compilation failed")
            signature_file.write_text(signature)
        fcntl.flock(lock, fcntl.LOCK_SH)
        result = subprocess.run(
            [str(executable)],
            input=json.dumps(request),
            text=True,
            capture_output=True,
        )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "SwiftSyntax indexing failed")
    try:
        index = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"SwiftSyntax returned invalid JSON: {error}") from error
    if regex_only:
        return index
    parse_failures = [path for path, facts in index.items() if facts["hasParseErrors"]]
    if parse_failures:
        raise RuntimeError("SwiftSyntax parse errors: " + ", ".join(parse_failures))
    if resolve_tests:
        index = _materialize_facts(index)
        _resolve_tests(index)
    return index


def _materialize_facts(index: dict[str, dict]) -> dict[str, dict]:
    result = {}
    for path, facts in index.items():
        source = facts['source'].encode()
        @cache
        def text(start, end):
            return source[start:end].decode()
        def decode(value):
            if isinstance(value, list): return [decode(item) for item in value]
            if isinstance(value, dict):
                if set(value) == {'$source'}: return text(*value['$source'])
                return {key: decode(item) for key, item in value.items()}
            return value
        decoded = decode(facts)
        decoded['calls'] = [dict(value=call['calledExpression'], scope=list(call['scope']), start=call['start'],
            lexicalScope=list(call['lexicalScope']), **({'receiverCall': call['receiverCall']} if 'receiverCall' in call else {}))
            for position in decoded['calls'] for call in [decoded['invocations'][position]]]
        result[path] = decoded
    return result


def _resolve_tests(index: dict[str, dict]) -> None:
    from swift_type_index import SwiftTypeIndex
    types = SwiftTypeIndex(index)
    class_ids = {types.resolve(path, '.'.join(canonical_type_scope(declaration['scope'] + [declaration['name']])), aliases=False)
        for path, facts in index.items() for declaration in facts['declarations'] if declaration['kind'] == 'class'}
    for path, facts in index.items():
        conformances = types.conformances(path)
        test_classes = {owner for owner, bases in conformances.items()
            if types.resolve(path, '.'.join(owner), aliases=False) in class_ids
            and any(base.rsplit(".", 1)[-1] == "XCTestCase" for base in bases)}
        facts["tests"] = [test for test in facts["tests"] if test.get("isTestingTest")
                          or canonical_type_scope(test["scope"]) in test_classes]


def swift_syntax_index(files: list[Path]) -> dict[str, dict]:
    return swift_syntax_index_sources({str(path): path.read_bytes().decode("utf-8") for path in files})


def swift_syntax_index_sources(sources: dict[str, str]) -> dict[str, dict]:
    cache_name = os.environ.get('BIT101_SOURCE_FACTS_CACHE')
    if not cache_name: return _index_sources(sources)
    from validation_inputs import SWIFT_ROOTS
    eligible = {}
    for name, source in sources.items():
        path = (ROOT / name).resolve()
        parts = path.relative_to(ROOT).parts if path.is_relative_to(ROOT) else ()
        if parts and parts[0] in SWIFT_ROOTS \
                and path.is_file() and path.read_bytes().decode('utf-8') == source:
            eligible[name] = str(path)
    if not eligible: return _index_sources(sources)
    requested = {path: sources[name] for name, path in eligible.items()}
    shared = _cached_facts(Path(cache_name), requested)
    index = {name: shared[path] for name, path in eligible.items()}
    missing = {name: source for name, source in sources.items() if name not in eligible}
    if missing: index.update(_index_sources(missing, resolve_tests=False))
    index = _materialize_facts(index)
    _resolve_tests(index)
    for name, source in sources.items():
        REGEX_RANGES_BY_SOURCE[source] = character_regex_ranges(source, index[name]['regexRanges'])
    return index


def _cached_facts(cache_path: Path, requested: dict[str, str]) -> dict:
    """Decode private facts for the requested files from the shared audit database."""
    with cache_path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with closing(sqlite3.connect(cache_path)) as database, database:
            database.execute('CREATE TABLE IF NOT EXISTS facts (path TEXT PRIMARY KEY, content TEXT)')
            database.execute('CREATE TABLE IF NOT EXISTS metadata (name TEXT PRIMARY KEY, value TEXT NOT NULL)')
            signature = source_facts_signature()
            previous = database.execute("SELECT value FROM metadata WHERE name = 'indexer'").fetchone()
            reclaim = previous is not None and previous[0] != signature
            if previous is None or previous[0] != signature:
                database.execute('DELETE FROM facts')
                database.execute("INSERT OR REPLACE INTO metadata VALUES ('indexer', ?)", (signature,))
            obsolete = [(path,) for path, in database.execute('SELECT path FROM facts') if not Path(path).is_file()]
            database.executemany('DELETE FROM facts WHERE path = ?', obsolete)
            shared = {}
            for path, source in requested.items():
                row = database.execute('SELECT content FROM facts WHERE path = ?', (path,)).fetchone()
                if row:
                    facts = json.loads(row[0])
                    if facts.get('source') == source: shared[path] = facts
            missing = {path: source for path, source in requested.items() if path not in shared}
            if missing:
                parsed = _index_sources(missing, resolve_tests=False)
                database.executemany('INSERT OR REPLACE INTO facts VALUES (?, ?)',
                    ((path, json.dumps(facts, ensure_ascii=False, separators=(',', ':'))) for path, facts in parsed.items()))
                shared.update(parsed)
            if reclaim:
                database.commit()
                database.execute('VACUUM')
            return shared


def _index_sources(sources: dict[str, str], *, resolve_tests: bool = True) -> dict[str, dict]:
    index = _run_swift_syntax_index({
        "paths": [],
        "sources": [
            {"name": name, "source": source}
            for name, source in sources.items()
        ],
    }, resolve_tests=resolve_tests)
    for name, source in sources.items():
        index[name]["source"] = source
        REGEX_RANGES_BY_SOURCE[source] = character_regex_ranges(source, index[name]["regexRanges"])
    return index


def character_regex_ranges(source: str, rows: list[dict]) -> dict[int, int]:
    encoded = source.encode()
    return {len(encoded[:row["start"]].decode()): len(encoded[:row["end"]].decode()) for row in rows}


@cache
def swift_regex_ranges(source: str) -> dict[int, int]:
    """Read literal boundaries from SwiftParser, including incomplete source fragments."""
    if "/" not in source: return {}
    if source in REGEX_RANGES_BY_SOURCE: return REGEX_RANGES_BY_SOURCE[source]
    facts = _run_swift_syntax_index({"paths": [], "sources": [{"name": "regex-source", "source": source}]}, regex_only=True)
    return character_regex_ranges(source, facts["regex-source"]["regexRanges"])


@cache
def swift_code(source: str, keep_comments: bool = False, keep_literals: bool = False) -> str:
    """Retain executable Swift, including interpolation, with stable positions."""
    result = ["\n" if char == "\n" else " " for char in source]
    string_start = re.compile(r'(#{0,})("""|")')
    regex_ranges = REGEX_RANGES_BY_SOURCE.get(source)
    regex_start = re.compile(r'#+/')

    def code(index: int, interpolation: bool = False) -> int:
        nonlocal regex_ranges
        depth = 1
        while index < len(source):
            if regex_ranges is None and (source[index] == '/' and not source.startswith(('//', '/*'), index)
                    or source[index] == '#' and regex_start.match(source, index)):
                regex_ranges = swift_regex_ranges(source)
            if regex_ranges and index in regex_ranges:
                end = regex_ranges[index]
                if keep_literals: result[index:end] = source[index:end]
                index = end
                continue
            if source.startswith("//", index):
                end = source.find("\n", index)
                end = len(source) if end < 0 else end
                if keep_comments: result[index:end] = source[index:end]
                index = end
                continue
            if source.startswith("/*", index):
                start = index
                nesting = 1
                index += 2
                while index < len(source) and nesting:
                    if source.startswith("/*", index):
                        nesting += 1
                        index += 2
                    elif source.startswith("*/", index):
                        nesting -= 1
                        index += 2
                    else:
                        index += 1
                if keep_comments: result[start:index] = source[start:index]
                continue
            match = string_start.match(source, index)
            if match:
                hashes, quotes = match.groups()
                if keep_literals: result[index:index + len(match[0])] = source[index:index + len(match[0])]
                index += len(match[0])
                closing = quotes + hashes
                escape = "\\" + hashes
                while index < len(source):
                    if source.startswith(escape + "(", index):
                        if keep_literals: result[index:index + len(escape) + 1] = source[index:index + len(escape) + 1]
                        index = code(index + len(escape) + 1, interpolation=True)
                    elif source.startswith(escape, index):
                        end = min(len(source), index + len(escape) + 1)
                        if keep_literals: result[index:end] = source[index:end]
                        index = end
                    elif source.startswith(closing, index):
                        if keep_literals: result[index:index + len(closing)] = source[index:index + len(closing)]
                        index += len(closing)
                        break
                    else:
                        if keep_literals: result[index] = source[index]
                        index += 1
                continue
            if interpolation:
                if source[index] == "(":
                    depth += 1
                elif source[index] == ")":
                    depth -= 1
                    if depth == 0:
                        if keep_literals: result[index] = source[index]
                        return index + 1
            result[index] = " " if source[index] == "`" else source[index]
            index += 1
        return index

    code(0)
    return "".join(result)


def expected_argument_types(facts: dict, reference: dict, *, context=None, path: str = 'source') -> list[str]:
    parents = [(call, index) for call in facts["invocations"] if call["start"] < reference["start"]
        for index, bounds in enumerate(call.get("argumentRanges") or []) if bounds[0] <= reference["start"] < bounds[1]]
    if not parents: return []
    call, index = min(parents, key=lambda entry: len(entry[0]["value"].encode()))
    from swift_type_index import SwiftBindingTypes
    context = context or SwiftBindingTypes({path: facts})
    types = context.types
    expression = call.get('calledExpression') or call['value'].split('(', 1)[0].strip()
    name = expression.rsplit('.', 1)[-1]
    labels = call.get("argumentLabels") or []
    constructed = types.resolve(path, expression.removesuffix('.init'), call['scope'])
    receiver = expression.rsplit('.', 1)[0] if '.' in expression else ''
    if receiver in {'self', 'Self'}:
        owner = types.resolve(path, '.'.join(call['scope']), aliases=False)
    else:
        kind = context.receiver_type(call, path)
        owner = types.resolve(path, kind or '', call['scope'])
    owners = {owner} if owner else set()
    if owner:
        owners.update(base for name in types.bases(owner)
            if (base := types.resolve(types.paths[owner], name, owner[1][:-1])))
    functions = []
    for source, entries in context.index.items():
        for function in entries.get('initializers' if constructed else 'functionRanges', []):
            if source != path and function.get('isPrivate'): continue
            scope = types.function_scope(source, function['scope'])
            if constructed:
                matched = scope == (constructed[0],) + constructed[1]
            elif receiver or call.get('receiverCall'):
                matched = function['name'] == name and any(scope == (key[0],) + key[1] for key in owners)
            else:
                matched = function['name'] == name and types.units[source] == types.units[path] \
                    and call['scope'][:len(function['scope'])] == function['scope'] \
                    and (not function.get('lexicalScope') or source == path
                        and call['lexicalScope'][:len(function['lexicalScope'])] == function['lexicalScope'])
            if matched: functions.append((source, function))
    result = []
    for source, function in functions:
        for binding in argument_parameter_bindings(function["parameters"], labels):
            result.append(types.terminal_name(source, binding[index]['type'], function['scope']))
    if constructed and not functions:
        result += [variable['type'] for source, entries in context.index.items() for variable in entries.get('typedVariables', [])
            if variable['name'] == labels[index] and not variable['lexicalScope']
            and types.function_scope(source, variable['scope']) == (constructed[0],) + constructed[1]]
    return result


def declaration_conformances(index: dict[str, dict], path: str | None = None) -> dict[tuple[str, ...], set[str]]:
    from swift_type_index import SwiftTypeIndex
    types = SwiftTypeIndex(index)
    if path is not None: return types.conformances(path)
    if len(set(types.units.values())) == 1: return types.conformances(next(iter(index))) if index else {}
    return types.all_conformances()


def scope_contains_type(scope: list[str], owners) -> bool:
    parts = canonical_type_scope(scope)
    return any(parts[:len(owner)] == owner for owner in owners)


def resource_context_type(value: str, resource: str = "UserDefaults") -> bool:
    value = re.sub(r"\s+|@(?:Sendable|MainActor)\b", "", value).rstrip("?!").removeprefix("Swift.")
    for wrapper in ("Optional", "Array"):
        if value.startswith(wrapper + "<") and value.endswith(">"):
            return resource_context_type(value[len(wrapper) + 1:-1], resource)
    if value.startswith("[") and value.endswith("]"):
        return resource_context_type(value[1:-1].rsplit(":", 1)[-1], resource)
    if value.startswith("Dictionary<") and value.endswith(">"):
        return resource_context_type(value[len("Dictionary<"):-1].rsplit(",", 1)[-1], resource)
    if "->" in value: return resource_context_type(value.rsplit("->", 1)[-1].strip("()"), resource)
    return value.removeprefix("Foundation.").removeprefix("StorageCore.") == resource


def matching_functions(facts: dict, name: str, call: dict) -> list[dict]:
    return [function for function in facts["functionRanges"] if function["name"] == name
        and call["scope"][:len(function["scope"])] == function["scope"]
        and call.get("lexicalScope", [])[:len(function["lexicalScope"])] == function["lexicalScope"]
        and argument_parameter_bindings(function["parameters"], call.get("argumentLabels", []))]


def compilation_type_context(index: dict, path: str | None = None) -> tuple:
    from swift_type_index import SwiftTypeIndex
    types = SwiftTypeIndex(index)
    path = path or next(iter(index), '')
    owners = types.conformances(path) if path else {}
    def visible(source, value):
        name = '.'.join(value['scope'])
        return types.resolve(source, name, aliases=False) == types.resolve(path, name, aliases=False)
    properties = {(canonical_type_scope(value["scope"]), value["name"], value["type"])
        for source, facts in index.items() for value in facts["typedVariables"]
        if not value.get("lexicalScope") and canonical_type_scope(value["scope"]) in owners and visible(source, value)}
    methods = {(canonical_type_scope(value["scope"]), value["name"])
        for source, facts in index.items() for value in facts["functionRanges"]
        if not value.get("lexicalScope") and canonical_type_scope(value["scope"]) in owners and visible(source, value)}
    for owner, bases in owners.items():
        for base in bases:
            target = next((owner[:depth] + canonical_type_scope([base]) for depth in range(len(owner) - 1, -1, -1)
                if owner[:depth] + canonical_type_scope([base]) in owners), ())
            properties.update((owner, name, kind) for scope, name, kind in list(properties) if scope == target)
            methods.update((owner, name) for scope, name in list(methods) if scope == target)
    return tuple(sorted(properties)), tuple(sorted(methods))


def local_member_calls(source: str, names: tuple, context: tuple = ((), ())) -> set[int]:
    facts = swift_syntax_index_sources({"local-methods": source})["local-methods"]
    own_context = compilation_type_context({"local-methods": facts})
    methods = set(context[1]) | set(own_context[1])
    properties = set(context[0]) | set(own_context[0])
    result = set()
    for call in facts["invocations"]:
        match = re.match(r"(.+?)(\.\s*`?(" + "|".join(names) + r")`?\s*\()", call["value"], re.DOTALL)
        if not match: continue
        receiver = re.sub(r"^(?:try[!?]?\s+|await\s+)+", "", match[1].strip()).rstrip("?!")
        owner = canonical_type_scope(call["scope"])
        kind = None
        if receiver == "self": kind = ".".join(owner)
        elif constructor := re.fullmatch(r"([\w.]+)\s*\(.*\)", receiver, re.DOTALL): kind = constructor[1]
        elif variable := re.fullmatch(r"(?:self\.)?(\w+)", receiver):
            visible = visible_variables(facts, call, variable[1], receiver.startswith("self."))
            if visible: kind = visible[-1]["type"]
            if kind is None:
                for binding in facts["bindings"]:
                    value = re.match(re.escape(variable[1]) + r"\s*=\s*([\w.]+)\s*\(", binding["value"])
                    if value and binding["start"] < call["start"] and binding["scope"] == call["scope"] \
                        and call.get("lexicalScope", [])[:len(binding.get("lexicalScope", []))] == binding.get("lexicalScope", []): kind = value[1]
            if kind is None: kind = next((kind for scope, name, kind in properties if scope == owner and name == variable[1]), None)
        if kind is None: continue
        kind = canonical_type_scope([kind.rstrip("?!")])
        if any((owner[:depth] + kind, match[3]) in methods for depth in range(len(owner), -1, -1)):
            result.add(call["start"] + len(call["value"][:match.start(2)].encode()))
    return result
