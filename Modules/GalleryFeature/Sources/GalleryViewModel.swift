import TransportCore
import DesignSystemKit
import CommunityCore
//
//  GalleryViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

/// 文件内统一使用的取消错误判断。
///
/// 话廊模块大量使用 Swift Concurrency 和 URLSession；二者的取消错误类型存在差异，
/// 因此在文件级收敛成一个 helper，避免每个调用点重复写同样的判断。
private func isGalleryCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}
@MainActor
/// 话廊页状态机。
///
/// 同时管理五个 feed 和一个搜索结果页，并显式处理分页、刷新和取消错误。
final class GalleryViewModel: ObservableObject {
    /// 当前选中的 feed。
    @Published var selectedFeed: GalleryFeedKind = .recommend
    /// 搜索页当前条件。
    @Published var searchQuery = GallerySearchQuery()
    /// 搜索结果列表状态。
    @Published var searchState = GalleryFeedState()
    /// 是否展示搜索页。
    @Published var isShowingSearch = false
    /// 统一错误提示。
    @Published var alert: AppAlert?

    /// 各 feed 的完整状态字典。
    @Published private(set) var feedStates: [GalleryFeedKind: GalleryFeedState] = {
        var states: [GalleryFeedKind: GalleryFeedState] = [:]
        GalleryFeedKind.allCases.forEach { states[$0] = GalleryFeedState() }
        return states
    }()

    private let service: any GalleryFeedServicing
    private let recommendPrefetch: GalleryRecommendPrefetchCoordinator
    private var refreshGenerations: [GalleryFeedKind: Int] = [:]
    private var searchGeneration = 0
    private var interactionTasks: [String: Task<Void, Never>] = [:]
    private var interactionTaskTokens: [String: UUID] = [:]

    init(service: any GalleryFeedServicing) {
        self.service = service
        recommendPrefetch = GalleryRecommendPrefetchCoordinator(service: service)
    }


    deinit {
        interactionTasks.values.forEach { $0.cancel() }
    }

    /// 将页面回调创建的非结构化任务收归 ViewModel，避免视图销毁后遗留请求。
    func enqueueRefresh(for feed: GalleryFeedKind) {
        enqueueInteractionTask(key: "refresh:\(feed.rawValue)") { [weak self] in
            await self?.refresh(feed: feed)
        }
    }

    func enqueuePrefetch(for feed: GalleryFeedKind, currentPoster: CommunityPoster) {
        enqueueInteractionTask(key: "prefetch:\(feed.rawValue)") { [weak self] in
            await self?.prefetchIfNeeded(for: feed, currentPoster: currentPoster)
        }
    }

    func enqueueLoadMore(for feed: GalleryFeedKind, currentPoster: CommunityPoster) {
        enqueueInteractionTask(key: "load-more:\(feed.rawValue)") { [weak self] in
            await self?.loadMoreIfNeeded(for: feed, currentPoster: currentPoster)
        }
    }

    func enqueueRetry(for feed: GalleryFeedKind) {
        enqueueInteractionTask(key: "retry:\(feed.rawValue)") { [weak self] in
            guard let self else { return }
            let state = self.state(for: feed)
            guard case .failed = state.status, state.posters.isEmpty else { return }
            await self.refresh(feed: feed)
        }
    }

    func enqueueNewestRefreshAfterComposer() {
        enqueueInteractionTask(key: "composer-refresh") { [weak self] in
            guard let self else { return }
            self.selectedFeed = .newest
            await self.refresh(feed: .newest)
        }
    }

    private func enqueueInteractionTask(
        key: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        interactionTasks[key]?.cancel()
        let token = UUID()
        interactionTaskTokens[key] = token
        interactionTasks[key] = Task { @MainActor [weak self] in
            await operation()
            guard let self, self.interactionTaskTokens[key] == token else { return }
            self.interactionTasks[key] = nil
            self.interactionTaskTokens[key] = nil
        }
    }

    /// 首次进入话题页时触发一次默认 feed 加载。
    func bootstrapIfNeeded() async {
        guard state(for: selectedFeed).status == .idle else { return }
        await refreshSelectedFeed()
    }

    /// 刷新当前选中的 feed。
    func refreshSelectedFeed() async {
        await refresh(feed: selectedFeed)
    }

    /// 从第一页重新拉取指定 feed。
    ///
    /// 取消错误恢复请求开始前的快照，保持 tab 快速切换时的 UI 状态。
    func refresh(feed: GalleryFeedKind) async {
        let previousState = state(for: feed)
        if previousState.status == .loading {
            return
        }
        let generation = (refreshGenerations[feed] ?? 0) &+ 1
        refreshGenerations[feed] = generation
        if feed == .recommend {
            recommendPrefetch.reset()
        }
        setState(for: feed) {
            $0.status = .loading
            $0.isLoadingMore = false
            $0.canLoadMore = true
            $0.nextPage = 0
        }

        do {
            if feed.isBotFeed {
                let batch = try await service.fetchBotFeed(startPage: 0)
                guard refreshGenerations[feed] == generation else { return }
                setState(for: feed) {
                    $0.posters = batch.posters
                    $0.status = .loaded
                    $0.nextPage = batch.nextSourcePage
                    $0.canLoadMore = batch.canLoadMore
                }
            } else {
                if feed == .recommend {
                    // 推荐流首屏拉取一个源页，先展示结果；更多源页交给后台预取。
                    let batch = try await service.fetchRecommendPage(sourcePage: 0)
                    guard refreshGenerations[feed] == generation else { return }
                    let uniquePosters = try await Self.deduplicateInBackground(batch.posters)
                    guard refreshGenerations[feed] == generation else { return }
                    setState(for: feed) {
                        $0.posters = uniquePosters
                        $0.status = .loaded
                        $0.nextPage = batch.nextSourcePage
                        $0.canLoadMore = batch.canLoadMore
                    }
                    if batch.canLoadMore {
                        recommendPrefetch.start(from: batch.nextSourcePage)
                    }
                } else {
                    let posters = try await service.fetchFeed(kind: feed, page: nil)
                    guard refreshGenerations[feed] == generation else { return }
                    let uniquePosters = try await Self.deduplicateInBackground(posters)
                    guard refreshGenerations[feed] == generation else { return }
                    setState(for: feed) {
                        $0.posters = uniquePosters
                        $0.status = .loaded
                        $0.nextPage = 1
                        $0.canLoadMore = !posters.isEmpty
                    }
                }
            }
        } catch {
            guard refreshGenerations[feed] == generation else { return }
            if isGalleryCancellation(error) {
                // 列表复用、tab 切换或手动重刷时，SwiftUI/URLSession 都可能取消在途任务。
                // 取消状态保持原列表，界面维持当前状态。
                setState(for: feed) {
                    $0.posters = previousState.posters
                    $0.status = previousState.posters.isEmpty ? .idle : .loaded
                    $0.isLoadingMore = false
                    $0.nextPage = previousState.nextPage
                    $0.canLoadMore = previousState.canLoadMore
                }
                return
            }
            setState(for: feed) {
                $0.posters = []
                $0.status = .failed(error.localizedDescription)
                $0.canLoadMore = false
            }
            alert = AppAlert(title: "加载话廊失败", message: error.localizedDescription)
        }
    }

    /// 推荐流接近尾部时提前预取；列表到达末项后追加下一页。
    ///
    /// 后台预取提前完成网络请求；追加页面时保持当前位置和滚动条比例。
    func prefetchIfNeeded(for feed: GalleryFeedKind, currentPoster: CommunityPoster?) async {
        guard feed == .recommend else { return }
        guard let currentPoster else { return }

        let state = state(for: feed)
        guard
            state.status == .loaded,
            state.canLoadMore,
            !state.posters.isEmpty
        else {
            return
        }
        guard state.posters.contains(where: { $0.id == currentPoster.id }) else { return }

        recommendPrefetch.start(from: state.nextPage)
    }

    /// 当用户滚动到尾部附近时触发分页加载。
    ///
    /// 普通 feed 直接请求下一页；推荐 feed 则优先消费本地预取页，必要时继续向后跳过空页。
    func loadMoreIfNeeded(for feed: GalleryFeedKind, currentPoster: CommunityPoster?) async {
        guard let currentPoster else { return }
        let generation = refreshGenerations[feed] ?? 0
        let state = state(for: feed)

        guard
            state.status == .loaded,
            state.shouldLoadMore(currentID: currentPoster.id)
        else {
            return
        }

        setState(for: feed) { $0.isLoadingMore = true }

        do {
            if feed.isBotFeed {
                let batch = try await service.fetchBotFeed(startPage: state.nextPage)
                guard refreshGenerations[feed] == generation else { return }
                let mergedPosters = try await Self.mergeUniqueInBackground(existing: state.posters, incoming: batch.posters)
                guard refreshGenerations[feed] == generation else { return }
                setState(for: feed) {
                    $0.posters = mergedPosters
                    $0.isLoadingMore = false
                    $0.nextPage = batch.nextSourcePage
                    $0.canLoadMore = batch.canLoadMore
                }
            } else if feed == .recommend {
                var mergedPosters = state.posters
                var nextPage = state.nextPage
                var canLoadMore = state.canLoadMore
                var attempt = 0

                // 推荐流允许在一次分页里继续请求后续页面，直到得到可展示的新帖子。
                while attempt < 3, canLoadMore, mergedPosters.count == state.posters.count {
                    let batch: GalleryPrefetchedPage
                    batch = try await recommendPrefetch.takePage(for: nextPage)
                    guard refreshGenerations[feed] == generation else { return }

                    mergedPosters = try await Self.mergeUniqueInBackground(existing: mergedPosters, incoming: batch.posters)
                    nextPage = batch.nextPage
                    canLoadMore = batch.canLoadMore
                    attempt += 1
                }

                guard refreshGenerations[feed] == generation else { return }
                setState(for: feed) {
                    $0.posters = mergedPosters
                    $0.isLoadingMore = false
                    $0.nextPage = nextPage
                    $0.canLoadMore = canLoadMore
                }
                if canLoadMore {
                    recommendPrefetch.start(from: nextPage)
                }
            } else {
                let posters = try await service.fetchFeed(kind: feed, page: state.nextPage)
                guard refreshGenerations[feed] == generation else { return }
                let mergedPosters = try await Self.mergeUniqueInBackground(existing: state.posters, incoming: posters)
                guard refreshGenerations[feed] == generation else { return }
                let nextPage = state.nextPage + 1
                setState(for: feed) {
                    $0.posters = mergedPosters
                    $0.isLoadingMore = false
                    $0.nextPage = nextPage
                    $0.canLoadMore = !posters.isEmpty
                }
            }
        } catch {
            guard refreshGenerations[feed] == generation else { return }
            if isGalleryCancellation(error) {
                setState(for: feed) { $0.isLoadingMore = false }
                return
            }
            setState(for: feed) { $0.isLoadingMore = false }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 执行当前搜索条件对应的首屏搜索。
    ///
    /// 搜索前会先裁剪首尾空白，确保排序和关键词状态保持一致。
    func performSearch() async {
        searchGeneration &+= 1
        let generation = searchGeneration
        let trimmed = searchQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery.text = trimmed
        let previousState = searchState
        searchState.status = .loading
        searchState.resetPagination()

        do {
            let posters = try await service.searchPosters(query: searchQuery, page: nil)
            guard searchGeneration == generation else { return }
            let uniquePosters = try await Self.deduplicateInBackground(posters)
            guard searchGeneration == generation else { return }
            searchState.applyFirstPage(uniquePosters)
            searchState.status = .loaded
        } catch {
            guard searchGeneration == generation else { return }
            if isGalleryCancellation(error) {
                searchState = previousState
                return
            }
            searchState.status = .failed(error.localizedDescription)
            searchState.canLoadMore = false
            alert = AppAlert(title: "搜索失败", message: error.localizedDescription)
        }
    }

    /// 搜索结果页的分页加载。
    ///
    /// 搜索结果按需加载；无关键词时保持预取请求链路空闲。
    func loadMoreSearchResultsIfNeeded(currentPoster: CommunityPoster?) async {
        guard let currentPoster else { return }
        let generation = searchGeneration

        guard
            searchState.status == .loaded,
            searchState.shouldLoadMore(currentID: currentPoster.id)
        else {
            return
        }

        searchState.isLoadingMore = true

        do {
            let posters = try await service.searchPosters(query: searchQuery, page: searchState.nextPage)
            guard searchGeneration == generation else { return }
            let mergedPosters = try await Self.mergeUniqueInBackground(existing: searchState.posters, incoming: posters)
            guard searchGeneration == generation else { return }
            searchState.posters = mergedPosters
            searchState.isLoadingMore = false
            searchState.nextPage += 1
            searchState.canLoadMore = !posters.isEmpty
        } catch {
            guard searchGeneration == generation else { return }
            if isGalleryCancellation(error) {
                searchState.isLoadingMore = false
                return
            }
            searchState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 读取某个 feed 的当前状态，缺省时返回空白状态。
    func state(for feed: GalleryFeedKind) -> GalleryFeedState {
        feedStates[feed] ?? GalleryFeedState()
    }

    /// 首次打开搜索页时自动触发一次默认预览搜索。
    func bootstrapSearchIfNeeded() async {
        guard searchState.status == .idle else { return }
        await performSearch()
    }

    /// 集中处理单个 feed 状态的读取、修改和回写。
    ///
    /// `GalleryFeedState` 是值类型，状态修改需要显式回写字典。
    private func setState(for feed: GalleryFeedKind, mutate: (inout GalleryFeedState) -> Void) {
        var state = feedStates[feed] ?? GalleryFeedState()
        mutate(&state)
        feedStates[feed] = state
    }

    /// 后台合并沿用调用任务的取消状态。
    @concurrent
    private static func mergeUniqueInBackground(existing: [CommunityPoster], incoming: [CommunityPoster]) async throws -> [CommunityPoster] {
        try Task.checkCancellation()
        let result = try mergeUniqueSync(existing: existing, incoming: incoming)
        try Task.checkCancellation()
        return result
    }

    @concurrent
    private static func deduplicateInBackground(_ posters: [CommunityPoster]) async throws -> [CommunityPoster] {
        try await mergeUniqueInBackground(existing: [], incoming: posters)
    }

    nonisolated private static func mergeUniqueSync(
        existing: [CommunityPoster],
        incoming: [CommunityPoster]
    ) throws -> [CommunityPoster] {
        var seenIDs = Set<Int>()
        seenIDs.reserveCapacity(existing.count + incoming.count)
        var merged = existing
        merged.reserveCapacity(existing.count + incoming.count)

        for (index, poster) in existing.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            seenIDs.insert(poster.id)
        }

        for (index, poster) in incoming.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if seenIDs.insert(poster.id).inserted {
                merged.append(poster)
            }
        }

        return merged
    }


}

