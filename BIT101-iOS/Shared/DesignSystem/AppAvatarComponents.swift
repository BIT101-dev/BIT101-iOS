import SwiftUI

/// 账号头像统一的加载、占位、裁切和尺寸容器。
struct AppAvatarView: View {
    let imageURL: URL?
    let size: CGFloat
    let tint: Color
    let systemImage: String
    let accessibilityLabel: String?

    init(
        imageURL: URL?,
        size: CGFloat = AppDesignSystem.Size.Avatar.standard,
        tint: Color = AppDesignSystem.Palette.highlight,
        systemImage: String = "person.fill",
        accessibilityLabel: String? = nil
    ) {
        self.imageURL = imageURL
        self.size = size
        self.tint = tint
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        CachedRemoteImage(url: imageURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Circle()
                .fill(tint.opacity(AppDesignSystem.Size.Avatar.placeholderOpacity))
                .overlay {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .font(
                            size >= AppDesignSystem.Size.Avatar.largeIconThreshold
                                ? AppDesignSystem.Typography.title2
                                : AppDesignSystem.Typography.captionEmphasis
                        )
                }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(accessibilityLabel == nil)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}
