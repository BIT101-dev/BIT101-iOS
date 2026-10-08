import TransportCore
import DesignSystemKit
import CommunityCore
import Combine
import Foundation

private func isGalleryMessageCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
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
    @Published var selectedPoster: CommunityPoster?
    /// 用于强制触发依赖本地已读仓库的视图刷新。
    @Published private var localReadVersion = 0

    /// 各消息分类的列表状态字典。
    @Published private(set) var listStates: [GalleryMessageType: GalleryMessageListState] = {
        var states: [GalleryMessageType: GalleryMessageListState] = [:]
        GalleryMessageType.allCases.forEach { states[$0] = GalleryMessageListState() }
        return states
    }()

    private let service: any GalleryMessageServicing
    private let readStore: any GalleryMessageReadStoring
    private var readStateObserver: AnyCancellable?
    private var listGenerations: [GalleryMessageType: Int] = [:]
    private var unreadGeneration = 0
    private var posterGeneration = 0

    /// 集中初始化服务和已读仓库，供构造器复用。
    init(service: any GalleryMessageServicing, readStore: any GalleryMessageReadStoring) {
        self.service = service
        self.readStore = readStore
        observeSyncedReadState()
    }



    private func observeSyncedReadState() {
        readStateObserver = readStore.changes
            .sink { [weak self] session in
                guard let self, session == self.readStore.currentSession else { return }
                self.localReadVersion += 1
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
        unreadGeneration &+= 1
        let generation = unreadGeneration
        do {
            let counts = try await service.fetchMessageUnreadCounts()
            try Task.checkCancellation()
            guard unreadGeneration == generation else { return }
            unreadCounts = counts
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
        unreadGeneration &+= 1

        let serverUnreadBeforeFetch = unreadCounts.unreadCount(for: type)
        let session = readStore.currentSession

        setState(for: type) {
            $0.status = .loading
            $0.resetCursorPagination()
        }

        do {
            var page = GalleryMessageListState()
            page.applyFirstCursorPage(try await service.fetchMessages(type: type, lastID: nil))
            try Task.checkCancellation()
            guard listGenerations[type] == generation, session == readStore.currentSession else { return }
            let unreadLimit = min(serverUnreadBeforeFetch, GalleryMessageReadSnapshot.maximumHistoryIDsPerType)
            while page.items.count < unreadLimit && page.canLoadMore {
                let cursor = page.nextCursor
                let messages = try await service.fetchMessages(type: type, lastID: cursor)
                try Task.checkCancellation()
                guard listGenerations[type] == generation, session == readStore.currentSession else { return }
                page.appendCursorPage(messages)
            }
            readStore.replaceLatestIDs(page.items.map(\.id), unreadCount: unreadLimit, for: type)
            page.status = .loaded
            listStates[type] = page
            switch type {
            case .comment: unreadCounts.comment = 0
            case .follow: unreadCounts.follow = 0
            case .like: unreadCounts.like = 0
            case .system: unreadCounts.system = 0
            }
            await refreshUnreadCounts()
        } catch {
            guard listGenerations[type] == generation, session == readStore.currentSession else { return }
            let cancelled = isGalleryMessageCancellation(error)
            setState(for: type) {
                $0.items = previousState.items
                $0.status = previousState.items.isEmpty ? (cancelled ? .idle : .failed(error.localizedDescription)) : .loaded
                $0.isLoadingMore = false
                $0.nextCursor = previousState.nextCursor
                $0.canLoadMore = previousState.canLoadMore && (cancelled || !previousState.items.isEmpty)
            }
            if cancelled { return }
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
    }

    /// 将单条消息标记为已读。
    func markMessageAsRead(_ message: GalleryMessage, in type: GalleryMessageType) {
        readStore.markSeen(ids: [message.id], for: type)
    }

    func openMessage(_ message: GalleryMessage, in type: GalleryMessageType,
        using details: any GalleryPosterDetailServicing) async {
        guard !Task.isCancelled else { return }
        posterGeneration &+= 1
        let generation = posterGeneration
        let session = readStore.currentSession
        markMessageAsRead(message, in: type)
        guard let posterID = message.linkedPosterID else { return }
        do {
            let poster = try await details.fetchPoster(id: posterID)
            try Task.checkCancellation()
            guard generation == posterGeneration, session == readStore.currentSession else { return }
            selectedPoster = poster.asPoster
        } catch {
            guard generation == posterGeneration, session == readStore.currentSession,
                  !Task.isCancelled, !TaskCancellation.matches(error) else { return }
            alert = AppAlert(title: "打开消息失败", message: error.localizedDescription)
        }
    }

    /// 当滚动到尾部附近时触发分页加载。
    ///
    /// 消息列表分页继续沿用 `last_id` 语义；新页追加到末尾，消息分页按需加载。
    func loadMoreIfNeeded(for type: GalleryMessageType, currentMessage: GalleryMessage?) async {
        guard let currentMessage else { return }
        let state = state(for: type)
        let generation = listGenerations[type] ?? 0
        let session = readStore.currentSession

        guard state.status == .loaded,
              state.shouldLoadMore(currentID: currentMessage.id)
        else { return }

        setState(for: type) { $0.isLoadingMore = true }

        do {
            let messages = try await service.fetchMessages(type: type, lastID: state.nextCursor)
            try Task.checkCancellation()
            guard listGenerations[type] == generation, session == readStore.currentSession else { return }
            setState(for: type) {
                $0.appendCursorPage(messages)
            }
        } catch {
            guard listGenerations[type] == generation, session == readStore.currentSession else { return }
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
