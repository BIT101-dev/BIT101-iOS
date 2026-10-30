#!/usr/bin/env python3
"""Run semantic SwiftUI and design system checks."""
import sys
sys.dont_write_bytecode = True
import re
import subprocess
from command_output import show_report_lines
from ui_rules import (
    DERIVED_DESIGN_TOKEN, DESIGN_SYSTEM, DESIGN_SYSTEM_SOURCES, DIRECT_FLOATING_MATERIAL,
    DIRECT_GRID_ITEM_GEOMETRY, DIRECT_GROUPED_LIST_STYLE, DIRECT_INPUT_PLACEHOLDER,
    DIRECT_LIST_SECTION_SPACING, DIRECT_LOCAL_CGFLOAT_LITERAL, DIRECT_PLAIN_LIST_STYLE,
    DIRECT_SEMANTIC_COLOR_RULES, DIRECT_STROKE_GEOMETRY, DIRECT_THUMBNAIL_GEOMETRY,
    DIRECT_VISUAL_RULES, PADDING_LITERAL, PLAIN_LIST_EXCEPTIONS, REPEATED_DESIGN_TOKEN,
    REPORT_PATH, ROOT, STACK_SPACING_LITERAL, append_rule_finding, call_name,
    check_accessibility_coverage, check_component_contracts, check_composer_lifecycle,
    check_contextual_component_colors, check_design_token_boundaries, check_error_report_coverage,
    check_fonts, check_haptic_consistency, check_interactive_list_colors,
    check_page_theme_consistency, check_registered_visual_contracts, check_ui_test_inventory,
    is_registered_cgfloat_contract, is_registered_map_theme_color_definition,
    is_reviewed_fixed_geometry, list_has_grouped_style, mask_comments, mask_literals_and_comments,
    pattern_line_number, pattern_nodes, rendered_component_counts, source_relative, source_text,
    swift_files, syntax_index,
)
from ui_rule_tests import ast_marker_boundary_findings, source_boundary_findings, map_theme_color_contract_findings, interaction_inventory_boundary_findings
from code_quality_rules import static_audit_lock
from swift_type_index import SwiftBindingTypes
from ui_source_facts import UIAuditContext, is_semantic_color_member

def main(shared_syntax: dict[str, dict] | None = None, boundary_findings: list[str] | None = None) -> int:
    swift_files.cache_clear()
    source_text.cache_clear()

    if not DESIGN_SYSTEM.is_file():
        print(f"[失败] 缺少设计系统入口：{DESIGN_SYSTEM.relative_to(ROOT)}", file=sys.stderr)
        return 1

    errors: list[str] = []
    if shared_syntax is None:
        try:
            syntax = syntax_index()
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            print(f"[失败] SwiftSyntax 索引：{error}", file=sys.stderr)
            return 1
    else:
        syntax = shared_syntax
    syntax = UIAuditContext(syntax)
    errors.extend(boundary_findings or [])
    color_types = SwiftBindingTypes(syntax)
    for facts in syntax.values():
        facts["renderedScopeFacts"] = {}
    check_component_contracts(errors, syntax)
    check_composer_lifecycle(errors, syntax)
    check_haptic_consistency(errors, syntax)
    check_error_report_coverage(errors, syntax)
    check_ui_test_inventory(errors, syntax)
    check_accessibility_coverage(errors, syntax)
    check_fonts(errors, syntax)
    check_design_token_boundaries(errors, syntax)
    check_page_theme_consistency(errors, syntax)
    check_contextual_component_colors(errors, syntax)
    check_interactive_list_colors(errors, syntax)
    check_registered_visual_contracts(errors)
    app_card_uses = 0
    floating_stack_uses = 0
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        relative = path.relative_to(ROOT)
        relative_source = source_relative(path)
        raw_source = source_text(path)
        facts = syntax[str(path)]
        components = rendered_component_counts(facts, syntax)
        app_card_uses += components['AppCard']
        floating_stack_uses += components['AppFloatingActionStack']
        for invocation in facts.get("invocations", []):
            name = call_name(invocation["calledExpression"])
            if name != "ZStack":
                continue
            invocation_source = mask_literals_and_comments(invocation["value"])
            if re.match(
                r"ZStack\s*\(\s*alignment\s*:\s*\.bottomTrailing\s*\)", invocation_source
            ) and re.search(r"\b(?:Floating|FAB)", invocation_source):
                if "AppFloatingActionStack" not in invocation_source:
                    errors.append(f"{relative}: 右下角操作组必须使用 AppFloatingActionStack")
        emitted_rule_findings: set[tuple[str, int, str]] = set()
        for pattern, message in DIRECT_VISUAL_RULES:
            if path.name == "AppLayoutComponents.swift" and pattern in (
                DIRECT_GROUPED_LIST_STYLE, DIRECT_LIST_SECTION_SPACING, DIRECT_FLOATING_MATERIAL
            ):
                continue
            for node in pattern_nodes(facts, pattern):
                if pattern is DIRECT_LOCAL_CGFLOAT_LITERAL and is_registered_cgfloat_contract(path, node):
                    continue
                if pattern in (
                    DIRECT_GRID_ITEM_GEOMETRY,
                    DIRECT_STROKE_GEOMETRY,
                    DIRECT_THUMBNAIL_GEOMETRY,
                ) and is_reviewed_fixed_geometry(path, raw_source, pattern, node):
                    continue
                pattern_source = mask_comments(node["value"]) if pattern is DIRECT_INPUT_PLACEHOLDER else mask_literals_and_comments(node["value"])
                for match in pattern.finditer(pattern_source):
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(errors, emitted_rule_findings, relative, line_number, message, pattern)
        for pattern, palette_name in DIRECT_SEMANTIC_COLOR_RULES:
            for node in pattern_nodes(facts, pattern):
                pattern_source = mask_literals_and_comments(node["value"])
                if pattern.search(pattern_source) is None:
                    continue
                if not is_semantic_color_member(str(path), node, color_types):
                    continue
                if is_registered_map_theme_color_definition(path, raw_source, node):
                    continue
                for match in pattern.finditer(pattern_source):
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(
                        errors, emitted_rule_findings, relative, line_number, f"请使用 {palette_name}", pattern
                    )

        for pattern, label in (
            (PADDING_LITERAL, "padding"),
            (STACK_SPACING_LITERAL, "stack spacing"),
        ):
            for node in pattern_nodes(facts, pattern):
                pattern_source = mask_literals_and_comments(node["value"])
                for match in pattern.finditer(pattern_source):
                    if float(match.group(1)) == 0:
                        continue
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(
                        errors,
                        emitted_rule_findings,
                        relative,
                        line_number,
                        f"{label} 必须使用 AppDesignSystem.Spacing 或专用语义令牌",
                        pattern,
                    )

        if path not in DESIGN_SYSTEM_SOURCES:
            for pattern in (DERIVED_DESIGN_TOKEN, REPEATED_DESIGN_TOKEN):
                for node in pattern_nodes(facts, pattern):
                    pattern_source = mask_literals_and_comments(node["value"])
                    for match in pattern.finditer(pattern_source):
                        line_number = pattern_line_number(raw_source, node, match.start())
                        append_rule_finding(
                            errors,
                            emitted_rule_findings,
                            relative,
                            line_number,
                            "设计令牌不得通过比例或重复相加/相减二次运算；请直接使用语义令牌",
                            pattern,
                        )

        if relative_source not in PLAIN_LIST_EXCEPTIONS:
            for node in pattern_nodes(facts, DIRECT_PLAIN_LIST_STYLE):
                pattern_source = mask_literals_and_comments(node["value"])
                for match in DIRECT_PLAIN_LIST_STYLE.finditer(pattern_source):
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(
                        errors,
                        emitted_rule_findings,
                        relative,
                        line_number,
                        "plain 列表只允许消息中心使用",
                        DIRECT_PLAIN_LIST_STYLE,
                    )

    if app_card_uses == 0:
        errors.append("公共卡片组件需要在生产视图中调用 AppCard")
    if floating_stack_uses == 0:
        errors.append("浮动操作组件需要在生产视图中调用 AppFloatingActionStack")

    # 按 List 表达式检查样式归属，消息页沿用 plain 列表。
    for path in swift_files():
        if path == DESIGN_SYSTEM:
            continue
        if source_relative(path) in PLAIN_LIST_EXCEPTIONS:
            continue
        facts = syntax[str(path)]
        for control in facts["listControls"]:
            if not list_has_grouped_style(control, facts["listStyleModifiers"]):
                errors.append(f"{path.relative_to(ROOT)}: {'.'.join(control['scope'])} List 必须由自身表达式接入 appGroupedListStyle")

    if errors:
        lines = ["[失败] UI 一致性检查：", *errors]
        report = "\n".join(lines)
        REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
        REPORT_PATH.write_text(report + "\n", encoding="utf-8")
        show_report_lines((line + '\n' for line in lines), REPORT_PATH, 'UI 一致性检查')
        return 1

    REPORT_PATH.unlink(missing_ok=True)
    if shared_syntax is None:
        print(f"[通过] UI 一致性检查（扫描 {len(swift_files())} 个 Swift 文件）")
    return 0


if __name__ == "__main__":
    with static_audit_lock():
        if sys.argv[1:] == ["--self-test"]:
            findings = [*ast_marker_boundary_findings(), *interaction_inventory_boundary_findings(),
                *source_boundary_findings(), *map_theme_color_contract_findings()]
            if findings:
                print("\n".join(findings), file=sys.stderr)
            else:
                print("[通过] UI 一致性检查器自测")
            raise SystemExit(int(bool(findings)))
        raise SystemExit(main(boundary_findings=[]))
