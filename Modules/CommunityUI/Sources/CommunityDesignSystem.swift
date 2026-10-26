import CommunityCore
import TransportCore
import Foundation

#if os(iOS)
import DesignSystemKit
import SwiftUI

extension View {
    public func communityReadRecovery(networkPath: NetworkPathState, isEnabled: Bool = true,
        retry: @escaping @MainActor () async -> Void) -> some View {
        modifier(CommunityReadRecoveryModifier(networkPath: networkPath, isEnabled: isEnabled, retry: retry))
    }
}

private struct CommunityReadRecoveryModifier: ViewModifier {
    let networkPath: NetworkPathState
    let isEnabled: Bool
    let retry: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var hasAppeared = false
    @State private var recoveryTask: Task<Void, Never>?
    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                if hasAppeared { recover() }
                hasAppeared = true
            }
            .onDisappear { isVisible = false; recoveryTask?.cancel(); recoveryTask = nil }
            .onChange(of: networkPath.snapshot.status) { recover() }
            .onChange(of: scenePhase) { recover() }
            .onChange(of: isEnabled) { recover() }
    }
    private func recover() {
        recoveryTask?.cancel()
        recoveryTask = nil
        guard isVisible, isEnabled, scenePhase == .active, networkPath.snapshot.status == .connected else { return }
        recoveryTask = Task { await retry() }
    }
}

public struct CommunityIdentityBadge: View {
    private let identity: CommunityIdentity
    public init(_ identity: CommunityIdentity) { self.identity = identity }

    public var body: some View {
        if !identity.text.isEmpty {
            let color = Color(hex: identity.color) ?? AppDesignSystem.Palette.Accent.primary
            Text(identity.text)
                .font(AppDesignSystem.Typography.captionEmphasis)
                .padding(.horizontal, AppDesignSystem.Spacing.tiny)
                .padding(.vertical, AppDesignSystem.Spacing.micro)
                .background(color.opacity(AppDesignSystem.Community.identitySurfaceOpacity), in: Capsule())
                .foregroundStyle(color)
        }
    }
}

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
            .accessibilityIdentifier("ui.community-comment-sort-picker.排序")
    }
}

extension AppDesignSystem {
    public enum Community {
        public static let thumbnailPortraitAspectRatio = 1 / CGFloat(2).squareRoot()
        public static let thumbnailLandscapeAspectRatio = CGFloat(2).squareRoot()
        public static let identitySurfaceOpacity = AppDesignSystem.Opacity.subtle
    }
}

public struct CommunityResultsContext: View {
    private let summary: String?
    public init(_ summary: String?) { self.summary = summary }

    public var body: some View {
        if let summary {
            Text("当前显示：\(summary)")
                .font(AppDesignSystem.Typography.caption)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppDesignSystem.Spacing.content)
                .accessibilityIdentifier("community.results-context")
        }
    }
}

/// 评论正文、回复前缀和图片在各资源详情中使用同一呈现。
public struct CommunityCommentBody: View {
    private let comment: CommunityComment
    private let onOpenImage: (Int, [CommunityImage]) -> Void

    public init(comment: CommunityComment, onOpenImage: @escaping (Int, [CommunityImage]) -> Void) {
        self.comment = comment
        self.onOpenImage = onOpenImage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            CommunityLinkedText(comment.text, prefix: replyPrefix)
                .font(AppDesignSystem.Typography.body)
                .lineSpacing(AppDesignSystem.Comment.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !comment.images.isEmpty {
                CommunityPosterImagesView(images: comment.images, onOpenImage: onOpenImage)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var replyPrefix: Text {
        if !comment.replyObj.isEmpty, comment.replyUser.id > 0, !comment.replyUser.nickname.isEmpty {
            Text("回复 @\(comment.replyUser.nickname)：").foregroundStyle(AppDesignSystem.Foreground.secondary)
        } else { Text("") }
    }
}
#endif
