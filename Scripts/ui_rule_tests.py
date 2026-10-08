"""Executable boundary checks for UI and design rules."""
from __future__ import annotations

from pathlib import Path
import importlib.util
import subprocess
import sys
from swift_source_index import swift_syntax_index_sources

from ui_design_contracts import (
    DERIVED_DESIGN_TOKEN, DIRECT_ANIMATION_DURATION, DIRECT_FLOATING_MATERIAL,
    DIRECT_FLOATING_SIZE, DIRECT_INPUT_PLACEHOLDER, DIRECT_OPACITY_ASSIGNMENT,
    DIRECT_OPACITY_LITERAL, DIRECT_PLAIN_LIST_STYLE, DIRECT_ROUNDED_RECTANGLE,
    DIRECT_SEMANTIC_COLOR_RULES, DIRECT_THUMBNAIL_GEOMETRY, DIRECT_VISUAL_RULES, PADDING_LITERAL,
    REPEATED_DESIGN_TOKEN, STACK_SPACING_LITERAL,
)

from ui_source_facts import (
    MAP_THEME_COLOR_CONTRACT, ROOT, SOURCE_ROOT, ast_has_marker, call_name, child_view_entries,
    has_component_declaration, image_only_label_facts, list_icon_findings, mask_comments,
    mask_literals_and_comments, pattern_nodes, rendered_view_has_marker,
    selection_control_has_feedback, source_path, view_or_child_has_marker,
)

from ui_rules import (
    alert_coverage_findings, haptic_entry_findings, interactive_list_row_findings,
    is_registered_map_theme_color_definition, is_reviewed_fixed_geometry,
    interaction_source_inventory, source_inventory_findings,
    source_runtime_interaction_findings,
)


def interaction_inventory_boundary_findings() -> list[str]:
    path = str(ROOT / "Modules/Example/Sources/Example.swift")
    original = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Button("入口") {} } }'})
    manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(original).items()}
    findings = []
    if source_inventory_findings(original, manifest, {"ExampleUITests/testScreen"}): findings.append("UI 清单自测：已归属交互")
    for change in ('struct Unvisited: View { var body: some View { Button("新页面") {} } }',
                   'extension Screen { var hiddenControl: some View { Toggle("新增", isOn: .constant(false)) } }'):
        changed = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Button("入口") {} } }\n' + change})
        if not source_inventory_findings(changed, manifest, {"ExampleUITests/testScreen"}): findings.append("UI 清单自测：新增页面与交互进入门禁")
    if not source_inventory_findings(original, manifest, set()): findings.append("UI 清单自测：验收用例删除进入门禁")
    evidence = [{"scope": "ExampleUITests/testScreen / 页面", "label": "入口", "identifier": "", "actions": ["tap"]}]
    if source_runtime_interaction_findings(original, manifest, evidence): findings.append("UI 清单自测：源码声明对应实际访问")
    changed = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Button("入口") {}; if expanded { Button("新增条件分支") {} } } }'})
    expanded = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(changed).items()}
    if not source_runtime_interaction_findings(changed, expanded, evidence): findings.append("UI 清单自测：条件分支需要独立访问证据")
    mixed = {key: (controls, {"ExampleUITests/testScreen", "manual:watch"}) for key, controls in interaction_source_inventory(changed).items()}
    if not source_inventory_findings(changed, mixed, {"ExampleUITests/testScreen"}): findings.append("UI 清单自测：手工归属需要匹配平台")
    if not source_runtime_interaction_findings(changed, mixed, evidence): findings.append("UI 清单自测：手工归属保留自动访问要求")
    if not source_runtime_interaction_findings(original, manifest, [dict(evidence[0], label="另一个入口")]): findings.append("UI 清单自测：标题按完整语义匹配")
    duplicate = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Button("入口") {}; if expanded { Button("入口") {} } } }'})
    duplicate_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(duplicate).items()}
    if not source_runtime_interaction_findings(duplicate, duplicate_manifest, evidence): findings.append("UI 清单自测：同名声明需要独立控件证据")
    if not source_runtime_interaction_findings(duplicate, duplicate_manifest,
            [dict(evidence[0], instance="presentation.first"), dict(evidence[0], instance="presentation.second")]):
        findings.append("UI 清单自测：重复呈现对应独立源码标识")
    for kind, action in [("refreshable", "refresh"), ("onSubmit", "submit"), ("onDelete", "delete"), ("onMove", "move")]:
        callback = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Color.clear.' + kind
            + ' { interactionEvidence?("callback", "' + action + '"); run() } } }'})
        callback_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(callback).items()}
        visited = dict(evidence[0], identifier="callback", instance="callback", actions=["input"])
        if not source_runtime_interaction_findings(callback, callback_manifest, [visited]):
            findings.append("UI 清单自测：回调要求实际执行对应动作")
        if source_runtime_interaction_findings(callback, callback_manifest, [dict(visited, actions=[action])]):
            findings.append("UI 清单自测：实际回调执行进入覆盖证据")
    dynamic = swift_syntax_index_sources({path: r'struct Screen: View { var body: some View { Button(title) {}.accessibilityIdentifier("item.\(id)") } }'})
    dynamic_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(dynamic).items()}
    if not source_runtime_interaction_findings(dynamic, dynamic_manifest, evidence): findings.append("UI 清单自测：动态标识需要匹配访问")
    if source_runtime_interaction_findings(dynamic, dynamic_manifest, [dict(evidence[0], identifier="item.42")]): findings.append("UI 清单自测：动态标识模板接受实际访问")
    for control in ('Toggle("启用", isOn: .constant(false))', 'Picker("校区", selection: .constant(0)) { Text("主校区").tag(0) }',
                    'DatePicker("日期", selection: .constant(Date()))', 'TextField("输入", text: .constant(""))', 'Button(dynamicTitle) {}'):
        hidden = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { ' + control + ' } }'})
        hidden_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(hidden).items()}
        if not source_runtime_interaction_findings(hidden, hidden_manifest, []): findings.append("UI 清单自测：输入、选择及动态标题需要实际身份合同")
    for kind, invocation, expected in [("TextField", 'TextField("输入", text: .constant(""))', "input"),
            ("SecureField", 'SecureField("输入", text: .constant(""))', "input"),
            ("TextEditor", 'TextEditor(text: .constant(""))', "input"),
            ("Toggle", 'Toggle("启用", isOn: .constant(false))', "tap"),
            ("Slider", 'Slider(value: .constant(0.5))', "gesture"),
            ("Stepper", 'Stepper("数值", value: .constant(1))', "tap")]:
        control = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { ' + invocation + '.accessibilityIdentifier("control") } }'})
        control_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(control).items()}
        row = dict(evidence[0], identifier="control", instance="control", actions=["tap" if expected != "tap" else "input"])
        if not source_runtime_interaction_findings(control, control_manifest, [row]): findings.append("UI 清单自测：控件需要对应动作类型")
        if source_runtime_interaction_findings(control, control_manifest, [dict(row, actions=[expected])]): findings.append("UI 清单自测：实际控件动作进入证据")
    scopes = swift_syntax_index_sources({path: 'struct FirstView: View { var body: some View { Button("取消") {} } }; struct SecondView: View { var body: some View { Button("取消") {} } }'})
    scope_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(scopes).items()}
    cancel = dict(evidence[0], label="取消", instance="cancel.first")
    if not source_runtime_interaction_findings(scopes, scope_manifest, [cancel]): findings.append("UI 清单自测：跨作用域声明需要独立身份")
    if not source_runtime_interaction_findings(scopes, scope_manifest, [cancel, dict(cancel, instance="cancel.second")]): findings.append("UI 清单自测：重复呈现保留跨作用域标识要求")
    scopes = swift_syntax_index_sources({path: 'struct FirstView: View { var body: some View { Button("取消") {}.accessibilityIdentifier("first.cancel") } }; struct SecondView: View { var body: some View { Button("取消") {}.accessibilityIdentifier("second.cancel") } }'})
    cancel = dict(cancel, identifier="first.cancel")
    second = dict(cancel, identifier="second.cancel", instance="cancel.second")
    if source_runtime_interaction_findings(scopes, scope_manifest, [cancel, second]): findings.append("UI 清单自测：明确标识覆盖同名作用域")
    keys = list(scope_manifest)
    scope_manifest[keys[0]] = (scope_manifest[keys[0]][0], {"ExampleUITests/testScreen", "ExampleUITests/testOther"})
    if source_runtime_interaction_findings(scopes, scope_manifest, [second, dict(cancel, scope="ExampleUITests/testOther", instance="cancel.other")]): findings.append("UI 清单自测：共享流程按完整匹配分配证据")
    gesture = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Color.clear.onTapGesture { open() }.accessibilityIdentifier("carrier").toolbar { Button("旁路") {}.accessibilityIdentifier("child") } } }'})
    gesture_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(gesture).items()}
    child = dict(evidence[0], identifier="child", instance="child")
    carrier = dict(evidence[0], identifier="carrier", instance="carrier", actions=["gesture"])
    if not source_runtime_interaction_findings(gesture, gesture_manifest, [child, carrier]): findings.append("UI 清单自测：手势需要对应动作")
    if source_runtime_interaction_findings(gesture, gesture_manifest, [child, dict(carrier, actions=["tap"])]): findings.append("UI 清单自测：手势载体与子控件分别匹配")
    return findings


def ast_marker_boundary_findings() -> list[str]:
    facts = {
        "declarations": [{"kind": "struct", "name": "SampleView"}],
        "calls": [{"value": "AppFailureState", "scope": ["SampleView"]}],
        "invocations": [
            {"value": 'Text("课程暂未发布说明")', "scope": ["SampleView"]}
        ],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "identifiers": ["AppFailureState", "Text"],
        "stringSegments": [{"value": "课程暂未发布说明", "scope": ["SampleView"]}],
    }
    findings = []
    haptic_path = ROOT / "Modules/DesignSystemKit/Sources/RelocatedFeedback.swift"
    haptic_source = '''
extension View {
    public func appSelectionFeedback<T: Equatable>(trigger: T) -> some View {
        sensoryFeedback(.selection, trigger: trigger)
    }
    public func appImpactFeedback<T: Equatable>(trigger: T) -> some View {
        sensoryFeedback(.impact, trigger: trigger)
    }
}
'''
    haptic_syntax = swift_syntax_index_sources({str(haptic_path): haptic_source})
    if haptic_entry_findings({haptic_path: haptic_source}, haptic_syntax)[0]:
        findings.append("UI 契约规则边界自检失败：公共触感声明应支持文件迁移")
    wrong_source = haptic_source.replace(".selection", ".impact")
    wrong_syntax = swift_syntax_index_sources({str(haptic_path): wrong_source})
    if len(haptic_entry_findings({haptic_path: wrong_source}, wrong_syntax)[0]) != 1:
        findings.append("UI 契约规则边界自检失败：公共触感声明需要对应系统动作")
    if not ast_has_marker(facts, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：组件调用识别")
    if ast_has_marker(facts, "AppFailureStates"):
        findings.append("UI 契约规则边界自检失败：标识符精确匹配")
    if not ast_has_marker(facts, 'Text("课程暂未发布说明")'):
        findings.append("UI 契约规则边界自检失败：调用文案联合识别")
    if ast_has_marker(facts, 'Text("课程未发布说明")'):
        findings.append("UI 契约规则边界自检失败：字符串片段精确匹配")
    unrelated_scope_facts = {
        **facts,
        "calls": [{"value": "AppFailureState", "scope": ["OtherView"]}],
        "stringSegments": [{"value": "课程暂未发布说明", "scope": ["OtherView"]}],
    }
    if ast_has_marker(unrelated_scope_facts, "AppFailureState", ["SampleView"]):
        findings.append("UI 契约规则边界自检失败：组件调用严格遵循当前 View 作用域")
    qualified_facts = {
        **facts,
        "calls": [{"value": "AppDateText.relativeText", "scope": ["SampleView"]}],
    }
    if not ast_has_marker(qualified_facts, "AppDateText", ["SampleView"]):
        findings.append("UI 契约规则边界自检失败：模块限定调用的根类型识别")

    scattered_facts = {
        "declarations": [],
        "calls": [],
        "invocations": [{"value": 'Text("其它文案")', "scope": ["SampleView"]}],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "identifiers": ["AppFailureState", "Text"],
        "stringSegments": [{"value": "课程暂未发布说明", "scope": ["SampleView"]}],
    }
    if ast_has_marker(scattered_facts, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：分散标识符被识别为组件契约")
    if ast_has_marker(scattered_facts, 'Text("课程暂未发布说明")'):
        findings.append("UI 契约规则边界自检失败：跨节点调用与文案被识别为同一表达式")
    literal_only_facts = {
        **scattered_facts,
        "calls": [{"value": "Text", "scope": ["SampleView"]}],
        "invocations": [{"value": 'Text("AppFailureState")', "scope": ["SampleView"]}],
        "stringSegments": [{"value": "AppFailureState", "scope": ["SampleView"]}],
    }
    if ast_has_marker(literal_only_facts, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：源码字面量被识别为组件调用")
    control = {"name": "Toggle", "invocation": 'Toggle("sample", isOn: $value)', "scope": ["SampleView"]}
    attached_modifier = {
        "name": "appSelectionFeedback",
        "base": 'Toggle("sample", isOn: $value)',
        "scope": ["SampleView"],
    }
    unrelated_modifier = {
        **attached_modifier,
        "base": 'Button("sample") {}',
        "scope": ["OtherView"],
    }
    if not selection_control_has_feedback(control, [attached_modifier]):
        findings.append("UI 契约规则边界自检失败：控件上的触感修饰器识别")
    if selection_control_has_feedback(control, [unrelated_modifier]):
        findings.append("UI 契约规则边界自检失败：控件与触感修饰器保持同一表达式")

    parent_facts = {
        "declarations": [{"kind": "struct", "name": "ParentView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [{"value": "ChildView", "scope": ["ParentView"]}],
        "invocations": [],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "scopedIdentifiers": [],
        "stringSegments": [],
    }
    child_facts = {
        "declarations": [{"kind": "struct", "name": "ChildView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [{"value": "appSelectionFeedback", "scope": ["ChildView"]}],
        "invocations": [],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "scopedIdentifiers": [],
        "stringSegments": [],
    }
    delegated_syntax = {
        str(SOURCE_ROOT / "moved/Parent.swift"): parent_facts,
        str(SOURCE_ROOT / "shared/Child.swift"): child_facts,
    }
    if not view_or_child_has_marker(delegated_syntax, parent_facts, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：直接子 View 的公共触感调用识别")
    wrapped_parent_facts = {
        **parent_facts,
        "calls": [{"value": "WrapperView", "scope": ["ParentView"]}],
    }
    wrapper_facts = {
        **parent_facts,
        "declarations": [{"kind": "struct", "name": "WrapperView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [{"value": "LeafView", "scope": ["WrapperView"]}],
    }
    leaf_facts = {
        **child_facts,
        "declarations": [{"kind": "struct", "name": "LeafView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [{"value": "appSelectionFeedback", "scope": ["LeafView"]}],
    }
    deep_syntax = {
        str(SOURCE_ROOT / "parent.swift"): wrapped_parent_facts,
        str(SOURCE_ROOT / "wrapper.swift"): wrapper_facts,
        str(SOURCE_ROOT / "leaf.swift"): leaf_facts,
    }
    if not view_or_child_has_marker(deep_syntax, wrapped_parent_facts, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：多层子 View 的契约归属识别")
    cyclic_parent = {
        **parent_facts,
        "calls": [{"value": "WrapperView", "scope": ["ParentView"]}],
    }
    cyclic_wrapper = {
        **wrapper_facts,
        "calls": [{"value": "ParentView", "scope": ["WrapperView"]}],
    }
    cycle_syntax = {
        str(SOURCE_ROOT / "parent.swift"): cyclic_parent,
        str(SOURCE_ROOT / "wrapper.swift"): cyclic_wrapper,
    }
    if view_or_child_has_marker(cycle_syntax, cyclic_parent, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：递归组件循环终止")
    plain_wrapper = {
        **wrapper_facts,
        "calls": [{"value": "PlainLeafView", "scope": ["WrapperView"]}],
    }
    unrelated_leaf = {
        **leaf_facts,
        "declarations": [{"kind": "struct", "name": "UnrelatedLeafView", "scope": [], "inheritedTypes": ["View"]}],
    }
    isolated_syntax = {
        str(SOURCE_ROOT / "parent.swift"): wrapped_parent_facts,
        str(SOURCE_ROOT / "wrapper.swift"): plain_wrapper,
        str(SOURCE_ROOT / "unrelated.swift"): unrelated_leaf,
    }
    if view_or_child_has_marker(isolated_syntax, wrapped_parent_facts, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：独立同名子树掩盖契约缺口")
    helper_scope = ["RenderedParent"]
    helper_view_facts = {
        "declarations": [],
        "calls": [{"value": "AppFailureState", "scope": helper_scope, "start": 120}],
        "invocations": [],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "stringSegments": [],
        "functionRanges": [{"name": "unusedContent", "returnsView": True, "scope": helper_scope, "start": 100, "end": 200}],
        "nonRenderedRanges": [],
    }
    if rendered_view_has_marker(helper_view_facts, helper_scope, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：未引用的 View 辅助方法满足页面契约")
    reachable_helper_facts = {
        **helper_view_facts,
        "calls": [
            {"value": "unusedContent", "scope": helper_scope, "start": 20},
            {"value": "AppFailureState", "scope": helper_scope, "start": 120},
        ],
    }
    if not rendered_view_has_marker(reachable_helper_facts, helper_scope, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：body 引用的 View 辅助方法未进入契约")
    extension_helper_facts = {
        **helper_view_facts,
        "calls": [{"value": "AppFailureState", "scope": helper_scope, "start": 120}],
        "functionRanges": [{"name": "extensionContent", "returnsView": True, "scope": helper_scope, "start": 100, "end": 200}],
        "nonRenderedRanges": [],
    }
    extension_parent_facts = {
        **helper_view_facts,
        "calls": [{"value": "extensionContent", "scope": helper_scope, "start": 20}],
        "functionRanges": [],
        "nonRenderedRanges": [],
    }
    extension_syntax = {
        str(SOURCE_ROOT / "parent.swift"): extension_parent_facts,
        str(SOURCE_ROOT / "extension.swift"): extension_helper_facts,
    }
    if not rendered_view_has_marker(extension_parent_facts, helper_scope, "AppFailureState", extension_syntax):
        findings.append("UI 契约规则边界自检失败：跨文件 View 辅助方法未进入契约")
    callback_facts = {
        **helper_view_facts,
        "calls": [{"value": "AppFailureState", "scope": helper_scope, "start": 35}],
        "functionRanges": [],
        "nonRenderedRanges": [{"scope": helper_scope, "start": 30, "end": 40}],
    }
    if rendered_view_has_marker(callback_facts, helper_scope, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：交互回调中的组件满足页面契约")
    nested_child_facts = {
        **leaf_facts,
        "declarations": [{
            "kind": "struct", "name": "ChildView", "scope": ["Outer", "ParentView"], "inheritedTypes": ["View"]
        }],
    }
    top_level_child_facts = {
        **leaf_facts,
        "declarations": [{"kind": "struct", "name": "ChildView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [],
    }
    nested_parent_facts = {
        **parent_facts,
        "declarations": [{"kind": "struct", "name": "ParentView", "scope": ["Outer"], "inheritedTypes": ["View"]}],
        "calls": [{"value": "ChildView", "scope": ["Outer", "ParentView"]}],
    }
    shadow_syntax = {
        str(SOURCE_ROOT / "nested-parent.swift"): nested_parent_facts,
        str(SOURCE_ROOT / "nested-child.swift"): nested_child_facts,
        str(SOURCE_ROOT / "top-level-child.swift"): top_level_child_facts,
    }
    if child_view_entries(shadow_syntax, "ChildView", ["Outer", "ParentView"]) != [
        (SOURCE_ROOT / "nested-child.swift", nested_child_facts, ["Outer", "ParentView", "ChildView"])
    ]:
        findings.append("UI 契约规则边界自检失败：嵌套 View 名称优先解析")
    return findings


def source_boundary_findings() -> list[str]:
    checker = ROOT / "Scripts/check-code-quality.py"
    spec = importlib.util.spec_from_file_location("check_code_quality_ui_self_test", checker)
    if spec is None or spec.loader is None:
        return ["UI 检查器自测无法加载 SwiftSyntax 索引器"]
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    source = r'''
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
class AppSMSVerificationSheet: View {}
extension AppSearchBarContainer: View {}
struct AppLoadingState {}
struct AppAvatarView: View { var body: some View { Text("avatar") } }
struct AppFixedColumnItem {}
'''
    try:
        facts = swift_syntax_index_sources({"ui-self-test.swift": source})["ui-self-test.swift"]
    except (OSError, subprocess.CalledProcessError, RuntimeError, KeyError) as error:
        return [f"UI 检查器自测无法解析内存 Swift 样例：{error}"]

    findings: list[str] = []
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
        any(view_name in finding for finding in item_alerts)
        for view_name in expected_invalid
    ):
        findings.append("UI 检查器自测：SwiftSyntax 未识别 item 与 isPresented 两种 AppAlert 展示路径")
    diagnostic_scope = {
        "typedVariables": [
            variable for variable in facts["typedVariables"]
            if variable["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "alertModifiers": [
            alert for alert in facts["alertModifiers"]
            if alert["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "calls": [
            call for call in facts["calls"]
            if call["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "invocations": [
            invocation for invocation in facts["invocations"]
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
                    variable for variable in facts["typedVariables"]
                    if variable["scope"][-1] == view_name
                ],
                "alertModifiers": [
                    alert for alert in facts["alertModifiers"]
                    if alert["scope"][-1] == view_name
                ],
            },
            Path("ui-self-test.swift"),
        )
    ]
    if allowed_alerts:
        findings.append("UI 检查器自测：既有用户输入提示例外未按 View 与绑定精确匹配")

    icon_findings = list_icon_findings(Path("UI/ListIconSample.swift"), facts)
    if len(icon_findings) != 5 or not any("person.fill" in finding for finding in icon_findings) or sum(
        "iconName" in finding for finding in icon_findings
    ) != 2 or not any(r"checkmark.\(" in finding for finding in icon_findings) or not any(
        "unsafeSystemIcon" in finding for finding in icon_findings
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
    masked_calls = mask_literals_and_comments(wrapped_calls)
    wrapped_patterns = (
        DIRECT_ANIMATION_DURATION,
        DIRECT_THUMBNAIL_GEOMETRY,
        DIRECT_FLOATING_MATERIAL,
        DIRECT_FLOATING_SIZE,
    )
    if not all(pattern.search(masked_calls) for pattern in wrapped_patterns):
        findings.append("UI 检查器自测：多行视觉规则调用识别异常")

    visual_source = r'''
import SwiftUI
struct VisualRuleSample: View {
    @State private var query = ""
    private let sampleOpacity: Double = 0.4
    private let fixedWidth: CGFloat = 40
    private let derivedWidth = AppDesignSystem.Size.avatar * 2
    private let repeatedWidth = AppDesignSystem.Size.avatar + AppDesignSystem.Size.avatar

    var body: some View {
        Text("https://example.invalid RoundedRectangle() Color.orange .frame(width: 42, height: 42) TextField(\"提示\", text: $query)")
        RoundedRectangle(
            cornerRadius: 12
        )
        Color(uiColor: .systemBackground)
        Color.accentColor
        Color.orange
        Color.red
        Color.blue
        Color.green
        Color.gray
        Color.pink
        Color.indigo
        Color.teal
        Color.brown
        Color.primary
        Color.secondary
        Text("Rule")
            .padding(12)
            .opacity(0.5)
            .foregroundStyle(.secondary)
            .font(.body)
            .blur(radius: 2)
            .frame(width: 40, height: 40)
            .cornerRadius(8)
            .frame(minHeight: 44)
        GridItem(.adaptive(minimum: 32))
        StrokeStyle(lineWidth: 2, dash: [1, 2])
        EdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
        VStack(spacing: 12) {
            HStack { Text("row") }
            HStack(spacing: 12) { Text("row") }
        }
        TextField("搜索提示", text: $query)
        List { Text("row") }
            .listStyle(.insetGrouped)
            .listSectionSpacing(12)
        List { Text("row") }
            .listStyle(.plain)
        Section(header: { Text("标题") }) { Text("row") }
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
    }
}
'''
    try:
        visual_facts = swift_syntax_index_sources(
            {"visual-rule-self-test.swift": visual_source}
        )["visual-rule-self-test.swift"]
    except (OSError, subprocess.CalledProcessError, RuntimeError, KeyError) as error:
        return [f"UI 检查器自测无法解析视觉规则样例：{error}"]
    rectangle_nodes = pattern_nodes(visual_facts, DIRECT_ROUNDED_RECTANGLE)
    if len(rectangle_nodes) != 1 or not DIRECT_ROUNDED_RECTANGLE.search(
        mask_literals_and_comments(rectangle_nodes[0]["value"])
    ):
        findings.append("UI 检查器自测：AST 视觉规则未识别多行形状调用")
    text_invocations = [
        invocation
        for call, invocation in zip(visual_facts["calls"], visual_facts["invocations"])
        if call_name(call["value"]) == "Text" and "https://example.invalid" in invocation["value"]
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
        findings.append("UI 检查器自测：Text 文案进入视觉规则候选节点（" + ", ".join(text_candidate_rules) + "）")
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
            pattern.pattern: [node["value"][:72].replace("\n", " ") for node in pattern_nodes(visual_facts, pattern)[:2]]
            for pattern in dict.fromkeys(coverage_patterns)
            if pattern.pattern in uncovered_rules
        }
        findings.append("UI 检查器自测：AST 规则映射缺少样例：" + repr(examples))
    reviewed_path = source_path("Modules/CourseFeature/Sources/CourseCommentViews.swift")
    reviewed_source = "thumbnailButton(image: displayedImages[0], index: 0, width: 180)"
    if not is_reviewed_fixed_geometry(
        reviewed_path,
        reviewed_source,
        DIRECT_THUMBNAIL_GEOMETRY,
        {"value": reviewed_source},
    ):
        findings.append("UI 检查器自测：登记几何变体未精确命中")
    unregistered_source = "thumbnailButton(image: anotherImage, index: 1, width: 52)"
    if is_reviewed_fixed_geometry(
        reviewed_path,
        reviewed_source + "\n" + unregistered_source,
        DIRECT_THUMBNAIL_GEOMETRY,
        {"value": unregistered_source},
    ):
        findings.append("UI 检查器自测：登记几何例外覆盖同文件的其它表达式")

    declarations = facts["declarations"]
    if has_component_declaration("AppTagChip", declarations):
        findings.append("UI 检查器自测：非 View 同名枚举通过公共组件声明检查")
    if has_component_declaration("AppSMSVerificationSheet", declarations):
        findings.append("UI 检查器自测：同名 class 通过公共组件声明检查")
    if has_component_declaration("AppSearchBarContainer", declarations):
        findings.append("UI 检查器自测：同名 extension 通过公共组件声明检查")
    if has_component_declaration("AppLoadingState", declarations):
        findings.append("UI 检查器自测：未实现 View 的同名结构通过公共组件声明检查")
    if not has_component_declaration("AppAvatarView", declarations):
        findings.append("UI 检查器自测：View 公共组件声明识别失败")
    if not has_component_declaration("AppFixedColumnItem", declarations):
        findings.append("UI 检查器自测：无协议继承的模型结构声明识别失败")
    row_source = r'''
import SwiftUI
struct NeutralTitle: View {
    var body: some View { Text("标题").foregroundStyle(AppDesignSystem.Foreground.primary) }
}
struct RowColors: View {
    var body: some View {
        List {
            Picker("时间轴", selection: $axis) { Text("线性").tag(0) }
            Toggle("开关", isOn: $enabled).appInteractiveListRow()
            Button {} label: { Text("标题").foregroundStyle(.primary) }.appInteractiveListRow()
            Button("删除", role: .destructive) {}.appInteractiveListRow()
            Button("删除正确", role: .destructive) {}.appInteractiveListRow(isDestructive: true)
            NavigationLink(destination: Text("目标")) { NeutralTitle() }.appInteractiveListRow()
            Button("伪造") { print(".appInteractiveListRow()") }
            Button("覆盖颜色") {}.appInteractiveListRow().foregroundStyle(.primary)
            Button {} label: { LabeledContent("左侧") { Text("右侧").foregroundStyle(.secondary) } }.appInteractiveListRow()
            Button {} label: {
                LabeledContent { Text("右侧").foregroundStyle(.secondary) } label: { Text("左侧").foregroundStyle(.tint) }
            }.appInteractiveListRow()
            helperRows
        }
        .toolbar { Button("关闭") {} }
        .overlay { floatingButton }
    }
    private var helperRows: some View { Button("计算属性行") {} }
    private var floatingButton: some View { Button("浮动按钮") {} }
}
'''
    row_path = ROOT / ".build/static-audit/row-color-self-test.swift"
    row_syntax = swift_syntax_index_sources({str(row_path): row_source})
    row_findings = interactive_list_row_findings(row_path, row_syntax[str(row_path)], row_syntax)
    if len(row_findings) != 7:
        findings.append(f"UI 检查器自测：列表标题、颜色覆盖、删除警示色、子组件、计算属性及字符串边界应报告 7 项，实际 {len(row_findings)} 项")
    return findings


def map_theme_color_contract_findings() -> list[str]:
    path = source_path(MAP_THEME_COLOR_CONTRACT[0])
    source = "extension AppDesignSystem {\n    enum Map {\n        " + MAP_THEME_COLOR_CONTRACT[1] + "\n    }\n}"
    start = source.encode("utf-8").find(b"Color.green")
    node = {"scope": ["AppDesignSystem", "Map"], "start": start}
    if not is_registered_map_theme_color_definition(path, source, node):
        return ["UI 检查器自测：地图主题令牌的精确源码例外无法识别"]

    unrelated_source = source.replace(MAP_THEME_COLOR_CONTRACT[1], "static let otherAccent = Color.green")
    if is_registered_map_theme_color_definition(path, unrelated_source, node):
        return ["UI 检查器自测：地图主题令牌例外覆盖了相邻声明"]
    wrong_scope_node = {**node, "scope": ["OtherDesignSystem", "Map"]}
    if is_registered_map_theme_color_definition(path, source, wrong_scope_node):
        return ["UI 检查器自测：地图主题令牌例外覆盖了其它词法作用域"]
    return []


def explanatory_text_boundary_findings() -> list[str]:
    "验证模块界面中的 footer 与 description 进入文案审查。"
    import ui_source_facts as rules
    import shutil
    from contextlib import redirect_stdout
    from io import StringIO
    from unittest.mock import patch

    fixture = ROOT / ".build/static-audit/explanatory-self-test"
    path = fixture / "Modules/DesignSystemKit/Sources/AppStateComponents.swift"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('Section { Text("内容") } footer: {\nText("模块提示")\n}\n'
                    'ContentUnavailableView { Text("状态") } description: {\nText("模块说明")\n}\n')
    try:
        with patch.object(rules, "ROOT", fixture), redirect_stdout(StringIO()):
            rules.explanatory_text_report()
        report = (fixture / ".build/explanatory-text-report.txt").read_text()
        assert '模块提示' in report and '模块说明' in report and 'Modules/DesignSystemKit' in report
    except (AssertionError, OSError) as error:
        return [f"解释文案范围自测：{error}"]
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return []


def school_lifecycle_boundary_findings() -> list[str]:
    from code_quality_rules import automatic_school_fetch_findings
    path = str(ROOT / "BIT101-iOS/LifecycleExample.swift")
    ports = {str(source): source.read_text() for source in (
        ROOT / "Modules/SchedulePorts/Sources/ScheduleServicing.swift",
        ROOT / "Modules/ScoreDomain/Sources/ScoreServicing.swift")}
    findings = []
    for source in (
        "struct RenamedApp: App { var body: some Scene { WindowGroup { Text(\"x\").task { await schedule.syncCourses() } } } }",
        "struct AccountLifecycle { func activate() { renamed() }; func renamed() { service.fetchScores() } }",
        "func movedRefresh() { service.syncDDLEvents() }; struct RenamedApp: App { func activate() { movedRefresh() } }",
        "protocol ScheduleCourseServicing { func renamedProbe() }; struct RenamedApp: App { func activate() { service.renamedProbe() } }",
        "struct First { func refresh() { service.fetchScores() } }; struct Second { func refresh() {} }; struct AppEntry: App { func activate() { first.refresh() } }",
        "struct Loader { func refresh() { service.fetchScores() } }; struct AppEntry: App { var body: some Scene { Text(\"x\").task(perform: loader.refresh) } }",
        "struct ScoreListPage: View { var body: some View { Text(\"x\").task { await service.fetchScores() } } }",
        'struct Screen: View { let service: any ScheduleCourseServicing; var action: () async throws -> Void { { _ = try await service.syncCourses(term: nil) } }; var body: some View { Text("x").task { try? await action() } } }',
        'struct Screen: View { let action: () async -> Void = { await service.fetchScores() }; var body: some View { Text("x").task { await action() } } }',
        'struct Screen: View { var body: some View { Text("x").onReceive(events) { _ in Task { await service.fetchScores() } } } }',
        'struct Screen: View { var body: some View { Text("x").onChange(of: ready, initial: true) { Task { await service.fetchScores() } } } }',
        'struct ScheduleRootView: View { func startClassroomPageRefresh() { service.fetchCampuses(); service.syncCourses() }; var body: some View { Text("x").task { startClassroomPageRefresh() } } }',
        'struct ScheduleTermPickerPage: View { func loadAvailableTerms() { service.fetchAvailableTerms(); service.syncCourses() }; var body: some View { Text("x").task { loadAvailableTerms() } } }',
        'struct TrustedTranscriptPage: View { func applyIfNeeded() { service.fetchTrustedTranscriptPages(); service.fetchScores() }; var body: some View { Text("x").task { applyIfNeeded() } } }',
    ):
        if not automatic_school_fetch_findings(swift_syntax_index_sources(dict(ports, **{path: source}))):
            findings.append("学校生命周期自测：重命名入口、包装方法与跨类型调用链")
    manual = "struct ManualPage: View { var body: some View { Button(\"刷新\") { Task { await service.syncCourses() } } } }"
    if automatic_school_fetch_findings(swift_syntax_index_sources(dict(ports, **{path: manual}))):
        findings.append("学校生命周期自测：用户操作保持独立调用边界")
    manual = 'struct Screen: View { let service: any ScheduleCourseServicing; var action: () async throws -> Void { { _ = try await service.syncCourses(term: nil) } }; var body: some View { Button("刷新") { Task { try? await action() } } } }'
    if automatic_school_fetch_findings(swift_syntax_index_sources(dict(ports, **{path: manual}))):
        findings.append("学校生命周期自测：计算属性动作保持用户操作边界")
    wrappers = "struct SchoolWrapper { func load() { service.fetchScores() } }; struct LocalWrapper { func load() {} }; "
    for body in (
        "let bridge: SchoolWrapper; func start() { bridge.load() }; func helper() { let bridge = LocalWrapper(); bridge.load() }",
        "let bridge: SchoolWrapper; func start() { self.bridge.load() }; func helper() { let bridge: LocalWrapper = .init(); bridge.load() }",
        "let bridge: SchoolWrapper; func start() { if ready { let bridge = LocalWrapper(); bridge.load() }; bridge.load() }",
        "let bridge: SchoolWrapper; func start() { let action = { let bridge = LocalWrapper(); bridge.load() }; bridge.load() }",
        "typealias Bridge = SchoolWrapper; typealias Alias = Bridge; let bridge: Alias; func start() { bridge.load() }",
        "let bridge: LocalWrapper; func start(bridge: SchoolWrapper) { bridge.load() }",
        "let bridge: LocalWrapper; init(bridge: SchoolWrapper) { bridge.load() }",
    ):
        source = wrappers + "struct FeatureLifecycle { " + body + " }"
        if not automatic_school_fetch_findings(swift_syntax_index_sources(dict(ports, **{path: source}))):
            findings.append("学校生命周期自测：成员、其他方法与嵌套代码块的变量归属")
    source = wrappers + "struct ManualPage: View { let bridge: LocalWrapper; var body: some View { Text(\"x\").task { bridge.load() } }; func helper() { let bridge = SchoolWrapper(); bridge.load() } }"
    if automatic_school_fetch_findings(swift_syntax_index_sources(dict(ports, **{path: source}))):
        findings.append("学校生命周期自测：局部包装类型保持所属方法边界")
    return findings


def device_discovery_boundary_findings() -> list[str]:
    import json
    import shlex
    support = ROOT / "Scripts/script-support.sh"
    findings = []
    def candidate(name, transport, tunnel="connected", pairing="paired", reality="physical"):
        return {"identifier": name, "hardwareProperties": {"udid": name, "deviceType": "iPhone", "reality": reality},
                "connectionProperties": {"transportType": transport, "tunnelState": tunnel, "pairingState": pairing},
                "deviceProperties": {"name": name}}

    for devices, expected in (
        ([candidate("wireless", "localNetwork"), candidate("wired", "wired")], "wired"),
        ([candidate("wireless", "localNetwork"), candidate("offline", None)], "wireless"),
        ([candidate("pending", "wired", "disconnected"), candidate("connected", "wired")], "connected"),
        ([candidate("unpaired", "wired", pairing="unpaired"), candidate("virtual", "wired", reality="virtual")], ""),
    ):
        snapshot = shlex.quote(json.dumps({"result": {"devices": devices}}))
        code = f'source {shlex.quote(str(support))}\nunset BIT101_XCODE_DEVICE_ID BIT101_DEVICETCL_DEVICE_ID BIT101_DEVICE_TRANSPORT BIT101_DEVICE_NAME\n'
        code += f'bit101_device_snapshot() {{ print -r -- {snapshot}; }}\nbit101_find_device || exit 1\nprint -r -- "$BIT101_DEVICE_NAME"\n'
        result = subprocess.run(["zsh", "-c", code], capture_output=True, text=True)
        if (expected and (result.returncode or result.stdout.strip() != expected)) or (not expected and result.returncode != 1):
            findings.append("设备自测：有线优先、无线发现、连接状态及真实配对设备范围")
    return findings
