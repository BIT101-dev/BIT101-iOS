"""Focused workflow and source checks."""

from __future__ import annotations
from pathlib import Path
import importlib.util
import subprocess
import sys
from swift_source_index import swift_syntax_index_sources
from ui_design_contracts import (
    DERIVED_DESIGN_TOKEN,
    DIRECT_ANIMATION_DURATION,
    DIRECT_FLOATING_MATERIAL,
    DIRECT_FLOATING_SIZE,
    DIRECT_INPUT_PLACEHOLDER,
    DIRECT_OPACITY_ASSIGNMENT,
    DIRECT_OPACITY_LITERAL,
    DIRECT_PLAIN_LIST_STYLE,
    DIRECT_ROUNDED_RECTANGLE,
    DIRECT_SEMANTIC_COLOR_RULES,
    DIRECT_THUMBNAIL_GEOMETRY,
    DIRECT_VISUAL_RULES,
    PADDING_LITERAL,
    REPEATED_DESIGN_TOKEN,
    STACK_SPACING_LITERAL,
)
from ui_source_facts import (
    MAP_THEME_COLOR_CONTRACT,
    ROOT,
    call_name,
    has_component_declaration,
    image_only_label_facts,
    list_icon_findings,
    mask_comments,
    mask_literals_and_comments,
    pattern_nodes,
    rendered_view_has_marker,
    source_path,
)
from ui_rules import (
    alert_coverage_findings,
    interactive_list_row_findings,
    is_registered_map_theme_color_definition,
    is_reviewed_fixed_geometry,
)


CONTROL_SOURCE = r"""
import SwiftUI

struct ItemAlertSample: View {
    @State private var failure: AppAlert?
    var body: some View {
        Text("Sample").alert(
            item: $failure
        ) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
    }
}

struct AlternateAlertSample: View {
    @State private var failure: AppAlert?
    @State private var isPresented = false
    var body: some View {
        Text("Sample").alert("Failure", isPresented: $isPresented) {
            Button("Dismiss") {}
        } message: {
            Text(failure?.message ?? "")
        }
    }
}

struct ConfirmationAlertSample: View {
    @State private var failure: AppAlert?
    @State private var isPresented = false
    var body: some View {
        Text("Sample").alert("failure", isPresented: $isPresented) {
            Button("Dismiss") {}
        }
    }
}

struct DiagnosticConfirmationAlertSample: View {
    @State private var alert: AppAlert?
    @State private var isPresented = false
    var body: some View {
        Text("Sample")
            .alert("Save draft?", isPresented: $isPresented) {
                Button("Save") {
                    alert = AppAlert(title: "Save failed", message: "Retry")
                }
            }
            .diagnosticAlert(item: $alert)
    }
}

struct CourseEvaluationLinkScene: View {
    @State private var alert: AppAlert?
    @State private var diagnosticAlert: AppAlert?
    var body: some View {
        Text("Sample").alert(item: $alert) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }.diagnosticAlert(item: $diagnosticAlert)
    }
}

struct CourseEvaluationScene: View {
    @State private var expectedAlert: AppAlert?
    var body: some View {
        Text("Sample").alert(item: $expectedAlert) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
    }
}

struct ListIconSample: View {
    let iconName = "gearshape"
    var body: some View {
        List {
            Image(
                systemName: "person.fill"
            )
            Image(
                systemName: "checkmark.circle"
            )
            Image(systemName: iconName)
            Image(systemName: isDone ? "checkmark.circle" : "circle")
            Image(systemName: isDone ? "checkmark.circle" : iconName)
            Image(systemName: "checkmark.\(isDone ? "circle" : "square")")
            Image(systemName: safeSystemIcon(isDone: isDone))
            Image(systemName: unsafeSystemIcon(isDone: isDone))
        }
    }

    private func safeSystemIcon(isDone: Bool) -> String {
        return isDone ? "checkmark.circle.fill" : "circle"
    }

    private func unsafeSystemIcon(isDone: Bool) -> String {
        if isDone { return "checkmark.circle" }
        return dynamicName
    }
}

struct MissingButtonLabelSample: View {
    var body: some View {
        Button(action: {}) {
            Image(systemName: "magnifyingglass")
        }
    }
}

struct AccessibleButtonLabelSample: View {
    var body: some View {
        Button(action: {}) {
            Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("搜索")
    }
}

struct ImageMenuLabelWithTextItemsSample: View {
    var body: some View {
        Menu {
            Button("设置") {}
        } label: {
            Image(systemName: "ellipsis")
        }
    }
}

struct ImageButtonLabelWithTextActionSample: View {
    var body: some View {
        Button(action: { _ = Text("操作内容") }) {
            Image(systemName: "magnifyingglass")
        }
    }
}

struct AccessibleMenuLabelSample: View {
    var body: some View {
        Menu {
            Button("设置") {}
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel("更多")
        }
    }
}

struct MenuChildLabelScopeSample: View {
    var body: some View {
        Menu {
            Button(action: {}, label: {
                Image(systemName: "folder")
                    .accessibilityLabel("打开文件夹")
            })
        } label: {
            Image(systemName: "ellipsis")
        }
    }
}

struct UnrenderedHelperComponentSample: View {
    var body: some View { Text("Visible") }
    private func unusedContent() -> some View { AppFailureState() }
}

struct ReachableHelperComponentSample: View {
    var body: some View { helperContent() }
    private func helperContent() -> some View { AppFailureState() }
}

struct ActionClosureComponentSample: View {
    var body: some View {
        Button(action: { _ = AppFailureState() }) {
            Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("示例操作")
    }
}

struct TitledMenuSample: View {
    var body: some View {
        Menu("更多") {
            Button(action: {}) {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
    }
}

enum AppTagChip { case sample }
class AppVerificationSheet: View {}
extension AppSearchBarContainer: View {}
struct AppLoadingState {}
struct AppAvatarView: View { var body: some View { Text("avatar") } }
struct AppFixedColumnItem {}
"""


def source_boundary_findings() -> list[str]:
    facts, findings, visual_facts, wrapped_calls = verify_control_source_rules()
    row_source = verify_visual_source_rules(facts, findings, visual_facts, wrapped_calls)
    verify_row_source_rules(findings, row_source)
    return findings


def map_theme_color_contract_findings() -> list[str]:
    path = source_path(MAP_THEME_COLOR_CONTRACT[0])
    source = (
        "extension AppDesignSystem {\n    enum Map {\n        "
        + MAP_THEME_COLOR_CONTRACT[1]
        + "\n    }\n}"
    )
    start = source.encode("utf-8").find(b"Color.green")
    node = {"scope": ["AppDesignSystem", "Map"], "start": start}
    if not is_registered_map_theme_color_definition(path, source, node):
        return ["UI 检查器自测：地图主题令牌的精确源码例外无法识别"]

    unrelated_source = source.replace(
        MAP_THEME_COLOR_CONTRACT[1], "static let otherAccent = Color.green"
    )
    if is_registered_map_theme_color_definition(path, unrelated_source, node):
        return ["UI 检查器自测：地图主题令牌例外覆盖了相邻声明"]
    wrong_scope_node = {**node, "scope": ["OtherDesignSystem", "Map"]}
    if is_registered_map_theme_color_definition(path, source, wrong_scope_node):
        return ["UI 检查器自测：地图主题令牌例外覆盖了其它词法作用域"]
    return []


def verify_control_source_rules():
    checker = ROOT / "Scripts/check-code-quality.py"
    spec = importlib.util.spec_from_file_location("check_code_quality_ui_self_test", checker)
    if spec is None or spec.loader is None:
        raise AssertionError("\n".join(["UI 检查器自测无法加载 SwiftSyntax 索引器"]))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    from unittest.mock import patch
    from ui_source_facts import swift_files as scanned_files
    from ui_rules import check_design_token_boundaries

    extension_probes = [
        ROOT / name / "VisualProbe.swift"
        for name in ("BIT101Watch", "BIT101ScheduleWidgets", "BIT101WatchWidgets")
    ]
    scanned_files.cache_clear()
    with patch("swift_source_index.repository_swift_files", return_value=extension_probes):
        observed = scanned_files()
    scanned_files.cache_clear()
    extension_findings = []
    if set(observed) != set(extension_probes):
        extension_findings.append("UI 扩展视觉自测：Watch 与两种 Widget 进入扫描范围")
    visual_source = 'struct Screen: View { var body: some View { Text("内容").opacity(0.9) } }'
    visual_facts = swift_syntax_index_sources({str(path): visual_source for path in observed})
    visual_errors = []
    with (
        patch("ui_rules.swift_files", return_value=observed),
        patch("ui_rules.source_text", return_value=visual_source),
    ):
        check_design_token_boundaries(visual_errors, visual_facts)
    for path in extension_probes:
        if not any(path.relative_to(ROOT).as_posix() in error for error in visual_errors):
            extension_findings.append("UI 扩展视觉自测：新增透明度常量触发设计规则")

    source = CONTROL_SOURCE
    try:
        facts = swift_syntax_index_sources({"ui-self-test.swift": source})["ui-self-test.swift"]
    except (OSError, subprocess.CalledProcessError, RuntimeError, KeyError) as error:
        raise AssertionError("\n".join([f"UI 检查器自测无法解析内存 Swift 样例：{error}"]))

    findings: list[str] = list(extension_findings)
    if rendered_view_has_marker(facts, ["UnrenderedHelperComponentSample"], "AppFailureState"):
        findings.append("UI 检查器自测：未引用的 View 辅助方法满足页面契约")
    if not rendered_view_has_marker(facts, ["ReachableHelperComponentSample"], "AppFailureState"):
        findings.append("UI 检查器自测：body 引用的 View 辅助方法未进入契约")
    if rendered_view_has_marker(facts, ["ActionClosureComponentSample"], "AppFailureState"):
        findings.append("UI 检查器自测：交互回调中的组件满足页面契约")
    item_alerts = alert_coverage_findings(facts, Path("ui-self-test.swift"))
    expected_invalid = {
        "ItemAlertSample",
        "AlternateAlertSample",
    }
    if len(item_alerts) != len(expected_invalid) or not all(
        any(view_name in finding for finding in item_alerts) for view_name in expected_invalid
    ):
        findings.append(
            "UI 检查器自测：SwiftSyntax 未识别 item 与 isPresented 两种 AppAlert 展示路径"
        )
    diagnostic_scope = {
        "typedVariables": [
            variable
            for variable in facts["typedVariables"]
            if variable["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "alertModifiers": [
            alert
            for alert in facts["alertModifiers"]
            if alert["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "calls": [
            call
            for call in facts["calls"]
            if call["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "invocations": [
            invocation
            for invocation in facts["invocations"]
            if invocation["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
    }
    if alert_coverage_findings(diagnostic_scope, Path("ui-self-test.swift")):
        findings.append("UI 检查器自测：诊断提示与确认弹层共享 AppAlert 时的归属识别")

    allowed_alerts = [
        finding
        for view_name in ("CourseEvaluationLinkScene", "CourseEvaluationScene")
        for finding in alert_coverage_findings(
            {
                "typedVariables": [
                    variable
                    for variable in facts["typedVariables"]
                    if variable["scope"][-1] == view_name
                ],
                "alertModifiers": [
                    alert for alert in facts["alertModifiers"] if alert["scope"][-1] == view_name
                ],
            },
            Path("ui-self-test.swift"),
        )
    ]
    if allowed_alerts:
        findings.append("UI 检查器自测：既有用户输入提示例外未按 View 与绑定精确匹配")

    icon_findings = list_icon_findings(Path("UI/ListIconSample.swift"), facts)
    if (
        len(icon_findings) != 5
        or not any("person.fill" in finding for finding in icon_findings)
        or sum("iconName" in finding for finding in icon_findings) != 2
        or not any(r"checkmark.\(" in finding for finding in icon_findings)
        or not any("unsafeSystemIcon" in finding for finding in icon_findings)
    ):
        findings.append("UI 检查器自测：静态、动态与混合分支列表图标契约识别异常")

    button_labels = image_only_label_facts(facts)
    expected_image_only_controls = {
        "MissingButtonLabelSample",
        "ImageMenuLabelWithTextItemsSample",
        "ImageButtonLabelWithTextActionSample",
        "MenuChildLabelScopeSample",
    }
    observed_image_only_controls = {item["scope"][-1] for item in button_labels}
    if observed_image_only_controls != expected_image_only_controls:
        findings.append("UI 检查器自测：控件标签闭包与菜单项/操作闭包归属识别异常")

    wrapped_calls = """
    withAnimation(
        .spring(
            duration: 0.2
        )
    ) {}
    thumbnailButton(
        image: image,
        width: 40
    )
    .background(
        .ultraThinMaterial,
        in: Circle()
    )
    .frame(
        width: 42,
        height: 42
    )
    """
    for source in (
        r'Text("\(format("https://example.invalid"))").padding(7)',
        r'Text(#"\#(format("https://example.invalid"))"#).padding(7)',
        'Text("""\n\\(format("https://example.invalid"))\n""").padding(7)',
    ):
        assert PADDING_LITERAL.search(mask_literals_and_comments(source))
        assert mask_comments(source) == source
    interpolation = r'Text("\(format("https://example.invalid") /* padding(7) */)").padding(8)'
    assert "https://example.invalid" in mask_comments(interpolation)
    assert "/* padding(7) */" not in mask_comments(interpolation)
    assert len(mask_literals_and_comments(interpolation)) == len(interpolation)
    return facts, findings, visual_facts, wrapped_calls


def verify_visual_source_rules(facts, findings, visual_facts, wrapped_calls):
    masked_calls = mask_literals_and_comments(wrapped_calls)
    wrapped_patterns = (
        DIRECT_ANIMATION_DURATION,
        DIRECT_THUMBNAIL_GEOMETRY,
        DIRECT_FLOATING_MATERIAL,
        DIRECT_FLOATING_SIZE,
    )
    if not all(pattern.search(masked_calls) for pattern in wrapped_patterns):
        findings.append("UI 检查器自测：多行视觉规则调用识别异常")

    visual_source = (
        '\nimport SwiftUI\nstruct VisualRuleSample: View {\n    @State private var query = ""\n   '
        " private let sampleOpacity: Double = 0.4\n    private let fixedWidth: CGFloat = 40\n    p"
        "rivate let derivedWidth = AppDesignSystem.Size.avatar * 2\n    private let repeatedWidth "
        "= AppDesignSystem.Size.avatar + AppDesignSystem.Size.avatar\n\n    var body: some View {"
        '\n        Text("https://example.invalid RoundedRectangle() Color.orange .frame(width: 42,'
        ' height: 42) TextField(\\"提示\\", text: $query)")\n        RoundedRectangle(\n            '
        "cornerRadius: 12\n        )\n        Color(uiColor: .systemBackground)\n        Color.acc"
        "entColor\n        Color.orange\n        Color.red\n        Color.blue\n        Color.gree"
        "n\n        Color.gray\n        Color.pink\n        Color.indigo\n        Color.teal\n    "
        '    Color.brown\n        Color.primary\n        Color.secondary\n        Text("Rule")\n  '
        "          .padding(12)\n            .opacity(0.5)\n            .foregroundStyle(.secondar"
        "y)\n            .font(.body)\n            .blur(radius: 2)\n            .frame(width: 40,"
        " height: 40)\n            .cornerRadius(8)\n            .frame(minHeight: 44)\n        Gr"
        "idItem(.adaptive(minimum: 32))\n        StrokeStyle(lineWidth: 2, dash: [1, 2])\n        "
        "EdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)\n        VStack(spacing: 12) {\n  "
        '          HStack { Text("row") }\n            HStack(spacing: 12) { Text("row") }\n      '
        '  }\n        TextField("搜索提示", text: $query)\n        List { Text("row") }\n            .'
        'listStyle(.insetGrouped)\n            .listSectionSpacing(12)\n        List { Text("row")'
        ' }\n            .listStyle(.plain)\n        Section(header: { Text("标题") }) { Text("row")'
        " }\n        withAnimation(\n            .spring(\n                duration: 0.2\n        "
        "    )\n        ) {}\n        thumbnailButton(\n            image: image,\n            wid"
        "th: 40\n        )\n        .background(\n            .ultraThinMaterial,\n            in:"
        " Circle()\n        )\n        .frame(\n            width: 42,\n            height: 42\n  "
        "      )\n    }\n}\n"
    )
    try:
        visual_facts = swift_syntax_index_sources({"visual-rule-self-test.swift": visual_source})[
            "visual-rule-self-test.swift"
        ]
    except (OSError, subprocess.CalledProcessError, RuntimeError, KeyError) as error:
        raise AssertionError("\n".join([f"UI 检查器自测无法解析视觉规则样例：{error}"]))
    rectangle_nodes = pattern_nodes(visual_facts, DIRECT_ROUNDED_RECTANGLE)
    if len(rectangle_nodes) != 1 or not DIRECT_ROUNDED_RECTANGLE.search(
        mask_literals_and_comments(rectangle_nodes[0]["value"])
    ):
        findings.append("UI 检查器自测：AST 视觉规则未识别多行形状调用")
    text_invocations = [
        invocation
        for invocation in visual_facts["invocations"]
        if call_name(invocation["calledExpression"]) == "Text"
        and "https://example.invalid" in invocation["value"]
    ]
    if not all(
        any(
            pattern.search(mask_literals_and_comments(node["value"]))
            for node in pattern_nodes(visual_facts, pattern)
        )
        for pattern in wrapped_patterns
    ):
        findings.append("UI 检查器自测：AST 范围未覆盖多行视觉规则表达式")
    coverage_patterns = [
        *(pattern for pattern, _ in DIRECT_VISUAL_RULES),
        *(pattern for pattern, _ in DIRECT_SEMANTIC_COLOR_RULES),
        DIRECT_OPACITY_LITERAL,
        DIRECT_OPACITY_ASSIGNMENT,
        PADDING_LITERAL,
        STACK_SPACING_LITERAL,
        DIRECT_PLAIN_LIST_STYLE,
        DERIVED_DESIGN_TOKEN,
        REPEATED_DESIGN_TOKEN,
    ]
    text_starts = {int(node.get("start", -1)) for node in text_invocations}
    text_candidate_rules = [
        pattern.pattern
        for pattern in dict.fromkeys(coverage_patterns)
        for node in pattern_nodes(visual_facts, pattern)
        if int(node.get("start", -2)) in text_starts
    ]
    if text_candidate_rules:
        findings.append(
            "UI 检查器自测：Text 文案进入视觉规则候选节点（"
            + ", ".join(text_candidate_rules)
            + "）"
        )
    uncovered_rules = [
        pattern.pattern
        for pattern in dict.fromkeys(coverage_patterns)
        if not any(
            pattern.search(
                mask_comments(node["value"])
                if pattern is DIRECT_INPUT_PLACEHOLDER
                else mask_literals_and_comments(node["value"])
            )
            for node in pattern_nodes(visual_facts, pattern)
        )
    ]
    if uncovered_rules:
        examples = {
            pattern.pattern: [
                node["value"][:72].replace("\n", " ")
                for node in pattern_nodes(visual_facts, pattern)[:2]
            ]
            for pattern in dict.fromkeys(coverage_patterns)
            if pattern.pattern in uncovered_rules
        }
        findings.append("UI 检查器自测：AST 规则映射缺少样例：" + repr(examples))
    reviewed_path = source_path("Modules/CommunityUI/Sources/CommunityPosterViews.swift")
    unregistered_source = "thumbnailButton(image: anotherImage, index: 1, width: 52)"
    if is_reviewed_fixed_geometry(
        reviewed_path,
        unregistered_source,
        DIRECT_THUMBNAIL_GEOMETRY,
        {"value": unregistered_source},
    ):
        findings.append("UI 检查器自测：登记几何例外覆盖同文件的其它表达式")

    declarations = facts["declarations"]
    if has_component_declaration("AppTagChip", declarations):
        findings.append("UI 检查器自测：非 View 同名枚举通过公共组件声明检查")
    if has_component_declaration("AppVerificationSheet", declarations):
        findings.append("UI 检查器自测：同名 class 通过公共组件声明检查")
    if has_component_declaration("AppSearchBarContainer", declarations):
        findings.append("UI 检查器自测：同名 extension 通过公共组件声明检查")
    if has_component_declaration("AppLoadingState", declarations):
        findings.append("UI 检查器自测：未实现 View 的同名结构通过公共组件声明检查")
    if not has_component_declaration("AppAvatarView", declarations):
        findings.append("UI 检查器自测：View 公共组件声明识别失败")
    if not has_component_declaration("AppFixedColumnItem", declarations):
        findings.append("UI 检查器自测：无协议继承的模型结构声明识别失败")
    row_source = (
        '\nimport SwiftUI\nstruct NeutralTitle: View {\n    var body: some View { Text("标题").foreg'
        "roundStyle(.tint) }\n}\nstruct RowColors: View {\n    var body: some View {\n        List"
        ' {\n            Section { ScrollView { Text("容器内容") } }\n            Picker("时间轴", select'
        'ion: $axis) { Text("线性").tag(0) }\n            Toggle("开关", isOn: $enabled).appInteractiv'
        'eListRow()\n            Button {} label: { Text("标题").foregroundStyle(.tint) }.appInterac'
        'tiveListRow()\n            Button("删除", role: .destructive) {}.appInteractiveListRow()\n '
        '           Button("删除正确", role: .destructive) {}.appInteractiveListRow(isDestructive: tru'
        'e)\n            NavigationLink(destination: Text("目标")) { NeutralTitle() }.appInteractive'
        'ListRow()\n            Button("伪造") { print(".appInteractiveListRow()") }\n            Bu'
        'tton("覆盖颜色") {}.appInteractiveListRow().foregroundStyle(.tint)\n            Button("系统填充按'
        '钮") {}.buttonStyle(.borderedProminent)\n            Button("冲突填充按钮") {}.buttonStyle(.bord'
        'eredProminent).appInteractiveListRow()\n            Button {} label: { LabeledContent("左侧'
        '") { Text("右侧").foregroundStyle(.secondary) } }.appInteractiveListRow()\n            Butt'
        'on {} label: {\n                LabeledContent { Text("右侧").foregroundStyle(.secondary) }'
        ' label: { Text("左侧").foregroundStyle(.tint) }\n            }.appInteractiveListRow()\n   '
        '         helperRows\n        }\n        .toolbar { Button("关闭") {} }\n        .overlay { '
        'floatingButton }\n    }\n    private var helperRows: some View { Button("计算属性行") {} }\n  '
        '  private var floatingButton: some View { Button("浮动按钮") {} }\n}\n'
    )
    return row_source


def verify_row_source_rules(findings, row_source):
    row_source = row_source.replace(
        "            helperRows",
        "            helperRows\n            calendarSurface",
    ).replace(
        "    private var helperRows:",
        '    private var calendarSurface: some View { Text("课表")'
        ".appBrowserFloatingActions { addActions } }\n"
        '    private var addActions: some View { Menu { Button("新增") {} }'
        ' label: { Text("加号") } }\n'
        "    private var helperRows:",
    )
    row_path = ROOT / ".build/static-audit/row-color-self-test.swift"
    row_syntax = swift_syntax_index_sources({str(row_path): row_source})
    row_findings = interactive_list_row_findings(row_path, row_syntax[str(row_path)], row_syntax)
    if len(row_findings) != 11:
        findings.append(
            f"UI 检查器自测：列表标题、颜色覆盖、删除警示色、子组件、右侧值、计算属性、填充按钮及字符串界限应报告 11 项，实际 {len(row_findings)} 项"
        )
