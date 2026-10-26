"""Exercise cross-file request ownership and lifecycle call boundaries."""
from code_quality_rules import ROOT, ast_has_view_request, view_transport_findings, automatic_school_fetch_findings, declaration_conformances


def cross_file_view_request_self_test() -> list[str]:
    from swift_source_index import swift_syntax_index_sources
    from swift_type_index import SwiftTypeIndex
    from ui_source_facts import view_helper_ranges
    from unittest.mock import patch
    from network_capability_rules import matching_api_calls
    for returned, expected in [('some View', True), ('some SwiftUI.View & Sendable', True), ('AnyView', True), ('Text', True), ('Content', True),
            ('Alias', True), ('WKWebView?', False), ('UIView', False), ('ContentViewModel', False)]:
        path = str(ROOT / 'BIT101-iOS/NativeBridge.swift')
        source = 'struct Content: View {}; typealias Alias = Content; struct ContentViewModel {};' + \
            'struct Factory { func make(_ webView: WKWebView) -> RETURNED { webView.load(request); fatalError() } }'
        facts = swift_syntax_index_sources({path: source.replace('RETURNED', returned)})
        assert bool(view_transport_findings(facts)) == expected, returned
    shared = swift_syntax_index_sources({
        'Views.swift': 'struct First: View { var body: some View { makeContent() } }; struct Second: View { var body: some View { Text("two") } }',
        'Helpers.swift': 'func makeContent() -> some View { makeLeaf() }; func makeLeaf() -> some View { Text("leaf") }; func unused() { URLRequest(url: url) }',
        'Other.swift': 'struct Other: View { var body: some View { Text("other") } }'})
    resolver = SwiftTypeIndex(shared)
    with patch('network_capability_rules.matching_api_calls', wraps=matching_api_calls) as resolve:
        first = view_helper_ranges(shared, resolver, origin='Views.swift')
        count = resolve.call_count
        other = view_helper_ranges(shared, resolver, origin='Other.swift')
        assert first['Helpers.swift'] and not other['Helpers.swift']
        assert view_helper_ranges(shared, resolver, origin='Views.swift') is first
        assert resolve.call_count == count, '来源切换与重复查询复用 helper 图'
    for split in (False, True):
        for action, expected in (('await rawLoad(client: client)', True), ('()', False)):
            view = str(ROOT / 'BIT101-iOS/HelperScreen.swift')
            helper = str(ROOT / 'BIT101-iOS/HelperActions.swift')
            body = 'func rawLoad(client: HTTPClient) async throws { _ = try await client.send(URLRequest(url: url)) }'
            source = 'struct Screen: View { let client: HTTPClient; var body: some View { Text("value").task { ACTION } } }'.replace('ACTION', action)
            inputs = {view: source, helper: body} if split else {view: source + "; " + body}
            facts = swift_syntax_index_sources(inputs)
            if ast_has_view_request(facts[view], context=facts) != expected or bool(view_transport_findings(facts)) != expected:
                return ['视图辅助函数边界自测：同文件、跨文件及未调用入口']
    sources = {
        "View.swift": "enum Namespace { struct Screen: SwiftUI.View {}; struct Helper {} }",
        "Actions.swift": "extension Namespace.Screen { func load() { _ = URLRequest(url: url) } }",
        "Other.swift": "extension Namespace.Helper { func load() { _ = URLRequest(url: url) } }",
    }
    index = swift_syntax_index_sources(sources)
    for action in ('await cloud.refreshFromCloudIfNeeded()', 'await Bootstrap().start()', 'await Bootstrap.init().start()',
            'await Bootstrap.make().start()', 'await makeBootstrap().start()', 'let work = Bootstrap().start; await work()'):
        cloud = swift_syntax_index_sources({
            'App.swift': 'struct BIT101_iOSApp: App { let cloud: ScheduleCloudSyncManager; var body: some Scene { WindowGroup { Text("sample").task { ACTION } } } }'.replace('ACTION', action),
            'Bootstrap.swift': 'struct Bootstrap { let cloud: ScheduleCloudSyncManager; static func make() -> Bootstrap { Bootstrap() }; func start() async { await cloud.refreshFromCloudIfNeeded() } }; func makeBootstrap() -> Bootstrap { Bootstrap() }',
            'Cloud.swift': 'class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }'})
        if not automatic_school_fetch_findings(cloud):
            return ['代码质量规则边界自检失败：云拉取的生命周期传递调用']
    cloud['App.swift'] = swift_syntax_index_sources({'App.swift':
        'struct SampleApp: App { var body: some Scene { WindowGroup { Text("sample").task { let work = Bootstrap().start; _ = work } } } }'})['App.swift']
    if automatic_school_fetch_findings(cloud):
        return ['代码质量规则边界自检失败：待用户操作的方法引用']
    for action, invoked in (('_ = actions', False), ('await actions.start()', True)):
        stored = swift_syntax_index_sources({'App.swift':
            'class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; struct Actions { let refresh: () async -> Void; func start() async { await refresh() } }; struct SampleApp: App { let cloud: ScheduleCloudSyncManager; var body: some Scene { WindowGroup { Text("sample").task { let actions = Actions(refresh: { await cloud.refreshFromCloudIfNeeded() }); ACTION } } } }'.replace('ACTION', action)})
        if bool(automatic_school_fetch_findings(stored)) != invoked:
            return ['代码质量规则边界自检失败：成员构造器保存闭包与后续调用']
    for action, invoked in (('_ = actions', False), ('await actions.start()', True)):
        stored = swift_syntax_index_sources({'App.swift':
            'protocol ScheduleCourseServicing { func syncCourses(term: String) async }; struct Service: ScheduleCourseServicing { func syncCourses(term: String) async {} }; struct Actions { let syncCourses: (String) async -> Void; func start() async { await syncCourses("term") } }; struct SampleApp: App { let service: Service; var body: some Scene { WindowGroup { Text("sample").task { let actions = Actions(syncCourses: { await service.syncCourses(term: $0) }); ACTION } } } }'.replace('ACTION', action)})
        if bool(automatic_school_fetch_findings(stored)) != invoked:
            return ['代码质量规则边界自检失败：同名参数标签与实际执行引用']
    registered = swift_syntax_index_sources({'App.swift':
        'typealias Presenter = (_ resolve: @escaping () async -> Void) -> Void; class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; struct Bootstrap { let cloud: ScheduleCloudSyncManager; let present: Presenter; func start() { present { await cloud.refreshFromCloudIfNeeded() } } }; struct SampleApp: App { var body: some Scene { WindowGroup { Text("sample").task { Bootstrap().start() } } } }'})
    if automatic_school_fetch_findings(registered):
        return ['代码质量规则边界自检失败：交互回调的登记边界']
    for operation, executed in (('_ = action', False), ('await action()', True), ('await forward(action)', True),
            ('_ = Actions(refresh: action)', False)):
        callbacks = swift_syntax_index_sources({'App.swift':
            'class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; struct Actions { let refresh: () async -> Void }; func forward(_ action: @escaping () async -> Void) async { await action() }; struct Bootstrap { func run(action: @escaping () async -> Void) async { OPERATION } }; struct SampleApp: App { let cloud: ScheduleCloudSyncManager; var body: some Scene { WindowGroup { Text("sample").task { await Bootstrap().run(action: cloud.refreshFromCloudIfNeeded) } } } }'.replace('OPERATION', operation)})
        if bool(automatic_school_fetch_findings(callbacks)) != executed:
            return ['代码质量规则边界自检失败：回调保存、直接执行与传递执行']
    for method, restricted in (('preferences', False), ('business', True)):
        isolated = swift_syntax_index_sources({'App.swift':
            'class ExperimentalPreferenceCloudSync { func refreshFromCloudIfNeeded() async {} }; class ScheduleCloudSyncManager { func refreshFromCloudIfNeeded() async {} }; struct Bootstrap { let pref: ExperimentalPreferenceCloudSync; let cloud: ScheduleCloudSyncManager; func perform(operation: @escaping () async -> Void) async { await operation() }; func preferences() async { await perform(operation: { await pref.refreshFromCloudIfNeeded() }) }; func business() async { await perform(operation: { await cloud.refreshFromCloudIfNeeded() }) } }; struct SampleApp: App { var body: some Scene { WindowGroup { Text("sample").task { await Bootstrap().METHOD() } } } }'.replace('METHOD', method)})
        if bool(automatic_school_fetch_findings(isolated)) != restricted:
            return ['代码质量规则边界自检失败：同名执行参数的调用归属']
    preference = swift_syntax_index_sources({
        'App.swift': 'struct SampleApp: App { let bootstrap: Bootstrap; var body: some Scene { WindowGroup { Text("sample").task { await bootstrap.start() } } } }',
        'Bootstrap.swift': 'struct Bootstrap { let cloud: ExperimentalPreferenceCloudSync; func start() async { await cloud.refreshFromCloudIfNeeded() } }; class ExperimentalPreferenceCloudSync { func refreshFromCloudIfNeeded() async {} }'})
    if automatic_school_fetch_findings(preference):
        return ['代码质量规则边界自检失败：已启用偏好同步的生命周期协调']
    types = declaration_conformances(index)
    if not ast_has_view_request(index["Actions.swift"], types, index) or ast_has_view_request(index["Other.swift"], types, index):
        return ["代码质量规则边界自检失败：跨文件 View 扩展与完整类型作用域"]
    for target in ("Foundation.URLRequest", "Leaf"):
        sources["Aliases.swift"] = f"private typealias Leaf = Foundation.URLRequest; typealias Request = {target}"
        sources["Actions.swift"] = "private typealias Leaf = Model; extension Namespace.Screen { func load() { _ = Request(url: url) } }"
        aliases = swift_syntax_index_sources(sources)
        if not ast_has_view_request(aliases["Actions.swift"], declaration_conformances(aliases), aliases):
            return ["代码质量规则边界自检失败：跨文件请求别名与别名声明文件归属"]
    for method in ("fetchScores", "`fetchScores`"):
        school = swift_syntax_index_sources({"School.swift": f"protocol ScoreListServicing {{ func fetchScores() async }}; struct Screen: View {{ let service: any ScoreListServicing; var body: some View {{ Text(\"sample\").task {{ await service.{method}() }} }} }}"})
        if not automatic_school_fetch_findings(school):
            return ["代码质量规则边界自检失败：生命周期学校请求的转义标识符"]
    for setup, preparation, action in (
        ("", "let refresh = service.syncCourses;", "try? await refresh()"),
        ("var refresh: () async throws -> Void { service.syncCourses };", "", "try? await refresh()"),
        ("", "", "_ = Model(service: service)"),
        ("", "", "_ = Model.init(service: service)"),
        ("", "", "let model: Model = .init(service: service); _ = model"),
    ):
        school = swift_syntax_index_sources({"School.swift": "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Model { init(service: any ScheduleCourseServicing) { Task { try? await service.syncCourses() } } }; struct Screen: View { let service: any ScheduleCourseServicing; " + setup + " var body: some View { " + preparation + " Text(\"sample\").task { " + action + " } } }"})
        if not automatic_school_fetch_findings(school):
            return ["代码质量规则边界自检失败：生命周期初始化器与方法引用调用链"]
        safe = swift_syntax_index_sources({"Safe.swift": "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Screen: View { let service: any ScheduleCourseServicing; " + setup + " var body: some View { " + preparation + " Text(\"sample\").task { _ = 1 } } }"})
        if automatic_school_fetch_findings(safe): return ["代码质量规则边界自检失败：手动调用引用作用域"]
    safe = swift_syntax_index_sources({"Safe.swift": "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Model { init(service: any ScheduleCourseServicing) { Task { try? await service.syncCourses() } } }; struct Screen: View { var body: some View { Text(\"sample\").task { let model: Model? = nil; _ = model } } }"})
    if automatic_school_fetch_findings(safe): return ["代码质量规则边界自检失败：类型声明与构造调用区分"]
    for property in ("let work = Task { try? await Service().syncCourses() }", "let work = Task { try? await Service().syncCourses() }; init() {}"):
        school = swift_syntax_index_sources({"School.swift": "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Service: ScheduleCourseServicing { func syncCourses() async throws {} }; class Model { " + property + " }; struct Screen: View { var body: some View { Text(\"sample\").task { _ = Model() } } }"})
        if not automatic_school_fetch_findings(school): return ["代码质量规则边界自检失败：构造执行实例属性初始化"]
    for construction in ("var manualRefresh: () async throws -> Void; init(service: any ScheduleCourseServicing) { manualRefresh = { try await service.syncCourses() } }", "let manualRefresh = Service().syncCourses", "let manualRefresh = { try await Service().syncCourses() }"):
        fixture = "protocol ScheduleCourseServicing { func syncCourses() async throws }; struct Service: ScheduleCourseServicing { func syncCourses() async throws {} }; class Model { " + construction + " }; struct Screen: View { var body: some View { Text(\"sample\").task { let model = Model(service: Service()); ACTION } } }"
        safe = swift_syntax_index_sources({"Safe.swift": fixture.replace("ACTION", "_ = model")})
        if automatic_school_fetch_findings(safe): return ["代码质量规则边界自检失败：构造保存手动回调"]
        invoked = swift_syntax_index_sources({"School.swift": fixture.replace("ACTION", "try? await model.manualRefresh()")})
        if not automatic_school_fetch_findings(invoked): return ["代码质量规则边界自检失败：生命周期调用已保存回调"]
    fixture = ('protocol ScheduleCourseServicing { func fetchCurrentTermOnly() async throws -> String }; '
        'struct Service: ScheduleCourseServicing { func fetchCurrentTermOnly() async throws -> String { "term" } }; '
        'struct CachedTermReader { func fetchCurrentTermOnly() async throws -> String { "cached" } }; '
        'struct Screen: View { @Environment(\\.scenePhase) var phase; let service: RECEIVER; '
        'var body: some View { Text("sample").MODIFIER { ACTION } } }')
    for receiver, modifier, action, expected in (
            ('Service', 'onChange(of: phase)', 'Task { try await service.fetchCurrentTermOnly() }', True),
            ('any ScheduleCourseServicing', 'onChange(of: accountID)', 'try await service.fetchCurrentTermOnly()', True),
            ('CachedTermReader', 'task', 'try await service.fetchCurrentTermOnly()', False),
            ('Service', 'task', 'if false { try await service.fetchCurrentTermOnly() }', False),
            ('Service', 'task', 'return; try await service.fetchCurrentTermOnly()', False)):
        source = fixture.replace('RECEIVER', receiver).replace('MODIFIER', modifier).replace('ACTION', action)
        if bool(automatic_school_fetch_findings(swift_syntax_index_sources({'School.swift': source}))) != expected:
            return ['代码质量规则边界自检失败：变更回调、接收者归属与不可执行分支']
    for owner, callback, action, expected in (
            ('UIApplicationDelegate', 'applicationDidBecomeActive', 'Task { await service.fetchScores() }', True),
            ('UIApplicationDelegate', 'application', 'Task { await service.fetchScores() }', True),
            ('UISceneDelegate', 'sceneDidBecomeActive', 'Task { await service.fetchScores() }', True),
            ('UISceneDelegate', 'scene', 'Task { await service.fetchScores() }', True),
            ('NSObject', 'applicationDidBecomeActive', 'Task { await service.fetchScores() }', False),
            ('UIApplicationDelegate', 'manualRefresh', 'Task { await service.fetchScores() }', False),
            ('UISceneDelegate', 'sceneDidBecomeActive', '_ = service', False)):
        source = ('protocol ScoreListServicing { func fetchScores() async }; '
            f'class Controller: {owner} {{ let service: any ScoreListServicing; func {callback}() {{ {action} }} }}')
        if bool(automatic_school_fetch_findings(swift_syntax_index_sources({'Delegate.swift': source}))) != expected:
            return ['代码质量规则边界自检失败：系统 delegate 生命周期及手动入口归属']
    return []
