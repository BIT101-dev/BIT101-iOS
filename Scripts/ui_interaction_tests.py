"""Exercise source interaction ownership and action evidence."""
from ui_source_facts import ROOT
from swift_source_index import swift_syntax_index_sources
from ui_rules import interaction_source_inventory, source_inventory_findings, source_runtime_interaction_findings


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
    for kind, invocation, action in [("ScrollView", "ScrollView { Text(\"内容\") }", "scroll"),
            ("List", "List { Text(\"内容\") }", "scroll"),
            ("TabView", "TabView { Text(\"内容\") }", "tab-switch")]:
        source = 'struct Screen: View { var body: some View { ' + invocation + '.accessibilityIdentifier("container") } }'
        container = swift_syntax_index_sources({path: source})
        container_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(container).items()}
        if not source_runtime_interaction_findings(container, container_manifest, []):
            findings.append(f"UI 容器自测：{kind} 需要独立动作证据")
        row = dict(evidence[0], identifier="container", instance="container", actions=["tap"])
        if not source_runtime_interaction_findings(container, container_manifest, [row]):
            findings.append(f"UI 容器自测：{kind} 核对实际动作类型")
        if source_runtime_interaction_findings(container, container_manifest, [dict(row, actions=[action])]):
            findings.append(f"UI 容器自测：{kind} 接受所属动作证据")
    combined = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { ScrollView { Text("内容") }.accessibilityIdentifier("container").simultaneousGesture(DragGesture().onEnded { _ in }).accessibilityIdentifier("container") } }'})
    combined_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(combined).items()}
    combined_evidence = dict(evidence[0], identifier="container", instance="container", actions=["scroll"])
    if not source_runtime_interaction_findings(combined, combined_manifest, [combined_evidence]):
        findings.append("UI 容器自测：共享载体分别核对滚动和业务手势")
    if source_runtime_interaction_findings(combined, combined_manifest, [dict(combined_evidence, actions=["scroll", "gesture"])]):
        findings.append("UI 容器自测：同一载体的独立动作共同进入证据")
    unrelated = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { TextField("输入", text: .constant("")).accessibilityIdentifier("shared"); Button("提交") {}.accessibilityIdentifier("shared") } }'})
    unrelated_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(unrelated).items()}
    if not source_runtime_interaction_findings(unrelated, unrelated_manifest,
            [dict(evidence[0], identifier="shared", instance="shared", actions=["input", "tap"])]):
        findings.append("UI 容器自测：不同控件继续要求独立身份")
    for modifier, action in [('accessibilityAction(named: "打开") { open() }', 'accessibility:打开'),
            ('keyboardShortcut(.defaultAction)', 'keyboard')]:
        source = 'struct Screen: View { var body: some View { Button("打开") {}.accessibilityIdentifier("carrier").' + modifier + ' } }'
        control = swift_syntax_index_sources({path: source})
        contract = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(control).items()}
        row = dict(evidence[0], identifier="carrier", instance="carrier", actions=["tap"])
        if not source_runtime_interaction_findings(control, contract, [row]):
            findings.append("UI 辅助交互自测：点击证据需要补齐独立入口")
        if source_runtime_interaction_findings(control, contract, [dict(row, actions=["tap", action])]):
            findings.append("UI 辅助交互自测：同一控件的独立动作共同进入证据")
        if action.startswith("accessibility:") and not source_runtime_interaction_findings(control, contract,
                [dict(row, actions=["tap", "accessibility:其他"])]):
            findings.append("UI 辅助交互自测：自定义动作核对名称")
    return findings
