#if os(iOS)
import CommunityUI
import MediaKit
import CommunityCore
import DesignSystemKit
//
//  GalleryFeedViews.swift
//  BIT101-iOS
//
//  Split from GalleryRootView.swift.
//

import SwiftUI

struct GalleryFeedView: View {
    @Environment(GalleryDependencies.self) private var dependencies
    @Environment(MediaEnvironment.self) private var media
    @Environment(CommunityProfileDestination.self) private var profiles
    let feedState: GalleryFeedState
    let feedIdentity: String
    let prefetchTriggerThreshold: Int
    let onRefresh: () -> Void
    let onPrefetch: (CommunityPoster?) -> Void
    let onLoadMore: (CommunityPoster?) -> Void
    @State private var selectedPoster: CommunityPoster?
    @State private var imageViewer: ImagePreviewRequest?
    @State private var deletedPosterIDs: Set<Int> = []
    @State private var currentTopPosterID: Int?
    @State private var pendingRestorePosterID: Int?
    @State private var lastPrefetchTriggerPosterID: Int?
    @State private var reportTarget: GalleryReportTarget?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isInitialLoading {
                    galleryPlaceholderContainer {
                        AppInlineLoadingState("正在加载话廊")
                    }
                } else if case let .failed(message) = feedState.status, visiblePosters.isEmpty {
                    galleryPlaceholderContainer {
                        AppFailureState(
                            title: "加载失败",
                            systemImage: "exclamationmark.triangle",
                            message: message,
                            onRetry: onRefresh
                        )
                    }
                } else if visiblePosters.isEmpty {
                    galleryPlaceholderContainer {
                        AppEmptyState(
                            title: feedIdentity == "search" ? "没有找到相关话题" : "暂无话题",
                            systemImage: "bubble.left.and.bubble.right",
                            message: feedIdentity == "search" ? "换个关键词试试。" : "当前分区还没有可展示的话题。"
                        )
                    }
                } else {
                    LazyVStack(spacing: AppDesignSystem.Spacing.none) {
                        ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                            AppFeedRow(isLast: index == visiblePosters.count - 1) {
                                CommunityPosterCard(
                                    poster: poster,
                                    onOpenPoster: { selectedPoster = poster },
                                    onOpenImage: { index, images in
                                        imageViewer = ImagePreviewRequest(remoteImages: images.map(\.previewImage), initialIndex: index)
                                    },
                                    onDelete: nil,
                                    onReport: { reportTarget = .poster(poster.id) }
                                )
                            }
                            .id(poster.id)
                            .onAppear {
                                if poster.id == prefetchTriggerPosterID,
                                   lastPrefetchTriggerPosterID != poster.id {
                                    lastPrefetchTriggerPosterID = poster.id
                                    onPrefetch(poster)
                                }
                                guard poster.id == visiblePosters.last?.id else { return }
                                onLoadMore(poster)
                            }
                        }

                        if feedState.isLoadingMore {
                            AppInlineLoadingState()
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            // 系统滚动定位在顶部目标发生变化时更新一次；卡片复用统一定位状态。
            .scrollPosition(id: $currentTopPosterID, anchor: .top)
            .background(AppDesignSystem.Palette.Background.grouped)
            .id(feedIdentity)
            .refreshable {
                pendingRestorePosterID = currentTopPosterID ?? visiblePosters.first?.id
                onRefresh()
            }
            .onChange(of: visiblePosterIDs) { _, newIDs in
                restoreScrollPositionIfNeeded(with: proxy, availableIDs: newIDs)
            }
            .navigationDestination(item: $selectedPoster) { poster in
                GalleryPosterDetailView(
                    dependencies: dependencies, media: media, profiles: profiles,
                    poster: poster,
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
    }

    /// 加载中和失败空态也放进统一滚动容器里，保证始终可以下拉刷新。
    @ViewBuilder
    private func galleryPlaceholderContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
        feedState.posters.filter { !deletedPosterIDs.contains($0.id) }
    }

    private var visiblePosterIDs: [Int] {
        visiblePosters.map(\.id)
    }

    /// 进入可见列表尾部若干条时触发的预取集合。
    ///
    /// 预取负责后台准备下一页；列表追加由末尾触发，滚动条比例和当前位置保持稳定。
    private var prefetchTriggerPosterID: Int? {
        guard prefetchTriggerThreshold > 0, !visiblePosters.isEmpty else { return nil }
        return visiblePosters[max(visiblePosters.count - prefetchTriggerThreshold, 0)].id
    }

    /// 刷新完成后，把滚动位置尽量恢复到刷新前的顶部帖子。
    ///
    /// 如果原帖子还在，就精确恢复；如果已经不在当前列表里，则退回到当前列表第一条，
    /// 至少避免页面直接跳到完全不可预期的位置。
    private func restoreScrollPositionIfNeeded(with proxy: ScrollViewProxy, availableIDs: [Int]) {
        guard let pendingRestorePosterID else { return }

        if availableIDs.contains(pendingRestorePosterID) {
            Task { @MainActor in
                scrollToTopPoster(pendingRestorePosterID, with: proxy)
                self.pendingRestorePosterID = nil
            }
        } else if let fallbackID = availableIDs.first {
            Task { @MainActor in
                scrollToTopPoster(fallbackID, with: proxy)
                self.pendingRestorePosterID = nil
            }
        } else {
            self.pendingRestorePosterID = nil
        }
    }

    /// 无动画滚回指定帖子顶部。
    ///
    /// 这里禁用动画是有意的：刷新完成后的补位应该尽量“静默”，否则用户会明显感知到
    /// 页面被强行滚动。
    private func scrollToTopPoster(_ posterID: Int, with proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(posterID, anchor: .top)
        }
    }

}

#endif
