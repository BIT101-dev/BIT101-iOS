//
//  CourseCommentViews.swift
//  BIT101-iOS
//
//  Split from CourseDetailView.swift.
//

import SwiftUI

struct CourseCommentsSection: View {
    let comments: [GalleryComment]
    let totalCommentCount: Int
    let status: GalleryFeedStatus
    let isLoadingMore: Bool
    let likingCommentIDs: Set<Int>
    let onReply: (CourseCommentReplyTarget) -> Void
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
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                ProgressView("正在加载评论")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, AppDesignSystem.Comment.progressVerticalPadding)

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
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, AppDesignSystem.Comment.emptyVerticalPadding)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: 0) {
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

/// 表示“主评论 + 当前真正回复目标”的成对上下文。
struct CourseCommentReplyTarget {
    let mainComment: GalleryComment
    let targetComment: GalleryComment
}

private struct CourseCommentRow: View {
    let comment: GalleryComment
    let likingCommentIDs: Set<Int>
    let onReply: (CourseCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void

    var body: some View {
        AppCommentRowContainer {
            commentBubble(comment, isSubComment: false)

            if !comment.sub.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(comment.sub.enumerated()), id: \.element.id) { index, subComment in
                        VStack(spacing: 0) {
                            commentBubble(subComment, isSubComment: true)

                            if index != comment.sub.count - 1 {
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
                imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl),
                size: isSubComment
                    ? AppDesignSystem.Comment.subCommentAvatarSize
                    : AppDesignSystem.Comment.avatarSize
            )
        } content: {
            AppCommentIdentityHeader(
                nickname: comment.user.nickname,
                isSubComment: isSubComment,
                timeText: CourseCommentDateDecoder.relativeText(from: comment.createTime, fallback: "未知时间"),
                onOpenProfile: canOpenUserProfile(comment) ? { onOpenUser(comment.user) } : nil
            )

            if comment.rate > 0 {
                Label(CourseRatingText.text(from: comment.rate), systemImage: "star.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppDesignSystem.Palette.highlight)
            }

            commentText(for: comment)

            if !comment.images.isEmpty {
                CourseCommentImagesView(images: comment.images, onOpenImage: onOpenImage)
            }

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

    private func canOpenUserProfile(_ comment: GalleryComment) -> Bool {
        !comment.anonymous && comment.user.id > 0
    }

    @ViewBuilder
    private func commentText(for comment: GalleryComment) -> some View {
        if comment.replyUser.id != 0, !comment.replyUser.nickname.isEmpty {
            (
                Text("回复 @\(comment.replyUser.nickname)：")
                    .foregroundStyle(.secondary) +
                    Text(comment.text)
                    .foregroundStyle(.primary)
            )
            .font(.subheadline)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(comment.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CourseCommentImagesView: View {
    let images: [GalleryImage]
    let onOpenImage: (Int, [GalleryImage]) -> Void

    var body: some View {
        let displayedImages = images.count <= 2 ? images : Array(images.prefix(images.count == 3 ? 3 : 4))

        if displayedImages.count == 1 {
            thumbnailButton(image: displayedImages[0], index: 0, width: 180, maxHeight: 220, aspectRatio: 1)
        } else if displayedImages.count == 2 {
            HStack(spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 150, aspectRatio: 1)
                }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(displayedImages.count, 4)), spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 78, aspectRatio: 1)
                }
            }
        }
    }

    private func thumbnailButton(image: GalleryImage, index: Int, width: CGFloat?, maxHeight: CGFloat?, aspectRatio: CGFloat) -> some View {
        Button {
            onOpenImage(index, images)
        } label: {
            GalleryPosterThumbnail(
                image: image,
                width: width,
                maxHeight: maxHeight,
                aspectRatio: aspectRatio
            )
        }
        .buttonStyle(.plain)
    }
}

/// 课程评论输入抽屉。
///
/// 课程顶层评论支持 0.5 星颗粒度的评分；回复评论时则退化成纯文本回复。
struct CourseCommentComposerSheet: View {
    let target: CourseCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: (String, Bool, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false
    /// 课程评论评分直接保存为后端原始 10 分制整数，便于支持 0.5 星颗粒度。
    @State private var rating = 0

    var body: some View {
        NavigationStack {
            Form {
                AppCommentComposerContentSection(anonymous: $anonymous) {
                    TextField(target.placeholder, text: $text, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                }

                if supportsCourseRating {
                    Section("评分") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                ForEach(1 ... 5, id: \.self) { value in
                                    ZStack {
                                        Image(systemName: starSymbol(for: value))
                                            .font(.title3)
                                            .foregroundStyle(AppDesignSystem.Palette.highlight)
                                            .frame(width: 28, height: 28)

                                        HStack(spacing: 0) {
                                            Button {
                                                setRating(for: value, isHalf: true)
                                            } label: {
                                                Color.clear
                                                    .frame(width: 14, height: 28)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)

                                            Button {
                                                setRating(for: value, isHalf: false)
                                            } label: {
                                                Color.clear
                                                    .frame(width: 14, height: 28)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }

                                Spacer()

                                Text(rating == 0 ? "不评分" : CourseRatingText.text(from: rating, empty: "不评分"))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(rating == 0 ? Color.secondary : AppDesignSystem.Palette.highlight)
                            }

                        }
                    }
                }
            }
            .appSelectionFeedback(trigger: rating)
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
                        onSubmit(text, anonymous, rawRating)
                    }
                )
            }
        }
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

    private func setRating(for value: Int, isHalf: Bool) {
        let nextRating = value * 2 - (isHalf ? 1 : 0)
        rating = rating == nextRating ? 0 : nextRating
    }
}

/// 课程评论时间解析器。
///
/// 评论接口历史上出现过多种日期格式，这里集中兼容，避免视图层自己兜底解析。
private enum CourseCommentDateDecoder {
    private static let formatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
    ]

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter = RelativeDateTimeFormatter()

    static func date(from string: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return iso8601Formatter.date(from: string)
    }

    static func relativeText(from string: String, fallback: String) -> String {
        guard let date = date(from: string) else {
            return fallback
        }

        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter
    }
}
