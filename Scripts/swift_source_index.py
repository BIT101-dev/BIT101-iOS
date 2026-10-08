#!/usr/bin/env python3
"""Shared SwiftSyntax source facts and the fixed, reusable compiler artifact."""
from __future__ import annotations
import fcntl
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

if not __debug__:
    raise RuntimeError("验证自测需要 Python 默认优化级别；请使用 python3 -E 执行入口。")

ROOT = Path(__file__).resolve().parents[1]




def _run_swift_syntax_index(request: dict) -> dict[str, dict]:
    swift = os.environ.get("SWIFT")
    if not swift:
        swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    swift_path = Path(swift).absolute()
    host_modules = swift_path.parent.parent / "lib/swift/host"
    if not (host_modules / "SwiftSyntax.swiftmodule").is_dir():
        raise RuntimeError(f"Xcode SwiftSyntax modules not found: {host_modules}")
    cache = ROOT / ".build/static-audit"
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "swift-syntax-indexer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source = ROOT / "Scripts/SwiftSyntaxIndexer.swift"
        (cache / "swift-syntax-indexer.swift").unlink(missing_ok=True)
        signature_file = cache / "swift-syntax-indexer-inputs.json"
        executable = cache / "swift-syntax-indexer"
        compiler = swift_path.with_name("swiftc")
        compiler_cache = ROOT / ".build/compiler-cache"
        module_cache = compiler_cache / "ModuleCache.noindex"
        module_cache.mkdir(parents=True, exist_ok=True)
        signature = hashlib.sha256(source.read_bytes() + str(compiler).encode() + str(module_cache).encode()).hexdigest()
        source_changed = not signature_file.exists() or signature_file.read_text() != signature
        toolchain_modified = max(
            compiler.stat().st_mtime_ns,
            (host_modules / "libSwiftSyntax.dylib").stat().st_mtime_ns,
            (host_modules / "libSwiftParser.dylib").stat().st_mtime_ns,
        )
        if source_changed or not executable.exists() or executable.stat().st_mtime_ns < toolchain_modified:
            executable.unlink(missing_ok=True)
            sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
            environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(module_cache))
            with (compiler_cache / "cache.lock").open("a") as compilation_lock:
                fcntl.flock(compilation_lock, fcntl.LOCK_EX)
                compilation = subprocess.run([
                    str(compiler), "-target", f"{os.uname().machine}-apple-macosx14.0", "-sdk", sdk,
                    "-module-cache-path", str(module_cache), "-warnings-as-errors",
                    "-I", str(host_modules), "-L", str(host_modules),
                    "-lSwiftSyntax", "-lSwiftParser", "-Xlinker", "-rpath", "-Xlinker", str(host_modules),
                    str(source), "-o", str(executable),
                ], capture_output=True, text=True, env=environment)
            if compilation.returncode:
                executable.unlink(missing_ok=True)
                raise RuntimeError(compilation.stderr.strip() or "SwiftSyntax indexer compilation failed")
            signature_file.write_text(signature)
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
    parse_failures = [path for path, facts in index.items() if facts["hasParseErrors"]]
    if parse_failures:
        raise RuntimeError("SwiftSyntax parse errors: " + ", ".join(parse_failures))
    conformances = declaration_conformances(index)
    test_classes = {canonical_type_scope(declaration["scope"] + [declaration["name"]])
        for facts in index.values() for declaration in facts["declarations"] if declaration["kind"] == "class"
        and any(base.rsplit(".", 1)[-1] == "XCTestCase" for base in
            conformances[canonical_type_scope(declaration["scope"] + [declaration["name"]])])}
    for facts in index.values():
        facts["tests"] = [test for test in facts["tests"] if test.get("isTestingTest")
                          or canonical_type_scope(test["scope"]) in test_classes]
    return index


def swift_syntax_index(files: list[Path]) -> dict[str, dict]:
    return _run_swift_syntax_index({"paths": [str(path) for path in files]})


def swift_syntax_index_sources(sources: dict[str, str]) -> dict[str, dict]:
    return _run_swift_syntax_index({
        "paths": [],
        "sources": [
            {"name": name, "source": source}
            for name, source in sources.items()
        ],
    })


def expected_argument_types(facts: dict, reference: dict) -> list[str]:
    parents = [(call, index) for call in facts["invocations"] if call["start"] < reference["start"]
        for index, bounds in enumerate(call.get("argumentRanges") or []) if bounds[0] <= reference["start"] < bounds[1]]
    if not parents: return []
    call, index = min(parents, key=lambda entry: len(entry[0]["value"].encode()))
    name = re.match(r"(?:\w+\.)*(\w+)\s*\(", call["value"])
    if not name: return []
    name = name[1]
    labels = call.get("argumentLabels") or []
    functions = [function for function in facts["functionRanges"] if function["name"] == name
        and call["scope"][:len(function["scope"])] == function["scope"]
        and call["lexicalScope"][:len(function["lexicalScope"])] == function["lexicalScope"]]
    functions += [function for function in facts["initializers"] if function["scope"] and function["scope"][-1] == name]
    result = []
    for function in functions:
        parameters = function["parameters"]
        if len(parameters) == len(labels) and all(parameter["label"] == label for parameter, label in zip(parameters, labels)):
            result.append(parameters[index]["type"])
    if not functions and any(declaration["name"] == name and declaration["kind"] == "struct" for declaration in facts["declarations"]):
        result += [variable["type"] for variable in facts["typedVariables"] if variable["name"] == labels[index]
            and variable["scope"] and variable["scope"][-1] == name and not variable["lexicalScope"]]
    return result


def canonical_type_scope(names: list[str]) -> tuple[str, ...]:
    return tuple(part for name in names for part in re.sub(r"\s+", "", name).split("."))


def declaration_conformances(index: dict[str, dict]) -> dict[tuple[str, ...], set[str]]:
    result: dict[tuple[str, ...], set[str]] = {}
    for facts in index.values():
        for declaration in facts.get("declarations", []):
            owner = canonical_type_scope(declaration.get("scope", []) + [declaration["name"]])
            result.setdefault(owner, set()).update(re.sub(r"\s+", "", base) for base in declaration.get("inheritedTypes", []))
        for alias in facts.get("typeAliases", []):
            owner = canonical_type_scope(alias["scope"] + [alias["name"]])
            result.setdefault(owner, set()).add(re.sub(r"\s+", "", alias["type"]))
    while True:
        changed = False
        for owner, bases in result.items():
            inherited = set(bases)
            for base in bases:
                key = canonical_type_scope([base])
                parent = next((result[owner[:depth] + key] for depth in range(len(owner) - 1, -1, -1)
                               if owner[:depth] + key in result), set())
                inherited.update(parent)
            if inherited != bases:
                result[owner] = inherited
                changed = True
        if not changed: return result


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


def visible_variables(facts: dict, reference: dict, name: str, explicit_self: bool = False) -> list[dict]:
    lexical = reference.get("lexicalScope", [])
    candidates = [variable for variable in facts["typedVariables"] if variable["name"] == name
        and canonical_type_scope(reference["scope"])[:len(canonical_type_scope(variable["scope"]))] == canonical_type_scope(variable["scope"])
        and lexical[:len(variable.get("lexicalScope", []))] == variable.get("lexicalScope", [])
        and (not variable.get("lexicalScope") or variable.get("start", 0) <= reference["start"])
        and not (explicit_self and any(function["scope"] == variable["scope"]
            and function["start"] <= variable.get("start", 0) < function["end"] for function in facts["functionRanges"]))]
    return sorted(candidates, key=lambda variable: (len(variable["scope"]), len(variable.get("lexicalScope", [])), variable.get("start", 0)))


def matching_functions(facts: dict, name: str, call: dict) -> list[dict]:
    def matches(parameters: list[dict], labels: list[str]) -> bool:
        if not parameters: return not labels
        parameter, remaining = parameters[0], parameters[1:]
        if parameter["hasDefault"] and matches(remaining, labels): return True
        if parameter["variadic"]:
            return any(matches(remaining, labels[count:]) for count in range(len(labels) + 1)
                if all(label == (parameter["label"] if index == 0 else "") for index, label in enumerate(labels[:count])))
        return bool(labels) and labels[0] == parameter["label"] and matches(remaining, labels[1:])
    return [function for function in facts["functionRanges"] if function["name"] == name
        and call["scope"][:len(function["scope"])] == function["scope"]
        and call.get("lexicalScope", [])[:len(function["lexicalScope"])] == function["lexicalScope"]
        and matches(function["parameters"], call.get("argumentLabels", []))]


def compilation_type_context(index: dict) -> tuple:
    owners = declaration_conformances(index)
    properties = {(canonical_type_scope(value["scope"]), value["name"], value["type"])
        for facts in index.values() for value in facts["typedVariables"]
        if not value.get("lexicalScope") and canonical_type_scope(value["scope"]) in owners}
    methods = {(canonical_type_scope(value["scope"]), value["name"])
        for facts in index.values() for value in facts["functionRanges"]
        if not value.get("lexicalScope") and canonical_type_scope(value["scope"]) in owners}
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
