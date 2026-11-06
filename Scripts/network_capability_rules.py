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
    return _BusinessMethodDiscovery(index).collect()


class _BusinessMethodDiscovery:
    def __init__(self, index):
        self.index = index

    def collect(self):
        self.prepare()
        self.discover_owners()
        self.resolve_callbacks()
        self.result, self.request_results = {}, {}
        for path, facts in self.index.items():
            self.collect_file(path, facts)
        self.mark_return_overloads()
        return self.result

    def prepare(self):
        from swift_type_index import callable_effect_index

        self.index = execution_index(callable_effect_index(self.index))
        self.can_execute = snapshot_execution_checker()
        from validation_inputs import NATIVE_PRODUCT_ROOTS, NATIVE_TEST_ROOTS

        self.NATIVE_PRODUCT_ROOTS = NATIVE_PRODUCT_ROOTS

        self.test_roots = {"ModuleTests", *NATIVE_TEST_ROOTS}
        from validation_compilation import active_network_source, active_swift_source
        from validation_policy import NETWORK_CAPABILITIES

        self.NETWORK_CAPABILITIES = NETWORK_CAPABILITIES
        from swift_type_index import (
            SwiftTypeIndex,
            SwiftBindingTypes,
            compilation_unit,
            receiver_resolver,
        )

        self.compilation_unit = compilation_unit

        self.types = SwiftTypeIndex(self.index)
        self.binding_types = SwiftBindingTypes(self.index, self.types)
        self.resolve_receiver = receiver_resolver(
            self.index, types=self.types, binding_types=self.binding_types
        )
        self.network_owners = set(self.NETWORK_CAPABILITIES)
        self.dependencies = {}
        self.protocols = {
            self.types.resolve(path, ".".join(node["scope"] + [node["name"]]), aliases=False)
            for path, facts in self.index.items()
            for node in facts.get("declarations", [])
            if node["kind"] == "protocol"
        }
        for target, bases in self.types.records.items():
            identity = ".".join([target[0], *target[1]])
            for base in bases:
                inherited = self.types.resolve(self.types.paths[target], base, target[1][:-1])
                if inherited in self.protocols and identity not in self.NETWORK_CAPABILITIES:
                    self.dependencies.setdefault(
                        (".").join([inherited[0], *inherited[1]]), set()
                    ).add(identity)
            if target[1][-1] not in NETWORK_TRANSPORT_TYPES and (
                "HTTPTransport"
            ) not in self.types.bases(target):
                continue
            self.network_owners.add(identity)
            for base in bases:
                if inherited := self.types.resolve(self.types.paths[target], base):
                    self.network_owners.add(".".join([inherited[0], *inherited[1]]))
        self.active_sources = {
            path: active_network_source(facts[("source")], path).encode()
            if ("source") in facts
            else None
            for path, facts in self.index.items()
        }
        self.regular_sources = {
            path: active_swift_source(facts["source"], "restore", path=path).encode()
            for path, facts in self.index.items()
            if "source" in facts
        }
        self.components = self.types.components

    def discover_owners(self):
        for path, facts in self.index.items():
            if self.test_roots.intersection(Path(path).parts):
                continue
            for node in facts.get("typedVariables", []):
                if not self.active(path, node):
                    continue
                identity = self.owner(path, node["scope"])
                kind = self.types.terminal_name(path, node.get("type", ""), node["scope"])
                if self.network_port(kind):
                    self.network_owners.add(identity)
                for source_path, name, scope in self.components(
                    path, node.get("type", ""), node["scope"], node
                ):
                    target = self.types.resolve(source_path, name, scope)
                    if (
                        self.types.terminal_name(source_path, name, scope).rsplit(".", 1)[-1]
                        in NETWORK_TRANSPORT_TYPES
                    ):
                        self.network_owners.add(identity)
                    if target:
                        self.dependencies.setdefault(identity, set()).add(
                            (".").join([target[0], *target[1]])
                        )
            for node in facts.get("bindings", []):
                if node.get("lexicalScope") or not self.active(path, node):
                    continue
                if target := self.resolve_receiver(
                    dict(node, path=path, calledExpression=node["bindingName"] + ".__propertyType")
                ):
                    self.dependencies.setdefault(self.owner(path, node["scope"]), set()).add(target)
            for call in facts.get("invocations", []):
                if not self.active(path, call):
                    continue
                expression = call.get("calledExpression", "")
                if self.remote_data_request(facts, call, path) or self.system_request(
                    facts, call, path
                ):
                    self.network_owners.add(self.owner(path, call["scope"]))
                if (
                    expression.removesuffix(".init").rsplit(".", 1)[-1]
                    in NETWORK_TRANSPORT_TYPES | {"URLRequest"}
                    or expression.split(".", 1)[0] in NETWORK_TRANSPORT_TYPES
                    and not self.value_utility(path, call)
                ):
                    self.network_owners.add(self.owner(path, call["scope"]))
        changed = True
        while changed:
            added = {
                identity
                for identity, targets in self.dependencies.items()
                if targets & self.network_owners
            } - self.network_owners
            changed = bool(added)
            self.network_owners.update(added)
        self.registered_methods = {
            identity: {
                signature.split(("("), 1)[0].removeprefix(("static ")) for signature in signatures
            }
            for identity, signatures in self.NETWORK_CAPABILITIES.items()
        }
        self.helper_functions = {}
        for source_path, source_facts in self.index.items():
            for function in source_facts.get("functionRanges", []) + [
                node
                for node in source_facts.get("initializers", [])
                if node.get("isExplicitInitializer")
            ]:
                if self.active(source_path, function):
                    self.helper_functions.setdefault(
                        self.owner(source_path, function[("scope")]), []
                    ).append((source_path, function))
        self.protocol_helpers = {}
        for identity in self.dependencies.keys() & self.network_owners:
            waiting, visited = list(self.dependencies[identity]), set()
            while waiting:
                implementation = waiting.pop()
                if implementation in visited:
                    continue
                visited.add(implementation)
                self.protocol_helpers.setdefault(identity, []).extend(
                    self.helper_functions.get(implementation, [])
                )
                waiting.extend(self.dependencies.get(implementation, set()) - visited)

    def resolve_callbacks(self):
        self.executed_bodies = {}
        eager_parameters = set()
        callback_functions = [
            (source_path, function)
            for entries in self.helper_functions.values()
            for source_path, function in entries
            if any("->" in parameter["type"] for parameter in function.get("parameters", []))
        ]
        self.stored_callbacks = stored_callback_bindings(self.index, self.types)
        self.stored_callback_names = {name for _, name in self.stored_callbacks}
        for source_path, source_facts in self.index.items():
            self.executed_bodies[source_path] = set()
        while True:
            previous = (len(eager_parameters), sum(map(len, self.executed_bodies.values())))
            for source_path, function in callback_functions:
                names = {
                    parameter["name"]
                    for parameter in function["parameters"]
                    if "->" in parameter["type"]
                }
                for call in self.index[source_path].get("invocations", []):
                    if (
                        not function.get("bodyStart", function["start"])
                        <= call["start"]
                        < function["end"]
                        or not self.active(source_path, call)
                        or not self.can_execute(self.index[source_path], call)
                        or not self.executes(source_path, function, call)
                    ):
                        continue
                    expression = call.get("calledExpression", "")
                    if expression in names:
                        eager_parameters.add((source_path, function["start"], expression))
                    references = set()
                    callback_body_ranges(
                        self.index[source_path],
                        call,
                        self.standard_callbacks(source_path, call),
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
                        self.callback_targets,
                        self.index,
                    )
            for source_path, source_facts in self.index.items():
                executed_starts = self.executed_bodies[source_path]
                for call in source_facts.get("invocations", []):
                    if not (
                        self.active(source_path, call) and self.can_execute(source_facts, call)
                    ):
                        continue
                    if not _call_in_executed_closure(call, source_facts, executed_starts):
                        continue
                    _record_direct_executed_bodies(
                        source_facts,
                        source_path,
                        call,
                        self.executed_bodies,
                        self.standard_callbacks,
                    )
                    for target_path, closure in self.stored_targets(source_path, call):
                        self.executed_bodies[target_path].add(closure["start"])
                    _propagate_executed_callback_bodies(
                        source_path,
                        source_facts,
                        call,
                        self.callback_targets,
                        eager_parameters,
                        self.executed_bodies,
                    )
            if previous == (len(eager_parameters), sum(map(len, self.executed_bodies.values()))):
                break

    def collect_file(self, path, facts):
        module = self.compilation_unit(path)
        if self.test_roots.intersection(Path(path).parts):
            return
        contains_request = lambda function: self.contains_request(function, path)
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
            if function.get("lexicalScope") or not self.active(path, function):
                continue
            identity = self.owner(path, scope)
            if method_signature(function) in NETWORK_FOUNDATION_API.get(identity, set()):
                continue
            harness_path = NETWORK_HARNESS_TYPES.get(self.owner(path, scope[:1]))
            harness_type = self.types.resolve(path, ".".join(scope[:1]), aliases=False)
            declared_path = self.types.paths.get(harness_type, "")
            if (
                harness_path
                and (declared_path == harness_path or declared_path.endswith("/" + harness_path))
                and path in self.regular_sources
                and self.regular_sources[path][function["start"] : function["start"] + 1]
                in {b" ", b"\n", b"\r"}
            ):
                continue
            if (
                identity not in self.network_owners
                and function not in callable_apis
                and not contains_request(function)
            ):
                continue
            target = self.types.resolve(path, ".".join(scope), aliases=False)
            if target in self.protocols:
                continue
            if (
                self.types.returns_view(path, function)
                or target
                and any(
                    base.rsplit(".", 1)[-1] in {"View", "ViewModifier", "App", "Scene"}
                    and self.types.resolve(path, base, target[1][:-1])
                    not in self.types.nominal_records
                    for base in self.types.bases(target)
                )
            ):
                continue
            parameters = function.get("parameters", [])
            if (
                target
                and "HTTPTransport" in self.types.bases(target)
                and function["name"] == "data"
                and not function.get("isStatic")
                and len(parameters) in {1, 2}
                and parameters[0]["label"] == "for"
                and (
                    len(parameters) == 1
                    or parameters[1]["label"] == "maximumBytes"
                    and re.sub(r"\s+", "", parameters[1]["type"]) in {"Int?", "Swift.Int?"}
                )
                and self.types.terminal_name(path, parameters[0]["type"], scope).rsplit(".", 1)[-1]
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
                    or method_signature(function) in self.NETWORK_CAPABILITIES.get(identity, {})
                )
                or module in self.NATIVE_PRODUCT_ROOTS
                and not function.get("isPrivate")
                and (
                    contains_request(function)
                    or method_signature(function) in self.NETWORK_CAPABILITIES.get(identity, {})
                )
                or not function.get("isPrivate")
                and method_signature(function) in self.NETWORK_CAPABILITIES.get(identity, {})
                and contains_request(function)
                or identity not in self.NETWORK_CAPABILITIES
                and not function.get("isPrivate")
                and contains_request(function)
            ):
                self.result.setdefault(identity, []).append((path, function))

    def mark_return_overloads(self):
        for functions in self.result.values():
            groups = {}
            for _, function in functions:
                groups.setdefault(method_signature(function), []).append(function)
            for group in groups.values():
                if not (len({row.get("returnType") or "Void" for row in group}) > 1):
                    continue
                for function in group:
                    function["returnOverload"] = True

    def owner(self, path, scope):
        return ".".join(self.types.function_scope(path, scope))

    def active(self, path, node):
        source = self.active_sources[path]
        return source is None or source[node["start"] : node["start"] + 1] not in {
            b" ",
            b"\n",
            b"\r",
        }

    def value_utility(self, path, call):
        expression = call.get("calledExpression", "")
        receiver, _, name = expression.rpartition(".")
        target = self.types.resolve(path, receiver, call["scope"])
        if not target:
            return False
        scope = (target[0], *target[1])
        definitions = [
            (source_path, function)
            for source_path, facts in self.index.items()
            for function in facts.get("functionRanges", [])
            if function["name"] == name
            and self.types.function_scope(source_path, function["scope"]) == scope
            and matching_functions(
                {"functionRanges": [function]}, name, dict(call, scope=function["scope"])
            )
        ]
        return bool(definitions) and all(
            not function.get("isAsync")
            and not any(
                self.types.terminal_name(source_path, kind, function["scope"]).rsplit(".", 1)[-1]
                in NETWORK_TRANSPORT_TYPES | {"URLRequest"}
                for kind in [
                    function.get("returnType") or "",
                    *[parameter["type"] for parameter in function.get("parameters", [])],
                ]
            )
            for source_path, function in definitions
        )

    def network_port(self, kind):
        return (
            "async" in kind
            and "->" in kind
            and re.search(r"\b(?:URL|URLRequest)\b", kind)
            and re.search(r"\b(?:Data|HTTPResponse|URLResponse|HTTPURLResponse)\b", kind)
        )

    def remote_data_request(self, facts, call, source_path):
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
            self.types.terminal_name(source_path, expression, call["scope"])
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
                if self.active(source_path, invocation)
                and self.can_execute(facts, invocation)
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

    def system_request(self, facts, call, source_path):
        expression = call.get("calledExpression", "")
        if platform_stream_request(self.types, source_path, call, self.binding_types):
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

    def transport_calls(self, facts):
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

    def executes(self, source_path, function, call):
        facts = self.index[source_path]
        return all(
            closure["start"] in self.executed_bodies[source_path]
            for closure in facts.get("callableRanges", []) + facts.get("inlineClosureRanges", [])
            if function["start"] <= closure["start"] <= call["start"] < closure["end"]
        )

    def callback_targets(self, source_path, call):
        receiver, _, name = call.get("calledExpression", "").rpartition(".")
        constructor = self.types.resolve(
            source_path, call.get("calledExpression", "").removesuffix(".init"), call["scope"]
        )
        if constructor:
            candidates = self.helper_functions.get(".".join([constructor[0], *constructor[1]]), [])
            return matching_api_calls(
                self.index,
                candidates,
                dict(
                    call,
                    path=source_path,
                    calledExpression="init",
                    receiverExpression=call["calledExpression"],
                ),
                types=self.types,
                conservative=True,
            )
        target = (
            self.owner(source_path, call["scope"])
            if receiver in {"", "self", "Self"}
            else self.resolve_receiver(dict(call, path=source_path))
        )
        candidates = self.helper_functions.get(target, [])
        if not receiver:
            candidates = candidates + self.helper_functions.get(self.owner(source_path, []), [])
        return matching_api_calls(
            self.index,
            candidates,
            dict(call, path=source_path),
            types=self.types,
            conservative=True,
        )

    def standard_callbacks(self, source_path, call):
        constructor = self.types.resolve(
            source_path, call.get("calledExpression", "").removesuffix(".init"), call["scope"]
        )
        return executed_callback_positions(
            call,
            project_call=constructor is not None or bool(self.callback_targets(source_path, call)),
            potential=True,
        )

    def selector_targets(self, source_path, call):
        if self.callback_targets(source_path, call):
            return
        facts = self.index[source_path]
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
            resolved = (
                self.types.resolve(source_path, receiver, call[("scope")]) if receiver else None
            )
            target = (
                ".".join([resolved[0], *resolved[1]])
                if resolved
                else self.owner(source_path, call["scope"])
            )
            labels = (
                [label.replace("_", "") for label in signature.split(":")[:-1]]
                if signature is not None
                else None
            )
            for target_path, function in self.helper_functions.get(target, []):
                if function["name"] == name and (
                    labels is None
                    or labels
                    == [parameter["label"] for parameter in function.get("parameters", [])]
                ):
                    yield target_path, function

    def stored_targets(self, source_path, call):
        receiver, _, name = call.get("calledExpression", "").rpartition(".")
        if name not in self.stored_callback_names:
            return []
        if receiver in {"", "self", "Self"}:
            facts = self.index[source_path]
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
            target = self.owner(source_path, call["scope"])
        else:
            target = self.resolve_receiver(dict(call, path=source_path))
        return [
            (path, closure)
            for path, closure, constructor in self.stored_callbacks.get((target, name), [])
            if self.active(path, constructor) and self.can_execute(self.index[path], constructor)
        ]

    def contains_request(self, function, source_path, seen=None):
        key = (
            source_path,
            function["start"],
            function["end"],
            function.get("bodyStart"),
            function.get("isExplicitInitializer"),
            tuple(function.get("scope", [])),
        )
        if key in self.request_results:
            return self.request_results[key]
        found = self.scan_requests(function, source_path, seen)
        if found or seen is None:
            self.request_results[key] = found
        return found

    def scan_requests(self, function, source_path, seen):
        if seen is None:
            seen = set()
        key = (source_path, function["start"])
        if key in seen:
            return False
        seen.add(key)
        source_facts = self.index[source_path]
        if function.get("isExplicitInitializer") and any(
            self.contains_request(node, source_path, seen)
            for node in source_facts.get("initializers", [])
            if not node.get("isExplicitInitializer") and node["scope"] == function["scope"]
        ):
            return True
        closures = source_facts.get("callableRanges", []) + source_facts.get(
            "inlineClosureRanges", []
        )
        task_bodies = self.executed_bodies[source_path]
        for call in self.transport_calls(source_facts):
            if (
                not (function.get("bodyStart") or function["start"])
                <= call["start"]
                < function["end"]
                or not self.active(source_path, call)
                or not self.can_execute(source_facts, call)
            ):
                continue
            target = self.resolve_receiver(dict(call, path=source_path))
            method = transport_method(call.get("calledExpression", ""))
            executes = all(
                closure["start"] in task_bodies
                for closure in closures
                if function["start"] <= closure["start"] <= call["start"] < closure["end"]
            )
            if not executes:
                continue
            if any(
                self.contains_request(closure, target_path, seen)
                for target_path, closure in self.stored_targets(source_path, call)
            ):
                return True
            if any(
                self.contains_request(callback, target_path, seen)
                for target_path, callback in self.selector_targets(source_path, call)
            ):
                return True
            callback_ranges = callback_body_ranges(
                source_facts, call, self.standard_callbacks(source_path, call)
            )
            if any(
                self.contains_request(closure, source_path, seen)
                for closure in closures
                if (closure["start"], closure["end"]) in callback_ranges
            ):
                return True
            if self.remote_data_request(source_facts, call, source_path):
                return True
            if executes and self.system_request(source_facts, call, source_path):
                return True
            expression = call.get("calledExpression", "")
            constructor = self.types.resolve(
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
                self.index,
                self.helper_functions.get(target, []),
                dict(invocation, path=source_path),
                types=self.types,
                conservative=True,
            )
            if (
                (
                    target
                    and target.rsplit(".", 1)[-1] in NETWORK_TRANSPORT_TYPES
                    or expression.removesuffix(".init").rsplit(".", 1)[-1]
                    in NETWORK_TRANSPORT_TYPES
                )
                and not self.value_utility(source_path, call)
                and (not definitions or any(function.get("isAsync") for _, function in definitions))
                and expression.removesuffix(".init") not in NETWORK_PLATFORM_TRANSPORT_TYPES
            ):
                return True
            if target in self.network_owners and (
                method in NETWORK_TRANSPORT_METHODS
                or method in self.registered_methods.get(target, set())
            ):
                return True
            expression = call.get("calledExpression", "").removeprefix("self.")
            if any(
                self.network_port(
                    self.types.terminal_name(
                        source_path, variable.get("type", ""), variable["scope"]
                    )
                )
                for variable in visible_variables(source_facts, call, expression)
            ):
                return True
            if method in NETWORK_TRANSPORT_METHODS and any(
                kind.rsplit(".", 1)[-1] in NETWORK_TRANSPORT_TYPES
                or kind in NETWORK_PLATFORM_TRANSPORT_TYPES
                for kind in self.binding_types.receiver_components(call, source_path)
            ):
                return True
            receiver, _, method = call.get("calledExpression", "").rpartition(".")
            receiver_name = re.split(r"[.\[]", receiver.removeprefix("self."), maxsplit=1)[0]
            for variable in visible_variables(
                source_facts, call, receiver_name, receiver.startswith("self.")
            ):
                if method in NETWORK_TRANSPORT_METHODS and any(
                    self.types.terminal_name(component_path, name, scope).rsplit(".", 1)[-1]
                    in NETWORK_TRANSPORT_TYPES
                    for component_path, name, scope in self.components(
                        source_path, variable.get("type", ""), variable["scope"], call
                    )
                ):
                    return True
            if not executes:
                continue
            if constructor:
                matches = definitions
                if any(
                    self.contains_request(helper, candidate_path, seen)
                    for candidate_path, helper in matches
                ):
                    return True
                continue
            if not receiver or receiver in {"self", "Self"}:
                if not receiver and visible_variables(source_facts, call, method):
                    continue
                target = self.owner(source_path, call["scope"])
            available = self.helper_functions.get(target, []) + self.protocol_helpers.get(
                target, []
            )
            if not receiver:
                available = available + self.helper_functions.get(self.owner(source_path, []), [])
            candidates = [
                (candidate_path, helper)
                for candidate_path, helper in available
                if (not helper.get("isPrivate") or candidate_path == source_path)
                and call.get("lexicalScope", [])[: len(helper.get("lexicalScope", []))]
                == helper.get("lexicalScope", [])
            ]
            groups = {None: candidates}
            if target in self.protocol_helpers:
                groups = {}
                for candidate_path, helper in candidates:
                    groups.setdefault(self.owner(candidate_path, helper["scope"]), []).append(
                        (candidate_path, helper)
                    )
            matches = [
                match
                for group in groups.values()
                for match in matching_api_calls(
                    self.index,
                    group,
                    dict(call, path=source_path),
                    types=self.types,
                    conservative=True,
                )
            ]
            if any(
                self.contains_request(helper, candidate_path, seen)
                for candidate_path, helper in matches
            ):
                return True
        return False
