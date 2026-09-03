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
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, AppDesignSystem.Comment.progressVerticalPadding)
            case let .failed(message) where comments.isEmpty:
                ContentUnavailableView {
                    Label("加载评论失败", systemImage: "bubble.right.fill")
                } description: {
                    Text(message)
                } actions: {
                    DiagnosticRecoveryActions(title: "加载评论失败", message: message)
                }
            default:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, AppDesignSystem.Comment.emptyVerticalPadding)
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
        VStack(alignment: .leading, spacing: 10) {
            GalleryCommentBubble(
                comment: comment,
                isSubComment: false,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(GalleryCommentReplyTarget(mainComment: comment, targetComment: comment))
                },
                onLike: {
                    onLikeComment(comment)
                },
                onOpenImage: onOpenImage,
                onOpenUser: {
                    onOpenUser(comment.user)
                }
            )

            if !comment.sub.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(comment.sub.enumerated()), id: \.element.id) { index, subComment in
                        VStack(spacing: 0) {
                            GalleryCommentBubble(
                                comment: subComment,
                                isSubComment: true,
                                isLiking: likingCommentIDs.contains(subComment.id),
                                onReply: {
                                    onReply(GalleryCommentReplyTarget(mainComment: comment, targetComment: subComment))
                                },
                                onLike: {
                                    onLikeComment(subComment)
                                },
                                onOpenImage: onOpenImage,
                                onOpenUser: {
                                    onOpenUser(subComment.user)
                                }
                            )

                            if index != comment.sub.count - 1 {
                                Divider()
                                .padding(.leading, AppDesignSystem.Comment.subCommentIndent)
                            }
                        }
                    }
                }
                .padding(.leading, AppDesignSystem.Comment.subCommentIndent)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, AppDesignSystem.Comment.rowHorizontalPadding)
        .padding(.vertical, AppDesignSystem.Comment.rowVerticalPadding)
    }
}

/// 评论内容气泡。
///
/// 一个评论气泡内部同时包含：
/// - 头像/昵称
/// - 时间
/// - 正文
/// - 图片
/// - 点赞按钮
/// - 点击整块回复
private struct GalleryCommentBubble: View {
    let comment: GalleryComment
    let isSubComment: Bool
    let isLiking: Bool
    let onReply: () -> Void
    let onLike: () -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if canOpenUserProfile {
                    Button(action: onOpenUser) {
                        GalleryAvatarView(imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl))
                            .frame(width: isSubComment ? 28 : 34, height: isSubComment ? 28 : 34)
                    }
                    .buttonStyle(.plain)
                } else {
                    GalleryAvatarView(imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl))
                        .frame(width: isSubComment ? 28 : 34, height: isSubComment ? 28 : 34)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if canOpenUserProfile {
                            Button(action: onOpenUser) {
                                Text(comment.user.nickname)
                                    .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(comment.user.nickname)
                                .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Text(relativeTimeText(comment.createTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                commentText

                if !comment.images.isEmpty {
                    GalleryPosterImagesView(images: comment.images, onOpenImage: onOpenImage)
                }

                HStack(spacing: 10) {
                    Button(action: onReply) {
                        Label("回复", systemImage: "arrowshape.turn.up.left")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button(action: onLike) {
                        Label {
                            Text("\(comment.likeNum)")
                                .font(.caption)
                        } icon: {
                            if isLiking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: comment.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }
                        }
                        .foregroundStyle(comment.like ? AppDesignSystem.Palette.highlight : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    private var canOpenUserProfile: Bool {
        !comment.anonymous && comment.user.id > 0
    }

    @ViewBuilder
    /// 处理“回复某人”的前缀文本拼接。
    private var commentText: some View {
        if comment.replyUser.id != 0, !comment.replyUser.nickname.isEmpty {
            (
                Text("回复 @\(comment.replyUser.nickname)：")
                    .foregroundStyle(.secondary) +
                    Text(galleryLinkifiedText(comment.text))
            )
            .font(.subheadline)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(galleryLinkifiedText(comment.text))
                .font(.subheadline)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知时间")
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
