import SwiftUI

/// 统一应用内的 segmented 控件基础样式和选择触感。
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

/// 顶部 segmented 控件的垂直层级变体。
enum AppTopSegmentedPickerVariant {
    /// 页面唯一顶部切换栏使用的标准高度。
    case standard
    /// 叠在另一个顶部切换栏下方时使用，避免重复累计两套顶部留白。
    case stacked

    var bottomPadding: CGFloat {
        switch self {
        case .standard:
            return AppDesignSystem.TopBar.bottomPadding
        case .stacked:
            return AppDesignSystem.TopBar.stackedBottomPadding
        }
    }
}

/// 统一承载页面顶部 segmented 控件的安全区内边距和背景。
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
        .padding(.horizontal, AppDesignSystem.TopBar.horizontalPadding)
        .padding(.top, AppDesignSystem.TopBar.topPadding)
        .padding(.bottom, variant.bottomPadding)
        .frame(maxWidth: .infinity)
        .background(AppDesignSystem.Palette.groupedBackground)
    }
}

/// 话廊和文章共用的带排序菜单搜索栏。
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
                    .foregroundStyle(
                        text.isEmpty
                            ? AppDesignSystem.Palette.neutral.opacity(AppDesignSystem.Search.clearButtonOpacity)
                            : AppDesignSystem.Palette.highlight
                    )
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
        }
        .padding(.horizontal, AppDesignSystem.Search.horizontalPadding)
        .padding(.vertical, AppDesignSystem.Search.verticalPadding)
        .background(
            AppDesignSystem.Palette.secondaryBackground,
            in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.grouped)
        )
    }
}

/// 统一搜索栏在页面顶部安全区中的外层材质和内边距。
struct AppSearchBarContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, AppDesignSystem.Search.chromeHorizontalPadding)
            .padding(.top, AppDesignSystem.Search.chromeTopPadding)
            .padding(.bottom, AppDesignSystem.Search.chromeBottomPadding)
            .background(.thinMaterial)
    }
}
