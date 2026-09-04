import SwiftUI

/// 账号头像统一的加载、占位、裁切和尺寸容器。
struct AppAvatarView: View {
    let imageURL: URL?
    let size: CGFloat
    let tint: Color
    let systemImage: String

    init(
        imageURL: URL?,
        size: CGFloat = AppDesignSystem.Comment.avatarSize,
        tint: Color = AppDesignSystem.Palette.highlight,
        systemImage: String = "person.fill"
    ) {
        self.imageURL = imageURL
        self.size = size
        self.tint = tint
        self.systemImage = systemImage
    }

    var body: some View {
        CachedRemoteImage(url: imageURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Circle()
                .fill(tint.opacity(0.15))
                .overlay {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .font(size >= 64 ? .title2 : .caption.weight(.bold))
                }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
