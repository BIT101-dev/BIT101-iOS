#!/usr/bin/env python3
"""Validate the local Swift Package source roots and direct dependency graph."""

from __future__ import annotations

import json
from bisect import bisect_right
import re
import subprocess
import sys
from functools import cache
from pathlib import Path

sys.dont_write_bytecode = True
from swift_source_index import canonical_type_scope, declaration_conformances, scope_contains_type, expected_argument_types, swift_syntax_index, swift_syntax_index_sources, resource_context_type, visible_variables, matching_functions, compilation_type_context, local_member_calls, swift_code
from validation_policy import coverage_registry_findings
from swift_type_index import SwiftBindingTypes
from network_capability_rules import FOUNDATION_COLLECTION_TYPES, NETWORK_SYSTEM_FUNCTIONS
from validation_inputs import manifest_targets, read_manifest

ROOT = Path(__file__).resolve().parents[1]

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
    "CoreTransferable",
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
        if layer(module) in {"Domain", "Contracts"}:
            pending, reachable = list(dependencies), set()
            while pending:
                dependency = pending.pop()
                if dependency in reachable: continue
                reachable.add(dependency)
                pending.extend(manifest.get(dependency, set()) - reachable)
            for dependency in sorted(reachable & SHARED_MODULES):
                errors.append(f"pure {layer(module).lower()} boundary: {module} -> {dependency}")
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
        prefix = code[:len(encoded[:start].decode())]
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


SERVICE_RESOURCE_OWNERS = {
    'web': {('GalleryFeature', 'GalleryRootViewScene.GalleryWebView'), ('GalleryFeature', 'GalleryWebCoordinator')},
    'transport': {('TransportCore', owner) for owner in ('HTTPClient', 'HTTPTransmissionMetrics', 'HTTPBoundedTransfer', 'HTTPTransport',
        'URLSession', 'URLSessionTransport', 'NoRedirectURLSessionDelegate', 'HTTPSUpgradingRedirectDelegate', 'UncachedHTTPTransport')},
    'cache': {('TransportCore', 'URLSessionTransport')},
    'requests': {('TransportCore', owner) for owner in ('HTTPClient', 'HTTPTransport', 'URLSession', 'URLSessionTransport', 'UncachedHTTPTransport')},
    'connections': {('TransportCore', 'NetworkPathState'), ('BIT101-iOS', 'UITestControlServer')},
    'errors': {('TransportCore', 'ErrorChain')},
    'form': {('TransportCore', 'HTTPFormEncoding')},
    'files': {('StorageCore', 'LocalAppFileService')},
    'preferences': {('BIT101-iOS', 'AppFileDirectories')},
}


def resource_permissions(path: str, source: str):
    from swift_type_index import compilation_unit
    unit, facts = compilation_unit(path), resource_facts(source)
    encoded = source.encode()
    line_starts = [0] + [match.end() for match in re.finditer(b'\n', encoded)]
    def owner(point):
        nominal = canonical_type_scope(point['scope'])
        return (unit, '.'.join(nominal)) if nominal else None
    points = [(point['start'], point['start'] + len(point.get('value', point.get('name', '')).encode()), len(point['scope']), owner(point))
        for point in facts['members'] + facts['scopedIdentifiers'] + facts['typeNames'] + facts['typedVariables'] + facts['invocations']]
    line_owners = {}
    for point in facts['invocations'] + facts['members'] + facts['scopedIdentifiers']:
        if point.get('isExpressionReference', True):
            line_owners.setdefault(bisect_right(line_starts, point['start']), set()).add(owner(point))
    def permitted(capability, *, offset=None, line=None):
        allowed = SERVICE_RESOURCE_OWNERS[capability]
        if line is not None:
            owners = line_owners.get(line, set())
            return bool(owners) and owners <= allowed
        candidates = [point for point in points if point[0] <= offset < point[1]]
        return bool(candidates) and min(candidates, key=lambda point: (point[1] - point[0], -point[2]))[3] in allowed
    return permitted


def service_boundary_errors(path: str, source: str, aliases: tuple = (), context: tuple = ((), ()), *, call_context=None, origin=None) -> list[str]:
    """Enforce resource capabilities on their owning module and declaration."""
    source = local_resource_source(expanded_resource_source(source, aliases, path), origin or path, call_context)
    source = normalized_resource_source(source)
    if call_context: call_context = call_context.replacing_source(origin or path, resource_facts(source))
    code, permitted = swift_code(source), resource_permissions(path, source)
    from network_capability_rules import NETWORK_PLATFORM_CONNECTION_TYPES, NETWORK_PLATFORM_TRANSPORT_TYPES, platform_stream_request
    patterns = [
        (r"\bAsyncImage\b", "load remote images through MediaKit", None),
        (r"\b(?:Process|NSTask)\b", "keep subprocess execution in host tooling", None),
        (r"\b(?:" + '|'.join(sorted(NETWORK_PLATFORM_TRANSPORT_TYPES | {'URLCache'})) + r")\b", "use TransportCore transport and cache services", 'transport'),
        (r"\b(?:CFSocket\w*|CFStreamCreatePairWith(?:Socket|PeerSocketSignature)\w*|CFReadStreamCreateForHTTPRequest|CFHTTPMessageCreateRequest)\b", "use TransportCore network services", 'transport'),
        (r"\.\s*(?:data|download|upload|bytes)\s*\(\s*for\s*:", "send requests through HTTPClient", 'requests'),
        (r"\.\s*(?:dataTask|downloadTask|uploadTask|webSocketTask)\s*\(", "send requests through HTTPClient", 'requests'),
        (r"\b(?:" + '|'.join(sorted(NETWORK_PLATFORM_CONNECTION_TYPES | {'NWPathMonitor', 'NWTCPConnection', 'NWUDPSession'})) + r")\b", "use TransportCore network services", 'connections'),
        (r"\.\s*userInfo\s*\[\s*NSUnderlyingErrorKey\s*\]", "traverse underlying errors through ErrorChain", 'errors'),
        (r"\bCharacterSet\s*\.\s*urlQueryAllowed\b", "encode form fields through HTTPFormEncoding", 'form'),
        (r"\b(?:DispatchIO|CF(?:Read|Write)StreamCreateWithFile)\b", "read and write files through AppFileService", 'files'),
        (r"\bFileManager\b(?!\s*\.\s*(?:SearchPathDirectory|SearchPathDomainMask|DirectoryEnumerationOptions|VolumeEnumerationOptions|URLRelationship|ItemReplacementOptions)\b)", "use AppFileService", 'files'),
        (r"\b(?:Data|NSData|NSMutableData|String|NSString|NSMutableString|XMLParser|" + '|'.join(sorted(FOUNDATION_COLLECTION_TYPES)) + r")\s*(?:\.\s*self\s*)?(?:\.\s*init\s*)?\(\s*(?:contentsOf|contentsOfFile|contentsOfURL|contentsOfMappedFile)\s*:", "read files through AppFileService", 'files'),
        (r"\bNS(?:Keyed)?Archiver\s*\.\s*archiveRootObject\b", "write files through AppFileService", 'files'),
        (r"\bNS(?:Keyed)?Unarchiver\s*\.\s*unarchiveObject\s*\(\s*withFile\s*:", "read files through AppFileService", 'files'),
        (r"\.\s*(?:resourceValues|setResourceValues|getResourceValue|setResourceValue|resolvingSymlinksInPath|checkResourceIsReachable)\s*\(", "access file metadata through AppFileService", 'files'),
        (r"\b(?:FileHandle|NSFileHandle)\b(?!\s*\.\s*standard(?:Output|Error)\b)|\b(?:NSFileCoordinator|CGImageSourceCreateWithURL|CGImageDestinationCreateWithURL)\b", "access files through AppFileService", 'files'),
        (r"\b(?:FileWrapper|NSFileWrapper)\s*(?:\.\s*init\s*)?\(\s*(?:url|path)\s*:", "access files through AppFileService", 'files'),
        (r"\b(?:UIImage|NSImage|InputStream|OutputStream)\s*(?:\.\s*init\s*)?\(\s*(?:contentsOfFile|contentsOf|url|fileAtPath|toFileAtPath)\s*:", "access files through AppFileService", 'files'),
        (r"\bCGDataProvider\s*(?:\.\s*init\s*)?\(\s*url\s*:", "access files through AppFileService", 'files'),
        (r"\bUserDefaults\s*\.\s*standard\b|\bUserDefaults\s*=\s*\.\s*standard\b|\bUserDefaults\s*(?:\(|\.\s*init\b)", "select preferences through the host storage entry", 'preferences'),
    ]
    if path.startswith("Modules/") and not path.startswith("Modules/TransportCore/"):
        patterns.append((r"\bURLSessionTransport\s*\.\s*(?:make|clearSharedCache)\b", "inject host-selected transport resources", None))
    if path.startswith("Modules/") and not path.startswith("Modules/StorageCore/"):
        patterns.append((r"\bLocalAppFileService\s*(?:\(|\.\s*init\b)", "inject host-selected file resources", None))
    if path.startswith("Modules/ScheduleFeature/"):
        patterns.append((r"\bDateFormatter\s*\(", "format schedule dates through ScheduleDateCodec", None))
    errors = []
    if 'getStreamsToHost' in code:
        bindings = call_context or SwiftBindingTypes({origin or path: resource_facts(source)})
        for call in resource_facts(source)['invocations']:
            if platform_stream_request(bindings.types, origin or path, call, bindings) and not permitted('transport', offset=call['start']):
                line = source.encode()[:call['start']].count(b'\n') + 1
                errors.append(f"service boundary: {path}:{line}: use TransportCore network services")
    errors.extend(f"service boundary: {path}:{line}: use TransportCore network services"
        for line in implicit_file_accesses(source, POSIX_NETWORK_FUNCTIONS) if not permitted('transport', line=line))
    errors.extend(f"service boundary: {path}:{line}: keep subprocess execution in host tooling"
        for line in implicit_file_accesses(source, POSIX_PROCESS_FUNCTIONS))
    if path.startswith("Modules/") and not path.startswith("Modules/StorageCore/"):
        errors.extend(f"service boundary: {path}:{line}: inject host-selected file resources"
            for line in implicit_resource_accesses(source, "LocalAppFileService", context[0], call_context=call_context, origin=origin or path))
    errors.extend(f"service boundary: {path}:{line}: access files through AppFileService"
        for line in implicit_file_accesses(source, call_context=call_context, origin=origin or path) if not permitted('files', line=line))
    errors.extend(f"service boundary: {path}:{line}: access files through AppFileService"
        for line in file_member_accesses(source, properties=context[0], call_context=call_context, origin=origin or path) if not permitted('files', line=line))
    errors.extend(f"service boundary: {path}:{line}: select preferences through the host storage entry: UserDefaults"
        for line in implicit_resource_accesses(source, properties=context[0], call_context=call_context, origin=origin or path) if not permitted('preferences', line=line))
    errors.extend(f"service boundary: {path}:{line}: select preferences through the host storage entry: CFPreferences"
        for line in implicit_file_accesses(source, CF_PREFERENCE_FUNCTIONS) if not permitted('preferences', line=line))
    local_names = ("data", "download", "upload", "bytes", "dataTask", "downloadTask", "uploadTask", "webSocketTask",
        "resourceValues", "setResourceValues", "getResourceValue", "setResourceValue", "resolvingSymlinksInPath", "checkResourceIsReachable")
    local_calls = local_member_calls(source, local_names, context) if re.search(r"\.\s*(?:" + '|'.join(local_names) + r")\s*\(", code) else set()
    for pattern, rule, capability in patterns:
        for match in re.finditer(pattern, code):
            offset = len(source[:match.start()].encode())
            if match[0].strip() == 'WKWebView' and permitted('web', offset=offset): continue
            if capability and permitted(capability, offset=offset): continue
            if rule in {"send requests through HTTPClient", "access file metadata through AppFileService"} and offset in local_calls: continue
            line = code.count("\n", 0, match.start()) + 1
            errors.append(f"service boundary: {path}:{line}: {rule}: {match[0].strip()}")
    return errors


POSIX_FILE_FUNCTIONS = r"open|openat|creat|close|read|pread|readv|write|pwrite|writev|lseek|fopen|freopen|fread|fwrite|fclose|rename|remove|unlink|mkdir|rmdir|stat|lstat|fstat|truncate|ftruncate|fsync|fdatasync|access|opendir|readdir|closedir|mmap|munmap|readlink|readlinkat|symlink|symlinkat|link|linkat|renameat|unlinkat|mkdirat|fstatat|chmod|fchmod|fchmodat|chown|fchown|lchown|fchownat|fdopen|fflush|fseek|ftell|fgetpos|fsetpos|rewind|scandir|removefile|copyfile|fcopyfile|realpath|getxattr|fgetxattr|setxattr|fsetxattr|listxattr|flistxattr|removexattr|fremovexattr"
POSIX_NETWORK_FUNCTIONS = '|'.join(sorted(NETWORK_SYSTEM_FUNCTIONS))
POSIX_PROCESS_FUNCTIONS = r"posix_spawn|posix_spawnp|fork|vfork|execl|execlp|execle|execv|execvp|execve|popen|system"
CF_PREFERENCE_FUNCTIONS = r"(?:CoreFoundation\s*\.\s*)?CFPreferences(?:CopyAppValue|CopyValue|CopyMultiple|CopyKeyList|CopyApplicationList|SetAppValue|SetValue|SetMultiple|AppSynchronize|Synchronize|GetAppBooleanValue|GetAppIntegerValue|AppValueIsForced|AddSuitePreferencesToApp|RemoveSuitePreferencesFromApp)"
FILE_INITIALIZER_TYPES = r"(?:Foundation\.|UIKit\.|AppKit\.|CoreGraphics\.)?(?:Data|NSData|NSMutableData|String|NSString|NSMutableString|XMLParser|UIImage|NSImage|InputStream|OutputStream|FileWrapper|NSFileWrapper|CGDataProvider|" + '|'.join(sorted(FOUNDATION_COLLECTION_TYPES)) + r")\??"


def local_resource_source(source: str, path: str, call_context=None) -> str:
    """Preserve source offsets while separating project types from platform resources."""
    from network_capability_rules import NETWORK_PLATFORM_CONNECTION_TYPES, NETWORK_PLATFORM_TRANSPORT_TYPES
    resources = FOUNDATION_COLLECTION_TYPES | NETWORK_PLATFORM_CONNECTION_TYPES | NETWORK_PLATFORM_TRANSPORT_TYPES | {
        'FileManager', 'UserDefaults', 'URLCache', 'HTTPCookieStorage', 'UIApplication', 'UIScreen',
        'Data', 'NSData', 'NSMutableData', 'String', 'NSString', 'NSMutableString', 'XMLParser',
        'UIImage', 'NSImage', 'Stream', 'NSStream', 'InputStream', 'OutputStream', 'NSInputStream', 'NSOutputStream', 'FileWrapper', 'NSFileWrapper',
        'FileHandle', 'NSFileHandle', 'NSFileCoordinator', 'NSKeyedArchiver', 'NSKeyedUnarchiver',
        'NSArchiver', 'NSUnarchiver', 'CGDataProvider', 'CharacterSet', 'DispatchIO', 'NWPathMonitor',
        'Process', 'NSTask', 'AsyncImage',
    }
    code = swift_code(source)
    if not any(re.search(r'\b' + name + r'\b', code) for name in resources): return source
    facts = resource_facts(source)
    types = (call_context or SwiftBindingTypes({path: facts})).types
    identities = {namespace + '.' + '.'.join(owner) for namespace, owner in types.records}
    declared = {types.resolve(owner_path, '.'.join(node['scope'] + [node['name']]), aliases=False)
        for owner_path, entries in types.index.items() for node in entries.get('declarations', [])
        if node['kind'] != 'extension'}
    encoded = bytearray(source.encode())
    for node in facts['scopedIdentifiers']:
        if node['value'] not in resources: continue
        prefix = code[:len(source.encode()[:node['start']].decode())]
        qualifier = re.search(r'(?:\b\w+\s*\.\s*)+$', prefix)
        name = re.sub(r'\s+', '', qualifier[0]) + node['value'] if qualifier else node['value']
        key = types.resolve(path, name, node['scope'])
        if key not in declared: continue
        terminal = types.terminal_name(path, name, node['scope'])
        if terminal not in identities: continue
        if any(base.removeprefix('Foundation.') in resources for base in types.bases(key)): continue
        encoded[node['start']] = ord('_')
    return encoded.decode()


def normalized_resource_source(source: str) -> str:
    resources = "Data|NSData|NSMutableData|String|NSString|NSMutableString|XMLParser|NSKeyedArchiver|NSKeyedUnarchiver|NSArchiver|NSUnarchiver|UIImage|NSImage|Stream|NSStream|InputStream|OutputStream|NSInputStream|NSOutputStream|FileWrapper|NSFileWrapper|UserDefaults|FileManager|URLSession|URLSessionTransport|URLCache|AppFileSystem|LocalAppFileService"
    code = swift_code(source)
    if re.search(r"\b(?:" + resources + r")\s*\.\s*self\b", code):
        facts = resource_facts(source)
        def metatype(name, point, seen=frozenset(), explicit_self=False):
            if name in seen: return None
            variables = visible_variables(facts, point, name, explicit_self)
            bindings = [binding for binding in facts['bindings'] if binding.get('bindingName') == name
                and binding['start'] < point['start'] and point['scope'][:len(binding['scope'])] == binding['scope']
                and (not explicit_self or not binding.get('lexicalScope'))
                and point.get('lexicalScope', [])[:len(binding.get('lexicalScope', []))] == binding.get('lexicalScope', [])]
            visible = variables + bindings
            if not visible: return None
            nearest = max(visible, key=lambda row: (len(row.get('lexicalScope', [])), row['start'], bool(row.get('bindingName'))))
            if not nearest.get('bindingName'): return None
            value = nearest.get('initializerReference', '')
            direct = re.fullmatch(r"((?:Foundation\.)?(?:" + resources + r"))\.self", value)
            return direct[1] if direct else metatype(value, nearest, seen | {name})
        encoded = source.encode()
        replacements = []
        binding_names = {binding.get('bindingName') for binding in facts['bindings']}
        for node in facts['scopedIdentifiers']:
            if not node.get('isExpressionReference') or node['value'] not in binding_names: continue
            qualifier = re.search(r'(\w+)\s*\.\s*$', code[:len(encoded[:node['start']].decode())])
            if qualifier and qualifier[1] != 'self': continue
            if target := metatype(node['value'], node, explicit_self=bool(qualifier)):
                begin = len(encoded[:node['start']].decode()[:qualifier.start()].encode()) if qualifier else node['start']
                replacements.append((begin, node['start'] + len(node['value'].encode()), target.encode()))
        for start, end, replacement in sorted(replacements, reverse=True):
            encoded = encoded[:start] + replacement + encoded[end:]
        source = encoded.decode()
    return re.sub(r"\b((?:Foundation\.)?(?:" + resources + r"))\s*\.\s*self(?=\s*\.)",
        lambda match: match[1] + "\n" * match[0].count("\n"), source)


@cache
def resource_facts(source: str) -> dict:
    return swift_syntax_index_sources({"resource-source": source})["resource-source"]


@cache
def file_member_accesses(source: str, properties: tuple = (), *, call_context=None, origin='resource-source') -> list[int]:
    if not re.search(r"\.\s*(?:write|read|matchesContents)\b|\bCGPDFDocument\b", swift_code(source)): return []
    facts = dict(resource_facts(source))
    facts["typedVariables"] = facts["typedVariables"] + [dict(scope=list(scope), name=name, type=kind, start=-1, lexicalScope=[])
        for scope, name, kind in properties]
    encoded = source.encode()
    binding_types = None
    file_types = FOUNDATION_COLLECTION_TYPES | {"Data", "NSData", "NSMutableData", "String", "NSString", "NSMutableString", "FileWrapper", "NSFileWrapper"}
    def normalized_type(value: str) -> str:
        value = value.strip().removeprefix("Foundation.").removeprefix("CoreFoundation.").removesuffix("?")
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
        nonlocal binding_types
        expression = re.sub(r"^(?:(?:try[!?]?|await)\s+)+", "", expression.strip()).rstrip("!?")
        if expression.startswith("(") and expression.endswith(")"):
            expression = expression[1:-1].strip()
        cast = re.fullmatch(r".+\s+as[!?]?\s+([\w.]+\??)", expression, re.DOTALL)
        if cast: return normalized_type(cast[1])
        result = re.match(r"(.+)\.\s*(encode|data|pngData|jpegData|appendingPathComponent|appendingPathExtension|appending)\s*\(", expression, re.DOTALL)
        if result:
            receiver_type = value_type(result[1], point, seen)
            if result[2] == "encode" and receiver_type in {"JSONEncoder", "PropertyListEncoder"}: return "Data"
            if result[2] == "data" and receiver_type in {"String", "NSString", "NSMutableString", "JSONSerialization", "PropertyListSerialization"}: return "Data"
            if result[2] in {"pngData", "jpegData"} and receiver_type == "UIImage": return "Data"
            if result[2].startswith("appending") and receiver_type in {"URL", "NSURL"}: return receiver_type
        if re.match(r'^#*"', expression): return "String"
        if expression.startswith("[") and expression.endswith("]"):
            item = value_type(expression[1:-1].split(",", 1)[0], point, seen)
            return "[" + item + "]" if item else None
        subscript = re.fullmatch(r"(.+)\[[^\[\]]+\]", expression, re.DOTALL)
        if subscript:
            return element_type(value_type(subscript[1], point, seen))
        method = re.match(r"(.+)\.\s*(\w+)\s*\(", expression, re.DOTALL)
        if method:
            if binding_types is None: binding_types = call_context or SwiftBindingTypes({origin: facts})
            owner = point['scope'] if method[1] == 'self' else (value_type(method[1], point, seen) or '').split('.')
            invocation = next((call for call in facts['invocations'] if call['value'] == expression
                and call['scope'] == point['scope'] and call.get('lexicalScope') == point.get('lexicalScope')), None)
            if owner and (returned := binding_types.method_return(origin, owner, method[2], invocation)):
                return normalized_type(returned)
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
        if re.match(r"(?:CoreGraphics\.)?CGPDFDocument\s*(?:\.\s*init\s*)?\(", call['value']):
            arguments = call.get('arguments') or []
            if arguments and value_type(arguments[0], call) in {'URL', 'NSURL', 'CFURL'}:
                hits.add(encoded[:call['start']].count(b'\n') + 1)
        match = re.match(r"(.+)\.\s*(write|read|matchesContents)\s*\(\s*(?:to|toFile|from|of)\s*:", call["value"], re.DOTALL)
        if match:
            receiver = value_type(match[1], call)
            arguments = call.get("arguments") or []
            target = value_type(arguments[0], call) if arguments else None
            if (match[2] == "write" and receiver in file_types or receiver in {"FileWrapper", "NSFileWrapper"}) or (match[2] == "write" and receiver is None and (target == "URL" or (target == "String" and "toFile" in call["argumentLabels"]))):
                hits.add(encoded[:call["start"]].count(b"\n") + 1)
    for reference in facts["members"]:
        if re.fullmatch(r'(?:CoreGraphics\.)?CGPDFDocument\s*\.\s*init', reference['value']):
            contexts = expected_argument_types(facts, reference, context=call_context, path=origin)
            contexts.extend(binding.get('bindingType', '') for binding in facts['bindings']
                if binding['start'] <= reference['start'] < binding['start'] + len(binding['value'].encode()))
            prefix = encoded[:reference['start']].decode()
            assignment = re.search(r'\b(\w+)\s*=\s*$', prefix)
            if assignment:
                contexts.extend(variable['type'] for variable in visible_variables(facts, reference, assignment[1]))
            if any(re.search(r'\bCFURL\b', context) for context in contexts):
                hits.add(encoded[:reference['start']].count(b'\n') + 1)
        match = re.fullmatch(r"(.+)\.\s*(write|read|matchesContents)(?:\(\s*(?:\w+\s*:\s*)+\))?", reference["value"], re.DOTALL)
        if not match: continue
        receiver = value_type(match[1], reference) or normalized_type(match[1])
        if match[2] == "write" and receiver in file_types or receiver in {"FileWrapper", "NSFileWrapper"}:
            hits.add(encoded[:reference["start"]].count(b"\n") + 1)
    return sorted(hits)


@cache
def implicit_file_accesses(source: str, functions: str = POSIX_FILE_FUNCTIONS, *, call_context=None, origin='resource-source') -> list[int]:
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
        if not reference.get("isExpressionReference", True): continue
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
        elif functions == POSIX_FILE_FUNCTIONS and re.match(r"\.\s*init\s*\(\s*(?:contentsOf|contentsOfFile|contentsOfURL|contentsOfMappedFile|url|path|fileAtPath|toFileAtPath)\s*:", value):
            prefix = code[:len(encoded[:call["start"]].decode())]
            contexts = expected_argument_types(facts, call, context=call_context, path=origin) + [match[1] for binding in facts["bindings"]
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
                else bool(re.match(r"\.\s*init\s*\(\s*contentsOf(?:File|URL|MappedFile)?\s*:", value))
        if forbidden: hits.add(encoded[:call["start"]].count(b"\n") + 1)
    return sorted(hits)


@cache
def implicit_resource_accesses(source: str, resource: str = "UserDefaults", properties: tuple = (), *, call_context=None, origin='resource-source') -> list[int]:
    code = swift_code(source)
    if not re.search(r"\.\s*(?:standard\b|init\s*\()", code): return []
    facts = dict(resource_facts(source))
    facts["typedVariables"] = facts["typedVariables"] + [dict(scope=list(scope), name=name, type=kind, start=-1, lexicalScope=[])
        for scope, name, kind in properties]
    encoded = source.encode()
    hits = []
    def matches(value, scope):
        if call_context:
            value = re.sub(r'(?<![\w.])(?:Foundation\.|StorageCore\.)?' + resource + r'\b',
                lambda match: call_context.types.terminal_name(origin, match[0], scope), value)
        return resource_context_type(value, resource)
    accesses = [member for member in facts["members"] if resource == "UserDefaults" and re.fullmatch(r"\.\s*standard", swift_code(member["value"]).strip())]
    accesses.extend(call for call in facts["invocations"] if re.match(r"\.\s*init\s*\(", swift_code(call["value"])))
    for member in accesses:
        prefix = code[:len(encoded[:member["start"]].decode())]
        assigned = re.search(r"(?:self\.)?(\w+)\s*=\s*$", prefix)
        inferred = bool(re.search(r"\b(?:Foundation\.|StorageCore\.)?" + resource + r"\??\s*=\s*$", prefix))
        inferred |= any(matches(value, member['scope']) for value in expected_argument_types(facts, member, context=call_context, path=origin))
        inferred |= any(binding["start"] <= member["start"] < binding["start"] + len(binding["value"].encode())
            and (context := re.match(r"\w+\s*:\s*([^={]+)", swift_code(binding["value"])))
            and matches(context[1], binding['scope'])
            and re.search(r"(?:\breturn|\bin|[\{=\[,:?])\s*(?:try[!?]?\s*)?$", prefix)
            for binding in facts["bindings"])
        if assigned:
            matching = visible_variables(facts, member, assigned[1], assigned[0].startswith("self."))
            inferred = inferred or bool(matching and matches(matching[-1]["type"], matching[-1]['scope']))
        inferred = inferred or any(function["start"] <= member["start"] < function["end"]
            and matches(function.get("returnType", ""), function['scope'])
            and re.search(r"(?:\breturn|[\{?:])\s*(?:try[!?]?\s*)?$", prefix) for function in facts["functionRanges"])
        if inferred: hits.append(prefix.count("\n") + 1)
    return hits


def ownership_errors(scope: str, source: str, path: str = "", aliases: tuple = (), properties: tuple = (), *, call_context=None) -> list[str]:
    source = local_resource_source(expanded_resource_source(source, aliases, path or "resource-source"), path or 'resource-source', call_context)
    source = normalized_resource_source(source)
    if call_context: call_context = call_context.replacing_source(path or 'resource-source', resource_facts(source))
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
        for line in implicit_resource_accesses(source, properties=properties, call_context=call_context, origin=path or 'resource-source')] if layer(scope) is not None else []
    if layer(scope) is not None:
        implicit.extend(f"resource ownership: {scope} selects CFPreferences at line {line}"
            for line in implicit_file_accesses(source, CF_PREFERENCE_FUNCTIONS))
    if layer(scope) is not None and scope != "StorageCore":
        implicit.extend(f"resource ownership: {scope} selects LocalAppFileService at line {line}"
            for line in implicit_resource_accesses(source, "LocalAppFileService", properties, call_context=call_context, origin=path or 'resource-source'))
    return implicit + [
        f"resource ownership: {scope} uses {match[0].strip()}"
        for pattern in patterns
        for match in re.finditer(pattern, code)
        if not (scope == "TransportCore" and re.fullmatch(r"URLCache\s*\.\s*shared", match[0])
                and resource_permissions(path, source)('cache', offset=len(source[:match.start()].encode())))
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


def adapter_call_roles(index: dict[str, dict]) -> dict:
    from network_capability_rules import api_invocations, call_can_execute, callback_body_ranges, executed_callback_positions, matching_api_calls
    from swift_type_index import callable_effect_index, compilation_unit, execution_index, receiver_resolver
    index = execution_index(callable_effect_index(index))
    types, resolve_receiver = SwiftBindingTypes(index).types, receiver_resolver(index)
    nodes, by_name, active = {}, {}, {}
    for path, facts in index.items():
        roles = adapter_roles(index, path)
        for function in facts.get('functionRanges', []) + facts.get('accessorRanges', []) + facts.get('inlineClosureRanges', []) + [
                node for node in facts.get('initializers', []) if node.get('isExplicitInitializer')]:
            key = (path, function['start'], function['end'])
            nodes[key] = function
            by_name.setdefault(function['name'], []).append((path, function))
            scope = canonical_type_scope(function['scope'])
            active[key] = {role for owner, role in roles.items() if scope[:len(owner)] == owner}
            active[key].update(owner for owner in function['scope'] if settings_owner(owner))
    edges = {key: set() for key in nodes}
    for path, facts in index.items():
        for call in api_invocations(facts):
            if not call_can_execute(facts, call): continue
            parents = [key for key in nodes if key[0] == path and key[1] <= call['start'] < key[2]]
            if not parents: continue
            caller = min(parents, key=lambda key: key[2] - key[1])
            expression = call['calledExpression']
            receiver, _, name = expression.rpartition('.')
            target_owner = resolve_receiver(dict(call, path=path)) if receiver else None
            candidates = []
            for target_path, function in by_name.get(name, []):
                if compilation_unit(target_path) != compilation_unit(path): continue
                if function.get('isPrivate') and target_path != path: continue
                if receiver in {'', 'self', 'Self'}:
                    if call['scope'][:len(function['scope'])] != function['scope']: continue
                    if function.get('lexicalScope') and (target_path != path or
                        call.get('lexicalScope', [])[:len(function['lexicalScope'])] != function['lexicalScope']): continue
                elif target_owner != '.'.join([compilation_unit(target_path), *function['scope']]): continue
                candidates.append((target_path, function))
            if candidates and receiver in {'', 'self', 'Self'}:
                depth = max((len(function['scope']), len(function.get('lexicalScope', []))) for _, function in candidates)
                candidates = [(target_path, function) for target_path, function in candidates
                    if (len(function['scope']), len(function.get('lexicalScope', []))) == depth]
            matches = matching_api_calls(index, candidates, dict(call, path=path), types=types, conservative=True)
            edges[caller].update((target_path, function['start'], function['end']) for target_path, function in matches)
            positions = executed_callback_positions(call, project_call=bool(matches))
            edges[caller].update((path, start, end) for start, end in callback_body_ranges(facts, call, positions)
                if (path, start, end) in nodes)
    changed = True
    while changed:
        changed = False
        for caller, targets in edges.items():
            for target in targets:
                additions = active[caller] - active[target]
                if additions: active[target].update(additions); changed = True
    return active


def adapter_ownership_errors(facts: dict, path: str = "", roles: dict | None = None, *, call_roles=None) -> list[str]:
    errors = set()
    if roles is None: roles = adapter_roles({path: facts})
    if call_roles is None: call_roles = adapter_call_roles({path: facts})
    for node in facts["scopedIdentifiers"] + facts["members"]:
        scope = canonical_type_scope(node["scope"])
        active_roles = {role for owner, role in roles.items() if scope[:len(owner)] == owner}
        active_roles.update(owner for owner in node["scope"] if settings_owner(owner))
        parents = [key for key in call_roles if key[0] == path and key[1] <= node['start'] < key[2]]
        if parents: active_roles.update(call_roles[min(parents, key=lambda key: key[2] - key[1])])
        line = facts.get('source', '').encode()[:node['start']].count(b'\n') + 1
        for role in active_roles:
            errors.update(f"{path or 'source'}:{line}: {error}" for error in ownership_errors(role, node["value"]))
    return sorted(errors)



def native_target_errors(root: Path, package: dict, modules: set[str]) -> list[str]:
    from code_quality_rules import native_project_targets
    from validation_inputs import SWIFT_ROOTS, NATIVE_PRODUCT_ROOTS, NATIVE_TEST_ROOTS, repository_input_names, native_project_paths
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(root / "BIT101-iOS.xcodeproj/project.pbxproj"),
    ], text=True))
    errors: list[str] = []
    for identifier, path in native_project_paths(project, root).items():
        if project['objects'][identifier].get('isa') == 'PBXFileReference' and not path.exists():
            errors.append(f'工程文件引用需要对应实际文件：{path.relative_to(root) if path.is_relative_to(root) else path}')
    inventory = {root / name for name in repository_input_names(root)
        if Path(name).suffix == '.swift' and Path(name).parts[0] in SWIFT_ROOTS}
    compiled = set()
    for name, declared, sources in native_project_targets(project, root):
        compiled.update(sources)
        for source in sorted(sources - inventory):
            errors.append(f'native target {name} source requires validation inventory registration: {source.relative_to(root)}')
        actual = {module for source in sources for module in imports_in_text(source.read_text(encoding="utf-8"))}
        exported = {module for product in package["products"] if product["name"] in declared for module in product["targets"]}
        for module in actual & modules - exported:
            errors.append(f"native target {name} imports undeclared product for {module}")
    for source in sorted(inventory - compiled):
        if source.relative_to(root).parts[0] in NATIVE_PRODUCT_ROOTS + NATIVE_TEST_ROOTS:
            errors.append(f'native source requires target membership: {source.relative_to(root)}')
    return errors



def main() -> int:
    if sys.argv[1:] not in ([], ["--self-test"]):
        print("usage: check-module-boundaries.py [--self-test]", file=sys.stderr)
        return 2
    if "--self-test" in sys.argv[1:]:
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
    ui_modules = set()
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
        call_context = SwiftBindingTypes(unit_index)
        for path in source_files:
            unit_context = compilation_type_context(unit_index, path.relative_to(root).as_posix())
            text = path.read_text(encoding="utf-8")
            context = imported_aliases(text, aliases, module_aliases)
            imports = raw_imports(text)
            if 'SwiftUI' in imports: ui_modules.add(module)
            errors.extend(platform_errors(module, imports))
            errors.extend(ownership_errors(module, text, path.relative_to(root).as_posix(), context, unit_context[0], call_context=call_context))
            errors.extend(service_boundary_errors(path.relative_to(root).as_posix(), text, context, unit_context, call_context=call_context))
        actual = imported_modules(source_root)
        for dependency in info["dependencies"] - actual.keys():
            errors.append(f"{module} declares unused {dependency}")
        for imported, files in actual.items():
            if imported not in modules:
                errors.append(f"{module} imports unknown module {imported}: {', '.join(sorted(files))}")
            elif imported not in info["dependencies"]:
                errors.append(f"{module} imports undeclared {imported}: {', '.join(sorted(files))}")

    errors.extend(coverage_registry_findings(set(modules), ui_modules))
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

    # 平台副作用适配的资源选择沿声明归属及辅助调用链核对。
    app_syntax = swift_syntax_index(sorted((root / "BIT101-iOS").rglob("*.swift")))
    app_aliases = type_aliases(app_syntax)
    normalized = {}
    for path in app_syntax:
        source = Path(path).read_text()
        expanded = expanded_resource_source(source, imported_aliases(source, app_aliases, module_aliases), Path(path).relative_to(root).as_posix())
        if expanded != source: normalized[path] = expanded
    app_syntax.update(swift_syntax_index_sources(normalized) if normalized else {})
    adapter_index = {Path(path).relative_to(root).as_posix(): facts for path, facts in app_syntax.items()}
    call_roles = adapter_call_roles(adapter_index)
    for path, facts in app_syntax.items():
        source = Path(path).relative_to(root).as_posix()
        errors.extend(adapter_ownership_errors(facts, source, adapter_roles(adapter_index, source), call_roles=call_roles))

    errors.extend(native_target_errors(root, package, set(modules)))

    from validation_inputs import NATIVE_PRODUCT_ROOTS
    for name in NATIVE_PRODUCT_ROOTS:
        sources = sorted((root / name).rglob("*.swift"))
        aliases = app_aliases if name == "BIT101-iOS" else type_aliases(swift_syntax_index(
            [source for source in sources if "typealias" in swift_code(source.read_text())]))
        unit_index = app_syntax if name == "BIT101-iOS" else swift_syntax_index_sources({
            path.relative_to(root).as_posix(): expanded_resource_source(path.read_text(), imported_aliases(path.read_text(), aliases, module_aliases), path.relative_to(root).as_posix()) for path in sources})
        network_index.update(unit_index)
        call_context = SwiftBindingTypes(unit_index)
        for source in sources:
            unit_context = compilation_type_context(unit_index, str(source) if name == "BIT101-iOS" else source.relative_to(root).as_posix())
            text = source.read_text(encoding="utf-8")
            errors.extend(service_boundary_errors(source.relative_to(root).as_posix(), text, imported_aliases(text, aliases, module_aliases), unit_context,
                call_context=call_context, origin=str(source) if name == 'BIT101-iOS' else source.relative_to(root).as_posix()))

    errors.extend(network_capability_findings(network_index))
    if errors:
        for error in errors:
            print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    print(f"module-boundary: {len(modules)} module source roots and direct dependencies pass")
    return 0


if __name__ == "__main__":
    from validation_artifacts import static_audit_lock
    with static_audit_lock(ROOT):
        raise SystemExit(main())
