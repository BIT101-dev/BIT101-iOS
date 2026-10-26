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

@MainActor
final class GallerySubscriptionsViewModel: ObservableObject {
    let pendingOperations = CommunityDetailTasks()
    @Published private var pagedItems = CommunityPagedItems<GallerySubscription>()
    var items: [GallerySubscription] { pagedItems.items }
    @Published private(set) var status: CommunityLoadStatus = .idle
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = true
    @Published private(set) var paginationError: String?
    @Published var alert: AppAlert?
    private let service: any GallerySubscriptionServicing
    private var nextPage = 0
    private var generation = 0

    init(service: any GallerySubscriptionServicing) { self.service = service }

    func bootstrapIfNeeded() async {
        guard status == .idle else { return }
        await refresh()
    }

    func refresh() async {
        generation &+= 1
        let requestGeneration = generation
        status = .loading
        isLoadingMore = false
        do {
            let result = try await service.fetchSubscriptions(page: 0)
            guard generation == requestGeneration else { return }
            try Task.checkCancellation()
            pagedItems.replace(with: result)
            nextPage = 1
            canLoadMore = !result.isEmpty
            paginationError = nil
            status = .loaded
        } catch {
            guard generation == requestGeneration else { return }
            if TaskCancellation.matches(error) { status = items.isEmpty ? .idle : .loaded }
            else if items.isEmpty { status = .failed(error.localizedDescription) }
            else { status = .loaded; alert = AppAlert(title: "刷新收藏失败", error: error) }
        }
    }

    func loadMore() async {
        guard status == .loaded, canLoadMore, !isLoadingMore else { return }
        let requestGeneration = generation
        isLoadingMore = true
        defer { if generation == requestGeneration { isLoadingMore = false } }
        var request = CommunityPageRequest<Int>(sourcePage: nextPage)
        do {
            guard let result = try await request.next(isCurrent: { self.generation == requestGeneration },
                knownIDs: { self.pagedItems.ids },
                fetch: { try await self.service.fetchSubscriptions(page: $0) }) else { return }
            pagedItems.append(result)
            nextPage = request.sourcePage + 1
            canLoadMore = !result.isEmpty
            paginationError = nil
        } catch {
            guard generation == requestGeneration else { return }
            nextPage = request.sourcePage
            guard !TaskCancellation.matches(error) else { return }
            paginationError = error.localizedDescription
            alert = AppAlert(title: "加载收藏失败", error: error)
        }
    }
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
    private var searchStorage = GalleryFeedState()
    var searchState: GalleryFeedState {
        get { searchStorage }
        set { objectWillChange.send(); searchStorage = newValue }
        _modify { objectWillChange.send(); yield &searchStorage }
    }
    private var pageSearchQuery: GallerySearchQuery?
    var displayedQueryDescription: String? {
        guard let pageSearchQuery,
              pageSearchQuery.text != searchQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
                || pageSearchQuery.order != searchQuery.order else { return nil }
        return "\(pageSearchQuery.text.isEmpty ? "全部话题" : "“\(pageSearchQuery.text)”的话题") · \(pageSearchQuery.order.title)"
    }
    /// 是否展示搜索页。
    @Published var isShowingSearch = false
    /// 统一错误提示。
    @Published var alert: AppAlert?

    /// 各 feed 的完整状态字典。
    private var feedStorage: [GalleryFeedKind: GalleryFeedState] = {
        var states: [GalleryFeedKind: GalleryFeedState] = [:]
        GalleryFeedKind.allCases.forEach { states[$0] = GalleryFeedState() }
        return states
    }()
    private(set) var feedStates: [GalleryFeedKind: GalleryFeedState] {
        get { feedStorage }
        set { objectWillChange.send(); feedStorage = newValue }
        _modify { objectWillChange.send(); yield &feedStorage }
    }

    private let service: any GalleryFeedServicing
    private let recommendPrefetch: GalleryRecommendPrefetchCoordinator
    private var refreshGenerations: [GalleryFeedKind: Int] = [:]
    private var refreshPreviousStates: [GalleryFeedKind: GalleryFeedState] = [:]
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
            if let previousState = refreshPreviousStates[feed] {
                feedStates[feed] = previousState
            }
            refreshGenerations[feed] = (refreshGenerations[feed] ?? 0) &+ 1
            setState(for: feed) {
                if $0.status == .loading { $0.status = $0.posters.isEmpty ? .idle : .loaded }
                $0.isLoadingMore = false
            }
        }
        refreshPreviousStates.removeAll()
        cancelSearchOperations()
    }

    func contentPreferencesDidChange() {
        cancelPendingOperations()
        for feed in GalleryFeedKind.allCases { feedStates[feed] = GalleryFeedState() }
        searchState = GalleryFeedState()
        enqueueRefresh(for: selectedFeed)
        if isShowingSearch { enqueueSearch() }
    }

    /// 内存压力时回收闲置分栏，当前分栏保留阅读位置。
    func releaseInactiveFeeds() {
        for feed in GalleryFeedKind.allCases where feed != selectedFeed {
            refreshGenerations[feed] = (refreshGenerations[feed] ?? 0) &+ 1
            for key in ["refresh:\(feed.rawValue)", "load-more:\(feed.rawValue)", "prefetch:\(feed.rawValue)"] {
                interactionTasks[key]?.cancel()
                interactionTasks[key] = nil
                interactionTaskTokens[key] = nil
            }
            feedStates[feed] = GalleryFeedState()
            refreshPreviousStates[feed] = nil
        }
        if selectedFeed != .recommend { recommendPrefetch.reset() }
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
    func enqueueLoadMore(for feed: GalleryFeedKind, currentPoster: CommunityPoster?) -> Task<Void, Never> {
        return enqueueInteractionTask(key: "load-more:\(feed.rawValue)") { [weak self] in
            await self?.loadMoreIfNeeded(for: feed, currentPoster: currentPoster)
        }
    }

    @discardableResult
    func enqueueNewestRefreshAfterComposer() -> Task<Void, Never> {
        enqueueInteractionTask(key: "composer-refresh", replacingCurrent: true) { [weak self] in
            guard let self else { return }
            self.selectedFeed = .newest
            self.interactionTasks["refresh:\(GalleryFeedKind.newest.rawValue)"]?.cancel()
            await self.refresh(feed: .newest, replacingCurrent: true)
        }
    }

    @discardableResult
    func enqueueSearch() -> Task<Void, Never> {
        enqueueInteractionTask(key: "search", replacingCurrent: true) { [weak self] in
            await self?.performSearch()
        }
    }

    @discardableResult
    func enqueueSearchLoadMore(currentPoster: CommunityPoster?) -> Task<Void, Never> {
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
    func refresh(feed: GalleryFeedKind, replacingCurrent: Bool = false) async {
        if state(for: feed).status == .loading && !replacingCurrent {
            return
        }
        let previousState = refreshPreviousStates[feed] ?? state(for: feed)
        refreshPreviousStates[feed] = previousState
        let generation = (refreshGenerations[feed] ?? 0) &+ 1
        refreshGenerations[feed] = generation
        defer { if refreshGenerations[feed] == generation { refreshPreviousStates[feed] = nil } }
        if feed == .recommend {
            recommendPrefetch.reset()
        }
        setState(for: feed) {
            $0.status = .loading
            $0.paginationError = nil
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
                    $0.needsContinuation = batch.items.isEmpty && batch.canLoadMore
                }
            } else {
                if feed == .recommend {
                    // 首屏沿源游标跳过过滤空页，可见内容发布后继续后台预取。
                    var sourcePage = 0
                    var progress = CommunityPageProgress<Int>()
                    var batch = try await service.fetchRecommendPage(sourcePage: sourcePage)
                    while true {
                        try Task.checkCancellation()
                        guard refreshGenerations[feed] == generation else { return }
                        guard !batch.canLoadMore || (batch.nextSourcePage > sourcePage && !batch.sourceIDs.isEmpty)
                        else { throw GalleryServiceError.invalidResponse }
                        try progress.record(batch.sourceIDs)
                        if !batch.items.isEmpty || !batch.canLoadMore || batch.nextSourcePage >= GalleryPaging.maximumSourcePages { break }
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
                        $0.needsContinuation = uniquePosters.isEmpty && batch.canLoadMore
                    }
                    if batch.canLoadMore, !uniquePosters.isEmpty {
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
                        $0.needsContinuation = uniquePosters.isEmpty && batch.canLoadMore
                    }
                }
            }
        } catch {
            guard refreshGenerations[feed] == generation else { return }
            let cancelled = TaskCancellation.matches(error)
            setState(for: feed) {
                $0.posters = previousState.posters
                $0.status = previousState.posters.isEmpty ? (cancelled ? .idle : .failed(error.localizedDescription)) : .loaded
                $0.isLoadingMore = false
                $0.nextPage = previousState.nextPage
                $0.canLoadMore = previousState.canLoadMore && (cancelled || !previousState.posters.isEmpty)
            }
            if cancelled { return }
            alert = AppAlert(title: "加载话廊失败", error: error)
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
        let generation = refreshGenerations[feed] ?? 0
        guard
            state(for: feed).status == .loaded,
            state(for: feed).canLoadMore, !state(for: feed).isLoadingMore,
            currentPoster.map({ state(for: feed).shouldLoadMore(currentID: $0.id) }) ?? state(for: feed).posters.isEmpty
        else {
            return
        }

        setState(for: feed) { $0.isLoadingMore = true }

        do {
            let batch = try await nextVisibleBatch(startPage: state(for: feed).nextPage,
                knownIDs: state(for: feed).posterIDs, stopAfterOne: feed.isBotFeed,
                skipsEmptyPages: feed == .recommend) { page in
                let batch: GalleryPageBatch<CommunityPoster>
                if feed == .recommend {
                    let prefetched = try await recommendPrefetch.takePage(for: page)
                    batch = .init(items: prefetched.posters, nextSourcePage: prefetched.nextPage,
                        canLoadMore: prefetched.canLoadMore, sourceIDs: prefetched.sourceIDs)
                } else if feed.isBotFeed {
                    batch = try await self.service.fetchBotFeed(startPage: page)
                } else {
                    batch = try await self.service.fetchFeed(kind: feed, page: page)
                }
                guard self.refreshGenerations[feed] == generation else { throw CancellationError() }
                return batch
            }
            guard refreshGenerations[feed] == generation else { return }
            setState(for: feed) { Self.commit(batch, into: &$0) }
            if feed == .recommend, batch.canLoadMore { recommendPrefetch.start(from: batch.nextSourcePage) }

        } catch {
            guard refreshGenerations[feed] == generation else { return }
            if TaskCancellation.matches(error) {
                setState(for: feed) { $0.isLoadingMore = false }
                return
            }
            setState(for: feed) { $0.isLoadingMore = false; $0.paginationError = error.localizedDescription }
            alert = AppAlert(title: "加载更多失败", error: error)
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
        searchState.paginationError = nil
        searchState.isLoadingMore = false

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
            searchState.needsContinuation = uniquePosters.isEmpty && batch.canLoadMore
            searchState.status = .loaded
        } catch {
            guard searchGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                searchState = previousState
                if previousState.status == .loading {
                    searchState.status = previousState.posters.isEmpty ? .idle : .loaded
                    searchState.isLoadingMore = false
                }
                return
            }
            searchState = previousState
            searchState.status = previousState.posters.isEmpty ? .failed(error.localizedDescription) : .loaded
            searchState.isLoadingMore = false
            if previousState.posters.isEmpty { searchState.canLoadMore = false }
            alert = AppAlert(title: "搜索失败", error: error)
        }
    }

    /// 搜索结果页的分页加载。
    ///
    /// 搜索结果按需加载；无关键词时保持预取请求链路空闲。
    func loadMoreSearchResultsIfNeeded(currentPoster: CommunityPoster?) async {
        guard let query = pageSearchQuery else { return }
        let generation = searchGeneration

        guard
            searchState.status == .loaded,
            searchState.canLoadMore, !searchState.isLoadingMore,
            currentPoster.map({ searchState.shouldLoadMore(currentID: $0.id) }) ?? searchState.posters.isEmpty
        else {
            return
        }

        searchState.isLoadingMore = true

        do {
            let batch = try await nextVisibleBatch(startPage: searchState.nextPage, knownIDs: searchState.posterIDs) { page in
                let batch = try await self.service.searchPosters(query: query, page: page)
                guard self.searchGeneration == generation else { throw CancellationError() }
                return batch
            }
            guard searchGeneration == generation else { return }
            Self.commit(batch, into: &searchState)
        } catch {
            guard searchGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                searchState.isLoadingMore = false
                return
            }
            searchState.isLoadingMore = false
            searchState.paginationError = error.localizedDescription
            alert = AppAlert(title: "加载更多失败", error: error)
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
        mutate(&feedStates[feed, default: GalleryFeedState()])
    }

    /// 请求阶段积累新增页，完成后释放读取快照并一次性提交。
    private func nextVisibleBatch(startPage: Int, knownIDs: Set<Int>, stopAfterOne: Bool = false,
        skipsEmptyPages: Bool = false,
        fetch: (Int) async throws -> GalleryPageBatch<CommunityPoster>) async throws -> GalleryPageBatch<CommunityPoster> {
        var page = startPage
        var pending = CommunityPagedItems<CommunityPoster>()
        var progress = CommunityPageProgress(knownIDs: knownIDs)
        var canLoadMore: Bool
        repeat {
            let batch = try await fetch(page)
            try Task.checkCancellation()
            guard !batch.canLoadMore || (batch.nextSourcePage > page && !batch.sourceIDs.isEmpty)
            else { throw GalleryServiceError.invalidResponse }
            try progress.record(batch.sourceIDs)
            pending.append(batch.items.filter { !knownIDs.contains($0.id) })
            page = batch.nextSourcePage
            canLoadMore = batch.canLoadMore
            if stopAfterOne || batch.items.isEmpty && !skipsEmptyPages { break }
        } while canLoadMore && pending.items.isEmpty && page - startPage < GalleryPaging.maximumSourcePages
        return .init(items: pending.items, nextSourcePage: page, canLoadMore: canLoadMore)
    }

    private static func commit(_ batch: GalleryPageBatch<CommunityPoster>, into state: inout GalleryFeedState) {
        state.paginationError = nil
        let count = state.posters.count
        state.appendUniqueItems(batch.items)
        state.nextPage = batch.nextSourcePage
        state.canLoadMore = batch.canLoadMore
        state.isLoadingMore = false
        state.needsContinuation = batch.canLoadMore && state.posters.count == count
    }

    @concurrent
    private static func deduplicateInBackground(_ posters: [CommunityPoster]) async throws -> [CommunityPoster] {
        try Task.checkCancellation()
        var storage = CommunityPagedItems<CommunityPoster>()
        storage.append(posters)
        try Task.checkCancellation()
        return storage.items
    }
}
