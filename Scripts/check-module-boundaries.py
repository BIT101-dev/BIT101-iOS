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
from swift_source_index import canonical_type_scope, declaration_conformances, scope_contains_type, expected_argument_types, swift_syntax_index, swift_syntax_index_sources, resource_context_type, visible_variables, matching_functions, compilation_type_context, local_member_calls


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


@cache
def swift_code(source: str, keep_comments: bool = False) -> str:
    """Retain executable Swift, including interpolation, with stable positions."""
    result = ["\n" if char == "\n" else " " for char in source]
    string_start = re.compile(r'(#{0,})("""|")')

    def code(index: int, interpolation: bool = False) -> int:
        depth = 1
        while index < len(source):
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
                index += len(match[0])
                closing = quotes + hashes
                escape = "\\" + hashes
                while index < len(source):
                    if source.startswith(escape + "(", index):
                        index = code(index + len(escape) + 1, interpolation=True)
                    elif source.startswith(escape, index):
                        index += len(escape) + 1
                    elif source.startswith(closing, index):
                        index += len(closing)
                        break
                    else:
                        index += 1
                continue
            regex = re.match(r"(#+)/", source[index:])
            prefix = source[:index].rstrip()
            bare = source[index] == "/" and (not prefix or prefix[-1] in "=(:,[!{;?" or re.search(r"\b(?:return|case|throw|try|await)$", prefix))
            if regex or bare:
                hashes = regex[1] if regex else ""
                cursor = index + len(hashes) + 1
                brackets = 0
                while cursor < len(source):
                    if source[cursor] == "\\": cursor += 2; continue
                    if source[cursor] == "[": brackets += 1
                    elif source[cursor] == "]": brackets = max(0, brackets - 1)
                    elif source.startswith("/" + hashes, cursor) and (hashes or brackets == 0):
                        index = cursor + 1 + len(hashes)
                        break
                    elif source[cursor] == "\n" and not hashes: break
                    cursor += 1
                else: cursor = len(source)
                if index == cursor + 1 + len(hashes): continue
            if interpolation:
                if source[index] == "(":
                    depth += 1
                elif source[index] == ")":
                    depth -= 1
                    if depth == 0:
                        return index + 1
            result[index] = " " if source[index] == "`" else source[index]
            index += 1
        return index

    code(0)
    return "".join(result)


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
        visit(module, ())
        for dependency in dependencies:
            source_layer, dependency_layer = layer(module), layer(dependency)
            if dependency not in manifest:
                errors.append(f"unknown dependency: {module} -> {dependency}")
            if source_layer and dependency_layer and dependency_layer not in LAYERS[source_layer]:
                errors.append(f"{source_layer.lower()} boundary: {module} -> {dependency}")
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
        patterns.append((r"\b(?:NWPathMonitor|NWConnection|NWListener)\b", "use TransportCore network services"))
    if path != "Modules/TransportCore/Sources/TaskCancellation.swift":
        patterns.append((r"\.\s*userInfo\s*\[\s*NSUnderlyingErrorKey\s*\]", "traverse underlying errors through ErrorChain"))
    if path != "Modules/TransportCore/Sources/AppURL.swift":
        patterns.append((r"\bCharacterSet\s*\.\s*urlQueryAllowed\b", "encode form fields through HTTPFormEncoding"))
    if path.startswith("Modules/ScheduleFeature/"):
        patterns.append((r"\bDateFormatter\s*\(", "format schedule dates through ScheduleDateCodec"))
    if path != "Modules/StorageCore/Sources/AppFileService.swift":
        patterns.extend((
            (r"\bCF(?:Read|Write)StreamCreateWithFile\b", "read and write files through AppFileService"),
            (r"\bFileManager\b(?!\s*\.\s*(?:SearchPathDirectory|DirectoryEnumerationOptions)\b)", "use AppFileService"),
            (r"\b(?:Data|NSData|NSMutableData|String|NSString|NSMutableString)\s*(?:\.\s*init\s*)?\(\s*(?:contentsOf|contentsOfFile|contentsOfURL)\s*:", "read files through AppFileService"),
            (r"\.\s*(?:resourceValues|setResourceValues|getResourceValue|setResourceValue|resolvingSymlinksInPath|checkResourceIsReachable)\s*\(", "access file metadata through AppFileService"),
            (r"\b(?:FileHandle|NSFileHandle)\b(?!\s*\.\s*standard(?:Output|Error)\b)|\b(?:NSFileCoordinator|CGImageSourceCreateWithURL|CGImageDestinationCreateWithURL)\b", "access files through AppFileService"),
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
        errors.extend(f"service boundary: {path}:{line}: write files through AppFileService"
            for line in file_write_accesses(source))
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
FILE_INITIALIZER_TYPES = r"(?:Foundation\.|UIKit\.|AppKit\.)?(?:Data|NSData|NSMutableData|String|NSString|NSMutableString|UIImage|NSImage|InputStream|OutputStream)\??"


def normalized_resource_source(source: str) -> str:
    resources = "Data|NSData|NSMutableData|String|NSString|NSMutableString|UIImage|NSImage|InputStream|OutputStream|UserDefaults|FileManager|URLSession|URLSessionTransport|URLCache|AppFileSystem|LocalAppFileService"
    return re.sub(r"\b((?:Foundation\.)?(?:" + resources + r"))\s*\.\s*self(?=\s*\.)",
        lambda match: match[1] + "\n" * match[0].count("\n"), source)


@cache
def file_write_accesses(source: str) -> list[int]:
    if not re.search(r"\.\s*write\s*\(\s*(?:to|toFile)\s*:", swift_code(source)): return []
    facts = swift_syntax_index_sources({"file-writes": source})["file-writes"]
    encoded = source.encode()
    file_types = {"Data", "NSData", "NSMutableData", "String", "NSString", "NSMutableString"}
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

    hits = []
    for call in facts["invocations"]:
        match = re.match(r"(.+)\.\s*write\s*\(\s*(?:to|toFile)\s*:", call["value"], re.DOTALL)
        if match:
            receiver = value_type(match[1], call)
            arguments = call.get("arguments") or []
            target = value_type(arguments[0], call) if arguments else None
            if receiver in file_types or (receiver is None and (target == "URL" or (target == "String" and "toFile" in call["argumentLabels"]))):
                hits.append(encoded[:call["start"]].count(b"\n") + 1)
    return hits


@cache
def implicit_file_accesses(source: str, functions: str = POSIX_FILE_FUNCTIONS) -> list[int]:
    code = swift_code(source)
    if not re.search((r"\.\s*init\s*\(|" if functions == POSIX_FILE_FUNCTIONS else "") + r"(?<![.\w])(?:" + functions + r")\b|\b(?:Darwin|Glibc)\s*\.", code): return []
    facts = swift_syntax_index_sources({"file-access": source})["file-access"]
    encoded = source.encode()
    hits = set()
    def own_value(reference: dict, name: str) -> bool:
        return bool(visible_variables(facts, reference, name)) or any(case["name"] == name and reference["scope"][:len(case["scope"])] == case["scope"] for case in facts["enumCases"]) or any(
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
        elif functions == POSIX_FILE_FUNCTIONS and re.match(r"\.\s*init\s*\(\s*(?:contentsOf|contentsOfFile|contentsOfURL|url|fileAtPath|toFileAtPath)\s*:", value):
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
    facts = swift_syntax_index_sources({"preferences": source})["preferences"]
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


def adapter_roles(index: dict[str, dict]) -> dict[tuple[str, ...], str]:
    roles = {(name,): name for name in {"AppScheduleCacheEffects", "AppExternalDisplayCoordinator", "AppLocalDataService"}}
    protocols = {"SchedulePlatformActions": "AppScheduleCacheEffects", "AppExternalDisplayCoordinating": "AppExternalDisplayCoordinator"}
    conformances = declaration_conformances(index)
    view_owners = {owner for owner, bases in conformances.items() if any(base.rsplit(".", 1)[-1] == "View" for base in bases)}
    for owner, bases in conformances.items():
        for inherited in bases:
            if role := protocols.get(inherited.rsplit(".", 1)[-1]): roles[owner] = role
    for path, facts in index.items():
        if path.startswith("BIT101-iOS/Settings/"):
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


def self_test() -> None:
    split_sources = {"Types.swift": "enum Namespace { struct Owner { var prefs: UserDefaults; var files: LocalAppFileService }; struct Local { func data(for item: Int) -> Int { item } } }",
        "Init.swift": "extension Namespace.Owner { init() { self.prefs = .standard; self.files = .init() } }",
        "Local.swift": "let catalog = Namespace.Local(); let value = catalog.data(for: 1)"}
    context = compilation_type_context(swift_syntax_index_sources(split_sources))
    assert len(ownership_errors("GalleryFeature", split_sources["Init.swift"], properties=context[0])) == 2
    assert len(service_boundary_errors("Modules/GalleryFeature/Sources/Init.swift", split_sources["Init.swift"], context=context)) == 2
    assert service_boundary_errors("Modules/GalleryFeature/Sources/Local.swift", split_sources["Local.swift"], context=context) == []
    assert service_boundary_errors("BIT101-iOS/Example.swift", "struct Catalog { func data(for item: Int) -> Int { item } }; let catalog = Catalog(); let value = catalog.data(for: 1)") == []
    assert service_boundary_errors("BIT101-iOS/Example.swift", "struct Catalog { func data(for item: Int) -> Int { item } }; let catalog = Catalog(); let value = catalog.data(for: 1); let data = try await session.data(for: request)")
    for source in ("let bytes = NSMutableData(contentsOf: url)", "let text = try NSMutableString(contentsOf: url, encoding: encoding)",
                   "let bytes: NSMutableData = .init(contentsOf: url)", "let text = try NSMutableString.self.init(contentsOf: url, encoding: encoding)"):
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source)
    targets = manifest_targets({"targets": [
        {"name": "NewCore", "path": "Modules/NewCore/Sources", "type": "regular", "dependencies": []},
        {"name": "NewFeature", "path": "Modules/NewFeature/Sources", "type": "regular",
         "dependencies": [{"byName": ["NewCore", None]}]},
        {"name": "ConsumerTests", "path": "ModuleTests/Consumer", "type": "test",
         "dependencies": [{"target": ["NewFeature", {"platformNames": ["macos"]}]}]},
    ]})
    assert targets["NewFeature"]["dependencies"] == {"NewCore"}
    assert targets["ConsumerTests"]["dependencies"] == {"NewFeature"}
    assert graph_errors({name: info["dependencies"] for name, info in targets.items() if info["type"] == "regular"}) == []
    for invalid in (
        {"name": "MissingCore", "type": "regular", "dependencies": []},
        {"name": "ExternalCore", "path": "Modules/ExternalCore/Sources", "type": "regular",
         "dependencies": [{"product": ["Remote", "Package", None]}]},
    ):
        try:
            manifest_targets({"targets": [invalid]})
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid manifest target accepted: {invalid}")
    assert imports_in_text("@testable import ScoreFeature\n@preconcurrency public import TransportCore\nimport SwiftUI") == {"ScoreFeature", "TransportCore"}
    assert raw_imports("@_implementationOnly import UIKit\n@_spi(Internal) import StorageCore") == {"UIKit", "StorageCore"}
    for access in ("public", "internal", "fileprivate", "private", "package"):
        assert raw_imports(f"{access} import UIKit") == {"UIKit"}
        assert platform_errors("ScheduleDomain", raw_imports(f"@preconcurrency {access} import struct UIKit.UIColor"))
    assert raw_imports("@_spi(Internal)\n@preconcurrency public import class Foundation.Date") == {"Foundation"}
    assert raw_imports("import Foundation; import UIKit; @_spi(Internal) import StorageCore") == {"Foundation", "UIKit", "StorageCore"}
    assert platform_errors("ScheduleDomain", raw_imports("#if os(iOS)\nimport Foundation; import UIKit\n#endif"))
    assert platform_errors("ScheduleDomain", raw_imports("import `UIKit`"))
    for source in ("Foundation.UserDefaults.`standard`", "`UserDefaults`.standard", "let prefs: `UserDefaults` = .`standard`"):
        assert ownership_errors("GalleryFeature", source) and service_boundary_errors("BIT101-iOS/Example.swift", source)
    assert graph_errors({"Leaf": set(), "First": {"Leaf"}, "Second": {"Leaf"}}) == []
    assert any("cycle" in error for error in graph_errors({"First": {"Second"}, "Second": {"First"}}))
    assert any("feature boundary" in error for error in graph_errors({"FirstFeature": {"SecondFeature"}, "SecondFeature": set()}))
    assert any("infrastructure boundary" in error for error in graph_errors({"ScoreInfrastructure": {"ScoreFeature"}, "ScoreFeature": set()}))


    assert graph_errors({"TransportCore": {"ScoreFeature"}, "ScoreFeature": set()})
    assert ownership_errors("CommunityUI", "let screen = UIApplication . shared")
    assert ownership_errors("ScoreFeature", "let store: ScoreCacheStore")
    assert ownership_errors("GalleryFeature", "let store: ComposerDraftStore")
    for factory in ("URLSessionTransport.make(configuration: .ephemeral)", "URLSessionTransport.self.make(configuration: .ephemeral)", "typealias Factory = URLSessionTransport; Factory.make(configuration: .ephemeral)"):
        assert ownership_errors("GalleryFeature", factory)
        assert service_boundary_errors("Modules/GalleryFeature/Sources/GalleryService.swift", factory)
    assert ownership_errors("CommunityUI", "let store: GalleryMessageReadStore")
    assert ownership_errors("ScoreFeature", "// ScoreCacheStore\nlet text = #\"URLSession.shared\"#") == []
    assert ownership_errors("AppLocalDataService", "LoginStorage.shared.clearAllLocalData()")
    assert ownership_errors("AppScheduleCacheEffects", "ScheduleCloudSyncManager.shared.pushLatestLocalCacheIfNeeded()")
    renamed = swift_syntax_index_sources({"renamed.swift": 'struct RenamedEffects: SchedulePlatformActions { func enable() { ScheduleCloudSyncManager.shared.push() } }; struct RenamedCleanup { func resetAllLocalData() { LoginStorage.shared.clear() } }'})
    assert len(adapter_ownership_errors(renamed["renamed.swift"])) >= 2
    split = swift_syntax_index_sources({
        "Types.swift": "enum Namespace { struct RenamedEffects: SchedulePlatformActions {}; struct Composition {} }",
        "Effects.swift": "extension Namespace.RenamedEffects { func enable() { ScheduleCloudSyncManager.shared.push() } }",
        "Composition.swift": "extension Namespace.Composition { func enable() { ScheduleCloudSyncManager.shared.push() } }",
    })
    roles = adapter_roles(split)
    assert adapter_ownership_errors(split["Effects.swift"], roles=roles)
    assert adapter_ownership_errors(split["Composition.swift"], roles=roles) == []
    renamed_settings = swift_syntax_index_sources({"settings.swift": 'struct RenamedScreen: View { var body: some View { AppMedia.shared } }'})
    assert adapter_ownership_errors(renamed_settings["settings.swift"], "BIT101-iOS/Settings/Renamed.swift")
    assert platform_errors("ScheduleDomain", {"UIKit"})
    assert platform_errors("ScheduleDomain", {"Foundation", "Compression"}) == []
    assert platform_errors("ScheduleActivityContracts", {"Foundation", "ActivityKit"}) == []
    interpolation_sources = (
        r'let text = "\(UserDefaults.standard.string(forKey: "key"))"',
        r'let text = #"\#(UserDefaults.standard)"#',
        'let text = """\n\\(UserDefaults.standard)\n"""',
        r'let text = "\("nested \(UserDefaults.standard)")"',
    )
    for source in interpolation_sources:
        assert ownership_errors("GalleryFeature", source)
        assert len(swift_code(source)) == len(source)
    assert ownership_errors("GalleryFeature", r'let text = "\\(UserDefaults.standard)"') == []
    assert ownership_errors("GalleryFeature", r'let text = #"\(UserDefaults.standard)"#') == []
    assert ownership_errors("GalleryFeature", r'let text = "\(value /* UserDefaults.standard */)"') == []
    assert imports_in_text('/* import GalleryFeature\n/* import ScoreFeature */ */\nimport TransportCore') == {"TransportCore"}
    assert imports_in_text('let text = #"""\nimport GalleryFeature\n"""#\nimport struct StorageCore.AppStorageSession') == {"StorageCore"}
    service_path = "BIT101-iOS/Example.swift"
    for source in ('let files = AppFileSystem.files', 'let files = LocalAppFileService()', 'let preferences = UserDefaults(suiteName: "global")'):
        assert ownership_errors("GalleryFeature", source)
    for source in ('LocalAppFileService.init()', 'let files: LocalAppFileService = .init()', 'let prefs: Swift.Optional<UserDefaults> = .standard', 'let prefs: Swift.Array<UserDefaults> = [.standard]', 'let prefs: Swift.Dictionary<String, UserDefaults> = ["prefs": .standard]'):
        assert ownership_errors("ScheduleFeature", source) and service_boundary_errors("Modules/ScheduleFeature/Sources/Example.swift", source), source
    assert ownership_errors("GalleryFeature", "URLSessionTransport.clearSharedCache()") and service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", "URLSessionTransport.clearSharedCache()")
    for source in ('let regex = /FileManager.default/', 'let regex = #/UserDefaults.standard [a/b]/#', 'let regex = flag ? /URLSession.shared/ : /safe/'):
        assert ownership_errors("GalleryFeature", source) == []
        assert service_boundary_errors(service_path, source) == []
        assert len(swift_code(source)) == len(source)
    assert ownership_errors("GalleryFeature", "let result = amount / UserDefaults.standard.integer(forKey: key)")
    for source in (
        "let session = URLSession(configuration: configuration)",
        "import CoreFoundation; let createSocket = CFSocketCreate; let connectSocket = CFSocketConnectToAddress",
        "let createStreams = CFStreamCreatePairWithSocketToHost; let connectPeer = CFStreamCreatePairWithPeerSocketSignature",
        "import Darwin; let channel = socket(AF_INET, SOCK_STREAM, 0); connect(channel, address, size); send(channel, bytes, size, 0)",
        "let openSocket = Darwin.socket; let sendBytes = Glibc.send",
        "import CoreFoundation; let readFile = CFReadStreamCreateWithFile; let writeFile = CFWriteStreamCreateWithFile",
        "try await transport.data(for: request)",
        "session.dataTask(with: request)",
        "let manager: FileManager = .default",
        "try Data(contentsOf: url)",
        "let bytes: Data = try .init(contentsOf: url)",
        "func parse(url: URL) throws { let bytes: Data = try .init(contentsOf: url) }",
        "let image = UIImage.init(contentsOfFile: path)",
        'func persist(_ image: UIImage, directory: URL) throws { try image.pngData()?.write(to: directory.appendingPathComponent("x")) }',
        'func persist(_ image: UIImage, directory: URL) throws { try image.jpegData(compressionQuality: 1)?.write(to: directory.appending(path: "x")) }',
        'func exists(_ url: NSURL) throws { var value: AnyObject?; try url.getResourceValue(&value, forKey: .fileSizeKey) }',
        "let stream = InputStream.init(url: url)",
        "var stream: InputStream?; stream = .init(url: url)",
        "func stream() -> InputStream? { .init(url: url) }",
        "let fd = open(path, O_RDONLY); read(fd, &buffer, count)",
        "let fd = Darwin.open(path, O_RDONLY); Darwin.read(fd, &buffer, count)",
        "Glibc.fopen(path, mode)",
        "try FileHandle(forReadingFrom: url)",
        "try String.init(contentsOf: url, encoding: .utf8)",
        "func save(data: Data, url: URL) throws { try data.write(to: url) }",
        'try "value".write(toFile: path, atomically: true, encoding: .utf8)',
        "let data = Data(); try data.write(to: url)",
        "func bytes() -> Data { Data() }; try bytes().write(to: url)",
        "let data: Data? = nil; try data?.write(to: url)",
        "func dump(_ data: [Data], _ target: URL) throws { try data[0].write(to: target) }",
        "func dump(_ data: [Data?], _ target: URL) throws { try data[0]?.write(to: target) }",
        'func dump(_ data: Dictionary<String, Data>, _ target: URL) throws { try data["key"]?.write(to: target) }',
        "func dump(_ data: [Data], _ target: URL) throws { for item in data { try item.write(to: target) } }",
        "func dump(_ data: [Data], _ target: URL) throws { try data.forEach { try $0.write(to: target) } }",
        "func save(bytes: () -> Data, target: URL) throws { try bytes().write(to: target) }",
        "struct Snapshot { let data: Data }; func dump(_ snapshot: Snapshot, _ target: URL) throws { try snapshot.data.write(to: target) }",
        "Darwin.readlink(path, buffer, count)",
        "func read(_ message: String) {}; read(fd, buffer, count)",
        "let data = try JSONEncoder().encode(value); try data.write(to: url)",
        "let encoder = PropertyListEncoder(); let data = try encoder.encode(value); try data.write(to: url)",
        'let data = "hello".data(using: .utf8)!; try data.write(to: url)',
        "let data = try JSONSerialization.data(withJSONObject: value); try data.write(to: url)",
        "rename(old, new)", "remove(path)",
        "try url.resourceValues(forKeys: [.fileSizeKey])",
        "url.resolvingSymlinksInPath()",
        "let image = UIImage(contentsOfFile: path)",
        "let monitor = NWPathMonitor()",
        "let defaults: UserDefaults = .standard",
        "let factory: () -> UserDefaults = { .standard }",
        "let factory: (Model) -> UserDefaults = { _ in .standard }",
        'let factory: () -> UserDefaults = { .init(suiteName: "fixture")! }',
        "func choose() -> Optional<UserDefaults> { .standard }",
        'let map: [String: UserDefaults] = ["fixture": .standard]',
        'let defaults: UserDefaults? = .init(suiteName: "module-owned")',
        "func configure(defaults: UserDefaults = .standard) {}",
        "func configure(defaults: UserDefaults? = . standard) {}",
        "struct Store { var defaults: UserDefaults { .standard } }",
        "struct Store { let defaults: UserDefaults; init() { defaults = .standard } }",
        "func preferences() -> UserDefaults { .standard }",
        "func pick(_ flag: Bool, _ supplied: UserDefaults) -> UserDefaults { flag ? .standard : supplied }",
        "let preferences: [UserDefaults] = [.standard]",
        'func accept(_ value: UserDefaults?) {}; accept(.standard); accept(.init(suiteName: "review"))',
        'struct State { let prefs: UserDefaults? }; State(prefs: .init(suiteName: "review"))',
        'UserDefaults.self.standard', 'UserDefaults.self.init(suiteName: "review")',
        'try Data.self.init(contentsOf: url)',
        'let openFile = Darwin.open; let fd = openFile(path, 0)',
        "let underlying = error.userInfo[NSUnderlyingErrorKey]",
        "let allowed = CharacterSet.urlQueryAllowed",
        r'let text = "\(try Data(contentsOf: url))"',
    ):
        assert service_boundary_errors(service_path, source), source
    assert ownership_errors("GalleryFeature", "struct Store { var defaults: UserDefaults { .standard } }")
    assert ownership_errors("GalleryFeature", "AppFileSystem.self.files")
    assert ownership_errors("GalleryFeature", "struct Store { let defaults: UserDefaults; init() { defaults = .standard } }")
    for source in ('let defaults: UserDefaults? = .init(suiteName: "module-owned")',
                   "let factory: () -> UserDefaults = UserDefaults.init; let preferences = factory()",
                   "let factory: () -> LocalAppFileService = LocalAppFileService.init; let files = factory()",
                   "func configure(defaults: UserDefaults? = .standard) {}",
                   'struct Store { var defaults: Foundation.UserDefaults?; func configure() { defaults = .init(suiteName: "module-owned") } }',
                   'func preferences() -> UserDefaults? { .init(suiteName: "module-owned") }'):
        assert ownership_errors("GalleryFeature", source), source
        assert service_boundary_errors("Modules/GalleryFeature/Sources/Example.swift", source), source
    for source in (
        "typealias Preferences = UserDefaults; let store = Preferences.standard",
        "typealias First = Foundation.UserDefaults; typealias Second = First; let store: Second = .standard",
        'typealias Preferences = UserDefaults; let store = Preferences(suiteName: "module-owned")',
        "struct Owner { typealias Preferences = UserDefaults }; let store = Owner.Preferences.standard",
        "func configure() { typealias Preferences = UserDefaults; let store = Preferences.standard }",
        "typealias Session = URLSession; let session = Session.shared",
        "typealias Files = FileManager; let files = Files.default",
    ):
        assert ownership_errors("GalleryFeature", source), source
        assert service_boundary_errors(service_path, source), source
    assert ownership_errors("GalleryFeature", "let factory: (UserDefaults) -> Model = { _ in .standard }") == []
    alias_index = swift_syntax_index_sources({"aliases.swift": "typealias First = UserDefaults; typealias Second = First"})
    aliases = type_aliases(alias_index)
    assert ownership_errors("GalleryFeature", "let store = Second.standard", "consumer.swift", aliases)
    assert service_boundary_errors("consumer.swift", "let store = Second.standard", aliases)
    external = type_aliases(swift_syntax_index_sources({
        "Modules/StorageCore/Sources/Aliases.swift": "public typealias First = UserDefaults; public typealias Second = First; internal typealias Local = UserDefaults; private typealias Hidden = UserDefaults"}))
    imported = imported_aliases("import StorageCore", (), external)
    consumer = "Modules/GalleryFeature/Sources/Consumer.swift"
    assert ownership_errors("GalleryFeature", "import StorageCore; let store = Second.standard", consumer, imported)
    assert service_boundary_errors(consumer, "import StorageCore; let store = StorageCore.Second.standard", imported)
    assert ownership_errors("GalleryFeature", "import StorageCore; struct Second { static let standard = 1 }; let store = Second.standard", consumer, imported) == []
    assert ownership_errors("GalleryFeature", "import StorageCore; let store = Local.standard; let hidden = Hidden.standard", consumer, imported) == []
    assert ownership_errors("GalleryFeature", 'typealias Preferences = UserDefaults; let text = "Preferences.standard"') == []
    assert ownership_errors("GalleryFeature", "typealias Preferences = UserDefaults; struct Model { let Preferences: Int }; let value = model.Preferences") == []
    assert ownership_errors("GalleryFeature", "typealias Preferences = UserDefaults; struct Item { var standard: Int }; let Preferences = Item(standard: 1); let value = Preferences.standard") == []
    assert service_boundary_errors(service_path, "struct Item { static let standard = Item() }; struct Store { var defaults: UserDefaults; func configure() { defaults = .standard }; func helper() { let defaults: Item = .standard } }")
    assert service_boundary_errors(service_path, "struct Item { static let standard = Item() }; struct Store { var defaults: Item; func configure() { defaults = .standard }; func helper() { let defaults: UserDefaults = .standard } }")
    assert service_boundary_errors(service_path, "struct Item { static let standard = Item() }; struct Store { var defaults: Item; func configure() { defaults = .standard }; func helper() { let defaults: UserDefaults } }") == []
    for source in (
        "// URLSession.shared\nlet text = #\"Data(contentsOf: url)\"#",
        "try files.writeData(data, to: url, options: [.atomic])",
        "try await client.send(request)",
        "func read(value: Data) -> Data { value }; let bytes = read(value: input)",
        "struct Reader { func read() {}; func run() { read() } }",
        "struct Item { init(url: URL) {} }; let item: Item = .init(url: url)",
        'struct Item { init(suiteName: String) {} }; let item: Item = .init(suiteName: "business")',
        "FileHandle.standardOutput.write(data)",
        "FileHandle.standardError.write(data)",
        "defaults.data(forKey: key)",
        "let directory: FileManager.SearchPathDirectory = .cachesDirectory",
        "let options: FileManager.DirectoryEnumerationOptions = []",
        "struct Store { var defaults: UserDefaults { log(.standard); return supplied } }",
    ):
        assert service_boundary_errors(service_path, source) == [], source
    assert service_boundary_errors("Modules/StorageCore/Sources/AppFileService.swift", "try data.write(to: url)") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; let message = Message(); message.write(to: 42)") == []
    assert service_boundary_errors(service_path, "struct Message { func encode(_ value: Int) -> Message { self }; func write(to target: Int) {} }; let data = Message().encode(1); data.write(to: 42)") == []
    assert service_boundary_errors(service_path, "func remove(_ value: Int) {}; remove(42); func rename(_ a: Int, _ b: Int) {}; rename(1, 2)") == []
    assert service_boundary_errors(service_path, 'let read = "value"; print(read); let open: (Int) -> Bool = { $0 > 0 }; open(1)') == []
    assert service_boundary_errors(service_path, "func read(message: String = \"\") {}; read(message: \"hello\"); read()") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; func bytes() -> Message { Message() }; bytes().write(to: 42)") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; struct Snapshot { let data: Message }; func send(snapshot: Snapshot, data: [Message]) { snapshot.data.write(to: 42); data[0].write(to: 42) }") == []
    assert service_boundary_errors(service_path, "struct Row { init(contentsOf: [Int]) {} }; let row: Row = .init(contentsOf: [1])") == []
    assert service_boundary_errors(service_path, 'struct Row { init(contentsOf: [Int]) {}; static let standard = Row(contentsOf: []) }; func accept(_ row: Row) {}; accept(.standard); accept(.init(contentsOf: [1]))') == []
    assert service_boundary_errors(service_path, "struct Message { func write(to url: URL) {} }; func send(messages: [Message], url: URL) { for message in messages { message.write(to: url) } }") == []
    assert service_boundary_errors(service_path, "struct Message { func write(to target: Int) {} }; func send(message: Message) { message.write(to: 42) }") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/HTTPClient.swift", "try await transport.data(for: request)") == []
    assert service_boundary_errors(service_path, "func socket(_ value: Int) {}; socket(1); func send(_ value: Int) {}; send(1); enum Delivery { case send; case preflight }") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/SecureURLTransport.swift", "URLSession(configuration: configuration)") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/NetworkPathState.swift", "NWPathMonitor()") == []
    assert service_boundary_errors("Modules/ScheduleFeature/Sources/Example.swift", "DateFormatter()")
    assert service_boundary_errors("Modules/TransportCore/Sources/TaskCancellation.swift", "error.userInfo[NSUnderlyingErrorKey]") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/AppURL.swift", "CharacterSet.urlQueryAllowed") == []
    assert ownership_errors("TransportCore", "URLCache.shared", "Modules/TransportCore/Sources/SecureURLTransport.swift") == []
    assert ownership_errors("TransportCore", "URLCache.shared", "Modules/TransportCore/Sources/HTTPClient.swift")
    assert ownership_errors("AppExternalDisplayCoordinator", "WatchScheduleSyncManager.shared.activateIfNeeded()")
    assert ownership_errors("AppExternalDisplayCoordinator", "activateWatch()") == []
    relocated = swift_syntax_index_sources({"BIT101-iOS/Relocated.swift": """
struct AppExternalDisplayCoordinator { func activate() { activateWatch() } }
extension AppExternalDisplayCoordinator { func unsafe() { WatchScheduleSyncManager.shared.activateIfNeeded() } }
"""})
    assert any(adapter_ownership_errors(facts) for facts in relocated.values())
    unrelated = swift_syntax_index_sources({"BIT101-iOS/Composition.swift": "struct Composition { let manager = WatchScheduleSyncManager.shared }"})
    assert all(adapter_ownership_errors(facts) == [] for facts in unrelated.values())
    for owner in ("AppLocalDataService", "SettingsNetworkService", "AboutSettingsPage", "AccountSettingsPage"):
        relocated = swift_syntax_index_sources({"BIT101-iOS/Relocated.swift":
            f"struct {owner} {{}}\nextension {owner} {{ func unsafe() {{ LoginStorage.shared.clearAllLocalData() }} }}"})
        assert any(adapter_ownership_errors(facts) for facts in relocated.values())


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
    self_test()
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
    errors: list[str] = []
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

    for module, info in modules.items():
        source_root = root / info["path"]
        if info["type"] != "regular" or info["path"] != f"Modules/{module}/Sources":
            errors.append(f"{module} requires a regular target at Modules/{module}/Sources")
        if layer(module) is None:
            errors.append(f"{module} requires a declared architectural layer suffix")
        if not source_root.is_dir():
            errors.append(f"{module} source root missing: {source_root}")
            continue
        source_files = sorted(source_root.rglob("*.swift"))
        aliases = tuple(alias for alias in module_aliases if alias_module(alias[4]) == module)
        unit_context = compilation_type_context(swift_syntax_index_sources({path.relative_to(root).as_posix():
            expanded_resource_source(path.read_text(), imported_aliases(path.read_text(), aliases, module_aliases), path.relative_to(root).as_posix())
            for path in source_files}))
        for path in source_files:
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
    roles = adapter_roles({Path(path).relative_to(root).as_posix(): facts for path, facts in app_syntax.items()})
    for path, facts in app_syntax.items():
        errors.extend(adapter_ownership_errors(facts, Path(path).relative_to(root).as_posix(), roles))

    errors.extend(native_target_errors(root, package, set(modules)))

    for name in ("BIT101-iOS", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"):
        sources = sorted((root / name).rglob("*.swift"))
        aliases = app_aliases if name == "BIT101-iOS" else type_aliases(swift_syntax_index(
            [source for source in sources if "typealias" in swift_code(source.read_text())]))
        unit_context = compilation_type_context(app_syntax if name == "BIT101-iOS" else swift_syntax_index_sources({
            path.relative_to(root).as_posix(): expanded_resource_source(path.read_text(), imported_aliases(path.read_text(), aliases, module_aliases), path.relative_to(root).as_posix()) for path in sources}))
        for source in sources:
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
