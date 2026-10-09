import Foundation

/// 连续四个非空源页缺少新标识时终止当前分页，调用方保留已加载内容和重试位置。
public struct CommunityPageProgress<ID: Hashable> {
    private var seen: Set<ID>
    private var repeatedPages = 0

    public init(knownIDs: [ID] = []) { seen = Set(knownIDs) }
    public init(knownIDs: Set<ID>) { seen = knownIDs }

    public mutating func record(_ ids: [ID]) throws {
        guard !ids.isEmpty else { return }
        let previousCount = seen.count
        seen.formUnion(ids)
        repeatedPages = seen.count == previousCount ? repeatedPages + 1 : 0
        guard repeatedPages < 4 else { throw URLError(.badServerResponse) }
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
