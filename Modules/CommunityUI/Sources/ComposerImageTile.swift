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
        LocalImageTile(data: draft.previewData, identifier: "composer.image.preview.\(draft.id)",
            onOpen: onOpen, onRemove: onRemove, previewLabel: previewAccessibilityLabel, removeLabel: removeAccessibilityLabel) {
            overlayContent
        }
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
