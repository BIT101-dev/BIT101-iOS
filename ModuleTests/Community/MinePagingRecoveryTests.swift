import CommunityCore
import Foundation
@testable import MineFeature
import Testing

@MainActor
struct MinePagingRecoveryTests {
    private func user(_ id: Int) -> CommunityUser { .placeholder(id: id, nickname: "用户") }
    private func poster(_ id: Int) -> CommunityPoster {
        CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
            createTime: "", editTime: "", id: id, images: [], likeNum: 0, public: true,
            tags: [], text: "正文", title: "帖子", updateTime: "", user: user(id))
    }

    @Test(arguments: ["followers", "followings", "mine", "profile"], [false, true])
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
            service.users = { _ in [user(2)] }
            service.posters = { _ in [poster(2)] }
            await next()
            #expect(ids() == [1, 2] && service.pages.last == 4)
        }
    }

    @Test(arguments: [true, false])
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
        service.users = { _ in throw URLError(.notConnectedToInternet) }
        await refresh()
        let state = followers ? model.followerState : model.followingState
        #expect(state.items.map(\.id) == [1, 2] && state.nextPage == 2 && state.status == .loaded)
        #expect(state.canLoadMore && !state.isLoadingMore && model.alert != nil)
        service.users = { page in [user(page + 1)] }
        await next()
        #expect((followers ? model.followerState : model.followingState).items.map(\.id) == [1, 2, 3])
    }
}
