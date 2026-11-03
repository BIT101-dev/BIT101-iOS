"""Analyze network callback rules."""

import re
from swift_source_index import visible_variables
from swift_type_index import (
    execution_index as scalar_execution_index,
    call_can_execute,
    visible_callable_ranges,
)
from network_api_facts import (
    api_argument_bindings,
    matching_api_calls,
)


def executed_callback_positions(
    call: dict, *, project_call: bool = False, potential: bool = False
) -> set[int]:
    "Resolve system execution callbacks, including cancellation paths for production capabilities."
    if project_call:
        return set()
    from swift_type_index import canonical_type_scope

    expression = ".".join(
        canonical_type_scope([call.get("calledExpression", "").removeprefix("self.")])
    ).removeprefix("_Concurrency.")
    if expression == "withTaskCancellationHandler":
        return {0, 1} if potential else {0}
    if (
        expression == "withExtendedLifetime"
        or expression.endswith(".withValue")
        and ".$" in expression
    ):
        return {1}
    if (
        expression
        in {"AsyncStream", "AsyncStream.init", "AsyncThrowingStream", "AsyncThrowingStream.init"}
        and "unfolding" in call.get("argumentLabels", [])
        and not potential
    ):
        return set()
    functions = {
        "Task",
        "Task.init",
        "Task.detached",
        "withTaskGroup",
        "withThrowingTaskGroup",
        "withDiscardingTaskGroup",
        "withThrowingDiscardingTaskGroup",
        "withCheckedContinuation",
        "withCheckedThrowingContinuation",
        "withUnsafeContinuation",
        "withUnsafeThrowingContinuation",
        "autoreleasepool",
        "withUnsafePointer",
        "withUnsafeMutablePointer",
        "withUnsafeTemporaryAllocation",
        "AsyncStream",
        "AsyncStream.init",
        "AsyncThrowingStream",
        "AsyncThrowingStream.init",
    }
    methods = {
        "addTask",
        "addTaskUnlessCancelled",
        "forEach",
        "map",
        "compactMap",
        "flatMap",
        "filter",
        "reduce",
        "async",
        "asyncAfter",
        "sync",
        "scheduledTimer",
        "sink",
        "addOperation",
        "addObserver",
        "addBarrierBlock",
        "concurrentPerform",
        "withUnsafeBytes",
        "withUnsafeMutableBytes",
        "withUnsafeBufferPointer",
        "withUnsafeMutableBufferPointer",
    }
    receiver, _, method = expression.rpartition(".")
    if not potential:
        if method in {"asyncAfter", "scheduledTimer"}:
            return set()
        if method == "addObserver":
            return set()
        if method == "sink" and not re.fullmatch(r"(?:Combine\.)?Just\([\s\S]*\)", receiver):
            return set()
        if (
            method in {"forEach", "map", "compactMap", "flatMap", "filter", "reduce"}
            and not (call.get("receiverElementCount") or 0) > 0
        ):
            return set()
        if method == "concurrentPerform":
            labels, arguments = call.get("argumentLabels", []), call.get("arguments", [])
            iterations = arguments[labels.index("iterations")] if "iterations" in labels else ""
            if (
                not re.fullmatch(r"[0-9][0-9_]*", iterations)
                or int(iterations.replace("_", "")) <= 0
            ):
                return set()
    if expression.removeprefix("Dispatch.") in {"DispatchWorkItem", "DispatchWorkItem.init"}:
        return set()
    if (
        not potential
        and expression not in functions
        and expression.rsplit(".", 1)[-1] not in methods
    ):
        return set()
    return set(range(len(call.get("arguments", [])))) | {
        position for position, _, _ in call.get("closureArguments", [])
    }


def snapshot_execution_checker():
    """复用固定语法快照中每处引用的可达性结果。"""
    states = {}

    def check(facts, call):
        key = (id(facts), id(call))
        if key not in states:
            states[key] = (facts, call, call_can_execute(facts, call))
        return states[key][2]

    return check


def execution_index(index: dict) -> dict:
    return autoclosure_index(scalar_execution_index(index))


def _is_autoclosure_position(position: int, bindings: list) -> bool:
    if not bindings:
        return False
    return all(position < len(b) and "@autoclosure" in b[position]["type"] for b in bindings)


def _resolve_autoclosure_lazy_ranges(ranges: list, bindings: list) -> list:
    return [
        (position, start, end)
        for position, (start, end) in enumerate(ranges)
        if _is_autoclosure_position(position, bindings)
    ]


def _record_autoclosure_nodes(lazy: list, call: dict, closures: list):
    existing_spans = {(node["start"], node["end"]) for node in closures}
    for position, start, end in lazy:
        if (start, end) not in existing_spans:
            existing_spans.add((start, end))
            closures.append(
                dict(
                    call,
                    start=start,
                    end=end,
                    bodyStart=start,
                    name=f"autoclosure_{call['start']}_{position}",
                    parameters=[],
                )
            )


def autoclosure_index(index: dict) -> dict:
    """Represent known project autoclosure arguments with the existing callback graph."""
    from swift_type_index import SwiftTypeIndex, compilation_unit, receiver_resolver

    functions = [
        (path, function)
        for path, facts in index.items()
        for function in facts.get("functionRanges", [])
    ]
    names = {
        function["name"]
        for _, function in functions
        if any("@autoclosure" in parameter["type"] for parameter in function.get("parameters", []))
    }
    if not names:
        return index
    types, receiver = SwiftTypeIndex(index), receiver_resolver(index)
    result = {}
    for path, facts in index.items():
        calls, closures = [], list(facts.get("inlineClosureRanges", []))
        for call in facts.get("invocations", []):
            expression = call["calledExpression"]
            prefix, _, name = expression.rpartition(".")
            if name not in names:
                calls.append(call)
                continue
            target = receiver(dict(call, path=path)) if prefix not in {"", "self", "Self"} else None
            candidates = [
                (source, function)
                for source, function in functions
                if function["name"] == name
                and (
                    target
                    and ".".join(types.function_scope(source, function["scope"])) == target
                    or not target
                    and prefix in {"", "self", "Self"}
                    and compilation_unit(source) == compilation_unit(path)
                    and call["scope"][: len(function["scope"])] == function["scope"]
                )
                and (
                    not function.get("lexicalScope")
                    or source == path
                    and call.get("lexicalScope", [])[: len(function["lexicalScope"])]
                    == function["lexicalScope"]
                )
            ]
            matches = matching_api_calls(
                index, candidates, dict(call, path=path), types=types, conservative=True
            )
            bindings = [
                binding
                for _, function in matches
                for binding in api_argument_bindings(function, call)
            ]
            ranges = call.get("argumentRanges", [])
            lazy = _resolve_autoclosure_lazy_ranges(ranges, bindings)
            calls.append(dict(call, autoclosureArguments=lazy))
            _record_autoclosure_nodes(lazy, call, closures)
        result[path] = dict(facts, invocations=calls, inlineClosureRanges=closures)
    return result


def _outermost_closure_spans(closures: list) -> set[tuple[int, int]]:
    spans = set()
    for node in closures:
        n_start, n_end = node["start"], node["end"]
        is_nested = any(parent["start"] < n_start and n_end <= parent["end"] for parent in closures)
        if not is_nested:
            spans.add((n_start, n_end))
    return spans


def callback_body_ranges(
    facts: dict, call: dict, positions: set[int], *, references: set[str] | None = None
) -> set[tuple[int, int]]:
    """Resolve consumed closures and work items through their visible local bindings."""
    if (
        not positions
        and not call.get("calledExpression", "").endswith(".perform")
        and not re.fullmatch(r"\w+", call.get("calledExpression", ""))
    ):
        return set()
    variables = dict(
        facts,
        typedVariables=[
            dict(node, name=node["bindingName"])
            for node in facts.get("bindings", [])
            if node.get("bindingName")
        ]
        + facts.get("callableRanges", []),
    )
    work_items = {
        "DispatchWorkItem",
        "DispatchWorkItem.init",
        "Dispatch.DispatchWorkItem",
        "Dispatch.DispatchWorkItem.init",
    }
    if any(node["name"] == "DispatchWorkItem" for node in facts.get("declarations", [])):
        work_items -= {"DispatchWorkItem", "DispatchWorkItem.init"}

    def resolve(value, reference, bounds=None, seen=frozenset()):
        name = value.removeprefix("self.")
        if re.fullmatch(r"\w+", name):
            if references is not None and not value.startswith("self."):
                references.add(name)
            visible = visible_variables(variables, reference, name, value.startswith("self."))
            if not visible:
                return set()
            binding = visible[-1]
            binding = next(
                (
                    node
                    for node in visible
                    if node["start"] == binding["start"] and node.get("iterationSource")
                ),
                binding,
            )
            if binding["start"] in seen:
                return set()
            seen = seen | {binding["start"]}
            result = {
                (node["start"], node["end"])
                for node in facts.get("callableRanges", [])
                if node["start"] == binding["start"] and node["name"] == name
            }
            target = binding.get("referenceTarget") or binding.get("initializerReference")
            if target:
                result.update(resolve(target, binding, seen=seen))
            if binding.get("iterationSource"):
                result.update(
                    resolve(
                        binding["iterationSource"],
                        dict(binding, lexicalScope=binding.get("lexicalScope", [])[:-1]),
                        seen=seen,
                    )
                )
            initializer = binding.get(
                "constantInitializer", binding.get("value", "").partition("=")[2]
            ).strip()
            if initializer.startswith("[") and initializer.endswith("]"):
                end = binding["start"] + len(binding["value"].encode())
                closures = [
                    node
                    for node in facts.get("inlineClosureRanges", [])
                    if binding["start"] <= node["start"] < node["end"] <= end
                ]
                result.update(_outermost_closure_spans(closures))
                for mutation in facts.get("invocations", []):
                    if (
                        mutation["calledExpression"] != name + ".append"
                        or mutation["start"] >= reference["start"]
                        or not call_can_execute(facts, mutation)
                    ):
                        continue
                    owners = visible_variables(variables, mutation, name)
                    if owners and owners[-1]["start"] == binding["start"]:
                        result.update(
                            callback_body_ranges(facts, mutation, {0}, references=references)
                        )
            if binding.get("initializerCall") in work_items:
                end = binding["start"] + len(binding["value"].encode())
                result.update(
                    resolve(
                        binding.get("constantInitializer", ""),
                        binding,
                        (binding["start"], end),
                        seen,
                    )
                )
            return result
        if bounds is None:
            return set()
        constructors = [
            node
            for node in facts.get("invocations", [])
            if node["calledExpression"] in work_items and bounds[0] <= node["start"] < bounds[1]
        ]
        if not constructors:
            return set()
        constructor = min(constructors, key=lambda node: node["start"])
        result = {(start, end) for _, start, end in constructor.get("closureArguments", [])}
        for position, argument in enumerate(constructor.get("arguments", [])):
            ranges = constructor.get("argumentRanges", [])
            result.update(
                resolve(
                    argument,
                    constructor,
                    ranges[position] if position < len(ranges) else None,
                    seen,
                )
            )
        return result

    result = {
        (start, end)
        for position, start, end in call.get("closureArguments", [])
        + call.get("autoclosureArguments", [])
        if position in positions
    }
    for position, argument in enumerate(call.get("arguments", [])):
        if position in positions:
            ranges = call.get("argumentRanges", [])
            result.update(
                resolve(argument, call, ranges[position] if position < len(ranges) else None)
            )
    if call.get("calledExpression", "").endswith(".perform"):
        result.update(resolve(call["calledExpression"].removesuffix(".perform"), call))
    expression = call.get("calledExpression", "")
    if re.fullmatch(r"\w+", expression):
        result.update(resolve(expression, call))
    return result


def _binding_assigned_names(
    parameter: str, expressions: list, fn_start: int, fn_end: int, allowed: set
) -> set:
    names = set()
    pattern = r"self\.(\w+)\s*=\s*" + re.escape(parameter)
    for assignment in expressions:
        if fn_start <= assignment["start"] < fn_end:
            match = re.fullmatch(pattern, assignment["value"])
            if match and match[1] in allowed:
                names.add(match[1])
    return names


def _resolve_initializer_property_names(
    initializers: dict,
    target: tuple,
    call: dict,
    position: int,
    index: dict,
    allowed_properties: set,
) -> set:
    names = set()
    for source_path, function in initializers.get(target, []):
        expressions = index[source_path].get("expressions", [])
        fn_start, fn_end = function["start"], function["end"]
        for binding in api_argument_bindings(function, call):
            if position < len(binding):
                parameter = binding[position].get("name", "")
                if parameter:
                    names |= _binding_assigned_names(
                        parameter, expressions, fn_start, fn_end, allowed_properties
                    )
    return names


def _record_stored_closure_results(
    closures: list,
    ranges: set,
    names: set,
    target: tuple,
    path: str,
    call: dict,
    result: dict,
):
    if not names or not ranges:
        return
    target_key = ".".join([target[0], *target[1]])
    for closure in closures:
        if (closure["start"], closure["end"]) in ranges:
            for name in names:
                result.setdefault((target_key, name), []).append((path, closure, call))


def stored_callback_bindings(index: dict, types) -> dict:
    """连接构造参数、闭包属性与所属源码中的可调用体。"""
    properties, initializers, result = {}, {}, {}
    for path, facts in index.items():
        for node in facts.get("typedVariables", []):
            if not (not node.get("lexicalScope") and "->" in node.get("type", "")):
                continue
            target = types.resolve(path, ".".join(node["scope"]), aliases=False)
            if target:
                properties.setdefault(target, set()).add(node["name"])
        for node in facts.get("initializers", []):
            if not (node.get("isExplicitInitializer")):
                continue
            target = types.resolve(path, ".".join(node["scope"]), aliases=False)
            if target:
                initializers.setdefault(target, []).append((path, node))
    for path, facts in index.items():
        closures = facts.get("callableRanges", []) + facts.get("inlineClosureRanges", [])
        for call in facts.get("invocations", []):
            expression = call["calledExpression"].removesuffix(".init")
            target = types.resolve(
                path, ".".join(call["scope"]) if expression == "Self" else expression, call["scope"]
            )
            if target not in properties:
                continue
            positions = set(range(len(call.get("arguments", [])))) | {
                row[0] for row in call.get("closureArguments", [])
            }
            for position in positions:
                labels = call.get("argumentLabels", [])
                names = (
                    {labels[position]} & properties[target]
                    if position < len(labels) and target not in initializers
                    else set()
                )
                names |= _resolve_initializer_property_names(
                    initializers, target, call, position, index, properties[target]
                )
                ranges = callback_body_ranges(facts, call, {position})
                _record_stored_closure_results(closures, ranges, names, target, path, call, result)
    return result


def _propagate_call_eager_parameters(
    source_path: str,
    function: dict,
    call: dict,
    names: set,
    eager_parameters: set,
    callback_targets_fn,
    index: dict,
):
    fn_start = function["start"]
    for target_path, target_function in callback_targets_fn(source_path, call):
        target_start = target_function["start"]
        for binding in api_argument_bindings(target_function, call):
            positions = {
                pos
                for pos, param in enumerate(binding)
                if (target_path, target_start, param.get("name")) in eager_parameters
            }
            if positions:
                references = set()
                callback_body_ranges(index[source_path], call, positions, references=references)
                for name in references & names:
                    eager_parameters.add((source_path, fn_start, name))


def _call_in_executed_closure(call: dict, source_facts: dict, executed_starts: set) -> bool:
    c_start = call["start"]
    all_closures = source_facts.get("callableRanges", []) + source_facts.get(
        "inlineClosureRanges", []
    )
    for closure in all_closures:
        if closure["start"] <= c_start < closure["end"]:
            if closure["start"] not in executed_starts:
                return False
    return True


def _record_direct_executed_bodies(
    source_facts: dict,
    source_path: str,
    call: dict,
    executed_bodies: dict,
    standard_callbacks_fn,
):
    ranges = callback_body_ranges(source_facts, call, standard_callbacks_fn(source_path, call))
    for start, _ in ranges:
        executed_bodies[source_path].add(start)
    for closure in visible_callable_ranges(source_facts, call["calledExpression"], call):
        executed_bodies[source_path].add(closure["start"])


def _propagate_executed_callback_bodies(
    source_path: str,
    source_facts: dict,
    call: dict,
    callback_targets_fn,
    eager_parameters: set,
    executed_bodies: dict,
):
    for target_path, function in callback_targets_fn(source_path, call):
        fn_start = function["start"]
        for binding in api_argument_bindings(function, call):
            positions = {
                pos
                for pos, param in enumerate(binding)
                if (target_path, fn_start, param.get("name")) in eager_parameters
            }
            if positions:
                for start, _ in callback_body_ranges(source_facts, call, positions):
                    executed_bodies[source_path].add(start)


def _is_exported_async_closure_api(
    declaration: dict, inline_closures: list, contains_request_fn
) -> bool:
    d_start, d_end = declaration["start"], declaration["end"]
    for node in inline_closures:
        if d_start <= node["start"] < node["end"] <= d_end:
            sub = dict(node, start=node["start"] + 1, end=node["end"] - 1)
            if contains_request_fn(sub):
                return True
    return False


def _body_has_lexical_binding(body: dict, bindings: list) -> bool:
    body_name = body["name"]
    body_start = body["start"]
    body_lexical = body.get("lexicalScope", [])
    for binding in bindings:
        b_lexical = binding.get("lexicalScope")
        if (
            binding.get("bindingName") == body_name
            and b_lexical
            and binding["start"] <= body_start
            and body_lexical[: len(b_lexical)] == b_lexical
        ):
            return True
    return False


def _outermost_enclosed_closures(body: dict, inline_closures: list) -> list:
    b_start, b_end = body["start"], body["end"]
    closures = [node for node in inline_closures if b_start <= node["start"] < node["end"] <= b_end]
    return [
        node
        for node in closures
        if not any(p["start"] < node["start"] and node["end"] <= p["end"] for p in closures)
    ]


def _body_contains_request(body: dict, inline_closures: list, contains_request_fn) -> bool:
    body_start = body.get("bodyStart")
    if body_start and contains_request_fn(dict(body, start=body_start)):
        return True
    outer = _outermost_enclosed_closures(body, inline_closures)
    for node in outer:
        if contains_request_fn(dict(node, start=node["start"] + 1, end=node["end"] - 1)):
            return True
    return False


def _is_exported_callable_async(declaration: dict, facts: dict, contains_request_fn) -> bool:
    d_name, d_scope = declaration["name"], declaration["scope"]
    inline_closures = facts.get("inlineClosureRanges", [])
    bindings = facts.get("bindings", [])
    for body in facts.get("callableRanges", []):
        if body["name"] == d_name and body["scope"] == d_scope:
            if body is not declaration and _body_has_lexical_binding(body, bindings):
                continue
            if _body_contains_request(body, inline_closures, contains_request_fn):
                return True
    return False
