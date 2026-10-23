#if os(iOS)
import SwiftUI

public enum AppInputPrompt {
    public static func text(_ value: String) -> Text {
        Text(value)
            .font(AppDesignSystem.Typography.body)
            .foregroundStyle(AppDesignSystem.Palette.Background.inputPlaceholder)
    }
}

/// AppListSectionHeader 统一自定义列表分组标题的语义样式。
public struct AppListSectionHeader: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
    }
}

/// AppNavigationRowLabel 为导航行提供标题、可选图标和披露标记。
public struct AppNavigationRowLabel: View {
    public init(title: String, systemImage: String? = nil, showsDisclosureIndicator: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.showsDisclosureIndicator = showsDisclosureIndicator
    }

    let title: String
    let systemImage: String?
    var showsDisclosureIndicator = false

    public var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            if let systemImage {
                Image(systemName: systemImage)
                    .frame(
                        width: AppDesignSystem.Size.Control.navigationIcon,
                        height: AppDesignSystem.Size.Control.navigationIcon
                    )
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(AppDesignSystem.Typography.body)
                .foregroundStyle(AppDesignSystem.Foreground.primary)

            Spacer()

            if showsDisclosureIndicator {
                Image(systemName: "chevron.right")
                    .font(AppDesignSystem.Typography.footnoteEmphasis)
                    .foregroundStyle(AppDesignSystem.Foreground.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// AppSegmentedPicker 为应用内 segmented 控件提供统一的基础样式和选择触感。
public struct AppSegmentedPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    private let content: Content

    public init(
        title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    public var body: some View {
        Picker(title, selection: $selection) {
            content
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
        .appSelectionFeedback(trigger: selection)
            .accessibilityIdentifier("ui.app-segmented-picker.value")
    }
}

/// AppTopSegmentedPickerVariant 表示顶部 segmented 控件的层级变体。
public enum AppTopSegmentedPickerVariant {
    /// 页面唯一的顶部切换栏使用标准底部留白。
    case standard
    /// 顶部切换栏叠在另一条顶部切换栏下方时使用紧凑底部留白，连续切换栏共享顶部内容间距。
    case stacked

    var bottomPadding: CGFloat {
        switch self {
        case .standard:
            return AppDesignSystem.Spacing.content
        case .stacked:
            return AppDesignSystem.Spacing.tiny
        }
    }
}

/// AppTopSegmentedPicker 为页面顶部 segmented 控件提供水平内边距、底部留白和分组背景。
public struct AppTopSegmentedPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    let variant: AppTopSegmentedPickerVariant
    private let content: Content

    public init(
        title: String,
        selection: Binding<Selection>,
        variant: AppTopSegmentedPickerVariant = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _selection = selection
        self.variant = variant
        self.content = content()
    }

    public var body: some View {
        AppSegmentedPicker(title: title, selection: $selection) {
            content
        }
        .font(AppDesignSystem.Typography.footnote)
        .padding(.horizontal, AppDesignSystem.Spacing.regular)
        .padding(.bottom, variant.bottomPadding)
        .frame(maxWidth: .infinity)
        .background(AppDesignSystem.Palette.Background.grouped)
    }
}

/// AppOrderedSearchBar 为话廊和文章提供带排序菜单的搜索栏。
public struct AppOrderedSearchBar<Order: Hashable, OrderContent: View>: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Binding var text: String
    @Binding var order: Order
    let selectedOrderTitle: String
    let placeholder: String
    let onSubmit: () -> Void
    let onClear: () -> Void
    private let orderContent: OrderContent

    public init(
        text: Binding<String>,
        order: Binding<Order>,
        selectedOrderTitle: String,
        placeholder: String = "在这里搜索哦",
        onSubmit: @escaping () -> Void,
        onClear: @escaping () -> Void,
        @ViewBuilder orderContent: () -> OrderContent
    ) {
        _text = text
        _order = order
        self.selectedOrderTitle = selectedOrderTitle
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.onClear = onClear
        self.orderContent = orderContent()
    }

    public var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Picker(selection: $order) {
                orderContent
            } label: {
                Label(selectedOrderTitle, systemImage: "arrow.up.arrow.down.circle")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("search.sort")
            .appSelectionFeedback(trigger: order)

            TextField("", text: $text, prompt: AppInputPrompt.text(placeholder))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    interactionEvidence?("interaction.AppOrderedSearchBar.onSubmit", "submit")

                    onSubmit()
                }
                .accessibilityIdentifier("ui.app-ordered-search-bar.input")

            Button {
                text = ""
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(AppDesignSystem.Palette.Accent.primary)
                    .frame(
                        width: AppDesignSystem.Size.Control.touchTarget,
                        height: AppDesignSystem.Size.Control.touchTarget
                    )
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .accessibilityLabel("清除搜索")
                .accessibilityIdentifier("ui.app-ordered-search-bar.清除搜索")
        }
        .padding(.horizontal, AppDesignSystem.Spacing.content)
        .padding(.vertical, AppDesignSystem.Spacing.regular)
        .background(
            AppDesignSystem.Palette.Background.secondary,
            in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped)
        )
    }
}

/// AppSearchBarContainer 为页面顶部搜索栏提供外层材质和内边距。
public struct AppSearchBarContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, AppDesignSystem.Spacing.content)
            .padding(.top, AppDesignSystem.Spacing.regular)
            .padding(.bottom, AppDesignSystem.Spacing.regular)
            .background(.thinMaterial)
    }
}

public struct AppSelectionRow: View {
    private let title: String
    private let isSelected: Bool
    public init(title: String, isSelected: Bool) { self.title = title; self.isSelected = isSelected }
    public var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Text(title)
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AppDesignSystem.Palette.Accent.primary : AppDesignSystem.Foreground.secondaryColor)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// AppMultiSelectionList 统一多选列表的行布局、选中图标、全选入口和完成按钮。
public struct AppMultiSelectionList<Item: Hashable>: View {
    public init(title: String, items: [Item], itemTitle: @escaping (Item) -> String, selectAllTitle: String?, showsCompletionButton: Bool, selectedItems: Binding<[Item]>, initialScrollItem: Item? = nil, onToggleAll: (() -> Void)? = nil) {
        self.title = title
        self.items = items
        self.itemTitle = itemTitle
        self.selectAllTitle = selectAllTitle
        self.showsCompletionButton = showsCompletionButton
        _selectedItems = selectedItems
        self.initialScrollItem = initialScrollItem
        self.onToggleAll = onToggleAll
    }

    let title: String
    let items: [Item]
    let itemTitle: (Item) -> String
    let selectAllTitle: String?
    let showsCompletionButton: Bool
    @Binding var selectedItems: [Item]
    let initialScrollItem: Item?
    let onToggleAll: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        ScrollViewReader { proxy in
        List {
            if selectAllTitle != nil {
                Section {
                    Button(toggleAllTitle) { toggleAll() }
                    .disabled(items.isEmpty)
                    .accessibilityValue("已选 \(Set(selectedItems).intersection(Set(items)).count) 项，共 \(items.count) 项")
                    .appInteractiveListRow()
                        .accessibilityIdentifier("ui.app-multi-selection-list.toggle-all")
                }
            }

            Section {
                if items.isEmpty { Text("暂无可选项").foregroundStyle(AppDesignSystem.Foreground.secondary) }
                ForEach(items, id: \.self) { item in
                    let isSelected = selectedItems.contains(item)
                    Button {
                        toggle(item)
                    } label: {
                        AppSelectionRow(title: itemTitle(item), isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(itemTitle(item))
                    .accessibilityValue(isSelected ? "已选择" : "未选择")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .appInteractiveListRow()
                        .accessibilityIdentifier("ui.app-multi-selection-list.item.\(String(reflecting: item))")
                    .id(item)
                }
            }
        }
        .accessibilityIdentifier("interaction.AppMultiSelectionList.list")
        .appGroupedListStyle()
        .appSelectionFeedback(trigger: selectedItems)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCompletionButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("ui.app-multi-selection-list.done")
                }
            }
        }
        .onAppear {
            if let initialScrollItem { proxy.scrollTo(initialScrollItem, anchor: .center) }
        }
        }
    }

    private var toggleAllTitle: String {
        let availableItems = Set(items)
        let allSelected = !items.isEmpty && availableItems.isSubset(of: Set(selectedItems))
        return allSelected ? "全不选" : (selectAllTitle ?? "全选")
    }

    private func toggle(_ item: Item) {
        if let index = selectedItems.firstIndex(of: item) {
            selectedItems.remove(at: index)
        } else {
            selectedItems.append(item)
        }
    }

    private func toggleAll() {
        if let onToggleAll { onToggleAll(); return }
        let availableItems = Set(items)
        selectedItems = availableItems.isSubset(of: Set(selectedItems)) ? [] : items
    }
}
#endif

#if os(iOS)

/// 横向控件以全局坐标参与分区切换的命中排除。
public struct AppHorizontalControlFramesKey: PreferenceKey {
    public static var defaultValue: [CGRect] { [] }
    public static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

/// 为 segmented 内容区提供一致的横向轻扫判定。
public func makeHorizontalSwitchGesture(excluding controlFrames: [CGRect] = [], onStep: @escaping (Int) -> Void) -> some Gesture {
    DragGesture(minimumDistance: 24, coordinateSpace: .global)
        .onEnded { value in
            guard !controlFrames.contains(where: { $0.contains(value.startLocation) }) else { return }
            let horizontal = value.translation.width
            let vertical = value.translation.height
            let horizontalDistance = abs(horizontal)
            let verticalDistance = abs(vertical)

            guard horizontalDistance > verticalDistance, horizontalDistance >= 56 else { return }
            onStep(horizontal < 0 ? 1 : -1)
        }
}

#endif
