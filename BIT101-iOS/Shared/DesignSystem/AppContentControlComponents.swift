import SwiftUI

enum AppInputPrompt {
    static func text(_ value: String) -> Text {
        Text(value)
            .font(AppDesignSystem.Typography.body)
            .foregroundStyle(AppDesignSystem.Palette.inputPlaceholder)
    }
}

/// AppListSectionHeader 统一自定义列表分组标题的语义样式。
struct AppListSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(AppDesignSystem.Typography.footnoteEmphasis)
            .foregroundStyle(.secondary)
    }
}

/// AppNavigationRowLabel 为设置入口等导航行提供图标、标题和可选披露标记。
struct AppNavigationRowLabel: View {
    let title: String
    let systemImage: String
    var showsDisclosureIndicator = false

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Image(systemName: systemImage)
                .frame(
                    width: AppDesignSystem.Size.Control.navigationIcon,
                    height: AppDesignSystem.Size.Control.navigationIcon
                )
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            Text(title)
                .font(AppDesignSystem.Typography.headline)
                .foregroundStyle(.primary)

            Spacer()

            if showsDisclosureIndicator {
                Image(systemName: "chevron.right")
                    .font(AppDesignSystem.Typography.footnoteEmphasis)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// AppSegmentedPicker 为应用内 segmented 控件提供统一的基础样式和选择触感。
struct AppSegmentedPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    private let content: Content

    init(
        title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        Picker(title, selection: $selection) {
            content
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
        .appSelectionFeedback(trigger: selection)
    }
}

/// AppTopSegmentedPickerVariant 表示顶部 segmented 控件的层级变体。
enum AppTopSegmentedPickerVariant {
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
struct AppTopSegmentedPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    let variant: AppTopSegmentedPickerVariant
    private let content: Content

    init(
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

    var body: some View {
        AppSegmentedPicker(title: title, selection: $selection) {
            content
        }
        .padding(.horizontal, AppDesignSystem.Spacing.regular)
        .padding(.bottom, variant.bottomPadding)
        .frame(maxWidth: .infinity)
        .background(AppDesignSystem.Palette.groupedBackground)
    }
}

/// AppOrderedSearchBar 为话廊和文章提供带排序菜单的搜索栏。
struct AppOrderedSearchBar<Order: Hashable, OrderContent: View>: View {
    @Binding var text: String
    @Binding var order: Order
    let selectedOrderTitle: String
    let placeholder: String
    let onSubmit: () -> Void
    let onClear: () -> Void
    private let orderContent: OrderContent

    init(
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

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Picker(selection: $order) {
                orderContent
            } label: {
                Label(selectedOrderTitle, systemImage: "arrow.up.arrow.down.circle")
            }
            .pickerStyle(.menu)
            .appSelectionFeedback(trigger: order)

            TextField("", text: $text, prompt: AppInputPrompt.text(placeholder))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)

            Button {
                text = ""
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(AppDesignSystem.Typography.title3)
                    .foregroundStyle(AppDesignSystem.Palette.highlight)
                    .frame(
                        width: AppDesignSystem.Size.Control.touchTarget,
                        height: AppDesignSystem.Size.Control.touchTarget
                    )
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .accessibilityLabel("清除搜索")
        }
        .padding(.horizontal, AppDesignSystem.Spacing.content)
        .padding(.vertical, AppDesignSystem.Spacing.regular)
        .background(
            AppDesignSystem.Palette.secondaryBackground,
            in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped)
        )
    }
}

/// AppSearchBarContainer 为页面顶部搜索栏提供外层材质和内边距。
struct AppSearchBarContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, AppDesignSystem.Spacing.content)
            .padding(.top, AppDesignSystem.Spacing.regular)
            .padding(.bottom, AppDesignSystem.Spacing.regular)
            .background(.thinMaterial)
    }
}

/// AppMultiSelectionList 统一多选列表的行布局、选中图标、全选入口和完成按钮。
struct AppMultiSelectionList<Item: Hashable>: View {
    let title: String
    let items: [Item]
    let itemTitle: (Item) -> String
    let selectAllTitle: String?
    let showsCompletionButton: Bool
    @Binding var selectedItems: [Item]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if selectAllTitle != nil {
                Section {
                    Button(toggleAllTitle) { toggleAll() }
                }
            }

            Section {
                ForEach(items, id: \.self) { item in
                    let isSelected = selectedItems.contains(item)
                    Button {
                        toggle(item)
                    } label: {
                        HStack(spacing: AppDesignSystem.Spacing.regular) {
                            Text(itemTitle(item))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? AppDesignSystem.Palette.accent : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(itemTitle(item))
                    .accessibilityValue(isSelected ? "已选择" : "未选择")
                }
            }
        }
        .appGroupedListStyle()
        .appSelectionFeedback(trigger: selectedItems)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCompletionButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var toggleAllTitle: String {
        let availableItems = Set(items)
        return availableItems.isSubset(of: Set(selectedItems)) ? "全不选" : (selectAllTitle ?? "全选")
    }

    private func toggle(_ item: Item) {
        if let index = selectedItems.firstIndex(of: item) {
            selectedItems.remove(at: index)
        } else {
            selectedItems.append(item)
        }
    }

    private func toggleAll() {
        let availableItems = Set(items)
        selectedItems = availableItems.isSubset(of: Set(selectedItems)) ? [] : items
    }
}
