"""Executable checks for workflow dispatch, cache ownership and audit rules."""
from __future__ import annotations
from workflow_process_tests import workflow_lock_boundary_findings
from script_command_tests import script_command_boundary_findings, device_discovery_boundary_findings, audit_lock_boundary_findings, restore_installation_boundary_findings
from worker_contract_tests import worker_boundary_findings
from report_inbox_tests import report_inbox_boundary_findings, community_recovery_self_test

from pathlib import Path
import json, os, re, subprocess, sys, shutil, signal
import shlex
from contextlib import nullcontext, redirect_stdout, redirect_stderr
from io import BytesIO, StringIO
from unittest.mock import Mock, patch
from swift_source_index import swift_syntax_index_sources
from ui_rule_tests import explanatory_text_boundary_findings, school_lifecycle_boundary_findings

from code_quality_call_tests import cross_file_view_request_self_test

from code_quality_rules import (
    ROOT, SCRIPT_ROOT, swift_files, ast_has_view_request, ci_trigger_shell_self_test,
    cancellation_findings, asynchronous_test_wait_findings, client_source_findings, extension_dependency_findings, mask_literals_and_comments,
    view_transport_findings, discarded_file_write_findings, file_write_calls,
    owner_has_call, uses_application_support_storage, view_request_matches, source_findings,
)


def campus_fixture_self_test() -> None:
    import generate_campus_map_fixture as subject
    from generate_campus_map_fixture import merge_locations, FIXTURE_PATH
    reviewed = [
        {"campus": "中关村校区", "classroom": "历史楼", "expected": "历史楼", "review": "mapped"},
        {"campus": "良乡校区", "classroom": "校外", "expected": None, "review": "excluded"},
    ]
    merged = merge_locations(reviewed, [("良乡校区", "新地点"), ("良乡校区", "校外")])
    assert all(row in merged for row in reviewed)
    assert len(merged) == 3 and merge_locations(reviewed, []) == reviewed
    assert next(row for row in merged if row["classroom"] == "新地点")["review"] == "pending"
    assert merge_locations(merged, [("良乡校区", "新地点")]) == merged
    fixtures = json.loads(FIXTURE_PATH.read_text())
    assert fixtures and len({(row["campus"], row["classroom"]) for row in fixtures}) == len(fixtures)
    for row in fixtures:
        assert row["review"] in {"mapped", "excluded"}, "地图 fixture 需要完成地点审核"
        assert (isinstance(row["expected"], str) and bool(row["expected"])) if row["review"] == "mapped" else row["expected"] is None
    directory = ROOT / '.build/static-audit/campus-fixture-self-test'
    fixture = directory / 'campus-map-locations.json'
    incoming = fixture.with_suffix('.incoming')
    original_write = Path.write_text
    def interrupted(path, text, **kwargs):
        original_write(path, text[:1], **kwargs)
        raise OSError('fixture write interrupted')
    try:
        directory.mkdir(parents=True, exist_ok=True)
        fixture.write_text(json.dumps(reviewed, ensure_ascii=False))
        original = fixture.read_bytes()
        with patch.object(subject, 'FIXTURE_PATH', fixture):
            with patch.object(Path, 'write_text', interrupted):
                try: subject.update_fixture([('良乡校区', '新地点')], True)
                except OSError: pass
                else: raise AssertionError('地图案例写入失败需要传播')
            assert fixture.read_bytes() == original and not incoming.exists()
            try: subject.update_fixture([('良乡校区', '新地点')], False)
            except SystemExit: pass
            else: raise AssertionError('新增案例需要显式选择待审核写入')
            assert fixture.read_bytes() == original
            incoming.write_text('partial')
            assert subject.update_fixture([('良乡校区', '新地点')], True) == (3, 1)
            assert json.loads(fixture.read_text()) == merged and not incoming.exists()
    finally:
        shutil.rmtree(directory, ignore_errors=True)

def checker_boundary_findings() -> list[str]:
    from code_quality_rules import script_findings
    from types import SimpleNamespace
    for suffix in ('.py', '.sh'):
        path = ROOT / ('Scripts/nested/entry' + suffix)
        source = "if __name__ == '__main__': pass" if suffix == '.py' else 'echo ready'
        with patch('code_quality_rules.repository_script_paths', return_value=[path]), \
                patch.object(Path, 'read_text', return_value=source), patch.object(Path, 'stat', return_value=SimpleNamespace(st_mode=0)):
            assert len(script_findings()) == 2
    import warnings
    from ui_rules import check_fonts
    from ui_source_facts import pattern_nodes
    from ui_design_contracts import PADDING_LITERAL
    visual = 'struct Example: View { var body: some View { Text(rows[0]).padding(19).font(.system(size: 23)) } }'
    visual_path = ROOT / 'BIT101-iOS/BIT101_iOSApp.swift'
    visual_facts = swift_syntax_index_sources({str(visual_path): visual})[str(visual_path)]
    visual_errors = []
    with patch('ui_rules.source_text', return_value=visual):
        check_fonts(visual_errors, {str(visual_path): visual_facts})
    assert any('23' in error for error in visual_errors), '下标嵌套后的显式字号需要参与验收'
    assert any(node['arguments'] == ['19'] for node in pattern_nodes(visual_facts, PADDING_LITERAL)), '下标嵌套后的间距参数需要按调用归属读取'
    from network_capability_rules import constant_boolean
    with warnings.catch_warnings(record=True) as observed:
        warnings.simplefilter('always')
        assert constant_boolean(r'key == "row.\(id)"', lambda name: None) is None
        assert constant_boolean(r'false && check("row.\(id)")', lambda name: None) is False
        assert not observed
    from swift_source_index import swift_code, swift_regex_ranges
    indexed_sources = {"RegexCache.swift": 'let label = "预热索引"; let pattern = /a\\/b/; // 已有事实\n',
        "CommentCache.swift": 'let number = 17 // 普通注释\n'}
    swift_syntax_index_sources(indexed_sources)
    swift_regex_ranges.cache_clear()
    with patch('swift_source_index._run_swift_syntax_index', side_effect=AssertionError('批量事实需要复用')):
        for source in indexed_sources.values():
            assert len(swift_code(source)) == len(source)
            assert '注释' not in swift_code(source)
    from swift_type_index_tests import self_test as type_index_self_test
    type_index_self_test()
    from audit_callback_rules import self_test as audit_delegate_self_test
    audit_delegate_self_test()
    findings: list[str] = []
    escape_path = ROOT / 'BIT101-iOS/Concurrency.swift'
    for conformance in ('Sendable', 'Swift.Sendable', 'Swift.`Sendable`', 'Alias'):
        source = 'import Foundation; typealias Alias = Sendable; final class Escaped: @unchecked ' + conformance + ' {}\n'
        syntax = swift_syntax_index_sources({str(escape_path): source})
        with patch('code_quality_rules.swift_files', return_value=[escape_path]), patch.object(Path, 'read_text', return_value=source):
            errors, _ = source_findings(syntax)
        assert any('并发安全检查' in error for error in errors), conformance
    from code_quality_rules import audit_callback_findings
    callbacks = Path(__file__).with_name("run-static-audit.sh").read_text()
    assert audit_callback_findings(callbacks) == []
    assert audit_callback_findings(callbacks.replace('python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"', 'true'))
    from code_quality_rules import scheme_inventory_findings
    scheme = '<Scheme LastUpgradeVersion="2700"><BuildAction buildImplicitDependencies="YES" /></Scheme>'
    if scheme_inventory_findings({"App": scheme}):
        findings.append("Scheme 库存自测：单一共享合同进入验收")
    if not scheme_inventory_findings({"App": scheme, "Copy": scheme.replace("2700", "2630")}):
        findings.append("Scheme 库存自测：元数据差异保留重复合同判定")
    if scheme_inventory_findings({"App": scheme, "Independent": scheme.replace("YES", "NO")}):
        findings.append("Scheme 库存自测：独立构建合同保持不同入口")
    from validate_versions import app_store_request_self_test
    findings.extend(app_store_request_self_test())
    from validation_test_areas import test_inventory
    from validation_test_areas import inventory_findings, critical_findings, CRITICAL_CONTRACTS, fixture_resource_self_test
    fixture_resource_self_test()
    findings.extend(inventory_findings({test.split("/", 1)[0] for test in test_inventory("all")}))
    inventories = {group: test_inventory(group) for group in CRITICAL_CONTRACTS}
    findings.extend(critical_findings(inventories))
    removed = {group: set(tests) for group, tests in inventories.items()}
    removed["all"].discard(next(iter(CRITICAL_CONTRACTS["all"].values())))
    assert critical_findings(removed)
    findings.extend(community_recovery_self_test())
    findings.extend(script_output_boundary_findings())
    campus_fixture_self_test()
    from development_workflow_tests import development_workflow_self_test
    development_workflow_self_test()
    markers = mask_literals_and_comments('// TODO\n/* FIXME /* HACK */ */\nlet text = "TODO"', keep_comments=True)
    if len(re.findall(r"\b(?:TODO|FIXME|HACK)\b", markers)) != 3:
        findings.append("代码质量规则边界自检失败：维护标记覆盖行注释及嵌套块注释")
    cancellation_path = ROOT / "Modules/TransportCore/Sources/RelocatedCancellation.swift"
    cancellation_source = '''
enum TaskCancellation {
    static func matches(_ error: Error) -> Bool { error is CancellationError }
}
enum Consumer {
    typealias Cancel = CancellationError; func alias(_ error: Error) -> Bool { error is Cancel }
    func wrong(_ renamed: Error) -> Bool { renamed is Swift.CancellationError }
    func cast(_ error: Error) -> Bool { (error as? CancellationError) != nil }
    func catches() { do { try work() } catch let error as CancellationError { consume(error) } }
    func wrapped(_ renamed: Error) -> Bool { TaskCancellation.matches(renamed) }
    let example = "error is CancellationError"
}
'''
    cancellation_syntax = swift_syntax_index_sources({str(cancellation_path): cancellation_source})
    if len(cancellation_findings(cancellation_path, cancellation_source, cancellation_syntax[str(cancellation_path)])) != 4:
        findings.append("代码质量规则边界自检失败：取消识别按声明归属处理文件迁移、变量改名和模块限定类型")
    if cancellation_findings(ROOT / "ModuleTests/Transport/ExactErrorTests.swift", cancellation_source, cancellation_syntax[str(cancellation_path)]):
        findings.append("代码质量规则边界自检失败：测试可直接断言底层取消类型")
    wait_path = ROOT / 'ModuleTests/Transport/EventTests.swift'
    view_path = str(ROOT / 'BIT101-iOS/Example.swift')
    transport_path = str(ROOT / 'Modules/TransportCore/Sources/HTTPClient.swift')
    for body, expected in (
        ('struct Example: View { let client: HTTPClient; let request: URLRequest; var body: some View { Text("").task { _ = try? await client.send(request) } } }', True),
        ('struct Example: View { let session: URLSession; let request: URLRequest; var body: some View { Text("").task { _ = try? await session.data(for: request) } } }', True),
        *((f'struct Example: {kind} {{ let client: HTTPClient; var body: some Scene {{ WindowGroup {{ Text("").task {{ try? await client.send(URLRequest(url: url)) }} }} }} }}', True) for kind in ('App', 'Scene')),
        ('struct Example: ViewModifier { let client: HTTPClient; let request: URLRequest; func body(content: Content) -> some View { content.task { _ = try? await client.send(request) } } }', True),
        ('struct Example { let client: HTTPClient; func render(_ request: URLRequest) -> some View { Task { _ = try? await client.send(request) }; EmptyView() } }', True),
        *((f'struct Example: View {{ let client: CommunityAPIClient; var body: some View {{ Text("").task {{ try? await client.{method}(request) }} }} }}', True)
            for method in ('request', 'requestData', 'requestVoid')),
        ('struct Example: View { let client: HTTPClient; var body: some View { let send = client.send; return Text("").task { _ = try? await send(request) } } }', True),
        ('struct Example { let client: HTTPClient; func render() -> some View { let send = client.send; Task { _ = try? await send(request) }; EmptyView() } }', True),
        ('struct Example: View { let service: Service; var body: some View { let send = service.send; return Text("").task { await send(1) } } }; struct Service { func send(_ value: Int) async {} }', False),
        ('struct Example: View { let client: Local; var body: some View { Text("").task { await client.send(1) } } }; struct Local { func send(_ value: Int) async {} }', False),
        ('struct Example: View { let service: Service; var body: some View { Text("").task { await service.fetch() } } }; struct Service { func fetch() async {} }', False),
    ):
        index = swift_syntax_index_sources({view_path: body, transport_path: 'public struct HTTPClient {}'})
        if bool(view_transport_findings(index)) != expected: findings.append('视图网络传输自测：现成请求、视图工厂及同名业务方法按所属类型验收')
    storage_path = str(ROOT / 'Modules/StorageCore/Sources/AppFileService.swift')
    for argument, expected in (('root', True), ('root.appendingPathComponent("cache")', True), ('"cache"', False)):
        source = '''struct FileHelper { let files: any AppFileService;
            func run(_ root: URL) { try? save(ARGUMENT) }
            private func save(_ location: URL) throws { try files.writeData(Data(), to: location) }
            private func save(_ text: String) throws {} }'''.replace('ARGUMENT', argument)
        index = swift_syntax_index_sources({view_path: source,
            storage_path: 'public protocol AppFileService { func writeData(_ data: Data, to url: URL) throws }'})
        if bool(discarded_file_write_findings(Path(view_path), source, index[view_path], file_write_calls(index))) != expected:
            findings.append('持久化重载自测：未知实参保留可能的文件写入边，明确类型沿对应重载验收')
    from swift_type_index_tests import asynchronous_wait_self_test
    asynchronous_wait_self_test(wait_path)
    unwrap_source = '''
// value!
let example = "value!"
let unwrapped = value!
let subscriptValue = entries[index]!
let tupleValue = pair.0!; let forcedTry = try! operation(); let forcedCast = value as! String
let interpolated = "\\(entry!)"
let comparison = left != right
struct Handler { var value: String!; func read() -> String { value }; func catches() { do {} catch _ {}; do {} catch let error {}; do {} catch is Error {}; do {} catch { _ = error }; do {} catch let failure { let _ = failure }; do {} catch { handle(error) }; do {} catch { _ = record(error) } } }
'''
    unwrap_facts = swift_syntax_index_sources({"Unwrap.swift": unwrap_source})["Unwrap.swift"]
    write_path = ROOT / "Modules/CommunityPersistence/Sources/Example.swift"
    write_source = 'func update(files: AppFileService) { try? files.removeItem(at: url); _ = try? files.writeData(data, to: url); let result = try? files.createDirectory(at: url); let data = try? files.readData(at: url) }'
    write_facts = swift_syntax_index_sources({str(write_path): write_source})[str(write_path)]
    if len(discarded_file_write_findings(write_path, write_source, write_facts)) != 3:
        findings.append("代码质量自测：文件副作用的丢弃结果需要错误处理，已消费结果沿调用方处理")
    writes = {
        'try? data.write(to: url, options: .atomic)': True, 'let outcome = try? files.writeData(data, to: url); _ = outcome': True, 'let outcome = try? files.writeData(data, to: url); consume(outcome)': False, 'let outcome = try? files.writeData(data, to: url); consume { outcome }': False,
        'let _ = try? files.removeItem(at: url)': True, 'let _: Void? = try? files.writeData(data, to: url)': True, '_ = (try? files.removeItem(at: url))': True, '(try? files.removeItem(at: url))': True, 'let _ = (try? files.removeItem(at: url))': True,
        'try? handle.write(contentsOf: data)': True,
        'try? text.write(to: url, atomically: true, encoding: .utf8)': True,
        'try? urls.forEach { try files.removeItem(at: $0) }': True,
        'try? files.replaceItemAt(url, withItemAt: other)': True,
        'try? files.setPrivateFileProtection(at: url)': True,
        'try? files.setBackupExcluded(true, at: url)': True,
        'try? files.setModificationDate(Date(), at: url)': True,
        'try? MemoryCollection().setPrivateFileProtection(at: url)': False,
        'try? client.write(value)': False, 'let cleanup = files.removeItem(at:); try? cleanup(url)': True, 'let cleanup = { try files.removeItem(at: url) }; try? cleanup()': True, 'let cleanup = { try files.removeItem(at: url) }; let untouched = 1': False,
        'try? MemoryCollection().removeItem(at: 0)': False,
        'try? MemoryCollection().writeData(data, to: url)': False,
        'try? MemoryCollection().createDirectory(at: url)': False,
        'try? MemoryCollection().moveItem(at: url, to: other)': False,
        'try? MemoryCollection().copyItem(at: url, to: other)': False,
        'try? MemoryCollection().replaceItemAt(url, withItemAt: other)': False,
        'try? FileManager.default.removeItem(at: url)': True,
        'let store = files; let local = store; try? local.removeItem(at: url)': True,
        'let store = MemoryCollection(); let local = store; try? local.removeItem(at: 0)': False,
    }
    write_sources = {statement: 'struct MemoryCollection { func removeItem(at index: Int) throws {} }; func update(files: any AppFileService, data: Data, handle: FileHandle, text: String) { ' + statement + ' }' for statement in writes}
    write_index = swift_syntax_index_sources(write_sources)
    for statement, expected in writes.items():
        if bool(discarded_file_write_findings(write_path, write_sources[statement], write_index[statement])) != expected:
            findings.append("代码质量自测：Foundation 文件写入与闭包内清理沿丢弃错误门禁处理")
    if discarded_file_write_findings(ROOT / "Modules/MediaKit/Sources/RemoteImageCache.swift", write_source, write_facts):
        findings.append("代码质量自测：图片缓存沿已有可选写盘合同处理")
    for directory in ("ModuleTests/Support", "BIT101-iOSTests", "BIT101-iOSUITests"):
        if len(discarded_file_write_findings(ROOT / directory / "Fixture.swift", write_source, write_facts)) != 3: findings.append("代码质量自测：测试夹具的写入和清理需要错误处理")
    wrapper_sources = {str(write_path): '''
        struct Store {
            let files: AppFileService
            func update() { try? save(); try? self.again(); try? save(value: 1); try? handled() }
            func save() throws { try files.writeData(data, to: url) }
            func save(value: Int) throws { try client.fetch(value) }
            func again() throws { try save() }
            func handled() { do { try files.writeData(data, to: url) } catch { log(error) } }
        }
    ''', str(write_path.with_name('Extension.swift')): 'extension Store { func reset() { try? self.again() } }'}
    wrapper_index = swift_syntax_index_sources(wrapper_sources)
    wrapper_writes = file_write_calls(wrapper_index)
    if sum(len(discarded_file_write_findings(Path(path), wrapper_sources[path], facts, wrapper_writes))
           for path, facts in wrapper_index.items()) != 3:
        findings.append("代码质量自测：持久化包装方法沿类型、重载及抛错调用链处理")
    if len(unwrap_facts["forceUnwraps"]) != 7 or len(unwrap_facts["emptyCatchClauses"]) != 5 or not any(path.is_relative_to(ROOT / "BIT101-iOSUITests") for path in swift_files()):
        findings.append("代码质量规则边界自检失败：全部测试目录的解包、强制 try 与类型转换识别")
    view_source = "struct SampleView: View { let request = URLRequest(url: url) }"
    model_source = "struct SampleModel { let request = URLRequest(url: url) }"
    if len(view_request_matches(view_source)) != 1 or view_request_matches(model_source):
        findings.append("代码质量规则边界自检失败：View 请求构造范围识别")
    view_facts = {
        "declarations": [{"name": "SampleView", "inheritedTypes": ["SwiftUI.View"]}],
        "calls": [{"value": "URLRequest", "scope": ["SampleView"]}],
    }
    model_facts = {
        "declarations": [{"name": "SampleModel", "inheritedTypes": ["ObservableObject"]}],
        "calls": [{"value": "URLRequest", "scope": ["SampleModel"]}],
    }
    if not ast_has_view_request(view_facts) or ast_has_view_request(model_facts):
        findings.append("代码质量规则边界自检失败：SwiftSyntax View 请求范围匹配")
    for constructor in ("Foundation.URLRequest(url: url)", "Foundation . URLRequest(url: url)", "URLRequest.init(url: url)", "let request: URLRequest = .init(url: url)", "typealias Request = URLRequest; Request(url: url)", "var request: URLRequest { .init(url: url) }", "typealias Request = Foundation.URLRequest; typealias Alias = Request; var request: Alias { .init(url: url) }", "func consume(_ request: URLRequest) {}; consume(.init(url: url))", "func consume(_ requests: [URLRequest]) {}; consume([.init(url: url)])", "func consume(_ request: URLRequest, enabled: Bool = true) {}; consume(.init(url: url))", "func consume(_ requests: URLRequest...) {}; consume(.init(url: url), .init(url: other))"):
        if not all(ast_has_view_request(swift_syntax_index_sources({"view-request": f"struct SampleView: {kind} {{ func load() {{ {constructor} }} }}"})["view-request"]) for kind in ('View', 'ViewModifier', 'App', 'Scene')):
            findings.append("View 请求构造自测：限定类型、显式及推断构造")

    if not uses_application_support_storage({"value": "AppFileDirectories.accountSupportFileURL"}) or uses_application_support_storage(
        {"value": "FileManager.default.urls(for: .applicationSupportDirectory)"}
    ):
        findings.append("代码质量规则边界自检失败：持久化仓库的统一存储入口识别")

    relocated_facts = {
        "declarations": [{"kind": "struct", "name": "ExampleView", "scope": []}],
        "calls": [{"value": "restoreCache", "scope": ["ExampleView"]}],
        "members": [],
        "scopedIdentifiers": [],
        "stringSegments": [],
    }
    relocated_index = {"Moved/ExampleView.swift": relocated_facts}
    if not owner_has_call(relocated_index, "ExampleView", "restoreCache"):
        findings.append("代码质量规则边界自检失败：类型迁移后仍按声明作用域匹配契约")
    if owner_has_call(relocated_index, "MissingView", "restoreCache"):
        findings.append("代码质量规则边界自检失败：缺少契约类型应保持失败")
    module_path = ROOT / "Modules/GalleryFeature/Sources/ExampleView.swift"
    for source, marker in (
        ('struct ExampleView: View { func load() { print("value") } }', "Logger"),
        ('struct ExampleView: View { let formatter = DateFormatter() }', "AppDateText"),
        (r'let text = "\(print("value"))"', "Logger"),
    ):
        if not any(marker in finding for finding in client_source_findings(module_path, source)):
            findings.append("代码质量规则边界自检失败：模块与插值中的客户端规则")
    for source, expected in (("item.loadTransferable(type: Data.self)", True),
                             ("item.loadTransferable(type: Foundation.Data.self)", True),
                             ("item.loadBoundedImageData()", False),
                             ('let label = "item.loadTransferable(type: Data.self)"', False)):
        if any("照片原始数据" in value for value in client_source_findings(module_path, source)) != expected:
            findings.append("照片读取容量门禁自检")
    if client_source_findings(module_path, '// print("value")\nlet example = "DateFormatter()"'):
        findings.append("代码质量规则边界自检失败：模块文案进入执行代码规则")
    for constructor in ("DateFormatter.init()", "typealias Formatter = DateFormatter; Formatter()",
                        "typealias Formatter = Foundation.ISO8601DateFormatter; Formatter.init()",
                        "let formatter: RelativeDateTimeFormatter = .init()"):
        source = f"struct ExampleView: View {{ func render() {{ {constructor} }} }}"
        if not any("AppDateText" in value for value in client_source_findings(module_path, source)):
            findings.append("社区日期构造自测：别名、显式与推断构造")
    source = "struct DateFormatter {}; struct ExampleView: View { let formatter = DateFormatter() }"
    if client_source_findings(module_path, source):
        findings.append("社区日期构造自测：同名业务类型归属")
    for source, expected in (("import TransportCore\nimport MediaKit\nimport TransportCore\n", 1),
                             ("#if os(iOS)\nimport UIKit\n#else\nimport UIKit\n#endif\n", 0),
                             ('let example = "import UIKit"\n// import UIKit\nimport UIKit\n', 0)):
        with patch("code_quality_rules.swift_files", return_value=[module_path]), patch.object(Path, "read_text", return_value=source):
            if sum("重复 import" in value for value in source_findings()[0]) != expected:
                findings.append("代码质量规则边界自检失败：分支内重复导入与注释、字符串隔离")
    findings.extend(smoke_script_boundary_findings())
    workflow_source = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    findings.extend(ci_trigger_shell_self_test(workflow_source) + cross_file_view_request_self_test())
    from ci_wiring_rules import ci_wiring_findings
    upload = re.search(r"actions/upload-artifact@[0-9a-f]{40}", workflow_source)[0]
    renamed_steps = re.sub(r'(?m)^(\s+- name:).*$', r'\1 Descriptive workflow label', workflow_source)
    assert not ci_wiring_findings(renamed_steps)
    spaced = workflow_source.replace('run: python3 Scripts/ci_evidence.py reuse ', 'run: python3  "Scripts/ci_evidence.py"   reuse ')
    assert not ci_wiring_findings(spaced)
    assert not ci_wiring_findings(workflow_source.replace(upload, "actions/upload-artifact@" + "a" * 40))
    for reference in ("v8", "main"):
        assert ci_wiring_findings(workflow_source.replace(upload, "actions/upload-artifact@" + reference))
    assert ci_wiring_findings(workflow_source.replace("compression-level: 0", "compression-level: 6"))
    assert ci_wiring_findings(workflow_source.replace("    tags: ['v*']\n", ""))
    assert ci_wiring_findings(workflow_source.replace("run: python3 Scripts/ci_evidence.py check-release", "run: echo skipped"))
    assert ci_wiring_findings(workflow_source.replace("run: python3 Scripts/ci_evidence.py export-core", "run: true"))
    assert ci_wiring_findings(workflow_source.replace("verify modules all release-runtime ui", "verify modules all ui"))
    for event in ("pull_request", "push"):
        for filtering in ("paths", "paths-ignore"):
            assert ci_wiring_findings(workflow_source.replace(event + ":\n", event + f":\n    {filtering}: ['docs/**']\n", 1))
    extension_graph = {"objects": {
        "app": {"isa": "PBXNativeTarget", "name": "BIT101-iOS", "dependencies": ["widget-edge", "watch-edge"]},
        "widget": {"isa": "PBXNativeTarget", "name": "BIT101ScheduleWidgets"},
        "watch": {"isa": "PBXNativeTarget", "name": "BIT101Watch", "dependencies": ["watch-widget-edge"]},
        "watch-widget": {"isa": "PBXNativeTarget", "name": "BIT101WatchWidgets"},
        "widget-edge": {"target": "widget", "platformFilter": "ios"},
        "watch-edge": {"target": "watch", "platformFilter": "ios"},
        "watch-widget-edge": {"target": "watch-widget"},
    }}
    if extension_dependency_findings(extension_graph):
        findings.append("代码质量规则边界自检失败：父 target 的扩展编译覆盖识别")
    extension_graph["objects"]["watch-edge"].pop("platformFilter")
    if not extension_dependency_findings(extension_graph):
        findings.append("代码质量规则边界自检失败：Mac Catalyst 的扩展平台隔离")
    extension_graph["objects"]["watch-edge"]["platformFilter"] = "ios"
    extension_graph["objects"]["watch"]["dependencies"] = []
    if not extension_dependency_findings(extension_graph):
        findings.append("代码质量规则边界自检失败：扩展依赖断开应触发门禁")
    from code_quality_rules import native_project_targets
    native_graph = {"rootObject": "project", "objects": {
        "project": {"mainGroup": "root"}, "root": {"children": ["group"], "sourceTree": "<group>"},
        "group": {"path": "Shared", "children": ["source"], "sourceTree": "<group>"},
        "source": {"path": "Shared.swift"}, "build": {"fileRef": "source"},
        "phase": {"isa": "PBXSourcesBuildPhase", "files": ["build"]}, "product": {"productName": "StorageCore"},
        "new": {"isa": "PBXNativeTarget", "name": "FutureUITests", "buildPhases": ["phase"], "packageProductDependencies": ["product"]},
    }}
    if native_project_targets(native_graph, ROOT) != [("FutureUITests", {"StorageCore"}, {ROOT / "Shared/Shared.swift"})]:
        findings.append("工程依赖自检失败：新增 target 和跨目录编译源文件需要按工程归属审计")
    return findings


def command_logging_boundary_findings() -> list[str]:
    """通过内存命令输出验证阈值、完整留档及进程状态。"""
    from types import SimpleNamespace

    from command_output import OUTPUT_LINE_LIMIT, run_command
    from script_output_tests import captured_command
    findings: list[str] = []
    for status, count, ci in ((0, 10, False), (7, OUTPUT_LINE_LIMIT, False), (7, OUTPUT_LINE_LIMIT + 1, False),
                              (-15, 1, False), (0, OUTPUT_LINE_LIMIT + 1, True), (7, OUTPUT_LINE_LIMIT + 1, True)):
        lines = [f"error: diagnostic {index}\n" for index in range(count)]
        output, log = captured_command(lines, status=status, ci=ci)
        if log != "".join(lines):
            findings.append("日志自测：完整输出留档")
        if ("[输出]" in output) != (count > OUTPUT_LINE_LIMIT):
            findings.append("日志自测：统一展示阈值与完整日志路径")
        expected_lines = min(count, OUTPUT_LINE_LIMIT)
        if sum(line.startswith("error:") for line in output.splitlines()) != expected_lines:
            findings.append("日志自测：首尾错误与共享输出预算")
    for ci in (True, False):
        visible, log = StringIO(), StringIO()
        case = "Test Case '-[UITests testAction]' passed (1.234 seconds).\n"
        def native_output():
            yield "    t = 0.10s Press button\n"
            yield case
            assert ("[用例]" in visible.getvalue()) == ci
        process = SimpleNamespace(stdout=native_output(), wait=lambda: 0)
        with patch.object(sys, 'argv', ['logger', '/audit/ui.log', '模拟器测试', 'xcodebuild']), \
                patch.object(subprocess, 'Popen', return_value=process), patch.object(Path, 'mkdir'), \
                patch.object(Path, 'open', lambda *args, **kwargs: nullcontext(log)), \
                patch.dict(os.environ, GITHUB_ACTIONS='true' if ci else 'false'), redirect_stdout(visible):
            assert run_command(sys.argv[1:]) == 0
        if log.getvalue() != "    t = 0.10s Press button\n" + case:
            findings.append('日志自测：原生用例进度即时展示，完整操作记录沿固定日志保留')
    return findings


def script_output_boundary_findings() -> list[str]:
    findings = command_logging_boundary_findings()
    script = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    from test_results import report_result_summary, record_native_metrics
    for failures in ([], [{'testIdentifierString': 'Suite/test', 'failureText': 'assertion'}]):
        visible = StringIO()
        sample = dict(result='Failed' if failures else 'Passed', passedTests=2 if failures else 3,
            totalTestCount=3, testFailures=failures)
        with patch.object(sys, 'argv', ['report', '/result']), \
                patch.object(subprocess, 'check_output', return_value=json.dumps(sample)) as read, redirect_stdout(visible):
            report_result_summary('/result')
        expected = ['结果来源：/result', f"{sample['result']} · {sample['passedTests']}/3 通过"]
        if failures: expected.append('Suite/test: assertion')
        if visible.getvalue().splitlines() != expected or read.call_count != 1:
            findings.append('报告默认输出摘要与失败项，完整用例树沿 report json 读取。')
    with patch.object(sys, "argv", ["metrics", "/result", "/report", "ui", "1", "device", "/audit"]), \
            patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 64, "", "incomplete result")):
        try:
            record_native_metrics(sys.argv[1:])
        except SystemExit as error:
            if "XCTest 结果包" not in str(error): findings.append("测试指标自测：启动中断摘要")
        else:
            findings.append("测试指标自测：中断阶段保持失败状态")
    validation = re.search(r"(?ms)^finish_validation\(\) \{\n.*?^\}$", script)
    for test_status, evidence_status in ((0, 0), (23, 0), (0, 7)):
        frame = 'ROOT_DIR=/audit\nBUILD_ONLY=true\nvalidation_group=ui\nvalidation_scope=full\n'
        frame += f'python3() {{ print -r -- "$3 $4 $5"; return {evidence_status}; }}\n'
        frame += validation[0] + f'\ntrap finish_validation EXIT\nexit {test_status}\n'
        result = subprocess.run(["zsh", "-c", frame], capture_output=True, text=True)
        if result.returncode != (evidence_status or test_status) or result.stdout.strip() != f"ui {test_status} full":
            findings.append("验证证据自测：成功、失败与证据写入错误的退出状态")
    header = script.split("set -euo pipefail", 1)[0]
    fixture = ROOT / ".build/static-audit/script-snapshot.sh"
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text(header + 'print -r -- "print replacement" > "$0"\n' + "# padding\n" * 2000 + "print snapshot-survived\n")
    try:
        result = subprocess.run(["zsh", str(fixture)], capture_output=True, text=True)
        if result.returncode or result.stdout.strip() != "snapshot-survived":
            findings.append("脚本快照自测：执行期间改写源码影响既有流程")
    finally:
        fixture.unlink(missing_ok=True)
    for check in (build_cache_boundary_findings, catalyst_signing_boundary_findings, script_command_boundary_findings, workflow_lock_boundary_findings,
                  audit_lock_boundary_findings, restore_installation_boundary_findings, worker_boundary_findings, report_inbox_boundary_findings, explanatory_text_boundary_findings, school_lifecycle_boundary_findings):
        findings.extend(check())
    support = (SCRIPT_ROOT / "script-support.sh").read_text()
    routing = subprocess.run(["zsh", "-c", support + r'''
bit101_build_cache() { print cached; }
bit101_log_command() { print direct; }
bit101_run_logged /log test xcodebuild test-without-building
bit101_run_logged /log build xcodebuild build-for-testing
'''], capture_output=True, text=True)
    if routing.returncode or routing.stdout.splitlines() != ["direct", "cached"]:
        findings.append("脚本自测：测试执行与编译缓存锁的生命周期")
    audit = (SCRIPT_ROOT / "run-static-audit.sh").read_text()
    tail = audit[audit.index("failed_groups=()"):]
    from script_test_support import shell_function
    wait_groups = shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_wait_audit_groups')
    selection = audit[audit.index('set -euo pipefail'):audit.index('\nROOT_DIR=')]
    harness = selection + r'''
set -euo pipefail
LOG_DIR=/audit
ROOT_DIR=/audit
AUDIT_STARTED=$SECONDS
python3() { return 0; }
bit101_run_audit_group() {
    print -r -- "RAN $1"
    case "$1" in shell-parse|docs) return 7;; esac
    return 0
}
bit101_start_audit_group() { bit101_run_audit_group "$1" "$2" & group_processes+=($!); }
'''
    fixture = ROOT / '.build/static-audit/workflow-lock-self-test'
    fixture.mkdir(parents=True, exist_ok=True)
    harness = harness.replace('LOG_DIR=/audit', 'LOG_DIR=' + shlex.quote(str(fixture)))
    try:
        for prepared in (0, 1):
            aggregation = subprocess.run(["zsh", "-c", harness + wait_groups + f'\nBIT101_AUDIT_ARTIFACTS_PREPARED={prepared}\n' + tail], capture_output=True, text=True)
            groups = re.findall(r"^RAN (.+)$", aggregation.stdout, re.MULTILINE)
            if aggregation.returncode != 1 or len(set(groups)) != 10 - prepared \
                    or ('artifact-hygiene' in groups) != (prepared == 0) \
                    or set(aggregation.stderr.removeprefix('[失败汇总] ').strip().split(', ')) != {'shell-parse', 'docs'}:
                findings.append("静态审计自测：产物准备、并行分组执行完整性与多个失败汇总")
    finally:
        shutil.rmtree(fixture)
    return findings


def catalyst_signing_boundary_findings() -> list[str]:
    """覆盖本机默认签名、显式免签名和托管 CI 策略。"""
    from script_test_support import shell_function
    signing = shell_function(SCRIPT_ROOT / 'script-support.sh', 'bit101_catalyst_signing_arguments')
    harness = 'set -euo pipefail\nGITHUB_ACTIONS="$2" BIT101_CATALYST_UNSIGNED_TESTS="$3"\n' + signing
    findings = []
    for mode in ('catalyst', 'catalyst-release-runtime'):
        for ci in ('', 'false', 'true'):
            for unsigned in ('', '0', '1'):
                result = subprocess.run(['zsh', '-c', harness + '\nbit101_catalyst_signing_arguments',
                    'catalyst-signing', mode, ci, unsigned], capture_output=True, text=True)
                expected = ['CODE_SIGNING_ALLOWED=NO'] if ci == 'true' or unsigned == '1' else ['-allowProvisioningUpdates']
                if result.returncode or result.stdout.splitlines() != expected:
                    findings.append(f'Catalyst 签名自测：{mode} 在 {ci or "local"}、免签名 {unsigned or "默认"} 时沿所属策略执行')
    return findings


def build_cache_boundary_findings() -> list[str]:
    "验证缓存合并、热文件保留、链接复用和清理边界。"

    from compiler_cache import run_cache
    fixture = ROOT / ".build/static-audit/cache-self-test"
    findings: list[str] = []
    try:
        from validation_artifacts import SELF_TEST_ARTIFACTS, recover_self_test_artifacts
        audit_folder = fixture / '.build/static-audit'
        audit_folder.mkdir(parents=True, exist_ok=True)
        for name in SELF_TEST_ARTIFACTS:
            path = audit_folder / name
            if path.suffix in {'.swift', '.sh'}: path.write_text('interrupted self-test')
            else: path.mkdir()
        retained = audit_folder / 'unregistered.log'
        retained.write_text('audit keeps unregistered evidence visible')
        recover_self_test_artifacts(fixture)
        assert list(audit_folder.iterdir()) == [retained]
        shared = fixture / ".build/compiler-cache/ModuleCache.noindex"
        old = fixture / ".build/extended-automation/ModuleCache.noindex"
        shared.mkdir(parents=True, exist_ok=True)
        old.mkdir(parents=True, exist_ok=True)
        (shared / "warm").write_text("retain warm module")
        (old / "warm").write_text("old module")
        os.utime(old / "warm", ns=(1, 1))
        (old / "unique").write_text("preserve unique module")
        module = old / "module.pcm"
        content = b"compiled module fixture\n" * 4096
        module.write_bytes(content)
        cas = fixture / ".build/extended-automation/CompilationCache.noindex"
        retained_cas = fixture / ".build/compiler-cache/CompilationCache.noindex"
        cas.mkdir(); retained_cas.mkdir()
        for name in ("index", "data"): (cas / name).write_bytes(content)
        os.utime(cas / "index", ns=(1, 1))
        (retained_cas / "index").write_text("distinct namespace")
        stats = fixture / ".build/extended-automation/SDKStatCaches.noindex"
        stats.mkdir()
        for name in ("iphoneos.sdkstatcache", "iphonesimulator.sdkstatcache"): (stats / name).write_text(name)
        modified = module.stat().st_mtime_ns
        contexts = {
            "simulator": "arm64-apple-ios27.0-simulator",
            "watch-simulator": "arm64-apple-watchos27.0-simulator",
            "phone": "arm64-apple-ios27.0",
            "mac": "arm64-apple-ios27.0-macabi",
            "unreadable": None,
        }
        for name in contexts:
            (shared / name).mkdir()
            (shared / name / f"{name}.pcm").write_bytes(content)
        command_run = subprocess.run
        builds = []

        def inspect_module(command, **options):
            if command[:2] == ["zsh", "-c"]:
                builds.append(command)
                return subprocess.CompletedProcess(command, 0)
            if command[:3] == ["xcrun", "clang", "-module-file-info"]:
                triple = contexts.get(Path(command[3]).stem)
                return subprocess.CompletedProcess(command, 0 if triple else 1,
                                                   f"Target options:\n  Triple: {triple}\n" if triple else "", "")
            return command_run(command, **options)

        obsolete_paths = [fixture / ".build/ui-authorization.logarchive", fixture / ".build/static-audit/package-build"]
        for path in obsolete_paths: path.mkdir(parents=True)
        obsolete_cloud_log = fixture / ".build/icloud-cross-device-smoke/testPhoneUpload.log"
        obsolete_cloud_log.parent.mkdir(); obsolete_cloud_log.write_text("obsolete stage")
        diagnostics = fixture / ".build/extended-automation/diagnostics"
        diagnostics.mkdir()
        diagnostic_result = diagnostics / 'test-results.xcresult'
        diagnostic_result.mkdir()
        (diagnostic_result / 'Info.plist').write_text('retain failure diagnostics')
        diagnostic_export = diagnostics / 'exported.log'
        diagnostic_export.write_text('temporary export')
        products = fixture / ".build/extended-automation/Build/Products"
        for platform in ("Release-iphoneos", "Release-iphonesimulator"):
            (products / platform).mkdir(parents=True)
            (products / platform / "product").write_text(platform)
        symbols = products / "Release-iphoneos/product.dSYM"
        symbols.mkdir()
        (symbols / "debug-info").write_bytes(content)
        bundled_symbols = products / "Release-iphoneos/Runner.app/PlugIns/tests.xctest.dSYM/debug-info"
        bundled_symbols.parent.mkdir(parents=True)
        bundled_symbols.write_bytes(content)
        result = fixture / ".build/extended-automation/test-results.xcresult"
        result.mkdir()
        (result / "evidence").write_text("retain result")
        cloud_result = fixture / '.build/icloud-cross-device-smoke/Mac/Logs/Test/test-results.xcresult'
        cloud_result.mkdir(parents=True); (cloud_result / 'evidence').write_text('retain recovery diagnostics')
        sdk = fixture / ".build/extended-automation/SDKExplicitPrecompiledModules"
        sdk.mkdir()
        (sdk / "referenced.pcm").write_bytes(content)
        (sdk / "unused.pcm").write_bytes(content)
        dependencies = products.parent / "Intermediates.noindex/fixture-dependencies.json"
        dependencies.parent.mkdir()
        debug_object = dependencies.parent / "debug.o"
        debug_object.write_bytes(content)
        dependencies.write_text(json.dumps([{"clangModulePath": str(sdk / "referenced.pcm")}]))
        for _ in range(2):
            with patch.object(sys, "argv", ["cache", str(fixture), "--maintenance"]), \
                    patch.object(subprocess, "run", inspect_module), redirect_stdout(StringIO()):
                run_cache(sys.argv[1:])
        if not old.is_symlink() or old.resolve() != shared.resolve():
            findings.append("缓存自测：同类缓存目录共享")
        if not cas.is_symlink() or any((cas / name).read_bytes() != content for name in ("index", "data")):
            findings.append("缓存自测：CAS 命名空间整体保留及共享")
        if not all((stats / name).exists() for name in ('iphonesimulator.sdkstatcache', 'iphoneos.sdkstatcache')):
            findings.append("缓存自测：SDK 统计缓存的平台归属")
        if (old / "warm").read_text() != "retain warm module" or (old / "unique").read_text() != "preserve unique module":
            findings.append("缓存自测：保留热模块及唯一模块")
        if module.read_bytes() != content or module.stat().st_mtime_ns != modified:
            findings.append("缓存自测：合并保留内容和修改时间")
        if not all((shared / name).exists() for name in ("simulator", "watch-simulator")):
            findings.append("缓存自测：保留模拟器平台的隐式模块")
        if any((shared / name / f"{name}.pcm").read_bytes() != content for name in ("phone", "mac", "unreadable")):
            findings.append("缓存自测：保留真机、Mac 及平台归属待核对的模块")
        if any(path.exists() for path in obsolete_paths) or obsolete_cloud_log.exists() or diagnostic_export.exists() or symbols.exists():
            findings.append("缓存自测：清理诊断与冗余符号产物")
        assert (diagnostic_result / 'Info.plist').read_text() == 'retain failure diagnostics'
        if not (products / "Release-iphonesimulator").exists():
            findings.append("缓存自测：保留模拟器增量产物")
        if debug_object.read_bytes() != content:
            findings.append("缓存自测：保留目标文件中的调试信息")
        if bundled_symbols.read_bytes() != content:
            findings.append("缓存自测：保留运行包内部的调试资源")
        if not (products / "Release-iphoneos/product").is_file() or not (result / "evidence").is_file():
            findings.append("缓存自测：保留增量构建及测试证据")
        if not (cloud_result / 'evidence').is_file(): findings.append('缓存自测：保留云同步失败的固定结果包')
        if not (sdk / "referenced.pcm").is_file() or (sdk / "unused.pcm").exists():
            findings.append("缓存自测：依赖清单引用模块保留")
        (sdk / "incomplete-map.pcm").write_bytes(content)
        dependencies.write_text("{")
        with patch.object(sys, "argv", ["cache", str(fixture), "--maintenance"]), \
                patch.object(subprocess, "run", inspect_module), redirect_stdout(StringIO()):
            run_cache(sys.argv[1:])
        if not (sdk / "incomplete-map.pcm").is_file():
            findings.append("缓存自测：依赖清单受损时保留缓存")
        for action, settings, expected in (
            ("build", [], []),
            ("test", ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"], ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"]),
            ("archive", [], []),
            ("build-for-testing", ["SWIFT_COMPILATION_MODE=wholemodule", "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=NO"], []),
            ("swift-build", [], None), ("swift-test", [], None),
        ):
            command = ["xcrun", "swift", action.removeprefix("swift-")] if expected is None else ["xcodebuild", action]
            arguments = ["cache", str(fixture), "build.log", "build", *command, *settings]
            with patch.object(sys, "argv", arguments), patch.object(subprocess, "run", inspect_module):
                try:
                    run_cache(sys.argv[1:])
                except SystemExit as result:
                    if result.code != 0:
                        raise
            assert builds[-1][3:5] == ['cache-build', str(fixture)]
            if expected is None:
                if not all(flag in builds[-1] for flag in ("-Xswiftc", "-warnings-as-errors", "-Xcc", "-Werror")):
                    findings.append("编译入口自测：SwiftPM 构建与测试的警告门禁")
                continue
            if [value for value in builds[-1] if value.startswith("DEBUG_INFORMATION_FORMAT=")] != expected:
                findings.append("缓存自测：开发 DWARF、显式符号设置和发行归档边界")
            expected_mode = [value for value in settings if value.startswith("SWIFT_COMPILATION_MODE=")]
            if [value for value in builds[-1] if value.startswith("SWIFT_COMPILATION_MODE=")] != expected_mode:
                findings.append("缓存自测：构建、测试与归档沿工程配置及显式编译模式")
            defaults = ("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "GCC_TREAT_WARNINGS_AS_ERRORS=YES", "COMPILATION_CACHE_ENABLE_CACHING=YES",
                "SWIFT_ENABLE_PREFIX_MAPPING=YES", "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES", "CLANG_ENABLE_PREFIX_MAPPING=YES", "CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES")
            if any([value for value in builds[-1] if value.startswith(setting.split('=')[0] + '=')] !=
                    ([value for value in settings if value.startswith(setting.split('=')[0] + '=')] or [setting]) for setting in defaults):
                findings.append("编译入口自测：构建、测试与正式归档的警告门禁及缓存路径映射")
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def smoke_script_boundary_findings() -> list[str]:
    "通过故障注入验证清理顺序、状态传播和测试现场保留。"

    source = (SCRIPT_ROOT / "run_icloud_cross_device_smoke.sh").read_text()
    findings: list[str] = []
    network = (SCRIPT_ROOT / 'release-network-smoke.sh').read_text()
    wait_loop = network.split('REPORT_READY=false\n', 1)[1].split('\nif ! $REPORT_READY', 1)[0]
    for marker in ('NETWORK_SMOKE_REPORT_WRITE_FAIL run_id=fixture', 'NETWORK_SMOKE_REQUEST_FAIL'):
        stub = 'set -euo pipefail\nRUN_ID=fixture\nCONSOLE_LOG=/fixture-console\nconsole_process=1\nREPORT_READY=false\nDEADLINE=$(( SECONDS + 5 ))\n'
        stub += 'rg() { [[ "$2" == "' + marker + '" ]]; }\nkill() { return 0; }\nxcrun() { return 9; }\nsleep() { return 9; }\n'
        failed = subprocess.run(['zsh', '-c', stub + wait_loop], capture_output=True, text=True, timeout=5)
        assert failed.returncode == 1 and '失败' in failed.stderr, failed.stderr
    stub = 'set -euo pipefail\nRUN_ID=fixture\nCONSOLE_LOG=/fixture-console\nconsole_process=1\nREPORT_READY=false\nDEADLINE=$(( SECONDS + 5 ))\n'
    stub += 'phase=waiting\nrg() { [[ "$2" == "NETWORK_SMOKE_SUMMARY run_id=fixture " && "$phase" == ready ]]; }\n'
    stub += 'DEVICETCL_DEVICE_ID=fixture\nAPP_GROUP_ID=fixture\nREMOTE_REPORT_PATH=fixture\nLOCAL_REPORT_PATH=/fixture\n'
    stub += 'kill() { [[ "$phase" == waiting ]]; }\nxcrun() { [[ "$phase" == ready ]] || exit 8; exit 17; }\nsleep() { phase=ready; }\n'
    ready = subprocess.run(['zsh', '-c', stub + wait_loop], capture_output=True, text=True, timeout=5)
    assert ready.returncode == 17, ready
    stopped = subprocess.run(['zsh', '-c', stub.replace('phase=waiting', 'phase=stopped') + wait_loop],
        capture_output=True, text=True, timeout=5)
    assert stopped.returncode == 1 and '控制台进程已结束' in stopped.stderr, stopped
    def shell_function(name: str, script_source: str = source) -> str:
        match = re.search(rf"(?ms)^([ \t]*){name}\(\) \{{\n.*?^\1\}}$", script_source)
        if match is None:
            raise RuntimeError(f"Smoke 自测需要 {name} 函数")
        return match[0]
    phone_function = shell_function("run_phone_test", (SCRIPT_ROOT / "icloud-smoke-support.sh").read_text())
    stub = r'''
set -euo pipefail
DERIVED_ROOT=/smoke
RESULT_BUNDLE=/smoke/test-results.xcresult
DEVICE_ID=device
TEST_CLASS=smoke
common_args=()
rm() { print -r -- "DELETE $*"; }
bit101_run_logged() { print -r -- "RUN $*"; }
record_result() { print -r -- "RECORD $*"; }
bit101_invalidate_restore() { :; }
'''
    cleanup = subprocess.run(["zsh", "-c", stub + phone_function + "\nrun_phone_test testCleanup"], capture_output=True, text=True)
    if cleanup.returncode or "DELETE -rf /smoke/test-results.xcresult" in cleanup.stdout or "-resultBundlePath" in cleanup.stdout:
        findings.append("Smoke 恢复自测失败：清理覆盖业务阶段结果包")
    business = subprocess.run(["zsh", "-c", stub + phone_function + "\nrun_phone_test testPhoneRoundTrip"], capture_output=True, text=True)
    if business.returncode or "-resultBundlePath" not in business.stdout:
        findings.append("Smoke 恢复自测失败：业务阶段结果包保存")
    worker = re.search(r"<<'PYWORKER'\n(.*?)^PYWORKER$", source, re.MULTILINE | re.DOTALL)
    handlers = {}
    child = type("Worker", (), {"pid": 42, "wait": lambda self, timeout=None:
        -signal.SIGTERM if timeout is not None else (handlers[signal.SIGTERM](signal.SIGTERM, None), -signal.SIGTERM)[1]})()
    with patch.object(sys, "argv", ["worker", "/root", "/derived", "/bundle", "/report", "device", "suite"]), \
         patch.object(subprocess, "Popen", return_value=child) as launch, \
         patch.object(signal, "signal", side_effect=lambda signum, handler: handlers.update({signum: handler})), \
         patch.object(os, "killpg") as cancel:
        try:
            exec(compile(worker[1], "phone-worker-self-test", "exec"), {})
        except SystemExit as result:
            if result.code != 143:
                findings.append("Smoke 并行自测：手机宿主信号退出状态")
        if launch.call_args.kwargs.get("start_new_session") is not True or cancel.call_args.args != (42, signal.SIGTERM):
            findings.append("Smoke 并行自测：中断时终止手机测试进程组")
    import shlex
    import time
    injected = 'import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print(os.getpid(), flush=True); time.sleep(60)'
    command = 'exec ' + shlex.quote(sys.executable) + ' -B -c ' + shlex.quote(injected)
    harness = re.sub(r"(?s)worker = r'''(.*?)'''", lambda match: 'worker = ' + repr(command), worker[1], count=1)
    supervisor = subprocess.Popen([sys.executable, '-B', '-c', harness, '/root', '/derived', '/bundle', '/report', 'device', 'suite'],
        env=dict(os.environ, BIT101_WORKFLOW_DEADLINE=str(time.monotonic() + 0.2)),
        start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    detached_pid = None
    try:
        detached_pid = int(supervisor.stdout.readline())
        os.killpg(supervisor.pid, signal.SIGTERM)
        _, error = supervisor.communicate(timeout=5)
        try: os.kill(detached_pid, 0)
        except ProcessLookupError: terminated = True
        else: terminated = False
        if supervisor.returncode != 143 or not terminated:
            findings.append('Smoke 并行自测：忽略终止信号的独立手机进程组需要在期限内结束')
    except subprocess.TimeoutExpired:
        findings.append('Smoke 并行自测：独立手机进程组需要按工作流期限强制终止')
    finally:
        if supervisor.poll() is None:
            os.killpg(supervisor.pid, signal.SIGKILL)
        if detached_pid is not None:
            try: os.kill(detached_pid, 0)
            except ProcessLookupError: pass
            else: os.killpg(detached_pid, signal.SIGKILL)
        supervisor.wait(timeout=5)
    finish = shell_function("finish_smoke")
    trap_registration = "\n".join(re.findall(r"(?m)^trap .+$", source))
    cases = ((7, 0, 7), (7, 1, 7), (0, 1, 1), (0, 0, 0), (130, 0, 130), (143, 0, 143))
    for initial, cleanup_status, expected in cases:
        triggers = [f"exit {initial}", f"fail_command() {{ return {initial}; }}; fail_command"]
        if initial in (130, 143): triggers.append(f"kill -s {'INT' if initial == 130 else 'TERM'} $$")
        for trigger in triggers:
            harness = f'''
set -euo pipefail
PHONE_TESTS_STARTED=true PHONE_CLEANED_UP=false PHONE_TEST_PID=""
MAC_TESTS_STARTED=false MAC_CLEANED_UP=false CLEANUP_ONLY=false
SUMMARY_PATH=/smoke/report.json validation_group=icloud ROOT_DIR=/audit
run_phone_test() {{ print cleanup; return {cleanup_status}; }}
report_result() {{ print report; }}
python3() {{ if [[ "$1" == - ]]; then cat >/dev/null; fi; }}
{finish}
{trap_registration}
{trigger}
'''
            result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
            if result.returncode != expected or not re.search(r"(?ms)^cleanup$.*^report$", result.stdout):
                findings.append(f"Smoke 清理自测：状态 {initial}/{cleanup_status}；{trigger}")
    network_source = (SCRIPT_ROOT / "release-network-smoke.sh").read_text()
    finish_network = shell_function("finish_smoke", network_source)
    network_traps = "\n".join(line.strip() for line in network_source.splitlines() if line.strip().startswith("trap "))
    cases = ((7, 7, "preflight", False, 0), (0, 0, "preflight", False, 0),
        (0, 0, "sms", False, 0), (7, 7, "sms", False, 0), (1, 1, "sms", True, 0),
        (130, 130, "sms", True, 0), (0, 1, "sms", True, 1))
    for initial, expected, sms, ready, school_record_status in cases:
        harness = f'''
set -euo pipefail
ROOT_DIR=/audit validation_group=network validation_scope=full
community_started=false PREPARE_ONLY=false report_ready={str(ready).lower()}
SMOKE_SCOPE=all SMS_MODE={sms} console_process=""
BIT101_VALIDATION_SOURCE_DIGEST=network-inputs SCHOOL_SMS_STARTED_DIGEST=school-inputs
python3() {{ print -r -- "$BIT101_VALIDATION_SOURCE_DIGEST $*"; if [[ "$*" == *'record school-sms'* ]]; then return {school_record_status}; fi; return 0; }}
{finish_network}
{network_traps}
fail_command() {{ return {initial}; }}
fail_command
'''
        result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
        if result.returncode != expected: findings.append(f"网络 Smoke 退出自测：状态 {initial}")
        school_status = 0 if ready and initial <= 2 else initial
        if sms == "sms" and (f"network-inputs /audit/Scripts/validation_evidence.py record network {initial} full" not in result.stdout
                or f"school-inputs /audit/Scripts/validation_evidence.py record school-sms {school_status} full" not in result.stdout):
            findings.append("全量短信验收退出自测：两个验证范围维持各自结果与开始摘要")
    extended_source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    from script_test_support import shell_function as shared_shell_function
    for name in ("bit101_finish_verification", "finish_validation"):
        finish = shared_shell_function(SCRIPT_ROOT / 'script-support.sh', name) if name == 'bit101_finish_verification' \
            else shell_function(name, extended_source)
        registration = re.search(rf"(?m)^[ \t]*trap {name} [^\n]+(?:\n[ \t]*trap [^\n]+)*", extended_source)
        if registration is None:
            findings.append(f"测试退出自测需要 {name} 错误钩子")
            continue
        for initial in (0, 7, 130, 143):
            triggers = [f"exit {initial}", f"fail_command() {{ return {initial}; }}; fail_command"]
            if initial in (130, 143): triggers.append(f"kill -s {'INT' if initial == 130 else 'TERM'} $$")
            for trigger in triggers:
                harness = f'''
set -euo pipefail
verification_audit_pid= BUILD_ONLY=false WORKFLOW_STARTED_SECONDS=$SECONDS
DERIVED_ROOT=/dev/null ROOT_DIR=/audit validation_group=ui validation_scope=full
retained_result_groups=()
python3() {{ return 0; }}
{finish}
{registration[0]}
{trigger}
'''
                result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
                if result.returncode != initial:
                    findings.append(f"测试退出自测：{name}；状态 {initial}；{trigger}")
    for filename in ('run-extended-tests.sh', 'release-network-smoke.sh', 'run_icloud_cross_device_smoke.sh'):
        shell = (SCRIPT_ROOT / filename).read_text()
        calls = [line.strip() for line in shell.splitlines() if '"$ROOT_DIR/Scripts/build-install-device.sh"' in line]
        expected = ['build-archive) bit101_verify_step build-archive "$ROOT_DIR/Scripts/build-install-device.sh" archive ;;'] if filename == 'run-extended-tests.sh' else []
        if calls != expected: findings.append(f"测试入口保留测试宿主，常规 App 装机沿独立步骤执行：{filename}")
    stage_source = (SCRIPT_ROOT / "icloud-smoke-support.sh").read_text()
    match = re.search(r"(?ms)^record_result\(\).*?<<'PY'\n(.*?)^PY$", stage_source)
    if match is None:
        return [*findings, "Smoke 自测需要阶段结果记录器"]
    state = {}
    def read(path: Path, *args, **kwargs) -> str:
        return state[str(path)]
    def write(path: Path, value: str, *args, **kwargs) -> int:
        state[str(path)] = value
        return len(value)
    summary = {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0,
               "testFailures": [{"failureText": "business failure"}]}
    completed = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
    observed = {}
    def result_response(command, **kwargs):
        if 'merge' in command: return subprocess.CompletedProcess(command, 0, '')
        if 'tests' in command:
            stage = sys.argv[3]
            tree = {'devices': [{'platform': observed.get('platform', 'macOS' if stage.startswith('testMac') else 'iOS'),
                'deviceId': observed.get('deviceId', 'phone')}], 'testNodes': [{'nodeType': 'Unit test bundle',
                'name': observed.get('target', 'BIT101-iOSTests'), 'children': [{'nodeType': 'Test Case',
                    'nodeIdentifier': observed.get('identifier', 'ICloudCrossDeviceSmokeTests/' + stage + '()')}]}]}
            return subprocess.CompletedProcess(command, 0, json.dumps(tree))
        result = summary if sys.argv[3] == "testPhoneRoundTrip" else completed
        return subprocess.CompletedProcess(command, 0, json.dumps(result))
    with patch.dict(os.environ, BIT101_VALIDATION_RUN_ID='fixture', BIT101_XCODE_DEVICE_ID='phone'), \
         patch.object(Path, "is_file", lambda path: str(path) in state), patch.object(Path, "is_dir", return_value=True), \
         patch.object(Path, "glob", side_effect=lambda *args: iter([Path("/smoke/generated.xcresult")])), \
         patch.object(Path, "exists", return_value=False), patch.object(shutil, "rmtree") as remove_bundle, \
         patch.object(shutil, "move") as retain_bundle, \
         patch.object(Path, "read_text", read), \
         patch('validation_evidence.report_lock', side_effect=lambda **kwargs: nullcontext()), \
         patch('validation_evidence.write_report', side_effect=lambda report, *, path: write(path, json.dumps(report))), \
         patch.object(subprocess, "run", side_effect=result_response) as result_tool:
        for stage, process_status, expected in (("testPhoneRoundTrip", "65", 65), ("testCleanup", "0", 0)):
            with patch.object(sys, "argv", ["record", "/smoke/report.json", "/smoke/results.xcresult", stage, process_status, "/smoke/log"]), redirect_stdout(StringIO()):
                try:
                    exec(compile(match[1], "smoke-stage-record", "exec"), {})
                except SystemExit as error:
                    if error.code != expected:
                        findings.append("Smoke 结果自测失败：阶段状态码传播")
        report = json.loads(state["/smoke/report.json"])
        if report["stages"][0].get("testFailures") != summary["testFailures"] or len(report["stages"]) != 1 \
                or report.get("cleanup", {}).get("passedTests") != 1 or result_tool.call_count != 4:
            findings.append("Smoke 结果自测失败：失败阶段与清理阶段的证据归属")
        for log, expected in (("", 1), ("skipped", 1), ("failed", 1), ("passed", 0)):
            completed = {"totalTestCount": int(bool(log)), "passedTests": int(log == "passed"),
                         "failedTests": int(log == "failed"), "skippedTests": int(log == "skipped")}
            result_tool.side_effect = result_response
            remove_bundle.reset_mock()
            retain_bundle.reset_mock()
            with patch.object(sys, "argv", ["record", "/smoke/report.json", "/smoke/results.xcresult", "testCleanup", "0", "/smoke/log"]), redirect_stdout(StringIO()):
                try:
                    exec(compile(match[1], "smoke-cleanup-record", "exec"), {})
                except SystemExit as error:
                    if error.code != expected:
                        findings.append(f"Smoke 清理验收自测失败：{log or '零用例'}")
            cleanup = json.loads(state["/smoke/report.json"])["cleanup"]
            if expected and (remove_bundle.called or retain_bundle.call_args.args != ("/smoke/generated.xcresult", "/smoke/test-results.xcresult")
                    or cleanup.get("resultBundle") != "/smoke/test-results.xcresult"):
                findings.append("Smoke 结果自测：失败阶段保留固定路径原始结果包")
            if not expected and (retain_bundle.called or not remove_bundle.called or "resultBundle" in cleanup):
                findings.append("Smoke 结果自测：成功阶段完成归集后清理原始结果包")
        completed = {'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}
        for key, value in [('identifier', 'UnrelatedTests/testAlwaysPass'), ('target', 'OtherTests'), ('platform', 'iOS Simulator'), ('deviceId', 'other')]:
            observed[key] = value
            with patch.object(sys, 'argv', ['record', '/smoke/report.json', '/smoke/results.xcresult', 'testCleanup', '0', '/smoke/log']), redirect_stdout(StringIO()):
                try: exec(compile(match[1], 'smoke-stage-identity', 'exec'), {})
                except SystemExit as error: assert error.code == 1
            assert json.loads(state['/smoke/report.json'])['cleanup']['exitCode'] == 1
            observed.clear()
        for exit_code in (0, 65):
            completed = {"totalTestCount": 1, "passedTests": int(exit_code == 0), "failedTests": int(exit_code != 0),
                "skippedTests": 0, "testFailures": summary["testFailures"] if exit_code else []}
            remove_bundle.reset_mock()
            retain_bundle.reset_mock()
            with patch.object(Path, "glob", return_value=iter([Path("/smoke/test-results.xcresult"), Path("/smoke/generated.xcresult")])), \
                    patch.object(Path, "exists", lambda path: path.name == "test-results.xcresult"), \
                    patch.object(sys, "argv", ["record", "/smoke/report.json", "", "testMacCleanup", str(exit_code), "/smoke/log"]), redirect_stdout(StringIO()):
                try:
                    exec(compile(match[1], "mac-cleanup-record", "exec"), {})
                except SystemExit as error:
                    if error.code != exit_code:
                        findings.append("Mac 恢复自测：清理状态码传播")
            cleanup = json.loads(state["/smoke/report.json"])["macCleanup"]
            merged = retain_bundle.call_args.args == ('/smoke/test-results.incoming.xcresult', '/smoke/test-results.xcresult') if retain_bundle.called else False
            if (merged != bool(exit_code)) or remove_bundle.call_args.args != (Path("/smoke/generated.xcresult"),) \
                    or exit_code and (cleanup.get("resultBundle") != "/smoke/test-results.xcresult"
                        or cleanup.get("testFailures") != summary["testFailures"]):
                findings.append("Mac 恢复自测：保留业务结果包与清理失败诊断")
    return findings
