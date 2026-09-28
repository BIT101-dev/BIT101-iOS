#!/usr/bin/env python3
"""Check that SwiftUI pages use the shared design system instead of local copies."""

from __future__ import annotations

import re
import json
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
    SOURCE_ROOT / "Map/CampusMapScreen.swift",
}
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
        elif source.startswith("//", index):
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

        index += 1
    return "".join(output)


def is_view_source(path: Path, code: str) -> bool:
    if path.name.endswith(("View.swift", "Views.swift", "Screen.swift", "Screens.swift")):
        return True
    return re.search(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b",
        code,
    ) is not None

FIXED_GEOMETRY_REVIEW = (
    (
        "Course/CourseCommentViews.swift",
        "thumbnailButton(image: displayedImages[0]",
        "评论图片的首图、横图和尾图使用不同的构图尺寸，保留业务视觉契约",
    ),
    (
        "Gallery/GalleryComposerView.swift",
        "GridItem(.adaptive(minimum: 64)",
        "自定义标签网格的 64pt 最小列宽暂无公共尺寸可表达",
    ),
    (
        "Course/CourseHistoryGradesViews.swift",
        "StrokeStyle(lineWidth: 2, dash: [5, 4])",
        "历史成绩图表选中线使用独立线型，保留图表可读性",
    ),
    (
        "Settings/SettingsRootView.swift",
        "max(1, width * scale)",
        "图片导出尺寸的 1pt 是 CoreGraphics 防零尺寸保护值",
    ),
    (
        "Schedule/ScheduleLinearCalendarViews.swift",
        "max(proxy.size.height - headerHeight, 1)",
        "时间轴画布的 1pt 是布局防零尺寸保护值",
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
    r"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*Opacity\s*(?::\s*(?:CGFloat|Double))?\s*=\s*(?:0\.[0-9]+|1(?:\.0+)?)"
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
    r"\bthumbnailButton\s*\([^\n]*(?:width|maxHeight|aspectRatio)\s*:\s*[0-9]+(?:\.[0-9]+)?"
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
PAGE_THEME_REVIEW = (
    (
        "Course/CourseHistoryGradesViews.swift",
        '.foregroundStyle(by: .value("指标", point.series))',
        "历史成绩多指标线按数据系列使用多色，保留图表可读性",
    ),
    (
        "Course/CourseHistoryGradesViews.swift",
        "Palette.Status.info",
        "历史成绩人数指标使用状态色，保留数据类别区分",
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
DIRECT_FLOATING_SIZE = re.compile(r"\.frame\(\s*width:\s*42\s*,\s*height:\s*42\s*\)")
DIRECT_TOUCH_TARGET = re.compile(
    r"\.frame\([^)]*(?:minHeight\s*:\s*44|width\s*:\s*44\s*,\s*height\s*:\s*44)"
)
DIRECT_FLOATING_MATERIAL = re.compile(r"\.background\(\s*\.ultraThinMaterial\s*,\s*in:\s*Circle\(\)\s*\)")
DIRECT_GROUPED_LIST_STYLE = re.compile(r"\.listStyle\(\s*\.insetGrouped\s*\)")
DIRECT_PLAIN_LIST_STYLE = re.compile(r"\.listStyle\(\s*\.plain\s*\)")
DIRECT_LIST_SECTION_SPACING = re.compile(r"\.listSectionSpacing\(")
DIRECT_INPUT_PLACEHOLDER = re.compile(
    r"\b(?:TextField|SecureField)\s*\(\s*\"[^\"]+\"\s*,\s*text\s*:"
)
DIRECT_CUSTOM_SECTION_HEADER = re.compile(r"header\s*:\s*\{\s*Text\s*\(")
DIRECT_ANIMATION_DURATION = re.compile(r"\b(?:withAnimation|animation)\s*\([^\n]*\bduration\s*:")
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
    r"\blet\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*CGFloat\s*=\s*"
    r"(?:[1-9][0-9]*(?:\.[0-9]+)?|0\.[0-9]*[1-9][0-9]*)"
)
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
        name="评论区",
        view_names=(
            "CourseCommentsSection", "CourseCommentRow", "CourseCommentImagesView",
            "GalleryPosterCommentsSection", "GalleryCommentRow",
            "PaperCommentsSection", "PaperCommentRow",
        ),
        requirements=tuple((token, "必须使用评论公共结构") for token in (
            "AppDesignSystem.Comment.", "appCommentSectionStyle",
            "AppCommentThread", "AppCommentBubble", "AppCommentIdentityHeader",
            "AppCommentActionBar", "AppAvatarView", "AppDateText", "AppFailureState",
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
        view_names=("ScheduleRootView", "ScheduleSectionTabs"),
        discovery_tokens=("AppTopSegmentedPicker",),
        requirements=(("AppTopSegmentedPicker", "必须使用公共顶部切换控件"), ("AppDesignSystem.Spacing.none", "必须使用统一顶部安全区布局")),
    ),
    ComponentContract(
        name="设置导航入口",
        view_names=("MineRootView", "UserProfileRootView", "SettingsRootView", "SettingsIndexPage", "SettingsIndexCard"),
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
        view_names=("CourseRootView", "CoursePageContent", "CourseListRow", "ScoreRootView", "ScoreListPage", "ScoreListRowCard"),
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
        discovery_tokens=("ScheduleSectionTabs",),
        requirements=((".safeAreaInset(edge: .bottom, spacing: AppDesignSystem.Spacing.none)", "内容必须使用统一的底部安全区间隙"),),
    ),
)


def swift_files() -> list[Path]:
    return sorted(SOURCE_ROOT.rglob("*.swift"))


def syntax_index() -> dict[str, dict]:
    checker = ROOT / "Scripts/check-code-quality.py"
    result = subprocess.run(
        [sys.executable, str(checker), "--swift-syntax-index"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


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


def view_entries(syntax: dict[str, dict], view_name: str) -> list[tuple[Path, dict, list[str]]]:
    return [
        (Path(path), facts, scope)
        for path, facts in syntax.items()
        for scope in view_scopes(facts)
        if scope[-1] == view_name
    ]


def type_entries(syntax: dict[str, dict], type_name: str) -> list[tuple[Path, dict, list[str]]]:
    return [
        (Path(path), facts, declaration["scope"] + [declaration["name"]])
        for path, facts in syntax.items()
        for declaration in facts["declarations"]
        if declaration["name"] == type_name
        and declaration["kind"] in {"struct", "class", "actor", "extension"}
    ]


def view_or_child_has_marker(syntax: dict[str, dict], facts: dict, scope: list[str], marker: str) -> bool:
    if ast_has_marker(facts, marker, scope):
        return True
    child_names = {
        call["value"].split(".")[-1]
        for call in facts["calls"]
        if call["scope"] == scope
    }
    return any(
        ast_has_marker(child_facts, marker, child_scope)
        for child_name in child_names
        for _, child_facts, child_scope in view_entries(syntax, child_name)
    )


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
    delegated_syntax = {"moved/Parent.swift": parent_facts, "shared/Child.swift": child_facts}
    if not view_or_child_has_marker(delegated_syntax, parent_facts, ["ParentView"], "appSelectionFeedback"):
        findings.append("UI 契约规则边界自检失败：直接子 View 的公共触感调用识别")
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
            if not any(
                declaration["name"] == symbol
                for declaration in component_declarations
            ):
                errors.append(f"公共组件组「{group}」缺少 {symbol}")

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
            if contract.any_tokens and not any(
                view_or_child_has_marker(syntax, facts, scope, token)
                for token in contract.any_tokens
                for scope in scopes
            ):
                errors.append(f"{relative}: {contract.name}缺少首屏状态公共组件")
            for token, message in contract.requirements:
                if not any(view_or_child_has_marker(syntax, facts, scope, token) for scope in scopes):
                    errors.append(f"{relative}: {contract.name}{message}（缺少 {token}）")

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

    # 列表/表单内的图标按位置审计：状态、右侧导航和交互控件可保留，
    # 其它左侧图标必须先进入公共组件契约。
    container_pattern = re.compile(r"\b(List|Form|Section)\b")
    icon_pattern = re.compile(
        r"\b(Label\s*\([^\n]*systemImage\s*:|Button\s*\([^\n]*systemImage\s*:|"
        r"NavigationLink\s*\([^\n]*systemImage\s*:|Image\s*\(systemName\s*:)")
    right_pattern = re.compile(r"checkmark|circle|chevron|xmark|minus|star")
    for path, source in code_sources.items():
        if "Mine" in path.parts:
            continue
        containers = []
        depth = 0
        literal_source = comment_free_sources[path]
        for line_number, (line, literal_line) in enumerate(
            zip(source.splitlines(), literal_source.splitlines()), 1
        ):
            code = line
            if container_pattern.search(code) and "{" in code:
                containers.append(depth)
            match = icon_pattern.search(literal_line)
            if match and containers and not right_pattern.search(literal_line):
                errors.append(f"{path.relative_to(ROOT)}:{line_number}: 列表/表单左侧图标必须通过公共组件提供")
            depth += code.count("{") - code.count("}")
            while containers and depth <= containers[-1]:
                containers.pop()

    direct_states = [
        str(path.relative_to(ROOT))
        for path in swift_files()
        if "ContentUnavailableView" in syntax[str(path)]["identifiers"]
        and "AppStateComponents.swift" not in str(path)
        and "Schedule/FreeClassroomViews.swift" not in str(path)
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


def _swift_block(source: str, start: int) -> str:
    opening = source.find("{", start)
    if opening < 0:
        return ""
    depth = 1
    end = opening + 1
    while end < len(source) and depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def check_error_report_coverage(errors: list[str], syntax: dict[str, dict]) -> None:
    schedule_notice_presenters = 0
    for path in swift_files():
        source = mask_literals_and_comments(path.read_text(encoding="utf-8"))
        schedule_notice_presenters += len(re.findall(r"\.scheduleViewModel\.\$notice\.compactMap", source))
        if path.name != "ErrorReportSupport.swift":
            position = 0
            while (start := source.find(".alert(item:", position)) >= 0:
                binding_match = re.search(r"\.alert\(item:\s*\$(\w+)", source[start:])
                binding = binding_match.group(1) if binding_match else ""
                block = _swift_block(source, start)
                approved_local_alert = binding == "expectedAlert" or (
                    binding == "alert" and "$diagnosticAlert" in source
                )
                if not approved_local_alert and binding != "diagnosticAlert" and ".title" in block and ".message" in block and "primaryButton" not in block:
                    errors.append(
                        f"{path.relative_to(ROOT)}:{source.count(chr(10), 0, start) + 1}: AppAlert 必须使用 diagnosticAlert"
                    )
                position = start + max(len(block), 1)

        facts = syntax[str(path)]
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


def check_fonts(errors: list[str]) -> None:
    swift_explicit_font_size = re.compile(
        r"(?:\bFont\.system|\.system)\s*\(\s*size\s*:\s*(?P<value>[^,\)\n]+)"
    )
    ui_explicit_font_size = re.compile(
        r"\bUIFont\.systemFont\s*\(\s*ofSize\s*:\s*(?P<value>[^,\)\n]+)"
    )
    custom_font = re.compile(r"\bFont\.custom\s*\(")

    roots = (SOURCE_ROOT, ROOT / "BIT101ScheduleWidgets", ROOT / "BIT101Watch", ROOT / "BIT101WatchWidgets", ROOT / "BIT101-iOSTests")
    for path in sorted(path for root in roots for path in root.rglob("*.swift")):
        source = mask_literals_and_comments(path.read_text(encoding="utf-8"))
        relative = path.relative_to(ROOT)
        if path not in DESIGN_SYSTEM_SOURCES:
            for match in swift_explicit_font_size.finditer(source):
                value = match.group("value").strip()
                if "AppDesignSystem." not in value:
                    errors.append(
                        f"{relative}:{source.count(chr(10), 0, match.start()) + 1}: "
                        f"字体字号必须使用设计系统令牌或系统语义字体：{value}"
                    )
            for match in ui_explicit_font_size.finditer(source):
                value = match.group("value").strip()
                if "AppDesignSystem." not in value:
                    errors.append(
                        f"{relative}:{source.count(chr(10), 0, match.start()) + 1}: "
                        f"UIFont 字号必须使用设计系统令牌或系统语义字体：{value}"
                    )
            for match in custom_font.finditer(source):
                errors.append(f"{relative}: 字体采用系统语义或公共令牌")


def check_design_token_boundaries(errors: list[str]) -> None:
    """透明度数字只允许存在于跨 target 基础刻度层。"""
    for path in swift_files():
        if path == PRIMITIVE_OPACITY_SOURCE:
            continue
        source = mask_literals_and_comments(path.read_text(encoding="utf-8"))
        relative = path.relative_to(ROOT)
        for pattern, message in (
            (DIRECT_OPACITY_LITERAL, "透明度数字必须通过 AppDesignSystem.Opacity 派生"),
            (DIRECT_OPACITY_ASSIGNMENT, "透明度标量必须引用 AppDesignSystem.Opacity"),
        ):
            for match in pattern.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: {message}")


def check_page_theme_consistency(errors: list[str]) -> None:
    """页面强调色必须使用所属模块的主题令牌。"""
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        source_relative = path.relative_to(SOURCE_ROOT).as_posix()
        source = mask_literals_and_comments(path.read_text(encoding="utf-8"))
        for prefixes, forbidden_tokens, expected_token in PAGE_THEME_RULES:
            if not source_relative.startswith(prefixes):
                continue
            for token in forbidden_tokens:
                start = 0
                while True:
                    index = source.find(token, start)
                    if index < 0:
                        break
                    line_number = source.count("\n", 0, index) + 1
                    errors.append(
                        f"{path.relative_to(ROOT)}:{line_number}: 页面主题色应使用 {expected_token}，当前发现 {token}"
                    )
                    start = index + len(token)


def check_contextual_component_colors(errors: list[str]) -> None:
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
        source = mask_literals_and_comments(raw_source)
        for token, expected_token in CONTEXTUAL_COLOR_BYPASSES:
            start = 0
            while True:
                index = source.find(token, start)
                if index < 0:
                    break
                line_number = raw_source.count("\n", 0, index) + 1
                errors.append(
                    f"{path.relative_to(ROOT)}:{line_number}: "
                    f"复用组件的页面主题色应使用 {expected_token}，当前发现 {token}"
                )
                start = index + len(token)


def collect_fixed_geometry_review_notes() -> list[str]:
    notes: list[str] = []
    for relative_path, marker, message in FIXED_GEOMETRY_REVIEW:
        path = SOURCE_ROOT / relative_path
        if not path.is_file():
            continue
        source = path.read_text(encoding="utf-8")
        if marker in source:
            notes.append(f"{path.relative_to(ROOT)}: {message}")
    return notes


def collect_page_theme_review_notes() -> list[str]:
    notes: list[str] = []
    for relative_path, marker, message in PAGE_THEME_REVIEW:
        path = SOURCE_ROOT / relative_path
        if path.is_file() and marker in path.read_text(encoding="utf-8"):
            notes.append(f"{path.relative_to(ROOT)}: {message}")
    return notes


def is_reviewed_fixed_geometry(path: Path, source: str, pattern: re.Pattern[str]) -> bool:
    relative_path = path.relative_to(SOURCE_ROOT).as_posix()
    reviewed_paths = {
        "Course/CourseCommentViews.swift": DIRECT_THUMBNAIL_GEOMETRY,
        "Course/CourseHistoryGradesViews.swift": DIRECT_STROKE_GEOMETRY,
        "Gallery/GalleryComposerView.swift": DIRECT_GRID_ITEM_GEOMETRY,
    }
    expected_pattern = reviewed_paths.get(relative_path)
    return expected_pattern is pattern and any(
        entry_path == relative_path and marker in source
        for entry_path, marker, _ in FIXED_GEOMETRY_REVIEW
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


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        findings = ast_marker_boundary_findings()
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
    try:
        syntax = syntax_index()
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"[失败] SwiftSyntax 索引：{error}", file=sys.stderr)
        return 1
    errors.extend(ast_marker_boundary_findings())
    check_component_contracts(errors, syntax)
    check_refresh_status_contract(errors, syntax)
    check_haptic_consistency(errors, syntax)
    check_error_report_coverage(errors, syntax)
    check_fonts(errors)
    check_design_token_boundaries(errors)
    check_page_theme_consistency(errors)
    check_contextual_component_colors(errors)
    app_card_uses = 0
    floating_stack_uses = 0
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        relative = path.relative_to(ROOT)
        source_relative = path.relative_to(SOURCE_ROOT).as_posix()
        raw_source = path.read_text(encoding="utf-8")
        source = mask_literals_and_comments(raw_source)
        comment_free_source = mask_comments(raw_source)
        if "AppFloatingActionStack" in source:
            floating_stack_uses += 1
        if "ZStack(alignment: .bottomTrailing)" in source and re.search(r"Floating|FAB", source):
            if "AppFloatingActionStack" not in source:
                errors.append(f"{relative}: 右下角操作组必须使用 AppFloatingActionStack")
        rules = (
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
        for pattern, message in rules:
            if path.name == "AppLayoutComponents.swift" and pattern in (
                DIRECT_GROUPED_LIST_STYLE, DIRECT_LIST_SECTION_SPACING, DIRECT_FLOATING_MATERIAL
            ):
                continue
            pattern_source = comment_free_source if pattern is DIRECT_INPUT_PLACEHOLDER else source
            for match in pattern.finditer(pattern_source):
                if pattern in (
                    DIRECT_GRID_ITEM_GEOMETRY,
                    DIRECT_STROKE_GEOMETRY,
                    DIRECT_THUMBNAIL_GEOMETRY,
                ) and is_reviewed_fixed_geometry(path, source, pattern):
                    continue
                line_number = raw_source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: {message}")
        for pattern, palette_name in DIRECT_SEMANTIC_COLOR_RULES:
            for match in pattern.finditer(source):
                line_number = raw_source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: 请使用 {palette_name}")

        for pattern, label in (
            (PADDING_LITERAL, "padding"),
            (STACK_SPACING_LITERAL, "stack spacing"),
        ):
            for match in pattern.finditer(source):
                if float(match.group(1)) == 0:
                    continue
                line_number = raw_source.count("\n", 0, match.start()) + 1
                errors.append(
                    f"{relative}:{line_number}: {label} 必须使用 AppDesignSystem.Spacing 或专用语义令牌"
                )

        if path not in DESIGN_SYSTEM_SOURCES:
            for pattern in (DERIVED_DESIGN_TOKEN, REPEATED_DESIGN_TOKEN):
                for match in pattern.finditer(source):
                    line_number = raw_source.count("\n", 0, match.start()) + 1
                    errors.append(
                        f"{relative}:{line_number}: 设计令牌不得通过比例或重复相加/相减二次运算；请直接使用语义令牌"
                    )

        if source_relative not in PLAIN_LIST_EXCEPTIONS:
            for match in DIRECT_PLAIN_LIST_STYLE.finditer(source):
                line_number = raw_source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: plain 列表只允许消息中心使用")

        app_card_uses += len(re.findall(r"\bAppCard\s*(?:<[^>]+>)?\s*(?:\(|\{)", source))

    if app_card_uses == 0:
        errors.append("未发现 AppCard 调用，公共卡片组件没有实际复用")
    if floating_stack_uses == 0:
        errors.append("未发现 AppFloatingActionStack 调用，右下角操作组没有实际复用")

    # 所有分组内容列表统一使用同一修饰器；消息页是刻意保留的 plain 列表例外。
    for path in swift_files():
        if path == DESIGN_SYSTEM:
            continue
        source = mask_literals_and_comments(path.read_text(encoding="utf-8"))
        if re.search(r"\bList\s*\{", source) and path.relative_to(SOURCE_ROOT).as_posix() not in PLAIN_LIST_EXCEPTIONS:
            list_count = len(re.findall(r"\bList\s*\{", source))
            style_count = source.count("appGroupedListStyle()")
            if style_count < list_count:
                errors.append(
                    f"{path.relative_to(ROOT)}: {list_count} 个分组列表必须逐个使用 appGroupedListStyle（当前 {style_count} 个）"
                )

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
