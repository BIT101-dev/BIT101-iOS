#!/usr/bin/env python3
"""Validate the local Swift Package source roots and direct dependency graph."""

from __future__ import annotations

import json
import multiprocessing
import os
from bisect import bisect_right
from concurrent.futures import ProcessPoolExecutor
import re
import subprocess
import sys
from functools import cache
from pathlib import Path

sys.dont_write_bytecode = True
from swift_source_index import (
    RAW_FACTS_BY_SOURCE,
    canonical_type_scope,
    declaration_conformances,
    scope_contains_type,
    expected_argument_types,
    swift_syntax_index,
    swift_syntax_index_sources,
    resource_context_type,
    visible_variables,
    matching_functions,
    compilation_type_context,
    local_member_calls,
    swift_code,
)
from validation_policy import coverage_registry_findings
from swift_type_index import SwiftBindingTypes
from network_capability_rules import FOUNDATION_COLLECTION_TYPES, NETWORK_SYSTEM_FUNCTIONS
from validation_inputs import manifest_targets, read_manifest
from module_resource_facts import (
    CF_PREFERENCE_FUNCTIONS as CF_PREFERENCE_FUNCTIONS,
    FILE_INITIALIZER_TYPES as FILE_INITIALIZER_TYPES,
    GLOBAL_RESOURCE_PATTERN as GLOBAL_RESOURCE_PATTERN,
    POSIX_FILE_FUNCTIONS as POSIX_FILE_FUNCTIONS,
    POSIX_NETWORK_FUNCTIONS as POSIX_NETWORK_FUNCTIONS,
    POSIX_PROCESS_FUNCTIONS as POSIX_PROCESS_FUNCTIONS,
    SERVICE_RESOURCE_OWNERS as SERVICE_RESOURCE_OWNERS,
    alias_module as alias_module,
    expanded_resource_source as expanded_resource_source,
    file_member_accesses as file_member_accesses,
    implicit_file_accesses as implicit_file_accesses,
    implicit_resource_accesses as implicit_resource_accesses,
    local_resource_source as local_resource_source,
    normalized_resource_source as normalized_resource_source,
    resource_facts as resource_facts,
    resource_permissions as resource_permissions,
    type_aliases as type_aliases,
)
from module_import_rules import (
    CROSS_BUSINESS_CONTRACTS as CROSS_BUSINESS_CONTRACTS,
    FOUNDATIONAL_IMPORTS as FOUNDATIONAL_IMPORTS,
    IGNORED_IMPORTS as IGNORED_IMPORTS,
    LAYERS as LAYERS,
    PLATFORM_EXCEPTIONS as PLATFORM_EXCEPTIONS,
    SHARED_MODULES as SHARED_MODULES,
    business_family as business_family,
    graph_errors as graph_errors,
    imported_modules as imported_modules,
    imports_in_text as imports_in_text,
    layer as layer,
    platform_errors as platform_errors,
    raw_imports as raw_imports,
)


ROOT = Path(__file__).resolve().parents[1]


def imported_aliases(source: str, local: tuple, modules: tuple) -> tuple:
    imports = raw_imports(source)
    return local + tuple(alias for alias in modules if alias_module(alias[4]) in imports)


def service_resource_patterns(path):
    from network_capability_rules import (
        NETWORK_PLATFORM_CONNECTION_TYPES,
        NETWORK_PLATFORM_TRANSPORT_TYPES,
    )

    patterns = [
        (r"\bAsyncImage\b", "load remote images through MediaKit", None),
        (r"\b(?:Process|NSTask)\b", "keep subprocess execution in host tooling", None),
        (
            r"\b(?:" + "|".join(sorted(NETWORK_PLATFORM_TRANSPORT_TYPES | {"URLCache"})) + r")\b",
            "use TransportCore transport and cache services",
            "transport",
        ),
        (
            (
                "\\b(?:CFSocket\\w*|CFStreamCreatePairWith(?:Socket|PeerSocketSignature)\\w*|CFRea"
                "dStreamCreateForHTTPRequest|CFHTTPMessageCreateRequest)\\b"
            ),
            "use TransportCore network services",
            "transport",
        ),
        (
            r"\.\s*(?:data|download|upload|bytes)\s*\(\s*for\s*:",
            "send requests through HTTPClient",
            "requests",
        ),
        (
            r"\.\s*(?:dataTask|downloadTask|uploadTask|webSocketTask)\s*\(",
            "send requests through HTTPClient",
            "requests",
        ),
        (
            r"\b(?:"
            + "|".join(
                sorted(
                    NETWORK_PLATFORM_CONNECTION_TYPES
                    | {"NWPathMonitor", "NWTCPConnection", "NWUDPSession"}
                )
            )
            + r")\b",
            "use TransportCore network services",
            "connections",
        ),
        (
            r"\.\s*userInfo\s*\[\s*NSUnderlyingErrorKey\s*\]",
            "traverse underlying errors through ErrorChain",
            "errors",
        ),
        (
            r"\bCharacterSet\s*\.\s*urlQueryAllowed\b",
            "encode form fields through HTTPFormEncoding",
            "form",
        ),
        (
            r"\b(?:DispatchIO|CF(?:Read|Write)StreamCreateWithFile)\b",
            "read and write files through AppFileService",
            "files",
        ),
        (
            (
                "\\bFileManager\\b(?!\\s*\\.\\s*(?:SearchPathDirectory|SearchPathDomainMask|Direct"
                "oryEnumerationOptions|VolumeEnumerationOptions|URLRelationship|ItemReplacementOpt"
                "ions)\\b)"
            ),
            "use AppFileService",
            "files",
        ),
        (
            r"\b(?:Data|NSData|NSMutableData|String|NSString|NSMutableString|XMLParser|"
            + "|".join(sorted(FOUNDATION_COLLECTION_TYPES))
            + (
                ")\\s*(?:\\.\\s*self\\s*)?(?:\\.\\s*init\\s*)?\\(\\s*(?:contentsOf|contentsOfFile|"
                "contentsOfURL|contentsOfMappedFile)\\s*:"
            ),
            "read files through AppFileService",
            "files",
        ),
        (
            r"\bNS(?:Keyed)?Archiver\s*\.\s*archiveRootObject\b",
            "write files through AppFileService",
            "files",
        ),
        (
            r"\bNS(?:Keyed)?Unarchiver\s*\.\s*unarchiveObject\s*\(\s*withFile\s*:",
            "read files through AppFileService",
            "files",
        ),
        (
            (
                "\\.\\s*(?:resourceValues|setResourceValues|getResourceValue|setResourceValue|reso"
                "lvingSymlinksInPath|checkResourceIsReachable)\\s*\\("
            ),
            "access file metadata through AppFileService",
            "files",
        ),
        (
            (
                "\\b(?:FileHandle|NSFileHandle)\\b(?!\\s*\\.\\s*standard(?:Output|Error)\\b)|\\b(?"
                ":NSFileCoordinator|CGImageSourceCreateWithURL|CGImageDestinationCreateWithURL)\\b"
            ),
            "access files through AppFileService",
            "files",
        ),
        (
            r"\b(?:FileWrapper|NSFileWrapper)\s*(?:\.\s*init\s*)?\(\s*(?:url|path)\s*:",
            "access files through AppFileService",
            "files",
        ),
        (
            (
                "\\b(?:UIImage|NSImage|InputStream|OutputStream)\\s*(?:\\.\\s*init\\s*)?\\(\\s*(?:"
                "contentsOfFile|contentsOf|url|fileAtPath|toFileAtPath)\\s*:"
            ),
            "access files through AppFileService",
            "files",
        ),
        (
            r"\bCGDataProvider\s*(?:\.\s*init\s*)?\(\s*url\s*:",
            "access files through AppFileService",
            "files",
        ),
        (
            (
                "\\bUserDefaults\\s*\\.\\s*standard\\b|\\bUserDefaults\\s*=\\s*\\.\\s*standard\\b|"
                "\\bUserDefaults\\s*(?:\\(|\\.\\s*init\\b)"
            ),
            "select preferences through the host storage entry",
            "preferences",
        ),
    ]
    if path.startswith("Modules/") and not path.startswith("Modules/TransportCore/"):
        patterns.append(
            (
                r"\bURLSessionTransport\s*\.\s*(?:make|clearSharedCache)\b",
                "inject host-selected transport resources",
                None,
            )
        )
    if path.startswith("Modules/") and not path.startswith("Modules/StorageCore/"):
        patterns.append(
            (
                r"\bLocalAppFileService\s*(?:\(|\.\s*init\b)",
                "inject host-selected file resources",
                None,
            )
        )
    if path.startswith("Modules/ScheduleFeature/"):
        patterns.append(
            (r"\bDateFormatter\s*\(", "format schedule dates through ScheduleDateCodec", None)
        )
    return patterns


def service_boundary_errors(
    path: str,
    source: str,
    aliases: tuple = (),
    context: tuple = ((), ()),
    *,
    call_context=None,
    origin=None,
) -> list[str]:
    """Enforce resource capabilities on their owning module and declaration."""
    source = local_resource_source(
        expanded_resource_source(source, aliases, path), origin or path, call_context
    )
    source = normalized_resource_source(source)
    if call_context:
        call_context = call_context.replacing_source(origin or path, resource_facts(source))
    code, permitted = swift_code(source), resource_permissions(path, source)
    from network_capability_rules import platform_stream_request

    patterns = service_resource_patterns(path)
    errors = []
    if "getStreamsToHost" in code:
        bindings = call_context or SwiftBindingTypes({origin or path: resource_facts(source)})
        for call in resource_facts(source)["invocations"]:
            if platform_stream_request(
                bindings.types, origin or path, call, bindings
            ) and not permitted("transport", offset=call["start"]):
                line = source.encode()[: call["start"]].count(b"\n") + 1
                errors.append(
                    f"service boundary: {path}:{line}: use TransportCore network services"
                )
    errors.extend(
        f"service boundary: {path}:{line}: use TransportCore network services"
        for line in implicit_file_accesses(source, POSIX_NETWORK_FUNCTIONS)
        if not permitted("transport", line=line)
    )
    errors.extend(
        f"service boundary: {path}:{line}: keep subprocess execution in host tooling"
        for line in implicit_file_accesses(source, POSIX_PROCESS_FUNCTIONS)
    )
    if path.startswith("Modules/") and not path.startswith("Modules/StorageCore/"):
        errors.extend(
            f"service boundary: {path}:{line}: inject host-selected file resources"
            for line in implicit_resource_accesses(
                source,
                "LocalAppFileService",
                context[0],
                call_context=call_context,
                origin=origin or path,
            )
        )
    errors.extend(
        f"service boundary: {path}:{line}: access files through AppFileService"
        for line in implicit_file_accesses(source, call_context=call_context, origin=origin or path)
        if not permitted("files", line=line)
    )
    errors.extend(
        f"service boundary: {path}:{line}: access files through AppFileService"
        for line in file_member_accesses(
            source, properties=context[0], call_context=call_context, origin=origin or path
        )
        if not permitted("files", line=line)
    )
    errors.extend(
        (
            f"service boundary: "
            f"{path}"
            f":"
            f"{line}"
            f": select preferences through the host storage entry: UserDefaults"
        )
        for line in implicit_resource_accesses(
            source, properties=context[0], call_context=call_context, origin=origin or path
        )
        if not permitted("preferences", line=line)
    )
    errors.extend(
        (
            f"service boundary: "
            f"{path}"
            f":"
            f"{line}"
            f": select preferences through the host storage entry: CFPreferences"
        )
        for line in implicit_file_accesses(source, CF_PREFERENCE_FUNCTIONS)
        if not permitted("preferences", line=line)
    )
    local_names = (
        "data",
        "download",
        "upload",
        "bytes",
        "dataTask",
        "downloadTask",
        "uploadTask",
        "webSocketTask",
        "resourceValues",
        "setResourceValues",
        "getResourceValue",
        "setResourceValue",
        "resolvingSymlinksInPath",
        "checkResourceIsReachable",
    )
    local_calls = (
        local_member_calls(source, local_names, context)
        if re.search(r"\.\s*(?:" + "|".join(local_names) + r")\s*\(", code)
        else set()
    )
    for pattern, rule, capability in patterns:
        for match in re.finditer(pattern, code):
            offset = len(source[: match.start()].encode())
            if match[0].strip() == "WKWebView" and permitted("web", offset=offset):
                continue
            if capability and permitted(capability, offset=offset):
                continue
            if (
                rule
                in {
                    "send requests through HTTPClient",
                    "access file metadata through AppFileService",
                }
                and offset in local_calls
            ):
                continue
            line = code.count("\n", 0, match.start()) + 1
            errors.append(f"service boundary: {path}:{line}: {rule}: {match[0].strip()}")
    return errors


def ownership_errors(
    scope: str,
    source: str,
    path: str = "",
    aliases: tuple = (),
    properties: tuple = (),
    *,
    call_context=None,
) -> list[str]:
    source = local_resource_source(
        expanded_resource_source(source, aliases, path or "resource-source"),
        path or "resource-source",
        call_context,
    )
    source = normalized_resource_source(source)
    if call_context:
        call_context = call_context.replacing_source(
            path or "resource-source", resource_facts(source)
        )
    code = swift_code(source)
    patterns = []
    if layer(scope) is not None:
        patterns.append(GLOBAL_RESOURCE_PATTERN)
        if scope != "TransportCore":
            patterns.append(r"\bURLSessionTransport\s*\.\s*(?:make|clearSharedCache)\b")
        if scope != "StorageCore":
            patterns.append(
                (
                    "\\bAppFileSystem\\s*\\.\\s*files\\b|\\b(?:LocalAppFileService|UserDefaults)\\"
                    "s*(?:\\(|\\.\\s*init\\b)"
                )
            )
    if scope in {"GalleryFeature", "CommunityUI"}:
        patterns.append(r"\b(?:ComposerDraftStore|GalleryMessageReadStore)\b")
    if scope == "ScoreFeature":
        patterns.append(r"\b(?:ScoreCacheStore|ScoreFilterPreferenceStore)\b")
    if scope == "AppScheduleCacheEffects":
        patterns.append(
            (
                "\\b(?:AppFileDirectories|AppAccountSession|ScheduleCloudSyncManager|ScheduleLiveA"
                "ctivityManager|ScheduleSystemCalendarManager)\\b|\\.\\s*shared\\b"
            )
        )
    if scope == "AppExternalDisplayCoordinator":
        patterns.append(
            (
                "\\b(?:AppFileDirectories|AppAccountSession|ScheduleWidgetExporter|ScheduleLiveAct"
                "ivityManager|WatchScheduleSyncManager|AppErrorPresenter)\\b|\\.\\s*shared\\b"
            )
        )
    if scope == "AppLocalDataService":
        patterns.extend(
            (
                GLOBAL_RESOURCE_PATTERN,
                (
                    "\\b(?:LoginStorage|ScheduleCacheStore|ScheduleWidgetExporter|AppMedia|AppSett"
                    "ingsStore|WKWebsiteDataStore)\\b"
                ),
            )
        )
    if settings_owner(scope):
        patterns.append(r"\b(?:AppMedia|LoginStorage)\s*\.")
    implicit = (
        [
            f"resource ownership: {scope} selects UserDefaults at line {line}"
            for line in implicit_resource_accesses(
                source,
                properties=properties,
                call_context=call_context,
                origin=path or "resource-source",
            )
        ]
        if layer(scope) is not None
        else []
    )
    if layer(scope) is not None:
        implicit.extend(
            f"resource ownership: {scope} selects CFPreferences at line {line}"
            for line in implicit_file_accesses(source, CF_PREFERENCE_FUNCTIONS)
        )
    if layer(scope) is not None and scope != "StorageCore":
        implicit.extend(
            f"resource ownership: {scope} selects LocalAppFileService at line {line}"
            for line in implicit_resource_accesses(
                source,
                "LocalAppFileService",
                properties,
                call_context=call_context,
                origin=path or "resource-source",
            )
        )
    return implicit + [
        f"resource ownership: {scope} uses {match[0].strip()}"
        for pattern in patterns
        for match in re.finditer(pattern, code)
        if not (
            scope == "TransportCore"
            and re.fullmatch(r"URLCache\s*\.\s*shared", match[0])
            and resource_permissions(path, source)(
                "cache", offset=len(source[: match.start()].encode())
            )
        )
    ]


def settings_owner(name: str) -> bool:
    return name.startswith(("Settings", "DeveloperSuggestion")) or name in {
        "GallerySettingsPage",
        "AboutSettingsPage",
        "AccountSettingsPage",
    }


def adapter_roles(index: dict[str, dict], path: str | None = None) -> dict[tuple[str, ...], str]:
    roles = {
        (name,): name
        for name in {
            "AppScheduleCacheEffects",
            "AppExternalDisplayCoordinator",
            "AppLocalDataService",
        }
    }
    protocols = {
        "SchedulePlatformActions": "AppScheduleCacheEffects",
        "AppExternalDisplayCoordinating": "AppExternalDisplayCoordinator",
    }
    conformances = declaration_conformances(index, path)
    view_owners = {
        owner
        for owner, bases in conformances.items()
        if any(base.rsplit(".", 1)[-1] == "View" for base in bases)
    }
    for owner, bases in conformances.items():
        for inherited in bases:
            if role := protocols.get(inherited.rsplit(".", 1)[-1]):
                roles[owner] = role
    for source, facts in index.items():
        if path is not None and source != path:
            continue
        if source.startswith("BIT101-iOS/Settings/"):
            for declaration in facts.get("declarations", []):
                roles.setdefault(
                    canonical_type_scope(declaration.get("scope", []) + [declaration["name"]]),
                    "Settings",
                )
        for function in facts.get("functionRanges", []):
            if (
                function["name"] == "resetAllLocalData"
                and function["scope"]
                and not scope_contains_type(function["scope"], view_owners)
            ):
                roles[canonical_type_scope(function["scope"])] = "AppLocalDataService"
    return roles


def adapter_call_roles(index: dict[str, dict], bindings: SwiftBindingTypes | None = None) -> dict:
    from network_capability_rules import (
        api_invocations,
        call_can_execute,
        callback_body_ranges,
        executed_callback_positions,
        matching_api_calls,
    )
    from swift_type_index import (
        callable_effect_index,
        compilation_unit,
        execution_index,
        receiver_resolver,
    )

    index = execution_index(callable_effect_index(index))
    bindings = bindings or SwiftBindingTypes(index)
    types = bindings.types
    resolve_receiver = receiver_resolver(index, types=types, binding_types=bindings)
    nodes, by_name, active = {}, {}, {}
    for path, facts in index.items():
        roles = adapter_roles(index, path)
        for function in (
            facts.get("functionRanges", [])
            + facts.get("accessorRanges", [])
            + facts.get("inlineClosureRanges", [])
            + [node for node in facts.get("initializers", []) if node.get("isExplicitInitializer")]
        ):
            key = (path, function["start"], function["end"])
            nodes[key] = function
            by_name.setdefault(function["name"], []).append((path, function))
            scope = canonical_type_scope(function["scope"])
            active[key] = {role for owner, role in roles.items() if scope[: len(owner)] == owner}
            active[key].update(owner for owner in function["scope"] if settings_owner(owner))

    def resolve_call_candidates(call, path):
        expression = call["calledExpression"]
        receiver, _, name = expression.rpartition(".")
        target_owner = resolve_receiver(dict(call, path=path)) if receiver else None
        candidates = []
        for target_path, function in by_name.get(name, []):
            if compilation_unit(target_path) != compilation_unit(path):
                continue
            if function.get("isPrivate") and target_path != path:
                continue
            if receiver in {"", "self", "Self"}:
                if call["scope"][: len(function["scope"])] != function["scope"]:
                    continue
                if function.get("lexicalScope") and (
                    target_path != path
                    or call.get("lexicalScope", [])[: len(function["lexicalScope"])]
                    != function["lexicalScope"]
                ):
                    continue
            elif target_owner != ".".join([compilation_unit(target_path), *function["scope"]]):
                continue
            candidates.append((target_path, function))
        if candidates and receiver in {"", "self", "Self"}:
            max_depth = max(
                (len(function["scope"]), len(function.get("lexicalScope", [])))
                for _, function in candidates
            )
            candidates = [
                (target_path, function)
                for target_path, function in candidates
                if (len(function["scope"]), len(function.get("lexicalScope", []))) == max_depth
            ]
        return candidates

    edges = {key: set() for key in nodes}
    for path, facts in index.items():
        for call in api_invocations(facts):
            if not call_can_execute(facts, call):
                continue
            parents = [key for key in nodes if key[0] == path and key[1] <= call["start"] < key[2]]
            if not parents:
                continue
            caller = min(parents, key=lambda key: key[2] - key[1])
            candidates = resolve_call_candidates(call, path)
            matches = matching_api_calls(
                index, candidates, dict(call, path=path), types=types, conservative=True
            )
            edges[caller].update(
                (target_path, function["start"], function["end"])
                for target_path, function in matches
            )
            positions = executed_callback_positions(call, project_call=bool(matches))
            edges[caller].update(
                (path, start, end)
                for start, end in callback_body_ranges(facts, call, positions)
                if (path, start, end) in nodes
            )
    changed = True
    while changed:
        changed = False
        for caller, targets in edges.items():
            for target in targets:
                additions = active[caller] - active[target]
                if additions:
                    active[target].update(additions)
                    changed = True
    return active


def adapter_ownership_errors(
    facts: dict, path: str = "", roles: dict | None = None, *, call_roles=None
) -> list[str]:
    errors = set()
    if roles is None:
        roles = adapter_roles({path: facts})
    if call_roles is None:
        call_roles = adapter_call_roles({path: facts})
    for node in facts["scopedIdentifiers"] + facts["members"]:
        scope = canonical_type_scope(node["scope"])
        active_roles = {role for owner, role in roles.items() if scope[: len(owner)] == owner}
        active_roles.update(owner for owner in node["scope"] if settings_owner(owner))
        parents = [key for key in call_roles if key[0] == path and key[1] <= node["start"] < key[2]]
        if parents:
            active_roles.update(call_roles[min(parents, key=lambda key: key[2] - key[1])])
        line = facts.get("source", "").encode()[: node["start"]].count(b"\n") + 1
        for role in active_roles:
            errors.update(
                f"{path or 'source'}:{line}: {error}"
                for error in ownership_errors(role, node["value"])
            )
    return sorted(errors)


def native_target_errors(root: Path, package: dict, modules: set[str]) -> list[str]:
    from code_quality_rules import native_project_targets
    from validation_inputs import (
        SWIFT_ROOTS,
        NATIVE_PRODUCT_ROOTS,
        NATIVE_TEST_ROOTS,
        repository_input_names,
        native_project_paths,
    )

    project = json.loads(
        subprocess.check_output(
            [
                "plutil",
                "-convert",
                "json",
                "-o",
                "-",
                str(root / "BIT101-iOS.xcodeproj/project.pbxproj"),
            ],
            text=True,
        )
    )
    errors: list[str] = []
    for identifier, path in native_project_paths(project, root).items():
        if project["objects"][identifier].get("isa") == "PBXFileReference" and not path.exists():
            errors.append(
                f"工程文件引用需要对应实际文件：{path.relative_to(root) if path.is_relative_to(root) else path}"
            )
    inventory = {
        root / name
        for name in repository_input_names(root)
        if Path(name).suffix == ".swift"
        and Path(name).parts[0] in SWIFT_ROOTS
        and (root / name).is_file()
    }
    compiled = set()
    for name, declared, sources in native_project_targets(project, root):
        compiled.update(sources)
        for source in sorted(sources - inventory):
            errors.append(
                (
                    f"native target "
                    f"{name}"
                    f" source requires validation inventory registration: "
                    f"{source.relative_to(root)}"
                )
            )
        actual = {
            module
            for source in sources
            for module in imports_in_text(source.read_text(encoding="utf-8"))
        }
        exported = {
            module
            for product in package["products"]
            if product["name"] in declared
            for module in product["targets"]
        }
        for module in actual & modules - exported:
            errors.append(f"native target {name} imports undeclared product for {module}")
    for source in sorted(inventory - compiled):
        if source.relative_to(root).parts[0] in NATIVE_PRODUCT_ROOTS + NATIVE_TEST_ROOTS:
            errors.append(f"native source requires target membership: {source.relative_to(root)}")
    return errors


def _audit_module_unit(task: tuple) -> tuple[bool, list[str]]:
    (
        module,
        info,
        rel_paths,
        raw_map,
        raw_facts_map,
        unit_index,
        aliases,
        module_aliases,
        known_modules,
        root_str,
    ) = task
    root = Path(root_str)
    source_root = root / info["path"]
    errors: list[str] = []
    if info["type"] != "regular" or info["path"] != f"Modules/{module}/Sources":
        errors.append(f"{module} requires a regular target at Modules/{module}/Sources")
    if not source_root.is_dir():
        errors.append(f"{module} source root missing: {source_root}")
        return False, errors
    for rel, text in raw_map.items():
        RAW_FACTS_BY_SOURCE[text] = raw_facts_map[rel]
    call_context = SwiftBindingTypes(unit_index)
    has_swiftui = False
    for rel in rel_paths:
        unit_context = compilation_type_context(unit_index, rel, types=call_context.types)
        text = raw_map[rel]
        context = imported_aliases(text, aliases, module_aliases)
        imports = raw_imports(text)
        if "SwiftUI" in imports:
            has_swiftui = True
        errors.extend(platform_errors(module, imports))
        errors.extend(
            ownership_errors(module, text, rel, context, unit_context[0], call_context=call_context)
        )
        errors.extend(
            service_boundary_errors(rel, text, context, unit_context, call_context=call_context)
        )
    actual = imported_modules(source_root)
    for dependency in info["dependencies"] - actual.keys():
        errors.append(f"{module} declares unused {dependency}")
    for imported, files in actual.items():
        if imported not in known_modules:
            errors.append(f"{module} imports unknown module {imported}: {', '.join(sorted(files))}")
        elif imported not in info["dependencies"]:
            errors.append(f"{module} imports undeclared {imported}: {', '.join(sorted(files))}")
    return has_swiftui, errors


def _audit_native_unit(task: tuple) -> tuple[list[str], list[str]]:
    name, rel_paths, raw_map, raw_facts_map, unit_index, aliases, module_aliases = task
    for rel, text in raw_map.items():
        RAW_FACTS_BY_SOURCE[text] = raw_facts_map[rel]
    call_context = SwiftBindingTypes(unit_index)
    adapter_errors: list[str] = []
    if name == "BIT101-iOS":
        call_roles = adapter_call_roles(unit_index, bindings=call_context)
        for rel in rel_paths:
            adapter_errors.extend(
                adapter_ownership_errors(
                    unit_index[rel],
                    rel,
                    adapter_roles(unit_index, rel),
                    call_roles=call_roles,
                )
            )
    service_errors: list[str] = []
    for rel in rel_paths:
        unit_context = compilation_type_context(unit_index, rel, types=call_context.types)
        text = raw_map[rel]
        service_errors.extend(
            service_boundary_errors(
                rel,
                text,
                imported_aliases(text, aliases, module_aliases),
                unit_context,
                call_context=call_context,
                origin=rel,
            )
        )
    return adapter_errors, service_errors


def _audit_business_methods(network_index: dict) -> dict:
    from network_capability_rules import business_methods, execution_index

    return business_methods(execution_index(network_index))


def _audit_reachable_smoke(network_index: dict) -> dict:
    from network_capability_rules import execution_index
    from validation_test_areas import reachable_smoke_calls

    return reachable_smoke_calls(execution_index(network_index))


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

    from validation_inputs import NATIVE_PRODUCT_ROOTS

    modules = {name: info for name, info in targets.items() if info["path"].startswith("Modules/")}
    support = {
        name: info
        for name, info in targets.items()
        if info["type"] == "regular" and info["path"].startswith("ModuleTests/")
    }
    tests = {name: info for name, info in targets.items() if info["type"] == "test"}
    errors: list[str] = coverage_registry_findings(set(modules))
    unknown = targets.keys() - modules.keys() - support.keys() - tests.keys()
    if unknown:
        errors.append(f"unclassified source targets: {sorted(unknown)}")
    roots = {path.name for path in (root / "Modules").iterdir() if path.is_dir()}
    if modules.keys() != roots:
        errors.append(f"module source roots differ from manifest: {sorted(modules.keys() ^ roots)}")
    errors.extend(graph_errors({name: info["dependencies"] for name, info in modules.items()}))

    module_files = {
        module: [
            p.relative_to(root).as_posix() for p in sorted((root / info["path"]).rglob("*.swift"))
        ]
        for module, info in modules.items()
    }
    native_files = {
        name: [p.relative_to(root).as_posix() for p in sorted((root / name).rglob("*.swift"))]
        for name in NATIVE_PRODUCT_ROOTS
    }
    raw_sources = {
        rel: (root / rel).read_text(encoding="utf-8")
        for group in (*module_files.values(), *native_files.values())
        for rel in group
    }
    raw_index = swift_syntax_index_sources(raw_sources, resolve_tests=False)
    module_aliases = type_aliases(
        {rel: raw_index[rel] for paths in module_files.values() for rel in paths}
    )
    native_aliases = {
        name: type_aliases({rel: raw_index[rel] for rel in rel_paths})
        for name, rel_paths in native_files.items()
    }
    expanded_sources = {}
    for module, rel_paths in module_files.items():
        aliases = tuple(alias for alias in module_aliases if alias_module(alias[4]) == module)
        for rel in rel_paths:
            expanded_sources[rel] = expanded_resource_source(
                raw_sources[rel], imported_aliases(raw_sources[rel], aliases, module_aliases), rel
            )
    for name, rel_paths in native_files.items():
        aliases = native_aliases[name]
        for rel in rel_paths:
            expanded_sources[rel] = expanded_resource_source(
                raw_sources[rel], imported_aliases(raw_sources[rel], aliases, module_aliases), rel
            )
    changed_expanded = {
        rel: text for rel, text in expanded_sources.items() if text != raw_sources[rel]
    }
    expanded_delta = (
        swift_syntax_index_sources(
            changed_expanded, cache_context="resource-expanded", resolve_tests=False
        )
        if changed_expanded
        else {}
    )
    network_index = {rel: expanded_delta.get(rel, raw_index[rel]) for rel in raw_sources}

    known_modules = set(modules)
    module_tasks = [
        (
            module,
            info,
            module_files[module],
            {rel: raw_sources[rel] for rel in module_files[module]},
            {rel: raw_index[rel] for rel in module_files[module]},
            {rel: network_index[rel] for rel in module_files[module]},
            tuple(alias for alias in module_aliases if alias_module(alias[4]) == module),
            module_aliases,
            known_modules,
            str(root),
        )
        for module, info in modules.items()
    ]
    native_tasks = [
        (
            name,
            native_files[name],
            {rel: raw_sources[rel] for rel in native_files[name]},
            {rel: raw_index[rel] for rel in native_files[name]},
            {rel: network_index[rel] for rel in native_files[name]},
            native_aliases[name],
            module_aliases,
        )
        for name in NATIVE_PRODUCT_ROOTS
    ]
    from validation_test_areas import network_capability_findings

    workers = 2 if os.getenv("BIT101_AUDIT_BACKGROUND") == "1" else min(8, os.cpu_count() or 4)
    with ProcessPoolExecutor(
        max_workers=workers, mp_context=multiprocessing.get_context("spawn")
    ) as pool:
        business_future = pool.submit(_audit_business_methods, network_index)
        reachable_future = pool.submit(_audit_reachable_smoke, network_index)
        native_futures = [pool.submit(_audit_native_unit, task) for task in native_tasks]
        module_results = list(pool.map(_audit_module_unit, module_tasks))
        test_errors: list[str] = []
        check_test_consumers(test_errors, modules, root, support, tests)
        target_errors = native_target_errors(root, package, known_modules)
        native_results = [future.result() for future in native_futures]
        capability_errors = network_capability_findings(
            network_index, precomputed=(business_future.result(), reachable_future.result())
        )

    ui_modules = {
        module for (module, _), (has_ui, _) in zip(modules.items(), module_results) if has_ui
    }
    for _, module_errors in module_results:
        errors.extend(module_errors)
    errors.extend(coverage_registry_findings(known_modules, ui_modules))
    errors.extend(test_errors)
    for adapter_errors, _ in native_results:
        errors.extend(adapter_errors)
    errors.extend(target_errors)
    for _, service_errors in native_results:
        errors.extend(service_errors)
    errors.extend(capability_errors)
    if errors:
        for error in errors:
            print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    print(f"module-boundary: {len(modules)} module source roots and direct dependencies pass")
    return 0


def check_test_consumers(errors, modules, root, support, tests):
    for name, info in (support | tests).items():
        source_root = root / info["path"]
        if not source_root.is_dir() or not info["path"].startswith("ModuleTests/"):
            errors.append(f"test source root requires ModuleTests ownership: {name}")
        actual = imported_modules(source_root).keys() & (modules.keys() | support.keys())
        if actual != info["dependencies"]:
            errors.append(
                f"test consumer {name}: declared {sorted(info['dependencies'])}, "
                f"imports {sorted(actual)}"
            )
    if len(tests) < 2:
        errors.append("test consumers require independent source roots")


if __name__ == "__main__":
    from validation_artifacts import static_audit_lock

    with static_audit_lock(ROOT):
        raise SystemExit(main())
