"""Evaluate Swift constants and reachable control flow."""

import ast
import math
import operator
import re
import unicodedata
import warnings
from functools import cache
from swift_scope_facts import visible_variables


def custom_constant_symbols(facts: dict) -> bool:
    return _custom_constant_symbols(
        facts.get("source", ""),
        tuple(function.get("name") for function in facts.get("functionRanges", [])),
        tuple(
            node["name"] for node in facts.get("declarations", []) + facts.get("typeAliases", [])
        ),
    )


@cache
def _custom_constant_symbols(source: str, functions: tuple, declarations: tuple) -> bool:
    scalar = (
        "(?:Bool|String|Character|Float|Double|U?Int(?:8|16|32|64)?|Array|ArraySlice|\\w*LiteralTy"
        "pe)"
    )
    operators = {
        "==",
        "!=",
        "<",
        ">",
        "<=",
        ">=",
        "+",
        "-",
        "*",
        "/",
        "%",
        "!",
        "&&",
        "||",
        "~=",
        "...",
        "..<",
        "prefix",
        "suffix",
        "dropFirst",
        "dropLast",
    }
    if any(name in operators for name in functions):
        return True
    if any(re.fullmatch(scalar, name) for name in declarations):
        return True
    return any(
        re.fullmatch(scalar, parameter.split(":", 1)[0].strip())
        for match in re.finditer(
            r"\b(?:func|struct|class|enum|typealias)\s+\w+\s*<([^>{}]*)", source
        )
        for parameter in match[1].split(",")
    )


def constant_folding_allowed(facts: dict) -> bool:
    if "constantFoldingAllowed" in facts:
        return facts["constantFoldingAllowed"]
    return not custom_constant_symbols(facts)


def string_literal_value(literal):
    escapes = {"0": "\0", "t": "\t", "n": "\n", "r": "\r", '"': '"', "'": "'", "\\": "\\"}
    pieces = []
    for part in re.finditer(r"\\(u\{[0-9a-fA-F]{1,8}\}|.)|[^\\]+", literal[1:-1]):
        escape = part[1]
        if escape is None:
            pieces.append(part[0])
        elif escape in escapes:
            pieces.append(escapes[escape])
        elif escape.startswith("u{"):
            scalar = int(escape[2:-1], 16)
            if scalar > 0x10FFFF or 0xD800 <= scalar <= 0xDFFF:
                return None
            pieces.append(chr(scalar))
        else:
            return None
    return unicodedata.normalize("NFC", "".join(pieces))


def constant_value(condition: str, resolve, *, floating=False):
    if '"""' in condition:
        return None
    tokens = {"&&": " and ", "||": " or ", "!": " not ", "true": "True", "false": "False"}

    def translate(match):
        if match[0].startswith('"'):
            literal = string_literal_value(match[0])
            return repr(literal) if literal is not None else "runtime_literal()"
        return tokens[match[0]]

    expression = re.sub(
        r'"(?:\\.|[^"\\])*"|&&|\|\||!(?!=)|\b(?:true|false)\b', translate, condition
    ).strip()
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", SyntaxWarning)
            node = ast.parse(expression, mode="eval").body
    except SyntaxError:
        return None

    def value(node, floating=False):
        if isinstance(node, ast.Constant):
            if type(node.value) is bool:
                return node.value
            if type(node.value) is int:
                if floating:
                    try:
                        return float(node.value)
                    except OverflowError:
                        return None
                return node.value
            if type(node.value) is float:
                return node.value if math.isfinite(node.value) else None
            if type(node.value) is str:
                return node.value
        if isinstance(node, ast.Name):
            return resolve(node.id)
        if isinstance(node, ast.UnaryOp):
            operand = value(node.operand, floating)
            if isinstance(node.op, ast.Not):
                return not operand if type(operand) is bool else None
            if type(operand) in {int, float}:
                if isinstance(node.op, ast.USub):
                    return -operand
                if isinstance(node.op, ast.UAdd):
                    return operand
        if isinstance(node, ast.BinOp):
            left, right = value(node.left, floating), value(node.right, floating)
            if isinstance(node.op, ast.Add) and type(left) is str and type(right) is str:
                return unicodedata.normalize("NFC", left + right)
            if type(left) is float or type(right) is float:
                left, right = value(node.left, True), value(node.right, True)
            if type(left) not in {int, float} or type(right) not in {int, float}:
                return None
            if (
                type(left) is int
                and type(right) is int
                and not all(-(1 << 63) <= item < (1 << 63) for item in (left, right))
            ):
                return None
            operation = {
                ast.Add: operator.add,
                ast.Sub: operator.sub,
                ast.Mult: operator.mul,
                ast.Div: operator.truediv,
            }.get(type(node.op))
            try:
                if (
                    type(left) is int
                    and type(right) is int
                    and isinstance(node.op, (ast.Div, ast.Mod))
                ):
                    if right == 0 or left == -(1 << 63) and right == -1:
                        return None
                    quotient = abs(left) // abs(right) * (-1 if (left < 0) != (right < 0) else 1)
                    result = quotient if isinstance(node.op, ast.Div) else left - quotient * right
                elif operation:
                    result = operation(left, right)
                else:
                    return None
            except (OverflowError, ZeroDivisionError):
                return None
            return (
                result
                if (
                    math.isfinite(result)
                    if type(result) is float
                    else -(1 << 63) <= result < (1 << 63)
                )
                else None
            )
        if isinstance(node, ast.BoolOp):
            values = [value(operand) for operand in node.values]
            if isinstance(node.op, ast.And):
                if any(item is False for item in values):
                    return False
                if all(item is True for item in values):
                    return True
                return None
            if isinstance(node.op, ast.Or):
                if any(item is True for item in values):
                    return True
                if all(item is False for item in values):
                    return False
                return None
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            left, right = value(node.left), value(node.comparators[0])
            if type(left) is float or type(right) is float:
                left, right = value(node.left, True), value(node.comparators[0], True)
            if left is None or right is None:
                return None
            numeric = type(left) in {int, float} and type(right) in {int, float}
            if not numeric and type(left) is not type(right):
                return None
            if numeric:
                if type(left) is float or type(right) is float:
                    try:
                        left, right = float(left), float(right)
                    except OverflowError:
                        return None
                    if not math.isfinite(left) or not math.isfinite(right):
                        return None
            if isinstance(node.ops[0], ast.Eq):
                return left == right
            if isinstance(node.ops[0], ast.NotEq):
                return left != right
            if numeric:
                comparison = {
                    ast.Lt: operator.lt,
                    ast.LtE: operator.le,
                    ast.Gt: operator.gt,
                    ast.GtE: operator.ge,
                }.get(type(node.ops[0]))
                if comparison:
                    return comparison(left, right)
        return None

    return value(node, floating)


def constant_boolean(condition: str, resolve) -> bool | None:
    result = constant_value(condition, resolve)
    return result if type(result) is bool else None


def branch_value(facts: dict, branch: dict, expression: str):
    literal = expression.strip(" \t\r\n()")
    if literal in {"true", "false"}:
        return literal == "true"
    if not constant_folding_allowed(facts):
        return None
    bound_scope = facts.get("smokeScope")
    scope_bindings = facts.get("smokeScopeBindings", {})
    smoke_context = bound_scope is not None or "smokeScopeBindings" in facts

    def enum_literals(value):
        return (
            re.sub(
                r"(?<![\w.])(?:NetworkSmokeScope)?\.(all|communityWrites|communityCleanup)\b",
                lambda match: '"' + match[1] + '"',
                value,
            )
            if smoke_context
            else value
        )

    expression = enum_literals(expression)

    def parameter_value(name, location, node=None):
        functions = [
            function
            for function in facts.get("functionRanges", [])
            if function["start"] <= location["start"] < function["end"]
            and (
                node is None
                or function["start"] <= node["start"] < function.get("bodyStart", function["start"])
            )
            and any(parameter.get("name") == name for parameter in function.get("parameters", []))
        ]
        if not functions:
            return None
        function = min(functions, key=lambda item: item["end"] - item["start"])
        root_scope = (
            bound_scope
            if function.get("scope") == ["ReleaseNetworkSmokeRunner"]
            and function["name"] == "run"
            and name == "scope"
            else None
        )
        return scope_bindings.get((function["start"], name), root_scope)

    resolving = set()

    def resolve(name, location=branch):
        lexical = location.get("lexicalScope", [])
        bindings = [
            node
            for node in facts.get("bindings", [])
            if node.get("bindingName") == name
            and node.get("scope") == location.get("scope")
            and node["start"] <= location["start"]
            and (
                not node.get("visibilityRange")
                or node["visibilityRange"][0] <= location["start"] < node["visibilityRange"][1]
            )
            and lexical[: len(node.get("lexicalScope", []))] == node.get("lexicalScope", [])
        ]
        variables = visible_variables(
            {
                **facts,
                "typedVariables": facts.get("typedVariables", []),
                "functionRanges": facts.get("functionRanges", []),
            },
            location,
            name,
        )
        if smoke_context and not bindings and not variables:
            return parameter_value(name, location)
        if candidates := bindings + variables:
            node = max(
                candidates,
                key=lambda item: (
                    len(item.get("scope", [])),
                    len(item.get("lexicalScope", [])),
                    item["start"],
                ),
            )
            initializer = node.get("constantInitializer")
            annotation = node.get("bindingType")
            if smoke_context and not initializer:
                return parameter_value(name, location, node)
            if (
                not initializer
                or node["start"] in resolving
                or annotation
                and not re.fullmatch(
                    r"(?:Swift\.)?(?:Bool|String|U?Int(?:8|16|32|64)?|Double)"
                    + (r"|NetworkSmokeScope" if smoke_context else ""),
                    annotation,
                )
            ):
                return None
            resolving.add(node["start"])
            try:
                result = constant_value(
                    enum_literals(initializer),
                    lambda referenced: resolve(referenced, node),
                    floating=annotation in {"Double", "Swift.Double"},
                )
                if annotation in {"Double", "Swift.Double"} and type(result) is int:
                    try:
                        return float(result)
                    except OverflowError:
                        return None
                return result
            finally:
                resolving.remove(node["start"])
        return None

    return constant_value(expression, resolve)


def branch_condition(facts: dict, branch: dict) -> bool | None:
    values = [
        branch_value(facts, branch, condition)
        for condition in branch.get("conditionElements") or [branch.get("condition") or ""]
    ]
    return (
        False
        if any(value is False for value in values)
        else True
        if all(value is True for value in values)
        else None
    )


def pattern_match_value(subject: object, value: object) -> bool | None:
    if subject is None or value is None:
        return None
    numeric = type(subject) in {int, float} and type(value) in {int, float}
    if numeric and (type(subject) is float or type(value) is float):
        try:
            return float(subject) == float(value)
        except OverflowError:
            return None
    if numeric or type(subject) is type(value):
        return subject == value
    return None


def switch_entries(facts: dict, branch: dict) -> set[int]:
    """Select possible entry cases from constant subjects, patterns and guards."""
    cases = branch.get("switchCases")
    if cases is None:
        return set(range(len(branch.get("branchRanges", []))))
    subject = branch_value(facts, branch, branch.get("switchSubject") or "")
    entries = set()
    for index, case in enumerate(cases):
        matches = [True] if case["isDefault"] else []
        for pattern in case["patterns"]:
            value = branch_value(facts, branch, pattern["value"])
            if pattern["value"] == "_":
                match = True
            elif value is None:
                guard = branch_value(facts, branch, pattern.get("condition") or "true")
                matches.append(False if guard is False else None)
                continue
            else:
                match = pattern_match_value(subject, value)
            guard = (
                branch_value(facts, branch, pattern["condition"])
                if pattern.get("condition")
                else True
            )
            matches.append(
                False
                if match is False or guard is False
                else True
                if match is True and guard is True
                else None
            )
        if any(match is not False for match in matches):
            entries.add(index)
        if any(match is True for match in matches):
            break
    return entries


def block_outcomes(facts: dict, branch: dict, conditions: dict, bounds, *, nested=True) -> set[str]:
    normal = {"normal"}
    if not bounds:
        return normal
    rows = facts.get("controlFlow", [])
    lexical = branch.get("lexicalScope", [])
    alternative = next(
        (
            row
            for row in rows
            if row["start"] == bounds[0]
            and row.get("lexicalScope", []) == lexical
            and row.get("thenRange")
        ),
        None,
    )
    if nested and alternative:
        return control_flow_outcomes(facts, alternative, conditions)
    outcomes = normal
    direct = sorted(
        (
            row
            for row in rows
            if bounds[0] <= row["start"] < bounds[1]
            and row.get("scope") == branch.get("scope")
            and row.get("lexicalScope", []) == lexical + ([bounds[0]] if nested else [])
        ),
        key=lambda row: row["start"],
    )
    covered_until = bounds[0]
    for row in direct:
        if row["start"] < covered_until:
            continue
        if "normal" not in outcomes:
            break
        if row.get("deadRange"):
            jump = row["value"].split(maxsplit=1)
            following = {
                "labeled-jump" if len(jump) > 1 and jump[0] in {"break", "continue"} else jump[0]
            }
        elif row.get("thenRange") or row.get("elseRange") or row.get("branchRanges"):
            following = control_flow_outcomes(facts, row, conditions)
            spans = [row[key] for key in ("thenRange", "elseRange") if row.get(key)] + row.get(
                "branchRanges", []
            )
            covered_until = max(
                [span[1] for span in spans] + [row.get("followingRange", [row["start"]])[0]]
            )
        else:
            continue
        outcomes = outcomes - normal | following
    return outcomes


def control_flow_outcomes(facts: dict, branch: dict, conditions: dict) -> set[str]:
    """Track normal continuation and explicit exits through compiler block facts."""
    normal = {"normal"}

    def outcomes(bounds, *, nested=True):
        return block_outcomes(facts, branch, conditions, bounds, nested=nested)

    identity = branch["start"]
    if identity not in conditions:
        conditions[identity] = branch_condition(facts, branch)
    value = conditions[identity]
    kind = branch["value"].split()[0]
    if kind == "switch":
        result, following = set(), normal
        entries = switch_entries(facts, branch)
        for index, bounds in reversed(list(enumerate(branch.get("branchRanges", [])))):
            outcome = outcomes(bounds, nested=False)
            following = outcome - {"fallthrough"} | (
                following if "fallthrough" in outcome else set()
            )
            if index in entries:
                result |= following
        return result - {"break"} | (normal if "break" in result or not entries else set())
    if kind == "guard":
        return (
            normal
            if value is True
            else outcomes(branch.get("elseRange")) | (normal if value is None else set())
        )
    body = outcomes(branch.get("thenRange"))
    if kind == "do":
        alternatives = set().union(*(outcomes(bounds) for bounds in branch.get("branchRanges", [])))
        return body | alternatives
    if kind in {"while", "repeat"}:
        if kind == "while" and value is False:
            return normal
        exits = "break" in body or value is not True and bool({"normal", "continue"} & body)
        return body - {"normal", "break", "continue"} | (
            normal if exits or kind == "while" and value is None else set()
        )
    alternative = outcomes(branch.get("elseRange"))
    return body if value is True else alternative if value is False else body | alternative


def collection_count(facts: dict, location: dict, source=None, seen=frozenset()):
    if location.get("collectionElementCount") is not None:
        return location["collectionElementCount"]
    name = (source if source is not None else location.get("iterationSource") or "").strip(
        " \t\r\n()"
    )
    if not re.fullmatch(r"[A-Za-z_]\w*", name):
        return None
    lexical = location.get("lexicalScope", [])
    candidates = [
        node
        for node in facts.get("bindings", [])
        if node.get("bindingName") == name
        and node.get("scope") == location.get("scope")
        and node["start"] < location["start"]
        and (
            not node.get("visibilityRange")
            or node["visibilityRange"][0] <= location["start"] < node["visibilityRange"][1]
        )
        and lexical[: len(node.get("lexicalScope", []))] == node.get("lexicalScope", [])
    ]
    candidates += visible_variables(facts, location, name)
    if not candidates:
        return None
    node = max(candidates, key=lambda item: (len(item.get("lexicalScope", [])), item["start"]))
    annotation = re.sub(r"\s+", "", node.get("bindingType") or "")
    if (
        not node.get("constantInitializer")
        or node["start"] in seen
        or annotation
        and not (
            annotation.startswith("[") or re.match(r"(?:Swift\.)?(?:Array|ArraySlice)<", annotation)
        )
    ):
        return None
    return collection_count(facts, node, node["constantInitializer"], seen | {node["start"]})


def is_empty_iteration(facts: dict, branch: dict, folding: bool) -> bool:
    sequence = re.sub(r"[\s()]", "", branch.get("iterationSource") or "")
    bounds = branch.get("iterationBounds")
    if not bounds:
        literal = re.fullmatch(r"([+-]?\d[\d_]*)(\.\.<|\.\.\.)([+-]?\d[\d_]*)", sequence)
        bounds = list(literal.groups()) if literal else None
    empty = folding and (sequence == "[]" or collection_count(facts, branch) == 0)
    if bounds and folding:
        lower, upper = (branch_value(facts, branch, bounds[position]) for position in (0, 2))
        if type(lower) is int and type(upper) is int:
            if bounds[1] == "..<":
                empty = lower >= upper
            else:
                empty = lower > upper
    return empty


def call_can_execute(facts: dict, call: dict) -> bool:
    conditions = {}
    folding = constant_folding_allowed(facts)
    for branch in facts.get("expressionFlow", []):
        if not any(
            bounds and bounds[0] <= call["start"] < bounds[1]
            for bounds in (branch.get("thenRange"), branch.get("elseRange"))
        ):
            continue
        value = branch_condition(facts, branch)
        excluded = (
            branch.get("elseRange")
            if value is True
            else branch.get("thenRange")
            if value is False
            else None
        )
        if excluded and excluded[0] <= call["start"] < excluded[1]:
            return False

    def hoisted(bounds, branch):
        return any(
            function["start"] >= bounds[0]
            and function["start"] <= call["start"] < function["end"]
            and function.get("lexicalScope", []) == branch.get("lexicalScope", [])
            for function in facts.get("functionRanges", [])
        )

    for branch in facts.get("controlFlow", []):
        dead = branch.get("deadRange")
        if dead and dead[0] <= call["start"] < dead[1]:
            if not hoisted(dead, branch):
                return False
        body = branch.get("thenRange")
        if body and body[0] <= call["start"] < body[1]:
            if is_empty_iteration(facts, branch, folding):
                return False
        if branch.get("switchSubject") is not None and any(
            bounds[0] <= call["start"] < bounds[1] for bounds in branch.get("branchRanges", [])
        ):
            reachable = switch_entries(facts, branch)
            for index, bounds in enumerate(branch.get("branchRanges", [])):
                if index in reachable and "fallthrough" in block_outcomes(
                    facts, branch, conditions, bounds, nested=False
                ):
                    reachable.add(index + 1)
                if bounds[0] <= call["start"] < bounds[1] and index not in reachable:
                    return False
        if not any(
            bounds and bounds[0] <= call["start"] < bounds[1]
            for bounds in (body, branch.get("elseRange"), branch.get("followingRange"))
        ):
            continue
        if branch["start"] not in conditions:
            conditions[branch["start"]] = branch_condition(facts, branch)
        value = conditions[branch["start"]]
        excluded = (
            branch.get("elseRange")
            if value is True
            else branch.get("thenRange")
            if value is False and not branch["value"].startswith("repeat")
            else None
        )
        if excluded and excluded[0] <= call["start"] < excluded[1]:
            return False
        following = branch.get("followingRange")
        if (
            following
            and following[0] <= call["start"] < following[1]
            and not hoisted(following, branch)
            and not {"normal", "labeled-jump"} & control_flow_outcomes(facts, branch, conditions)
        ):
            return False
    return True
