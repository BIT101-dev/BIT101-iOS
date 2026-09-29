import Combine
import Foundation

private func isGalleryMessageCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

/// 本地保存的消息已读快照。
///
/// 服务端提供分类未读数，客户端按账号保存逐条消息的“伪新消息”状态。
struct GalleryMessageReadSnapshot: Codable, Equatable {
    var latestIDsByType: [String: [Int]] = [:]
    var seenIDsByType: [String: [Int]] = [:]
}

/// 本地消息已读仓库。
///
    /// 记录“当前分类最新一批消息”和“已被用户手动标记已读的消息”；系统通知申请保持独立。
final class GalleryMessageReadStore {
    static let shared = GalleryMessageReadStore()

    private let snapshotStore = AccountScopedCodableStore<GalleryMessageReadSnapshot>(
        keyPrefix: "gallery.message.read.snapshot"
    )

    private init() {}

    /// 读取当前账号对应的本地快照。
    ///
    /// 这里故意完全按账号隔离，避免切换学号后把上一个账号的消息已读状态串过来。
    private func loadSnapshot() -> GalleryMessageReadSnapshot {
        snapshotStore.load() ?? GalleryMessageReadSnapshot()
    }

    /// 回写当前账号的本地快照。
    private func saveSnapshot(_ snapshot: GalleryMessageReadSnapshot, shouldSync: Bool = true) {
        snapshotStore.save(snapshot)
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
    /// 当服务端未读数为 0 时保留本地结果，让用户打开列表后继续看到当前的新消息样式。
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
    private var readStateObserverTask: Task<Void, Never>?
    private var listGenerations: [GalleryMessageType: Int] = [:]

    /// 集中初始化服务和已读仓库，供构造器复用。
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
        readStateObserverTask?.cancel()
    }

    private func observeSyncedReadState() {
        readStateObserverTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .galleryMessageReadStateDidChange) {
                guard let self else { return }
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
    /// 未读摘要用于悬浮按钮角标；请求失败时保持当前状态，错误提示继续留空。
    func refreshUnreadCounts() async {
        do {
            unreadCounts = try await service.fetchMessageUnreadCounts()
        } catch {
            if isGalleryMessageCancellation(error) { return }
        }
    }

    /// 刷新当前选中的消息分类。
    func refreshSelectedType() async {
        await refresh(type: selectedType)
    }

    /// 从第一页重新拉取指定消息分类。
    ///
    /// 首次分页会清空该分类未读数，成功后同步刷新摘要。
    func refresh(type: GalleryMessageType) async {
        let previousState = state(for: type)
        if previousState.status == .loading {
            return
        }

        let generation = (listGenerations[type] ?? 0) &+ 1
        listGenerations[type] = generation

        let serverUnreadBeforeFetch = unreadCounts.unreadCount(for: type)

        setState(for: type) {
            $0.status = .loading
            $0.resetCursorPagination()
        }

        do {
            let messages = try await service.fetchMessages(type: type, lastID: nil)
            guard listGenerations[type] == generation else { return }
            readStore.replaceLatestIDs(messages.map(\.id), unreadCount: serverUnreadBeforeFetch, for: type)
            setState(for: type) {
                $0.applyFirstCursorPage(messages)
                $0.status = .loaded
            }
            localReadVersion += 1
            await refreshUnreadCounts()
        } catch {
            guard listGenerations[type] == generation else { return }
            if isGalleryMessageCancellation(error) {
                setState(for: type) {
                    $0.items = previousState.items
                    $0.status = previousState.items.isEmpty ? .idle : .loaded
                    $0.isLoadingMore = false
                    $0.nextCursor = previousState.nextCursor
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
    /// 操作写入本地；服务端分类未读数在首次拉列表时清零。
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
    /// 消息列表分页继续沿用 `last_id` 语义；新页追加到末尾，消息分页按需加载。
    func loadMoreIfNeeded(for type: GalleryMessageType, currentMessage: GalleryMessage?) async {
        guard let currentMessage else { return }
        let state = state(for: type)
        let generation = listGenerations[type] ?? 0

        guard state.status == .loaded,
              state.shouldLoadMore(currentID: currentMessage.id)
        else { return }

        setState(for: type) { $0.isLoadingMore = true }

        do {
            let messages = try await service.fetchMessages(type: type, lastID: state.nextCursor)
            guard listGenerations[type] == generation else { return }
            setState(for: type) {
                $0.appendCursorPage(messages)
            }
        } catch {
            guard listGenerations[type] == generation else { return }
            if isGalleryMessageCancellation(error) {
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
