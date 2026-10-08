import CommunityCore
import TransportCore
import DesignSystemKit
//
//  CourseViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Combine
import Foundation

/// 识别课程请求的任务取消状态，切页或重复刷新时跳过失败提示。
private func isCourseRequestCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

private extension CoursePagedState {
    /// 开始首屏刷新并重置分页游标。
    mutating func prepareForRefresh() {
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
    private var searchResetTask: Task<Void, Never>?

    public init(service: any CourseListServicing) {
        self.service = service
    }


    deinit {
        searchResetTask?.cancel()
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveSearch: Bool {
        !normalizedSearchText.isEmpty
    }

    /// 写入其他页面并行预取的课程搜索首屏。
    ///
    /// 同时写入搜索词和分页状态，详情返回后可立即浏览同名课程的其他教师，
    /// 后续滚动从 page 1 继续分页。
    public func applyPreparedSearch(query: String, items: [CourseSummary]) {
        refreshGeneration &+= 1
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
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let search = normalizedSearchText
        let previousState = state
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
            if isCourseRequestCancellation(error) {
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
                alert = AppAlert(title: "刷新课程失败", message: error.localizedDescription)
                return
            }

            state.status = .failed(error.localizedDescription)
            state.canLoadMore = false
            alert = AppAlert(title: "加载课程失败", message: error.localizedDescription)
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

        do {
            let previousCount = state.items.count
            var progress = CommunityPageProgress(knownIDs: state.items.map(\.id))
            repeat {
                try Task.checkCancellation()
                state.isLoadingMore = true
                let items = try await service.fetchCourses(search: search, page: state.nextPage)
                try Task.checkCancellation()
                guard refreshGeneration == generation else { return }
                try progress.record(items.map(\.id))
                state.appendPage(items)
            } while state.canLoadMore && state.items.count == previousCount
        } catch {
            guard refreshGeneration == generation else { return }
            if isCourseRequestCancellation(error) {
                return
            }

            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    func submitSearch() async {
        await refresh()
    }

    func clearSearchIfNeeded(from oldValue: String, to newValue: String) {
        let oldKeyword = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKeyword = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldKeyword.isEmpty, newKeyword.isEmpty else { return }

        searchResetTask?.cancel()
        searchResetTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }
}
