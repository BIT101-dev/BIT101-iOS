#!/usr/bin/env python3
"""Run source quality checks through the shared rule module."""
import sys
import importlib.util
sys.dont_write_bytecode = True
import json
import subprocess
import traceback
import time
from command_output import OUTPUT_LINE_LIMIT
from code_quality_rules import (
    REPORT_PATH, ROOT, SCRIPT_ROOT, audit_wiring_findings, automatic_school_fetch_findings,
    explanatory_text_report, relative, repository_script_paths, script_findings, source_findings,
    static_audit_lock, swift_files, swift_syntax_index,
)

def main(shared_syntax: dict[str, dict] | None = None, boundary_findings: list[str] | None = None) -> int:
    from code_quality_tests import checker_boundary_findings
    if sys.argv[1:] == ["--swift-syntax-index"]:
        try:
            print(json.dumps(swift_syntax_index(swift_files()), ensure_ascii=False))
            return 0
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            print(f"SwiftSyntax 索引失败：{error}", file=sys.stderr)
            return 1

    if sys.argv[1:] == ["--self-test"]:
        findings = checker_boundary_findings()
        if findings:
            print("[失败] 代码质量检查器自测：", file=sys.stderr)
            print("\n".join(findings), file=sys.stderr)
            return 1
        print("[通过] 代码质量检查器自测")
        return 0

    errors: list[str] = []
    if shared_syntax is None:
        try:
            syntax_index = swift_syntax_index(swift_files())
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            syntax_index = {}
            errors.append(f"SwiftSyntax 索引失败：{error}")
    else:
        syntax_index = shared_syntax
    source_errors, review = source_findings(syntax_index or None)
    large_scripts = [relative(path) for path in repository_script_paths(ROOT, {'.sh', '.py', '.swift'})
        if len(path.read_text().splitlines()) > 800]
    if large_scripts: review.append('大型脚本候选：' + ', '.join(large_scripts))
    errors.extend(source_errors)
    errors.extend(boundary_findings or [])
    errors.extend(script_findings())
    if syntax_index:
        errors.extend(automatic_school_fetch_findings(syntax_index))
    errors.extend(audit_wiring_findings())

    report_lines = [
        "# 逐份源码质量审查",
        "",
        f"扫描 Swift 文件：{len(swift_files())} 个",
        "",
        "## 需要修复",
        *(errors or ["无"]),
        "",
        "## 人工审查候选",
        *(review or ["无"]),
        "",
    ]
    report = "\n".join(report_lines)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(report, encoding="utf-8")
    findings = errors
    if len(findings) <= OUTPUT_LINE_LIMIT:
        if findings:
            print("\n".join(findings))
    else:
        print(f"代码质量检查共 {len(findings)} 项 · {relative(REPORT_PATH)}")

    if errors:
        return 1
    return 0




def self_test_findings(checker) -> list[str]:
    try:
        return checker()
    except AssertionError as error:
        frame = traceback.extract_tb(error.__traceback__)[-1]
        return [f"自测失败 {checker.__name__}：{frame.filename}:{frame.lineno} {error}"]


def combined_main() -> int:
    from code_quality_tests import checker_boundary_findings
    started = time.monotonic()
    try:
        syntax_index = swift_syntax_index(swift_files())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"[失败] SwiftSyntax 索引：{error}", file=sys.stderr)
        return 1
    ui_path = SCRIPT_ROOT / "check-ui-consistency.py"
    spec = importlib.util.spec_from_file_location("check_ui_consistency", ui_path)
    if spec is None or spec.loader is None:
        print(f"[失败] UI 检查器加载：{ui_path}", file=sys.stderr)
        return 1
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    indexed = time.monotonic()
    test_rules = "--self-test" in sys.argv
    quality_boundaries = self_test_findings(checker_boundary_findings) if test_rules else []
    ui_boundaries = [finding for checker in (
        module.ast_marker_boundary_findings, module.source_boundary_findings,
        module.map_theme_color_contract_findings, module.interaction_inventory_boundary_findings,
    ) for finding in self_test_findings(checker)] if test_rules else []
    if quality_boundaries or ui_boundaries:
        print('\n'.join(quality_boundaries + ui_boundaries))
        return 1
    tested = time.monotonic()
    ui_status = module.main(syntax_index, ui_boundaries)
    ui_checked = time.monotonic()
    quality_status = main(syntax_index, quality_boundaries)
    explanatory_text_report()
    print(f'审计耗时：索引 {indexed - started:.1f} 秒 · 规则自测 {tested - indexed:.1f} 秒 · '
        f'UI {ui_checked - tested:.1f} 秒 · 代码 {time.monotonic() - ui_checked:.1f} 秒')
    return int(ui_status != 0 or quality_status != 0)


if __name__ == "__main__":
    with static_audit_lock():
        raise SystemExit(combined_main() if "--combined" in sys.argv else main())
