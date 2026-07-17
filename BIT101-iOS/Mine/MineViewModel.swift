//
//  MineViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

/// “我的”列表分页触发条件。
///
/// 只有滚动到尾部附近、当前不在加载中且服务端仍有更多数据时，才允许继续翻页。
/// “我的”模块统一使用的取消错误判断。
///
/// 页面切换、下拉刷新和任务复用时都可能触发取消，这里集中兼容 Swift Concurrency 与 URLSession 两类信号。
private func isMineCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

/// 把分页状态重置到“重新拉第一页”的初始状态。
///
/// “我的”模块里多个列表都沿用同一套分页状态结构，因此第一页刷新前的状态清空逻辑也完全一致。
private func resetMinePagedState<Item>(_ state: inout MinePagedState<Item>) {
    state.status = .loading
    state.resetPagination()
}

/// 用新拉回来的第一页结果覆盖分页状态。
///
/// “我的”模块多个列表第一页刷新成功后的回写逻辑完全一致，因此集中成一个 helper，
/// 避免每个刷新函数都各自维护同样一套字段赋值。
private func applyMinePagedRefreshResult<Item>(_ items: [Item], to state: inout MinePagedState<Item>) {
    state.applyFirstPage(items)
    state.status = .loaded
}

/// 将新加载的一页结果追加到已有分页状态中。
///
/// 关注、粉丝、帖子三类列表在“加载更多成功”时的状态推进规则相同，因此统一收口。
private func appendMinePagedPage<Item>(_ items: [Item], to state: inout MinePagedState<Item>) {
    state.appendPage(items)
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
    @Published private(set) var followerState = MinePagedState<GalleryUser>()
    /// 关注列表分页状态。
    @Published private(set) var followingState = MinePagedState<GalleryUser>()
    /// 我的帖子列表分页状态。
    @Published private(set) var posterState = MinePagedState<GalleryPoster>()
    @Published var alert: AppAlert?

    private let service: any MineOverviewServicing
    /// 防止主页首次加载逻辑重复执行。
    private var hasBootstrapped = false

    init(service: any MineOverviewServicing) {
        self.service = service
    }

    convenience init() {
        self.init(service: MineService())
    }

    /// 首次进入“我的”页时预加载资料卡和帖子数。
    ///
    /// 粉丝和关注列表保持按需进入时再加载，避免首页启动就拉太多接口。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refreshProfile()
        await refreshPosters()
    }

    /// 资料卡里展示的帖子数摘要。
    ///
    /// 服务端没有总数字段时，用 `+` 表示当前页后面可能还有更多。
    var posterCountText: String {
        switch posterState.status {
        case .idle, .loading:
            return "..."
        case .loaded:
            return posterState.canLoadMore ? "\(posterState.items.count)+" : "\(posterState.items.count)"
        case .failed:
            return "0"
        }
    }

    /// 刷新个人资料卡。
    ///
    /// 如果页面上已经有旧资料，刷新失败时保留旧内容，只弹出提示。
    func refreshProfile() async {
        let hadUserInfo = userInfo != nil || profileStatus == .loaded
        if !hadUserInfo {
            profileStatus = .loading
        }

        do {
            userInfo = try await service.fetchMyInfo()
            profileStatus = .loaded
        } catch {
            if isMineCancellation(error) {
                profileStatus = hadUserInfo ? .loaded : .idle
                return
            }

            if hadUserInfo {
                profileStatus = .loaded
                alert = AppAlert(title: "刷新个人信息失败", message: error.localizedDescription)
                return
            }

            userInfo = nil
            profileStatus = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载个人信息失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取粉丝第一页。
    ///
    /// 这里采用“整页重置再请求”的策略，因为粉丝/关注量通常不大，简单可靠比局部 diff 更重要。
    func refreshFollowers() async {
        resetMinePagedState(&followerState)

        do {
            let users = try await service.fetchFollowers(page: 0)
            applyMinePagedRefreshResult(users, to: &followerState)
        } catch {
            followerState.status = .failed(error.localizedDescription)
            followerState.canLoadMore = false
            alert = AppAlert(title: "加载粉丝失败", message: error.localizedDescription)
        }
    }

    /// 粉丝列表的分页加载。
    func loadMoreFollowersIfNeeded(currentUser: GalleryUser?) async {
        guard let currentUser else { return }
        guard followerState.status == .loaded, followerState.shouldLoadMore(currentID: currentUser.id) else { return }

        followerState.isLoadingMore = true
        do {
            let users = try await service.fetchFollowers(page: followerState.nextPage)
            appendMinePagedPage(users, to: &followerState)
        } catch {
            followerState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取关注列表第一页。
    func refreshFollowings() async {
        resetMinePagedState(&followingState)

        do {
            let users = try await service.fetchFollowings(page: 0)
            applyMinePagedRefreshResult(users, to: &followingState)
        } catch {
            followingState.status = .failed(error.localizedDescription)
            followingState.canLoadMore = false
            alert = AppAlert(title: "加载关注失败", message: error.localizedDescription)
        }
    }

    /// 关注列表的分页加载。
    func loadMoreFollowingsIfNeeded(currentUser: GalleryUser?) async {
        guard let currentUser else { return }
        guard followingState.status == .loaded, followingState.shouldLoadMore(currentID: currentUser.id) else { return }

        followingState.isLoadingMore = true
        do {
            let users = try await service.fetchFollowings(page: followingState.nextPage)
            appendMinePagedPage(users, to: &followingState)
        } catch {
            followingState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取“我的帖子”第一页。
    ///
    /// 如果当前已经有旧帖子，则刷新失败时会保留旧内容并只弹提示，避免整个页面回退成空态。
    func refreshPosters() async {
        let hadPosters = !posterState.items.isEmpty || posterState.status == .loaded
        if !hadPosters {
            resetMinePagedState(&posterState)
        }

        do {
            let posters = try await service.fetchMyPosters(page: 0)
            applyMinePagedRefreshResult(posters, to: &posterState)
        } catch {
            posterState.isLoadingMore = false

            if isMineCancellation(error) {
                posterState.status = hadPosters ? .loaded : .idle
                return
            }

            if hadPosters {
                posterState.status = .loaded
                alert = AppAlert(title: "刷新帖子失败", message: error.localizedDescription)
                return
            }

            posterState.status = .failed(error.localizedDescription)
            posterState.canLoadMore = false
            alert = AppAlert(title: "加载帖子失败", message: error.localizedDescription)
        }
    }

    /// “我的帖子”列表的分页加载。
    func loadMorePostersIfNeeded(currentPoster: GalleryPoster?) async {
        guard let currentPoster else { return }
        guard posterState.status == .loaded, posterState.shouldLoadMore(currentID: currentPoster.id) else { return }

        posterState.isLoadingMore = true
        do {
            let posters = try await service.fetchMyPosters(page: posterState.nextPage)
            appendMinePagedPage(posters, to: &posterState)
        } catch {
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
    @Published private(set) var posterState = MinePagedState<GalleryPoster>()
    @Published var alert: AppAlert?

    private let userID: Int
    private let service: any UserProfileServicing
    /// 防止首次加载逻辑重复执行。
    private var hasBootstrapped = false

    init(userID: Int, service: any UserProfileServicing) {
        self.userID = userID
        self.service = service
    }

    convenience init(userID: Int) {
        self.init(userID: userID, service: MineService())
    }

    /// 首次进入主页时预加载资料和第一页帖子。
    ///
    /// 他人主页和“我的”页不同，没有粉丝/关注分页，因此这里只并发拉资料与帖子两块内容。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refreshAll()
    }

    /// 资料卡里展示的帖子数摘要。
    var posterCountText: String {
        switch posterState.status {
        case .idle, .loading:
            return "..."
        case .loaded:
            return posterState.canLoadMore ? "\(posterState.items.count)+" : "\(posterState.items.count)"
        case .failed:
            return "0"
        }
    }

    /// 同时刷新资料卡和帖子列表。
    ///
    /// 资料卡和帖子列表相互独立，因此这里并发请求，缩短进入主页后的首屏等待时间。
    func refreshAll() async {
        async let infoTask: Void = refreshProfile()
        async let posterTask: Void = refreshPosters()
        _ = await (infoTask, posterTask)
    }

    /// 刷新指定用户资料卡。
    func refreshProfile() async {
        let hadUserInfo = userInfo != nil || profileStatus == .loaded
        if !hadUserInfo {
            profileStatus = .loading
        }

        do {
            userInfo = try await service.fetchUserInfo(id: userID)
            profileStatus = .loaded
        } catch {
            if isMineCancellation(error) {
                profileStatus = hadUserInfo ? .loaded : .idle
                return
            }

            if hadUserInfo {
                profileStatus = .loaded
                alert = AppAlert(title: "刷新主页失败", message: error.localizedDescription)
                return
            }

            userInfo = nil
            profileStatus = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载主页失败", message: error.localizedDescription)
        }
    }

    /// 刷新指定用户帖子列表第一页。
    func refreshPosters() async {
        let hadPosters = !posterState.items.isEmpty || posterState.status == .loaded
        if !hadPosters {
            resetMinePagedState(&posterState)
        }

        do {
            let posters = try await service.fetchUserPosters(userID: userID, page: 0)
            applyMinePagedRefreshResult(posters, to: &posterState)
        } catch {
            posterState.isLoadingMore = false

            if isMineCancellation(error) {
                posterState.status = hadPosters ? .loaded : .idle
                return
            }

            if hadPosters {
                posterState.status = .loaded
                alert = AppAlert(title: "刷新帖子失败", message: error.localizedDescription)
                return
            }

            posterState.status = .failed(error.localizedDescription)
            posterState.canLoadMore = false
            alert = AppAlert(title: "加载帖子失败", message: error.localizedDescription)
        }
    }

    /// 指定用户帖子列表分页加载。
    func loadMorePostersIfNeeded(currentPoster: GalleryPoster?) async {
        guard let currentPoster else { return }
        guard posterState.status == .loaded, posterState.shouldLoadMore(currentID: currentPoster.id) else { return }

        posterState.isLoadingMore = true
        do {
            let posters = try await service.fetchUserPosters(userID: userID, page: posterState.nextPage)
            appendMinePagedPage(posters, to: &posterState)
        } catch {
            posterState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

}
