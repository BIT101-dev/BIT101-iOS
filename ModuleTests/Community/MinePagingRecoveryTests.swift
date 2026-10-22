import BIT101TestSupport
import CommunityCore
import Foundation
@testable import MineFeature
import Testing

@MainActor
struct MinePagingRecoveryTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["mine-profile", "user-profile", "mine-posters", "user-posters", "followers", "followings"], [false, true])
    func initialFailurePublishesInlineRecoveryForEachOwnedScene(scene: String, authenticationFailure: Bool) async {
        let service = PagingMineService()
        let profileRequest = service.profile, userRequest = service.users, posterRequest = service.posters
        let failure: any Error = authenticationFailure ? MineServiceError.notLoggedIn : URLError(.notConnectedToInternet)
        service.profile = { throw failure }
        service.users = { _ in throw failure }
        service.posters = { _ in throw failure }
        let mine = MineViewModel(service: service)
        let profile = UserProfileViewModel(userID: 1, service: service)
        func refresh() async -> MineLoadStatus {
            switch scene {
            case "mine-profile": await mine.refreshProfile(); return mine.profileStatus
            case "user-profile": await profile.refreshProfile(); return profile.profileStatus
            case "mine-posters": await mine.refreshPosters(); return mine.posterState.status
            case "user-posters": await profile.refreshPosters(); return profile.posterState.status
            case "followers": await mine.refreshFollowers(); return mine.followerState.status
            default: await mine.refreshFollowings(); return mine.followingState.status
            }
        }
        #expect(await refresh() == .failed(failure.localizedDescription))
        #expect(mine.alert == nil && profile.alert == nil)
        service.profile = profileRequest; service.users = userRequest; service.posters = posterRequest
        #expect(await refresh() == .loaded)
    }

    private func user(_ id: Int) -> CommunityUser { .placeholder(id: id, nickname: "用户") }
    private func poster(_ id: Int) -> CommunityPoster {
        CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
            createTime: "", editTime: "", id: id, images: [], likeNum: 0, public: true,
            tags: [], text: "正文", title: "帖子", updateTime: "", user: user(id))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["followers", "followings", "mine", "profile"], [false, true])
    func repeatedPagesAdvanceOrRemainRetryable(scene: String, stalled: Bool) async {
        let service = PagingMineService()
        service.users = { page in [user(!stalled && page >= 3 ? 2 : 1)] }
        service.posters = { page in [poster(!stalled && page >= 3 ? 2 : 1)] }
        let mine = MineViewModel(service: service)
        let profile = UserProfileViewModel(userID: 1, service: service)
        switch scene {
        case "followers": await mine.refreshFollowers()
        case "followings": await mine.refreshFollowings()
        case "mine": await mine.refreshPosters()
        default: await profile.refreshPosters()
        }
        func next() async {
            switch scene {
            case "followers": await mine.loadMoreFollowersIfNeeded(currentUser: mine.followerState.items.last)
            case "followings": await mine.loadMoreFollowingsIfNeeded(currentUser: mine.followingState.items.last)
            case "mine": await mine.loadMorePostersIfNeeded(currentPoster: mine.posterState.items.last)
            default: await profile.loadMorePostersIfNeeded(currentPoster: profile.posterState.items.last)
            }
        }
        func ids() -> [Int] {
            switch scene {
            case "followers": mine.followerState.items.map(\.id)
            case "followings": mine.followingState.items.map(\.id)
            case "mine": mine.posterState.items.map(\.id)
            default: profile.posterState.items.map(\.id)
            }
        }
        await next()
        #expect(ids() == (stalled ? [1] : [1, 2]))
        #expect(service.pages == (stalled ? [0, 1, 2, 3, 4] : [0, 1, 2, 3]))
        if stalled {
            let message: String?
            switch scene {
            case "followers": message = mine.followerState.loadMoreError
            case "followings": message = mine.followingState.loadMoreError
            case "mine": message = mine.posterState.loadMoreError
            default: message = profile.posterState.loadMoreError
            }
            #expect(message != nil)
            service.users = { _ in [user(2)] }
            service.posters = { _ in [poster(2)] }
            await next()
            #expect(ids() == [1, 2] && service.pages.last == 4)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func failedUserRefreshRetainsLoadedRowsAndCursor(followers: Bool) async {
        let service = PagingMineService()
        service.users = { page in [user(page + 1)] }
        let model = MineViewModel(service: service)
        func refresh() async { if followers { await model.refreshFollowers() } else { await model.refreshFollowings() } }
        func next() async {
            if followers { await model.loadMoreFollowersIfNeeded(currentUser: model.followerState.items.last) }
            else { await model.loadMoreFollowingsIfNeeded(currentUser: model.followingState.items.last) }
        }
        await refresh()
        await next()
        service.users = { _ in
            let visible = followers ? model.followerState : model.followingState
            #expect(visible.items.map(\.id) == [1, 2] && visible.nextPage == 2)
            throw URLError(.notConnectedToInternet)
        }
        await refresh()
        let state = followers ? model.followerState : model.followingState
        #expect(state.items.map(\.id) == [1, 2] && state.nextPage == 2 && state.status == .loaded)
        #expect(state.canLoadMore && !state.isLoadingMore && model.alert != nil)
        service.users = { page in [user(page + 1)] }
        await next()
        #expect((followers ? model.followerState : model.followingState).items.map(\.id) == [1, 2, 3])
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
    @Test(.timeLimit(.minutes(1))) func explicitOverviewRefreshRecoversTheFailedPosterSummary() async {
        let service = PagingMineService()
        service.posters = { _ in throw URLError(.notConnectedToInternet) }
        let model = MineViewModel(service: service)
        await model.bootstrapIfNeeded()
        #expect(model.posterCountText == "待恢复")
        service.posters = { _ in [listPoster(1)] }
        await model.refreshAll()
        #expect(model.posterCountText == "1+" && model.posterState.items.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func returningToMineRefreshesSavedProfileAndKeepsThePosterSummary() async {
        let service = PagingMineService()
        service.posters = { _ in [listPoster(1)] }
        let model = MineViewModel(service: service)
        await model.refreshOverview()
        service.profile = {
            MineUserInfo(user: .placeholder(id: 1, nickname: "保存后的昵称"), followingNum: 4,
                followerNum: 5, following: false, follower: false, own: true)
        }
        await model.refreshOverview()
        #expect(model.userInfo?.user.nickname == "保存后的昵称" && model.userInfo?.followingNum == 4)
        #expect(model.posterState.items.map(\.id) == [1] && service.pages == [0] && service.profileRequests == 2)
        service.profile = { throw URLError(.notConnectedToInternet) }
        await model.refreshOverview()
        #expect(model.userInfo?.user.nickname == "保存后的昵称" && model.profileStatus == .loaded)
        #expect(model.alert?.title == "刷新个人信息失败")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false]) func cancelledBootstrapRetriesBothProfileAndPosters(onOwnProfile: Bool) async {
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
    func posterRefreshAdmitsTheNextPageAfterItsFirstPage(onOwnProfile: Bool) async throws {
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
        try await waitForTestEvent { !(pending == nil) }
        await more(1)
        #expect(service.pages == [0, 0])
        pending?.resume(returning: [listPoster(2)])
        await updating.value
        await more(2)
        #expect((onOwnProfile ? mine.posterState : profile.posterState).items.map(\.id) == [2, 3])
        #expect(service.pages == [0, 0, 1])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func cancellingAUserListRefreshReleasesItsSupersededPagination(followers: Bool) async throws {
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
        try await waitForTestEvent { !(pending == nil) }
        service.users = { _ in throw CancellationError() }
        await refresh()
        #expect((followers ? model.followerState : model.followingState).isLoadingMore == false)
        pending?.resume(returning: [listUser(99)])
        await pagination.value
        service.users = { _ in [listUser(2)] }
        await more()
        #expect((followers ? model.followerState : model.followingState).items.map(\.id) == [1, 2])
    }

    @Test(.timeLimit(.minutes(1))) func bootstrapLoadsOnceAndProfileRefreshRetainsDisplayedInformation() async {
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

    @Test(.timeLimit(.minutes(1))) func posterRefreshAndPaginationFailuresPreserveContentAndRetryCursor() async {
        let service = PagingMineService()
        service.posters = { _ in throw URLError(.notConnectedToInternet) }
        let model = MineViewModel(service: service)
        await model.refreshPosters()
        #expect(model.alert == nil && model.posterState.status == .failed(URLError(.notConnectedToInternet).localizedDescription))
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

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
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

    @Test(.timeLimit(.minutes(1))) func profileSupersedesDelayedResponseAndPagingRefreshSupersedesOldPage() async throws {
        let service = PagingMineService()
        let gate = ListRequestGate<[CommunityPoster]>()
        service.posters = { page in page == 0 ? [listPoster(1)] : try await gate.request() }
        let model = MineViewModel(service: service)
        await model.refreshPosters()
        let pending = Task { await model.loadMorePostersIfNeeded(currentPoster: listPoster(1)) }
        try await gate.waitUntilRequested()
        service.posters = { _ in [listPoster(3)] }
        await model.refreshPosters()
        gate.finish([listPoster(2)])
        await pending.value
        #expect(model.posterState.items.map(\.id) == [3])
        #expect(model.posterState.nextPage == 1)
        let profileGate = ListRequestGate<MineUserInfo>()
        let info = try await service.profile()
        service.profile = { try await profileGate.request() }
        let first = Task { await model.refreshProfile() }
        try await profileGate.waitUntilRequested()
        service.profile = { throw URLError(.networkConnectionLost) }
        await model.refreshProfile()
        profileGate.finish(info)
        await first.value
        #expect(model.userInfo == nil)
        #expect(model.alert == nil && model.profileStatus == .failed(URLError(.networkConnectionLost).localizedDescription))
    }

    @Test(.timeLimit(.minutes(1))) func expiredCommunitySessionKeepsTheOwnedSceneRecoverable() async {
        let service = PagingMineService()
        service.profile = { throw MineServiceError.notLoggedIn }
        service.posters = { _ in throw MineServiceError.notLoggedIn }
        service.users = { _ in throw MineServiceError.notLoggedIn }
        let model = MineViewModel(service: service)
        await model.bootstrapIfNeeded()
        await model.refreshFollowers()
        await model.refreshFollowings()
        #expect(model.profileStatus == .failed(MineServiceError.notLoggedIn.localizedDescription))
        #expect(model.followerState.status == .failed(MineServiceError.notLoggedIn.localizedDescription))
        #expect(model.followingState.status == .failed(MineServiceError.notLoggedIn.localizedDescription))
        #expect(model.alert == nil)
        let profile = UserProfileViewModel(userID: 1, service: service)
        await profile.bootstrapIfNeeded()
        #expect(profile.alert == nil)
        #expect(profile.profileStatus == .failed(MineServiceError.notLoggedIn.localizedDescription))
        #expect(profile.posterState.status == .failed(MineServiceError.notLoggedIn.localizedDescription))
    }

    @Test(.timeLimit(.minutes(1))) func independentAccountScenesKeepTheirRequestsAndContentsSeparate() async {
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

    @Test(.timeLimit(.minutes(1))) func cancelledProfileRequestRestoresStateAfterServiceCompletion() async throws {
        let service = PagingMineService()
        let info = MineUserInfo(user: listUser(1), followingNum: 0, followerNum: 0, following: false, follower: false, own: true)
        let gate = ListRequestGate<MineUserInfo>()
        service.profile = { try await gate.request() }
        let model = MineViewModel(service: service)
        let pending = Task { await model.refreshProfile() }
        try await gate.waitUntilRequested()
        pending.cancel()
        gate.finish(info)
        await pending.value
        #expect(model.userInfo == nil)
        #expect(model.profileStatus == .idle)
        #expect(model.alert == nil)
    }

    @Test(.timeLimit(.minutes(1))) func publicProfileBootstrapsPagesAndFollowsWithRetry() async {
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
        #expect(service.followingRequests == 2)
        #expect(model.userInfo?.following == true)
        #expect(model.userInfo?.followerNum == 5)
        service.follow = { MineFollowResult(following: false, follower: true, followingNum: 4, followerNum: 4) }
        await model.followUser()
        #expect(service.followingRequests == 3 && model.userInfo?.following == false && model.userInfo?.followerNum == 4)
        await model.loadMorePostersIfNeeded(currentPoster: listPoster(1))
        #expect(model.posterCountText == "1")
        #expect(model.posterState.canLoadMore == false)
    }
}
