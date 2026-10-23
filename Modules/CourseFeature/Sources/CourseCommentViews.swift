#if os(iOS)
import CommunityUI
import MediaKit
import CommunityCore
import DesignSystemKit
//
//  CourseCommentViews.swift
//  BIT101-iOS
//

import SwiftUI

struct CourseCommentsSection: View {
    let comments: [CommunityComment]
    let totalCommentCount: Int
    let status: CommunityLoadStatus
    let isLoadingMore: Bool
    let paginationError: String?
    let likingCommentIDs: Set<Int>
    let onReply: (CourseCommentReplyTarget) -> Void
    let onLikeComment: (CommunityComment) -> Void
    let onOpenImage: (Int, [CommunityImage]) -> Void
    let onOpenUser: (CommunityUser) -> Void
    let onLoadMore: (CommunityComment?) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            AppCommentSectionHeader(count: totalCommentCount) { EmptyView() }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                AppInlineLoadingState("正在加载评论")

            case let .failed(message) where comments.isEmpty:
                AppFailureState(
                    title: "加载评论失败",
                    systemImage: "bubble.right.fill",
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
                                CourseCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment,
                                    onOpenImage: onOpenImage,
                                    onOpenUser: onOpenUser
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

                        CommunityPaginationFooter(isLoading: isLoadingMore,
                            errorMessage: paginationError) { onLoadMore(comments.last) }
                    }
                    .appCommentSectionStyle()
                }
            }
        }
    }
}

/// 保存回复所属的主评论和当前目标评论。
struct CourseCommentReplyTarget {
    let mainComment: CommunityComment
    let targetComment: CommunityComment
}

private struct CourseCommentRow: View {
    let comment: CommunityComment
    let likingCommentIDs: Set<Int>
    let onReply: (CourseCommentReplyTarget) -> Void
    let onLikeComment: (CommunityComment) -> Void
    let onOpenImage: (Int, [CommunityImage]) -> Void
    let onOpenUser: (CommunityUser) -> Void

    var body: some View {
        AppCommentThread(comment: comment, subcomments: comment.flattenedReplies) { comment, isSubComment in
            commentBubble(comment, isSubComment: isSubComment)
        }
    }
    @ViewBuilder
    private func commentBubble(_ comment: CommunityComment, isSubComment: Bool) -> some View {
        AppCommentBubble {
            AppAvatarView(
                imageURL: comment.anonymous
                    ? nil
                    : comment.user.avatar.thumbnailURL,
                fallbackImageURL: comment.anonymous ? nil : comment.user.avatar.originalURL,
                size: isSubComment
                    ? AppDesignSystem.Size.Control.compact
                    : AppDesignSystem.Size.Avatar.standard,
                tint: AppDesignSystem.Course.accent,
                anonymous: comment.anonymous
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.anonymous ? AppUserPresentation.anonymousName : comment.user.nickname,
                isSubComment: isSubComment,
                timeText: AppDateText.relativeText(from: comment.createTime, fallback: "未知时间"),
                onOpenProfile: canOpenUserProfile(comment) ? { onOpenUser(comment.user) } : nil
            )

            if comment.rate > 0 {
                Label(CourseRatingText.text(from: comment.rate), systemImage: "star.fill")
                    .font(AppDesignSystem.Typography.captionEmphasis)
                    .foregroundStyle(AppDesignSystem.Course.accent)
            }

            CommunityCommentBody(comment: comment, onOpenImage: onOpenImage)

            AppCommentActionBar(
                likeCount: comment.likeNum,
                isLiked: comment.like,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(CourseCommentReplyTarget(mainComment: self.comment, targetComment: comment))
                },
                onLike: {
                    onLikeComment(comment)
                }
            )
        }
    }

    private func canOpenUserProfile(_ comment: CommunityComment) -> Bool {
        !comment.anonymous && comment.user.id > 0
    }


}

struct CourseCommentComposerSheet: View {
    let target: CommunityCommentComposerTarget
    let isSubmitting: Bool
    let review: CommunityCommentReviewActions
    let onSubmit: (String, Bool, Int?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false
    @State private var isSubmissionRequested = false
    /// 评分状态使用后端 10 分制整数；奇数值表示半星。
    @State private var rating = 0
    private var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || anonymous || rating > 0
    }

    var body: some View {
        let submission = CommunityCommentSubmission(objectID: target.objectID, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            anonymous: anonymous, replyObjectID: target.replyObjectID, replyUID: target.replyUID, rate: rawRating)
        NavigationStack {
            Form {
                AppCommentComposerContentSection(anonymous: $anonymous) {
                    TextField("", text: $text, prompt: AppInputPrompt.text(target.placeholder), axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                        .accessibilityIdentifier("ui.course-comment-composer-sheet.input")
                }

                CommunityCommentReviewSection(submission: submission, actions: review) { isSubmissionRequested = true }
                if supportsCourseRating {
                    Section("评分") {
                        Stepper(value: $rating, in: 0...10) {
                            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                                HStack(spacing: AppDesignSystem.Spacing.tiny) {
                                    ForEach(1...5, id: \.self) { value in
                                        Image(systemName: starSymbol(for: value))
                                            .font(AppDesignSystem.Typography.title)
                                            .foregroundStyle(AppDesignSystem.Course.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                                Text(rating == 0 ? "请选择评分" : CourseRatingText.text(from: rating, empty: "请选择评分"))
                                    .font(AppDesignSystem.Typography.bodyEmphasis)
                                    .foregroundStyle(rating == 0 ? AppDesignSystem.Foreground.secondaryColor : AppDesignSystem.Course.accent)
                            }
                        }
                        .frame(minHeight: AppDesignSystem.Size.Control.touchTarget)
                        .accessibilityLabel("课程评分")
                        .accessibilityValue(rating == 0 ? "请选择评分" : CourseRatingText.text(from: rating, empty: "请选择评分"))
                        .accessibilityIdentifier("ui.course-comment-composer-sheet.rating")
                    }
                }
            }
            .disabled(isSubmitting || isSubmissionRequested)
            .appSelectionFeedback(trigger: rating)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: isSubmissionRequested) {
                guard isSubmissionRequested else { return }
                let submitted = await onSubmit(text, anonymous, rawRating)
                guard !Task.isCancelled else { return }
                isSubmissionRequested = false
                if submitted { dismiss() }
            }
            .toolbar {
                AppComposerToolbar(
                    isSubmitting: isSubmitting || isSubmissionRequested,
                    submitTitle: "发送",
                    isSubmitDisabled: supportsCourseRating && rating == 0,
                    confirmDiscard: hasDraftContent,
                    onCancel: {
                        dismiss()
                    },
                    onSubmit: {
                        isSubmissionRequested = true
                    }
                )
            }
        }
        .interactiveDismissDisabled(hasDraftContent || isSubmitting || isSubmissionRequested)
    }

    private var supportsCourseRating: Bool {
        if case .course = target {
            return true
        }
        return false
    }

    private var rawRating: Int? {
        guard supportsCourseRating, rating > 0 else { return nil }
        return rating
    }

    private func starSymbol(for value: Int) -> String {
        let fullStarThreshold = value * 2
        if rating >= fullStarThreshold {
            return "star.fill"
        }
        if rating == fullStarThreshold - 1 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }

}

#endif
