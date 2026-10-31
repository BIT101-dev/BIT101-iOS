#if os(iOS)
import SwiftUI
import UIKit

public struct AppWindowLayout: Equatable {
    public var size: CGSize = .zero
    public var isRegularWidth = false
    public var usesAccessibilityText = false
    public var availableWidth: CGFloat?
    public var availableHeight: CGFloat?
    public var interfaceIdiom: UIUserInterfaceIdiom
    public var safeAreaInsets: UIEdgeInsets
    public var divisionX: CGFloat?
    private var windowUsesTopTabBar: Bool?
    private var windowUsesSideToolbar: Bool?
    public init(size: CGSize = .zero, isRegularWidth: Bool = false, usesAccessibilityText: Bool = false,
                availableWidth: CGFloat? = nil, availableHeight: CGFloat? = nil,
                interfaceIdiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom,
                safeAreaInsets: UIEdgeInsets = .zero, divisionX: CGFloat? = nil) {
        self.size = size; self.isRegularWidth = isRegularWidth; self.usesAccessibilityText = usesAccessibilityText
        self.availableWidth = availableWidth
        self.availableHeight = availableHeight
        self.interfaceIdiom = interfaceIdiom
        self.safeAreaInsets = safeAreaInsets
        self.divisionX = divisionX
    }
    public var sidebarWidth: CGFloat {
        hasLandscapeDivision ? max((divisionX ?? 0) - safeAreaInsets.left, 0)
            : (availableHeight ?? size.height) * AppDesignSystem.Size.Layout.sidebarAspectRatio
    }
    public var isLandscapeWindow: Bool { size.width > size.height }
    public var hasLandscapeDivision: Bool { divisionX != nil && isLandscapeWindow }
    public var hasHorizontalSystemInsets: Bool { safeAreaInsets.left > 0 || safeAreaInsets.right > 0 }
    public var contentTopInset: CGFloat {
        hasHorizontalSystemInsets && safeAreaInsets.top == 0 ? AppDesignSystem.Spacing.section : AppDesignSystem.Spacing.none
    }
    public var isLandscape: Bool {
        isRegularWidth && isLandscapeWindow && !usesAccessibilityText
            && (availableWidth ?? size.width) >= AppDesignSystem.Size.Layout.landscapeColumnsMinimumWidth
    }
    public var gridColumns: [GridItem] { Array(repeating: GridItem(.flexible()), count: isLandscape ? 2 : 1) }
    public var singleColumn: AppWindowLayout {
        var value = self
        value.windowUsesTopTabBar = usesTopTabBar
        value.windowUsesSideToolbar = usesSideToolbar
        value.isRegularWidth = false
        return value
    }
    public var usesExpandedNavigation: Bool { isLandscape && size.width >= AppDesignSystem.Size.Layout.expandedNavigationMinimumWidth }
    public var usesTopTabBar: Bool {
        if let windowUsesTopTabBar { return windowUsesTopTabBar }
        if #available(iOS 18.0, *) { return isRegularWidth && usesOpaqueNavigation } else { return false }
    }
    public var usesBottomTabBar: Bool { !usesTopTabBar && !hasHorizontalSystemInsets }
    public var usesSideToolbar: Bool {
        if let windowUsesSideToolbar { return windowUsesSideToolbar }
#if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) { return hasHorizontalSystemInsets && !isLandscapeWindow && !isRegularWidth }
#endif
        return false
    }
    public var usesOpaqueNavigation: Bool {
        switch interfaceIdiom {
        case .phone: false
        default: true
        }
    }
}

private struct AppWindowLayoutKey: EnvironmentKey {
    static var defaultValue: AppWindowLayout { AppWindowLayout() }
}

extension EnvironmentValues {
    @Entry public var appExpandedNavigation = false
    @Entry public var appPageIsVisible = true
    @Entry public var appUsesNativeToolbarActions = false
    @Entry public var appBrowserHeader: AnyView? = nil
    @Entry public var appFeedRowIsSelected = false
    @Entry public var appContentColumn: AppContentColumn? = nil
    public var appWindowLayout: AppWindowLayout {
        get { self[AppWindowLayoutKey.self] }
        set { self[AppWindowLayoutKey.self] = newValue }
    }
}

public enum AppContentColumn: Equatable { case leading, trailing }

public struct AppPairedPages<First: View, Second: View>: View {
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.appPageIsVisible) private var isVisible
    private let showsFirst: Bool
    private let pairsInLandscape: Bool
    private let first: First
    private let second: Second
    @State private var hasShownFirst: Bool
    @State private var hasShownSecond: Bool
    public init(showsFirst: Bool, pairsInLandscape: Bool = true,
                @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.showsFirst = showsFirst; self.first = first(); self.second = second()
        self.pairsInLandscape = pairsInLandscape
        _hasShownFirst = State(initialValue: showsFirst); _hasShownSecond = State(initialValue: !showsFirst)
    }
    public var body: some View {
        let isPaired = pairsInLandscape && layout.isLandscape
        let firstVisible = isPaired || showsFirst
        let secondVisible = isPaired || !showsFirst
        HStack(spacing: AppDesignSystem.Spacing.none) {
            if hasShownFirst || firstVisible {
                pane(first, visible: firstVisible)
                    .frame(width: isPaired && layout.hasLandscapeDivision ? layout.sidebarWidth : nil)
                    .environment(\.appContentColumn, isPaired ? .leading : nil)
            }
            if isPaired { Divider() }
            if hasShownSecond || secondVisible {
                pane(second, visible: secondVisible).environment(\.appContentColumn, isPaired ? .trailing : nil)
            }
        }
        .onChange(of: firstVisible, initial: true) { _, visible in if visible { hasShownFirst = true } }
        .onChange(of: secondVisible, initial: true) { _, visible in if visible { hasShownSecond = true } }
    }
    private func pane(_ content: some View, visible: Bool) -> some View {
        content.environment(\.appWindowLayout, pairsInLandscape ? layout.singleColumn : layout)
            .environment(\.appPageIsVisible, visible && isVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: visible ? nil : 0)
            .clipped().allowsHitTesting(visible).accessibilityHidden(!visible)
    }
}

public struct AppBrowserLayout<Selection: Hashable, Master: View, Detail: View, DefaultDetail: View>: View {
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.appBrowserHeader) private var header
    @Environment(\.appPageIsVisible) private var isVisible
    @Binding private var selection: Selection?
    @State private var wasLandscapeWindow = false
    private let master: Master
    private let detail: (Selection) -> Detail
    private let defaultDetail: DefaultDetail
    public init(selection: Binding<Selection?>, title: String, symbol: String,
                @ViewBuilder master: () -> Master, @ViewBuilder detail: @escaping (Selection) -> Detail)
                where DefaultDetail == AppEmptyState {
        self.init(selection: selection, master: master,
            defaultDetail: { AppEmptyState(title: title, systemImage: symbol, message: "从左侧列表选择内容") },
            detail: detail)
    }
    public init(selection: Binding<Selection?>, @ViewBuilder master: () -> Master,
                @ViewBuilder defaultDetail: () -> DefaultDetail,
                @ViewBuilder detail: @escaping (Selection) -> Detail) {
        _selection = selection; self.defaultDetail = defaultDetail()
        self.master = master(); self.detail = detail
    }
    public var body: some View {
        Group {
            if layout.isLandscape {
                HStack(spacing: AppDesignSystem.Spacing.none) {
                    NavigationStack { masterContent }
                        .environment(\.appContentColumn, .leading)
                        .frame(width: layout.sidebarWidth)
                    Divider()
                    NavigationStack(path: Binding(get: { selection.map { [$0] } ?? [] }, set: { selection = $0.last })) {
                        defaultDetail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AppDesignSystem.Palette.Background.grouped)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.visible, for: .navigationBar)
                            .appNativeBarBackground(isPresented: layout.usesOpaqueNavigation)
                            .navigationDestination(for: Selection.self) { selected in
                                detailContent(selected).appPaneBackButton(isPresented: true) { selection = nil }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("browser.detail")
                    .environment(\.appContentColumn, .trailing)
                    .padding(.top, layout.usesTopTabBar ? AppDesignSystem.Size.Control.touchTarget : AppDesignSystem.Spacing.none)
                    .padding(.top, header == nil ? AppDesignSystem.Spacing.none : layout.contentTopInset)
                }
            } else {
                NavigationStack(path: Binding(get: { selection.map { [$0] } ?? [] }, set: { selection = $0.last })) {
                    masterContent
                        .environment(\.appPageIsVisible, isVisible && selection == nil)
                        .navigationDestination(for: Selection.self) { selected in
                            detailContent(selected)
                                .accessibilityElement(children: .contain).accessibilityIdentifier("browser.detail")
                        }
                }
                .padding(.top, layout.usesTopTabBar && selection != nil
                    ? AppDesignSystem.Size.Control.touchTarget : AppDesignSystem.Spacing.none)
            }
        }
        .padding(.top, header == nil ? layout.contentTopInset : AppDesignSystem.Spacing.none)
        .ignoresSafeArea(.keyboard, edges: layout.isLandscapeWindow ? .bottom : [])
        .background(AppDesignSystem.Palette.Background.grouped)
        .onChange(of: layout.isLandscapeWindow, initial: true) { _, isLandscape in
            if wasLandscapeWindow && !isLandscape {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { selection = nil }
            }
            wasLandscapeWindow = isLandscape
        }
    }

    private var masterContent: some View {
        master.environment(\.appWindowLayout, layout.singleColumn)
            .ignoresSafeArea(.container, edges: layout.isLandscape ? .trailing : [])
            .scrollContentBackground(.hidden)
            .background(AppDesignSystem.Palette.Background.grouped)
            .focusEffectDisabled()
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
                header?.padding(.top, layout.contentTopInset)
            }
            .appBrowserNavigationBar()
            .accessibilityElement(children: .contain).accessibilityIdentifier("browser.master")
    }

    private func detailContent(_ selected: Selection) -> some View {
        detail(selected)
            .background(AppDesignSystem.Palette.Background.grouped)
            .toolbar(.visible, for: .navigationBar)
            .appNativeBarBackground(isPresented: layout.usesOpaqueNavigation)
    }
}

public struct AppBrowserListRow<Content: View>: View {
    private let isSelected: Bool
    private let action: () -> Void
    private let content: Content
    public init(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected; self.action = action; self.content = content()
    }
    public var body: some View {
        Button(action: action) {
            content.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, AppDesignSystem.Spacing.section)
                .contentShape(Rectangle())
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right")
                .font(AppDesignSystem.Typography.footnoteEmphasis)
                .foregroundStyle(AppDesignSystem.Foreground.tertiary)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("ui.app-browser-list-row.action")
        .appInteractiveListRow(isSelected: isSelected)
    }
}

private struct AppWindowLayoutModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measurement = AppWindowLayout()
    func body(content: Content) -> some View {
        var layout = measurement
        layout.isRegularWidth = horizontalSizeClass == .regular
        layout.usesAccessibilityText = dynamicTypeSize.isAccessibilitySize
        return content
            .background(AppWindowSizeReader(onChange: { measurement = $0 }))
            .environment(\.appWindowLayout, layout)
    }
}

private struct AppWindowSizeReader: UIViewRepresentable {
    let onChange: (AppWindowLayout) -> Void
    func makeUIView(context: Context) -> ProbeView { ProbeView(onChange: onChange) }
    func updateUIView(_ view: ProbeView, context: Context) { view.onChange = onChange; view.measure() }
    final class ProbeView: UIView {
        var onChange: (AppWindowLayout) -> Void
        private var lastMeasurement: AppWindowLayout?
        init(onChange: @escaping (AppWindowLayout) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { return nil }
        override func didMoveToWindow() { super.didMoveToWindow(); measure() }
        override func layoutSubviews() { super.layoutSubviews(); measure() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); measure() }
        func measure() {
            guard let window, bounds.width > 0 else { return }
            var divisionX: CGFloat?
#if !targetEnvironment(macCatalyst)
            if #available(iOS 27.1, *) {
                divisionX = window.reservedRegions(kind: .division, options: .includeInactive)
                    .first { $0.frame.height > $0.frame.width && $0.frame.midX > 0 && $0.frame.midX < window.bounds.width }?.frame.midX
            }
#endif
            let value = AppWindowLayout(size: window.bounds.size, availableWidth: bounds.width,
                availableHeight: window.safeAreaLayoutGuide.layoutFrame.height,
                interfaceIdiom: window.traitCollection.userInterfaceIdiom, safeAreaInsets: window.safeAreaInsets, divisionX: divisionX)
            guard value != lastMeasurement else { return }
            lastMeasurement = value
            Task { @MainActor [weak self] in
                guard let self, lastMeasurement == value else { return }
                onChange(value)
            }
        }
    }
}

extension View {
    public func appPaneBackButton(isPresented: Bool, onBack: @escaping () -> Void) -> some View {
        modifier(AppPaneBackButtonModifier(isPresented: isPresented, onBack: onBack))
    }

    public func appWindowLayout() -> some View { modifier(AppWindowLayoutModifier()) }
    public func appReadableContent(fillsAvailableWidth: Bool = false) -> some View {
        modifier(AppReadableContentModifier(fillsAvailableWidth: fillsAvailableWidth))
    }
    public func appBrowserHeader<Header: View>(isPresented: Bool = true, @ViewBuilder content: () -> Header) -> some View {
        environment(\.appBrowserHeader, isPresented ? AnyView(content()) : nil)
    }
    public func appNativeBarBackground(isPresented: Bool) -> some View {
        toolbarBackground(isPresented ? AnyShapeStyle(AppDesignSystem.Palette.Background.grouped) : AnyShapeStyle(Material.bar),
                          for: .tabBar, .navigationBar)
            .toolbarBackground(isPresented ? .visible : .automatic, for: .tabBar, .navigationBar)
            .navigationBarTitleDisplayMode(isPresented ? .inline : .automatic)
    }
}

private struct AppPaneBackButtonModifier: ViewModifier {
    let isPresented: Bool
    let onBack: () -> Void
    func body(content: Content) -> some View {
        content.navigationBarBackButtonHidden(isPresented)
            .toolbar {
                if isPresented {
#if !targetEnvironment(macCatalyst)
                    if #available(iOS 27.1, *) { backItem.axisBehavior(.horizontalOnly) }
                    else { backItem }
#else
                    backItem
#endif
                }
            }
    }
    private var backItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("返回", systemImage: "chevron.backward", action: onBack)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("app.pane.back")
        }
    }
}

private struct AppReadableContentModifier: ViewModifier {
    let fillsAvailableWidth: Bool
    func body(content: Content) -> some View {
        content.frame(maxWidth: fillsAvailableWidth ? .infinity : AppDesignSystem.Size.Layout.readingWidth)
            .frame(maxWidth: .infinity)
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
    let accessibilityIdentifier: String?
    @Environment(\.appUsesNativeToolbarActions) private var usesNativeToolbar
    @State private var feedbackToken = 0

    public init(
        systemImage: String,
        badgeText: String? = nil,
        accessibilityLabel: String,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.badgeText = badgeText
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        Group {
            if usesNativeToolbar {
                Button(accessibilityLabel, systemImage: systemImage, action: performAction)
                    .labelStyle(.iconOnly)
                    .badge(badgeText.map { Text($0) })
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(badgeText.map { "\($0) 条未读" } ?? "")
                    .accessibilityIdentifier(accessibilityIdentifier ?? "ui.app-floating-action-button.toolbar-action")
            } else {
                Button(action: performAction) {
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
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(badgeText.map { "\($0) 条未读" } ?? "")
                .accessibilityIdentifier(accessibilityIdentifier ?? "ui.app-floating-action-button.action")
            }
        }
        .appImpactFeedback(trigger: feedbackToken)
    }
    private func performAction() {
        feedbackToken &+= 1
        action()
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
    @Environment(\.appWindowLayout) private var windowLayout
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
        .padding(.bottom, windowLayout.isLandscapeWindow ? AppDesignSystem.Spacing.none
            : AppDesignSystem.Size.Layout.floatingActionBottomInset)
    }
}

extension View {
    public func appBrowserActions<Actions: View>(floatingBottomInset: CGFloat = 0,
        @ViewBuilder actions: () -> Actions) -> some View {
        appBrowserFloatingActions(bottomInset: floatingBottomInset, actions: actions)
            .appSideToolbarActions(actions: actions)
    }

    public func appBrowserFloatingActions<Actions: View>(bottomInset: CGFloat = 0,
        @ViewBuilder actions: () -> Actions) -> some View {
        modifier(AppBrowserFloatingActionsModifier(actions: actions(), bottomInset: bottomInset))
    }

    public func appSideToolbarActions<Actions: View>(@ViewBuilder actions: () -> Actions) -> some View {
        modifier(AppSideToolbarActionsModifier(actions: actions()))
    }

    public func appBrowserNavigationBar() -> some View { modifier(AppBrowserNavigationBarModifier()) }
}

private struct AppBrowserNavigationBarModifier: ViewModifier {
    @Environment(\.appWindowLayout) private var layout
    func body(content: Content) -> some View {
        content.background(AppDesignSystem.Palette.Background.grouped)
            .toolbar(layout.usesTopTabBar || layout.usesSideToolbar ? .visible : .hidden, for: .navigationBar)
            .appNativeBarBackground(isPresented: layout.usesOpaqueNavigation)
    }
}

private struct AppBrowserFloatingActionsModifier<Actions: View>: ViewModifier {
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.appPageIsVisible) private var isVisible
    let actions: Actions
    let bottomInset: CGFloat
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if isVisible && !layout.usesSideToolbar {
                AppFloatingActionStack { actions }.padding(.bottom, bottomInset)
            }
        }
    }
}

private struct AppSideToolbarActionsModifier<Actions: View>: ViewModifier {
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.appPageIsVisible) private var isVisible
    let actions: Actions
    func body(content: Content) -> some View {
        content.toolbar {
#if !targetEnvironment(macCatalyst)
            if #available(iOS 27.1, *), layout.usesSideToolbar && isVisible {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    actions.environment(\.appUsesNativeToolbarActions, true)
                }
                .axisBehavior(.verticalPreferred)
            }
#endif
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

private struct AppSelectableRowBackground: View {
    let isSelected: Bool
    var color = AppDesignSystem.Palette.Background.secondaryGrouped
    var body: some View {
        ZStack {
            color
            if isSelected { AppSelectionHighlight() }
        }
    }
}

/// 统一所有分组列表的系统样式、section 间距和横向内容边距。
extension View {
    /// 列表标题沿系统主文字色，右侧值沿页面主题，删除动作沿警示色。
    @ViewBuilder public func appInteractiveListRow(isDestructive: Bool = false, isSelected: Bool? = nil) -> some View {
        let row = foregroundStyle(isDestructive
            ? AnyShapeStyle(AppDesignSystem.Palette.Status.danger)
            : AnyShapeStyle(AppDesignSystem.Foreground.primary))
            .labeledContentStyle(AppInteractiveLabeledContentStyle(isDestructive: isDestructive))
        if let isSelected {
            row.listRowBackground(AppSelectableRowBackground(isSelected: isSelected))
                .focusEffectDisabled()
        }
        else { row.listRowBackground(AppDesignSystem.Palette.Background.secondaryGrouped) }
    }

    public func appGroupedListStyle(insetViewport: Bool = false) -> some View {
        modifier(AppGroupedListStyleModifier(insetViewport: insetViewport))
    }
}

private struct AppGroupedListStyleModifier: ViewModifier {
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.appContentColumn) private var column
    let insetViewport: Bool
    func body(content: Content) -> some View {
        let inset = insetViewport || (layout.hasHorizontalSystemInsets && column != .leading)
        content.listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, AppDesignSystem.Size.Control.refreshStatusRowHeight)
            .listSectionSpacing(AppDesignSystem.Spacing.content)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.horizontal, inset ? AppDesignSystem.Spacing.tiny : AppDesignSystem.Spacing.regular,
                            for: .scrollContent)
            .padding(.horizontal, inset ? AppDesignSystem.Spacing.tiny : AppDesignSystem.Spacing.none)
    }
}

extension View {

    public func appGroupedSectionStyle() -> some View {
        listRowBackground(AppDesignSystem.Palette.Background.secondaryGrouped)
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
        modifier(AppFeedCardStyleModifier())
    }
}

private struct AppFeedCardStyleModifier: ViewModifier {
    @Environment(\.appFeedRowIsSelected) private var isSelected
    func body(content: Content) -> some View {
        content.padding(AppDesignSystem.Spacing.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSelectableRowBackground(isSelected: isSelected, color: AppDesignSystem.Palette.Background.system))
            .contentShape(Rectangle())
    }
}
#endif
