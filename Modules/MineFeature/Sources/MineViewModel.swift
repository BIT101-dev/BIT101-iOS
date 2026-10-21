import CommunityTransport
import TransportCore
import DesignSystemKit
import CommunityCore
import Combine
import Foundation

/// “我的”模块统一识别取消错误。
///
/// 页面切换、下拉刷新和任务复用都可能触发取消。统一识别 Swift Concurrency 与 URLSession 的取消信号。
private func isMineCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

private func isMineNotLoggedIn(_ error: Error) -> Bool {
    guard let serviceError = error as? MineServiceError else { return false }
    if case .notLoggedIn = serviceError { return true }
    return false
}

/// 为第一页加载准备分页状态。
///
/// 首屏请求完成后提交新分页，加载期间保留已有列表与游标。
private func prepareMinePagedRefresh<Item: Identifiable>(_ state: inout MinePagedState<Item>) {
    state.status = .loading
    state.isLoadingMore = false
}

/// 将第一页结果写入分页状态并标记加载完成。
private func applyMinePagedRefreshResult<Item: Identifiable>(_ items: [Item], to state: inout MinePagedState<Item>) {
    state.applyFirstPage(items)
    state.status = .loaded
}

/// 将新加载的一页结果追加到现有分页状态。
private func appendMinePagedPage<Item: Identifiable>(_ items: [Item], to state: inout MinePagedState<Item>) {
    state.appendPage(items)
}

/// 生成资料卡展示的帖子数摘要。
///
/// 分页结果的数量后缀 `+` 表示当前页后续可能还有更多帖子。
private func minePosterCountText(for state: MinePagedState<CommunityPoster>) -> String {
    switch state.status {
    case .idle, .loading:
        return "..."
    case .loaded:
        return state.canLoadMore ? "\(state.items.count)+" : "\(state.items.count)"
    case .failed:
        return "0"
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
    /// 粉丝列表分页状态。
    @Published private(set) var followerState = MinePagedState<CommunityUser>()
    /// 关注列表分页状态。
    @Published private(set) var followingState = MinePagedState<CommunityUser>()
    /// 我的帖子列表分页状态。
    @Published private(set) var posterState = MinePagedState<CommunityPoster>()
    /// 社区会话失效时通知页面回到登录流程。
    @Published private(set) var requiresLogin = false
    @Published var alert: AppAlert?

    private let service: any MineOverviewServicing
    /// 记录主页首次加载流程的执行状态。
    private var hasBootstrapped = false
    private var profileGeneration = 0
    private var followerGeneration = 0
    private var followingGeneration = 0
    private var posterGeneration = 0

    init(service: any MineOverviewServicing) {
        self.service = service
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

    /// 资料卡里展示的帖子数摘要。
    var posterCountText: String {
        minePosterCountText(for: posterState)
    }

    /// 刷新个人资料卡。
    ///
    /// 页面已有资料时，刷新失败保留已展示内容并弹出提示。
    func refreshProfile() async {
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
        } catch {
            guard profileGeneration == generation else { return }
            if isMineCancellation(error) {
                profileStatus = hadUserInfo ? .loaded : .idle
                return
            }
            if isMineNotLoggedIn(error) {
                requiresLogin = true
                return
            }

            if hadUserInfo {
                profileStatus = .loaded
                alert = AppAlert(title: "刷新个人信息失败", message: error.localizedDescription)
                return
            }

            userInfo = nil
            profileStatus = .failed(error.localizedDescription)
        }
    }

    /// 重新拉取粉丝第一页。
    ///
    /// 粉丝和关注量通常不大，刷新时重置分页状态并请求第一页。
    func refreshFollowers() async {
        followerGeneration &+= 1
        let generation = followerGeneration
        let previousState = followerState
        prepareMinePagedRefresh(&followerState)

        do {
            let users = try await service.fetchFollowers(page: 0)
            try Task.checkCancellation()
            guard followerGeneration == generation else { return }
            applyMinePagedRefreshResult(users, to: &followerState)
        } catch {
            guard followerGeneration == generation else { return }
            if isMineCancellation(error) {
                followerState = previousState
                followerState.isLoadingMore = false
                if case .loading = previousState.status {
                    followerState.status = previousState.items.isEmpty ? .idle : .loaded
                }
                return
            }
            if isMineNotLoggedIn(error) {
                requiresLogin = true
                return
            }
            if previousState.status == .loaded || !previousState.items.isEmpty {
                followerState = previousState
                followerState.isLoadingMore = false
                followerState.status = .loaded
                alert = AppAlert(title: "刷新粉丝失败", message: error.localizedDescription)
                return
            }
            followerState.status = .failed(error.localizedDescription)
            followerState.canLoadMore = false
        }
    }

    /// 粉丝列表的分页加载。
    func loadMoreFollowersIfNeeded(currentUser: CommunityUser?) async {
        guard let currentUser else { return }
        guard followerState.status == .loaded, followerState.shouldLoadMore(currentID: currentUser.id) else { return }

        let generation = followerGeneration
        followerState.isLoadingMore = true
        do {
            var progress = CommunityPageProgress<Int>()
            while true {
                let users = try await service.fetchFollowers(page: followerState.nextPage)
                try Task.checkCancellation()
                guard followerGeneration == generation else { return }
                try progress.record(users.map(\.id), knownIDs: followerState.pagedItems.ids)
                if users.isEmpty || users.contains(where: { !followerState.pagedItems.ids.contains($0.id) }) {
                    appendMinePagedPage(users, to: &followerState)
                    break
                }
                followerState.nextPage += 1
            }
        } catch {
            guard followerGeneration == generation else { return }
            if isMineCancellation(error) {
                followerState.isLoadingMore = false
                return
            }
            if isMineNotLoggedIn(error) {
                followerState.isLoadingMore = false
                requiresLogin = true
                return
            }
            followerState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取关注列表第一页。
    func refreshFollowings() async {
        followingGeneration &+= 1
        let generation = followingGeneration
        let previousState = followingState
        prepareMinePagedRefresh(&followingState)

        do {
            let users = try await service.fetchFollowings(page: 0)
            try Task.checkCancellation()
            guard followingGeneration == generation else { return }
            applyMinePagedRefreshResult(users, to: &followingState)
        } catch {
            guard followingGeneration == generation else { return }
            if isMineCancellation(error) {
                followingState = previousState
                followingState.isLoadingMore = false
                if case .loading = previousState.status {
                    followingState.status = previousState.items.isEmpty ? .idle : .loaded
                }
                return
            }
            if isMineNotLoggedIn(error) {
                requiresLogin = true
                return
            }
            if previousState.status == .loaded || !previousState.items.isEmpty {
                followingState = previousState
                followingState.isLoadingMore = false
                followingState.status = .loaded
                alert = AppAlert(title: "刷新关注失败", message: error.localizedDescription)
                return
            }
            followingState.status = .failed(error.localizedDescription)
            followingState.canLoadMore = false
        }
    }

    /// 关注列表的分页加载。
    func loadMoreFollowingsIfNeeded(currentUser: CommunityUser?) async {
        guard let currentUser else { return }
        guard followingState.status == .loaded, followingState.shouldLoadMore(currentID: currentUser.id) else { return }

        let generation = followingGeneration
        followingState.isLoadingMore = true
        do {
            var progress = CommunityPageProgress<Int>()
            while true {
                let users = try await service.fetchFollowings(page: followingState.nextPage)
                try Task.checkCancellation()
                guard followingGeneration == generation else { return }
                try progress.record(users.map(\.id), knownIDs: followingState.pagedItems.ids)
                if users.isEmpty || users.contains(where: { !followingState.pagedItems.ids.contains($0.id) }) {
                    appendMinePagedPage(users, to: &followingState)
                    break
                }
                followingState.nextPage += 1
            }
        } catch {
            guard followingGeneration == generation else { return }
            if isMineCancellation(error) {
                followingState.isLoadingMore = false
                return
            }
            if isMineNotLoggedIn(error) {
                followingState.isLoadingMore = false
                requiresLogin = true
                return
            }
            followingState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取“我的帖子”第一页。
    ///
    /// 页面已有帖子时，刷新失败保留已展示内容并弹出提示。
    func refreshPosters() async {
        posterGeneration &+= 1
        let generation = posterGeneration
        let hadPosters = !posterState.items.isEmpty || posterState.status == .loaded
        if !hadPosters {
            prepareMinePagedRefresh(&posterState)
        } else {
            posterState.status = .loading
            posterState.isLoadingMore = false
        }

        do {
            let posters = try await service.fetchMyPosters(page: 0)
            try Task.checkCancellation()
            guard posterGeneration == generation else { return }
            applyMinePagedRefreshResult(posters, to: &posterState)
        } catch {
            guard posterGeneration == generation else { return }
            posterState.isLoadingMore = false

            if isMineCancellation(error) {
                posterState.status = hadPosters ? .loaded : .idle
                return
            }
            if isMineNotLoggedIn(error) {
                requiresLogin = true
                return
            }

            if hadPosters {
                posterState.status = .loaded
                alert = AppAlert(title: "刷新帖子失败", message: error.localizedDescription)
                return
            }

            posterState.status = .failed(error.localizedDescription)
            posterState.canLoadMore = false
        }
    }

    /// “我的帖子”列表的分页加载。
    func loadMorePostersIfNeeded(currentPoster: CommunityPoster?) async {
        guard let currentPoster else { return }
        guard posterState.status == .loaded, posterState.shouldLoadMore(currentID: currentPoster.id) else { return }

        let generation = posterGeneration
        posterState.isLoadingMore = true
        do {
            var progress = CommunityPageProgress<Int>()
            while true {
                let posters = try await service.fetchMyPosters(page: posterState.nextPage)
                try Task.checkCancellation()
                guard posterGeneration == generation else { return }
                try progress.record(posters.map(\.id), knownIDs: posterState.pagedItems.ids)
                if posters.isEmpty || posters.contains(where: { !posterState.pagedItems.ids.contains($0.id) }) {
                    appendMinePagedPage(posters, to: &posterState)
                    break
                }
                posterState.nextPage += 1
            }
        } catch {
            guard posterGeneration == generation else { return }
            if isMineCancellation(error) {
                posterState.isLoadingMore = false
                return
            }
            if isMineNotLoggedIn(error) {
                posterState.isLoadingMore = false
                requiresLogin = true
                return
            }
            posterState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
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
    /// 他人帖子列表分页状态。
    @Published private(set) var posterState = MinePagedState<CommunityPoster>()
    @Published private(set) var isFollowingUser = false
    /// 社区会话失效时通知页面回到登录流程。
    @Published private(set) var requiresLogin = false
    @Published var alert: AppAlert?

    private let userID: Int
    private let service: any UserProfileServicing
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
    }


    /// 首次进入主页时加载资料和第一页帖子。
    ///
    /// 他人主页的首屏内容由资料和帖子组成，资料与帖子请求在 `refreshAll()` 中并发执行。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
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
            followResultNeedsReview = false
        } catch {
            guard profileGeneration == generation else { return }
            if isMineCancellation(error) {
                profileStatus = hadUserInfo ? .loaded : .idle
                return
            }
            if isMineNotLoggedIn(error) {
                requiresLogin = true
                return
            }

            if hadUserInfo {
                profileStatus = .loaded
                alert = AppAlert(title: "刷新主页失败", message: error.localizedDescription)
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

        do {
            let result = try await service.followUser(id: userID)
            followRevision &+= 1
            latestFollowResult = result
            self.userInfo = (self.userInfo ?? userInfo).updatingFollow(result)
        } catch {
            if error is CommunityToggleOutcomeUnknown {
                followResultNeedsReview = true
                await refreshProfile()
                if followResultNeedsReview { alert = AppAlert(title: "关注结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage) }
                return
            }
            if isMineCancellation(error) { return }
            if isMineNotLoggedIn(error) {
                requiresLogin = true
                return
            }
            alert = AppAlert(title: userInfo.following ? "取消关注失败" : "关注失败", message: error.localizedDescription)
        }
    }

    /// 刷新指定用户帖子列表第一页。
    func refreshPosters() async {
        posterGeneration &+= 1
        let generation = posterGeneration
        let hadPosters = !posterState.items.isEmpty || posterState.status == .loaded
        if !hadPosters {
            prepareMinePagedRefresh(&posterState)
        } else {
            posterState.status = .loading
            posterState.isLoadingMore = false
        }

        do {
            let posters = try await service.fetchUserPosters(userID: userID, page: 0)
            try Task.checkCancellation()
            guard posterGeneration == generation else { return }
            applyMinePagedRefreshResult(posters, to: &posterState)
        } catch {
            guard posterGeneration == generation else { return }
            posterState.isLoadingMore = false

            if isMineCancellation(error) {
                posterState.status = hadPosters ? .loaded : .idle
                return
            }
            if isMineNotLoggedIn(error) {
                requiresLogin = true
                return
            }

            if hadPosters {
                posterState.status = .loaded
                alert = AppAlert(title: "刷新帖子失败", message: error.localizedDescription)
                return
            }

            posterState.status = .failed(error.localizedDescription)
            posterState.canLoadMore = false
        }
    }

    /// 指定用户帖子列表分页加载。
    func loadMorePostersIfNeeded(currentPoster: CommunityPoster?) async {
        guard let currentPoster else { return }
        guard posterState.status == .loaded, posterState.shouldLoadMore(currentID: currentPoster.id) else { return }

        let generation = posterGeneration
        posterState.isLoadingMore = true
        do {
            var progress = CommunityPageProgress<Int>()
            while true {
                let posters = try await service.fetchUserPosters(userID: userID, page: posterState.nextPage)
                try Task.checkCancellation()
                guard posterGeneration == generation else { return }
                try progress.record(posters.map(\.id), knownIDs: posterState.pagedItems.ids)
                if posters.isEmpty || posters.contains(where: { !posterState.pagedItems.ids.contains($0.id) }) {
                    appendMinePagedPage(posters, to: &posterState)
                    break
                }
                posterState.nextPage += 1
            }
        } catch {
            guard posterGeneration == generation else { return }
            if isMineCancellation(error) {
                posterState.isLoadingMore = false
                return
            }
            if isMineNotLoggedIn(error) {
                posterState.isLoadingMore = false
                requiresLogin = true
                return
            }
            posterState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

}
