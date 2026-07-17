import Foundation

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

extension PagedItemsState where Item: Identifiable, Item.ID: Equatable {
    func shouldLoadMore(currentID: Item.ID, preloadCount: Int = 4) -> Bool {
        !isLoadingMore &&
            canLoadMore &&
            items.suffix(preloadCount).contains(where: { $0.id == currentID })
    }
}
