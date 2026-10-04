#if os(iOS)
import CommunityUI
import MediaKit
import CommunityCore
import DesignSystemKit
//
//  PaperCommentViews.swift
//  BIT101-iOS
import SwiftUI

struct PaperCommentsSection: View {
    let comments: [CommunityComment]
    let totalCommentCount: Int
    let status: CommunityLoadStatus
    let isLoadingMore: Bool
    let selectedOrder: CommunityCommentOrder
    let likingCommentIDs: Set<Int>
    let onSelectOrder: @MainActor (CommunityCommentOrder) -> Void
    let onReply: (PaperCommentReplyTarget) -> Void
    let onLikeComment: (CommunityComment) -> Void
    let onLoadMore: (CommunityComment?) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            AppCommentSectionHeader(count: totalCommentCount) {
                CommunityCommentSortPicker(order: Binding(get: { selectedOrder }, set: onSelectOrder))
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
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
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

struct PaperCommentReplyTarget {
    let mainComment: CommunityComment
    let targetComment: CommunityComment
}

private struct PaperCommentRow: View {
    let comment: CommunityComment
    let likingCommentIDs: Set<Int>
    let onReply: (PaperCommentReplyTarget) -> Void
    let onLikeComment: (CommunityComment) -> Void

    var body: some View {
        AppCommentThread(comment: comment, subcomments: comment.sub) { comment, isSubComment in
            commentBubble(comment, isSubComment: isSubComment)
        }
    }

    @ViewBuilder
    private func commentBubble(_ comment: CommunityComment, isSubComment: Bool) -> some View {
        AppCommentBubble {
            AppAvatarView(
                imageURL: comment.anonymous ? nil : comment.user.avatar.preferredRemoteURL,
                size: isSubComment
                    ? AppDesignSystem.Size.Control.compact
                    : AppDesignSystem.Size.Avatar.standard,
                anonymous: comment.anonymous
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.anonymous ? AppUserPresentation.anonymousName : comment.user.nickname,
                isSubComment: isSubComment,
                timeText: AppDateText.timestampText(from: comment.updateTime),
                onOpenProfile: nil
            )

            if !comment.replyObj.isEmpty, comment.replyUser.id > 0 {
                Text("回复 @\(comment.replyUser.nickname)：")
                    .font(AppDesignSystem.Typography.captionEmphasis)
                    .foregroundStyle(AppDesignSystem.Foreground.secondary)
            }

            Text(comment.text)
                .font(isSubComment
                    ? AppDesignSystem.Typography.subheadline
                    : AppDesignSystem.Typography.body)
                .foregroundStyle(AppDesignSystem.Foreground.primary)
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

#endif
