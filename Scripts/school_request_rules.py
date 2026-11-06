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
    executed = callback_ranges[path][2]
    if not calls and not executed:
        return False
    deferred = facts.get("callableRanges", []) + callback_ranges[path][0]
    references = _find_parameter_references(facts, function, name, executed)
    candidates = [call for _, call in calls] + references
    body_start = function.get("bodyStart", function["start"])
    end = function["end"]
    return any(
        _reference_can_run(ref, body_start, end, facts, deferred, can_exec) for ref in candidates
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
        children = _collect_children_references(references, start, end, function, deferred_ranges)
        functions.setdefault(function["name"], []).append((key, children))
        if function.get("isDeinitializer"):
            roots.extend(children)


def _is_in_deferred(ref_start: int, deferred_ranges: list) -> bool:
    for d in deferred_ranges:
        if d["start"] <= ref_start < d["end"]:
            return True
    return False


def _collect_declaration_roots(declaration: dict, references: list, deferred_ranges: list) -> list:
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
    return _SchoolRequestAnalysis(syntax_index).collect()


class _SchoolRequestAnalysis:
    def __init__(self, syntax_index):
        self.syntax_index = syntax_index
        self.callback_invocations = cache(self.callback_invocations)

    def collect(self):
        self.check_removed_entries()
        self.prepare()
        self.resolve_callbacks()
        self.collect_roots()
        self.index_receiver_implementations()
        return self.collect_findings()

    def check_removed_entries(self):
        from network_capability_rules import (
            snapshot_execution_checker,
            execution_index,
            matching_execution_entries,
        )

        self.execution_index = execution_index
        self.matching_execution_entries = matching_execution_entries
        self.snapshot_execution_checker = snapshot_execution_checker
        from validation_compilation import (
            active_swift_source,
            source_architectures,
            source_platforms,
        )

        self.active_swift_source = active_swift_source
        self.source_architectures = source_architectures
        self.source_platforms = source_platforms

        self.errors: list[str] = []
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
        for name, facts in self.syntax_index.items():
            path = Path(name)
            for term in forbidden_identifiers:
                if ast_has_identifier(facts, term):
                    self.errors.append(
                        f"{relative(path)}: 学校/WebVPN 请求须由用户操作触发：{term}"
                    )
            for term in forbidden_literals:
                if any(term in literal["value"] for literal in facts["stringSegments"]):
                    self.errors.append(
                        f"{relative(path)}: 学校/WebVPN 请求须由用户操作触发：{term}"
                    )

        if owner_has_call(self.syntax_index, "ScoreListPage", "bootstrapIfNeeded"):
            self.errors.append("ScoreListPage: 成绩页的学校查询须由用户操作触发")

    def prepare(self):
        self.syntax_index = {
            path: facts
            for path, facts in self.syntax_index.items()
            if not any(
                Path(path).is_relative_to(ROOT / root)
                for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")
            )
        }
        self.syntax_index, self.call_can_execute = (
            self.execution_index(self.syntax_index),
            self.snapshot_execution_checker(),
        )
        self.active_sources = {
            path: [
                self.active_swift_source(
                    facts[("source")],
                    ("restore"),
                    platform=platform,
                    architecture=architecture,
                    path=path,
                ).encode()
                for platform in self.source_platforms(path)
                for architecture in self.source_architectures(platform, facts["source"])
            ]
            for path, facts in self.syntax_index.items()
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

        self.types = SwiftTypeIndex(self.syntax_index)
        protocols = {
            self.types.resolve(
                path, (".").join(declaration[("scope")] + [declaration[("name")]]), aliases=False
            )
            for path, facts in self.syntax_index.items()
            for declaration in facts.get("declarations", [])
            if declaration["kind"] == "protocol"
        }
        school_owners = {owner for owner in protocols if owner and owner[1][-1] in school_protocols}
        while inherited := {
            owner
            for owner in protocols - school_owners
            if owner
            and any(
                self.types.resolve(self.types.paths[owner], base, owner[1][:-1]) in school_owners
                for base in self.types.records[owner]
            )
        }:
            school_owners.update(inherited)
        school_scopes = {(namespace,) + scope for namespace, scope in school_owners}
        self.school_operations = {
            function["name"]
            for path, facts in self.syntax_index.items()
            for function in facts.get("functionRanges", [])
            if self.types.function_scope(path, function["scope"]) in school_scopes
        }
        self.school_receivers = set(school_owners)
        while inherited := {
            owner
            for owner in self.types.records.keys() - self.school_receivers
            if any(
                self.types.resolve(self.types.paths[owner], base, owner[1][:-1])
                in self.school_receivers
                for base in self.types.records[owner]
            )
        }:
            self.school_receivers.update(inherited)
        self.functions = {}
        self.declarations = {}
        self.invocations = {
            (path, node["start"], node["calledExpression"]): node
            for path, facts in self.syntax_index.items()
            for node in facts.get("invocations", [])
        }
        self.callable_names = {
            function["name"]
            for facts in self.syntax_index.values()
            for category in ("callableRanges", "functionRanges", "accessorRanges")
            for function in facts.get(category, [])
        }
        from swift_type_index import SwiftBindingTypes

        self.bindings = SwiftBindingTypes(self.syntax_index, self.types)
        self.type_ids, self.variable_types, self.aliases = (
            self.bindings.type_ids,
            self.bindings.variable_types,
            self.bindings.aliases,
        )
        self.variable_scope, self.receiver_type = (
            self.bindings.variable_scope,
            self.bindings.receiver_type,
        )
        self.canonical_type, self.reference_paths = (
            self.bindings.canonical_type,
            self.bindings.reference_paths,
        )
        self.call_ids = {
            id(call) for facts in self.syntax_index.values() for call in facts[("calls")]
        }

        self.explicit_initializers = {
            self.types.function_scope(path, function["scope"])
            for path, facts in self.syntax_index.items()
            for function in facts.get("initializers", [])
            if function.get("isExplicitInitializer")
        }
        self.callback_declarations = [
            function
            for facts in self.syntax_index.values()
            for category in ("functionRanges", "initializers")
            for function in facts.get(category, [])
        ]
        self.function_paths = {
            id(function): path
            for path, facts in self.syntax_index.items()
            for category in ("functionRanges", "initializers")
            for function in facts.get(category, [])
        }
        self.callback_declarations_by_name = {}
        self.initializers_by_owner = {}
        for function in self.callback_declarations:
            self.callback_declarations_by_name.setdefault(function["name"], []).append(function)
            if function["name"] == "init":
                fn_scope = self.types.function_scope(
                    self.function_paths[id(function)], function[("scope")]
                )
                self.initializers_by_owner.setdefault(fn_scope, []).append(function)
        self.execution_calls = {}
        for path, facts in self.syntax_index.items():
            for call in facts["calls"]:
                if not self.call_can_execute(facts, call):
                    continue
                self.execution_calls.setdefault(
                    (path, tuple(call[("scope")]), call[("value")]), []
                ).append((facts, call))
        self.eager_parameters = set()

    def resolve_callbacks(self):
        while True:
            self.callback_ranges = {
                path: self.registered_callbacks(path, facts)
                for path, facts in self.syntax_index.items()
            }
            observed = set(self.eager_parameters)
            for function in self.callback_declarations:
                path = self.function_paths[id(function)]
                facts = self.syntax_index[path]
                for parameter in function["parameters"]:
                    name = parameter.get("name", parameter["label"])
                    if _parameter_observed_eager(
                        function,
                        parameter,
                        facts,
                        path,
                        self.callback_ranges,
                        self.execution_calls,
                        self.call_can_execute,
                    ):
                        observed.add((id(function), name))
            if observed == self.eager_parameters:
                break
            self.eager_parameters = observed

    def collect_roots(self):
        self.roots = []
        for path, facts in self.syntax_index.items():
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
                and self.call_can_execute(facts, reference)
                and (
                    path not in self.active_sources
                    or any(
                        source[reference["start"] : reference["start"] + 1] != b" "
                        for source in self.active_sources[path]
                    )
                )
                and not (
                    id(reference) in identifier_ids
                    and any(start <= reference["start"] < end for start, end in member_ranges)
                )
                and not (
                    any(start <= reference["start"] < end for start, end in discarded)
                    and not self.bindings.is_accessor_reference(reference, path)
                )
                and not any(start <= reference["start"] < end for start, end in assignments)
                and (
                    "." in reference["value"]
                    or reference["value"] in self.callable_names
                    or (self.variable_scope(path, reference), reference[("value")])
                    not in self.variable_types
                )
            ]
            registered, stored, _ = self.callback_ranges[path]
            deferred_ranges = facts.get("callableRanges", []) + registered
            range_sets = [
                facts.get(category, [])
                for category in (
                    ("functionRanges"),
                    ("callableRanges"),
                    ("initializers"),
                    ("accessorRanges"),
                )
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
                        self.variable_scope,
                        self.declarations,
                        self.functions,
                        self.roots,
                    )
            for declaration in facts["declarations"]:
                self.roots.extend(
                    _collect_declaration_roots(declaration, references, deferred_ranges)
                )
            self.roots.extend(
                _collect_lifecycle_roots(
                    facts.get(("lifecycleRanges"), []), references, deferred_ranges
                )
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
                self.roots.extend(
                    _collect_native_callback_roots(
                        function, path, self.types, native_callbacks, references, deferred_ranges
                    )
                )

    def index_receiver_implementations(self):
        self.implementations_by_receiver = {}
        for identity in self.types.records:
            namespace, owner = identity
            for base in self.types.bases(identity):
                receiver = self.canonical_type(
                    base, (namespace,) + owner, self.types.paths[identity]
                )
                self.implementations_by_receiver.setdefault(receiver, set()).add(
                    (namespace,) + owner
                )

    def collect_findings(self):
        self.reasons = {}
        self.predecessors = {}
        self.cloud_operation = "refreshFromCloudIfNeeded"
        for entries in self.functions.values():
            for key, children in entries:
                for child in children:
                    operation = child["value"].rsplit(".", 1)[-1].strip()
                    if self.restricted(child):
                        self.reasons.setdefault(key, {})[operation] = [child["value"]]
                    for target, _ in self.targets(child):
                        self.predecessors.setdefault(target, set()).add(key)
        pending = [(key, operation) for key, routes in self.reasons.items() for operation in routes]
        while pending:
            target, operation = pending.pop()
            for key in self.predecessors.get(target, set()):
                if operation in self.reasons.setdefault(key, {}):
                    continue
                self.reasons[key][operation] = [
                    (".").join(target[0] + (target[1],))
                ] + self.reasons[target][operation]
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
        for call in self.roots:
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
                for key, _ in self.targets(call)
                for operation, reason in self.reasons.get(key, {}).items()
                if operation not in allowed
            ]
            if self.restricted(call) and name not in allowed or routes:
                path = self.reference_paths[id(call)]
                line = self.syntax_index[path]["source"].encode().count(b"\n", 0, call["start"]) + 1
                self.errors.append(
                    f"{path}:{line}: {'/'.join(call['scope'])}: 生命周期业务拉取需要明确用户操作：{call['value']}"
                    + (" → " + " → ".join(routes[0]) if routes else "")
                )

        return list(dict.fromkeys(self.errors))

    def callback_invocations(self, path):
        facts, result = self.syntax_index[path], []
        calls = {(call["start"], call["value"]): call for call in facts["calls"]}
        for invocation in facts.get("invocations", []):
            if not invocation.get("closureArguments") and not any(
                re.fullmatch(r"(?:[\w?$]+\.)*\w+", argument)
                for argument in invocation.get("arguments", [])
            ):
                continue
            call = calls.get((invocation["start"], invocation.get("calledExpression")))
            if call is None or not self.call_can_execute(facts, call):
                continue
            scope = self.variable_scope(path, call)
            value = call["value"].removesuffix(".init")
            identity = self.types.resolve(path, value, call["scope"])
            owner = (
                (identity[0],) + identity[1]
                if identity
                else self.types.function_scope(path, value.split("."))
            )
            signature = next(
                (
                    self.variable_types[(scope[:length], value.removeprefix("self."))]
                    for length in range(len(scope), -1, -1)
                    if (scope[:length], value.removeprefix("self.")) in self.variable_types
                ),
                None,
            )
            escaping = set().union(
                *(
                    set(alias.get("escapingParameters", []))
                    for alias_path, alias, alias_scope in self.aliases
                    if signature == alias["name"]
                    and (not alias.get("isFilePrivate") or alias_path == path)
                    and scope[: len(alias_scope)] == alias_scope
                )
            )
            receiver = self.receiver_type(call)
            receiver_id = self.type_ids.get(receiver)
            receiver_owner = (receiver_id[0],) + receiver_id[1] if receiver_id else None
            method = value.rsplit(".", 1)[-1]
            if method[:1].isupper():
                declarations = list(self.initializers_by_owner.get(owner, ()))
            else:
                candidate_functions = self.callback_declarations_by_name.get(method, [])
                var_scope = self.variable_scope(path, call)
                declarations = [
                    fn
                    for fn in candidate_functions
                    if _matches_callback_function(
                        fn,
                        method,
                        owner,
                        receiver,
                        receiver_owner,
                        var_scope,
                        self.function_paths,
                        self.types,
                    )
                ]
            result.append((invocation, owner, escaping, declarations))
        return result

    def registered_callbacks(self, path, facts):
        registered, stored, executed = [], [], []
        for invocation, owner, escaping, declarations in self.callback_invocations(path):
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
                property_type = self.variable_types.get((owner, label), "")
                memberwise = owner not in self.explicit_initializers and "->" in property_type
                stored_names = {label} if memberwise else set()
                parameters = _matching_escaping_parameters(declarations, label, index)
                held = parameters and all(
                    function.get("bodyStart") is not None
                    and (id(function), parameter.get("name", parameter["label"]))
                    not in self.eager_parameters
                    for function, parameter in parameters
                )
                for function, parameter in parameters:
                    if function.get("isExplicitInitializer"):
                        declaration_facts = self.syntax_index[self.function_paths[id(function)]]
                        stored_names.update(
                            _stored_property_names(
                                function, parameter, declaration_facts, self.variable_types, owner
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

    def possible_targets(self, call):
        name = call["value"].rsplit(".", 1)[-1]
        if name[:1].isupper():
            if id(call) not in self.call_ids:
                return []
            constructed = self.canonical_type(
                call["value"],
                self.variable_scope(self.reference_paths.get(id(call), ""), call),
                self.reference_paths.get(id(call), ""),
            )
            identity = self.type_ids.get(constructed)
            owner = (identity[0],) + identity[1] if identity else None
            return [entry for entry in self.functions.get("init", []) if entry[0][0] == owner]
        candidates = self.functions.get(name, [])
        if not candidates:
            return []
        receiver = self.receiver_type(call)
        if receiver:
            identity = self.type_ids.get(receiver)
            receiver_owner = (identity[0],) + identity[1] if identity else None
            implementations = set(self.implementations_by_receiver.get(receiver, ()))
            if identity:
                for name in self.types.bases(identity):
                    if parent := self.types.resolve(
                        self.types.paths[identity], name, identity[1][:-1]
                    ):
                        implementations.add((parent[0],) + parent[1])
            return [
                entry
                for entry in candidates
                if receiver_owner
                and entry[0][0][: len(receiver_owner)] == receiver_owner
                or any(entry[0][0][: len(owner)] == owner for owner in implementations)
            ]
        if call["value"] == ".init":
            path = self.reference_paths[id(call)]
            facts = self.syntax_index[path]
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
                self.type_ids.get(
                    self.canonical_type(context, self.variable_scope(path, call), path)
                )
                for context in contexts
            ]
            owners = {(identity[0],) + identity[1] for identity in identities if identity}
            return [entry for entry in candidates if entry[0][0] in owners]
        scope = self.variable_scope(self.reference_paths.get(id(call), ""), call)
        owned = [entry for entry in candidates if scope[: len(entry[0][0])] == entry[0][0]]
        if owned:
            return [
                entry
                for entry in owned
                if len(entry[0][0]) == max(len(item[0][0]) for item in owned)
            ]
        receiver_name = call["value"].replace("?", "").split(".")[0]
        visible_units = {
            self.types.units[self.reference_paths[id(call)]],
            *self.syntax_index[self.reference_paths[id(call)]].get("imports", []),
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

    def targets(self, call):
        entries = self.possible_targets(call)
        if not entries:
            return []
        path = self.reference_paths[id(call)]
        invocation = self.invocations.get((path, call["start"], call["value"]))
        if (
            invocation is None
            and not any(
                start <= call[("start")] < end for start, end in self.callback_ranges[path][2]
            )
            and not any(
                node.get("referenceTarget") and node["start"] <= call["start"] < node["end"]
                for node in self.syntax_index[path].get("callableRanges", [])
            )
            and not any(
                node["start"] <= call["start"] < node["end"]
                for node in self.syntax_index[path].get("lifecycleRanges", [])
            )
        ):
            entries = [
                entry
                for entry in entries
                if self.declarations[entry[0]][1].get("isAccessor")
                or self.declarations[entry[0]][1].get("isCallableValue")
            ]
        return self.matching_execution_entries(
            self.syntax_index,
            entries,
            dict(call, path=path),
            self.declarations,
            invocation,
            types=self.types,
        )

    def restricted(self, call):
        operation = call["value"].rsplit(".", 1)[-1].strip()
        if operation in self.school_operations:
            receivers = {
                self.type_ids.get(kind) for kind in self.bindings.receiver_components(call)
            }
            scope = self.variable_scope(self.reference_paths[id(call)], call)
            return (
                bool(receivers & self.school_receivers)
                or not (receivers - {None})
                and "." not in call["value"]
                and any(
                    scope[: len(owner) + 1] == (namespace,) + owner
                    for namespace, owner in self.school_receivers
                )
            )
        if operation != self.cloud_operation:
            return False
        preference = (
            self.receiver_type(call)
            in {
                "BIT101-iOS.ExperimentalPreferenceCloudSync",
                "fixture.ExperimentalPreferenceCloudSync",
                "ScheduleSync.ScheduleCloudSyncManager",
            }
            or "ExperimentalPreferenceCloudSync" in call["scope"]
            and self.types.units[self.reference_paths[id(call)]] in {"BIT101-iOS", "fixture"}
        )
        return not preference
