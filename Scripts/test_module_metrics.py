"""Export native module test measurements."""

from pathlib import Path


def module_result(events: Path, status: int) -> dict:
    from validation_evidence import module_event_summary

    try:
        result = module_event_summary(events.read_text())
    except (OSError, ValueError, KeyError, TypeError) as error:
        if status == 0:
            raise
        return dict(passed=False, exitCode=status, diagnostic=f"模块事件读取失败：{error}")
    return dict(result, passed=result["failedTests"] == 0 and status == 0, exitCode=status)


def export_module_metrics(arguments: list[str]) -> None:
    cli_arguments = ["", *arguments]
    import json
    import os
    from pathlib import Path
    import subprocess
    import sys

    coverage_path, report_path, root_path = map(Path, cli_arguments[1:4])
    status = int(cli_arguments[4]) if len(cli_arguments) > 4 else 0
    sys.path.insert(0, str(root_path / "Scripts"))
    from validation_inputs import module_coverage_executables

    tests = module_result(report_path.parent / "module-events.jsonl", status)
    if status:
        from command_output import FailureSummary

        log = report_path.parent / "modules.log"
        details = FailureSummary()
        if log.is_file():
            with log.open() as source:
                for line in source:
                    details.add(line)
        if diagnostic := tests.get("diagnostic"):
            details.add(diagnostic + "\n")
        report_path.with_name("test-failures.txt").write_text("".join(details.lines()))
        rows = [
            "# 模块测试指标",
            "结果来源：" + json.dumps(dict(family="modules", exitCode=status, coverage=None)),
            f"结果：Failed · 进程状态 {status}",
            "完整日志：" + str(log),
            "验证输入：" + os.environ["BIT101_VALIDATION_INPUT_IDENTITY"],
            "验证运行：" + os.environ["BIT101_VALIDATION_RUN_ID"],
        ]
        if "totalTests" in tests:
            rows.append(
                (
                    f"总计 "
                    f"{tests['totalTests']}"
                    f"；通过 "
                    f"{tests['passedTests']}"
                    f"；失败 "
                    f"{tests['failedTests']}"
                    f"；跳过 "
                    f"{tests['skippedTests']}"
                )
            )
        report_path.write_text("\n".join(rows) + "\n")
        return
    test_count = tests["passedTests"]
    executed = tests["executedTests"]
    products = coverage_path.parent.parent
    executables = module_coverage_executables(root_path, products)
    command = [
        "xcrun",
        "llvm-cov",
        "export",
        str(executables[0]),
        "-instr-profile",
        str(coverage_path.parent / "default.profdata"),
    ]
    for executable in executables[1:]:
        command += ["-object", str(executable)]
    coverage_text = subprocess.check_output(command, text=True)
    coverage = json.loads(coverage_text)
    coverage_path.write_text(coverage_text)
    modules = {}
    for section in coverage["data"]:
        for file in section["files"]:
            path = Path(file["filename"])
            if not path.is_relative_to(root_path / "Modules"):
                continue
            module = path.relative_to(root_path / "Modules").parts[0]
            lines = file["summary"]["lines"]
            covered, count = modules.get(module, (0, 0))
            modules[module] = covered + lines["covered"], count + lines["count"]
    if not modules:
        raise SystemExit("模块覆盖率需要包含生产源码。")
    covered = sum(row[0] for row in modules.values())
    count = sum(row[1] for row in modules.values())
    rows = [
        "# 模块生产源码行覆盖率",
        "结果来源：" + json.dumps(dict(family="modules", coverage=str(coverage_path))),
        (
            f"总计 "
            f"{tests['totalTests']}"
            f"；通过 "
            f"{test_count}"
            f"；失败 "
            f"{tests['failedTests']}"
            f"；跳过 "
            f"{tests['skippedTests']}"
        ),
        "测试实例：" + json.dumps(tests["testCases"]),
        "验证输入：" + os.environ["BIT101_VALIDATION_INPUT_IDENTITY"],
        "验证运行：" + os.environ["BIT101_VALIDATION_RUN_ID"],
        f"统计范围：macOS 可执行生产源码，共 {len(modules)} 个模块",
        f"合计：{covered / count * 100 if count else 0:.2f}% ({covered}/{count} lines)",
        *[
            f"- {name}: {covered / count * 100 if count else 0:.2f}% ({covered}/{count} lines)"
            for name, (covered, count) in sorted(modules.items())
        ],
    ]
    report_path.write_text("\n".join(rows) + "\n")
    with report_path.open("a") as stream:
        stream.write("已执行用例：" + json.dumps(sorted(set(executed))) + "\n")
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        table = [
            "## 模块回归",
            f"{test_count} 项测试通过；统计范围为 macOS 可执行生产源码。",
            "",
            "| 模块 | 行覆盖率 | 覆盖行 / 可执行行 |",
            "| --- | ---: | ---: |",
        ]
        table += [
            f"| {name} | {hit / total * 100 if total else 0:.2f}% | {hit} / {total} |"
            for name, (hit, total) in sorted(modules.items())
        ]
        table += [f"| 合计 | {covered / count * 100 if count else 0:.2f}% | {covered} / {count} |"]
        with Path(summary_path).open("a", encoding="utf-8") as summary:
            summary.write("\n".join(table) + "\n")
    print(f"[覆盖率] {len(modules)} 个模块 · {covered}/{count} 行")


def ui_step_timings(text: str) -> list[tuple[float, str, str]]:
    import re

    rows = []
    owner = "UI session"
    previous = None
    for line in text.splitlines():
        case = re.search(r"Test Case '([^']+)' started", line)
        if case:
            owner = case[1]
            previous = None
        step = re.search(r"\bt =\s*([0-9.]+)s\s+(.+)", line)
        if step is None:
            continue
        current = (float(step[1]), step[2].strip())
        if previous is not None and current[0] >= previous[0]:
            elapsed = current[0] - previous[0]
            if elapsed >= 1:
                rows.append((elapsed, owner, previous[1]))
        previous = current
    return sorted(rows, reverse=True)


def report_ui_timings(arguments: list[str]) -> None:
    log = (
        Path(arguments[0])
        if arguments
        else (Path(__file__).resolve().parents[1] / ".build/extended-automation/ui.log")
    )
    for seconds, owner, step in ui_step_timings(log.read_text()):
        print(f"{seconds:.2f}s | {owner} | {step}")
