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
    @State private var reportTarget: GalleryReportTarget?
    @State private var imageAspectRatios: [Int: CGFloat] = [:]
    @State private var isShowingEditor = false
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
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.section) {
                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
                    Text(viewModel.poster.title)
                        .font(AppDesignSystem.Typography.titleEmphasis)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: AppDesignSystem.Spacing.content) {
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

                        Spacer()

                        HStack(spacing: AppDesignSystem.Spacing.regular) {
                            AppDetailCircleButton(accessibilityLabel: "评论帖子") {
                                composerTarget = .poster(posterID: viewModel.poster.id)
                            } label: {
                                Image(systemName: "bubble.right")
                                    .font(AppDesignSystem.Typography.title)
                                    .foregroundStyle(.primary)
                            }

                            AppDetailCircleButton(
                                accessibilityLabel: viewModel.poster.like ? "取消帖子点赞" : "点赞帖子"
                            ) {
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
                                            .font(AppDesignSystem.Typography.title)
                                    }
                                }
                                .foregroundStyle(viewModel.poster.like ? AppDesignSystem.Palette.highlight : Color.primary)
                            }
                            .disabled(viewModel.isLikingPoster)
                        }
                    }
                }

                if case let .failed(message) = viewModel.posterStatus {
                    AppFailureState(
                        title: "加载帖子失败",
                        systemImage: "exclamationmark.triangle",
                        message: message,
                        onRetry: {
                            Task { await viewModel.refreshAll() }
                        }
                    )
                }

                if viewModel.poster.claim.id != 0 {
                    HStack(spacing: AppDesignSystem.Spacing.tiny) {
                        Image(systemName: "checkmark.seal")
                        Text(viewModel.poster.claim.text)
                    }
                    .font(AppDesignSystem.Typography.footnoteEmphasis)
                    .foregroundStyle(AppDesignSystem.Palette.highlight)
                }

                Text(galleryLinkifiedText(viewModel.poster.text))
                    .font(AppDesignSystem.Typography.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !viewModel.poster.images.isEmpty {
                    VStack(spacing: AppDesignSystem.Spacing.regular) {
                        ForEach(Array(viewModel.poster.images.enumerated()), id: \.element.id) { index, image in
                            let imageAccessibilityLabel = "图片 \(index + 1)"
                            Button {
                                imageViewer = GalleryImageViewerState(images: viewModel.poster.images, initialIndex: index)
                            } label: {
                                GalleryPosterThumbnail(
                                    image: image,
                                    contentMode: .fit,
                                    loadsOriginal: true,
                                    onAspectRatioResolved: { ratio in
                                        guard ratio > 0, imageAspectRatios[index] != ratio else { return }
                                        imageAspectRatios[index] = ratio
                                    }
                                )
                                .aspectRatio(
                                    imageAspectRatios[index]
                                        ?? AppDesignSystem.Gallery.thumbnailLandscapeAspectRatio,
                                    contentMode: .fit
                                )
                                .frame(maxWidth: .infinity)
                                .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(imageAccessibilityLabel)
                            .accessibilityHint("轻点查看大图")
                        }
                    }
                    .onChange(of: viewModel.poster.images) { _, _ in
                        imageAspectRatios = [:]
                    }
                }

                if !viewModel.poster.tags.isEmpty {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        ForEach(viewModel.poster.tags, id: \.self) { tag in
                            AppTagChip(title: tag, variant: .display)
                        }
                    }
                }

                HStack(spacing: AppDesignSystem.Spacing.section) {
                    Text("\(viewModel.poster.likeNum)赞")
                    Text("\(viewModel.poster.commentNum)评论")
                }
                .font(AppDesignSystem.Typography.subheadline)
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
                    onReportComment: { comment in
                        reportTarget = .comment(comment.id)
                    },
                    onDeleteComment: { comment in
                        Task { await viewModel.deleteComment(comment) }
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
            .padding(.horizontal, AppDesignSystem.Spacing.section)
            .padding(.top, AppDesignSystem.Spacing.section)
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
                    Button {
                        isShowingEditor = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("编辑帖子")
                }

                GalleryPosterActionMenu(
                    onDelete: viewModel.poster.own ? {
                        isShowingDeleteConfirmation = true
                    } : nil,
                    onReport: {
                        reportTarget = .poster(viewModel.poster.id)
                    }
                )
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .gallerySystemImagePreview(item: $imageViewer)
        .sheet(isPresented: $isShowingEditor) {
            NavigationStack {
                GalleryComposerView(editingPoster: viewModel.poster) {
                    isShowingEditor = false
                    Task { await viewModel.refreshAll() }
                }
            }
        }
        .sheet(item: $composerTarget) { target in
            GalleryCommentComposerSheet(
                target: target,
                isSubmitting: viewModel.isSubmittingComment
            ) { text, anonymous, images in
                Task {
                    let success = await viewModel.submitComment(
                        text: text,
                        anonymous: anonymous,
                        imageMids: images.map(\.mid),
                        target: target
                    )
                    if success {
                        composerTarget = nil
                    }
                }
            }
        }
        .sheet(item: $reportTarget) { target in
            GalleryReportSheet(target: target) {}
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

    private var authorSummary: some View {
        HStack(spacing: AppDesignSystem.Spacing.content) {
            AppAvatarView(imageURL: posterAvatarURL)

            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                Text(posterDisplayName)
                    .font(AppDesignSystem.Typography.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: AppDesignSystem.Spacing.regular) {
                    Text(AppDateText.relativeText(from: viewModel.poster.editTime, fallback: "未知时间"))
                    if !viewModel.poster.public {
                        Label("仅自己可见", systemImage: "eye.slash")
                    }
                }
                .font(AppDesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var canOpenPosterUserProfile: Bool {
        !viewModel.poster.anonymous && viewModel.poster.user.id > 0
    }

    private var posterDisplayName: String {
        viewModel.poster.anonymous ? "匿名用户" : viewModel.poster.user.nickname
    }

    private var posterAvatarURL: URL? {
        guard !viewModel.poster.anonymous else { return nil }
        let rawURL = viewModel.poster.user.avatar.lowUrl.isEmpty
            ? viewModel.poster.user.avatar.url
            : viewModel.poster.user.avatar.lowUrl
        return URL(string: rawURL)
    }

    /// 独立跳转域名使用稳定的 `/gallery/{id}` 路由；未安装 App 时由 Worker 转至网页。
    private var posterShareURL: URL {
        AppURL.required("https://open.aihelpme.dev/gallery/\(viewModel.poster.id)")
    }

}
