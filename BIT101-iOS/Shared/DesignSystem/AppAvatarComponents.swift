import SwiftUI

nonisolated enum AppUserPresentation {
    static let anonymousName = "匿名用户"
}

/// 头像统一的占位、裁切、无障碍和尺寸容器。
struct AppAvatarContainer: View {
    let image: Image?
    let size: CGFloat
    let tint: Color
    let systemImage: String
    let accessibilityLabel: String?

    init(
        image: Image?,
        size: CGFloat = AppDesignSystem.Size.Avatar.standard,
        tint: Color = AppDesignSystem.Palette.Accent.primary,
        systemImage: String = "person.fill",
        accessibilityLabel: String? = nil
    ) {
        self.image = image
        self.size = size
        self.tint = tint
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Group {
            if let image {
                image
                .resizable()
                .scaledToFill()
            } else {
                Circle()
                    .fill(tint.opacity(AppDesignSystem.Opacity.subtle))
                    .overlay {
                        Image(systemName: systemImage)
                            .foregroundStyle(tint)
                            .font(
                                size >= AppDesignSystem.Size.Avatar.largeIconThreshold
                                    ? AppDesignSystem.Typography.title
                                    : AppDesignSystem.Typography.captionEmphasis
                            )
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(accessibilityLabel == nil)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}
