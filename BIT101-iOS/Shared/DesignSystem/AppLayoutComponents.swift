import SwiftUI

/// 公共卡片容器。页面通过变体表达布局差异，背景、圆角和内边距由组件统一处理。
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
        case .compact, .secondaryGrouped:
            return AppDesignSystem.Radius.card
        }
    }

    var padding: CGFloat {
        switch self {
        case .standard:
            return AppDesignSystem.Spacing.content
        case .compact:
            return AppDesignSystem.Spacing.regular
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

/// 课程、帖子和文章详情页共用的系统分享按钮。
struct AppDetailShareLink: View {
    let item: URL
    let subject: String
    let accessibilityLabel: String

    var body: some View {
        ShareLink(item: item, subject: Text(subject)) {
            Image(systemName: "square.and.arrow.up")
                .frame(
                    width: AppDesignSystem.Size.Control.touchTarget,
                    height: AppDesignSystem.Size.Control.touchTarget
                )
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 帖子、文章和课程详情页共用的圆形评论/点赞按钮。
struct AppDetailCircleButton<Label: View>: View {
    let action: () -> Void
    let accessibilityLabel: String
    private let label: Label

    init(
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(
                    width: AppDesignSystem.Size.Control.detailActionButton,
                    height: AppDesignSystem.Size.Control.detailActionButton
                )
                .background(AppDesignSystem.Palette.highlightSurface, in: Circle())
                .frame(
                    width: AppDesignSystem.Size.Control.touchTarget,
                    height: AppDesignSystem.Size.Control.touchTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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
                        .font(AppDesignSystem.Typography.caption2Emphasis)
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppDesignSystem.Spacing.tiny)
                        .frame(
                            minWidth: AppDesignSystem.Size.FloatingAction.badgeMinimum,
                            minHeight: AppDesignSystem.Size.FloatingAction.badgeMinimum
                        )
                        .background(AppDesignSystem.Palette.danger, in: Capsule())
                        .offset(x: AppDesignSystem.Spacing.tiny, y: -AppDesignSystem.Spacing.tiny)
                }
            }
        }
        .buttonStyle(.plain)
        .appImpactFeedback(trigger: feedbackToken)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(badgeText.map { "\($0) 条未读" } ?? "")
    }
}

/// 菜单标签复用圆形操作按钮主体，`Button` 和 `Menu` 保持相同的尺寸。
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
                width: AppDesignSystem.Size.Control.touchTarget,
                height: AppDesignSystem.Size.Control.touchTarget
            )
            .background(fill ?? .clear, in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .frame(
                width: AppDesignSystem.Size.Control.touchTarget,
                height: AppDesignSystem.Size.Control.touchTarget
            )
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
        VStack(alignment: .trailing, spacing: AppDesignSystem.Spacing.regular) {
            content
        }
        .padding(.trailing, AppDesignSystem.Spacing.regular)
        .padding(.bottom, AppDesignSystem.Size.FloatingAction.bottomInset)
    }
}

/// 课程详情入口共用的列表行。
///
/// 日程和成绩详情共用标题与加载态；导航行为由外层容器负责。
struct AppCourseEvaluationRow: View {
    let isLoading: Bool

    init(isLoading: Bool = false) {
        self.isLoading = isLoading
    }

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
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
            .listRowInsets(EdgeInsets(
                top: AppDesignSystem.Spacing.tiny,
                leading: AppDesignSystem.Spacing.content,
                bottom: AppDesignSystem.Spacing.tiny,
                trailing: AppDesignSystem.Spacing.content
            ))
    }

    func appCommentSectionStyle() -> some View {
        background(
            AppDesignSystem.Palette.systemBackground,
            in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped)
        )
        .overlay {
            AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped)
                .stroke(AppDesignSystem.Palette.subtleBorder, lineWidth: 1)
        }
    }

    func appFeedCardStyle() -> some View {
        padding(AppDesignSystem.Spacing.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppDesignSystem.Palette.systemBackground)
            .contentShape(Rectangle())
    }
}
