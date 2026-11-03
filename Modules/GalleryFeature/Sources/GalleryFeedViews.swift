#if os(iOS)
import CommunityUI
import MediaKit
import CommunityCore
import TransportCore
import DesignSystemKit
//
//  GalleryFeedViews.swift
//  BIT101-iOS
//
//

import SwiftUI

struct GallerySubscriptionsView: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Environment(GalleryDependencies.self) private var dependencies
    @Environment(MediaEnvironment.self) private var media
    @Environment(CommunityProfileDestination.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: GallerySubscriptionsViewModel
    @State private var selectedPoster: GalleryPosterDetail?
    @State private var openingID: Int?
    let onOpenResource: (String, Int) -> Void

    init(
        service: any GallerySubscriptionServicing,
        onOpenResource: @escaping (String, Int) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: GallerySubscriptionsViewModel(service: service))
        self.onOpenResource = onOpenResource
    }

    private func handleItemTap(item: GallerySubscription) {
        guard let resource = item.resource else { return }
        guard resource.kind == "poster" else {
            onOpenResource(resource.kind, resource.id)
            return
        }
        openingID = item.id
        viewModel.pendingOperations.enqueue {
            defer { openingID = nil }
            do {
                selectedPoster = try await dependencies.posterDetail.fetchPoster(id: resource.id)
            } catch {
                guard !TaskCancellation.matches(error) else { return }
                viewModel.alert = AppAlert(title: "无法打开话题", error: error)
            }
        }
    }

    @ViewBuilder
    private func itemLabel(item: GallerySubscription) -> some View {
        let displayTitle = item.text.isEmpty ? item.resourceTitle : item.text
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.content) {
            Text(displayTitle)
                .font(AppDesignSystem.Typography.bodyEmphasis)
                .lineLimit(3)
            HStack(spacing: AppDesignSystem.Spacing.content) {
                Text(item.resourceTitle)
                Text(item.level.title)
                Spacer()
                if openingID == item.id { ProgressView() }
            }
            .font(AppDesignSystem.Typography.caption)
            .foregroundStyle(AppDesignSystem.Foreground.secondary)
        }
        .padding(.vertical, AppDesignSystem.Spacing.content)
    }

    @ViewBuilder
    private func subscriptionRow(item: GallerySubscription) -> some View {
        Button {
            handleItemTap(item: item)
        } label: {
            itemLabel(item: item)
        }
        .appInteractiveListRow()
        .disabled(openingID != nil || item.resource == nil)
        .accessibilityIdentifier("gallery.subscription.\(item.id)")
    }

    @ViewBuilder
    private var emptyOrLoadingView: some View {
        if case .failed(let message) = viewModel.status {
            AppFailureState(title: "加载收藏失败", systemImage: "bookmark", message: message) {
                viewModel.pendingOperations.enqueue { await viewModel.refresh() }
            }
        } else if viewModel.status == .loading || viewModel.status == .idle {
            AppInlineLoadingState("正在加载收藏")
        } else {
            AppEmptyState(
                title: "还没有收藏", systemImage: "bookmark",
                message: "在话题详情中点按插眼收藏，方便日后继续阅读。")
        }
    }

    @ViewBuilder
    private var loadMoreSection: some View {
        if !viewModel.items.isEmpty, viewModel.canLoadMore {
            if viewModel.isLoadingMore {
                AppInlineLoadingState()
            } else {
                Button("加载更多收藏") {
                    viewModel.pendingOperations.enqueue { await viewModel.loadMore() }
                }
                .appInteractiveListRow()
                .accessibilityIdentifier("gallery.subscriptions.more")
            }
        }
    }

    var body: some View {
        List {
            if viewModel.items.isEmpty {
                emptyOrLoadingView
            }
            ForEach(viewModel.items) { item in
                subscriptionRow(item: item)
            }
            loadMoreSection
        }
        .accessibilityIdentifier("interaction.GallerySubscriptionsView.list")
        .appGroupedListStyle()
        .scrollContentBackground(.hidden)
        .background(AppDesignSystem.Palette.Background.grouped)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }.accessibilityIdentifier("gallery.subscriptions.done")
            }
        }
        .task { await viewModel.bootstrapIfNeeded() }
        .communityReadRecovery(
            networkPath: dependencies.networkPath, isEnabled: selectedPoster == nil
        ) {
            if viewModel.needsRefresh {
                await viewModel.refresh()
            } else if viewModel.paginationError != nil {
                await viewModel.loadMore()
            }
        }
        .refreshable {
            interactionEvidence?("interaction.GallerySubscriptionsView.refreshable", "refresh")
            await viewModel.refresh()
        }
        .onDisappear { viewModel.pendingOperations.cancel() }
        .diagnosticAlert(item: $viewModel.alert)
        .navigationDestination(item: $selectedPoster) { poster in
            GalleryPosterDetailView(
                dependencies: dependencies, media: media, profiles: profiles,
                poster: poster.asPoster, initialDetail: poster,
                onUpdated: {
                    viewModel.pendingOperations.enqueue { await viewModel.refresh() }
                },
                onDeleted: { viewModel.pendingOperations.enqueue { await viewModel.refresh() } }
            )
        }
    }
}

struct GalleryFeedView: View {
    @Environment(\.appWindowLayout) private var layout
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Environment(GalleryDependencies.self) private var dependencies
    @Environment(MediaEnvironment.self) private var media
    @Environment(CommunityProfileDestination.self) private var profiles
    let feedState: GalleryFeedState
    let feedIdentity: String
    let prefetchTriggerThreshold: Int
    let onRefresh: () -> Void
    let onPullToRefresh: () async -> Void
    let onPrefetch: (CommunityPoster?) -> Void
    let onLoadMore: (CommunityPoster?) -> Void
    var onSelectPoster: ((CommunityPoster) -> Void)? = nil
    var excludedPosterIDs: Set<Int> = []
    var selectedPosterID: Int? = nil
    var scrollPosition: Binding<Int?>? = nil
    var onPreview: ((ImagePreviewRequest) -> Void)? = nil
    @State private var selectedPoster: CommunityPoster?
    @State private var imageViewer: ImagePreviewRequest?
    @State private var deletedPosterIDs: Set<Int> = []
    @State private var currentTopPosterID: Int?
    @State private var lastPrefetchTriggerPosterID: Int?
    @State private var reportTarget: GalleryReportTarget?

    private func handleOpenPoster(_ poster: CommunityPoster) {
        if let onSelectPoster {
            onSelectPoster(poster)
        } else {
            selectedPoster = poster
        }
    }

    private func handleOpenImage(index: Int, images: [CommunityImage]) {
        let request = ImagePreviewRequest(
            remoteImages: images.map(\.previewImage),
            initialIndex: index)
        if let onPreview {
            onPreview(request)
        } else {
            imageViewer = request
        }
    }

    private func handlePrefetchAndLoadMore(
        poster: CommunityPoster,
        prefetchTriggerPosterID: Int?,
        visiblePosters: [CommunityPoster]
    ) {
        if poster.id == prefetchTriggerPosterID,
            lastPrefetchTriggerPosterID != poster.id
        {
            lastPrefetchTriggerPosterID = poster.id
            onPrefetch(poster)
        }
        guard poster.id == visiblePosters.last?.id else { return }
        onLoadMore(poster)
    }

    @ViewBuilder
    private func posterCard(for poster: CommunityPoster) -> some View {
        CommunityPosterCard(
            poster: poster,
            onOpenPoster: { handleOpenPoster(poster) },
            onOpenImage: { index, images in handleOpenImage(index: index, images: images) },
            onDelete: nil,
            onReport: { reportTarget = .poster(poster.id) }
        )
    }

    @ViewBuilder
    private func feedRow(
        index: Int,
        poster: CommunityPoster,
        visiblePosters: [CommunityPoster],
        prefetchTriggerPosterID: Int?
    ) -> some View {
        AppFeedRow(
            isLast: layout.isLandscape || index == visiblePosters.count - 1,
            isSelected: selectedPosterID == poster.id
        ) {
            posterCard(for: poster)
        }
        .id(poster.id)
        .task(id: feedState.status == .loaded ? feedState.nextPage : nil) {
            handlePrefetchAndLoadMore(
                poster: poster,
                prefetchTriggerPosterID: prefetchTriggerPosterID,
                visiblePosters: visiblePosters)
        }
    }

    @ViewBuilder
    private func feedGrid(
        visiblePosters: [CommunityPoster],
        prefetchTriggerPosterID: Int?
    ) -> some View {
        LazyVStack(spacing: AppDesignSystem.Spacing.none) {
            LazyVGrid(
                columns: layout.gridColumns,
                spacing: layout.isLandscape
                    ? AppDesignSystem.Spacing.content : AppDesignSystem.Spacing.none
            ) {
                ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                    feedRow(
                        index: index,
                        poster: poster,
                        visiblePosters: visiblePosters,
                        prefetchTriggerPosterID: prefetchTriggerPosterID)
                }
            }
            .scrollTargetLayout()
            if feedState.canLoadMore { pageContinuation }
        }
    }

    var body: some View {
        let visiblePosters = self.visiblePosters
        let prefetchTriggerPosterID =
            prefetchTriggerThreshold > 0 && !visiblePosters.isEmpty
            ? visiblePosters[max(visiblePosters.count - prefetchTriggerThreshold, 0)].id : nil
        ScrollView {
            if isInitialLoading {
                galleryPlaceholder {
                    AppInlineLoadingState("正在加载话廊")
                }
            } else if case .failed(let message) = feedState.status, visiblePosters.isEmpty {
                galleryPlaceholder {
                    AppFailureState(
                        title: "加载失败",
                        systemImage: "exclamationmark.triangle",
                        message: message,
                        onRetry: onRefresh
                    )
                }
            } else if visiblePosters.isEmpty {
                galleryPlaceholder {
                    AppEmptyState(
                        title: feedIdentity == "search" ? "没有找到相关话题" : "暂无话题",
                        systemImage: "bubble.left.and.bubble.right",
                        message: feedIdentity == "search" ? "换个关键词试试。" : "当前分区还没有可展示的话题。"
                    )
                    if feedState.canLoadMore { pageContinuation }
                }
            } else {
                feedGrid(
                    visiblePosters: visiblePosters,
                    prefetchTriggerPosterID: prefetchTriggerPosterID)
            }
        }
        .accessibilityIdentifier("interaction.GalleryFeedView.scroll")
        // 系统按帖子标识保持滚动位置。
        .scrollPosition(id: scrollPosition ?? $currentTopPosterID, anchor: .top)
        .background(AppDesignSystem.Palette.Background.grouped)
        .id(feedIdentity)
        .refreshable {
            interactionEvidence?("interaction.GalleryFeedView.refreshable", "refresh")
            await onPullToRefresh()
        }
        .navigationDestination(item: $selectedPoster) { poster in
            GalleryPosterDetailView(
                dependencies: dependencies, media: media, profiles: profiles,
                poster: poster,
                onUpdated: onRefresh,
                onDeleted: {
                    deletedPosterIDs.insert(poster.id)
                    onRefresh()
                }
            )
        }
        .systemImagePreview(item: $imageViewer)
        .sheet(item: $reportTarget) { target in
            GalleryReportSheet(target: target, service: dependencies.reporting) {}
        }
    }

    /// 加载中和失败空态也放进统一滚动容器里，保证始终可以下拉刷新。
    @ViewBuilder
    private func galleryPlaceholder<Content: View>(@ViewBuilder content: () -> Content)
        -> some View
    {
        AppScrollStateContainer(content: content)
    }

    /// 首屏空态下是否应该显示中央加载指示器。
    private var isInitialLoading: Bool {
        switch feedState.status {
        case .idle, .loading:
            return visiblePosters.isEmpty
        default:
            return false
        }
    }

    /// 当前真正可见的帖子列表。
    ///
    /// 删帖成功后会先做本地移除，再等待上层刷新；因此这里要叠加一层
    /// `deletedPosterIDs` 过滤，保证体感上帖子会立刻消失。
    private var visiblePosters: [CommunityPoster] {
        feedState.posters.filter {
            !deletedPosterIDs.contains($0.id) && !excludedPosterIDs.contains($0.id)
        }
    }

    /// 进入可见列表尾部若干条时触发的预取集合。
    ///
    /// 预取负责后台准备下一页；列表追加由末尾触发，滚动条比例和当前位置保持稳定。
    private var pageContinuation: some View {
        CommunityPaginationFooter(
            isLoading: feedState.isLoadingMore, errorMessage: feedState.paginationError,
            showsContinuation: feedState.needsContinuation
        ) { onLoadMore(visiblePosters.last) }
    }

}

#endif
