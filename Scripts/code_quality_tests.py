"""Executable checks for workflow dispatch, cache ownership and audit rules."""

from __future__ import annotations
from workflow_process_tests import workflow_lock_boundary_findings
from script_command_tests import (
    script_command_boundary_findings,
    device_discovery_boundary_findings,
    audit_lock_boundary_findings,
    restore_installation_boundary_findings,
)
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
    ROOT,
    SCRIPT_ROOT,
    swift_files,
    ast_has_view_request,
    ci_trigger_shell_self_test,
    cancellation_findings,
    asynchronous_test_wait_findings,
    client_source_findings,
    extension_dependency_findings,
    mask_literals_and_comments,
    view_transport_findings,
    discarded_file_write_findings,
    file_write_calls,
    owner_has_call,
    uses_application_support_storage,
    view_request_matches,
    source_findings,
)

from build_workflow_tests import (
    command_logging_boundary_findings as command_logging_boundary_findings,
    script_output_boundary_findings as script_output_boundary_findings,
    catalyst_signing_boundary_findings as catalyst_signing_boundary_findings,
    check_cache_setting_defaults as check_cache_setting_defaults,
    verify_cache_build_action as verify_cache_build_action,
    build_cache_boundary_findings as build_cache_boundary_findings,
)
from smoke_workflow_tests import (
    run_recorded_stage as run_recorded_stage,
    smoke_script_boundary_findings as smoke_script_boundary_findings,
)


def campus_fixture_self_test() -> None:
    import generate_campus_map_fixture as subject
    from generate_campus_map_fixture import merge_locations, FIXTURE_PATH

    sheet = Mock()
    sheet.iter_rows.return_value = iter(
        [
            ("学校校区", "课程", "已排时间地点"),
            (),
            ("良乡校区",),
            ("良乡校区", "课程", "星期一第1节 理教楼101"),
        ]
    )
    workbook = Mock(active=sheet)
    with patch.dict(sys.modules, openpyxl=Mock(load_workbook=Mock(return_value=workbook))):
        assert subject.extract_unique_locations(Path("/fixture/courses.xlsx")) == [
            ("良乡校区", "理教楼101")
        ]
    workbook.close.assert_called_once()
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
    assert fixtures and len({(row["campus"], row["classroom"]) for row in fixtures}) == len(
        fixtures
    )
    for row in fixtures:
        assert row["review"] in {"mapped", "excluded"}, "地图 fixture 需要完成地点审核"
        assert (
            (isinstance(row["expected"], str) and bool(row["expected"]))
            if row["review"] == "mapped"
            else row["expected"] is None
        )
    directory = ROOT / ".build/static-audit/campus-fixture-self-test"
    fixture = directory / "campus-map-locations.json"
    incoming = fixture.with_suffix(".incoming")
    original_write = Path.write_text

    def interrupted(path, text, **kwargs):
        original_write(path, text[:1], **kwargs)
        raise OSError("fixture write interrupted")

    try:
        directory.mkdir(parents=True, exist_ok=True)
        fixture.write_text(json.dumps(reviewed, ensure_ascii=False))
        original = fixture.read_bytes()
        with patch.object(subject, "FIXTURE_PATH", fixture):
            with patch.object(Path, "write_text", interrupted):
                try:
                    subject.update_fixture([("良乡校区", "新地点")], True)
                except OSError:
                    pass
                else:
                    raise AssertionError("地图案例写入失败需要传播")
            assert fixture.read_bytes() == original and not incoming.exists()
            try:
                subject.update_fixture([("良乡校区", "新地点")], False)
            except SystemExit:
                pass
            else:
                raise AssertionError("新增案例需要显式选择待审核写入")
            assert fixture.read_bytes() == original
            incoming.write_text("partial")
            assert subject.update_fixture([("良乡校区", "新地点")], True) == (3, 1)
            assert json.loads(fixture.read_text()) == merged and not incoming.exists()
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def checker_boundary_findings() -> list[str]:
    from code_style_tests import self_test as test_style

    test_style()
    from code_quality_rules import script_findings
    from types import SimpleNamespace

    for suffix in (".py", ".sh"):
        path = ROOT / ("Scripts/nested/entry" + suffix)
        source = "if __name__ == '__main__': pass" if suffix == ".py" else "echo ready"
        with (
            patch("code_quality_rules.repository_script_paths", return_value=[path]),
            patch.object(Path, "read_text", return_value=source),
            patch.object(Path, "stat", return_value=SimpleNamespace(st_mode=0)),
        ):
            assert len(script_findings()) == 2
    import warnings
    from ui_rules import check_fonts
    from ui_source_facts import pattern_nodes
    from ui_design_contracts import PADDING_LITERAL

    visual = (
        "struct Example: View { var body: some View { Text(rows[0]).padding(19).font(.system(size:"
        " 23)) } }"
    )
    visual_path = ROOT / "BIT101-iOS/BIT101_iOSApp.swift"
    visual_facts = swift_syntax_index_sources({str(visual_path): visual})[str(visual_path)]
    visual_errors = []
    with patch("ui_rules.source_text", return_value=visual):
        check_fonts(visual_errors, {str(visual_path): visual_facts})
    assert any("23" in error for error in visual_errors), "下标嵌套后的显式字号需要参与验收"
    assert any(
        node["arguments"] == ["19"] for node in pattern_nodes(visual_facts, PADDING_LITERAL)
    ), "下标嵌套后的间距参数需要按调用归属读取"
    from network_capability_rules import constant_boolean

    with warnings.catch_warnings(record=True) as observed:
        warnings.simplefilter("always")
        assert constant_boolean(r'key == "row.\(id)"', lambda name: None) is None
        assert constant_boolean(r'false && check("row.\(id)")', lambda name: None) is False
        assert not observed
    from swift_source_index import swift_code, swift_regex_ranges

    indexed_sources = {
        "RegexCache.swift": 'let label = "预热索引"; let pattern = /a\\/b/; // 已有事实\n',
        "CommentCache.swift": "let number = 17 // 普通注释\n",
    }
    swift_syntax_index_sources(indexed_sources)
    swift_regex_ranges.cache_clear()
    with patch(
        "swift_source_index._run_swift_syntax_index", side_effect=AssertionError("批量事实需要复用")
    ):
        for source in indexed_sources.values():
            assert len(swift_code(source)) == len(source)
            assert "注释" not in swift_code(source)
    from swift_type_index_tests import self_test as type_index_self_test

    type_index_self_test()
    from audit_callback_rules import self_test as audit_delegate_self_test

    audit_delegate_self_test()
    findings: list[str] = []
    escape_path = ROOT / "BIT101-iOS/Concurrency.swift"
    for conformance in ("Sendable", "Swift.Sendable", "Swift.`Sendable`", "Alias"):
        source = (
            "import Foundation; typealias Alias = Sendable; final class Escaped: @unchecked "
            + conformance
            + " {}\n"
        )
        syntax = swift_syntax_index_sources({str(escape_path): source})
        with (
            patch("code_quality_rules.swift_files", return_value=[escape_path]),
            patch.object(Path, "read_text", return_value=source),
        ):
            errors, _ = source_findings(syntax)
        assert any("并发访问" in error for error in errors), conformance
    from code_quality_rules import audit_callback_findings

    callbacks = Path(__file__).with_name("run-static-audit.sh").read_text()
    assert audit_callback_findings(callbacks) == []
    assert audit_callback_findings(
        callbacks.replace('python3 "$ROOT_DIR/Scripts/check-module-boundaries.py"', "true")
    )
    from code_quality_rules import scheme_inventory_findings

    scheme = (
        '<Scheme LastUpgradeVersion="2700"><BuildAction buildImplicitDependencies="YES" /></Scheme>'
    )
    if scheme_inventory_findings({"App": scheme}):
        findings.append("Scheme 库存自测：单一共享约定进入验收")
    if not scheme_inventory_findings({"App": scheme, "Copy": scheme.replace("2700", "2630")}):
        findings.append("Scheme 库存自测：元数据差异保留重复约定判定")
    if scheme_inventory_findings({"App": scheme, "Independent": scheme.replace("YES", "NO")}):
        findings.append("Scheme 库存自测：独立构建约定保持不同入口")
    from validate_versions import app_store_request_self_test

    findings.extend(app_store_request_self_test())
    from validation_test_areas import test_inventory
    from validation_test_areas import (
        inventory_findings,
        critical_findings,
        CRITICAL_CONTRACTS,
        fixture_resource_self_test,
    )

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
    markers = mask_literals_and_comments(
        '// TODO\n/* FIXME /* HACK */ */\nlet text = "TODO"', keep_comments=True
    )
    if len(re.findall(r"\b(?:TODO|FIXME|HACK)\b", markers)) != 3:
        findings.append("代码质量规则界限自检失败：维护标记覆盖行注释及嵌套块注释")
    cancellation_path = ROOT / "Modules/TransportCore/Sources/RelocatedCancellation.swift"
    cancellation_source = """
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
"""
    cancellation_syntax = swift_syntax_index_sources({str(cancellation_path): cancellation_source})
    if (
        len(
            cancellation_findings(
                cancellation_path, cancellation_source, cancellation_syntax[str(cancellation_path)]
            )
        )
        != 4
    ):
        findings.append(
            "代码质量规则界限自检失败：取消识别按声明归属处理文件迁移、变量改名和模块限定类型"
        )
    if cancellation_findings(
        ROOT / "ModuleTests/Transport/ExactErrorTests.swift",
        cancellation_source,
        cancellation_syntax[str(cancellation_path)],
    ):
        findings.append("代码质量规则界限自检失败：测试可直接断言底层取消类型")
    wait_path = ROOT / "ModuleTests/Transport/EventTests.swift"
    view_path = str(ROOT / "BIT101-iOS/Example.swift")
    transport_path = str(ROOT / "Modules/TransportCore/Sources/HTTPClient.swift")
    for body, expected in (
        (
            (
                "struct Example: View { let client: HTTPClient; let request: URLRequest; var body:"
                ' some View { Text("").task { _ = try? await client.send(request) } } }'
            ),
            True,
        ),
        (
            (
                "struct Example: View { let session: URLSession; let request: URLRequest; var body"
                ': some View { Text("").task { _ = try? await session.data(for: request) } } }'
            ),
            True,
        ),
        *(
            (
                (
                    f"struct Example: "
                    f"{kind}"
                    f' {{ let client: HTTPClient; var body: some Scene {{ WindowGroup {{ Text("").t'
                    f"ask {{ try? await client.send(URLRequest(url: url)) }} }} }} }}"
                ),
                True,
            )
            for kind in ("App", "Scene")
        ),
        (
            (
                "struct Example: ViewModifier { let client: HTTPClient; let request: URLRequest; f"
                "unc body(content: Content) -> some View { content.task { _ = try? await client.se"
                "nd(request) } } }"
            ),
            True,
        ),
        (
            (
                "struct Example { let client: HTTPClient; func render(_ request: URLRequest) -> so"
                "me View { Task { _ = try? await client.send(request) }; EmptyView() } }"
            ),
            True,
        ),
        *(
            (
                (
                    f"struct Example: View {{ let client: CommunityAPIClient; var body: some View"
                    f' {{ Text("").task {{ try? await client.'
                    f"{method}"
                    f"(request) }} }} }}"
                ),
                True,
            )
            for method in ("request", "requestData", "requestVoid")
        ),
        (
            (
                "struct Example: View { let client: HTTPClient; var body: some View { let send = c"
                'lient.send; return Text("").task { _ = try? await send(request) } } }'
            ),
            True,
        ),
        (
            (
                "struct Example { let client: HTTPClient; func render() -> some View { let send = "
                "client.send; Task { _ = try? await send(request) }; EmptyView() } }"
            ),
            True,
        ),
        (
            (
                "struct Example: View { let service: Service; var body: some View { let send = ser"
                'vice.send; return Text("").task { await send(1) } } }; struct Service { func send'
                "(_ value: Int) async {} }"
            ),
            False,
        ),
        (
            (
                'struct Example: View { let client: Local; var body: some View { Text("").task { a'
                "wait client.send(1) } } }; struct Local { func send(_ value: Int) async {} }"
            ),
            False,
        ),
        (
            (
                'struct Example: View { let service: Service; var body: some View { Text("").task '
                "{ await service.fetch() } } }; struct Service { func fetch() async {} }"
            ),
            False,
        ),
    ):
        index = swift_syntax_index_sources(
            {view_path: body, transport_path: "public struct HTTPClient {}"}
        )
        if bool(view_transport_findings(index)) != expected:
            findings.append("视图网络传输自测：现成请求、视图工厂及同名业务方法按所属类型验收")
    storage_path = str(ROOT / "Modules/StorageCore/Sources/AppFileService.swift")
    for argument, expected in (
        ("root", True),
        ('root.appendingPathComponent("cache")', True),
        ('"cache"', False),
    ):
        source = """struct FileHelper { let files: any AppFileService;
            func run(_ root: URL) { try? save(ARGUMENT) }
            private func save(_ location: URL) throws { try files.writeData(Data(), to: location) }
            private func save(_ text: String) throws {} }""".replace("ARGUMENT", argument)
        index = swift_syntax_index_sources(
            {
                view_path: source,
                storage_path: (
                    "public protocol AppFileService { func writeData(_ data: Data, to url: URL) th"
                    "rows }"
                ),
            }
        )
        if (
            bool(
                discarded_file_write_findings(
                    Path(view_path), source, index[view_path], file_write_calls(index)
                )
            )
            != expected
        ):
            findings.append("持久化重载自测：未知实参保留可能的文件写入边，明确类型沿对应重载验收")
    from swift_type_index_tests import asynchronous_wait_self_test

    asynchronous_wait_self_test(wait_path)
    unwrap_source = (
        '\n// value!\nlet example = "value!"\nlet unwrapped = value!\nlet subscriptValue = entries'
        "[index]!\nlet tupleValue = pair.0!; let forcedTry = try! operation(); let forcedCast = va"
        'lue as! String\nlet interpolated = "\\(entry!)"\nlet comparison = left != right\nstruct H'
        "andler { var value: String!; func read() -> String { value }; func catches() { do {} catc"
        "h _ {}; do {} catch let error {}; do {} catch is Error {}; do {} catch { _ = error }; do "
        "{} catch let failure { let _ = failure }; do {} catch { handle(error) }; do {} catch { _ "
        "= record(error) } } }\n"
    )
    unwrap_facts = swift_syntax_index_sources({"Unwrap.swift": unwrap_source})["Unwrap.swift"]
    write_path = ROOT / "Modules/CommunityPersistence/Sources/Example.swift"
    write_source = (
        "func update(files: AppFileService) { try? files.removeItem(at: url); _ = try? files.write"
        "Data(data, to: url); let result = try? files.createDirectory(at: url); let data = try? fi"
        "les.readData(at: url) }"
    )
    write_facts = swift_syntax_index_sources({str(write_path): write_source})[str(write_path)]
    if len(discarded_file_write_findings(write_path, write_source, write_facts)) != 3:
        findings.append("代码质量自测：文件副作用的丢弃结果需要错误处理，已消费结果沿调用方处理")
    writes = {
        "try? data.write(to: url, options: .atomic)": True,
        "let outcome = try? files.writeData(data, to: url); _ = outcome": True,
        "let outcome = try? files.writeData(data, to: url); consume(outcome)": False,
        "let outcome = try? files.writeData(data, to: url); consume { outcome }": False,
        "let _ = try? files.removeItem(at: url)": True,
        "let _: Void? = try? files.writeData(data, to: url)": True,
        "_ = (try? files.removeItem(at: url))": True,
        "(try? files.removeItem(at: url))": True,
        "let _ = (try? files.removeItem(at: url))": True,
        "try? handle.write(contentsOf: data)": True,
        "try? text.write(to: url, atomically: true, encoding: .utf8)": True,
        "try? urls.forEach { try files.removeItem(at: $0) }": True,
        "try? files.replaceItemAt(url, withItemAt: other)": True,
        "try? files.setPrivateFileProtection(at: url)": True,
        "try? files.setBackupExcluded(true, at: url)": True,
        "try? files.setModificationDate(Date(), at: url)": True,
        "try? MemoryCollection().setPrivateFileProtection(at: url)": False,
        "try? client.write(value)": False,
        "let cleanup = files.removeItem(at:); try? cleanup(url)": True,
        "let cleanup = { try files.removeItem(at: url) }; try? cleanup()": True,
        "let cleanup = { try files.removeItem(at: url) }; let untouched = 1": False,
        "try? MemoryCollection().removeItem(at: 0)": False,
        "try? MemoryCollection().writeData(data, to: url)": False,
        "try? MemoryCollection().createDirectory(at: url)": False,
        "try? MemoryCollection().moveItem(at: url, to: other)": False,
        "try? MemoryCollection().copyItem(at: url, to: other)": False,
        "try? MemoryCollection().replaceItemAt(url, withItemAt: other)": False,
        "try? FileManager.default.removeItem(at: url)": True,
        "let store = files; let local = store; try? local.removeItem(at: url)": True,
        "let store = MemoryCollection(); let local = store; try? local.removeItem(at: 0)": False,
    }
    write_sources = {
        statement: (
            "struct MemoryCollection { func removeItem(at index: Int) throws {} }; func update(fil"
            "es: any AppFileService, data: Data, handle: FileHandle, text: String) { "
        )
        + statement
        + " }"
        for statement in writes
    }
    write_index = swift_syntax_index_sources(write_sources)
    for statement, expected in writes.items():
        if (
            bool(
                discarded_file_write_findings(
                    write_path, write_sources[statement], write_index[statement]
                )
            )
            != expected
        ):
            findings.append("代码质量自测：Foundation 文件写入与闭包内清理沿丢弃错误门禁处理")
    if discarded_file_write_findings(
        ROOT / "Modules/MediaKit/Sources/RemoteImageCache.swift", write_source, write_facts
    ):
        findings.append("代码质量自测：图片缓存沿已有可选写盘约定处理")
    for directory in ("ModuleTests/Support", "BIT101-iOSTests", "BIT101-iOSUITests"):
        if (
            len(
                discarded_file_write_findings(
                    ROOT / directory / "Fixture.swift", write_source, write_facts
                )
            )
            != 3
        ):
            findings.append("代码质量自测：测试测试数据的写入和清理需要错误处理")
    wrapper_sources = {
        str(write_path): """
        struct Store {
            let files: AppFileService
            func update() { try? save(); try? self.again(); try? save(value: 1); try? handled() }
            func save() throws { try files.writeData(data, to: url) }
            func save(value: Int) throws { try client.fetch(value) }
            func again() throws { try save() }
            func handled() { do { try files.writeData(data, to: url) } catch { log(error) } }
        }
    """,
        str(
            write_path.with_name("Extension.swift")
        ): "extension Store { func reset() { try? self.again() } }",
    }
    wrapper_index = swift_syntax_index_sources(wrapper_sources)
    wrapper_writes = file_write_calls(wrapper_index)
    if (
        sum(
            len(
                discarded_file_write_findings(
                    Path(path), wrapper_sources[path], facts, wrapper_writes
                )
            )
            for path, facts in wrapper_index.items()
        )
        != 3
    ):
        findings.append("代码质量自测：持久化包装方法沿类型、重载及抛错调用链处理")
    if (
        len(unwrap_facts["forceUnwraps"]) != 7
        or len(unwrap_facts["emptyCatchClauses"]) != 5
        or not any(path.is_relative_to(ROOT / "BIT101-iOSUITests") for path in swift_files())
    ):
        findings.append("代码质量规则界限自检失败：全部测试目录的解包、强制 try 与类型转换识别")
    view_source = "struct SampleView: View { let request = URLRequest(url: url) }"
    model_source = "struct SampleModel { let request = URLRequest(url: url) }"
    if len(view_request_matches(view_source)) != 1 or view_request_matches(model_source):
        findings.append("代码质量规则界限自检失败：View 请求构造范围识别")
    view_facts = {
        "declarations": [{"name": "SampleView", "inheritedTypes": ["SwiftUI.View"]}],
        "calls": [{"value": "URLRequest", "scope": ["SampleView"]}],
    }
    model_facts = {
        "declarations": [{"name": "SampleModel", "inheritedTypes": ["ObservableObject"]}],
        "calls": [{"value": "URLRequest", "scope": ["SampleModel"]}],
    }
    if not ast_has_view_request(view_facts) or ast_has_view_request(model_facts):
        findings.append("代码质量规则界限自检失败：SwiftSyntax View 请求范围匹配")
    for constructor in (
        "Foundation.URLRequest(url: url)",
        "Foundation . URLRequest(url: url)",
        "URLRequest.init(url: url)",
        "let request: URLRequest = .init(url: url)",
        "typealias Request = URLRequest; Request(url: url)",
        "var request: URLRequest { .init(url: url) }",
        (
            "typealias Request = Foundation.URLRequest; typealias Alias = Request; var request: Al"
            "ias { .init(url: url) }"
        ),
        "func consume(_ request: URLRequest) {}; consume(.init(url: url))",
        "func consume(_ requests: [URLRequest]) {}; consume([.init(url: url)])",
        "func consume(_ request: URLRequest, enabled: Bool = true) {}; consume(.init(url: url))",
        "func consume(_ requests: URLRequest...) {}; consume(.init(url: url), .init(url: other))",
    ):
        if not all(
            ast_has_view_request(
                swift_syntax_index_sources(
                    {
                        "view-request": (
                            f"struct SampleView: {kind} {{ func load() {{ {constructor} }} }}"
                        )
                    }
                )["view-request"]
            )
            for kind in ("View", "ViewModifier", "App", "Scene")
        ):
            findings.append("View 请求构造自测：限定类型、显式及推断构造")

    if not uses_application_support_storage(
        {"value": "AppFileDirectories.accountSupportFileURL"}
    ) or uses_application_support_storage(
        {"value": "FileManager.default.urls(for: .applicationSupportDirectory)"}
    ):
        findings.append("代码质量规则界限自检失败：持久化仓库的统一存储入口识别")

    relocated_facts = {
        "declarations": [{"kind": "struct", "name": "ExampleView", "scope": []}],
        "calls": [{"value": "restoreCache", "scope": ["ExampleView"]}],
        "members": [],
        "scopedIdentifiers": [],
        "stringSegments": [],
    }
    relocated_index = {"Moved/ExampleView.swift": relocated_facts}
    if not owner_has_call(relocated_index, "ExampleView", "restoreCache"):
        findings.append("代码质量规则界限自检失败：类型迁移后仍按声明作用域匹配契约")
    if owner_has_call(relocated_index, "MissingView", "restoreCache"):
        findings.append("代码质量规则界限自检失败：缺少契约类型应保持失败")
    module_path = ROOT / "Modules/GalleryFeature/Sources/ExampleView.swift"
    for source, marker in (
        ('struct ExampleView: View { func load() { print("value") } }', "Logger"),
        ("struct ExampleView: View { let formatter = DateFormatter() }", "AppDateText"),
        (r'let text = "\(print("value"))"', "Logger"),
    ):
        if not any(marker in finding for finding in client_source_findings(module_path, source)):
            findings.append("代码质量规则界限自检失败：模块与插值中的客户端规则")
    for source, expected in (
        ("item.loadTransferable(type: Data.self)", True),
        ("item.loadTransferable(type: Foundation.Data.self)", True),
        ("item.loadBoundedImageData()", False),
        ('let label = "item.loadTransferable(type: Data.self)"', False),
    ):
        if (
            any("照片原始数据" in value for value in client_source_findings(module_path, source))
            != expected
        ):
            findings.append("照片读取容量门禁自检")
    if client_source_findings(module_path, '// print("value")\nlet example = "DateFormatter()"'):
        findings.append("代码质量规则界限自检失败：模块文案进入执行代码规则")
    for constructor in (
        "DateFormatter.init()",
        "typealias Formatter = DateFormatter; Formatter()",
        "typealias Formatter = Foundation.ISO8601DateFormatter; Formatter.init()",
        "let formatter: RelativeDateTimeFormatter = .init()",
    ):
        source = f"struct ExampleView: View {{ func render() {{ {constructor} }} }}"
        if not any("AppDateText" in value for value in client_source_findings(module_path, source)):
            findings.append("社区日期构造自测：别名、显式与推断构造")
    source = "struct DateFormatter {}; struct ExampleView: View { let formatter = DateFormatter() }"
    if client_source_findings(module_path, source):
        findings.append("社区日期构造自测：同名业务类型归属")
    for source, expected in (
        ("import TransportCore\nimport MediaKit\nimport TransportCore\n", 1),
        ("#if os(iOS)\nimport UIKit\n#else\nimport UIKit\n#endif\n", 0),
        ('let example = "import UIKit"\n// import UIKit\nimport UIKit\n', 0),
    ):
        with (
            patch("code_quality_rules.swift_files", return_value=[module_path]),
            patch.object(Path, "read_text", return_value=source),
        ):
            if sum("重复 import" in value for value in source_findings()[0]) != expected:
                findings.append("代码质量规则界限自检失败：分支内重复导入与注释、字符串隔离")
    findings.extend(smoke_script_boundary_findings())
    workflow_source = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    findings.extend(
        ci_trigger_shell_self_test(workflow_source) + cross_file_view_request_self_test()
    )
    from ci_wiring_rules import ci_wiring_findings

    upload = re.search(r"actions/upload-artifact@[0-9a-f]{40}", workflow_source)[0]
    renamed_steps = re.sub(
        r"(?m)^(\s+- name:).*$", r"\1 Descriptive workflow label", workflow_source
    )
    assert not ci_wiring_findings(renamed_steps)
    reordered = workflow_source.replace(
        "[validation-plan, static-audit, ios-app-tests]",
        "[ios-app-tests, validation-plan, static-audit]",
    )
    assert reordered != workflow_source and not ci_wiring_findings(reordered)
    assert not ci_wiring_findings(
        workflow_source.replace("needs: [validation-plan]", "needs: validation-plan")
    )
    spaced = workflow_source.replace(
        "run: python3 Scripts/ci_evidence.py reuse ",
        'run: python3  "Scripts/ci_evidence.py"   reuse ',
    )
    assert not ci_wiring_findings(spaced)
    assert not ci_wiring_findings(
        workflow_source.replace(upload, "actions/upload-artifact@" + "a" * 40)
    )
    for reference in ("v8", "main"):
        assert ci_wiring_findings(
            workflow_source.replace(upload, "actions/upload-artifact@" + reference)
        )
    assert ci_wiring_findings(
        workflow_source.replace("compression-level: 0", "compression-level: 6")
    )
    assert ci_wiring_findings(workflow_source.replace("    tags: ['v*']\n", ""))
    assert ci_wiring_findings(
        workflow_source.replace(
            "run: python3 Scripts/ci_evidence.py check-release", "run: echo skipped"
        )
    )
    assert ci_wiring_findings(
        workflow_source.replace(
            "run: python3 Scripts/ci_evidence.py export-result ios", "run: true"
        )
    )
    assert any(
        "禁止执行 UITest" in message
        for message in ci_wiring_findings(
            workflow_source.replace(
                "Scripts/run-extended-tests.sh simulator app",
                "Scripts/run-extended-tests.sh simulator ui",
            )
        )
    )
    for event in ("pull_request", "push"):
        for filtering in ("paths", "paths-ignore"):
            assert ci_wiring_findings(
                workflow_source.replace(
                    event + ":\n", event + f":\n    {filtering}: ['docs/**']\n", 1
                )
            )
    extension_graph = {
        "objects": {
            "app": {
                "isa": "PBXNativeTarget",
                "name": "BIT101-iOS",
                "dependencies": ["widget-edge", "watch-edge"],
            },
            "widget": {"isa": "PBXNativeTarget", "name": "BIT101ScheduleWidgets"},
            "watch": {
                "isa": "PBXNativeTarget",
                "name": "BIT101Watch",
                "dependencies": ["watch-widget-edge"],
            },
            "watch-widget": {"isa": "PBXNativeTarget", "name": "BIT101WatchWidgets"},
            "widget-edge": {"target": "widget", "platformFilter": "ios"},
            "watch-edge": {"target": "watch", "platformFilter": "ios"},
            "watch-widget-edge": {"target": "watch-widget"},
        }
    }
    if extension_dependency_findings(extension_graph):
        findings.append("代码质量规则界限自检失败：父 target 的扩展编译覆盖识别")
    extension_graph["objects"]["watch-edge"].pop("platformFilter")
    if not extension_dependency_findings(extension_graph):
        findings.append("代码质量规则界限自检失败：Mac Catalyst 的扩展平台隔离")
    extension_graph["objects"]["watch-edge"]["platformFilter"] = "ios"
    extension_graph["objects"]["watch"]["dependencies"] = []
    if not extension_dependency_findings(extension_graph):
        findings.append("代码质量规则界限自检失败：扩展依赖断开应触发门禁")
    from code_quality_rules import native_project_targets

    native_graph = {
        "rootObject": "project",
        "objects": {
            "project": {"mainGroup": "root"},
            "root": {"children": ["group"], "sourceTree": "<group>"},
            "group": {"path": "Shared", "children": ["source"], "sourceTree": "<group>"},
            "source": {"path": "Shared.swift"},
            "build": {"fileRef": "source"},
            "phase": {"isa": "PBXSourcesBuildPhase", "files": ["build"]},
            "product": {"productName": "StorageCore"},
            "new": {
                "isa": "PBXNativeTarget",
                "name": "FutureUITests",
                "buildPhases": ["phase"],
                "packageProductDependencies": ["product"],
            },
        },
    }
    if native_project_targets(native_graph, ROOT) != [
        ("FutureUITests", {"StorageCore"}, {ROOT / "Shared/Shared.swift"})
    ]:
        findings.append("工程依赖自检失败：新增 target 和跨目录编译源文件需要按工程归属审计")
    return findings
