"""Shared UI, accessibility and design rule checks."""

from __future__ import annotations

from pathlib import Path
from collections import Counter
import json
import re
import sys
from network_capability_rules import branch_value, execution_index

from ui_design_contracts import (
    COMPONENT_GROUPS,
    COMPONENT_INHERITANCE,
    CONTEXTUAL_COLOR_BYPASSES,
    DERIVED_DESIGN_TOKEN,
    DIRECT_FLOATING_MATERIAL,
    DIRECT_GRID_ITEM_GEOMETRY,
    DIRECT_GROUPED_LIST_STYLE,
    DIRECT_INPUT_PLACEHOLDER,
    DIRECT_LIST_SECTION_SPACING,
    DIRECT_LOCAL_CGFLOAT_LITERAL,
    DIRECT_OPACITY_ASSIGNMENT,
    DIRECT_OPACITY_LITERAL,
    DIRECT_PLAIN_LIST_STYLE,
    DIRECT_SEMANTIC_COLOR_RULES,
    DIRECT_STROKE_GEOMETRY,
    DIRECT_THUMBNAIL_GEOMETRY,
    DIRECT_VISUAL_RULES,
    FIXED_GEOMETRY_CONTRACTS,
    LOCAL_APP_ALERT_BINDINGS,
    PADDING_LITERAL,
    PAGE_THEME_CONTRACTS,
    PAGE_THEME_RULES,
    PLAIN_LIST_EXCEPTIONS,
    REPEATED_DESIGN_TOKEN,
    STACK_SPACING_LITERAL,
    THEME_SENSITIVE_ROOTS,
    VISUAL_CONTRACT_OWNERS,
)

from ui_source_facts import (
    DESIGN_SYSTEM,
    DESIGN_SYSTEM_SOURCES,
    MAP_THEME_COLOR_CONTRACT,
    PRIMITIVE_OPACITY_SOURCE,
    REPORT_PATH,
    ROOT,
    append_rule_finding,
    call_name,
    child_view_entries,
    has_component_declaration,
    image_only_label_facts,
    list_has_grouped_style,
    list_icon_findings,
    mask_comments,
    mask_literals_and_comments,
    path_is_in_source_root,
    pattern_line_number,
    pattern_nodes,
    rendered_scope_facts,
    rendered_view_has_marker,
    selection_control_has_feedback,
    source_path,
    source_relative,
    source_text,
    swift_files,
    syntax_index,
    view_entries,
    view_or_child_has_marker,
    view_scopes,
)

from ui_list_rules import (
    is_interactive_list_row as is_interactive_list_row,
    interactive_list_row_findings as interactive_list_row_findings,
    list_semantics_findings as list_semantics_findings,
    check_interactive_list_colors as check_interactive_list_colors,
)
from ui_interaction_rules import (
    resolved_interaction_name as resolved_interaction_name,
    inventory_component_names as inventory_component_names,
    interaction_source_inventory as interaction_source_inventory,
    source_inventory_findings as source_inventory_findings,
    manual_source_matches as manual_source_matches,
    configured_interactions as configured_interactions,
    interaction_selector as interaction_selector,
    gesture_actions as gesture_actions,
    resolve_control_action as resolve_control_action,
    source_runtime_interaction_findings as source_runtime_interaction_findings,
    check_ui_test_inventory as check_ui_test_inventory,
    check_accessibility_coverage as check_accessibility_coverage,
)


def check_composer_lifecycle(errors: list[str], syntax: dict[str, dict]) -> None:
    from ui_source_facts import UIAuditContext

    execution = syntax.execution if isinstance(syntax, UIAuditContext) else execution_index(syntax)
    for path, facts in syntax.items():
        for scope in view_scopes(facts):
            rendered = rendered_scope_facts(facts, scope, syntax)
            callback = any(
                node.get("scope") == scope
                and "async" in node.get("type", "")
                and "->" in node.get("type", "")
                and re.search(r"\bBool\b", node["type"])
                for node in facts.get("typedVariables", [])
            )
            editor = any(
                call_name(node.get("calledExpression", "")) == "accessibilityIdentifier"
                and node.get("arguments")
                in (['"ui.gallery-composer-scene.submit"'], ['"ui.paper-composer-view.submit"'])
                for node in rendered.get("invocations", [])
            )
            comment = any(
                call_name(node["value"]) == "AppCommentComposerContentSection"
                for node in rendered.get("calls", [])
            )
            if not editor and not (callback and comment):
                continue
            guards = [
                invocation
                for invocation in rendered.get("invocations", [])
                if call_name(invocation["calledExpression"]) == "interactiveDismissDisabled"
            ]
            if not any(
                not invocation.get("arguments")
                or branch_value(execution[path], invocation, invocation["arguments"][0])
                is not False
                for invocation in guards
            ):
                errors.append(f"{path}: {scope[-1]} 的系统关闭需要沿编辑与提交状态保护")


def rendered_component_counts(facts: dict, syntax: dict[str, dict]) -> Counter:
    return Counter(
        call_name(call["value"])
        for scope in view_scopes(facts)
        for call in rendered_scope_facts(facts, scope, syntax).get("calls", [])
    )


def list_row_layout_findings(syntax: dict[str, dict]) -> list[str]:
    from ui_design_contracts import GROUPED_BROWSER_MASTER_ROLES

    findings = []
    for path, facts in syntax.items():
        relative = (
            Path(path).relative_to(ROOT).as_posix() if Path(path).is_relative_to(ROOT) else path
        )
        owners = {owner for source, owner in GROUPED_BROWSER_MASTER_ROLES if source == relative}
        sections = {
            (tuple(node["scope"]), node["start"])
            for node in facts.get("invocations", [])
            if call_name(node["calledExpression"]) == "appGroupedSectionStyle"
        }
        for node in facts.get("invocations", []):
            if not node["scope"] or node["scope"][0] not in owners:
                continue
            name = call_name(node["calledExpression"])
            if name == "Section" and (tuple(node["scope"]), node["start"]) not in sections:
                findings.append(f"{path}: 浏览器一级列表的分组需要使用 appGroupedSectionStyle")
            if name == "List" and "selection" in node.get("argumentLabels", []):
                findings.append(f"{path}: 浏览器一级列表选择需要由 AppBrowserListRow 统一控制")
        containers = {
            (tuple(node["scope"]), node["start"])
            for node in facts.get("invocations", [])
            if call_name(node["calledExpression"])
            in {"List", "Form", "listStyle", "appGroupedListStyle"}
        }
        for invocation in facts.get("invocations", []):
            if (
                call_name(invocation["calledExpression"]) in {"listRowInsets", "appListRowInsets"}
                and (tuple(invocation["scope"]), invocation["start"]) in containers
            ):
                findings.append(f"{path}: 列表行边距需要由实际行持有")
        for scope in view_scopes(facts):
            if scope[-1] != "AppRefreshStatusRow":
                continue
            rendered = rendered_scope_facts(facts, scope, syntax)
            row_starts = {
                node["start"]
                for node in rendered.get("invocations", [])
                if call_name(node["calledExpression"]) == "HStack"
            }
            if not any(
                call_name(node["calledExpression"]) == "appListRowInsets"
                and node["start"] in row_starts
                for node in rendered.get("invocations", [])
            ):
                findings.append(f"{path}: 更新时间组件需要持有完整行的设计系统边距")
    return findings


def text_loading_state_findings(syntax: dict[str, dict]) -> list[str]:
    return [
        f"{Path(path).relative_to(ROOT)}: 首屏文字加载状态必须使用 AppLoadingState/AppInlineLoadingState"
        for path, facts in syntax.items()
        if Path(path) != ROOT / "Modules/DesignSystemKit/Sources/AppStateComponents.swift"
        for call in facts.get("invocations", [])
        if call_name(call["calledExpression"]) == "ProgressView"
        and call.get("arguments")
        and re.match(r'^\s*#*"', mask_comments(call["arguments"][0]))
    ]


def check_scope_component_contracts(
    path: Path, facts: dict, scope: list[str], syntax: dict[str, dict], errors: list[str]
) -> None:
    scoped_identifiers = {
        item["value"] for item in facts["scopedIdentifiers"] if item["scope"] == scope
    }
    missing_state = (
        scoped_identifiers & {"List", "Form", "Section"}
        and "ContentUnavailableView" in scoped_identifiers
        and not any(
            view_or_child_has_marker(syntax, facts, scope, marker)
            for marker in ("AppFailureState", "AppEmptyState")
        )
    )
    if missing_state:
        errors.append(
            f"{path.relative_to(ROOT)}: {'.'.join(scope)} 页面状态必须使用公共空态/失败态组件"
        )
    if not (
        re.search(r"\b(?:Gallery|Paper|Course|Mine|Settings)\b", str(path))
        and any(identifier.lower() == "avatar" for identifier in scoped_identifiers)
    ):
        return
    if not view_or_child_has_marker(
        syntax, facts, scope, "AppAvatarView"
    ) and "AppAvatarComponents.swift" not in str(path):
        errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 头像页面必须使用 AppAvatarView")


def check_component_contracts(errors: list[str], syntax: dict[str, dict]) -> None:
    errors.extend(list_row_layout_findings(syntax))
    errors.extend(text_loading_state_findings(syntax))
    sources = {path: source_text(path) for path in swift_files()}
    code_sources = {path: mask_literals_and_comments(source) for path, source in sources.items()}

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

    # 页面级公共规则按含义模式发现。
    for path, source in code_sources.items():
        facts = syntax[str(path)]
        for scope in view_scopes(facts):
            check_scope_component_contracts(path, facts, scope, syntax, errors)

    # 列表/表单内的图标按语法树调用关系审计，跨行参数与闭包仍保持归属。
    for path in swift_files():
        errors.extend(list_icon_findings(path.relative_to(ROOT), syntax[str(path)]))

    direct_states = [
        str(path.relative_to(ROOT))
        for path in swift_files()
        if "ContentUnavailableView" in syntax[str(path)]["identifiers"]
        and "AppStateComponents.swift" not in str(path)
    ]
    errors.extend(f"空态与失败态请使用公共组件：{item}" for item in direct_states)


def haptic_entry_findings(
    sources: dict[Path, str], syntax: dict[str, dict]
) -> tuple[list[str], set[Path]]:
    findings = []
    owners = set()
    for name, generator, action in (
        ("appSelectionFeedback", "UISelectionFeedbackGenerator", "selectionChanged"),
        ("appImpactFeedback", "UIImpactFeedbackGenerator", "impactOccurred"),
    ):
        definitions = [
            (path, function)
            for path in sources
            for function in syntax[str(path)].get("functionRanges", [])
            if function["name"] == name
        ]
        if len(definitions) != 1:
            findings.append(f"公共触感接口 {name} 需要唯一声明")
            continue
        path, function = definitions[0]
        code = mask_literals_and_comments(
            sources[path].encode()[function["start"] : function["end"]].decode()
        )
        if not path.is_relative_to(ROOT / "Modules/DesignSystemKit") or function["scope"] != [
            "View"
        ]:
            findings.append(f"公共触感接口 {name} 归 DesignSystemKit 的 View 扩展维护")
        if not (
            re.search(r"\bonChange\s*\(\s*of\s*:\s*trigger\s*\)", code)
            and re.search(rf"\b{generator}\s*\(\s*\)\s*\.\s*{action}\s*\(", code)
        ):
            findings.append(f"公共触感接口 {name} 需要调用对应系统触感")
        owners.add(path)
    return findings, owners


def check_haptic_consistency(errors: list[str], syntax: dict[str, dict]) -> None:
    raw_sources = {path: source_text(path) for path in swift_files()}
    entry_errors, haptic_sources = haptic_entry_findings(raw_sources, syntax)
    errors.extend(entry_errors)
    sources = {path: mask_literals_and_comments(source) for path, source in raw_sources.items()}

    interactive_markers = {
        "toggleTag",
        "selectedTags",
        "setRating",
        "selectedValues",
        "sortIndex",
        "sortOrder",
        "onToggleDone",
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
                item["value"] for item in facts["scopedIdentifiers"] if item["scope"] == scope
            }
            if not identifiers & interactive_markers:
                continue
            if not view_or_child_has_marker(syntax, facts, scope, "appSelectionFeedback"):
                errors.append(
                    f"{path.relative_to(ROOT)}: {'.'.join(scope)} 选择交互缺少公共触感修饰器"
                )

    multiselection_entries = view_entries(syntax, "AppMultiSelectionList")
    if not multiselection_entries:
        errors.append("AppMultiSelectionList: 公共多选列表 View 声明缺失")
    for path, facts, scope in multiselection_entries:
        if not rendered_view_has_marker(facts, scope, "appSelectionFeedback", syntax):
            errors.append(
                f"{path.relative_to(ROOT)}: AppMultiSelectionList 必须为选择变化提供公共触感"
            )

    for component in ("AppFloatingActionButton", "FloatingMapLabelButton"):
        entries = view_entries(syntax, component)
        if not entries:
            errors.append(f"{component}: 浮动操作组件需要 View 声明")
        for path, facts, scope in entries:
            if not rendered_view_has_marker(facts, scope, "appImpactFeedback", syntax):
                errors.append(f"{path.relative_to(ROOT)}: {component} 浮动操作需要公共触感")

    direct_patterns = re.compile(
        (
            "\\.sensoryFeedback\\(|UIFeedbackGenerator|UI(Selection|Impact|Notification)FeedbackGe"
            "nerator|impactOccurred\\(|selectionChanged\\(|notificationOccurred\\(|AudioServicesPl"
            "aySystemSound|kSystemSoundID_Vibrate|CHHapticEngine|NSHapticFeedbackManager|WKInterfa"
            "ceDevice.*\\.play"
        )
    )
    for path, source in sources.items():
        if path not in haptic_sources and direct_patterns.search(source):
            errors.append(f"{path.relative_to(ROOT)}: 触感请使用公共修饰器")

        for match in re.finditer(r"\.app[A-Za-z]+Feedback\(", source):
            name = match.group(0)
            if name not in (".appSelectionFeedback(", ".appImpactFeedback("):
                errors.append(f"{path.relative_to(ROOT)}: 发现未登记的公共触感调用 {name}")


def alert_coverage_findings(facts: dict, path: Path) -> list[str]:
    app_alert_variables = [
        variable
        for variable in facts.get("typedVariables", [])
        if re.search(r"\bAppAlert\b", variable["type"])
    ]
    findings: list[str] = []
    diagnostic_bindings: set[tuple[tuple[str, ...], str]] = set()
    for invocation in facts.get("invocations", []):
        if call_name(invocation["calledExpression"]) != "diagnosticAlert":
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
                view_name,
                variable_name,
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
        facts = syntax[str(path)]
        schedule_notice_presenters += sum(
            call_name(node.get("calledExpression", "")) == "diagnosticAlert"
            and any(
                re.search(r"\bscheduleViewModel\.notice\b", argument)
                for argument in node.get("arguments", [])
            )
            for node in facts.get("invocations", [])
        )
        errors.extend(alert_coverage_findings(facts, path.relative_to(ROOT)))
        for scope in view_scopes(facts):
            failed_states = [
                flow["value"]
                for flow in facts["controlFlow"]
                if flow["scope"] == scope
                and re.search(
                    r"(?:case|if case|else if case) let \.failed\(message\)", flow["value"]
                )
                and "ContentUnavailableView" in flow["value"]
            ]
            if any(
                "DiagnosticRecoveryActions" not in flow and "PaperEmptyState" not in flow
                for flow in failed_states
            ):
                errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 失败态缺少错误报告入口")

    if schedule_notice_presenters != 1:
        errors.append(f"日程共享错误展示器数量异常：引用数 {schedule_notice_presenters}")


def check_font_invocation(
    invocation: dict,
    relative: Path,
    raw_source: str,
    swift_pattern: re.Pattern,
    ui_pattern: re.Pattern,
    custom_pattern: re.Pattern,
    errors: list[str],
) -> None:
    name = call_name(invocation["calledExpression"])
    if name not in {"system", "systemFont", "custom"}:
        return
    source = mask_literals_and_comments(invocation["value"])
    if name == "system":
        for match in swift_pattern.finditer(source):
            value = match.group("value").strip()
            if "AppDesignSystem." not in value:
                line = pattern_line_number(raw_source, invocation, match.start())
                errors.append(
                    f"{relative}:{line}: 字体字号必须使用设计系统令牌或系统含义字体：{value}"
                )
    elif name == "systemFont":
        for match in ui_pattern.finditer(source):
            value = match.group("value").strip()
            if "AppDesignSystem." not in value:
                line = pattern_line_number(raw_source, invocation, match.start())
                errors.append(
                    f"{relative}:{line}: UIFont 字号必须使用设计系统令牌或系统含义字体：{value}"
                )
    elif name == "custom" and custom_pattern.search(source):
        errors.append(
            f"{relative}:{pattern_line_number(raw_source, invocation, 0)}: 字体采用系统含义或公共令牌"
        )


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
        if not (path not in DESIGN_SYSTEM_SOURCES):
            continue
        for invocation in facts.get("invocations", []):
            check_font_invocation(
                invocation,
                relative,
                raw_source,
                swift_explicit_font_size,
                ui_explicit_font_size,
                custom_font,
                errors,
            )


def check_design_token_boundaries(errors: list[str], syntax: dict[str, dict]) -> None:
    """透明度数字统一定义在跨 target 基础刻度层。"""
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


def check_page_theme_rule(
    path: Path,
    raw_source: str,
    members: list[dict],
    forbidden_tokens: tuple[str, ...],
    expected_token: str,
    errors: list[str],
) -> None:
    emitted: set[tuple[int, str]] = set()
    for token in forbidden_tokens:
        for node in members:
            if token not in node["value"]:
                continue
            line_number = pattern_line_number(raw_source, node, 0)
            marker = (line_number, token)
            if marker in emitted:
                continue
            emitted.add(marker)
            errors.append(
                f"{path.relative_to(ROOT)}:{line_number}: 页面主题色应使用 "
                f"{expected_token}，当前发现 {token}"
            )


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
            check_page_theme_rule(
                path,
                raw_source,
                facts.get("members", []),
                forbidden_tokens,
                expected_token,
                errors,
            )


def check_contextual_component_colors(errors: list[str], syntax: dict[str, dict]) -> None:
    """复用内容与组件通过环境 tint 使用页面强调色。"""
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


def swift_contract_tokens(value: str) -> str:
    return re.sub(
        r'"(?:\\.|[^"\\])*"|\s+',
        lambda match: match[0] if match[0].startswith('"') else "",
        mask_comments(value),
    )


def function_range_nodes(facts: dict, scope: tuple[str, ...], entry: str) -> list[dict]:
    functions = [
        function
        for function in facts.get("functionRanges", [])
        if tuple(function["scope"]) == scope and function["name"] == entry
    ]
    matching = []
    for kind in ("invocations", "bindings"):
        for node in facts.get(kind, []):
            if any(function["start"] <= node["start"] < function["end"] for function in functions):
                matching.append(node)
    return matching


def visual_contract_present(
    relative_path: str, marker: str, sources: dict[Path, str], syntax: dict | None = None
) -> bool:
    from swift_source_index import swift_syntax_index_sources

    directory = source_path(relative_path).parent
    scope, entry = VISUAL_CONTRACT_OWNERS[relative_path]
    syntax = syntax or swift_syntax_index_sources(
        {str(path): source for path, source in sources.items()}
    )
    syntax = {path: facts for path, facts in syntax.items() if Path(path).is_relative_to(directory)}
    expected = swift_contract_tokens(marker)
    for facts in syntax.values():
        if entry is None:
            selected = rendered_scope_facts(facts, list(scope), syntax)
            nodes = selected.get("invocations", []) + selected.get("expressions", [])
        elif entry == "tabAccent":
            nodes = [
                node
                for node in facts.get("bindings", [])
                if tuple(node["scope"]) == scope and node.get("bindingName") == entry
            ]
            expected = swift_contract_tokens(marker.removeprefix("public static let "))
        else:
            nodes = function_range_nodes(facts, scope, entry)
        if any(
            tuple(node["scope"]) == scope and expected in swift_contract_tokens(node["value"])
            for node in nodes
        ):
            return True
    return False


def check_registered_visual_contracts(errors: list[str]) -> None:
    contracts = (
        *FIXED_GEOMETRY_CONTRACTS,
        *PAGE_THEME_CONTRACTS,
        MAP_THEME_COLOR_CONTRACT,
    )
    sources = {path: source_text(path) for path in swift_files()}
    syntax = syntax_index()
    for relative_path, marker in contracts:
        if not visual_contract_present(relative_path, marker, sources, syntax):
            errors.append(
                (
                    f"{relative_path}"
                    f":1: "
                    f"{'.'.join(VISUAL_CONTRACT_OWNERS[relative_path][0])}"
                    f": 视觉契约需要对应所属渲染或实现表达式（"
                    f"{marker}"
                    f"）"
                )
            )


def is_reviewed_fixed_geometry(
    path: Path, source: str, pattern: re.Pattern[str], node: dict
) -> bool:
    reviewed_paths = {
        "Modules/CourseFeature/Sources/CourseCommentViews.swift": DIRECT_THUMBNAIL_GEOMETRY,
        "Modules/CourseFeature/Sources/CourseHistoryGradesViews.swift": DIRECT_STROKE_GEOMETRY,
        "Modules/GalleryFeature/Sources/GalleryComposerView.swift": DIRECT_GRID_ITEM_GEOMETRY,
    }
    normalized_node = swift_contract_tokens(node["value"])
    return any(
        path.is_relative_to(source_path(entry_path).parent)
        and reviewed_paths.get(entry_path) is pattern
        and tuple(node.get("scope", [])) == VISUAL_CONTRACT_OWNERS[entry_path][0]
        and swift_contract_tokens(marker) in swift_contract_tokens(source)
        and swift_contract_tokens(marker) in normalized_node
        for entry_path, marker in FIXED_GEOMETRY_CONTRACTS
    )


def is_registered_cgfloat_contract(path: Path, node: dict) -> bool:
    normalized_node = swift_contract_tokens(node["value"])
    return any(
        path.is_relative_to(source_path(entry_path).parent)
        and swift_contract_tokens(marker) in normalized_node
        and tuple(node.get("scope", [])) == VISUAL_CONTRACT_OWNERS[entry_path][0]
        for entry_path, marker in FIXED_GEOMETRY_CONTRACTS
    )


def is_registered_map_theme_color_definition(path: Path, source: str, node: dict) -> bool:
    if not path.is_relative_to(source_path(MAP_THEME_COLOR_CONTRACT[0]).parent) or node.get(
        "scope"
    ) != ["AppDesignSystem", "Map"]:
        return False
    start = max(0, int(node.get("start", 0)))
    pattern = r"public\s+static\s+let\s+tabAccent\s*=\s*Color\s*\.\s*green\b"
    return any(
        len(source[: match.start()].encode()) <= start < len(source[: match.end()].encode())
        for match in re.finditer(pattern, mask_comments(source))
    )


from ui_design_contracts import (
    SWIFTUI_INTERACTION_KINDS as INTERACTION_KINDS,
    SWIFTUI_CONTROL_ACTIONS,
    SWIFTUI_MODIFIER_ACTIONS,
    SWIFTUI_GESTURE_MODIFIERS,
)


from ui_native_interactions import (
    NATIVE_INTERACTION_KINDS,
    native_interaction_inventory,
    native_runtime_controls,
)


PAGE_CONTAINER_OWNERS = {
    "BIT101-iOS/Shell/AppAcademicDestinations.swift": "AppPairedPages",
    "Modules/GalleryFeature/Sources/GalleryRootView.swift": "AppPairedPages",
    "Modules/ScheduleFeature/Sources/ScheduleRootView.swift": "AppRetainedPage",
    "Modules/PaperFeature/Sources/PaperRootView.swift": "AppRetainedPage",
}


def page_transition_findings(relative: str, facts: dict) -> list[str]:
    calls = {call_name(call["calledExpression"]) for call in facts.get("invocations", [])}
    errors = design_page_component_findings(relative, facts)
    expected = PAGE_CONTAINER_OWNERS.get(relative)
    if expected and expected not in calls:
        errors.append(f"{relative}: 分区页面需要使用 {expected} 保留页面并统一切换动画")
    owns_pages = expected or calls.intersection(
        {("appPageSwitch"), ("AppPairedPages"), ("AppRetainedPage")}
    )
    if owns_pages and not relative.startswith("Modules/DesignSystemKit/"):
        for call in facts.get("invocations", []):
            name = call_name(call["calledExpression"])
            if is_custom_page_animation(call):
                errors.append(
                    f"{relative}:{call.get('line', 1)}: 分区切换应使用设计系统页面组件，统一淡入淡出；局部 {name} 会造成动画差异"
                )
    return errors


def check_page_transitions(errors: list[str], syntax: dict[str, dict]) -> None:
    for path, facts in syntax.items():
        relative = str(Path(path).relative_to(ROOT))
        errors.extend(page_transition_findings(relative, facts))


def design_page_component_findings(relative: str, facts: dict) -> list[str]:
    errors = []
    invocations = facts.get("invocations", [])
    if relative == "Modules/DesignSystemKit/Sources/AppLayoutComponents.swift":
        functions = [
            row
            for row in facts.get(("functionRanges"), [])
            if row[("name")] == ("appPageTransition")
        ]
        transitions = [
            call
            for call in invocations
            if call_name(call["calledExpression"]) == "transition"
            and any(row["bodyStart"] <= call["start"] < row["end"] for row in functions)
        ]
        if len(transitions) != 1 or transitions[0]["arguments"] != [".opacity"]:
            errors.append(f"{relative}: 共享页面切换必须保持系统 opacity 过渡")
        for call in invocations:
            if set(call.get(("scope"), [])).intersection(
                {("AppPairedPages"), ("AppRetainedPage")}
            ) and is_custom_page_animation(call):
                errors.append(f"{relative}: 页面容器统一调用 appPageTransition，保持淡入淡出")
    if relative == "Modules/DesignSystemKit/Sources/AppContentControlComponents.swift":
        isolated = any(
            "AppSegmentedPicker" in call.get("scope", [])
            and call_name(call["calledExpression"]) == "transaction"
            and re.search(r"\.animation\s*=\s*nil", mask_literals_and_comments(call["value"]))
            for call in invocations
        )
        if not isolated:
            errors.append(f"{relative}: 系统分段栏需要隔离页面动画事务，保持控件与标题稳定")
    return errors


def is_custom_page_animation(call: dict) -> bool:
    name = call_name(call["calledExpression"])
    return name in {"transition", "offset", "scaleEffect"} and not (
        name == "transition" and call["calledExpression"].startswith("AppDesignSystem.Motion.")
    )
