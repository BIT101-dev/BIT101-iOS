"""Shared UI, accessibility and design rule checks."""
from __future__ import annotations

from pathlib import Path
from collections import Counter
import json
import re
import sys
from network_capability_rules import branch_value, execution_index

from ui_design_contracts import (
    COMPONENT_GROUPS, COMPONENT_INHERITANCE, CONTEXTUAL_COLOR_BYPASSES, DERIVED_DESIGN_TOKEN,
    DIRECT_FLOATING_MATERIAL, DIRECT_GRID_ITEM_GEOMETRY, DIRECT_GROUPED_LIST_STYLE,
    DIRECT_INPUT_PLACEHOLDER, DIRECT_LIST_SECTION_SPACING, DIRECT_LOCAL_CGFLOAT_LITERAL,
    DIRECT_OPACITY_ASSIGNMENT, DIRECT_OPACITY_LITERAL, DIRECT_PLAIN_LIST_STYLE,
    DIRECT_SEMANTIC_COLOR_RULES, DIRECT_STROKE_GEOMETRY, DIRECT_THUMBNAIL_GEOMETRY,
    DIRECT_VISUAL_RULES, FIXED_GEOMETRY_CONTRACTS, LOCAL_APP_ALERT_BINDINGS, PADDING_LITERAL,
    PAGE_THEME_CONTRACTS, PAGE_THEME_RULES, PLAIN_LIST_EXCEPTIONS, REPEATED_DESIGN_TOKEN,
    STACK_SPACING_LITERAL, THEME_SENSITIVE_ROOTS, VISUAL_CONTRACT_OWNERS,
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


def check_composer_lifecycle(errors: list[str], syntax: dict[str, dict]) -> None:
    from ui_source_facts import UIAuditContext
    execution = syntax.execution if isinstance(syntax, UIAuditContext) else execution_index(syntax)
    for path, facts in syntax.items():
        for scope in view_scopes(facts):
            rendered = rendered_scope_facts(facts, scope, syntax)
            callback = any(node.get('scope') == scope and 'async' in node.get('type', '') and '->' in node.get('type', '')
                and re.search(r'\bBool\b', node['type']) for node in facts.get('typedVariables', []))
            editor = any(call_name(node.get('calledExpression', '')) == 'accessibilityIdentifier'
                and node.get('arguments') in (['"ui.gallery-composer-scene.submit"'], ['"ui.paper-composer-view.submit"'])
                for node in rendered.get('invocations', []))
            comment = any(call_name(node['value']) == 'AppCommentComposerContentSection' for node in rendered.get('calls', []))
            if not editor and not (callback and comment): continue
            guards = [invocation for invocation in rendered.get('invocations', [])
                if call_name(invocation['calledExpression']) == 'interactiveDismissDisabled']
            if not any(not invocation.get('arguments') or branch_value(execution[path], invocation, invocation['arguments'][0]) is not False for invocation in guards):
                errors.append(f'{path}: {scope[-1]} 的系统关闭需要沿编辑与提交状态保护')


def rendered_component_counts(facts: dict, syntax: dict[str, dict]) -> Counter:
    return Counter(call_name(call['value']) for scope in view_scopes(facts)
        for call in rendered_scope_facts(facts, scope, syntax).get('calls', []))


def list_row_layout_findings(syntax: dict[str, dict]) -> list[str]:
    from ui_design_contracts import GROUPED_BROWSER_MASTER_ROLES
    findings = []
    for path, facts in syntax.items():
        relative = Path(path).relative_to(ROOT).as_posix() if Path(path).is_relative_to(ROOT) else path
        owners = {owner for source, owner in GROUPED_BROWSER_MASTER_ROLES if source == relative}
        sections = {(tuple(node['scope']), node['start']) for node in facts.get('invocations', [])
            if call_name(node['calledExpression']) == 'appGroupedSectionStyle'}
        for node in facts.get('invocations', []):
            if not node['scope'] or node['scope'][0] not in owners: continue
            name = call_name(node['calledExpression'])
            if name == 'Section' and (tuple(node['scope']), node['start']) not in sections:
                findings.append(f'{path}: 浏览器一级列表的分组需要使用 appGroupedSectionStyle')
            if name == 'List' and 'selection' in node.get('argumentLabels', []):
                findings.append(f'{path}: 浏览器一级列表选择需要由 AppBrowserListRow 统一控制')
        containers = {(tuple(node['scope']), node['start']) for node in facts.get('invocations', [])
            if call_name(node['calledExpression']) in {'List', 'Form', 'listStyle', 'appGroupedListStyle'}}
        for invocation in facts.get('invocations', []):
            if call_name(invocation['calledExpression']) in {'listRowInsets', 'appListRowInsets'} and (tuple(invocation['scope']), invocation['start']) in containers:
                findings.append(f'{path}: 列表行边距需要由实际行持有')
        for scope in view_scopes(facts):
            if scope[-1] != 'AppRefreshStatusRow': continue
            rendered = rendered_scope_facts(facts, scope, syntax)
            row_starts = {node['start'] for node in rendered.get('invocations', []) if call_name(node['calledExpression']) == 'HStack'}
            if not any(call_name(node['calledExpression']) == 'appListRowInsets' and node['start'] in row_starts
                    for node in rendered.get('invocations', [])):
                findings.append(f'{path}: 更新时间组件需要持有完整行的设计系统边距')
    return findings


def text_loading_state_findings(syntax: dict[str, dict]) -> list[str]:
    return [f'{Path(path).relative_to(ROOT)}: 首屏文字加载状态必须使用 AppLoadingState/AppInlineLoadingState'
        for path, facts in syntax.items() if Path(path) != ROOT / 'Modules/DesignSystemKit/Sources/AppStateComponents.swift'
        for call in facts.get('invocations', []) if call_name(call['calledExpression']) == 'ProgressView'
        and call.get('arguments') and re.match(r'^\s*#*"', mask_comments(call['arguments'][0]))]


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


def haptic_entry_findings(sources: dict[Path, str], syntax: dict[str, dict]) -> tuple[list[str], set[Path]]:
    findings = []
    owners = set()
    for name, feedback in (("appSelectionFeedback", "selection"), ("appImpactFeedback", "impact")):
        definitions = [(path, function) for path in sources
            for function in syntax[str(path)].get("functionRanges", []) if function["name"] == name]
        if len(definitions) != 1:
            findings.append(f"公共触感接口 {name} 需要唯一声明")
            continue
        path, function = definitions[0]
        code = mask_literals_and_comments(sources[path].encode()[function["start"]:function["end"]].decode())
        if not path.is_relative_to(ROOT / "Modules/DesignSystemKit") or function["scope"] != ["View"]:
            findings.append(f"公共触感接口 {name} 归 DesignSystemKit 的 View 扩展维护")
        if not re.search(rf"\bsensoryFeedback\s*\(\s*\.{feedback}\s*,\s*trigger\s*:", code):
            findings.append(f"公共触感接口 {name} 需要调用对应系统触感")
        owners.add(path)
    return findings, owners


def check_haptic_consistency(errors: list[str], syntax: dict[str, dict]) -> None:
    raw_sources = {path: source_text(path) for path in swift_files()}
    entry_errors, haptic_sources = haptic_entry_findings(raw_sources, syntax)
    errors.extend(entry_errors)
    sources = {path: mask_literals_and_comments(source) for path, source in raw_sources.items()}

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

    for component in ("AppFloatingActionButton", "FloatingMapLabelButton"):
        entries = view_entries(syntax, component)
        if not entries:
            errors.append(f"{component}: 浮动操作组件需要 View 声明")
        for path, facts, scope in entries:
            if not rendered_view_has_marker(facts, scope, "appImpactFeedback", syntax):
                errors.append(f"{path.relative_to(ROOT)}: {component} 浮动操作需要公共触感")

    direct_patterns = re.compile(
        r"\.sensoryFeedback\(|UIFeedbackGenerator|UI(Selection|Impact|Notification)FeedbackGenerator|"
        r"impactOccurred\(|selectionChanged\(|notificationOccurred\(|AudioServicesPlaySystemSound|"
        r"kSystemSoundID_Vibrate|CHHapticEngine|NSHapticFeedbackManager|WKInterfaceDevice.*\.play"
    )
    for path, source in sources.items():
        if path not in haptic_sources and direct_patterns.search(source):
            errors.append(f"{path.relative_to(ROOT)}: 页面不得绕过公共触感修饰器")

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
        facts = syntax[str(path)]
        schedule_notice_presenters += sum(call_name(node.get('calledExpression', '')) == 'diagnosticAlert'
            and any(re.search(r'\bscheduleViewModel\.notice\b', argument) for argument in node.get('arguments', []))
            for node in facts.get('invocations', []))
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
            for invocation in facts.get("invocations", []):
                name = call_name(invocation["calledExpression"])
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
    neutral = re.compile(r"\.foreground(?:Style|Color)\s*\(\s*(?:AppDesignSystem\.(?:Foreground\.(?:secondary|tertiary)|Course\.accent|Schedule\.tabAccent|Palette\.(?:Accent|Highlight)\.[\w]+)|\.(?:tint|secondary|tertiary|black|white|gray))\s*\)")

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

    def value_override(row: dict) -> bool:
        start, end = row["labelStart"], row["labelEnd"]
        if start < 0: return False
        labeled = [item for item in facts.get("accessibilityControls", [])
            if item["name"] == "LabeledContent" and start <= item["start"] < end]
        trailing = re.compile(r"\.foreground(?:Style|Color)\s*\(\s*(?:AppDesignSystem\.Foreground\.[\w]+|\.(?:primary|secondary|tertiary))\s*\)")
        for item in labeled:
            content_end = item["labelStart"] if item["labelStart"] >= 0 else item["start"] + len(item["invocation"].encode())
            expressions = [node["value"] for node in facts.get("invocations", [])
                if re.match(r"Text\s*\(", node.get("value", "")) and item["start"] <= node["start"] < content_end]
            if any(trailing.search(mask_literals_and_comments(value)) for value in expressions): return True
        spacers = [node["start"] for node in facts.get("invocations", [])
            if node.get("calledExpression") == "Spacer" and start <= node["start"] < end]
        if not labeled and spacers:
            texts = [node["value"] for node in facts.get("invocations", [])
                if re.match(r"Text\s*\(", node.get("value", "")) and min(spacers) < node["start"] < end]
            if any(trailing.search(mask_literals_and_comments(value)) for value in texts): return True
        return False

    for row in facts.get("accessibilityControls", []):
        if row["name"] in {"TextField", "SecureField", "TextEditor", "Slider", "Stepper", "ScrollView", "List", "TabView", "onTapGesture", "onLongPressGesture", "gesture", "simultaneousGesture", "highPriorityGesture", "refreshable", "onSubmit", "onDelete", "onMove", "searchable", "contextMenu", "swipeActions"}: continue
        if not is_interactive_list_row(row, facts):
            continue
        suffix = mask_literals_and_comments(row["expression"][len(row["invocation"]):])
        line = source_text(path).encode()[:row["start"]].count(b"\n") + 1 if path.is_file() else 1
        location = f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}:{line}"
        has_list_style = re.search(r"\.appInteractiveListRow\s*\(", suffix)
        if re.search(r"\.buttonStyle\s*\(\s*\.borderedProminent\s*\)", suffix):
            if has_list_style:
                findings.append(f"{location}: 填充按钮应沿用系统文字样式")
            continue
        if not has_list_style:
            findings.append(f"{location}: {row['name']} 交互列表行必须接入 appInteractiveListRow")
        if re.search(r"\brole\s*:\s*\.destructive\b", mask_comments(row["invocation"]).split("label:", 1)[0]) and not re.search(r"appInteractiveListRow\s*\(\s*isDestructive:\s*true", suffix):
            findings.append(f"{location}: 删除列表行必须使用警示色")
        if neutral.search(suffix) or (row["labelStart"] >= 0 and title_override(facts, row["labelStart"], row["labelEnd"], row["scope"], set())):
            findings.append(f"{location}: 交互列表行左侧标题沿系统主文字色")
        if value_override(row):
            findings.append(f"{location}: 交互列表行右侧值使用页面主题色")
    return findings


def list_semantics_findings(syntax: dict[str, dict]) -> list[str]:
    findings = []
    for path, facts in syntax.items():
        for call in facts.get('invocations', []):
            name = call_name(call['calledExpression'])
            labels = call.get('argumentLabels', []) + call.get('trailingClosureLabels', [])
            if name == 'Section' and 'footer' in labels:
                line = facts['source'].encode()[:call['start']].count(b'\n') + 1
                findings.append(f'{path}:{line}: 列表分组内容使用正文行，Section footer 说明需要清理')
            if call.get('scope', []) == ['AppListSectionHeader'] and name in {'font', 'foregroundStyle', 'foregroundColor'}:
                findings.append(f'{path}: 列表分组标题继承系统样式')
            if name == 'Image' and any(value in str(call.get('arguments', [])) for value in ('chevron.right', 'chevron.forward', 'arrow.right')):
                expression = mask_literals_and_comments(max((node.get('value', '') for node in facts.get('invocations', [])
                    if node['start'] == call['start']), key=len, default=''))
                if re.search(r'\.foreground(?:Style|Color)\(\s*(?:\.tint|AppDesignSystem\.(?:Course\.accent|Schedule\.tabAccent))', expression):
                    findings.append(f'{path}: 列表披露箭头沿系统符号颜色')
        refresh = [call for call in facts.get('accessibilityControls', []) if call['scope'] == ['AppRefreshStatusRow'] and call['name'] == 'Button']
        if refresh:
            text = max((call['value'] for call in facts.get('invocations', [])
                if re.match(r'Text\s*\(\s*trailingText\s*\)', call.get('value', ''))), key=len, default='')
            body_font = r'\.font\(\s*AppDesignSystem\.Typography\.body\s*\)'
            if not re.search(body_font, text) or any(not re.search(body_font, row['expression']) for row in refresh):
                findings.append(f'{path}: 更新时间行的操作和只读标记共同使用正文字号')
    return findings


def check_interactive_list_colors(errors: list[str], syntax: dict[str, dict]) -> None:
    errors.extend(list_semantics_findings(syntax))
    for path in swift_files():
        errors.extend(interactive_list_row_findings(path, syntax[str(path)], syntax))


def swift_contract_tokens(value: str) -> str:
    return re.sub(r'"(?:\\.|[^"\\])*"|\s+', lambda match: match[0] if match[0].startswith('"') else '', mask_comments(value))


def visual_contract_present(relative_path: str, marker: str, sources: dict[Path, str], syntax: dict | None = None) -> bool:
    from swift_source_index import swift_syntax_index_sources
    directory = source_path(relative_path).parent
    scope, entry = VISUAL_CONTRACT_OWNERS[relative_path]
    syntax = syntax or swift_syntax_index_sources({str(path): source for path, source in sources.items()})
    syntax = {path: facts for path, facts in syntax.items() if Path(path).is_relative_to(directory)}
    expected = swift_contract_tokens(marker)
    for facts in syntax.values():
        if entry is None:
            selected = rendered_scope_facts(facts, list(scope), syntax)
            nodes = selected.get('invocations', []) + selected.get('expressions', [])
        elif entry == 'tabAccent':
            nodes = [node for node in facts.get('bindings', []) if tuple(node['scope']) == scope
                and node.get('bindingName') == entry]
            expected = swift_contract_tokens(marker.removeprefix('public static let '))
        else:
            functions = [function for function in facts.get('functionRanges', [])
                if tuple(function['scope']) == scope and function['name'] == entry]
            nodes = [node for kind in ('invocations', 'bindings') for node in facts.get(kind, [])
                if any(function['start'] <= node['start'] < function['end'] for function in functions)]
        if any(tuple(node['scope']) == scope and expected in swift_contract_tokens(node['value']) for node in nodes):
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
            errors.append(f"{relative_path}:1: {'.'.join(VISUAL_CONTRACT_OWNERS[relative_path][0])}: 视觉契约需要对应所属渲染或实现表达式（{marker}）")


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
        path.is_relative_to(source_path(entry_path).parent) and reviewed_paths.get(entry_path) is pattern
        and tuple(node.get('scope', [])) == VISUAL_CONTRACT_OWNERS[entry_path][0]
        and swift_contract_tokens(marker) in swift_contract_tokens(source)
        and swift_contract_tokens(marker) in normalized_node
        for entry_path, marker in FIXED_GEOMETRY_CONTRACTS
    )


def is_registered_cgfloat_contract(path: Path, node: dict) -> bool:
    normalized_node = swift_contract_tokens(node["value"])
    return any(
        path.is_relative_to(source_path(entry_path).parent) and swift_contract_tokens(marker) in normalized_node
        and tuple(node.get('scope', [])) == VISUAL_CONTRACT_OWNERS[entry_path][0]
        for entry_path, marker in FIXED_GEOMETRY_CONTRACTS
    )


def is_registered_map_theme_color_definition(path: Path, source: str, node: dict) -> bool:
    if not path.is_relative_to(source_path(MAP_THEME_COLOR_CONTRACT[0]).parent) or node.get("scope") != ["AppDesignSystem", "Map"]:
        return False
    start = max(0, int(node.get("start", 0)))
    pattern = r"public\s+static\s+let\s+tabAccent\s*=\s*Color\s*\.\s*green\b"
    return any(len(source[:match.start()].encode()) <= start < len(source[:match.end()].encode())
        for match in re.finditer(pattern, mask_comments(source)))


from ui_design_contracts import SWIFTUI_INTERACTION_KINDS as INTERACTION_KINDS, SWIFTUI_CONTROL_ACTIONS, SWIFTUI_MODIFIER_ACTIONS, SWIFTUI_GESTURE_MODIFIERS


from ui_native_interactions import NATIVE_INTERACTION_KINDS, native_interaction_inventory, native_runtime_controls


def resolved_interaction_name(types, path, call):
    from swift_source_index import canonical_type_scope
    name = call["value"].removesuffix(".init")
    if call_name(name) in INTERACTION_KINDS: return call_name(name)
    resolved = types.terminal_name(path, name, call["scope"] + call.get("lexicalScope", []))
    parts = canonical_type_scope([resolved])
    return parts[-1] if parts else call_name(name)


def interaction_source_inventory(syntax: dict[str, dict]) -> dict[str, dict[str, int]]:
    from swift_type_index import SwiftTypeIndex
    types = SwiftTypeIndex(syntax)
    components = {scope[0] for path, facts in syntax.items()
        if any(f"/{module}/" in path for module in ("DesignSystemKit", "CommunityUI", "MediaKit"))
        for scope in view_scopes(facts) if any(resolved_interaction_name(types, path, call) in INTERACTION_KINDS
            and call["scope"][:len(scope)] == scope for call in facts["calls"])}
    inventory = {}
    for path, facts in syntax.items():
        if any(Path(path).is_relative_to(ROOT / root) for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")): continue
        for scope in {tuple(call["scope"]) for call in facts["calls"]}:
            controls = Counter(resolved_interaction_name(types, path, call) for call in facts["calls"]
                if tuple(call["scope"]) == scope and resolved_interaction_name(types, path, call) in INTERACTION_KINDS | components
                and call["value"] not in {"onSubmit", "onDelete", "onMove"})
            if controls:
                inventory[Path(path).relative_to(ROOT).as_posix() + ":" + (".".join(scope) or "global")] = dict(sorted(controls.items()))
    for source, controls in native_interaction_inventory(syntax).items():
        inventory[source] = dict(sorted((Counter(inventory.get(source, {})) + controls).items()))
    return dict(sorted(inventory.items()))


def source_inventory_findings(syntax: dict[str, dict], documented: dict[str, tuple[dict, set]], tests: set[str]) -> list[str]:
    actual = interaction_source_inventory(syntax)
    errors = []
    for source, controls in actual.items():
        contract, journeys = documented.get(source, ({}, set()))
        if controls != contract: errors.append(f"UI 源码交互清单需要同步：{source}")
        if not journeys or any(journey not in tests | {"manual:watch", "manual:widget", "manual:web-interactions"} for journey in journeys):
            errors.append(f"UI 源码交互需要验收归属：{source}")
        for journey in journeys:
            if journey.startswith("manual:") and not manual_source_matches(source, journey):
                errors.append(f"UI 手工验收归属需要匹配平台：{source} · {journey}")
    errors.extend(f"UI 源码交互清单需要清理：{source}" for source in documented.keys() - actual.keys())
    return errors


def manual_source_matches(source: str, journey: str) -> bool:
    return journey == "manual:watch" and source.startswith("BIT101Watch/") \
        or journey == "manual:widget" and source.startswith(("BIT101ScheduleWidgets/", "BIT101WatchWidgets/"))


def documented_interactions() -> dict[str, tuple[dict, set]]:
    document = (ROOT / "docs/UI_INTERACTION_COVERAGE.md").read_text()
    return {source: (json.loads(controls), set(journeys.split(","))) for source, controls, journeys
        in re.findall(r"^\| `([^`]+\.swift:[^`]+)` \| `(\{[^`]+\})` \| `([^`]+)` \|$", document, re.MULTILINE)}


def interaction_selector(control: dict, syntax: dict) -> tuple[str, tuple[str, ...]] | None:
    if "nativeSelector" in control: return control["nativeSelector"]
    literal = r'"((?:[^"\\]|\\.)+)"'
    if control["name"] in {"refreshable", "onSubmit", "onDelete", "onMove"}:
        marker = re.search(r'interactionEvidence\??\(\s*' + literal, control.get("callback", control["invocation"]))
        return ("identifier", (marker[1],)) if marker else None
    modifiers = control.get("modifiers", control["expression"])
    identifiers = re.findall(r'\.accessibilityIdentifier\(\s*' + literal + r'\s*\)', modifiers)
    if identifiers: return "identifier", (identifiers[-1],)
    forwarded = re.search(r'\.accessibilityIdentifier\(\s*(\w+)\s*\?\?\s*' + literal + r'\s*\)', modifiers)
    if forwarded:
        names = {forwarded[2]}
        for facts in syntax.values():
            for call in facts.get("invocations", []):
                if control["scope"] and call_name(call["value"]) == control["scope"][-1]:
                    names.update(re.findall(r'\b' + re.escape(forwarded[1]) + r':\s*' + literal, call["value"]))
        return "identifier", tuple(sorted(names))
    label = re.search(r'\.accessibilityLabel\(\s*' + literal + r'\s*\)', modifiers)
    if ".accessibilityLabel(" in modifiers and not label: return None
    title = re.match(r'\w+\(\s*' + literal, control.get("carrierInvocation", control["invocation"])) if control.get("hasTextTitle") else None
    label_content = re.search(r'\b(?:Text|Label|LabeledContent)\(\s*' + literal, control["label"])
    prompt = re.search(r'AppInputPrompt\.text\(\s*' + literal + r'\s*\)', control["invocation"])
    selector = label or title or label_content or prompt
    return ("label", (selector[1],)) if selector else None


def gesture_actions(control: dict, facts: dict, types, path: str) -> set[str]:
    kinds = {'MagnificationGesture': 'pinch', 'MagnifyGesture': 'pinch', 'RotationGesture': 'rotate',
        'LongPressGesture': 'press', 'TapGesture': 'tap', 'DragGesture': 'pan'}
    invocation = next((node for node in facts.get('invocations', [])
        if node['start'] == control['start'] and node.get('value') == control['invocation']), None)
    if not invocation or not invocation.get('argumentRanges'): return {'pan'}
    start, end = invocation['argumentRanges'][0]
    closures = facts.get('callableRanges', []) + facts.get('inlineClosureRanges', [])
    return {kinds[name] for node in facts.get('invocations', [])
        if start <= node['start'] < end and not any(start <= closure['start'] <= node['start'] < closure['end']
            for closure in closures)
        if (name := types.terminal_name(path, node.get('calledExpression', ''), node['scope']).removeprefix('SwiftUI.')) in kinds} or {'pan'}


def source_runtime_interaction_findings(syntax: dict[str, dict], documented: dict[str, tuple[dict, set]], evidence: list[dict]) -> list[str]:
    from validation_compilation import active_swift_source
    from swift_type_index import SwiftTypeIndex
    types = SwiftTypeIndex(syntax)
    actions, native_actions, gestures = SWIFTUI_MODIFIER_ACTIONS, SWIFTUI_CONTROL_ACTIONS, SWIFTUI_GESTURE_MODIFIERS
    errors = []
    selectors = Counter()
    contracts = {}
    expressions = {}
    carriers = {}
    native = native_runtime_controls(syntax)
    for path, facts in syntax.items():
        if any(Path(path).is_relative_to(ROOT / root) for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")): continue
        active = active_swift_source(Path(path).read_text(), "ui", path=path).encode() if Path(path).is_file() else None
        for control in facts.get("accessibilityControls", []) + facts.get("accessibilityControlCandidates", []) + native.get(path, []):
            if "nativeAction" not in control:
                control = dict(control, name=resolved_interaction_name(types, path, dict(control, value=control["name"])))
                if control["name"] not in native_actions.keys() | gestures | actions.keys(): continue
            if active is not None and active[control["start"]:control["start"] + 1] == b" ": continue
            source = Path(path).relative_to(ROOT).as_posix() + ":" + (".".join(control["scope"]) or "global")
            journeys = documented.get(source, ({}, set()))[1]
            tests = {journey for journey in journeys if not journey.startswith("manual:")}
            if not tests and journeys and all(manual_source_matches(source, journey) for journey in journeys): continue
            selector = interaction_selector(control, syntax)
            if selector is None:
                errors.append(f"源码交互需要明确的标识或标签合同：{source} · {control['name']} · {control['start']}")
                continue
            kind, names = selector
            action = control.get("nativeAction") or ("tap" if control["name"] == "onTapGesture" else "press" if control["name"] == "onLongPressGesture" else "gesture" if control["name"] in gestures else actions.get(control["name"], native_actions.get(control["name"], "")))
            required = gesture_actions(control, facts, types, path) if action == "gesture" else {action}
            if control["name"] == "accessibilityAction":
                named = re.search(r'accessibilityAction\(\s*named:\s*"((?:[^"\\]|\\.)+)"', control["invocation"])
                if named: action += ":" + named[1]
                required = {action}
            for action in required:
                key = (source, kind, names, action)
                selectors[key] += 1
                contracts[key] = tests
                expressions.setdefault(key, set()).add(control["expression"])
                carriers.setdefault(key, set()).add((path, control['start']))
    def shares_carrier(key, other):
        native_carrier = len(expressions[key]) == 1 and next(iter(expressions[key])).startswith("UIKit:")
        return (key[0] == other[0] or native_carrier) and key[1:3] == other[1:3] and key[3] != other[3] \
            and (len(carriers[key]) == 1 and carriers[key] == carriers[other]
                or any(action in {"scroll", "keyboard"} or action.startswith("accessibility") for action in (key[3], other[3]))) \
            and len(expressions[key]) == 1 and expressions[key] == expressions[other]
    demands = []
    for (source, kind, names, action), count in selectors.items():
        key = (source, kind, names, action)
        overlaps = any(other != key and other[1:3] == (kind, names) and not shares_carrier(key, other)
            and contracts[other] & contracts[(source, kind, names, action)] for other in selectors)
        if count > 1 or overlaps:
            errors.append(f"源码交互需要明确的标识区分分支：{source} · {' | '.join(names)}")
        patterns = [".+".join(re.escape(part) for part in re.split(r'\\\((?:[^()]|\([^()]*\))*\)', name)) for name in names]
        def matches(row):
            scoped = any(all(re.search(r"(?<!\w)" + re.escape(part) + r"(?!\w)", row.get("scope", ""))
                for part in journey.split("/")) for journey in contracts[(source, kind, names, action)])
            value = row.get(kind, "").strip()
            accepted_actions = {"tap", "selection"} if action == "selection" else {"swipe", "drag"} if action == "pan" else {"scroll", "scroll-fit"} if action == "scroll" else {action}
            return scoped and bool(accepted_actions & set(row.get("actions", []))) and any(re.fullmatch(pattern, value) is not None
                or kind == "label" and re.match(pattern + r",\s", value) is not None for pattern in patterns)
        shared = any(shares_carrier(key, other) for other in selectors)
        visited = {(row.get("instance") or json.dumps(row, sort_keys=True), action if shared else "") for row in evidence if matches(row)}
        demands.extend(((source, names), visited) for _ in range(count))
    owners = {}
    def assign(index, seen):
        for instance in sorted(demands[index][1] - seen):
            seen.add(instance)
            if instance not in owners or assign(owners[instance], seen):
                owners[instance] = index
                return True
        return False
    for index, ((source, names), _) in enumerate(demands):
        if not assign(index, set()): errors.append(f"源码交互需要独立访问证据：{source} · {' | '.join(names)}")
    return list(dict.fromkeys(errors))


def check_ui_test_inventory(errors: list[str], syntax: dict[str, dict]) -> None:
    """Keep the interaction map aligned with every executable UI journey."""
    from validation_test_areas import test_inventory
    from validation_provenance import normalized_test_id
    actual = {normalized_test_id(test) for test in test_inventory("ui")}
    document = (ROOT / "docs/UI_INTERACTION_COVERAGE.md").read_text()
    documented = set(re.findall(r"\b(\w+UITests/test\w+)\b", document))
    errors.extend(f"UI interaction map missing: {name}" for name in sorted(actual - documented))
    errors.extend(f"UI interaction map references an absent journey: {name}" for name in sorted(documented - actual))
    sources = documented_interactions()
    errors.extend(source_inventory_findings(syntax, sources, actual))
    errors.extend(error for error in source_runtime_interaction_findings(syntax, sources, []) if "明确的标识" in error)


def check_accessibility_coverage(errors: list[str], syntax: dict[str, dict]) -> None:
    for path, facts in syntax.items():
        if not path.startswith(str(ROOT) + "/") or "/BIT101-iOSTests/" in path:
            continue
        for invocation in image_only_label_facts(facts):
            errors.append(
                f"{Path(path).relative_to(ROOT)}: {'.'.join(invocation['scope'])} 图片型操作控件需提供 accessibilityLabel"
                f"（{invocation['value'][:96].replace(chr(10), ' ')}）"
            )
