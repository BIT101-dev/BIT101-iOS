import Foundation
import Combine

public nonisolated struct CommunityResourceMetrics: Sendable {
    public let objectID: String
    public var likeNum: Int?
    public var commentNum: Int?
    public var rate: Double?
    public var needsRefresh: Bool { likeNum == nil && commentNum == nil && rate == nil }
    public init(objectID: String, likeNum: Int? = nil, commentNum: Int? = nil, rate: Double? = nil) {
        self.objectID = objectID; self.likeNum = likeNum; self.commentNum = commentNum; self.rate = rate
    }
}

public nonisolated protocol CommunityResourceItem: Identifiable, Equatable {
    var communityObjectID: String { get }
    var likeNum: Int { get }
    var commentNum: Int { get }
    var communityRate: Double? { get }
    func updatingCommunityMetrics(_ metrics: CommunityResourceMetrics) -> Self
}

extension CommunityResourceItem {
    public nonisolated var communityRate: Double? { nil }
}

public protocol CommunityResourceObserving {
    var resourceChanges: AnyPublisher<CommunityResourceMetrics, Never> { get }
}

extension CommunityResourceObserving {
    public var resourceChanges: AnyPublisher<CommunityResourceMetrics, Never> { Empty().eraseToAnyPublisher() }
}

/// 账号内共享已确认的交互计数，读取沿请求开始时的修订合并。
@MainActor
public final class CommunityResourceUpdates<Owner: Equatable> {
    private let currentOwner: () -> Owner
    private var owner: Owner
    private var revision: UInt64 = 0
    private struct Confirmed {
        var metrics: CommunityResourceMetrics
        var likeRevision: UInt64 = 0
        var commentRevision: UInt64 = 0
        var rateRevision: UInt64 = 0
    }
    private var confirmed: [String: Confirmed] = [:]
    private let subject = PassthroughSubject<CommunityResourceMetrics, Never>()

    public init(currentOwner: @escaping () -> Owner) { self.currentOwner = currentOwner; owner = currentOwner() }

    public var changes: AnyPublisher<CommunityResourceMetrics, Never> {
        let observed = currentOwner()
        return subject.filter { [weak self] _ in self?.currentOwner() == observed }.eraseToAnyPublisher()
    }

    public func beginRead() -> UInt64 { selectOwner(); return revision }

    public func confirmLike(objectID: String, count: Int) {
        selectOwner(); revision &+= 1
        var value = confirmed[objectID] ?? Confirmed(metrics: .init(objectID: objectID))
        value.metrics.likeNum = count; value.likeRevision = revision
        confirmed[objectID] = value
        subject.send(.init(objectID: objectID, likeNum: count))
    }

    public func invalidateComments(objectID: String) {
        selectOwner(); revision &+= 1
        var value = confirmed[objectID] ?? Confirmed(metrics: .init(objectID: objectID))
        value.metrics.commentNum = nil; value.metrics.rate = nil
        value.commentRevision = revision; value.rateRevision = revision
        confirmed[objectID] = value
        subject.send(.init(objectID: objectID))
    }

    public func resolve<Item: CommunityResourceItem>(_ item: Item, since started: UInt64) -> Item {
        selectOwner()
        var metrics = CommunityResourceMetrics(objectID: item.communityObjectID,
            likeNum: item.likeNum, commentNum: item.commentNum, rate: item.communityRate)
        if var pending = confirmed[item.communityObjectID] {
            Self.merge(&metrics.likeNum, confirmed: &pending.metrics.likeNum, revision: &pending.likeRevision, since: started)
            Self.merge(&metrics.commentNum, confirmed: &pending.metrics.commentNum, revision: &pending.commentRevision, since: started)
            Self.merge(&metrics.rate, confirmed: &pending.metrics.rate, revision: &pending.rateRevision, since: started)
            confirmed[item.communityObjectID] = pending
        }
        subject.send(metrics)
        return item.updatingCommunityMetrics(metrics)
    }

    private static func merge<Value>(_ value: inout Value?, confirmed: inout Value?, revision: inout UInt64, since started: UInt64) {
        if revision > started { value = confirmed ?? value }
        else { confirmed = value; revision = started }
    }

    private func selectOwner() {
        let selected = currentOwner()
        guard selected != owner else { return }
        owner = selected; revision = 0; confirmed.removeAll()
    }
}

/// 连续四个非空源页缺少新标识时终止当前分页，调用方保留已加载内容和重试位置。
public struct CommunityPageProgress<ID: Hashable> {
    private let known: Set<ID>
    private var seen: Set<ID> = []
    private var repeatedPages = 0

    public init(knownIDs: [ID] = []) { known = Set(knownIDs) }
    public init(knownIDs: Set<ID>) { known = knownIDs }

    public mutating func record(_ ids: [ID], knownIDs: Set<ID> = []) throws {
        guard !ids.isEmpty else { return }
        let previousCount = seen.count
        seen.formUnion(ids.filter { !known.contains($0) && !knownIDs.contains($0) })
        repeatedPages = seen.count == previousCount ? repeatedPages + 1 : 0
        guard repeatedPages < 4 else { throw URLError(.badServerResponse) }
    }
}

public struct CommunityPageRequest<ID: Hashable> {
    public private(set) var sourcePage: Int

    public init(sourcePage: Int) { self.sourcePage = sourcePage }

    @MainActor
    public mutating func next<Item: Identifiable>(
        isCurrent: () -> Bool, knownIDs: () -> Set<ID>,
        fetch: (Int) async throws -> [Item]
    ) async throws -> [Item]? where Item.ID == ID {
        var progress = CommunityPageProgress<ID>()
        while true {
            try Task.checkCancellation()
            let items = try await fetch(sourcePage)
            try Task.checkCancellation()
            guard isCurrent() else { return nil }
            let known = knownIDs()
            try progress.record(items.map(\.id), knownIDs: known)
            if items.isEmpty || items.contains(where: { !known.contains($0.id) }) { return items }
            sourcePage += 1
        }
    }
}

/// 分页追加沿增量标识索引去重，整体替换时重建索引。
public nonisolated struct CommunityPagedItems<Item: Identifiable> {
    public private(set) var items: [Item] = []
    public private(set) var ids: Set<Item.ID> = []
    public init() {}
    public mutating func replace(with values: [Item]) { items = []; ids = []; append(values) }
    public mutating func append(_ values: [Item]) {
        items.append(contentsOf: values.filter { ids.insert($0.id).inserted })
    }
}

extension CommunityPagedItems where Item: CommunityResourceItem {
    @discardableResult public mutating func apply(_ metrics: CommunityResourceMetrics) -> Bool {
        guard let index = items.firstIndex(where: { $0.communityObjectID == metrics.objectID }) else { return false }
        let updated = items[index].updatingCommunityMetrics(metrics)
        guard items[index] != updated else { return false }
        items[index] = updated
        return true
    }
}

public protocol CommunityItemsState {
    associatedtype Item: Identifiable
    var pagedItems: CommunityPagedItems<Item> { get set }
}

extension CommunityItemsState {
    public var items: [Item] {
        get { pagedItems.items }
        set { pagedItems.replace(with: newValue) }
    }
    public mutating func appendUniqueItems(_ newItems: [Item]) { pagedItems.append(newItems) }
}

/// 页码分页列表共享的最小状态契约。
public protocol PagedItemsState: CommunityItemsState {
    var nextPage: Int { get set }
    var isLoadingMore: Bool { get set }
    var canLoadMore: Bool { get set }
}

extension PagedItemsState {
    public mutating func resetPagination() {
        items = []
        nextPage = 0
        isLoadingMore = false
        canLoadMore = true
    }

    public mutating func applyFirstPage(_ newItems: [Item]) {
        pagedItems.replace(with: newItems)
        nextPage = 1
        isLoadingMore = false
        canLoadMore = !newItems.isEmpty
    }

    public mutating func appendPage(_ newItems: [Item]) {
        appendUniqueItems(newItems)
        nextPage += 1
        isLoadingMore = false
        canLoadMore = !newItems.isEmpty
    }
}

private func shouldLoadMoreItems<Item: Identifiable>(
    items: [Item],
    currentID: Item.ID,
    isLoadingMore: Bool,
    canLoadMore: Bool,
    preloadCount: Int
) -> Bool {
    guard preloadCount > 0 else { return false }
    return !isLoadingMore &&
        canLoadMore &&
        items.suffix(preloadCount).contains(where: { $0.id == currentID })
}

extension PagedItemsState where Item: Identifiable {
    public func shouldLoadMore(currentID: Item.ID, preloadCount: Int = 4) -> Bool {
        shouldLoadMoreItems(
            items: items,
            currentID: currentID,
            isLoadingMore: isLoadingMore,
            canLoadMore: canLoadMore,
            preloadCount: preloadCount
        )
    }
}

/// 使用“最后一项 ID”作为游标的分页列表状态契约。
///
/// 消息中心和页码列表使用不同分页协议，加载更多的状态转移保持一致；
/// 公共分页协议提供列表操作；页码与后端游标由具体分页状态分别表示。
public protocol CursorPagedItemsState: CommunityItemsState {
    associatedtype Cursor: Equatable where Item.ID == Cursor

    var nextCursor: Cursor? { get set }
    var isLoadingMore: Bool { get set }
    var canLoadMore: Bool { get set }
}

extension CursorPagedItemsState {
    public func shouldLoadMore(currentID: Item.ID, preloadCount: Int = 4) -> Bool {
        shouldLoadMoreItems(
            items: items,
            currentID: currentID,
            isLoadingMore: isLoadingMore,
            canLoadMore: canLoadMore,
            preloadCount: preloadCount
        )
    }

    public mutating func resetCursorPagination() {
        items = []
        nextCursor = nil
        isLoadingMore = false
        canLoadMore = true
    }

    public mutating func applyFirstCursorPage(_ newItems: [Item]) {
        pagedItems.replace(with: newItems)
        nextCursor = newItems.last?.id
        isLoadingMore = false
        canLoadMore = !newItems.isEmpty
    }

    public mutating func appendCursorPage(_ newItems: [Item]) {
        let cursorAdvanced = newItems.last.map { $0.id != nextCursor && !pagedItems.ids.contains($0.id) } ?? false
        pagedItems.append(newItems)
        nextCursor = newItems.last?.id ?? nextCursor
        isLoadingMore = false
        canLoadMore = cursorAdvanced
    }
}
