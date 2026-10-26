"""Swift source facts for shared UI and design rules."""
from __future__ import annotations

from pathlib import Path
from functools import cache
import re
import sys
from swift_source_index import swift_code, expected_argument_types, scope_contains_type
from swift_type_index import call_can_execute, execution_index

from ui_design_contracts import (
    COMPONENT_INHERITANCE, DERIVED_DESIGN_TOKEN, DIRECT_ACCENT_COLOR, DIRECT_ANIMATION_DURATION,
    DIRECT_BARE_HSTACK, DIRECT_BLUR_GEOMETRY, DIRECT_CORNER_RADIUS, DIRECT_CUSTOM_SECTION_HEADER,
    DIRECT_EDGE_INSETS_LITERAL, DIRECT_FLOATING_MATERIAL, DIRECT_FLOATING_SIZE,
    DIRECT_FONT_MODIFIER, DIRECT_FOREGROUND_STYLE, DIRECT_FRAME_LITERAL, DIRECT_GRID_ITEM_GEOMETRY,
    DIRECT_GROUPED_LIST_STYLE, DIRECT_HIERARCHICAL_COLOR, DIRECT_HSTACK_LITERAL,
    DIRECT_INPUT_PLACEHOLDER, DIRECT_LIST_SECTION_SPACING, DIRECT_LOCAL_CGFLOAT_LITERAL,
    DIRECT_OPACITY_ASSIGNMENT, DIRECT_OPACITY_LITERAL, DIRECT_PLAIN_LIST_STYLE,
    DIRECT_ROUNDED_RECTANGLE, DIRECT_SEMANTIC_COLOR_RULES, DIRECT_STROKE_GEOMETRY,
    DIRECT_SYSTEM_COLOR, DIRECT_THUMBNAIL_GEOMETRY, DIRECT_TOUCH_TARGET, PADDING_LITERAL,
    REPEATED_DESIGN_TOKEN, STACK_SPACING_LITERAL,
)


sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[1]


SOURCE_ROOT = ROOT / "BIT101-iOS"


SOURCE_ROOTS = tuple(ROOT / name for name in ("BIT101-iOS", "Modules", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"))


DESIGN_SYSTEM = ROOT / "Modules/DesignSystemKit/Sources/AppDesignSystem.swift"


DESIGN_SYSTEM_SOURCES = {
    DESIGN_SYSTEM,
    ROOT / "Modules/DesignSystemKit/Sources/DesignPrimitives.swift",
    ROOT / "Modules/DesignSystemKit/Sources/ExternalDesignSystem.swift",
    ROOT / "Modules/ScheduleFeature/Sources/ScheduleDesignSystem.swift",
    ROOT / "Modules/GalleryFeature/Sources/GalleryDesignSystem.swift",
}


MAP_THEME_COLOR_CONTRACT = (
    "Modules/MapFeature/Sources/CampusMapScreen.swift",
    "public static let tabAccent = Color.green",
)


PRIMITIVE_OPACITY_SOURCE = ROOT / "Modules/DesignSystemKit/Sources/DesignPrimitives.swift"


def source_path(relative_path: str) -> Path:
    return ROOT / relative_path if relative_path.startswith("Modules/") else SOURCE_ROOT / relative_path


@cache
def source_relative(path: Path) -> str:
    return path.relative_to(SOURCE_ROOT).as_posix() if path.is_relative_to(SOURCE_ROOT) else path.relative_to(ROOT).as_posix()


REPORT_PATH = ROOT / ".build/ui-consistency-report.txt"


@cache
def mask_comments(source: str) -> str:
    return swift_code(source, keep_literals=True)


@cache
def mask_literals_and_comments(source: str) -> str:
    return swift_code(source)


@cache
def swift_files() -> list[Path]:
    from swift_source_index import repository_swift_files
    return [path for path in repository_swift_files() if any(path.is_relative_to(root) for root in SOURCE_ROOTS)]


@cache
def source_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def syntax_index() -> dict[str, dict]:
    from swift_source_index import swift_syntax_index
    return swift_syntax_index(swift_files())


def ast_has_marker(facts: dict, marker: str, scope: list[str] | None = None) -> bool:
    normalized = re.sub(r"\s+", " ", marker).strip()
    in_scope = lambda item: scope is None or item.get("scope") == scope
    if normalized.startswith("struct "):
        name = normalized.removeprefix("struct ").strip()
        return any(
            declaration["kind"] == "struct"
            and declaration["name"] == name
            and (scope is None or declaration["scope"] + [declaration["name"]] == scope)
            for declaration in facts["declarations"]
        )

    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", normalized):
        return any(
            declaration["name"] == normalized
            and in_scope({"scope": declaration["scope"] + [declaration["name"]]})
            for declaration in facts["declarations"]
        ) or any(
            (
                call["value"] == normalized
                or call["value"].endswith("." + normalized)
                or call["value"].startswith(normalized + ".")
            )
            and in_scope(call)
            for call in facts["calls"]
        ) or any(
            (
                member["value"] == normalized
                or member["value"].endswith("." + normalized)
                or member["value"].startswith(normalized + ".")
            )
            and in_scope(member)
            for member in facts["members"]
        ) or any(
            re.search(
                rf"(?<![A-Za-z0-9_$]){re.escape(normalized)}(?![A-Za-z0-9_$])",
                binding["value"].split("=", 1)[0],
            )
            and in_scope(binding)
            for binding in facts["bindings"]
        )

    variants = {normalized}
    for keyword in ("let ", "var "):
        if normalized.startswith(keyword):
            variants.add(normalized.removeprefix(keyword))
    collections = (
        facts["calls"], facts["invocations"], facts["members"], facts["expressions"],
        facts["bindings"], facts["controlFlow"], facts["typeNames"],
    )
    if any(
        any(
            (
                expected == re.sub(r"\s+", " ", item["value"]).strip()
                or expected in re.sub(r"\s+", " ", item["value"]).strip()
            )
            and in_scope(item)
            for expected in variants
        )
        for collection in collections
        for item in collection
    ):
        return True

    if any(normalized in segment["value"] and in_scope(segment) for segment in facts["stringSegments"]):
        return True
    return False


def view_scopes(facts: dict) -> list[list[str]]:
    return [
        declaration["scope"] + [declaration["name"]]
        for declaration in facts["declarations"]
        if any(inherited.rsplit(".", 1)[-1] == "View" for inherited in declaration["inheritedTypes"])
    ]


@cache
def path_is_in_source_root(path: str, source_root: Path) -> bool:
    return Path(path).is_relative_to(source_root)


def view_entries(
    syntax: dict[str, dict], view_name: str, source_root: Path = ROOT
) -> list[tuple[Path, dict, list[str]]]:
    return [
        (Path(path), facts, declaration["scope"] + [declaration["name"]])
        for path, facts in syntax.items()
        if path_is_in_source_root(path, source_root)
        for declaration in facts["declarations"]
        if declaration["name"] == view_name
        and any(inherited.rsplit(".", 1)[-1] == "View" for inherited in declaration["inheritedTypes"])
    ]


def child_view_entries(
    syntax: dict[str, dict], call_name: str, parent_scope: list[str]
) -> list[tuple[Path, dict, list[str]]]:
    components = call_name.split(".")
    candidates = view_entries(syntax, components[-1])
    if len(components) > 1:
        qualified = [
            entry for entry in candidates
            if entry[2][-len(components):] == components
        ]
        return qualified if qualified else []

    for end in range(len(parent_scope), -1, -1):
        lexical_parent = parent_scope[:end]
        local = [entry for entry in candidates if entry[2][:-1] == lexical_parent]
        if local:
            return local

    top_level = [entry for entry in candidates if len(entry[2]) == 1]
    if len(top_level) == 1:
        return top_level
    if len(candidates) == 1:
        return candidates
    return []


def type_entries(
    syntax: dict[str, dict], type_name: str, source_root: Path = ROOT
) -> list[tuple[Path, dict, list[str]]]:
    return [
        (Path(path), facts, declaration["scope"] + [declaration["name"]])
        for path, facts in syntax.items()
        if path_is_in_source_root(path, source_root)
        for declaration in facts["declarations"]
        if declaration["name"] == type_name
        and declaration["kind"] in {"struct", "class", "actor", "extension"}
    ]


def has_component_declaration(symbol: str, declarations: list[dict]) -> bool:
    expected_inheritance = COMPONENT_INHERITANCE[symbol]
    return any(
        declaration["name"] == symbol
        and declaration["kind"] == "struct"
        and (
            expected_inheritance is None
            or any(
                inherited.rsplit(".", 1)[-1] == expected_inheritance
                for inherited in declaration["inheritedTypes"]
            )
        )
        for declaration in declarations
    )


def list_icon_findings(path: Path, facts: dict) -> list[str]:
    findings: list[str] = []
    for icon in facts.get("listIcons", []):
        if not icon["containers"]:
            continue
        symbol = icon["symbol"].strip()
        possible_symbols = resolved_icon_symbols(symbol, facts, icon["scope"])
        all_symbols_are_standard = bool(possible_symbols) and all(
            re.search(r"checkmark|circle|chevron|xmark|minus|star", candidate)
            for candidate in possible_symbols
        )
        if not all_symbols_are_standard:
            findings.append(
                f"{path}: {'.'.join(icon['scope'])} 列表/表单左侧图标需使用公共组件或静态可验证的标准符号"
                f"（{icon['name']}: {symbol}）"
            )
    return findings


def resolved_icon_symbols(symbol: str, facts: dict, scope: list[str]) -> list[str]:
    return static_symbol_values(symbol, facts, scope)


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
            if expression.startswith(("?.", "??"), index) or index > 0 and expression[index - 1] == "?":
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
                    return expression[question + 1:index].strip(), expression[index + 1:].strip()
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
            match = re.match(rf"(?:let\s+|var\s+)?{re.escape(name)}\s*=\s*(.+)$", binding["value"], re.S)
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
            function for function in facts.get("functions", [])
            if function["scope"] == scope
            and re.search(rf"\bfunc\s+{re.escape(function_name)}\s*\(", function["value"])
        ]
        if len(functions) != 1:
            return []
        return_expressions = [
            item["value"] for item in facts.get("functionReturns", [])
            if item["name"] == function_name and item["scope"] == scope
        ]
        if not return_expressions:
            return []
        values = []
        for returned in return_expressions:
            branch_values = static_symbol_values(returned, facts, scope, resolving | {function_name})
            if not branch_values:
                return []
            values.extend(branch_values)
        return values
    return []


class UIAuditContext(dict):
    def __init__(self, syntax):
        super().__init__(syntax)
        self.execution = execution_index(self)


def rendered_scope_facts(facts: dict, scope: list[str], syntax: dict[str, dict] | None = None) -> dict:
    """Limit a View's contract search to rendered expressions and reachable View helpers."""
    memo = facts.get("renderedScopeFacts")
    key = (tuple(scope), id(syntax))
    if memo is not None and key in memo:
        return memo[key]
    parts = [(facts, True)]
    if syntax:
        parts.extend(
            (other_facts, False)
            for path, other_facts in syntax.items()
            if path_is_in_source_root(path, ROOT)
            if other_facts is not facts
            and any(item["scope"] == scope for item in other_facts.get("functionRanges", []))
        )
    functions = [
        (part, item)
        for part, _ in parts
        for item in part.get("functionRanges", [])
        if item["scope"] == scope
    ]
    inputs = dict(syntax or {})
    if not any(part is facts for part in inputs.values()):
        inputs["ui-fixture.swift"] = facts
    execution = syntax.execution if isinstance(syntax, UIAuditContext) and len(inputs) == len(syntax) else execution_index(inputs)
    executable_parts = {id(part): execution[path] for path, part in inputs.items()}

    def can_render(part: dict, start: int) -> bool:
        return call_can_execute(executable_parts[id(part)], {"start": start})

    hidden_ranges = {
        id(part): [bounds for branch in part.get("controlFlow", []) + part.get("expressionFlow", [])
            for bounds in [branch.get(key) for key in ("thenRange", "elseRange", "deadRange", "followingRange")]
                + branch.get("branchRanges", [])
            if bounds and not can_render(part, bounds[0])]
        for part, _ in parts
    }

    def rendered_node(part: dict, item: dict) -> dict:
        start, value = item.get("start", -1), item.get("value")
        if start < 0 or not isinstance(value, str):
            return item
        raw = bytearray(value.encode())
        for lower, upper in hidden_ranges[id(part)]:
            lower, upper = max(lower, start), min(upper, start + len(raw))
            if lower < upper and not can_render(part, lower):
                raw[lower - start:upper - start] = b" " * (upper - lower)
        return dict(item, value=raw.decode())

    def containing_function(part: dict, start: int) -> dict | None:
        candidates = [
            item for owner, item in functions
            if owner is part and item["start"] <= start < item["end"]
        ]
        return min(candidates, key=lambda item: item["end"] - item["start"]) if candidates else None

    def in_callback(part: dict, start: int) -> bool:
        return any(
            item["scope"] == scope and item["start"] <= start < item["end"]
            for item in part.get("nonRenderedRanges", [])
        )

    reachable: set[tuple[int, str, int, int]] = set()
    changed = True
    while changed:
        changed = False
        for part, is_root in parts:
            for call in part.get("calls", []):
                call_start = call.get("start", -1)
                if call["scope"] != scope or in_callback(part, call_start) or not can_render(part, call_start):
                    continue
                owner = containing_function(part, call_start)
                if owner:
                    owner_key = (id(part), owner["name"], owner["start"], owner["end"])
                    if owner_key not in reachable:
                        continue
                elif not is_root:
                    continue
                called_name = call["value"].rsplit(".", 1)[-1].split("<", 1)[0]
                candidates = [item for _, item in functions if item["name"] == called_name]
                if len(candidates) != 1 or not candidates[0].get("returnsView", False):
                    continue
                function = candidates[0]
                function_part = next(part for part, item in functions if item is function)
                key = (id(function_part), function["name"], function["start"], function["end"])
                if key not in reachable:
                    reachable.add(key)
                    changed = True

    def is_visible(part: dict, is_root: bool, item: dict) -> bool:
        if item.get("scope") != scope or in_callback(part, item.get("start", -1)) or not can_render(part, item.get("start", -1)):
            return False
        owner = containing_function(part, item.get("start", -1))
        if owner is None:
            return is_root
        return (id(part), owner["name"], owner["start"], owner["end"]) in reachable

    filtered = dict(facts)
    filtered.pop("renderedScopeFacts", None)
    for collection in (
        "calls", "invocations", "members", "expressions", "bindings",
        "controlFlow", "typeNames", "stringSegments",
    ):
        filtered[collection] = [
            rendered_node(part, item)
            for part, is_root in parts
            for item in part.get(collection, [])
            if is_visible(part, is_root, item)
        ]
    if memo is not None:
        memo[key] = filtered
    return filtered


def rendered_view_has_marker(
    facts: dict, scope: list[str], marker: str, syntax: dict[str, dict] | None = None
) -> bool:
    return ast_has_marker(rendered_scope_facts(facts, scope, syntax), marker, scope)


def view_or_child_has_marker(
    syntax: dict[str, dict],
    facts: dict,
    scope: list[str],
    marker: str,
    visited: set[tuple[int, tuple[str, ...]]] | None = None,
) -> bool:
    visible_facts = rendered_scope_facts(facts, scope, syntax)
    if ast_has_marker(visible_facts, marker, scope):
        return True
    visited = set() if visited is None else visited
    identity = (id(facts), tuple(scope))
    if identity in visited:
        return False
    visited.add(identity)
    child_calls = {
        call["value"]
        for call in visible_facts["calls"]
        if call["scope"] == scope
    }
    for child_call in child_calls:
        for _, child_facts, child_scope in child_view_entries(syntax, child_call, scope):
            if view_or_child_has_marker(syntax, child_facts, child_scope, marker, visited):
                return True
    return False


def image_only_button_findings(path: Path, facts: dict) -> list[str]:
    return [
        f"{path}: {'.'.join(invocation['scope'])} 图片型操作控件需提供 accessibilityLabel"
        f"（{invocation['value'][:96].replace(chr(10), ' ')}）"
        for invocation in image_only_label_facts(facts)
    ]


def selection_control_has_feedback(control: dict, modifiers: list[dict]) -> bool:
    prefix = re.compile(rf"^(?:SwiftUI\.)?{re.escape(control['name'])}\s*\(")
    return any(
        modifier["name"] == "appSelectionFeedback"
        and modifier["scope"] == control["scope"]
        and prefix.search(modifier["base"].lstrip())
        and control["invocation"] in modifier["base"]
        for modifier in modifiers
    )


def list_has_grouped_style(control: dict, modifiers: list[dict]) -> bool:
    return any(
        modifier["name"] == "appGroupedListStyle"
        and modifier["scope"] == control["scope"]
        and modifier["baseStart"] == control["start"]
        and modifier["base"].lstrip().startswith(control["invocation"])
        for modifier in modifiers
    )


def call_name(value: str) -> str:
    name = value.rsplit(".", 1)[-1]
    return name.split("<", 1)[0]


CALL_RULE_NAMES = {
    DIRECT_ROUNDED_RECTANGLE: {"RoundedRectangle"},
    DIRECT_CORNER_RADIUS: {"cornerRadius"},
    DIRECT_SYSTEM_COLOR: {"Color"},
    DIRECT_OPACITY_LITERAL: {"opacity"},
    DIRECT_FOREGROUND_STYLE: {"foregroundStyle"},
    DIRECT_FONT_MODIFIER: {"font"},
    DIRECT_GRID_ITEM_GEOMETRY: {"GridItem"},
    DIRECT_STROKE_GEOMETRY: {"StrokeStyle"},
    DIRECT_BLUR_GEOMETRY: {"blur"},
    DIRECT_THUMBNAIL_GEOMETRY: {"thumbnailButton"},
    DIRECT_FLOATING_SIZE: {"frame"},
    DIRECT_TOUCH_TARGET: {"frame"},
    DIRECT_FLOATING_MATERIAL: {"background"},
    DIRECT_GROUPED_LIST_STYLE: {"listStyle"},
    DIRECT_PLAIN_LIST_STYLE: {"listStyle"},
    DIRECT_LIST_SECTION_SPACING: {"listSectionSpacing"},
    DIRECT_INPUT_PLACEHOLDER: {"TextField", "SecureField"},
    DIRECT_CUSTOM_SECTION_HEADER: {"Section"},
    DIRECT_ANIMATION_DURATION: {"withAnimation", "animation"},
    DIRECT_BARE_HSTACK: {"HStack"},
    DIRECT_HSTACK_LITERAL: {"HStack"},
    DIRECT_FRAME_LITERAL: {"frame"},
    DIRECT_EDGE_INSETS_LITERAL: {"EdgeInsets"},
}


MEMBER_RULES = {
    DIRECT_ACCENT_COLOR,
    DIRECT_HIERARCHICAL_COLOR,
    *(pattern for pattern, _ in DIRECT_SEMANTIC_COLOR_RULES),
}


BINDING_RULES = {DIRECT_OPACITY_ASSIGNMENT, DIRECT_LOCAL_CGFLOAT_LITERAL}


EXPRESSION_RULES = {DERIVED_DESIGN_TOKEN, REPEATED_DESIGN_TOKEN}


SPACING_CALL_NAMES = {"padding", "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack"}


def pattern_nodes(facts: dict, pattern: re.Pattern[str]) -> list[dict]:
    if pattern in CALL_RULE_NAMES:
        names = CALL_RULE_NAMES[pattern]
        return [
            invocation
            for invocation in facts.get("invocations", [])
            if call_name(invocation["calledExpression"]) in names
        ]
    if pattern is PADDING_LITERAL or pattern is STACK_SPACING_LITERAL:
        names = {"padding"} if pattern is PADDING_LITERAL else SPACING_CALL_NAMES
        return [
            invocation
            for invocation in facts.get("invocations", [])
            if call_name(invocation["calledExpression"]) in names
        ]
    if pattern in MEMBER_RULES:
        return facts.get("members", [])
    if pattern in BINDING_RULES:
        return facts.get("bindings", [])
    if pattern in EXPRESSION_RULES:
        return facts.get("expressions", [])
    return []


def pattern_line_number(source: str, node: dict, local_position: int) -> int:
    byte_start = max(0, int(node.get("start", 0)))
    prior_lines = source.encode("utf-8")[:byte_start].count(b"\n")
    local_lines = node["value"][:local_position].count("\n")
    return prior_lines + local_lines + 1


def is_semantic_color_member(path: str, node: dict, context) -> bool:
    """Apply palette rules to color members in their declared or SwiftUI argument context."""
    value = mask_literals_and_comments(node['value']).strip()
    if not re.fullmatch(r'(?:[A-Za-z_]\w*\s*\.)*\s*\.?[A-Za-z_]\w*', value): return False
    facts = context.index[path]
    def is_color(kind):
        return any(context.types.terminal_name(source, name, scope) in
            {'Color', 'SwiftUI.Color', 'ShapeStyle', 'SwiftUI.ShapeStyle'}
            for source, name, scope in context.types.components(path, kind, node['scope'], node))
    if not value.startswith('.'):
        kind = context.receiver_type(node, path)
        if kind is None and value.rpartition('.')[0] == 'SwiftUI.Color': kind = 'SwiftUI.Color'
        return is_color(kind or '')
    expected = expected_argument_types(facts, node, context=context, path=path)
    if expected: return any(is_color(kind) for kind in expected)
    parents = [(call, index) for call in facts.get('invocations', [])
        for index, bounds in enumerate(call.get('argumentRanges') or [])
        if bounds[0] <= node['start'] < bounds[1]]
    if parents:
        call, index = min(parents, key=lambda entry: len(entry[0]['value'].encode()))
        labels = call.get('argumentLabels') or []
        name = call_name(call['calledExpression'])
        if index == 0 and name in {'foregroundStyle', 'foregroundColor', 'tint', 'background',
                'overlay', 'fill', 'stroke', 'strokeBorder', 'border', 'listRowBackground'}: return True
        if name == 'shadow' and labels[index] == 'color': return True
        return False
    for binding in facts.get('bindings', []):
        if binding['start'] <= node['start'] < binding['start'] + len(binding['value'].encode()):
            initializer = binding['value'].partition('=')[2].strip()
            if initializer.strip('() ') == value and binding.get('bindingType'):
                return is_color(binding['bindingType'])
    returns = [entry for entry in facts.get('functionReturns', [])
        if entry['start'] == node['start'] and entry['value'].strip() == value]
    return any(is_color(function.get('returnType') or '') for function in
        facts.get('functionRanges', []) + facts.get('accessorRanges', [])
        if function['start'] <= node['start'] < function['end']
        and any(entry['name'] == function['name'] and entry['scope'] == function['scope'] for entry in returns))


def append_rule_finding(
    errors: list[str],
    emitted: set[tuple[str, int, str]],
    path: Path,
    line: int,
    message: str,
    pattern: re.Pattern[str],
) -> None:
    key = (pattern.pattern, line, message)
    if key in emitted:
        return
    emitted.add(key)
    errors.append(f"{path}:{line}: {message}")


def image_only_label_facts(facts: dict) -> list[dict]:
    """Collect image-only interactive expressions that need an accessible name."""
    results: list[dict] = []
    for control in facts.get("accessibilityControls", []):
        source = mask_literals_and_comments(control["label"])
        if not re.search(r"\bImage\s*\(", source):
            continue
        if re.search(r"\b(?:Text|Label)\s*\(", source):
            continue
        if control.get("hasTextTitle"):
            continue
        if any(
            modifier["name"] == "accessibilityLabel"
            and modifier["scope"] == control["scope"]
            and (
                modifier.get("baseStart", -1) == control["start"]
                or control.get("labelStart", -1) <= modifier.get("baseStart", -1) < control.get("labelEnd", -1)
            )
            for modifier in facts.get("accessibilityModifiers", [])
        ):
            continue
        results.append({"scope": control["scope"], "value": control["invocation"]})
    return results


def explanatory_text_report() -> None:
    from ui_explanatory_text import write_report
    write_report(ROOT)


class ViewHelperGraph:
    def __init__(self, index, types):
        from swift_type_index import compilation_unit
        self.index, self.types = index, types
        self.units = {path: compilation_unit(path) for path in index}
        self.named = {}
        for path, facts in index.items():
            for function in facts.get('functionRanges', []):
                if not function['scope'] and function.get('bodyStart') is not None:
                    self.named.setdefault((self.units[path], function['name']), []).append((path, function))
        self.owners = {path: {owner for owner, bases in types.conformances(path).items()
            if any(base.rsplit('.', 1)[-1] in {'View', 'ViewModifier', 'App', 'Scene'} for base in bases)} for path in index}
        self.factories = {path: {(path, function['bodyStart'], function['end']) for function in facts.get('functionRanges', [])
            if function.get('returnsView') and function.get('bodyStart') is not None} for path, facts in index.items()}
        self.calls, self.roots, self.edges, self.results = {}, {}, {}, {}

    def targets(self, path, call):
        from network_capability_rules import matching_api_calls
        key = (path, call['start'])
        if key not in self.calls:
            prefix, _, name = call['calledExpression'].rpartition('.')
            candidates = [(source, function) for source, function in self.named.get((self.units[path], name), [])
                if (not prefix or prefix == self.units[path])
                and (not function.get('isFilePrivate') or source == path) and (
                    not function.get('lexicalScope') or source == path
                    and call.get('lexicalScope', [])[:len(function['lexicalScope'])] == function['lexicalScope'])]
            self.calls[key] = {(source, function['bodyStart'], function['end']) for source, function in matching_api_calls(
                self.index, candidates, dict(call, path=path), types=self.types, conservative=True)} if candidates else set()
        return self.calls[key]

    def seeds(self, path):
        if path not in self.roots:
            result = set(self.factories[path])
            for call in self.index[path].get('invocations', []):
                if scope_contains_type(call['scope'], self.owners[path]) or any(
                        start <= call['start'] < end for _, start, end in self.factories[path]):
                    result.update(self.targets(path, call))
            self.roots[path] = result
        return self.roots[path]

    def successors(self, key):
        if key not in self.edges:
            path, start, end = key
            self.edges[key] = set().union(*(self.targets(path, call) for call in self.index[path].get('invocations', [])
                if start <= call['start'] < end))
        return self.edges[key]

    def ranges(self, origin):
        if origin not in self.results:
            reachable = set().union(*(self.seeds(path) for path in self.index if origin is None or path == origin))
            pending = list(reachable)
            while pending:
                for target in self.successors(pending.pop()) - reachable:
                    reachable.add(target); pending.append(target)
            result = {path: set() for path in self.index}
            for path, start, end in reachable: result[path].add((start, end))
            self.results[origin] = result
        return self.results[origin]


def view_helper_ranges(index: dict, types, *, origin=None) -> dict[str, set[tuple[int, int]]]:
    """Resolve reachable helper edges once per audit and share ranges by source."""
    graph = getattr(types, '_view_helpers', None)
    if graph is None or graph.index is not index:
        graph = ViewHelperGraph(index, types)
        types._view_helpers = graph
    return graph.ranges(origin)


def view_transport_findings(index: dict) -> list[str]:
    from swift_type_index import SwiftTypeIndex, SwiftBindingTypes, receiver_resolver
    from network_capability_rules import NETWORK_TRANSPORT_TYPES, NETWORK_TRANSPORT_METHODS, transport_method
    types = SwiftTypeIndex(index)
    bindings = SwiftBindingTypes(index, types)
    resolve = receiver_resolver(index)
    errors = []
    helpers = view_helper_ranges(index, types)
    for path, facts in index.items():
        if not Path(path).relative_to(ROOT).as_posix().startswith(('BIT101-iOS/', 'Modules/', 'BIT101ScheduleWidgets/', 'BIT101WatchWidgets/', 'BIT101Watch/')): continue
        owners = {owner for owner, bases in types.conformances(path).items()
            if any(base.rsplit('.', 1)[-1] in {'View', 'ViewModifier', 'App', 'Scene'} for base in bases)}
        factories = [fn for fn in facts.get('functionRanges', []) if fn.get('returnsView') and fn.get('bodyStart') is not None]
        invocations = facts.get('invocations', [])
        invoked = {call['start'] for call in invocations}
        references = [dict(member, calledExpression=member['value']) for member in facts.get('members', [])
            if member['start'] not in invoked]
        for call in [*invocations, *references]:
            if not scope_contains_type(call['scope'], owners) and not any(
                    fn['bodyStart'] <= call['start'] < fn['end'] for fn in factories) and not any(
                    start <= call['start'] < end for start, end in helpers.get(path, set())): continue
            method = transport_method(call['calledExpression'])
            if method not in NETWORK_TRANSPORT_METHODS: continue
            owner = resolve(dict(call, path=path))
            kind = owner or bindings.receiver_type(call, path) or ''
            target = types.resolve(path, kind, call['scope'])
            if kind.rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES or target and any(
                    base.rsplit('.', 1)[-1] == 'HTTPTransport' for base in types.bases(target)):
                line = facts['source'].encode()[:call['start']].count(b'\n') + 1
                errors.append(f'{Path(path).relative_to(ROOT).as_posix()}:{line}: 视图网络传输沿注入的业务服务执行')
    return list(dict.fromkeys(errors))
