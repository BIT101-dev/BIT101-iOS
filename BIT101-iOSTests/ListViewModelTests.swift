import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Course list state machine")
struct CourseListViewModelTests {
    private final class ServiceStub: CourseListServicing {
        var pages: [Int: Result<[CourseSummary], Error>]
        private(set) var requests: [(search: String, page: Int)] = []

        init(pages: [Int: Result<[CourseSummary], Error>]) { self.pages = pages }

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            requests.append((search, page))
            return try pages[page, default: .success([])].get()
        }
    }

    @Test("Refresh trims search and pagination stops after an empty page")
    @MainActor
    func refreshAndPaginate() async throws {
        let first = try course(id: 1)
        let service = ServiceStub(pages: [0: .success([first]), 1: .success([])])
        let viewModel = CourseListViewModel(service: service)
        viewModel.searchText = "  高等数学  "

        await viewModel.refresh()
        await viewModel.loadMoreIfNeeded(currentCourse: first)

        #expect(service.requests.map { "\($0.search):\($0.page)" } == ["高等数学:0", "高等数学:1"])
        #expect(viewModel.state.items == [first])
        #expect(viewModel.state.status == .loaded)
        #expect(!viewModel.state.canLoadMore)
        #expect(!viewModel.state.isLoadingMore)
    }

    @Test("Initial failures enter a retryable failed state")
    @MainActor
    func initialFailure() async {
        let service = ServiceStub(pages: [0: .failure(URLError(.notConnectedToInternet))])
        let viewModel = CourseListViewModel(service: service)

        await viewModel.refresh()

        guard case .failed = viewModel.state.status else {
            Issue.record("Expected a failed initial state")
            return
        }
        #expect(!viewModel.state.canLoadMore)
        #expect(viewModel.alert?.title == "加载课程失败")
    }

    @Test("Cancellation is silent and returns the initial state to idle")
    @MainActor
    func cancellationIsSilent() async {
        let service = ServiceStub(pages: [0: .failure(CancellationError())])
        let viewModel = CourseListViewModel(service: service)

        await viewModel.refresh()

        #expect(viewModel.state.status == .idle)
        #expect(viewModel.alert == nil)
    }

    @Test("Prepared searches are visible immediately and continue from the next page")
    @MainActor
    func appliesPreparedSearch() async throws {
        let first = try course(id: 1)
        let second = try course(id: 2)
        let service = ServiceStub(pages: [1: .success([second])])
        let viewModel = CourseListViewModel(service: service)

        viewModel.applyPreparedSearch(query: "高等数学", items: [first])
        await viewModel.loadMoreIfNeeded(currentCourse: first)

        #expect(viewModel.searchText == "高等数学")
        #expect(viewModel.state.items == [first, second])
        #expect(viewModel.state.status == .loaded)
        #expect(service.requests.map { "\($0.search):\($0.page)" } == ["高等数学:1"])
    }

    @Test("Score entry searches directly without rejecting an empty course name")
    @MainActor
    func searchesDirectlyFromScoreEntry() async {
        let service = ServiceStub(pages: [0: .success([])])
        let viewModel = CourseListViewModel(service: service)

        await viewModel.search(for: "")

        #expect(service.requests.map { "\($0.search):\($0.page)" } == [":0"])
        #expect(viewModel.state.status == .loaded)
    }

    private func course(id: Int) throws -> CourseSummary {
        try JSONDecoder().decode(CourseSummary.self, from: Data("""
        {"id":\(id),"name":"课程\(id)","number":"C-\(id)","credit":2,
         "likeNum":1,"commentNum":1,"rate":8,"teachersName":"教师","teachersNumber":"T1"}
        """.utf8))
    }
}

@Suite("Paper search state machine")
struct PaperSearchViewModelTests {
    private final class ServiceStub: PaperListServicing {
        private(set) var requests: [(search: String?, order: PaperSortOrder, page: Int)] = []
        let result: Result<[PaperSummary], Error>

        init(result: Result<[PaperSummary], Error>) { self.result = result }

        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            requests.append((search, order, page))
            return try result.get()
        }

        func fetchPaper(id: Int) async throws -> PaperDetail {
            throw URLError(.unsupportedURL)
        }
    }

    @Test("Blank searches reset locally without a network request")
    @MainActor
    func blankSearchResetsLocally() async {
        let service = ServiceStub(result: .success([]))
        let viewModel = PaperSearchViewModel(service: service)
        viewModel.searchText = "   "

        await viewModel.performSearch()

        #expect(service.requests.isEmpty)
        #expect(viewModel.state.status == .idle)
        #expect(viewModel.state.items.isEmpty)
    }

    @Test("Search parameters are normalized and forwarded")
    @MainActor
    func forwardsNormalizedSearch() async {
        let paper = PaperSummary(
            id: 7,
            title: "标题",
            intro: "摘要",
            likeNum: 1,
            commentNum: 2,
            updateTime: "2026-08-09"
        )
        let service = ServiceStub(result: .success([paper]))
        let viewModel = PaperSearchViewModel(service: service)
        viewModel.searchText = "  Swift  "
        viewModel.selectedOrder = .like

        await viewModel.performSearch()

        #expect(service.requests.count == 1)
        #expect(service.requests.first?.search == "Swift")
        #expect(service.requests.first?.order == .like)
        #expect(service.requests.first?.page == 0)
        #expect(viewModel.state.items == [paper])
        #expect(viewModel.state.status == .loaded)
    }
}
