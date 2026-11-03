"""Focused checks for ui visual tests."""

from ui_source_facts import ROOT
from pathlib import Path
from swift_source_index import swift_syntax_index_sources


def explanatory_text_boundary_findings() -> list[str]:
    "验证模块界面中的 footer 与 description 进入文案审查。"
    import ui_source_facts as rules
    import shutil
    from contextlib import redirect_stdout
    from io import StringIO
    from unittest.mock import patch

    fixture = ROOT / ".build/static-audit/explanatory-self-test"
    path = fixture / "Modules/DesignSystemKit/Sources/AppStateComponents.swift"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        'Section { Text("内容") } footer: {\nText("模块提示")\n}\n'
        'ContentUnavailableView { Text("状态") } description: {\nText("模块说明")\n}\n'
        'Section { Text("内容") } footer: { Text(\n"多行提示"\n).font(.body); Text(message) }\n'
        'ContentUnavailableView("空", systemImage: "x", description: Text(\n"构造说明"\n))\n'
        'AppEmptyState(title: "空", systemImage: "x", message: "传入说明")\n'
        'Section { Text("内容") } footer: { Text("换个关键词试试。") }\n'
        '// Section { } footer: { Text("注释候选") }\n'
    )
    try:
        with patch.object(rules, "ROOT", fixture), redirect_stdout(StringIO()):
            rules.explanatory_text_report()
        report = (fixture / ".build/explanatory-text-report.txt").read_text()
        assert "模块提示" in report and "模块说明" in report and "Modules/DesignSystemKit" in report
        assert all(
            value in report for value in ("多行提示", "Text(message)", "构造说明", "传入说明")
        )
        assert (
            ".font" not in report and "换个关键词试试。" not in report and "注释候选" not in report
        )
    except (AssertionError, OSError) as error:
        return [f"解释文案范围自测：{error}"]
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return checker_report_boundary_findings()


def checker_report_boundary_findings() -> list[str]:
    from contextlib import redirect_stdout
    from io import StringIO
    import importlib.util
    import shutil
    import subprocess
    import sys
    from types import ModuleType, SimpleNamespace
    from unittest.mock import patch

    fixture = ROOT / ".build/static-audit/explanatory-self-test"
    names = ("code-quality-report.txt", "ui-consistency-report.txt", "explanatory-text-report.txt")
    reports = [fixture / ".build" / name for name in names]
    (fixture / ".build/static-audit").mkdir(parents=True, exist_ok=True)
    try:
        for report in reports:
            report.write_text("previous report")
        audit = (ROOT / "Scripts/run-static-audit.sh").read_text()
        cleanup = audit.split("trap 'exit 143' TERM\n", 1)[1].split("\nSWIFT_FRONTEND=", 1)[0]
        result = subprocess.run(
            [
                "zsh",
                "-c",
                'ROOT_DIR="$1"\nLOG_DIR="$ROOT_DIR/.build/static-audit"\ngroup_names=(checkers)\n'
                + cleanup,
                "checker-report-cleanup",
                str(fixture),
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == 0, result.stderr
        assert [report for report in reports if report.exists()] == [], "审计启动需要清理固定报告"
        spec = importlib.util.spec_from_file_location(
            "checker_report_self_test", ROOT / "Scripts/check-code-quality.py"
        )
        subject = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(subject)
        visited = []

        def quality_probe():
            raise AssertionError("quality fixture failure")

        def ui_probe():
            raise AssertionError("UI fixture failure")

        def write_report(index, findings):
            visited.append(names[index])
            reports[index].write_text("\n".join(findings))
            return int(bool(findings))

        module = ModuleType("checker_ui_self_test")
        module.ast_marker_boundary_findings = ui_probe
        module.source_boundary_findings = lambda: visited.append("source") or []
        module.map_theme_color_contract_findings = lambda: visited.append("theme") or []
        module.interaction_inventory_boundary_findings = lambda: (
            visited.append("interactions") or []
        )
        module.main = lambda syntax: write_report(1, [])
        module.swift_files = lambda: []
        ui_spec = SimpleNamespace(
            name=module.__name__, loader=SimpleNamespace(exec_module=lambda loaded: None)
        )
        with (
            patch.dict(sys.modules),
            patch.object(subject, "swift_files", return_value=[]),
            patch.object(subject, "swift_syntax_index", return_value={}),
            patch("code_quality_tests.checker_boundary_findings", new=quality_probe),
            patch.object(sys, "argv", ["check-code-quality.py", "--combined", "--self-test"]),
            patch.object(subject.importlib.util, "spec_from_file_location", return_value=ui_spec),
            patch.object(subject.importlib.util, "module_from_spec", return_value=module),
            patch.object(subject, "main", side_effect=lambda syntax: write_report(0, [])),
            patch.object(
                subject,
                "explanatory_text_report",
                side_effect=lambda: write_report(2, ["current source"]),
            ),
            redirect_stdout(output := StringIO()),
        ):
            assert subject.combined_main() == 1, "自测失败需要保留失败状态"
        assert visited == [names[1], names[0], names[2], "source", "theme", "interactions"], (
            "工作区报告先完成，规则自测随后输出诊断"
        )
        for probe in ("quality_probe", "ui_probe"):
            assert probe in output.getvalue() and Path(__file__).name + ":" in output.getvalue(), (
                "诊断需要记录失败组与位置"
            )
        assert [report.read_text() for report in reports] == ["", "", "current source"], (
            "规则自测失败时保留当前工作区报告"
        )
    except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
        return [f"组合检查报告自测：{error}"]
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return []


def visual_contract_boundary_findings() -> list[str]:
    list_semantics_boundary_self_test()
    text_loading_state_boundary_self_test()
    from ui_rules import visual_contract_present, rendered_component_counts

    marker = "StrokeStyle(lineWidth: 2, dash: [5, 4])"
    contract = "Modules/CourseFeature/Sources/CourseHistoryGradesViews.swift"
    moved = ROOT / "Modules/CourseFeature/Sources/Moved.swift"
    template = (
        'struct CourseHistoryGradesChart: View { var body: some View { Text("chart").lineStyle(MAR'
        "KER) } }"
    )
    assert visual_contract_present(
        contract,
        marker,
        {moved: template.replace("MARKER", "StrokeStyle(\n lineWidth: 2,\n dash: [5, 4]\n)")},
    )
    assert not visual_contract_present(contract, marker, {moved: "// " + marker})
    assert not visual_contract_present(
        contract, marker, {moved: marker.replace("[5, 4]", "[5, 3]")}
    )
    assert not visual_contract_present(
        contract, marker, {moved: "func unused() { _ = " + marker + " }"}
    )
    assert not visual_contract_present(
        contract,
        marker,
        {
            moved: (
                'struct CourseHistoryGradesChart: View { var body: some View { Text("chart") }; fu'
                'nc unused() -> some View { Text("unused").lineStyle('
            )
            + marker
            + ") } }"
        },
    )
    assert not visual_contract_present(
        contract,
        marker,
        {
            moved: template.replace("CourseHistoryGradesChart", "OtherChart").replace(
                "MARKER", marker
            )
        },
    )
    for condition, present in [
        ("false", False),
        ("true", True),
        ("1 == 2", False),
        ("isVisible", True),
    ]:
        content = f'if {condition} {{ Text("chart").lineStyle({marker}) }} else {{ Text("plain") }}'
        sample = template.replace('Text("chart").lineStyle(MARKER)', content)
        assert visual_contract_present(contract, marker, {moved: sample}) == present
        sample = (
            template.replace(
                'Text("chart").lineStyle(MARKER)',
                f'if {condition} {{ helper() }} else {{ Text("plain") }}',
            )[:-1]
            + f'; func helper() -> some View {{ Text("chart").lineStyle({marker}) }} }}'
        )
        assert visual_contract_present(contract, marker, {moved: sample}) == present
        sample = (
            f"struct Screen: View {{ var body: some View {{ if "
            f"{condition}"
            f' {{ AppCard {{ Text("chart") }} }} }} }}'
        )
        syntax = swift_syntax_index_sources({str(moved): sample})
        assert bool(rendered_component_counts(syntax[str(moved)], syntax)["AppCard"]) == present
    for content in [
        f'if true {{ Text("plain") }} else {{ Text("chart").lineStyle({marker}) }}',
        f'let hidden = false; if hidden {{ Text("chart").lineStyle({marker}) }}',
        f'let hidden = false; let alias = hidden; if alias {{ Text("chart").lineStyle({marker}) }}',
        f'false ? Text("chart").lineStyle({marker}) : Text("plain")',
        f'HStack {{ Text("图表"); if false {{ Text("chart").lineStyle({marker}) }} }}',
        f'HStack {{ false ? Text("图表").lineStyle({marker}) : Text("plain") }}',
        f'return Text("plain"); Text("chart").lineStyle({marker})',
    ]:
        assert not visual_contract_present(
            contract, marker, {moved: template.replace('Text("chart").lineStyle(MARKER)', content)}
        )
    source = template.replace(
        'Text("chart").lineStyle(MARKER)', f'if false {{ Text("chart").lineStyle({marker}) }}'
    )
    custom = ROOT / "Modules/CourseFeature/Sources/Operators.swift"
    assert visual_contract_present(
        contract, marker, {moved: source.replace("if false", "if 1 == 2"), custom: "struct Bool {}"}
    )
    return []


def text_loading_state_boundary_self_test() -> None:
    from ui_rules import text_loading_state_findings

    path = str(ROOT / "BIT101-iOS/LoadingProbe.swift")
    bodies = [
        ('ProgressView("加载中")', True),
        ('ProgressView(#"加载中"#)', True),
        ("ProgressView()", False),
        ('let example = #"ProgressView("loading")"#; Text(example)', False),
        ('// ProgressView("loading")\nText("加载中")', False),
    ]
    for body, expected in bodies:
        syntax = swift_syntax_index_sources(
            {path: "struct Screen: View { var body: some View { " + body + " } }"}
        )
        assert bool(text_loading_state_findings(syntax)) == expected, body


def list_semantics_boundary_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from ui_rules import list_semantics_findings

    path = ROOT / ".build/static-audit/list-semantics-self-test.swift"
    cases = [
        (
            'struct Sample: View { var body: some View { List { Section("标题") { Text("正文") } } } }',
            0,
        ),
        (
            (
                'struct Sample: View { var body: some View { List { Section { Text("正文") } footer:'
                ' { Text("说明") } } } }'
            ),
            1,
        ),
        (
            (
                'struct Sample: View { var body: some View { List { Section(header: Text("标题"), fo'
                'oter: hint) { Text("正文") } } } }'
            ),
            1,
        ),
        ("struct AppListSectionHeader: View { var body: some View { Text(title) } }", 0),
        (
            (
                "struct AppListSectionHeader: View { var body: some View { Text(title).font(AppDes"
                "ignSystem.Typography.footnote) } }"
            ),
            1,
        ),
        (
            (
                "struct AppListSectionHeader: View { var body: some View { Text(title).foregroundS"
                "tyle(.secondary) } }"
            ),
            1,
        ),
        (
            (
                'struct Row: View { var body: some View { Image(systemName: "chevron.right").foreg'
                "roundStyle(.tint) } }"
            ),
            1,
        ),
        (
            (
                'struct Row: View { var body: some View { Image(systemName: "chevron.right").foreg'
                "roundStyle(.secondary) } }"
            ),
            0,
        ),
        (
            (
                'struct AppRefreshStatusRow: View { var body: some View { Button("刷新") {}.font(App'
                "DesignSystem.Typography.body); Text(trailingText).font(AppDesignSystem.Typography"
                ".body) } }"
            ),
            0,
        ),
        (
            (
                'struct AppRefreshStatusRow: View { var body: some View { Button("刷新") {}.font(App'
                "DesignSystem.Typography.body); Text(trailingText).font(AppDesignSystem.Typography"
                ".footnote) } }"
            ),
            1,
        ),
    ]
    for source, expected in cases:
        syntax = swift_syntax_index_sources({str(path): source})
        assert len(list_semantics_findings(syntax)) == expected, source
