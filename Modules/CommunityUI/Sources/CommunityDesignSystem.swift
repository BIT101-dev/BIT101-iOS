import CommunityCore
import Foundation

#if os(iOS)
import DesignSystemKit
import SwiftUI

/// 话题和文章共用评论排序入口及全部排序选项。
public struct CommunityCommentSortPicker: View {
    @Binding private var order: CommunityCommentOrder

    public init(order: Binding<CommunityCommentOrder>) {
        _order = order
    }

    public var body: some View {
        Picker("排序", selection: $order) {
            ForEach(CommunityCommentOrder.allCases) { order in
                Text(order.title).tag(order)
            }
        }
        .appSelectionFeedback(trigger: order)
        .pickerStyle(.menu)
    }
}

extension AppDesignSystem {
    public enum Community {
        public static let thumbnailPortraitAspectRatio = 1 / CGFloat(2).squareRoot()
        public static let thumbnailLandscapeAspectRatio = CGFloat(2).squareRoot()
        public static let identitySurfaceOpacity = AppDesignSystem.Opacity.subtle
    }
}

#endif

#if os(iOS)
import ImageIO
import UIKit

/// 发帖页图片缩略图条目。
///
/// 图片状态对应以下交互：
/// - 上传中显示进度
/// - 失败时允许重试
/// - 每种状态都提供删除操作
public struct ComposerImageTile: View {
    let draft: ComposerImageDraft
    let onRetry: () -> Void
    let onRemove: () -> Void
    let showsPreparedSuccessIndicator: Bool

    public init(
        draft: ComposerImageDraft,
        onRetry: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        showsPreparedSuccessIndicator: Bool = true
    ) {
        self.draft = draft
        self.onRetry = onRetry
        self.onRemove = onRemove
        self.showsPreparedSuccessIndicator = showsPreparedSuccessIndicator
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card)
                    .fill(AppDesignSystem.Palette.Background.secondaryGrouped)

                if let image = UIImage(data: draft.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(AppDesignSystem.Typography.title)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }
            }
            .frame(width: AppDesignSystem.Size.Media.draft, height: AppDesignSystem.Size.Media.draft)
            .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
            .overlay(alignment: .bottom) {
                overlayContent
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(AppDesignSystem.Palette.Media.foreground, AppDesignSystem.Palette.Media.controlOverlay)
            }
            .padding(AppDesignSystem.Spacing.tiny)
            .buttonStyle(.plain)
            .accessibilityLabel("移除图片")
        }
        .frame(width: AppDesignSystem.Size.Media.draft, height: AppDesignSystem.Size.Media.draft)
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch draft.status {
        case .uploading:
            ZStack {
                Rectangle()
                    .fill(AppDesignSystem.Palette.Media.overlay)
                ProgressView()
                    .tint(.white)
            }
            .frame(height: AppDesignSystem.Size.Control.compact)
        case .compressing:
            ZStack {
                Rectangle()
                    .fill(AppDesignSystem.Palette.Media.overlay)
                Text("\(draft.progress)%")
                    .font(AppDesignSystem.Typography.captionEmphasis)
                    .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
            }
            .frame(height: AppDesignSystem.Size.Control.compact)
        case .prepared:
            if showsPreparedSuccessIndicator {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
                    .padding(AppDesignSystem.Spacing.tiny)
                    .background(AppDesignSystem.Palette.Media.overlaySoft, in: Circle())
            }
        case .uploaded:
            HStack(spacing: AppDesignSystem.Spacing.tiny) {
                Image(systemName: "checkmark.circle.fill")
                Text("已上传")
            }
            .font(AppDesignSystem.Typography.captionEmphasis)
            .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppDesignSystem.Spacing.tiny)
            .background(AppDesignSystem.Palette.Media.overlaySoft)
        case .failed:
            Button(action: onRetry) {
                HStack(spacing: AppDesignSystem.Spacing.tiny) {
                    Image(systemName: "arrow.clockwise")
                    Text("重试")
                }
                .font(AppDesignSystem.Typography.captionEmphasis)
                .foregroundStyle(AppDesignSystem.Palette.Media.foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppDesignSystem.Spacing.tiny)
                .background(AppDesignSystem.Palette.Status.danger.opacity(AppDesignSystem.Opacity.emphasis))
            }
            .buttonStyle(.plain)
        }
    }
}

public enum ComposerDraftImageCompressor {
    public nonisolated static let maximumBytes = ComposerDraftImagePolicy.maximumBytes

    public nonisolated static func compress(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1600
                  ] as CFDictionary
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var best = render(image: image, maxDimension: 1600, quality: 0.68)
        if best.count <= maximumBytes { return best }

        for quality in [0.48, 0.32, 0.2] {
            best = render(image: image, maxDimension: 1600, quality: quality)
            if best.count <= maximumBytes { return best }
        }

        for dimension in [1200, 900, 700, 512, 384, 256] {
            best = render(image: image, maxDimension: CGFloat(dimension), quality: 0.5)
            if best.count <= maximumBytes { return best }
        }
        guard best.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return best
    }

    private nonisolated static func render(
        image: CGImage,
        maxDimension: CGFloat,
        quality: CGFloat
    ) -> Data {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = CGSize(
            width: max(1, width * scale),
            height: max(1, height * scale)
        )
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: quality) { context in
            context.cgContext.interpolationQuality = .medium
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}


#endif
