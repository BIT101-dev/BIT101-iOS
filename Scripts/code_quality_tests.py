"""Executable checks for workflow dispatch, cache ownership and audit rules."""
from __future__ import annotations

from pathlib import Path
import json
import os
import re
import subprocess
import sys

from code_quality_rules import (
    FORCE_UNWRAP, ROOT, SCRIPT_ROOT, ast_has_view_request, ci_wiring_findings,
    client_source_findings, extension_dependency_findings, mask_literals_and_comments,
    owner_has_call, uses_application_support_storage, view_request_matches,
)


def checker_boundary_findings() -> list[str]:
    findings: list[str] = []
    findings.extend(script_output_boundary_findings())
    unwrap_source = '''
// value!
let example = "value!"
let unwrapped = value!
let comparison = left != right
'''
    masked_unwrap_source = mask_literals_and_comments(unwrap_source)
    if len(FORCE_UNWRAP.findall(masked_unwrap_source)) != 1:
        findings.append("代码质量规则边界自检失败：强制解包与比较运算区分")

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
    findings.extend(smoke_script_boundary_findings())
    workflow_source = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    detached_release = workflow_source.replace("needs: static-audit", "needs: []", 1)
    if not any("必须依赖静态审计" in item for item in ci_wiring_findings(detached_release)):
        findings.append("代码质量规则边界自检失败：Release Job 与静态审计依赖识别")
    misplaced_audit = workflow_source.replace("run: Scripts/run-static-audit.sh", "run: echo skipped", 1)
    misplaced_audit += "\n# Scripts/run-static-audit.sh\n"
    if not any("静态审计 Job 缺少执行入口" in item for item in ci_wiring_findings(misplaced_audit)):
        findings.append("代码质量规则边界自检失败：CI 注释中的审计标记隔离")
    detached_catalyst = re.sub(r"(?s)(  catalyst-tests:.*?)    needs: static-audit", r"\1    needs: []", workflow_source, count=1)
    if not any("Catalyst 行为 Job 需要依赖静态审计" in item for item in ci_wiring_findings(detached_catalyst)):
        findings.append("代码质量规则边界自检失败：Catalyst Job 与静态审计依赖识别")
    skipped_catalyst = workflow_source.replace("run: Scripts/run-extended-tests.sh catalyst", "run: echo skipped", 1)
    if not any("Catalyst 行为 Job 需要执行" in item for item in ci_wiring_findings(skipped_catalyst)):
        findings.append("代码质量规则边界自检失败：并行 Catalyst 行为用例执行门禁")
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
    return findings


def script_output_boundary_findings() -> list[str]:
    """通过内存命令输出验证阈值、完整留档及进程状态。"""
    from contextlib import nullcontext, redirect_stdout
    from io import StringIO
    from types import SimpleNamespace
    from unittest.mock import patch

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
    findings.extend(build_cache_boundary_findings())
    findings.extend(script_command_boundary_findings())
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


def script_command_boundary_findings() -> list[str]:
    "通过内存替身验证自动选机、操作分派、筛选合并及参数拒绝。"
    import os
    import shlex
    import plistlib
    from contextlib import nullcontext, redirect_stdout
    from io import BytesIO, StringIO
    from unittest.mock import Mock, patch

    findings = []
    support = SCRIPT_ROOT / "script-support.sh"
    frame = r'''
bit101_require_device() {
  print DEVICE
  export BIT101_XCODE_DEVICE_ID=udid BIT101_DEVICETCL_DEVICE_ID=core
  export BIT101_DEVICE_TRANSPORT=wired BIT101_DEVICE_NAME=phone
}
bit101_build_cache() { print CACHE; }
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
    ui_test_count = sum(
        len(re.findall(r"^\s*(?:@objc )?func test\w+\(", path.read_text(), re.MULTILINE))
        for path in (ROOT / "BIT101-iOSUITests").glob("*.swift")
    )
    cases = (
        ("build-install-device.sh", [], 0, "platform=iOS,id=udid", "DEVICE"),
        ("build-install-device.sh", ["build"], 0, "generic/platform=iOS", ""),
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
        ("run_icloud_cross_device_smoke.sh", [], 86, "ICLOUD_CROSS_DEVICE_SMOKE", "DEVICE"),
    )
    environment = dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1", BIT101_DEFER_APP_RESTORE="1")
    for filename, arguments, expected, marker, device in cases:
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"',
                                         f"source {shlex.quote(str(support))}\n" + frame)
        stop = "exit 86" if expected == 86 else "return 0"
        source = source.replace(frame, frame + f'\nbit101_run_logged() {{ print -r -- "BUILD $*"; {stop}; }}\n')
        source = re.sub(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$",
                        'ui_test_plan() { print -r -- /audit/ui.xctestrun; }', source, count=1)
        result = subprocess.run(["zsh", "-c", source, str(path), *arguments], env=environment,
                                capture_output=True, text=True)
        if result.returncode != expected or marker not in result.stdout or ("DEVICE\n" in result.stdout) != bool(device):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 分派及自动选机；{result.stderr[:160]}")
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
    configuration = {"TestConfigurations": [{"TestTargets": [
        {"IsUITestBundle": True, "UITargetAppMainThreadCheckerEnabled": True,
         "UITargetAppPerformanceAntipatternCheckerEnabled": True, "TestBundlePath": "UI.xctest"},
        {"IsUITestBundle": False, "UITargetAppMainThreadCheckerEnabled": True, "TestBundlePath": "App.xctest"},
    ]}]}
    older, newer = Mock(), Mock()
    older.stat.return_value.st_mtime = 1
    newer.stat.return_value.st_mtime = 2
    written = BytesIO()
    newer.open.side_effect = [nullcontext(BytesIO(plistlib.dumps(configuration))), nullcontext(written)]
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), \
         patch.object(Path, "glob", return_value=[older, newer]), redirect_stdout(StringIO()):
        exec(compile(plan_source, "ui-plan-self-test", "exec"), {})
    targets = plistlib.loads(written.getvalue())["TestConfigurations"][0]["TestTargets"]
    if older.open.called or targets[0]["UITargetAppMainThreadCheckerEnabled"] \
            or targets[0]["UITargetAppPerformanceAntipatternCheckerEnabled"] \
            or targets[0]["TestBundlePath"] != "UI.xctest" or targets[1] != configuration["TestConfigurations"][0]["TestTargets"][1]:
        findings.append("UI 计划自测：最新构建选择、诊断设置及业务 target 配置保留")
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), patch.object(Path, "glob", return_value=[]):
        try:
            exec(compile(plan_source, "ui-plan-empty-self-test", "exec"), {})
        except SystemExit as error:
            if ".xctestrun" not in str(error):
                findings.append("UI 计划自测：冷缓存缺少运行配置时的诊断")
        else:
            findings.append("UI 计划自测：运行配置完整性检查")

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


def build_cache_boundary_findings() -> list[str]:
    "验证缓存合并、热文件保留、链接复用和清理边界。"
    from contextlib import redirect_stdout
    from io import StringIO
    import os
    import shutil
    from unittest.mock import patch

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

        obsolete = fixture / ".build/ui-authorization.logarchive"
        obsolete.mkdir()
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
        if (old / "warm").read_text() != "retain warm module" or (old / "unique").read_text() != "preserve unique module":
            findings.append("缓存自测：保留热模块及唯一模块")
        if module.read_bytes() != content or module.stat().st_mtime_ns != modified:
            findings.append("缓存自测：合并保留内容和修改时间")
        if any((shared / name).exists() for name in ("simulator", "watch-simulator")):
            findings.append("缓存自测：停用平台的隐式模块清理")
        if any((shared / name / f"{name}.pcm").read_bytes() != content for name in ("phone", "mac", "unreadable")):
            findings.append("缓存自测：保留真机、Mac 及平台归属待核对的模块")
        if obsolete.exists() or diagnostics.exists() or symbols.exists() or (products / "Release-iphonesimulator").exists():
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
        ):
            arguments = ["cache", str(fixture), "build.log", "build", "xcodebuild", action, *settings]
            with patch.object(sys, "argv", arguments), patch.object(subprocess, "run", inspect_module):
                try:
                    exec(compile(block[1], "cache-self-test", "exec"), {})
                except SystemExit as result:
                    if result.code != 0:
                        raise
            if [value for value in builds[-1] if value.startswith("DEBUG_INFORMATION_FORMAT=")] != expected:
                findings.append("缓存自测：开发 DWARF、显式符号设置和发行归档边界")
            expected_mode = [] if action == "archive" else ["SWIFT_COMPILATION_MODE=wholemodule" if settings == ["SWIFT_COMPILATION_MODE=wholemodule"] else "SWIFT_COMPILATION_MODE=singlefile"]
            if [value for value in builds[-1] if value.startswith("SWIFT_COMPILATION_MODE=")] != expected_mode:
                findings.append("缓存自测：开发增量编译、显式编译模式和发行归档边界")
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def smoke_script_boundary_findings() -> list[str]:
    "通过故障注入验证恢复顺序、状态传播和失败证据保留。"
    from contextlib import redirect_stdout
    from io import StringIO
    from unittest.mock import patch

    import os
    import signal

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
BIT101_DEFER_APP_RESTORE=0
run_phone_test() {{ print cleanup; return {cleanup_status}; }}
restore_normal_app() {{ print restore; return {restore_status}; }}
report_result() {{ print report; }}
python3() {{ cat >/dev/null; }}
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
UI_TEST_EXECUTION_STARTED=true
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
UI_TEST_EXECUTION_STARTED=false
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
        if report["stages"][0].get("testFailures") != summary["testFailures"] or len(report["stages"]) != 2 or result_tool.call_count != 1:
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
