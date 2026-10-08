import TransportCore
import CommunityCore
import DesignSystemKit
@testable import PaperFeature
@testable import CourseFeature
@testable import GalleryFeature
@testable import MineFeature
import Foundation
import Testing

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
        while pending == nil { await Task.yield() }
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

@Suite("Paper search state machine")
struct PaperSearchViewModelTests {
    private final class ServiceStub: PaperListServicing {
        private(set) var requests: [(search: String?, order: PaperSortOrder, page: Int)] = []
        var result: Result<[PaperSummary], Error>
        var metadata: (Int) async throws -> PaperDetail = { _ in throw URLError(.unsupportedURL) }

        init(result: Result<[PaperSummary], Error>) { self.result = result }

        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            requests.append((search, order, page))
            return try result.get()
        }

        func fetchPaper(id: Int) async throws -> PaperDetail {
            try await metadata(id)
        }
    }

    @Test @MainActor
    func listPaginationKeepsTheSuccessfulConditionsAfterEditingAndRefreshFailure() async {
        let paper = PaperSummary(id: 1, title: "A", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let model = PaperListViewModel(service: service)
        model.searchText = "A"; model.selectedOrder = .like
        await model.refresh()
        model.searchText = "B"; model.selectedOrder = .newest
        service.result = .failure(URLError(.timedOut))
        await model.refresh()
        service.result = .success([])
        await model.loadMoreIfNeeded(currentPaper: paper)
        #expect(service.requests.last?.search == "A" && service.requests.last?.order == .like)
        #expect(service.requests.last?.page == 1 && model.state.items == [paper])
    }

    @Test @MainActor
    func searchPaginationKeepsItsSubmittedConditionsWhileEditing() async {
        let paper = PaperSummary(id: 1, title: "A", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let model = PaperSearchViewModel(service: service)
        model.searchText = "A"; model.selectedOrder = .like
        await model.performSearch()
        model.searchText = "B"; model.selectedOrder = .newest
        service.result = .success([])
        await model.loadMoreIfNeeded(currentPaper: paper)
        #expect(service.requests.last?.search == "A" && service.requests.last?.order == .like)
        #expect(service.requests.last?.page == 1 && model.state.items == [paper])
    }

    @Test(arguments: [false, true]) @MainActor
    func metadataRefreshRejectsEarlierRequestsAndReflectsAnonymity(search: Bool) async throws {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .success([paper]))
        let original = PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "",
            updateUser: listUser(1), anonymous: false, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        let edited = PaperDetail(id: 1, title: "fixture", intro: "", content: "", createTime: "", updateTime: "",
            updateUser: listUser(2), anonymous: true, likeNum: 0, commentNum: 0, publicEdit: true, like: false, own: true)
        let list = PaperListViewModel(service: service)
        let results = PaperSearchViewModel(service: service)
        results.searchText = "fixture"
        let refresh: @MainActor () async -> Void
        let load: @MainActor () async -> Void
        let preview: @MainActor () -> PaperPreviewMetadata?
        if search {
            refresh = { await results.performSearch() }
            load = { await results.loadPreviewMetadataIfNeeded(for: paper) }
            preview = { results.previewMetadata(for: paper.id) }
        } else {
            refresh = { await list.refresh() }
            load = { await list.loadPreviewMetadataIfNeeded(for: paper) }
            preview = { list.previewMetadata(for: paper.id) }
        }
        service.metadata = { _ in original }
        await refresh(); await load()
        #expect(preview()?.authorName == original.updateUser.nickname)
        await refresh()
        #expect(preview() == nil)
        let gate = ListRequestGate<PaperDetail>()
        service.metadata = { _ in await gate.request() }
        let earlier = Task { await load() }
        await gate.waitUntilRequested()
        await refresh()
        service.metadata = { _ in edited }
        await load()
        gate.finish(original)
        await earlier.value
        #expect(preview()?.isAnonymous == true)
        #expect(preview()?.avatarURL == nil)
        #expect(preview()?.authorName == edited.previewMetadata.authorName)
        if search { results.reset(); #expect(preview() == nil) }
    }

    @Test @MainActor func paperListRetriesItsCancelledBootstrapWhenThePageReturns() async {
        let paper = PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")
        let service = ServiceStub(result: .failure(CancellationError()))
        let model = PaperListViewModel(service: service)
        await model.bootstrapIfNeeded()
        #expect(model.state.status == .idle)
        service.result = .success([paper])
        await model.bootstrapIfNeeded()
        await model.bootstrapIfNeeded()
        #expect(model.state.items == [paper] && model.state.status == .loaded)
        #expect(service.requests.count == 2)
    }

    @Test("Blank searches reset populated results locally")
    @MainActor
    func blankSearchResetsLocally() async {
        let paper = PaperSummary(
            id: 1,
            title: "标题",
            intro: "摘要",
            likeNum: 1,
            commentNum: 1,
            updateTime: "2026-08-09"
        )
        let service = ServiceStub(result: .success([paper]))
        let viewModel = PaperSearchViewModel(service: service)
        viewModel.searchText = "Swift"

        await viewModel.performSearch()

        viewModel.searchText = "   "

        await viewModel.performSearch()

        #expect(service.requests.count == 1)
        #expect(viewModel.state.status == .idle)
        #expect(viewModel.state.items.isEmpty)
    }

    @Test("Cancellation restores the idle search state with alert clear")
    @MainActor
    func cancellationIsSilent() async {
        let service = ServiceStub(result: .failure(CancellationError()))
        let viewModel = PaperSearchViewModel(service: service)
        viewModel.searchText = "Swift"

        await viewModel.performSearch()

        #expect(viewModel.state.status == .idle)
        #expect(viewModel.state.items.isEmpty)
        #expect(viewModel.alert == nil)
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

@MainActor
private final class ListRequestGate<Value: Sendable> {
    private var result: CheckedContinuation<Value, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func request() async -> Value {
        await withCheckedContinuation {
            result = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilRequested() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ value: Value) { result?.resume(returning: value); result = nil }
}

@MainActor
private func listUser(_ id: Int) -> CommunityUser {
    CommunityUser(id: id, createTime: "", nickname: "用户\(id)",
        avatar: CommunityImage(mid: "", url: "", lowUrl: ""), motto: "",
        identity: CommunityIdentity(id: 0, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
}

@MainActor
private func listPoster(_ id: Int) -> CommunityPoster {
    CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
        createTime: "", editTime: "", id: id, images: [], likeNum: 0, public: true,
        tags: [], text: "正文", title: "帖子\(id)", updateTime: "", user: listUser(id))
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
    func repeatedInteractionsShareTheirPendingRefreshOrPage(pagination: Bool) async {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in [listPoster(1)] }
        let model = GalleryViewModel(service: service)
        if pagination { await model.refresh(feed: .newest) }
        service.request = { _ in await gate.request() }
        let first = pagination ? model.enqueueLoadMore(for: .newest, currentPoster: listPoster(1)) : model.enqueueRefresh(for: .newest)
        await gate.waitUntilRequested()
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
            return .init(items: page == 6 && !emptyEnd ? [listPoster(7)] : [], nextSourcePage: page + 1, canLoadMore: page < 6)
        }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .recommend)
        #expect(pages == Array(0...6))
        #expect(model.state(for: .recommend).posters.map(\.id) == (emptyEnd ? [] : [7]))
        #expect(model.state(for: .recommend).nextPage == 7 && model.state(for: .recommend).canLoadMore == false)
        #expect(model.state(for: .recommend).status == .loaded)
    }

    @Test(.timeLimit(.minutes(1)))
    func closingSearchCancelsTheQueuedRequestAndItsLateResult() async {
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
        await gate.waitUntilRequested()
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
    func ownerExitCancelsQueuedRequestsAndTheirLatePrefetch(feed: GalleryFeedKind) async {
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
        await gate.waitUntilRequested()
        model.cancelPendingOperations()
        gate.finish([listPoster(1)])
        while !finished { await Task.yield() }
        #expect(cancelled)
        #expect(model.state(for: feed).status == .idle)
        #expect(model.state(for: feed).posters.isEmpty)
        #expect(requests == [0])
        #expect(model.alert == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func prefetchCoordinatorReleasesDuringASuspendedSourceRequest() async {
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
        await gate.waitUntilRequested()
        coordinator = nil
        #expect(released == nil)
        gate.finish([])
        while !finished { await Task.yield() }
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

    @Test func refreshedFeedWinsOverDelayedPagination() async {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { page in page == 0 ? [listPoster(1)] : await gate.request() }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .newest)
        let pending = Task { await model.loadMoreIfNeeded(for: .newest, currentPoster: listPoster(1)) }
        await gate.waitUntilRequested()
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
            return .init(items: items, nextSourcePage: scenario == "stalled" && page == 1 ? 1 : page + 1, canLoadMore: page < 6)
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
    func cancelledFeedRequestRestoresStateAfterServiceCompletion(feed: GalleryFeedKind) async {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in await gate.request() }
        service.bot = { page in .init(items: await gate.request(), nextSourcePage: page + 1, canLoadMore: false) }
        service.recommend = { page in .init(items: await gate.request(), nextSourcePage: page + 1, canLoadMore: false) }
        let model = GalleryViewModel(service: service)
        let pending = Task { await model.refresh(feed: feed) }
        await gate.waitUntilRequested()
        pending.cancel()
        gate.finish([listPoster(1)])
        await pending.value
        #expect(model.state(for: feed).status == .idle)
        #expect(model.state(for: feed).posters.isEmpty)
        #expect(model.alert == nil)
    }

    @Test func cancelledReplacementSearchReturnsTheSceneToIdle() async {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in await gate.request() }
        let model = GalleryViewModel(service: service)
        let pending = Task { await model.performSearch() }
        await gate.waitUntilRequested()
        service.request = { _ in throw CancellationError() }
        await model.performSearch()
        gate.finish([listPoster(1)])
        await pending.value
        #expect(model.searchState.status == .idle)
        #expect(model.searchState.posters.isEmpty)
        #expect(model.searchState.isLoadingMore == false)
        #expect(model.alert == nil)
    }

    @Test func latestSearchWinsOverDelayedResults() async {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in await gate.request() }
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "first"
        let pending = Task { await model.performSearch() }
        await gate.waitUntilRequested()
        service.request = { _ in [listPoster(2)] }
        model.searchQuery.text = "second"
        await model.performSearch()
        gate.finish([listPoster(1)])
        await pending.value
        #expect(model.searchState.posters.map(\.id) == [2])
        #expect(model.searchQuery.text == "second")
    }
}

@MainActor
final class PagingMineService: MineOverviewServicing, UserProfileServicing {
    var profile: () async throws -> MineUserInfo = {
        MineUserInfo(user: listUser(1), followingNum: 2, followerNum: 3, following: false, follower: false, own: false)
    }
    var posters: (Int) async throws -> [CommunityPoster] = { _ in [] }
    var users: (Int) async throws -> [CommunityUser] = { _ in [] }
    var follow: () async throws -> MineFollowResult = {
        MineFollowResult(following: true, follower: true, followingNum: 4, followerNum: 5)
    }
    var pages: [Int] = []
    var profileRequests = 0
    var followingRequests = 0
    func fetchMyInfo() async throws -> MineUserInfo { profileRequests += 1; return try await profile() }
    func fetchFollowers(page: Int) async throws -> [CommunityUser] { pages.append(page); return try await users(page) }
    func fetchFollowings(page: Int) async throws -> [CommunityUser] { pages.append(page); return try await users(page) }
    func fetchMyPosters(page: Int) async throws -> [CommunityPoster] { pages.append(page); return try await posters(page) }
    func fetchUserInfo(id: Int) async throws -> MineUserInfo { profileRequests += 1; return try await profile() }
    func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster] { pages.append(page); return try await posters(page) }
    func followUser(id: Int) async throws -> MineFollowResult { followingRequests += 1; return try await follow() }
}

@MainActor
struct MineLifecycleTests {
    @Test(arguments: [true, false]) func cancelledBootstrapRetriesBothProfileAndPosters(onOwnProfile: Bool) async {
        let service = PagingMineService()
        service.profile = { throw CancellationError() }
        service.posters = { _ in throw CancellationError() }
        let mine = MineViewModel(service: service)
        let profile = UserProfileViewModel(userID: 1, service: service)
        func bootstrap() async {
            if onOwnProfile { await mine.bootstrapIfNeeded() } else { await profile.bootstrapIfNeeded() }
        }
        await bootstrap()
        #expect((onOwnProfile ? mine.profileStatus : profile.profileStatus) == .idle)
        service.profile = { MineUserInfo(user: listUser(1), followingNum: 0, followerNum: 0, following: false, follower: false, own: onOwnProfile) }
        service.posters = { _ in [listPoster(1)] }
        await bootstrap()
        await bootstrap()
        #expect((onOwnProfile ? mine.profileStatus : profile.profileStatus) == .loaded)
        #expect((onOwnProfile ? mine.posterState : profile.posterState).items.map(\.id) == [1])
        #expect(service.profileRequests == 2 && service.pages == [0, 0])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func posterRefreshAdmitsTheNextPageAfterItsFirstPage(onOwnProfile: Bool) async {
        let service = PagingMineService()
        service.posters = { _ in [listPoster(1)] }
        let mine = MineViewModel(service: service)
        let profile = UserProfileViewModel(userID: 1, service: service)
        func refresh() async { if onOwnProfile { await mine.refreshPosters() } else { await profile.refreshPosters() } }
        func more(_ id: Int) async {
            if onOwnProfile { await mine.loadMorePostersIfNeeded(currentPoster: listPoster(id)) }
            else { await profile.loadMorePostersIfNeeded(currentPoster: listPoster(id)) }
        }
        await refresh()
        var pending: CheckedContinuation<[CommunityPoster], Never>?
        service.posters = { page in
            if page == 0 { return await withCheckedContinuation { pending = $0 } }
            return [listPoster(3)]
        }
        let updating = Task { await refresh() }
        while pending == nil { await Task.yield() }
        await more(1)
        #expect(service.pages == [0, 0])
        pending?.resume(returning: [listPoster(2)])
        await updating.value
        await more(2)
        #expect((onOwnProfile ? mine.posterState : profile.posterState).items.map(\.id) == [2, 3])
        #expect(service.pages == [0, 0, 1])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func cancellingAUserListRefreshReleasesItsSupersededPagination(followers: Bool) async {
        let service = PagingMineService()
        service.users = { _ in [listUser(1)] }
        let model = MineViewModel(service: service)
        func refresh() async { if followers { await model.refreshFollowers() } else { await model.refreshFollowings() } }
        func more() async {
            if followers { await model.loadMoreFollowersIfNeeded(currentUser: listUser(1)) }
            else { await model.loadMoreFollowingsIfNeeded(currentUser: listUser(1)) }
        }
        await refresh()
        var pending: CheckedContinuation<[CommunityUser], Never>?
        service.users = { _ in await withCheckedContinuation { pending = $0 } }
        let pagination = Task { await more() }
        while pending == nil { await Task.yield() }
        service.users = { _ in throw CancellationError() }
        await refresh()
        #expect((followers ? model.followerState : model.followingState).isLoadingMore == false)
        pending?.resume(returning: [listUser(99)])
        await pagination.value
        service.users = { _ in [listUser(2)] }
        await more()
        #expect((followers ? model.followerState : model.followingState).items.map(\.id) == [1, 2])
    }

    @Test func bootstrapLoadsOnceAndProfileRefreshRetainsDisplayedInformation() async {
        let service = PagingMineService()
        service.posters = { _ in [listPoster(1)] }
        let model = MineViewModel(service: service)
        await model.bootstrapIfNeeded()
        await model.bootstrapIfNeeded()
        #expect(service.profileRequests == 1)
        #expect(model.userInfo?.user.id == 1)
        #expect(model.posterCountText == "1+")
        service.profile = { throw URLError(.networkConnectionLost) }
        await model.refreshProfile()
        #expect(model.userInfo?.user.id == 1)
        #expect(model.profileStatus == .loaded)
        #expect(model.alert?.title == "刷新个人信息失败")
        model.alert = nil
        service.profile = { throw CancellationError() }
        await model.refreshProfile()
        #expect(model.profileStatus == .loaded)
        #expect(model.alert == nil)
    }

    @Test func posterRefreshAndPaginationFailuresPreserveContentAndRetryCursor() async {
        let service = PagingMineService()
        service.posters = { _ in throw URLError(.notConnectedToInternet) }
        let model = MineViewModel(service: service)
        await model.refreshPosters()
        #expect(model.alert?.title == "加载帖子失败")
        service.posters = { _ in [listPoster(1)] }
        await model.refreshPosters()
        service.posters = { _ in throw URLError(.networkConnectionLost) }
        await model.refreshPosters()
        #expect(model.posterState.items.map(\.id) == [1])
        #expect(model.posterState.status == .loaded)
        #expect(model.alert?.title == "刷新帖子失败")
        await model.loadMorePostersIfNeeded(currentPoster: listPoster(1))
        #expect(model.posterState.nextPage == 1)
        #expect(model.posterState.isLoadingMore == false)
        service.posters = { _ in [listPoster(1), listPoster(2)] }
        await model.loadMorePostersIfNeeded(currentPoster: listPoster(1))
        #expect(model.posterState.items.map(\.id) == [1, 2])
        service.posters = { _ in [] }
        await model.loadMorePostersIfNeeded(currentPoster: listPoster(2))
        #expect(model.posterCountText == "2")
        #expect(model.posterState.canLoadMore == false)
    }

    @Test(arguments: [true, false])
    func userListsRecoverFromCancellationFailureAndEndPagination(followers: Bool) async {
        let service = PagingMineService()
        let model = MineViewModel(service: service)
        func refresh() async {
            if followers { await model.refreshFollowers() } else { await model.refreshFollowings() }
        }
        func more() async {
            if followers { await model.loadMoreFollowersIfNeeded(currentUser: listUser(1)) }
            else { await model.loadMoreFollowingsIfNeeded(currentUser: listUser(1)) }
        }
        service.users = { _ in throw URLError(.notConnectedToInternet) }
        await refresh()
        service.users = { _ in [listUser(1)] }
        await refresh()
        service.users = { _ in throw CancellationError() }
        await refresh()
        #expect((followers ? model.followerState : model.followingState).items.map(\.id) == [1])
        await more()
        #expect((followers ? model.followerState : model.followingState).isLoadingMore == false)
        service.users = { _ in throw URLError(.networkConnectionLost) }
        await more()
        #expect((followers ? model.followerState : model.followingState).nextPage == 1)
        service.users = { _ in [] }
        await more()
        #expect((followers ? model.followerState : model.followingState).canLoadMore == false)
    }

    @Test func profileSupersedesDelayedResponseAndPagingRefreshSupersedesOldPage() async throws {
        let service = PagingMineService()
        let gate = ListRequestGate<[CommunityPoster]>()
        service.posters = { page in page == 0 ? [listPoster(1)] : await gate.request() }
        let model = MineViewModel(service: service)
        await model.refreshPosters()
        let pending = Task { await model.loadMorePostersIfNeeded(currentPoster: listPoster(1)) }
        await gate.waitUntilRequested()
        service.posters = { _ in [listPoster(3)] }
        await model.refreshPosters()
        gate.finish([listPoster(2)])
        await pending.value
        #expect(model.posterState.items.map(\.id) == [3])
        #expect(model.posterState.nextPage == 1)
        let profileGate = ListRequestGate<MineUserInfo>()
        let info = try await service.profile()
        service.profile = { await profileGate.request() }
        let first = Task { await model.refreshProfile() }
        await profileGate.waitUntilRequested()
        service.profile = { throw URLError(.networkConnectionLost) }
        await model.refreshProfile()
        profileGate.finish(info)
        await first.value
        #expect(model.userInfo == nil)
        #expect(model.alert?.title == "加载个人信息失败")
    }

    @Test func expiredSessionReturnsTheOwnedSceneToLogin() async {
        let service = PagingMineService()
        service.profile = { throw MineServiceError.notLoggedIn }
        service.posters = { _ in throw MineServiceError.notLoggedIn }
        service.users = { _ in throw MineServiceError.notLoggedIn }
        let model = MineViewModel(service: service)
        await model.bootstrapIfNeeded()
        await model.refreshFollowers()
        await model.refreshFollowings()
        #expect(model.requiresLogin)
        #expect(model.alert == nil)
        let profile = UserProfileViewModel(userID: 1, service: service)
        await profile.bootstrapIfNeeded()
        #expect(profile.requiresLogin)
        #expect(profile.alert == nil)
    }

    @Test func independentAccountScenesKeepTheirRequestsAndContentsSeparate() async {
        let first = PagingMineService()
        let second = PagingMineService()
        first.posters = { _ in [listPoster(1)] }
        second.posters = { _ in [listPoster(2)] }
        let owner = MineViewModel(service: first)
        let switched = MineViewModel(service: second)
        await owner.refreshPosters()
        await switched.refreshPosters()
        second.posters = { _ in throw CancellationError() }
        await switched.refreshPosters()
        #expect(owner.posterState.items.map(\.id) == [1])
        #expect(switched.posterState.items.map(\.id) == [2])
        #expect(first.pages == [0])
        #expect(second.pages == [0, 0])
    }

    @Test func cancelledProfileRequestRestoresStateAfterServiceCompletion() async {
        let service = PagingMineService()
        let info = MineUserInfo(user: listUser(1), followingNum: 0, followerNum: 0, following: false, follower: false, own: true)
        let gate = ListRequestGate<MineUserInfo>()
        service.profile = { await gate.request() }
        let model = MineViewModel(service: service)
        let pending = Task { await model.refreshProfile() }
        await gate.waitUntilRequested()
        pending.cancel()
        gate.finish(info)
        await pending.value
        #expect(model.userInfo == nil)
        #expect(model.profileStatus == .idle)
        #expect(model.alert == nil)
    }

    @Test func publicProfileBootstrapsPagesAndFollowsWithRetry() async {
        let service = PagingMineService()
        service.posters = { page in page == 0 ? [listPoster(1)] : [] }
        let model = UserProfileViewModel(userID: 1, service: service)
        await model.bootstrapIfNeeded()
        await model.bootstrapIfNeeded()
        #expect(service.profileRequests == 1)
        #expect(model.userInfo?.user.id == 1)
        service.follow = { throw URLError(.notConnectedToInternet) }
        await model.followUser()
        #expect(model.isFollowingUser == false)
        #expect(model.alert?.title == "关注失败")
        service.follow = {
            MineFollowResult(following: true, follower: true, followingNum: 4, followerNum: 5)
        }
        await model.followUser()
        await model.followUser()
        #expect(service.followingRequests == 2)
        #expect(model.userInfo?.following == true)
        #expect(model.userInfo?.followerNum == 5)
        await model.loadMorePostersIfNeeded(currentPoster: listPoster(1))
        #expect(model.posterCountText == "1")
        #expect(model.posterState.canLoadMore == false)
    }
}
