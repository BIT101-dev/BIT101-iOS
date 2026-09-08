//
//  PaperCommentViews.swift
//  BIT101-iOS
//
//  Split from PaperRootView.swift.
//

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
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.container) {
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
            case let .failed(message):
                AppFailureState(
                    title: "加载评论失败",
                    systemImage: "text.bubble",
                    message: message,
                    onRetry: onRetry
                )
            case .loaded:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppDesignSystem.Spacing.section)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: 0) {
                                PaperCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment
                                )

                                if index != comments.count - 1 {
                                    Divider()
                                        .padding(.leading, AppDesignSystem.Comment.layout.dividerLeading)
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
            default:
                EmptyView()
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
                imageURL: comment.user.avatar.preferredRemoteURL,
                size: isSubComment
                    ? AppDesignSystem.Size.control.compact
                    : AppDesignSystem.Comment.layout.avatarSize
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.user.nickname,
                isSubComment: isSubComment,
                timeText: AppDateText.timestampText(from: comment.updateTime),
                onOpenProfile: nil
            )

            if !comment.replyObj.isEmpty, comment.replyUser.id > 0 {
                Text("回复 @\(comment.replyUser.nickname)：")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(comment.text)
                .font(isSubComment ? .subheadline : .body)
                .foregroundStyle(.primary)
                .lineSpacing(3)
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
