//
//  GalleryPosterDetailView.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

struct GalleryPosterDetailView: View {
    private struct UserRoute: Identifiable, Hashable {
        let userID: Int
        var id: Int { userID }
    }

    @ObservedObject private var settings = AppSettingsStore.shared
    private let reportService = CommunityReportService()
    @StateObject private var viewModel: GalleryPosterDetailViewModel
    @State private var imageViewer: GalleryImageViewerState?
    @State private var reportContext: GalleryReportContext?
    @State private var composerTarget: GalleryCommentComposerTarget?
    @State private var userRoute: UserRoute?
    @State private var isShowingDeleteConfirmation = false
    let onReport: ((CommunityReportAction) -> Void)?
    let onDeleted: (() -> Void)?

    init(
        poster: GalleryPoster,
        onReport: ((CommunityReportAction) -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: GalleryPosterDetailViewModel(initialPoster: poster))
        self.onReport = onReport
        self.onDeleted = onDeleted
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.poster.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Group {
                            if canOpenPosterUserProfile {
                                Button {
                                    userRoute = UserRoute(userID: viewModel.poster.user.id)
                                } label: {
                                    authorSummary
                                }
                                .buttonStyle(.plain)
                            } else {
                                authorSummary
                            }
                        }

                        Spacer()

                        HStack(spacing: 10) {
                            Button {
                                composerTarget = .poster(posterID: viewModel.poster.id)
                            } label: {
                                Image(systemName: "bubble.right")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color.orange.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task {
                                    await viewModel.likePoster()
                                }
                            } label: {
                                Group {
                                    if viewModel.isLikingPoster {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: viewModel.poster.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                                            .font(.headline)
                                    }
                                }
                                .foregroundStyle(viewModel.poster.like ? Color.orange : Color.primary)
                                .frame(width: 34, height: 34)
                                .background(Color.orange.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLikingPoster)
                        }
                    }
                }

                if viewModel.poster.claim.id != 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                        Text(viewModel.poster.claim.text)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                }

                Text(galleryLinkifiedText(viewModel.poster.text))
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !viewModel.poster.images.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(Array(viewModel.poster.images.enumerated()), id: \.element.id) { index, image in
                            Button {
                                imageViewer = GalleryImageViewerState(images: viewModel.poster.images, initialIndex: index)
                            } label: {
                                GalleryPosterThumbnail(
                                    image: image,
                                    width: nil,
                                    maxHeight: 320,
                                    aspectRatio: 1.6
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !viewModel.poster.tags.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(viewModel.poster.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }

                HStack(spacing: 18) {
                    Text("\(viewModel.poster.likeNum)赞")
                    Text("\(viewModel.poster.commentNum)评论")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Divider()

                GalleryPosterCommentsSection(
                    comments: filteredComments,
                    totalCommentCount: viewModel.poster.commentNum,
                    status: viewModel.commentState.status,
                    isLoadingMore: viewModel.commentState.isLoadingMore,
                    selectedOrder: viewModel.commentOrder,
                    likingCommentIDs: viewModel.likingCommentIDs,
                    onSelectOrder: { order in
                        Task {
                            await viewModel.setCommentOrder(order)
                        }
                    },
                    onReply: { target in
                        composerTarget = .comment(mainComment: target.mainComment, targetComment: target.targetComment)
                    },
                    onLikeComment: { comment in
                        Task {
                            await viewModel.likeComment(comment)
                        }
                    },
                    onOpenImage: { index, images in
                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                    },
                    onOpenUser: { user in
                        guard user.id > 0 else { return }
                        userRoute = UserRoute(userID: user.id)
                    },
                    onLoadMore: { comment in
                        Task {
                            await viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                        }
                    }
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .refreshable {
            await viewModel.refreshAll()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("帖子详情")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $userRoute) { route in
            UserProfileRootView(userID: route.userID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(
                    item: posterShareURL,
                    subject: Text(viewModel.poster.title.isEmpty ? "BIT101 话题" : viewModel.poster.title),
                    message: Text("在 BIT101 查看这个话题")
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享话题")

                if onReport != nil || viewModel.poster.own {
                    GalleryPosterActionMenu(
                        onSelectAction: onReport == nil ? nil : { action in
                            reportContext = GalleryReportContext(poster: viewModel.poster.asPoster, action: action)
                        },
                        onDelete: viewModel.poster.own ? {
                            isShowingDeleteConfirmation = true
                        } : nil
                    )
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .gallerySystemImagePreview(item: $imageViewer)
        .sheet(item: $reportContext) { context in
            CommunityReportSheet(context: context) { type, note in
                applyReport(context, type: type, note: note)
            }
        }
        .sheet(item: $composerTarget) { target in
            GalleryCommentComposerSheet(
                target: target,
                isSubmitting: viewModel.isSubmittingComment
            ) { text, anonymous in
                Task {
                    let success = await viewModel.submitComment(text: text, anonymous: anonymous, target: target)
                    if success {
                        composerTarget = nil
                    }
                }
            }
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .alert(
            "删除帖子",
            isPresented: $isShowingDeleteConfirmation,
            presenting: viewModel.poster
        ) { _ in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    if await viewModel.deletePoster() {
                        onDeleted?()
                        dismiss()
                    }
                }
            }
        } message: { poster in
            Text("确定删除“\(poster.title.isEmpty ? "未命名帖子" : poster.title)”吗？删除后无法恢复。")
        }
    }

    /// 详情页顶部作者信息区域。
    private var authorSummary: some View {
        HStack(spacing: 12) {
            GalleryAvatarView(imageURL: URL(string: viewModel.poster.user.avatar.lowUrl.isEmpty ? viewModel.poster.user.avatar.url : viewModel.poster.user.avatar.lowUrl))

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.poster.user.nickname)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(relativeTimeText(viewModel.poster.editTime))
                    if !viewModel.poster.public {
                        Label("仅自己可见", systemImage: "eye.slash")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 当前帖子作者是否允许跳转到用户主页。
    private var canOpenPosterUserProfile: Bool {
        !viewModel.poster.anonymous && viewModel.poster.user.id > 0
    }

    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知时间")
    }

    private var filteredComments: [GalleryComment] {
        CommunityModeration.filterVisibleComments(viewModel.commentState.items, snapshot: settings.snapshot)
    }

    /// 网页端帖子详情使用稳定的 `/gallery/{id}` 路由，分享后无需安装 App 也能打开。
    private var posterShareURL: URL {
        URL(string: "https://bit101.cn/gallery/\(viewModel.poster.id)")!
    }

    /// 在详情页里应用举报动作。
    private func applyReport(_ context: GalleryReportContext, type: CommunityReportType, note: String) {
        applyGalleryModerationAction(context, type: type, note: note, settings: settings, reportService: reportService)
    }
}

/// 评论区主体。
///
/// 这里只负责“评论列表如何展示”，不直接持有评论请求逻辑；请求和排序状态由上层
/// `GalleryPosterDetailViewModel` 驱动，再通过闭包把操作回传上去。
