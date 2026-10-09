"""Executable checks for workflow dispatch, cache ownership and audit rules."""
from __future__ import annotations
from script_command_tests import script_command_boundary_findings
from worker_contract_tests import worker_boundary_findings

from pathlib import Path
import json, os, re, subprocess, sys, shutil, signal
from contextlib import nullcontext, redirect_stdout, redirect_stderr
from io import BytesIO, StringIO
from unittest.mock import Mock, patch
from swift_source_index import swift_syntax_index_sources
from ui_rule_tests import device_discovery_boundary_findings, explanatory_text_boundary_findings, school_lifecycle_boundary_findings

from code_quality_rules import (
    ROOT, SCRIPT_ROOT, swift_files, ast_has_view_request, ci_trigger_shell_self_test, cross_file_view_request_self_test,
    cancellation_findings, client_source_findings, extension_dependency_findings, mask_literals_and_comments,
    owner_has_call, uses_application_support_storage, view_request_matches, source_findings,
)


def campus_fixture_self_test() -> None:
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


def checker_boundary_findings() -> list[str]:
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
    from validation_evidence import community_recovery_self_test, test_inventory
    from validation_test_areas import inventory_findings, critical_findings, CRITICAL_CONTRACTS
    findings.extend(inventory_findings({test.split("/", 1)[0] for test in test_inventory("all")}))
    inventories = {group: test_inventory(group) for group in CRITICAL_CONTRACTS}
    findings.extend(critical_findings(inventories))
    removed = {group: set(tests) for group, tests in inventories.items()}
    removed["all"].discard(next(iter(CRITICAL_CONTRACTS["all"].values())))
    assert critical_findings(removed)
    findings.extend(community_recovery_self_test())
    findings.extend(script_output_boundary_findings())
    campus_fixture_self_test()
    markers = mask_literals_and_comments('// TODO\n/* FIXME /* HACK */ */\nlet text = "TODO"', keep_comments=True)
    if len(re.findall(r"\b(?:TODO|FIXME|HACK)\b", markers)) != 3:
        findings.append("代码质量规则边界自检失败：维护标记覆盖行注释及嵌套块注释")
    cancellation_path = ROOT / "Modules/TransportCore/Sources/RelocatedCancellation.swift"
    cancellation_source = '''
enum TaskCancellation {
    static func matches(_ error: Error) -> Bool { error is CancellationError }
}
enum Consumer {
    func wrong(_ renamed: Error) -> Bool { renamed is Swift.CancellationError }
    func cast(_ error: Error) -> Bool { (error as? CancellationError) != nil }
    func catches() { do { try work() } catch let error as CancellationError { consume(error) } }
    func wrapped(_ renamed: Error) -> Bool { TaskCancellation.matches(renamed) }
    let example = "error is CancellationError"
}
'''
    cancellation_syntax = swift_syntax_index_sources({str(cancellation_path): cancellation_source})
    if len(cancellation_findings(cancellation_path, cancellation_source, cancellation_syntax[str(cancellation_path)])) != 3:
        findings.append("代码质量规则边界自检失败：取消识别按声明归属处理文件迁移、变量改名和模块限定类型")
    if cancellation_findings(ROOT / "ModuleTests/Transport/ExactErrorTests.swift", cancellation_source, cancellation_syntax[str(cancellation_path)]):
        findings.append("代码质量规则边界自检失败：测试可直接断言底层取消类型")
    unwrap_source = '''
// value!
let example = "value!"
let unwrapped = value!
let subscriptValue = entries[index]!
let tupleValue = pair.0!; let forcedTry = try! operation(); let forcedCast = value as! String
let interpolated = "\\(entry!)"
let comparison = left != right
struct Handler { var value: String!; func read() -> String { value }; func catches() { do {} catch _ {}; do {} catch let error {}; do {} catch is Error {}; do {} catch { handle(error) } } }
'''
    unwrap_facts = swift_syntax_index_sources({"Unwrap.swift": unwrap_source})["Unwrap.swift"]
    if len(unwrap_facts["forceUnwraps"]) != 7 or len(unwrap_facts["emptyCatchClauses"]) != 3 or not any(path.is_relative_to(ROOT / "BIT101-iOSUITests") for path in swift_files()):
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
    for constructor in ("Foundation.URLRequest(url: url)", "Foundation . URLRequest(url: url)", "URLRequest.init(url: url)", "let request: URLRequest = .init(url: url)", "typealias Request = URLRequest; Request(url: url)", "var request: URLRequest { .init(url: url) }", "typealias Request = Foundation.URLRequest; typealias Alias = Request; var request: Alias { .init(url: url) }", "func consume(_ request: URLRequest) {}; consume(.init(url: url))", "func consume(_ requests: [URLRequest]) {}; consume([.init(url: url)])"):
        if not ast_has_view_request(swift_syntax_index_sources({"view-request": f"struct SampleView: View {{ func load() {{ {constructor} }} }}"})["view-request"]):
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
    if client_source_findings(module_path, '// print("value")\nlet example = "DateFormatter()"'):
        findings.append("代码质量规则边界自检失败：模块文案进入执行代码规则")
    for source, expected in (("import TransportCore\nimport MediaKit\nimport TransportCore\n", 1),
                             ("#if os(iOS)\nimport UIKit\n#else\nimport UIKit\n#endif\n", 0),
                             ('let example = "import UIKit"\n// import UIKit\nimport UIKit\n', 0)):
        with patch("code_quality_rules.swift_files", return_value=[module_path]), patch.object(Path, "read_text", return_value=source):
            if sum("重复 import" in value for value in source_findings()[0]) != expected:
                findings.append("代码质量规则边界自检失败：分支内重复导入与注释、字符串隔离")
    findings.extend(smoke_script_boundary_findings())
    workflow_source = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    findings.extend(ci_trigger_shell_self_test(workflow_source) + cross_file_view_request_self_test())
    from code_quality_rules import ci_wiring_findings
    assert not ci_wiring_findings(workflow_source.replace("actions/upload-artifact@v7", "actions/upload-artifact@v8"))
    assert not ci_wiring_findings(workflow_source.replace("actions/upload-artifact@v7", "actions/upload-artifact@" + "a" * 40))
    assert ci_wiring_findings(workflow_source.replace("actions/upload-artifact@v7", "actions/upload-artifact@main"))
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


def script_output_boundary_findings() -> list[str]:
    """通过内存命令输出验证阈值、完整留档及进程状态。"""
    from types import SimpleNamespace

    source = (SCRIPT_ROOT / "script-support.sh").read_text()
    block = re.search(r"<<'PY'\n(.*?)^PY$", source, re.MULTILINE | re.DOTALL)
    if block is None:
        return ["日志自测需要公共输出处理器"]
    findings: list[str] = []
    for status, count, ci in ((0, 10, False), (7, 40, False), (7, 41, False),
                              (-15, 1, False), (0, 41, True), (7, 41, True)):
        lines = [f"error: diagnostic {index}\n" for index in range(count)]
        process = SimpleNamespace(stdout=iter(lines), wait=lambda: status)
        visible, log = StringIO(), StringIO()
        with patch.object(sys, "argv", ["logger", "/audit/build.log", "logger", "fake"]), \
             patch.object(subprocess, "Popen", return_value=process), \
             patch.object(Path, "mkdir"), patch.object(Path, "open", return_value=nullcontext(log)), \
             patch.dict(os.environ, {"GITHUB_ACTIONS": "true" if ci else "false"}), \
             redirect_stdout(visible):
            try:
                exec(compile(block[1], "logger-self-test", "exec"), {})
            except SystemExit as error:
                expected = status if status >= 0 else 128 - status
                if error.code != expected:
                    findings.append("日志自测：进程退出状态传递")
            else:
                findings.append("日志自测：进程退出状态缺失")
        output = visible.getvalue()
        if log.getvalue() != "".join(lines):
            findings.append("日志自测：完整输出留档")
        show_details = count <= 40 or (ci and status != 0)
        if ("[输出]" in output) == show_details:
            findings.append("日志自测：本地展示阈值与 CI 失败诊断")
        if show_details and sum(line.startswith("error:") for line in output.splitlines()) != count:
            findings.append("日志自测：完整诊断展示")
    script = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    metrics = re.search(r"(?ms)^record_metrics\(\) \{.*?<<'PY'\n(.*?)^PY$", script)[1]
    with patch.object(sys, "argv", ["metrics", "/result", "/report", "ui", "1", "device", "/audit"]), \
            patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 64, "", "incomplete result")):
        try:
            exec(compile(metrics, "metrics-interruption-self-test", "exec"), {})
        except SystemExit as error:
            if "XCTest 结果包" not in str(error): findings.append("测试指标自测：启动中断摘要")
        else:
            findings.append("测试指标自测：中断阶段保持失败状态")
    validation = re.search(r"(?ms)^finish_validation\(\) \{\n.*?^\}$", script)
    for test_status, evidence_status in ((0, 0), (23, 0), (0, 7)):
        frame = 'ROOT_DIR=/audit\nvalidation_group=ui\nvalidation_scope=full\n'
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
    for check in (build_cache_boundary_findings, script_command_boundary_findings, workflow_lock_boundary_findings,
                  worker_boundary_findings, report_inbox_boundary_findings, explanatory_text_boundary_findings, school_lifecycle_boundary_findings):
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
    harness = r'''
set -euo pipefail
LOG_DIR=/audit
ROOT_DIR=/audit
AUDIT_STARTED=$SECONDS
cat() { :; }
show_group_log() { :; }
python3() { return 0; }
run_group() {
    print -r -- "RAN $1"
    case "$1" in shell-parse|docs) return 7;; esac
    return 0
}
'''
    aggregation = subprocess.run(["zsh", "-c", harness + tail], capture_output=True, text=True)
    groups = re.findall(r"^RAN (.+)$", aggregation.stdout, re.MULTILINE)
    if aggregation.returncode != 1 or len(set(groups)) != 10 or "shell-parse, docs" not in aggregation.stderr:
        findings.append("静态审计自测：并行分组执行完整性与多个失败汇总")
    return findings


def report_inbox_boundary_findings() -> list[str]:
    "验证反馈正文、附件、旧键和重复拉取的保存合同。"

    source = (SCRIPT_ROOT / "fetch-issues-and-reports.sh").read_text()
    block = next(match[1] for match in re.finditer(r"<<'PY'\n(.*?)^PY$", source, re.MULTILINE | re.DOTALL)
                 if "processed_path =" in match[1])
    fixture = ROOT / ".build/static-audit/report-inbox-self-test"
    staging = fixture / ".incoming"
    keys_path, processed_path = fixture / "keys.json", fixture / "report-keys.txt"
    reports = {"report:2000-01-01T10:20:30.000Z:old": {"report": {"isDevelopmentBuild": False,
        "attachments": [{"data": "aW1hZ2U=", "contentType": "image/jpeg"}, {"data": "aW1hZ2U=", "contentType": []}]}},
        "report:2000-01-02T10:20:30.000Z:new": {"report": {"mode": "suggestion"}}}
    import weakref
    live_results = weakref.WeakSet()
    calls = []
    findings = []
    fetch_failures = {}
    def fetch(arguments, **_):
        calls.append(arguments)
        result = subprocess.CompletedProcess(arguments, *fetch_failures.get(arguments[4], (0, json.dumps(reports[arguments[4]]), "")))
        live_results.add(result)
        assert len(live_results) <= 4, "整批报告正文驻留内存"
        return result
    def execute():
        staging.mkdir(parents=True, exist_ok=True)
        keys_path.write_text(json.dumps([{"name": key} for key in reports]))
        output = StringIO()
        with patch.object(sys, "argv", ["inbox", str(keys_path), str(staging), "/worker", "namespace", str(processed_path)]), \
                patch.object(subprocess, "run", fetch), redirect_stdout(output):
            exec(compile(block, "report-inbox-self-test", "exec"), {})
        return int(output.getvalue())
    try:
        assert execute() == 2
        saved = {path.relative_to(fixture): path.read_bytes() for path in fixture.glob("*/*/*") if path.is_file()}
        attachment = next(fixture.glob("*/*/*_附件/*.jpg"))
        assert attachment.read_bytes() == b"image" and next(fixture.glob("*/*/*_附件/*.bin")).read_bytes() == b"image"
        assert execute() == 0
        assert all((fixture / path).read_bytes() == data for path, data in saved.items())
        next(fixture.glob("*/*/report_*.json")).unlink()
        assert execute() == 1 and len(calls) == 3
        assert all(arguments[3] == "get" for arguments in calls)
        reports.update({f"report:2000-01-03:batch-{index}": {"report": {"comment": "x" * 8192}} for index in range(40)})
        assert execute() == 40
        reports["report:invalid-attachment"] = {"report": {"attachments": [
            {"data": "invalid%base64", "contentType": "image/png", "name": "原附件"}, "legacy-invalid"]}}
        try:
            with redirect_stderr(StringIO()):
                execute()
        except SystemExit as error:
            assert error.code == 1
        else:
            raise AssertionError("异常附件需要返回部分失败")
        invalid_path = next(fixture.glob("*/*/report_invalid-attachment.json"))
        archived = json.loads(invalid_path.read_text())
        assert archived["inboxAttachmentErrors"] == 2
        assert archived["report"]["attachments"][0]["data"] == "invalid%base64"
        assert archived["report"]["attachments"][1]["original"] == "legacy-invalid"
        assert "report:invalid-attachment" not in processed_path.read_text()
        reports["report:invalid-attachment"] = {"report": {"attachments": []}}
        assert execute() == 1
        assert "report:invalid-attachment" in processed_path.read_text()
        reports.update({"report:partial-success": {"report": {"comment": "archived"}},
                        "report:request-failure": {}, "report:json-failure": {}})
        fetch_failures.update({"report:request-failure": (17, "", "fixture failure"), "report:json-failure": (0, "{partial", "")})
        with redirect_stderr(StringIO()):
            try: execute()
            except SystemExit as error: assert error.code == 1
            else: raise AssertionError("单份失败需要传播部分失败")
        assert next(fixture.glob("*/*/report_partial-success.json")).is_file()
        assert "report:partial-success" in processed_path.read_text()
        assert "report:request-failure" not in processed_path.read_text() and "report:json-failure" not in processed_path.read_text()
        fetch_failures.clear()
        reports["report:request-failure"] = reports["report:json-failure"] = {"report": {"comment": "recovered"}}
        assert execute() == 2
        import shlex
        tool_dir = fixture / "bin"
        tool_dir.mkdir(exist_ok=True)
        fake_gh = tool_dir / "gh"
        fake_gh.write_text(r'''#!/bin/zsh
if [[ "$1" == api ]]; then
  if [[ "$INBOX_SELF_TEST_MODE" == listing-failure ]]; then print partial; exit 17; fi
  print '[]'
elif [[ "$2" == list ]]; then
  if [[ "$INBOX_SELF_TEST_MODE" == listing-failure ]]; then print partial; exit 18; fi
  if [[ "$INBOX_SELF_TEST_MODE" == log-failure ]]; then
    print '[{"databaseId":1,"updatedAt":"new","headSha":"head"}]'
  else print '[]'; fi
elif [[ "$2" == view ]]; then print -ru2 'fixture log failure'; exit 19
else exit 99; fi
''')
        fake_gh.chmod(0o700)
        shell_source = source.replace('OUTPUT_DIR="$ROOT_DIR/.build/issue-report-inbox"', 'OUTPUT_DIR=' + shlex.quote(str(fixture)))
        shell_source = shell_source.replace('source "$ROOT_DIR/Scripts/script-support.sh"', 'bit101_acquire_script_lock() { :; }\nmock_wrangler() { print \'[]\'; }')
        shell_source = shell_source.replace('WRANGLER="$WRANGLER_DIR/node_modules/.bin/wrangler"', 'WRANGLER=mock_wrangler')
        issue_path, ci_path = fixture / "github-issues.json", fixture / "github-ci.json"
        old_issue = '[{"number":1,"state":"open","title":"cached issue","url":"fixture"}]'
        old_ci = '[{"databaseId":1,"updatedAt":"old","headSha":"head","failedLogTail":"cached log"}]'
        issue_path.write_text(old_issue)
        ci_path.write_text(old_ci)
        def run_fetch(mode):
            return subprocess.run(["zsh", "-c", shell_source, str(SCRIPT_ROOT / "fetch-issues-and-reports.sh"), "fetch"],
                env=dict(os.environ, PATH=str(tool_dir) + os.pathsep + os.environ["PATH"], INBOX_SELF_TEST_MODE=mode),
                capture_output=True, text=True)
        assert run_fetch("listing-failure").returncode == 1
        assert issue_path.read_text() == old_issue and ci_path.read_text() == old_ci
        assert "failed" in (fixture / "summary.txt").read_text()
        assert run_fetch("log-failure").returncode == 1
        partial = json.loads(ci_path.read_text())[0]
        assert partial["previousFailedLogTail"] == "cached log" and "failedLogError" in partial
        assert run_fetch("log-failure").returncode == 1
        repeated = json.loads(ci_path.read_text())[0]
        assert repeated["previousFailedLogTail"] == "cached log" and "failedLogError" in repeated
        assert run_fetch("success").returncode == 0
        assert json.loads(issue_path.read_text()) == json.loads(ci_path.read_text()) == []
    except (AssertionError, OSError) as error:
        findings.append(f"反馈收件箱自测：{error}")
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def workflow_lock_boundary_findings() -> list[str]:
    "验证竞争工作流排队及父子流程锁复用。"
    import select
    import shlex
    import time

    fixture = ROOT / ".build/static-audit/workflow-lock-self-test"
    worker = fixture / "worker.sh"
    release = fixture / "release"
    processes = []
    findings = []
    environment = dict(os.environ)
    optimization = subprocess.run(["zsh", "-c", 'source "$1"; python3 -c "assert False"',
        "assertion-contract", str(SCRIPT_ROOT / "script-support.sh")],
        env=dict(environment, PYTHONOPTIMIZE="1"), capture_output=True, text=True)
    if optimization.returncode == 0 or "AssertionError" not in optimization.stderr:
        findings.append("工作流环境自测：Python 自测断言沿默认优化级别执行")
    environment.pop("BIT101_EXTENDED_TESTS_LOCK_HELD", None)
    environment.pop("BIT101_DEVICE_WORKFLOW_LOCK_HELD", None)
    environment.pop("BIT101_WORKFLOW_DEADLINE", None)
    environment["BIT101_LOCK_TEST_CHECKOUT"] = str(fixture)
    try:
        shutil.rmtree(fixture, ignore_errors=True)
        fixture.mkdir(parents=True, exist_ok=True); os.mkfifo(release)
        support = (SCRIPT_ROOT / "script-support.sh").read_text().replace(
            '"$HOME/Library/Caches/BIT101-iOS/device-workflow.lock"', shlex.quote(str(fixture / "device-workflow.lock")))
        worker.write_text('ROOT_DIR="$BIT101_LOCK_TEST_CHECKOUT"\n' + support + '\n'
                         'if [[ "${1:-}" == artifact ]]; then bit101_acquire_artifact_lock "$0" "$@"; '
                         'else bit101_acquire_workflow_lock "$0" "$@"; fi\nprint entered\n'
                         'if [[ "${1:-}" == signal || "${1:-}" == budget ]]; then\n'
                         '  trap \'print cleanup; if [[ "$1" == signal ]]; then read -r reply < "$ROOT_DIR/release"; fi; exit 143\' TERM\n'
                         'fi\n'
                         'if (( $# > 0 )) && [[ "$1" != artifact ]]; then read -r reply < "$ROOT_DIR/release"; fi\n')
        def line(process):
            return process.stdout.readline().strip() if select.select([process.stdout], [], [], 5)[0] else "timeout"
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered":
            raise ValueError("首个工作流取得锁")
        other_checkout = dict(environment, BIT101_LOCK_TEST_CHECKOUT=str(fixture / "other-checkout"))
        independent = subprocess.run(["zsh", str(worker), "artifact"], capture_output=True, text=True,
            env=other_checkout, timeout=5)
        if independent.returncode or independent.stdout.strip() != 'entered':
            raise ValueError('独立工作区的本机流程与真机流程并行')
        competing = subprocess.Popen(["zsh", str(worker), "artifact"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS='0.5'))
        processes.append(competing)
        output, _ = competing.communicate(timeout=5)
        if competing.returncode != 124 or 'entered' in output:
            raise ValueError('同一工作区的本机与真机流程共用固定产物锁')
        second = subprocess.Popen(["zsh", str(worker)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=other_checkout)
        processes.append(second)
        if not line(second).startswith("[等待]"):
            raise ValueError("竞争工作流在执行前排队")
        with release.open("w") as stream:
            stream.write("done\n")
        first.communicate(timeout=5)
        output, _ = second.communicate(timeout=5)
        if first.returncode or second.returncode or output.strip() != "entered":
            raise ValueError("锁释放后继续执行并复用父流程锁")
        first = subprocess.Popen(["zsh", str(worker), "signal"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered":
            raise ValueError("信号测试取得工作流锁")
        first.terminate()
        if line(first) != "cleanup":
            raise ValueError("外层信号传递到执行子进程")
        second = subprocess.Popen(["zsh", str(worker)], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=other_checkout)
        processes.append(second)
        if not line(second).startswith("[等待]"):
            raise ValueError("子进程清理期间保持工作流锁")
        with release.open("w") as stream:
            stream.write("done\n")
        first.communicate(timeout=5)
        output, _ = second.communicate(timeout=5)
        if first.returncode != 143 or second.returncode or output.strip() != "entered":
            raise ValueError("信号清理完成后释放锁并保持退出状态")
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered": raise ValueError("超时竞争测试取得锁")
        second = subprocess.Popen(["zsh", str(worker)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(other_checkout, BIT101_WORKFLOW_TIMEOUT_SECONDS="0.5"))
        processes.append(second)
        output, _ = second.communicate(timeout=5)
        if second.returncode != 124 or "[超时]" not in output or "entered" in output:
            raise ValueError("竞争工作流沿等待预算结束")
        with release.open("w") as stream: stream.write("done\n")
        first.communicate(timeout=5)
        timed = subprocess.Popen(["zsh", str(worker), "signal"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS="0.5"))
        processes.append(timed)
        if line(timed) != "entered": raise ValueError("执行超时测试取得锁")
        if not line(timed).startswith("[超时]") or line(timed) != "cleanup":
            raise ValueError("执行预算触发恢复清理")
        with release.open("w") as stream: stream.write("done\n")
        timed.communicate(timeout=5)
        recovered = subprocess.run(["zsh", str(worker)], capture_output=True, text=True, env=environment, timeout=5)
        if timed.returncode != 124 or recovered.returncode or recovered.stdout.strip() != "entered":
            raise ValueError("超时恢复完成后释放全局与工作区锁")
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment)
        processes.append(first)
        if line(first) != "entered": raise ValueError("共享预算测试取得锁")
        started = time.monotonic()
        second = subprocess.Popen(["zsh", str(worker), "budget"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS="1"))
        processes.append(second)
        if not line(second).startswith("[等待]"): raise ValueError("共享预算测试进入排队")
        time.sleep(0.4)
        with release.open("w") as stream: stream.write("done\n")
        first.communicate(timeout=5)
        output, _ = second.communicate(timeout=5)
        if second.returncode != 124 or "entered" not in output or "cleanup" not in output or time.monotonic() - started >= 1.3:
            raise ValueError("等待与执行沿同一截止时间消费预算")
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        findings.append(f"工作流锁自测：{error}")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
        shutil.rmtree(fixture, ignore_errors=True)
    return findings



def build_cache_boundary_findings() -> list[str]:
    "验证缓存合并、热文件保留、链接复用和清理边界。"

    source = (SCRIPT_ROOT / "script-support.sh").read_text()
    function = source.split("bit101_build_cache() {", 1)[1].split("\n}\n", 1)[0]
    block = re.search(r"<<'PY'\n(.*?)^PY$", function, re.MULTILINE | re.DOTALL)
    fixture = ROOT / ".build/static-audit/cache-self-test"
    findings: list[str] = []
    try:
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
                exec(compile(block[1], "cache-self-test", "exec"), {})
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
        if any(path.exists() for path in obsolete_paths) or obsolete_cloud_log.exists() or diagnostics.exists() or symbols.exists():
            findings.append("缓存自测：清理诊断与冗余符号产物")
        if not (products / "Release-iphonesimulator").exists():
            findings.append("缓存自测：保留模拟器增量产物")
        if debug_object.read_bytes() != content:
            findings.append("缓存自测：保留目标文件中的调试信息")
        if bundled_symbols.read_bytes() != content:
            findings.append("缓存自测：保留运行包内部的调试资源")
        if not (products / "Release-iphoneos/product").is_file() or not (result / "evidence").is_file():
            findings.append("缓存自测：保留增量构建及测试证据")
        if not (sdk / "referenced.pcm").is_file() or (sdk / "unused.pcm").exists():
            findings.append("缓存自测：依赖清单引用模块保留")
        (sdk / "incomplete-map.pcm").write_bytes(content)
        dependencies.write_text("{")
        with patch.object(sys, "argv", ["cache", str(fixture), "--maintenance"]), \
                patch.object(subprocess, "run", inspect_module), redirect_stdout(StringIO()):
            exec(compile(block[1], "cache-self-test", "exec"), {})
        if not (sdk / "incomplete-map.pcm").is_file():
            findings.append("缓存自测：依赖清单受损时保留缓存")
        for action, settings, expected in (
            ("build", [], []),
            ("test", ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"], ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"]),
            ("archive", [], []),
            ("build-for-testing", ["SWIFT_COMPILATION_MODE=wholemodule"], []),
            ("swift-build", [], None), ("swift-test", [], None),
        ):
            command = ["xcrun", "swift", action.removeprefix("swift-")] if expected is None else ["xcodebuild", action]
            arguments = ["cache", str(fixture), "build.log", "build", *command, *settings]
            with patch.object(sys, "argv", arguments), patch.object(subprocess, "run", inspect_module):
                try:
                    exec(compile(block[1], "cache-self-test", "exec"), {})
                except SystemExit as result:
                    if result.code != 0:
                        raise
            if expected is None:
                if not all(flag in builds[-1] for flag in ("-Xswiftc", "-warnings-as-errors", "-Xcc", "-Werror")):
                    findings.append("编译入口自测：SwiftPM 构建与测试的警告门禁")
                continue
            if [value for value in builds[-1] if value.startswith("DEBUG_INFORMATION_FORMAT=")] != expected:
                findings.append("缓存自测：开发 DWARF、显式符号设置和发行归档边界")
            expected_mode = [value for value in settings if value.startswith("SWIFT_COMPILATION_MODE=")]
            if [value for value in builds[-1] if value.startswith("SWIFT_COMPILATION_MODE=")] != expected_mode:
                findings.append("缓存自测：行为测试和归档沿工程默认编译模式，并保留显式设置")
            if not all(setting in builds[-1] for setting in ("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "GCC_TREAT_WARNINGS_AS_ERRORS=YES")):
                findings.append("编译入口自测：构建、测试与正式归档的警告门禁")
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def smoke_script_boundary_findings() -> list[str]:
    "通过故障注入验证恢复顺序、状态传播和失败证据保留。"

    source = (SCRIPT_ROOT / "run_icloud_cross_device_smoke.sh").read_text()
    findings: list[str] = []

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
'''
    cleanup = subprocess.run(["zsh", "-c", stub + phone_function + "\nrun_phone_test testCleanup"], capture_output=True, text=True)
    if cleanup.returncode or "DELETE -rf /smoke/test-results.xcresult" in cleanup.stdout or "-resultBundlePath" in cleanup.stdout:
        findings.append("Smoke 恢复自测失败：清理覆盖业务阶段结果包")
    business = subprocess.run(["zsh", "-c", stub + phone_function + "\nrun_phone_test testPhoneRoundTrip"], capture_output=True, text=True)
    if business.returncode or "-resultBundlePath" not in business.stdout:
        findings.append("Smoke 恢复自测失败：业务阶段结果包保存")

    worker = re.search(r"<<'PYWORKER'\n(.*?)^PYWORKER$", source, re.MULTILINE | re.DOTALL)
    handlers = {}
    child = type("Worker", (), {"pid": 42, "wait": lambda self: (handlers[signal.SIGTERM](signal.SIGTERM, None), -signal.SIGTERM)[1]})()
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

    finish = shell_function("finish_smoke").replace('"$ROOT_DIR/Scripts/build-install-device.sh"', "restore_normal_app")
    trap_registration = "\n".join(re.findall(r"(?m)^trap .+$", source))
    cases = ((7, 0, 0, 7), (7, 1, 0, 7), (7, 0, 1, 7), (0, 1, 0, 1), (0, 0, 1, 1), (0, 0, 0, 0), (130, 0, 0, 130), (143, 0, 0, 143))
    for initial, cleanup_status, restore_status, expected in cases:
        triggers = [f"exit {initial}", f"fail_command() {{ return {initial}; }}; fail_command"]
        if initial in (130, 143):
            triggers.append(f"kill -s {'INT' if initial == 130 else 'TERM'} $$")
        for trigger in triggers:
            harness = f'''
set -euo pipefail
PHONE_TESTS_STARTED=true
PHONE_CLEANED_UP=false
PHONE_TEST_PID=""
CLEANUP_ONLY=false
SUMMARY_PATH=/smoke/report.json
validation_group=icloud
DEVICE_ID=device
ROOT_DIR=/audit
BIT101_DEFER_APP_RESTORE=0
run_phone_test() {{ print cleanup; return {cleanup_status}; }}
restore_normal_app() {{ print restore; return {restore_status}; }}
report_result() {{ print report; }}
python3() {{ if [[ "$1" == - ]]; then cat >/dev/null; fi; }}
{finish}
{trap_registration}
{trigger}
'''
            result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
            if result.returncode != expected or not re.search(r"(?ms)^cleanup$.*^restore$.*^report$", result.stdout):
                findings.append(f"Smoke 恢复自测失败：状态 {initial}/{cleanup_status}/{restore_status}；{trigger}")

    network_source = (SCRIPT_ROOT / "release-network-smoke.sh").read_text()
    restore = shell_function("restore_normal_app", network_source).replace(
        '"$ROOT_DIR/Scripts/build-install-device.sh" >/dev/null 2>&1',
        "restore_release",
    )
    network_traps = "\n".join(line.strip() for line in network_source.splitlines() if line.strip().startswith("trap "))
    for initial, restore_status, expected, sms in ((7, 0, 7, "preflight"), (7, 1, 7, "preflight"), (0, 1, 1, "preflight"), (0, 0, 0, "preflight"), (0, 0, 0, "sms"), (7, 0, 7, "sms")):
        harness = f'''
set -euo pipefail
DEVICE_ID=device
ROOT_DIR=/audit
validation_group=network
validation_scope=full
community_started=false
SMOKE_SCOPE=all
SMS_MODE={sms}
BIT101_VALIDATION_SOURCE_DIGEST=network-inputs
SCHOOL_SMS_STARTED_DIGEST=school-inputs
BIT101_DEFER_APP_RESTORE=0
console_process=""
python3() {{ print -r -- "$BIT101_VALIDATION_SOURCE_DIGEST $*"; return 0; }}
restore_release() {{ print restore; return {restore_status}; }}
{restore}
{network_traps}
fail_command() {{ return {initial}; }}
fail_command
'''
        result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
        if result.returncode != expected or result.stdout.count("restore\n") != 1:
            findings.append(f"网络 Smoke 恢复自测失败：状态 {initial}/{restore_status}")
        if sms == "sms" and (f"network-inputs /audit/Scripts/validation_evidence.py record network {expected} full" not in result.stdout
                or f"school-inputs /audit/Scripts/validation_evidence.py record school-sms {expected} full" not in result.stdout):
            findings.append("全量短信验收恢复自测：两个验证范围共用结果并维持各自开始摘要")

    extended_source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    restore_condition = re.search(r'(?m)^if (\[\[.*\]\]); then\n  DEVICE_TEST_EXECUTION_STARTED=false', extended_source)[1]
    for mode, build, deferred, expected in (("all", "false", 0, True), ("schedule", "false", 0, True), ("infrastructure", "false", 0, True), ("login", "false", 0, True), ("extensions", "false", 0, True), ("release-runtime", "false", 0, True), ("ui", "false", 0, True), ("modules", "false", 0, False), ("catalyst", "false", 0, False), ("ui", "true", 0, False), ("all", "false", 1, False)):
        result = subprocess.run(["zsh", "-c", f'MODE={mode}; BUILD_ONLY={build}; BIT101_DEFER_APP_RESTORE={deferred}; if {restore_condition}; then print restore; fi'], capture_output=True, text=True)
        if result.returncode or (result.stdout.strip() == "restore") != expected:
            findings.append(f"测试恢复入口自测失败：{mode}/{build}/{deferred}")
    for name in ("finish_verification", "restore_release_app"):
        recovery = shell_function(name, extended_source).replace(
            '"$ROOT_DIR/Scripts/build-install-device.sh"', "restore_release",
        )
        registration = re.search(rf"(?m)^[ \t]*trap {name} [^\n]+(?:\n[ \t]*trap [^\n]+)*", extended_source)
        if registration is None:
            findings.append(f"测试恢复自测需要 {name} 错误钩子")
            continue
        for initial, restore_status, expected in ((7, 0, 7), (7, 1, 7), (0, 1, 1), (0, 0, 0), (130, 0, 130), (143, 0, 143)):
            triggers = [f"exit {initial}", f"fail_command() {{ return {initial}; }}; fail_command"]
            if initial in (130, 143):
                triggers.append(f"kill -s {'INT' if initial == 130 else 'TERM'} $$")
            for trigger in triggers:
                harness = f'''
set -euo pipefail
verification_needs_device=true
DEVICE_TEST_EXECUTION_STARTED=true
WORKFLOW_STARTED_SECONDS=$SECONDS
DERIVED_ROOT=/dev/null
ROOT_DIR=/audit
validation_group=ui
validation_scope=full
python3() {{ return 0; }}
restore_release() {{ print restore; return {restore_status}; }}
{recovery}
{registration[0]}
{trigger}
'''
                result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
                if result.returncode != expected or result.stdout.count("restore\n") != 1:
                    findings.append(f"测试恢复自测失败：{name}；状态 {initial}/{restore_status}；{trigger}")
        if name == "restore_release_app":
            for initial in (1, 130, 143):
                harness = f'''
set -euo pipefail
DEVICE_TEST_EXECUTION_STARTED=false
WORKFLOW_STARTED_SECONDS=$SECONDS
DERIVED_ROOT=/dev/null
ROOT_DIR=/audit
validation_group=ui
validation_scope=full
python3() {{ return 0; }}
restore_release() {{ print restore; return 0; }}
{recovery}
{registration[0]}
exit {initial}
'''
                result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
                if result.returncode != initial or "restore\n" in result.stdout:
                    findings.append(f"UI 编译失败恢复自测失败：状态 {initial}")

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
    def result_response(*args, **kwargs):
        result = summary if sys.argv[3] == "testPhoneRoundTrip" else completed
        return subprocess.CompletedProcess([], 0, json.dumps(result))
    with patch.object(Path, "is_file", lambda path: str(path) in state), patch.object(Path, "is_dir", return_value=True), \
         patch.object(Path, "glob", side_effect=lambda *args: iter([Path("/smoke/generated.xcresult")])), \
         patch.object(Path, "exists", return_value=False), patch.object(shutil, "rmtree") as remove_bundle, \
         patch.object(shutil, "move") as retain_bundle, \
         patch.object(Path, "read_text", read), \
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
                or report.get("cleanup", {}).get("passedTests") != 1 or result_tool.call_count != 2:
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
    return findings
