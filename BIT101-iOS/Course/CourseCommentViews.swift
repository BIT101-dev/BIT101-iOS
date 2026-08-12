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
        VStack(alignment: .leading, spacing: 14) {
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
                    .padding(.vertical, 20)

            case let .failed(message) where comments.isEmpty:
                ContentUnavailableView {
                    Label("加载评论失败", systemImage: "bubble.right.fill")
                } description: {
                    Text(message)
                }

            default:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
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
                                        .padding(.leading, 46)
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
                            .padding(.vertical, 12)
                        }
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            CourseCommentBubble(
                comment: comment,
                isSubComment: false,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(CourseCommentReplyTarget(mainComment: comment, targetComment: comment))
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
                            CourseCommentBubble(
                                comment: subComment,
                                isSubComment: true,
                                isLiking: likingCommentIDs.contains(subComment.id),
                                onReply: {
                                    onReply(CourseCommentReplyTarget(mainComment: comment, targetComment: subComment))
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
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
                .padding(.leading, 42)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct CourseCommentBubble: View {
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
                        CourseCommentAvatarView(
                            imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl),
                            size: isSubComment ? 28 : 34
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    CourseCommentAvatarView(
                        imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl),
                        size: isSubComment ? 28 : 34
                    )
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

                if comment.rate > 0 {
                    Label(CourseRatingText.text(from: comment.rate), systemImage: "star.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }

                commentText

                if !comment.images.isEmpty {
                    CourseCommentImagesView(images: comment.images, onOpenImage: onOpenImage)
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
                        .foregroundStyle(comment.like ? Color.orange : Color.secondary)
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
    private var commentText: some View {
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

    private func relativeTimeText(_ string: String) -> String {
        CourseCommentDateDecoder.relativeText(from: string, fallback: "未知时间")
    }
}

private struct CourseCommentAvatarView: View {
    let imageURL: URL?
    let size: CGFloat

    var body: some View {
        CachedRemoteImage(url: imageURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(Color.orange.opacity(0.15))
                Image(systemName: "person.fill")
                    .foregroundStyle(.orange)
                    .font(.caption.weight(.bold))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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
                Section("内容") {
                    TextField(target.placeholder, text: $text, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)

                    Toggle("匿名评论", isOn: $anonymous)
                }

                if supportsCourseRating {
                    Section("评分") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                ForEach(1 ... 5, id: \.self) { value in
                                    ZStack {
                                        Image(systemName: starSymbol(for: value))
                                            .font(.title3)
                                            .foregroundStyle(Color.orange)
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
                                    .foregroundStyle(rating == 0 ? Color.secondary : Color.orange)
                            }

                            Text("支持半星；点左半颗记 0.5 分，点右半颗记整颗星。提交带评分的课程评论后，当前账号不能重复评价。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "发送中" : "发送") {
                        onSubmit(text, anonymous, rawRating)
                    }
                    .disabled(isSubmitting)
                }
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
