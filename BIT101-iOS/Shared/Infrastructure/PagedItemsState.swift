/// 页码分页列表共享的最小状态契约。
protocol PagedItemsState {
    associatedtype Item

    var items: [Item] { get set }
    var nextPage: Int { get set }
    var isLoadingMore: Bool { get set }
    var canLoadMore: Bool { get set }
}

extension PagedItemsState {
    mutating func resetPagination() {
        items = []
        nextPage = 0
        isLoadingMore = false
        canLoadMore = true
    }

    mutating func applyFirstPage(_ newItems: [Item]) {
        items = newItems
        nextPage = 1
        isLoadingMore = false
        canLoadMore = !newItems.isEmpty
    }

    mutating func appendPage(_ newItems: [Item]) {
        items.append(contentsOf: newItems)
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
) -> Bool where Item.ID: Equatable {
    !isLoadingMore &&
        canLoadMore &&
        items.suffix(preloadCount).contains(where: { $0.id == currentID })
}

extension PagedItemsState where Item: Identifiable, Item.ID: Equatable {
    func shouldLoadMore(currentID: Item.ID, preloadCount: Int = 4) -> Bool {
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
/// 此处抽出游标分页需要的公共部分，页码和后端游标保留各自表示。
protocol CursorPagedItemsState {
    associatedtype Item: Identifiable
    associatedtype Cursor: Equatable where Item.ID == Cursor

    var items: [Item] { get set }
    var nextCursor: Cursor? { get set }
    var isLoadingMore: Bool { get set }
    var canLoadMore: Bool { get set }
}

extension CursorPagedItemsState {
    func shouldLoadMore(currentID: Item.ID, preloadCount: Int = 4) -> Bool {
        shouldLoadMoreItems(
            items: items,
            currentID: currentID,
            isLoadingMore: isLoadingMore,
            canLoadMore: canLoadMore,
            preloadCount: preloadCount
        )
    }

    mutating func resetCursorPagination() {
        items = []
        nextCursor = nil
        isLoadingMore = false
        canLoadMore = true
    }

    mutating func applyFirstCursorPage(_ newItems: [Item]) {
        items = newItems
        nextCursor = newItems.last?.id
        isLoadingMore = false
        canLoadMore = !newItems.isEmpty
    }

    mutating func appendCursorPage(_ newItems: [Item]) {
        items.append(contentsOf: newItems)
        nextCursor = newItems.last?.id ?? nextCursor
        isLoadingMore = false
        canLoadMore = !newItems.isEmpty
    }
}
