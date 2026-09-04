import SwiftUI
import UIKit

/// App 内部 UI 的唯一基础样式来源。
///
/// 业务页面只选择语义化的间距、圆角、颜色和卡片变体；不在页面里重新定义同一套值。
enum AppDesignSystem {
    enum Spacing {
        static let micro: CGFloat = 2
        static let control: CGFloat = 10
        static let content: CGFloat = 12
        static let section: CGFloat = 16
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
        static let floatingActionButton: CGFloat = 42
        static let floatingIcon: CGFloat = 16
        static let detailActionButton: CGFloat = 34
        static let badgeMinimum: CGFloat = 18
        static let badgePadding: CGFloat = 4
        static let wideBadgePadding: CGFloat = 5
        static let badgeOffset: CGFloat = 5
        static let floatingActionBottomInset: CGFloat = 20
    }

    enum Typography {
        static let floatingIcon = Font.system(size: Size.floatingIcon, weight: .semibold)
        static let floatingLabel = Font.system(size: 17, weight: .bold, design: .rounded)
    }

    enum Feed {
        static let cardPadding: CGFloat = 14
        static let dividerLeading: CGFloat = 14
    }

    enum TopBar {
        /// 顶部控件和顶部列表内容共用的可调横向边距。
        static let horizontalPadding: CGFloat = 8
        /// 顶部内容统一贴合安全区下沿；安全区本身负责与灵动岛/状态栏保持距离。
        static let topPadding: CGFloat = 0
        /// 顶部控件与正文、正文与底部系统栏之间共用的内容间隙。
        static let contentGap: CGFloat = 6
        /// 标准顶部控件与第一个列表 Section 的间距，和分组列表 Section 间距一致。
        static let bottomPadding: CGFloat = AppDesignSystem.Spacing.content
        /// 单独承载更新时间 Section 的原生 List 高度。
        static let statusListHeight: CGFloat = 58
        static let stackedTopPadding: CGFloat = 0
        static let stackedBottomPadding: CGFloat = 4
    }

    enum Schedule {
        /// 课表网格线的统一宽度；课程块以此作为与网格线的对称内缩。
        static let gridLineWidth: CGFloat = 0.5
        static let courseCardInset: CGFloat = gridLineWidth
        static let courseBorderWidth: CGFloat = gridLineWidth * 2
        /// 课程块内所有方向共用的文字安全内边距。
        static let courseContentInset: CGFloat = AppDesignSystem.Spacing.micro
        static let courseTitleTextStyle: UIFont.TextStyle = .caption2
        static let courseLocationTextStyle: UIFont.TextStyle = .caption2
        static let courseTitleMaximumLinesForTwoSections = 2
        static let courseTitleMinimumScaleFactor: CGFloat = 0.75
        static let courseLocationLineCount = 2
        static let courseLocationLineHeightMultiple: CGFloat = 0.8
        static let courseLocationMinimumScaleFactor: CGFloat = 0.01
    }

    enum Search {
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 10
        static let controlSpacing: CGFloat = 10
        static let chromeHorizontalPadding: CGFloat = 14
        static let chromeTopPadding: CGFloat = 10
        static let chromeBottomPadding: CGFloat = 8
        static let clearButtonOpacity: CGFloat = 0.35
    }

    enum Tag {
        static let feedHorizontalPadding: CGFloat = 8
        static let feedVerticalPadding: CGFloat = 5
        static let detailHorizontalPadding: CGFloat = 10
        static let detailVerticalPadding: CGFloat = 6
        static let selectionHorizontalPadding: CGFloat = 12
        static let selectionVerticalPadding: CGFloat = 8
        static let interItemSpacing: CGFloat = 8
    }

    enum Detail {
        static let contentPadding: CGFloat = 18
    }

    enum Comment {
        static let sectionSpacing: CGFloat = 14
        static let progressVerticalPadding: CGFloat = 20
        static let emptyVerticalPadding: CGFloat = 16
        static let rowHorizontalPadding: CGFloat = 14
        static let rowVerticalPadding: CGFloat = 14
        static let rowContentSpacing: CGFloat = 10
        static let avatarContentSpacing: CGFloat = 10
        static let bubbleContentSpacing: CGFloat = 6
        static let headerSpacing: CGFloat = 8
        static let actionSpacing: CGFloat = 10
        static let actionTopPadding: CGFloat = 2
        static let avatarSize: CGFloat = 34
        static let subCommentAvatarSize: CGFloat = 28
        static let subCommentTopPadding: CGFloat = 4
        static let subCommentIndent: CGFloat = 42
        static let dividerLeading: CGFloat = 46
    }

    enum Palette {
        static let accent = Color.accentColor
        static let highlight = Color.orange
        static let danger = Color.red
        static let info = Color.blue
        static let success = Color.green
        static let neutral = Color.gray
        static let scheduleTab = Color.indigo
        static let courseTab = Color.teal
        static let mapTab = Color.green
        static let scoreTab = Color.pink
        static let paperTab = Color.brown
        static let scoreMetric = Color.pink
        static let systemBackground = Color(uiColor: .systemBackground)
        static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
        static let secondaryGroupedBackground = Color(uiColor: .secondarySystemGroupedBackground)
        static let secondaryFill = Color(uiColor: .secondarySystemFill)
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
                    width: AppDesignSystem.Size.detailActionButton,
                    height: AppDesignSystem.Size.detailActionButton
                )
                .background(AppDesignSystem.Palette.highlight.opacity(0.12), in: Circle())
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
                            ? AppDesignSystem.Size.wideBadgePadding
                            : AppDesignSystem.Size.badgePadding)
                        .frame(
                            minWidth: AppDesignSystem.Size.badgeMinimum,
                            minHeight: AppDesignSystem.Size.badgeMinimum
                        )
                        .background(AppDesignSystem.Palette.danger, in: Capsule())
                        .offset(x: AppDesignSystem.Size.badgeOffset, y: -AppDesignSystem.Size.badgeOffset)
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
                width: AppDesignSystem.Size.floatingActionButton,
                height: AppDesignSystem.Size.floatingActionButton
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
        .padding(.bottom, AppDesignSystem.Size.floatingActionBottomInset)
    }
}

/// 统一所有分组列表的系统样式、section 间距和横向内容边距。
extension View {
    func appGroupedListStyle() -> some View {
        listStyle(.insetGrouped)
            .listSectionSpacing(AppDesignSystem.Spacing.content)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.horizontal, AppDesignSystem.TopBar.horizontalPadding, for: .scrollContent)
    }

    func appCommentSectionStyle() -> some View {
        background(
            AppDesignSystem.Palette.systemBackground,
            in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.prominent, style: .continuous)
        )
        .overlay {
            AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.prominent, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    func appFeedCardStyle() -> some View {
        padding(AppDesignSystem.Feed.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppDesignSystem.Palette.systemBackground)
            .contentShape(Rectangle())
    }
}
