"""Resolve nominal Swift types within their module, imports and file access scope."""

import re
from pathlib import Path
from functools import cache
from swift_scope_facts import (
    _canonical_type_scope as _canonical_type_scope,
    canonical_type_scope as canonical_type_scope,
    compilation_unit as compilation_unit,
    package_target_paths as package_target_paths,
    visible_variables as visible_variables,
)
from swift_constant_values import (
    _custom_constant_symbols as _custom_constant_symbols,
    block_outcomes as block_outcomes,
    branch_condition as branch_condition,
    branch_value as branch_value,
    call_can_execute as call_can_execute,
    collection_count as collection_count,
    constant_boolean as constant_boolean,
    constant_folding_allowed as constant_folding_allowed,
    constant_value as constant_value,
    control_flow_outcomes as control_flow_outcomes,
    custom_constant_symbols as custom_constant_symbols,
    is_empty_iteration as is_empty_iteration,
    pattern_match_value as pattern_match_value,
    string_literal_value as string_literal_value,
    switch_entries as switch_entries,
)


def matches_variadic_labels(parameter: dict, labels: list[str]) -> bool:
    for index, label in enumerate(labels):
        expected = parameter["label"] if index == 0 else ""
        if label != expected:
            return False
    return True


def argument_parameter_bindings(parameters: list[dict], labels: list[str]) -> list[list[dict]]:
    """Align supplied arguments with parameters, including defaults and variadic arguments."""
    if not parameters:
        return [[]] if not labels else []
    parameter, remaining = parameters[0], parameters[1:]
    bindings = argument_parameter_bindings(remaining, labels) if parameter["hasDefault"] else []
    if parameter["variadic"]:
        for count in range(len(labels) + 1):
            if matches_variadic_labels(parameter, labels[:count]):
                bindings.extend(
                    [parameter] * count + tail
                    for tail in argument_parameter_bindings(remaining, labels[count:])
                )
    elif labels and labels[0] == parameter["label"]:
        bindings.extend(
            [parameter] + tail for tail in argument_parameter_bindings(remaining, labels[1:])
        )
    return bindings


class SwiftTypeIndex:
    def __init__(self, index: dict):
        self.index = index
        self.units = {path: compilation_unit(path) for path in index}
        self.module_names = set(self.units.values())
        self.imports = {path: set(facts.get("imports", [])) for path, facts in index.items()}
        self.records = {}
        self.paths = {}
        self.inheritance_paths = {}
        self.exported = set()
        self.aliases = {}
        for path, facts in index.items():
            private = {
                canonical_type_scope(node["scope"] + [node["name"]])
                for node in facts.get("declarations", [])
                if node.get("isFilePrivate") and node["kind"] != "extension"
            }
            for node in facts.get("declarations", []) + facts.get("typeAliases", []):
                if node.get("kind") == "extension":
                    continue
                owner = canonical_type_scope(node.get("scope", []) + [node["name"]])
                hidden = node.get("isFilePrivate") or any(
                    owner[: len(parent)] == parent for parent in private
                )
                namespace = self.units[path] + ("@" + path if hidden else "")
                key = (namespace, owner)
                bases = [node["type"]] if "type" in node else node.get("inheritedTypes", [])
                self.records.setdefault(key, set()).update(
                    re.sub(r"\s+", "", base) for base in bases
                )
                for base in bases:
                    self.inheritance_paths[key, re.sub(r"\s+", "", base)] = path
                self.paths.setdefault(key, path)
                if node.get("isExported") and not hidden:
                    self.exported.add(key)
                if "type" in node:
                    self.aliases[key] = node["type"]
        self.exported_by_owner = {}
        for key in self.exported:
            self.exported_by_owner.setdefault(key[1], []).append(key)
        self.nominal_records = frozenset(self.records)
        self._resolutions = None
        for path, facts in index.items():
            for node in facts.get("declarations", []):
                if node.get("kind") != "extension":
                    continue
                key = self.resolve(path, node["name"], node["scope"], aliases=False) or (
                    self.units[path],
                    canonical_type_scope(node["scope"] + [node["name"]]),
                )
                self.records.setdefault(key, set()).update(
                    re.sub(r"\s+", "", base) for base in node["inheritedTypes"]
                )
                for base in node["inheritedTypes"]:
                    self.inheritance_paths[key, re.sub(r"\s+", "", base)] = path
                self.paths.setdefault(key, path)
        self._bases = {}
        self._resolutions = {}
        self._function_scopes = {}
        self.enum_cases = {}
        for path, facts in index.items():
            for case in facts.get("enumCases", []):
                owner = self.terminal_name(path, ".".join(case["scope"]))
                self.enum_cases.setdefault(owner, set()).add(case["name"])

    def resolve(self, path: str, name: str, scope=(), *, aliases=True):
        key = (path, name, tuple(scope), aliases)
        if self._resolutions is None:
            return self._resolve(*key)
        if key not in self._resolutions:
            self._resolutions[key] = self._resolve(*key)
        return self._resolutions[key]

    def _resolve(self, path, name, scope, aliases):
        name = re.sub(r"\s+|\bany\b", "", name).rstrip("?!")
        parts = canonical_type_scope([name])
        if not parts:
            return None
        if parts[0] == "Self":
            parts = (
                canonical_type_scope([part for part in scope if isinstance(part, str)]) + parts[1:]
            )
        if not parts:
            return None
        module = self.units[path]
        if parts[0] in self.module_names:
            candidates = [(parts[0], parts[1:])]
        else:
            candidates = [
                (namespace, tuple(scope[:depth]) + parts)
                for depth in range(len(scope), -1, -1)
                for namespace in (module + "@" + path, module)
            ]
        key = next(
            (
                key
                for key in candidates
                if key in self.records
                and (key[0].split("@", 1)[0] == module or key in self.exported)
            ),
            None,
        )
        if key is None:
            candidates = [
                key for key in self.exported_by_owner.get(parts, []) if key[0] in self.imports[path]
            ]
            if len(candidates) == 1:
                key = candidates[0]
        if key is not None and aliases:
            seen = set()
            while key in self.aliases and key not in seen:
                seen.add(key)
                target = self.resolve(
                    self.paths[key], self.aliases[key], key[1][:-1], aliases=False
                )
                if target is None:
                    break
                key = target
        return key

    def bases(self, key, visiting=frozenset()):
        if key in self._bases:
            return self._bases[key]
        if key in visiting:
            return set()
        result = set(self.records[key])
        for base in self.records[key]:
            parent = self.resolve(self.inheritance_paths[key, base], base, key[1][:-1])
            if parent is not None:
                result.update(self.bases(parent, visiting | {key}))
        self._bases[key] = result
        return result

    def returns_view(self, path: str, function: dict) -> bool:
        returned = re.sub(r"^(?:some|any)\s+", "", function.get("returnType") or "")
        if not returned:
            return False
        scope = function.get("scope", [])
        if any(part.strip() in {"View", "SwiftUI.View"} for part in returned.split("&")):
            return True
        terminal = self.terminal_name(path, returned, scope).split("<", 1)[0]
        if terminal in {
            "View",
            "SwiftUI.View",
            "AnyView",
            "SwiftUI.AnyView",
            "EmptyView",
            "SwiftUI.EmptyView",
            "TupleView",
            "SwiftUI.TupleView",
            "Text",
            "SwiftUI.Text",
            "Image",
            "SwiftUI.Image",
            "Color",
            "SwiftUI.Color",
        }:
            return True
        target = self.resolve(path, returned, scope)
        return target is not None and any(
            base.rsplit(".", 1)[-1] == "View" for base in self.bases(target)
        )

    def conformances(self, path: str):
        module = self.units[path]
        result = {}
        for key in self.records:
            namespace, owner = key
            if (
                namespace in {module, module + "@" + path}
                and self.resolve(path, ".".join(owner), aliases=False) == key
            ):
                result[owner] = self.bases(key)
        imported = set(self.index[path].get("imports", []))
        candidates = {}
        for key in self.exported:
            if key[0] not in imported:
                continue
            result[(key[0],) + key[1]] = self.bases(key)
            candidates.setdefault(key[1], []).append(key)
        for owner, keys in candidates.items():
            if owner not in result and len(keys) == 1:
                result[owner] = self.bases(keys[0])
        return result

    def inheritance_distance(self, actual: str, expected: str):
        identities = {
            ".".join([namespace, *owner]): (namespace, owner) for namespace, owner in self.records
        }
        source, target = identities.get(actual), identities.get(expected)
        if source is None or target is None:
            return None
        pending, seen = [(source, 0)], set()
        for key, distance in pending:
            if key == target:
                return distance
            if key in seen:
                continue
            seen.add(key)
            for base in self.records[key]:
                path = self.inheritance_paths[key, base]
                parent = self.resolve(path, base, key[1][:-1])
                if parent is not None:
                    pending.append((parent, distance + 1))
        return None

    def all_conformances(self):
        return {
            (namespace,) + owner: self.bases((namespace, owner))
            for namespace, owner in self.records
        }

    def function_scope(self, path: str, scope):
        identity = (path, tuple(scope))
        if identity not in self._function_scopes:
            self._function_scopes[identity] = self._function_scope(path, scope)
        return self._function_scopes[identity]

    def _function_scope(self, path: str, scope):
        key = self.resolve(path, ".".join(scope), aliases=False) if scope else None
        return (key[0],) + key[1] if key else (self.units[path],) + canonical_type_scope(scope)

    def terminal_name(self, path: str, name: str, scope=(), seen=frozenset()) -> str:
        name = re.sub(r"\bany\b|\s+", "", name).rstrip("?!")
        key = self.resolve(path, name, scope, aliases=False)
        if key in self.aliases and key not in seen:
            return self.terminal_name(self.paths[key], self.aliases[key], key[1][:-1], seen | {key})
        return ".".join([key[0], *key[1]]) if key else name

    def _expand_generic_constraints(self, source_path, name, constraints, seen, pending):
        size = min(item["end"] - item["start"] for item in constraints)
        for item in constraints:
            key = (source_path, name, item["start"], item["type"])
            if item["end"] - item["start"] == size and item["type"] and key not in seen:
                seen.add(key)
                pending.append((source_path, item["type"], item["scope"]))

    def components(self, path, kind, scope, reference):
        pending, seen, result = [(path, kind, scope)], set(), []
        while pending:
            source_path, value, source_scope = pending.pop()
            for name in re.findall(r"\b[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*", value):
                constraints = [
                    item
                    for item in self.index[source_path].get("genericConstraints", [])
                    if item["name"] == name and item["start"] <= reference["start"] < item["end"]
                ]
                if constraints:
                    self._expand_generic_constraints(source_path, name, constraints, seen, pending)
                    continue
                target = self.resolve(source_path, name, source_scope, aliases=False)
                if target in self.aliases and target not in seen:
                    seen.add(target)
                    pending.append((self.paths[target], self.aliases[target], target[1][:-1]))
                elif target not in self.aliases:
                    result.append((source_path, name, source_scope))
        return result


class SwiftBindingTypes:
    """Share declaration, variable and factory types used by semantic call audits."""

    def __init__(self, index: dict, types: SwiftTypeIndex | None = None):
        self.index = index
        self.types = types or SwiftTypeIndex(index)
        self.type_ids = {
            namespace + "." + ".".join(owner): (namespace, owner)
            for namespace, owner in self.types.records
        }
        self.accessors = {
            (self.types.function_scope(path, node["scope"]), node["name"])
            for path, facts in index.items()
            for node in facts.get("accessorRanges", [])
        }
        self.return_types = {}
        for path, facts in index.items():
            for function in facts.get("functionRanges", []):
                if function.get("returnType"):
                    key = (self.types.function_scope(path, function["scope"]), function["name"])
                    self.return_types.setdefault(key, []).append((function, path))
        self.reference_paths = {
            id(node): path
            for path, facts in index.items()
            for node in facts.get("calls", [])
            + facts.get("members", [])
            + facts.get("scopedIdentifiers", [])
        }
        self.aliases = [
            (path, alias, self.variable_scope(path, alias))
            for path, facts in index.items()
            for alias in facts.get("typeAliases", [])
        ]
        self.variable_types = {}
        for path, facts in index.items():
            for variable in facts.get("typedVariables", []):
                self.variable_types[(self.variable_scope(path, variable), variable["name"])] = (
                    variable["type"]
                )
            for binding in facts.get("bindings", []):
                scope = self.variable_scope(path, binding)
                initializer = re.match(
                    r"(\w+)\s*=\s*(?:try\??\s+)?(?:await\s+)?([A-Z]\w*)[.(]", binding["value"]
                )
                if initializer:
                    self.variable_types[(scope, initializer[1])] = initializer[2]
                returned = re.match(
                    r"(\w+)\s*=\s*(?:try\??\s+)?(?:await\s+)?(\w+)\.(\w+)\(", binding["value"]
                )
                if returned and (
                    returned_type := self.method_return(
                        path,
                        (returned[2],),
                        returned[3],
                        self.factory_invocation(path, binding, returned[2] + "." + returned[3]),
                    )
                ):
                    self.variable_types[(scope, returned[1])] = returned_type
                decoded = re.match(r"(\w+)\s*=.*?\.decode\(\s*(\w+)\.self", binding["value"])
                if decoded:
                    self.variable_types[(scope, decoded[1])] = decoded[2]
        for path, facts in index.items():
            for binding in facts.get("bindings", []):
                key = (self.variable_scope(path, binding), binding.get("bindingName"))
                reference = binding.get("initializerReference")
                if not (reference and key[1] and (key not in self.variable_types)):
                    continue
                kind = self.receiver_type(dict(binding, calledExpression=reference + ".type"), path)
                if kind:
                    self.variable_types[key] = kind

    def variable_scope(self, path, node):
        owner = (
            (node["ownerNamespace"],) + tuple(node["scope"])
            if node.get("ownerNamespace")
            else self.types.function_scope(path, node["scope"])
        )
        return owner + tuple(f"@{path}:{start}" for start in node.get("lexicalScope", []))

    def replacing_source(self, path, facts):
        return SwiftBindingTypes({**self.index, path: facts}, self.types)

    def canonical_type(self, value, scope, path):
        if value in self.type_ids:
            return value
        owner_scope = tuple(part for part in scope[1:] if not part.startswith("@"))
        key = self.types.resolve(path, value, owner_scope)
        return key[0] + "." + ".".join(key[1]) if key else value.rsplit(".", 1)[-1].rstrip("?!")

    def factory_invocation(self, path, reference, expression):
        end = reference["start"] + len(reference.get("value", "").encode())
        return next(
            (
                call
                for call in self.index[path].get("invocations", [])
                if call["calledExpression"] == expression
                and reference["start"] <= call["start"] < end
            ),
            None,
        )

    def _matches_parameter_types(self, function, source, scope, path, invocation, argument_types):
        var_scope = self.variable_scope(path, invocation)
        for parameters in argument_parameter_bindings(
            function["parameters"], invocation.get("argumentLabels", [])
        ):
            all_match = True
            for actual, parameter in zip(argument_types, parameters):
                if actual is None:
                    continue
                param_type = self.canonical_type(parameter["type"].rstrip("?!"), scope, source)
                arg_type = self.canonical_type(actual, var_scope, path)
                if param_type != arg_type:
                    all_match = False
                    break
            if all_match:
                return True
        return False

    def method_return(self, path, owner, name, invocation=None):
        key = self.types.resolve(path, ".".join(owner)) if owner else None
        scope = (key[0],) + key[1] if key else self.types.function_scope(path, owner)
        candidates = self.return_types.get((scope, name), [])
        if invocation:
            candidates = [
                (function, source)
                for function, source in candidates
                if argument_parameter_bindings(
                    function["parameters"], invocation.get("argumentLabels", [])
                )
            ]
            if len(candidates) > 1:

                def argument_type(argument):
                    if re.fullmatch(r'".*"', argument, re.DOTALL):
                        return "String"
                    if re.fullmatch(r"[+-]?\d[\d_]*", argument):
                        return "Int"
                    if argument in {"true", "false"}:
                        return "Bool"
                    variable_scope = self.variable_scope(path, invocation)
                    return next(
                        (
                            self.variable_types[(owner, argument)]
                            for length in range(len(variable_scope), 0, -1)
                            if (owner := variable_scope[:length], argument) in self.variable_types
                        ),
                        None,
                    )

                argument_types = [
                    argument_type(argument) for argument in invocation.get("arguments", [])
                ]
                candidates = [
                    (function, source)
                    for function, source in candidates
                    if self._matches_parameter_types(
                        function, source, scope, path, invocation, argument_types
                    )
                ]
        results = {
            self.canonical_type(function["returnType"], scope, source)
            for function, source in candidates
        }
        if (
            not results
            and key is None
            and invocation
            and self.receiver_type(invocation, path) == "URLSession"
        ):
            return {
                "dataTask": "URLSessionDataTask",
                "uploadTask": "URLSessionUploadTask",
                "downloadTask": "URLSessionDownloadTask",
                "streamTask": "URLSessionStreamTask",
                "webSocketTask": "URLSessionWebSocketTask",
                "dataTaskPublisher": "URLSessionDataTaskPublisher",
            }.get(name)
        return next(iter(results)) if len(results) == 1 else None

    def receiver_type(self, call, path=None):
        path = path or self.reference_paths.get(id(call), "")
        scope = self.variable_scope(path, call)
        if constructor := call.get("receiverCall"):
            constructor = constructor.removesuffix(".init")
            if constructor.rsplit(".", 1)[-1][:1].isupper():
                return self.canonical_type(constructor, scope, path)
            owner, _, method = constructor.rpartition(".")
            owners = (
                [tuple(owner.split("."))]
                if owner
                else [tuple(call["scope"][:length]) for length in range(len(call["scope"]), -1, -1)]
            )
            invocation = self.factory_invocation(path, call, call["receiverCall"])
            return next(
                (
                    returned
                    for owner in owners
                    if (
                        returned := self.method_return(
                            path, owner, method or constructor, invocation
                        )
                    )
                ),
                None,
            )
        parts = call.get("calledExpression", call.get("value", "")).replace("?", "").split(".")[:-1]
        if parts and parts[0] == "self":
            parts.pop(0)
            scope = self.types.function_scope(path, call["scope"])
            if not parts:
                for length in range(len(call["scope"]), 0, -1):
                    owner = self.types.resolve(
                        path, ".".join(call["scope"][:length]), aliases=False
                    )
                    if owner:
                        return ".".join((owner[0],) + owner[1])
        resolved = None
        for length in range(len(parts), 0, -1):
            if self.types.resolve(path, ".".join(parts[:length])) is not None:
                resolved = self.canonical_type(".".join(parts[:length]), scope, path)
                parts = parts[length:]
                break
        for part in parts:
            if part == "shared" and resolved:
                continue
            if resolved is None and part[:1].isupper():
                resolved = self.canonical_type(part, scope, path)
                continue
            identity = self.type_ids.get(resolved)
            owned_type = (identity[0],) + identity[1] if identity else None
            lookup_scopes = (
                [scope[:length] for length in range(len(scope), 0, -1)]
                if resolved is None
                else [
                    owner
                    for owner, field in self.variable_types
                    if owner == owned_type and field == part
                ]
            )
            if resolved is None:
                facts = self.index[path]
                bindings = [
                    dict(node, name=node["bindingName"])
                    for node in facts.get("bindings", [])
                    if node.get("bindingName")
                ]
                visible = visible_variables(
                    dict(facts, typedVariables=facts.get("typedVariables", []) + bindings),
                    call,
                    part,
                    call.get("calledExpression", "").startswith("self."),
                )
                if visible:
                    lookup_scopes = [self.variable_scope(path, visible[-1])]
            resolved = next(
                (
                    self.variable_types[(owner, part)]
                    for owner in lookup_scopes
                    if (owner, part) in self.variable_types
                ),
                None,
            )
            if resolved is None:
                return None
            resolved = self.canonical_type(resolved, scope, path)
        return resolved

    def receiver_components(self, call, path=None):
        path = path or self.reference_paths.get(id(call), "")
        kind = self.receiver_type(call, path)
        if kind in self.type_ids:
            return {kind}
        return {
            self.types.terminal_name(source, name, scope)
            for source, name, scope in self.types.components(path, kind or "", call["scope"], call)
        }

    def is_accessor_reference(self, call, path=None):
        path = path or self.reference_paths.get(id(call), "")
        identity = self.type_ids.get(self.receiver_type(call, path))
        if identity is None:
            return False
        name = call.get("calledExpression", call.get("value", "")).rsplit(".", 1)[-1]
        owners = {identity} | {
            self.types.resolve(self.types.paths[identity], base, identity[1])
            for base in self.types.bases(identity)
        }
        return any(((owner[0],) + owner[1], name) in self.accessors for owner in owners if owner)


def receiver_resolver(index: dict, *, follow_parameters: bool = False):
    types = SwiftTypeIndex(index)
    binding_types = SwiftBindingTypes(index, types)
    variables, factories, invocations_by_name = {}, {}, {}
    protocols = {
        types.resolve(path, ".".join(node["scope"] + [node["name"]]), aliases=False)
        for path, facts in index.items()
        for node in facts.get("declarations", [])
        if node["kind"] == "protocol"
    }
    for path, facts in index.items():
        bindings = [
            dict(binding, name=binding["bindingName"], type=binding.get("bindingType", ""))
            for binding in facts.get("bindings", [])
            if binding.get("bindingName")
        ]
        variables[path] = dict(
            facts,
            typedVariables=facts.get("typedVariables", []) + bindings,
            functionRanges=facts.get("functionRanges", []),
        )
        for call in facts.get("invocations", []):
            name = call["calledExpression"].rsplit(".", 1)[-1]
            invocations_by_name.setdefault(name, []).append(dict(call, path=path))
        for function in facts.get("functionRanges", []) + facts.get("callableRanges", []):
            owner = types.resolve(path, ".".join(function["scope"]), aliases=False)
            if owner:
                factories.setdefault((owner, function["name"]), []).append((path, function))

    @cache
    def candidates_for(path, scope, lexical, start, name, explicit_self):
        reference = {"scope": list(scope), "lexicalScope": list(lexical), "start": start}
        return visible_variables(variables[path], reference, name, explicit_self)

    def parameter_arguments(function, variable, call):
        values = call.get("arguments", [])
        return [
            values[position]
            for binding in argument_parameter_bindings(
                function["parameters"], call.get("argumentLabels", [])
            )
            for position, parameter in enumerate(binding)
            if parameter["name"] == variable["name"] and position < len(values)
        ]

    def invocation_owner(call, seen):
        expression = call["calledExpression"]
        receiver = expression.rpartition(".")[0]
        if receiver in {"", "self", "Self"}:
            return types.resolve(call["path"], ".".join(call["scope"]), aliases=False)
        target = resolve(call["path"], receiver, call, seen)
        if target is not None:
            return target
        choices = {
            identity
            for declared in binding_types.receiver_components(call, call["path"])
            if (identity := types.resolve(call["path"], declared, call["scope"]))
        }
        return next(iter(choices)) if len(choices) == 1 else None

    def forwarded_receiver(path, variable, seen):
        functions = [
            function
            for function in index[path].get("functionRanges", [])
            if function["start"] <= variable["start"] < function.get("bodyStart", 0)
            and function["scope"] == variable["scope"]
            and any(p["name"] == variable["name"] for p in function.get("parameters", []))
        ]
        targets = set()
        for function in functions:
            expected = types.resolve(path, ".".join(function["scope"]), aliases=False)
            for call in invocations_by_name.get(function["name"], []):
                if invocation_owner(call, seen) != expected:
                    continue
                arguments = parameter_arguments(function, variable, call)
                targets.update(
                    target
                    for value in arguments
                    if (target := resolve(call["path"], value, call, seen)) is not None
                )
        return next(iter(targets)) if len(targets) == 1 else None

    def resolve(path, expression, reference, seen=frozenset()):
        key = (path, expression, reference["start"])
        if key in seen:
            return None
        seen = seen | {key}
        nominal = types.resolve(path, expression, reference["scope"])
        if nominal:
            return nominal
        explicit_self = expression.startswith("self.")
        name = expression.removeprefix("self.")
        candidates = candidates_for(
            path,
            tuple(reference["scope"]),
            tuple(reference.get("lexicalScope", [])),
            reference["start"],
            name,
            explicit_self,
        )
        if candidates:
            variable = candidates[-1]
            if initializer := variable.get("initializerCall") or variable.get(
                "initializerReference"
            ):
                position = (
                    dict(variable, start=variable["start"] - 1)
                    if initializer == variable["name"] and variable.get("lexicalScope")
                    else variable
                )
                target = resolve(path, initializer, position, seen)
                if target:
                    return target
            variable_owner = types.resolve(path, ".".join(variable["scope"]), aliases=False)
            assigned = {
                target
                for factory_path, factory in factories.get((variable_owner, variable["name"]), [])
                if factory.get("referenceTarget")
                and (
                    factory.get("isPropertyAssignment")
                    and not variable.get("lexicalScope")
                    or not factory.get("isAssignment")
                    and factory.get("lexicalScope", []) == variable.get("lexicalScope", [])
                    or factory.get("isUnqualifiedAssignment")
                    and (
                        visible := candidates_for(
                            factory_path,
                            tuple(factory["scope"]),
                            tuple(factory.get("lexicalScope", [])),
                            factory["start"],
                            variable["name"],
                            False,
                        )
                    )
                    and visible[-1]["start"] == variable["start"]
                )
                and (target := resolve(factory_path, factory["referenceTarget"], factory, seen))
            }
            if len(assigned) == 1:
                return next(iter(assigned))
            declared = types.resolve(path, variable.get("type", ""), variable["scope"])
            if not follow_parameters or declared not in protocols:
                return declared
            return forwarded_receiver(path, variable, seen) or declared
        receiver, _, method = expression.rpartition(".")
        owner = (
            types.resolve(path, ".".join(reference["scope"]), aliases=False)
            if receiver in {"self", "Self", ""}
            else resolve(path, receiver, reference, seen)
        )
        targets = set()
        for factory_path, factory in factories.get((owner, method), []):
            target = resolve(
                factory_path,
                factory.get("returnedCall") or factory.get("referenceTarget") or "",
                factory,
                seen,
            )
            if not target:
                target = types.resolve(
                    factory_path, factory.get("returnType") or "", factory["scope"]
                )
            if target:
                targets.add(target)
        return next(iter(targets)) if len(targets) == 1 else None

    def owner(call):
        expression = call.get("calledExpression", "")
        receiver = call.get("receiverCall") or (
            expression.rsplit(".", 1)[0] if "." in expression else ""
        )
        target = resolve(call["path"], receiver, call)
        if target is None:
            targets = {
                identity
                for declared in binding_types.receiver_components(call, call["path"])
                if (identity := types.resolve(call["path"], declared, call["scope"]))
            }
            target = next(iter(targets)) if len(targets) == 1 else None
        return ".".join([target[0], *target[1]]) if target else None

    return owner


def callable_effect_index(index: dict[str, dict]) -> dict[str, dict]:
    """函数值与闭包共享已有调用图事实；引用的效果由实际调用传播。"""
    output = {}
    for path, facts in collection_callable_index(index).items():
        aliases = facts.get("callableRanges", [])
        invocations = list(facts.get("invocations", []))
        for alias in aliases:
            target = alias.get("referenceTarget")
            if not target:
                continue
            labels = re.search(r"\(([^()]*)\)$", target)
            labels = labels[1].split(":")[:-1] if labels else []
            invocations.append(
                dict(
                    alias,
                    calledExpression=re.sub(r"\([^()]*\)$", "", target),
                    argumentLabels=labels,
                    arguments=["_"] * len(labels),
                )
            )
        output[path] = dict(
            facts,
            callableRanges=aliases,
            invocations=invocations,
            functionRanges=facts.get("functionRanges", []) + aliases,
        )
    return implicit_callable_index(output)


def collection_callable_index(index: dict) -> dict:
    return {
        path: dict(
            facts,
            callableRanges=facts.get("callableRanges", []) + collection_callable_ranges(facts),
        )
        for path, facts in index.items()
    }


def collection_callable_ranges(facts: dict) -> list[dict]:
    """Connect literal closure collections to the visible for-in element binding."""
    variables = dict(
        facts,
        typedVariables=[
            dict(row, name=row["bindingName"])
            for row in facts.get("bindings", [])
            if row.get("bindingName")
        ],
    )

    def elements(value, reference, bounds, seen=frozenset()):
        if re.fullmatch(r"(?:self\.)?\w+", value):
            visible = visible_variables(
                variables, reference, value.removeprefix("self."), value.startswith("self.")
            )
            if not visible or visible[-1]["start"] in seen:
                return []
            binding = visible[-1]
            return elements(
                binding.get("initializerReference") or binding.get("constantInitializer") or "",
                binding,
                (binding["start"], binding["start"] + len(binding["value"].encode())),
                seen | {binding["start"]},
            )
        if not value.startswith("[") or not value.endswith("]"):
            return []
        closures = [
            row
            for row in facts.get("inlineClosureRanges", [])
            if bounds[0] <= row["start"] < bounds[1]
        ]
        return [
            row
            for row in closures
            if not any(parent["start"] < row["start"] < parent["end"] for parent in closures)
        ]

    result = []
    existing = {
        (row.get("collectionBindingStart"), row["start"]) for row in facts.get("callableRanges", [])
    }
    for binding in facts.get("bindings", []):
        if not binding.get("bindingName") or not binding.get("iterationSourceRange"):
            continue
        reference = dict(binding, lexicalScope=binding["lexicalScope"][:-1])
        for closure in elements(
            binding["iterationSource"], reference, binding["iterationSourceRange"]
        ):
            if (binding["start"], closure["start"]) in existing:
                continue
            result.append(
                dict(
                    closure,
                    name=binding["bindingName"],
                    scope=binding["scope"],
                    lexicalScope=binding["lexicalScope"],
                    collectionBindingStart=binding["start"],
                )
            )
    return result


def visible_callable_ranges(facts: dict, name: str, call: dict) -> list[dict]:
    variables = dict(
        facts,
        typedVariables=[
            dict(row, name=row["bindingName"])
            for row in facts.get("bindings", [])
            if row.get("bindingName")
        ],
    )
    visible = visible_variables(variables, call, name)
    return [
        alias
        for alias in facts.get("callableRanges", [])
        if alias["name"] == name
        and call["scope"][: len(alias["scope"])] == alias["scope"]
        and call.get("lexicalScope", [])[: len(alias["lexicalScope"])] == alias["lexicalScope"]
        and (not alias["lexicalScope"] or alias["start"] <= call["start"])
        and (
            not alias.get("collectionBindingStart")
            or visible
            and visible[-1]["start"] == alias["collectionBindingStart"]
        )
    ]


def implicit_callable_index(index: dict[str, dict]) -> dict[str, dict]:
    """把函数式对象的调用连接到其 callAsFunction 方法。"""
    types = SwiftTypeIndex(index)
    owners = {
        ".".join(types.function_scope(path, function["scope"]))
        for path, facts in index.items()
        for function in facts.get("functionRanges", [])
        if function["name"] == "callAsFunction" and not function.get("lexicalScope")
    }
    if not owners:
        return index
    resolve, result = receiver_resolver(index), {}
    for path, facts in index.items():
        calls = []
        for call in facts.get("invocations", []):
            expression = call["calledExpression"]
            named = (
                any(
                    function["name"] == expression
                    and call["scope"][: len(function["scope"])] == function["scope"]
                    and call.get("lexicalScope", [])[: len(function.get("lexicalScope", []))]
                    == function.get("lexicalScope", [])
                    and argument_parameter_bindings(
                        function.get("parameters", []), call.get("argumentLabels", [])
                    )
                    for function in facts.get("functionRanges", [])
                )
                if "." not in expression
                else False
            )
            candidate = dict(call, path=path, calledExpression=expression + ".callAsFunction")
            if (
                not named
                and not expression.endswith((".callAsFunction", ".init"))
                and types.resolve(path, expression, call["scope"]) is None
                and resolve(candidate) in owners
            ):
                call = dict(call, calledExpression=candidate["calledExpression"])
            calls.append(call)
        result[path] = dict(facts, invocations=calls)
    return result


def execution_index(index: dict) -> dict:
    """Keep custom scalar and operator paths reachable across module imports."""
    index = collection_callable_index(index)
    units = {path: compilation_unit(path) for path in index}
    imports = {}
    for path, facts in index.items():
        imports.setdefault(units[path], set()).update(facts.get("imports", []))
    custom = {units[path] for path, facts in index.items() if custom_constant_symbols(facts)}
    while imported := {
        unit
        for unit, dependencies in imports.items()
        if unit not in custom and dependencies & custom
    }:
        custom.update(imported)
    return implicit_callable_index(
        {
            path: dict(facts, constantFoldingAllowed=units[path] not in custom)
            for path, facts in index.items()
        }
    )
