//
//  GalleryCommentViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

struct GalleryPosterCommentsSection: View {
    let comments: [GalleryComment]
    let totalCommentCount: Int
    let status: GalleryFeedStatus
    let isLoadingMore: Bool
    let selectedOrder: GalleryCommentOrder
    let likingCommentIDs: Set<Int>
    let onSelectOrder: (GalleryCommentOrder) -> Void
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void
    let onLoadMore: (GalleryComment?) -> Void

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
            case let .failed(message) where comments.isEmpty:
                AppFailureState(
                    title: "加载评论失败",
                    systemImage: "bubble.right.fill",
                    message: message
                )
            default:
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
                                GalleryCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment,
                                    onOpenImage: onOpenImage,
                                    onOpenUser: onOpenUser
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
            }
        }
    }
}

/// 评论回复目标。
///
/// `mainComment` 表示发评论接口真正要挂靠的主评论，
/// `targetComment` 表示当前 UI 上用户实际点中的那条评论。
struct GalleryCommentReplyTarget {
    let mainComment: GalleryComment
    let targetComment: GalleryComment
}

/// 单条评论及其子评论预览。
///
/// 主评论和子评论共用同一套气泡视图，只是在这一层决定是否渲染嵌套结构。
private struct GalleryCommentRow: View {
    let comment: GalleryComment
    let likingCommentIDs: Set<Int>
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void

    var body: some View {
        AppCommentThread(comment: comment, subcomments: comment.sub) { comment, isSubComment in
            commentBubble(comment, isSubComment: isSubComment)
        }
    }
    @ViewBuilder
    private func commentBubble(_ comment: GalleryComment, isSubComment: Bool) -> some View {
        AppCommentBubble {
            AppAvatarView(
                imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl),
                size: isSubComment
                    ? AppDesignSystem.Size.control.compact
                    : AppDesignSystem.Comment.layout.avatarSize
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.user.nickname,
                isSubComment: isSubComment,
                timeText: AppDateText.relativeText(from: comment.createTime, fallback: "未知时间"),
                onOpenProfile: canOpenUserProfile(comment) ? { onOpenUser(comment.user) } : nil
            )

            commentText(for: comment)

            if !comment.images.isEmpty {
                GalleryPosterImagesView(images: comment.images, onOpenImage: onOpenImage)
            }

            AppCommentActionBar(
                likeCount: comment.likeNum,
                isLiked: comment.like,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(GalleryCommentReplyTarget(mainComment: self.comment, targetComment: comment))
                },
                onLike: {
                    onLikeComment(comment)
                }
            )
        }
    }

    private func canOpenUserProfile(_ comment: GalleryComment) -> Bool {
        !comment.anonymous && comment.user.id > 0
    }

    @ViewBuilder
    /// 处理“回复某人”的前缀文本拼接。
    private func commentText(for comment: GalleryComment) -> some View {
        if comment.replyUser.id != 0, !comment.replyUser.nickname.isEmpty {
            (
                Text("回复 @\(comment.replyUser.nickname)：")
                    .foregroundStyle(.secondary) +
                    Text(galleryLinkifiedText(comment.text))
            )
            .font(.subheadline)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(galleryLinkifiedText(comment.text))
                .font(.subheadline)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 评论发送弹层。
///
/// 评论输入单独做成 sheet，而不是直接贴在详情页底部，是为了避免和 tab bar、抽屉详情、
/// 键盘安全区互相打架。
struct GalleryCommentComposerSheet: View {
    let target: GalleryCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false

    var body: some View {
        NavigationStack {
            Form {
                AppCommentComposerContentSection(anonymous: $anonymous) {
                    TextField(target.placeholder, text: $text, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppComposerToolbar(
                    isSubmitting: isSubmitting,
                    submitTitle: "发送",
                    onCancel: {
                        dismiss()
                    },
                    onSubmit: {
                        onSubmit(text, anonymous)
                    }
                )
            }
        }
    }
}

/// 搜索页。
///
/// 搜索结果页直接复用 `GalleryFeedView`，只是在顶部额外挂一个搜索栏，
/// 这样搜索结果的分页、详情和看图逻辑都不需要重复实现。
