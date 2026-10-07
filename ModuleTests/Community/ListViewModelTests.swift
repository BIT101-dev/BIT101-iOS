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
        var result: Result<[PaperSummary], Error>

        init(result: Result<[PaperSummary], Error>) { self.result = result }

        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            requests.append((search, order, page))
            return try result.get()
        }

        func fetchPaper(id: Int) async throws -> PaperDetail {
            throw URLError(.unsupportedURL)
        }
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
    var recommend: (Int) async throws -> GalleryRecommendFeedBatch = {
        .init(posters: [], nextSourcePage: $0 + 1, canLoadMore: false)
    }
    var bot: (Int) async throws -> GalleryBotFeedBatch = {
        .init(posters: [], nextSourcePage: $0 + 1, canLoadMore: false)
    }
    var pages: [Int] = []
    var queries: [GallerySearchQuery] = []
    func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> [CommunityPoster] {
        pages.append(page ?? 0); return try await request(page ?? 0)
    }
    func fetchRecommendPage(sourcePage: Int) async throws -> GalleryRecommendFeedBatch { try await recommend(sourcePage) }
    func fetchBotFeed(startPage: Int) async throws -> GalleryBotFeedBatch { try await bot(startPage) }
    func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> [CommunityPoster] {
        queries.append(query); pages.append(page ?? 0); return try await request(page ?? 0)
    }
}

@MainActor
struct GalleryPaginationTests {
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
        model.alert = nil
        service.request = { _ in throw CancellationError() }
        await model.refresh(feed: .hot)
        #expect(model.state(for: .hot).status == .loaded)
        #expect(model.state(for: .hot).posters.map(\.id) == [1])
        #expect(model.alert == nil)
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

    @Test func recommendSkipsDuplicatePagesAndRetainsSourceCursor() async {
        let service = PagingGalleryService()
        var pages: [Int] = []
        service.recommend = { page in
            pages.append(page)
            return .init(posters: [listPoster(page < 2 ? 1 : 2)], nextSourcePage: page + 1, canLoadMore: page < 2)
        }
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .recommend)
        await model.prefetchIfNeeded(for: .recommend, currentPoster: listPoster(1))
        await model.loadMoreIfNeeded(for: .recommend, currentPoster: listPoster(1))
        #expect(pages == [0, 1, 2])
        #expect(model.state(for: .recommend).posters.map(\.id) == [1, 2])
        #expect(model.state(for: .recommend).nextPage == 3)
        #expect(model.state(for: .recommend).canLoadMore == false)
    }

    @Test func botFeedUsesSourcePageInsteadOfDisplayPage() async {
        let service = PagingGalleryService()
        var pages: [Int] = []
        service.bot = { page in
            pages.append(page)
            return .init(posters: [listPoster(page == 0 ? 1 : 2)], nextSourcePage: page + 4, canLoadMore: page == 0)
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
        service.request = { _ in throw URLError(.networkConnectionLost) }
        await model.loadMoreSearchResultsIfNeeded(currentPoster: listPoster(1))
        #expect(model.searchState.nextPage == 1)
        #expect(model.searchState.isLoadingMore == false)
        #expect(model.alert?.title == "加载更多失败")
        service.request = { _ in [] }
        await model.loadMoreSearchResultsIfNeeded(currentPoster: listPoster(1))
        #expect(model.searchState.canLoadMore == false)
        #expect(service.pages == [0, 1, 1])
    }

    @Test(arguments: [GalleryFeedKind.newest, .bot, .recommend])
    func cancelledFeedRequestRestoresStateAfterServiceCompletion(feed: GalleryFeedKind) async {
        let gate = ListRequestGate<[CommunityPoster]>()
        let service = PagingGalleryService()
        service.request = { _ in await gate.request() }
        service.bot = { page in .init(posters: await gate.request(), nextSourcePage: page + 1, canLoadMore: false) }
        service.recommend = { page in .init(posters: await gate.request(), nextSourcePage: page + 1, canLoadMore: false) }
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
private final class PagingMineService: MineOverviewServicing, UserProfileServicing {
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
