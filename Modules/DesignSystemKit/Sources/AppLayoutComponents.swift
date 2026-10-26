#if os(iOS)
import SwiftUI
import UIKit

public struct AppWindowLayout: Equatable {
    public var size: CGSize = .zero
    public var isRegularWidth = false
    public var usesAccessibilityText = false
    public var availableWidth: CGFloat?
    public init(size: CGSize = .zero, isRegularWidth: Bool = false, usesAccessibilityText: Bool = false, availableWidth: CGFloat? = nil) {
        self.size = size; self.isRegularWidth = isRegularWidth; self.usesAccessibilityText = usesAccessibilityText
        self.availableWidth = availableWidth
    }
    public var isLandscape: Bool {
        isRegularWidth && size.width > size.height && !usesAccessibilityText
            && (availableWidth ?? size.width) >= AppDesignSystem.Size.Layout.landscapeColumnsMinimumWidth
    }
    public var gridColumns: [GridItem] { Array(repeating: GridItem(.flexible()), count: isLandscape ? 2 : 1) }
    public var singleColumn: AppWindowLayout {
        var value = self; value.isRegularWidth = false
        return value
    }
    public var usesExpandedNavigation: Bool { isLandscape && size.width >= AppDesignSystem.Size.Layout.expandedNavigationMinimumWidth }
}

private struct AppWindowLayoutKey: EnvironmentKey {
    static var defaultValue: AppWindowLayout { AppWindowLayout() }
}

extension EnvironmentValues {
    @Entry public var appExpandedNavigation = false
    @Entry public var appPageIsVisible = true
    public var appWindowLayout: AppWindowLayout {
        get { self[AppWindowLayoutKey.self] }
        set { self[AppWindowLayoutKey.self] = newValue }
    }
}

public struct AppPairedPages<First: View, Second: View>: View {
    @Environment(\.appWindowLayout) private var layout
    private let showsFirst: Bool
    private let first: First
    private let second: Second
    @State private var hasShownFirst: Bool
    @State private var hasShownSecond: Bool
    public init(showsFirst: Bool, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.showsFirst = showsFirst; self.first = first(); self.second = second()
        _hasShownFirst = State(initialValue: showsFirst); _hasShownSecond = State(initialValue: !showsFirst)
    }
    public var body: some View {
        let firstVisible = layout.isLandscape || showsFirst
        let secondVisible = layout.isLandscape || !showsFirst
        HStack(spacing: AppDesignSystem.Spacing.none) {
            if hasShownFirst || firstVisible { pane(first, visible: firstVisible) }
            if layout.isLandscape { Divider() }
            if hasShownSecond || secondVisible { pane(second, visible: secondVisible) }
        }
        .onChange(of: firstVisible, initial: true) { _, visible in if visible { hasShownFirst = true } }
        .onChange(of: secondVisible, initial: true) { _, visible in if visible { hasShownSecond = true } }
    }
    private func pane(_ content: some View, visible: Bool) -> some View {
        content.environment(\.appWindowLayout, layout.singleColumn)
            .environment(\.appPageIsVisible, visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: visible ? nil : 0)
            .clipped().allowsHitTesting(visible).accessibilityHidden(!visible)
    }
}

public struct AppBrowserLayout<Selection: Hashable, Master: View, Detail: View>: View {
    @Environment(\.appWindowLayout) private var layout
    @Binding private var selection: Selection?
    private let title: String
    private let symbol: String
    private let master: Master
    private let detail: (Selection) -> Detail
    public init(selection: Binding<Selection?>, title: String, symbol: String,
                @ViewBuilder master: () -> Master, @ViewBuilder detail: @escaping (Selection) -> Detail) {
        _selection = selection; self.title = title; self.symbol = symbol
        self.master = master(); self.detail = detail
    }
    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all), preferredCompactColumn: Binding(
            get: { selection == nil ? .sidebar : .detail },
            set: { if $0 == .sidebar { selection = nil } }
        )) {
            NavigationStack {
                master.environment(\.appWindowLayout, layout.singleColumn)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .navigationSplitViewColumnWidth(min: AppDesignSystem.Size.Layout.sidebarWidth,
                ideal: AppDesignSystem.Size.Layout.sidebarWidth, max: AppDesignSystem.Size.Layout.sidebarWidth)
            .accessibilityElement(children: .contain).accessibilityIdentifier("browser.master")
        } detail: {
            NavigationStack {
                Group {
                    if let selection { detail(selection) }
                    else { AppEmptyState(title: title, systemImage: symbol, message: "从左侧列表选择内容") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesignSystem.Palette.Background.grouped)
                .toolbar(.visible, for: .navigationBar)
            }
            .toolbar(removing: .sidebarToggle)
            .accessibilityElement(children: .contain).accessibilityIdentifier("browser.detail")
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.horizontalSizeClass, layout.isLandscape ? .regular : .compact)
        .background(AppDesignSystem.Palette.Background.grouped)
    }
}

private struct AppWindowLayoutModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var size = CGSize.zero
    @State private var availableWidth: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .background(AppWindowSizeReader(onChange: { size = $0; availableWidth = $1 }))
            .environment(\.appWindowLayout, AppWindowLayout(size: size,
                isRegularWidth: horizontalSizeClass == .regular, usesAccessibilityText: dynamicTypeSize.isAccessibilitySize,
                availableWidth: availableWidth))
    }
}

private struct AppWindowSizeReader: UIViewRepresentable {
    let onChange: (CGSize, CGFloat) -> Void
    func makeUIView(context: Context) -> ProbeView { ProbeView(onChange: onChange) }
    func updateUIView(_ view: ProbeView, context: Context) { view.onChange = onChange; view.measure() }
    final class ProbeView: UIView {
        var onChange: (CGSize, CGFloat) -> Void
        private var lastSize = CGSize.zero
        private var lastWidth: CGFloat = 0
        init(onChange: @escaping (CGSize, CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { return nil }
        override func didMoveToWindow() { super.didMoveToWindow(); measure() }
        override func layoutSubviews() { super.layoutSubviews(); measure() }
        func measure() {
            guard let size = window?.bounds.size, bounds.width > 0 else { return }
            let width = bounds.width
            guard size != lastSize || width != lastWidth else { return }
            lastSize = size; lastWidth = width
            Task { @MainActor [weak self] in
                guard let self, lastSize == size, lastWidth == width else { return }
                onChange(size, width)
            }
        }
    }
}

extension View {
    public func appWindowLayout() -> some View { modifier(AppWindowLayoutModifier()) }
    public func appReadableContent() -> some View { modifier(AppReadableContentModifier()) }
    @ViewBuilder public func appScrollEdgeEffectHidden(_ hidden: Bool) -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectHidden(hidden, for: .top) }
        else { self }
    }
}

private struct AppReadableContentModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: AppDesignSystem.Size.Layout.readingWidth)
            .frame(maxWidth: .infinity)
    }
}

public struct AppSidebarLayout<Sidebar: View, Content: View>: View {
    @Environment(\.appWindowLayout) private var layout
    private let sidebar: Sidebar
    private let content: (Bool) -> Content
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.sidebar = sidebar(); self.content = content
    }
    public var body: some View {
        GeometryReader { geometry in
            let usesSidebar = layout.isLandscape && geometry.size.width >= AppDesignSystem.Size.Layout.landscapeColumnsMinimumWidth
            HStack(spacing: AppDesignSystem.Spacing.none) {
                if usesSidebar {
                    sidebar.frame(width: AppDesignSystem.Size.Layout.sidebarWidth)
                    Divider()
                }
                content(usesSidebar).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// 公共卡片容器。页面通过变体表达布局差异，背景、圆角和内边距由组件统一处理。
public enum AppCardVariant {
    case standard
    case compact
    case secondaryGrouped

    var background: Color {
        switch self {
        case .standard, .compact:
            return AppDesignSystem.Palette.Background.secondary
        case .secondaryGrouped:
            return AppDesignSystem.Palette.Background.secondaryGrouped
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

public struct AppCard<Content: View>: View {
    private let variant: AppCardVariant
    private let content: Content

    public init(
        variant: AppCardVariant = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.variant = variant
        self.content = content()
    }

    public var body: some View {
        content
            .padding(variant.padding)
            .background(
                variant.background,
                in: AppDesignSystem.roundedRectangle(variant.radius)
            )
    }
}

/// 课程、帖子和文章详情页共用的系统分享按钮。
public struct AppDetailShareLink: View {
    public init(item: URL, subject: String, accessibilityLabel: String) {
        self.item = item
        self.subject = subject
        self.accessibilityLabel = accessibilityLabel
    }

    let item: URL
    let subject: String
    let accessibilityLabel: String

    public var body: some View {
        ShareLink(item: item, subject: Text(subject)) {
            Label(accessibilityLabel, systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("detail.share")
    }
}

/// 帖子、文章和课程详情页共用的圆形评论/点赞按钮。
public struct AppDetailCircleButton<Label: View>: View {
    let action: () -> Void
    let accessibilityLabel: String
    private let label: Label

    public init(
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label
                .frame(
                    width: AppDesignSystem.Size.Control.detailActionButton,
                    height: AppDesignSystem.Size.Control.detailActionButton
                )
                .background(AppDesignSystem.Palette.Accent.surface, in: Circle())
                .frame(
                    width: AppDesignSystem.Size.Control.touchTarget,
                    height: AppDesignSystem.Size.Control.touchTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("ui.app-detail-circle-button.action")
    }
}

/// 右下角圆形操作按钮的公共主体，统一尺寸、背景和图标排布。
public struct AppFloatingActionButton: View {
    let systemImage: String
    let badgeText: String?
    let accessibilityLabel: String
    let action: () -> Void
    @State private var feedbackToken = 0

    public init(
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

    public var body: some View {
        Button {
            feedbackToken &+= 1
            action()
        } label: {
            ZStack(alignment: .topTrailing) {
                AppFloatingActionButtonLabel(systemImage: systemImage)

                if let badgeText {
                    Text(badgeText)
                        .font(AppDesignSystem.Typography.captionEmphasis)
                        .foregroundStyle(AppDesignSystem.Palette.Highlight.foreground)
                        .padding(.horizontal, AppDesignSystem.Spacing.tiny)
                        .frame(
                            minWidth: AppDesignSystem.Size.FloatingAction.badgeMinimum,
                            minHeight: AppDesignSystem.Size.FloatingAction.badgeMinimum
                        )
                        .background(AppDesignSystem.Palette.Status.danger, in: Capsule())
                        .offset(x: AppDesignSystem.Spacing.tiny, y: -AppDesignSystem.Spacing.tiny)
                }
            }
        }
        .buttonStyle(.plain)
        .appImpactFeedback(trigger: feedbackToken)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(badgeText.map { "\($0) 条未读" } ?? "")
            .accessibilityIdentifier("ui.app-floating-action-button.action")
    }
}

/// 菜单标签复用圆形操作按钮主体，`Button` 和 `Menu` 保持相同的尺寸。
public struct AppFloatingActionButtonLabel: View {
    public init(systemImage: String) {
        self.systemImage = systemImage
    }

    let systemImage: String

    public var body: some View {
        AppFloatingActionButtonSurface {
            Image(systemName: systemImage)
                .font(AppDesignSystem.Typography.bodyEmphasis)
                .foregroundStyle(AppDesignSystem.Foreground.primary)
        }
    }
}

/// 圆形按钮的可复用背景容器，支持校区按钮的选中填充色。
public struct AppFloatingActionButtonSurface<Content: View>: View {
    private let fill: Color?
    private let content: Content

    public init(fill: Color? = nil, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.content = content()
    }

    public var body: some View {
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
public struct AppFloatingActionStack<Content: View>: View {
    private let axis: Axis
    private let content: Content

    public init(axis: Axis = .vertical, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.content = content()
    }

    public var body: some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: AppDesignSystem.Spacing.regular))
            : AnyLayout(VStackLayout(alignment: .trailing, spacing: AppDesignSystem.Spacing.regular))
        layout {
            content
        }
        .padding(.trailing, AppDesignSystem.Spacing.regular)
        .padding(.bottom, AppDesignSystem.Size.Layout.floatingActionBottomInset)
    }
}

extension View {
    public func appBrowserActions<Actions: View>(expanded: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        let buttons = actions()
        return self
            .safeAreaInset(edge: .bottom, spacing: AppDesignSystem.Spacing.none) {
                if expanded {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Spacer(minLength: AppDesignSystem.Spacing.none)
                        AppFloatingActionStack(axis: .horizontal) { buttons }
                    }
                    .padding(.top, AppDesignSystem.Spacing.regular)
                    .background(AppDesignSystem.Palette.Background.grouped)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !expanded { AppFloatingActionStack { buttons } }
            }
    }
}

private struct AppInteractiveLabeledContentStyle: LabeledContentStyle {
    let isDestructive: Bool
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            configuration.content.foregroundStyle(.tint)
        } label: {
            configuration.label.foregroundStyle(isDestructive
                ? AnyShapeStyle(AppDesignSystem.Palette.Status.danger)
                : AnyShapeStyle(AppDesignSystem.Foreground.primary))
        }
        .labeledContentStyle(.automatic)
    }
}

/// 统一所有分组列表的系统样式、section 间距和横向内容边距。
extension View {
    /// 列表标题沿系统主文字色，右侧值沿页面主题，删除动作沿警示色。
    public func appInteractiveListRow(isDestructive: Bool = false) -> some View {
        foregroundStyle(isDestructive
            ? AnyShapeStyle(AppDesignSystem.Palette.Status.danger)
            : AnyShapeStyle(AppDesignSystem.Foreground.primary))
            .labeledContentStyle(AppInteractiveLabeledContentStyle(isDestructive: isDestructive))
    }

    public func appGroupedListStyle() -> some View {
        listStyle(.insetGrouped)
            .listSectionSpacing(AppDesignSystem.Spacing.content)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.horizontal, AppDesignSystem.Spacing.regular, for: .scrollContent)
    }

    /// 在实际列表行上设置内容边距。
    public func appListRowInsets() -> some View {
        listRowInsets(EdgeInsets(
            top: AppDesignSystem.Spacing.tiny,
            leading: AppDesignSystem.Spacing.content,
            bottom: AppDesignSystem.Spacing.tiny,
            trailing: AppDesignSystem.Spacing.content
        ))
    }

    public func appCommentSectionStyle() -> some View {
        background(
            AppDesignSystem.Palette.Background.system,
            in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped)
        )
        .overlay {
            AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped)
                .stroke(AppDesignSystem.Palette.Border.subtle, lineWidth: 1)
        }
    }

    public func appFeedCardStyle() -> some View {
        padding(AppDesignSystem.Spacing.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppDesignSystem.Palette.Background.system)
            .contentShape(Rectangle())
    }
}
#endif
