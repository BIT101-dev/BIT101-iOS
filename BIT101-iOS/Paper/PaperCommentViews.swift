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
        VStack(alignment: .leading, spacing: AppDesignSystem.Comment.sectionSpacing) {
            HStack {
                Text("评论")
                    .font(.headline)
                Text("\(totalCommentCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

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
                ProgressView("正在加载评论")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppDesignSystem.Comment.progressVerticalPadding)
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
                        .padding(.vertical, AppDesignSystem.Comment.emptyVerticalPadding)
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
                                        .padding(.leading, AppDesignSystem.Comment.dividerLeading)
                                }
                            }
                            .onAppear {
                                onLoadMore(comment)
                            }
                        }

                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, AppDesignSystem.Spacing.content)
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

/// 文章模块的轻量网络可达性观察器。
///
/// 这里只服务“失败后自动再试”的体验兜底，不承担全局联网状态管理。
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
        AppCommentRowContainer {
            commentBubble(comment, isSubComment: false)

            if !comment.sub.isEmpty {
                VStack(spacing: 0) {
                    ForEach(comment.sub) { subComment in
                        VStack(spacing: 0) {
                            commentBubble(subComment, isSubComment: true)

                            if subComment.id != comment.sub.last?.id {
                                Divider()
                                    .padding(.leading, AppDesignSystem.Comment.subCommentIndent)
                            }
                        }
                    }
                }
                .padding(.leading, AppDesignSystem.Comment.subCommentIndent)
                .padding(.top, AppDesignSystem.Comment.subCommentTopPadding)
            }
        }
    }

    @ViewBuilder
    private func commentBubble(_ comment: GalleryComment, isSubComment: Bool) -> some View {
        AppCommentBubble {
            AppCommentAvatarView(
                imageURL: comment.user.avatar.preferredRemoteURL,
                size: isSubComment
                    ? AppDesignSystem.Comment.subCommentAvatarSize
                    : AppDesignSystem.Comment.avatarSize
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.user.nickname,
                isSubComment: isSubComment,
                timeText: PaperDateText.timestampString(from: comment.updateTime),
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
