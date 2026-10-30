import CommunityTransport
import TransportCore
import DesignSystemKit
import CommunityCore
import Combine
import Foundation

/// 四类主页列表共用第一页恢复与分页推进规则，业务对象持有代际与提示。
@MainActor
private func refreshMinePage<Item: Identifiable>(
    read: () -> MinePagedState<Item>, write: (MinePagedState<Item>) -> Void,
    isCurrent: () -> Bool, fetch: () async throws -> [Item], failureTitle: String,
    onAlert: (AppAlert) -> Void, restoringItems: ([Item], [Item]) -> [Item] = { previous, _ in previous }
) async {
    let previous = read()
    var loading = previous
    loading.status = .loading
    loading.isLoadingMore = false
    loading.loadMoreError = nil
    write(loading)
    do {
        let items = try await fetch()
        try Task.checkCancellation()
        guard isCurrent() else { return }
        var state = read()
        state.applyFirstPage(items)
        state.status = .loaded
        state.needsRefresh = false
        state.loadMoreError = nil
        write(state)
    } catch {
        guard isCurrent() else { return }
        var state = previous
        state.pagedItems.replace(with: restoringItems(previous.items, read().items))
        state.isLoadingMore = false
        let hadItems = !previous.items.isEmpty || previous.status == .loaded
        if TaskCancellation.matches(error) {
            state.status = previous.status == .loading ? (hadItems ? .loaded : .idle) : previous.status
            write(state)
            return
        }
        state.status = hadItems ? .loaded : .failed(error.localizedDescription)
        state.needsRefresh = true
        if !hadItems { state.canLoadMore = false }
        write(state)
        if hadItems { onAlert(AppAlert(title: failureTitle, error: error)) }
    }
}

@MainActor
private func loadMoreMinePage<Item: Identifiable>(
    current: Item?, read: () -> MinePagedState<Item>, write: (MinePagedState<Item>) -> Void,
    isCurrent: () -> Bool, fetch: (Int) async throws -> [Item]
) async {
    guard let current else { return }
    var state = read()
    guard state.status == .loaded, state.shouldLoadMore(currentID: current.id) else { return }
    let previousError = state.loadMoreError
    state.isLoadingMore = true
    state.loadMoreError = nil
    write(state)
    var request = CommunityPageRequest<Item.ID>(sourcePage: state.nextPage)
    do {
        guard let items = try await request.next(isCurrent: isCurrent,
            knownIDs: { read().pagedItems.ids }, fetch: fetch) else { return }
        state = read()
        state.nextPage = request.sourcePage
        state.appendPage(items)
        write(state)
    } catch {
        guard isCurrent() else { return }
        state = read()
        state.nextPage = request.sourcePage
        state.isLoadingMore = false
        state.loadMoreError = TaskCancellation.matches(error) ? previousError : error.localizedDescription
        write(state)
    }
}

/// 生成资料卡展示的帖子数摘要。
///
/// 分页结果的数量后缀 `+` 表示当前页后续可能还有更多帖子。
private func minePosterCountText(for state: MinePagedState<CommunityPoster>) -> String {
    if !state.items.isEmpty { return state.canLoadMore ? "\(state.items.count)+" : "\(state.items.count)" }
    switch state.status {
    case .idle, .loading: return "..."
    case .loaded: return "0"
    case .failed: return "待恢复"
    }
}

@MainActor
/// “我的”页状态机。
///
/// 负责资料卡刷新，以及粉丝、关注、帖子三个分页列表的加载。
final class MineViewModel: ObservableObject {
    /// 当前登录用户的资料卡信息。
    @Published private(set) var userInfo: MineUserInfo?
    /// 资料卡加载状态。
    @Published private(set) var profileStatus: MineLoadStatus = .idle
    @Published private(set) var profileNeedsRefresh = false
    /// 粉丝列表分页状态。
    @Published private(set) var followerState = MinePagedState<CommunityUser>()
    /// 关注列表分页状态。
    @Published private(set) var followingState = MinePagedState<CommunityUser>()
    /// 我的帖子列表分页状态。
    @Published private(set) var posterState = MinePagedState<CommunityPoster>()
    @Published var alert: AppAlert?

    private let service: any MineOverviewServicing
    private var resourceSubscription: AnyCancellable?
    /// 记录主页首次加载流程的执行状态。
    private var hasBootstrapped = false
    private var profileGeneration = 0
    private var followerGeneration = 0
    private var followingGeneration = 0
    private var posterGeneration = 0

    init(service: any MineOverviewServicing) {
        self.service = service
        resourceSubscription = service.resourceChanges.sink { [weak self] metrics in
            guard let self else { return }
            let needsRefresh = self.posterState.items.needsCommunityRefresh(for: metrics)
            if needsRefresh {
                self.posterGeneration &+= 1
                self.posterState.isLoadingMore = false
                if self.posterState.status == .loading { self.posterState.status = .loaded }
            }
            var updated = self.posterState
            if updated.pagedItems.apply(metrics) { self.posterState = updated }
            if needsRefresh { self.posterState.needsRefresh = true }
        }
    }


    /// 首次进入“我的”页时加载资料卡和第一页帖子。
    ///
    /// 首页启动流程并行请求资料卡和帖子；粉丝和关注列表在对应页面进入时加载。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        async let profileTask = refreshProfile()
        async let posterTask = refreshPosters()
        _ = await (profileTask, posterTask)
        if profileStatus == .idle || posterState.status == .idle { hasBootstrapped = false }
    }

    /// 返回主页时更新资料，首次进入时同时加载帖子摘要。
    func refreshOverview() async {
        if hasBootstrapped { await refreshProfile() }
        else { await bootstrapIfNeeded() }
    }

    /// 用户刷新主页时同步资料卡与帖子摘要。
    func refreshAll() async {
        async let profile: Void = refreshProfile()
        async let posters: Void = refreshPosters()
        _ = await (profile, posters)
    }

    /// 资料卡里展示的帖子数摘要。
    var posterCountText: String {
        minePosterCountText(for: posterState)
    }

    /// 刷新个人资料卡。
    ///
    /// 页面已有资料时，刷新失败保留已展示内容并弹出提示。
    func refreshProfile() async {
        let previousStatus = profileStatus == .loading ? .idle : profileStatus
        profileGeneration &+= 1
        let generation = profileGeneration
        let hadUserInfo = userInfo != nil || profileStatus == .loaded
        if !hadUserInfo {
            profileStatus = .loading
        }

        do {
            let info = try await service.fetchMyInfo()
            try Task.checkCancellation()
            guard profileGeneration == generation else { return }
            userInfo = info
            profileStatus = .loaded
            profileNeedsRefresh = false
        } catch {
            guard profileGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                profileStatus = hadUserInfo ? .loaded : previousStatus
                return
            }
            profileNeedsRefresh = true
            if hadUserInfo {
                profileStatus = .loaded
                alert = AppAlert(title: "刷新个人信息失败", error: error)
                return
            }

            userInfo = nil
            profileStatus = .failed(error.localizedDescription)
        }
    }

    /// 重新拉取粉丝第一页。
    ///
    /// 刷新成功后提交第一页和新游标，失败时保留可用列表。
    func refreshFollowers() async {
        followerGeneration &+= 1
        let generation = followerGeneration
        await refreshMinePage(read: { self.followerState }, write: { self.followerState = $0 },
            isCurrent: { self.followerGeneration == generation }, fetch: { try await self.service.fetchFollowers(page: 0) },
            failureTitle: "刷新粉丝失败", onAlert: { self.alert = $0 })
    }

    /// 粉丝列表的分页加载。
    func loadMoreFollowersIfNeeded(currentUser: CommunityUser?) async {
        let generation = followerGeneration
        await loadMoreMinePage(current: currentUser, read: { self.followerState }, write: { self.followerState = $0 },
            isCurrent: { self.followerGeneration == generation }, fetch: { try await self.service.fetchFollowers(page: $0) })
    }

    /// 重新拉取关注列表第一页。
    func refreshFollowings() async {
        followingGeneration &+= 1
        let generation = followingGeneration
        await refreshMinePage(read: { self.followingState }, write: { self.followingState = $0 },
            isCurrent: { self.followingGeneration == generation }, fetch: { try await self.service.fetchFollowings(page: 0) },
            failureTitle: "刷新关注失败", onAlert: { self.alert = $0 })
    }

    /// 关注列表的分页加载。
    func loadMoreFollowingsIfNeeded(currentUser: CommunityUser?) async {
        let generation = followingGeneration
        await loadMoreMinePage(current: currentUser, read: { self.followingState }, write: { self.followingState = $0 },
            isCurrent: { self.followingGeneration == generation }, fetch: { try await self.service.fetchFollowings(page: $0) })
    }

    /// 重新拉取“我的帖子”第一页。
    ///
    /// 页面已有帖子时，刷新失败保留已展示内容并弹出提示。
    func refreshPosters() async {
        posterGeneration &+= 1
        let generation = posterGeneration
        await refreshMinePage(read: { self.posterState }, write: { self.posterState = $0 },
            isCurrent: { self.posterGeneration == generation }, fetch: { try await self.service.fetchMyPosters(page: 0) },
            failureTitle: "刷新帖子失败", onAlert: { self.alert = $0 },
            restoringItems: { $0.preservingCommunityMetrics(from: $1) })
    }

    /// “我的帖子”列表的分页加载。
    func loadMorePostersIfNeeded(currentPoster: CommunityPoster?) async {
        let generation = posterGeneration
        await loadMoreMinePage(current: currentPoster, read: { self.posterState }, write: { self.posterState = $0 },
            isCurrent: { self.posterGeneration == generation }, fetch: { try await self.service.fetchMyPosters(page: $0) })
    }

}

@MainActor
/// 他人主页状态机。
///
/// 负责拉取指定用户的公开资料和帖子列表，供话题详情里的“查看主页”复用。
final class UserProfileViewModel: ObservableObject {
    /// 他人主页资料卡。
    @Published private(set) var userInfo: MineUserInfo?
    /// 资料卡加载状态。
    @Published private(set) var profileStatus: MineLoadStatus = .idle
    @Published private(set) var profileNeedsRefresh = false
    /// 他人帖子列表分页状态。
    @Published private(set) var posterState = MinePagedState<CommunityPoster>()
    @Published private(set) var isFollowingUser = false
    @Published var alert: AppAlert?

    private let userID: Int
    private let service: any UserProfileServicing
    private var resourceSubscription: AnyCancellable?
    /// 记录首次加载流程的执行状态。
    private var hasBootstrapped = false
    private var profileGeneration = 0
    private var posterGeneration = 0
    private var followRevision = 0
    private var latestFollowResult: MineFollowResult?
    private var followResultNeedsReview = false

    init(userID: Int, service: any UserProfileServicing) {
        self.userID = userID
        self.service = service
        resourceSubscription = service.resourceChanges.sink { [weak self] metrics in
            guard let self else { return }
            let needsRefresh = self.posterState.items.needsCommunityRefresh(for: metrics)
            if needsRefresh {
                self.posterGeneration &+= 1
                self.posterState.isLoadingMore = false
                if self.posterState.status == .loading { self.posterState.status = .loaded }
            }
            var updated = self.posterState
            if updated.pagedItems.apply(metrics) { self.posterState = updated }
            if needsRefresh { self.posterState.needsRefresh = true }
        }
    }


    /// 首次进入主页时加载资料和第一页帖子。
    ///
    /// 他人主页的首屏内容由资料和帖子组成，资料与帖子请求在 `refreshAll()` 中并发执行。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else {
            if followResultNeedsReview { await refreshProfile() }
            return
        }
        hasBootstrapped = true
        await refreshAll()
        if profileStatus == .idle || posterState.status == .idle { hasBootstrapped = false }
    }

    /// 资料卡里展示的帖子数摘要。
    var posterCountText: String {
        minePosterCountText(for: posterState)
    }

    /// 并发刷新资料卡和帖子列表，缩短进入主页后的首屏等待时间。
    func refreshAll() async {
        async let infoTask: Void = refreshProfile()
        async let posterTask: Void = refreshPosters()
        _ = await (infoTask, posterTask)
    }

    /// 刷新指定用户资料卡。
    func refreshProfile() async {
        let previousStatus = profileStatus == .loading ? .idle : profileStatus
        profileGeneration &+= 1
        let generation = profileGeneration
        let followRevisionAtStart = followRevision
        let hadUserInfo = userInfo != nil || profileStatus == .loaded
        if !hadUserInfo {
            profileStatus = .loading
        }

        do {
            let info = try await service.fetchUserInfo(id: userID)
            try Task.checkCancellation()
            guard profileGeneration == generation else { return }
            if followRevision != followRevisionAtStart, let latestFollowResult {
                userInfo = info.updatingFollow(latestFollowResult)
            } else {
                userInfo = info
                latestFollowResult = nil
            }
            profileStatus = .loaded
            profileNeedsRefresh = false
            followResultNeedsReview = false
        } catch {
            guard profileGeneration == generation else { return }
            if TaskCancellation.matches(error) {
                profileStatus = hadUserInfo ? .loaded : previousStatus
                return
            }
            profileNeedsRefresh = true
            if hadUserInfo {
                profileStatus = .loaded
                alert = AppAlert(title: "刷新主页失败", error: error)
                return
            }

            userInfo = nil
            profileStatus = .failed(error.localizedDescription)
        }
    }

    func followUser() async {
        guard !followResultNeedsReview else {
            alert = AppAlert(title: "关注结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage)
            return
        }
        guard let userInfo, !userInfo.own, !isFollowingUser else { return }
        isFollowingUser = true
        defer { isFollowingUser = false }
        guard userInfo.isViewerAuthenticated else { await refreshProfile(); return }

        do {
            let result = try await service.followUser(id: userID)
            followRevision &+= 1
            latestFollowResult = result
            self.userInfo = (self.userInfo ?? userInfo).updatingFollow(result)
        } catch {
            if error is CommunityToggleOutcomeUnknown {
                followResultNeedsReview = true
                guard !Task.isCancelled else { return }
                await refreshProfile()
                guard !Task.isCancelled else { return }
                if followResultNeedsReview { alert = AppAlert(title: "关注结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage) }
                return
            }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: userInfo.following ? "取消关注失败" : "关注失败", error: error)
        }
    }

    /// 刷新指定用户帖子列表第一页。
    func refreshPosters() async {
        posterGeneration &+= 1
        let generation = posterGeneration
        await refreshMinePage(read: { self.posterState }, write: { self.posterState = $0 },
            isCurrent: { self.posterGeneration == generation }, fetch: { try await self.service.fetchUserPosters(userID: self.userID, page: 0) },
            failureTitle: "刷新帖子失败", onAlert: { self.alert = $0 },
            restoringItems: { $0.preservingCommunityMetrics(from: $1) })
    }

    /// 指定用户帖子列表分页加载。
    func loadMorePostersIfNeeded(currentPoster: CommunityPoster?) async {
        let generation = posterGeneration
        await loadMoreMinePage(current: currentPoster, read: { self.posterState }, write: { self.posterState = $0 },
            isCurrent: { self.posterGeneration == generation }, fetch: { try await self.service.fetchUserPosters(userID: self.userID, page: $0) })
    }

}
