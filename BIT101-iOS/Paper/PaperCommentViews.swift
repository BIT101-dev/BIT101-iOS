//
//  PaperCommentViews.swift
//  BIT101-iOS
import SwiftUI
import Network
import Combine

struct PaperCommentsSection: View {
    let comments: [GalleryComment]
    let totalCommentCount: Int
    let status: GalleryFeedStatus
    let isLoadingMore: Bool
    let selectedOrder: GalleryCommentOrder
    let likingCommentIDs: Set<Int>
    let onSelectOrder: (GalleryCommentOrder) -> Void
    let onReply: (PaperCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onLoadMore: (GalleryComment?) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            AppCommentSectionHeader(count: totalCommentCount) {
                Picker("排序", selection: Binding(get: { selectedOrder }, set: onSelectOrder)) {
                    ForEach(GalleryCommentOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .appSelectionFeedback(trigger: selectedOrder)
                .pickerStyle(.menu)
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                AppInlineLoadingState("正在加载评论")
            case let .failed(message) where comments.isEmpty:
                AppFailureState(
                    title: "加载评论失败",
                    systemImage: "text.bubble",
                    message: message,
                    onRetry: onRetry
                )
            default:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(AppDesignSystem.Typography.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppDesignSystem.Spacing.section)
                } else {
                    LazyVStack(spacing: AppDesignSystem.Spacing.none) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: AppDesignSystem.Spacing.none) {
                                PaperCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment
                                )

                                if index != comments.count - 1 {
                                    Divider()
                                        .padding(.leading, AppDesignSystem.Comment.replyInset)
                                }
                            }
                            .onAppear {
                                onLoadMore(comment)
                            }
                        }

                        if isLoadingMore {
                            AppInlineLoadingState()
                        }
                    }
                    .appCommentSectionStyle()
                }
            }
        }
    }
}

/// 文章模块使用的网络可达性观察器。
///
/// 用于文章模块失败后的自动重试，网络可达性状态限定在文章模块。
@MainActor
final class PaperNetworkObserver: ObservableObject {
    @Published private(set) var isReachable = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "BIT101.PaperNetworkObserver")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isReachable = isReachable
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

struct PaperCommentReplyTarget {
    let mainComment: GalleryComment
    let targetComment: GalleryComment
}

private struct PaperCommentRow: View {
    let comment: GalleryComment
    let likingCommentIDs: Set<Int>
    let onReply: (PaperCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void

    var body: some View {
        AppCommentThread(comment: comment, subcomments: comment.sub) { comment, isSubComment in
            commentBubble(comment, isSubComment: isSubComment)
        }
    }

    @ViewBuilder
    private func commentBubble(_ comment: GalleryComment, isSubComment: Bool) -> some View {
        AppCommentBubble {
            AppAvatarView(
                imageURL: comment.anonymous ? nil : comment.user.avatar.preferredRemoteURL,
                size: isSubComment
                    ? AppDesignSystem.Size.Control.compact
                    : AppDesignSystem.Size.Avatar.standard
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.anonymous ? "匿名用户" : comment.user.nickname,
                isSubComment: isSubComment,
                timeText: AppDateText.timestampText(from: comment.updateTime),
                onOpenProfile: nil
            )

            if !comment.replyObj.isEmpty, comment.replyUser.id > 0 {
                Text("回复 @\(comment.replyUser.nickname)：")
                    .font(AppDesignSystem.Typography.captionEmphasis)
                    .foregroundStyle(.secondary)
            }

            Text(comment.text)
                .font(isSubComment
                    ? AppDesignSystem.Typography.subheadline
                    : AppDesignSystem.Typography.body)
                .foregroundStyle(.primary)
                .lineSpacing(AppDesignSystem.Spacing.tiny)
                .frame(maxWidth: .infinity, alignment: .leading)

            AppCommentActionBar(
                likeCount: comment.likeNum,
                isLiked: comment.like,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(.init(mainComment: self.comment, targetComment: comment))
                },
                onLike: {
                    onLikeComment(comment)
                }
            )
        }
    }
}
