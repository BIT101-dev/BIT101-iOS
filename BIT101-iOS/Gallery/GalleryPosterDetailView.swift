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

    @StateObject private var viewModel: GalleryPosterDetailViewModel
    @State private var imageViewer: GalleryImageViewerState?
    @State private var composerTarget: GalleryCommentComposerTarget?
    @State private var userRoute: UserRoute?
    @State private var isShowingDeleteConfirmation = false
    let onDeleted: (() -> Void)?

    init(
        poster: GalleryPoster,
        onDeleted: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: GalleryPosterDetailViewModel(initialPoster: poster))
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
                            AppDetailCircleButton {
                                composerTarget = .poster(posterID: viewModel.poster.id)
                            } label: {
                                Image(systemName: "bubble.right")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                            }

                            AppDetailCircleButton {
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
                                .foregroundStyle(viewModel.poster.like ? AppDesignSystem.Palette.highlight : Color.primary)
                            }
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
                    .foregroundStyle(AppDesignSystem.Palette.highlight)
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
                                .background(AppDesignSystem.Palette.highlight.opacity(0.12), in: Capsule())
                                .foregroundStyle(AppDesignSystem.Palette.highlight)
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
                        comments: viewModel.commentState.items,
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
            .padding(.horizontal, AppDesignSystem.Detail.contentPadding)
            .padding(.top, AppDesignSystem.Detail.contentPadding)
        }
        .refreshable {
            await viewModel.refreshAll()
        }
        .background(AppDesignSystem.Palette.groupedBackground)
        .navigationTitle("帖子详情")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $userRoute) { route in
            UserProfileRootView(userID: route.userID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                AppDetailShareLink(
                    item: posterShareURL,
                    subject: viewModel.poster.title.isEmpty ? "BIT101 话题" : viewModel.poster.title,
                    accessibilityLabel: "分享话题"
                )

                if viewModel.poster.own {
                    GalleryPosterActionMenu(
                        onDelete: {
                            isShowingDeleteConfirmation = true
                        }
                    )
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .gallerySystemImagePreview(item: $imageViewer)
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
        .diagnosticAlert(item: $viewModel.alert)
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

    /// 独立跳转域名使用稳定的 `/gallery/{id}` 路由；未安装 App 时由 Worker 转至网页。
    private var posterShareURL: URL {
        URL(string: "https://open.aihelpme.dev/gallery/\(viewModel.poster.id)")!
    }

}

/// 评论区主体。
///
/// 这里只负责“评论列表如何展示”，不直接持有评论请求逻辑；请求和排序状态由上层
/// `GalleryPosterDetailViewModel` 驱动，再通过闭包把操作回传上去。
