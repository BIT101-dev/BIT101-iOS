#!/usr/bin/env python3
"""Check that SwiftUI pages use the shared design system instead of local copies."""

from __future__ import annotations

import re
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
    (re.compile(r"\bColor\.pink\b|(?<![\w.])\.pink\b"), "AppDesignSystem.Palette.scoreTab"),
    (re.compile(r"\bColor\.indigo\b|(?<![\w.])\.indigo\b"), "AppDesignSystem.Palette.scheduleTab"),
    (re.compile(r"\bColor\.teal\b|(?<![\w.])\.teal\b"), "AppDesignSystem.Palette.courseTab"),
    (re.compile(r"\bColor\.brown\b|(?<![\w.])\.brown\b"), "AppDesignSystem.Palette.paperTab"),
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
    """按页面角色和公共组件用法自动发现同类 UI 的复用契约。"""

    name: str
    requirements: tuple[tuple[str, str], ...]
    path_globs: tuple[str, ...] = ()
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
        discovery_tokens=("AppDetailShareLink", "AppDetailCircleButton"),
        requirements=(
            ("AppDetailShareLink", "必须使用公共分享入口"),
            ("AppDetailCircleButton", "圆形操作必须使用公共按钮"),
        ),
    ),
    ComponentContract(
        name="评论区",
        path_globs=("**/*CommentViews.swift",),
        requirements=tuple((token, "必须使用评论公共结构") for token in (
            "AppDesignSystem.Comment.", "appCommentSectionStyle",
            "AppCommentThread", "AppCommentBubble", "AppCommentIdentityHeader",
            "AppCommentActionBar", "AppAvatarView", "AppDateText", "AppFailureState",
        )),
    ),
    ComponentContract(
        name="评论编辑页",
        path_globs=("Course/*CommentViews.swift", "Gallery/*CommentViews.swift", "Paper/*ComposerViews.swift"),
        discovery_tokens=("AppCommentComposerContentSection",),
        requirements=(("AppCommentComposerContentSection", "必须使用公共内容段"), ("AppComposerToolbar", "必须使用公共工具栏")),
    ),
    ComponentContract(
        name="排序搜索页",
        path_globs=("**/*SearchView.swift", "**/*SearchViews.swift"),
        discovery_tokens=("AppOrderedSearchBar", "AppSearchBarContainer"),
        requirements=(("AppOrderedSearchBar", "必须使用公共搜索栏"), ("AppSearchBarContainer", "必须使用公共顶部容器")),
    ),
    ComponentContract(
        name="顶部切换页",
        discovery_tokens=("AppTopSegmentedPicker",),
        requirements=(("AppTopSegmentedPicker", "必须使用公共顶部切换控件"), ("AppDesignSystem.Spacing.none", "必须使用统一顶部安全区布局")),
    ),
    ComponentContract(
        name="设置导航入口",
        path_globs=("**/Mine/*RootView.swift", "**/Settings/*RootView.swift"),
        requirements=(("AppNavigationRowLabel", "必须使用公共图标标题行"),),
    ),
    ComponentContract(
        name="资料卡宽屏布局",
        discovery_tokens=("struct MineProfileCard",),
        requirements=((".frame(maxWidth: .infinity, alignment: .center)", "资料卡必须扩展并保持居中"),),
    ),
    ComponentContract(
        name="信息流卡片",
        path_globs=("**/*FeedViews.swift", "**/*SummaryViews.swift"),
        requirements=(("appFeedCardStyle", "必须使用公共 Feed 样式"),),
    ),
    ComponentContract(
        name="首屏状态页",
        path_globs=(
            "**/Course/*RootView.swift", "**/Course/*HistoryGradesViews.swift", "**/Gallery/*MessagesView.swift",
            "**/Mine/*RootView.swift", "**/Score/*RootView.swift", "**/Paper/*RootView.swift", "**/Paper/*SearchViews.swift",
        ),
        any_tokens=("AppLoadingState", "AppInlineLoadingState"),
        requirements=(("AppFailureState", "必须使用公共失败状态"),),
    ),
    ComponentContract(
        name="滚动信息流",
        path_globs=("**/Gallery/*FeedViews.swift", "**/Paper/*RootView.swift", "**/Paper/*SearchViews.swift"),
        requirements=(("AppScrollStateContainer", "必须使用公共滚动状态容器"),),
    ),
    ComponentContract(
        name="比例数据页",
        path_globs=("**/Course/*RootView.swift", "**/Score/*RootView.swift"),
        requirements=(("AppFixedColumnRow", "必须使用公共比例数据行"),),
    ),
    ComponentContract(
        name="验证码页面",
        path_globs=("**/Schedule/*RootView.swift", "**/Score/*RootView.swift", "**/Settings/*ScheduleViews.swift"),
        requirements=(("AppSMSVerificationSheet", "必须使用公共验证码面板"),),
    ),
    ComponentContract(
        name="标签页面",
        path_globs=("**/Gallery/*FeedViews.swift", "**/Gallery/*PosterDetailView.swift", "**/Gallery/*ComposerView.swift"),
        requirements=(("AppTagChip", "必须使用公共标签组件"),),
    ),
    ComponentContract(
        name="课表网格",
        discovery_tokens=("orderedBackgroundLayers",),
        requirements=(
            ("orderedBackgroundLayers", "叠加课程必须按中心位置统一排序"),
            ("entry.kind == .course", "课程背景必须使用不透明底色遮住节次分割线"),
            ("let leftWidth = columnWidth", "周次与叠加视图必须共用等宽列"),
            ("let dayWidth = columnWidth", "周次与叠加视图必须共用等宽列"),
            ("secondaryGroupedBackground", "周次滑块与日期栏必须使用可区分的语义背景色"),
        ),
    ),
    ComponentContract(
        name="日程根页",
        discovery_tokens=("ScheduleSectionTabs",),
        requirements=((".safeAreaInset(edge: .bottom, spacing: 0)", "内容必须使用统一的底部安全区间隙"),),
    ),
)


def swift_files() -> list[Path]:
    return sorted(SOURCE_ROOT.rglob("*.swift"))


def check_component_contracts(errors: list[str]) -> None:
    sources = {path: path.read_text(encoding="utf-8") for path in swift_files()}
    declarations = "\n".join(sources.values())

    # 公共组件清单只声明语义名称；来源文件由源码声明自动发现，不再维护文件名映射。
    for group, symbols in COMPONENT_GROUPS:
        for symbol in symbols:
            if not re.search(rf"\b(?:struct|enum|class|protocol)\s+{re.escape(symbol)}\b", declarations):
                errors.append(f"公共组件组「{group}」缺少 {symbol}")

    for contract in COMPONENT_CONTRACTS:
        members = set()
        for pattern in contract.path_globs:
            members.update(SOURCE_ROOT.glob(pattern))
        for path, source in sources.items():
            if (
                contract.discovery_tokens
                and "View" in path.stem
                and path.parent != DESIGN_SYSTEM.parent
                and any(token in source for token in contract.discovery_tokens)
            ):
                members.add(path)
        for path in sorted(path for path in members if path.is_file()):
            source = sources[path]
            relative = path.relative_to(ROOT)
            if contract.any_tokens and not any(token in source for token in contract.any_tokens):
                errors.append(f"{relative}: {contract.name}缺少首屏状态公共组件")
            for token, message in contract.requirements:
                if token not in source:
                    errors.append(f"{relative}: {contract.name}{message}（缺少 {token}）")

    forbidden_duplicate_wrappers = (
        "GalleryFloatingActionButton",
        "PaperFloatingActionButton",
        "FloatingMapButton",
    )
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        for name in forbidden_duplicate_wrappers:
            if re.search(rf"\b(?:struct|class|enum)\s+{name}\b", source):
                errors.append(f"{str(path.relative_to(ROOT))}: 不得重新包装 {name}，请直接使用公共浮动按钮组件")

    # 首屏文字加载状态必须走公共状态组件；按钮内的无文字进度条仍可保留。
    for path in swift_files():
        if path == ROOT / "BIT101-iOS/Shared/DesignSystem/AppStateComponents.swift":
            continue
        source = path.read_text(encoding="utf-8")
        if re.search(r"\bProgressView\s*\(\s*\"", source):
            errors.append(f"{str(path.relative_to(ROOT))}: 首屏文字加载状态必须使用 AppLoadingState/AppInlineLoadingState")

    # 页面级公共规则：只按语义模式发现，不按业务文件名列白名单。
    for path, source in sources.items():
        if "View" not in path.stem:
            continue
        if re.search(r"\b(List|Form|Section)\b", source) and "ContentUnavailableView" in source:
            if "AppFailureState" not in source and "AppEmptyState" not in source:
                errors.append(f"{path.relative_to(ROOT)}: 页面状态必须使用公共空态/失败态组件")
        if re.search(r"\b(?:Gallery|Paper|Course|Mine|Settings)\b", str(path)) and re.search(r"avatar", source, re.IGNORECASE):
            if "AppAvatarView" not in source and "AppAvatarComponents.swift" not in str(path):
                errors.append(f"{path.relative_to(ROOT)}: 头像页面必须使用 AppAvatarView")

    # 列表/表单内的图标按位置审计：状态、右侧导航和交互控件可保留，
    # 其它左侧图标必须先进入公共组件契约。
    container_pattern = re.compile(r"\b(List|Form|Section)\b")
    icon_pattern = re.compile(
        r"\b(Label\s*\([^\n]*systemImage\s*:|Button\s*\([^\n]*systemImage\s*:|"
        r"NavigationLink\s*\([^\n]*systemImage\s*:|Image\s*\(systemName\s*:)")
    right_pattern = re.compile(r"checkmark|circle|chevron|xmark|minus|star")
    for path, source in sources.items():
        if "Mine" in path.parts:
            continue
        containers = []
        depth = 0
        for line_number, line in enumerate(source.splitlines(), 1):
            code = line.split("//", 1)[0]
            if container_pattern.search(code) and "{" in code:
                containers.append(depth)
            match = icon_pattern.search(code)
            if match and containers and not right_pattern.search(code):
                errors.append(f"{path.relative_to(ROOT)}:{line_number}: 列表/表单左侧图标必须通过公共组件提供")
            depth += code.count("{") - code.count("}")
            while containers and depth <= containers[-1]:
                containers.pop()

    direct_states = [
        f"{path.relative_to(ROOT)}:{index + 1}: {line.strip()}"
        for path, source in sources.items()
        for index, line in enumerate(source.splitlines())
        if "ContentUnavailableView" in line and "AppStateComponents.swift" not in str(path)
        and "Schedule/FreeClassroomViews.swift" not in str(path)
    ]
    errors.extend(f"页面不得直接实现空态/失败态：{item}" for item in direct_states)


def check_haptic_consistency(errors: list[str]) -> None:
    sources = {path: path.read_text(encoding="utf-8") for path in swift_files()}
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

    selection_pattern = re.compile(
        r"\bPicker\s*\(|\bToggle\s*\(|checkmark\.circle\.fill|checkmark\.square\.fill|"
        r"toggleTag\(|selectedTags|setRating\("
    )
    for path, source in sources.items():
        if selection_pattern.search(source) and "appSelectionFeedback" not in source:
            errors.append(f"{path.relative_to(ROOT)}: 选择控件缺少公共触感修饰器")

        lines = source.splitlines()
        for index, line in enumerate(lines):
            if not re.search(r"\b(?:Picker|Toggle)\s*\(", line):
                continue
            end = min(index + 28, len(lines))
            for candidate in range(index + 1, len(lines)):
                if re.search(r"\b(?:Picker|Toggle)\s*\(", lines[candidate]):
                    end = candidate
                    break
            if "appSelectionFeedback" not in "\n".join(lines[index:end]):
                errors.append(f"{path.relative_to(ROOT)}:{index + 1}: 原生选择控件未接入公共触感")

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


def check_error_report_coverage(errors: list[str]) -> None:
    schedule_notice_presenters = 0
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
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

        if not any(word in path.name for word in ("View", "Screen")):
            continue
        lines = source.splitlines()
        for index, line in enumerate(lines):
            if not re.search(r"(?:case|if case|else if case) let \.failed\(message\)", line):
                continue
            window = "\n".join(lines[index:index + 35])
            if "ContentUnavailableView" not in window:
                continue
            if "DiagnosticRecoveryActions" not in window and "PaperEmptyState" not in window:
                errors.append(f"{path.relative_to(ROOT)}:{index + 1}: 失败态缺少错误报告入口")

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
        source = path.read_text(encoding="utf-8")
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


def check_refresh_status_contract(errors: list[str]) -> None:
    status_component_path = DESIGN_SYSTEM.parent / "AppRefreshStatusComponents.swift"
    status_component = status_component_path.read_text(encoding="utf-8")
    refresh_pages = (
        SOURCE_ROOT / "Score/ScoreRootView.swift",
        SOURCE_ROOT / "Schedule/ScheduleDDLViews.swift",
        SOURCE_ROOT / "Schedule/FreeClassroomViews.swift",
    )
    for page_path in refresh_pages:
        page_source = page_path.read_text(encoding="utf-8")
        if "AppRefreshStatusRow(" not in page_source:
            errors.append(f"{page_path.relative_to(ROOT)}: 刷新数据页必须使用 AppRefreshStatusRow")
        if ".appGroupedListStyle()" not in page_source:
            errors.append(f"{page_path.relative_to(ROOT)}: 刷新数据页必须使用统一分组列表样式")

    path = SOURCE_ROOT / "Schedule/CourseScheduleTabView.swift"
    source = path.read_text(encoding="utf-8")
    header_contract = (
        "if activeSchedule.isPrimary",
        "lastUpdatedText: activeSchedule.importedAt.map",
        "导入时间：",
        'trailingText: "只读"',
        "ScheduleRefreshStatusContentHeightKey.self",
        "onPreferenceChange(ScheduleRefreshStatusContentHeightKey.self)",
    )
    missing = [item for item in header_contract if item not in source]
    if missing:
        errors.append(
            f"{path.relative_to(ROOT)}: 我的课表与分享课表必须共用顶部行组件（缺少 {', '.join(missing)}）"
        )

    if ".frame(height:" in status_component or ".frame(minHeight:" in status_component:
        errors.append(f"{status_component_path.relative_to(ROOT)}: 公共更新时间行保留列表自然行高")
    for token in ("let trailingText: String?", "else if let trailingText"):
        if token not in status_component:
            errors.append(f"{status_component_path.relative_to(ROOT)}: 只读课表顶部行必须复用更新时间行（缺少 {token}）")

    header_start = source.find("Section {")
    header_end = source.find("// 学校尚未发布未来学期课表时", header_start)
    header_source = source[header_start:header_end] if header_start >= 0 and header_end >= 0 else ""
    if header_source.count("AppRefreshStatusRow(") != 2:
        errors.append(f"{path.relative_to(ROOT)}: 主课表与分享课表顶部行共用 AppRefreshStatusRow")
    if "refreshStatusContentHeight" not in source or "rowProxy.size.height" not in source:
        errors.append(f"{path.relative_to(ROOT)}: 课表日历按实际更新时间行高度计算剩余空间")
    for custom_style in (
        ".listRowInsets(",
        ".listRowBackground(",
        ".frame(height:",
        ".frame(minHeight:",
    ):
        if custom_style in header_source:
            errors.append(f"{path.relative_to(ROOT)}: 顶部更新时间行沿用公共分组列表样式（发现 {custom_style}）")

    schedule_design_path = SOURCE_ROOT / "Schedule/ScheduleDesignSystem.swift"
    schedule_design = schedule_design_path.read_text(encoding="utf-8")
    if "static func refreshStatusRowHeight(contentHeight:" not in schedule_design:
        errors.append(f"{schedule_design_path.relative_to(ROOT)}: 列表行高派生逻辑归入课表设计系统")

    height_start = source.find("let calendarHeight = max(")
    height_end = source.find("\n            )", height_start)
    height_expression = source[height_start:height_end] if height_start >= 0 and height_end >= 0 else ""
    if not height_expression or "activeSchedule" in height_expression:
        errors.append(f"{path.relative_to(ROOT)}: 两种课表变体使用同一日历高度计算")

    actions_path = SOURCE_ROOT / "Schedule/CourseScheduleTabViewActions.swift"
    actions_source = actions_path.read_text(encoding="utf-8")
    if "encodeLatest(courses: activeSchedule.courses)" not in actions_source:
        errors.append(f"{actions_path.relative_to(ROOT)}: 分享操作必须使用当前显示课表的数据源")


def main() -> int:
    if not DESIGN_SYSTEM.is_file():
        print(f"[失败] 缺少设计系统入口：{DESIGN_SYSTEM.relative_to(ROOT)}", file=sys.stderr)
        return 1

    errors: list[str] = []
    check_component_contracts(errors)
    check_refresh_status_contract(errors)
    check_haptic_consistency(errors)
    check_error_report_coverage(errors)
    check_fonts(errors)
    app_card_uses = 0
    floating_stack_uses = 0
    for path in swift_files():
        if path in DESIGN_SYSTEM_SOURCES:
            continue
        relative = path.relative_to(ROOT)
        source_relative = path.relative_to(SOURCE_ROOT).as_posix()
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
        )
        for pattern, message in rules:
            if path.name == "AppLayoutComponents.swift" and pattern in (
                DIRECT_GROUPED_LIST_STYLE, DIRECT_LIST_SECTION_SPACING, DIRECT_FLOATING_MATERIAL
            ):
                continue
            for match in pattern.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: {message}")
        for pattern, palette_name in DIRECT_SEMANTIC_COLOR_RULES:
            for match in pattern.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: 请使用 {palette_name}")

        for pattern, label in (
            (PADDING_LITERAL, "padding"),
            (STACK_SPACING_LITERAL, "stack spacing"),
        ):
            for match in pattern.finditer(source):
                if float(match.group(1)) == 0:
                    continue
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(
                    f"{relative}:{line_number}: {label} 必须使用 AppDesignSystem.Spacing 或专用语义令牌"
                )

        if path not in DESIGN_SYSTEM_SOURCES:
            for pattern in (DERIVED_DESIGN_TOKEN, REPEATED_DESIGN_TOKEN):
                for match in pattern.finditer(source):
                    line_number = source.count("\n", 0, match.start()) + 1
                    errors.append(
                        f"{relative}:{line_number}: 设计令牌不得通过比例或重复相加/相减二次运算；请直接使用语义令牌"
                    )

        if source_relative not in PLAIN_LIST_EXCEPTIONS:
            for match in DIRECT_PLAIN_LIST_STYLE.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
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
        source = path.read_text(encoding="utf-8")
        if re.search(r"\bList\s*\{", source) and path.relative_to(SOURCE_ROOT).as_posix() not in PLAIN_LIST_EXCEPTIONS:
            list_count = len(re.findall(r"\bList\s*\{", source))
            style_count = source.count("appGroupedListStyle()")
            if style_count < list_count:
                errors.append(
                    f"{path.relative_to(ROOT)}: {list_count} 个分组列表必须逐个使用 appGroupedListStyle（当前 {style_count} 个）"
                )

    if errors:
        print("[失败] UI 一致性检查：")
        print("\n".join(errors))
        return 1

    print(f"[通过] UI 一致性检查（扫描 {len(swift_files())} 个 Swift 文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
