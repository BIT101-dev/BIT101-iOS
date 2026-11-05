"""Shared source facts and school request ownership checks."""

import re
from pathlib import Path
from functools import cache
from swift_source_index import (
    declaration_conformances,
    expected_argument_types,
    scope_contains_type,
)
from source_fact_queries import ast_has_identifier, owner_has_call, relative

ROOT = Path(__file__).resolve().parents[1]


def _matches_callback_function(
    function: dict,
    method: str,
    owner,
    receiver,
    receiver_owner,
    var_scope,
    function_paths: dict,
    types,
) -> bool:
    fn_path = function_paths[id(function)]
    fn_scope = types.function_scope(fn_path, function["scope"])
    if method[:1].isupper():
        return fn_scope == owner
    if receiver:
        return fn_scope == receiver_owner
    return var_scope[: len(fn_scope)] == fn_scope


def _matches_parameter(parameter: dict, param_index: int, label: str, index: int) -> bool:
    if "@escaping" not in parameter["type"]:
        return False
    if label:
        return parameter["label"] == label
    return param_index == index


def _matching_escaping_parameters(declarations: list, label: str, index: int) -> list:
    result = []
    for function in declarations:
        for p_idx, parameter in enumerate(function["parameters"]):
            if _matches_parameter(parameter, p_idx, label, index):
                result.append((function, parameter))
    return result


def _stored_property_names(function, parameter, declaration_facts, variable_types, owner):
    target = parameter.get("name", parameter["label"])
    body_start = function.get("bodyStart", function["start"])
    end = function["end"]
    names = set()
    for factory in declaration_facts.get("callableRanges", []):
        if (
            factory.get("isPropertyAssignment")
            and factory.get("referenceTarget") == target
            and body_start <= factory["start"] < end
            and "->" in variable_types.get((owner, factory["name"]), "")
        ):
            names.add(factory["name"])
    return names


def _is_reference_in_ranges(ref_start: int, ranges: list) -> bool:
    for start, end in ranges:
        if start <= ref_start < end:
            return True
    return False


def _find_parameter_references(
    facts: dict, function: dict, name: str, executed_ranges: list
) -> list:
    result = []
    scope = function["scope"]
    for ref in facts.get("scopedIdentifiers", []):
        if (
            ref.get("isExpressionReference")
            and ref["value"] == name
            and ref["scope"] == scope
            and _is_reference_in_ranges(ref["start"], executed_ranges)
        ):
            result.append(ref)
    return result


def _reference_can_run(
    ref: dict, body_start: int, end: int, facts: dict, deferred: list, can_exec
) -> bool:
    start = ref["start"]
    if not (body_start <= start < end and can_exec(facts, ref)):
        return False
    return not _is_reference_in_ranges(start, [(b["start"], b["end"]) for b in deferred])


def _parameter_observed_eager(
    function: dict,
    parameter: dict,
    facts: dict,
    path: str,
    callback_ranges: dict,
    execution_calls: dict,
    can_exec,
) -> bool:
    name = parameter.get("name", parameter["label"])
    calls = execution_calls.get((path, tuple(function["scope"]), name), [])
    deferred = facts.get("callableRanges", []) + callback_ranges[path][0]
    executed = callback_ranges[path][2]
    references = _find_parameter_references(facts, function, name, executed)
    candidates = [call for _, call in calls] + references
    body_start = function.get("bodyStart", function["start"])
    end = function["end"]
    return any(
        _reference_can_run(ref, body_start, end, facts, deferred, can_exec)
        for ref in candidates
    )


def _collect_function_bodies(function: dict) -> list[tuple[int, int, int]]:
    bodies = [
        (
            function["start"],
            function.get("bodyStart", function["start"]),
            function["end"],
        )
    ]
    for parameter in function.get("parameters", []):
        bounds = parameter.get("defaultExpressionRange")
        if bounds:
            bodies.append((bounds[0], *bounds))
    return bodies


def _is_deferred_reference(ref_start: int, function: dict, deferred_ranges: list) -> bool:
    fn_name = function["name"]
    fn_span = (function["start"], function["end"])
    for deferred in deferred_ranges:
        if deferred["start"] <= ref_start < deferred["end"]:
            if fn_name == "init" or (deferred["start"], deferred["end"]) != fn_span:
                return True
    return False


def _collect_children_references(
    references: list, start: int, end: int, function: dict, deferred_ranges: list
) -> list:
    return [
        ref
        for ref in references
        if start <= ref["start"] < end
        and not _is_deferred_reference(ref["start"], function, deferred_ranges)
    ]


def _index_function_record(
    function: dict,
    is_callable: bool,
    path: str,
    references: list,
    deferred_ranges: list,
    var_scope_fn,
    declarations: dict,
    functions: dict,
    roots: list,
):
    if is_callable:
        function = dict(function, isCallableValue=True)
    bodies = _collect_function_bodies(function)
    for identity_start, start, end in bodies:
        key = (var_scope_fn(path, function), function["name"], path, identity_start)
        declarations[key] = (path, function)
        children = _collect_children_references(
            references, start, end, function, deferred_ranges
        )
        functions.setdefault(function["name"], []).append((key, children))
        if function.get("isDeinitializer"):
            roots.extend(children)


def _is_in_deferred(ref_start: int, deferred_ranges: list) -> bool:
    for d in deferred_ranges:
        if d["start"] <= ref_start < d["end"]:
            return True
    return False


def _collect_declaration_roots(
    declaration: dict, references: list, deferred_ranges: list
) -> list:
    inherited = {value.rsplit(".", 1)[-1] for value in declaration["inheritedTypes"]}
    name = declaration["name"]
    if not (
        "App" in inherited
        or name.endswith("Lifecycle")
        or name == "ScheduleReminderBackgroundRefresh"
    ):
        return []
    scope = declaration["scope"] + [name]
    scope_len = len(scope)
    return [
        call
        for call in references
        if call["scope"][:scope_len] == scope
        and not _is_in_deferred(call["start"], deferred_ranges)
    ]


def _collect_lifecycle_roots(
    lifecycle_ranges: list, references: list, deferred_ranges: list
) -> list:
    result = []
    for lifecycle in lifecycle_ranges:
        start, end = lifecycle["start"], lifecycle["end"]
        for ref in references:
            if start <= ref["start"] < end and not _is_in_deferred(ref["start"], deferred_ranges):
                result.append(ref)
    return result


def _collect_native_callback_roots(
    function: dict,
    path: str,
    types,
    native_callbacks: dict,
    references: list,
    deferred_ranges: list,
) -> list:
    name = function["name"]
    if not any(name in names for names in native_callbacks.values()):
        return []
    owner = types.resolve(path, ".".join(function["scope"]), aliases=False)
    bases = {base.rsplit(".", 1)[-1] for base in types.bases(owner)} if owner else set()
    if not any(name in native_callbacks.get(base, set()) for base in bases):
        return []
    start = function.get("bodyStart", function["start"])
    end = function["end"]
    return [
        ref
        for ref in references
        if start <= ref["start"] < end and not _is_in_deferred(ref["start"], deferred_ranges)
    ]


def automatic_school_fetch_findings(syntax_index: dict[str, dict]) -> list[str]:
    """核对生命周期调用链与学校业务请求入口。"""
    from network_capability_rules import (
        snapshot_execution_checker,
        execution_index,
        matching_execution_entries,
    )
    from validation_compilation import active_swift_source, source_architectures, source_platforms

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
                errors.append(f"{relative(path)}: 学校/WebVPN 请求须由用户操作触发：{term}")
        for term in forbidden_literals:
            if any(term in literal["value"] for literal in facts["stringSegments"]):
                errors.append(f"{relative(path)}: 学校/WebVPN 请求须由用户操作触发：{term}")

    if owner_has_call(syntax_index, "ScoreListPage", "bootstrapIfNeeded"):
        errors.append("ScoreListPage: 成绩页的学校查询须由用户操作触发")

    syntax_index = {
        path: facts
        for path, facts in syntax_index.items()
        if not any(
            Path(path).is_relative_to(ROOT / root)
            for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")
        )
    }
    syntax_index, call_can_execute = execution_index(syntax_index), snapshot_execution_checker()
    active_sources = {
        path: [
            active_swift_source(
                facts["source"], "restore", platform=platform, architecture=architecture, path=path
            ).encode()
            for platform in source_platforms(path)
            for architecture in source_architectures(platform, facts["source"])
        ]
        for path, facts in syntax_index.items()
        if "#" in facts.get("source", "")
    }

    school_protocols = {
        "ScheduleCourseServicing",
        "ScheduleDDLServicing",
        "ScheduleClassroomServicing",
        "ScoreListServicing",
        "TrustedTranscriptServicing",
    }
    from swift_type_index import SwiftTypeIndex

    types = SwiftTypeIndex(syntax_index)
    protocols = {
        types.resolve(path, ".".join(declaration["scope"] + [declaration["name"]]), aliases=False)
        for path, facts in syntax_index.items()
        for declaration in facts.get("declarations", [])
        if declaration["kind"] == "protocol"
    }
    school_owners = {owner for owner in protocols if owner and owner[1][-1] in school_protocols}
    while inherited := {
        owner
        for owner in protocols - school_owners
        if owner
        and any(
            types.resolve(types.paths[owner], base, owner[1][:-1]) in school_owners
            for base in types.records[owner]
        )
    }:
        school_owners.update(inherited)
    school_scopes = {(namespace,) + scope for namespace, scope in school_owners}
    school_operations = {
        function["name"]
        for path, facts in syntax_index.items()
        for function in facts.get("functionRanges", [])
        if types.function_scope(path, function["scope"]) in school_scopes
    }
    school_receivers = set(school_owners)
    while inherited := {
        owner
        for owner in types.records.keys() - school_receivers
        if any(
            types.resolve(types.paths[owner], base, owner[1][:-1]) in school_receivers
            for base in types.records[owner]
        )
    }:
        school_receivers.update(inherited)
    functions = {}
    declarations = {}
    invocations = {
        (path, node["start"], node["calledExpression"]): node
        for path, facts in syntax_index.items()
        for node in facts.get("invocations", [])
    }
    callable_names = {
        function["name"]
        for facts in syntax_index.values()
        for category in ("callableRanges", "functionRanges", "accessorRanges")
        for function in facts.get(category, [])
    }
    from swift_type_index import SwiftBindingTypes

    bindings = SwiftBindingTypes(syntax_index, types)
    type_ids, variable_types, aliases = bindings.type_ids, bindings.variable_types, bindings.aliases
    variable_scope, receiver_type = bindings.variable_scope, bindings.receiver_type
    canonical_type, reference_paths = bindings.canonical_type, bindings.reference_paths
    call_ids = {id(call) for facts in syntax_index.values() for call in facts["calls"]}

    explicit_initializers = {
        types.function_scope(path, function["scope"])
        for path, facts in syntax_index.items()
        for function in facts.get("initializers", [])
        if function.get("isExplicitInitializer")
    }
    callback_declarations = [
        function
        for facts in syntax_index.values()
        for category in ("functionRanges", "initializers")
        for function in facts.get(category, [])
    ]
    function_paths = {
        id(function): path
        for path, facts in syntax_index.items()
        for category in ("functionRanges", "initializers")
        for function in facts.get(category, [])
    }
    callback_declarations_by_name = {}
    for function in callback_declarations:
        callback_declarations_by_name.setdefault(function["name"], []).append(function)
    execution_calls = {}
    for path, facts in syntax_index.items():
        for call in facts["calls"]:
            if not call_can_execute(facts, call):
                continue
            execution_calls.setdefault((path, tuple(call["scope"]), call["value"]), []).append(
                (facts, call)
            )
    eager_parameters = set()

    @cache
    def callback_invocations(path):
        facts, result = syntax_index[path], []
        calls = {(call["start"], call["value"]): call for call in facts["calls"]}
        for invocation in facts.get("invocations", []):
            if not invocation.get("closureArguments") and not any(
                re.fullmatch(r"(?:[\w?$]+\.)*\w+", argument)
                for argument in invocation.get("arguments", [])
            ):
                continue
            call = calls.get((invocation["start"], invocation.get("calledExpression")))
            if call is None or not call_can_execute(facts, call):
                continue
            scope = variable_scope(path, call)
            value = call["value"].removesuffix(".init")
            identity = types.resolve(path, value, call["scope"])
            owner = (
                (identity[0],) + identity[1]
                if identity
                else types.function_scope(path, value.split("."))
            )
            signature = next(
                (
                    variable_types[(scope[:length], value.removeprefix("self."))]
                    for length in range(len(scope), -1, -1)
                    if (scope[:length], value.removeprefix("self.")) in variable_types
                ),
                None,
            )
            escaping = set().union(
                *(
                    set(alias.get("escapingParameters", []))
                    for alias_path, alias, alias_scope in aliases
                    if signature == alias["name"]
                    and (not alias.get("isFilePrivate") or alias_path == path)
                    and scope[: len(alias_scope)] == alias_scope
                )
            )
            receiver = receiver_type(call)
            receiver_id = type_ids.get(receiver)
            receiver_owner = (receiver_id[0],) + receiver_id[1] if receiver_id else None
            method = value.rsplit(".", 1)[-1]
            lookup_key = "init" if method[:1].isupper() else method
            candidate_functions = callback_declarations_by_name.get(lookup_key, [])
            var_scope = variable_scope(path, call)
            declarations = [
                fn
                for fn in candidate_functions
                if _matches_callback_function(
                    fn, method, owner, receiver, receiver_owner, var_scope, function_paths, types
                )
            ]
            result.append((invocation, owner, escaping, declarations))
        return result

    def registered_callbacks(path, facts):
        registered, stored, executed = [], [], []
        for invocation, owner, escaping, declarations in callback_invocations(path):
            arguments = list(invocation.get("closureArguments", []))
            arguments += [
                [index, *bounds]
                for index, (argument, bounds) in enumerate(
                    zip(invocation.get("arguments", []), invocation.get("argumentRanges", []))
                )
                if re.fullmatch(r"(?:[\w?$]+\.)*\w+", argument)
            ]
            for index, start, end in arguments:
                labels = invocation.get("argumentLabels", [])
                label = labels[index] if index < len(labels) else ""
                property_type = variable_types.get((owner, label), "")
                memberwise = owner not in explicit_initializers and "->" in property_type
                stored_names = {label} if memberwise else set()
                parameters = _matching_escaping_parameters(declarations, label, index)
                held = parameters and all(
                    function.get("bodyStart") is not None
                    and (id(function), parameter.get("name", parameter["label"]))
                    not in eager_parameters
                    for function, parameter in parameters
                )
                for function, parameter in parameters:
                    if function.get("isExplicitInitializer"):
                        declaration_facts = syntax_index[function_paths[id(function)]]
                        stored_names.update(
                            _stored_property_names(
                                function, parameter, declaration_facts, variable_types, owner
                            )
                        )
                if parameters and not held:
                    executed.append((start, end))
                if memberwise or index in escaping or held or stored_names:
                    callback = {
                        "name": label,
                        "scope": list(owner[1:]),
                        "ownerNamespace": owner[0],
                        "lexicalScope": [],
                        "start": start,
                        "end": end,
                    }
                    registered.append(callback)
                    stored.extend(dict(callback, name=name) for name in stored_names)
        return registered, stored, executed

    while True:
        callback_ranges = {
            path: registered_callbacks(path, facts) for path, facts in syntax_index.items()
        }
        observed = set(eager_parameters)
        for function in callback_declarations:
            path = function_paths[id(function)]
            facts = syntax_index[path]
            for parameter in function["parameters"]:
                name = parameter.get("name", parameter["label"])
                if _parameter_observed_eager(
                    function,
                    parameter,
                    facts,
                    path,
                    callback_ranges,
                    execution_calls,
                    call_can_execute,
                ):
                    observed.add((id(function), name))
        if observed == eager_parameters:
            break
        eager_parameters = observed

    roots = []
    for path, facts in syntax_index.items():
        if any(
            Path(path).is_relative_to(ROOT / root)
            for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")
        ):
            continue
        identifier_ids = {id(reference) for reference in facts.get("scopedIdentifiers", [])}
        member_ranges = [
            (member["start"], member["start"] + len(member["value"].encode()))
            for member in facts.get("members", [])
        ]
        assignments = [
            (expression["start"], expression["start"] + len(match[1].encode()))
            for expression in facts.get("expressions", [])
            if (match := re.match(r"((?:self\.)?\w+\s*)=(?!=)", expression["value"]))
        ]
        discarded = [
            (expression["start"], expression["start"] + len(expression["value"].encode()))
            for expression in facts.get("expressions", [])
            if re.fullmatch(r"_\s*=(?!=)\s*[\w?.]+", expression["value"])
        ]
        scoped_refs = [
            node
            for node in facts.get("scopedIdentifiers", [])
            if node.get("isExpressionReference")
        ]
        references = [
            reference
            for reference in facts["calls"] + facts.get("members", []) + scoped_refs
            if (
                re.fullmatch(r"(?:[\w?$]+\.)*\w+", reference["value"])
                or reference["value"] == ".init"
                or reference.get("receiverCall")
            )
            and call_can_execute(facts, reference)
            and (
                path not in active_sources
                or any(
                    source[reference["start"] : reference["start"] + 1] != b" "
                    for source in active_sources[path]
                )
            )
            and not (
                id(reference) in identifier_ids
                and any(start <= reference["start"] < end for start, end in member_ranges)
            )
            and not (
                any(start <= reference["start"] < end for start, end in discarded)
                and not bindings.is_accessor_reference(reference, path)
            )
            and not any(start <= reference["start"] < end for start, end in assignments)
            and (
                "." in reference["value"]
                or reference["value"] in callable_names
                or (variable_scope(path, reference), reference["value"]) not in variable_types
            )
        ]
        registered, stored, _ = callback_ranges[path]
        deferred_ranges = facts.get("callableRanges", []) + registered
        range_sets = [
            facts.get(category, [])
            for category in ("functionRanges", "callableRanges", "initializers", "accessorRanges")
        ] + [stored]
        for ranges in range_sets:
            is_callable = ranges is stored or ranges is facts.get("callableRanges")
            for function in ranges:
                _index_function_record(
                    function,
                    is_callable,
                    path,
                    references,
                    deferred_ranges,
                    variable_scope,
                    declarations,
                    functions,
                    roots,
                )
        for declaration in facts["declarations"]:
            roots.extend(_collect_declaration_roots(declaration, references, deferred_ranges))
        roots.extend(
            _collect_lifecycle_roots(facts.get("lifecycleRanges", []), references, deferred_ranges)
        )
        native_callbacks = {
            "UIApplicationDelegate": {
                "application",
                "applicationDidBecomeActive",
                "applicationWillResignActive",
                "applicationDidEnterBackground",
                "applicationWillEnterForeground",
                "applicationWillTerminate",
                "applicationProtectedDataDidBecomeAvailable",
                "applicationProtectedDataWillBecomeUnavailable",
                "applicationSignificantTimeChange",
            },
            "UISceneDelegate": {
                "scene",
                "sceneDidBecomeActive",
                "sceneWillResignActive",
                "sceneDidEnterBackground",
                "sceneWillEnterForeground",
                "sceneDidDisconnect",
            },
            "UIViewController": {
                "viewDidLoad",
                "viewWillAppear",
                "viewIsAppearing",
                "viewDidAppear",
                "viewWillDisappear",
                "viewDidDisappear",
                "viewWillLayoutSubviews",
                "viewDidLayoutSubviews",
                "updateViewConstraints",
                "traitCollectionDidChange",
                "didReceiveMemoryWarning",
                "awakeFromNib",
            },
            "UIView": {
                "didMoveToWindow",
                "didMoveToSuperview",
                "layoutSubviews",
                "updateConstraints",
                "traitCollectionDidChange",
                "awakeFromNib",
            },
            "UIViewControllerRepresentable": {
                "makeUIViewController",
                "updateUIViewController",
                "dismantleUIViewController",
            },
            "UIViewRepresentable": {"makeUIView", "updateUIView", "dismantleUIView"},
        }
        for function in facts.get("functionRanges", []):
            roots.extend(
                _collect_native_callback_roots(
                    function, path, types, native_callbacks, references, deferred_ranges
                )
            )

    implementations_by_receiver = {}
    for identity in types.records:
        namespace, owner = identity
        for base in types.bases(identity):
            receiver = canonical_type(base, (namespace,) + owner, types.paths[identity])
            implementations_by_receiver.setdefault(receiver, set()).add((namespace,) + owner)

    def possible_targets(call):
        name = call["value"].rsplit(".", 1)[-1]
        candidates = functions.get(name, [])
        if name[:1].isupper():
            if id(call) not in call_ids:
                return []
            constructed = canonical_type(
                call["value"],
                variable_scope(reference_paths.get(id(call), ""), call),
                reference_paths.get(id(call), ""),
            )
            identity = type_ids.get(constructed)
            owner = (identity[0],) + identity[1] if identity else None
            return [entry for entry in functions.get("init", []) if entry[0][0] == owner]
        receiver = receiver_type(call)
        if receiver:
            identity = type_ids.get(receiver)
            receiver_owner = (identity[0],) + identity[1] if identity else None
            implementations = set(implementations_by_receiver.get(receiver, ()))
            if identity:
                for name in types.bases(identity):
                    if parent := types.resolve(types.paths[identity], name, identity[1][:-1]):
                        implementations.add((parent[0],) + parent[1])
            return [
                entry
                for entry in candidates
                if receiver_owner
                and entry[0][0][: len(receiver_owner)] == receiver_owner
                or any(entry[0][0][: len(owner)] == owner for owner in implementations)
            ]
        if call["value"] == ".init":
            path = reference_paths[id(call)]
            facts = syntax_index[path]
            contexts = expected_argument_types(facts, call)
            contexts.extend(
                match[1]
                for binding in facts.get("bindings", [])
                if binding["start"]
                <= call["start"]
                < binding["start"] + len(binding["value"].encode())
                and (match := re.match(r"\w+\s*:\s*([^={]+)", binding["value"]))
            )
            identities = [
                type_ids.get(canonical_type(context, variable_scope(path, call), path))
                for context in contexts
            ]
            owners = {(identity[0],) + identity[1] for identity in identities if identity}
            return [entry for entry in candidates if entry[0][0] in owners]
        scope = variable_scope(reference_paths.get(id(call), ""), call)
        owned = [entry for entry in candidates if scope[: len(entry[0][0])] == entry[0][0]]
        if owned:
            return [
                entry
                for entry in owned
                if len(entry[0][0]) == max(len(item[0][0]) for item in owned)
            ]
        receiver_name = call["value"].replace("?", "").split(".")[0]
        visible_units = {
            types.units[reference_paths[id(call)]],
            *syntax_index[reference_paths[id(call)]].get("imports", []),
        }
        candidates = [
            entry for entry in candidates if entry[0][0][0].split("@", 1)[0] in visible_units
        ]
        named = [
            entry
            for entry in candidates
            if any(receiver_name.lower() in owner.lower() for owner in entry[0][0])
        ]
        return (
            named or candidates
            if "." in call["value"]
            else [entry for entry in candidates if len(entry[0][0]) == 1]
        )

    def targets(call):
        path = reference_paths[id(call)]
        invocation = invocations.get((path, call["start"], call["value"]))
        entries = possible_targets(call)
        if (
            invocation is None
            and not any(start <= call["start"] < end for start, end in callback_ranges[path][2])
            and not any(
                node.get("referenceTarget") and node["start"] <= call["start"] < node["end"]
                for node in syntax_index[path].get("callableRanges", [])
            )
            and not any(
                node["start"] <= call["start"] < node["end"]
                for node in syntax_index[path].get("lifecycleRanges", [])
            )
        ):
            entries = [
                entry
                for entry in entries
                if declarations[entry[0]][1].get("isAccessor")
                or declarations[entry[0]][1].get("isCallableValue")
            ]
        return matching_execution_entries(
            syntax_index, entries, dict(call, path=path), declarations, invocation, types=types
        )

    reasons = {}
    predecessors = {}
    cloud_operation = "refreshFromCloudIfNeeded"

    def restricted(call):
        operation = call["value"].rsplit(".", 1)[-1].strip()
        if operation in school_operations:
            receivers = {type_ids.get(kind) for kind in bindings.receiver_components(call)}
            scope = variable_scope(reference_paths[id(call)], call)
            return (
                bool(receivers & school_receivers)
                or not (receivers - {None})
                and "." not in call["value"]
                and any(
                    scope[: len(owner) + 1] == (namespace,) + owner
                    for namespace, owner in school_receivers
                )
            )
        if operation != cloud_operation:
            return False
        preference = (
            receiver_type(call)
            in {
                "BIT101-iOS.ExperimentalPreferenceCloudSync",
                "fixture.ExperimentalPreferenceCloudSync",
                "ScheduleSync.ScheduleCloudSyncManager",
            }
            or "ExperimentalPreferenceCloudSync" in call["scope"]
            and types.units[reference_paths[id(call)]] in {"BIT101-iOS", "fixture"}
        )
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
            if operation in reasons.setdefault(key, {}):
                continue
            reasons[key][operation] = [".".join(target[0] + (target[1],))] + reasons[target][
                operation
            ]
            pending.append((key, operation))
    exceptions = {
        ("ScheduleTermPickerPage", "loadAvailableTerms"): {
            "loadAvailableTerms",
            "fetchAvailableTerms",
        },
        ("ScheduleRootView", "startClassroomPageRefresh"): {
            "fetchCurrentTermOnly",
            "prepareTeachingAccess",
            "fetchCampuses",
            "fetchBuildings",
            "fetchClassrooms",
            "prefetchClassrooms",
        },
        ("TrustedTranscriptPage", "applyIfNeeded"): {"fetchTrustedPages"},
    }
    for call in roots:
        name = call["value"].rsplit(".", 1)[-1].strip()
        allowed = set().union(
            *(
                operations
                for (owner, entry), operations in exceptions.items()
                if owner in call["scope"] and entry == name
            )
        )
        routes = [
            reason
            for key, _ in targets(call)
            for operation, reason in reasons.get(key, {}).items()
            if operation not in allowed
        ]
        if restricted(call) and name not in allowed or routes:
            path = reference_paths[id(call)]
            line = syntax_index[path]["source"].encode().count(b"\n", 0, call["start"]) + 1
            errors.append(
                f"{path}:{line}: {'/'.join(call['scope'])}: 生命周期业务拉取需要明确用户操作：{call['value']}"
                + (" → " + " → ".join(routes[0]) if routes else "")
            )

    return list(dict.fromkeys(errors))
