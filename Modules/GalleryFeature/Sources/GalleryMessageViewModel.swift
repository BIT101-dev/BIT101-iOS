import TransportCore
import DesignSystemKit
import CommunityCore
import Combine
import Foundation
import OSLog

private func isGalleryMessageCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

private enum GalleryMessagePersistenceError: LocalizedError {
    case unavailable
    case unreadable
    case unreadSummary(String)
    case recoveryLimit
    case changingSummary
    var errorDescription: String? {
        switch self {
        case .unavailable: "消息已读状态保存失败，原记录已保留，请重试。"
        case .unreadable: "消息已读状态读取失败，原记录已保留，请重试。"
        case .unreadSummary(let reason): "未读消息摘要读取失败：\(reason)"
        case .recoveryLimit: "消息恢复达到处理上限，未读记录已保留，请继续刷新。"
        case .changingSummary: "消息持续更新，请稍后刷新。"
        }
    }
}

@MainActor
/// 消息中心状态机。
///
/// 负责未读数、分类切换和按 `last_id` 分页加载消息列表。
final class GalleryMessageViewModel: ObservableObject {
    @Published var selectedType: GalleryMessageType = .comment
    /// 服务端返回的分类未读摘要。
    @Published private(set) var unreadCounts = GalleryMessageUnreadCounts()
    @Published private(set) var unreadCountsFailure: String?
    private static let logger = Logger(subsystem: "BIT101-dev.BIT101-iOS", category: "GalleryMessages")
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
    @Published private var completedRefreshGenerations: [GalleryMessageType: Int] = [:]
    private var listGenerations: [GalleryMessageType: Int] = [:]
    private var unreadGeneration = 0
    private var posterGeneration = 0
    private var refreshingTypes: Set<GalleryMessageType> = []

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
            let sum = partialResult.addingReportingOverflow(max(0, unreadCount(for: type)))
            return sum.overflow ? Int.max : sum.partialValue
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
    /// 未读摘要用于悬浮按钮角标；请求失败时保留摘要并记录恢复原因。
    func refreshUnreadCounts() async {
        unreadGeneration &+= 1
        let generation = unreadGeneration
        do {
            let counts = try await service.fetchMessageUnreadCounts()
            try Task.checkCancellation()
            guard unreadGeneration == generation else { return }
            unreadCounts = counts
            unreadCountsFailure = nil
        } catch {
            if isGalleryMessageCancellation(error) { return }
            guard unreadGeneration == generation else { return }
            unreadCountsFailure = error.localizedDescription
            Self.logger.error("Unread summary failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 刷新当前选中的消息分类。
    func refreshSelectedType() async {
        if unreadCountsFailure != nil { await refreshUnreadCounts() }
        await refresh(type: selectedType)
    }

    func paginationTaskID(for type: GalleryMessageType) -> String? {
        let state = state(for: type)
        guard state.status == .loaded else { return nil }
        return "\(completedRefreshGenerations[type] ?? 0)-\(state.nextCursor ?? 0)"
    }

    /// 从第一页重新拉取指定消息分类。
    ///
    /// 首次分页会清空该分类未读数，成功后同步刷新摘要。
    func refresh(type: GalleryMessageType) async {
        guard refreshingTypes.insert(type).inserted else { return }
        defer {
            refreshingTypes.remove(type)
            setState(for: type) { $0.isLoadingMore = false }
            completedRefreshGenerations[type] = listGenerations[type]
        }
        let previousState = state(for: type)
        let generation = (listGenerations[type] ?? 0) &+ 1
        listGenerations[type] = generation
        unreadGeneration &+= 1
        let serverUnreadBeforeFetch = unreadCounts.unreadCount(for: type)
        let session = readStore.currentSession
        let deadline = ContinuousClock.now.advanced(by: .seconds(URLSessionConfiguration.default.timeoutIntervalForRequest))
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard listGenerations[type] == generation, session == readStore.currentSession else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw GalleryMessagePersistenceError.recoveryLimit }
        }
        func show(_ messages: [GalleryMessage]) {
            var page = GalleryMessageListState()
            page.applyFirstCursorPage(messages)
            page.status = .loaded
            page.isLoadingMore = true
            listStates[type] = page
        }
        setState(for: type) { $0.status = .loading; $0.resetCursorPagination() }
        do {
            if let unreadCountsFailure { throw GalleryMessagePersistenceError.unreadSummary(unreadCountsFailure) }
            guard await readStore.prepareSnapshot() else { throw GalleryMessagePersistenceError.unreadable }
            try checkCurrent()
            var first = try await service.fetchMessages(type: type, lastID: Int.max)
            try checkCurrent()
            show(first)
            var currentUnread = try await service.fetchMessageUnreadCounts().unreadCount(for: type)
            try checkCurrent()
            var unreadLimit = serverUnreadBeforeFetch
            if currentUnread > unreadLimit {
                unreadLimit = currentUnread
                first = try await service.fetchMessages(type: type, lastID: Int.max)
                try checkCurrent()
                show(first)
                currentUnread = try await service.fetchMessageUnreadCounts().unreadCount(for: type)
                try checkCurrent()
                guard currentUnread <= unreadLimit else { throw GalleryMessagePersistenceError.changingSummary }
            }
            guard unreadLimit <= GalleryMessageReadSnapshot.maximumUnreadIDsPerType else { throw GalleryMessagePersistenceError.recoveryLimit }
            let newestID = first.map(\.id).max() ?? 0
            let ids = try await collectUnreadIDs(type: type, first: first, count: unreadLimit, after: nil, checkCurrent: checkCurrent)
            guard await readStore.replaceLatestIDs(ids, unreadCount: unreadLimit, for: type) else { throw GalleryMessagePersistenceError.unavailable }
            try checkCurrent()
            if unreadLimit > 0 {
                let boundary = min(readStore.pendingUnreadAfterID(for: type) ?? newestID, newestID)
                guard await readStore.setPendingUnreadAfterID(boundary, for: type) else { throw GalleryMessagePersistenceError.unavailable }
                try checkCurrent()
                let confirmed = try await service.fetchMessages(type: type, lastID: nil)
                try checkCurrent()
                let arrivals = confirmed.filter { $0.id > newestID }
                guard await readStore.replaceLatestIDs(arrivals.map(\.id), unreadCount: arrivals.count, for: type) else { throw GalleryMessagePersistenceError.unavailable }
                try checkCurrent()
                if !confirmed.isEmpty { show(confirmed) }
            }
            if let boundary = readStore.pendingUnreadAfterID(for: type) {
                let firstRecovery = try await service.fetchMessages(type: type, lastID: Int.max)
                try checkCurrent()
                let arrivals = try await collectUnreadIDs(type: type, first: firstRecovery, count: nil, after: boundary, checkCurrent: checkCurrent)
                guard await readStore.replaceLatestIDs(arrivals, unreadCount: arrivals.count, for: type) else { throw GalleryMessagePersistenceError.unavailable }
                try checkCurrent()
                guard await readStore.setPendingUnreadAfterID(nil, for: type) else { throw GalleryMessagePersistenceError.unavailable }
                try checkCurrent()
            }
            switch type {
            case .comment: unreadCounts.comment = 0
            case .follow: unreadCounts.follow = 0
            case .like: unreadCounts.like = 0
            case .system: unreadCounts.system = 0
            case .subscription: unreadCounts.subscription = 0
            }
            await refreshUnreadCounts()
        } catch {
            guard listGenerations[type] == generation, session == readStore.currentSession else { return }
            let cancelled = isGalleryMessageCancellation(error)
            if state(for: type).status == .loading {
                listStates[type] = previousState
                setState(for: type) {
                    $0.status = previousState.items.isEmpty ? (cancelled ? .idle : .failed(error.localizedDescription)) : .loaded
                }
            }
            if cancelled { return }
            alert = AppAlert(title: "加载消息失败", message: error.localizedDescription)
        }
    }

    /// 恢复保留消息标识，界面正文沿首屏和按需分页加载。
    private func collectUnreadIDs(type: GalleryMessageType, first: [GalleryMessage], count: Int?, after boundary: Int?,
                                  checkCurrent: () throws -> Void) async throws -> [Int] {
        var rows = first, ids: [Int] = [], seen: Set<Int> = []
        var previousCursor = Int.max
        while true {
            try checkCurrent()
            for row in rows where boundary.map({ row.id > $0 }) ?? true {
                if seen.insert(row.id).inserted { ids.append(row.id) }
            }
            guard ids.count <= GalleryMessageReadSnapshot.maximumUnreadIDsPerType else { throw GalleryMessagePersistenceError.recoveryLimit }
            if let count, ids.count >= count { return Array(ids.prefix(count)) }
            guard let cursor = rows.last?.id else {
                if let count, ids.count < count { throw GalleryMessagePersistenceError.changingSummary }
                return ids
            }
            guard cursor < previousCursor else { throw GalleryMessagePersistenceError.changingSummary }
            if let boundary, cursor <= boundary { return ids }
            previousCursor = cursor
            rows = try await service.fetchMessages(type: type, lastID: cursor)
        }
    }

    /// 读取某个分类的“伪新消息”未读数。
    ///
    /// 本地候选与服务端摘要可能重叠，采用两者的较大计数。
    func unreadCount(for type: GalleryMessageType) -> Int {
        _ = localReadVersion
        let localUnread = readStore.unreadCount(for: type)
        return max(localUnread, unreadCounts.unreadCount(for: type))
    }

    /// 判断某条消息是否需要按“新消息”样式展示。
    func isUnread(_ message: GalleryMessage, in type: GalleryMessageType) -> Bool {
        _ = localReadVersion
        return readStore.isUnread(id: message.id, for: type)
    }

    /// 将当前分类里已加载到页面上的消息全部标记为已读。
    ///
    /// 操作写入本地；服务端分类未读数在首次拉列表时清零。
    func markCurrentTypeAsRead() async {
        let ids = state(for: selectedType).items.map(\.id)
        guard !ids.isEmpty else { return }
        guard await readStore.markSeen(ids: ids, for: selectedType) else {
            alert = AppAlert(title: "保存消息状态失败", message: GalleryMessagePersistenceError.unavailable.localizedDescription)
            return
        }
    }

    /// 将单条消息标记为已读。
    func markMessageAsRead(_ message: GalleryMessage, in type: GalleryMessageType) async {
        guard await readStore.markSeen(ids: [message.id], for: type) else {
            alert = AppAlert(title: "保存消息状态失败", message: GalleryMessagePersistenceError.unavailable.localizedDescription)
            return
        }
    }

    func openMessage(_ message: GalleryMessage, in type: GalleryMessageType,
        using details: any GalleryPosterDetailServicing) async {
        guard !Task.isCancelled else { return }
        posterGeneration &+= 1
        let generation = posterGeneration
        let session = readStore.currentSession
        await markMessageAsRead(message, in: type)
        guard session == readStore.currentSession, !Task.isCancelled else { return }
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
