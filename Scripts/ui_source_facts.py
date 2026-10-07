"""Swift source facts for shared UI and design rules."""
from __future__ import annotations

from pathlib import Path
from functools import cache
import importlib.util
import re
import sys

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


SOURCE_ROOTS = (SOURCE_ROOT, ROOT / "Modules")


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


LITERAL_OR_COMMENT_START = re.compile(r'//|/\*|#+"|"')


def _blank_segment(output: list[str], source: str, start: int, end: int) -> None:
    end = min(end, len(source))
    output[start:end] = ("\n" if character == "\n" else " " for character in source[start:end])


@cache
def mask_comments(source: str) -> str:
    """移除注释并保留字符串，供需要识别 UI 文案结构的规则使用。"""
    output = list(source)
    index = 0
    depth = 0
    while index < len(source):
        if depth:
            if source.startswith("/*", index):
                depth += 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                depth -= 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            else:
                _blank_segment(output, source, index, index + 1)
                index += 1
            continue

        raw_match = re.match(r'(#+)("{1,3})', source[index:]) if source[index] == "#" else None
        if raw_match:
            hashes, quote = raw_match.groups()
            terminator = quote + hashes
            content_start = index + len(hashes) + len(quote)
            end = source.find(terminator, content_start)
            index = len(source) if end < 0 else end + len(terminator)
            continue
        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            index = len(source) if end < 0 else end + 3
            continue
        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            continue

        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            _blank_segment(output, source, index, end)
            index = end
        elif source.startswith("/*", index):
            depth = 1
            _blank_segment(output, source, index, index + 2)
            index += 2
        else:
            next_token = LITERAL_OR_COMMENT_START.search(source, index + 1)
            index = next_token.start() if next_token else len(source)
    return "".join(output)


@cache
def mask_literals_and_comments(source: str) -> str:
    """保留换行，忽略字符串和注释，避免文案伪造 UI 契约。"""
    output = list(source)
    index = 0
    comment_depth = 0
    while index < len(source):
        if comment_depth:
            if source.startswith("/*", index):
                comment_depth += 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                comment_depth -= 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            else:
                _blank_segment(output, source, index, index + 1)
                index += 1
            continue

        raw_match = re.match(r"(#+)(\"{1,3})", source[index:]) if source[index] == "#" else None
        if raw_match:
            hashes, quote = raw_match.groups()
            terminator = quote + hashes
            content_start = index + len(hashes) + len(quote)
            end = source.find(terminator, content_start)
            end = len(source) if end < 0 else end + len(terminator)
            _blank_segment(output, source, index, end)
            index = end
            continue

        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            end = len(source) if end < 0 else end + 3
            _blank_segment(output, source, index, end)
            index = end
            continue

        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    _blank_segment(output, source, index, index + 2)
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    _blank_segment(output, source, index, index + 1)
                    index += 1
            continue

        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            _blank_segment(output, source, index, end)
            index = end
            continue
        if source.startswith("/*", index):
            comment_depth = 1
            _blank_segment(output, source, index, index + 2)
            index += 2
            continue

        next_token = LITERAL_OR_COMMENT_START.search(source, index + 1)
        index = next_token.start() if next_token else len(source)
    return "".join(output)


def is_view_source(path: Path, code: str) -> bool:
    if path.name.endswith(("View.swift", "Views.swift", "Screen.swift", "Screens.swift")):
        return True
    return re.search(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b",
        code,
    ) is not None


@cache
def swift_files() -> list[Path]:
    return sorted(
        path
        for source_root in SOURCE_ROOTS
        if source_root.is_dir()
        for path in source_root.rglob("*.swift")
    )


@cache
def source_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def syntax_index() -> dict[str, dict]:
    checker = ROOT / "Scripts/check-code-quality.py"
    spec = importlib.util.spec_from_file_location("check_code_quality", checker)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"SwiftSyntax 索引器加载失败：{checker}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.swift_syntax_index(module.swift_files())


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
                if call["scope"] != scope or in_callback(part, call_start):
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
        if item.get("scope") != scope or in_callback(part, item.get("start", -1)):
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
            item
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
            for call, invocation in zip(facts.get("calls", []), facts.get("invocations", []))
            if call_name(call["value"]) in names
        ]
    if pattern is PADDING_LITERAL or pattern is STACK_SPACING_LITERAL:
        names = {"padding"} if pattern is PADDING_LITERAL else SPACING_CALL_NAMES
        return [
            invocation
            for call, invocation in zip(facts.get("calls", []), facts.get("invocations", []))
            if call_name(call["value"]) in names
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
