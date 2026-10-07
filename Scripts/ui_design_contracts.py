"""Shared design tokens and semantic rule definitions."""
import re

FIXED_GEOMETRY_CONTRACTS = (
    (
        "Modules/CourseFeature/Sources/CourseCommentViews.swift",
        "thumbnailButton(image: displayedImages[0], index: 0, width: 180",
    ),
    (
        "Modules/CourseFeature/Sources/CourseCommentViews.swift",
        "thumbnailButton(image: image, index: index, width: nil, maxHeight: 150",
    ),
    (
        "Modules/CourseFeature/Sources/CourseCommentViews.swift",
        "thumbnailButton(image: image, index: index, width: nil, maxHeight: 78",
    ),
    (
        "Modules/GalleryFeature/Sources/GalleryComposerView.swift",
        "GridItem(.adaptive(minimum: 64)",
    ),
    (
        "Modules/CourseFeature/Sources/CourseHistoryGradesViews.swift",
        "StrokeStyle(lineWidth: 2, dash: [5, 4])",
    ),
    (
        "Modules/CommunityUI/Sources/CommunityDesignSystem.swift",
        "width: max(1, width * scale)",
    ),
    (
        "Modules/ScheduleFeature/Sources/ScheduleLinearCalendarViews.swift",
        "max(proxy.size.height - headerHeight, 1)",
    ),
    (
        "Modules/ScheduleFeature/Sources/ScheduleCourseCardViews.swift",
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
        ("Modules/CourseFeature/Sources/", "Modules/ScoreFeature/Sources/"),
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
        "Modules/CourseFeature/Sources/CourseHistoryGradesViews.swift",
        '.foregroundStyle(by: .value("指标", point.series))',
    ),
)


THEME_SENSITIVE_ROOTS = (
    "Modules/DesignSystemKit/Sources",
    "Modules/GalleryFeature/Sources",
    "Modules/PaperFeature/Sources",
    "Modules/MineFeature/Sources",
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


PLAIN_LIST_EXCEPTIONS = {"Modules/GalleryFeature/Sources/GalleryMessagesView.swift"}


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
    ("CourseEvaluationScene", "expectedAlert"),
}
