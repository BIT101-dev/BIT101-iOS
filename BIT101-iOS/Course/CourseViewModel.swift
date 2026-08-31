//
//  CourseViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Combine
import Foundation

/// 判断课程请求是否只是被任务取消，避免把切页或重复触发刷新误报成失败。
private func isCourseRequestCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

private extension CoursePagedState {
    /// 进入首屏刷新时重置分页游标。
    mutating func prepareForRefresh() {
        status = .loading
        resetPagination()
    }
}

@MainActor
/// 课程列表状态机。
final class CourseListViewModel: ObservableObject {
    @Published private(set) var state = CoursePagedState()
    @Published var searchText = ""
    @Published var alert: AppAlert?

    private let service: any CourseListServicing
    private var hasBootstrapped = false

    init(service: any CourseListServicing) {
        self.service = service
    }

    convenience init() {
        self.init(service: CourseService())
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveSearch: Bool {
        !normalizedSearchText.isEmpty
    }

    /// 接收其它页面已经并行预取好的课程搜索首屏。
    ///
    /// 同时写入搜索词和分页状态，用户从详情返回时可以立即浏览同名课程的其它教师，
    /// 后续滚动仍从 page 1 继续正常分页。
    func applyPreparedSearch(query: String, items: [CourseSummary]) {
        hasBootstrapped = true
        searchText = query
        state.applyFirstPage(items)
        state.status = .loaded
        alert = nil
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refresh()
    }

    func refresh() async {
        let hadCourses = !state.items.isEmpty || state.status == .loaded
        if !hadCourses {
            state.prepareForRefresh()
        } else {
            state.isLoadingMore = false
        }

        do {
            let items = try await service.fetchCourses(
                search: normalizedSearchText,
                page: 0
            )
            state.applyFirstPage(items)
            state.status = .loaded
        } catch {
            if isCourseRequestCancellation(error) {
                if !hadCourses {
                    state.status = .idle
                }
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
        guard let currentCourse else { return }
        guard state.status == .loaded, state.shouldLoadMore(currentID: currentCourse.id) else { return }

        state.isLoadingMore = true

        do {
            let items = try await service.fetchCourses(
                search: normalizedSearchText,
                page: state.nextPage
            )
            state.appendPage(items)
        } catch {
            if isCourseRequestCancellation(error) {
                state.isLoadingMore = false
                return
            }

            state.isLoadingMore = false
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

        Task {
            await refresh()
        }
    }
}
