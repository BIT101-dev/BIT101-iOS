"""Shared UI, accessibility and design rule checks."""
from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys

from ui_design_contracts import (
    COMPONENT_GROUPS, COMPONENT_INHERITANCE, CONTEXTUAL_COLOR_BYPASSES, DERIVED_DESIGN_TOKEN,
    DIRECT_FLOATING_MATERIAL, DIRECT_GRID_ITEM_GEOMETRY, DIRECT_GROUPED_LIST_STYLE,
    DIRECT_INPUT_PLACEHOLDER, DIRECT_LIST_SECTION_SPACING, DIRECT_LOCAL_CGFLOAT_LITERAL,
    DIRECT_OPACITY_ASSIGNMENT, DIRECT_OPACITY_LITERAL, DIRECT_PLAIN_LIST_STYLE,
    DIRECT_SEMANTIC_COLOR_RULES, DIRECT_STROKE_GEOMETRY, DIRECT_THUMBNAIL_GEOMETRY,
    DIRECT_VISUAL_RULES, FIXED_GEOMETRY_CONTRACTS, LOCAL_APP_ALERT_BINDINGS, PADDING_LITERAL,
    PAGE_THEME_CONTRACTS, PAGE_THEME_RULES, PLAIN_LIST_EXCEPTIONS, REPEATED_DESIGN_TOKEN,
    STACK_SPACING_LITERAL, THEME_SENSITIVE_ROOTS,
)

from ui_source_facts import (
    DESIGN_SYSTEM, DESIGN_SYSTEM_SOURCES, MAP_THEME_COLOR_CONTRACT, PRIMITIVE_OPACITY_SOURCE,
    REPORT_PATH, ROOT, append_rule_finding, call_name, child_view_entries,
    has_component_declaration, image_only_label_facts, list_has_grouped_style, list_icon_findings,
    mask_comments, mask_literals_and_comments, path_is_in_source_root, pattern_line_number,
    pattern_nodes, rendered_scope_facts, rendered_view_has_marker, selection_control_has_feedback,
    source_path, source_relative, source_text, swift_files, syntax_index, view_entries,
    view_or_child_has_marker, view_scopes,
)


def check_component_contracts(errors: list[str], syntax: dict[str, dict]) -> None:
    sources = {path: source_text(path) for path in swift_files()}
    code_sources = {path: mask_literals_and_comments(source) for path, source in sources.items()}
    comment_free_sources = {path: mask_comments(source) for path, source in sources.items()}

    # Public component existence comes from declaration nodes, independent of comments and strings.
    component_declarations = [
        declaration
        for path, facts in syntax.items()
        if path_is_in_source_root(path, ROOT)
        for declaration in facts["declarations"]
    ]
    for group, symbols in COMPONENT_GROUPS:
        for symbol in symbols:
            if not has_component_declaration(symbol, component_declarations):
                expected = COMPONENT_INHERITANCE[symbol]
                requirement = "struct" if expected is None else f"struct: {expected}"
                errors.append(f"公共组件组「{group}」缺少符合 {requirement} 的 {symbol}")

    # 首屏文字加载状态必须走公共状态组件；按钮内的无文字进度条仍可保留。
    for path in swift_files():
        if path == ROOT / "Modules/DesignSystemKit/Sources/AppStateComponents.swift":
            continue
        source = comment_free_sources[path]
        if re.search(r"\bProgressView\s*\(\s*\"", source):
            errors.append(f"{str(path.relative_to(ROOT))}: 首屏文字加载状态必须使用 AppLoadingState/AppInlineLoadingState")

    # 页面级公共规则按语义模式发现。
    for path, source in code_sources.items():
        facts = syntax[str(path)]
        for scope in view_scopes(facts):
            scoped_identifiers = {
                item["value"]
                for item in facts["scopedIdentifiers"]
                if item["scope"] == scope
            }
            if scoped_identifiers & {"List", "Form", "Section"} and "ContentUnavailableView" in scoped_identifiers:
                if not any(
                    view_or_child_has_marker(syntax, facts, scope, marker)
                    for marker in ("AppFailureState", "AppEmptyState")
                ):
                    errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 页面状态必须使用公共空态/失败态组件")
            if re.search(r"\b(?:Gallery|Paper|Course|Mine|Settings)\b", str(path)) and any(
                identifier.lower() == "avatar" for identifier in scoped_identifiers
            ):
                if not view_or_child_has_marker(syntax, facts, scope, "AppAvatarView") and "AppAvatarComponents.swift" not in str(path):
                    errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 头像页面必须使用 AppAvatarView")

    # 列表/表单内的图标按语法树调用关系审计，跨行参数与闭包仍保持归属。
    for path in swift_files():
        errors.extend(list_icon_findings(path.relative_to(ROOT), syntax[str(path)]))

    direct_states = [
        str(path.relative_to(ROOT))
        for path in swift_files()
        if "ContentUnavailableView" in syntax[str(path)]["identifiers"]
        and "AppStateComponents.swift" not in str(path)
    ]
    errors.extend(f"页面不得直接实现空态/失败态：{item}" for item in direct_states)


def check_haptic_consistency(errors: list[str], syntax: dict[str, dict]) -> None:
    sources = {path: mask_literals_and_comments(source_text(path)) for path in swift_files()}
    required = (
        ("Modules/DesignSystemKit/Sources/AppHapticFeedback.swift", "func appSelectionFeedback"),
        ("Modules/DesignSystemKit/Sources/AppHapticFeedback.swift", "sensoryFeedback(.selection, trigger:"),
        ("Modules/DesignSystemKit/Sources/AppHapticFeedback.swift", "func appImpactFeedback"),
        ("Modules/DesignSystemKit/Sources/AppHapticFeedback.swift", "sensoryFeedback(.impact, trigger:"),
        ("Modules/DesignSystemKit/Sources/AppLayoutComponents.swift", "appImpactFeedback"),
        ("Modules/DesignSystemKit/Sources/AppContentControlComponents.swift", "appSelectionFeedback"),
        ("Shell/AppShellView.swift", "appSelectionFeedback"),
        ("Modules/ScheduleFeature/Sources/ScheduleCalendarViews.swift", "appSelectionFeedback"),
        ("Modules/ScheduleFeature/Sources/ScheduleCalendarViews.swift", "appImpactFeedback"),
        ("Modules/MapFeature/Sources/CampusMapScreen.swift", "appImpactFeedback"),
    )
    for relative_path, marker in required:
        path = source_path(relative_path)
        if marker not in sources.get(path, ""):
            errors.append(f"{path.relative_to(ROOT)}: 缺少系统触感入口 {marker}")

    interactive_markers = {
        "toggleTag", "selectedTags", "setRating", "selectedValues", "sortIndex",
        "sortOrder", "onToggleDone",
    }
    for path, source in sources.items():
        facts = syntax[str(path)]
        for control in facts["selectionControls"]:
            if not selection_control_has_feedback(control, facts["feedbackModifiers"]):
                errors.append(
                    f"{path.relative_to(ROOT)}: {control['name']} 控件必须由自身表达式接入 appSelectionFeedback"
                )

        for scope in view_scopes(facts):
            identifiers = {
                item["value"]
                for item in facts["scopedIdentifiers"]
                if item["scope"] == scope
            }
            if not identifiers & interactive_markers:
                continue
            if not view_or_child_has_marker(syntax, facts, scope, "appSelectionFeedback"):
                errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 选择交互缺少公共触感修饰器")

    multiselection_entries = view_entries(syntax, "AppMultiSelectionList")
    if not multiselection_entries:
        errors.append("AppMultiSelectionList: 公共多选列表 View 声明缺失")
    for path, facts, scope in multiselection_entries:
        if not rendered_view_has_marker(facts, scope, "appSelectionFeedback", syntax):
            errors.append(f"{path.relative_to(ROOT)}: AppMultiSelectionList 必须为选择变化提供公共触感")

    button_components = (
        ("Modules/DesignSystemKit/Sources/AppLayoutComponents.swift", "struct AppFloatingActionButton: View"),
        ("Modules/MapFeature/Sources/CampusMapScreen.swift", "struct FloatingMapLabelButton: View"),
    )
    for relative_path, declaration in button_components:
        source = sources.get(source_path(relative_path), "")
        start = source.find(declaration)
        if start < 0 or "appImpactFeedback" not in source[start:]:
            errors.append(f"{relative_path}: 右下角操作按钮缺少公共触感")

    direct_patterns = re.compile(
        r"\.sensoryFeedback\(|UIFeedbackGenerator|UI(Selection|Impact|Notification)FeedbackGenerator|"
        r"impactOccurred\(|selectionChanged\(|notificationOccurred\(|AudioServicesPlaySystemSound|"
        r"kSystemSoundID_Vibrate|CHHapticEngine|NSHapticFeedbackManager|WKInterfaceDevice.*\.play"
    )
    haptic_file = ROOT / "Modules/DesignSystemKit/Sources/AppHapticFeedback.swift"
    for path, source in sources.items():
        if path != haptic_file and direct_patterns.search(source):
            errors.append(f"{path.relative_to(ROOT)}: 页面不得绕过公共触感修饰器")

        for match in re.finditer(r"\.app[A-Za-z]+Feedback\(", source):
            name = match.group(0)
            if name not in (".appSelectionFeedback(", ".appImpactFeedback("):
                errors.append(f"{path.relative_to(ROOT)}: 发现未登记的公共触感调用 {name}")

        if path != haptic_file and re.search(r"func app(?:Selection|Impact)Feedback", source):
            errors.append(f"{path.relative_to(ROOT)}: 公共触感接口不得重复声明")


def alert_coverage_findings(facts: dict, path: Path) -> list[str]:
    app_alert_variables = [
        variable
        for variable in facts.get("typedVariables", [])
        if re.search(r"\bAppAlert\b", variable["type"])
    ]
    findings: list[str] = []
    diagnostic_bindings: set[tuple[tuple[str, ...], str]] = set()
    for call, invocation in zip(facts.get("calls", []), facts.get("invocations", [])):
        if call["value"].split(".")[-1] != "diagnosticAlert":
            continue
        source = mask_literals_and_comments(invocation["value"])
        for variable in app_alert_variables:
            if variable["scope"] != invocation["scope"]:
                continue
            binding = re.compile(rf"\bitem\s*:\s*\${re.escape(variable['name'])}\b")
            if binding.search(source):
                diagnostic_bindings.add((tuple(variable["scope"]), variable["name"]))

    for alert in facts.get("alertModifiers", []):
        item_binding = ""
        for label, argument in zip(alert["labels"], alert["arguments"]):
            if label == "item":
                match = re.fullmatch(r"\$([A-Za-z_][A-Za-z0-9_]*)", argument.strip())
                item_binding = match.group(1) if match else ""
                break

        used_variables = {
            variable["name"]
            for variable in app_alert_variables
            if variable["scope"] == alert["scope"]
            and variable["name"] in alert.get("identifiers", [])
        }
        if item_binding and any(
            variable["name"] == item_binding and variable["scope"] == alert["scope"]
            for variable in app_alert_variables
        ):
            used_variables.add(item_binding)

        for variable_name in sorted(used_variables):
            if (tuple(alert["scope"]), variable_name) in diagnostic_bindings:
                continue
            view_name = alert["scope"][-1] if alert["scope"] else ""
            exact_local_exception = (
                view_name, variable_name
            ) in LOCAL_APP_ALERT_BINDINGS and item_binding == variable_name
            if exact_local_exception:
                continue
            findings.append(
                f"{path}: {'.'.join(alert['scope'])} 的 AppAlert「{variable_name}」"
                "必须通过 diagnosticAlert 展示"
            )
    return findings


def check_error_report_coverage(errors: list[str], syntax: dict[str, dict]) -> None:
    schedule_notice_presenters = 0
    for path in swift_files():
        source = mask_literals_and_comments(source_text(path))
        schedule_notice_presenters += len(re.findall(r"\bscheduleViewModel\.\$notice\.compactMap", source))
        facts = syntax[str(path)]
        errors.extend(alert_coverage_findings(facts, path.relative_to(ROOT)))
        for scope in view_scopes(facts):
            failed_states = [
                flow["value"]
                for flow in facts["controlFlow"]
                if flow["scope"] == scope
                and re.search(r"(?:case|if case|else if case) let \.failed\(message\)", flow["value"])
                and "ContentUnavailableView" in flow["value"]
            ]
            if any(
                "DiagnosticRecoveryActions" not in flow and "PaperEmptyState" not in flow
                for flow in failed_states
            ):
                errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 失败态缺少错误报告入口")

    if schedule_notice_presenters != 1:
        errors.append(f"日程共享错误展示器数量异常：引用数 {schedule_notice_presenters}")


def check_fonts(errors: list[str], syntax: dict[str, dict]) -> None:
    swift_explicit_font_size = re.compile(
        r"(?:\bFont\.system|\.system)\s*\(\s*size\s*:\s*(?P<value>[^,\)\n]+)"
    )
    ui_explicit_font_size = re.compile(
        r"\bUIFont\.systemFont\s*\(\s*ofSize\s*:\s*(?P<value>[^,\)\n]+)"
    )
    custom_font = re.compile(r"\bFont\.custom\s*\(")

    for path_string, facts in syntax.items():
        path = Path(path_string)
        if not path.is_file():
            continue
        raw_source = source_text(path)
        relative = path.relative_to(ROOT)
        if path not in DESIGN_SYSTEM_SOURCES:
            for call, invocation in zip(facts.get("calls", []), facts.get("invocations", [])):
                name = call_name(call["value"])
                if name not in {"system", "systemFont", "custom"}:
                    continue
                source = mask_literals_and_comments(invocation["value"])
                if name == "system":
                    for match in swift_explicit_font_size.finditer(source):
                        value = match.group("value").strip()
                        if "AppDesignSystem." not in value:
                            line = pattern_line_number(raw_source, invocation, match.start())
                            errors.append(
                                f"{relative}:{line}: 字体字号必须使用设计系统令牌或系统语义字体：{value}"
                            )
                if name == "systemFont":
                    for match in ui_explicit_font_size.finditer(source):
                        value = match.group("value").strip()
                        if "AppDesignSystem." not in value:
                            line = pattern_line_number(raw_source, invocation, match.start())
                            errors.append(
                                f"{relative}:{line}: UIFont 字号必须使用设计系统令牌或系统语义字体：{value}"
                            )
                if name == "custom" and custom_font.search(source):
                    errors.append(f"{relative}:{pattern_line_number(raw_source, invocation, 0)}: 字体采用系统语义或公共令牌")


def check_design_token_boundaries(errors: list[str], syntax: dict[str, dict]) -> None:
    """透明度数字只允许存在于跨 target 基础刻度层。"""
    for path in swift_files():
        if path == PRIMITIVE_OPACITY_SOURCE:
            continue
        raw_source = source_text(path)
        facts = syntax[str(path)]
        relative = path.relative_to(ROOT)
        emitted: set[tuple[str, int, str]] = set()
        for pattern, message in (
            (DIRECT_OPACITY_LITERAL, "透明度数字必须通过 AppDesignSystem.Opacity 派生"),
            (DIRECT_OPACITY_ASSIGNMENT, "透明度标量必须引用 AppDesignSystem.Opacity"),
        ):
            for node in pattern_nodes(facts, pattern):
                source = mask_literals_and_comments(node["value"])
                for match in pattern.finditer(source):
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(errors, emitted, relative, line_number, message, pattern)


def check_page_theme_consistency(errors: list[str], syntax: dict[str, dict]) -> None:
    """页面强调色必须使用所属模块的主题令牌。"""
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        relative_source = source_relative(path)
        raw_source = source_text(path)
        facts = syntax[str(path)]
        for prefixes, forbidden_tokens, expected_token in PAGE_THEME_RULES:
            if not relative_source.startswith(prefixes):
                continue
            emitted: set[tuple[int, str]] = set()
            for token in forbidden_tokens:
                for node in facts.get("members", []):
                    if token not in node["value"]:
                        continue
                    line_number = pattern_line_number(raw_source, node, 0)
                    marker = (line_number, token)
                    if marker in emitted:
                        continue
                    emitted.add(marker)
                    errors.append(
                        f"{path.relative_to(ROOT)}:{line_number}: 页面主题色应使用 {expected_token}，当前发现 {token}"
                    )


def check_contextual_component_colors(errors: list[str], syntax: dict[str, dict]) -> None:
    """复用内容与组件使用页面强调色，避免绕过环境 tint 的固定高亮色。"""
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        relative_source = source_relative(path)
        if not any(
            relative_source == root or relative_source.startswith(f"{root}/")
            for root in THEME_SENSITIVE_ROOTS
        ):
            continue

        raw_source = source_text(path)
        facts = syntax[str(path)]
        for token, expected_token in CONTEXTUAL_COLOR_BYPASSES:
            emitted: set[int] = set()
            for node in facts.get("members", []):
                if token not in node["value"]:
                    continue
                line_number = pattern_line_number(raw_source, node, 0)
                if line_number in emitted:
                    continue
                emitted.add(line_number)
                errors.append(
                    f"{path.relative_to(ROOT)}:{line_number}: "
                    f"复用组件的页面主题色应使用 {expected_token}，当前发现 {token}"
                )


def is_interactive_list_row(row: dict, facts: dict) -> bool:
    if row["name"] == "LabeledContent":
        return False
    if any(item["scope"] == row["scope"] and item["start"] <= row["start"] < item["end"]
           for item in facts.get("nonRenderedRanges", [])):
        return False
    if set(row.get("containers", [])) & {"List", "Form", "Section"}:
        return True
    # 按列表引用追踪返回 View 的属性和函数，核对实际渲染的交互行。
    helpers = []
    for binding in facts.get("bindings", []):
        match = re.match(r"(\w+)\s*:\s*some\s+View\s*\{", mask_literals_and_comments(binding["value"]))
        if match and binding["scope"] == row["scope"]:
            helpers.append({"name": match[1], "start": binding["start"],
                            "end": binding["start"] + len(binding["value"].encode())})
    helpers += [item for item in facts.get("functionRanges", [])
                if item["scope"] == row["scope"] and item.get("returnsView")]
    ranges = [(item["start"], item["start"] + len(item["invocation"].encode()))
              for item in facts.get("listControls", []) if item["scope"] == row["scope"]]
    reachable = set()
    while ranges:
        start, end = ranges.pop()
        symbols = {item["value"] for item in facts.get("scopedIdentifiers", [])
                   if item["scope"] == row["scope"] and start <= item["start"] < end}
        for helper in helpers:
            if helper["name"] in symbols and helper["name"] not in reachable:
                reachable.add(helper["name"])
                ranges.append((helper["start"], helper["end"]))
    return any(helper["name"] in reachable and helper["start"] <= row["start"] < helper["end"]
               for helper in helpers)


def interactive_list_row_findings(path: Path, facts: dict, syntax: dict[str, dict]) -> list[str]:
    """逐行核对样式；标题组件的显式前景色同样接受检查。"""
    findings = []
    neutral = re.compile(r"\.foreground(?:Style|Color)\s*\(\s*(?:AppDesignSystem\.Foreground\.[\w]+|\.(?:primary|secondary|tertiary|black|white|gray))\s*\)")

    def title_override(owner: dict, start: int, end: int, scope: list[str], visited: set[str]) -> bool:
        texts = [item for item in owner.get("invocations", [])
                 if start <= item["start"] < end and item["scope"] == scope
                 and re.match(r"Text\s*\(", item["value"])]
        labeled = [item for item in owner.get("accessibilityControls", [])
                   if item["name"] == "LabeledContent" and start <= item["start"] < end and item["scope"] == scope]
        first_text = min((item["start"] for item in texts), default=sys.maxsize)
        if labeled and min(item["start"] for item in labeled) < first_text:
            content = min(labeled, key=lambda item: item["start"])
            suffix = content["expression"][len(content["invocation"]):]
            if neutral.search(mask_literals_and_comments(suffix)):
                return True
            return content["labelStart"] >= 0 and title_override(
                owner, content["labelStart"], content["labelEnd"], scope, visited
            )
        if texts:
            first_start = min(item["start"] for item in texts)
            expression = max((item["value"] for item in texts if item["start"] == first_start), key=len)
            return bool(neutral.search(mask_literals_and_comments(expression)))
        for call in owner.get("calls", []):
            if not start <= call["start"] < end or call["scope"] != scope:
                continue
            for child_path, child, child_scope in child_view_entries(syntax, call["value"], scope):
                key = f"{child_path}:{'.'.join(child_scope)}"
                if key in visited:
                    continue
                rendered = rendered_scope_facts(child, child_scope, syntax)
                if title_override(rendered, 0, sys.maxsize, child_scope, visited | {key}):
                    return True
        return False

    for row in facts.get("accessibilityControls", []):
        if not is_interactive_list_row(row, facts):
            continue
        suffix = mask_literals_and_comments(row["expression"][len(row["invocation"]):])
        line = source_text(path).encode()[:row["start"]].count(b"\n") + 1 if path.is_file() else 1
        location = f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}:{line}"
        if not re.search(r"\.appInteractiveListRow\s*\(", suffix):
            findings.append(f"{location}: {row['name']} 交互列表行必须接入 appInteractiveListRow")
        if re.search(r"\brole\s*:\s*\.destructive\b", mask_comments(row["invocation"]).split("label:", 1)[0]) and not re.search(r"appInteractiveListRow\s*\(\s*isDestructive:\s*true", suffix):
            findings.append(f"{location}: 删除列表行必须使用警示色")
        if neutral.search(suffix) or (row["labelStart"] >= 0 and title_override(facts, row["labelStart"], row["labelEnd"], row["scope"], set())):
            findings.append(f"{location}: 交互列表行左侧标题必须使用页面主题色或警示色")
    return findings


def check_interactive_list_colors(errors: list[str], syntax: dict[str, dict]) -> None:
    for path in swift_files():
        errors.extend(interactive_list_row_findings(path, syntax[str(path)], syntax))


def check_registered_visual_contracts(errors: list[str]) -> None:
    contracts = (
        *FIXED_GEOMETRY_CONTRACTS,
        *PAGE_THEME_CONTRACTS,
        MAP_THEME_COLOR_CONTRACT,
    )
    for relative_path, marker in contracts:
        path = source_path(relative_path)
        if not path.is_file():
            errors.append(f"{path.relative_to(ROOT)}: 自动视觉契约引用的源码缺失")
            continue
        source = mask_comments(source_text(path))
        if marker not in source:
            errors.append(f"{path.relative_to(ROOT)}: 自动视觉契约已变化，请同步更新契约声明（{marker}）")


def is_reviewed_fixed_geometry(
    path: Path, source: str, pattern: re.Pattern[str], node: dict
) -> bool:
    relative_path = source_relative(path)
    reviewed_paths = {
        "Modules/CourseFeature/Sources/CourseCommentViews.swift": DIRECT_THUMBNAIL_GEOMETRY,
        "Modules/CourseFeature/Sources/CourseHistoryGradesViews.swift": DIRECT_STROKE_GEOMETRY,
        "Modules/GalleryFeature/Sources/GalleryComposerView.swift": DIRECT_GRID_ITEM_GEOMETRY,
    }
    expected_pattern = reviewed_paths.get(relative_path)
    normalized_node = " ".join(node["value"].split())
    return expected_pattern is pattern and any(
        entry_path == relative_path
        and " ".join(marker.split()) in " ".join(source.split())
        and " ".join(marker.split()) in normalized_node
        for entry_path, marker in FIXED_GEOMETRY_CONTRACTS
    )


def is_registered_cgfloat_contract(path: Path, node: dict) -> bool:
    relative_path = source_relative(path)
    normalized_node = " ".join(node["value"].split())
    return any(
        entry_path == relative_path and " ".join(marker.split()) in normalized_node
        for entry_path, marker in FIXED_GEOMETRY_CONTRACTS
    )


def is_registered_map_theme_color_definition(path: Path, source: str, node: dict) -> bool:
    relative_path = source_relative(path)
    if relative_path != MAP_THEME_COLOR_CONTRACT[0] or node.get("scope") != ["AppDesignSystem", "Map"]:
        return False
    start = max(0, int(node.get("start", 0)))
    encoded_source = source.encode("utf-8")
    line_start = encoded_source.rfind(b"\n", 0, start) + 1
    line_end = encoded_source.find(b"\n", start)
    line_end = len(encoded_source) if line_end < 0 else line_end
    return encoded_source[line_start:line_end].decode("utf-8").strip() == MAP_THEME_COLOR_CONTRACT[1]


def check_ui_test_inventory(errors: list[str]) -> None:
    """Keep the interaction map aligned with every executable UI journey."""
    actual: set[str] = set()
    for path in (ROOT / "BIT101-iOSUITests").glob("*.swift"):
        source = path.read_text()
        suite = re.search(r"^(?:nonisolated final class |extension )(\w+UITests)(?::|\s*\{)", source, re.MULTILINE)
        if suite:
            actual.update(f"{suite[1]}/{name}" for name in re.findall(r"^    (?:@objc )?func (test\w+)\(", source, re.MULTILINE))
    documented = set(re.findall(r"\b(\w+UITests/test\w+)\b", (ROOT / "docs/UI_INTERACTION_COVERAGE.md").read_text()))
    errors.extend(f"UI interaction map missing: {name}" for name in sorted(actual - documented))
    errors.extend(f"UI interaction map references an absent journey: {name}" for name in sorted(documented - actual))


def check_accessibility_coverage(errors: list[str], syntax: dict[str, dict]) -> None:
    for path, facts in syntax.items():
        if not path.startswith(str(ROOT) + "/") or "/BIT101-iOSTests/" in path:
            continue
        for invocation in image_only_label_facts(facts):
            errors.append(
                f"{Path(path).relative_to(ROOT)}: {'.'.join(invocation['scope'])} 图片型操作控件需提供 accessibilityLabel"
                f"（{invocation['value'][:96].replace(chr(10), ' ')}）"
            )


def main(shared_syntax: dict[str, dict] | None = None, boundary_findings: list[str] | None = None) -> int:
    from ui_rule_tests import ast_marker_boundary_findings, source_boundary_findings, map_theme_color_contract_findings
    swift_files.cache_clear()
    source_text.cache_clear()
    if sys.argv[1:] == ["--self-test"]:
        findings = [
            *ast_marker_boundary_findings(),
            *source_boundary_findings(),
            *map_theme_color_contract_findings(),
        ]
        if findings:
            print("[失败] UI 一致性检查器自测：", file=sys.stderr)
            print("\n".join(findings), file=sys.stderr)
            return 1
        print("[通过] UI 一致性检查器自测")
        return 0

    if not DESIGN_SYSTEM.is_file():
        print(f"[失败] 缺少设计系统入口：{DESIGN_SYSTEM.relative_to(ROOT)}", file=sys.stderr)
        return 1

    errors: list[str] = []
    if shared_syntax is None:
        try:
            syntax = syntax_index()
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            print(f"[失败] SwiftSyntax 索引：{error}", file=sys.stderr)
            return 1
    else:
        syntax = shared_syntax
    errors.extend(ast_marker_boundary_findings() if boundary_findings is None else boundary_findings)
    for facts in syntax.values():
        facts["renderedScopeFacts"] = {}
    check_component_contracts(errors, syntax)
    check_haptic_consistency(errors, syntax)
    check_error_report_coverage(errors, syntax)
    check_ui_test_inventory(errors)
    check_accessibility_coverage(errors, syntax)
    check_fonts(errors, syntax)
    check_design_token_boundaries(errors, syntax)
    check_page_theme_consistency(errors, syntax)
    check_contextual_component_colors(errors, syntax)
    check_interactive_list_colors(errors, syntax)
    check_registered_visual_contracts(errors)
    app_card_uses = 0
    floating_stack_uses = 0
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        relative = path.relative_to(ROOT)
        relative_source = source_relative(path)
        raw_source = source_text(path)
        facts = syntax[str(path)]
        call_pairs = zip(facts.get("calls", []), facts.get("invocations", []))
        for call, invocation in call_pairs:
            name = call_name(call["value"])
            if name == "AppFloatingActionStack":
                floating_stack_uses += 1
            if name != "ZStack":
                continue
            invocation_source = mask_literals_and_comments(invocation["value"])
            if re.match(
                r"ZStack\s*\(\s*alignment\s*:\s*\.bottomTrailing\s*\)", invocation_source
            ) and re.search(r"\b(?:Floating|FAB)", invocation_source):
                if "AppFloatingActionStack" not in invocation_source:
                    errors.append(f"{relative}: 右下角操作组必须使用 AppFloatingActionStack")
        emitted_rule_findings: set[tuple[str, int, str]] = set()
        for pattern, message in DIRECT_VISUAL_RULES:
            if path.name == "AppLayoutComponents.swift" and pattern in (
                DIRECT_GROUPED_LIST_STYLE, DIRECT_LIST_SECTION_SPACING, DIRECT_FLOATING_MATERIAL
            ):
                continue
            for node in pattern_nodes(facts, pattern):
                if pattern is DIRECT_LOCAL_CGFLOAT_LITERAL and is_registered_cgfloat_contract(path, node):
                    continue
                if pattern in (
                    DIRECT_GRID_ITEM_GEOMETRY,
                    DIRECT_STROKE_GEOMETRY,
                    DIRECT_THUMBNAIL_GEOMETRY,
                ) and is_reviewed_fixed_geometry(path, raw_source, pattern, node):
                    continue
                pattern_source = mask_comments(node["value"]) if pattern is DIRECT_INPUT_PLACEHOLDER else mask_literals_and_comments(node["value"])
                for match in pattern.finditer(pattern_source):
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(errors, emitted_rule_findings, relative, line_number, message, pattern)
        for pattern, palette_name in DIRECT_SEMANTIC_COLOR_RULES:
            for node in pattern_nodes(facts, pattern):
                if is_registered_map_theme_color_definition(path, raw_source, node):
                    continue
                pattern_source = mask_literals_and_comments(node["value"])
                for match in pattern.finditer(pattern_source):
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(
                        errors, emitted_rule_findings, relative, line_number, f"请使用 {palette_name}", pattern
                    )

        for pattern, label in (
            (PADDING_LITERAL, "padding"),
            (STACK_SPACING_LITERAL, "stack spacing"),
        ):
            for node in pattern_nodes(facts, pattern):
                pattern_source = mask_literals_and_comments(node["value"])
                for match in pattern.finditer(pattern_source):
                    if float(match.group(1)) == 0:
                        continue
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(
                        errors,
                        emitted_rule_findings,
                        relative,
                        line_number,
                        f"{label} 必须使用 AppDesignSystem.Spacing 或专用语义令牌",
                        pattern,
                    )

        if path not in DESIGN_SYSTEM_SOURCES:
            for pattern in (DERIVED_DESIGN_TOKEN, REPEATED_DESIGN_TOKEN):
                for node in pattern_nodes(facts, pattern):
                    pattern_source = mask_literals_and_comments(node["value"])
                    for match in pattern.finditer(pattern_source):
                        line_number = pattern_line_number(raw_source, node, match.start())
                        append_rule_finding(
                            errors,
                            emitted_rule_findings,
                            relative,
                            line_number,
                            "设计令牌不得通过比例或重复相加/相减二次运算；请直接使用语义令牌",
                            pattern,
                        )

        if relative_source not in PLAIN_LIST_EXCEPTIONS:
            for node in pattern_nodes(facts, DIRECT_PLAIN_LIST_STYLE):
                pattern_source = mask_literals_and_comments(node["value"])
                for match in DIRECT_PLAIN_LIST_STYLE.finditer(pattern_source):
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(
                        errors,
                        emitted_rule_findings,
                        relative,
                        line_number,
                        "plain 列表只允许消息中心使用",
                        DIRECT_PLAIN_LIST_STYLE,
                    )

        app_card_uses += sum(call_name(call["value"]) == "AppCard" for call in facts.get("calls", []))

    if app_card_uses == 0:
        errors.append("未发现 AppCard 调用，公共卡片组件没有实际复用")
    if floating_stack_uses == 0:
        errors.append("未发现 AppFloatingActionStack 调用，右下角操作组没有实际复用")

    # 按 List 表达式检查样式归属，消息页沿用 plain 列表。
    for path in swift_files():
        if path == DESIGN_SYSTEM:
            continue
        if source_relative(path) in PLAIN_LIST_EXCEPTIONS:
            continue
        facts = syntax[str(path)]
        for control in facts["listControls"]:
            if not list_has_grouped_style(control, facts["listStyleModifiers"]):
                errors.append(f"{path.relative_to(ROOT)}: {'.'.join(control['scope'])} List 必须由自身表达式接入 appGroupedListStyle")

    if errors:
        lines = ["[失败] UI 一致性检查：", *errors]
        report = "\n".join(lines)
        REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
        REPORT_PATH.write_text(report + "\n", encoding="utf-8")
        if len(lines) <= 1000:
            print(report)
        else:
            print(f"UI 检查结果共 {len(lines)} 行 · {REPORT_PATH.relative_to(ROOT)}")
        return 1

    REPORT_PATH.unlink(missing_ok=True)
    if shared_syntax is None:
        print(f"[通过] UI 一致性检查（扫描 {len(swift_files())} 个 Swift 文件）")
    return 0
