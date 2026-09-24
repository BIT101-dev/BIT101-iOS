import SwiftUI

/// 课程、话题和文章评论区共用这个标题行。
///
/// 业务传入右侧可选操作；组件保持标题、数量和占位关系完全一致。
struct AppCommentSectionHeader<Trailing: View>: View {
    let count: Int
    private let trailing: Trailing

    init(count: Int, @ViewBuilder trailing: () -> Trailing) {
        self.count = count
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Text("评论")
                .font(AppDesignSystem.Typography.title)

            Text("\(count)")
                .font(AppDesignSystem.Typography.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
            trailing
        }
    }
}

/// 评论区使用这个标题行展示昵称和时间。
struct AppCommentIdentityHeader: View {
    let nickname: String
    let isSubComment: Bool
    let timeText: String
    let onOpenProfile: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesignSystem.Spacing.regular) {
            if let onOpenProfile {
                Button(action: onOpenProfile) {
                    nicknameText
                }
                .buttonStyle(.plain)
                .frame(minHeight: AppDesignSystem.Size.Control.touchTarget)
            } else {
                nicknameText
            }

            Spacer(minLength: 0)

            Text(timeText)
                .font(AppDesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var nicknameText: some View {
        Text(nickname)
            .font(isSubComment
                ? AppDesignSystem.Typography.subheadlineEmphasis
                : AppDesignSystem.Typography.title)
            .lineLimit(1)
    }
}

/// 评论区使用这个操作行展示回复和点赞操作。
struct AppCommentActionBar: View {
    let likeCount: Int
    let isLiked: Bool
    let isLiking: Bool
    let onReply: () -> Void
    let onLike: () -> Void

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Button(action: onReply) {
                Label("回复", systemImage: "arrowshape.turn.up.left")
                    .font(AppDesignSystem.Typography.captionEmphasis)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: AppDesignSystem.Size.Control.touchTarget)
            }
            .buttonStyle(.plain)

            Button(action: onLike) {
                Label {
                    Text("\(likeCount)")
                        .font(AppDesignSystem.Typography.caption)
                } icon: {
                    if isLiking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                }
                .foregroundStyle(isLiked ? AppDesignSystem.Palette.highlight : .secondary)
                .frame(minHeight: AppDesignSystem.Size.Control.touchTarget)
            }
            .buttonStyle(.plain)
            .disabled(isLiking)

            Spacer(minLength: 0)
        }
        .padding(.top, AppDesignSystem.Spacing.micro)
    }
}

/// 评论气泡使用统一的头像和内容列间距。
struct AppCommentBubble<Avatar: View, Content: View>: View {
    private let avatar: Avatar
    private let content: Content

    init(
        @ViewBuilder avatar: () -> Avatar,
        @ViewBuilder content: () -> Content
    ) {
        self.avatar = avatar()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignSystem.Spacing.regular) {
            avatar

            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                content
            }
        }
    }
}

/// 评论主项使用统一的内容间距和内边距。
struct AppCommentRowContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
            content
        }
        .padding(AppDesignSystem.Spacing.content)
    }
}

/// 评论主项和嵌套回复使用这个线程结构。
///
/// 课程、话题和文章提供单条气泡内容；组件统一维护回复缩进、分隔线和上下层级。
struct AppCommentThread<Comment: Identifiable, Content: View>: View {
    let comment: Comment
    let subcomments: [Comment]
    private let content: (Comment, Bool) -> Content

    init(
        comment: Comment,
        subcomments: [Comment],
        @ViewBuilder content: @escaping (Comment, Bool) -> Content
    ) {
        self.comment = comment
        self.subcomments = subcomments
        self.content = content
    }

    var body: some View {
        AppCommentRowContainer {
            content(comment, false)

            if !subcomments.isEmpty {
                VStack(spacing: AppDesignSystem.Spacing.none) {
                    ForEach(Array(subcomments.enumerated()), id: \.element.id) { index, subcomment in
                        VStack(spacing: AppDesignSystem.Spacing.none) {
                            content(subcomment, true)

                            if index != subcomments.count - 1 {
                                Divider()
                                    .padding(.leading, AppDesignSystem.Comment.replyInset)
                            }
                        }
                    }
                }
                .padding(.leading, AppDesignSystem.Comment.replyInset)
                .padding(.top, AppDesignSystem.Spacing.tiny)
            }
        }
    }
}
