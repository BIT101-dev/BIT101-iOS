import SwiftUI

/// 信息流、详情页和编辑页共用的标签胶囊变体。
enum AppTagChipVariant {
    case feed
    case detail
    case selection(isSelected: Bool)

    var horizontalPadding: CGFloat {
        switch self {
        case .feed: return AppDesignSystem.Tag.feedHorizontalPadding
        case .detail: return AppDesignSystem.Tag.detailHorizontalPadding
        case .selection: return AppDesignSystem.Tag.selectionHorizontalPadding
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .feed: return AppDesignSystem.Tag.feedVerticalPadding
        case .detail: return AppDesignSystem.Tag.detailVerticalPadding
        case .selection: return AppDesignSystem.Tag.selectionVerticalPadding
        }
    }

    var font: Font {
        switch self {
        case .feed, .detail:
            return .caption.weight(.medium)
        case .selection:
            return .footnote.weight(.medium)
        }
    }
}

/// 统一标签文本、内边距、前景色和胶囊背景。
struct AppTagChip: View {
    let title: String
    let variant: AppTagChipVariant

    var body: some View {
        Text(title)
            .font(variant.font)
            .padding(.horizontal, variant.horizontalPadding)
            .padding(.vertical, variant.verticalPadding)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor, in: Capsule())
    }

    private var foregroundColor: Color {
        switch variant {
        case .feed, .detail:
            return AppDesignSystem.Palette.highlight
        case let .selection(isSelected):
            return isSelected ? .white : AppDesignSystem.Palette.accent
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .feed, .detail:
            return AppDesignSystem.Palette.highlight.opacity(0.12)
        case let .selection(isSelected):
            return isSelected
                ? AppDesignSystem.Palette.accent
                : AppDesignSystem.Palette.accent.opacity(0.12)
        }
    }
}
