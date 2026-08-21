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
/// 话廊模块大量使用 Swift Concurrency 和 URLSession；二者的取消错误类型并不完全一致，
/// 因此在文件级收敛成一个 helper，避免每个调用点重复写同样的判断。
private func isGalleryCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

@MainActor
/// 话题页状态机。
///
/// 同时管理四个 feed 和一个搜索结果页，并显式处理分页、刷新和取消错误。
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

    init(service: any GalleryFeedServicing) {
        self.service = service
        recommendPrefetch = GalleryRecommendPrefetchCoordinator(service: service)
    }

    convenience init() {
        self.init(service: GalleryService())
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
    /// 取消错误会恢复旧快照，避免 tab 快速切换时把 UI 误判成失败。
    func refresh(feed: GalleryFeedKind) async {
        let previousState = state(for: feed)
        if previousState.status == .loading {
            return
        }
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
                setState(for: feed) {
                    $0.posters = batch.posters
                    $0.status = .loaded
                    $0.nextPage = batch.nextSourcePage
                    $0.canLoadMore = batch.canLoadMore
                }
            } else {
                if feed == .recommend {
                    // 推荐流首屏只拉一个源页，先尽快展示；更多源页交给后台预取。
                    let batch = try await service.fetchRecommendPage(sourcePage: 0)
                    let uniquePosters = await deduplicateInBackground(batch.posters)
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
                    let uniquePosters = await deduplicateInBackground(posters)
                    setState(for: feed) {
                        $0.posters = uniquePosters
                        $0.status = .loaded
                        $0.nextPage = 1
                        $0.canLoadMore = !posters.isEmpty
                    }
                }
            }
        } catch {
            if isGalleryCancellation(error) {
                // 列表复用、tab 切换或手动重刷时，SwiftUI/URLSession 都可能主动取消旧任务。
                // 这种情况不是用户可感知的失败，不应该弹错误框。
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

    /// 推荐流在接近尾部时提前预取，但真正 append 仍然等到最后一条出现。
    ///
    /// 这样做的目的是把网络等待藏到用户还没滚到底的时候，同时避免“提前 append 新内容”
    /// 破坏当前位置和滚动条比例。
    func prefetchIfNeeded(for feed: GalleryFeedKind, currentPoster: GalleryPoster?) async {
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
    func loadMoreIfNeeded(for feed: GalleryFeedKind, currentPoster: GalleryPoster?) async {
        guard let currentPoster else { return }
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
                let mergedPosters = await mergeUniqueInBackground(existing: state.posters, incoming: batch.posters)
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

                // 推荐流允许在一次分页里向后多试几页，直到真正拿到能展示的新帖子。
                while attempt < 3, canLoadMore, mergedPosters.count == state.posters.count {
                    let batch: GalleryPrefetchedPage
                    batch = try await recommendPrefetch.takePage(for: nextPage)

                    mergedPosters = await mergeUniqueInBackground(existing: mergedPosters, incoming: batch.posters)
                    nextPage = batch.nextPage
                    canLoadMore = batch.canLoadMore
                    attempt += 1
                }

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
                let mergedPosters = await mergeUniqueInBackground(existing: state.posters, incoming: posters)
                let nextPage = state.nextPage + 1
                setState(for: feed) {
                    $0.posters = mergedPosters
                    $0.isLoadingMore = false
                    $0.nextPage = nextPage
                    $0.canLoadMore = !posters.isEmpty
                }
            }
        } catch {
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
        let trimmed = searchQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery.text = trimmed
        let previousState = searchState
        searchState.status = .loading
        searchState.resetPagination()

        do {
            let posters = try await service.searchPosters(query: searchQuery, page: nil)
            searchState.applyFirstPage(await deduplicateInBackground(posters))
            searchState.status = .loaded
        } catch {
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
    /// 搜索结果不做预取，保持实现简单并避免无关键词时产生多余请求。
    func loadMoreSearchResultsIfNeeded(currentPoster: GalleryPoster?) async {
        guard let currentPoster else { return }

        guard
            searchState.status == .loaded,
            searchState.shouldLoadMore(currentID: currentPoster.id)
        else {
            return
        }

        searchState.isLoadingMore = true

        do {
            let posters = try await service.searchPosters(query: searchQuery, page: searchState.nextPage)
            searchState.posters = await mergeUniqueInBackground(existing: searchState.posters, incoming: posters)
            searchState.isLoadingMore = false
            searchState.nextPage += 1
            searchState.canLoadMore = !posters.isEmpty
        } catch {
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

    /// 统一回写单个 feed 的可变状态，避免多个调用点直接操作字典。
    ///
    /// `GalleryFeedState` 是值类型，如果散落在多个地方直接改字典，很容易漏掉回写。
    private func setState(for feed: GalleryFeedKind, mutate: (inout GalleryFeedState) -> Void) {
        var state = feedStates[feed] ?? GalleryFeedState()
        mutate(&state)
        feedStates[feed] = state
    }

    /// 推荐流可能出现重复帖子，这里按帖子 ID 去重后再拼接。
    ///
    /// 去重和拼接放到后台队列执行，是为了避免大数组操作阻塞主线程滚动。
    private func mergeUniqueInBackground(existing: [GalleryPoster], incoming: [GalleryPoster]) async -> [GalleryPoster] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.mergeUniqueSync(existing: existing, incoming: incoming))
            }
        }
    }

    /// 首屏列表也走同一套去重逻辑，但放到后台队列执行，避免刷新时卡主滚动。
    private func deduplicateInBackground(_ posters: [GalleryPoster]) async -> [GalleryPoster] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.deduplicateSync(posters))
            }
        }
    }

    nonisolated private static func mergeUniqueSync(existing: [GalleryPoster], incoming: [GalleryPoster]) -> [GalleryPoster] {
        var seenIDs = Set(existing.map(\.id))
        var merged = existing

        for poster in incoming where seenIDs.insert(poster.id).inserted {
            merged.append(poster)
        }

        return merged
    }

    /// 首屏返回的推荐结果也可能包含重复项，先做一次稳定去重。
    nonisolated private static func deduplicateSync(_ posters: [GalleryPoster]) -> [GalleryPoster] {
        mergeUniqueSync(existing: [], incoming: posters)
    }

}

/// 本地保存的消息已读快照。
///
/// 服务端只有分类未读数，没有逐条已读状态，这里按账号做一层“伪新消息”持久化。
struct GalleryMessageReadSnapshot: Codable, Equatable {
    var latestIDsByType: [String: [Int]] = [:]
    var seenIDsByType: [String: [Int]] = [:]
}

/// 本地消息已读仓库。
///
/// 只记录“当前分类最新一批消息”和“已被用户手动标记已读的消息”，不申请系统通知。
final class GalleryMessageReadStore {
    static let shared = GalleryMessageReadStore()

    private let defaults = UserDefaults.standard
    private let keyPrefix = "gallery.message.read.snapshot"

    private init() {}

    /// 读取当前账号对应的本地快照。
    ///
    /// 这里故意完全按账号隔离，避免切换学号后把上一个账号的消息已读状态串过来。
    private func loadSnapshot() -> GalleryMessageReadSnapshot {
        guard
            let data = defaults.data(forKey: storageKey),
            let snapshot = try? JSONDecoder().decode(GalleryMessageReadSnapshot.self, from: data)
        else {
            return GalleryMessageReadSnapshot()
        }
        return snapshot
    }

    /// 回写当前账号的本地快照。
    private func saveSnapshot(_ snapshot: GalleryMessageReadSnapshot, shouldSync: Bool = true) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
        if shouldSync {
            Task { @MainActor in
                ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .galleryMessageRead)
            }
        }
    }

    func syncSnapshot() -> GalleryMessageReadSnapshot {
        loadSnapshot()
    }

    func applySyncedSnapshot(_ snapshot: GalleryMessageReadSnapshot) {
        saveSnapshot(snapshot, shouldSync: false)
        NotificationCenter.default.post(name: .galleryMessageReadStateDidChange, object: nil)
    }

    /// 用服务端给出的未读数量，重建当前分类的“候选新消息”集合。
    ///
    /// 当服务端未读数为 0 时，不主动覆盖本地结果，避免用户刚打开列表时就把视觉上的新消息全抹掉。
    func replaceLatestIDs(_ ids: [Int], unreadCount: Int, for type: GalleryMessageType) {
        guard unreadCount > 0 else { return }

        var snapshot = loadSnapshot()
        let latestUnread = Array(ids.prefix(unreadCount))
        let normalizedLatest = normalize(latestUnread)
        let existingSeen = Set(snapshot.seenIDsByType[type.rawValue] ?? [])

        snapshot.latestIDsByType[type.rawValue] = normalizedLatest
        snapshot.seenIDsByType[type.rawValue] = normalizedLatest.filter { existingSeen.contains($0) }
        saveSnapshot(snapshot)
    }

    /// 把指定消息标记为已读。
    func markSeen(ids: [Int], for type: GalleryMessageType) {
        var snapshot = loadSnapshot()
        let existing = Set(snapshot.seenIDsByType[type.rawValue] ?? [])
        snapshot.seenIDsByType[type.rawValue] = normalize(Array(existing.union(ids)))
        saveSnapshot(snapshot)
    }

    /// 当前分类本地仍被视作“新消息”的数量。
    ///
    /// 已读状态的判定规则是：出现在 latest 集合里，但还没出现在 seen 集合里。
    func unreadCount(for type: GalleryMessageType) -> Int {
        let snapshot = loadSnapshot()
        let latest = Set(snapshot.latestIDsByType[type.rawValue] ?? [])
        guard !latest.isEmpty else { return 0 }
        let seen = Set(snapshot.seenIDsByType[type.rawValue] ?? [])
        return latest.subtracting(seen).count
    }

    /// 判断某条消息是否需要按“新消息”样式展示。
    func isUnread(id: Int, for type: GalleryMessageType) -> Bool {
        let snapshot = loadSnapshot()
        let latest = Set(snapshot.latestIDsByType[type.rawValue] ?? [])
        guard latest.contains(id) else { return false }
        let seen = Set(snapshot.seenIDsByType[type.rawValue] ?? [])
        return !seen.contains(id)
    }

    private var storageKey: String {
        let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = studentID.isEmpty ? "guest" : studentID
        return "\(keyPrefix).\(suffix)"
    }

    /// 去重同时保留原始顺序。
    private func normalize(_ ids: [Int]) -> [Int] {
        Array(NSOrderedSet(array: ids)) as? [Int] ?? ids
    }
}

extension Notification.Name {
    static let galleryMessageReadStateDidChange = Notification.Name("galleryMessageReadStateDidChange")
}

@MainActor
/// 消息中心状态机。
///
/// 负责未读数、分类切换和按 `last_id` 分页加载消息列表。
final class GalleryMessageViewModel: ObservableObject {
    @Published var selectedType: GalleryMessageType = .comment
    /// 服务端返回的分类未读摘要。
    @Published private(set) var unreadCounts = GalleryMessageUnreadCounts()
    @Published var alert: AppAlert?
    /// 用于强制触发依赖本地已读仓库的视图刷新。
    @Published private var localReadVersion = 0

    /// 各消息分类的列表状态字典。
    @Published private(set) var listStates: [GalleryMessageType: GalleryMessageListState] = {
        var states: [GalleryMessageType: GalleryMessageListState] = [:]
        GalleryMessageType.allCases.forEach { states[$0] = GalleryMessageListState() }
        return states
    }()

    private let service: any GalleryMessageServicing
    private let readStore: GalleryMessageReadStore
    private var readStateObserver: NSObjectProtocol?

    /// 允许注入服务和已读仓库，方便后续测试。
    private init(service: any GalleryMessageServicing, readStore: GalleryMessageReadStore) {
        self.service = service
        self.readStore = readStore
        observeSyncedReadState()
    }

    init(service: any GalleryMessageServicing) {
        self.service = service
        readStore = .shared
        observeSyncedReadState()
    }

    convenience init() {
        self.init(service: GalleryService(), readStore: .shared)
    }

    deinit {
        if let readStateObserver {
            NotificationCenter.default.removeObserver(readStateObserver)
        }
    }

    private func observeSyncedReadState() {
        readStateObserver = NotificationCenter.default.addObserver(
            forName: .galleryMessageReadStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.localReadVersion += 1
            }
        }
    }

    /// 悬浮消息按钮使用的总未读数。
    ///
    /// 这里会把“本地伪未读”和“服务端摘要”统一折算到同一个入口红点。
    var totalUnreadCount: Int {
        GalleryMessageType.allCases.reduce(0) { partialResult, type in
            partialResult + unreadCount(for: type)
        }
    }

    /// 当前分类是否仍有本地“新消息”。
    var hasUnreadInCurrentType: Bool {
        unreadCount(for: selectedType) > 0
    }

    /// 首次进入消息页时刷新未读数，并加载默认分类。
    func bootstrapIfNeeded() async {
        await refreshUnreadCounts()
        guard state(for: selectedType).status == .idle else { return }
        await refresh(type: selectedType)
    }

    /// 单独刷新消息按钮上的未读红点。
    ///
    /// 未读摘要失败不弹错误，因为它只是悬浮按钮角标，不应该打断主流程。
    func refreshUnreadCounts() async {
        do {
            unreadCounts = try await service.fetchMessageUnreadCounts()
        } catch {
            if isGalleryCancellation(error) { return }
        }
    }

    /// 刷新当前选中的消息分类。
    func refreshSelectedType() async {
        await refresh(type: selectedType)
    }

    /// 从第一页重新拉取指定消息分类。
    ///
    /// 首次分页会顺手清空该分类未读数，所以这里在成功后同步刷新摘要。
    func refresh(type: GalleryMessageType) async {
        let previousState = state(for: type)
        if previousState.status == .loading {
            return
        }

        let serverUnreadBeforeFetch = unreadCounts.unreadCount(for: type)

        setState(for: type) {
            $0.status = .loading
            $0.isLoadingMore = false
            $0.canLoadMore = true
            $0.nextLastID = nil
        }

        do {
            let messages = try await service.fetchMessages(type: type, lastID: nil)
            readStore.replaceLatestIDs(messages.map(\.id), unreadCount: serverUnreadBeforeFetch, for: type)
            setState(for: type) {
                $0.items = messages
                $0.status = .loaded
                $0.nextLastID = messages.last?.id
                $0.canLoadMore = !messages.isEmpty
            }
            localReadVersion += 1
            await refreshUnreadCounts()
        } catch {
            if isGalleryCancellation(error) {
                setState(for: type) {
                    $0.items = previousState.items
                    $0.status = previousState.items.isEmpty ? .idle : .loaded
                    $0.isLoadingMore = false
                    $0.nextLastID = previousState.nextLastID
                    $0.canLoadMore = previousState.canLoadMore
                }
                return
            }

            setState(for: type) {
                $0.items = []
                $0.status = .failed(error.localizedDescription)
                $0.canLoadMore = false
            }
            alert = AppAlert(title: "加载消息失败", message: error.localizedDescription)
        }
    }

    /// 读取某个分类的“伪新消息”未读数。
    ///
    /// 如果本地已有候选新消息，则优先显示本地结果；否则回退到服务端分类未读数。
    func unreadCount(for type: GalleryMessageType) -> Int {
        _ = localReadVersion
        let localUnread = readStore.unreadCount(for: type)
        return localUnread > 0 ? localUnread : unreadCounts.unreadCount(for: type)
    }

    /// 判断某条消息是否需要按“新消息”样式展示。
    func isUnread(_ message: GalleryMessage, in type: GalleryMessageType) -> Bool {
        _ = localReadVersion
        return readStore.isUnread(id: message.id, for: type)
    }

    /// 将当前分类里已加载到页面上的消息全部标记为已读。
    ///
    /// 这是一个纯本地动作，不额外请求服务端；服务端真正的分类未读清零发生在首次拉列表时。
    func markCurrentTypeAsRead() {
        let ids = state(for: selectedType).items.map(\.id)
        guard !ids.isEmpty else { return }
        readStore.markSeen(ids: ids, for: selectedType)
        localReadVersion += 1
    }

    /// 将单条消息标记为已读。
    func markMessageAsRead(_ message: GalleryMessage, in type: GalleryMessageType) {
        readStore.markSeen(ids: [message.id], for: type)
        localReadVersion += 1
    }

    /// 当滚动到尾部附近时触发分页加载。
    ///
    /// 消息列表分页继续沿用 `last_id` 语义；新页直接追加到末尾，不做额外预取。
    func loadMoreIfNeeded(for type: GalleryMessageType, currentMessage: GalleryMessage?) async {
        guard let currentMessage else { return }
        let state = state(for: type)

        guard state.status == .loaded,
              state.shouldLoadMore(currentID: currentMessage.id)
        else { return }

        setState(for: type) { $0.isLoadingMore = true }

        do {
            let messages = try await service.fetchMessages(type: type, lastID: state.nextLastID)
            setState(for: type) {
                $0.appendPage(messages)
            }
        } catch {
            if isGalleryCancellation(error) {
                setState(for: type) { $0.isLoadingMore = false }
                return
            }
            setState(for: type) { $0.isLoadingMore = false }
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 读取某个分类的当前列表状态。
    func state(for type: GalleryMessageType) -> GalleryMessageListState {
        listStates[type] ?? GalleryMessageListState()
    }

    /// 统一回写单个分类的可变状态。
    private func setState(for type: GalleryMessageType, mutate: (inout GalleryMessageListState) -> Void) {
        var state = listStates[type] ?? GalleryMessageListState()
        mutate(&state)
        listStates[type] = state
    }

}
