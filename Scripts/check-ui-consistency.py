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
DIRECT_SYSTEM_COLOR = re.compile(
    r"\bColor\s*\(\s*(?:uiColor\s*:\s*)?\.(?:systemBackground|systemGroupedBackground|"
    r"secondarySystemBackground|secondarySystemGroupedBackground|secondarySystemFill)\s*\)"
)
DIRECT_ACCENT_COLOR = re.compile(r"\bColor\.accentColor\b")
DIRECT_HIGHLIGHT_COLOR = re.compile(r"\bColor\.orange\b")
DIRECT_DANGER_COLOR = re.compile(r"\bColor\.red\b")
DIRECT_INFO_COLOR = re.compile(r"\bColor\.blue\b")
DIRECT_HIGHLIGHT_SHORTHAND = re.compile(r"(?<![\w.])\.(?:orange)\b")
DIRECT_DANGER_SHORTHAND = re.compile(r"(?<![\w.])\.(?:red)\b")
DIRECT_INFO_SHORTHAND = re.compile(r"(?<![\w.])\.(?:blue)\b")
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

REMOVED_UI_TERMS = (
    "举报并屏蔽",
    "举报该帖子",
    "屏蔽本文",
    "PaperArticleActionMenu",
    "CommunityReportAction",
    "CommunityReportService",
)

ALLOWED_SHARED_URLSESSION_FILES = {
    "BIT101-iOS/Shared/Networking/HTTPClient.swift",
    "BIT101-iOS/Shared/Infrastructure/AppUpdateChecker.swift",
    "BIT101-iOS/Shared/Infrastructure/EmergencyUpdateChecker.swift",
    "BIT101-iOS/Shared/Infrastructure/ErrorReportSupport.swift",
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


def main() -> int:
    if not DESIGN_SYSTEM.is_file():
        print(f"[失败] 缺少设计系统入口：{DESIGN_SYSTEM.relative_to(ROOT)}", file=sys.stderr)
        return 1

    errors: list[str] = []
    app_card_uses = 0
    floating_stack_uses = 0
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
            (DIRECT_SYSTEM_COLOR, "请使用 AppDesignSystem.Palette"),
            (DIRECT_ACCENT_COLOR, "请使用 AppDesignSystem.Palette.accent"),
            (DIRECT_HIGHLIGHT_COLOR, "请使用 AppDesignSystem.Palette.highlight"),
            (DIRECT_DANGER_COLOR, "请使用 AppDesignSystem.Palette.danger"),
            (DIRECT_INFO_COLOR, "请使用 AppDesignSystem.Palette.info"),
            (DIRECT_HIGHLIGHT_SHORTHAND, "请使用 AppDesignSystem.Palette.highlight"),
            (DIRECT_DANGER_SHORTHAND, "请使用 AppDesignSystem.Palette.danger"),
            (DIRECT_INFO_SHORTHAND, "请使用 AppDesignSystem.Palette.info"),
            (DIRECT_FLOATING_SIZE, "圆形操作按钮尺寸必须使用 AppDesignSystem.Size"),
            (DIRECT_FLOATING_MATERIAL, "圆形操作按钮背景必须使用 AppFloatingActionButtonSurface"),
            (DIRECT_GROUPED_LIST_STYLE, "分组列表必须使用 appGroupedListStyle"),
            (DIRECT_LIST_SECTION_SPACING, "列表 section 间距必须通过 appGroupedListStyle 统一"),
        )
        for pattern, message in rules:
            for match in pattern.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: {message}")

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

        for removed in REMOVED_UI_TERMS:
            if removed in source:
                errors.append(f"{relative}: 已移除的社区操作仍存在：{removed}")
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
            if "appGroupedListStyle()" not in source:
                errors.append(f"{path.relative_to(ROOT)}: 分组列表必须使用 appGroupedListStyle")

    # 帖子和文章详情必须共用同一个分享按钮，避免只实现一侧或出现不同的系统入口。
    for detail_file in ("Course/CourseDetailView.swift", "Gallery/GalleryPosterDetailView.swift", "Paper/PaperDetailView.swift"):
        detail_path = SOURCE_ROOT / detail_file
        if detail_path.is_file() and "AppDetailShareLink" not in detail_path.read_text(encoding="utf-8"):
            errors.append(f"{detail_path.relative_to(ROOT)}: 详情页必须使用 AppDetailShareLink")

    for detail_file in ("Course/CourseDetailView.swift", "Gallery/GalleryPosterDetailView.swift", "Paper/PaperDetailView.swift"):
        detail_path = SOURCE_ROOT / detail_file
        if detail_path.is_file() and "AppDetailCircleButton" not in detail_path.read_text(encoding="utf-8"):
            errors.append(f"{detail_path.relative_to(ROOT)}: 详情页圆形评论/点赞按钮必须使用 AppDetailCircleButton")

    for comment_file in (
        "Course/CourseCommentViews.swift",
        "Gallery/GalleryCommentViews.swift",
        "Paper/PaperCommentViews.swift",
    ):
        comment_path = SOURCE_ROOT / comment_file
        if comment_path.is_file():
            comment_source = comment_path.read_text(encoding="utf-8")
            if "AppDesignSystem.Comment." not in comment_source or "appCommentSectionStyle" not in comment_source:
                errors.append(f"{comment_path.relative_to(ROOT)}: 评论区必须使用公共间距和容器样式")

    for feed_file in ("Gallery/GalleryFeedViews.swift", "Paper/PaperSummaryViews.swift"):
        feed_path = SOURCE_ROOT / feed_file
        if feed_path.is_file():
            feed_source = feed_path.read_text(encoding="utf-8")
            if "appFeedCardStyle" not in feed_source:
                errors.append(f"{feed_path.relative_to(ROOT)}: 信息流卡片必须使用公共 Feed 样式")

    # 学业页顶部切换栏由外层 safeAreaInset 提供；列表不能再次叠加默认滚动上边距。
    for page_file in ("Course/CourseRootView.swift", "Score/ScoreRootView.swift"):
        page_path = SOURCE_ROOT / page_file
        if page_path.is_file() and "contentMargins(.top, 0, for: .scrollContent)" not in page_path.read_text(encoding="utf-8"):
            errors.append(f"{page_path.relative_to(ROOT)}: 学业列表不能叠加顶部滚动边距")

    # 已移除帖子举报、用户屏蔽和文章隐藏入口；边角菜单不得回流这些旧动作。
    for menu_file in ("Gallery/GalleryModerationViews.swift", "Paper/PaperComposerViews.swift"):
        menu_path = SOURCE_ROOT / menu_file
        if menu_path.is_file():
            menu_source = menu_path.read_text(encoding="utf-8")
            for removed in ("CommunityReport", "举报", "屏蔽本文", "person.crop.circle.badge.xmark"):
                if removed in menu_source:
                    errors.append(f"{menu_path.relative_to(ROOT)}: 已移除的菜单动作仍存在：{removed}")

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
