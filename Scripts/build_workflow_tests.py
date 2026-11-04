"""Focused workflow and source checks."""

from __future__ import annotations
from workflow_process_tests import workflow_lock_boundary_findings
from script_command_tests import (
    script_command_boundary_findings,
    audit_lock_boundary_findings,
    restore_installation_boundary_findings,
)
from worker_contract_tests import worker_boundary_findings
from report_inbox_tests import report_inbox_boundary_findings
from pathlib import Path
import json, os, re, subprocess, sys, shutil
import shlex
from contextlib import nullcontext, redirect_stdout
from io import StringIO
from unittest.mock import Mock, patch
from ui_rule_tests import explanatory_text_boundary_findings, school_lifecycle_boundary_findings
from code_quality_rules import (
    ROOT,
    SCRIPT_ROOT,
)


def command_logging_boundary_findings() -> list[str]:
    """通过内存命令输出验证阈值、完整留档及进程状态。"""
    from types import SimpleNamespace

    from command_output import OUTPUT_LINE_LIMIT, run_command
    from script_output_tests import captured_command

    findings: list[str] = []
    for status, count, ci in (
        (0, 10, False),
        (7, OUTPUT_LINE_LIMIT, False),
        (7, OUTPUT_LINE_LIMIT + 1, False),
        (-15, 1, False),
        (0, OUTPUT_LINE_LIMIT + 1, True),
        (7, OUTPUT_LINE_LIMIT + 1, True),
    ):
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
            assert "[用例]" not in visible.getvalue()

        process = SimpleNamespace(stdout=native_output(), wait=lambda: 0)
        with (
            patch.object(sys, "argv", ["logger", "/audit/ui.log", "模拟器测试", "xcodebuild"]),
            patch.object(subprocess, "Popen", return_value=process),
            patch.object(Path, "mkdir"),
            patch.object(Path, "open", lambda *args, **kwargs: nullcontext(log)),
            patch.dict(os.environ, GITHUB_ACTIONS="true" if ci else "false"),
            redirect_stdout(visible),
        ):
            assert run_command(sys.argv[1:]) == 0
        if log.getvalue() != "    t = 0.10s Press button\n" + case:
            findings.append("日志自测：原生用例进度即时展示，完整操作记录沿固定日志保留")
    return findings


def script_output_boundary_findings() -> list[str]:
    findings = command_logging_boundary_findings()
    script = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    from test_results import report_result_summary, record_native_metrics

    for failures in ([], [{"testIdentifierString": "Suite/test", "failureText": "assertion"}]):
        visible = StringIO()
        sample = dict(
            result="Failed" if failures else "Passed",
            passedTests=2 if failures else 3,
            totalTestCount=3,
            testFailures=failures,
        )
        with (
            patch.object(sys, "argv", ["report", "/result"]),
            patch.object(subprocess, "check_output", return_value=json.dumps(sample)) as read,
            redirect_stdout(visible),
        ):
            report_result_summary("/result")
        expected = ["结果来源：/result", f"{sample['result']} · {sample['passedTests']}/3 通过"]
        if failures:
            expected.append("Suite/test: assertion")
        if visible.getvalue().splitlines() != expected or read.call_count != 1:
            findings.append("报告默认输出摘要与失败项，完整用例树沿 report json 读取。")
    with (
        patch.object(sys, "argv", ["metrics", "/result", "/report", "ui", "1", "device", "/audit"]),
        patch.object(
            subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 64, "", "incomplete result"),
        ),
    ):
        try:
            record_native_metrics(sys.argv[1:])
        except SystemExit as error:
            if "XCTest 结果包" not in str(error):
                findings.append("测试指标自测：启动中断摘要")
        else:
            findings.append("测试指标自测：中断阶段保持失败状态")
    validation = re.search(r"(?ms)^finish_validation\(\) \{\n.*?^\}$", script)
    for test_status, evidence_status in ((0, 0), (23, 0), (0, 7)):
        frame = "ROOT_DIR=/audit\nBUILD_ONLY=true\nvalidation_group=ui\nvalidation_scope=full\n"
        frame += f'python3() {{ print -r -- "$3 $4 $5"; return {evidence_status}; }}\n'
        frame += validation[0] + f"\ntrap finish_validation EXIT\nexit {test_status}\n"
        result = subprocess.run(["zsh", "-c", frame], capture_output=True, text=True)
        if (
            result.returncode != (evidence_status or test_status)
            or result.stdout.strip() != f"ui {test_status} full"
        ):
            findings.append("验证证据自测：成功、失败与证据写入错误的退出状态")
    header = script.split("set -euo pipefail", 1)[0]
    fixture = ROOT / ".build/static-audit/script-snapshot.sh"
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text(
        header
        + 'print -r -- "print replacement" > "$0"\n'
        + "# padding\n" * 2000
        + "print snapshot-survived\n"
    )
    try:
        result = subprocess.run(["zsh", str(fixture)], capture_output=True, text=True)
        if result.returncode or result.stdout.strip() != "snapshot-survived":
            findings.append("脚本快照自测：执行期间改写源码影响既有流程")
    finally:
        fixture.unlink(missing_ok=True)
    for check in (
        build_cache_boundary_findings,
        catalyst_signing_boundary_findings,
        script_command_boundary_findings,
        workflow_lock_boundary_findings,
        audit_lock_boundary_findings,
        restore_installation_boundary_findings,
        worker_boundary_findings,
        report_inbox_boundary_findings,
        explanatory_text_boundary_findings,
        school_lifecycle_boundary_findings,
    ):
        findings.extend(check())
    support = (SCRIPT_ROOT / "script-support.sh").read_text()
    routing = subprocess.run(
        [
            "zsh",
            "-c",
            support
            + r"""
bit101_build_cache() { print cached; }
bit101_log_command() { print direct; }
bit101_run_logged /log test xcodebuild test-without-building
bit101_run_logged /log build xcodebuild build-for-testing
""",
        ],
        capture_output=True,
        text=True,
    )
    if routing.returncode or routing.stdout.splitlines() != ["direct", "cached"]:
        findings.append("脚本自测：测试执行与编译缓存锁的生命周期")
    audit = (SCRIPT_ROOT / "run-static-audit.sh").read_text()
    tail = audit[audit.index("failed_groups=()") :]
    from script_test_support import shell_function

    wait_groups = shell_function(SCRIPT_ROOT / "script-support.sh", "bit101_wait_audit_groups")
    selection = audit[audit.index("set -euo pipefail") : audit.index("\nROOT_DIR=")]
    harness = (
        selection
        + r"""
set -euo pipefail
LOG_DIR=/audit
ROOT_DIR=/audit
unset BIT101_AUDIT_BACKGROUND
AUDIT_STARTED=$SECONDS
python3() { return 0; }
bit101_run_audit_group() {
    print -r -- "RAN $1"
    case "$1" in shell-parse|docs) return 7;; esac
    return 0
}
bit101_start_audit_group() { bit101_run_audit_group "$1" "$2" & group_processes+=($!); }
"""
    )
    fixture = ROOT / ".build/static-audit/workflow-lock-self-test"
    fixture.mkdir(parents=True, exist_ok=True)
    harness = harness.replace("LOG_DIR=/audit", "LOG_DIR=" + shlex.quote(str(fixture)))
    try:
        for prepared in (0, 1):
            aggregation = subprocess.run(
                [
                    "zsh",
                    "-c",
                    harness
                    + wait_groups
                    + f"\nBIT101_AUDIT_ARTIFACTS_PREPARED={prepared}\n"
                    + tail,
                ],
                capture_output=True,
                text=True,
            )
            groups = re.findall(r"^RAN (.+)$", aggregation.stdout, re.MULTILINE)
            if (
                aggregation.returncode != 1
                or len(set(groups)) != 10 - prepared
                or ("artifact-hygiene" in groups) != (prepared == 0)
                or set(aggregation.stderr.removeprefix("[失败汇总] ").strip().split(", "))
                != {"shell-parse", "docs"}
            ):
                findings.append("静态审计自测：产物准备、并行分组执行完整性与多个失败汇总")
    finally:
        shutil.rmtree(fixture)
    return findings


def catalyst_signing_boundary_findings() -> list[str]:
    """覆盖本机默认签名、显式免签名和托管 CI 策略。"""
    from script_test_support import shell_function

    signing = shell_function(SCRIPT_ROOT / "script-support.sh", "bit101_catalyst_signing_arguments")
    harness = (
        'set -euo pipefail\nGITHUB_ACTIONS="$2" BIT101_CATALYST_UNSIGNED_TESTS="$3"\n' + signing
    )
    findings = []
    for mode in ("catalyst", "catalyst-release-runtime"):
        for ci in ("", "false", "true"):
            for unsigned in ("", "0", "1"):
                result = subprocess.run(
                    [
                        "zsh",
                        "-c",
                        harness + "\nbit101_catalyst_signing_arguments",
                        "catalyst-signing",
                        mode,
                        ci,
                        unsigned,
                    ],
                    capture_output=True,
                    text=True,
                )
                expected = (
                    ["CODE_SIGNING_ALLOWED=NO"]
                    if ci == "true" or unsigned == "1"
                    else ["-allowProvisioningUpdates"]
                )
                if result.returncode or result.stdout.splitlines() != expected:
                    findings.append(
                        f"Catalyst 签名自测：{mode} 在 {ci or 'local'}、免签名 {unsigned or '默认'} 时沿所属策略执行"
                    )
    return findings


def check_cache_setting_defaults(
    build: list[str], settings: list[str], defaults: tuple[str, ...]
) -> bool:
    for setting in defaults:
        prefix = setting.split("=")[0] + "="
        actual = [value for value in build if value.startswith(prefix)]
        expected = [value for value in settings if value.startswith(prefix)] or [setting]
        if actual != expected:
            return True
    return False


def verify_cache_build_action(
    fixture: Path,
    action: str,
    settings: list[str],
    expected: list[str] | None,
    inspect_module: object,
    builds: list[list[str]],
    findings: list[str],
) -> None:
    from compiler_cache import run_cache

    command = (
        ["xcrun", "swift", action.removeprefix("swift-")]
        if expected is None
        else ["xcodebuild", action]
    )
    arguments = ["cache", str(fixture), "build.log", "build", *command, *settings]
    with (
        patch.object(sys, "argv", arguments),
        patch.object(subprocess, "run", inspect_module),
        patch.object(shutil, "disk_usage", return_value=Mock(free=4 * 1024**3)),
    ):
        try:
            run_cache(sys.argv[1:])
        except SystemExit as result:
            if result.code != 0:
                raise
    assert builds[-1][3:5] == ["cache-build", str(fixture)]
    if expected is None:
        if not all(
            flag in builds[-1] for flag in ("-Xswiftc", "-warnings-as-errors", "-Xcc", "-Werror")
        ):
            findings.append("编译入口自测：SwiftPM 构建与测试的警告门禁")
        return
    debug_format = [value for value in builds[-1] if value.startswith("DEBUG_INFORMATION_FORMAT=")]
    if debug_format != expected:
        findings.append("缓存自测：开发 DWARF、显式符号设置和发行归档界限")
    expected_mode = [value for value in settings if value.startswith("SWIFT_COMPILATION_MODE=")]
    compilation_mode = [
        value for value in builds[-1] if value.startswith("SWIFT_COMPILATION_MODE=")
    ]
    if compilation_mode != expected_mode:
        findings.append("缓存自测：构建、测试与归档沿工程配置及显式编译模式")
    defaults = (
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
        "COMPILATION_CACHE_ENABLE_CACHING=YES",
        "SWIFT_ENABLE_PREFIX_MAPPING=YES",
        "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES",
        "CLANG_ENABLE_PREFIX_MAPPING=YES",
        "CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES",
    )
    if check_cache_setting_defaults(builds[-1], settings, defaults):
        findings.append("编译入口自测：构建、测试与正式归档的警告门禁及缓存路径映射")


def build_cache_boundary_findings() -> list[str]:
    "验证缓存合并、热文件保留、链接复用和清理界限。"

    from compiler_cache import run_cache

    fixture = ROOT / ".build/static-audit/cache-self-test"
    findings: list[str] = []
    try:
        from validation_artifacts import SELF_TEST_ARTIFACTS, recover_self_test_artifacts

        audit_folder = fixture / ".build/static-audit"
        audit_folder.mkdir(parents=True, exist_ok=True)
        for name in SELF_TEST_ARTIFACTS:
            path = audit_folder / name
            if path.suffix in {".swift", ".sh"}:
                path.write_text("interrupted self-test")
            else:
                path.mkdir()
        retained = audit_folder / "unregistered.log"
        retained.write_text("audit keeps unregistered evidence visible")
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
        direct_module = shared / "swift-syntax.pcm"
        direct_module.write_text("direct compiler consumer")
        module = old / "module.pcm"
        content = b"compiled module fixture\n" * 4096
        module.write_bytes(content)
        cas = fixture / ".build/extended-automation/CompilationCache.noindex"
        retained_cas = fixture / ".build/compiler-cache/CompilationCache.noindex"
        cas.mkdir()
        retained_cas.mkdir()
        for name in ("index", "data"):
            (cas / name).write_bytes(content)
        os.utime(cas / "index", ns=(1, 1))
        (retained_cas / "index").write_text("distinct namespace")
        stats = fixture / ".build/extended-automation/SDKStatCaches.noindex"
        stats.mkdir()
        for name in ("iphoneos.sdkstatcache", "iphonesimulator.sdkstatcache"):
            (stats / name).write_text(name)
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
                return subprocess.CompletedProcess(
                    command,
                    0 if triple else 1,
                    f"Target options:\n  Triple: {triple}\n" if triple else "",
                    "",
                )
            return command_run(command, **options)

        obsolete_paths = [
            fixture / ".build/ui-authorization.logarchive",
            fixture / ".build/static-audit/package-build",
        ]
        for path in obsolete_paths:
            path.mkdir(parents=True)
        obsolete_cloud_log = fixture / ".build/icloud-cross-device-smoke/testPhoneUpload.log"
        obsolete_cloud_log.parent.mkdir()
        obsolete_cloud_log.write_text("obsolete stage")
        diagnostics = fixture / ".build/extended-automation/diagnostics"
        diagnostics.mkdir()
        diagnostic_result = diagnostics / "test-results.xcresult"
        diagnostic_result.mkdir()
        (diagnostic_result / "Info.plist").write_text("retain failure diagnostics")
        diagnostic_export = diagnostics / "exported.log"
        diagnostic_export.write_text("temporary export")
        products = fixture / ".build/extended-automation/Build/Products"
        for platform in ("Release-iphoneos", "Release-iphonesimulator"):
            (products / platform).mkdir(parents=True)
            (products / platform / "product").write_text(platform)
        symbols = products / "Release-iphoneos/product.dSYM"
        symbols.mkdir()
        (symbols / "debug-info").write_bytes(content)
        orphan_symbols = products / "Release-iphoneos/orphan.dSYM"
        orphan_symbols.mkdir()
        test_symbols = products / "Release-iphoneos/tests.xctest.dSYM"
        test_symbols.mkdir()
        (test_symbols / "debug-info").write_bytes(content)
        (products / "Release-iphoneos/Runner.app/PlugIns/tests.xctest").mkdir(parents=True)
        bundled_symbols = (
            products / "Release-iphoneos/Runner.app/PlugIns/tests.xctest.dSYM/debug-info"
        )
        bundled_symbols.parent.mkdir(parents=True)
        bundled_symbols.write_bytes(content)
        result = fixture / ".build/extended-automation/test-results.xcresult"
        result.mkdir()
        (result / "evidence").write_text("retain result")
        cloud_result = (
            fixture / ".build/icloud-cross-device-smoke/Mac/Logs/Test/test-results.xcresult"
        )
        cloud_result.mkdir(parents=True)
        (cloud_result / "evidence").write_text("retain recovery diagnostics")
        sdk = fixture / ".build/extended-automation/SDKExplicitPrecompiledModules"
        sdk.mkdir()
        (sdk / "referenced.pcm").write_bytes(content)
        (sdk / "unused.pcm").write_bytes(content)
        dependencies = products.parent / "Intermediates.noindex/fixture-dependencies.json"
        dependencies.parent.mkdir()
        debug_object = dependencies.parent / "debug.o"
        debug_object.write_bytes(content)
        dependencies.write_text(
            json.dumps(
                [{"clangModulePath": str(sdk / "referenced.pcm")}, {"clangModulePath": str(module)}]
            )
        )
        for _ in range(2):
            with (
                patch.object(sys, "argv", ["cache", str(fixture), "--maintenance"]),
                patch.object(subprocess, "run", inspect_module),
                redirect_stdout(StringIO()),
            ):
                run_cache(sys.argv[1:])
        if not old.is_symlink() or old.resolve() != shared.resolve():
            findings.append("缓存自测：同类缓存目录共享")
        if not cas.is_symlink() or any(
            (cas / name).read_bytes() != content for name in ("index", "data")
        ):
            findings.append("缓存自测：CAS 命名空间整体保留及共享")
        if not all(
            (stats / name).exists()
            for name in ("iphonesimulator.sdkstatcache", "iphoneos.sdkstatcache")
        ):
            findings.append("缓存自测：SDK 统计缓存的平台归属")
        if (old / "warm").read_text() != "retain warm module" or (
            old / "unique"
        ).read_text() != "preserve unique module":
            findings.append("缓存自测：保留热模块及唯一模块")
        if module.read_bytes() != content or module.stat().st_mtime_ns != modified:
            findings.append("缓存自测：合并保留内容和修改时间")
        assert direct_module.read_text() == "direct compiler consumer"
        if not all((shared / name).exists() for name in ("simulator", "watch-simulator")):
            findings.append("缓存自测：保留模拟器平台的隐式模块")
        if any(
            (shared / name / f"{name}.pcm").read_bytes() != content
            for name in ("phone", "mac", "unreadable")
        ):
            findings.append("缓存自测：保留真机、Mac 及平台归属待核对的模块")
        if (
            any(path.exists() for path in obsolete_paths)
            or obsolete_cloud_log.exists()
            or diagnostic_export.exists()
            or orphan_symbols.exists()
        ):
            findings.append("缓存自测：清理诊断与冗余符号产物")
        assert (symbols / "debug-info").read_bytes() == content and (
            test_symbols / "debug-info"
        ).read_bytes() == content
        assert (diagnostic_result / "Info.plist").read_text() == "retain failure diagnostics"
        if not (products / "Release-iphonesimulator").exists():
            findings.append("缓存自测：保留模拟器增量产物")
        if debug_object.read_bytes() != content:
            findings.append("缓存自测：保留目标文件中的调试信息")
        if bundled_symbols.read_bytes() != content:
            findings.append("缓存自测：保留运行包内部的调试资源")
        if (
            not (products / "Release-iphoneos/product").is_file()
            or not (result / "evidence").is_file()
        ):
            findings.append("缓存自测：保留增量构建及测试证据")
        if not (cloud_result / "evidence").is_file():
            findings.append("缓存自测：保留云同步失败的固定结果包")
        if not (sdk / "referenced.pcm").is_file() or (sdk / "unused.pcm").exists():
            findings.append("缓存自测：依赖清单引用模块保留")
        (sdk / "incomplete-map.pcm").write_bytes(content)
        dependencies.write_text("{")
        with (
            patch.object(sys, "argv", ["cache", str(fixture), "--maintenance"]),
            patch.object(subprocess, "run", inspect_module),
            redirect_stdout(StringIO()),
        ):
            run_cache(sys.argv[1:])
        if not (sdk / "incomplete-map.pcm").is_file():
            findings.append("缓存自测：依赖清单受损时保留缓存")
        for action, settings, expected in (
            ("build", [], []),
            (
                "test",
                ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"],
                ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"],
            ),
            ("archive", [], []),
            (
                "build-for-testing",
                ["SWIFT_COMPILATION_MODE=wholemodule", "SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=NO"],
                [],
            ),
            ("swift-build", [], None),
            ("swift-test", [], None),
        ):
            verify_cache_build_action(
                fixture, action, settings, expected, inspect_module, builds, findings
            )
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings
