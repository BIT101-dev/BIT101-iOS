import SwiftUI

/// AppTagChipVariant 为信息流、详情页和编辑页提供标签胶囊样式变体。
enum AppTagChipVariant {
    case display
    case selection(isSelected: Bool)

    var horizontalPadding: CGFloat {
        switch self {
        case .display: return AppDesignSystem.Spacing.control
        case .selection: return AppDesignSystem.Spacing.content
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .display: return AppDesignSystem.Spacing.tight
        case .selection: return AppDesignSystem.Spacing.regular
        }
    }

    var font: Font {
        switch self {
        case .display:
            return .caption.weight(.medium)
        case .selection:
            return .footnote.weight(.medium)
        }
    }
}

/// AppTagChip 根据变体显示标签文本并应用内边距、前景色和胶囊背景。
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
        case .display:
            return AppDesignSystem.Palette.highlight
        case let .selection(isSelected):
            return isSelected
                ? AppDesignSystem.Palette.highlightForeground
                : AppDesignSystem.Palette.accent
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .display:
            return AppDesignSystem.Palette.highlightSurface
        case let .selection(isSelected):
            return isSelected
                ? AppDesignSystem.Palette.accent
                : AppDesignSystem.Palette.accent.opacity(0.12)
        }
    }
}
