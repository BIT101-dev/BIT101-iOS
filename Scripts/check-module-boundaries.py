#!/usr/bin/env python3
"""Validate the local Swift Package source roots and direct dependency graph."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from functools import cache
from pathlib import Path

sys.dont_write_bytecode = True
from swift_source_index import canonical_type_scope, declaration_conformances, scope_contains_type, expected_argument_types, swift_syntax_index, swift_syntax_index_sources, resource_context_type, visible_variables, matching_functions, compilation_type_context, local_member_calls, swift_code
from validation_policy import coverage_registry_findings


IGNORED_IMPORTS = {
    "Foundation",
    "Observation",
    "ActivityKit",
    "os",
    "Testing",
    "SwiftUI",
    "Combine",
    "Charts",
    "CryptoKit",
    "Compression",
    "CoreFoundation",
    "CoreGraphics",
    "CoreLocation",
    "ImageIO",
    "MapKit",
    "Network",
    "OSLog",
    "PhotosUI",
    "QuickLook",
    "Security",
    "UIKit",
    "UniformTypeIdentifiers",
    "WatchConnectivity",
    "WebKit",
    "WidgetKit",
}


def manifest_targets(package: dict) -> dict[str, dict]:
    """Consume SwiftPM's evaluated manifest, including computed and conditional declarations."""
    targets = {}
    for target in package["targets"]:
        name = target["name"]
        path = target.get("path")
        if not isinstance(path, str):
            raise ValueError(f"{name} requires an explicit source path")
        dependencies = set()
        for dependency in target["dependencies"]:
            value = dependency.get("byName") or dependency.get("target")
            if not value or not isinstance(value[0], str):
                raise ValueError(f"{name} requires local target dependencies: {dependency}")
            dependencies.add(value[0])
        if name in targets:
            raise ValueError(f"duplicate target: {name}")
        targets[name] = {"path": path, "type": target["type"], "dependencies": dependencies}
    return targets


def read_manifest(root: Path) -> dict:
    environment = dict(os.environ)
    environment["CLANG_MODULE_CACHE_PATH"] = str(root / ".build/compiler-cache/ModuleCache.noindex")
    result = subprocess.run([
        "xcrun", "swift", "package", "--package-path", str(root),
        "--scratch-path", str(root / ".build/extended-automation"), "dump-package",
    ], capture_output=True, text=True, env=environment)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "SwiftPM manifest evaluation failed")
    return json.loads(result.stdout)


def imported_modules(source_root: Path) -> dict[str, set[str]]:
    imports: dict[str, set[str]] = {}
    for source in sorted(source_root.rglob("*.swift")):
        for imported in imports_in_text(source.read_text(encoding="utf-8")):
            imports.setdefault(imported, set()).add(str(source))
    return imports




def raw_imports(source: str) -> set[str]:
    pattern = r"(?:^|;)\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|fileprivate|private|package)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z0-9_]+)"
    return set(re.findall(pattern, swift_code(source), re.MULTILINE))


def imports_in_text(source: str) -> set[str]:
    return raw_imports(source) - IGNORED_IMPORTS


LAYERS = {
    "Core": {"Core"},
    "Transport": {"Core", "Transport"},
    "Kit": {"Core", "Kit"},
    "UI": {"Core", "Kit", "UI"},
    "Contracts": {"Core", "Contracts"},
    "Domain": {"Core", "Contracts", "Domain"},
    "Ports": {"Core", "Contracts", "Domain", "Ports"},
    "Persistence": {"Core", "Contracts", "Domain", "Persistence"},
    "SharedStore": {"Core", "Contracts"},
    "Infrastructure": {"Core", "Transport", "Contracts", "Domain", "Ports", "Infrastructure"},
    "Sync": {"Core", "Contracts", "Domain", "Persistence", "Ports"},
    "Feature": {"Core", "Transport", "Kit", "UI", "Contracts", "Domain", "Ports"},
}


def layer(module: str) -> str | None:
    return next((name for name in LAYERS if module.endswith(name)), None)


FOUNDATIONAL_IMPORTS = {"Foundation", "Combine", "Observation", "CryptoKit", "Compression", "OSLog", "os", "CoreFoundation"}
PLATFORM_EXCEPTIONS = {"ScheduleActivityContracts": {"ActivityKit"}, "TransportCore": {"Network"}}
SHARED_MODULES = {"ClientCore", "StorageCore", "TransportCore", "DesignSystemKit", "MediaKit"}
CROSS_BUSINESS_CONTRACTS = {("MapFeature", "ScheduleContracts")}


def business_family(module: str) -> str:
    name = module.removesuffix(layer(module) or "")
    if name.startswith("Schedule"): return "Schedule"
    return "Community" if name in {"Community", "Gallery", "Course", "Paper", "Mine"} else name


def platform_errors(module: str, imports: set[str]) -> list[str]:
    if layer(module) in {"Core", "Transport", "Contracts", "Domain", "Ports", "Persistence", "SharedStore", "Infrastructure", "Sync"}:
        forbidden = (imports & IGNORED_IMPORTS) - FOUNDATIONAL_IMPORTS - PLATFORM_EXCEPTIONS.get(module, set())
        return [f"platform boundary: {module} imports {name}" for name in sorted(forbidden)]
    return []


def graph_errors(manifest: dict[str, set[str]]) -> list[str]:
    errors: list[str] = []
    visited: set[str] = set()

    def visit(module: str, path: tuple[str, ...]) -> None:
        if module in path:
            errors.append(f"dependency cycle: {' -> '.join((*path, module))}")
            return
        if module in visited:
            return
        for dependency in sorted(manifest.get(module, set())):
            visit(dependency, (*path, module))
        visited.add(module)

    for module, dependencies in manifest.items():
        if layer(module) is None:
            errors.append(f"{module} requires a declared architectural layer suffix")
        visit(module, ())
        for dependency in dependencies:
            source_layer, dependency_layer = layer(module), layer(dependency)
            if dependency not in manifest:
                errors.append(f"unknown dependency: {module} -> {dependency}")
            if source_layer and dependency_layer and dependency_layer not in LAYERS[source_layer]:
                errors.append(f"{source_layer.lower()} boundary: {module} -> {dependency}")
            if source_layer and dependency_layer and dependency not in SHARED_MODULES \
                    and business_family(module) != business_family(dependency) \
                    and (module, dependency) not in CROSS_BUSINESS_CONTRACTS:
                errors.append(f"business domain boundary: {module} -> {dependency}")
    return errors


GLOBAL_RESOURCE_PATTERN = r"\b(?:UserDefaults\s*\.\s*standard|URLSession\s*\.\s*shared|URLCache\s*\.\s*shared|HTTPCookieStorage\s*\.\s*shared|FileManager\s*\.\s*default|UIApplication\s*\.\s*shared|UIScreen\s*\.\s*main)\b"


def type_aliases(index: dict) -> tuple:
    root = Path(__file__).resolve().parents[1]
    return tuple((alias["name"], alias["type"], tuple(alias["scope"]), tuple(alias.get("lexicalScope", [])),
                  str(Path(path).relative_to(root)) if Path(path).is_absolute() else path, alias["start"],
                  alias.get("isFilePrivate", False), alias.get("isExported", False))
        for path, facts in index.items() for alias in facts.get("typeAliases", []))


def alias_module(path: str) -> str:
    parts = Path(path).parts
    return parts[1] if len(parts) > 1 and parts[0] == "Modules" else parts[0] if len(parts) > 1 else ""


def imported_aliases(source: str, local: tuple, modules: tuple) -> tuple:
    imports = raw_imports(source)
    return local + tuple(alias for alias in modules if alias_module(alias[4]) in imports)


@cache
def expanded_resource_source(source: str, aliases: tuple = (), path: str = "resource-source") -> str:
    code = swift_code(source)
    if "typealias" not in code and not any(re.search(r"\b" + re.escape(alias[0]) + r"\b", code) for alias in aliases):
        return source
    facts = swift_syntax_index_sources({path: source})[path]
    aliases = tuple(dict.fromkeys(aliases + type_aliases({path: facts})))

    def lookup(name, scope, lexical, owner_path):
        qualified = name.split(".")
        candidates = []
        for alias in aliases:
            components = qualified[1:] if len(qualified) > 1 and qualified[0] == alias_module(alias[4]) else qualified
            if alias[0] == components[-1] and (alias[2] == tuple(components[:-1]) if len(components) > 1 else scope[:len(alias[2])] == alias[2]) \
                    and (not alias[6] or alias[4] == owner_path) \
                    and (alias[7] or alias_module(alias[4]) == alias_module(owner_path)) \
                    and (not alias[3] or alias[4] == owner_path and lexical[:len(alias[3])] == alias[3]):
                candidates.append(alias)
        return max(candidates, key=lambda alias: (alias_module(alias[4]) == alias_module(owner_path), len(alias[2]), len(alias[3])), default=None)

    def resolve(alias, visited=()):
        if alias in visited: return alias[0]
        value = re.sub(r"\s+", "", alias[1])
        if not re.fullmatch(r"[\w.]+\??", value): return alias[0]
        target = lookup(value.removesuffix("?"), alias[2], alias[3], alias[4])
        return (resolve(target, visited + (alias,)) if target else value.removesuffix("?")) + ("?" if value.endswith("?") else "")

    encoded = source.encode()
    replacements = []
    alias_names = {alias[0] for alias in aliases}
    declaration_positions = {alias[5] for alias in aliases if alias[4] == path}
    type_positions = {node["start"] for node in facts["typeNames"]}
    bindings = [(binding, name[1]) for binding in facts["bindings"]
        if (name := re.match(r"(\w+)\s*(?::[^=]+)?=", swift_code(binding["value"])))]
    bindings.extend((variable, variable["name"]) for variable in facts["typedVariables"])
    for node in facts["scopedIdentifiers"]:
        if node["value"] not in alias_names or node["start"] in declaration_positions: continue
        start = node["start"]
        prefix = swift_code(encoded[:start].decode())
        qualifier = re.search(r"(?:\b\w+\s*\.\s*)+$", prefix)
        if not qualifier and (any(declaration["name"] == node["value"]
            and node["scope"][:len(declaration["scope"])] == declaration["scope"] for declaration in facts["declarations"])
            or node["start"] not in type_positions and any(name == node["value"]
                and binding["start"] <= start and node["scope"][:len(binding["scope"])] == binding["scope"]
                and node.get("lexicalScope", [])[:len(binding.get("lexicalScope", []))] == binding.get("lexicalScope", [])
                for binding, name in bindings)): continue
        name = re.sub(r"\s+", "", qualifier[0]) + node["value"] if qualifier else node["value"]
        alias = lookup(name, tuple(node["scope"]), tuple(node.get("lexicalScope", [])), path)
        if alias and (replacement := resolve(alias)) != alias[0]:
            begin = len(encoded[:start].decode()[:qualifier.start()].encode()) if qualifier else start
            replacements.append((begin, start + len(node["value"].encode()), replacement.encode()))
    for start, end, replacement in sorted(replacements, reverse=True):
        encoded = encoded[:start] + replacement + encoded[end:]
    return encoded.decode()


def service_boundary_errors(path: str, source: str, aliases: tuple = (), context: tuple = ((), ())) -> list[str]:
    """Enforce service ownership across production modules, app, and extensions."""
    source = normalized_resource_source(expanded_resource_source(source, aliases, path))
    code = swift_code(source)
    patterns: list[tuple[str, str]] = []
    transport_sources = {
        "Modules/TransportCore/Sources/HTTPClient.swift",
        "Modules/TransportCore/Sources/SecureURLTransport.swift",
    }
    if path not in transport_sources:
        patterns.append((r"\b(?:URLSession|URLCache)\b", "use TransportCore transport and cache services"))
        patterns.append((r"\b(?:CFSocket\w*|CFStreamCreatePairWith(?:Socket|PeerSocketSignature)\w*)\b", "use TransportCore network services"))
    if path.startswith("Modules/") and not path.startswith("Modules/TransportCore/"):
        patterns.append((r"\bURLSessionTransport\s*\.\s*(?:make|clearSharedCache)\b", "inject host-selected transport resources"))
    if path.startswith("Modules/") and not path.startswith("Modules/StorageCore/"):
        patterns.append((r"\bLocalAppFileService\s*(?:\(|\.\s*init\b)", "inject host-selected file resources"))
    if path != "Modules/TransportCore/Sources/HTTPClient.swift":
        patterns.append((r"\.\s*(?:data|download|upload|bytes)\s*\(\s*for\s*:", "send requests through HTTPClient"))
        patterns.append((r"\.\s*(?:dataTask|downloadTask|uploadTask|webSocketTask)\s*\(", "send requests through HTTPClient"))
    if path not in {"Modules/TransportCore/Sources/NetworkPathState.swift", "BIT101-iOS/Login/AppUITestBootstrap.swift"}:
        patterns.append((r"\b(?:NWPathMonitor|NWConnection|NWConnectionGroup|NWListener|NWTCPConnection|NWUDPSession)\b", "use TransportCore network services"))
    if path != "Modules/TransportCore/Sources/TaskCancellation.swift":
        patterns.append((r"\.\s*userInfo\s*\[\s*NSUnderlyingErrorKey\s*\]", "traverse underlying errors through ErrorChain"))
    if path != "Modules/TransportCore/Sources/AppURL.swift":
        patterns.append((r"\bCharacterSet\s*\.\s*urlQueryAllowed\b", "encode form fields through HTTPFormEncoding"))
    if path.startswith("Modules/ScheduleFeature/"):
        patterns.append((r"\bDateFormatter\s*\(", "format schedule dates through ScheduleDateCodec"))
    if path != "Modules/StorageCore/Sources/AppFileService.swift":
        patterns.extend((
            (r"\b(?:DispatchIO|CF(?:Read|Write)StreamCreateWithFile)\b", "read and write files through AppFileService"),
            (r"\bFileManager\b(?!\s*\.\s*(?:SearchPathDirectory|DirectoryEnumerationOptions)\b)", "use AppFileService"),
            (r"\b(?:Data|NSData|NSMutableData|String|NSString|NSMutableString)\s*(?:\.\s*init\s*)?\(\s*(?:contentsOf|contentsOfFile|contentsOfURL)\s*:", "read files through AppFileService"),
            (r"\.\s*(?:resourceValues|setResourceValues|getResourceValue|setResourceValue|resolvingSymlinksInPath|checkResourceIsReachable)\s*\(", "access file metadata through AppFileService"),
            (r"\b(?:FileHandle|NSFileHandle)\b(?!\s*\.\s*standard(?:Output|Error)\b)|\b(?:NSFileCoordinator|CGImageSourceCreateWithURL|CGImageDestinationCreateWithURL)\b", "access files through AppFileService"),
            (r"\b(?:FileWrapper|NSFileWrapper)\s*(?:\.\s*init\s*)?\(\s*(?:url|path)\s*:", "access files through AppFileService"),
            (r"\b(?:UIImage|NSImage|InputStream|OutputStream)\s*(?:\.\s*init\s*)?\(\s*(?:contentsOfFile|contentsOf|url|fileAtPath|toFileAtPath)\s*:", "access files through AppFileService"),
        ))
    if path != "BIT101-iOS/Shared/Client/AppFileDirectories.swift":
        patterns.append((r"\bUserDefaults\s*\.\s*standard\b|\bUserDefaults\s*=\s*\.\s*standard\b|\bUserDefaults\s*(?:\(|\.\s*init\b)", "select preferences through the host storage entry"))
    errors = []
    if path not in transport_sources:
        errors.extend(f"service boundary: {path}:{line}: use TransportCore network services"
            for line in implicit_file_accesses(source, POSIX_NETWORK_FUNCTIONS))
    if path.startswith("Modules/") and not path.startswith("Modules/StorageCore/"):
        errors.extend(f"service boundary: {path}:{line}: inject host-selected file resources"
            for line in implicit_resource_accesses(source, "LocalAppFileService", context[0]))
    if path != "Modules/StorageCore/Sources/AppFileService.swift":
        errors.extend(f"service boundary: {path}:{line}: access files through AppFileService"
            for line in implicit_file_accesses(source))
        errors.extend(f"service boundary: {path}:{line}: access files through AppFileService"
            for line in file_member_accesses(source, properties=context[0]))
    if path != "BIT101-iOS/Shared/Client/AppFileDirectories.swift":
        errors.extend(f"service boundary: {path}:{line}: select preferences through the host storage entry: UserDefaults"
            for line in implicit_resource_accesses(source, properties=context[0]))
    local_calls = local_member_calls(source, ("data", "download", "upload", "bytes", "dataTask", "downloadTask", "uploadTask", "webSocketTask"), context) if re.search(r"\.\s*(?:data|download|upload|bytes|dataTask|downloadTask|uploadTask|webSocketTask)\s*\(", code) else set()
    for pattern, rule in patterns:
        for match in re.finditer(pattern, code):
            if rule == "send requests through HTTPClient" and len(source[:match.start()].encode()) in local_calls: continue
            line = code.count("\n", 0, match.start()) + 1
            errors.append(f"service boundary: {path}:{line}: {rule}: {match[0].strip()}")
    return errors


POSIX_FILE_FUNCTIONS = r"open|openat|creat|close|read|pread|readv|write|pwrite|writev|lseek|fopen|freopen|fread|fwrite|fclose|rename|remove|unlink|mkdir|rmdir|stat|lstat|fstat|truncate|ftruncate|fsync|fdatasync|access|opendir|readdir|closedir|mmap|munmap|readlink|readlinkat|symlink|symlinkat|link|linkat|renameat|unlinkat|mkdirat|fstatat|chmod|fchmod|fchmodat|chown|fchown|lchown|fchownat|fdopen|fflush|fseek|ftell|fgetpos|fsetpos|rewind|scandir"
POSIX_NETWORK_FUNCTIONS = r"socket|socketpair|connect|bind|listen|accept|send|sendto|sendmsg|recv|recvfrom|recvmsg|shutdown|setsockopt|getsockopt|getpeername|getsockname"
FILE_INITIALIZER_TYPES = r"(?:Foundation\.|UIKit\.|AppKit\.)?(?:Data|NSData|NSMutableData|String|NSString|NSMutableString|UIImage|NSImage|InputStream|OutputStream|FileWrapper|NSFileWrapper)\??"


def normalized_resource_source(source: str) -> str:
    resources = "Data|NSData|NSMutableData|String|NSString|NSMutableString|UIImage|NSImage|InputStream|OutputStream|FileWrapper|NSFileWrapper|UserDefaults|FileManager|URLSession|URLSessionTransport|URLCache|AppFileSystem|LocalAppFileService"
    return re.sub(r"\b((?:Foundation\.)?(?:" + resources + r"))\s*\.\s*self(?=\s*\.)",
        lambda match: match[1] + "\n" * match[0].count("\n"), source)


@cache
def resource_facts(source: str) -> dict:
    return swift_syntax_index_sources({"resource-source": source})["resource-source"]


@cache
def file_member_accesses(source: str, properties: tuple = ()) -> list[int]:
    if not re.search(r"\.\s*(?:write|read|matchesContents)\b", swift_code(source)): return []
    facts = dict(resource_facts(source))
    facts["typedVariables"] = facts["typedVariables"] + [dict(scope=list(scope), name=name, type=kind, start=-1, lexicalScope=[])
        for scope, name, kind in properties]
    encoded = source.encode()
    file_types = {"Data", "NSData", "NSMutableData", "String", "NSString", "NSMutableString", "FileWrapper", "NSFileWrapper"}
    def normalized_type(value: str) -> str:
        value = value.strip().removeprefix("Foundation.").removesuffix("?")
        optional = re.fullmatch(r"(?:Swift\.)?Optional<(.+)>", value)
        return normalized_type(optional[1]) if optional else value

    def element_type(container: str | None) -> str | None:
        if container is None: return None
        container = normalized_type(container)
        array = re.fullmatch(r"\[(.+)\]|(?:Swift\.)?Array<(.+)>", container)
        if array:
            value = array[1] or array[2]
            return normalized_type(value.split(":", 1)[-1])
        dictionary = re.fullmatch(r"(?:Swift\.)?Dictionary<.+,\s*(.+)>", container)
        return normalized_type(dictionary[1]) if dictionary else None

    def value_type(expression: str, point: dict, seen: frozenset = frozenset()) -> str | None:
        expression = re.sub(r"^(?:(?:try[!?]?|await)\s+)+", "", expression.strip()).rstrip("!?")
        if expression.startswith("(") and expression.endswith(")"):
            expression = expression[1:-1].strip()
        result = re.match(r"(.+)\.\s*(encode|data|pngData|jpegData|appendingPathComponent|appendingPathExtension|appending)\s*\(", expression, re.DOTALL)
        if result:
            receiver_type = value_type(result[1], point, seen)
            if result[2] == "encode" and receiver_type in {"JSONEncoder", "PropertyListEncoder"}: return "Data"
            if result[2] == "data" and receiver_type in {"String", "NSString", "NSMutableString", "JSONSerialization", "PropertyListSerialization"}: return "Data"
            if result[2] in {"pngData", "jpegData"} and receiver_type == "UIImage": return "Data"
            if result[2].startswith("appending") and receiver_type in {"URL", "NSURL"}: return receiver_type
            return None
        if re.match(r'^#*"', expression): return "String"
        if expression.startswith("[") and expression.endswith("]"):
            item = value_type(expression[1:-1].split(",", 1)[0], point, seen)
            return "[" + item + "]" if item else None
        subscript = re.fullmatch(r"(.+)\[[^\[\]]+\]", expression, re.DOTALL)
        if subscript:
            return element_type(value_type(subscript[1], point, seen))
        constructor = re.match(r"(?:Foundation\.)?(\w+)\s*(?:\.\s*init)?\s*\(", expression)
        if constructor:
            invocations = [call for call in facts["invocations"] if call["value"] == expression
                and call["scope"] == point["scope"] and call.get("lexicalScope") == point.get("lexicalScope")]
            invocation = min(invocations, key=lambda call: abs(call["start"] - point["start"])) if invocations else None
            functions = matching_functions(facts, constructor[1], invocation or point)
            if functions:
                return normalized_type(functions[-1].get("returnType") or "")
            variables = visible_variables(facts, point, constructor[1], False)
            if variables and "->" in variables[-1]["type"]:
                return normalized_type(variables[-1]["type"].rsplit("->", 1)[1])
            return constructor[1] if constructor[1][:1].isupper() or any(
                declaration["name"] == constructor[1] for declaration in facts["declarations"]) else None
        if expression in {"JSONSerialization", "PropertyListSerialization"}: return expression
        member = re.fullmatch(r"(.+)\.\s*(\w+)", expression)
        if member and member[1] != "self":
            owner = value_type(member[1], point, seen)
            if member[2] in {"first", "last"} and owner and re.fullmatch(
                    r"\[[^:]+\]|(?:Swift\.)?Array<.+>", normalized_type(owner)):
                return element_type(owner)
            fields = [variable for variable in facts["typedVariables"]
                if variable["name"] == member[2] and variable["scope"] and variable["scope"][-1] == owner
                and not variable.get("lexicalScope")]
            return normalized_type(fields[-1]["type"]) if fields else None
        if not re.fullmatch(r"(?:self\.)?\w+", expression): return None
        name = expression.rsplit(".", 1)[-1]
        identity = (expression, point["start"])
        if identity in seen: return None
        variables = visible_variables(facts, point, name, expression.startswith("self."))
        candidates = [binding for binding in facts["bindings"]
            if re.match(re.escape(name) + r"\s*(?:=|in\b)", binding["value"]) and binding["start"] < point["start"]
            and (not expression.startswith("self.") or not binding.get("lexicalScope"))
            and point["scope"][:len(binding["scope"])] == binding["scope"]
            and point.get("lexicalScope", [])[:len(binding.get("lexicalScope", []))] == binding.get("lexicalScope", [])]
        visible = variables + candidates
        if visible:
            binding = max(visible, key=lambda item: (len(item.get("lexicalScope", [])), item["start"]))
            if "type" in binding: return normalized_type(binding["type"])
            iteration = re.match(re.escape(name) + r"\s+in\s+(.+)", binding["value"], re.DOTALL)
            if iteration: return element_type(value_type(iteration[1], binding, seen | {identity}))
            return value_type(binding["value"].split("=", 1)[1], binding, seen | {identity})
        return None

    hits = set()
    for call in facts["invocations"]:
        match = re.match(r"(.+)\.\s*(write|read|matchesContents)\s*\(\s*(?:to|toFile|from|of)\s*:", call["value"], re.DOTALL)
        if match:
            receiver = value_type(match[1], call)
            arguments = call.get("arguments") or []
            target = value_type(arguments[0], call) if arguments else None
            if (match[2] == "write" and receiver in file_types or receiver in {"FileWrapper", "NSFileWrapper"}) or (match[2] == "write" and receiver is None and (target == "URL" or (target == "String" and "toFile" in call["argumentLabels"]))):
                hits.add(encoded[:call["start"]].count(b"\n") + 1)
    for reference in facts["members"]:
        match = re.fullmatch(r"(.+)\.\s*(write|read|matchesContents)(?:\(\s*(?:\w+\s*:\s*)+\))?", reference["value"], re.DOTALL)
        if not match: continue
        receiver = value_type(match[1], reference) or normalized_type(match[1])
        if match[2] == "write" and receiver in file_types or receiver in {"FileWrapper", "NSFileWrapper"}:
            hits.add(encoded[:reference["start"]].count(b"\n") + 1)
    return sorted(hits)


@cache
def implicit_file_accesses(source: str, functions: str = POSIX_FILE_FUNCTIONS) -> list[int]:
    code = swift_code(source)
    if not re.search((r"\.\s*init\s*\(|" if functions == POSIX_FILE_FUNCTIONS else "") + r"(?<![.\w])(?:" + functions + r")\b|\b(?:Darwin|Glibc)\s*\.", code): return []
    facts = resource_facts(source)
    encoded = source.encode()
    hits = set()
    def own_value(reference: dict, name: str) -> bool:
        return bool(visible_variables(facts, reference, name)) or any(
            variable["name"] == name and variable["start"] == reference["start"] for variable in facts["typedVariables"]) or any(case["name"] == name and reference["scope"][:len(case["scope"])] == case["scope"] for case in facts["enumCases"]) or any(
            re.match(re.escape(name) + r"\s*=", binding["value"]) and binding["start"] <= reference["start"]
            and reference["scope"][:len(binding["scope"])] == binding["scope"]
            and reference["lexicalScope"][:len(binding["lexicalScope"])] == binding["lexicalScope"] for binding in facts["bindings"])
    for reference in facts["members"] + facts["scopedIdentifiers"]:
        qualified = re.fullmatch(r"(?:Darwin|Glibc)\s*\.\s*(" + functions + r")", reference["value"])
        bare = re.fullmatch(functions, reference["value"])
        own = any(function["name"] == reference["value"] and reference["scope"][:len(function["scope"])] == function["scope"]
            for function in facts["functionRanges"])
        member_name = any(member["start"] <= reference["start"] < member["start"] + len(member["value"].encode())
            for member in facts["members"] if member is not reference)
        if qualified or (bare and not member_name and not own and not own_value(reference, reference["value"])):
            hits.add(encoded[:reference["start"]].count(b"\n") + 1)
    for call in facts["invocations"]:
        value = swift_code(call["value"])
        posix = re.match(r"(?:(Darwin|Glibc)\s*\.\s*)?(" + functions + r")\s*\(", value)
        forbidden = False
        if posix:
            own_function = bool(matching_functions(facts, posix[2], call)) or own_value(call, posix[2])
            forbidden = bool(posix[1]) or not own_function
        elif functions == POSIX_FILE_FUNCTIONS and re.match(r"\.\s*init\s*\(\s*(?:contentsOf|contentsOfFile|contentsOfURL|url|path|fileAtPath|toFileAtPath)\s*:", value):
            prefix = swift_code(encoded[:call["start"]].decode())
            contexts = expected_argument_types(facts, call) + [match[1] for binding in facts["bindings"]
                if binding["start"] <= call["start"] < binding["start"] + len(binding["value"].encode())
                and (match := re.match(r"\w+\s*:\s*([^={]+)", swift_code(binding["value"])))]
            assigned = re.search(r"(?:self\.)?(\w+)\s*=\s*$", prefix)
            if assigned:
                matching = visible_variables(facts, call, assigned[1], assigned[0].startswith("self."))
                if matching: contexts.append(matching[-1]["type"])
            contexts.extend(function["returnType"] for function in facts["functionRanges"]
                if function["start"] <= call["start"] < function["end"] and function.get("returnType")
                and re.search(r"(?:\breturn|\{)\s*$", prefix))
            forbidden = any(re.search(r"\b" + FILE_INITIALIZER_TYPES + r"\b", context) for context in contexts) if contexts \
                else bool(re.match(r"\.\s*init\s*\(\s*contentsOf(?:File|URL)?\s*:", value))
        if forbidden: hits.add(encoded[:call["start"]].count(b"\n") + 1)
    return sorted(hits)


@cache
def implicit_resource_accesses(source: str, resource: str = "UserDefaults", properties: tuple = ()) -> list[int]:
    code = swift_code(source)
    if not re.search(r"\.\s*(?:standard\b|init\s*\()", code): return []
    facts = dict(resource_facts(source))
    facts["typedVariables"] = facts["typedVariables"] + [dict(scope=list(scope), name=name, type=kind, start=-1, lexicalScope=[])
        for scope, name, kind in properties]
    encoded = source.encode()
    hits = []
    accesses = [member for member in facts["members"] if resource == "UserDefaults" and re.fullmatch(r"\.\s*standard", swift_code(member["value"]).strip())]
    accesses.extend(call for call in facts["invocations"] if re.match(r"\.\s*init\s*\(", swift_code(call["value"])))
    for member in accesses:
        prefix = swift_code(encoded[:member["start"]].decode())
        assigned = re.search(r"(?:self\.)?(\w+)\s*=\s*$", prefix)
        inferred = bool(re.search(r"\b(?:Foundation\.|StorageCore\.)?" + resource + r"\??\s*=\s*$", prefix))
        inferred |= any(resource_context_type(value, resource) for value in expected_argument_types(facts, member))
        inferred |= any(binding["start"] <= member["start"] < binding["start"] + len(binding["value"].encode())
            and (context := re.match(r"\w+\s*:\s*([^={]+)", swift_code(binding["value"])))
            and resource_context_type(context[1], resource)
            and re.search(r"(?:\breturn|\bin|[\{=\[,:?])\s*(?:try[!?]?\s*)?$", prefix)
            for binding in facts["bindings"])
        if assigned:
            matching = visible_variables(facts, member, assigned[1], assigned[0].startswith("self."))
            inferred = inferred or bool(matching and resource_context_type(matching[-1]["type"], resource))
        inferred = inferred or any(function["start"] <= member["start"] < function["end"]
            and resource_context_type(function.get("returnType", ""), resource)
            and re.search(r"(?:\breturn|[\{?:])\s*(?:try[!?]?\s*)?$", prefix) for function in facts["functionRanges"])
        if inferred: hits.append(prefix.count("\n") + 1)
    return hits


def ownership_errors(scope: str, source: str, path: str = "", aliases: tuple = (), properties: tuple = ()) -> list[str]:
    source = normalized_resource_source(expanded_resource_source(source, aliases, path or "resource-source"))
    code = swift_code(source)
    patterns = []
    if layer(scope) is not None:
        patterns.append(GLOBAL_RESOURCE_PATTERN)
        if scope != "TransportCore": patterns.append(r"\bURLSessionTransport\s*\.\s*(?:make|clearSharedCache)\b")
        if scope != "StorageCore": patterns.append(r"\bAppFileSystem\s*\.\s*files\b|\b(?:LocalAppFileService|UserDefaults)\s*(?:\(|\.\s*init\b)")
    if scope in {"GalleryFeature", "CommunityUI"}:
        patterns.append(r"\b(?:ComposerDraftStore|GalleryMessageReadStore)\b")
    if scope == "ScoreFeature":
        patterns.append(r"\b(?:ScoreCacheStore|ScoreFilterPreferenceStore)\b")
    if scope == "AppScheduleCacheEffects":
        patterns.append(r"\b(?:AppFileDirectories|AppAccountSession|ScheduleCloudSyncManager|ScheduleLiveActivityManager|ScheduleSystemCalendarManager)\b|\.\s*shared\b")
    if scope == "AppExternalDisplayCoordinator":
        patterns.append(r"\b(?:AppFileDirectories|AppAccountSession|ScheduleWidgetExporter|ScheduleLiveActivityManager|WatchScheduleSyncManager|AppErrorPresenter)\b|\.\s*shared\b")
    if scope == "AppLocalDataService":
        patterns.extend((GLOBAL_RESOURCE_PATTERN, r"\b(?:LoginStorage|ScheduleCacheStore|ScheduleWidgetExporter|AppMedia|AppSettingsStore|WKWebsiteDataStore)\b"))
    if settings_owner(scope):
        patterns.append(r"\b(?:AppMedia|LoginStorage)\s*\.")
    implicit = [f"resource ownership: {scope} selects UserDefaults at line {line}"
        for line in implicit_resource_accesses(source, properties=properties)] if layer(scope) is not None else []
    if layer(scope) is not None and scope != "StorageCore":
        implicit.extend(f"resource ownership: {scope} selects LocalAppFileService at line {line}"
            for line in implicit_resource_accesses(source, "LocalAppFileService", properties))
    return implicit + [
        f"resource ownership: {scope} uses {match[0].strip()}"
        for pattern in patterns
        for match in re.finditer(pattern, code)
        if not (path == "Modules/TransportCore/Sources/SecureURLTransport.swift"
                and re.fullmatch(r"URLCache\s*\.\s*shared", match[0]))
    ]


def settings_owner(name: str) -> bool:
    return name.startswith(("Settings", "DeveloperSuggestion")) or name in {"GallerySettingsPage", "AboutSettingsPage", "AccountSettingsPage"}


def adapter_roles(index: dict[str, dict], path: str | None = None) -> dict[tuple[str, ...], str]:
    roles = {(name,): name for name in {"AppScheduleCacheEffects", "AppExternalDisplayCoordinator", "AppLocalDataService"}}
    protocols = {"SchedulePlatformActions": "AppScheduleCacheEffects", "AppExternalDisplayCoordinating": "AppExternalDisplayCoordinator"}
    conformances = declaration_conformances(index, path)
    view_owners = {owner for owner, bases in conformances.items() if any(base.rsplit(".", 1)[-1] == "View" for base in bases)}
    for owner, bases in conformances.items():
        for inherited in bases:
            if role := protocols.get(inherited.rsplit(".", 1)[-1]): roles[owner] = role
    for source, facts in index.items():
        if path is not None and source != path: continue
        if source.startswith("BIT101-iOS/Settings/"):
            for declaration in facts.get("declarations", []):
                roles.setdefault(canonical_type_scope(declaration.get("scope", []) + [declaration["name"]]), "Settings")
        for function in facts.get("functionRanges", []):
            if function["name"] == "resetAllLocalData" and function["scope"] and not scope_contains_type(function["scope"], view_owners):
                roles[canonical_type_scope(function["scope"])] = "AppLocalDataService"
    return roles


def adapter_ownership_errors(facts: dict, path: str = "", roles: dict | None = None) -> list[str]:
    errors = []
    if roles is None: roles = adapter_roles({path: facts})
    for node in facts["scopedIdentifiers"] + facts["members"]:
        scope = canonical_type_scope(node["scope"])
        active_roles = {role for owner, role in roles.items() if scope[:len(owner)] == owner}
        active_roles.update(owner for owner in node["scope"] if settings_owner(owner))
        for role in active_roles:
            errors.extend(ownership_errors(role, node["value"]))
    return errors



def native_target_errors(root: Path, package: dict, modules: set[str]) -> list[str]:
    from code_quality_rules import native_project_targets
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(root / "BIT101-iOS.xcodeproj/project.pbxproj"),
    ], text=True))
    errors: list[str] = []
    for name, declared, sources in native_project_targets(project, root):
        actual = {module for source in sources for module in imports_in_text(source.read_text(encoding="utf-8"))}
        exported = {module for product in package["products"] if product["name"] in declared for module in product["targets"]}
        for module in actual & modules - exported:
            errors.append(f"native target {name} imports undeclared product for {module}")
    return errors



def main() -> int:
    from module_boundary_tests import run_self_test
    run_self_test(globals())
    root = Path(__file__).resolve().parents[1]
    try:
        package = read_manifest(root)
        targets = manifest_targets(package)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    modules = {name: info for name, info in targets.items() if info["path"].startswith("Modules/")}
    support = {name: info for name, info in targets.items()
               if info["type"] == "regular" and info["path"].startswith("ModuleTests/")}
    tests = {name: info for name, info in targets.items() if info["type"] == "test"}
    errors: list[str] = coverage_registry_findings(set(modules))
    unknown = targets.keys() - modules.keys() - support.keys() - tests.keys()
    if unknown:
        errors.append(f"unclassified source targets: {sorted(unknown)}")
    roots = {path.name for path in (root / "Modules").iterdir() if path.is_dir()}
    if modules.keys() != roots:
        errors.append(f"module source roots differ from manifest: {sorted(modules.keys() ^ roots)}")
    graph = {name: info["dependencies"] for name, info in modules.items()}
    errors.extend(graph_errors(graph))
    module_aliases = type_aliases(swift_syntax_index([path for info in modules.values()
        for path in (root / info["path"]).rglob("*.swift") if "typealias" in swift_code(path.read_text())]))

    network_index = {}
    for module, info in modules.items():
        source_root = root / info["path"]
        if info["type"] != "regular" or info["path"] != f"Modules/{module}/Sources":
            errors.append(f"{module} requires a regular target at Modules/{module}/Sources")
        if not source_root.is_dir():
            errors.append(f"{module} source root missing: {source_root}")
            continue
        source_files = sorted(source_root.rglob("*.swift"))
        aliases = tuple(alias for alias in module_aliases if alias_module(alias[4]) == module)
        unit_index = swift_syntax_index_sources({path.relative_to(root).as_posix():
            expanded_resource_source(path.read_text(), imported_aliases(path.read_text(), aliases, module_aliases), path.relative_to(root).as_posix())
            for path in source_files})
        network_index.update(unit_index)
        for path in source_files:
            unit_context = compilation_type_context(unit_index, path.relative_to(root).as_posix())
            text = path.read_text(encoding="utf-8")
            context = imported_aliases(text, aliases, module_aliases)
            errors.extend(platform_errors(module, raw_imports(text)))
            errors.extend(ownership_errors(module, text, path.relative_to(root).as_posix(), context, unit_context[0]))
            errors.extend(service_boundary_errors(path.relative_to(root).as_posix(), text, context, unit_context))
        actual = imported_modules(source_root)
        for dependency in info["dependencies"] - actual.keys():
            errors.append(f"{module} declares unused {dependency}")
        for imported, files in actual.items():
            if imported not in modules:
                errors.append(f"{module} imports unknown module {imported}: {', '.join(sorted(files))}")
            elif imported not in info["dependencies"]:
                errors.append(f"{module} imports undeclared {imported}: {', '.join(sorted(files))}")

    from validation_test_areas import network_capability_findings
    for name, info in (support | tests).items():
        source_root = root / info["path"]
        if not source_root.is_dir() or not info["path"].startswith("ModuleTests/"):
            errors.append(f"test source root requires ModuleTests ownership: {name}")
        actual = imported_modules(source_root).keys() & (modules.keys() | support.keys())
        if actual != info["dependencies"]:
            errors.append(f"test consumer {name}: declared {sorted(info['dependencies'])}, imports {sorted(actual)}")
    if len(tests) < 2:
        errors.append("test consumers require independent source roots")

    # 平台副作用适配的资源选择沿语法树声明归属核对。
    app_syntax = swift_syntax_index(sorted((root / "BIT101-iOS").rglob("*.swift")))
    app_aliases = type_aliases(app_syntax)
    normalized = {}
    for path in app_syntax:
        source = Path(path).read_text()
        expanded = expanded_resource_source(source, imported_aliases(source, app_aliases, module_aliases), Path(path).relative_to(root).as_posix())
        if expanded != source: normalized[path] = expanded
    app_syntax.update(swift_syntax_index_sources(normalized) if normalized else {})
    errors.extend(network_capability_findings(network_index | app_syntax))
    adapter_index = {Path(path).relative_to(root).as_posix(): facts for path, facts in app_syntax.items()}
    for path, facts in app_syntax.items():
        source = Path(path).relative_to(root).as_posix()
        errors.extend(adapter_ownership_errors(facts, source, adapter_roles(adapter_index, source)))

    errors.extend(native_target_errors(root, package, set(modules)))

    for name in ("BIT101-iOS", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"):
        sources = sorted((root / name).rglob("*.swift"))
        aliases = app_aliases if name == "BIT101-iOS" else type_aliases(swift_syntax_index(
            [source for source in sources if "typealias" in swift_code(source.read_text())]))
        unit_index = app_syntax if name == "BIT101-iOS" else swift_syntax_index_sources({
            path.relative_to(root).as_posix(): expanded_resource_source(path.read_text(), imported_aliases(path.read_text(), aliases, module_aliases), path.relative_to(root).as_posix()) for path in sources})
        for source in sources:
            unit_context = compilation_type_context(unit_index, str(source) if name == "BIT101-iOS" else source.relative_to(root).as_posix())
            text = source.read_text(encoding="utf-8")
            errors.extend(service_boundary_errors(source.relative_to(root).as_posix(), text, imported_aliases(text, aliases, module_aliases), unit_context))

    if errors:
        for error in errors:
            print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    print(f"module-boundary: {len(modules)} module source roots and direct dependencies pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
