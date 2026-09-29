#!/usr/bin/env python3
"""Check that SwiftUI pages use the shared design system instead of local copies."""

from __future__ import annotations

import re
import importlib.util
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "BIT101-iOS"
DESIGN_SYSTEM = SOURCE_ROOT / "Shared/DesignSystem/AppDesignSystem.swift"
DESIGN_SYSTEM_SOURCES = {
    DESIGN_SYSTEM,
    SOURCE_ROOT / "Shared/DesignSystem/DesignPrimitives.swift",
    SOURCE_ROOT / "Shared/DesignSystem/ExternalDesignSystem.swift",
    SOURCE_ROOT / "Course/CourseDesignSystem.swift",
    SOURCE_ROOT / "Schedule/ScheduleDesignSystem.swift",
    SOURCE_ROOT / "Gallery/GalleryDesignSystem.swift",
}
MAP_THEME_COLOR_CONTRACT = (
    "Map/CampusMapScreen.swift",
    "static let tabAccent = Color.green",
)
PRIMITIVE_OPACITY_SOURCE = SOURCE_ROOT / "Shared/DesignSystem/DesignPrimitives.swift"
REPORT_PATH = ROOT / ".build/ui-consistency-report.txt"


def _blank_segment(output: list[str], source: str, start: int, end: int) -> None:
    for index in range(start, min(end, len(source))):
        if source[index] != "\n":
            output[index] = " "


def mask_comments(source: str) -> str:
    """移除注释并保留字符串，供需要识别 UI 文案结构的规则使用。"""
    output = list(source)
    index = 0
    depth = 0
    while index < len(source):
        if depth:
            if source.startswith("/*", index):
                depth += 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                depth -= 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            else:
                _blank_segment(output, source, index, index + 1)
                index += 1
            continue

        raw_match = re.match(r'(#+)("{1,3})', source[index:])
        if raw_match:
            hashes, quote = raw_match.groups()
            terminator = quote + hashes
            content_start = index + len(hashes) + len(quote)
            end = source.find(terminator, content_start)
            index = len(source) if end < 0 else end + len(terminator)
            continue
        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            index = len(source) if end < 0 else end + 3
            continue
        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            continue

        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            _blank_segment(output, source, index, end)
            index = end
        elif source.startswith("/*", index):
            depth = 1
            _blank_segment(output, source, index, index + 2)
            index += 2
        else:
            index += 1
    return "".join(output)


def mask_literals_and_comments(source: str) -> str:
    """保留换行，忽略字符串和注释，避免文案伪造 UI 契约。"""
    output = list(source)
    index = 0
    comment_depth = 0
    while index < len(source):
        if comment_depth:
            if source.startswith("/*", index):
                comment_depth += 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                comment_depth -= 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            else:
                _blank_segment(output, source, index, index + 1)
                index += 1
            continue

        raw_match = re.match(r"(#+)(\"{1,3})", source[index:])
        if raw_match:
            hashes, quote = raw_match.groups()
            terminator = quote + hashes
            content_start = index + len(hashes) + len(quote)
            end = source.find(terminator, content_start)
            end = len(source) if end < 0 else end + len(terminator)
            _blank_segment(output, source, index, end)
            index = end
            continue

        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            end = len(source) if end < 0 else end + 3
            _blank_segment(output, source, index, end)
            index = end
            continue

        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    _blank_segment(output, source, index, index + 2)
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    _blank_segment(output, source, index, index + 1)
                    index += 1
            continue

        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            _blank_segment(output, source, index, end)
            index = end
            continue
        if source.startswith("/*", index):
            comment_depth = 1
            _blank_segment(output, source, index, index + 2)
            index += 2
            continue

        index += 1
    return "".join(output)


def is_view_source(path: Path, code: str) -> bool:
    if path.name.endswith(("View.swift", "Views.swift", "Screen.swift", "Screens.swift")):
        return True
    return re.search(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b",
        code,
    ) is not None

FIXED_GEOMETRY_CONTRACTS = (
    (
        "Course/CourseCommentViews.swift",
        "thumbnailButton(image: displayedImages[0], index: 0, width: 180",
    ),
    (
        "Course/CourseCommentViews.swift",
        "thumbnailButton(image: image, index: index, width: nil, maxHeight: 150",
    ),
    (
        "Course/CourseCommentViews.swift",
        "thumbnailButton(image: image, index: index, width: nil, maxHeight: 78",
    ),
    (
        "Gallery/GalleryComposerView.swift",
        "GridItem(.adaptive(minimum: 64)",
    ),
    (
        "Course/CourseHistoryGradesViews.swift",
        "StrokeStyle(lineWidth: 2, dash: [5, 4])",
    ),
    (
        "Gallery/GalleryComposerView.swift",
        "width: max(1, width * scale)",
    ),
    (
        "Schedule/ScheduleLinearCalendarViews.swift",
        "max(proxy.size.height - headerHeight, 1)",
    ),
    (
        "Schedule/ScheduleCourseCardViews.swift",
        "lowerBound: CGFloat = 1",
    ),
)

DIRECT_ROUNDED_RECTANGLE = re.compile(r"\bRoundedRectangle\s*\(")
DIRECT_CORNER_RADIUS = re.compile(r"\.cornerRadius\s*\(")
DIRECT_SYSTEM_COLOR = re.compile(
    r"\bColor\s*\(\s*(?:uiColor\s*:\s*)?\.(?:systemBackground|systemGroupedBackground|"
    r"secondarySystemBackground|secondarySystemGroupedBackground|secondarySystemFill)\s*\)"
)
DIRECT_ACCENT_COLOR = re.compile(r"\bColor\.accentColor\b")
DIRECT_OPACITY_LITERAL = re.compile(
    r"\.opacity\s*\(\s*(?:0\.[0-9]+|1(?:\.0+)?)\s*\)"
)
DIRECT_OPACITY_ASSIGNMENT = re.compile(
    r"\b[A-Za-z_][A-Za-z0-9_]*Opacity\s*(?::\s*(?:CGFloat|Double))?\s*=\s*(?:0\.[0-9]+|1(?:\.0+)?)"
)
DIRECT_FOREGROUND_STYLE = re.compile(
    r"\.foregroundStyle\s*\(\s*\.(?:primary|secondary|tertiary|quaternary|quinary|white|black)\s*\)"
)
DIRECT_HIERARCHICAL_COLOR = re.compile(r"\bColor\.(?:primary|secondary)\b")
DIRECT_FONT_MODIFIER = re.compile(r"\.font\s*\(\s*\.[A-Za-z_][A-Za-z0-9_]*\s*\)")
DIRECT_GRID_ITEM_GEOMETRY = re.compile(
    r"\bGridItem\s*\([^)]*\b(?:minimum|maximum)\s*:\s*[0-9]+(?:\.[0-9]+)?"
)
DIRECT_STROKE_GEOMETRY = re.compile(
    r"\bStrokeStyle\s*\([^)]*\b(?:lineWidth|dash)\s*:\s*(?:\[[^\]]+\]|[0-9]+(?:\.[0-9]+)?)"
)
DIRECT_BLUR_GEOMETRY = re.compile(r"\.blur\s*\(\s*radius\s*:\s*[0-9]+(?:\.[0-9]+)?")
DIRECT_THUMBNAIL_GEOMETRY = re.compile(
    r"\bthumbnailButton\s*\([^)]*(?:width|maxHeight|aspectRatio)\s*:\s*[0-9]+(?:\.[0-9]+)?"
)
DIRECT_SEMANTIC_COLOR_RULES = (
    (re.compile(r"\bColor\.orange\b|(?<![\w.])\.orange\b"), "AppDesignSystem.Palette.Highlight.primary"),
    (re.compile(r"\bColor\.red\b|(?<![\w.])\.red\b"), "AppDesignSystem.Palette.Status.danger"),
    (re.compile(r"\bColor\.blue\b|(?<![\w.])\.blue\b"), "AppDesignSystem.Palette.Status.info"),
    (re.compile(r"\bColor\.green\b|(?<![\w.])\.green\b"), "AppDesignSystem.Palette.Status.success"),
    (re.compile(r"\bColor\.gray\b|(?<![\w.])\.gray\b"), "AppDesignSystem.Palette.Status.neutral"),
    (re.compile(r"\bColor\.pink\b|(?<![\w.])\.pink\b"), "AppDesignSystem.Course.accent"),
    (re.compile(r"\bColor\.indigo\b|(?<![\w.])\.indigo\b"), "AppDesignSystem.Schedule.tabAccent"),
    (re.compile(r"\bColor\.teal\b|(?<![\w.])\.teal\b"), "AppDesignSystem.Palette.Status.info"),
    (re.compile(r"\bColor\.brown\b|(?<![\w.])\.brown\b"), "AppDesignSystem.Palette.Status.neutral"),
)
PAGE_THEME_RULES = (
    (
        ("Course/", "Score/"),
        (
            "AppDesignSystem.Palette.Accent.primary",
            "AppDesignSystem.Palette.Highlight.primary",
            "AppDesignSystem.Palette.Highlight.surface",
        ),
        "AppDesignSystem.Course.accent",
    ),
)
PAGE_THEME_CONTRACTS = (
    (
        "Course/CourseHistoryGradesViews.swift",
        '.foregroundStyle(by: .value("指标", point.series))',
    ),
)
THEME_SENSITIVE_ROOTS = (
    "Shared/DesignSystem",
    "Gallery",
    "Paper",
    "Mine",
)
CONTEXTUAL_COLOR_BYPASSES = (
    ("AppDesignSystem.Palette.Highlight.primary", "AppDesignSystem.Palette.Accent.primary"),
    ("AppDesignSystem.Palette.Highlight.surface", "AppDesignSystem.Palette.Accent.surface"),
)
DIRECT_FLOATING_SIZE = re.compile(
    r"\.frame\(\s*width\s*:\s*42\s*,\s*height\s*:\s*42\s*\)"
)
DIRECT_TOUCH_TARGET = re.compile(
    r"\.frame\([^)]*(?:minHeight\s*:\s*44|width\s*:\s*44\s*,\s*height\s*:\s*44)"
)
DIRECT_FLOATING_MATERIAL = re.compile(
    r"\.background\(\s*\.ultraThinMaterial\s*,\s*in\s*:\s*Circle\s*\(\s*\)\s*\)"
)
DIRECT_GROUPED_LIST_STYLE = re.compile(r"\.listStyle\(\s*\.insetGrouped\s*\)")
DIRECT_PLAIN_LIST_STYLE = re.compile(r"\.listStyle\(\s*\.plain\s*\)")
DIRECT_LIST_SECTION_SPACING = re.compile(r"\.listSectionSpacing\(")
DIRECT_INPUT_PLACEHOLDER = re.compile(
    r"\b(?:TextField|SecureField)\s*\(\s*\"[^\"]+\"\s*,\s*text\s*:"
)
DIRECT_CUSTOM_SECTION_HEADER = re.compile(r"header\s*:\s*\{\s*Text\s*\(")
DIRECT_ANIMATION_DURATION = re.compile(
    r"\b(?:withAnimation|animation)\s*\([^)]*\bduration\s*:"
)
DIRECT_BARE_HSTACK = re.compile(r"\bHStack\s*\{")
DIRECT_HSTACK_LITERAL = re.compile(
    r"\bHStack\s*\([^)]*\bspacing\s*:\s*[0-9]+(?:\.[0-9]+)?"
)

DIRECT_FRAME_LITERAL = re.compile(
    r"\.frame\([^)]*\b(?:width|height|minWidth|minHeight|maxWidth|maxHeight)\s*:\s*"
    r"(?:[1-9][0-9]*(?:\.[0-9]+)?|0\.[0-9]*[1-9][0-9]*)"
)
DIRECT_EDGE_INSETS_LITERAL = re.compile(
    r"EdgeInsets\([^)]*\b(?:top|leading|bottom|trailing)\s*:\s*"
    r"(?:[1-9][0-9]*(?:\.[0-9]+)?|0\.[0-9]*[1-9][0-9]*)"
)
DIRECT_LOCAL_CGFLOAT_LITERAL = re.compile(
    r"\b[A-Za-z_][A-Za-z0-9_]*\s*:\s*CGFloat\s*=\s*"
    r"(?:[1-9][0-9]*(?:\.[0-9]+)?|0\.[0-9]*[1-9][0-9]*)"
)
PADDING_LITERAL = re.compile(
    r"\.padding\(\s*(?:\.[A-Za-z]+\s*,\s*)?([0-9]+(?:\.[0-9]+)?)"
)
STACK_SPACING_LITERAL = re.compile(
    r"\b(?:VStack|HStack|ZStack|LazyVStack|LazyHStack)\s*\([^)]*"
    r"\bspacing\s*:\s*([0-9]+(?:\.[0-9]+)?)"
)
DIRECT_VISUAL_RULES = (
    (DIRECT_ROUNDED_RECTANGLE, "请使用 AppDesignSystem.roundedRectangle"),
    (DIRECT_CORNER_RADIUS, "圆角半径必须通过 AppDesignSystem.Radius 和 roundedRectangle 统一"),
    (DIRECT_SYSTEM_COLOR, "请使用 AppDesignSystem.Palette"),
    (DIRECT_ACCENT_COLOR, "请使用 AppDesignSystem.Palette.Accent.primary"),
    (DIRECT_FLOATING_SIZE, "圆形操作按钮尺寸必须使用 AppDesignSystem.Size"),
    (DIRECT_TOUCH_TARGET, "触控区域尺寸必须使用 AppDesignSystem.Size.Control.touchTarget"),
    (DIRECT_FLOATING_MATERIAL, "圆形操作按钮背景必须使用 AppFloatingActionButtonSurface"),
    (DIRECT_GROUPED_LIST_STYLE, "分组列表必须使用 appGroupedListStyle"),
    (DIRECT_LIST_SECTION_SPACING, "列表 section 间距必须通过 appGroupedListStyle 统一"),
    (DIRECT_ANIMATION_DURATION, "优先使用系统动画时长，不要在页面单独指定 duration"),
    (DIRECT_INPUT_PLACEHOLDER, "输入提示必须使用 AppInputPrompt"),
    (DIRECT_CUSTOM_SECTION_HEADER, "列表自定义标题必须使用 AppListSectionHeader"),
    (DIRECT_BARE_HSTACK, "HStack 必须显式使用 AppDesignSystem.Spacing 语义间距"),
    (DIRECT_HSTACK_LITERAL, "HStack 间距必须使用 AppDesignSystem.Spacing 语义令牌"),
    (DIRECT_FRAME_LITERAL, "固定 frame 尺寸必须使用 AppDesignSystem.Size 或专用语义令牌"),
    (DIRECT_EDGE_INSETS_LITERAL, "EdgeInsets 必须使用 AppDesignSystem.Spacing"),
    (DIRECT_LOCAL_CGFLOAT_LITERAL, "页面布局常量必须提升为设计系统语义令牌"),
    (DIRECT_FOREGROUND_STYLE, "前景层级必须使用 AppDesignSystem.Foreground"),
    (DIRECT_HIERARCHICAL_COLOR, "系统前景颜色必须使用 AppDesignSystem.Foreground"),
    (DIRECT_FONT_MODIFIER, "字体角色必须使用 AppDesignSystem.Typography"),
    (DIRECT_GRID_ITEM_GEOMETRY, "GridItem 尺寸必须使用 AppDesignSystem.Size 或模块语义令牌"),
    (DIRECT_STROKE_GEOMETRY, "图表线宽和虚线必须使用模块设计令牌"),
    (DIRECT_BLUR_GEOMETRY, "模糊半径必须使用 AppDesignSystem.Size.Effect"),
    (DIRECT_THUMBNAIL_GEOMETRY, "缩略图几何必须使用模块设计令牌"),
)
DERIVED_DESIGN_TOKEN = re.compile(
    r"(?:\bAppDesignSystem\.[A-Za-z_][\w.]*\s*[*/]\s*[A-Za-z0-9_.]+|"
    r"[A-Za-z0-9_.]+\s*[*/]\s*AppDesignSystem\.[A-Za-z_][\w.]*)"
)
REPEATED_DESIGN_TOKEN = re.compile(
    r"(AppDesignSystem\.[A-Za-z_][\w.]*)\s*[+\-]\s*\1"
)

PLAIN_LIST_EXCEPTIONS = {"Gallery/GalleryMessagesView.swift"}

@dataclass(frozen=True)
class ComponentContract:
    """按稳定的 View 声明名和公共组件用法发现同类 UI 契约。"""

    name: str
    requirements: tuple[tuple[str, str], ...]
    view_names: tuple[str, ...] = ()
    discovery_tokens: tuple[str, ...] = ()
    any_tokens: tuple[str, ...] = ()

COMPONENT_GROUPS = (
    ("评论", ("AppCommentSectionHeader", "AppCommentIdentityHeader", "AppCommentActionBar", "AppCommentBubble", "AppCommentRowContainer", "AppCommentThread")),
    ("评论编辑", ("AppCommentComposerContentSection", "AppComposerToolbar")),
    ("内容控制", ("AppSegmentedPicker", "AppTopSegmentedPicker", "AppOrderedSearchBar", "AppSearchBarContainer", "AppNavigationRowLabel")),
    ("头像标签", ("AppAvatarView", "AppTagChip")),
    ("状态", ("AppLoadingState", "AppInlineLoadingState", "AppScrollStateContainer", "AppFailureState", "AppEmptyState")),
    ("数据行", ("AppFixedColumnItem", "AppFixedColumnRow", "AppRefreshStatusRow", "AppFeedRow", "AppCourseEvaluationRow")),
    ("验证码", ("AppSMSVerificationSheet",)),
)

COMPONENT_INHERITANCE = {
    **{
        symbol: "View"
        for _, symbols in COMPONENT_GROUPS
        for symbol in symbols
    },
    "AppComposerToolbar": "ToolbarContent",
    "AppFixedColumnItem": None,
}

LOCAL_APP_ALERT_BINDINGS = {
    ("CourseEvaluationLink", "alert"),
    ("CourseEvaluationDestination", "expectedAlert"),
}

COMPONENT_CONTRACTS = (
    ComponentContract(
        name="详情页",
        view_names=("CourseDetailView", "PaperDetailView", "GalleryPosterDetailView"),
        discovery_tokens=("AppDetailShareLink", "AppDetailCircleButton"),
        requirements=(
            ("AppDetailShareLink", "必须使用公共分享入口"),
            ("AppDetailCircleButton", "圆形操作必须使用公共按钮"),
        ),
    ),
    ComponentContract(
        name="评论区容器",
        view_names=(
            "CourseCommentsSection", "GalleryPosterCommentsSection", "PaperCommentsSection",
        ),
        requirements=(("appCommentSectionStyle", "必须使用评论公共结构"), ("AppFailureState", "必须使用公共失败状态")),
    ),
    ComponentContract(
        name="评论行",
        view_names=("CourseCommentRow", "GalleryCommentRow", "PaperCommentRow"),
        requirements=tuple((token, "必须使用评论公共结构") for token in (
            "AppDesignSystem.Comment.",
            "AppCommentThread", "AppCommentBubble", "AppCommentIdentityHeader",
            "AppCommentActionBar", "AppAvatarView", "AppDateText",
        )),
    ),
    ComponentContract(
        name="评论编辑页",
        view_names=("CourseCommentComposerSheet", "GalleryCommentComposerSheet", "PaperCommentComposerSheet"),
        discovery_tokens=("AppCommentComposerContentSection",),
        requirements=(("AppCommentComposerContentSection", "必须使用公共内容段"), ("AppComposerToolbar", "必须使用公共工具栏")),
    ),
    ComponentContract(
        name="排序搜索页",
        view_names=("GallerySearchView", "PaperSearchView"),
        discovery_tokens=("AppOrderedSearchBar", "AppSearchBarContainer"),
        requirements=(("AppOrderedSearchBar", "必须使用公共搜索栏"), ("AppSearchBarContainer", "必须使用公共顶部容器")),
    ),
    ComponentContract(
        name="顶部切换页",
        view_names=("ScheduleSectionTabs",),
        discovery_tokens=("AppTopSegmentedPicker",),
        requirements=(("AppTopSegmentedPicker", "必须使用公共顶部切换控件"),),
    ),
    ComponentContract(
        name="顶部安全区",
        view_names=("ScheduleRootView",),
        requirements=(("AppDesignSystem.Spacing.none", "必须使用统一顶部安全区布局"),),
    ),
    ComponentContract(
        name="设置导航入口",
        view_names=("MineRootView", "SettingsIndexPage", "SettingsIndexCard"),
        requirements=(("AppNavigationRowLabel", "必须使用公共图标标题行"),),
    ),
    ComponentContract(
        name="资料卡宽屏布局",
        discovery_tokens=("struct MineProfileCard",),
        requirements=((".frame(maxWidth: .infinity, alignment: .center)", "资料卡必须扩展并保持居中"),),
    ),
    ComponentContract(
        name="信息流卡片",
        view_names=("GalleryFeedView", "GalleryPosterCard", "PaperSummaryCard"),
        requirements=(("appFeedCardStyle", "必须使用公共 Feed 样式"),),
    ),
    ComponentContract(
        name="首屏状态页",
        view_names=(
            "CourseRootView", "CoursePageContent", "GalleryMessagesView",
            "MineRootView", "UserProfileRootView", "MineUserListView", "MinePosterListView",
            "ScoreRootView", "ScoreListPage", "TrustedTranscriptPage",
            "PaperRootView", "PaperSearchView",
        ),
        any_tokens=("AppLoadingState", "AppInlineLoadingState"),
        requirements=(("AppFailureState", "必须使用公共失败状态"),),
    ),
    ComponentContract(
        name="滚动信息流",
        view_names=("GalleryFeedView", "PaperRootView", "PaperSearchView"),
        requirements=(("AppScrollStateContainer", "必须使用公共滚动状态容器"),),
    ),
    ComponentContract(
        name="比例数据页",
        view_names=("CoursePageContent", "CourseListRow", "ScoreListPage", "ScoreListRowCard"),
        requirements=(("AppFixedColumnRow", "必须使用公共比例数据行"),),
    ),
    ComponentContract(
        name="验证码页面",
        view_names=("ScheduleRootView", "ScoreListPage", "TrustedTranscriptPage", "CalendarSettingsPage"),
        requirements=(("AppSMSVerificationSheet", "必须使用公共验证码面板"),),
    ),
    ComponentContract(
        name="标签页面",
        view_names=("GalleryFeedView", "GalleryPosterCard", "GalleryPosterDetailView", "GalleryComposerView"),
        requirements=(("AppTagChip", "必须使用公共标签组件"),),
    ),
    ComponentContract(
        name="课表网格",
        view_names=("CourseScheduleCalendarView",),
        discovery_tokens=("orderedBackgroundLayers",),
        requirements=(
            ("orderedBackgroundLayers", "叠加课程必须按中心位置统一排序"),
            ("entry.kind == .course", "课程背景必须使用不透明底色遮住节次分割线"),
            ("let leftWidth = columnWidth", "周次与叠加视图必须共用等宽列"),
            ("let dayWidth = columnWidth", "周次与叠加视图必须共用等宽列"),
            ("AppDesignSystem.Palette.Background.secondaryGrouped", "周次滑块与日期栏必须使用可区分的语义背景色"),
        ),
    ),
    ComponentContract(
        name="日程根页",
        view_names=("ScheduleRootView",),
        requirements=((".safeAreaInset(edge: .bottom, spacing: AppDesignSystem.Spacing.none)", "内容必须使用统一的底部安全区间隙"),),
    ),
)


def swift_files() -> list[Path]:
    return sorted(SOURCE_ROOT.rglob("*.swift"))


def syntax_index() -> dict[str, dict]:
    checker = ROOT / "Scripts/check-code-quality.py"
    spec = importlib.util.spec_from_file_location("check_code_quality", checker)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"SwiftSyntax 索引器加载失败：{checker}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.swift_syntax_index(module.swift_files())


def ast_has_marker(facts: dict, marker: str, scope: list[str] | None = None) -> bool:
    normalized = re.sub(r"\s+", " ", marker).strip()
    in_scope = lambda item: scope is None or item.get("scope") == scope
    if normalized.startswith("struct "):
        name = normalized.removeprefix("struct ").strip()
        return any(
            declaration["kind"] == "struct"
            and declaration["name"] == name
            and (scope is None or declaration["scope"] + [declaration["name"]] == scope)
            for declaration in facts["declarations"]
        )

    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", normalized):
        return any(
            declaration["name"] == normalized
            and in_scope({"scope": declaration["scope"] + [declaration["name"]]})
            for declaration in facts["declarations"]
        ) or any(
            (
                call["value"] == normalized
                or call["value"].endswith("." + normalized)
                or call["value"].startswith(normalized + ".")
            )
            and in_scope(call)
            for call in facts["calls"]
        ) or any(
            (
                member["value"] == normalized
                or member["value"].endswith("." + normalized)
                or member["value"].startswith(normalized + ".")
            )
            and in_scope(member)
            for member in facts["members"]
        ) or any(
            re.search(
                rf"(?<![A-Za-z0-9_$]){re.escape(normalized)}(?![A-Za-z0-9_$])",
                binding["value"].split("=", 1)[0],
            )
            and in_scope(binding)
            for binding in facts["bindings"]
        )

    variants = {normalized}
    for keyword in ("let ", "var "):
        if normalized.startswith(keyword):
            variants.add(normalized.removeprefix(keyword))
    collections = (
        facts["calls"], facts["invocations"], facts["members"], facts["expressions"],
        facts["bindings"], facts["controlFlow"], facts["typeNames"],
    )
    if any(
        any(
            (
                expected == re.sub(r"\s+", " ", item["value"]).strip()
                or expected in re.sub(r"\s+", " ", item["value"]).strip()
            )
            and in_scope(item)
            for expected in variants
        )
        for collection in collections
        for item in collection
    ):
        return True

    if any(normalized in segment["value"] and in_scope(segment) for segment in facts["stringSegments"]):
        return True
    return False


def view_scopes(facts: dict) -> list[list[str]]:
    return [
        declaration["scope"] + [declaration["name"]]
        for declaration in facts["declarations"]
        if any(inherited.rsplit(".", 1)[-1] == "View" for inherited in declaration["inheritedTypes"])
    ]


def view_entries(
    syntax: dict[str, dict], view_name: str, source_root: Path = SOURCE_ROOT
) -> list[tuple[Path, dict, list[str]]]:
    return [
        (Path(path), facts, scope)
        for path, facts in syntax.items()
        if Path(path).is_relative_to(source_root)
        for scope in view_scopes(facts)
        if scope[-1] == view_name
    ]


def child_view_entries(
    syntax: dict[str, dict], call_name: str, parent_scope: list[str]
) -> list[tuple[Path, dict, list[str]]]:
    components = call_name.split(".")
    candidates = view_entries(syntax, components[-1])
    if len(components) > 1:
        qualified = [
            entry for entry in candidates
            if entry[2][-len(components):] == components
        ]
        return qualified if qualified else []

    for end in range(len(parent_scope), -1, -1):
        lexical_parent = parent_scope[:end]
        local = [entry for entry in candidates if entry[2][:-1] == lexical_parent]
        if local:
            return local

    top_level = [entry for entry in candidates if len(entry[2]) == 1]
    if len(top_level) == 1:
        return top_level
    if len(candidates) == 1:
        return candidates
    return []


def type_entries(
    syntax: dict[str, dict], type_name: str, source_root: Path = SOURCE_ROOT
) -> list[tuple[Path, dict, list[str]]]:
    return [
        (Path(path), facts, declaration["scope"] + [declaration["name"]])
        for path, facts in syntax.items()
        if Path(path).is_relative_to(source_root)
        for declaration in facts["declarations"]
        if declaration["name"] == type_name
        and declaration["kind"] in {"struct", "class", "actor", "extension"}
    ]


def has_component_declaration(symbol: str, declarations: list[dict]) -> bool:
    expected_inheritance = COMPONENT_INHERITANCE[symbol]
    return any(
        declaration["name"] == symbol
        and declaration["kind"] == "struct"
        and (
            expected_inheritance is None
            or any(
                inherited.rsplit(".", 1)[-1] == expected_inheritance
                for inherited in declaration["inheritedTypes"]
            )
        )
        for declaration in declarations
    )


def list_icon_findings(path: Path, facts: dict) -> list[str]:
    findings: list[str] = []
    for icon in facts.get("listIcons", []):
        if not icon["containers"]:
            continue
        symbol = icon["symbol"].strip()
        possible_symbols = resolved_icon_symbols(symbol, facts, icon["scope"])
        all_symbols_are_standard = bool(possible_symbols) and all(
            re.search(r"checkmark|circle|chevron|xmark|minus|star", candidate)
            for candidate in possible_symbols
        )
        if not all_symbols_are_standard:
            findings.append(
                f"{path}: {'.'.join(icon['scope'])} 列表/表单左侧图标需使用公共组件或静态可验证的标准符号"
                f"（{icon['name']}: {symbol}）"
            )
    return findings


def resolved_icon_symbols(symbol: str, facts: dict, scope: list[str]) -> list[str]:
    literal = re.fullmatch(r'(?:#+)?"([^"\n]*)"(?:#+)?', symbol.strip())
    if literal:
        return [literal.group(1)]

    candidates = re.findall(r'"([^"\n]*)"', symbol)
    if candidates:
        return candidates

    variable = re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", symbol.strip())
    if variable:
        for binding in facts.get("bindings", []):
            if binding["scope"] != scope:
                continue
            match = re.match(rf"{re.escape(symbol.strip())}\s*=\s*(.+)$", binding["value"], re.S)
            if match:
                candidates = re.findall(r'"([^"\n]*)"', match.group(1))
                if candidates:
                    return candidates

    called_function = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(", symbol.strip())
    if called_function:
        function_name = called_function.group(1)
        candidates = []
        for function in facts.get("functions", []):
            if function["scope"] != scope or not re.search(
                rf"\bfunc\s+{re.escape(function_name)}\s*\(", function["value"]
            ):
                continue
            candidates.extend(re.findall(r'"([^"\n]*)"', mask_comments(function["value"])))
        if candidates:
            return candidates
    return []


def view_or_child_has_marker(
    syntax: dict[str, dict],
    facts: dict,
    scope: list[str],
    marker: str,
    visited: set[tuple[int, tuple[str, ...]]] | None = None,
) -> bool:
    if ast_has_marker(facts, marker, scope):
        return True
    visited = set() if visited is None else visited
    identity = (id(facts), tuple(scope))
    if identity in visited:
        return False
    visited.add(identity)
    child_calls = {
        call["value"]
        for call in facts["calls"]
        if call["scope"] == scope
    }
    for child_call in child_calls:
        for _, child_facts, child_scope in child_view_entries(syntax, child_call, scope):
            if view_or_child_has_marker(syntax, child_facts, child_scope, marker, visited):
                return True
    return False


def image_only_button_findings(path: Path, facts: dict) -> list[str]:
    return [
        f"{path}: {'.'.join(invocation['scope'])} 图片型操作控件需提供 accessibilityLabel"
        f"（{invocation['value'][:96].replace(chr(10), ' ')}）"
        for invocation in image_only_label_facts(facts)
    ]


def ast_marker_boundary_findings() -> list[str]:
    facts = {
        "declarations": [{"kind": "struct", "name": "SampleView"}],
        "calls": [{"value": "AppFailureState", "scope": ["SampleView"]}],
        "invocations": [
            {"value": 'Text("课程暂未发布说明")', "scope": ["SampleView"]}
        ],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "identifiers": ["AppFailureState", "Text"],
        "stringSegments": [{"value": "课程暂未发布说明", "scope": ["SampleView"]}],
    }
    findings = []
    if not ast_has_marker(facts, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：组件调用识别")
    if ast_has_marker(facts, "AppFailureStates"):
        findings.append("UI 契约规则边界自检失败：标识符精确匹配")
    if not ast_has_marker(facts, 'Text("课程暂未发布说明")'):
        findings.append("UI 契约规则边界自检失败：调用文案联合识别")
    if ast_has_marker(facts, 'Text("课程未发布说明")'):
        findings.append("UI 契约规则边界自检失败：字符串片段精确匹配")
    unrelated_scope_facts = {
        **facts,
        "calls": [{"value": "AppFailureState", "scope": ["OtherView"]}],
        "stringSegments": [{"value": "课程暂未发布说明", "scope": ["OtherView"]}],
    }
    if ast_has_marker(unrelated_scope_facts, "AppFailureState", ["SampleView"]):
        findings.append("UI 契约规则边界自检失败：组件调用严格遵循当前 View 作用域")
    qualified_facts = {
        **facts,
        "calls": [{"value": "AppDateText.relativeText", "scope": ["SampleView"]}],
    }
    if not ast_has_marker(qualified_facts, "AppDateText", ["SampleView"]):
        findings.append("UI 契约规则边界自检失败：模块限定调用的根类型识别")

    scattered_facts = {
        "declarations": [],
        "calls": [],
        "invocations": [{"value": 'Text("其它文案")', "scope": ["SampleView"]}],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "identifiers": ["AppFailureState", "Text"],
        "stringSegments": [{"value": "课程暂未发布说明", "scope": ["SampleView"]}],
    }
    if ast_has_marker(scattered_facts, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：分散标识符被识别为组件契约")
    if ast_has_marker(scattered_facts, 'Text("课程暂未发布说明")'):
        findings.append("UI 契约规则边界自检失败：跨节点调用与文案被识别为同一表达式")
    literal_only_facts = {
        **scattered_facts,
        "calls": [{"value": "Text", "scope": ["SampleView"]}],
        "invocations": [{"value": 'Text("AppFailureState")', "scope": ["SampleView"]}],
        "stringSegments": [{"value": "AppFailureState", "scope": ["SampleView"]}],
    }
    if ast_has_marker(literal_only_facts, "AppFailureState"):
        findings.append("UI 契约规则边界自检失败：源码字面量被识别为组件调用")
    control = {"name": "Toggle", "invocation": 'Toggle("sample", isOn: $value)', "scope": ["SampleView"]}
    attached_modifier = {
        "name": "appSelectionFeedback",
        "base": 'Toggle("sample", isOn: $value)',
        "scope": ["SampleView"],
    }
    unrelated_modifier = {
        **attached_modifier,
        "base": 'Button("sample") {}',
        "scope": ["OtherView"],
    }
    if not selection_control_has_feedback(control, [attached_modifier]):
        findings.append("UI 契约规则边界自检失败：控件上的触感修饰器识别")
    if selection_control_has_feedback(control, [unrelated_modifier]):
        findings.append("UI 契约规则边界自检失败：控件与触感修饰器保持同一表达式")

    parent_facts = {
        "declarations": [{"kind": "struct", "name": "ParentView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [{"value": "ChildView", "scope": ["ParentView"]}],
        "invocations": [],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "scopedIdentifiers": [],
        "stringSegments": [],
    }
    child_facts = {
        "declarations": [{"kind": "struct", "name": "ChildView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [{"value": "appSelectionFeedback", "scope": ["ChildView"]}],
        "invocations": [],
        "members": [],
        "expressions": [],
        "bindings": [],
        "controlFlow": [],
        "typeNames": [],
        "scopedIdentifiers": [],
        "stringSegments": [],
    }
    delegated_syntax = {
        str(SOURCE_ROOT / "moved/Parent.swift"): parent_facts,
        str(SOURCE_ROOT / "shared/Child.swift"): child_facts,
    }
    if not view_or_child_has_marker(delegated_syntax, parent_facts, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：直接子 View 的公共触感调用识别")
    wrapped_parent_facts = {
        **parent_facts,
        "calls": [{"value": "WrapperView", "scope": ["ParentView"]}],
    }
    wrapper_facts = {
        **parent_facts,
        "declarations": [{"kind": "struct", "name": "WrapperView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [{"value": "LeafView", "scope": ["WrapperView"]}],
    }
    leaf_facts = {
        **child_facts,
        "declarations": [{"kind": "struct", "name": "LeafView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [{"value": "appSelectionFeedback", "scope": ["LeafView"]}],
    }
    deep_syntax = {
        str(SOURCE_ROOT / "parent.swift"): wrapped_parent_facts,
        str(SOURCE_ROOT / "wrapper.swift"): wrapper_facts,
        str(SOURCE_ROOT / "leaf.swift"): leaf_facts,
    }
    if not view_or_child_has_marker(deep_syntax, wrapped_parent_facts, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：多层子 View 的契约归属识别")
    cyclic_parent = {
        **parent_facts,
        "calls": [{"value": "WrapperView", "scope": ["ParentView"]}],
    }
    cyclic_wrapper = {
        **wrapper_facts,
        "calls": [{"value": "ParentView", "scope": ["WrapperView"]}],
    }
    cycle_syntax = {
        str(SOURCE_ROOT / "parent.swift"): cyclic_parent,
        str(SOURCE_ROOT / "wrapper.swift"): cyclic_wrapper,
    }
    if view_or_child_has_marker(cycle_syntax, cyclic_parent, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：递归组件循环终止")
    plain_wrapper = {
        **wrapper_facts,
        "calls": [{"value": "PlainLeafView", "scope": ["WrapperView"]}],
    }
    unrelated_leaf = {
        **leaf_facts,
        "declarations": [{"kind": "struct", "name": "UnrelatedLeafView", "scope": [], "inheritedTypes": ["View"]}],
    }
    isolated_syntax = {
        str(SOURCE_ROOT / "parent.swift"): wrapped_parent_facts,
        str(SOURCE_ROOT / "wrapper.swift"): plain_wrapper,
        str(SOURCE_ROOT / "unrelated.swift"): unrelated_leaf,
    }
    if view_or_child_has_marker(isolated_syntax, wrapped_parent_facts, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：独立同名子树掩盖契约缺口")
    nested_child_facts = {
        **leaf_facts,
        "declarations": [{
            "kind": "struct", "name": "ChildView", "scope": ["Outer", "ParentView"], "inheritedTypes": ["View"]
        }],
    }
    top_level_child_facts = {
        **leaf_facts,
        "declarations": [{"kind": "struct", "name": "ChildView", "scope": [], "inheritedTypes": ["View"]}],
        "calls": [],
    }
    nested_parent_facts = {
        **parent_facts,
        "declarations": [{"kind": "struct", "name": "ParentView", "scope": ["Outer"], "inheritedTypes": ["View"]}],
        "calls": [{"value": "ChildView", "scope": ["Outer", "ParentView"]}],
    }
    shadow_syntax = {
        str(SOURCE_ROOT / "nested-parent.swift"): nested_parent_facts,
        str(SOURCE_ROOT / "nested-child.swift"): nested_child_facts,
        str(SOURCE_ROOT / "top-level-child.swift"): top_level_child_facts,
    }
    if child_view_entries(shadow_syntax, "ChildView", ["Outer", "ParentView"]) != [
        (SOURCE_ROOT / "nested-child.swift", nested_child_facts, ["Outer", "ParentView", "ChildView"])
    ]:
        findings.append("UI 契约规则边界自检失败：嵌套 View 名称优先解析")
    contract = ComponentContract(name="样例", requirements=(("AppFailureState", "需要公共失败状态"),))
    first = {**parent_facts, "calls": [{"value": "AppFailureState", "scope": ["FirstView"]}]}
    second = {**parent_facts, "calls": []}
    contract_syntax = {"first.swift": first, "second.swift": second}
    if contract_scope_findings(contract, contract_syntax, first, ["FirstView"], Path("first.swift")):
        findings.append("UI 契约规则边界自检失败：已满足契约的 View 被报告")
    if not contract_scope_findings(contract, contract_syntax, second, ["SecondView"], Path("second.swift")):
        findings.append("UI 契约规则边界自检失败：相邻 View 的组件掩盖契约缺口")
    list_control = {"name": "List", "invocation": "List { Text(\"A\") }", "scope": ["FirstView"], "start": 10}
    other_style = {"name": "appGroupedListStyle", "base": "List { Text(\"B\") }", "scope": ["FirstView"], "baseStart": 40}
    if list_has_grouped_style(list_control, [other_style]):
        findings.append("UI 契约规则边界自检失败：相邻 List 的样式掩盖归属缺口")
    if not list_has_grouped_style(list_control, [{**other_style, "base": list_control["invocation"], "baseStart": 10}]):
        findings.append("UI 契约规则边界自检失败：List 自身的样式归属识别")
    if list_has_grouped_style(list_control, [{**other_style, "base": list_control["invocation"]}]):
        findings.append("UI 契约规则边界自检失败：同文本相邻 List 的样式归属识别")
    return findings


def selection_control_has_feedback(control: dict, modifiers: list[dict]) -> bool:
    prefix = re.compile(rf"^(?:SwiftUI\.)?{re.escape(control['name'])}\s*\(")
    return any(
        modifier["name"] == "appSelectionFeedback"
        and modifier["scope"] == control["scope"]
        and prefix.search(modifier["base"].lstrip())
        and control["invocation"] in modifier["base"]
        for modifier in modifiers
    )


def list_has_grouped_style(control: dict, modifiers: list[dict]) -> bool:
    return any(
        modifier["name"] == "appGroupedListStyle"
        and modifier["scope"] == control["scope"]
        and modifier["baseStart"] == control["start"]
        and modifier["base"].lstrip().startswith(control["invocation"])
        for modifier in modifiers
    )


def contract_scope_findings(
    contract: ComponentContract, syntax: dict[str, dict], facts: dict, scope: list[str], path: Path
) -> list[str]:
    findings: list[str] = []
    if contract.any_tokens and not any(
        view_or_child_has_marker(syntax, facts, scope, token)
        for token in contract.any_tokens
    ):
        findings.append(f"{path}: {'.'.join(scope)} {contract.name}缺少首屏状态公共组件")
    for token, message in contract.requirements:
        if not view_or_child_has_marker(syntax, facts, scope, token):
            findings.append(f"{path}: {'.'.join(scope)} {contract.name}{message}（缺少 {token}）")
    return findings


def check_component_contracts(errors: list[str], syntax: dict[str, dict]) -> None:
    sources = {path: path.read_text(encoding="utf-8") for path in swift_files()}
    code_sources = {path: mask_literals_and_comments(source) for path, source in sources.items()}
    comment_free_sources = {path: mask_comments(source) for path, source in sources.items()}

    # Public component existence comes from declaration nodes, independent of comments and strings.
    component_declarations = [
        declaration
        for path, facts in syntax.items()
        if Path(path).is_relative_to(SOURCE_ROOT)
        for declaration in facts["declarations"]
    ]
    for group, symbols in COMPONENT_GROUPS:
        for symbol in symbols:
            if not has_component_declaration(symbol, component_declarations):
                expected = COMPONENT_INHERITANCE[symbol]
                requirement = "struct" if expected is None else f"struct: {expected}"
                errors.append(f"公共组件组「{group}」缺少符合 {requirement} 的 {symbol}")

    for contract in COMPONENT_CONTRACTS:
        members: dict[Path, list[list[str]]] = {}
        for view_name in contract.view_names:
            entries = view_entries(syntax, view_name)
            if not entries:
                errors.append(f"{contract.name}: 必需的 View 声明缺失：{view_name}")
            for path, _, scope in entries:
                members.setdefault(path, []).append(scope)
        for path, source in code_sources.items():
            if not contract.discovery_tokens or path.parent == DESIGN_SYSTEM.parent:
                continue
            facts = syntax[str(path)]
            discovered_scopes = [
                scope
                for scope in view_scopes(facts)
                if any(ast_has_marker(facts, token, scope) for token in contract.discovery_tokens)
            ]
            if discovered_scopes:
                members.setdefault(path, []).extend(discovered_scopes)
        for path, candidate_scopes in sorted(members.items()):
            if not path.is_file():
                continue
            facts = syntax[str(path)]
            relative = path.relative_to(ROOT)
            scopes = list({tuple(scope): scope for scope in candidate_scopes}.values())
            if not scopes:
                errors.append(f"{relative}: {contract.name}契约没有对应的 SwiftUI View 声明")
                continue
            for scope in scopes:
                errors.extend(contract_scope_findings(contract, syntax, facts, scope, relative))

    forbidden_duplicate_wrappers = (
        "GalleryFloatingActionButton",
        "PaperFloatingActionButton",
        "FloatingMapButton",
    )
    for path in swift_files():
        source = code_sources[path]
        for name in forbidden_duplicate_wrappers:
            if re.search(rf"\b(?:struct|class|enum)\s+{name}\b", source):
                errors.append(f"{str(path.relative_to(ROOT))}: 不得重新包装 {name}，请直接使用公共浮动按钮组件")

    # 首屏文字加载状态必须走公共状态组件；按钮内的无文字进度条仍可保留。
    for path in swift_files():
        if path == ROOT / "BIT101-iOS/Shared/DesignSystem/AppStateComponents.swift":
            continue
        source = comment_free_sources[path]
        if re.search(r"\bProgressView\s*\(\s*\"", source):
            errors.append(f"{str(path.relative_to(ROOT))}: 首屏文字加载状态必须使用 AppLoadingState/AppInlineLoadingState")

    # 页面级公共规则：只按语义模式发现，不按业务文件名列白名单。
    for path, source in code_sources.items():
        facts = syntax[str(path)]
        for scope in view_scopes(facts):
            scoped_identifiers = {
                item["value"]
                for item in facts["scopedIdentifiers"]
                if item["scope"] == scope
            }
            if scoped_identifiers & {"List", "Form", "Section"} and "ContentUnavailableView" in scoped_identifiers:
                if not any(
                    view_or_child_has_marker(syntax, facts, scope, marker)
                    for marker in ("AppFailureState", "AppEmptyState")
                ):
                    errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 页面状态必须使用公共空态/失败态组件")
            if re.search(r"\b(?:Gallery|Paper|Course|Mine|Settings)\b", str(path)) and any(
                identifier.lower() == "avatar" for identifier in scoped_identifiers
            ):
                if not view_or_child_has_marker(syntax, facts, scope, "AppAvatarView") and "AppAvatarComponents.swift" not in str(path):
                    errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 头像页面必须使用 AppAvatarView")

    # 列表/表单内的图标按语法树调用关系审计，跨行参数与闭包仍保持归属。
    for path in swift_files():
        errors.extend(list_icon_findings(path.relative_to(ROOT), syntax[str(path)]))

    direct_states = [
        str(path.relative_to(ROOT))
        for path in swift_files()
        if "ContentUnavailableView" in syntax[str(path)]["identifiers"]
        and "AppStateComponents.swift" not in str(path)
    ]
    errors.extend(f"页面不得直接实现空态/失败态：{item}" for item in direct_states)


def check_haptic_consistency(errors: list[str], syntax: dict[str, dict]) -> None:
    sources = {path: mask_literals_and_comments(path.read_text(encoding="utf-8")) for path in swift_files()}
    required = (
        ("Shared/DesignSystem/AppHapticFeedback.swift", "func appSelectionFeedback"),
        ("Shared/DesignSystem/AppHapticFeedback.swift", "sensoryFeedback(.selection, trigger:"),
        ("Shared/DesignSystem/AppHapticFeedback.swift", "func appImpactFeedback"),
        ("Shared/DesignSystem/AppHapticFeedback.swift", "sensoryFeedback(.impact, trigger:"),
        ("Shared/DesignSystem/AppLayoutComponents.swift", "appImpactFeedback"),
        ("Shared/DesignSystem/AppContentControlComponents.swift", "appSelectionFeedback"),
        ("Shell/AppShellView.swift", "appSelectionFeedback"),
        ("Schedule/ScheduleCalendarViews.swift", "appSelectionFeedback"),
        ("Schedule/ScheduleCalendarViews.swift", "appImpactFeedback"),
        ("Map/CampusMapScreen.swift", "appImpactFeedback"),
    )
    for relative_path, marker in required:
        path = SOURCE_ROOT / relative_path
        if marker not in sources.get(path, ""):
            errors.append(f"{path.relative_to(ROOT)}: 缺少系统触感入口 {marker}")

    interactive_markers = {
        "toggleTag", "selectedTags", "setRating", "selectedValues", "sortIndex",
        "sortOrder", "onToggleDone",
    }
    for path, source in sources.items():
        facts = syntax[str(path)]
        for control in facts["selectionControls"]:
            if not selection_control_has_feedback(control, facts["feedbackModifiers"]):
                errors.append(
                    f"{path.relative_to(ROOT)}: {control['name']} 控件必须由自身表达式接入 appSelectionFeedback"
                )

        for scope in view_scopes(facts):
            identifiers = {
                item["value"]
                for item in facts["scopedIdentifiers"]
                if item["scope"] == scope
            }
            if not identifiers & interactive_markers:
                continue
            if not view_or_child_has_marker(syntax, facts, scope, "appSelectionFeedback"):
                errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 选择交互缺少公共触感修饰器")

    multiselection_entries = view_entries(syntax, "AppMultiSelectionList")
    if not multiselection_entries:
        errors.append("AppMultiSelectionList: 公共多选列表 View 声明缺失")
    for path, facts, scope in multiselection_entries:
        if not ast_has_marker(facts, "appSelectionFeedback", scope):
            errors.append(f"{path.relative_to(ROOT)}: AppMultiSelectionList 必须为选择变化提供公共触感")

    button_components = (
        ("Shared/DesignSystem/AppLayoutComponents.swift", "struct AppFloatingActionButton: View"),
        ("Map/CampusMapScreen.swift", "struct FloatingMapLabelButton: View"),
    )
    for relative_path, declaration in button_components:
        source = sources.get(SOURCE_ROOT / relative_path, "")
        start = source.find(declaration)
        if start < 0 or "appImpactFeedback" not in source[start:]:
            errors.append(f"{relative_path}: 右下角操作按钮缺少公共触感")

    direct_patterns = re.compile(
        r"\.sensoryFeedback\(|UIFeedbackGenerator|UI(Selection|Impact|Notification)FeedbackGenerator|"
        r"impactOccurred\(|selectionChanged\(|notificationOccurred\(|AudioServicesPlaySystemSound|"
        r"kSystemSoundID_Vibrate|CHHapticEngine|NSHapticFeedbackManager|WKInterfaceDevice.*\.play"
    )
    haptic_file = SOURCE_ROOT / "Shared/DesignSystem/AppHapticFeedback.swift"
    for path, source in sources.items():
        if path != haptic_file and direct_patterns.search(source):
            errors.append(f"{path.relative_to(ROOT)}: 页面不得绕过公共触感修饰器")

        for match in re.finditer(r"\.app[A-Za-z]+Feedback\(", source):
            name = match.group(0)
            if name not in (".appSelectionFeedback(", ".appImpactFeedback("):
                errors.append(f"{path.relative_to(ROOT)}: 发现未登记的公共触感调用 {name}")

        if path != haptic_file and re.search(r"func app(?:Selection|Impact)Feedback", source):
            errors.append(f"{path.relative_to(ROOT)}: 公共触感接口不得重复声明")


def alert_coverage_findings(facts: dict, path: Path) -> list[str]:
    app_alert_variables = [
        variable
        for variable in facts.get("typedVariables", [])
        if re.search(r"\bAppAlert\b", variable["type"])
    ]
    findings: list[str] = []
    diagnostic_bindings: set[tuple[tuple[str, ...], str]] = set()
    for call, invocation in zip(facts.get("calls", []), facts.get("invocations", [])):
        if call["value"].split(".")[-1] != "diagnosticAlert":
            continue
        source = mask_literals_and_comments(invocation["value"])
        for variable in app_alert_variables:
            if variable["scope"] != invocation["scope"]:
                continue
            binding = re.compile(rf"\bitem\s*:\s*\${re.escape(variable['name'])}\b")
            if binding.search(source):
                diagnostic_bindings.add((tuple(variable["scope"]), variable["name"]))

    for alert in facts.get("alertModifiers", []):
        item_binding = ""
        for label, argument in zip(alert["labels"], alert["arguments"]):
            if label == "item":
                match = re.fullmatch(r"\$([A-Za-z_][A-Za-z0-9_]*)", argument.strip())
                item_binding = match.group(1) if match else ""
                break

        used_variables = {
            variable["name"]
            for variable in app_alert_variables
            if variable["scope"] == alert["scope"]
            and variable["name"] in alert.get("identifiers", [])
        }
        if item_binding and any(
            variable["name"] == item_binding and variable["scope"] == alert["scope"]
            for variable in app_alert_variables
        ):
            used_variables.add(item_binding)

        for variable_name in sorted(used_variables):
            if (tuple(alert["scope"]), variable_name) in diagnostic_bindings:
                continue
            view_name = alert["scope"][-1] if alert["scope"] else ""
            exact_local_exception = (
                view_name, variable_name
            ) in LOCAL_APP_ALERT_BINDINGS and item_binding == variable_name
            if exact_local_exception:
                continue
            findings.append(
                f"{path}: {'.'.join(alert['scope'])} 的 AppAlert「{variable_name}」"
                "必须通过 diagnosticAlert 展示"
            )
    return findings


def source_boundary_findings() -> list[str]:
    checker = ROOT / "Scripts/check-code-quality.py"
    spec = importlib.util.spec_from_file_location("check_code_quality_ui_self_test", checker)
    if spec is None or spec.loader is None:
        return ["UI 检查器自测无法加载 SwiftSyntax 索引器"]
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    source = r'''
import SwiftUI

struct ItemAlertSample: View {
    @State private var failure: AppAlert?
    var body: some View {
        Text("Sample").alert(
            item: $failure
        ) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
    }
}

struct AlternateAlertSample: View {
    @State private var failure: AppAlert?
    @State private var isPresented = false
    var body: some View {
        Text("Sample").alert("Failure", isPresented: $isPresented) {
            Button("Dismiss") {}
        } message: {
            Text(failure?.message ?? "")
        }
    }
}

struct ConfirmationAlertSample: View {
    @State private var failure: AppAlert?
    @State private var isPresented = false
    var body: some View {
        Text("Sample").alert("failure", isPresented: $isPresented) {
            Button("Dismiss") {}
        }
    }
}

struct DiagnosticConfirmationAlertSample: View {
    @State private var alert: AppAlert?
    @State private var isPresented = false
    var body: some View {
        Text("Sample")
            .alert("Save draft?", isPresented: $isPresented) {
                Button("Save") {
                    alert = AppAlert(title: "Save failed", message: "Retry")
                }
            }
            .diagnosticAlert(item: $alert)
    }
}

struct CourseEvaluationLink: View {
    @State private var alert: AppAlert?
    @State private var diagnosticAlert: AppAlert?
    var body: some View {
        Text("Sample").alert(item: $alert) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }.diagnosticAlert(item: $diagnosticAlert)
    }
}

struct CourseEvaluationDestination: View {
    @State private var expectedAlert: AppAlert?
    var body: some View {
        Text("Sample").alert(item: $expectedAlert) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
    }
}

struct ListIconSample: View {
    let iconName = "gearshape"
    var body: some View {
        List {
            Image(
                systemName: "person.fill"
            )
            Image(
                systemName: "checkmark.circle"
            )
            Image(systemName: iconName)
            Image(systemName: isDone ? "checkmark.circle" : "circle")
            Image(systemName: safeSystemIcon(isDone: isDone))
        }
    }

    private func safeSystemIcon(isDone: Bool) -> String {
        isDone ? "checkmark.circle.fill" : "circle"
    }
}

struct MissingButtonLabelSample: View {
    var body: some View {
        Button(action: {}) {
            Image(systemName: "magnifyingglass")
        }
    }
}

struct AccessibleButtonLabelSample: View {
    var body: some View {
        Button(action: {}) {
            Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("搜索")
    }
}

struct ImageMenuLabelWithTextItemsSample: View {
    var body: some View {
        Menu {
            Button("设置") {}
        } label: {
            Image(systemName: "ellipsis")
        }
    }
}

struct ImageButtonLabelWithTextActionSample: View {
    var body: some View {
        Button(action: { _ = Text("操作内容") }) {
            Image(systemName: "magnifyingglass")
        }
    }
}

struct AccessibleMenuLabelSample: View {
    var body: some View {
        Menu {
            Button("设置") {}
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel("更多")
        }
    }
}

struct MenuChildLabelScopeSample: View {
    var body: some View {
        Menu {
            Button(action: {}, label: {
                Image(systemName: "folder")
                    .accessibilityLabel("打开文件夹")
            })
        } label: {
            Image(systemName: "ellipsis")
        }
    }
}

struct TitledMenuSample: View {
    var body: some View {
        Menu("更多") {
            Button(action: {}) {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
    }
}

enum AppTagChip { case sample }
class AppSMSVerificationSheet: View {}
extension AppSearchBarContainer: View {}
struct AppLoadingState {}
struct AppAvatarView: View { var body: some View { Text("avatar") } }
struct AppFixedColumnItem {}
'''
    try:
        facts = module.swift_syntax_index_sources({"ui-self-test.swift": source})["ui-self-test.swift"]
    except (OSError, subprocess.CalledProcessError, RuntimeError, KeyError) as error:
        return [f"UI 检查器自测无法解析内存 Swift 样例：{error}"]

    findings: list[str] = []
    item_alerts = alert_coverage_findings(facts, Path("ui-self-test.swift"))
    expected_invalid = {
        "ItemAlertSample",
        "AlternateAlertSample",
    }
    if len(item_alerts) != len(expected_invalid) or not all(
        any(view_name in finding for finding in item_alerts)
        for view_name in expected_invalid
    ):
        findings.append("UI 检查器自测：SwiftSyntax 未识别 item 与 isPresented 两种 AppAlert 展示路径")
    diagnostic_scope = {
        "typedVariables": [
            variable for variable in facts["typedVariables"]
            if variable["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "alertModifiers": [
            alert for alert in facts["alertModifiers"]
            if alert["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "calls": [
            call for call in facts["calls"]
            if call["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
        "invocations": [
            invocation for invocation in facts["invocations"]
            if invocation["scope"][-1] == "DiagnosticConfirmationAlertSample"
        ],
    }
    if alert_coverage_findings(diagnostic_scope, Path("ui-self-test.swift")):
        findings.append("UI 检查器自测：诊断提示与确认弹层共享 AppAlert 时的归属识别")

    allowed_alerts = [
        finding
        for view_name in ("CourseEvaluationLink", "CourseEvaluationDestination")
        for finding in alert_coverage_findings(
            {
                "typedVariables": [
                    variable for variable in facts["typedVariables"]
                    if variable["scope"][-1] == view_name
                ],
                "alertModifiers": [
                    alert for alert in facts["alertModifiers"]
                    if alert["scope"][-1] == view_name
                ],
            },
            Path("ui-self-test.swift"),
        )
    ]
    if allowed_alerts:
        findings.append("UI 检查器自测：既有用户输入提示例外未按 View 与绑定精确匹配")

    icon_findings = list_icon_findings(Path("UI/ListIconSample.swift"), facts)
    if len(icon_findings) != 2 or not any("person.fill" in finding for finding in icon_findings) or not any(
        "iconName" in finding for finding in icon_findings
    ):
        findings.append("UI 检查器自测：静态与动态列表图标契约识别异常")

    button_labels = image_only_label_facts(facts)
    expected_image_only_controls = {
        "MissingButtonLabelSample",
        "ImageMenuLabelWithTextItemsSample",
        "ImageButtonLabelWithTextActionSample",
        "MenuChildLabelScopeSample",
    }
    observed_image_only_controls = {item["scope"][-1] for item in button_labels}
    if observed_image_only_controls != expected_image_only_controls:
        findings.append("UI 检查器自测：控件标签闭包与菜单项/操作闭包归属识别异常")

    wrapped_calls = """
    withAnimation(
        .spring(
            duration: 0.2
        )
    ) {}
    thumbnailButton(
        image: image,
        width: 40
    )
    .background(
        .ultraThinMaterial,
        in: Circle()
    )
    .frame(
        width: 42,
        height: 42
    )
    """
    masked_calls = mask_literals_and_comments(wrapped_calls)
    wrapped_patterns = (
        DIRECT_ANIMATION_DURATION,
        DIRECT_THUMBNAIL_GEOMETRY,
        DIRECT_FLOATING_MATERIAL,
        DIRECT_FLOATING_SIZE,
    )
    if not all(pattern.search(masked_calls) for pattern in wrapped_patterns):
        findings.append("UI 检查器自测：多行视觉规则调用识别异常")

    visual_source = r'''
import SwiftUI
struct VisualRuleSample: View {
    @State private var query = ""
    private let sampleOpacity: Double = 0.4
    private let fixedWidth: CGFloat = 40
    private let derivedWidth = AppDesignSystem.Size.avatar * 2
    private let repeatedWidth = AppDesignSystem.Size.avatar + AppDesignSystem.Size.avatar

    var body: some View {
        Text("https://example.invalid RoundedRectangle() Color.orange .frame(width: 42, height: 42) TextField(\"提示\", text: $query)")
        RoundedRectangle(
            cornerRadius: 12
        )
        Color(uiColor: .systemBackground)
        Color.accentColor
        Color.orange
        Color.red
        Color.blue
        Color.green
        Color.gray
        Color.pink
        Color.indigo
        Color.teal
        Color.brown
        Color.primary
        Color.secondary
        Text("Rule")
            .padding(12)
            .opacity(0.5)
            .foregroundStyle(.secondary)
            .font(.body)
            .blur(radius: 2)
            .frame(width: 40, height: 40)
            .cornerRadius(8)
            .frame(minHeight: 44)
        GridItem(.adaptive(minimum: 32))
        StrokeStyle(lineWidth: 2, dash: [1, 2])
        EdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
        VStack(spacing: 12) {
            HStack { Text("row") }
            HStack(spacing: 12) { Text("row") }
        }
        TextField("搜索提示", text: $query)
        List { Text("row") }
            .listStyle(.insetGrouped)
            .listSectionSpacing(12)
        List { Text("row") }
            .listStyle(.plain)
        Section(header: { Text("标题") }) { Text("row") }
        withAnimation(
            .spring(
                duration: 0.2
            )
        ) {}
        thumbnailButton(
            image: image,
            width: 40
        )
        .background(
            .ultraThinMaterial,
            in: Circle()
        )
        .frame(
            width: 42,
            height: 42
        )
    }
}
'''
    try:
        visual_facts = module.swift_syntax_index_sources(
            {"visual-rule-self-test.swift": visual_source}
        )["visual-rule-self-test.swift"]
    except (OSError, subprocess.CalledProcessError, RuntimeError, KeyError) as error:
        return [f"UI 检查器自测无法解析视觉规则样例：{error}"]
    rectangle_nodes = pattern_nodes(visual_facts, DIRECT_ROUNDED_RECTANGLE)
    if len(rectangle_nodes) != 1 or not DIRECT_ROUNDED_RECTANGLE.search(
        mask_literals_and_comments(rectangle_nodes[0]["value"])
    ):
        findings.append("UI 检查器自测：AST 视觉规则未识别多行形状调用")
    text_invocations = [
        invocation
        for call, invocation in zip(visual_facts["calls"], visual_facts["invocations"])
        if call_name(call["value"]) == "Text" and "https://example.invalid" in invocation["value"]
    ]
    if not all(
        any(
            pattern.search(mask_literals_and_comments(node["value"]))
            for node in pattern_nodes(visual_facts, pattern)
        )
        for pattern in wrapped_patterns
    ):
        findings.append("UI 检查器自测：AST 范围未覆盖多行视觉规则表达式")
    coverage_patterns = [
        *(pattern for pattern, _ in DIRECT_VISUAL_RULES),
        *(pattern for pattern, _ in DIRECT_SEMANTIC_COLOR_RULES),
        DIRECT_OPACITY_LITERAL,
        DIRECT_OPACITY_ASSIGNMENT,
        PADDING_LITERAL,
        STACK_SPACING_LITERAL,
        DIRECT_PLAIN_LIST_STYLE,
        DERIVED_DESIGN_TOKEN,
        REPEATED_DESIGN_TOKEN,
    ]
    text_starts = {int(node.get("start", -1)) for node in text_invocations}
    text_candidate_rules = [
        pattern.pattern
        for pattern in dict.fromkeys(coverage_patterns)
        for node in pattern_nodes(visual_facts, pattern)
        if int(node.get("start", -2)) in text_starts
    ]
    if text_candidate_rules:
        findings.append("UI 检查器自测：Text 文案进入视觉规则候选节点（" + ", ".join(text_candidate_rules) + "）")
    uncovered_rules = [
        pattern.pattern
        for pattern in dict.fromkeys(coverage_patterns)
        if not any(
            pattern.search(
                mask_comments(node["value"])
                if pattern is DIRECT_INPUT_PLACEHOLDER
                else mask_literals_and_comments(node["value"])
            )
            for node in pattern_nodes(visual_facts, pattern)
        )
    ]
    if uncovered_rules:
        examples = {
            pattern.pattern: [node["value"][:72].replace("\n", " ") for node in pattern_nodes(visual_facts, pattern)[:2]]
            for pattern in dict.fromkeys(coverage_patterns)
            if pattern.pattern in uncovered_rules
        }
        findings.append("UI 检查器自测：AST 规则映射缺少样例：" + repr(examples))
    reviewed_path = SOURCE_ROOT / "Course/CourseCommentViews.swift"
    reviewed_source = "thumbnailButton(image: displayedImages[0], index: 0, width: 180)"
    if not is_reviewed_fixed_geometry(
        reviewed_path,
        reviewed_source,
        DIRECT_THUMBNAIL_GEOMETRY,
        {"value": reviewed_source},
    ):
        findings.append("UI 检查器自测：登记几何变体未精确命中")
    unregistered_source = "thumbnailButton(image: anotherImage, index: 1, width: 52)"
    if is_reviewed_fixed_geometry(
        reviewed_path,
        reviewed_source + "\n" + unregistered_source,
        DIRECT_THUMBNAIL_GEOMETRY,
        {"value": unregistered_source},
    ):
        findings.append("UI 检查器自测：登记几何例外覆盖同文件的其它表达式")

    declarations = facts["declarations"]
    if has_component_declaration("AppTagChip", declarations):
        findings.append("UI 检查器自测：非 View 同名枚举通过公共组件声明检查")
    if has_component_declaration("AppSMSVerificationSheet", declarations):
        findings.append("UI 检查器自测：同名 class 通过公共组件声明检查")
    if has_component_declaration("AppSearchBarContainer", declarations):
        findings.append("UI 检查器自测：同名 extension 通过公共组件声明检查")
    if has_component_declaration("AppLoadingState", declarations):
        findings.append("UI 检查器自测：未实现 View 的同名结构通过公共组件声明检查")
    if not has_component_declaration("AppAvatarView", declarations):
        findings.append("UI 检查器自测：View 公共组件声明识别失败")
    if not has_component_declaration("AppFixedColumnItem", declarations):
        findings.append("UI 检查器自测：无协议继承的模型结构声明识别失败")
    return findings


def map_theme_color_contract_findings() -> list[str]:
    path = SOURCE_ROOT / MAP_THEME_COLOR_CONTRACT[0]
    source = "extension AppDesignSystem {\n    enum Map {\n        " + MAP_THEME_COLOR_CONTRACT[1] + "\n    }\n}"
    start = source.encode("utf-8").find(b"Color.green")
    node = {"scope": ["AppDesignSystem", "Map"], "start": start}
    if not is_registered_map_theme_color_definition(path, source, node):
        return ["UI 检查器自测：地图主题令牌的精确源码例外无法识别"]

    unrelated_source = source.replace(MAP_THEME_COLOR_CONTRACT[1], "static let otherAccent = Color.green")
    if is_registered_map_theme_color_definition(path, unrelated_source, node):
        return ["UI 检查器自测：地图主题令牌例外覆盖了相邻声明"]
    wrong_scope_node = {**node, "scope": ["OtherDesignSystem", "Map"]}
    if is_registered_map_theme_color_definition(path, source, wrong_scope_node):
        return ["UI 检查器自测：地图主题令牌例外覆盖了其它词法作用域"]
    return []


def check_error_report_coverage(errors: list[str], syntax: dict[str, dict]) -> None:
    schedule_notice_presenters = 0
    for path in swift_files():
        source = mask_literals_and_comments(path.read_text(encoding="utf-8"))
        schedule_notice_presenters += len(re.findall(r"\.scheduleViewModel\.\$notice\.compactMap", source))
        facts = syntax[str(path)]
        errors.extend(alert_coverage_findings(facts, path.relative_to(ROOT)))
        for scope in view_scopes(facts):
            failed_states = [
                flow["value"]
                for flow in facts["controlFlow"]
                if flow["scope"] == scope
                and re.search(r"(?:case|if case|else if case) let \.failed\(message\)", flow["value"])
                and "ContentUnavailableView" in flow["value"]
            ]
            if any(
                "DiagnosticRecoveryActions" not in flow and "PaperEmptyState" not in flow
                for flow in failed_states
            ):
                errors.append(f"{path.relative_to(ROOT)}: {'.'.join(scope)} 失败态缺少错误报告入口")

    if schedule_notice_presenters != 1:
        errors.append(f"日程共享错误展示器数量异常：引用数 {schedule_notice_presenters}")


def check_fonts(errors: list[str], syntax: dict[str, dict]) -> None:
    swift_explicit_font_size = re.compile(
        r"(?:\bFont\.system|\.system)\s*\(\s*size\s*:\s*(?P<value>[^,\)\n]+)"
    )
    ui_explicit_font_size = re.compile(
        r"\bUIFont\.systemFont\s*\(\s*ofSize\s*:\s*(?P<value>[^,\)\n]+)"
    )
    custom_font = re.compile(r"\bFont\.custom\s*\(")

    for path_string, facts in syntax.items():
        path = Path(path_string)
        if not path.is_file():
            continue
        raw_source = path.read_text(encoding="utf-8")
        relative = path.relative_to(ROOT)
        if path not in DESIGN_SYSTEM_SOURCES:
            for call, invocation in zip(facts.get("calls", []), facts.get("invocations", [])):
                name = call_name(call["value"])
                source = mask_literals_and_comments(invocation["value"])
                if name == "system":
                    for match in swift_explicit_font_size.finditer(source):
                        value = match.group("value").strip()
                        if "AppDesignSystem." not in value:
                            line = pattern_line_number(raw_source, invocation, match.start())
                            errors.append(
                                f"{relative}:{line}: 字体字号必须使用设计系统令牌或系统语义字体：{value}"
                            )
                if name == "systemFont":
                    for match in ui_explicit_font_size.finditer(source):
                        value = match.group("value").strip()
                        if "AppDesignSystem." not in value:
                            line = pattern_line_number(raw_source, invocation, match.start())
                            errors.append(
                                f"{relative}:{line}: UIFont 字号必须使用设计系统令牌或系统语义字体：{value}"
                            )
                if name == "custom" and custom_font.search(source):
                    errors.append(f"{relative}:{pattern_line_number(raw_source, invocation, 0)}: 字体采用系统语义或公共令牌")


def check_design_token_boundaries(errors: list[str], syntax: dict[str, dict]) -> None:
    """透明度数字只允许存在于跨 target 基础刻度层。"""
    for path in swift_files():
        if path == PRIMITIVE_OPACITY_SOURCE:
            continue
        raw_source = path.read_text(encoding="utf-8")
        facts = syntax[str(path)]
        relative = path.relative_to(ROOT)
        emitted: set[tuple[str, int, str]] = set()
        for pattern, message in (
            (DIRECT_OPACITY_LITERAL, "透明度数字必须通过 AppDesignSystem.Opacity 派生"),
            (DIRECT_OPACITY_ASSIGNMENT, "透明度标量必须引用 AppDesignSystem.Opacity"),
        ):
            for node in pattern_nodes(facts, pattern):
                source = mask_literals_and_comments(node["value"])
                for match in pattern.finditer(source):
                    line_number = pattern_line_number(raw_source, node, match.start())
                    append_rule_finding(errors, emitted, relative, line_number, message, pattern)


def check_page_theme_consistency(errors: list[str], syntax: dict[str, dict]) -> None:
    """页面强调色必须使用所属模块的主题令牌。"""
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        source_relative = path.relative_to(SOURCE_ROOT).as_posix()
        raw_source = path.read_text(encoding="utf-8")
        facts = syntax[str(path)]
        for prefixes, forbidden_tokens, expected_token in PAGE_THEME_RULES:
            if not source_relative.startswith(prefixes):
                continue
            emitted: set[tuple[int, str]] = set()
            for token in forbidden_tokens:
                for node in facts.get("members", []):
                    if token not in node["value"]:
                        continue
                    line_number = pattern_line_number(raw_source, node, 0)
                    marker = (line_number, token)
                    if marker in emitted:
                        continue
                    emitted.add(marker)
                    errors.append(
                        f"{path.relative_to(ROOT)}:{line_number}: 页面主题色应使用 {expected_token}，当前发现 {token}"
                    )


def check_contextual_component_colors(errors: list[str], syntax: dict[str, dict]) -> None:
    """复用内容与组件使用页面强调色，避免绕过环境 tint 的固定高亮色。"""
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        source_relative = path.relative_to(SOURCE_ROOT).as_posix()
        if not any(
            source_relative == root or source_relative.startswith(f"{root}/")
            for root in THEME_SENSITIVE_ROOTS
        ):
            continue

        raw_source = path.read_text(encoding="utf-8")
        facts = syntax[str(path)]
        for token, expected_token in CONTEXTUAL_COLOR_BYPASSES:
            emitted: set[int] = set()
            for node in facts.get("members", []):
                if token not in node["value"]:
                    continue
                line_number = pattern_line_number(raw_source, node, 0)
                if line_number in emitted:
                    continue
                emitted.add(line_number)
                errors.append(
                    f"{path.relative_to(ROOT)}:{line_number}: "
                    f"复用组件的页面主题色应使用 {expected_token}，当前发现 {token}"
                )


def check_registered_visual_contracts(errors: list[str]) -> None:
    contracts = (
        *FIXED_GEOMETRY_CONTRACTS,
        *PAGE_THEME_CONTRACTS,
        MAP_THEME_COLOR_CONTRACT,
    )
    for relative_path, marker in contracts:
        path = SOURCE_ROOT / relative_path
        if not path.is_file():
            errors.append(f"{path.relative_to(ROOT)}: 自动视觉契约引用的源码缺失")
            continue
        source = mask_comments(path.read_text(encoding="utf-8"))
        if marker not in source:
            errors.append(f"{path.relative_to(ROOT)}: 自动视觉契约已变化，请同步更新契约声明（{marker}）")


def is_reviewed_fixed_geometry(
    path: Path, source: str, pattern: re.Pattern[str], node: dict
) -> bool:
    relative_path = path.relative_to(SOURCE_ROOT).as_posix()
    reviewed_paths = {
        "Course/CourseCommentViews.swift": DIRECT_THUMBNAIL_GEOMETRY,
        "Course/CourseHistoryGradesViews.swift": DIRECT_STROKE_GEOMETRY,
        "Gallery/GalleryComposerView.swift": DIRECT_GRID_ITEM_GEOMETRY,
    }
    expected_pattern = reviewed_paths.get(relative_path)
    normalized_node = " ".join(node["value"].split())
    return expected_pattern is pattern and any(
        entry_path == relative_path
        and " ".join(marker.split()) in " ".join(source.split())
        and " ".join(marker.split()) in normalized_node
        for entry_path, marker in FIXED_GEOMETRY_CONTRACTS
    )


def is_registered_cgfloat_contract(path: Path, node: dict) -> bool:
    relative_path = path.relative_to(SOURCE_ROOT).as_posix()
    normalized_node = " ".join(node["value"].split())
    return any(
        entry_path == relative_path and " ".join(marker.split()) in normalized_node
        for entry_path, marker in FIXED_GEOMETRY_CONTRACTS
    )


def is_registered_map_theme_color_definition(path: Path, source: str, node: dict) -> bool:
    relative_path = path.relative_to(SOURCE_ROOT).as_posix()
    if relative_path != MAP_THEME_COLOR_CONTRACT[0] or node.get("scope") != ["AppDesignSystem", "Map"]:
        return False
    start = max(0, int(node.get("start", 0)))
    encoded_source = source.encode("utf-8")
    line_start = encoded_source.rfind(b"\n", 0, start) + 1
    line_end = encoded_source.find(b"\n", start)
    line_end = len(encoded_source) if line_end < 0 else line_end
    return encoded_source[line_start:line_end].decode("utf-8").strip() == MAP_THEME_COLOR_CONTRACT[1]


def call_name(value: str) -> str:
    name = value.rsplit(".", 1)[-1]
    return name.split("<", 1)[0]


CALL_RULE_NAMES = {
    DIRECT_ROUNDED_RECTANGLE: {"RoundedRectangle"},
    DIRECT_CORNER_RADIUS: {"cornerRadius"},
    DIRECT_SYSTEM_COLOR: {"Color"},
    DIRECT_OPACITY_LITERAL: {"opacity"},
    DIRECT_FOREGROUND_STYLE: {"foregroundStyle"},
    DIRECT_FONT_MODIFIER: {"font"},
    DIRECT_GRID_ITEM_GEOMETRY: {"GridItem"},
    DIRECT_STROKE_GEOMETRY: {"StrokeStyle"},
    DIRECT_BLUR_GEOMETRY: {"blur"},
    DIRECT_THUMBNAIL_GEOMETRY: {"thumbnailButton"},
    DIRECT_FLOATING_SIZE: {"frame"},
    DIRECT_TOUCH_TARGET: {"frame"},
    DIRECT_FLOATING_MATERIAL: {"background"},
    DIRECT_GROUPED_LIST_STYLE: {"listStyle"},
    DIRECT_PLAIN_LIST_STYLE: {"listStyle"},
    DIRECT_LIST_SECTION_SPACING: {"listSectionSpacing"},
    DIRECT_INPUT_PLACEHOLDER: {"TextField", "SecureField"},
    DIRECT_CUSTOM_SECTION_HEADER: {"Section"},
    DIRECT_ANIMATION_DURATION: {"withAnimation", "animation"},
    DIRECT_BARE_HSTACK: {"HStack"},
    DIRECT_HSTACK_LITERAL: {"HStack"},
    DIRECT_FRAME_LITERAL: {"frame"},
    DIRECT_EDGE_INSETS_LITERAL: {"EdgeInsets"},
}
MEMBER_RULES = {
    DIRECT_ACCENT_COLOR,
    DIRECT_HIERARCHICAL_COLOR,
    *(pattern for pattern, _ in DIRECT_SEMANTIC_COLOR_RULES),
}
BINDING_RULES = {DIRECT_OPACITY_ASSIGNMENT, DIRECT_LOCAL_CGFLOAT_LITERAL}
EXPRESSION_RULES = {DERIVED_DESIGN_TOKEN, REPEATED_DESIGN_TOKEN}
SPACING_CALL_NAMES = {"padding", "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack"}


def pattern_nodes(facts: dict, pattern: re.Pattern[str]) -> list[dict]:
    if pattern in CALL_RULE_NAMES:
        names = CALL_RULE_NAMES[pattern]
        return [
            invocation
            for call, invocation in zip(facts.get("calls", []), facts.get("invocations", []))
            if call_name(call["value"]) in names
        ]
    if pattern is PADDING_LITERAL or pattern is STACK_SPACING_LITERAL:
        names = {"padding"} if pattern is PADDING_LITERAL else SPACING_CALL_NAMES
        return [
            invocation
            for call, invocation in zip(facts.get("calls", []), facts.get("invocations", []))
            if call_name(call["value"]) in names
        ]
    if pattern in MEMBER_RULES:
        return facts.get("members", [])
    if pattern in BINDING_RULES:
        return facts.get("bindings", [])
    if pattern in EXPRESSION_RULES:
        return facts.get("expressions", [])
    return []


def pattern_line_number(source: str, node: dict, local_position: int) -> int:
    byte_start = max(0, int(node.get("start", 0)))
    prior_lines = source.encode("utf-8")[:byte_start].count(b"\n")
    local_lines = node["value"][:local_position].count("\n")
    return prior_lines + local_lines + 1


def append_rule_finding(
    errors: list[str],
    emitted: set[tuple[str, int, str]],
    path: Path,
    line: int,
    message: str,
    pattern: re.Pattern[str],
) -> None:
    key = (pattern.pattern, line, message)
    if key in emitted:
        return
    emitted.add(key)
    errors.append(f"{path}:{line}: {message}")


def image_only_label_facts(facts: dict) -> list[dict]:
    """Collect image-only interactive expressions that need an accessible name."""
    results: list[dict] = []
    for control in facts.get("accessibilityControls", []):
        source = mask_literals_and_comments(control["label"])
        if not re.search(r"\bImage\s*\(", source):
            continue
        if re.search(r"\b(?:Text|Label)\s*\(", source):
            continue
        if control.get("hasTextTitle"):
            continue
        if any(
            modifier["name"] == "accessibilityLabel"
            and modifier["scope"] == control["scope"]
            and (
                modifier.get("baseStart", -1) == control["start"]
                or control.get("labelStart", -1) <= modifier.get("baseStart", -1) < control.get("labelEnd", -1)
            )
            for modifier in facts.get("accessibilityModifiers", [])
        ):
            continue
        results.append({"scope": control["scope"], "value": control["invocation"]})
    return results


def check_accessibility_coverage(errors: list[str], syntax: dict[str, dict]) -> None:
    for path, facts in syntax.items():
        if not path.startswith(str(ROOT) + "/") or "/BIT101-iOSTests/" in path:
            continue
        for invocation in image_only_label_facts(facts):
            errors.append(
                f"{Path(path).relative_to(ROOT)}: {'.'.join(invocation['scope'])} 图片型操作控件需提供 accessibilityLabel"
                f"（{invocation['value'][:96].replace(chr(10), ' ')}）"
            )


def check_refresh_status_contract(errors: list[str], syntax: dict[str, dict]) -> None:
    refresh_pages = ("ScoreListPage", "DDLScheduleTabView", "FreeClassroomTabView")
    for view_name in refresh_pages:
        entries = view_entries(syntax, view_name)
        if not entries:
            errors.append(f"{view_name}: 刷新数据页 View 声明缺失")
            continue
        for path, facts, scope in entries:
            if not ast_has_marker(facts, "AppRefreshStatusRow", scope):
                errors.append(f"{path.relative_to(ROOT)}: {view_name} 必须使用 AppRefreshStatusRow")
            if not ast_has_marker(facts, "appGroupedListStyle", scope):
                errors.append(f"{path.relative_to(ROOT)}: {view_name} 必须使用统一分组列表样式")

    schedule_views = view_entries(syntax, "CourseScheduleTabView")
    if not schedule_views:
        errors.append("CourseScheduleTabView: 课表顶部行 View 声明缺失")
    header_contract = (
        "if activeSchedule.isPrimary",
        "lastUpdatedText: activeSchedule.importedAt.map",
        "导入时间：",
        'trailingText: "只读"',
        "ScheduleRefreshStatusContentHeightKey.self",
        "onPreferenceChange(ScheduleRefreshStatusContentHeightKey.self)",
    )
    for path, facts, scope in schedule_views:
        missing = [item for item in header_contract if not ast_has_marker(facts, item, scope)]
        if missing:
            errors.append(
                f"{path.relative_to(ROOT)}: 我的课表与分享课表必须共用顶部行组件（缺少 {', '.join(missing)}）"
            )

        status_row_calls = sum(
            call["value"] == "AppRefreshStatusRow" and call["scope"] == scope
            for call in facts["calls"]
        )
        if status_row_calls != 2:
            errors.append(f"{path.relative_to(ROOT)}: 主课表与分享课表顶部行共用 AppRefreshStatusRow")
        if not ast_has_marker(facts, "refreshStatusContentHeight", scope) or not ast_has_marker(
            facts, "rowProxy.size.height", scope
        ):
            errors.append(f"{path.relative_to(ROOT)}: 课表日历按实际更新时间行高度计算剩余空间")

        height_bindings = [
            binding["value"]
            for binding in facts["bindings"]
            if binding["scope"] == scope and binding["value"].startswith("calendarHeight =")
        ]
        if not height_bindings or any("activeSchedule" in binding for binding in height_bindings):
            errors.append(f"{path.relative_to(ROOT)}: 两种课表变体使用同一日历高度计算")

    status_entries = view_entries(syntax, "AppRefreshStatusRow")
    if not status_entries:
        errors.append("AppRefreshStatusRow: 公共更新时间行 View 声明缺失")
    for path, facts, scope in status_entries:
        if any(call["value"].endswith("frame") and call["scope"] == scope for call in facts["calls"]):
            errors.append(f"{path.relative_to(ROOT)}: 公共更新时间行保留列表自然行高")
        for token in ("trailingText: String?", "else if let trailingText"):
            if not ast_has_marker(facts, token, scope):
                errors.append(f"{path.relative_to(ROOT)}: 只读课表顶部行必须复用更新时间行（缺少 {token}）")

    if not any(
        item["value"] == "refreshStatusRowHeight" and "AppDesignSystem" in item["scope"]
        for facts in syntax.values()
        for item in facts["scopedIdentifiers"]
    ):
        errors.append("AppDesignSystem.Schedule: 列表行高派生逻辑归入课表设计系统")

    actions_entries = type_entries(syntax, "CourseScheduleTabView")
    actions_have_current_data = any(
        any(
            call["value"].endswith("encodeLatest") and call["scope"] == scope
            for call in facts["calls"]
        )
        and any(
            member["value"] == "activeSchedule.courses" and member["scope"] == scope
            for member in facts["members"]
        )
        for _, facts, scope in actions_entries
    )
    if not actions_entries or not actions_have_current_data:
        errors.append("CourseScheduleTabView: 分享操作必须使用当前显示课表的数据源")


def main(shared_syntax: dict[str, dict] | None = None) -> int:
    if sys.argv[1:] == ["--self-test"]:
        findings = [
            *ast_marker_boundary_findings(),
            *source_boundary_findings(),
            *map_theme_color_contract_findings(),
        ]
        if findings:
            print("[失败] UI 一致性检查器自测：", file=sys.stderr)
            print("\n".join(findings), file=sys.stderr)
            return 1
        print("[通过] UI 一致性检查器自测")
        return 0

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
    errors.extend(ast_marker_boundary_findings())
    check_component_contracts(errors, syntax)
    check_refresh_status_contract(errors, syntax)
    check_haptic_consistency(errors, syntax)
    check_error_report_coverage(errors, syntax)
    check_accessibility_coverage(errors, syntax)
    check_fonts(errors, syntax)
    check_design_token_boundaries(errors, syntax)
    check_page_theme_consistency(errors, syntax)
    check_contextual_component_colors(errors, syntax)
    check_registered_visual_contracts(errors)
    app_card_uses = 0
    floating_stack_uses = 0
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        relative = path.relative_to(ROOT)
        source_relative = path.relative_to(SOURCE_ROOT).as_posix()
        raw_source = path.read_text(encoding="utf-8")
        facts = syntax[str(path)]
        call_pairs = zip(facts.get("calls", []), facts.get("invocations", []))
        for call, invocation in call_pairs:
            name = call_name(call["value"])
            invocation_source = mask_literals_and_comments(invocation["value"])
            if name == "AppFloatingActionStack":
                floating_stack_uses += 1
            if name == "ZStack" and re.match(
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
                if is_registered_map_theme_color_definition(path, raw_source, node):
                    continue
                pattern_source = mask_literals_and_comments(node["value"])
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

        if source_relative not in PLAIN_LIST_EXCEPTIONS:
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

        app_card_uses += sum(call_name(call["value"]) == "AppCard" for call in facts.get("calls", []))

    if app_card_uses == 0:
        errors.append("未发现 AppCard 调用，公共卡片组件没有实际复用")
    if floating_stack_uses == 0:
        errors.append("未发现 AppFloatingActionStack 调用，右下角操作组没有实际复用")

    # 按 List 表达式检查样式归属，消息页沿用 plain 列表。
    for path in swift_files():
        if path == DESIGN_SYSTEM:
            continue
        if path.relative_to(SOURCE_ROOT).as_posix() in PLAIN_LIST_EXCEPTIONS:
            continue
        facts = syntax[str(path)]
        for control in facts["listControls"]:
            if not list_has_grouped_style(control, facts["listStyleModifiers"]):
                errors.append(f"{path.relative_to(ROOT)}: {'.'.join(control['scope'])} List 必须由自身表达式接入 appGroupedListStyle")

    if errors:
        lines = ["[失败] UI 一致性检查：", *errors]
        report = "\n".join(lines)
        if len(lines) <= 1000:
            REPORT_PATH.unlink(missing_ok=True)
            print(report)
        else:
            REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
            REPORT_PATH.write_text(report + "\n", encoding="utf-8")
            print(f"UI 检查结果共 {len(lines)} 行，详情写入 {REPORT_PATH.relative_to(ROOT)}")
        return 1

    REPORT_PATH.unlink(missing_ok=True)
    print(f"[通过] UI 一致性检查（扫描 {len(swift_files())} 个 Swift 文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
