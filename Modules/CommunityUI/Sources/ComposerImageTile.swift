#if os(iOS)
import CommunityCore
import DesignSystemKit
import MediaKit
import Foundation
import SwiftUI
import UIKit

/// 发帖页图片缩略图条目。
///
/// 图片状态对应以下交互：
/// - 上传中显示进度
/// - 失败时允许重试
/// - 每种状态都提供删除操作
public struct ComposerImageTile: View {
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    private struct ThumbnailIdentity: Equatable {
        let data: Data
        let scale: CGFloat
    }
    let draft: ComposerImageDraft
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onOpen: (() -> Void)?
    let previewAccessibilityLabel: String
    let removeAccessibilityLabel: String
    let showsPreparedSuccessIndicator: Bool

    public init(
        draft: ComposerImageDraft,
        onRetry: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onOpen: (() -> Void)? = nil,
        showsPreparedSuccessIndicator: Bool = true,
        previewAccessibilityLabel: String = "预览所选图片",
        removeAccessibilityLabel: String = "移除图片"
    ) {
        self.draft = draft
        self.onRetry = onRetry
        self.onRemove = onRemove
        self.onOpen = onOpen
        self.showsPreparedSuccessIndicator = showsPreparedSuccessIndicator
        self.previewAccessibilityLabel = previewAccessibilityLabel
        self.removeAccessibilityLabel = removeAccessibilityLabel
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let onOpen {
                    Button(action: onOpen) { thumbnailContent }
                        .buttonStyle(.plain)
                        .accessibilityLabel(previewAccessibilityLabel)
                        .accessibilityIdentifier("composer.image.preview.\(draft.id)")
                } else { thumbnailContent }
            }
            .overlay(alignment: .bottom) {
                overlayContent
            }

            AppComposerImageRemoveButton(accessibilityLabel: removeAccessibilityLabel, onRemove: onRemove)
        }
        .frame(width: AppDesignSystem.Size.Media.draft, height: AppDesignSystem.Size.Media.draft)
        .task(id: ThumbnailIdentity(data: draft.previewData, scale: displayScale)) {
            let prepared = await Self.prepareThumbnail(draft.previewData, pointSize: AppDesignSystem.Size.Media.draft, scale: displayScale)
            guard !Task.isCancelled else { return }
            thumbnail = prepared
        }
    }

    private var thumbnailContent: some View {
        ZStack {
            AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card)
                .fill(AppDesignSystem.Palette.Background.secondaryGrouped)

            if let image = thumbnail {
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
    }

    @concurrent
    private nonisolated static func prepareThumbnail(_ data: Data, pointSize: CGFloat, scale: CGFloat) async -> UIImage? {
        BoundedStillImageDecoder.image(from: data, pointSize: pointSize, displayScale: scale)
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
#endif
