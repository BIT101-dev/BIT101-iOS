#!/usr/bin/env python3
"""Generate an interactive course-history audit viewer."""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


# --- Style Config ---
COLORS = {
    "likely_formal": "#3e7ad9",
    "likely_makeup": "#d95f59",
    "uncertain": "#f4a259",
    "predicted": "#5b8e7d",
    "ink": "#241711",
    "muted": "#826f64",
    "surface": "#fffaf5",
    "border": "#ead8c8",
}

DEFAULT_FIXTURE = Path(__file__).resolve().parents[1] / "BIT101-iOSTests" / "CourseHistoryAuditFixture.json"
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / ".build" / "course-history-audit.html"
MANUAL_LABELS = {"likely_formal", "likely_makeup", "uncertain"}


def load_fixture(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def embedded_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")


def normalize_fixture(fixture: dict) -> dict:
    courses = fixture.get("courses")
    if not isinstance(courses, list):
        raise ValueError("fixture.courses 必须是数组")

    counts = {label: 0 for label in MANUAL_LABELS}
    grade_count = 0
    for course in courses:
        grades = course.get("grades")
        if not isinstance(grades, list):
            raise ValueError("课程 grades 必须是数组")
        labels = set()
        for grade in grades:
            label = grade.get("manual_label")
            if label not in MANUAL_LABELS:
                raise ValueError(f"人工标签无法识别：{label}")
            counts[label] += 1
            labels.add(label)
            grade_count += 1
        course["manual_review_label"] = next(iter(labels)) if len(labels) == 1 else "mixed"

    fixture["manual_label_counts"] = counts
    fixture["sampled_course_count"] = len(courses)
    fixture["sampled_grade_count"] = grade_count
    return fixture


def build_html(fixture: dict) -> str:
    data = embedded_json(fixture)
    colors = embedded_json(COLORS)
    return f'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>课程历史人工分类审查</title>
  <style>
    :root {{
      color-scheme: light;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", sans-serif;
      background: #fff7ee;
      color: {COLORS["ink"]};
    }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; background: linear-gradient(145deg, #fff7ee, #f8eee5); }}
    main {{ width: min(1180px, calc(100vw - 32px)); margin: 24px auto 56px; }}
    header, .toolbar, .summary, .chart-card, .table-card {{
      background: rgba(255, 250, 245, .92);
      border: 1px solid {COLORS["border"]};
      border-radius: 18px;
      box-shadow: 0 12px 34px rgba(91, 50, 25, .08);
    }}
    header {{ padding: 24px; }}
    h1 {{ margin: 0 0 8px; font-size: clamp(22px, 3vw, 32px); }}
    h2 {{ margin: 0; font-size: 19px; }}
    p {{ margin: 0; color: {COLORS["muted"]}; line-height: 1.6; }}
    .toolbar {{ display: flex; flex-wrap: wrap; gap: 10px; align-items: center; padding: 14px; margin-top: 16px; }}
    button, select {{
      border: 1px solid {COLORS["border"]}; border-radius: 10px; background: #fff; color: {COLORS["ink"]};
      min-height: 38px; padding: 0 13px; font: inherit; cursor: pointer;
    }}
    button:hover, select:hover {{ border-color: #d99c73; }}
    button:focus-visible, select:focus-visible {{ outline: 3px solid rgba(62, 122, 217, .25); outline-offset: 2px; }}
    .primary {{ background: {COLORS["ink"]}; color: #fff7ee; border-color: {COLORS["ink"]}; }}
    .save-status {{ font-size: 13px; color: {COLORS["muted"]}; min-width: 110px; }}
    .toolbar .spacer {{ flex: 1; }}
    .shortcut {{ font-size: 13px; color: {COLORS["muted"]}; }}
    .summary {{ display: grid; grid-template-columns: repeat(5, minmax(120px, 1fr)); gap: 12px; padding: 16px; margin-top: 16px; }}
    .metric {{ padding: 12px; border-radius: 12px; background: #fff; }}
    .metric strong {{ display: block; font-size: 22px; margin-top: 4px; }}
    .metric span {{ color: {COLORS["muted"]}; font-size: 13px; }}
    .course-heading {{ display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: baseline; margin: 24px 2px 12px; }}
    .course-heading p {{ font-size: 14px; }}
    .chart-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }}
    .chart-card {{ padding: 16px; min-width: 0; }}
    .chart-card h2 {{ margin-bottom: 8px; }}
    svg {{ display: block; width: 100%; height: auto; overflow: visible; }}
    .axis {{ stroke: #bda997; stroke-width: 1; }}
    .axis-label {{ fill: {COLORS["muted"]}; font-size: 12px; }}
    .term-label {{ fill: {COLORS["muted"]}; font-size: 11px; }}
    .course-line {{ fill: none; stroke: #9b8170; stroke-width: 2; opacity: .65; }}
    .score-line.avg {{ fill: none; stroke: #3e7ad9; stroke-width: 2.5; }}
    .score-line.max {{ fill: none; stroke: #5b8e7d; stroke-width: 2.5; stroke-dasharray: 6 4; }}
    .legend {{ display: flex; flex-wrap: wrap; gap: 8px 16px; margin-top: 10px; font-size: 13px; color: {COLORS["muted"]}; }}
    .legend-item {{ display: inline-flex; align-items: center; gap: 6px; }}
    .dot {{ width: 10px; height: 10px; border-radius: 50%; display: inline-block; }}
    .ring {{ width: 12px; height: 12px; border: 2px solid {COLORS["predicted"]}; border-radius: 50%; display: inline-block; }}
    .table-card {{ margin-top: 16px; overflow: auto; }}
    table {{ width: 100%; border-collapse: collapse; min-width: 760px; }}
    th, td {{ padding: 11px 13px; text-align: left; border-bottom: 1px solid #f0e2d7; white-space: nowrap; }}
    th {{ color: {COLORS["muted"]}; font-size: 13px; font-weight: 600; background: #fff7ee; position: sticky; top: 0; }}
    tr:last-child td {{ border-bottom: 0; }}
    .label {{ display: inline-flex; padding: 4px 8px; border-radius: 999px; font-size: 12px; font-weight: 650; }}
    .label.formal {{ color: #234d98; background: #e5efff; }}
    .label.makeup {{ color: #9b322f; background: #ffe8e4; }}
    .label.uncertain {{ color: #95550f; background: #fff0d9; }}
    .manual-editor {{ min-height: 32px; padding: 0 8px; font-size: 13px; }}
    .match {{ color: #27754b; }}
    .mismatch {{ color: #b44537; font-weight: 650; }}
    .note {{ margin-top: 12px; font-size: 13px; color: {COLORS["muted"]}; }}
    @media (max-width: 820px) {{
      main {{ width: min(100% - 20px, 1180px); margin-top: 10px; }}
      .summary {{ grid-template-columns: repeat(2, minmax(120px, 1fr)); }}
      .chart-grid {{ grid-template-columns: 1fr; }}
      header, .toolbar, .summary, .chart-card, .table-card {{ border-radius: 14px; }}
    }}
  </style>
</head>
<body>
<main>
  <header>
    <h1>课程历史人工分类审查</h1>
    <p>左右方向键切换课程，课程图表展示学习人数、成绩、人工标签和算法候选。</p>
  </header>

  <section class="toolbar" aria-label="课程导航">
    <button id="previous" type="button">← 上一门</button>
    <button id="next" type="button" class="primary">下一门 →</button>
    <select id="course-select" aria-label="选择课程"></select>
    <select id="filter-select" aria-label="课程筛选">
      <option value="all">全部课程</option>
      <option value="manual">存在 likely_makeup</option>
      <option value="candidate">存在算法候选</option>
      <option value="disagreement">存在确定标签分歧</option>
    </select>
    <button id="promote-uncertain" type="button">uncertain → likely_makeup</button>
    <button id="save-fixture" type="button" class="primary">保存标注</button>
    <span id="save-status" class="save-status">自动保存待命</span>
    <span class="spacer"></span>
    <span id="position" class="shortcut"></span>
    <span class="shortcut">← / → 切换 · Home / End 跳转</span>
  </section>

  <section id="summary" class="summary"></section>
  <div class="course-heading">
    <h2 id="course-title"></h2>
    <p id="course-meta"></p>
  </div>
  <section class="chart-grid">
    <article class="chart-card">
      <h2>学习人数（线性坐标）</h2>
      <div id="count-chart"></div>
      <div class="legend">
        <span class="legend-item"><i class="dot" style="background:{COLORS["likely_formal"]}"></i>likely_formal</span>
        <span class="legend-item"><i class="dot" style="background:{COLORS["likely_makeup"]}"></i>likely_makeup</span>
        <span class="legend-item"><i class="dot" style="background:{COLORS["uncertain"]}"></i>uncertain</span>
        <span class="legend-item"><i class="ring"></i>算法候选</span>
      </div>
    </article>
    <article class="chart-card">
      <h2>成绩统计</h2>
      <div id="score-chart"></div>
      <div class="legend">
        <span class="legend-item"><i class="dot" style="background:{COLORS["likely_formal"]}"></i>平均分</span>
        <span class="legend-item"><i class="dot" style="background:{COLORS["predicted"]}"></i>最高分</span>
      </div>
    </article>
  </section>

  <section class="table-card">
    <table>
      <thead><tr><th>学期</th><th>学习人数</th><th>平均分</th><th>最高分</th><th>人工标签（可编辑）</th><th>算法预测</th><th>匹配</th></tr></thead>
      <tbody id="grade-table"></tbody>
    </table>
    <p id="course-note" class="note"></p>
  </section>
</main>
<script>
const FIXTURE = {data};
const COLORS = {colors};
const LABEL_NAMES = {{ likely_formal: "likely_formal", likely_makeup: "likely_makeup", uncertain: "uncertain" }};
const MANUAL_LABELS = ["likely_formal", "likely_makeup", "uncertain"];
const state = {{ filter: "all", visibleCourses: [], index: 0 }};
let isDirty = false;

function formatNumber(value) {{
  return Number.isInteger(value) ? String(value) : Number(value).toFixed(1);
}}

function manualColor(label) {{ return COLORS[label] || COLORS.muted; }}

function updateManualMetadata() {{
  const counts = {{ likely_formal: 0, likely_makeup: 0, uncertain: 0 }};
  for (const course of FIXTURE.courses) {{
    const labels = new Set();
    for (const grade of course.grades) {{
      counts[grade.manual_label] = (counts[grade.manual_label] || 0) + 1;
      labels.add(grade.manual_label);
    }}
    course.manual_review_label = labels.size === 1 ? [...labels][0] : "mixed";
  }}
  FIXTURE.manual_label_counts = counts;
}}

function setSaveStatus(text, dirty = isDirty) {{
  isDirty = dirty;
  document.getElementById("save-status").textContent = text;
}}

async function saveFixture() {{
  updateManualMetadata();
  setSaveStatus("保存中…", true);
  if (window.location.protocol === "file:") {{
    setSaveStatus("请使用 --serve 保存", true);
    return;
  }}
  try {{
    const response = await fetch("/save", {{
      method: "POST",
      headers: {{ "Content-Type": "application/json" }},
      body: JSON.stringify(FIXTURE),
    }});
    if (!response.ok) throw new Error(`HTTP ${{response.status}}`);
    setSaveStatus("已自动写入 fixture", false);
  }} catch (error) {{
    setSaveStatus(`保存失败：${{error.message}}`, true);
  }}
}}

function metricCard(label, value) {{
  return `<div class="metric"><span>${{label}}</span><strong>${{value}}</strong></div>`;
}}

function allMetrics() {{
  let tp = 0, fp = 0, fn = 0, tn = 0, uncertain = 0, predicted = 0, manualMakeup = 0;
  for (const course of FIXTURE.courses) {{
    const candidates = new Set(course.predicted_hidden_terms);
    predicted += candidates.size;
    for (const grade of course.grades) {{
      if (grade.manual_label === "uncertain") {{ uncertain++; continue; }}
      const isPredicted = candidates.has(grade.term);
      if (grade.manual_label === "likely_makeup") {{ manualMakeup++; isPredicted ? tp++ : fn++; }}
      if (grade.manual_label === "likely_formal") {{ isPredicted ? fp++ : tn++; }}
    }}
  }}
  const precision = tp + fp ? tp / (tp + fp) : 0;
  const recall = tp + fn ? tp / (tp + fn) : 0;
  return {{ tp, fp, fn, tn, uncertain, predicted, manualMakeup, precision, recall }};
}}

function isDisagreement(course) {{
  const candidates = new Set(course.predicted_hidden_terms);
  return course.grades.some(grade => grade.manual_label !== "uncertain" && candidates.has(grade.term) !== (grade.manual_label === "likely_makeup"));
}}

function filteredCourses() {{
  return FIXTURE.courses.filter(course => {{
    if (state.filter === "manual") return course.grades.some(grade => grade.manual_label === "likely_makeup");
    if (state.filter === "candidate") return course.predicted_hidden_terms.length > 0;
    if (state.filter === "disagreement") return isDisagreement(course);
    return true;
  }});
}}

function updateCourseList() {{
  state.visibleCourses = filteredCourses();
  if (!state.visibleCourses.length) {{
    state.index = 0;
    renderEmpty();
    return;
  }}
  state.index = Math.min(state.index, state.visibleCourses.length - 1);
  const select = document.getElementById("course-select");
  select.innerHTML = state.visibleCourses.map((course, index) =>
    `<option value="${{index}}">${{index + 1}}. ${{course.course_name}} · ${{course.course_number}}</option>`
  ).join("");
  select.value = String(state.index);
  renderCourse();
}}

function renderSummary() {{
  const metrics = allMetrics();
  document.getElementById("summary").innerHTML = [
    metricCard("课程", FIXTURE.sampled_course_count),
    metricCard("学期记录", FIXTURE.sampled_grade_count),
    metricCard("人工 likely_makeup", metrics.manualMakeup),
    metricCard("算法候选", metrics.predicted),
    metricCard("precision / recall", `${{(metrics.precision * 100).toFixed(1)}}% / ${{(metrics.recall * 100).toFixed(1)}}%`),
  ].join("");
}}

function renderEmpty() {{
  document.getElementById("course-title").textContent = "当前筛选暂无课程";
  document.getElementById("course-meta").textContent = "调整上方筛选条件";
  document.getElementById("count-chart").innerHTML = "";
  document.getElementById("score-chart").innerHTML = "";
  document.getElementById("grade-table").innerHTML = "";
  document.getElementById("course-note").textContent = "";
  document.getElementById("position").textContent = "0 / 0";
}}

function chartGeometry(count) {{
  const width = 560, height = 300;
  const left = 52, right = 14, top = 20, bottom = 76;
  const plotWidth = width - left - right;
  const plotHeight = height - top - bottom;
  return {{ width, height, left, right, top, bottom, plotWidth, plotHeight, x: index =>
    count === 1 ? left + plotWidth / 2 : left + plotWidth * index / (count - 1) }};
}}

function svgText(x, y, text, className, anchor = "middle", extra = "") {{
  return `<text x="${{x}}" y="${{y}}" class="${{className}}" text-anchor="${{anchor}}" ${{extra}}>${{text}}</text>`;
}}

function renderCountChart(course) {{
  const grades = course.grades;
  const geo = chartGeometry(grades.length);
  const maxValue = Math.max(...grades.map(grade => grade.student_num), 1);
  const tickValues = [0, maxValue * 0.25, maxValue * 0.5, maxValue * 0.75, maxValue];
  const y = value => geo.top + geo.plotHeight * (maxValue - value) / maxValue;
  const points = grades.map((grade, index) => [geo.x(index), y(grade.student_num) ]);
  let body = `<svg viewBox="0 0 ${{geo.width}} ${{geo.height}}" role="img" aria-label="学习人数图表">`;
  body += `<line class="axis" x1="${{geo.left}}" y1="${{geo.top}}" x2="${{geo.left}}" y2="${{geo.height - geo.bottom}}"/>`;
  body += `<line class="axis" x1="${{geo.left}}" y1="${{geo.height - geo.bottom}}" x2="${{geo.width - geo.right}}" y2="${{geo.height - geo.bottom}}"/>`;
  for (const tick of tickValues) {{
    const tickY = y(tick);
    body += `<line class="axis" opacity=".25" x1="${{geo.left}}" y1="${{tickY}}" x2="${{geo.width - geo.right}}" y2="${{tickY}}"/>`;
    body += svgText(geo.left - 8, tickY + 4, formatNumber(tick), "axis-label", "end");
  }}
  body += `<polyline class="course-line" points="${{points.map(point => point.join(",")).join(" ")}}"/>`;
  grades.forEach((grade, index) => {{
    const [pointX, pointY] = points[index];
    const candidate = course.predicted_hidden_terms.includes(grade.term);
    body += `<circle cx="${{pointX}}" cy="${{pointY}}" r="6" fill="${{manualColor(grade.manual_label)}}"/>`;
    if (candidate) body += `<circle cx="${{pointX}}" cy="${{pointY}}" r="10" fill="none" stroke="${{COLORS.predicted}}" stroke-width="2.5"/>`;
    body += svgText(pointX, geo.height - geo.bottom + 18, grade.term, "term-label", "end", `transform="rotate(-42 ${{pointX}} ${{geo.height - geo.bottom + 18}})"`);
  }});
  body += svgText(geo.left, 12, "人数", "axis-label", "start");
  body += `</svg>`;
  document.getElementById("count-chart").innerHTML = body;
}}

function renderScoreChart(course) {{
  const grades = course.grades;
  const geo = chartGeometry(grades.length);
  const y = value => geo.top + geo.plotHeight * (100 - value) / 100;
  const avgPoints = grades.map((grade, index) => [geo.x(index), y(grade.avg_score)]);
  const maxPoints = grades.map((grade, index) => [geo.x(index), y(grade.max_score)]);
  let body = `<svg viewBox="0 0 ${{geo.width}} ${{geo.height}}" role="img" aria-label="成绩图表">`;
  body += `<line class="axis" x1="${{geo.left}}" y1="${{geo.top}}" x2="${{geo.left}}" y2="${{geo.height - geo.bottom}}"/>`;
  body += `<line class="axis" x1="${{geo.left}}" y1="${{geo.height - geo.bottom}}" x2="${{geo.width - geo.right}}" y2="${{geo.height - geo.bottom}}"/>`;
  for (const tick of [0, 50, 100]) {{
    const tickY = y(tick);
    body += `<line class="axis" opacity=".25" x1="${{geo.left}}" y1="${{tickY}}" x2="${{geo.width - geo.right}}" y2="${{tickY}}"/>`;
    body += svgText(geo.left - 8, tickY + 4, tick, "axis-label", "end");
  }}
  body += `<polyline class="score-line avg" points="${{avgPoints.map(point => point.join(",")).join(" ")}}"/>`;
  body += `<polyline class="score-line max" points="${{maxPoints.map(point => point.join(",")).join(" ")}}"/>`;
  grades.forEach((grade, index) => {{
    const pointX = geo.x(index);
    body += `<circle cx="${{pointX}}" cy="${{y(grade.avg_score)}}" r="4" fill="${{COLORS.likely_formal}}"/>`;
    body += `<circle cx="${{pointX}}" cy="${{y(grade.max_score)}}" r="4" fill="${{COLORS.predicted}}"/>`;
    body += svgText(pointX, geo.height - geo.bottom + 18, grade.term, "term-label", "end", `transform="rotate(-42 ${{pointX}} ${{geo.height - geo.bottom + 18}})"`);
  }});
  body += svgText(geo.left, 12, "分数", "axis-label", "start");
  body += `</svg>`;
  document.getElementById("score-chart").innerHTML = body;
}}

function labelClass(label) {{
  if (label === "likely_makeup") return "makeup";
  if (label === "uncertain") return "uncertain";
  return "formal";
}}

function renderTable(course) {{
  const candidates = new Set(course.predicted_hidden_terms);
  document.getElementById("grade-table").innerHTML = course.grades.map((grade, index) => {{
    const predicted = candidates.has(grade.term);
    const expected = grade.manual_label === "likely_makeup" ? predicted : grade.manual_label === "likely_formal" ? !predicted : true;
    const matchText = grade.manual_label === "uncertain" ? "待确认" : expected ? "匹配" : "分歧";
    const labelOptions = MANUAL_LABELS.map(label => `<option value="${{label}}" ${{label === grade.manual_label ? "selected" : ""}}>${{LABEL_NAMES[label]}}</option>`).join("");
    return `<tr>
      <td>${{grade.term}}</td><td>${{grade.student_num}}</td><td>${{formatNumber(grade.avg_score)}}</td><td>${{formatNumber(grade.max_score)}}</td>
      <td><select class="manual-editor" data-grade-index="${{index}}" aria-label="${{grade.term}} 人工标签">${{labelOptions}}</select></td>
      <td>${{predicted ? "statisticalCandidate" : "keptVisible"}}</td>
      <td class="${{expected ? "match" : "mismatch"}}">${{matchText}}</td>
    </tr>`;
  }}).join("");
}}

function renderCourse() {{
  const course = state.visibleCourses[state.index];
  if (!course) {{ renderEmpty(); return; }}
  document.getElementById("course-title").textContent = course.course_name;
  document.getElementById("course-meta").textContent = `${{course.course_number}} · ${{course.teachers_name}} · 人工标签 ${{course.manual_review_label}}`;
  document.getElementById("position").textContent = `${{state.index + 1}} / ${{state.visibleCourses.length}}`;
  document.getElementById("course-select").value = String(state.index);
  document.getElementById("course-note").textContent = course.manual_note || "";
  renderCountChart(course);
  renderScoreChart(course);
  renderTable(course);
}}

function move(delta) {{
  if (!state.visibleCourses.length) return;
  state.index = (state.index + delta + state.visibleCourses.length) % state.visibleCourses.length;
  renderCourse();
}}

document.getElementById("previous").addEventListener("click", () => move(-1));
document.getElementById("next").addEventListener("click", () => move(1));
document.getElementById("course-select").addEventListener("change", event => {{ state.index = Number(event.target.value); renderCourse(); }});
document.getElementById("filter-select").addEventListener("change", event => {{ state.filter = event.target.value; state.index = 0; updateCourseList(); }});
document.getElementById("grade-table").addEventListener("change", event => {{
  if (!event.target.matches(".manual-editor")) return;
  const course = state.visibleCourses[state.index];
  const grade = course?.grades[Number(event.target.dataset.gradeIndex)];
  if (!grade) return;
  grade.manual_label = event.target.value;
  updateManualMetadata();
  renderSummary();
  renderCourse();
  saveFixture();
}});
document.getElementById("promote-uncertain").addEventListener("click", () => {{
  let changed = 0;
  for (const course of FIXTURE.courses) for (const grade of course.grades) {{
    if (grade.manual_label === "uncertain") {{ grade.manual_label = "likely_makeup"; changed++; }}
  }}
  updateManualMetadata();
  renderSummary();
  renderCourse();
  setSaveStatus(`已调整 ${{changed}} 条，保存中…`, true);
  saveFixture();
}});
document.getElementById("save-fixture").addEventListener("click", saveFixture);
document.addEventListener("keydown", event => {{
  if (event.target.matches("input, select, textarea, button")) return;
  if (event.key === "ArrowLeft") {{ event.preventDefault(); move(-1); }}
  if (event.key === "ArrowRight") {{ event.preventDefault(); move(1); }}
  if (event.key === "Home") {{ event.preventDefault(); state.index = 0; renderCourse(); }}
  if (event.key === "End") {{ event.preventDefault(); state.index = state.visibleCourses.length - 1; renderCourse(); }}
}});

updateManualMetadata();
renderSummary();
updateCourseList();
</script>
</body>
</html>
'''


def make_handler(fixture_path: Path, output_path: Path):
    class ViewerHandler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            route = self.path.split("?", 1)[0]
            if route not in {"/", "/course-history-audit.html"}:
                self.send_error(404)
                return
            content = output_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def do_POST(self):  # noqa: N802
            route = self.path.split("?", 1)[0]
            if route != "/save":
                self.send_error(404)
                return

            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                payload = normalize_fixture(payload)
                fixture_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                output_path.write_text(build_html(payload), encoding="utf-8")
                response = {"saved": True, "fixture": str(fixture_path)}
                encoded = json.dumps(response, ensure_ascii=False).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
            except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as error:
                self.send_error(400, str(error))

        def log_message(self, _format, *_args):
            return

    return ViewerHandler


def main() -> None:
    parser = argparse.ArgumentParser(description="生成课程历史人工分类审查页面")
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--serve", action="store_true", help="启动本地保存服务，支持网页自动覆写 fixture")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    fixture = normalize_fixture(load_fixture(args.fixture))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(build_html(fixture), encoding="utf-8")
    print(f"课程历史可视化已生成：{args.output}")
    if args.serve:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args.fixture, args.output))
        print(f"标注服务已启动：http://127.0.0.1:{args.port}/")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("标注服务已停止。")
        finally:
            server.server_close()


if __name__ == "__main__":
    main()
