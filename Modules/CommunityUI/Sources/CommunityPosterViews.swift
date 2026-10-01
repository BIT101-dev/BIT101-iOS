import CommunityCore
import Foundation
import MediaKit

/// 社区图片在媒体边界投影为下载地址。
extension CommunityImage {
    public var previewImage: RemotePreviewImage {
        RemotePreviewImage(
            thumbnailURL: URL(string: lowUrl.isEmpty ? url : lowUrl),
            originalURL: URL(string: url.isEmpty ? lowUrl : url)
        )
    }
}

#if os(iOS)
import DesignSystemKit
import SwiftUI

/// 单个帖子卡片。
///
/// 帖子点击进入详情，图片点击进入全屏看图，二者需要显式拆开避免手势冲突。
public struct CommunityPosterCard: View {
    let poster: CommunityPoster
    let onOpenPoster: () -> Void
    let onOpenImage: (Int, [CommunityImage]) -> Void
    let onDelete: (() -> Void)?
    let onReport: (() -> Void)?

    public init(poster: CommunityPoster, onOpenPoster: @escaping () -> Void, onOpenImage: @escaping (Int, [CommunityImage]) -> Void, onDelete: (() -> Void)? = nil, onReport: (() -> Void)? = nil) {
        self.poster = poster
        self.onOpenPoster = onOpenPoster
        self.onOpenImage = onOpenImage
        self.onDelete = onDelete
        self.onReport = onReport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                Text(poster.title)
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(AppDesignSystem.Palette.Accent.primary)
                    .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: AppDesignSystem.Spacing.regular) {
                    AppAvatarView(
                        imageURL: poster.anonymous
                            ? nil
                            : URL(string: poster.user.avatar.lowUrl.isEmpty ? poster.user.avatar.url : poster.user.avatar.lowUrl),
                        anonymous: poster.anonymous
                    )

                    VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.micro) {
                        HStack(spacing: AppDesignSystem.Spacing.tiny) {
                            Text(poster.anonymous ? AppUserPresentation.anonymousName : poster.user.nickname)
                                .font(AppDesignSystem.Typography.bodyEmphasis)
                                .foregroundStyle(AppDesignSystem.Foreground.primary)
                                .lineLimit(1)

                            if !poster.anonymous, !poster.user.identity.text.isEmpty {
                                Text(poster.user.identity.text)
                                    .font(AppDesignSystem.Typography.captionEmphasis)
                                    .padding(.horizontal, AppDesignSystem.Spacing.tiny)
                                    .padding(.vertical, AppDesignSystem.Spacing.micro)
                                    .background(identityColor.opacity(AppDesignSystem.Community.identitySurfaceOpacity), in: Capsule())
                                    .foregroundStyle(identityColor)
                            }
                        }

                        if !poster.anonymous, !poster.user.motto.isEmpty {
                            Text(poster.user.motto)
                                .font(AppDesignSystem.Typography.caption)
                                .foregroundStyle(AppDesignSystem.Foreground.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if onDelete != nil || onReport != nil {
                        CommunityPosterActionMenu(
                            onDelete: onDelete,
                            onReport: onReport
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { }
                    }
                }

                Text(communityLinkifiedText(poster.text))
                    .font(AppDesignSystem.Typography.body)
                    .lineLimit(poster.images.count <= 2 ? 4 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenPoster)

            if !poster.images.isEmpty {
                CommunityPosterImagesView(images: poster.images, onOpenImage: onOpenImage)
            }

            HStack(spacing: AppDesignSystem.Spacing.content) {
                Label("\(poster.likeNum)", systemImage: "hand.thumbsup")
                Label("\(poster.commentNum)", systemImage: "bubble.right")

                if !poster.public {
                    Label("仅自己可见", systemImage: "eye.slash")
                }

                if !poster.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppDesignSystem.Spacing.tiny) {
                            ForEach(poster.tags, id: \.self) { tag in
                                AppTagChip(title: tag, variant: .display)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: AppDesignSystem.Spacing.tiny)
                }

                Text(relativeTimeText(poster.editTime))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(AppDesignSystem.Typography.caption)
            .foregroundStyle(AppDesignSystem.Foreground.secondary)
        }
        .appFeedCardStyle()
        .accessibilityAddTraits(.isButton)
    }

    private var identityColor: Color {
        Color(hex: poster.user.identity.color) ?? AppDesignSystem.Palette.Accent.primary
    }

    /// 把后端时间文本转成相对时间文案。
    private func relativeTimeText(_ string: String) -> String {
        AppDateText.relativeText(from: string, fallback: "未知")
    }
}

/// 帖子图片网格。
///
/// 图片组使用单行比例格带，基础格保持竖向 1:√2。
public struct CommunityPosterImagesView: View {
    private struct Allocation: Identifiable {
        let index: Int
        let width: CGFloat

        var id: Int { index }
    }

    private struct LayoutPlan {
        let allocations: [Allocation]
        let hiddenImageCount: Int
    }

    let images: [CommunityImage]
    let onOpenImage: (Int, [CommunityImage]) -> Void
    @State private var imageAspectRatios: [Int: CGFloat] = [:]

    public init(images: [CommunityImage], onOpenImage: @escaping (Int, [CommunityImage]) -> Void) {
        self.images = images
        self.onOpenImage = onOpenImage
    }

    public var body: some View {
        GeometryReader { proxy in
            let spacing = AppDesignSystem.Spacing.tiny
            let plan = layoutPlan(in: proxy.size, spacing: spacing)

            HStack(spacing: spacing) {
                ForEach(plan.allocations) { allocation in
                    Button {
                        onOpenImage(allocation.index, images)
                    } label: {
                        ZStack {
                            CommunityImageThumbnail(
                                image: images[allocation.index],
                                contentMode: .fill,
                                onAspectRatioResolved: { ratio in
                                    guard ratio > 0, imageAspectRatios[allocation.index] != ratio else { return }
                                    imageAspectRatios[allocation.index] = ratio
                                }
                            )

                            if allocation.index == plan.allocations.last?.index,
                               plan.hiddenImageCount > 0 {
                                AppDesignSystem.Palette.Media.overlay
                                Text("+\(plan.hiddenImageCount)")
                                    .font(AppDesignSystem.Typography.title)
                                    .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
                            }
                        }
                        .frame(width: allocation.width, height: proxy.size.height)
                        .clipped()
                        .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("查看第\(allocation.index + 1)张图片")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(AppDesignSystem.Community.thumbnailLandscapeAspectRatio, contentMode: .fit)
        .onChange(of: images) { _, _ in
            imageAspectRatios = [:]
        }
    }

    private func layoutPlan(in size: CGSize, spacing: CGFloat) -> LayoutPlan {
        guard !images.isEmpty, size.width > 0, size.height > 0 else {
            return LayoutPlan(allocations: [], hiddenImageCount: 0)
        }

        let targetRatio = AppDesignSystem.Community.thumbnailPortraitAspectRatio
        let targetWidth = size.height * targetRatio
        let estimatedCount = max((size.width + spacing) / max(targetWidth + spacing, 1), 1)
        let lowerCount = max(Int(floor(estimatedCount)), 1)
        let upperCount = max(Int(ceil(estimatedCount)), 1)
        let candidateCounts = lowerCount == upperCount ? [lowerCount] : [lowerCount, upperCount]
        let divisionCount = candidateCounts.min { lhs, rhs in
            divisionError(
                count: lhs,
                width: size.width,
                height: size.height,
                spacing: spacing,
                targetRatio: targetRatio
            ) < divisionError(
                count: rhs,
                width: size.width,
                height: size.height,
                spacing: spacing,
                targetRatio: targetRatio
            )
        } ?? 1
        let cellWidth = max(
            (size.width - CGFloat(divisionCount - 1) * spacing) / CGFloat(divisionCount),
            1
        )

        var remainingCells = divisionCount
        var allocations: [Allocation] = []
        for index in images.indices where remainingCells > 0 {
            let imageRatio = imageAspectRatios[index] ?? targetRatio
            let span = (1 ... remainingCells).min { lhs, rhs in
                spanError(
                    span: lhs,
                    imageRatio: imageRatio,
                    cellWidth: cellWidth,
                    height: size.height,
                    spacing: spacing
                ) < spanError(
                    span: rhs,
                    imageRatio: imageRatio,
                    cellWidth: cellWidth,
                    height: size.height,
                    spacing: spacing
                )
            } ?? 1
            let width = CGFloat(span) * cellWidth + CGFloat(span - 1) * spacing
            allocations.append(Allocation(index: index, width: width))
            remainingCells -= span
        }

        return LayoutPlan(
            allocations: allocations,
            hiddenImageCount: max(images.count - allocations.count, 0)
        )
    }

    private func divisionError(
        count: Int,
        width: CGFloat,
        height: CGFloat,
        spacing: CGFloat,
        targetRatio: CGFloat
    ) -> CGFloat {
        let cellWidth = (width - CGFloat(count - 1) * spacing) / CGFloat(count)
        let ratio = max(cellWidth / height, 0.001)
        return abs(log(ratio / targetRatio))
    }

    private func spanError(
        span: Int,
        imageRatio: CGFloat,
        cellWidth: CGFloat,
        height: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let occupiedWidth = CGFloat(span) * cellWidth + CGFloat(span - 1) * spacing
        let occupiedRatio = max(occupiedWidth / height, 0.001)
        return abs(log(occupiedRatio / max(imageRatio, 0.001)))
    }
}

/// 单张帖子图片缩略图。
public struct CommunityImageThumbnail: View {
    let image: CommunityImage
    private let width: CGFloat?
    private let maxHeight: CGFloat?
    private let aspectRatio: CGFloat?
    private let contentMode: ContentMode
    private let loadsOriginal: Bool
    private let onAspectRatioResolved: ((CGFloat) -> Void)?

    public init(
        image: CommunityImage,
        contentMode: ContentMode = .fit,
        loadsOriginal: Bool = false,
        onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    ) {
        self.image = image
        width = nil
        maxHeight = nil
        aspectRatio = nil
        self.contentMode = contentMode
        self.loadsOriginal = loadsOriginal
        self.onAspectRatioResolved = onAspectRatioResolved
    }

    /// 保留课程评论原有尺寸语义；话廊图片使用上面的自适应初始化器。
    public init(image: CommunityImage, width: CGFloat?, maxHeight: CGFloat?, aspectRatio: CGFloat) {
        self.image = image
        self.width = width
        self.maxHeight = maxHeight
        self.aspectRatio = aspectRatio
        contentMode = .fit
        loadsOriginal = false
        onAspectRatioResolved = nil
    }

    public var body: some View {
        if let aspectRatio {
            thumbnailContent
                .frame(maxWidth: width == nil ? .infinity : width)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(width: width)
                .frame(maxHeight: maxHeight)
                .clipped()
                .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
        } else {
            thumbnailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        Group {
            if let animatedURL {
                RemoteAutoplayingImage(
                    url: animatedURL,
                    contentMode: contentMode,
                    cornerRadius: AppDesignSystem.Radius.card
                )
                .allowsHitTesting(false)
            } else if loadsOriginal, let originalURL {
                RemoteProgressiveStillImage(
                    thumbnailURL: thumbnailURL,
                    originalURL: originalURL,
                    contentMode: contentMode,
                    onAspectRatioResolved: onAspectRatioResolved
                )
            } else {
                RemoteCachedStillImage(
                    url: thumbnailURL,
                    contentMode: contentMode,
                    onAspectRatioResolved: onAspectRatioResolved
                )
            }
        }
    }

    private var thumbnailURL: URL? {
        URL(string: image.lowUrl.isEmpty ? image.url : image.lowUrl)
    }

    private var originalURL: URL? {
        URL(string: image.url.isEmpty ? image.lowUrl : image.url)
    }

    /// 动图必须读取原文件；服务端生成的 lowUrl 通常只是静态缩略图。
    private var animatedURL: URL? {
        guard image.isGIF else {
            return nil
        }
        return URL(string: image.url.isEmpty ? image.lowUrl : image.url)
    }

}

#endif
