import SwiftUI

/// AppNavigationRowLabel 为设置入口等导航行提供图标、标题和可选披露标记。
struct AppNavigationRowLabel: View {
    let title: String
    let systemImage: String
    var showsDisclosureIndicator = false

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Image(systemName: systemImage)
                .frame(
                    width: AppDesignSystem.Size.control.navigationIcon,
                    height: AppDesignSystem.Size.control.navigationIcon
                )
                .foregroundStyle(.primary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            if showsDisclosureIndicator {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
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
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Picker(selection: $order) {
                orderContent
            } label: {
                Label(selectedOrderTitle, systemImage: "arrow.up.arrow.down.circle")
            }
            .pickerStyle(.menu)
            .appSelectionFeedback(trigger: order)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)

            Button {
                text = ""
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppDesignSystem.Palette.highlight)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .accessibilityLabel("清除搜索")
        }
        .padding(.horizontal, AppDesignSystem.Spacing.container)
        .padding(.vertical, AppDesignSystem.Spacing.control)
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
            .padding(.horizontal, AppDesignSystem.Spacing.container)
            .padding(.top, AppDesignSystem.Spacing.control)
            .padding(.bottom, AppDesignSystem.Spacing.regular)
            .background(.thinMaterial)
    }
}
