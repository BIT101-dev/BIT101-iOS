"""Resolve statically known Swift symbol expressions."""

import re
from functools import cache
from swift_source_index import swift_code


@cache
def mask_comments(source: str) -> str:
    return swift_code(source, keep_literals=True)


def _string_literal_value(expression: str) -> str | None:
    expression = expression.strip()
    match = re.fullmatch(r'"([^"\\\n]*)"', expression)
    if match:
        return match.group(1)
    match = re.fullmatch(r'(?P<hashes>#+)"(?P<value>[^"\\\n]*)"(?P=hashes)', expression)
    return match.group("value") if match else None


def _skip_swift_string(source: str, start: int) -> int | None:
    quote_start = start
    while quote_start < len(source) and source[quote_start] == "#":
        quote_start += 1
    if quote_start >= len(source) or source[quote_start] != '"':
        return None
    hashes = source[start:quote_start]
    quote = '"""' if source.startswith('"""', quote_start) else '"'
    terminator = quote + hashes
    index = quote_start + len(quote)
    while index < len(source):
        if not hashes and source[index] == "\\":
            index += 2
            continue
        if source.startswith(terminator, index):
            return index + len(terminator)
        index += 1
    return None


def _top_level_ternary(expression: str) -> tuple[str, str] | None:
    depths = {"(": 0, "[": 0, "{": 0}
    closing = {")": "(", "]": "[", "}": "{"}
    question = None
    index = 0
    while index < len(expression):
        string_end = _skip_swift_string(expression, index)
        if string_end is not None:
            index = string_end
            continue
        character = expression[index]
        if character in depths:
            depths[character] += 1
        elif character in closing:
            depths[closing[character]] -= 1
        elif not any(depths.values()) and character == "?":
            if (
                expression.startswith(("?.", "??"), index)
                or index > 0
                and expression[index - 1] == "?"
            ):
                index += 1
                continue
            question = index
            break
        index += 1
    if question is None:
        return None

    nested_questions = 0
    depths = {"(": 0, "[": 0, "{": 0}
    index = question + 1
    while index < len(expression):
        string_end = _skip_swift_string(expression, index)
        if string_end is not None:
            index = string_end
            continue
        character = expression[index]
        if character in depths:
            depths[character] += 1
        elif character in closing:
            depths[closing[character]] -= 1
        elif not any(depths.values()):
            if character == "?" and not expression.startswith(("?.", "??"), index):
                nested_questions += 1
            elif character == ":":
                if nested_questions == 0:
                    return expression[question + 1 : index].strip(), expression[index + 1 :].strip()
                nested_questions -= 1
        index += 1
    return None


def _outer_parenthesized_expression(expression: str) -> str:
    expression = expression.strip()
    while expression.startswith("(") and expression.endswith(")"):
        depth = 0
        closes_at_end = False
        index = 0
        while index < len(expression):
            string_end = _skip_swift_string(expression, index)
            if string_end is not None:
                index = string_end
                continue
            if expression[index] == "(":
                depth += 1
            elif expression[index] == ")":
                depth -= 1
                if depth == 0:
                    closes_at_end = index == len(expression) - 1
                    break
            index += 1
        if not closes_at_end:
            break
        expression = expression[1:-1].strip()
    return expression


def static_symbol_values(
    expression: str,
    facts: dict,
    scope: list[str],
    resolving: frozenset[str] = frozenset(),
) -> list[str]:
    expression = _outer_parenthesized_expression(mask_comments(expression))
    if re.search(r"\\#*\(", expression):
        return []
    literal = _string_literal_value(expression)
    if literal is not None:
        return [literal]

    conditional = _top_level_ternary(expression)
    if conditional:
        then_values = static_symbol_values(conditional[0], facts, scope, resolving)
        else_values = static_symbol_values(conditional[1], facts, scope, resolving)
        return then_values + else_values if then_values and else_values else []

    variable = re.fullmatch(r"(?:self\.)?([A-Za-z_][A-Za-z0-9_]*)", expression)
    if variable:
        name = variable.group(1)
        if name in resolving:
            return []
        bindings = []
        for binding in facts.get("bindings", []):
            if binding["scope"] != scope:
                continue
            match = re.match(
                rf"(?:let\s+|var\s+)?{re.escape(name)}\s*=\s*(.+)$", binding["value"], re.S
            )
            if match:
                bindings.append(match.group(1).strip())
        if len(bindings) == 1:
            return static_symbol_values(bindings[0], facts, scope, resolving | {name})
        return []

    called_function = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(", expression)
    if called_function and expression.endswith(")"):
        function_name = called_function.group(1)
        if function_name in resolving:
            return []
        functions = [
            function
            for function in facts.get("functions", [])
            if function["scope"] == scope
            and re.search(rf"\bfunc\s+{re.escape(function_name)}\s*\(", function["value"])
        ]
        if len(functions) != 1:
            return []
        return_expressions = [
            item["value"]
            for item in facts.get("functionReturns", [])
            if item["name"] == function_name and item["scope"] == scope
        ]
        if not return_expressions:
            return []
        values = []
        for returned in return_expressions:
            branch_values = static_symbol_values(
                returned, facts, scope, resolving | {function_name}
            )
            if not branch_values:
                return []
            values.extend(branch_values)
        return values
    return []
