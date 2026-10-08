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
    private var pageSearchQuery: GallerySearchQuery?
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

    func cancelPendingOperations() {
        interactionTasks.values.forEach { $0.cancel() }
        interactionTasks.removeAll()
        interactionTaskTokens.removeAll()
        recommendPrefetch.reset()
        for feed in GalleryFeedKind.allCases {
            refreshGenerations[feed] = (refreshGenerations[feed] ?? 0) &+ 1
            setState(for: feed) {
                if $0.status == .loading { $0.status = $0.posters.isEmpty ? .idle : .loaded }
                $0.isLoadingMore = false
            }
        }
        cancelSearchOperations()
    }

    func cancelSearchOperations() {
        for key in ["search", "search-load-more"] {
            interactionTasks[key]?.cancel()
            interactionTasks[key] = nil
            interactionTaskTokens[key] = nil
        }
        searchGeneration &+= 1
        if searchState.status == .loading { searchState.status = searchState.posters.isEmpty ? .idle : .loaded }
        searchState.isLoadingMore = false
    }

    /// 将页面回调创建的非结构化任务收归 ViewModel，避免视图销毁后遗留请求。
    @discardableResult
    func enqueueRefresh(for feed: GalleryFeedKind) -> Task<Void, Never> {
        return enqueueInteractionTask(key: "refresh:\(feed.rawValue)") { [weak self] in
            await self?.refresh(feed: feed)
        }
    }

    func enqueuePrefetch(for feed: GalleryFeedKind, currentPoster: CommunityPoster) {
        enqueueInteractionTask(key: "prefetch:\(feed.rawValue)") { [weak self] in
            await self?.prefetchIfNeeded(for: feed, currentPoster: currentPoster)
        }
    }

    @discardableResult
    func enqueueLoadMore(for feed: GalleryFeedKind, currentPoster: CommunityPoster) -> Task<Void, Never> {
        return enqueueInteractionTask(key: "load-more:\(feed.rawValue)") { [weak self] in
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

    @discardableResult
    func enqueueSearch() -> Task<Void, Never> {
        enqueueInteractionTask(key: "search", replacingCurrent: true) { [weak self] in
            await self?.performSearch()
        }
    }

    func enqueueSearchLoadMore(currentPoster: CommunityPoster) {
        enqueueInteractionTask(key: "search-load-more") { [weak self] in
            await self?.loadMoreSearchResultsIfNeeded(currentPoster: currentPoster)
        }
    }

    @discardableResult
    private func enqueueInteractionTask(
        key: String,
        replacingCurrent: Bool = false,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        if !replacingCurrent, let running = interactionTasks[key] { return running }
        interactionTasks[key]?.cancel()
        let token = UUID()
        interactionTaskTokens[key] = token
        let task = Task { @MainActor [weak self] in
            await operation()
            guard let self, self.interactionTaskTokens[key] == token else { return }
            self.interactionTasks[key] = nil
            self.interactionTaskTokens[key] = nil
        }
        interactionTasks[key] = task
        return task
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
    /// 刷新失败和取消恢复请求开始前的快照，保持已有内容和分页位置。
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
                try Task.checkCancellation()
                guard refreshGenerations[feed] == generation else { return }
                setState(for: feed) {
                    $0.posters = batch.items
                    $0.status = .loaded
                    $0.nextPage = batch.nextSourcePage
                    $0.canLoadMore = batch.canLoadMore
                }
            } else {
                if feed == .recommend {
                    // 首屏沿源游标跳过过滤空页，可见内容发布后继续后台预取。
                    var sourcePage = 0
                    var batch = try await service.fetchRecommendPage(sourcePage: sourcePage)
                    while batch.items.isEmpty, batch.canLoadMore {
                        try Task.checkCancellation()
                        guard refreshGenerations[feed] == generation else { return }
                        guard batch.nextSourcePage > sourcePage else { throw GalleryServiceError.invalidResponse }
                        sourcePage = batch.nextSourcePage
                        batch = try await service.fetchRecommendPage(sourcePage: sourcePage)
                    }
                    try Task.checkCancellation()
                    guard refreshGenerations[feed] == generation else { return }
                    let uniquePosters = try await Self.deduplicateInBackground(batch.items)
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
                    let batch = try await service.fetchFeed(kind: feed, page: nil)
                    try Task.checkCancellation()
                    guard refreshGenerations[feed] == generation else { return }
                    let uniquePosters = try await Self.deduplicateInBackground(batch.items)
                    guard refreshGenerations[feed] == generation else { return }
                    setState(for: feed) {
                        $0.posters = uniquePosters
                        $0.status = .loaded
                        $0.nextPage = batch.nextSourcePage
                        $0.canLoadMore = batch.canLoadMore
                    }
                }
            }
        } catch {
            guard refreshGenerations[feed] == generation else { return }
            let cancelled = isGalleryCancellation(error)
            setState(for: feed) {
                $0.posters = previousState.posters
                $0.status = previousState.posters.isEmpty ? (cancelled ? .idle : .failed(error.localizedDescription)) : .loaded
                $0.isLoadingMore = false
                $0.nextPage = previousState.nextPage
                $0.canLoadMore = previousState.canLoadMore && (cancelled || !previousState.posters.isEmpty)
            }
            if cancelled { return }
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
                try Task.checkCancellation()
                guard refreshGenerations[feed] == generation else { return }
                let mergedPosters = try await Self.mergeUniqueInBackground(existing: state.posters, incoming: batch.items)
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

                // 推荐流允许在一次分页里继续请求后续页面，直到得到可展示的新帖子。
                while canLoadMore, mergedPosters.count == state.posters.count {
                    let batch: GalleryPrefetchedPage
                    batch = try await recommendPrefetch.takePage(for: nextPage)
                    try Task.checkCancellation()
                    guard refreshGenerations[feed] == generation else { return }
                    guard !batch.canLoadMore || batch.nextPage > nextPage else { throw GalleryServiceError.invalidResponse }

                    mergedPosters = try await Self.mergeUniqueInBackground(existing: mergedPosters, incoming: batch.posters)
                    nextPage = batch.nextPage
                    canLoadMore = batch.canLoadMore
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
                let batch = try await service.fetchFeed(kind: feed, page: state.nextPage)
                try Task.checkCancellation()
                guard refreshGenerations[feed] == generation else { return }
                let mergedPosters = try await Self.mergeUniqueInBackground(existing: state.posters, incoming: batch.items)
                guard refreshGenerations[feed] == generation else { return }
                setState(for: feed) {
                    $0.posters = mergedPosters
                    $0.isLoadingMore = false
                    $0.nextPage = batch.nextSourcePage
                    $0.canLoadMore = batch.canLoadMore
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
        let query = searchQuery
        let previousState = searchState
        searchState.status = .loading
        searchState.resetPagination()

        do {
            let batch = try await service.searchPosters(query: query, page: nil)
            try Task.checkCancellation()
            guard searchGeneration == generation else { return }
            let uniquePosters = try await Self.deduplicateInBackground(batch.items)
            guard searchGeneration == generation else { return }
            searchState.applyFirstPage(uniquePosters)
            pageSearchQuery = query
            searchState.nextPage = batch.nextSourcePage
            searchState.canLoadMore = batch.canLoadMore
            searchState.status = .loaded
        } catch {
            guard searchGeneration == generation else { return }
            if isGalleryCancellation(error) {
                searchState = previousState
                if previousState.status == .loading {
                    searchState.status = previousState.posters.isEmpty ? .idle : .loaded
                    searchState.isLoadingMore = false
                }
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
        guard let currentPoster, let query = pageSearchQuery else { return }
        let generation = searchGeneration

        guard
            searchState.status == .loaded,
            searchState.shouldLoadMore(currentID: currentPoster.id)
        else {
            return
        }

        searchState.isLoadingMore = true

        do {
            let batch = try await service.searchPosters(query: query, page: searchState.nextPage)
            try Task.checkCancellation()
            guard searchGeneration == generation else { return }
            let mergedPosters = try await Self.mergeUniqueInBackground(existing: searchState.posters, incoming: batch.items)
            guard searchGeneration == generation else { return }
            searchState.posters = mergedPosters
            searchState.isLoadingMore = false
            searchState.nextPage = batch.nextSourcePage
            searchState.canLoadMore = batch.canLoadMore
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
