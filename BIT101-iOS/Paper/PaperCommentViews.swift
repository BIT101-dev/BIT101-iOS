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
        VStack(alignment: .leading, spacing: 14) {
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
                .pickerStyle(.menu)
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                ProgressView("正在加载评论")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            case let .failed(message):
                PaperEmptyState(
                    systemImage: "text.bubble",
                    title: "加载评论失败",
                    message: message,
                    onRetry: onRetry
                )
            case .loaded:
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
                                PaperCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment
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
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    }
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
        VStack(alignment: .leading, spacing: 12) {
            PaperCommentBubble(
                comment: comment,
                isSubComment: false,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(.init(mainComment: comment, targetComment: comment))
                },
                onLikeComment: {
                    onLikeComment(comment)
                }
            )

            if !comment.sub.isEmpty {
                VStack(spacing: 0) {
                    ForEach(comment.sub) { subComment in
                        VStack(spacing: 0) {
                            PaperCommentBubble(
                                comment: subComment,
                                isSubComment: true,
                                isLiking: likingCommentIDs.contains(subComment.id),
                                onReply: {
                                    onReply(.init(mainComment: comment, targetComment: subComment))
                                },
                                onLikeComment: {
                                    onLikeComment(subComment)
                                }
                            )

                            if subComment.id != comment.sub.last?.id {
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
        .padding(.vertical, 14)
    }
}

private struct PaperCommentBubble: View {
    let comment: GalleryComment
    let isSubComment: Bool
    let isLiking: Bool
    let onReply: () -> Void
    let onLikeComment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                CachedRemoteImage(url: comment.user.avatar.preferredRemoteURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                }
                .frame(width: isSubComment ? 28 : 34, height: isSubComment ? 28 : 34)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(comment.user.nickname)
                            .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(PaperDateText.timestampString(from: comment.updateTime))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    if !comment.replyObj.isEmpty, comment.replyUser.id > 0 {
                        Text("回复 @\(comment.replyUser.nickname)：")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(comment.text)
                        .font(isSubComment ? .subheadline : .body)
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 14) {
                Button(action: onReply) {
                    Label("回复", systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                    .buttonStyle(.plain)
                Button {
                    onLikeComment()
                } label: {
                    Label {
                        Text("\(comment.likeNum)")
                            .font(.caption)
                    } icon: {
                        Image(systemName: comment.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLiking)
            }
            .padding(.leading, isSubComment ? 38 : 44)
        }
    }
}

/// 文章列表和详情复用的文章操作菜单。
///
/// 当前先提供最小能力：本地隐藏本文。
