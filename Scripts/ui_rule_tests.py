"""Executable boundary checks for UI and design rules."""

from __future__ import annotations

from pathlib import Path
import importlib.util
import subprocess
import sys
from swift_source_index import swift_syntax_index_sources
from swift_type_index import SwiftBindingTypes

from ui_interaction_tests import (
    interaction_inventory_boundary_findings,
    explanatory_text_boundary_findings,
    visual_contract_boundary_findings,
)

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
    SOURCE_ROOT,
    ast_has_marker,
    call_name,
    child_view_entries,
    has_component_declaration,
    image_only_label_facts,
    is_semantic_color_member,
    list_icon_findings,
    mask_comments,
    mask_literals_and_comments,
    pattern_nodes,
    rendered_view_has_marker,
    selection_control_has_feedback,
    source_path,
    view_or_child_has_marker,
)

from ui_rules import (
    alert_coverage_findings,
    haptic_entry_findings,
    interactive_list_row_findings,
    is_registered_map_theme_color_definition,
    is_reviewed_fixed_geometry,
    check_composer_lifecycle,
    rendered_component_counts,
)

from ui_source_rule_tests import (
    source_boundary_findings as source_boundary_findings,
    map_theme_color_contract_findings as map_theme_color_contract_findings,
)


def ast_marker_boundary_findings() -> list[str]:
    from unittest.mock import patch
    from ui_source_facts import UIAuditContext, rendered_scope_facts
    from swift_type_index import execution_index

    path = str(ROOT / "BIT101-iOS/Views.swift")
    shared = swift_syntax_index_sources(
        {
            path: (
                "struct First: View { var body: some View { makeLeaf() }; func makeLeaf() -> some "
                'View { Leaf() } }; struct Second: View { var body: some View { Text("two") } }; s'
                'truct Leaf: View { var body: some View { Text("leaf").appSelectionFeedback(trigge'
                "r: true) } }"
            )
        }
    )
    with patch("ui_source_facts.execution_index", wraps=execution_index) as build:
        context = UIAuditContext(shared)
        for facts in context.values():
            facts["renderedScopeFacts"] = {}
        check_composer_lifecycle([], context)
        for name in ("First", "Second"):
            assert rendered_scope_facts(context[path], [name], context)["calls"]
        assert view_or_child_has_marker(context, context[path], ["First"], "appSelectionFeedback")
        assert build.call_count == 1, "多份 View 共享单次执行索引"
    color_path = "semantic-color-self-test.swift"
    color_source = """
import SwiftUI
enum TrafficPhase { case red, green }
typealias Phase = TrafficPhase
typealias Accent = Color
struct Status { let phase: Phase = .red; let color: Accent = .green }
func consume(_ phase: TrafficPhase) {}
func consumeColor(_ color: Color) {}
func phase() -> TrafficPhase { .green }
func color() -> Color { .red }
func sample() {
    let color = SwiftUI.Color.red; let local = Color.red; let phase = TrafficPhase.red
    consume(.red); consumeColor(.green)
    Text("label").foregroundStyle(.red)
    Text("label").background(.green)
}
"""
    color_syntax = swift_syntax_index_sources({color_path: color_source})
    color_context = SwiftBindingTypes(color_syntax)
    color_nodes = [
        node
        for node in color_syntax[color_path]["members"]
        if node["value"] in {".red", ".green", "Color.red", "SwiftUI.Color.red", "TrafficPhase.red"}
    ]
    assert (
        len(color_nodes) == 11
        and sum(is_semantic_color_member(color_path, node, color_context) for node in color_nodes)
        == 7
    )
    editors = [
        ("GalleryComposerScene", "", "ui.gallery-composer-scene.submit"),
        ("PaperComposerView", "model.isSubmitting", "ui.paper-composer-view.submit"),
    ]
    editors += [
        (owner, "isSubmitting || isSubmissionRequested", "")
        for owner in (
            "GalleryCommentComposerSheet",
            "CourseCommentComposerSheet",
            "PaperCommentComposerSheet",
        )
    ]
    for owner, guard, identifier in editors:
        member = "let callback: () async -> Bool;" if guard and not identifier else ""
        marker = f'.accessibilityIdentifier("{identifier}")' if identifier else ""
        template = (
            f"struct "
            f"{owner}"
            f": View {{ "
            f"{member}"
            f' var body: some View {{ AppCommentComposerContentSection {{ Text("editor") }}'
            f"{marker}"
            f".interactiveDismissDisabled("
            f"{guard}"
            f") }} }}"
        )

        def findings(source):
            source = source.replace(
                "var body:",
                "let protectDismissal = false; let protectAlias = protectDismissal; var body:",
            )
            errors = []
            check_composer_lifecycle(
                errors, swift_syntax_index_sources({"ui-self-test.swift": source})
            )
            return errors

        assert not findings(template)
        assert not findings(
            template.replace(owner, "RenamedEditor").replace(guard, "blocksDismissal")
            if guard
            else template.replace(owner, "RenamedEditor")
        )
        assert findings(template.replace(f".interactiveDismissDisabled({guard})", ""))
        for disabled in (
            "false",
            "(!true)",
            "(false && isSubmitting)",
            "(false || false)",
            "1 == 2",
            "protectDismissal",
            "protectAlias",
        ):
            assert findings(
                template.replace(
                    f".interactiveDismissDisabled({guard})",
                    f".interactiveDismissDisabled({disabled})",
                )
            )
        for enabled in ("true", "(!false)", "isSubmitting || true"):
            assert not findings(
                template.replace(
                    f".interactiveDismissDisabled({guard})",
                    f".interactiveDismissDisabled({enabled})",
                )
            )
        unused = template.replace(f".interactiveDismissDisabled({guard})", "")[:-1] + (
            f'; func unused() -> some View {{ Text("unused").interactiveDismissDisabled('
            f"{guard}"
            f") }} }}"
        )
        assert findings(unused)
        if not identifier:
            assert not findings(
                template.replace("AppCommentComposerContentSection", "OtherSection").replace(
                    f".interactiveDismissDisabled({guard})", ""
                )
            )
    for symbol in (
        "AppCard",
        "AppFloatingActionStack",
        "appBrowserActions",
        "appBrowserFloatingActions",
    ):
        source = (
            f'struct Example: View {{ var body: some View {{ Text("visible") }}; func unused() -> s'
            f"ome View {{ "
            f"{symbol}"
            f' {{ Text("unused") }} }} }}'
        )
        facts = swift_syntax_index_sources({"ui-self-test.swift": source})
        assert not rendered_component_counts(facts["ui-self-test.swift"], facts)[symbol]
        active = source.replace('Text("visible")', f'{symbol} {{ Text("visible") }}')
        facts = swift_syntax_index_sources({"ui-self-test.swift": active})
        assert rendered_component_counts(facts["ui-self-test.swift"], facts)[symbol]
    assert not visual_contract_boundary_findings()
    facts = {
        "declarations": [{"kind": "struct", "name": "SampleView"}],
        "calls": [{"value": "AppFailureState", "scope": ["SampleView"]}],
        "invocations": [{"value": 'Text("课程暂未发布说明")', "scope": ["SampleView"]}],
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
    haptic_source = """
extension View {
    public func appSelectionFeedback<T: Equatable>(trigger: T) -> some View {
        onChange(of: trigger) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
    }
    public func appImpactFeedback<T: Equatable>(trigger: T) -> some View {
        onChange(of: trigger) { _, _ in UIImpactFeedbackGenerator().impactOccurred() }
    }
}
"""
    haptic_syntax = swift_syntax_index_sources({str(haptic_path): haptic_source})
    if haptic_entry_findings({haptic_path: haptic_source}, haptic_syntax)[0]:
        findings.append("UI 契约规则边界自检失败：公共触感声明应支持文件迁移")
    wrong_source = haptic_source.replace(
        "UISelectionFeedbackGenerator", "UIImpactFeedbackGenerator"
    )
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
    control = {
        "name": "Toggle",
        "invocation": 'Toggle("sample", isOn: $value)',
        "scope": ["SampleView"],
    }
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
        "declarations": [
            {"kind": "struct", "name": "ParentView", "scope": [], "inheritedTypes": ["View"]}
        ],
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
        "declarations": [
            {"kind": "struct", "name": "ChildView", "scope": [], "inheritedTypes": ["View"]}
        ],
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
    if not view_or_child_has_marker(
        delegated_syntax, parent_facts, ["ParentView"], "appSelectionFeedback"
    ):
        findings.append("UI 契约规则边界自检失败：直接子 View 的公共触感调用识别")
    wrapped_parent_facts = {
        **parent_facts,
        "calls": [{"value": "WrapperView", "scope": ["ParentView"]}],
    }
    wrapper_facts = {
        **parent_facts,
        "declarations": [
            {"kind": "struct", "name": "WrapperView", "scope": [], "inheritedTypes": ["View"]}
        ],
        "calls": [{"value": "LeafView", "scope": ["WrapperView"]}],
    }
    leaf_facts = {
        **child_facts,
        "declarations": [
            {"kind": "struct", "name": "LeafView", "scope": [], "inheritedTypes": ["View"]}
        ],
        "calls": [{"value": "appSelectionFeedback", "scope": ["LeafView"]}],
    }
    deep_syntax = {
        str(SOURCE_ROOT / "parent.swift"): wrapped_parent_facts,
        str(SOURCE_ROOT / "wrapper.swift"): wrapper_facts,
        str(SOURCE_ROOT / "leaf.swift"): leaf_facts,
    }
    if not view_or_child_has_marker(
        deep_syntax, wrapped_parent_facts, ["ParentView"], "appSelectionFeedback"
    ):
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
    if view_or_child_has_marker(
        cycle_syntax, cyclic_parent, ["ParentView"], "appSelectionFeedback"
    ):
        findings.append("UI 契约规则边界自检失败：递归组件循环终止")
    plain_wrapper = {
        **wrapper_facts,
        "calls": [{"value": "PlainLeafView", "scope": ["WrapperView"]}],
    }
    unrelated_leaf = {
        **leaf_facts,
        "declarations": [
            {"kind": "struct", "name": "UnrelatedLeafView", "scope": [], "inheritedTypes": ["View"]}
        ],
    }
    isolated_syntax = {
        str(SOURCE_ROOT / "parent.swift"): wrapped_parent_facts,
        str(SOURCE_ROOT / "wrapper.swift"): plain_wrapper,
        str(SOURCE_ROOT / "unrelated.swift"): unrelated_leaf,
    }
    if view_or_child_has_marker(
        isolated_syntax, wrapped_parent_facts, ["ParentView"], "appSelectionFeedback"
    ):
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
        "functionRanges": [
            {
                "name": "unusedContent",
                "returnsView": True,
                "scope": helper_scope,
                "start": 100,
                "end": 200,
            }
        ],
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
        "functionRanges": [
            {
                "name": "extensionContent",
                "returnsView": True,
                "scope": helper_scope,
                "start": 100,
                "end": 200,
            }
        ],
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
    if not rendered_view_has_marker(
        extension_parent_facts, helper_scope, "AppFailureState", extension_syntax
    ):
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
        "declarations": [
            {
                "kind": "struct",
                "name": "ChildView",
                "scope": ["Outer", "ParentView"],
                "inheritedTypes": ["View"],
            }
        ],
    }
    top_level_child_facts = {
        **leaf_facts,
        "declarations": [
            {"kind": "struct", "name": "ChildView", "scope": [], "inheritedTypes": ["View"]}
        ],
        "calls": [],
    }
    nested_parent_facts = {
        **parent_facts,
        "declarations": [
            {"kind": "struct", "name": "ParentView", "scope": ["Outer"], "inheritedTypes": ["View"]}
        ],
        "calls": [{"value": "ChildView", "scope": ["Outer", "ParentView"]}],
    }
    shadow_syntax = {
        str(SOURCE_ROOT / "nested-parent.swift"): nested_parent_facts,
        str(SOURCE_ROOT / "nested-child.swift"): nested_child_facts,
        str(SOURCE_ROOT / "top-level-child.swift"): top_level_child_facts,
    }
    if child_view_entries(shadow_syntax, "ChildView", ["Outer", "ParentView"]) != [
        (
            SOURCE_ROOT / "nested-child.swift",
            nested_child_facts,
            ["Outer", "ParentView", "ChildView"],
        )
    ]:
        findings.append("UI 契约规则边界自检失败：嵌套 View 名称优先解析")
    return findings


def school_lifecycle_boundary_findings() -> list[str]:
    from code_quality_rules import automatic_school_fetch_findings

    path = str(ROOT / "BIT101-iOS/LifecycleExample.swift")
    ports = {
        str(source): source.read_text()
        for source in (
            ROOT / "Modules/SchedulePorts/Sources/ScheduleServicing.swift",
            ROOT / "Modules/ScorePorts/Sources/ScoreServicing.swift",
        )
    }
    prefix = "import SchedulePorts; import ScorePorts; "
    ports[str(ROOT / "BIT101-iOS/FixtureSchool.swift")] = prefix + (
        "protocol FixtureSchoolServicing: ScheduleServicing, ScoreListServicing, TrustedTransc"
        "riptServicing {}; let service: any FixtureSchoolServicing; let schedule: any Schedule"
        "Servicing;"
    )
    findings = []
    source = prefix + (
        'struct Screen: View { var body: some View { Text("x").task { await schedule.syncCours'
        "es() } } }"
    )
    for name, expected in (
        ("BIT101-iOS/LifecycleUITestExample.swift", True),
        ("BIT101-iOS/ReleaseNetworkSmokeExample.swift", True),
        ("BIT101-iOS/Tests/LifecycleExample.swift", True),
        ("ModuleTests/Support/LifecycleExample.swift", False),
        ("BIT101-iOSTests/LifecycleExample.swift", False),
        ("BIT101-iOSUITests/LifecycleExample.swift", False),
    ):
        renamed = str(ROOT / name)
        if (
            bool(
                automatic_school_fetch_findings(
                    swift_syntax_index_sources(dict(ports, **{renamed: source}))
                )
            )
            != expected
        ):
            findings.append("学校生命周期自测：生产文件名与实际测试目录归属")
    for condition, expected in (
        ("RELEASE_NETWORK_SMOKE", False),
        ("BIT101_UI_TESTING", False),
        ("os(iOS)", True),
        ("targetEnvironment(macCatalyst)", True),
    ):
        guarded = f"#if {condition}\n{source}\n#endif"
        if (
            bool(
                automatic_school_fetch_findings(
                    swift_syntax_index_sources(dict(ports, **{path: guarded}))
                )
            )
            != expected
        ):
            findings.append("学校生命周期自测：正式平台编译条件与专项宿主归属")
    for source in (
        (
            'struct RenamedApp: App { var body: some Scene { WindowGroup { Text("x").task { await '
            "schedule.syncCourses() } } } }"
        ),
        (
            "struct AccountLifecycle { func activate() { renamed() }; func renamed() { service.fet"
            "chScores() } }"
        ),
        (
            "func movedRefresh() { service.syncDDLEvents() }; struct RenamedApp: App { func activa"
            "te() { movedRefresh() } }"
        ),
        (
            "protocol ScheduleCourseServicing { func renamedProbe() }; struct RenamedApp: App { le"
            "t service: any ScheduleCourseServicing; func activate() { service.renamedProbe() } }"
        ),
        (
            "import SchedulePorts; protocol ExtendedScheduleServicing: ScheduleCourseServicing { f"
            "unc fetchNewSchoolData() async throws }; struct Screen: View { let service: any Exten"
            'dedScheduleServicing; var body: some View { Text("x").task { try? await service.fetch'
            "NewSchoolData() } } }"
        ),
        (
            "import SchedulePorts; typealias SchoolBase = ScheduleCourseServicing; protocol Extend"
            "edScheduleServicing: SchoolBase { func fetchNewSchoolData() async throws }; struct Sc"
            'reen: View { let service: any ExtendedScheduleServicing; var body: some View { Text("'
            'x").task { try? await service.fetchNewSchoolData() } } }'
        ),
        (
            "import SchedulePorts; protocol Intermediate: ScheduleCourseServicing {}; protocol Ext"
            "endedScheduleServicing: Intermediate { func fetchNewSchoolData() async throws }; stru"
            "ct Screen: View { let service: any ExtendedScheduleServicing; var body: some View { T"
            'ext("x").task { try? await service.fetchNewSchoolData() } } }'
        ),
        (
            "struct First { func refresh() { service.fetchScores() } }; struct Second { func refre"
            "sh() {} }; struct AppEntry: App { func activate() { first.refresh() } }"
        ),
        (
            "struct Loader { func refresh() { service.fetchScores() } }; struct AppEntry: App { va"
            'r body: some Scene { Text("x").task(perform: loader.refresh) } }'
        ),
        (
            'struct ScoreListPage: View { var body: some View { Text("x").task { await service.fet'
            "chScores() } } }"
        ),
        (
            "struct Screen: View { let service: any ScheduleCourseServicing; var action: () async "
            "throws -> Void { { _ = try await service.syncCourses(term: nil) } }; var body: some V"
            'iew { Text("x").task { try? await action() } } }'
        ),
        (
            "struct Screen: View { let action: () async -> Void = { await service.fetchScores() };"
            ' var body: some View { Text("x").task { await action() } } }'
        ),
        (
            'struct Screen: View { var body: some View { Text("x").onReceive(events) { _ in Task {'
            " await service.fetchScores() } } } }"
        ),
        (
            'struct Screen: View { var body: some View { Text("x").onChange(of: ready, initial: tr'
            "ue) { Task { await service.fetchScores() } } } }"
        ),
        (
            'struct Screen: View { var body: some View { Text("x").onDisappear { Task { await serv'
            "ice.fetchScores() } } } }"
        ),
        (
            'struct Screen: View { var body: some View { Text("x").onPreferenceChange(Key.self) { '
            "_ in service.fetchScores() } } }"
        ),
        (
            "class Screen: UIViewController { override func viewDidLoad() { Task { await service.f"
            "etchScores() } } }"
        ),
        (
            "class Base: UIKit.UIViewController {}; class Screen: Base { override func viewWillApp"
            "ear(_ animated: Bool) { service.fetchScores() } }"
        ),
        (
            "struct Screen: UIViewControllerRepresentable { func makeUIViewController(context: Con"
            "text) -> UIViewController { service.fetchScores(); return UIViewController() } }"
        ),
        (
            "struct Screen: SwiftUI.UIViewControllerRepresentable { func updateUIViewController(_ "
            "view: UIViewController, context: Context) { service.fetchScores() } }"
        ),
        (
            "struct Screen: UIViewRepresentable { func updateUIView(_ view: UIView, context: Conte"
            "xt) { service.fetchScores() } }"
        ),
        (
            "struct ScheduleRootView: View { func startClassroomPageRefresh() { service.fetchCampu"
            'ses(); service.syncCourses() }; var body: some View { Text("x").task { startClassroom'
            "PageRefresh() } } }"
        ),
        (
            "struct ScheduleTermPickerPage: View { func loadAvailableTerms() { service.fetchAvaila"
            'bleTerms(); service.syncCourses() }; var body: some View { Text("x").task { loadAvail'
            "ableTerms() } } }"
        ),
        (
            "struct TrustedTranscriptPage: View { func applyIfNeeded() { service.fetchTrustedPages"
            '(); service.fetchScores() }; var body: some View { Text("x").task { applyIfNeeded() }'
            " } }"
        ),
        (
            "protocol Loading { func load() async }; struct Loader: Loading { let service: any Sco"
            "reListServicing; func load() async { await service.fetchScores() } }; struct Screen: "
            'View { let loader: any Loading; var body: some View { Text("x").task { await loader.l'
            "oad() } } }"
        ),
        (
            "protocol Loading { func load() async }; protocol SchoolLoading: Loading {}; struct Lo"
            "ader: SchoolLoading { let service: any ScoreListServicing; func load() async { await "
            "service.fetchScores() } }; struct Screen: View { let loader: any Loading; var body: s"
            'ome View { Text("x").task { await loader.load() } } }'
        ),
    ):
        source = prefix + source
        if not automatic_school_fetch_findings(
            swift_syntax_index_sources(dict(ports, **{path: source}))
        ):
            findings.append("学校生命周期自测：重命名入口、包装方法与跨类型调用链")
    manual = prefix + (
        'struct ManualPage: View { var body: some View { Button("刷新") { Task { await service.s'
        "yncCourses() } } } }"
    )
    if automatic_school_fetch_findings(swift_syntax_index_sources(dict(ports, **{path: manual}))):
        findings.append("学校生命周期自测：用户操作保持独立调用边界")
    loader = prefix + (
        "protocol Loading { func load() async }; struct Loader: Loading { let service: any Sco"
        "reListServicing; func load() async { await service.fetchScores() } };"
    )
    screen = (
        'struct Screen: View { let loader: any Loading; var body: some View { Text("x").task { awa'
        "it loader.load() } } }"
    )
    if not automatic_school_fetch_findings(
        swift_syntax_index_sources(
            dict(ports, **{path: screen, str(ROOT / "BIT101-iOS/Loader.swift"): loader})
        )
    ):
        findings.append("学校生命周期自测：跨文件协议转发需要连接具体实现")
    manual_loader = screen.replace('Text("x").task', 'Button("刷新")')
    if automatic_school_fetch_findings(
        swift_syntax_index_sources(
            dict(ports, **{path: manual_loader, str(ROOT / "BIT101-iOS/Loader.swift"): loader})
        )
    ):
        findings.append("学校生命周期自测：协议转发的用户操作保持独立边界")
    manual = prefix + (
        "struct Screen: View { let service: any ScheduleCourseServicing; var action: () async "
        "throws -> Void { { _ = try await service.syncCourses(term: nil) } }; var body: some V"
        'iew { Button("刷新") { Task { try? await action() } } } }'
    )
    if automatic_school_fetch_findings(swift_syntax_index_sources(dict(ports, **{path: manual}))):
        findings.append("学校生命周期自测：计算属性动作保持用户操作边界")
    for active in (False, True):
        source = prefix + (
            "struct SampleHolder { let action: () async -> Void; init(refresh cb: @escaping ()"
            " async -> Void) { self.action = cb }; func start() async { await action() } }; st"
            "ruct SampleApp: App { let holder = SampleHolder(refresh: { _ = try? await schedul"
            'e.syncCourses(term: nil) }); var body: some Scene { WindowGroup { Text("x").task '
            "{ CALL } } } }"
        ).replace("CALL", "await holder.start()" if active else "await unrelated()")
        if (
            bool(
                automatic_school_fetch_findings(
                    swift_syntax_index_sources(dict(ports, **{path: source}))
                )
            )
            != active
        ):
            findings.append("学校生命周期自测：显式初始化器保存与实际执行保持归属")
    wrappers = prefix + (
        "struct SchoolWrapper { func load() { service.fetchScores() } }; struct LocalWrapper {"
        " func load() {} }; "
    )
    for body in (
        (
            "let bridge: SchoolWrapper; func start() { bridge.load() }; func helper() { let bridge"
            " = LocalWrapper(); bridge.load() }"
        ),
        (
            "let bridge: SchoolWrapper; func start() { self.bridge.load() }; func helper() { let b"
            "ridge: LocalWrapper = .init(); bridge.load() }"
        ),
        (
            "let bridge: SchoolWrapper; func start() { if ready { let bridge = LocalWrapper(); bri"
            "dge.load() }; bridge.load() }"
        ),
        (
            "let bridge: SchoolWrapper; func start() { let action = { let bridge = LocalWrapper();"
            " bridge.load() }; bridge.load() }"
        ),
        (
            "typealias Bridge = SchoolWrapper; typealias Alias = Bridge; let bridge: Alias; func s"
            "tart() { bridge.load() }"
        ),
        "let bridge: LocalWrapper; func start(bridge: SchoolWrapper) { bridge.load() }",
        "let bridge: LocalWrapper; init(bridge: SchoolWrapper) { bridge.load() }",
    ):
        source = wrappers + "struct FeatureLifecycle { " + body + " }"
        if not automatic_school_fetch_findings(
            swift_syntax_index_sources(dict(ports, **{path: source}))
        ):
            findings.append("学校生命周期自测：成员、其他方法与嵌套代码块的变量归属")
    source = wrappers + (
        'struct ManualPage: View { let bridge: LocalWrapper; var body: some View { Text("x").t'
        "ask { bridge.load() } }; func helper() { let bridge = SchoolWrapper(); bridge.load() "
        "} }"
    )
    if automatic_school_fetch_findings(swift_syntax_index_sources(dict(ports, **{path: source}))):
        findings.append("学校生命周期自测：局部包装类型保持所属方法边界")
    return findings
