"""Exercise source interaction ownership and action evidence."""
from ui_source_facts import ROOT
from pathlib import Path
from swift_source_index import swift_syntax_index_sources
from ui_rules import interaction_source_inventory, source_inventory_findings, source_runtime_interaction_findings


def interaction_inventory_boundary_findings() -> list[str]:
    path = str(ROOT / "Modules/Example/Sources/Example.swift")
    original = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Button("入口") {} } }'})
    manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(original).items()}
    findings = list_row_layout_boundary_findings()
    for kind, modifier, action in (
            ('onDrag', 'onDrag { NSItemProvider() }', 'drag'),
            ('onDrop', 'onDrop(of: ["text"], isTargeted: nil) { _ in true }', 'drop'),
            ('draggable', 'draggable("内容")', 'drag'),
            ('dropDestination', 'dropDestination(for: String.self) { _, _ in true }', 'drop'),
            ('onKeyPress', 'onKeyPress(.return) { .handled }', 'keyboard')):
        syntax = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Text("内容").'
            + modifier + '.accessibilityIdentifier("carrier") } }'})
        inventory = interaction_source_inventory(syntax)
        if list(inventory.values()) != [{kind: 1}] or not source_inventory_findings(syntax, {}, set()):
            findings.append('UI 清单自测：拖放与键盘事件进入归属库存')
        modifier_manifest = {key: (controls, {'ExampleUITests/testScreen'}) for key, controls in inventory.items()}
        row = dict(scope='ExampleUITests/testScreen', identifier='carrier', instance='carrier', actions=[action])
        if not source_runtime_interaction_findings(syntax, modifier_manifest, []) or source_runtime_interaction_findings(syntax, modifier_manifest, [row]):
            findings.append('UI 清单自测：拖放与键盘事件核对实际动作证据')
        if action in {'drag', 'drop'} and not source_runtime_interaction_findings(syntax, modifier_manifest, [dict(row, actions=['swipe'])]):
            findings.append('UI 清单自测：拖放需要独立于轻扫的动作证据')
    for gesture, action, wrong in [('DragGesture()', 'swipe', 'pinch'), ('MagnificationGesture()', 'pinch', 'swipe'),
            ('TapGesture()', 'tap', 'swipe'), ('LongPressGesture()', 'press', 'tap')]:
        syntax = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Text("内容").gesture('
            + gesture + ').accessibilityIdentifier("carrier") } }'})
        gesture_manifest = {key: (controls, {'ExampleUITests/testScreen'}) for key, controls in interaction_source_inventory(syntax).items()}
        row = dict(scope='ExampleUITests/testScreen', identifier='carrier', instance='carrier', actions=[action])
        if source_runtime_interaction_findings(syntax, gesture_manifest, [row]) or not source_runtime_interaction_findings(syntax, gesture_manifest, [dict(row, actions=[wrong])]):
            findings.append('UI 清单自测：轻扫、捏合、点击与长按分别验证')
    for gesture, required in [
            ('gesture(TapGesture().simultaneously(with: DragGesture()))', {'tap', 'swipe'}),
            ('gesture(TapGesture().sequenced(before: LongPressGesture()))', {'tap', 'press'}),
            ('gesture(TapGesture()).simultaneousGesture(DragGesture())', {'tap', 'swipe'}),
            ('gesture(DragGesture().onChanged { _ in print("MagnificationGesture"); let unused = MagnificationGesture() })', {'swipe'}),
            ('gesture(DragGesture(/* MagnificationGesture */))', {'swipe'})]:
        syntax = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Text("内容").'
            + gesture + '.accessibilityIdentifier("carrier") } }'})
        gesture_manifest = {key: (controls, {'ExampleUITests/testScreen'}) for key, controls in interaction_source_inventory(syntax).items()}
        row = dict(scope='ExampleUITests/testScreen', identifier='carrier', instance='carrier', actions=sorted(required))
        if source_runtime_interaction_findings(syntax, gesture_manifest, [row]):
            findings.append('UI 清单自测：组合手势按实际构造核对完整动作集合')
        for missing in required:
            actions = sorted(required - {missing}) or ['pinch']
            if not source_runtime_interaction_findings(syntax, gesture_manifest, [dict(row, actions=actions)]):
                findings.append('UI 清单自测：组合手势逐项检查动作缺口')
    for kind, control, action in (("DisclosureGroup", 'DisclosureGroup("详情") { Text("正文") }', 'tap'),
            ("ColorPicker", 'ColorPicker("颜色", selection: .constant(.red))', 'selection'),
            ("MultiDatePicker", 'MultiDatePicker("日期", selection: .constant(Set<DateComponents>()))', 'selection'),
            ("EditButton", 'EditButton()', 'tap'), ("PasteButton", 'PasteButton(payloadType: String.self) { _ in }', 'tap')):
        identifier = 'control' if kind in {'MultiDatePicker', 'EditButton', 'PasteButton'} else ''
        if identifier: control += '.accessibilityIdentifier("control")'
        syntax = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { ' + control + ' } }'})
        control_manifest = {key: (controls, {'ExampleUITests/testScreen'}) for key, controls in interaction_source_inventory(syntax).items()}
        if list(value[0] for value in control_manifest.values()) != [{kind: 1}] or not source_inventory_findings(syntax, {}, set()):
            findings.append('UI 清单自测：系统折叠与颜色控件进入归属库存')
        row = dict(scope='ExampleUITests/testScreen', label='详情' if kind == 'DisclosureGroup' else '颜色', identifier=identifier, instance='control', actions=['tap' if action == 'selection' else action])
        if not source_runtime_interaction_findings(syntax, control_manifest, []) or source_runtime_interaction_findings(syntax, control_manifest, [row]):
            findings.append('UI 清单自测：系统控件核对实际动作证据')
    spacers = swift_syntax_index_sources({path: 'class Screen { func build() { let fixed = UIBarButtonItem(systemItem: .fixedSpace); let flexible: UIBarButtonItem = .init(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) } }'})
    if interaction_source_inventory(spacers): findings.append('UI 原生清单自测：工具栏间隔沿布局归属')
    for root, expected in (("BIT101-iOS", True), ("BIT101-iOS/Tests", True), ("ModuleTests/Support", False), ("BIT101-iOSTests", False), ("BIT101-iOSUITests", False)):
        renamed_path = str(ROOT / root / 'ScreenUITestExample.swift')
        renamed = swift_syntax_index_sources({renamed_path: 'struct Screen: View { var body: some View { Button("入口") {} }; func build() { let field = UITextField() } }'})
        if list(interaction_source_inventory(renamed).values()) != ([{"Button": 1, "UITextField": 1}] if expected else []):
            findings.append("UI 清单自测：生产文件名与实际测试目录归属")
        if expected and not source_runtime_interaction_findings(renamed, {}, []):
            findings.append("UI 清单自测：重命名控件继续核对运行证据")
    native_sources = {path: 'class CodeField: UITextField {}; class Screen { func build() { let field = CodeField(); let input: UITextField = .init(); let menu = UIAction(title: "动作") { _ in }; let pinch = UIPinchGestureRecognizer(); let label = UILabel(); accept(.init()) }; func direct() -> UITextField { .init() }; func returned() -> UITextField { let frame: CGRect = .init(); return .init() } }',
        str(Path(path).with_name('Support.swift')): 'extension Screen { func accept(_ field: UITextField, enabled: Bool = true) {} }'}
    native = swift_syntax_index_sources(native_sources)
    native_inventory = interaction_source_inventory(native)
    if list(native_inventory.values()) != [{'UIAction': 1, 'UIPinchGestureRecognizer': 1, 'UITextField': 5}]:
        findings.append("UI 原生清单自测：控件继承、隐式构造、菜单和手势进入库存")
    native_manifest = {key: (controls, {"ExampleUITests/testNative"}) for key, controls in native_inventory.items()}
    if source_inventory_findings(native, native_manifest, {"ExampleUITests/testNative"}):
        findings.append("UI 原生清单自测：已登记控件对应验证用例")
    changed_native = swift_syntax_index_sources({**native_sources, path: native_sources[path].replace('let label = UILabel()', 'let added = UITapGestureRecognizer()')})
    if not source_inventory_findings(changed_native, native_manifest, {"ExampleUITests/testNative"}):
        findings.append("UI 原生清单自测：新增交互需要同步库存")
    if not source_inventory_findings(native, native_manifest, set()):
        findings.append("UI 原生清单自测：验证用例移除触发归属检查")
    findings.extend(native_runtime_boundary_findings(path))
    if source_inventory_findings(original, manifest, {"ExampleUITests/testScreen"}): findings.append("UI 清单自测：已归属交互")
    for change in ('struct Unvisited: View { var body: some View { Button("新页面") {} } }',
                   'extension Screen { var hiddenControl: some View { Toggle("新增", isOn: .constant(false)) } }'):
        changed = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { Button("入口") {} } }\n' + change})
        if not source_inventory_findings(changed, manifest, {"ExampleUITests/testScreen"}): findings.append("UI 清单自测：新增页面与交互进入门禁")
    if not source_inventory_findings(original, manifest, set()): findings.append("UI 清单自测：验收用例删除进入门禁")
    evidence = [{"scope": "ExampleUITests/testScreen / 页面", "label": "入口", "identifier": "", "actions": ["tap"]}]
    for declaration, invocation in [('typealias Alias = Button<Text>', 'Alias("入口") {}'),
            ('typealias Generic<T: View> = SwiftUI.Button<T>; typealias Alias = Generic<Text>', 'Alias("入口") {}'),
            ('typealias alias = Button<Text>', 'alias("入口") {}'),
            ('typealias Alias = Button<Text>', 'Alias(action: {}) { Text("入口") }')]:
        aliased = swift_syntax_index_sources({path: declaration + '; struct Screen: View { var body: some View { ' + invocation + ' } }'})
        if interaction_source_inventory(aliased) != interaction_source_inventory(original):
            findings.append("UI 别名清单自测：泛型与连续别名沿控件类型归属")
        if not source_runtime_interaction_findings(aliased, manifest, []):
            findings.append("UI 别名清单自测：控件入口需要实际访问证据")
        if source_runtime_interaction_findings(aliased, manifest, evidence):
            findings.append("UI 别名清单自测：原生控件证据沿别名匹配")
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
            ("Slider", 'Slider(value: .constant(0.5))', "drag"),
            ("MultiDatePicker", 'MultiDatePicker("日期", selection: .constant(Set<DateComponents>()))', "selection"),
            ("EditButton", 'EditButton()', "tap"), ("PasteButton", 'PasteButton(payloadType: String.self) { _ in }', "tap"),
            ("Stepper", 'Stepper("数值", value: .constant(1))', "tap")]:
        control = swift_syntax_index_sources({path: 'struct Screen: View { var body: some View { ' + invocation + '.accessibilityIdentifier("control") } }'})
        control_manifest = {key: (controls, {"ExampleUITests/testScreen"}) for key, controls in interaction_source_inventory(control).items()}
        row = dict(evidence[0], identifier="control", instance="control", actions=["input" if expected in {"tap", "selection"} else "tap"])
        if not source_runtime_interaction_findings(control, control_manifest, [row]): findings.append("UI 清单自测：控件需要对应动作类型")
        if source_runtime_interaction_findings(control, control_manifest, [dict(row, actions=["tap" if expected == "selection" else expected])]): findings.append("UI 清单自测：实际控件动作进入证据")
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
    if source_runtime_interaction_findings(combined, combined_manifest, [dict(combined_evidence, actions=["scroll", "swipe"])]):
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


def native_runtime_boundary_findings(path: str) -> list[str]:
    from ui_native_interactions import NATIVE_INTERACTION_ACTIONS
    findings = []
    for kind, action in NATIVE_INTERACTION_ACTIONS.items():
        declaration = ('UIAction(title: "动作", identifier: UIAction.Identifier("native")) { _ in }'
            if kind == 'UIAction' else kind + '()')
        source = 'class Screen { func build() { let control = ' + declaration + '; control.accessibilityIdentifier = "native" } }'
        syntax = swift_syntax_index_sources({path: source})
        manifest = {key: (controls, {'ExampleUITests/testNative'}) for key, controls in interaction_source_inventory(syntax).items()}
        row = dict(scope='ExampleUITests/testNative', identifier='native', label='', instance='control', actions=['tap' if action == 'selection' else 'drag' if action == 'pan' else action])
        if not source_runtime_interaction_findings(syntax, manifest, []):
            findings.append(f'UI 原生运行自测：{kind} 需要实际访问证据')
        if source_runtime_interaction_findings(syntax, manifest, [row]):
            findings.append(f'UI 原生运行自测：{kind} 接受对应动作证据')
        if not source_runtime_interaction_findings(syntax, manifest, [dict(row, actions=['keyboard'])]):
            findings.append(f'UI 原生运行自测：{kind} 核对动作类型')
        if not source_runtime_interaction_findings(syntax, manifest, [dict(row, scope='ExampleUITests/testOther')]):
            findings.append(f'UI 原生运行自测：{kind} 核对所属流程')
    for source, action in [
        ('class Screen { func build() { let input: UITextField = .init(); input.accessibilityIdentifier = "native" } }', 'input'),
        ('typealias Field = UITextField; class Screen { func build() { let input = Field(); input.accessibilityIdentifier = "native" } }', 'input'),
        ('class Field: UITextField { init() { accessibilityIdentifier = "native" } }; class Screen { func build() { let input = Field() } }', 'input'),
        ('class Screen { func build() { let input = UITextView(); input.isEditable = false; input.accessibilityIdentifier = "native" } }', 'tap'),
        ('class Screen { var interactionEvidence: ((String,String)->Void)?; let tap = UITapGestureRecognizer(target: self, action: #selector(tapped)); func tapped() { interactionEvidence?("native", "tap") } }', 'tap'),
        ('class Screen { var interactionEvidence: ((String,String)->Void)?; func build() { let action = UIAction(title: title) { _ in interactionEvidence?("native", "tap") } } }', 'tap'),
    ]:
        syntax = swift_syntax_index_sources({path: source})
        manifest = {key: (controls, {'ExampleUITests/testNative'}) for key, controls in interaction_source_inventory(syntax).items()}
        row = dict(scope='ExampleUITests/testNative', identifier='native', instance='control', actions=[action])
        if not source_runtime_interaction_findings(syntax, manifest, []) or source_runtime_interaction_findings(syntax, manifest, [row]):
            findings.append('UI 原生运行自测：隐式构造、别名、继承、只读正文和回调保留证据合同')
    source = 'class Timeline: UIScrollView { let pinch = UIPinchGestureRecognizer(); init() { accessibilityIdentifier = "timeline"; addGestureRecognizer(pinch) } }; class Screen { func build() { let view = Timeline() } }'
    syntax = swift_syntax_index_sources({path: source})
    manifest = {key: (controls, {'ExampleUITests/testNative'}) for key, controls in interaction_source_inventory(syntax).items()}
    row = dict(scope='ExampleUITests/testNative', identifier='timeline', instance='timeline', actions=['scroll'])
    if not source_runtime_interaction_findings(syntax, manifest, [row]):
        findings.append('UI 原生运行自测：滚动载体需要独立手势动作')
    if source_runtime_interaction_findings(syntax, manifest, [dict(row, actions=['scroll', 'pinch'])]):
        findings.append('UI 原生运行自测：滚动与原生手势沿同一载体分别验证')
    return findings


def list_row_layout_boundary_findings() -> list[str]:
    from ui_rules import list_row_layout_findings
    findings = []
    cases = [
        ('struct Page: View { var body: some View { List { Text("行").listRowInsets(.init()) } } }', False),
        ('struct Page: View { var body: some View { Form { Text("行") }.appListRowInsets() } }', True),
        ('struct Page: View { var body: some View { List { Text("行") }.listRowInsets(.init()) } }', True),
        ('extension View { func appGroupedListStyle() -> some View { listStyle(.insetGrouped).listRowInsets(.init()) } }', True),
        ('struct AppRefreshStatusRow: View { var body: some View { HStack { Text("时间") }.appListRowInsets() } }', False),
        ('struct AppRefreshStatusRow: View { var body: some View { HStack { Text("时间") }.frame(minHeight: 44).appListRowInsets() } }', False),
        ('struct AppRefreshStatusRow: View { var body: some View { HStack { Text("时间").appListRowInsets() } } }', True),
        ('struct AppRefreshStatusRow: View { var body: some View { HStack { Text("时间") } }; func unused() -> some View { HStack {}.appListRowInsets() } }', True),
    ]
    for source, expected in cases:
        if bool(list_row_layout_findings(swift_syntax_index_sources({'ui-self-test.swift': source}))) != expected:
            findings.append('UI 布局自测：列表容器、行组件和闲置修饰的边距归属')
    return findings


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
                    'ContentUnavailableView { Text("状态") } description: {\nText("模块说明")\n}\n'
                    'Section { Text("内容") } footer: { Text(\n"多行提示"\n).font(.body); Text(message) }\n'
                    'ContentUnavailableView("空", systemImage: "x", description: Text(\n"构造说明"\n))\n'
                    'AppEmptyState(title: "空", systemImage: "x", message: "传入说明")\n'
                    'Section { Text("内容") } footer: { Text("换个关键词试试。") }\n'
                    '// Section { } footer: { Text("注释候选") }\n')
    try:
        with patch.object(rules, "ROOT", fixture), redirect_stdout(StringIO()):
            rules.explanatory_text_report()
        report = (fixture / ".build/explanatory-text-report.txt").read_text()
        assert '模块提示' in report and '模块说明' in report and 'Modules/DesignSystemKit' in report
        assert all(value in report for value in ('多行提示', 'Text(message)', '构造说明', '传入说明'))
        assert '.font' not in report and '换个关键词试试。' not in report and '注释候选' not in report
    except (AssertionError, OSError) as error:
        return [f"解释文案范围自测：{error}"]
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return checker_report_boundary_findings()


def checker_report_boundary_findings() -> list[str]:
    from contextlib import redirect_stdout
    from io import StringIO
    import importlib.util
    import shutil
    import subprocess
    import sys
    from types import ModuleType, SimpleNamespace
    from unittest.mock import patch

    fixture = ROOT / ".build/static-audit/explanatory-self-test"
    names = ('code-quality-report.txt', 'ui-consistency-report.txt', 'explanatory-text-report.txt')
    reports = [fixture / '.build' / name for name in names]
    (fixture / '.build/static-audit').mkdir(parents=True, exist_ok=True)
    try:
        for report in reports:
            report.write_text('previous report')
        audit = (ROOT / 'Scripts/run-static-audit.sh').read_text()
        cleanup = audit.split("trap 'exit 143' TERM\n", 1)[1].split('\nSWIFT_FRONTEND=', 1)[0]
        result = subprocess.run(['zsh', '-c', 'ROOT_DIR="$1"\nLOG_DIR="$ROOT_DIR/.build/static-audit"\n' + cleanup,
                                 'checker-report-cleanup', str(fixture)], capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr
        assert [report for report in reports if report.exists()] == [], '审计启动需要清理固定报告'
        spec = importlib.util.spec_from_file_location('checker_report_self_test', ROOT / 'Scripts/check-code-quality.py')
        subject = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(subject)
        visited = []

        def quality_probe():
            raise AssertionError('quality fixture failure')

        def ui_probe():
            raise AssertionError('UI fixture failure')

        def write_report(index, findings):
            visited.append(names[index])
            reports[index].write_text('\n'.join(findings))
            return int(bool(findings))

        module = ModuleType('checker_ui_self_test')
        module.ast_marker_boundary_findings = ui_probe
        module.source_boundary_findings = lambda: visited.append('source') or []
        module.map_theme_color_contract_findings = lambda: visited.append('theme') or []
        module.interaction_inventory_boundary_findings = lambda: visited.append('interactions') or []
        module.main = lambda syntax, findings: write_report(1, findings)
        ui_spec = SimpleNamespace(name=module.__name__, loader=SimpleNamespace(exec_module=lambda loaded: None))
        with patch.dict(sys.modules), patch.object(subject, 'swift_files', return_value=[]), \
                patch.object(subject, 'swift_syntax_index', return_value={}), \
                patch('code_quality_tests.checker_boundary_findings', new=quality_probe), \
                patch.object(subject.importlib.util, 'spec_from_file_location', return_value=ui_spec), \
                patch.object(subject.importlib.util, 'module_from_spec', return_value=module), \
                patch.object(subject, 'main', side_effect=lambda syntax, findings: write_report(0, findings)), \
                patch.object(subject, 'explanatory_text_report', side_effect=lambda: write_report(2, ['current source'])), \
                redirect_stdout(output := StringIO()):
            assert subject.combined_main() == 1, '自测失败需要保留失败状态'
        assert visited == ['source', 'theme', 'interactions'], '自测失败后立即返回诊断'
        for probe in ('quality_probe', 'ui_probe'):
            assert probe in output.getvalue() and 'ui_interaction_tests.py:' in output.getvalue(), '诊断需要记录失败组与位置'
        assert [report for report in reports if report.exists()] == [], '失败时沿已清理报告和当前诊断验收'
    except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
        return [f'组合检查报告自测：{error}']
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return []


def visual_contract_boundary_findings() -> list[str]:
    from ui_rules import visual_contract_present, rendered_component_counts
    marker = 'StrokeStyle(lineWidth: 2, dash: [5, 4])'
    contract = 'Modules/CourseFeature/Sources/CourseHistoryGradesViews.swift'
    moved = ROOT / 'Modules/CourseFeature/Sources/Moved.swift'
    template = 'struct CourseHistoryGradesChart: View { var body: some View { Text("chart").lineStyle(MARKER) } }'
    assert visual_contract_present(contract, marker, {moved: template.replace('MARKER', 'StrokeStyle(\n lineWidth: 2,\n dash: [5, 4]\n)')})
    assert not visual_contract_present(contract, marker, {moved: '// ' + marker})
    assert not visual_contract_present(contract, marker, {moved: marker.replace('[5, 4]', '[5, 3]')})
    assert not visual_contract_present(contract, marker, {moved: 'func unused() { _ = ' + marker + ' }'})
    assert not visual_contract_present(contract, marker, {moved: 'struct CourseHistoryGradesChart: View { var body: some View { Text("chart") }; func unused() -> some View { Text("unused").lineStyle(' + marker + ') } }'})
    assert not visual_contract_present(contract, marker, {moved: template.replace('CourseHistoryGradesChart', 'OtherChart').replace('MARKER', marker)})
    for condition, present in [('false', False), ('true', True), ('1 == 2', False), ('isVisible', True)]:
        content = f'if {condition} {{ Text("chart").lineStyle({marker}) }} else {{ Text("plain") }}'
        sample = template.replace('Text("chart").lineStyle(MARKER)', content)
        assert visual_contract_present(contract, marker, {moved: sample}) == present
        sample = template.replace('Text("chart").lineStyle(MARKER)',
            f'if {condition} {{ helper() }} else {{ Text("plain") }}')[:-1] + f'; func helper() -> some View {{ Text("chart").lineStyle({marker}) }} }}'
        assert visual_contract_present(contract, marker, {moved: sample}) == present
        sample = f'struct Screen: View {{ var body: some View {{ if {condition} {{ AppCard {{ Text("chart") }} }} }} }}'
        syntax = swift_syntax_index_sources({str(moved): sample})
        assert bool(rendered_component_counts(syntax[str(moved)], syntax)['AppCard']) == present
    for content in [f'if true {{ Text("plain") }} else {{ Text("chart").lineStyle({marker}) }}',
            f'let hidden = false; if hidden {{ Text("chart").lineStyle({marker}) }}',
            f'let hidden = false; let alias = hidden; if alias {{ Text("chart").lineStyle({marker}) }}',
            f'false ? Text("chart").lineStyle({marker}) : Text("plain")',
            f'HStack {{ Text("图表"); if false {{ Text("chart").lineStyle({marker}) }} }}',
            f'HStack {{ false ? Text("图表").lineStyle({marker}) : Text("plain") }}',
            f'return Text("plain"); Text("chart").lineStyle({marker})']:
        assert not visual_contract_present(contract, marker, {moved: template.replace('Text("chart").lineStyle(MARKER)', content)})
    source = template.replace('Text("chart").lineStyle(MARKER)', f'if false {{ Text("chart").lineStyle({marker}) }}')
    custom = ROOT / 'Modules/CourseFeature/Sources/Operators.swift'
    assert visual_contract_present(contract, marker, {moved: source.replace('if false', 'if 1 == 2'), custom: 'struct Bool {}'})
    return []
