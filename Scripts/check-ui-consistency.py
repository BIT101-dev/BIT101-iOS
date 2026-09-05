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
DIRECT_STDOUT_LOG = re.compile(r"\b(?:print|debugPrint|NSLog)\s*\(")
DIRECT_SHARED_URLSESSION = re.compile(r"\bURLSession\.shared\b")
DIRECT_ANIMATION_DURATION = re.compile(r"\b(?:withAnimation|animation)\s*\([^\n]*\bduration\s*:")
DIRECT_DATE_FORMATTER = re.compile(
    r"\b(?:DateFormatter|ISO8601DateFormatter|RelativeDateTimeFormatter)\s*\("
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

URLSESSION_EXCEPTIONS = {
    "BIT101-iOS/Shared/Networking/HTTPClient.swift",
    "BIT101-iOS/Shared/Infrastructure/ReleaseNetworkSmoke.swift",
}
PLAIN_LIST_EXCEPTIONS = {"Gallery/GalleryMessagesView.swift"}
STDOUT_EXCEPTIONS = {"Shared/Infrastructure/ReleaseNetworkSmoke.swift"}


@dataclass(frozen=True)
class PageContract:
    """按路径类别或公共组件用法自动发现页面，并统一声明复用要求。"""

    name: str
    requirements: tuple[tuple[str, str], ...]
    path_globs: tuple[str, ...] = ()
    discovery_tokens: tuple[str, ...] = ()


PAGE_CONTRACTS = (
    PageContract(
        name="详情页",
        path_globs=("Course/*DetailView.swift", "Gallery/*DetailView.swift", "Paper/*DetailView.swift"),
        discovery_tokens=("AppDetailShareLink", "AppDetailCircleButton"),
        requirements=(
            ("AppDetailShareLink", "必须使用公共分享入口"),
            ("AppDetailCircleButton", "圆形操作必须使用公共按钮"),
        ),
    ),
    PageContract(
        name="评论区",
        path_globs=("*/*CommentViews.swift",),
        discovery_tokens=("AppCommentThread", "AppCommentSectionHeader", "appCommentSectionStyle"),
        requirements=(
            ("AppDesignSystem.Comment.", "必须使用公共间距令牌"),
            ("appCommentSectionStyle", "必须使用公共容器样式"),
            ("AppCommentThread", "必须使用公共线程结构"),
            ("AppCommentBubble", "必须使用公共气泡结构"),
            ("AppCommentIdentityHeader", "必须使用公共身份标题"),
            ("AppCommentActionBar", "必须使用公共操作行"),
            ("AppAvatarView", "必须使用公共头像"),
            ("AppDateText", "必须使用公共日期文本"),
            ("AppFailureState", "必须使用公共失败状态"),
        ),
    ),
    PageContract(
        name="评论编辑页",
        path_globs=("Course/*CommentViews.swift", "Gallery/*CommentViews.swift", "Paper/*ComposerViews.swift"),
        discovery_tokens=("AppCommentComposerContentSection",),
        requirements=(
            ("AppCommentComposerContentSection", "必须使用公共内容段"),
            ("AppComposerToolbar", "必须使用公共工具栏"),
        ),
    ),
    PageContract(
        name="排序搜索页",
        discovery_tokens=("AppOrderedSearchBar", "AppSearchBarContainer"),
        requirements=(
            ("AppOrderedSearchBar", "必须使用公共搜索栏"),
            ("AppSearchBarContainer", "必须使用公共顶部容器"),
        ),
    ),
    PageContract(
        name="设置导航入口",
        path_globs=("Mine/*RootView.swift", "Settings/*RootView.swift"),
        requirements=(("AppNavigationRowLabel", "必须使用公共图标标题行"),),
    ),
    PageContract(
        name="信息流卡片",
        path_globs=("Gallery/*FeedViews.swift", "Paper/*SummaryViews.swift"),
        discovery_tokens=("appFeedCardStyle",),
        requirements=(("appFeedCardStyle", "必须使用公共 Feed 样式"),),
    ),
    PageContract(
        name="顶部切换页",
        discovery_tokens=("AppTopSegmentedPicker",),
        requirements=((".safeAreaInset(edge: .top, spacing: 0)", "必须使用统一 safeAreaInset 布局"),),
    ),
    # 课表网格属于必要的业务特例，但仍与其他类别共用同一契约机制。
    PageContract(
        name="课表网格",
        path_globs=("Schedule/*CalendarViews.swift",),
        requirements=(
            ("orderedBackgroundLayers", "叠加课程必须按中心位置统一排序"),
            ("isOpaque: entry.kind == .course", "课程背景必须使用不透明底色遮住节次分割线"),
            ("let leftWidth = columnWidth", "周次与叠加视图必须共用等宽列"),
            ("let dayWidth = columnWidth", "周次与叠加视图必须共用等宽列"),
            ("secondaryGroupedBackground", "周次滑块与日期栏必须使用可区分的语义背景色"),
        ),
    ),
    PageContract(
        name="日程根页",
        path_globs=("Schedule/*RootView.swift",),
        requirements=((".safeAreaInset(edge: .bottom, spacing: 0)", "内容必须使用统一的底部安全区间隙"),),
    ),
)


def swift_files() -> list[Path]:
    return sorted(SOURCE_ROOT.rglob("*.swift"))


def contract_files(contract: PageContract) -> list[Path]:
    """以目录类别和已采用的公共组件发现成员；新增同类文件无需修改检查逻辑。"""
    paths = {path for pattern in contract.path_globs for path in SOURCE_ROOT.glob(pattern)}
    if contract.discovery_tokens:
        for path in swift_files():
            if path.parent == DESIGN_SYSTEM.parent:
                continue
            source = path.read_text(encoding="utf-8")
            if any(token in source for token in contract.discovery_tokens):
                paths.add(path)
    return sorted(path for path in paths if path.is_file())


def check_page_contracts(errors: list[str]) -> None:
    for contract in PAGE_CONTRACTS:
        for path in contract_files(contract):
            source = path.read_text(encoding="utf-8")
            for token, message in contract.requirements:
                if token not in source:
                    relative = path.relative_to(SOURCE_ROOT)
                    errors.append(f"{relative}: {contract.name}{message}（缺少 {token}）")


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
            (DIRECT_TOUCH_TARGET, "触控区域尺寸必须使用 AppDesignSystem.Size.control.touchTarget"),
            (DIRECT_FLOATING_MATERIAL, "圆形操作按钮背景必须使用 AppFloatingActionButtonSurface"),
            (DIRECT_GROUPED_LIST_STYLE, "分组列表必须使用 appGroupedListStyle"),
            (DIRECT_LIST_SECTION_SPACING, "列表 section 间距必须通过 appGroupedListStyle 统一"),
            (DIRECT_ANIMATION_DURATION, "优先使用系统动画时长，不要在页面单独指定 duration"),
            (DIRECT_FRAME_LITERAL, "固定 frame 尺寸必须使用 AppDesignSystem.Size 或专用语义令牌"),
            (DIRECT_EDGE_INSETS_LITERAL, "EdgeInsets 必须使用 AppDesignSystem.Spacing"),
            (DIRECT_LOCAL_CGFLOAT_LITERAL, "页面布局常量必须提升为设计系统语义令牌"),
        )
        for pattern, message in rules:
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

        if path != DESIGN_SYSTEM:
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

        if source_relative not in STDOUT_EXCEPTIONS:
            for match in DIRECT_STDOUT_LOG.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: 主 App 不应直接输出日志；调试输出只允许放在网络 smoke 文件")

        if relative.as_posix() not in URLSESSION_EXCEPTIONS:
            for match in DIRECT_SHARED_URLSESSION.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(f"{relative}:{line_number}: 网络请求应通过 HTTPClient 或场景化 Service，不要直接使用 URLSession.shared")

        if source_relative.split("/", 1)[0] in {"Course", "Gallery", "Paper"} and "View" in path.stem:
            for match in DIRECT_DATE_FORMATTER.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                errors.append(
                    f"{relative}:{line_number}: 社区页面日期必须使用 AppDateText，不得重复创建 formatter"
                )

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

    check_page_contracts(errors)

    if errors:
        print("[失败] UI 一致性检查：")
        print("\n".join(errors))
        return 1

    print(f"[通过] UI 一致性检查（扫描 {len(swift_files())} 个 Swift 文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
