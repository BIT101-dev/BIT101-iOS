#!/usr/bin/env python3
"""Check that SwiftUI pages use the shared design system instead of local copies."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "BIT101-iOS"
DESIGN_SYSTEM = SOURCE_ROOT / "Shared/DesignSystem/AppDesignSystem.swift"

DIRECT_ROUNDED_RECTANGLE = re.compile(r"\bRoundedRectangle\s*\(")
DIRECT_CORNER_RADIUS = re.compile(r"\.cornerRadius\s*\(")
DIRECT_SYSTEM_COLOR = re.compile(
    r"\bColor\s*\(\s*(?:uiColor\s*:\s*)?\.(?:systemBackground|systemGroupedBackground|"
    r"secondarySystemBackground|secondarySystemGroupedBackground|secondarySystemFill)\s*\)"
)
DIRECT_ACCENT_COLOR = re.compile(r"\bColor\.accentColor\b")
DIRECT_SEMANTIC_COLOR_RULES = (
    (re.compile(r"\bColor\.orange\b|(?<![\w.])\.orange\b"), "AppDesignSystem.Palette.highlight"),
    (re.compile(r"\bColor\.red\b|(?<![\w.])\.red\b"), "AppDesignSystem.Palette.danger"),
    (re.compile(r"\bColor\.blue\b|(?<![\w.])\.blue\b"), "AppDesignSystem.Palette.info"),
    (re.compile(r"\bColor\.green\b|(?<![\w.])\.green\b"), "AppDesignSystem.Palette.success"),
    (re.compile(r"\bColor\.gray\b|(?<![\w.])\.gray\b"), "AppDesignSystem.Palette.neutral"),
    (re.compile(r"\bColor\.pink\b|(?<![\w.])\.pink\b"), "AppDesignSystem.Palette.scoreMetric"),
    (re.compile(r"\bColor\.indigo\b|(?<![\w.])\.indigo\b"), "AppDesignSystem.Palette.scheduleTab"),
    (re.compile(r"\bColor\.teal\b|(?<![\w.])\.teal\b"), "AppDesignSystem.Palette.courseTab"),
    (re.compile(r"\bColor\.brown\b|(?<![\w.])\.brown\b"), "AppDesignSystem.Palette.paperTab"),
)
DIRECT_FLOATING_SIZE = re.compile(r"\.frame\(\s*width:\s*42\s*,\s*height:\s*42\s*\)")
DIRECT_FLOATING_MATERIAL = re.compile(r"\.background\(\s*\.ultraThinMaterial\s*,\s*in:\s*Circle\(\)\s*\)")
DIRECT_GROUPED_LIST_STYLE = re.compile(r"\.listStyle\(\s*\.insetGrouped\s*\)")
DIRECT_PLAIN_LIST_STYLE = re.compile(r"\.listStyle\(\s*\.plain\s*\)")
DIRECT_LIST_SECTION_SPACING = re.compile(r"\.listSectionSpacing\(")
DIRECT_STDOUT_LOG = re.compile(r"\b(?:print|debugPrint|NSLog)\s*\(")
DIRECT_SHARED_URLSESSION = re.compile(r"\bURLSession\.shared\b")
PADDING_LITERAL = re.compile(
    r"\.padding\(\s*(?:\.[A-Za-z]+\s*,\s*)?([0-9]+(?:\.[0-9]+)?)"
)
STACK_SPACING_LITERAL = re.compile(
    r"\b(?:VStack|HStack|ZStack|LazyVStack|LazyHStack)\s*\([^)]*"
    r"\bspacing\s*:\s*([0-9]+(?:\.[0-9]+)?)"
)
DERIVED_DESIGN_TOKEN = re.compile(
    r"(?:\bAppDesignSystem\.[A-Za-z_][\w.]*\s*[*/]\s*[A-Za-z0-9_.]+|"
    r"[A-Za-z0-9_.]+\s*[*/]\s*AppDesignSystem\.[A-Za-z_][\w.]*)"
)
REPEATED_DESIGN_TOKEN = re.compile(
    r"(AppDesignSystem\.[A-Za-z_][\w.]*)\s*[+\-]\s*\1"
)
DERIVED_TOKEN_DEFINITION = re.compile(
    r"^\s*static\s+let\s+[A-Za-z_][\w]*\s*:\s*[^=]+="
    r"\s*[A-Za-z_][\w.]*\s*[*/]\s*[A-Za-z0-9_.]+",
    re.MULTILINE,
)
REPEATED_TOKEN_DEFINITION = re.compile(
    r"^\s*static\s+let\s+[A-Za-z_][\w]*\s*:\s*[^=]+="
    r"\s*(\w+)\s*[+\-]\s*\1",
    re.MULTILINE,
)

ALLOWED_SHARED_URLSESSION_FILES = {
    "BIT101-iOS/Shared/Networking/HTTPClient.swift",
    "BIT101-iOS/Shared/Infrastructure/ReleaseNetworkSmoke.swift",
}


def swift_files() -> list[Path]:
    return sorted(SOURCE_ROOT.rglob("*.swift"))


def added_swift_lines() -> list[tuple[str, int, str]]:
    try:
        result = subprocess.run(
            ["git", "diff", "HEAD", "--unified=0", "--", "*.swift"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return []

    current_file = ""
    current_line = 0
    additions: list[tuple[str, int, str]] = []
    for line in result.stdout.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
            continue
        if line.startswith("@@"):
            match = re.search(r"\+([0-9]+)", line)
            current_line = int(match.group(1)) if match else 0
            continue
        if line.startswith("+") and not line.startswith("+++"):
            additions.append((current_file, current_line, line[1:]))
            current_line += 1
        elif line and not line.startswith("-"):
            current_line += 1
    return additions


def require_token(
    errors: list[str],
    files: tuple[str, ...],
    token: str,
    message: str,
) -> None:
    """用同一条契约检查一组同类页面，避免为每个页面复制一份规则。"""
    for file_name in files:
        path = SOURCE_ROOT / file_name
        if path.is_file() and token not in path.read_text(encoding="utf-8"):
            errors.append(f"{file_name}: {message}（缺少 {token}）")


def main() -> int:
    if not DESIGN_SYSTEM.is_file():
        print(f"[失败] 缺少设计系统入口：{DESIGN_SYSTEM.relative_to(ROOT)}", file=sys.stderr)
        return 1

    errors: list[str] = []
    app_card_uses = 0
    floating_stack_uses = 0
    design_source = DESIGN_SYSTEM.read_text(encoding="utf-8")
    for pattern in (DERIVED_TOKEN_DEFINITION, REPEATED_TOKEN_DEFINITION):
        for match in pattern.finditer(design_source):
            line_number = design_source.count("\n", 0, match.start()) + 1
            errors.append(
                f"{DESIGN_SYSTEM.relative_to(ROOT)}:{line_number}: 设计令牌定义不得通过比例或重复相加/相减派生"
            )
    for path in swift_files():
        if path == DESIGN_SYSTEM:
            continue
        relative = path.relative_to(ROOT)
        source = path.read_text(encoding="utf-8")
        if "AppFloatingActionStack" in source:
            floating_stack_uses += 1
        if "ZStack(alignment: .bottomTrailing)" in source and re.search(r"Floating|FAB", source):
            if "AppFloatingActionStack" not in source:
                errors.append(f"{relative}: 右下角操作组必须使用 AppFloatingActionStack")
        rules = (
            (DIRECT_ROUNDED_RECTANGLE, "请使用 AppDesignSystem.roundedRectangle"),
            (DIRECT_CORNER_RADIUS, "圆角半径必须通过 AppDesignSystem.Radius 和 roundedRectangle 统一"),
            (DIRECT_SYSTEM_COLOR, "请使用 AppDesignSystem.Palette"),
            (DIRECT_ACCENT_COLOR, "请使用 AppDesignSystem.Palette.accent"),
            (DIRECT_FLOATING_SIZE, "圆形操作按钮尺寸必须使用 AppDesignSystem.Size"),
            (DIRECT_FLOATING_MATERIAL, "圆形操作按钮背景必须使用 AppFloatingActionButtonSurface"),
            (DIRECT_GROUPED_LIST_STYLE, "分组列表必须使用 appGroupedListStyle"),
            (DIRECT_LIST_SECTION_SPACING, "列表 section 间距必须通过 appGroupedListStyle 统一"),
        )
        for pattern, message in rules:
            for match in pattern.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: {message}")
        for pattern, palette_name in DIRECT_SEMANTIC_COLOR_RULES:
            for match in pattern.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: 请使用 {palette_name}")

        if path != DESIGN_SYSTEM:
            for pattern in (DERIVED_DESIGN_TOKEN, REPEATED_DESIGN_TOKEN):
                for match in pattern.finditer(source):
                    line_number = source.count("\n", 0, match.start()) + 1
                    errors.append(
                        f"{relative}:{line_number}: 设计令牌不得通过比例或重复相加/相减二次运算；请直接使用语义令牌"
                    )

        if path.name != "GalleryMessagesView.swift":
            for match in DIRECT_PLAIN_LIST_STYLE.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: plain 列表只允许消息中心使用")

        if path.name != "ReleaseNetworkSmoke.swift":
            for match in DIRECT_STDOUT_LOG.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: 主 App 不应直接输出日志；调试输出只允许放在网络 smoke 文件")

        if str(relative) not in ALLOWED_SHARED_URLSESSION_FILES:
            for match in DIRECT_SHARED_URLSESSION.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: 网络请求应通过 HTTPClient 或场景化 Service，不要直接使用 URLSession.shared")

        app_card_uses += len(re.findall(r"\bAppCard\s*(?:<[^>]+>)?\s*(?:\(|\{)", source))

    if app_card_uses == 0:
        errors.append("未发现 AppCard 调用，公共卡片组件没有实际复用")
    if floating_stack_uses == 0:
        errors.append("未发现 AppFloatingActionStack 调用，右下角操作组没有实际复用")

    # 所有分组内容列表统一使用同一修饰器；消息页是刻意保留的 plain 列表例外。
    for path in swift_files():
        if path == DESIGN_SYSTEM:
            continue
        source = path.read_text(encoding="utf-8")
        if re.search(r"\bList\s*\{", source) and path.name != "GalleryMessagesView.swift":
            list_count = len(re.findall(r"\bList\s*\{", source))
            style_count = source.count("appGroupedListStyle()")
            if style_count < list_count:
                errors.append(
                    f"{path.relative_to(ROOT)}: {list_count} 个分组列表必须逐个使用 appGroupedListStyle（当前 {style_count} 个）"
                )

    # 同类页面只声明“必须使用哪个公共结构”，检查机制本身不再为每个页面复制一套逻辑。
    detail_files = ("Course/CourseDetailView.swift", "Gallery/GalleryPosterDetailView.swift", "Paper/PaperDetailView.swift")
    require_token(errors, detail_files, "AppDetailShareLink", "详情页必须使用公共分享入口")
    require_token(errors, detail_files, "AppDetailCircleButton", "详情页圆形操作必须使用公共按钮")
    require_token(
        errors,
        ("Course/CourseCommentViews.swift", "Gallery/GalleryCommentViews.swift", "Paper/PaperCommentViews.swift"),
        "AppDesignSystem.Comment.",
        "评论区必须使用公共间距令牌",
    )
    require_token(
        errors,
        ("Course/CourseCommentViews.swift", "Gallery/GalleryCommentViews.swift", "Paper/PaperCommentViews.swift"),
        "appCommentSectionStyle",
        "评论区必须使用公共容器样式",
    )
    require_token(
        errors,
        ("Gallery/GalleryFeedViews.swift", "Paper/PaperSummaryViews.swift"),
        "appFeedCardStyle",
        "信息流卡片必须使用公共 Feed 样式",
    )
    require_token(
        errors,
        ("Score/ScoreRootView.swift", "Gallery/GalleryRootView.swift", "Schedule/ScheduleRootView.swift"),
        ".safeAreaInset(edge: .top, spacing: 0)",
        "顶部切换栏必须使用统一 safeAreaInset 布局",
    )

    schedule_root_path = SOURCE_ROOT / "Schedule/ScheduleRootView.swift"
    if schedule_root_path.is_file() and ".safeAreaInset(edge: .bottom, spacing: 0)" not in schedule_root_path.read_text(encoding="utf-8"):
        errors.append(f"{schedule_root_path.relative_to(ROOT)}: 日程内容必须使用统一的底部安全区间隙")

    schedule_path = SOURCE_ROOT / "Schedule/ScheduleCalendarViews.swift"
    if schedule_path.is_file():
        schedule_source = schedule_path.read_text(encoding="utf-8")
        if "orderedBackgroundLayers" not in schedule_source:
            errors.append("ScheduleCalendarViews.swift: 叠加课程必须按中心位置统一排序")
        if "isOpaque: entry.kind == .course" not in schedule_source:
            errors.append("ScheduleCalendarViews.swift: 课程背景必须使用不透明底色遮住节次分割线")
        if "let leftWidth = columnWidth" not in schedule_source or "let dayWidth = columnWidth" not in schedule_source:
            errors.append("ScheduleCalendarViews.swift: 周次与叠加视图必须共用等宽列")
        if "secondaryGroupedBackground" not in schedule_source:
            errors.append("ScheduleCalendarViews.swift: 周次滑块与日期栏必须使用可区分的语义背景色")

    # 新增代码中的固定间距必须先取得语义名称；历史代码逐步迁移，不在本次一次性重写。
    for file_name, line_number, line in added_swift_lines():
        if file_name.endswith("Shared/DesignSystem/AppDesignSystem.swift"):
            continue
        for pattern, label in (
            (PADDING_LITERAL, "padding"),
            (STACK_SPACING_LITERAL, "stack spacing"),
        ):
            match = pattern.search(line)
            if match and float(match.group(1)) != 0:
                errors.append(
                    f"{file_name}:{line_number}: 新增 {label} 使用固定值 {match.group(1)}，请改用 AppDesignSystem.Spacing"
                )

    if errors:
        print("[失败] UI 一致性检查：")
        print("\n".join(errors))
        return 1

    print(f"[通过] UI 一致性检查（扫描 {len(swift_files())} 个 Swift 文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
