import SwiftUI
import UIKit

/// App 内部 UI 的唯一基础样式来源。
///
/// 业务页面只选择语义化的间距、圆角、颜色和卡片变体；不在页面里重新定义同一套值。
enum AppDesignSystem {
    enum Spacing {
        static let micro: CGFloat = 2
        static let tiny: CGFloat = 4
        static let tight: CGFloat = 6
        static let regular: CGFloat = 8
        static let control: CGFloat = 10
        static let content: CGFloat = 12
        static let container: CGFloat = 14
        static let section: CGFloat = 16
        static let prominent: CGFloat = 18
    }

    enum Radius {
        static let small: CGFloat = 8
        static let badge: CGFloat = 10
        static let card: CGFloat = 12
        static let sheet: CGFloat = 14
        static let grouped: CGFloat = 16
        static let prominent: CGFloat = 18
    }

    enum Size {
        struct FloatingActionMetrics {
            let button: CGFloat
            let icon: CGFloat
            let badgeMinimum: CGFloat
            let wideBadgePadding: CGFloat
            let badgeOffset: CGFloat
            let bottomInset: CGFloat
            let contentInset: CGFloat
        }

        struct ControlMetrics {
            let detailActionButton: CGFloat
            let navigationIcon: CGFloat
            let compact: CGFloat
            let touchTarget: CGFloat
        }

        struct ContentMetrics {
            let multilineEditorMinimumHeight: CGFloat
            let imageDraft: CGFloat
            let chartHeight: CGFloat
            let unreadIndicator: CGFloat
            let messageDividerLeading: CGFloat
            let refreshStatusListHeight: CGFloat
        }

        struct CompactRowMetrics {
            let primaryHeight: CGFloat
            let secondaryHeight: CGFloat
        }

        static let floatingAction = FloatingActionMetrics(
            button: 42,
            icon: 16,
            badgeMinimum: 18,
            wideBadgePadding: 5,
            badgeOffset: 5,
            bottomInset: 20,
            contentInset: 84
        )
        static let control = ControlMetrics(
            detailActionButton: 34,
            navigationIcon: 24,
            compact: 28,
            touchTarget: 44
        )
        static let content = ContentMetrics(
            multilineEditorMinimumHeight: 180,
            imageDraft: 96,
            chartHeight: 240,
            unreadIndicator: 7,
            messageDividerLeading: 52,
            refreshStatusListHeight: 58
        )
        static let compactRow = CompactRowMetrics(primaryHeight: 22, secondaryHeight: 20)
    }

    enum Typography {
        static let floatingIcon = Font.system(size: Size.floatingAction.icon, weight: .semibold)
        static let floatingLabel = Font.system(size: 17, weight: .bold, design: .rounded)
    }

    enum Schedule {
        struct GridMetrics {
            let lineWidth: CGFloat
            let cellSpacing: CGFloat
            let currentTimeLineHeight: CGFloat
            let previewTriggerSize: CGFloat
            let lineOffset: CGFloat
            let courseCardTotalInset: CGFloat
            let courseBorderWidth: CGFloat
        }

        struct WeekSliderMetrics {
            let itemSpacing: CGFloat
            let itemWidth: CGFloat
            let itemHeight: CGFloat
            let labelHeight: CGFloat
            let barHeight: CGFloat
            let minorBarHeight: CGFloat
            let selectedBarWidth: CGFloat
            let barWidth: CGFloat
            let sliderHeight: CGFloat
            let dateHeaderHeight: CGFloat
            let compactHeaderHeight: CGFloat
        }

        struct CourseTextMetrics {
            let style: UIFont.TextStyle
            let titleMaximumLinesForTwoSections: Int
            let titleMinimumScaleFactor: CGFloat
            let locationLineCount: Int
            let locationLineHeightMultiple: CGFloat
            let locationMinimumScaleFactor: CGFloat
        }

        static let grid = GridMetrics(
            lineWidth: 0.5,
            cellSpacing: 1,
            currentTimeLineHeight: 1.5,
            previewTriggerSize: 1,
            lineOffset: 0.25,
            courseCardTotalInset: 1,
            courseBorderWidth: 1
        )
        static let weekSlider = WeekSliderMetrics(
            itemSpacing: 5,
            itemWidth: 24,
            itemHeight: 34,
            labelHeight: 13,
            barHeight: 20,
            minorBarHeight: 16,
            selectedBarWidth: 4,
            barWidth: 3,
            sliderHeight: 36,
            dateHeaderHeight: 26,
            compactHeaderHeight: 42
        )
        static let courseText = CourseTextMetrics(
            style: .caption2,
            titleMaximumLinesForTwoSections: 2,
            titleMinimumScaleFactor: 0.75,
            locationLineCount: 2,
            locationLineHeightMultiple: 0.8,
            locationMinimumScaleFactor: 0.01
        )
        static let settingsPanelMinimumHeight: CGFloat = 220
    }

    enum Comment {
        struct LayoutMetrics {
            let avatarSize: CGFloat
            let subCommentIndent: CGFloat
            let dividerLeading: CGFloat
        }

        static let layout = LayoutMetrics(avatarSize: 34, subCommentIndent: 42, dividerLeading: 46)
    }

    enum Palette {
        static let accent = Color.accentColor
        static let highlight = Color.orange
        static let highlightSurface = Color.orange.opacity(0.12)
        static let danger = Color.red
        static let info = Color.blue
        static let success = Color.green
        static let neutral = Color.gray
        static let scheduleTab = Color.indigo
        static let courseTab = Color.teal
        static let mapTab = Color.green
        static let scoreTab = Color.pink
        static let paperTab = Color.brown
        static let systemBackground = Color(uiColor: .systemBackground)
        static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
        static let secondaryGroupedBackground = Color(uiColor: .secondarySystemGroupedBackground)
        static let secondaryFill = Color(uiColor: .secondarySystemFill)
        static let mediaOverlay = Color.black.opacity(0.45)
    }

    static func roundedRectangle(
        _ radius: CGFloat = Radius.card,
        style: RoundedCornerStyle = .continuous
    ) -> RoundedRectangle {
        return RoundedRectangle(cornerRadius: radius, style: style)
    }
}

/// 公共卡片容器。页面只通过变体表达布局差异，避免复制背景、圆角和内边距。
enum AppCardVariant {
    case standard
    case compact
    case secondaryGrouped

    var background: Color {
        switch self {
        case .standard, .compact:
            return AppDesignSystem.Palette.secondaryBackground
        case .secondaryGrouped:
            return AppDesignSystem.Palette.secondaryGroupedBackground
        }
    }

    var radius: CGFloat {
        switch self {
        case .standard:
            return AppDesignSystem.Radius.grouped
        case .compact:
            return AppDesignSystem.Radius.card
        case .secondaryGrouped:
            return AppDesignSystem.Radius.sheet
        }
    }

    var padding: CGFloat {
        switch self {
        case .standard:
            return AppDesignSystem.Spacing.content
        case .compact:
            return AppDesignSystem.Spacing.control
        case .secondaryGrouped:
            return AppDesignSystem.Spacing.content
        }
    }
}

struct AppCard<Content: View>: View {
    private let variant: AppCardVariant
    private let content: Content

    init(
        variant: AppCardVariant = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.variant = variant
        self.content = content()
    }

    var body: some View {
        content
            .padding(variant.padding)
            .background(
                variant.background,
                in: AppDesignSystem.roundedRectangle(variant.radius)
            )
    }
}

/// 帖子与文章详情页共用的系统分享按钮。
struct AppDetailShareLink: View {
    let item: URL
    let subject: String
    let accessibilityLabel: String

    var body: some View {
        ShareLink(item: item, subject: Text(subject)) {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 帖子、文章和课程详情页共用的圆形评论/点赞按钮。
struct AppDetailCircleButton<Label: View>: View {
    let action: () -> Void
    private let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(
                    width: AppDesignSystem.Size.control.detailActionButton,
                    height: AppDesignSystem.Size.control.detailActionButton
                )
                .background(AppDesignSystem.Palette.highlightSurface, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 右下角圆形操作按钮的公共主体，统一尺寸、背景和图标排布。
struct AppFloatingActionButton: View {
    let systemImage: String
    let badgeText: String?
    let accessibilityLabel: String
    let action: () -> Void
    @State private var feedbackToken = 0

    init(
        systemImage: String,
        badgeText: String? = nil,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.badgeText = badgeText
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button {
            feedbackToken &+= 1
            action()
        } label: {
            ZStack(alignment: .topTrailing) {
                AppFloatingActionButtonLabel(systemImage: systemImage)

                if let badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, badgeText.count > 2
                            ? AppDesignSystem.Size.floatingAction.wideBadgePadding
                            : AppDesignSystem.Spacing.tiny)
                        .frame(
                            minWidth: AppDesignSystem.Size.floatingAction.badgeMinimum,
                            minHeight: AppDesignSystem.Size.floatingAction.badgeMinimum
                        )
                        .background(AppDesignSystem.Palette.danger, in: Capsule())
                        .offset(x: AppDesignSystem.Size.floatingAction.badgeOffset, y: -AppDesignSystem.Size.floatingAction.badgeOffset)
                }
            }
        }
        .buttonStyle(.plain)
        .appImpactFeedback(trigger: feedbackToken)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(badgeText.map { "\($0) 条未读" } ?? "")
    }
}

/// 菜单标签也复用圆形操作按钮主体，避免 `Button` 和 `Menu` 尺寸漂移。
struct AppFloatingActionButtonLabel: View {
    let systemImage: String

    var body: some View {
        AppFloatingActionButtonSurface {
            Image(systemName: systemImage)
                .font(AppDesignSystem.Typography.floatingIcon)
                .foregroundStyle(.primary)
        }
    }
}

/// 圆形按钮的可复用背景容器，支持校区按钮的选中填充色。
struct AppFloatingActionButtonSurface<Content: View>: View {
    private let fill: Color?
    private let content: Content

    init(fill: Color? = nil, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                width: AppDesignSystem.Size.floatingAction.button,
                height: AppDesignSystem.Size.floatingAction.button
            )
            .background(fill ?? .clear, in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
    }
}

/// 右下角操作按钮组，统一按钮间距和安全区内边距。
struct AppFloatingActionStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: AppDesignSystem.Spacing.control) {
            content
        }
        .padding(.trailing, AppDesignSystem.Spacing.control)
        .padding(.bottom, AppDesignSystem.Size.floatingAction.bottomInset)
    }
}

/// 课程详情入口共用的列表行。
///
/// 日程课程详情和成绩详情必须使用同一份标题、图标和系统导航尾部，
/// 业务页面只负责提供相同的导航请求或目的地。
struct AppCourseEvaluationRow: View {
    let isLoading: Bool

    init(isLoading: Bool = false) {
        self.isLoading = isLoading
    }

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Text("查看课程评价")
                .foregroundStyle(.tint)

            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 统一所有分组列表的系统样式、section 间距和横向内容边距。
extension View {
    func appGroupedListStyle() -> some View {
        listStyle(.insetGrouped)
            .listSectionSpacing(AppDesignSystem.Spacing.content)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.horizontal, AppDesignSystem.Spacing.regular, for: .scrollContent)
    }

    func appCommentSectionStyle() -> some View {
        background(
            AppDesignSystem.Palette.systemBackground,
            in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.prominent)
        )
        .overlay {
            AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.prominent)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    func appFeedCardStyle() -> some View {
        padding(AppDesignSystem.Spacing.container)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppDesignSystem.Palette.systemBackground)
            .contentShape(Rectangle())
    }
}
