#!/usr/bin/env python3
"""从教务导出的全校课程表生成地图地点回归测试数据。

脚本读取“学校校区”和“已排时间地点”，按 (校区, 原始地点) 去重并合并历史案例。
fixture 保存地点、人工确认的 expected 和审核状态。新地点沿显式参数写为 pending，
审核后选择 mapped 或 excluded，回归测试核对审核完成及对应地点结果。
"""

from __future__ import annotations

import argparse
import json
import re
import warnings
from contextlib import closing
from pathlib import Path
from validation_provenance import report_lock

SUPPORTED_CAMPUSES = {"中关村校区", "良乡校区"}
FIXTURE_PATH = Path(__file__).resolve().parents[1] / "BIT101-iOSTests/Fixtures/campus-map-locations.json"
TIME_PATTERN = re.compile(
    r"星期[一二三四五六日天]\s*"
    r"(?:\[[^\]]+\]|第\s*\d+\s*节(?:\s*-\s*第\s*\d+\s*节)?)"
    r"\s*(.*?)"
    r"(?=(?:[;；]|[,，]\s*(?=[0-9单双周第()（）\-—至~、，,\s]*星期))|$)"
)


def extract_unique_locations(path: Path) -> list[tuple[str, str]]:
    from openpyxl import load_workbook
    warnings.filterwarnings("ignore", message="Workbook contains no default style")
    with closing(load_workbook(path, read_only=True, data_only=True)) as workbook:
        sheet = workbook.active
        sheet.reset_dimensions()  # 教务导出偶尔错误地把 dimension 标成 A1。
        rows = sheet.iter_rows(values_only=True)
        headers = next(rows)
        columns = {name: index for index, name in enumerate(headers)}
        required = {"学校校区", "已排时间地点"}
        if not required.issubset(columns):
            raise ValueError(f"工作簿缺少列：{', '.join(sorted(required - columns.keys()))}")

        locations: set[tuple[str, str]] = set()
        required_width = max(columns[name] for name in required) + 1
        for row in rows:
            if len(row) < required_width:
                continue
            campus = str(row[columns["学校校区"]] or "").strip()
            schedule = row[columns["已排时间地点"]]
            if campus not in SUPPORTED_CAMPUSES or not schedule:
                continue
            for match in TIME_PATTERN.finditer(str(schedule)):
                classroom = match.group(1).strip(" \t,，;；")
                if classroom:
                    locations.add((campus, classroom))
        return sorted(locations)


def merge_locations(old_rows: list[dict], locations: list[tuple[str, str]]) -> list[dict]:
    retained = {(row["campus"], row["classroom"]): row for row in old_rows}
    for campus, classroom in locations:
        retained.setdefault((campus, classroom), {
            "campus": campus, "classroom": classroom, "expected": None, "review": "pending",
        })
    return [retained[key] for key in sorted(retained)]


def update_fixture(locations: list[tuple[str, str]], allow_new: bool) -> tuple[int, int]:
    with report_lock(path=FIXTURE_PATH):
        old_rows = json.loads(FIXTURE_PATH.read_text(encoding="utf-8")) if FIXTURE_PATH.exists() else []
        decisions = {(row["campus"], row["classroom"]): row.get("expected") for row in old_rows}
        new_locations = [item for item in locations if item not in decisions]
        if new_locations and not allow_new:
            preview = "\n".join(f"- {campus} / {classroom}" for campus, classroom in new_locations[:20])
            raise SystemExit(
                f"发现 {len(new_locations)} 个新地点需要审核：\n{preview}\n"
                "审核后更新 expected，或显式使用 --allow-new 生成待处理项。"
            )

        rows = merge_locations(old_rows, locations)
        FIXTURE_PATH.parent.mkdir(parents=True, exist_ok=True)
        incoming = FIXTURE_PATH.with_suffix(".incoming")
        try:
            incoming.write_text("[\n" + ",\n".join("  " + json.dumps(row, ensure_ascii=False) for row in rows) + "\n]\n", encoding="utf-8")
            incoming.replace(FIXTURE_PATH)
        finally:
            incoming.unlink(missing_ok=True)
        return len(rows), len(new_locations)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("xlsx", type=Path)
    parser.add_argument(
        "--allow-new",
        action="store_true",
        help="将新增地点写为 review=pending，供人工审核",
    )
    args = parser.parse_args()

    rows, new_locations = update_fixture(extract_unique_locations(args.xlsx), args.allow_new)
    print(f"写入 {rows} 条去重地点；新增待审核 {new_locations} 条：{FIXTURE_PATH}")


if __name__ == "__main__":
    main()
