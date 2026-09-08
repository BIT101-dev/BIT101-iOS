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
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Text("评论")
                .font(.headline)

            Text("\(count)")
                .font(.subheadline)
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
            } else {
                nicknameText
            }

            Spacer(minLength: 0)

            Text(timeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var nicknameText: some View {
        Text(nickname)
            .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
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
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Button(action: onReply) {
                Label("回复", systemImage: "arrowshape.turn.up.left")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: onLike) {
                Label {
                    Text("\(likeCount)")
                        .font(.caption)
                } icon: {
                    if isLiking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                }
                .foregroundStyle(isLiked ? AppDesignSystem.Palette.highlight : .secondary)
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
        HStack(alignment: .top, spacing: AppDesignSystem.Spacing.control) {
            avatar

            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tight) {
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
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.control) {
            content
        }
        .padding(AppDesignSystem.Spacing.container)
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
                VStack(spacing: 0) {
                    ForEach(Array(subcomments.enumerated()), id: \.element.id) { index, subcomment in
                        VStack(spacing: 0) {
                            content(subcomment, true)

                            if index != subcomments.count - 1 {
                                Divider()
                                    .padding(.leading, AppDesignSystem.Comment.layout.dividerLeading)
                            }
                        }
                    }
                }
                .padding(.leading, AppDesignSystem.Comment.layout.subCommentIndent)
                .padding(.top, AppDesignSystem.Spacing.tiny)
            }
        }
    }
}
