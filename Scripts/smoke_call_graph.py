"""Inspect validation source coverage."""

from pathlib import Path
from functools import cache
import re
from validation_compilation import active_swift_source
from swift_source_index import swift_syntax_index_sources

ROOT = Path(__file__).resolve().parents[1]


def _collect_platform_calls(calls: list, route: str, seen: dict, result: dict):
    for call in calls:
        key = (
            call["path"],
            call.get("start"),
            call.get("end"),
            call["calledExpression"],
        )
        if key not in seen[route]:
            seen[route].add(key)
            result[route].append(call)


def reachable_smoke_calls(index: dict) -> dict[str, list[dict]]:
    from validation_compilation import source_platforms

    platforms = {
        platform
        for path, facts in index.items()
        if any(
            function["scope"] == ["ReleaseNetworkSmokeRunner"] and function["name"] == "run"
            for function in facts.get("functionRanges", [])
        )
        for platform in source_platforms(path)
    }
    platforms &= {"iOS"}
    result, seen = (
        {"network": [], "community-writes": []},
        {"network": set(), "community-writes": set()},
    )
    for platform in sorted(platforms):
        for root_route in ("network", "community-writes"):
            for route, calls in platform_smoke_calls(index, platform, root_route).items():
                _collect_platform_calls(calls, route, seen, result)
    return result


def _resolve_implementation_edges(
    resolved: str,
    expression: str,
    implementations: dict,
    by_name: dict,
    index: dict,
    fact: dict,
    path: str,
    key: tuple,
    types,
    nodes: dict,
    implementation_edges: dict,
):
    from network_capability_rules import matching_api_calls

    method = expression.rsplit(".", 1)[-1]
    concrete = {
        target
        for target in implementations.get(resolved, set())
        if ".".join([target[0], *target[1], method]) in by_name
    }
    fact_with_path = dict(fact, path=path)
    for target in concrete:
        name = ".".join([target[0], *target[1], method])
        targets = [(node[0], nodes[node]) for node in by_name[name]]
        matches = matching_api_calls(index, targets, fact_with_path, types=types)
        for source_path, function in matches:
            edge = ((source_path, function["start"], function["end"]), target)
            implementation_edges.setdefault(key, set()).add(edge)


def _filter_target_keys(target_keys: set, nodes: dict) -> set:
    if not target_keys:
        return set()
    depth = max(len(nodes[tk].get("lexicalScope", [])) for tk in target_keys)
    return {tk for tk in target_keys if len(nodes[tk].get("lexicalScope", [])) == depth}


def _select_candidate_target_keys(
    target: str,
    by_name: dict,
    compilation_unit,
    path: str,
    types,
    stored_callables: set,
    nodes: dict,
    fact: dict,
) -> set:
    target_keys = set()
    fact_lexical = fact.get("lexicalScope", [])
    fact_called = fact.get("calledExpression", "")
    for target_key in by_name.get(target, set()):
        same_unit = (
            compilation_unit(target_key[0]) == compilation_unit(path)
            or target.split(".", 1)[0] in types.module_names
        )
        if not same_unit:
            continue
        tk_node = nodes[target_key]
        tk_lexical = tk_node.get("lexicalScope")
        in_stored = target_key in stored_callables or not tk_lexical
        in_lexical = (
            target_key[0] == path
            and fact_lexical[: len(tk_lexical)] == tk_lexical
            and not fact_called.startswith(("self.", "Self."))
        )
        if in_stored or in_lexical:
            target_keys.add(target_key)
    return _filter_target_keys(target_keys, nodes)


def _process_candidate_target(
    target: str,
    by_name: dict,
    compilation_unit,
    path: str,
    types,
    stored_callables: set,
    nodes: dict,
    fact: dict,
    key: tuple,
    callables: set,
    connect,
    index: dict,
    callback_calls: list,
) -> bool:
    from network_capability_rules import api_argument_bindings, matching_api_calls

    target_keys = _select_candidate_target_keys(
        target, by_name, compilation_unit, path, types, stored_callables, nodes, fact
    )
    if not fact.get("isMemberRead"):
        connect(key, target_keys & callables, fact)
    targets = [(tk[0], nodes[tk]) for tk in target_keys - callables]
    matches = matching_api_calls(
        index,
        targets,
        dict(
            fact,
            path=path,
            calledExpression=target,
            receiverExpression=fact["calledExpression"],
        ),
        types=types,
    )
    edges = ((tp, fn["start"], fn["end"]) for tp, fn in matches)
    connect(key, edges, fact)
    for target_path, function in matches:
        bindings = api_argument_bindings(function, fact)
        if len(bindings) == 1:
            callback_calls.append(
                (key, (target_path, function["start"], function["end"]), fact, bindings[0])
            )
    return bool(matches)


def _key_parameter_names(key: tuple, nodes: dict, nodes_by_path: dict, callables: set) -> set:
    parents = nodes_by_path[key[0]] if key in callables else (key,)
    result = set()
    is_callable = key in callables
    for parent in parents:
        matches = parent == key or (
            is_callable and parent[0] == key[0] and parent[1] <= key[1] and key[2] <= parent[2]
        )
        if matches:
            for parameter in nodes[parent].get("parameters", []):
                result.add(parameter.get("name"))
    return result


def _propagate_callback_guards(
    callback_calls: list,
    executed_parameters: dict,
    index: dict,
    nodes: dict,
    callback_guards: dict,
    edges: dict,
    connect,
) -> bool:
    from network_capability_rules import callback_body_ranges

    changed = False
    for caller, callee, call, bindings in callback_calls:
        for position, parameter in enumerate(bindings):
            param_name = parameter.get("name")
            if param_name not in executed_parameters[callee]:
                continue
            ranges = callback_body_ranges(index[caller[0]], call, {position})
            targets = {(caller[0], s, e) for s, e in ranges if (caller[0], s, e) in nodes}
            for target in targets:
                guard = (callee, parameter["name"], call)
                guards = callback_guards.setdefault((caller, target), [])
                if guard not in guards:
                    guards.append(guard)
            additions = targets - edges[caller]
            if additions:
                connect(caller, additions, call)
                changed = True
    return changed


def _has_constructed_type_match(
    nominal, route: str, constructed_types: dict, reached: set, ctx_facts, can_exec
) -> bool:
    for creator, call in constructed_types.get(nominal, []):
        for reached_key, reached_route, reached_context in reached:
            if creator == reached_key and route == reached_route:
                if can_exec(ctx_facts(creator, reached_context), call):
                    return True
    return False


def _resolve_implementation_targets(
    key: tuple,
    route: str,
    implementation_edges: dict,
    constructed_types: dict,
    reached: set,
    ctx_facts,
    can_exec,
) -> set:
    targets = set()
    for target, nominal in implementation_edges.get(key, set()):
        if _has_constructed_type_match(
            nominal, route, constructed_types, reached, ctx_facts, can_exec
        ):
            targets.add(target)
    return targets


def _stored_callable_reachable(
    target: tuple, target_route: str, stored_callables: dict, reached: set, ctx_facts, can_exec
) -> bool:
    if target not in stored_callables:
        return True
    for creator, constructor in stored_callables[target]:
        for parent, parent_route, parent_context in reached:
            if parent == creator and parent_route == target_route:
                if can_exec(ctx_facts(parent, parent_context), constructor):
                    return True
    return False


def _find_edge_evidence(
    key: tuple, target: tuple, edge_calls: dict, calls: dict, nodes: dict
) -> list:
    if (key, target) in edge_calls:
        return edge_calls[(key, target)]
    target_name = nodes[target]["name"]
    return [
        call
        for call in calls[key]
        if call.get("calledExpression", "").rsplit(".", 1)[-1] == target_name
    ]


def _guards_can_execute(
    guards: list, key: tuple, context, call: dict, target_ctx_fn, param_exec_fn
) -> bool:
    if not guards:
        return True
    return any(
        param_exec_fn(callee, target_ctx_fn(key, callee, context, call), name)
        for callee, name, _ in guards
    )


def _process_evidence_call(
    call: dict,
    facts: dict,
    key: tuple,
    target: tuple,
    context,
    can_exec,
    callback_guards: dict,
    target_ctx_fn,
    param_exec_fn,
) -> bool:
    if call is not None and not can_exec(facts, call):
        return False
    guards = [g for g in callback_guards.get((key, target), []) if g[2] == call]
    return _guards_can_execute(guards, key, context, call, target_ctx_fn, param_exec_fn)


def _collect_target_additions(
    target: tuple,
    route: str,
    key: tuple,
    context,
    facts: dict,
    nodes: dict,
    stored_callables: dict,
    reached: set,
    edge_calls: dict,
    calls: dict,
    callback_guards: dict,
    ctx_facts,
    can_exec,
    target_ctx_fn,
    param_exec_fn,
) -> set:
    target_route = (
        "community-writes" if nodes[target]["scope"][:1] == ["CommunityWriteSmoke"] else route
    )
    if not _stored_callable_reachable(
        target, target_route, stored_callables, reached, ctx_facts, can_exec
    ):
        return set()
    evidence = _find_edge_evidence(key, target, edge_calls, calls, nodes)
    additions = set()
    for call in evidence:
        if _process_evidence_call(
            call,
            facts,
            key,
            target,
            context,
            can_exec,
            callback_guards,
            target_ctx_fn,
            param_exec_fn,
        ):
            additions.add((target, target_route, target_ctx_fn(key, target, context, call)))
    return additions


def _is_owner_path(path: str, owner: str) -> bool:
    parts = Path(path).parts
    if "Modules" in parts:
        return parts[parts.index("Modules") + 1] == owner.split(".")[0]
    return owner.startswith("BIT101-iOS.")


def _build_enum_syntax_index(index: dict, effective: str) -> dict:
    from validation_inputs import repository_input_names, includes_input

    names = {
        argument.removesuffix(".allCases").rsplit(".", 1)[-1]
        for source in index.values()
        for entry in source["tests"]
        for argument in entry.get("arguments", [])
        if re.fullmatch(r"[\w.]+\.allCases", argument)
    }
    referenced_enum = re.compile(r"\b(?:" + "|".join(map(re.escape, sorted(names))) + r")\b")
    enum_sources = {}
    for name in repository_input_names(ROOT):
        if not (name.endswith(".swift") and includes_input(name, effective)):
            continue
        path = ROOT / name
        try:
            source = path.read_text()
        except FileNotFoundError:
            continue
        if referenced_enum.search(source) and re.search(r"\benum\s+|\ballCases\b", source):
            enum_sources[str(path)] = active_swift_source(source, effective, path=name)
    return swift_syntax_index_sources(enum_sources)


def _resolve_case_iterable_count(test: dict, scope: list[str], enum_index: dict) -> int:
    candidates = []
    for enum_facts in enum_index.values():
        for node in enum_facts["declarations"]:
            if (
                node["kind"] == "enum"
                and (node["scope"] + [node["name"]])[-len(scope) :] == scope
                and any(
                    base.rsplit(".", 1)[-1] == "CaseIterable" for base in node["inheritedTypes"]
                )
            ):
                count = sum(
                    case["scope"] == node["scope"] + [node["name"]]
                    for case in enum_facts["enumCases"]
                )
                candidates.append((node, count))
    if len(candidates) != 1:
        raise ValueError(f"参数库存需要唯一枚举定义：{test['value']}")
    node, count = candidates[0]
    enum_scope = ".".join(node["scope"] + [node["name"]])
    has_custom_all_cases = any(
        binding.get("bindingName") == "allCases"
        and binding.get("isStaticBinding") is True
        and ".".join(binding["scope"]) == enum_scope
        for enum_facts in enum_index.values()
        for binding in enum_facts["bindings"]
    )
    if has_custom_all_cases:
        raise ValueError(f"参数库存支持自动合成 allCases 和字面量数组：{test['value']}")
    return count


def platform_smoke_calls(
    index: dict, platform: str, root_route: str = "network"
) -> dict[str, list[dict]]:
    from network_capability_rules import branch_value, execution_index

    bound_scope = "all" if root_route == "network" else "communityWrites"
    index = execution_index(index)
    from pathlib import Path
    import re
    from validation_compilation import source_platforms
    from network_capability_rules import (
        api_argument_bindings,
        api_invocations,
        call_can_execute as evaluate_call,
        callback_body_ranges,
        executed_callback_positions,
        stored_callback_bindings,
    )
    from swift_type_index import SwiftTypeIndex, compilation_unit, receiver_resolver

    types, resolve_receiver = SwiftTypeIndex(index), receiver_resolver(index)
    execution_cache = {}

    def call_can_execute(facts, call):
        identity = (id(facts), id(call))
        if identity not in execution_cache:
            execution_cache[identity] = (facts, call, evaluate_call(facts, call))
        return execution_cache[identity][2]

    units = {
        compilation_unit(path)
        for path, facts in index.items()
        if any(
            function["scope"] == ["ReleaseNetworkSmokeRunner"] and function["name"] == "run"
            for function in facts.get("functionRanges", [])
        )
    }
    files = {
        path
        for path in index
        if platform in source_platforms(path)
        and (compilation_unit(path) in units or "Modules" in Path(path).parts)
    }
    nodes, by_name, active_sources, callables, stored_callables = {}, {}, {}, set(), {}
    for path, facts in index.items():
        if path not in files:
            continue
        active = (
            active_swift_source(facts["source"], "network", platform=platform, path=path).encode()
            if "source" in facts
            else None
        )
        active_sources[path] = active
        closures = facts.get("callableRanges", []) + facts.get("inlineClosureRanges", [])
        for function in (
            facts.get("functionRanges", [])
            + facts.get("accessorRanges", [])
            + closures
            + [node for node in facts.get("initializers", []) if node.get("isExplicitInitializer")]
        ):
            if active is not None and active[function["start"] : function["start"] + 1] in {
                b" ",
                b"\n",
                b"\r",
            }:
                continue
            key = (path, function["start"], function["end"])
            nodes[key] = function
            if function in closures:
                callables.add(key)
            name = ".".join([*function["scope"], function["name"]])
            by_name.setdefault(name, set()).add(key)
            by_name.setdefault(compilation_unit(path) + "." + name, set()).add(key)
            by_name.setdefault(
                ".".join([*types.function_scope(path, function["scope"]), function["name"]]), set()
            ).add(key)
    for (owner, name), bindings in stored_callback_bindings(index, types).items():
        for path, closure, call in bindings:
            key = (path, closure["start"], closure["end"])
            if key not in nodes:
                continue
            parents = [
                parent
                for parent in nodes
                if parent[0] == path and parent[1] <= call["start"] < parent[2]
            ]
            if not parents:
                continue
            stored_callables.setdefault(key, []).append(
                (min(parents, key=lambda item: item[2] - item[1]), call)
            )
            by_name.setdefault(owner.split(".", 1)[1] + "." + name, set()).add(key)
            by_name.setdefault(owner + "." + name, set()).add(key)
    edges = {key: set() for key in nodes}
    edge_calls = {}

    def connect(caller, targets, call=None):
        for target in targets:
            edges[caller].add(target)
            evidence = edge_calls.setdefault((caller, target), [])
            if call not in evidence:
                evidence.append(call)

    calls = {key: [] for key in nodes}
    callback_calls = []
    constructed_types, implementation_edges, implementations = {}, {}, {}
    for target in types.records:
        for base in types.bases(target):
            if protocol := types.resolve(types.paths[target], base, target[1][:-1]):
                implementations.setdefault(".".join([protocol[0], *protocol[1]]), set()).add(target)
    nodes_by_path = {path: [key for key in nodes if key[0] == path] for path in files}
    for key, function in nodes.items():
        if not (reference := function.get("referenceTarget")):
            continue
        owner = ".".join(function["scope"])
        for target in {
            reference,
            owner + "." + reference.removeprefix("Self.").removeprefix("self."),
        }:
            connect(key, by_name.get(target, set()))
    for path, facts in index.items():
        if path not in files:
            continue
        active = active_sources[path]
        for fact in api_invocations(facts):
            if active is not None and active[fact["start"] : fact["start"] + 1] in {
                b" ",
                b"\n",
                b"\r",
            }:
                continue
            if not call_can_execute(facts, fact):
                continue
            containing = [key for key in nodes_by_path[path] if key[1] <= fact["start"] < key[2]]
            if not containing:
                continue
            key = min(containing, key=lambda item: item[2] - item[1])
            expression = fact.get("calledExpression", fact.get("value", "")).removeprefix("self.")
            if not fact.get("isMemberRead"):
                nominal = types.resolve(
                    path,
                    ".".join(fact["scope"])
                    if expression == "Self"
                    else expression.removesuffix(".init"),
                    fact["scope"],
                )
                if nominal:
                    constructed_types.setdefault(nominal, []).append((key, fact))
            owner = ".".join(nodes[key]["scope"])
            candidates = {expression, owner + "." + expression.removeprefix("Self.")}
            constructor = types.resolve(path, expression.removesuffix(".init"), fact["scope"])
            if constructor:
                candidates.add(".".join([constructor[0], *constructor[1], "init"]))
            callbacks = set()
            if expression.startswith("dependencies."):
                candidates.add("ReleaseNetworkSmokeDependencies." + expression.split(".", 1)[1])
            if fact.get("receiverCall"):
                candidates.add(fact["receiverCall"] + "." + expression.rsplit(".", 1)[-1])
            if resolved := resolve_receiver(dict(fact, path=path)):
                candidates.add(resolved + "." + expression.rsplit(".", 1)[-1])
                _resolve_implementation_edges(
                    resolved,
                    expression,
                    implementations,
                    by_name,
                    index,
                    fact,
                    path,
                    key,
                    types,
                    nodes,
                    implementation_edges,
                )
            project_call = False
            for target in candidates:
                matched = _process_candidate_target(
                    target,
                    by_name,
                    compilation_unit,
                    path,
                    types,
                    stored_callables,
                    nodes,
                    fact,
                    key,
                    callables,
                    connect,
                    index,
                    callback_calls,
                )
                project_call = project_call or matched
            callback_positions = executed_callback_positions(fact, project_call=project_call)
            if expression in {
                "runInParallel",
                "probe",
                "NetworkSmokePaging.batch",
                "NetworkSmokePaging.arrayPage",
                "NetworkSmokePaging.messages",
            }:
                callback_positions.update(range(len(fact.get("arguments", []))))
                callback_positions.update(
                    position for position, _, _ in fact.get("closureArguments", [])
                )
            for position, argument in enumerate(fact.get("arguments", [])):
                if position in callback_positions:
                    callbacks.update({argument, owner + "." + argument})
            references = set()
            connect(
                key,
                (
                    (path, start, end)
                    for start, end in callback_body_ranges(
                        facts, fact, callback_positions, references=references
                    )
                    if (path, start, end) in nodes
                ),
                fact,
            )
            for target in callbacks:
                connect(key, by_name.get(target, set()) - callables, fact)
            if "calledExpression" in fact:
                calls[key].append(dict(fact, path=path, executedCallbackReferences=references))
    parameter_names = {
        key: _key_parameter_names(key, nodes, nodes_by_path, callables) for key in nodes
    }
    executed_parameters = {
        key: {
            name
            for name in parameter_names[key]
            if any(
                call["calledExpression"] == name
                and not call.get("isMemberRead")
                or name in call.get("executedCallbackReferences", set())
                for call in calls[key]
            )
        }
        for key in nodes
    }
    callback_guards = {}
    changed = True
    while changed:
        changed = False
        for caller, targets in edges.items():
            for target in targets & callables:
                if not (
                    caller[0] == target[0] and caller[1] <= target[1] and (target[2] <= caller[2])
                ):
                    continue
                additions = (
                    executed_parameters[target]
                    & parameter_names[caller] - executed_parameters[caller]
                )
                if additions:
                    executed_parameters[caller].update(additions)
                    changed = True
        for caller, callee, call, bindings in callback_calls:
            positions = {
                position
                for position, parameter in enumerate(bindings)
                if parameter.get("name") in executed_parameters[callee]
            }
            references = set()
            callback_body_ranges(index[caller[0]], call, positions, references=references)
            additions = references & parameter_names[caller] - executed_parameters[caller]
            if additions:
                executed_parameters[caller].update(additions)
                changed = True
        if _propagate_callback_guards(
            callback_calls,
            executed_parameters,
            index,
            nodes,
            callback_guards,
            edges,
            connect,
        ):
            changed = True

    @cache
    def contextual_facts(key, context):
        return dict(
            index[key[0]],
            smokeScopeBindings={
                (start, name): value for path, start, name, value in context if path == key[0]
            },
        )

    context_cache = {}

    def target_context(caller, target, context, call):
        identity = (caller, target, context, id(call))
        if identity not in context_cache:
            context_cache[identity] = (call, evaluate_context(caller, target, context, call))
        return context_cache[identity][1]

    def evaluate_context(caller, target, context, call):
        retained = {
            entry
            for entry in context
            if entry[0] == target[0]
            and entry[1] <= target[1]
            and any(
                function["start"] == entry[1] and target[2] <= function["end"]
                for function in index[target[0]].get("functionRanges", [])
            )
        }
        function = nodes[target]
        bindings = (
            api_argument_bindings(function, call)
            if call is not None and target not in callables
            else []
        )
        for parameter in function.get("parameters", []):
            kind = types.terminal_name(
                target[0], parameter.get("type", ""), function["scope"]
            ).rsplit(".", 1)[-1]
            if not re.fullmatch(r"NetworkSmokeScope|Bool|String|U?Int(?:8|16|32|64)?|Double", kind):
                continue
            position = (
                next(
                    (
                        position
                        for position, bound in enumerate(bindings[0])
                        if bound.get("name") == parameter.get("name")
                    ),
                    None,
                )
                if len(bindings) == 1
                else None
            )
            arguments = call.get("arguments", []) if call else []
            value = (
                branch_value(contextual_facts(caller, context), call, arguments[position])
                if position is not None and position < len(arguments)
                else None
            )
            if position is None and (bounds := parameter.get("defaultExpressionRange")):
                facts = contextual_facts(target, context)
                expression = facts["source"].encode()[bounds[0] : bounds[1]].decode()
                value = branch_value(facts, dict(function, start=bounds[0]), expression)
            retained = {
                entry
                for entry in retained
                if entry[:3] != (target[0], target[1], parameter["name"])
            }
            if type(value) in {bool, int, float, str}:
                retained.add((target[0], target[1], parameter["name"], value))
        return tuple(sorted(retained))

    callback_calls_by_caller = {}
    for row in callback_calls:
        callback_calls_by_caller.setdefault(row[0], []).append(row)

    @cache
    def parameter_executes(key, context, name):
        return parameter_reachable(key, context, name, set())

    def parameter_reachable(key, context, name, seen):
        identity = (key, context, name)
        if identity in seen:
            return False
        seen.add(identity)
        facts = contextual_facts(key, context)
        if any(
            call_can_execute(facts, call)
            and (
                call["calledExpression"] == name
                and not call.get("isMemberRead")
                or name in call.get("executedCallbackReferences", set())
            )
            for call in calls[key]
        ):
            return True
        for target in edges[key] & callables:
            if target[0] != key[0] or not key[1] <= target[1] < target[2] <= key[2]:
                continue
            if any(
                (call is None or call_can_execute(facts, call))
                and parameter_reachable(
                    target, target_context(key, target, context, call), name, seen
                )
                for call in edge_calls.get((key, target), [])
            ):
                return True
        for caller, callee, call, bindings in callback_calls_by_caller.get(key, []):
            if not call_can_execute(facts, call):
                continue
            for position, parameter in enumerate(bindings):
                references = set()
                callback_body_ranges(index[key[0]], call, {position}, references=references)
                if name in references and parameter_reachable(
                    callee, target_context(key, callee, context, call), parameter.get("name"), seen
                ):
                    return True
        return False

    reached = {
        (key, root_route, ((key[0], key[1], "scope", bound_scope),))
        for key in by_name.get("ReleaseNetworkSmokeRunner.run", set())
    }
    changed = True
    while changed:
        additions = set()
        for key, route, context in reached:
            facts = contextual_facts(key, context)
            targets = edges[key] | _resolve_implementation_targets(
                key,
                route,
                implementation_edges,
                constructed_types,
                reached,
                contextual_facts,
                call_can_execute,
            )
            for target in targets:
                additions |= _collect_target_additions(
                    target,
                    route,
                    key,
                    context,
                    facts,
                    nodes,
                    stored_callables,
                    reached,
                    edge_calls,
                    calls,
                    callback_guards,
                    contextual_facts,
                    call_can_execute,
                    target_context,
                    parameter_executes,
                )
        additions -= reached
        changed = bool(additions)
        reached.update(additions)
    result = {"network": [], "community-writes": []}
    for key, route, context in reached:
        result[route].extend(
            call for call in calls[key] if call_can_execute(contextual_facts(key, context), call)
        )
    return result


def smoke_receiver_resolver(index: dict):
    from swift_type_index import receiver_resolver

    return receiver_resolver(index, follow_parameters=True)
