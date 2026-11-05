#if os(iOS)
import CommunityUI
import TransportCore
import MediaKit
import CommunityCore
import DesignSystemKit
import SwiftUI

public struct GalleryPosterDetailView: View {
    private let scene: GalleryPosterDetailViewScene
    private let identity: [ObjectIdentifier]
    private let resourceID: Int

    public init(
        dependencies: GalleryDependencies,
        media: MediaEnvironment,
        profiles: CommunityProfileDestination,
        poster: CommunityPoster,
        initialDetail: GalleryPosterDetail? = nil,
        onUpdated: (() -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        scene = GalleryPosterDetailViewScene(
            dependencies: dependencies, media: media, profiles: profiles, poster: poster,
            initialDetail: initialDetail, onUpdated: onUpdated, onDeleted: onDeleted)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
        resourceID = poster.id
    }

    public var body: some View {
        scene.id(identity)
            .id(resourceID)
            .appReadableContent(fillsAvailableWidth: true)
    }
}

private struct GalleryPosterDetailViewScene: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    private let dependencies: GalleryDependencies
    private let destinations: CommunityProfileDestination
    private let media: MediaEnvironment
    private var contentPreferences: CommunityPreferences
    private struct UserRoute: Identifiable, Hashable {
        let userID: Int
        var id: Int { userID }
    }

    @State private var viewModel: GalleryPosterDetailViewModel
    @State private var imageViewer: ImagePreviewRequest?
    @State private var composerTarget: CommunityCommentComposerTarget?
    @State private var userRoute: UserRoute?
    @State private var isShowingDeleteConfirmation = false
    @State private var reportTarget: GalleryReportTarget?
    @State private var imageAspectRatios: [Int: CGFloat] = [:]
    @State private var isShowingEditor = false
    let onUpdated: (() -> Void)?
    let onDeleted: (() -> Void)?

    private var commentFilter: GalleryCommentFilter {
        .init(preferences: contentPreferences.snapshot)
    }

    init(
        dependencies: GalleryDependencies,
        media: MediaEnvironment,
        profiles: CommunityProfileDestination,
        poster: CommunityPoster,
        initialDetail: GalleryPosterDetail?,
        onUpdated: (() -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.dependencies = dependencies
        self.media = media
        self.contentPreferences = dependencies.preferences
        self.destinations = profiles
        _viewModel = State(
            initialValue: GalleryPosterDetailViewModel(
                initialPoster: poster, initialDetail: initialDetail,
                service: dependencies.posterDetail))
        self.onUpdated = onUpdated
        self.onDeleted = onDeleted
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content.environment(dependencies).environment(media).environment(destinations)
    }

    private var posterLikeLabel: some View {
        Group {
            if viewModel.isLikingPoster
                || (!viewModel.hasKnownLikeState
                    && (viewModel.posterStatus == .idle
                        || viewModel.posterStatus == .loading))
            {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(
                    systemName: viewModel.poster.like
                        ? "hand.thumbsup.fill" : "hand.thumbsup"
                )
                .font(AppDesignSystem.Typography.title)
            }
        }
        .foregroundStyle(
            viewModel.poster.like
                ? AppDesignSystem.Palette.Accent.primary
                : AppDesignSystem.Foreground.primaryColor)
    }

    private func posterImage(index: Int, image: CommunityImage) -> some View {
        let imageAccessibilityLabel = "图片 \(index + 1)"
        return Button {
            imageViewer = ImagePreviewRequest(
                remoteImages: viewModel.poster.images.map(\.previewImage),
                initialIndex: index)
        } label: {
            CommunityImageThumbnail(
                image: image,
                contentMode: .fit,
                loadsOriginal: true,
                onAspectRatioResolved: { ratio in
                    guard ratio > 0, imageAspectRatios[index] != ratio
                    else { return }
                    imageAspectRatios[index] = ratio
                }
            )
            .aspectRatio(
                imageAspectRatios[index]
                    ?? AppDesignSystem.Community
                    .thumbnailLandscapeAspectRatio,
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
            .clipShape(
                AppDesignSystem.roundedRectangle(
                    AppDesignSystem.Radius.card))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(imageAccessibilityLabel)
        .accessibilityHint("轻点查看大图")
        .accessibilityIdentifier(
            "ui.gallery-poster-detail-view-scene.images")
    }

    @ViewBuilder
    private var posterTags: some View {
        if !viewModel.poster.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppDesignSystem.Spacing.tiny) {
                    ForEach(viewModel.poster.tags, id: \.self) { tag in
                        AppTagChip(title: tag, variant: .display)
                    }
                }
            }
            .accessibilityIdentifier(
                "interaction.GalleryPosterDetailViewScene.tags"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Spacer(minLength: AppDesignSystem.Spacing.tiny)
        }
    }

    @ViewBuilder
    private var posterFailure: some View {
        if case .failed(let message) = viewModel.posterStatus {
            AppFailureState(
                title: "加载帖子失败",
                systemImage: "exclamationmark.triangle",
                message: message,
                onRetry: {
                    viewModel.pendingOperations.enqueue { await viewModel.refreshAll() }
                }
            )
        }
    }

    private func saveSubscription(_ level: GallerySubscriptionLevel) async {
        if await viewModel.setSubscription(level) { onUpdated?() }
    }

    private var subscriptionMenu: some View {
        Menu {
            ForEach(GallerySubscriptionLevel.allCases) { level in
                Button {
                    viewModel.pendingOperations.enqueue { await saveSubscription(level) }
                } label: {
                    Label(
                        level.title,
                        systemImage: viewModel.subscriptionLevel == level
                            ? "checkmark" : "bookmark")
                }
                .disabled(viewModel.subscriptionLevel == level)
                .accessibilityIdentifier("gallery.subscription-level.\(level.rawValue)")
            }
        } label: {
            if viewModel.isSavingSubscription {
                ProgressView()
            } else {
                Image(
                    systemName: viewModel.subscriptionLevel == .none
                        ? "bookmark" : "bookmark.fill")
            }
        }
        .accessibilityLabel("插眼收藏")
        .accessibilityIdentifier("gallery.subscription-menu")
        .accessibilityValue(
            viewModel.subscriptionLevel == .none
                ? "尚未插眼" : viewModel.subscriptionLevel.title
        )
        .disabled(viewModel.isSavingSubscription || viewModel.posterStatus != .loaded)
    }

    private var posterActions: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            AppDetailCircleButton(accessibilityLabel: "评论帖子") {
                composerTarget = .poster(posterID: viewModel.poster.id)
            } label: {
                Image(systemName: "bubble.right")
                    .font(AppDesignSystem.Typography.title)
                    .foregroundStyle(AppDesignSystem.Foreground.primary)
            }

            AppDetailCircleButton(
                accessibilityLabel: viewModel.hasKnownLikeState
                    ? (viewModel.poster.like ? "取消帖子点赞" : "点赞帖子") : "等待帖子点赞状态"
            ) {
                viewModel.pendingOperations.enqueue {
                    await viewModel.likePoster()
                }
            } label: {
                posterLikeLabel

            }
            .disabled(viewModel.isLikingPoster || !viewModel.hasKnownLikeState)
        }
    }

    private var posterHeader: some View {
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
                    .accessibilityIdentifier(
                        "ui.gallery-poster-detail-view-scene.profile")
                } else {
                    authorSummary
                }

                Spacer()

                posterActions

            }
        }
    }

    @ViewBuilder
    private var posterImages: some View {
        if !viewModel.poster.images.isEmpty {
            VStack(spacing: AppDesignSystem.Spacing.regular) {
                ForEach(Array(viewModel.poster.images.enumerated()), id: \.element.id) {
                    index, image in
                    posterImage(index: index, image: image)

                }
            }
            .onChange(of: viewModel.poster.images) { _, _ in
                imageAspectRatios = [:]
            }
        }
    }

    private var posterStatistics: some View {
        HStack(spacing: AppDesignSystem.Spacing.content) {
            Label("\(viewModel.poster.likeNum)", systemImage: "hand.thumbsup")
            Label("\(viewModel.poster.commentNum)", systemImage: "bubble.right")

            posterTags

        }
        .font(AppDesignSystem.Typography.caption)
        .foregroundStyle(AppDesignSystem.Foreground.secondary)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.section) {
                posterHeader

                posterFailure

                if viewModel.poster.claim.id != 0 {
                    HStack(spacing: AppDesignSystem.Spacing.tiny) {
                        Image(systemName: "checkmark.seal")
                        Text(viewModel.poster.claim.text)
                    }
                    .font(AppDesignSystem.Typography.footnoteEmphasis)
                    .foregroundStyle(AppDesignSystem.Palette.Accent.primary)
                }

                CommunityLinkedText(viewModel.poster.text)
                    .font(AppDesignSystem.Typography.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                posterImages

                posterStatistics

                Divider()

                GalleryPosterCommentsSection(
                    comments: viewModel.commentState.items,
                    totalCommentCount: viewModel.poster.commentNum,
                    status: viewModel.commentState.status,
                    isLoadingMore: viewModel.commentState.isLoadingMore,
                    paginationError: viewModel.commentState.paginationError,
                    canContinue: viewModel.commentState.canLoadMore
                        && viewModel.commentState.needsContinuation,
                    selectedOrder: viewModel.commentOrder,
                    likingCommentIDs: viewModel.likingCommentIDs,
                    onSelectOrder: { order in
                        viewModel.pendingOperations.enqueue {
                            await viewModel.setCommentOrder(order)
                        }
                    },
                    onReply: { target in
                        composerTarget = target
                    },
                    onLikeComment: { comment in
                        viewModel.pendingOperations.enqueue {
                            await viewModel.likeComment(comment)
                        }
                    },
                    onReportComment: { comment in
                        reportTarget = .comment(comment.id)
                    },
                    onDeleteComment: { comment in
                        viewModel.pendingOperations.enqueue {
                            await viewModel.deleteComment(comment)
                        }
                    },
                    onOpenImage: { index, images in
                        imageViewer = ImagePreviewRequest(
                            remoteImages: images.map(\.previewImage), initialIndex: index)
                    },
                    onOpenUser: { user in
                        guard user.id > 0 else { return }
                        userRoute = UserRoute(userID: user.id)
                    },
                    onLoadMore: { comment in
                        viewModel.pendingOperations.enqueue {
                            await viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                        }
                    },
                    onRetry: {
                        viewModel.pendingOperations.enqueue {
                            await viewModel.refreshComments()
                        }
                    }
                )
            }
            .padding(.horizontal, AppDesignSystem.Spacing.section)
            .padding(.top, AppDesignSystem.Spacing.section)
        }
        .accessibilityIdentifier("interaction.GalleryPosterDetailViewScene.content")
        .refreshable {
            interactionEvidence?(
                "interaction.GalleryPosterDetailViewScene.refreshable", "refresh")

            media.retryFailedImages()
            await viewModel.refreshAll()
        }
        .background(AppDesignSystem.Palette.Background.grouped)
        .navigationTitle("帖子详情")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $userRoute) { route in
            destinations.profile(route.userID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                subscriptionMenu

                AppDetailShareLink(
                    item: posterShareURL,
                    subject: viewModel.poster.title.isEmpty
                        ? "BIT101 话题" : viewModel.poster.title,
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

                CommunityPosterActionMenu(
                    onDelete: viewModel.poster.own
                        ? {
                            isShowingDeleteConfirmation = true
                        } : nil,
                    onReport: {
                        reportTarget = .poster(viewModel.poster.id)
                    }
                )
            }
        }
        .task(id: commentFilter) {
            await viewModel.loadContent(filter: commentFilter)
        }
        .systemImagePreview(item: $imageViewer)
        .sheet(isPresented: $isShowingEditor) {
            NavigationStack {
                GalleryComposerView(editingPoster: viewModel.poster) {
                    isShowingEditor = false
                    onUpdated?()
                    viewModel.pendingOperations.enqueue { await viewModel.refreshAll() }
                }
            }
        }
        .sheet(item: $composerTarget) { target in
            GalleryCommentComposerSheet(
                dependencies: dependencies,
                target: target,
                isSubmitting: viewModel.isSubmittingComment,
                review: viewModel.commentReview
            ) { text, anonymous, images in
                await viewModel.submitComment(
                    text: text, anonymous: anonymous, imageMids: images.map(\.mid),
                    target: target)
            }
            .id(target.id)
        }
        .sheet(item: $reportTarget) { target in
            GalleryReportSheet(target: target, service: dependencies.reporting) {}
        }
        .communityReadRecovery(networkPath: dependencies.networkPath) {
            await retryDetailIfNeeded()
        }
        .onDisappear { viewModel.pendingOperations.cancel() }
        .diagnosticAlert(item: $viewModel.alert)
        .alert(
            "删除帖子",
            isPresented: $isShowingDeleteConfirmation,
            presenting: viewModel.poster
        ) { _ in
            Button("取消", role: .cancel) {}
                .accessibilityIdentifier("ui.gallery-poster-detail-view-scene.cancel")
            Button("删除", role: .destructive) {
                viewModel.pendingOperations.enqueue {
                    if await viewModel.deletePoster() {
                        onDeleted?()
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier("ui.gallery-poster-detail-view-scene.delete")
        } message: { poster in
            Text("确定删除“\(poster.title.isEmpty ? "未命名帖子" : poster.title)”吗？删除后无法恢复。")
        }
    }

    private func retryDetailIfNeeded() async {
        await viewModel.retryFailedContent()
    }

    private var authorSummary: some View {
        HStack(spacing: AppDesignSystem.Spacing.content) {
            AppAvatarView(
                imageURL: viewModel.poster.anonymous
                    ? nil : viewModel.poster.user.avatar.thumbnailURL,
                fallbackImageURL: viewModel.poster.anonymous
                    ? nil : viewModel.poster.user.avatar.originalURL,
                anonymous: viewModel.poster.anonymous)

            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                Text(posterDisplayName)
                    .font(AppDesignSystem.Typography.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: AppDesignSystem.Spacing.regular) {
                    Text(
                        AppDateText.relativeText(
                            from: viewModel.poster.editTime, fallback: "未知时间"))
                    if !viewModel.poster.public {
                        Label("仅自己可见", systemImage: "eye.slash")
                    }
                }
                .font(AppDesignSystem.Typography.caption)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
            }
        }
    }

    private var canOpenPosterUserProfile: Bool {
        !viewModel.poster.anonymous && viewModel.poster.user.id > 0
    }

    private var posterDisplayName: String {
        viewModel.poster.anonymous
            ? AppUserPresentation.anonymousName : viewModel.poster.user.nickname
    }

    /// 独立跳转域名使用稳定的 `/gallery/{id}` 路由；未安装 App 时由 Worker 转至网页。
    private var posterShareURL: URL {
        AppEndpoints.openLink("gallery/\(viewModel.poster.id)")
    }

}

#endif
