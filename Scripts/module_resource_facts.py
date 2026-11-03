"""Inspect module ownership and dependencies."""

from __future__ import annotations
from bisect import bisect_right
import re
from functools import cache
from pathlib import Path
from swift_source_index import (
    canonical_type_scope,
    expected_argument_types,
    swift_syntax_index_sources,
    resource_context_type,
    visible_variables,
    matching_functions,
    swift_code,
)
from swift_type_index import SwiftBindingTypes
from network_capability_rules import FOUNDATION_COLLECTION_TYPES, NETWORK_SYSTEM_FUNCTIONS

ROOT = Path(__file__).resolve().parents[1]


GLOBAL_RESOURCE_PATTERN = (
    "\\b(?:UserDefaults\\s*\\.\\s*standard|URLSession\\s*\\.\\s*shared|URLCache\\s*\\.\\s*shared|H"
    "TTPCookieStorage\\s*\\.\\s*shared|FileManager\\s*\\.\\s*default|UIApplication\\s*\\.\\s*share"
    "d|UIScreen\\s*\\.\\s*main)\\b"
)


def type_aliases(index: dict) -> tuple:
    root = Path(__file__).resolve().parents[1]
    return tuple(
        (
            alias["name"],
            alias["type"],
            tuple(alias["scope"]),
            tuple(alias.get("lexicalScope", [])),
            str(Path(path).relative_to(root)) if Path(path).is_absolute() else path,
            alias["start"],
            alias.get("isFilePrivate", False),
            alias.get("isExported", False),
        )
        for path, facts in index.items()
        for alias in facts.get("typeAliases", [])
    )


def alias_module(path: str) -> str:
    parts = Path(path).parts
    return (
        parts[1] if len(parts) > 1 and parts[0] == "Modules" else parts[0] if len(parts) > 1 else ""
    )


@cache
def expanded_resource_source(
    source: str, aliases: tuple = (), path: str = "resource-source"
) -> str:
    code = swift_code(source)
    if "typealias" not in code and not any(
        re.search(r"\b" + re.escape(alias[0]) + r"\b", code) for alias in aliases
    ):
        return source
    facts = swift_syntax_index_sources({path: source})[path]
    aliases = tuple(dict.fromkeys(aliases + type_aliases({path: facts})))

    def lookup(name, scope, lexical, owner_path):
        qualified = name.split(".")
        candidates = []
        for alias in aliases:
            components = (
                qualified[1:]
                if len(qualified) > 1 and qualified[0] == alias_module(alias[4])
                else qualified
            )
            if (
                alias[0] == components[-1]
                and (
                    alias[2] == tuple(components[:-1])
                    if len(components) > 1
                    else scope[: len(alias[2])] == alias[2]
                )
                and (not alias[6] or alias[4] == owner_path)
                and (alias[7] or alias_module(alias[4]) == alias_module(owner_path))
                and (
                    not alias[3] or alias[4] == owner_path and lexical[: len(alias[3])] == alias[3]
                )
            ):
                candidates.append(alias)
        return max(
            candidates,
            key=lambda alias: (
                alias_module(alias[4]) == alias_module(owner_path),
                len(alias[2]),
                len(alias[3]),
            ),
            default=None,
        )

    def resolve(alias, visited=()):
        if alias in visited:
            return alias[0]
        value = re.sub(r"\s+", "", alias[1])
        if not re.fullmatch(r"[\w.]+\??", value):
            return alias[0]
        target = lookup(value.removesuffix("?"), alias[2], alias[3], alias[4])
        return (resolve(target, visited + (alias,)) if target else value.removesuffix("?")) + (
            "?" if value.endswith("?") else ""
        )

    encoded = source.encode()
    replacements = []
    alias_names = {alias[0] for alias in aliases}
    declaration_positions = {alias[5] for alias in aliases if alias[4] == path}
    type_positions = {node["start"] for node in facts["typeNames"]}
    bindings = [
        (binding, name[1])
        for binding in facts["bindings"]
        if (name := re.match(r"(\w+)\s*(?::[^=]+)?=", swift_code(binding["value"])))
    ]
    bindings.extend((variable, variable["name"]) for variable in facts["typedVariables"])
    for node in facts["scopedIdentifiers"]:
        if node["value"] not in alias_names or node["start"] in declaration_positions:
            continue
        start = node["start"]
        prefix = code[: len(encoded[:start].decode())]
        qualifier = re.search(r"(?:\b\w+\s*\.\s*)+$", prefix)
        if not qualifier and (
            any(
                declaration["name"] == node["value"]
                and node["scope"][: len(declaration["scope"])] == declaration["scope"]
                for declaration in facts["declarations"]
            )
            or node["start"] not in type_positions
            and any(
                name == node["value"]
                and binding["start"] <= start
                and node["scope"][: len(binding["scope"])] == binding["scope"]
                and node.get("lexicalScope", [])[: len(binding.get("lexicalScope", []))]
                == binding.get("lexicalScope", [])
                for binding, name in bindings
            )
        ):
            continue
        name = re.sub(r"\s+", "", qualifier[0]) + node["value"] if qualifier else node["value"]
        alias = lookup(name, tuple(node["scope"]), tuple(node.get("lexicalScope", [])), path)
        if alias and (replacement := resolve(alias)) != alias[0]:
            begin = (
                len(encoded[:start].decode()[: qualifier.start()].encode()) if qualifier else start
            )
            replacements.append((begin, start + len(node["value"].encode()), replacement.encode()))
    for start, end, replacement in sorted(replacements, reverse=True):
        encoded = encoded[:start] + replacement + encoded[end:]
    return encoded.decode()


SERVICE_RESOURCE_OWNERS = {
    "web": {
        ("GalleryFeature", "GalleryRootViewScene.GalleryWebView"),
        ("GalleryFeature", "GalleryWebCoordinator"),
    },
    "transport": {
        ("TransportCore", owner)
        for owner in (
            "HTTPClient",
            "HTTPTransmissionMetrics",
            "HTTPBoundedTransfer",
            "HTTPTransport",
            "URLSession",
            "URLSessionTransport",
            "NoRedirectURLSessionDelegate",
            "HTTPSUpgradingRedirectDelegate",
            "UncachedHTTPTransport",
        )
    },
    "cache": {("TransportCore", "URLSessionTransport")},
    "requests": {
        ("TransportCore", owner)
        for owner in (
            "HTTPClient",
            "HTTPTransport",
            "URLSession",
            "URLSessionTransport",
            "UncachedHTTPTransport",
        )
    },
    "connections": {("TransportCore", "NetworkPathState"), ("BIT101-iOS", "UITestControlServer")},
    "errors": {("TransportCore", "ErrorChain")},
    "form": {("TransportCore", "HTTPFormEncoding")},
    "files": {("StorageCore", "LocalAppFileService")},
    "preferences": {("BIT101-iOS", "AppFileDirectories")},
}


def resource_permissions(path: str, source: str):
    from swift_type_index import compilation_unit

    unit, facts = compilation_unit(path), resource_facts(source)
    encoded = source.encode()
    line_starts = [0] + [match.end() for match in re.finditer(b"\n", encoded)]

    def owner(point):
        nominal = canonical_type_scope(point["scope"])
        return (unit, ".".join(nominal)) if nominal else None

    points = [
        (
            point["start"],
            point["start"] + len(point.get("value", point.get("name", "")).encode()),
            len(point["scope"]),
            owner(point),
        )
        for point in facts["members"]
        + facts["scopedIdentifiers"]
        + facts["typeNames"]
        + facts["typedVariables"]
        + facts["invocations"]
    ]
    line_owners = {}
    for point in facts["invocations"] + facts["members"] + facts["scopedIdentifiers"]:
        if point.get("isExpressionReference", True):
            line_owners.setdefault(bisect_right(line_starts, point["start"]), set()).add(
                owner(point)
            )

    def permitted(capability, *, offset=None, line=None):
        allowed = SERVICE_RESOURCE_OWNERS[capability]
        if line is not None:
            owners = line_owners.get(line, set())
            return bool(owners) and owners <= allowed
        candidates = [point for point in points if point[0] <= offset < point[1]]
        return (
            bool(candidates)
            and min(candidates, key=lambda point: (point[1] - point[0], -point[2]))[3] in allowed
        )

    return permitted


POSIX_FILE_FUNCTIONS = (
    "open|openat|creat|close|read|pread|readv|write|pwrite|writev|lseek|fopen|freopen|fread|fwrite"
    "|fclose|rename|remove|unlink|mkdir|rmdir|stat|lstat|fstat|truncate|ftruncate|fsync|fdatasync|"
    "access|opendir|readdir|closedir|mmap|munmap|readlink|readlinkat|symlink|symlinkat|link|linkat"
    "|renameat|unlinkat|mkdirat|fstatat|chmod|fchmod|fchmodat|chown|fchown|lchown|fchownat|fdopen|"
    "fflush|fseek|ftell|fgetpos|fsetpos|rewind|scandir|removefile|copyfile|fcopyfile|realpath|getx"
    "attr|fgetxattr|setxattr|fsetxattr|listxattr|flistxattr|removexattr|fremovexattr"
)


POSIX_NETWORK_FUNCTIONS = "|".join(sorted(NETWORK_SYSTEM_FUNCTIONS))


POSIX_PROCESS_FUNCTIONS = (
    r"posix_spawn|posix_spawnp|fork|vfork|execl|execlp|execle|execv|execvp|execve|popen|system"
)


CF_PREFERENCE_FUNCTIONS = (
    "(?:CoreFoundation\\s*\\.\\s*)?CFPreferences(?:CopyAppValue|CopyValue|CopyMultiple|CopyKeyList"
    "|CopyApplicationList|SetAppValue|SetValue|SetMultiple|AppSynchronize|Synchronize|GetAppBoolea"
    "nValue|GetAppIntegerValue|AppValueIsForced|AddSuitePreferencesToApp|RemoveSuitePreferencesFro"
    "mApp)"
)


FILE_INITIALIZER_TYPES = (
    (
        "(?:Foundation\\.|UIKit\\.|AppKit\\.|CoreGraphics\\.)?(?:Data|NSData|NSMutableData|String|"
        "NSString|NSMutableString|XMLParser|UIImage|NSImage|InputStream|OutputStream|FileWrapper|N"
        "SFileWrapper|CGDataProvider|"
    )
    + "|".join(sorted(FOUNDATION_COLLECTION_TYPES))
    + r")\??"
)


def local_resource_source(source: str, path: str, call_context=None) -> str:
    """Preserve source offsets while separating project types from platform resources."""
    from network_capability_rules import (
        NETWORK_PLATFORM_CONNECTION_TYPES,
        NETWORK_PLATFORM_TRANSPORT_TYPES,
    )

    resources = (
        FOUNDATION_COLLECTION_TYPES
        | NETWORK_PLATFORM_CONNECTION_TYPES
        | NETWORK_PLATFORM_TRANSPORT_TYPES
        | {
            "FileManager",
            "UserDefaults",
            "URLCache",
            "HTTPCookieStorage",
            "UIApplication",
            "UIScreen",
            "Data",
            "NSData",
            "NSMutableData",
            "String",
            "NSString",
            "NSMutableString",
            "XMLParser",
            "UIImage",
            "NSImage",
            "Stream",
            "NSStream",
            "InputStream",
            "OutputStream",
            "NSInputStream",
            "NSOutputStream",
            "FileWrapper",
            "NSFileWrapper",
            "FileHandle",
            "NSFileHandle",
            "NSFileCoordinator",
            "NSKeyedArchiver",
            "NSKeyedUnarchiver",
            "NSArchiver",
            "NSUnarchiver",
            "CGDataProvider",
            "CharacterSet",
            "DispatchIO",
            "NWPathMonitor",
            "Process",
            "NSTask",
            "AsyncImage",
        }
    )
    code = swift_code(source)
    if not any(re.search(r"\b" + name + r"\b", code) for name in resources):
        return source
    facts = resource_facts(source)
    types = (call_context or SwiftBindingTypes({path: facts})).types
    identities = {namespace + "." + ".".join(owner) for namespace, owner in types.records}
    declared = {
        types.resolve(owner_path, ".".join(node["scope"] + [node["name"]]), aliases=False)
        for owner_path, entries in types.index.items()
        for node in entries.get("declarations", [])
        if node["kind"] != "extension"
    }
    encoded = bytearray(source.encode())
    for node in facts["scopedIdentifiers"]:
        if node["value"] not in resources:
            continue
        prefix = code[: len(source.encode()[: node["start"]].decode())]
        qualifier = re.search(r"(?:\b\w+\s*\.\s*)+$", prefix)
        name = re.sub(r"\s+", "", qualifier[0]) + node["value"] if qualifier else node["value"]
        key = types.resolve(path, name, node["scope"])
        if key not in declared:
            continue
        terminal = types.terminal_name(path, name, node["scope"])
        if terminal not in identities:
            continue
        if any(base.removeprefix("Foundation.") in resources for base in types.bases(key)):
            continue
        encoded[node["start"]] = ord("_")
    return encoded.decode()


def normalized_resource_source(source: str) -> str:
    resources = (
        "Data|NSData|NSMutableData|String|NSString|NSMutableString|XMLParser|NSKeyedArchiver|NSKey"
        "edUnarchiver|NSArchiver|NSUnarchiver|UIImage|NSImage|Stream|NSStream|InputStream|OutputSt"
        "ream|NSInputStream|NSOutputStream|FileWrapper|NSFileWrapper|UserDefaults|FileManager|URLS"
        "ession|URLSessionTransport|URLCache|AppFileSystem|LocalAppFileService"
    )
    code = swift_code(source)
    if re.search(r"\b(?:" + resources + r")\s*\.\s*self\b", code):
        facts = resource_facts(source)

        def metatype(name, point, seen=frozenset(), explicit_self=False):
            if name in seen:
                return None
            variables = visible_variables(facts, point, name, explicit_self)
            bindings = [
                binding
                for binding in facts["bindings"]
                if binding.get("bindingName") == name
                and binding["start"] < point["start"]
                and point["scope"][: len(binding["scope"])] == binding["scope"]
                and (not explicit_self or not binding.get("lexicalScope"))
                and point.get("lexicalScope", [])[: len(binding.get("lexicalScope", []))]
                == binding.get("lexicalScope", [])
            ]
            visible = variables + bindings
            if not visible:
                return None
            nearest = max(
                visible,
                key=lambda row: (
                    len(row.get("lexicalScope", [])),
                    row["start"],
                    bool(row.get("bindingName")),
                ),
            )
            if not nearest.get("bindingName"):
                return None
            value = nearest.get("initializerReference", "")
            direct = re.fullmatch(r"((?:Foundation\.)?(?:" + resources + r"))\.self", value)
            return direct[1] if direct else metatype(value, nearest, seen | {name})

        encoded = source.encode()
        replacements = []
        binding_names = {binding.get("bindingName") for binding in facts["bindings"]}
        for node in facts["scopedIdentifiers"]:
            if not node.get("isExpressionReference") or node["value"] not in binding_names:
                continue
            qualifier = re.search(r"(\w+)\s*\.\s*$", code[: len(encoded[: node["start"]].decode())])
            if qualifier and qualifier[1] != "self":
                continue
            if target := metatype(node["value"], node, explicit_self=bool(qualifier)):
                begin = (
                    len(encoded[: node["start"]].decode()[: qualifier.start()].encode())
                    if qualifier
                    else node["start"]
                )
                replacements.append(
                    (begin, node["start"] + len(node["value"].encode()), target.encode())
                )
        for start, end, replacement in sorted(replacements, reverse=True):
            encoded = encoded[:start] + replacement + encoded[end:]
        source = encoded.decode()
    return re.sub(
        r"\b((?:Foundation\.)?(?:" + resources + r"))\s*\.\s*self(?=\s*\.)",
        lambda match: match[1] + "\n" * match[0].count("\n"),
        source,
    )


@cache
def resource_facts(source: str) -> dict:
    return swift_syntax_index_sources({"resource-source": source})["resource-source"]


@cache
def file_member_accesses(
    source: str, properties: tuple = (), *, call_context=None, origin="resource-source"
) -> list[int]:
    if not re.search(
        r"\.\s*(?:write|read|matchesContents)\b|\bCGPDFDocument\b", swift_code(source)
    ):
        return []
    facts = dict(resource_facts(source))
    facts["typedVariables"] = facts["typedVariables"] + [
        dict(scope=list(scope), name=name, type=kind, start=-1, lexicalScope=[])
        for scope, name, kind in properties
    ]
    encoded = source.encode()
    binding_types = None
    file_types = FOUNDATION_COLLECTION_TYPES | {
        "Data",
        "NSData",
        "NSMutableData",
        "String",
        "NSString",
        "NSMutableString",
        "FileWrapper",
        "NSFileWrapper",
    }

    def normalized_type(value: str) -> str:
        value = (
            value.strip()
            .removeprefix("Foundation.")
            .removeprefix("CoreFoundation.")
            .removesuffix("?")
        )
        optional = re.fullmatch(r"(?:Swift\.)?Optional<(.+)>", value)
        return normalized_type(optional[1]) if optional else value

    def element_type(container: str | None) -> str | None:
        if container is None:
            return None
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
        if cast:
            return normalized_type(cast[1])
        result = re.match(
            (
                "(.+)\\.\\s*(encode|data|pngData|jpegData|appendingPathComponent|appendingPathExte"
                "nsion|appending)\\s*\\("
            ),
            expression,
            re.DOTALL,
        )
        if result:
            receiver_type = value_type(result[1], point, seen)
            if result[2] == "encode" and receiver_type in {"JSONEncoder", "PropertyListEncoder"}:
                return "Data"
            if result[2] == "data" and receiver_type in {
                "String",
                "NSString",
                "NSMutableString",
                "JSONSerialization",
                "PropertyListSerialization",
            }:
                return "Data"
            if result[2] in {"pngData", "jpegData"} and receiver_type == "UIImage":
                return "Data"
            if result[2].startswith("appending") and receiver_type in {"URL", "NSURL"}:
                return receiver_type
        if re.match(r'^#*"', expression):
            return "String"
        if expression.startswith("[") and expression.endswith("]"):
            item = value_type(expression[1:-1].split(",", 1)[0], point, seen)
            return "[" + item + "]" if item else None
        subscript = re.fullmatch(r"(.+)\[[^\[\]]+\]", expression, re.DOTALL)
        if subscript:
            return element_type(value_type(subscript[1], point, seen))
        method = re.match(r"(.+)\.\s*(\w+)\s*\(", expression, re.DOTALL)
        if method:
            if binding_types is None:
                binding_types = call_context or SwiftBindingTypes({origin: facts})
            owner = (
                point["scope"]
                if method[1] == "self"
                else (value_type(method[1], point, seen) or "").split(".")
            )
            invocation = next(
                (
                    call
                    for call in facts["invocations"]
                    if call["value"] == expression
                    and call["scope"] == point["scope"]
                    and call.get("lexicalScope") == point.get("lexicalScope")
                ),
                None,
            )
            if owner and (
                returned := binding_types.method_return(origin, owner, method[2], invocation)
            ):
                return normalized_type(returned)
        constructor = re.match(r"(?:Foundation\.)?(\w+)\s*(?:\.\s*init)?\s*\(", expression)
        if constructor:
            invocations = [
                call
                for call in facts["invocations"]
                if call["value"] == expression
                and call["scope"] == point["scope"]
                and call.get("lexicalScope") == point.get("lexicalScope")
            ]
            invocation = (
                min(invocations, key=lambda call: abs(call["start"] - point["start"]))
                if invocations
                else None
            )
            functions = matching_functions(facts, constructor[1], invocation or point)
            if functions:
                return normalized_type(functions[-1].get("returnType") or "")
            variables = visible_variables(facts, point, constructor[1], False)
            if variables and "->" in variables[-1]["type"]:
                return normalized_type(variables[-1]["type"].rsplit("->", 1)[1])
            return (
                constructor[1]
                if constructor[1][:1].isupper()
                or any(
                    declaration["name"] == constructor[1] for declaration in facts["declarations"]
                )
                else None
            )
        if expression in {"JSONSerialization", "PropertyListSerialization"}:
            return expression
        member = re.fullmatch(r"(.+)\.\s*(\w+)", expression)
        if member and member[1] != "self":
            owner = value_type(member[1], point, seen)
            if (
                member[2] in {"first", "last"}
                and owner
                and re.fullmatch(r"\[[^:]+\]|(?:Swift\.)?Array<.+>", normalized_type(owner))
            ):
                return element_type(owner)
            fields = [
                variable
                for variable in facts["typedVariables"]
                if variable["name"] == member[2]
                and variable["scope"]
                and variable["scope"][-1] == owner
                and not variable.get("lexicalScope")
            ]
            return normalized_type(fields[-1]["type"]) if fields else None
        if not re.fullmatch(r"(?:self\.)?\w+", expression):
            return None
        name = expression.rsplit(".", 1)[-1]
        identity = (expression, point["start"])
        if identity in seen:
            return None
        variables = visible_variables(facts, point, name, expression.startswith("self."))
        candidates = [
            binding
            for binding in facts["bindings"]
            if re.match(re.escape(name) + r"\s*(?:=|in\b)", binding["value"])
            and binding["start"] < point["start"]
            and (not expression.startswith("self.") or not binding.get("lexicalScope"))
            and point["scope"][: len(binding["scope"])] == binding["scope"]
            and point.get("lexicalScope", [])[: len(binding.get("lexicalScope", []))]
            == binding.get("lexicalScope", [])
        ]
        visible = variables + candidates
        if visible:
            binding = max(
                visible, key=lambda item: (len(item.get("lexicalScope", [])), item["start"])
            )
            if "type" in binding:
                return normalized_type(binding["type"])
            iteration = re.match(re.escape(name) + r"\s+in\s+(.+)", binding["value"], re.DOTALL)
            if iteration:
                return element_type(value_type(iteration[1], binding, seen | {identity}))
            return value_type(binding["value"].split("=", 1)[1], binding, seen | {identity})
        return None

    hits = set()
    for call in facts["invocations"]:
        if re.match(r"(?:CoreGraphics\.)?CGPDFDocument\s*(?:\.\s*init\s*)?\(", call["value"]):
            arguments = call.get("arguments") or []
            if arguments and value_type(arguments[0], call) in {"URL", "NSURL", "CFURL"}:
                hits.add(encoded[: call["start"]].count(b"\n") + 1)
        match = re.match(
            r"(.+)\.\s*(write|read|matchesContents)\s*\(\s*(?:to|toFile|from|of)\s*:",
            call["value"],
            re.DOTALL,
        )
        if not (match):
            continue
        receiver = value_type(match[1], call)
        arguments = call.get("arguments") or []
        target = value_type(arguments[0], call) if arguments else None
        if (
            match[2] == "write"
            and receiver in file_types
            or receiver in {"FileWrapper", "NSFileWrapper"}
        ) or (
            match[2] == "write"
            and receiver is None
            and (target == "URL" or (target == "String" and "toFile" in call["argumentLabels"]))
        ):
            hits.add(encoded[: call["start"]].count(b"\n") + 1)
    for reference in facts["members"]:
        if re.fullmatch(r"(?:CoreGraphics\.)?CGPDFDocument\s*\.\s*init", reference["value"]):
            contexts = expected_argument_types(facts, reference, context=call_context, path=origin)
            contexts.extend(
                binding.get("bindingType", "")
                for binding in facts["bindings"]
                if binding["start"]
                <= reference["start"]
                < binding["start"] + len(binding["value"].encode())
            )
            prefix = encoded[: reference["start"]].decode()
            assignment = re.search(r"\b(\w+)\s*=\s*$", prefix)
            if assignment:
                contexts.extend(
                    variable["type"]
                    for variable in visible_variables(facts, reference, assignment[1])
                )
            if any(re.search(r"\bCFURL\b", context) for context in contexts):
                hits.add(encoded[: reference["start"]].count(b"\n") + 1)
        match = re.fullmatch(
            r"(.+)\.\s*(write|read|matchesContents)(?:\(\s*(?:\w+\s*:\s*)+\))?",
            reference["value"],
            re.DOTALL,
        )
        if not match:
            continue
        receiver = value_type(match[1], reference) or normalized_type(match[1])
        if (
            match[2] == "write"
            and receiver in file_types
            or receiver in {"FileWrapper", "NSFileWrapper"}
        ):
            hits.add(encoded[: reference["start"]].count(b"\n") + 1)
    return sorted(hits)


@cache
def implicit_file_accesses(
    source: str,
    functions: str = POSIX_FILE_FUNCTIONS,
    *,
    call_context=None,
    origin="resource-source",
) -> list[int]:
    code = swift_code(source)
    if not re.search(
        (r"\.\s*init\s*\(|" if functions == POSIX_FILE_FUNCTIONS else "")
        + r"(?<![.\w])(?:"
        + functions
        + r")\b|\b(?:Darwin|Glibc)\s*\.",
        code,
    ):
        return []
    facts = resource_facts(source)
    encoded = source.encode()
    hits = set()

    def own_value(reference: dict, name: str) -> bool:
        return (
            bool(visible_variables(facts, reference, name))
            or any(
                variable["name"] == name and variable["start"] == reference["start"]
                for variable in facts["typedVariables"]
            )
            or any(
                case["name"] == name and reference["scope"][: len(case["scope"])] == case["scope"]
                for case in facts["enumCases"]
            )
            or any(
                re.match(re.escape(name) + r"\s*=", binding["value"])
                and binding["start"] <= reference["start"]
                and reference["scope"][: len(binding["scope"])] == binding["scope"]
                and reference["lexicalScope"][: len(binding["lexicalScope"])]
                == binding["lexicalScope"]
                for binding in facts["bindings"]
            )
        )

    for reference in facts["members"] + facts["scopedIdentifiers"]:
        if not reference.get("isExpressionReference", True):
            continue
        qualified = re.fullmatch(
            r"(?:Darwin|Glibc)\s*\.\s*(" + functions + r")", reference["value"]
        )
        bare = re.fullmatch(functions, reference["value"])
        own = any(
            function["name"] == reference["value"]
            and reference["scope"][: len(function["scope"])] == function["scope"]
            for function in facts["functionRanges"]
        )
        member_name = any(
            member["start"] <= reference["start"] < member["start"] + len(member["value"].encode())
            for member in facts["members"]
            if member is not reference
        )
        if qualified or (
            bare and not member_name and not own and not own_value(reference, reference["value"])
        ):
            hits.add(encoded[: reference["start"]].count(b"\n") + 1)
    for call in facts["invocations"]:
        value = swift_code(call["value"])
        posix = re.match(r"(?:(Darwin|Glibc)\s*\.\s*)?(" + functions + r")\s*\(", value)
        forbidden = False
        if posix:
            own_function = bool(matching_functions(facts, posix[2], call)) or own_value(
                call, posix[2]
            )
            forbidden = bool(posix[1]) or not own_function
        elif functions == POSIX_FILE_FUNCTIONS and re.match(
            (
                "\\.\\s*init\\s*\\(\\s*(?:contentsOf|contentsOfFile|contentsOfURL|contentsOfMapped"
                "File|url|path|fileAtPath|toFileAtPath)\\s*:"
            ),
            value,
        ):
            prefix = code[: len(encoded[: call["start"]].decode())]
            contexts = expected_argument_types(facts, call, context=call_context, path=origin) + [
                match[1]
                for binding in facts["bindings"]
                if binding["start"]
                <= call["start"]
                < binding["start"] + len(binding["value"].encode())
                and (match := re.match(r"\w+\s*:\s*([^={]+)", swift_code(binding["value"])))
            ]
            assigned = re.search(r"(?:self\.)?(\w+)\s*=\s*$", prefix)
            if assigned:
                matching = visible_variables(
                    facts, call, assigned[1], assigned[0].startswith("self.")
                )
                if matching:
                    contexts.append(matching[-1]["type"])
            contexts.extend(
                function["returnType"]
                for function in facts["functionRanges"]
                if function["start"] <= call["start"] < function["end"]
                and function.get("returnType")
                and re.search(r"(?:\breturn|\{)\s*$", prefix)
            )
            forbidden = (
                any(
                    re.search(r"\b" + FILE_INITIALIZER_TYPES + r"\b", context)
                    for context in contexts
                )
                if contexts
                else bool(
                    re.match(r"\.\s*init\s*\(\s*contentsOf(?:File|URL|MappedFile)?\s*:", value)
                )
            )
        if forbidden:
            hits.add(encoded[: call["start"]].count(b"\n") + 1)
    return sorted(hits)


@cache
def implicit_resource_accesses(
    source: str,
    resource: str = "UserDefaults",
    properties: tuple = (),
    *,
    call_context=None,
    origin="resource-source",
) -> list[int]:
    code = swift_code(source)
    if not re.search(r"\.\s*(?:standard\b|init\s*\()", code):
        return []
    facts = dict(resource_facts(source))
    facts["typedVariables"] = facts["typedVariables"] + [
        dict(scope=list(scope), name=name, type=kind, start=-1, lexicalScope=[])
        for scope, name, kind in properties
    ]
    encoded = source.encode()
    hits = []

    def matches(value, scope):
        if call_context:
            value = re.sub(
                r"(?<![\w.])(?:Foundation\.|StorageCore\.)?" + resource + r"\b",
                lambda match: call_context.types.terminal_name(origin, match[0], scope),
                value,
            )
        return resource_context_type(value, resource)

    accesses = [
        member
        for member in facts["members"]
        if resource == "UserDefaults"
        and re.fullmatch(r"\.\s*standard", swift_code(member["value"]).strip())
    ]
    accesses.extend(
        call
        for call in facts["invocations"]
        if re.match(r"\.\s*init\s*\(", swift_code(call["value"]))
    )
    for member in accesses:
        prefix = code[: len(encoded[: member["start"]].decode())]
        assigned = re.search(r"(?:self\.)?(\w+)\s*=\s*$", prefix)
        inferred = bool(
            re.search(r"\b(?:Foundation\.|StorageCore\.)?" + resource + r"\??\s*=\s*$", prefix)
        )
        inferred |= any(
            matches(value, member["scope"])
            for value in expected_argument_types(facts, member, context=call_context, path=origin)
        )
        inferred |= any(
            binding["start"] <= member["start"] < binding["start"] + len(binding["value"].encode())
            and (context := re.match(r"\w+\s*:\s*([^={]+)", swift_code(binding["value"])))
            and matches(context[1], binding["scope"])
            and re.search(r"(?:\breturn|\bin|[\{=\[,:?])\s*(?:try[!?]?\s*)?$", prefix)
            for binding in facts["bindings"]
        )
        if assigned:
            matching = visible_variables(
                facts, member, assigned[1], assigned[0].startswith("self.")
            )
            inferred = inferred or bool(
                matching and matches(matching[-1]["type"], matching[-1]["scope"])
            )
        inferred = inferred or any(
            function["start"] <= member["start"] < function["end"]
            and matches(function.get("returnType", ""), function["scope"])
            and re.search(r"(?:\breturn|[\{?:])\s*(?:try[!?]?\s*)?$", prefix)
            for function in facts["functionRanges"]
        )
        if inferred:
            hits.append(prefix.count("\n") + 1)
    return hits
