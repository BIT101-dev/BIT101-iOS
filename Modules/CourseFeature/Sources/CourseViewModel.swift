import CommunityCore
import TransportCore
import DesignSystemKit

import Combine
import Foundation

/// 识别课程请求的任务取消状态，切页或重复刷新时跳过失败提示。
private extension CoursePagedState {
    /// 开始首屏刷新并重置分页游标。
    mutating func prepareForRefresh() {
        paginationError = nil
        status = .loading
        resetPagination()
    }
}

@MainActor
/// 管理课程列表的加载、刷新和分页状态。
public final class CourseListViewModel: ObservableObject {
    @Published private(set) var state = CoursePagedState()
    @Published var searchText = ""
    @Published var alert: AppAlert?

    private let service: any CourseListServicing
    private var hasBootstrapped = false
    private var refreshGeneration = 0
    private var pageSearch: String?
    private var refreshTask: Task<Void, Never>?
    private var refreshPreviousState: CoursePagedState?

    public init(service: any CourseListServicing) {
        self.service = service
    }


    deinit {
        refreshTask?.cancel()
    }

    func cancelRefreshOperations() {
        refreshTask?.cancel(); refreshTask = nil
        refreshGeneration &+= 1
        if let refreshPreviousState { state = refreshPreviousState }
        refreshPreviousState = nil
        if state.status == .loading { state.status = state.items.isEmpty ? .idle : .loaded }
        state.isLoadingMore = false
        if state.status == .idle { hasBootstrapped = false }
    }

    @discardableResult
    private func enqueueRefresh() -> Task<Void, Never> {
        cancelRefreshOperations()
        hasBootstrapped = true
        alert = nil
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self, self.refreshGeneration == generation, !Task.isCancelled else { return }
            await self.performRefresh()
            if self.refreshGeneration == generation { self.refreshTask = nil }
        }
        refreshTask = task
        return task
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveSearch: Bool {
        !normalizedSearchText.isEmpty
    }
    var displayedQueryDescription: String? {
        guard let pageSearch, pageSearch != normalizedSearchText else { return nil }
        return pageSearch.isEmpty ? "全部课程" : "“\(pageSearch)”的课程"
    }

    /// 写入其他页面并行预取的课程搜索首屏。
    ///
    /// 同时写入搜索词和分页状态，详情返回后可立即浏览同名课程的其他教师，
    /// 后续滚动从 page 1 继续分页。
    public func applyPreparedSearch(query: String, items: [CourseSummary]) {
        cancelRefreshOperations()
        hasBootstrapped = true
        searchText = query
        pageSearch = normalizedSearchText
        state.applyFirstPage(items)
        state.status = .loaded
        alert = nil
    }

    /// 接收成绩页的课程名并直接搜索同名课程。
    public func search(for query: String) async {
        hasBootstrapped = true
        searchText = query
        await refresh()
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refresh()
        if state.status == .idle { hasBootstrapped = false }
    }

    func refresh() async {
        let task = enqueueRefresh()
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    func retryAfterConnectivityRecovery() {
        guard case .failed = state.status, state.items.isEmpty else { return }
        enqueueRefresh()
    }

    private func performRefresh() async {
        let generation = refreshGeneration
        let search = normalizedSearchText
        let previousState = state
        refreshPreviousState = previousState
        defer { if refreshGeneration == generation { refreshPreviousState = nil } }
        let hadCourses = !state.items.isEmpty || state.status == .loaded
        if !hadCourses {
            state.prepareForRefresh()
        } else {
            state.status = .loading
            state.isLoadingMore = false
        }

        do {
            let items = try await service.fetchCourses(
                search: search,
                page: 0
            )
            try Task.checkCancellation()
            guard refreshGeneration == generation else { return }
            state.applyFirstPage(items)
            pageSearch = search
            state.status = .loaded
        } catch {
            guard refreshGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                var restoredState = previousState
                restoredState.isLoadingMore = false
                if !restoredState.items.isEmpty {
                    restoredState.status = .loaded
                } else if case .loading = restoredState.status {
                    restoredState.status = .idle
                }
                state = restoredState
                return
            }

            state.isLoadingMore = false

            if hadCourses {
                state.status = .loaded
                alert = AppAlert(title: "刷新课程失败", error: error)
                return
            }

            state.status = .failed(error.localizedDescription)
            state.canLoadMore = false
            alert = AppAlert(title: "加载课程失败", error: error)
        }
    }

    func loadMoreIfNeeded(currentCourse: CourseSummary?) async {
        guard let currentCourse, let search = pageSearch else { return }
        let generation = refreshGeneration
        guard state.status == .loaded, state.shouldLoadMore(currentID: currentCourse.id) else { return }

        state.isLoadingMore = true
        defer {
            if refreshGeneration == generation {
                state.isLoadingMore = false
            }
        }

        var request = CommunityPageRequest<Int>(sourcePage: state.nextPage)
        do {
            guard let items = try await request.next(isCurrent: { self.refreshGeneration == generation },
                knownIDs: { self.state.pagedItems.ids },
                fetch: { try await self.service.fetchCourses(search: search, page: $0) }) else { return }
            var updated = state
            updated.nextPage = request.sourcePage
            updated.appendPage(items)
            updated.paginationError = nil
            state = updated
        } catch {
            guard refreshGeneration == generation else { return }
            state.nextPage = request.sourcePage
            if TaskCancellation.matches(error) {
                return
            }

            state.paginationError = error.localizedDescription
            alert = AppAlert(title: "加载更多失败", error: error)
        }
    }

    func submitSearch() async {
        await refresh()
    }

    func clearSearchIfNeeded(from oldValue: String, to newValue: String) {
        let oldKeyword = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKeyword = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldKeyword.isEmpty, newKeyword.isEmpty else { return }

        enqueueRefresh()
    }
}
