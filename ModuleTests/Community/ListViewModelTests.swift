import BIT101TestSupport
import TransportCore
import CommunityCore
import DesignSystemKit
@testable import PaperFeature
@testable import CourseFeature
@testable import GalleryFeature
@testable import MineFeature
import Foundation
import Testing

@MainActor
@Suite
struct ListRequestGateTests {
    @Test func observationHonorsCancellationAndReentry() async throws {
        let gate = ListRequestGate<Int>()
        let observation = Task { try await gate.waitUntilRequested() }
        observation.cancel()
        await #expect(throws: CancellationError.self) { try await observation.value }
        let request = Task { await gate.request() }
        try await gate.waitUntilRequested()
        gate.finish(41)
        #expect(await request.value == 41)
    }
}

@Suite("Course list state machine")
struct CourseListViewModelTests {
    private final class ServiceStub: CourseListServicing {
        var pages: [Int: Result<[CourseSummary], Error>]
        var fetch: ((String, Int) async throws -> [CourseSummary])?
        private(set) var requests: [(search: String, page: Int)] = []

        init(pages: [Int: Result<[CourseSummary], Error>]) { self.pages = pages }

        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            requests.append((search, page))
            if let fetch { return try await fetch(search, page) }
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

    @Test("Initial failures enter a retryable state")
    @MainActor
    func initialFailure() async throws {
        let first = try course(id: 1)
        let service = ServiceStub(pages: [0: .failure(URLError(.notConnectedToInternet))])
        let viewModel = CourseListViewModel(service: service)

        await viewModel.refresh()

        guard case .failed = viewModel.state.status else {
            Issue.record("Expected a failed initial state")
            return
        }
        #expect(!viewModel.state.canLoadMore)
        #expect(viewModel.alert?.title == "加载课程失败")

        service.pages[0] = .success([first])
        await viewModel.refresh()

        #expect(viewModel.state.status == .loaded)
        #expect(viewModel.state.items == [first])
        #expect(service.requests.map { "\($0.search):\($0.page)" } == [":0", ":0"])
    }

    @Test(arguments: [false, true]) @MainActor
    func paginationKeepsItsSuccessfulQueryWhileEditingOrAfterFirstPageFailure(failedRefresh: Bool) async throws {
        let first = try course(id: 1)
        let service = ServiceStub(pages: [0: .success([first]), 1: .success([])])
        let model = CourseListViewModel(service: service)
        model.searchText = "A"
        await model.refresh()
        model.searchText = "B"
        if failedRefresh { service.pages[0] = .failure(URLError(.timedOut)); await model.refresh() }
        await model.loadMoreIfNeeded(currentCourse: first)
        #expect(service.requests.last?.search == "A" && service.requests.last?.page == 1)
        #expect(model.state.items == [first])
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

    @Test @MainActor func cancelledBootstrapLoadsOnTheNextEntry() async throws {
        let first = try course(id: 1)
        let service = ServiceStub(pages: [0: .failure(CancellationError())])
        let model = CourseListViewModel(service: service)
        await model.bootstrapIfNeeded()
        #expect(model.state.status == .idle)
        service.pages[0] = .success([first])
        await model.bootstrapIfNeeded()
        await model.bootstrapIfNeeded()
        #expect(model.state.items == [first] && model.state.status == .loaded)
        #expect(service.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func refreshingASearchAdmitsPaginationAfterItsFirstPage() async throws {
        let old = try course(id: 1), fresh = try course(id: 2), next = try course(id: 3)
        let service = ServiceStub(pages: [:])
        var pending: CheckedContinuation<[CourseSummary], Never>?
        service.fetch = { _, page in
            if page == 0 { return await withCheckedContinuation { pending = $0 } }
            return [next]
        }
        let model = CourseListViewModel(service: service)
        model.applyPreparedSearch(query: "old", items: [old])
        let refresh = Task { await model.search(for: "fresh") }
        try await waitForTestEvent { !(pending == nil) }
        await model.loadMoreIfNeeded(currentCourse: old)
        #expect(model.state.items == [old] && service.requests.count == 1)
        pending?.resume(returning: [fresh])
        await refresh.value
        await model.loadMoreIfNeeded(currentCourse: fresh)
        #expect(model.state.items == [fresh, next])
        #expect(service.requests.map { "\($0.search):\($0.page)" } == ["fresh:0", "fresh:1"])
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

@MainActor
private final class PagingGalleryService: GalleryFeedServicing {
    var request: (Int) async throws -> [CommunityPoster] = { _ in [] }
    var recommend: (Int) async throws -> GalleryPageBatch<CommunityPoster> = {
        .init(items: [], nextSourcePage: $0 + 1, canLoadMore: false)
    }
    var bot: (Int) async throws -> GalleryPageBatch<CommunityPoster> = {
        .init(items: [], nextSourcePage: $0 + 1, canLoadMore: false)
    }
    var pages: [Int] = []
    var queries: [GallerySearchQuery] = []
    func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
        pages.append(page ?? 0)
        let posters = try await request(page ?? 0)
        return .init(items: posters, nextSourcePage: (page ?? 0) + 1, canLoadMore: !posters.isEmpty)
    }
    func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> { try await recommend(sourcePage) }
    func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> { try await bot(startPage) }
    func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
        queries.append(query); pages.append(page ?? 0)
        let posters = try await request(page ?? 0)
        return .init(items: posters, nextSourcePage: (page ?? 0) + 1, canLoadMore: !posters.isEmpty)
    }
}

@MainActor
struct GalleryPaginationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func composerRefreshSupersedesAnEarlierSnapshotAndPreservesRecovery(fails: Bool) async throws {
        let service = PagingGalleryService()
        service.request = { page in [listPoster(page + 9)] }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .newest)
        await model.loadMoreIfNeeded(for: .newest, currentPoster: listPoster(9))
        let previous = model.state(for: .newest)
        let gate = ListRequestGate<[CommunityPoster]>()
        service.request = { _ in await gate.request() }
        let earlier = Task { await model.refresh(feed: .newest) }
        try await gate.waitUntilRequested()
        service.request = { _ in
            if fails { throw URLError(.timedOut) }
            return [listPoster(11)]
        }
        await model.enqueueNewestRefreshAfterComposer().value
        gate.finish([listPoster(1)])
        await earlier.value
        let current = model.state(for: .newest)
        #expect(model.selectedFeed == .newest && current.status == .loaded)
        #expect(current.posters.map(\.id) == (fails ? previous.posters.map(\.id) : [11]))
        #expect(current.nextPage == (fails ? previous.nextPage : 1))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func repeatedInteractionsShareTheirPendingRefreshOrPage(pagination: Bool) async throws {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in [listPoster(1)] }
        let model = GalleryViewModel(service: service)
        if pagination { await model.refresh(feed: .newest) }
        service.request = { _ in await gate.request() }
        let first = pagination ? model.enqueueLoadMore(for: .newest, currentPoster: listPoster(1)) : model.enqueueRefresh(for: .newest)
        try await gate.waitUntilRequested()
        let second = pagination ? model.enqueueLoadMore(for: .newest, currentPoster: listPoster(1)) : model.enqueueRefresh(for: .newest)
        var finished = false
        let observer = Task { await second.value; finished = true }
        await Task.yield()
        #expect(finished == false)
        #expect(service.pages == (pagination ? [0, 1] : [0]))
        #expect(pagination ? model.state(for: .newest).isLoadingMore : model.state(for: .newest).status == .loading)
        gate.finish([listPoster(2)])
        await first.value
        await observer.value
        #expect(finished)
        #expect(model.state(for: .newest).posters.map(\.id) == (pagination ? [1, 2] : [2]))
        #expect(model.state(for: .newest).status == .loaded && model.state(for: .newest).isLoadingMore == false)
    }

    @Test(arguments: [false, true])
    func recommendFirstPageAdvancesPastFilteredSourcesToContentOrTheEnd(emptyEnd: Bool) async {
        let service = PagingGalleryService()
        var pages: [Int] = []
        service.recommend = { page in
            pages.append(page)
            return .init(items: page == 6 && !emptyEnd ? [listPoster(7)] : [], nextSourcePage: page + 1, canLoadMore: page < 6, sourceIDs: page < 6 ? [page] : [])
        }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .recommend)
        #expect(pages == Array(0...4))
        #expect(model.state(for: .recommend).posters.isEmpty && model.state(for: .recommend).nextPage == 5)
        #expect(model.state(for: .recommend).canLoadMore)
        await model.loadMoreIfNeeded(for: .recommend, currentPoster: nil)
        #expect(pages == Array(0...6))
        #expect(model.state(for: .recommend).posters.map(\.id) == (emptyEnd ? [] : [7]))
        #expect(model.state(for: .recommend).nextPage == 7 && model.state(for: .recommend).canLoadMore == false)
        #expect(model.state(for: .recommend).status == .loaded)
    }

    @Test(.timeLimit(.minutes(1)))
    func closingSearchCancelsTheQueuedRequestAndItsLateResult() async throws {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        var cancelled = false
        service.request = { _ in
            let result = await gate.request()
            cancelled = Task.isCancelled
            return result
        }
        let model = GalleryViewModel(service: service)
        let request = model.enqueueSearch()
        try await gate.waitUntilRequested()
        model.cancelSearchOperations()
        gate.finish([listPoster(1)])
        await request.value
        #expect(cancelled && model.searchState.status == .idle && model.searchState.posters.isEmpty)
    }

    @Test(arguments: [false, true])
    func replyComposerUsesTheCommentAuthorVisibility(anonymous: Bool) {
        let user = listUser(1)
        let comment = CommunityComment(id: 1, obj: "poster1", images: [], user: user, anonymous: anonymous,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0,
            own: false, rate: 0, replyUser: user, replyObj: "", text: "", sub: [])
        let target = GalleryCommentComposerTarget.comment(mainComment: comment, targetComment: comment)
        let expected = "回复 @\(anonymous ? AppUserPresentation.anonymousName : user.nickname)"
        #expect(target.title == expected)
        #expect(target.placeholder == expected)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [GalleryFeedKind.newest, .recommend])
    func ownerExitCancelsQueuedRequestsAndTheirLatePrefetch(feed: GalleryFeedKind) async throws {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        var cancelled = false
        var finished = false
        var requests: [Int] = []
        service.request = { page in
            requests.append(page)
            let result = await gate.request()
            cancelled = Task.isCancelled
            finished = true
            return result
        }
        service.recommend = { page in
            .init(items: try await service.request(page), nextSourcePage: page + 1, canLoadMore: true)
        }
        let model = GalleryViewModel(service: service)
        model.enqueueRefresh(for: feed)
        try await gate.waitUntilRequested()
        model.cancelPendingOperations()
        gate.finish([listPoster(1)])
        try await waitForTestEvent { !(!finished) }
        #expect(cancelled)
        #expect(model.state(for: feed).status == .idle)
        #expect(model.state(for: feed).posters.isEmpty)
        #expect(requests == [0])
        #expect(model.alert == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func ownerExitRestoresTheCompleteRefreshSnapshotAfterPaging() async throws {
        let service = PagingGalleryService()
        service.request = { page in page < 2 ? [listPoster(page + 1)] : [] }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .newest)
        await model.loadMoreIfNeeded(for: .newest, currentPoster: listPoster(1))
        await model.loadMoreIfNeeded(for: .newest, currentPoster: listPoster(2))
        let previous = model.state(for: .newest)
        #expect(previous.nextPage == 3 && !previous.canLoadMore)
        let gate = ListRequestGate<[CommunityPoster]>()
        service.request = { _ in await gate.request() }
        let refresh = model.enqueueRefresh(for: .newest)
        try await gate.waitUntilRequested()
        model.cancelPendingOperations()
        let restored = model.state(for: .newest)
        #expect(restored.posters == previous.posters && restored.posterIDs == previous.posterIDs)
        #expect(restored.nextPage == previous.nextPage && restored.canLoadMore == previous.canLoadMore)
        #expect(restored.needsContinuation == previous.needsContinuation && restored.status == .loaded)
        #expect(!restored.isLoadingMore)
        gate.finish([listPoster(99)])
        await refresh.value
        await model.loadMoreIfNeeded(for: .newest, currentPoster: listPoster(2))
        #expect(service.pages == [0, 1, 2, 0])
        #expect(model.state(for: .newest).posters == previous.posters && model.alert == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func prefetchCoordinatorReleasesDuringASuspendedSourceRequest() async throws {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        var cancelled = false
        var finished = false
        service.recommend = { page in
            let posters = await gate.request()
            cancelled = Task.isCancelled
            finished = true
            return .init(items: posters, nextSourcePage: page + 1, canLoadMore: true)
        }
        var coordinator: GalleryRecommendPrefetchCoordinator? = .init(service: service)
        weak let released = coordinator
        coordinator?.start(from: 0)
        try await gate.waitUntilRequested()
        coordinator = nil
        #expect(released == nil)
        gate.finish([])
        try await waitForTestEvent { !(!finished) }
        #expect(cancelled)
    }

    @Test(arguments: [GalleryFeedKind.newest, .follow, .hot])
    func ordinaryFeedDeduplicatesAndEndsAtEmptyPage(feed: GalleryFeedKind) async {
        let service = PagingGalleryService()
        service.request = { page in page == 0 ? [listPoster(1), listPoster(1)] : page == 1 ? [listPoster(1), listPoster(2)] : [] }
        let model = GalleryViewModel(service: service)
        model.selectedFeed = feed
        await model.bootstrapIfNeeded()
        await model.bootstrapIfNeeded()
        await model.loadMoreIfNeeded(for: feed, currentPoster: nil)
        await model.loadMoreIfNeeded(for: feed, currentPoster: listPoster(99))
        await model.loadMoreIfNeeded(for: feed, currentPoster: listPoster(1))
        await model.loadMoreIfNeeded(for: feed, currentPoster: listPoster(2))
        await model.loadMoreIfNeeded(for: feed, currentPoster: listPoster(2))
        #expect(service.pages == [0, 1, 2])
        #expect(model.state(for: feed).posters.map(\.id) == [1, 2])
        #expect(model.state(for: feed).nextPage == 3)
        #expect(model.state(for: feed).canLoadMore == false)
    }

    @Test func paginationFailureRetainsCursorAndSupportsRetry() async {
        let service = PagingGalleryService()
        service.request = { page in
            if page == 1 { throw URLError(.notConnectedToInternet) }
            return [listPoster(1)]
        }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .newest)
        await model.loadMoreIfNeeded(for: .newest, currentPoster: listPoster(1))
        #expect(model.state(for: .newest).posters.map(\.id) == [1])
        #expect(model.state(for: .newest).nextPage == 1)
        #expect(model.state(for: .newest).isLoadingMore == false)
        #expect(model.alert?.title == "加载更多失败")
        service.request = { _ in [listPoster(2)] }
        await model.loadMoreIfNeeded(for: .newest, currentPoster: listPoster(1))
        #expect(model.state(for: .newest).posters.map(\.id) == [1, 2])
        #expect(service.pages == [0, 1, 1])
    }

    @Test func refreshFailureAndCancellationRecoverThroughRetry() async {
        let service = PagingGalleryService()
        service.request = { _ in throw URLError(.notConnectedToInternet) }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .hot)
        #expect(model.alert?.title == "加载话廊失败")
        #expect(model.state(for: .hot).canLoadMore == false)
        service.request = { _ in [listPoster(1)] }
        await model.refresh(feed: .hot)
        for error in [URLError(.notConnectedToInternet) as any Error, CancellationError()] {
            model.alert = nil
            service.request = { _ in throw error }
            await model.refresh(feed: .hot)
            #expect(model.state(for: .hot).status == .loaded)
            #expect(model.state(for: .hot).posters.map(\.id) == [1])
            #expect(model.state(for: .hot).nextPage == 1 && model.state(for: .hot).canLoadMore)
            #expect(model.alert?.title == (error is CancellationError ? nil : "加载话廊失败"))
        }
        service.request = { _ in [listPoster(2)] }
        await model.refresh(feed: .hot)
        #expect(model.state(for: .hot).posters.map(\.id) == [2])
    }

    @Test func refreshedFeedWinsOverDelayedPagination() async throws {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { page in page == 0 ? [listPoster(1)] : await gate.request() }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .newest)
        let pending = Task { await model.loadMoreIfNeeded(for: .newest, currentPoster: listPoster(1)) }
        try await gate.waitUntilRequested()
        service.request = { _ in [listPoster(3)] }
        await model.refresh(feed: .newest)
        gate.finish([listPoster(2)])
        await pending.value
        #expect(model.state(for: .newest).posters.map(\.id) == [3])
        #expect(model.state(for: .newest).nextPage == 1)
    }

    @Test(arguments: ["duplicate", "filtered", "stalled"])
    func recommendSkipsLongEmptyRunsAndRetainsSourceCursor(scenario: String) async {
        let service = PagingGalleryService()
        var pages: [Int] = []
        service.recommend = { page in
            pages.append(page)
            let items = page >= 6 ? [listPoster(2)] : page == 0 || scenario == "duplicate" ? [listPoster(1)] : []
            return .init(items: items, nextSourcePage: scenario == "stalled" && page == 1 ? 1 : page + 1, canLoadMore: page < 6, sourceIDs: page < 6 ? [page] : [])
        }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .recommend)
        await model.prefetchIfNeeded(for: .recommend, currentPoster: listPoster(1))
        await model.loadMoreIfNeeded(for: .recommend, currentPoster: listPoster(1))
        if scenario == "stalled" {
            #expect(model.state(for: .recommend).posters.map(\.id) == [1])
            #expect(model.state(for: .recommend).nextPage == 1 && model.alert?.title == "加载更多失败")
            return
        }
        #expect(model.state(for: .recommend).posters.map(\.id) == [1] && model.state(for: .recommend).nextPage == 6)
        await model.loadMoreIfNeeded(for: .recommend, currentPoster: listPoster(1))
        #expect(pages == Array(0...6))
        #expect(model.state(for: .recommend).posters.map(\.id) == [1, 2])
        #expect(model.state(for: .recommend).nextPage == 7)
        #expect(model.state(for: .recommend).canLoadMore == false)
    }

    @Test func botFeedUsesSourcePageInsteadOfDisplayPage() async {
        let service = PagingGalleryService()
        var pages: [Int] = []
        service.bot = { page in
            pages.append(page)
            return .init(items: [listPoster(page == 0 ? 1 : 2)], nextSourcePage: page + 4, canLoadMore: page == 0)
        }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .bot)
        await model.loadMoreIfNeeded(for: .bot, currentPoster: listPoster(1))
        #expect(pages == [0, 4])
        #expect(model.state(for: .bot).posters.map(\.id) == [1, 2])
        #expect(model.state(for: .bot).canLoadMore == false)
    }

    @Test func searchNormalizesConditionsAndPreservesCursorOnFailure() async {
        let service = PagingGalleryService()
        service.request = { _ in [listPoster(1), listPoster(1)] }
        let model = GalleryViewModel(service: service)
        model.searchQuery = .init(text: "  Swift  ", order: .like)
        await model.performSearch()
        #expect(service.queries.first?.text == "Swift")
        #expect(model.searchState.posters.map(\.id) == [1])
        model.searchQuery.text = "edited"
        service.request = { _ in throw URLError(.networkConnectionLost) }
        await model.loadMoreSearchResultsIfNeeded(currentPoster: listPoster(1))
        #expect(model.searchState.nextPage == 1)
        #expect(model.searchState.isLoadingMore == false)
        #expect(model.alert?.title == "加载更多失败")
        service.request = { _ in [] }
        await model.loadMoreSearchResultsIfNeeded(currentPoster: listPoster(1))
        #expect(model.searchState.canLoadMore == false)
        #expect(service.pages == [0, 1, 1])
        #expect(service.queries.allSatisfy { $0.text == "Swift" && $0.order == .like })
    }

    @Test(arguments: [GalleryFeedKind.newest, .bot, .recommend])
    func cancelledFeedRequestRestoresStateAfterServiceCompletion(feed: GalleryFeedKind) async throws {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in await gate.request() }
        service.bot = { page in .init(items: await gate.request(), nextSourcePage: page + 1, canLoadMore: false) }
        service.recommend = { page in .init(items: await gate.request(), nextSourcePage: page + 1, canLoadMore: false) }
        let model = GalleryViewModel(service: service)
        let pending = Task { await model.refresh(feed: feed) }
        try await gate.waitUntilRequested()
        pending.cancel()
        gate.finish([listPoster(1)])
        await pending.value
        #expect(model.state(for: feed).status == .idle)
        #expect(model.state(for: feed).posters.isEmpty)
        #expect(model.alert == nil)
    }

    @Test func cancelledReplacementSearchReturnsTheSceneToIdle() async throws {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in await gate.request() }
        let model = GalleryViewModel(service: service)
        let pending = Task { await model.performSearch() }
        try await gate.waitUntilRequested()
        service.request = { _ in throw CancellationError() }
        await model.performSearch()
        gate.finish([listPoster(1)])
        await pending.value
        #expect(model.searchState.status == .idle)
        #expect(model.searchState.posters.isEmpty)
        #expect(model.searchState.isLoadingMore == false)
        #expect(model.alert == nil)
    }

    @Test func latestSearchWinsOverDelayedResults() async throws {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in await gate.request() }
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "first"
        let pending = Task { await model.performSearch() }
        try await gate.waitUntilRequested()
        service.request = { _ in [listPoster(2)] }
        model.searchQuery.text = "second"
        await model.performSearch()
        gate.finish([listPoster(1)])
        await pending.value
        #expect(model.searchState.posters.map(\.id) == [2])
        #expect(model.searchQuery.text == "second")
    }
}
