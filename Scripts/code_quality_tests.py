"""Executable checks for workflow dispatch, cache ownership and audit rules."""
from __future__ import annotations

from pathlib import Path
import json, os, re, subprocess, sys, shutil, signal
from contextlib import nullcontext, redirect_stdout
from io import BytesIO, StringIO
from unittest.mock import Mock, patch
from swift_source_index import swift_syntax_index_sources
from ui_rule_tests import device_discovery_boundary_findings, explanatory_text_boundary_findings, school_lifecycle_boundary_findings

from code_quality_rules import (
    ROOT, SCRIPT_ROOT, swift_files, ast_has_view_request, ci_trigger_shell_self_test, cross_file_view_request_self_test,
    cancellation_findings, client_source_findings, extension_dependency_findings, mask_literals_and_comments,
    owner_has_call, uses_application_support_storage, view_request_matches, source_findings,
)


def checker_boundary_findings() -> list[str]:
    findings: list[str] = []
    from validate_versions import app_store_request_self_test
    findings.extend(app_store_request_self_test())
    from validation_evidence import community_recovery_self_test
    findings.extend(community_recovery_self_test())
    findings.extend(script_output_boundary_findings())
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
    tail = re.sub(r'  line_count="[^\n]+"', "  line_count=0", tail)
    harness = r'''
set -euo pipefail
LOG_DIR=/audit
ROOT_DIR=/audit
AUDIT_STARTED=$SECONDS
cat() { :; }
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


def worker_boundary_findings() -> list[str]:
    "通过 Workers 本地 runtime 验证跨域预检、并发配额及 Smoke 约束。"
    script = r'''
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = require("miniflare");
(async () => {
  const config = JSON.parse(fs.readFileSync("../ErrorReportWorker/wrangler.jsonc", "utf8"));
  assert(config.durable_objects.bindings.some(binding => binding.name === "REPORT_QUOTA" && binding.class_name === "ReportQuota"));
  assert(config.migrations.some(migration => migration.new_sqlite_classes.includes("ReportQuota")));
  const fixture = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8") + `
export class QuotaFixture extends ReportQuota {
  async fetch(request) {
    if (new URL(request.url).pathname === "/seed") {
      this.ctx.storage.kv.put(new URL(request.url).searchParams.get("kind") || "daily", await request.json());
      return new Response(null, { status: 204 });
    }
    if (new URL(request.url).pathname === "/inspect") return Response.json(this.ctx.storage.kv.get(new URL(request.url).searchParams.get("kind") || "daily"));
    return super.fetch(request);
  }
}`;
  const mf = new Miniflare(convertV4MiniflareOptions({ name: "worker-fixture", modules: true, script: fixture,
    compatibilityDate: config.compatibility_date, kvNamespaces: ["ERROR_REPORTS"],
    durableObjects: { REPORT_QUOTA: { className: "QuotaFixture", useSQLite: true } },
    log: new Log(LogLevel.NONE) }));
  try {
    const preflight = await mf.dispatchFetch("https://feedback.invalid/api/error-reports", { method: "OPTIONS" });
    assert.equal(preflight.status, 204);
    assert.equal(await preflight.text(), "");
    assert.equal(preflight.headers.get("Access-Control-Allow-Origin"), "*");
    const namespace = await mf.getDurableObjectNamespace("REPORT_QUOTA");
    const quota = namespace.get(namespace.idFromName("daily"));
    const today = new Date().toISOString().slice(0, 10);
    const seed = (value, kind = "daily") => quota.fetch(`https://quota/seed?kind=${kind}`, { method: "POST", body: JSON.stringify(value) });
    const inspect = async (kind = "daily") => (await quota.fetch(`https://quota/inspect?kind=${kind}`)).json();
    const send = (value, ip = "192.0.2.1") => mf.dispatchFetch("https://feedback.invalid/api/error-reports", {
      method: "POST", headers: { "CF-Connecting-IP": ip, "x-bit101-network-smoke": "1" }, body: JSON.stringify(value) });
    await seed({ day: today, count: 0 });
    for (const value of [{}, [], { mode: "unknown" }, { mode: "sanitized" }, { mode: "suggestion", comment: " " },
                         { mode: "network-smoke", runID: "" }, { mode: "network-smoke", runID: "wrong/value" },
                         ...[{}, [null], [1], [[]]].map(diagnostics => ({ mode: "suggestion", comment: "fixture", diagnostics }))]) {
      assert.equal((await send(value)).status, 400);
    }
    for (const contentType of [[], {}, 5]) {
      assert.equal((await send({ mode: "suggestion", comment: "fixture", attachments: [{ data: "QQ==", contentType }] })).status, 400);
    }
    const deep = await mf.dispatchFetch("https://feedback.invalid/api/error-reports", { method: "POST", body: '{"mode":"suggestion","comment":"fixture","extra":' + '['.repeat(5000) + 'null' + ']'.repeat(5000) + '}' });
    assert.equal(deep.status, 400);
    assert.equal((await send({ mode: "suggestion", comment: "x".repeat(2 * 1024 * 1024) })).status, 413);
    assert.equal((await inspect()).count, 0);
    for (const data of ["", "==", "AB==", "AAAA=", "AA A", "AAAA!", "A==="]) {
      assert.equal((await send({ mode: "network-smoke", runID: "invalid-base64", attachments: [{ data }] })).status, 400);
    }
    assert.equal((await send({ mode: "network-smoke", runID: "maximum",
      attachments: Array.from({ length: 6 }, () => ({ data: Buffer.alloc(2 * 1024 * 1024).toString("base64") })) })).status, 201);
    const kv = await mf.getKVNamespace("ERROR_REPORTS");
    for (const title of ["x".repeat(1100), "\u0000".repeat(1100), "🧪".repeat(1100)]) {
      const response = await send({ mode: "sanitized", errorTitle: title, errorMessage: "fixture",
        appVersion: "\u0000".repeat(1100), build: { toString: null } });
      assert.equal(response.status, 201);
      const id = (await response.json()).id;
      const row = (await kv.list()).keys.find(key => key.name.endsWith(id));
      assert(Buffer.byteLength(JSON.stringify(row.metadata)) <= 1024);
      assert.equal(JSON.parse(await kv.get(row.name)).report.errorTitle, title);
    }
    const source = Object.keys((await inspect()).sources)[0];
    assert(/^[a-f0-9]{64}$/.test(source));
    await seed({ day: today, count: 99, sources: { [source]: 99 } });
    const concurrent = () => Promise.all(Array.from({ length: 5 }, () => send({ mode: "suggestion", comment: "fixture" })));
    const sourceResponses = await concurrent();
    assert.equal(sourceResponses.filter(response => response.status === 201).length, 1);
    assert.equal(sourceResponses.filter(response => response.status === 429).length, 4);
    assert.equal((await sourceResponses.find(response => response.status === 429).json()).error, "source_limit_reached");
    assert.equal((await send({ mode: "suggestion", comment: "fixture" }, "192.0.2.2")).status, 201);
    await seed({ day: today, count: 999 });
    const responses = await concurrent();
    assert.equal(responses.filter(response => response.status === 201).length, 1);
    assert.equal(responses.filter(response => response.status === 429).length, 4);
    assert.equal((await inspect()).count, 1000);
    const nextDay = await send({ mode: "network-smoke", runID: "fixture" });
    assert.equal(nextDay.status, 201);
    assert.deepEqual(await nextDay.json(), { ok: true, temporaryRecordRemoved: true, quotaReserved: true });
    await seed({ day: today, count: 1000 }, "smoke");
    assert.equal((await send({ mode: "network-smoke", runID: "fixture" })).status, 429);
    await seed({ day: "2000-01-01", count: 1000 });
    assert.equal((await send({ mode: "suggestion", comment: "fixture" })).status, 201);
    assert.equal((await inspect()).count, 1);
    assert((await kv.list()).keys.every(key => key.name.startsWith("report:")));
  } finally { await mf.dispose(); }
  const bodySource = fs.readFileSync("../ErrorReportWorker/worker.js", "utf8")
    .replace('import { DurableObject } from "cloudflare:workers";', 'class DurableObject {}') + "\nexport { readReportBody, MAX_BODY_BYTES, forceRedact, PROTECTED_NAMES };";
  const { default: feedback, readReportBody, MAX_BODY_BYTES, forceRedact, PROTECTED_NAMES } = await import("data:text/javascript;base64," + Buffer.from(bodySource).toString("base64"));
  let notification, saved = 0;
  const accepted = await feedback.fetch(new Request("https://feedback.invalid/api/error-reports", { method: "POST", headers: { "CF-Connecting-IP": "192.0.2.1" }, body: JSON.stringify({ mode: "suggestion", comment: "fixture" }) }), {
    ERROR_REPORTS: { async put() { saved += 1; } }, REPORT_QUOTA: { idFromName() {}, get() { return { async fetch() { return Response.json({ allowed: true }); } }; } },
    REPORT_EMAIL: { send() { throw new Error("offline"); } }
  }, { waitUntil(task) { notification = task; } });
  assert.equal(accepted.status, 201); await notification; assert.equal(saved, 1);
  const appNames = JSON.parse("[" + fs.readFileSync("../../BIT101-iOS/Shared/Client/ErrorReportSupport.swift", "utf8").match(/protectedNames = \[([\s\S]*?)\]/)[1] + "]");
  assert.deepEqual(PROTECTED_NAMES, appNames);
  for (const value of ["https://example.invalid/?%70assword=TEST_ONLY_SECRET", "https://example.invalid/?%2570assword=TEST_ONLY_SECRET", "https://example.invalid/?service=https%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "https://example.invalid/?service=HTTPS%3A%2F%2Fschool.invalid%2F%3Fticket%3DTEST_ONLY_SECRET", "https://fixture-user:TEST_ONLY_SECRET@example.invalid/", "https://example.invalid/#%74oken=TEST_ONLY_SECRET", "https://example.invalid/#%2574oken=TEST_ONLY_SECRET", "https://example.invalid/#%74oken=TEST_ONLY_SECRET&note=%bad"]) {
    assert(!decodeURIComponent(forceRedact(value)).includes("TEST_ONLY_SECRET")); assert.equal(forceRedact("https://example.invalid/#section"), "https://example.invalid/#section");
  }
  for (const value of ["Authorization: Bearer TEST_ONLY_SECRET", "Authorization: Basic TEST_ONLY_SECRET", "Cookie: first=TEST_ONLY_SECRET; second=TEST_ONLY_SECRET", '{"password":"TEST_ONLY_\\\"SECRET"}']) assert(!forceRedact(value).includes("TEST_ONLY") && !forceRedact(value).includes("SECRET"));
  for (const value of ['<input id="login-page-flowkey" name="execution" value="SENSITIVE_VALUE">', '<input id="login-croypto" value="SENSITIVE_VALUE">', '<input value="SENSITIVE_VALUE>TAIL_VALUE" name="execution">', '<input name="execution" value="SENSITIVE_VALUE', '<textarea name="password">SENSITIVE_VALUE</textarea>', '<textarea name="password">SENSITIVE_VALUE', '{"access_token":{"value":"SENSITIVE_VALUE"},"status":"available"}', '{"captcha_payload":["SENSITIVE_VALUE"]}', '{"cookie_str":{"value":"SENSITIVE_VALUE']) {
    const masked = forceRedact(value); assert(!masked.includes("SENSITIVE_VALUE") && !masked.includes("TAIL_VALUE") && masked.includes("[REDACTED]"));
    if (value.includes("available")) assert(masked.includes("available"));
  }
  const emergency = (await import("data:text/javascript;base64," + Buffer.from(fs.readFileSync("src/index.js", "utf8")).toString("base64"))).default;
  const notice = { schema_version: 1, enabled: true, notice_id: "fixture", maximum_affected_build: 100, title: "fixture", message: "fixture" };
  for (const [value, status] of [[null, 503], [{ enabled: false }, 503], [{ schema_version: 1, enabled: false }, 200], [new Error("offline"), 503], [notice, 200], [{ ...notice, title: " " }, 503], [{ ...notice, maximum_affected_build: 1e20 }, 503]]) {
    const response = await emergency.fetch(new Request("https://emergency.invalid/emergency-update.json"), { EMERGENCY_CONFIG: { async get() { if (value instanceof Error) throw value; return value; } } });
    assert.equal(response.status, status);
  }
  for (const args of [["1", " ", "fixture"], ["1", "fixture", " "], ["9007199254740992", "fixture", "fixture"]]) {
    assert.equal(require("node:child_process").spawnSync("zsh", ["Scripts/publish-emergency-update.sh", ...args]).status, 64);
  }
  let chunks = 0, cancelled = false;
  const stream = new ReadableStream({
    pull(controller) { chunks += 1; controller.enqueue(new Uint8Array(1024 * 1024)); },
    cancel() { cancelled = true; }
  });
  assert.equal(await readReportBody(new Request("https://feedback.invalid", { method: "POST", body: stream, duplex: "half" })), null);
  assert(cancelled && chunks <= Math.floor(MAX_BODY_BYTES / (1024 * 1024)) + 2);
  const utf8 = new TextEncoder().encode('文章😀');
  const split = new ReadableStream({ start(controller) {
    for (const byte of utf8) controller.enqueue(new Uint8Array([byte]));
    controller.close();
  }});
  assert.equal(await readReportBody(new Request("https://feedback.invalid", { method: "POST", body: split, duplex: "half" })), '文章😀');
  const source = fs.readFileSync("../OpenWorker/worker.js", "utf8");
  const worker = (await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"))).default;
  const aasa = await (await worker.fetch(new Request("https://open.invalid/.well-known/apple-app-site-association"))).json();
  assert.deepEqual(aasa.applinks.details[0].paths, ["/gallery/*", "/course/*", "/paper/*"]);
  for (const route of ["gallery", "course", "paper"]) {
    const response = await worker.fetch(new Request(`https://open.invalid/${route}/42`));
    assert.equal(response.status, 200);
    const html = await response.text();
    assert(html.includes(`href="bit101://${route}/42"`) && html.includes(`href="https://bit101.cn/${route}/42"`));
  }
  for (const [status, type, expected] of [[404, "text/html", 404], [200, "text/html", 502], [200, "image/jpeg", 200], [200, "image/png", 200]]) {
    global.fetch = async url => String(url).startsWith("https://itunes.apple.com/")
      ? Response.json({ results: [{ trackId: 6761147125, artworkUrl512: "https://is1-ssl.mzstatic.com/current.jpg" }] })
      : new Response(type === "image/png" ? Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ9sAAAAASUVORK5CYII=", "base64") : "fixture", { status, headers: { "Content-Type": type } });
    const response = await worker.fetch(new Request("https://open.invalid/share-icon.jpg"));
    assert.equal(response.status, expected);
    if (expected !== 200) assert.equal(response.headers.get("Cache-Control"), "no-store"); else assert.equal(response.headers.get("Content-Type"), type);
  }
  for (const results of [[], [{ trackId: 1, artworkUrl512: "https://is1-ssl.mzstatic.com/icon.jpg" }],
      [{ trackId: 6761147125, artworkUrl512: "https://foreign.invalid/icon.jpg" }]]) {
    let calls = 0;
    global.fetch = async () => { calls += 1; return Response.json({ results }); };
    assert.equal((await worker.fetch(new Request("https://open.invalid/share-icon.jpg"))).status, 502);
    assert.equal(calls, 1);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    result = subprocess.run(["node", "-"], input=script, capture_output=True, text=True,
                            cwd=ROOT / "Cloudflare/EmergencyUpdateWorker", timeout=60)
    return [f"Worker 行为回归：{result.stderr[:600]}"] if result.returncode else []


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
    def fetch(arguments, **_):
        calls.append(arguments)
        result = subprocess.CompletedProcess(arguments, 0, json.dumps(reports[arguments[4]]), "")
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
    except (AssertionError, OSError) as error:
        findings.append(f"反馈收件箱自测：{error}")
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def workflow_lock_boundary_findings() -> list[str]:
    "验证竞争工作流排队及父子流程锁复用。"
    import select
    import shlex

    fixture = ROOT / ".build/static-audit/workflow-lock-self-test"
    worker = fixture / "worker.sh"
    release = fixture / "release"
    processes = []
    findings = []
    environment = dict(os.environ)
    environment.pop("BIT101_EXTENDED_TESTS_LOCK_HELD", None)
    try:
        shutil.rmtree(fixture, ignore_errors=True)
        fixture.mkdir(parents=True, exist_ok=True); os.mkfifo(release)
        worker.write_text(f'ROOT_DIR={shlex.quote(str(fixture))}\n'
                         f'source {shlex.quote(str(SCRIPT_ROOT / "script-support.sh"))}\n'
                         'bit101_acquire_workflow_lock "$0" "$@"\nprint entered\n'
                         'if [[ "${1:-}" == signal ]]; then\n'
                         '  trap \'print cleanup; read -r reply < "$ROOT_DIR/release"; exit 143\' TERM\n'
                         'fi\n'
                         'if (( $# > 0 )); then read -r reply < "$ROOT_DIR/release"; fi\n')
        def line(process):
            return process.stdout.readline().strip() if select.select([process.stdout], [], [], 5)[0] else "timeout"
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered":
            raise ValueError("首个工作流取得锁")
        second = subprocess.Popen(["zsh", str(worker)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
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
                                  stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(second)
        if not line(second).startswith("[等待]"):
            raise ValueError("子进程清理期间保持工作流锁")
        with release.open("w") as stream:
            stream.write("done\n")
        first.communicate(timeout=5)
        output, _ = second.communicate(timeout=5)
        if first.returncode != 143 or second.returncode or output.strip() != "entered":
            raise ValueError("信号清理完成后释放锁并保持退出状态")
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        findings.append(f"工作流锁自测：{error}")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def script_command_boundary_findings() -> list[str]:
    "通过内存替身验证自动选机、操作分派、筛选合并及参数拒绝。"
    import shlex
    import plistlib

    findings = []
    support = SCRIPT_ROOT / "script-support.sh"
    frame = r'''
bit101_require_device() {
  print DEVICE
  export BIT101_XCODE_DEVICE_ID=udid BIT101_DEVICETCL_DEVICE_ID=core
  export BIT101_DEVICE_TRANSPORT=wired BIT101_DEVICE_NAME=phone
}
bit101_build_cache() { print CACHE; }
bit101_acquire_workflow_lock() { print WORKFLOW_LOCK; }
bit101_acquire_script_lock() { :; }
mkdir() { :; }
rm() { :; }
ditto() { :; }
open() { :; }
pgrep() { return 1; }
trap() { :; }
xcrun() {
  if [[ "$*" == *lockState* ]]; then print '{"result":{"isLocked":false}}';
  else print -ru2 -- "TOOL $*"; fi
}
'''
    export_source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
    export_source = export_source[:export_source.index('if [[ "${1:-}" == -h')]
    export_source = export_source.replace('  python3 - "$DERIVED_ROOT/test-results.xcresult"', '  exit 86\n  python3 - "$DERIVED_ROOT/test-results.xcresult"')
    for arguments in (["report", "json"], ["diagnostics"], ["activities", "test"], ["screenshot", "test"]):
        result = subprocess.run(["zsh", "-c", export_source, str(SCRIPT_ROOT / "run-extended-tests.sh"), *arguments],
                                env=dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1"), capture_output=True, text=True)
        if result.returncode != 86 or result.stdout.count("WORKFLOW_LOCK") != 1:
            findings.append(f"固定产物导出自测：{arguments[0]} 取得工作流锁")
    ui_test_count = sum(
        len(re.findall(r"^\s*(?:@objc )?func test\w+\(", path.read_text(), re.MULTILINE))
        for path in (ROOT / "BIT101-iOSUITests").glob("*.swift")
    )
    cases = (
        ("build-install-device.sh", [], 0, "platform=iOS,id=udid", "DEVICE"),
        ("build-install-device.sh", ["build"], 0, "generic/platform=iOS", ""),
        ("build-install-device.sh", ["archive"], 0, "xcodebuild archive", ""),
        ("build-install-device.sh", ["mac"], 0, "variant=Mac Catalyst", ""),
        ("build-install-device.sh", ["info"], 0, "phone", "DEVICE"),
        ("build-install-device.sh", ["screenshot"], 0, "截图已保存", "DEVICE"),
        ("run-extended-tests.sh", ["build"], 0, "build-for-testing", ""),
        ("run-extended-tests.sh", ["build", "ui"], 0, "BIT101-iOS-UIAutomation", ""),
        ("run-extended-tests.sh", ["build", "network-smoke"], 0, "RELEASE_NETWORK_SMOKE", ""),
        ("run-extended-tests.sh", ["build", "icloud-smoke"], 0, "ICLOUD_CROSS_DEVICE_SMOKE", ""),
        ("run-extended-tests.sh", ["build", "modules"], 0, "swift build", ""),
        ("run-extended-tests.sh", ["build", "catalyst"], 0, "variant=Mac Catalyst", ""),
        ("run-extended-tests.sh", ["ui", "About", "About"], 86, "LoginAndScheduleUITests/testAboutLicenseUpdateAndResetConfirmation", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "Schedule"], 86, "testScheduleWeekButtonsAndSectionSwipes", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "DDLEditor"], 86, "InteractionCoverageUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "test"], 86, f"{ui_test_count} 项 UI 用例", "DEVICE"),
        ("run-extended-tests.sh", ["modules"], 86, "swift test", ""),
        ("run-extended-tests.sh", [], 86, "-only-testing:BIT101-iOSTests", "DEVICE"),
        ("run-extended-tests.sh", ["NetworkClientTests"], 86, "BIT101-iOSTests/NetworkClientTests", "DEVICE"),
        ("run-extended-tests.sh", ["cache"], 0, "CACHE", ""),
        ("release-network-smoke.sh", ["ddl"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("run_icloud_cross_device_smoke.sh", [], 86, "ICLOUD_CROSS_DEVICE_SMOKE", "DEVICE"), ("run_icloud_cross_device_smoke.sh", ["report"], 0, "REPORT", ""),
    )
    environment = dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1", BIT101_DEFER_APP_RESTORE="1")
    for filename, arguments in (("build-install-device.sh", ["archive"]), ("run-extended-tests.sh", ["build"]),
                                ("release-network-smoke.sh", ["ddl"]), ("run_icloud_cross_device_smoke.sh", []),
                                ("run-static-audit.sh", [])):
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"', frame)
        failure = frame + '''\npython3() {
  if [[ "$*" == *"validation_evidence.py digest"* ]]; then return 79; fi
  return 0
}\n'''
        result = subprocess.run(["zsh", "-c", failure + source, str(path), *arguments],
                                env=dict(environment, BIT101_STATIC_AUDIT_LOCK_HELD="1", SWIFT_FRONTEND="/usr/bin/true"),
                                capture_output=True, text=True)
        if result.returncode != 79:
            findings.append(f"源码摘要失败应在工作流启动前退出：{filename}")
    for filename, arguments, expected, marker, device in cases:
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"',
                                         f"source {shlex.quote(str(support))}\n" + frame)
        stop = "exit 86" if expected == 86 else "return 0"
        source = source.replace(frame, frame + f'\nbit101_run_logged() {{ print -r -- "BUILD $*"; {stop}; }}\n')
        source = re.sub(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$",
                        'ui_test_plan() { print -r -- /audit/ui.xctestrun; }', source, count=1)
        source = re.sub(r"(?ms)^report_result\(\) \{\n.*?^\}$", 'report_result() { print REPORT; }', source, count=1)
        result = subprocess.run(["zsh", "-c", source, str(path), *arguments], env=environment,
                                capture_output=True, text=True)
        if result.returncode != expected or marker not in result.stdout or ("DEVICE\n" in result.stdout) != bool(device):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 分派及自动选机；{result.stderr[:160]}")
        needs_lock = arguments not in (["info"], ["cache"])
        if ("WORKFLOW_LOCK\n" in result.stdout) != needs_lock:
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 取得工作流锁")
        if filename == "run-extended-tests.sh" and arguments[:2] == ["ui", "About"] and result.stdout.count(marker) != 1:
            findings.append("命令自测：重复 UI 关键词合并为一个用例")
        if arguments == ["ui", "Schedule"] and "testAboutLicense" in result.stdout:
            findings.append("命令自测：方法关键词按实际流程筛选")
        if arguments == ["ui", "test"] and result.stdout.count("-only-testing:BIT101-iOSUITests/") != ui_test_count:
            findings.append("命令自测：两个测试类的全部交互用例可通过关键词选择")
    for filename, arguments in (
        ("build-install-device.sh", ["build", "extra"]),
        ("run-extended-tests.sh", ["ui", "unmatched-keyword"]),
        ("run-extended-tests.sh", ["build", "unknown"]),
        ("run-extended-tests.sh", ["verify", "unknown"]),
        ("release-network-smoke.sh", ["unknown"]),
        ("run_icloud_cross_device_smoke.sh", ["unknown"]),
    ):
        result = subprocess.run(["zsh", str(SCRIPT_ROOT / filename), *arguments], capture_output=True, text=True)
        if result.returncode != 64:
            findings.append(f"命令自测：{filename} 错误参数在执行前拒绝")

    plan_function = re.search(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$", (SCRIPT_ROOT / "run-extended-tests.sh").read_text())
    plan_source = re.search(r"<<'PY'\n(.*?)^PY$", plan_function[0], re.MULTILINE | re.DOTALL)[1]
    older, newer = Mock(), Mock()
    older.stat.return_value.st_mtime = 1
    newer.stat.return_value.st_mtime = 2
    selected = StringIO()
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), \
         patch.object(Path, "glob", return_value=[older, newer]), redirect_stdout(selected):
        exec(compile(plan_source, "ui-plan-self-test", "exec"), {})
    if older.open.called or newer.open.called or selected.getvalue().strip() != str(newer):
        findings.append("UI 计划自测：最新构建选择及默认诊断配置保留")
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), patch.object(Path, "glob", return_value=[]):
        try:
            exec(compile(plan_source, "ui-plan-empty-self-test", "exec"), {})
        except SystemExit as error:
            if ".xctestrun" not in str(error):
                findings.append("UI 计划自测：冷缓存缺少运行配置时的诊断")
        else:
            findings.append("UI 计划自测：运行配置完整性检查")

    findings.extend(device_discovery_boundary_findings())
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
        if (stats / "iphonesimulator.sdkstatcache").exists() or not (stats / "iphoneos.sdkstatcache").exists():
            findings.append("缓存自测：SDK 统计缓存的平台归属")
        if (old / "warm").read_text() != "retain warm module" or (old / "unique").read_text() != "preserve unique module":
            findings.append("缓存自测：保留热模块及唯一模块")
        if module.read_bytes() != content or module.stat().st_mtime_ns != modified:
            findings.append("缓存自测：合并保留内容和修改时间")
        if any((shared / name).exists() for name in ("simulator", "watch-simulator")):
            findings.append("缓存自测：停用平台的隐式模块清理")
        if any((shared / name / f"{name}.pcm").read_bytes() != content for name in ("phone", "mac", "unreadable")):
            findings.append("缓存自测：保留真机、Mac 及平台归属待核对的模块")
        if any(path.exists() for path in obsolete_paths) or obsolete_cloud_log.exists() or diagnostics.exists() or symbols.exists() or (products / "Release-iphonesimulator").exists():
            findings.append("缓存自测：清理诊断与失效平台产物")
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
            ("build", [], ["DEBUG_INFORMATION_FORMAT=dwarf"]),
            ("test", ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"], ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"]),
            ("archive", [], []),
            ("build-for-testing", ["SWIFT_COMPILATION_MODE=wholemodule"], ["DEBUG_INFORMATION_FORMAT=dwarf"]),
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
            expected_mode = [] if action == "archive" else ["SWIFT_COMPILATION_MODE=wholemodule" if settings == ["SWIFT_COMPILATION_MODE=wholemodule"] else "SWIFT_COMPILATION_MODE=singlefile"]
            if [value for value in builds[-1] if value.startswith("SWIFT_COMPILATION_MODE=")] != expected_mode:
                findings.append("缓存自测：开发增量编译、显式编译模式和发行归档边界")
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

    phone_function = shell_function("run_phone_test")
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
    if cleanup.returncode or "DELETE" in cleanup.stdout or "-resultBundlePath" in cleanup.stdout:
        findings.append("Smoke 恢复自测失败：清理覆盖业务阶段结果包")
    business = subprocess.run(["zsh", "-c", stub + phone_function + "\nrun_phone_test testPhoneRoundTrip"], capture_output=True, text=True)
    if business.returncode or "-resultBundlePath" not in business.stdout:
        findings.append("Smoke 恢复自测失败：业务阶段结果包保存")

    worker = re.search(r"<<'PYWORKER'\n(.*?)^PYWORKER$", source, re.MULTILINE | re.DOTALL)
    handlers = {}
    child = type("Worker", (), {"pid": 42, "wait": lambda self: (handlers[signal.SIGTERM](signal.SIGTERM, None), -signal.SIGTERM)[1]})()
    with patch.object(sys, "argv", ["worker", source, "/root", "/derived", "/bundle", "/report", "device", "suite"]), \
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
    for initial, restore_status, expected in ((7, 0, 7), (7, 1, 7), (0, 1, 1), (0, 0, 0)):
        harness = f'''
set -euo pipefail
DEVICE_ID=device
ROOT_DIR=/audit
validation_group=network
validation_scope=full
community_started=false
SMOKE_SCOPE=all
BIT101_DEFER_APP_RESTORE=0
console_process=""
python3() {{ return 0; }}
restore_release() {{ print restore; return {restore_status}; }}
{restore}
{network_traps}
fail_command() {{ return {initial}; }}
fail_command
'''
        result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
        if result.returncode != expected or result.stdout.count("restore\n") != 1:
            findings.append(f"网络 Smoke 恢复自测失败：状态 {initial}/{restore_status}")

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

    match = re.search(r"(?ms)^record_result\(\).*?<<'PY'\n(.*?)^PY$", source)
    if match is None:
        return [*findings, "Smoke 自测需要阶段结果记录器"]
    state = {}
    def read(path: Path, *args, **kwargs) -> str:
        return state.get(str(path), "Test case 'ICloudCrossDeviceSmokeTests.testCleanup()' passed on 'device' (0.01 seconds)\n")
    def write(path: Path, value: str, *args, **kwargs) -> int:
        state[str(path)] = value
        return len(value)
    summary = {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0,
               "testFailures": [{"failureText": "business failure"}]}
    with patch.object(Path, "is_file", lambda path: str(path) in state), patch.object(Path, "is_dir", return_value=True), \
         patch.object(Path, "read_text", read), patch.object(Path, "write_text", write), \
         patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(summary))) as result_tool:
        for stage, process_status, expected in (("testPhoneRoundTrip", "65", 65), ("testCleanup", "0", 0)):
            with patch.object(sys, "argv", ["record", "/smoke/report.json", "/smoke/results.xcresult", stage, process_status, "/smoke/log"]), redirect_stdout(StringIO()):
                try:
                    exec(compile(match[1], "smoke-stage-record", "exec"), {})
                except SystemExit as error:
                    if error.code != expected:
                        findings.append("Smoke 结果自测失败：阶段状态码传播")
        report = json.loads(state["/smoke/report.json"])
        if report["stages"][0].get("testFailures") != summary["testFailures"] or len(report["stages"]) != 1 \
                or report.get("cleanup", {}).get("passedTests") != 1 or result_tool.call_count != 1:
            findings.append("Smoke 结果自测失败：失败阶段与清理阶段的证据归属")
        for log, expected in (("", 1), ("skipped", 1), ("failed", 1), ("passed", 0)):
            state["/smoke/log"] = f"Test case 'ICloudCrossDeviceSmokeTests.testCleanup()' {log} on 'device' (0.01 seconds)\n" if log else ""
            with patch.object(sys, "argv", ["record", "/smoke/report.json", "/smoke/results.xcresult", "testCleanup", "0", "/smoke/log"]), redirect_stdout(StringIO()):
                try:
                    exec(compile(match[1], "smoke-cleanup-record", "exec"), {})
                except SystemExit as error:
                    if error.code != expected:
                        findings.append(f"Smoke 清理验收自测失败：{log or '零用例'}")
    return findings
