"""Resolve business network API signatures and calls from compiler source facts."""

import re
from pathlib import Path
from swift_source_index import argument_parameter_bindings, matching_functions, visible_variables
from swift_type_index import (
    custom_constant_symbols,
    execution_index as scalar_execution_index,
    constant_folding_allowed,
    string_literal_value,
    constant_value,
    constant_boolean,
    branch_value,
    branch_condition,
    switch_entries,
    block_outcomes,
    control_flow_outcomes,
    collection_count,
    call_can_execute,
    visible_callable_ranges,
)
from network_api_facts import (
    FOUNDATION_COLLECTION_TYPES as FOUNDATION_COLLECTION_TYPES,
    NETWORK_FOUNDATION_API as NETWORK_FOUNDATION_API,
    NETWORK_HARNESS_TYPES as NETWORK_HARNESS_TYPES,
    NETWORK_PLATFORM_CONNECTION_TYPES as NETWORK_PLATFORM_CONNECTION_TYPES,
    NETWORK_PLATFORM_STREAM_TYPES as NETWORK_PLATFORM_STREAM_TYPES,
    NETWORK_PLATFORM_TRANSPORT_TYPES as NETWORK_PLATFORM_TRANSPORT_TYPES,
    NETWORK_SYSTEM_FUNCTIONS as NETWORK_SYSTEM_FUNCTIONS,
    NETWORK_TRANSPORT_METHODS as NETWORK_TRANSPORT_METHODS,
    NETWORK_TRANSPORT_TYPES as NETWORK_TRANSPORT_TYPES,
    _is_omitted_default as _is_omitted_default,
    _match_argument_position as _match_argument_position,
    _match_return_type as _match_return_type,
    _omitted_default_parameter_starts as _omitted_default_parameter_starts,
    api_argument_bindings as api_argument_bindings,
    api_invocations as api_invocations,
    matching_api_calls as matching_api_calls,
    matching_execution_entries as matching_execution_entries,
    method_signature as method_signature,
    platform_stream_request as platform_stream_request,
    signature_function as signature_function,
    transport_method as transport_method,
)
from network_callback_rules import (
    _binding_assigned_names as _binding_assigned_names,
    _body_contains_request as _body_contains_request,
    _body_has_lexical_binding as _body_has_lexical_binding,
    _call_in_executed_closure as _call_in_executed_closure,
    _is_autoclosure_position as _is_autoclosure_position,
    _is_exported_async_closure_api as _is_exported_async_closure_api,
    _is_exported_callable_async as _is_exported_callable_async,
    _outermost_closure_spans as _outermost_closure_spans,
    _outermost_enclosed_closures as _outermost_enclosed_closures,
    _propagate_call_eager_parameters as _propagate_call_eager_parameters,
    _propagate_executed_callback_bodies as _propagate_executed_callback_bodies,
    _record_autoclosure_nodes as _record_autoclosure_nodes,
    _record_direct_executed_bodies as _record_direct_executed_bodies,
    _record_stored_closure_results as _record_stored_closure_results,
    _resolve_autoclosure_lazy_ranges as _resolve_autoclosure_lazy_ranges,
    _resolve_initializer_property_names as _resolve_initializer_property_names,
    autoclosure_index as autoclosure_index,
    callback_body_ranges as callback_body_ranges,
    executed_callback_positions as executed_callback_positions,
    execution_index as execution_index,
    snapshot_execution_checker as snapshot_execution_checker,
    stored_callback_bindings as stored_callback_bindings,
)


NETWORK_SYSTEM_FUNCTIONS |= frozenset(
    {
        "connectx",
        "disconnectx",
        "sendfile",
        "sockatmark",
        "CFSocketCreate",
        "CFSocketCreateWithNative",
        "CFSocketCreateWithSocketSignature",
        "CFSocketCreateConnectedToSocketSignature",
        "CFSocketSetAddress",
        "CFSocketConnectToAddress",
        "CFSocketSendData",
        "CFStreamCreatePairWithSocket",
        "CFStreamCreatePairWithSocketToHost",
        "CFStreamCreatePairWithPeerSocketSignature",
        "CFStreamCreatePairWithSocketToCFHost",
        "CFStreamCreatePairWithSocketToNetService",
    }
)


def business_methods(index: dict) -> dict[str, list[tuple[str, dict]]]:
    from swift_type_index import callable_effect_index

    index = execution_index(callable_effect_index(index))
    can_execute = snapshot_execution_checker()
    from validation_inputs import NATIVE_PRODUCT_ROOTS, NATIVE_TEST_ROOTS

    test_roots = {"ModuleTests", *NATIVE_TEST_ROOTS}
    from validation_compilation import active_network_source, active_swift_source
    from validation_policy import NETWORK_CAPABILITIES
    from swift_type_index import (
        SwiftTypeIndex,
        SwiftBindingTypes,
        compilation_unit,
        receiver_resolver,
    )

    types = SwiftTypeIndex(index)
    binding_types = SwiftBindingTypes(index, types)
    resolve_receiver = receiver_resolver(index, types=types, binding_types=binding_types)
    network_owners = set(NETWORK_CAPABILITIES)
    dependencies = {}
    protocols = {
        types.resolve(path, ".".join(node["scope"] + [node["name"]]), aliases=False)
        for path, facts in index.items()
        for node in facts.get("declarations", [])
        if node["kind"] == "protocol"
    }
    for target, bases in types.records.items():
        identity = ".".join([target[0], *target[1]])
        for base in bases:
            inherited = types.resolve(types.paths[target], base, target[1][:-1])
            if inherited in protocols and identity not in NETWORK_CAPABILITIES:
                dependencies.setdefault(".".join([inherited[0], *inherited[1]]), set()).add(
                    identity
                )
        if target[1][-1] not in NETWORK_TRANSPORT_TYPES and "HTTPTransport" not in types.bases(
            target
        ):
            continue
        network_owners.add(identity)
        for base in bases:
            if inherited := types.resolve(types.paths[target], base):
                network_owners.add(".".join([inherited[0], *inherited[1]]))
    active_sources = {
        path: active_network_source(facts["source"], path).encode() if "source" in facts else None
        for path, facts in index.items()
    }
    regular_sources = {
        path: active_swift_source(facts["source"], "restore", path=path).encode()
        for path, facts in index.items()
        if "source" in facts
    }

    def owner(path, scope):
        return ".".join(types.function_scope(path, scope))

    components = types.components

    def active(path, node):
        source = active_sources[path]
        return source is None or source[node["start"] : node["start"] + 1] not in {
            b" ",
            b"\n",
            b"\r",
        }

    def value_utility(path, call):
        expression = call.get("calledExpression", "")
        receiver, _, name = expression.rpartition(".")
        target = types.resolve(path, receiver, call["scope"])
        if not target:
            return False
        scope = (target[0], *target[1])
        definitions = [
            (source_path, function)
            for source_path, facts in index.items()
            for function in facts.get("functionRanges", [])
            if function["name"] == name
            and types.function_scope(source_path, function["scope"]) == scope
            and matching_functions(
                {"functionRanges": [function]}, name, dict(call, scope=function["scope"])
            )
        ]
        return bool(definitions) and all(
            not function.get("isAsync")
            and not any(
                types.terminal_name(source_path, kind, function["scope"]).rsplit(".", 1)[-1]
                in NETWORK_TRANSPORT_TYPES | {"URLRequest"}
                for kind in [
                    function.get("returnType") or "",
                    *[parameter["type"] for parameter in function.get("parameters", [])],
                ]
            )
            for source_path, function in definitions
        )

    def network_port(kind):
        return (
            "async" in kind
            and "->" in kind
            and re.search(r"\b(?:URL|URLRequest)\b", kind)
            and re.search(r"\b(?:Data|HTTPResponse|URLResponse|HTTPURLResponse)\b", kind)
        )

    def remote_data_request(facts, call, source_path):
        readers = FOUNDATION_COLLECTION_TYPES | {
            "Data",
            "NSData",
            "NSMutableData",
            "String",
            "NSString",
            "NSMutableString",
            "XMLParser",
        }
        expression = call.get("calledExpression", "").removesuffix(".init").removesuffix(
            ".self"
        ) or call.get("expectedType", "")
        expression = (
            types.terminal_name(source_path, expression, call["scope"])
            .removeprefix("Foundation.")
            .removeprefix("Swift.")
        )
        labels = call.get("argumentLabels", [])
        label = next((value for value in labels if value in {"contentsOf", "contentsOfURL"}), None)
        if expression not in readers or label is None:
            return False
        position = labels.index(label)

        def file_only_argument(argument, invocation):
            if not re.fullmatch(r"[A-Za-z_]\w*", argument):
                return False
            parameter = any(
                function["start"] <= invocation["start"] < function["end"]
                and any(
                    item.get("name") == argument and "inout" not in item.get("type", "")
                    for item in function.get("parameters", [])
                )
                for function in facts.get("functionRanges", [])
            )
            return parameter and any(
                branch["value"].startswith("guard ")
                and re.sub(r"\s+", "", branch.get("condition") or "") == argument + ".isFileURL"
                and branch["scope"] == invocation["scope"]
                and branch.get("lexicalScope") == invocation.get("lexicalScope")
                and branch.get("elseRange", [0, invocation["start"] + 1])[1] < invocation["start"]
                and not any(
                    node.get("bindingName") == argument
                    and branch["start"] < node["start"] < invocation["start"]
                    for node in facts.get("bindings", [])
                )
                for branch in facts.get("controlFlow", [])
            )

        if call.get("referenceTarget"):
            uses = [
                invocation
                for invocation in facts.get("invocations", [])
                if active(source_path, invocation)
                and can_execute(facts, invocation)
                and any(
                    node["start"] == call["start"]
                    for node in visible_callable_ranges(
                        facts, invocation.get("calledExpression", ""), invocation
                    )
                )
            ]
            return not uses or any(
                position >= len(invocation.get("arguments", []))
                or not file_only_argument(invocation["arguments"][position], invocation)
                for invocation in uses
            )
        return not file_only_argument(call.get("arguments", [])[position], call)

    def system_request(facts, call, source_path):
        expression = call.get("calledExpression", "")
        if platform_stream_request(types, source_path, call, binding_types):
            return True
        if expression in {
            module + "." + name
            for module in ("Darwin", "Glibc", "CFNetwork", "CoreFoundation")
            for name in NETWORK_SYSTEM_FUNCTIONS
        }:
            return True
        return (
            expression in NETWORK_SYSTEM_FUNCTIONS
            and not visible_variables(facts, call, expression)
            and not matching_functions(facts, expression, call)
        )

    for path, facts in index.items():
        if test_roots.intersection(Path(path).parts):
            continue
        for node in facts.get("typedVariables", []):
            if not active(path, node):
                continue
            identity = owner(path, node["scope"])
            kind = types.terminal_name(path, node.get("type", ""), node["scope"])
            if network_port(kind):
                network_owners.add(identity)
            for source_path, name, scope in components(
                path, node.get("type", ""), node["scope"], node
            ):
                target = types.resolve(source_path, name, scope)
                if (
                    types.terminal_name(source_path, name, scope).rsplit(".", 1)[-1]
                    in NETWORK_TRANSPORT_TYPES
                ):
                    network_owners.add(identity)
                if target:
                    dependencies.setdefault(identity, set()).add(".".join([target[0], *target[1]]))
        for node in facts.get("bindings", []):
            if node.get("lexicalScope") or not active(path, node):
                continue
            if target := resolve_receiver(
                dict(node, path=path, calledExpression=node["bindingName"] + ".__propertyType")
            ):
                dependencies.setdefault(owner(path, node["scope"]), set()).add(target)
        for call in facts.get("invocations", []):
            if not active(path, call):
                continue
            expression = call.get("calledExpression", "")
            if remote_data_request(facts, call, path) or system_request(facts, call, path):
                network_owners.add(owner(path, call["scope"]))
            if (
                expression.removesuffix(".init").rsplit(".", 1)[-1]
                in NETWORK_TRANSPORT_TYPES | {"URLRequest"}
                or expression.split(".", 1)[0] in NETWORK_TRANSPORT_TYPES
                and not value_utility(path, call)
            ):
                network_owners.add(owner(path, call["scope"]))
    changed = True
    while changed:
        added = {
            identity for identity, targets in dependencies.items() if targets & network_owners
        } - network_owners
        changed = bool(added)
        network_owners.update(added)
    registered_methods = {
        identity: {signature.split("(", 1)[0].removeprefix("static ") for signature in signatures}
        for identity, signatures in NETWORK_CAPABILITIES.items()
    }
    helper_functions = {}
    for source_path, source_facts in index.items():
        for function in source_facts.get("functionRanges", []) + [
            node
            for node in source_facts.get("initializers", [])
            if node.get("isExplicitInitializer")
        ]:
            if active(source_path, function):
                helper_functions.setdefault(owner(source_path, function["scope"]), []).append(
                    (source_path, function)
                )
    protocol_helpers = {}
    for identity in dependencies.keys() & network_owners:
        waiting, visited = list(dependencies[identity]), set()
        while waiting:
            implementation = waiting.pop()
            if implementation in visited:
                continue
            visited.add(implementation)
            protocol_helpers.setdefault(identity, []).extend(
                helper_functions.get(implementation, [])
            )
            waiting.extend(dependencies.get(implementation, set()) - visited)

    def transport_calls(facts):
        return (
            facts.get("invocations", [])
            + [
                dict(
                    member,
                    calledExpression=member["value"],
                    arguments=[],
                    argumentLabels=[],
                    isMemberRead=True,
                )
                for member in facts.get("members", [])
                if not member.get("isAssignmentTarget")
                and transport_method(member["value"]) in NETWORK_TRANSPORT_METHODS
            ]
            + [
                dict(
                    node, calledExpression=node["referenceTarget"], arguments=[], argumentLabels=[]
                )
                for node in facts.get("callableRanges", [])
                if node.get("referenceTarget")
            ]
        )

    executed_bodies = {}
    eager_parameters = set()
    callback_functions = [
        (source_path, function)
        for entries in helper_functions.values()
        for source_path, function in entries
        if any("->" in parameter["type"] for parameter in function.get("parameters", []))
    ]

    def executes(source_path, function, call):
        facts = index[source_path]
        return all(
            closure["start"] in executed_bodies[source_path]
            for closure in facts.get("callableRanges", []) + facts.get("inlineClosureRanges", [])
            if function["start"] <= closure["start"] <= call["start"] < closure["end"]
        )

    def callback_targets(source_path, call):
        receiver, _, name = call.get("calledExpression", "").rpartition(".")
        constructor = types.resolve(
            source_path, call.get("calledExpression", "").removesuffix(".init"), call["scope"]
        )
        if constructor:
            candidates = helper_functions.get(".".join([constructor[0], *constructor[1]]), [])
            return matching_api_calls(
                index,
                candidates,
                dict(
                    call,
                    path=source_path,
                    calledExpression="init",
                    receiverExpression=call["calledExpression"],
                ),
                types=types,
                conservative=True,
            )
        target = (
            owner(source_path, call["scope"])
            if receiver in {"", "self", "Self"}
            else resolve_receiver(dict(call, path=source_path))
        )
        candidates = helper_functions.get(target, [])
        if not receiver:
            candidates = candidates + helper_functions.get(owner(source_path, []), [])
        return matching_api_calls(
            index, candidates, dict(call, path=source_path), types=types, conservative=True
        )

    def standard_callbacks(source_path, call):
        constructor = types.resolve(
            source_path, call.get("calledExpression", "").removesuffix(".init"), call["scope"]
        )
        return executed_callback_positions(
            call,
            project_call=constructor is not None or bool(callback_targets(source_path, call)),
            potential=True,
        )

    def selector_targets(source_path, call):
        if callback_targets(source_path, call):
            return
        facts = index[source_path]
        variables = dict(
            facts,
            typedVariables=[
                dict(node, name=node["bindingName"])
                for node in facts.get("bindings", [])
                if node.get("bindingName")
            ],
        )

        def reference(value, position, seen=frozenset()):
            matches = visible_variables(variables, position, value)
            if not matches or matches[-1]["start"] in seen:
                return None
            binding = matches[-1]
            return binding.get("selectorTarget") or reference(
                binding.get("initializerReference", ""), binding, seen | {binding["start"]}
            )

        selectors = list(call.get("selectorArguments", []))
        selectors.extend([None] * (len(call.get("arguments", [])) - len(selectors)))
        for position, argument in enumerate(call.get("arguments", [])):
            selector = selectors[position] or reference(argument, call)
            if not selector:
                continue
            match = re.fullmatch(r"(?:(.+)\.)?(\w+)(?:\(([^()]*)\))?", selector)
            if not match:
                continue
            receiver, name, signature = match.groups()
            resolved = types.resolve(source_path, receiver, call["scope"]) if receiver else None
            target = (
                ".".join([resolved[0], *resolved[1]])
                if resolved
                else owner(source_path, call["scope"])
            )
            labels = (
                [label.replace("_", "") for label in signature.split(":")[:-1]]
                if signature is not None
                else None
            )
            for target_path, function in helper_functions.get(target, []):
                if function["name"] == name and (
                    labels is None
                    or labels
                    == [parameter["label"] for parameter in function.get("parameters", [])]
                ):
                    yield target_path, function

    stored_callbacks = stored_callback_bindings(index, types)
    stored_callback_names = {name for _, name in stored_callbacks}

    def stored_targets(source_path, call):
        receiver, _, name = call.get("calledExpression", "").rpartition(".")
        if name not in stored_callback_names:
            return []
        if receiver in {"", "self", "Self"}:
            facts = index[source_path]
            variables = visible_variables(
                dict(
                    facts,
                    typedVariables=facts.get("typedVariables", [])
                    + [
                        dict(node, name=node["bindingName"])
                        for node in facts.get("bindings", [])
                        if node.get("bindingName")
                    ],
                ),
                call,
                name,
            )
            if (
                not receiver
                and variables
                and (variables[-1].get("lexicalScope") or variables[-1].get("visibilityRange"))
            ):
                return []
            target = owner(source_path, call["scope"])
        else:
            target = resolve_receiver(dict(call, path=source_path))
        return [
            (path, closure)
            for path, closure, constructor in stored_callbacks.get((target, name), [])
            if active(path, constructor) and can_execute(index[path], constructor)
        ]

    for source_path, source_facts in index.items():
        executed_bodies[source_path] = set()
    while True:
        previous = (len(eager_parameters), sum(map(len, executed_bodies.values())))
        for source_path, function in callback_functions:
            names = {
                parameter["name"]
                for parameter in function["parameters"]
                if "->" in parameter["type"]
            }
            for call in index[source_path].get("invocations", []):
                if (
                    not function.get("bodyStart", function["start"])
                    <= call["start"]
                    < function["end"]
                    or not active(source_path, call)
                    or not can_execute(index[source_path], call)
                    or not executes(source_path, function, call)
                ):
                    continue
                expression = call.get("calledExpression", "")
                if expression in names:
                    eager_parameters.add((source_path, function["start"], expression))
                references = set()
                callback_body_ranges(
                    index[source_path],
                    call,
                    standard_callbacks(source_path, call),
                    references=references,
                )
                eager_parameters.update(
                    (source_path, function["start"], name) for name in references & names
                )
                _propagate_call_eager_parameters(
                    source_path,
                    function,
                    call,
                    names,
                    eager_parameters,
                    callback_targets,
                    index,
                )
        for source_path, source_facts in index.items():
            executed_starts = executed_bodies[source_path]
            for call in source_facts.get("invocations", []):
                if not (active(source_path, call) and can_execute(source_facts, call)):
                    continue
                if not _call_in_executed_closure(call, source_facts, executed_starts):
                    continue
                _record_direct_executed_bodies(
                    source_facts, source_path, call, executed_bodies, standard_callbacks
                )
                for target_path, closure in stored_targets(source_path, call):
                    executed_bodies[target_path].add(closure["start"])
                _propagate_executed_callback_bodies(
                    source_path,
                    source_facts,
                    call,
                    callback_targets,
                    eager_parameters,
                    executed_bodies,
                )
        if previous == (len(eager_parameters), sum(map(len, executed_bodies.values()))):
            break
    result, request_results = {}, {}
    for path, facts in index.items():
        module = compilation_unit(path)
        if test_roots.intersection(Path(path).parts):
            continue

        def contains_request(function, source_path=path, seen=None):
            key = (
                source_path,
                function["start"],
                function["end"],
                function.get("bodyStart"),
                function.get("isExplicitInitializer"),
                tuple(function.get("scope", [])),
            )
            if key in request_results:
                return request_results[key]
            found = scan_requests(function, source_path, seen)
            if found or seen is None:
                request_results[key] = found
            return found

        def scan_requests(function, source_path, seen):
            if seen is None:
                seen = set()
            key = (source_path, function["start"])
            if key in seen:
                return False
            seen.add(key)
            source_facts = index[source_path]
            if function.get("isExplicitInitializer") and any(
                contains_request(node, source_path, seen)
                for node in source_facts.get("initializers", [])
                if not node.get("isExplicitInitializer") and node["scope"] == function["scope"]
            ):
                return True
            closures = source_facts.get("callableRanges", []) + source_facts.get(
                "inlineClosureRanges", []
            )
            task_bodies = executed_bodies[source_path]
            for call in transport_calls(source_facts):
                if (
                    not (function.get("bodyStart") or function["start"])
                    <= call["start"]
                    < function["end"]
                    or not active(source_path, call)
                    or not can_execute(source_facts, call)
                ):
                    continue
                target = resolve_receiver(dict(call, path=source_path))
                method = transport_method(call.get("calledExpression", ""))
                executes = all(
                    closure["start"] in task_bodies
                    for closure in closures
                    if function["start"] <= closure["start"] <= call["start"] < closure["end"]
                )
                if not executes:
                    continue
                if any(
                    contains_request(closure, target_path, seen)
                    for target_path, closure in stored_targets(source_path, call)
                ):
                    return True
                if any(
                    contains_request(callback, target_path, seen)
                    for target_path, callback in selector_targets(source_path, call)
                ):
                    return True
                callback_ranges = callback_body_ranges(
                    source_facts, call, standard_callbacks(source_path, call)
                )
                if any(
                    contains_request(closure, source_path, seen)
                    for closure in closures
                    if (closure["start"], closure["end"]) in callback_ranges
                ):
                    return True
                if remote_data_request(source_facts, call, source_path):
                    return True
                if executes and system_request(source_facts, call, source_path):
                    return True
                expression = call.get("calledExpression", "")
                constructor = types.resolve(
                    source_path, expression.removesuffix(".init"), call["scope"]
                )
                invocation = (
                    dict(call, calledExpression="init", receiverExpression=expression)
                    if constructor
                    else call
                )
                if constructor:
                    target = ".".join([constructor[0], *constructor[1]])
                definitions = matching_api_calls(
                    index,
                    helper_functions.get(target, []),
                    dict(invocation, path=source_path),
                    types=types,
                    conservative=True,
                )
                if (
                    (
                        target
                        and target.rsplit(".", 1)[-1] in NETWORK_TRANSPORT_TYPES
                        or expression.removesuffix(".init").rsplit(".", 1)[-1]
                        in NETWORK_TRANSPORT_TYPES
                    )
                    and not value_utility(source_path, call)
                    and (
                        not definitions
                        or any(function.get("isAsync") for _, function in definitions)
                    )
                    and expression.removesuffix(".init") not in NETWORK_PLATFORM_TRANSPORT_TYPES
                ):
                    return True
                if target in network_owners and (
                    method in NETWORK_TRANSPORT_METHODS
                    or method in registered_methods.get(target, set())
                ):
                    return True
                expression = call.get("calledExpression", "").removeprefix("self.")
                if any(
                    network_port(
                        types.terminal_name(
                            source_path, variable.get("type", ""), variable["scope"]
                        )
                    )
                    for variable in visible_variables(source_facts, call, expression)
                ):
                    return True
                if method in NETWORK_TRANSPORT_METHODS and any(
                    kind.rsplit(".", 1)[-1] in NETWORK_TRANSPORT_TYPES
                    or kind in NETWORK_PLATFORM_TRANSPORT_TYPES
                    for kind in binding_types.receiver_components(call, source_path)
                ):
                    return True
                receiver, _, method = call.get("calledExpression", "").rpartition(".")
                receiver_name = re.split(r"[.\[]", receiver.removeprefix("self."), maxsplit=1)[0]
                for variable in visible_variables(
                    source_facts, call, receiver_name, receiver.startswith("self.")
                ):
                    if method in NETWORK_TRANSPORT_METHODS and any(
                        types.terminal_name(component_path, name, scope).rsplit(".", 1)[-1]
                        in NETWORK_TRANSPORT_TYPES
                        for component_path, name, scope in components(
                            source_path, variable.get("type", ""), variable["scope"], call
                        )
                    ):
                        return True
                if not executes:
                    continue
                if constructor:
                    matches = definitions
                    if any(
                        contains_request(helper, candidate_path, seen)
                        for candidate_path, helper in matches
                    ):
                        return True
                    continue
                if not receiver or receiver in {"self", "Self"}:
                    if not receiver and visible_variables(source_facts, call, method):
                        continue
                    target = owner(source_path, call["scope"])
                available = helper_functions.get(target, []) + protocol_helpers.get(target, [])
                if not receiver:
                    available = available + helper_functions.get(owner(source_path, []), [])
                candidates = [
                    (candidate_path, helper)
                    for candidate_path, helper in available
                    if (not helper.get("isPrivate") or candidate_path == source_path)
                    and call.get("lexicalScope", [])[: len(helper.get("lexicalScope", []))]
                    == helper.get("lexicalScope", [])
                ]
                groups = {None: candidates}
                if target in protocol_helpers:
                    groups = {}
                    for candidate_path, helper in candidates:
                        groups.setdefault(owner(candidate_path, helper["scope"]), []).append(
                            (candidate_path, helper)
                        )
                matches = [
                    match
                    for group in groups.values()
                    for match in matching_api_calls(
                        index, group, dict(call, path=source_path), types=types, conservative=True
                    )
                ]
                if any(
                    contains_request(helper, candidate_path, seen)
                    for candidate_path, helper in matches
                ):
                    return True
            return False

        accessors = [
            node
            for node in facts.get("accessorRanges", [])
            if node.get("isAsync") or contains_request(node)
        ]
        explicit_scopes = {
            tuple(node["scope"])
            for node in facts.get("initializers", [])
            if node.get("isExplicitInitializer")
        }
        constructors = [
            node
            for node in facts.get("initializers", [])
            if (node.get("isExplicitInitializer") or tuple(node["scope"]) not in explicit_scopes)
            and contains_request(node)
        ]
        callable_apis = []
        inline_closures = facts.get("inlineClosureRanges", [])
        for declaration in facts.get("functionRanges", []) + facts.get("accessorRanges", []):
            if not declaration.get("isExported") or "->" not in (
                declaration.get("returnType") or ""
            ):
                continue
            if _is_exported_async_closure_api(declaration, inline_closures, contains_request):
                callable_apis.append(dict(declaration, isAsync=True))
        for declaration in facts.get("callableRanges", []):
            if declaration.get("lexicalScope") or not declaration.get("isExported"):
                continue
            if _is_exported_callable_async(declaration, facts, contains_request):
                callable_apis.append(dict(declaration, isAsync=True))
        for function in facts.get("functionRanges", []) + accessors + constructors + callable_apis:
            scope = function["scope"]
            if function.get("lexicalScope") or not active(path, function):
                continue
            identity = owner(path, scope)
            if method_signature(function) in NETWORK_FOUNDATION_API.get(identity, set()):
                continue
            harness_path = NETWORK_HARNESS_TYPES.get(owner(path, scope[:1]))
            harness_type = types.resolve(path, ".".join(scope[:1]), aliases=False)
            declared_path = types.paths.get(harness_type, "")
            if (
                harness_path
                and (declared_path == harness_path or declared_path.endswith("/" + harness_path))
                and path in regular_sources
                and regular_sources[path][function["start"] : function["start"] + 1]
                in {b" ", b"\n", b"\r"}
            ):
                continue
            if (
                identity not in network_owners
                and function not in callable_apis
                and not contains_request(function)
            ):
                continue
            target = types.resolve(path, ".".join(scope), aliases=False)
            if target in protocols:
                continue
            if (
                types.returns_view(path, function)
                or target
                and any(
                    base.rsplit(".", 1)[-1] in {"View", "ViewModifier", "App", "Scene"}
                    and types.resolve(path, base, target[1][:-1]) not in types.nominal_records
                    for base in types.bases(target)
                )
            ):
                continue
            parameters = function.get("parameters", [])
            if (
                target
                and "HTTPTransport" in types.bases(target)
                and function["name"] == "data"
                and not function.get("isStatic")
                and len(parameters) in {1, 2}
                and parameters[0]["label"] == "for"
                and (
                    len(parameters) == 1
                    or parameters[1]["label"] == "maximumBytes"
                    and re.sub(r"\s+", "", parameters[1]["type"]) in {"Int?", "Swift.Int?"}
                )
                and types.terminal_name(path, parameters[0]["type"], scope).rsplit(".", 1)[-1]
                == "URLRequest"
            ):
                continue
            if (
                function.get("isDeinitializer")
                and contains_request(function)
                or function.get("isExported")
                and (
                    function in callable_apis
                    or contains_request(function)
                    or method_signature(function) in NETWORK_CAPABILITIES.get(identity, {})
                )
                or module in NATIVE_PRODUCT_ROOTS
                and not function.get("isPrivate")
                and (
                    contains_request(function)
                    or method_signature(function) in NETWORK_CAPABILITIES.get(identity, {})
                )
                or not function.get("isPrivate")
                and method_signature(function) in NETWORK_CAPABILITIES.get(identity, {})
                and contains_request(function)
                or identity not in NETWORK_CAPABILITIES
                and not function.get("isPrivate")
                and contains_request(function)
            ):
                result.setdefault(identity, []).append((path, function))
    for functions in result.values():
        groups = {}
        for _, function in functions:
            groups.setdefault(method_signature(function), []).append(function)
        for group in groups.values():
            if not (len({row.get("returnType") or "Void" for row in group}) > 1):
                continue
            for function in group:
                function["returnOverload"] = True
    return result
