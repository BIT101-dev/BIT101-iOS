#!/usr/bin/env python3
"""Read test results, export diagnostics and format workflow measurements."""

import sys
from pathlib import Path
from validation_artifacts import clear_diagnostic_exports
from test_module_metrics import (
    export_module_metrics, module_result, native_test_timings, report_ui_timings,
)
from validation_result_readers import (
    append_catalyst_coverage_lines,
    current_result_bundle,
    export_failure_hierarchy_attachments,
    failure_text,
    read_test_tree,
    report_result_summary,
    report_test_activities,
    result_bundle_modified,
)


def workflow_start(arguments: list[str]) -> None:
    import time

    print(time.monotonic())


def report_test_results(arguments: list[str]) -> None:
    cli_arguments = ["", *arguments]
    import json
    import subprocess
    import sys
    from pathlib import Path

    bundle = Path(cli_arguments[1])
    sys.path.insert(0, cli_arguments[4])
    from validation_performance import result_bundle_complete

    result_root = bundle.parent
    metrics_path = result_root / "test-metrics.txt"
    bundle = current_result_bundle(bundle)
    metrics_current = (
        cli_arguments[3] == "report"
        and metrics_path.is_file()
        and (
            not bundle.is_dir() or metrics_path.stat().st_mtime_ns >= result_bundle_modified(bundle)
        )
    )
    if cli_arguments[3] == "report" and not cli_arguments[2] and metrics_current:
        report_metrics(metrics_path)
        return
    if (
        cli_arguments[3] == "report"
        and cli_arguments[2] in {"json", "coverage"}
        and metrics_current
    ):
        sources = [
            json.loads(line.removeprefix("结果来源："))
            for line in metrics_path.read_text().splitlines()
            if line.startswith("结果来源：")
        ]
        if len(sources) == 1 and sources[0]["family"] == "modules":
            if cli_arguments[2] == "json":
                print(
                    json.dumps(
                        module_result(
                            result_root / "module-events.jsonl", sources[0].get("exitCode", 0)
                        ),
                        ensure_ascii=False,
                    )
                )
            else:
                if not sources[0].get("coverage"):
                    raise SystemExit(
                        f"当前模块执行失败，覆盖率随成功运行生成。完整日志：{result_root / 'modules.log'}"
                    )
                print(Path(sources[0]["coverage"]).read_text())
            raise SystemExit(0)
    diagnostics = result_root / "diagnostics"
    if cli_arguments[2] == "performance":
        sys.path.insert(0, cli_arguments[4])
        from validation_provenance import complete_group_row
        from validation_evidence import REPORT

        report = json.loads(REPORT.read_text())
        for group in ("all", "ui"):
            row = complete_group_row(report.get("groups", {}).get(group, {}))
            for name, record in row.get("performance", {}).get("records", {}).items():
                print(
                    json.dumps(
                        {
                            "scenario": name,
                            "test": record["testIdentifier"],
                            "metrics": record["xcresultMetrics"],
                        }
                    )
                )
        raise SystemExit(0)

    if not result_bundle_complete(bundle):
        raise SystemExit("测试结果可在运行结束后通过 report 读取。")

    if cli_arguments[2] == "performance-run":
        sys.path.insert(0, cli_arguments[4])
        from validation_manual import PERFORMANCE_WORKLOADS
        from validation_evidence import test_summary, normalized_test_id

        executed = {
            normalized_test_id(test)
            for test in test_summary(metrics_path.read_text())["executedTests"]
        }
        for name, (test, _) in PERFORMANCE_WORKLOADS.items():
            if test not in executed:
                continue
            value = json.loads(
                subprocess.check_output(
                    [
                        "xcrun",
                        "xcresulttool",
                        "get",
                        "test-results",
                        "metrics",
                        "--path",
                        str(bundle),
                        "--test-id",
                        test + "()",
                    ],
                    text=True,
                )
            )
            print(json.dumps({"scenario": name, "test": test, "metrics": value}))
        raise SystemExit(0)

    if cli_arguments[2] == "json":
        print(
            subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
                text=True,
            )
        )
        raise SystemExit(0)

    if cli_arguments[2] == "performance-schema":
        subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "metrics",
                "--schema",
                "--path",
                str(bundle),
            ],
            check=True,
        )
        raise SystemExit(0)

    if cli_arguments[2] == "coverage":
        print(
            subprocess.check_output(
                ["xcrun", "xccov", "view", "--report", "--json", str(bundle)], text=True
            )
        )
        raise SystemExit(0)

    if cli_arguments[3] == "diagnostics":
        output = diagnostics
        clear_diagnostic_exports(output)
        subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "export",
                "diagnostics",
                "--path",
                str(bundle),
                "--output-path",
                str(output),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        print(output)
        raise SystemExit(0)

    report_test_activities(bundle, cli_arguments, diagnostics, result_root)

    report_result_summary(str(bundle))


def report_metrics(metrics: Path) -> None:
    from command_output import FailureSummary

    prefixes = (
        "测试分组：",
        "结果：",
        "总计 ",
        "构建与运行耗时：",
        "统计范围：",
        "合计：",
        "用例耗时合计：",
        "完整日志：",
    )
    for line in metrics.read_text().splitlines():
        if line.startswith(prefixes):
            print(line)
    print(f"完整指标：{metrics}")
    failures = metrics.with_name("test-failures.txt")
    if failures.is_file() and failures.stat().st_size:
        summary = FailureSummary()
        with failures.open() as source:
            for line in source:
                summary.add(line)
        sys.stdout.writelines(summary.lines())
        print(f"完整失败记录：{failures}")


def workflow_elapsed(arguments: list[str]) -> None:
    import os, time

    print(round(time.monotonic() - float(os.environ["BIT101_WORKFLOW_STARTED_AT"]), 1))


def simulator_plan(products: Path, scheme: str) -> Path:
    plans = list(products.glob(scheme + "_*iphonesimulator*.xctestrun"))
    if not plans:
        raise ValueError("模拟器编译需要生成对应的运行配置。")
    return max(plans, key=lambda path: path.stat().st_mtime_ns)


def ui_host_product_paths(products: Path) -> list[Path]:
    import plistlib

    plan = simulator_plan(products, "BIT101-iOS-UIAutomation")
    paths = {plan}

    def visit(value, key=""):
        if isinstance(value, dict):
            for name, child in value.items():
                visit(child, name)
        elif isinstance(value, list):
            for child in value:
                visit(child, key)
        elif (
            isinstance(value, str)
            and value.startswith("__TESTROOT__/")
            and key
            in {"TestHostPath", "UITargetAppPath", "TestBundlePath", "DependentProductPaths"}
        ):
            relative = Path(value.removeprefix("__TESTROOT__/"))
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("UI 宿主路径需要属于产品目录。")
            for index, part in enumerate(relative.parts):
                if Path(part).suffix in {".app", ".appex", ".framework", ".xctest"}:
                    relative = Path(*relative.parts[: index + 1])
                    break
            path = products / relative
            if not path.exists():
                raise ValueError(f"UI 宿主需要运行配置引用的产物：{path}")
            paths.add(path)

    visit(plistlib.loads(plan.read_bytes()))
    return sorted(path for path in paths if not any(parent in paths for parent in path.parents))


def ui_host_paths(arguments: list[str]) -> None:
    import os

    products = Path(arguments[0])
    root = Path(__file__).resolve().parents[1]
    files = ui_host_product_paths(products) + [
        root / name
        for name in (
            ".build/compiler-cache/swift-syntax-indexer",
            ".build/compiler-cache/swift-syntax-indexer-inputs.json",
            ".build/static-audit/compilation-conditions.json",
        )
    ]
    paths = "\n".join(str(path.resolve().relative_to(root)) for path in files)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("paths<<BIT101_UI_HOST_PATHS\n" + paths + "\nBIT101_UI_HOST_PATHS\n")


def ui_test_plan(arguments: list[str]) -> None:
    cli_arguments = ["", *arguments]
    from pathlib import Path

    products = Path(cli_arguments[1])
    plans = list(products.glob("BIT101-iOS-UIAutomation_*_iphoneos*.xctestrun"))
    if not plans:
        raise SystemExit("UI 宿主编译产物需要包含 .xctestrun 运行配置。")
    plan = max(plans, key=lambda path: path.stat().st_mtime)
    print(plan)


def report_test_failures(arguments: list[str]) -> None:
    cli_arguments = ["", *arguments]
    import json
    import subprocess
    from command_output import show_report_lines

    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", cli_arguments[1]],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        summary = json.loads(result.stdout)
        failures = summary.get("testFailures", [])
        if failures:
            if all(
                "Not authorized for performing UI testing actions" in failure_text(failure)
                for failure in failures
            ):
                print("真机 UI 自动化授权状态失效；检查手机解锁状态及屏幕提示。")
                print("本批交互用例待验证；详细错误保存在固定 XCTest 结果包。")
                raise SystemExit(0)
            grouped = {}
            for failure in failures:
                grouped.setdefault(failure_text(failure), []).append(
                    failure.get("testIdentifierString", "?")
                )

            def lines():
                from command_output import ui_authorization_failure

                for message, tests in grouped.items():
                    if explanation := ui_authorization_failure(message):
                        yield explanation
                        continue
                    yield f"{message.splitlines()[0][:240]} · {len(tests)} 个用例\n"
                    for test in tests:
                        yield f"  {test}\n"
                    if "enabling automation mode" in message:
                        yield "UI 自动化授权尚未完成；请在手机上完成 XCTest 密码验证后重试。\n"

            show_report_lines(lines(), Path(cli_arguments[1]), "测试失败摘要")


def is_ui_automation_blocked(actions: list, failures: list[dict]) -> bool:
    if actions or not failures:
        return False
    messages = ("enabling automation mode", "Not authorized for performing UI testing actions")
    for failure in failures:
        text = failure.get("failureText", "")
        if not any(message in text for message in messages):
            return False
    return True


def append_ui_interaction_report_lines(
    lines: list[str], result_bundle: str, summary: dict, report_path: str
) -> None:
    import json
    import re
    import subprocess

    lines.append(
        "交互覆盖依据 docs/UI_INTERACTION_COVERAGE.md；常规场景复用 App 进程，核心持久化场景结束进程后验证冷启动恢复。"
    )
    diagnostics = Path(report_path).parent / "diagnostics"
    clear_diagnostic_exports(diagnostics)
    try:
        subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "export",
                "diagnostics",
                "--path",
                result_bundle,
                "--output-path",
                str(diagnostics),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        output = "\n".join(
            path.read_text(errors="replace")
            for path in diagnostics.rglob("StandardOutputAndStandardError.txt")
        )
        with (Path(report_path).parent / "ui-tests.log").open("a") as log:
            log.write("\n" + output)
    finally:
        clear_diagnostic_exports(diagnostics)
    launches = len(re.findall(r"\bt =\s*[\d.]+s\s+Launch BIT101-dev\.BIT101-iOS\b", output))
    processes = sorted(set(re.findall(r"UI automation App process: (\d+)", output)))
    lines.append(f"App 启动次数：{launches}；App 进程：{', '.join(processes) or '未采集'}")
    actions = re.findall(r"\bt =\s*[\d.]+s\s+(Tap|Type|Swipe|Press|Pinch)\b", output)
    lines.append(
        f"系统交互动作：{len(actions)}；"
        + "；".join(
            f"{action} {actions.count(action)}"
            for action in ["Tap", "Type", "Swipe", "Press", "Pinch"]
        )
    )
    activations = [
        float(value) for value in re.findall(r"UI accessibility activate: ([\d.]+)", output)
    ]
    lines.append(f"控件无障碍激活：{len(activations)} 次；累计 {sum(activations):.1f} 秒")
    query_metrics = [
        json.loads(value) for value in re.findall(r"UI query metrics: (\{[^\n]+\})", output)
    ]
    for kind, label in (
        ("liveQueries", "App 内界面查询"),
        ("sharedSnapshots", "共享原生快照读取"),
    ):
        count = sum(row.get(kind, {}).get("count", 0) for row in query_metrics)
        seconds = sum(row.get(kind, {}).get("seconds", 0) for row in query_metrics)
        lines.append(f"{label}：{int(count)} 次；累计 {seconds:.1f} 秒")
    control_actions = [float(value) for value in re.findall(r"UI control action: ([\d.]+)", output)]
    lines.append(f"UIKit 控件事件：{len(control_actions)} 次；累计 {sum(control_actions):.1f} 秒")
    inventories = re.findall(r"UI control inventory: (\{[^\n]+\})", output)
    if inventories and summary.get("failedTests", 0) == 0:
        from ui_inventory import merge

        inventory = merge([json.loads(value) for value in inventories], set(processes))
        lines.append("控件库存：" + json.dumps(inventory, ensure_ascii=False))
        lines.append(
            f"运行中发现的交互标识：{inventory['observed']}；已访问 {inventory['visited']}"
        )
        pending = inventory.get("pending", [])
        lines.append(
            f"待补充访问的标识：{len(pending)}"
            + ("；" + "、".join(pending[:10]) if pending else "")
        )
    replacements = [float(value) for value in re.findall(r"UI input replace: ([\d.]+)", output)]
    lines.append(f"输入控件更新：{len(replacements)} 次；累计 {sum(replacements):.1f} 秒")
    keyboard_finishes = output.count("UI keyboard finish")
    lines.append(f"键盘完成动作：{keyboard_finishes} 次")
    lines.append(f"滚动定位准备：{output.count('UI scroll reveal')} 次")
    interaction_total = sum(map(len, (actions, activations, control_actions, replacements)))
    interaction_total += keyboard_finishes
    lines.append(f"交互动作合计：{interaction_total}")
    failures = summary.get("testFailures", [])
    if is_ui_automation_blocked(actions, failures):
        lines.append("真机自动化初始化或授权阻塞；本批实际交互待验证。")
    wait_started = None
    system_waits = []
    for line in output.splitlines():
        timestamp = re.search(r"t =\s*([\d.]+)s", line)
        if not timestamp:
            continue
        if "Start Test" in line:
            wait_started = None
        elif "Wait for " in line and " to idle" in line:
            wait_started = float(timestamp[1]) if "com.apple.springboard" in line else None
        elif (
            "App animations complete notification not received" in line and wait_started is not None
        ):
            system_waits.append(float(timestamp[1]) - wait_started)
            wait_started = None
    lines.append(f"系统动画等待超时：{len(system_waits)} 次；累计 {sum(system_waits):.1f} 秒")
    query_retries = len(re.findall(r"\(retry \d+\)", output))
    lines.append(f"控件查询重试：{query_retries} 次")
    lines.append(f"系统通知横幅处理：{output.count('UI notification banner dismissed')} 次")
    snapshot_count = 0
    snapshot_seconds = 0.0
    previous_step = None
    for line in output.splitlines():
        step = re.search(r"t =\s*([\d.]+)s\s+(.*)", line)
        if not step:
            continue
        current_step = (float(step[1]), step[2].strip())
        if current_step[1].startswith("Requesting snapshot"):
            snapshot_count += 1
        if previous_step and previous_step[1].startswith("Requesting snapshot"):
            duration = current_step[0] - previous_step[0]
            if duration >= 0:
                snapshot_seconds += duration
        previous_step = current_step
    lines.append(f"界面快照请求：{snapshot_count} 次；阶段耗时约 {snapshot_seconds:.1f} 秒")
    preparations = [float(value) for value in re.findall(r"UI scene preparation: ([\d.]+)", output)]
    if preparations:
        lines.append(f"场景准备：{len(preparations)} 次；累计 {sum(preparations):.1f} 秒")


def unstarted_test_message(mode: str, result_bundle: str) -> str:
    if mode == "ui":
        log = Path(result_bundle).parent / "ui.log"
        return f"UI 测试尚未执行任何用例。请处理上方设备或测试程序启动错误；完整记录：{log}"
    return "测试尚未执行任何用例。请处理上方编译或测试程序启动错误，并核对测试类/方法筛选。"


def record_native_metrics(arguments: list[str]) -> None:
    cli_arguments = ["", *arguments]
    import json
    import os
    import re
    import subprocess
    import sys
    from pathlib import Path

    result_bundle, report_path, mode, elapsed_seconds, device_id, root = cli_arguments[1:]
    performance_only = os.environ.get("BIT101_TEST_PERFORMANCE_ONLY") == "1"
    if mode in {"catalyst", "catalyst-release-runtime"}:
        device_id = ""
    sys.path.insert(0, str(Path(root) / "Scripts"))
    from validation_evidence import validate_community_write_test_output
    from command_output import ui_authorization_failure

    summary_result = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_bundle,
        ],
        capture_output=True,
        text=True,
    )
    if summary_result.returncode:
        raise SystemExit("XCTest 结果包尚待生成；请检查测试运行日志及设备提示。")
    summary = json.loads(summary_result.stdout)
    if summary.get("totalTestCount", 0) == 0 or any(
        ui_authorization_failure(failure.get("failureText", ""))
        for failure in summary.get("testFailures", [])
    ):
        raise SystemExit(unstarted_test_message(mode, result_bundle))

    coverage = None
    coverage_error = None
    if not performance_only and mode not in {"catalyst", "catalyst-release-runtime"}:
        coverage_result = subprocess.run(
            [
                "xcrun",
                "xccov",
                "view",
                "--report",
                "--json",
                result_bundle,
            ],
            capture_output=True,
            text=True,
        )
        if coverage_result.returncode == 0:
            try:
                coverage = json.loads(coverage_result.stdout)
            except json.JSONDecodeError as error:
                coverage_error = f"xccov returned invalid JSON: {error}"
        else:
            coverage_error = (coverage_result.stderr or coverage_result.stdout).strip()
            if not coverage_error:
                coverage_error = f"xccov exited with status {coverage_result.returncode}"

    lines = [
        "# XCTest 与覆盖率指标",
        f"测试分组：{mode}",
        "",
        "## 测试汇总",
        (
            f"结果："
            f"{summary.get('result', '?')}"
            f"；总计 "
            f"{summary.get('totalTestCount', '?')}"
            f"；通过 "
            f"{summary.get('passedTests', 0)}"
            f"；失败 "
            f"{summary.get('failedTests', 0)}"
            f"；跳过 "
            f"{summary.get('skippedTests', 0)}"
        ),
        f"构建与运行耗时：{elapsed_seconds} 秒",
        "",
        "## UI 交互覆盖" if mode == "ui" else "## 逐 target 行覆盖率",
    ]
    if performance_only:
        lines.append("性能专项：关闭代码覆盖率统计。")
    elif coverage is None or mode == "ui":
        if mode == "ui":
            append_ui_interaction_report_lines(lines, result_bundle, summary, report_path)
        elif mode in {"catalyst", "catalyst-release-runtime"}:
            append_catalyst_coverage_lines(lines, report_path)
        else:
            lines.append("设备测试汇总已采集；Xcode 覆盖率归档诊断如下。")
            if coverage_error:
                lines.append(coverage_error)
    append_native_coverage_lines(coverage, device_id, lines, report_path, root)

    test_tree = read_test_tree(result_bundle)
    durations, executed = native_test_timings(test_tree)
    if performance_only and summary.get("result") == "Passed" and (
        not executed or any(
            not name.startswith(("MaintenancePerformanceTests/", "MaintenancePerformanceUITests/"))
            for name in executed
        )
    ):
        raise SystemExit("性能专项只接受性能测试用例。")
    if summary.get("result") == "Passed":
        validate_community_write_test_output(Path(result_bundle), set(executed))
    lines.append("已执行用例：" + json.dumps(sorted(set(executed)), ensure_ascii=False))
    from validation_evidence import native_case_summary

    lines.append(
        "测试实例："
        + json.dumps(
            native_case_summary(
                test_tree,
                mode
                if mode
                in {
                    "ui",
                    "catalyst",
                    "catalyst-release-runtime",
                    "release-runtime",
                    "network-smoke",
                }
                else "all",
                device_identifier=device_id,
            ),
            ensure_ascii=False,
        )
    )
    if durations:
        lines += [
            "",
            "## 用例耗时",
            f"用例耗时合计：{sum(item[0] for item in durations):.1f} 秒",
            *[
                f"- {name}: {duration}"
                for _, name, duration in sorted(durations, reverse=True)[:10]
            ],
        ]

    lines += [
        "验证输入：" + os.environ["BIT101_VALIDATION_INPUT_IDENTITY"],
        "验证运行：" + os.environ["BIT101_VALIDATION_RUN_ID"],
    ]
    report = "\n".join(lines) + "\n"
    Path(report_path).write_text(report, encoding="utf-8")
    print(lines[4])
    if (
        not performance_only and mode not in {"catalyst", "catalyst-release-runtime"}
        and coverage is None
    ):
        if coverage_error:
            print(coverage_error)
        raise SystemExit("覆盖率采集失败。")


def selected_inventory(arguments: list[str]) -> None:
    import json
    from validation_evidence import selected_test_inventory

    try:
        print(json.dumps(sorted(selected_test_inventory(arguments[0], arguments[1:]))))
    except ValueError as error:
        raise SystemExit(str(error))


def module_filter(arguments: list[str]) -> None:
    import re

    print("|".join(r"(?:^|\.)" + re.escape(value) + r"(?:/|\(|$)" for value in arguments))


def append_native_coverage_lines(coverage, device_id, lines, report_path, root):
    from pathlib import Path
    import json
    import sys

    if coverage is not None:
        target_rows = coverage.get("targets", [])
        for target in target_rows:
            fraction = target.get("lineCoverage")
            if not (isinstance(fraction, (int, float))):
                continue
            percentage = fraction * 100 if fraction <= 1 else fraction
            covered = target.get("coveredLines", "?")
            executable = target.get("executableLines", "?")
            if executable == 0:
                lines.append(f"- {target.get('name', '?')}: 符号合并到宿主范围")
            else:
                lines.append(
                    (
                        f"- "
                        f"{target.get('name', '?')}"
                        f": "
                        f"{percentage:.2f}"
                        f"% ("
                        f"{covered}"
                        f"/"
                        f"{executable}"
                        f" lines)"
                    )
                )
        sys.path.insert(0, str(Path(root) / "Scripts"))
        from validation_evidence import native_source_coverage

        build = Path(report_path).parent / "Build"
        ios_modules = native_source_coverage(
            build / "Products/Release-iphoneos",
            build / "ProfileData" / device_id / "Coverage.profdata",
            include_app=True,
        )
        for name, (covered, executable) in sorted(ios_modules.items()):
            label = name if name == "BIT101-iOS.app" else "iOS/" + name
            if executable:
                lines.append(
                    f"- {label}: {covered * 100 / executable:.2f}% ({covered}/{executable} lines)"
                )
        if not target_rows:
            lines.append(json.dumps(coverage, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    commands = {
        "report": report_test_results,
        "elapsed": workflow_elapsed,
        "start": workflow_start,
        "ui-plan": ui_test_plan,
        "ui-host-paths": ui_host_paths,
        "failures": report_test_failures,
        "native-metrics": record_native_metrics,
        "module-metrics": export_module_metrics,
        "select": selected_inventory,
        "module-filter": module_filter,
        "ui-timings": report_ui_timings,
    }
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        raise SystemExit(
            (
                "用法：test_results.py report|ui-plan|failures|native-metrics|module-metrics|select|m"
                "odule-filter 参数..."
            )
        )
    commands[sys.argv[1]](sys.argv[2:])
