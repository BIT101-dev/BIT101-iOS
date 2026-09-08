//
//  MineViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

/// “我的”模块统一识别取消错误。
///
/// 页面切换、下拉刷新和任务复用都可能触发取消。此处兼容 Swift Concurrency 与 URLSession 的取消信号。
private func isMineCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

/// 为第一页加载准备分页状态。
///
/// 多个列表使用同一套分页状态结构，第一页刷新前统一设置加载状态并重置分页。
private func resetMinePagedState<Item>(_ state: inout MinePagedState<Item>) {
    state.status = .loading
    state.resetPagination()
}

/// 将第一页结果写入分页状态并标记加载完成。
private func applyMinePagedRefreshResult<Item>(_ items: [Item], to state: inout MinePagedState<Item>) {
    state.applyFirstPage(items)
    state.status = .loaded
}

/// 将新加载的一页结果追加到现有分页状态。
private func appendMinePagedPage<Item>(_ items: [Item], to state: inout MinePagedState<Item>) {
    state.appendPage(items)
}

/// 生成资料卡展示的帖子数摘要。
///
/// 分页结果的数量后缀 `+` 表示当前页后续可能还有更多帖子。
private func minePosterCountText(for state: MinePagedState<GalleryPoster>) -> String {
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
    @Published private(set) var followerState = MinePagedState<GalleryUser>()
    /// 关注列表分页状态。
    @Published private(set) var followingState = MinePagedState<GalleryUser>()
    /// 我的帖子列表分页状态。
    @Published private(set) var posterState = MinePagedState<GalleryPoster>()
    @Published var alert: AppAlert?

    private let service: any MineOverviewServicing
    /// 记录主页首次加载流程的执行状态。
    private var hasBootstrapped = false

    init(service: any MineOverviewServicing) {
        self.service = service
    }

    convenience init() {
        self.init(service: MineService())
    }

    /// 首次进入“我的”页时加载资料卡和第一页帖子。
    ///
    /// 首页启动流程先请求资料卡和帖子；粉丝和关注列表在对应页面进入时加载。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refreshProfile()
        await refreshPosters()
    }

    /// 资料卡里展示的帖子数摘要。
    var posterCountText: String {
        minePosterCountText(for: posterState)
    }

    /// 刷新个人资料卡。
    ///
    /// 页面已有旧资料时，刷新失败保留旧内容并弹出提示。
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
    /// 粉丝和关注量通常不大，刷新时重置分页状态并请求第一页。
    func refreshFollowers() async {
        let previousState = followerState
        resetMinePagedState(&followerState)

        do {
            let users = try await service.fetchFollowers(page: 0)
            applyMinePagedRefreshResult(users, to: &followerState)
        } catch {
            if isMineCancellation(error) {
                followerState = previousState
                return
            }
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
            if isMineCancellation(error) {
                followerState.isLoadingMore = false
                return
            }
            followerState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取关注列表第一页。
    func refreshFollowings() async {
        let previousState = followingState
        resetMinePagedState(&followingState)

        do {
            let users = try await service.fetchFollowings(page: 0)
            applyMinePagedRefreshResult(users, to: &followingState)
        } catch {
            if isMineCancellation(error) {
                followingState = previousState
                return
            }
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
            if isMineCancellation(error) {
                followingState.isLoadingMore = false
                return
            }
            followingState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 重新拉取“我的帖子”第一页。
    ///
    /// 页面已有旧帖子时，刷新失败保留旧内容并弹出提示，页面继续显示原有列表。
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
            if isMineCancellation(error) {
                posterState.isLoadingMore = false
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
    @Published private(set) var posterState = MinePagedState<GalleryPoster>()
    @Published var alert: AppAlert?

    private let userID: Int
    private let service: any UserProfileServicing
    /// 记录首次加载流程的执行状态。
    private var hasBootstrapped = false

    init(userID: Int, service: any UserProfileServicing) {
        self.userID = userID
        self.service = service
    }

    convenience init(userID: Int) {
        self.init(userID: userID, service: MineService())
    }

    /// 首次进入主页时加载资料和第一页帖子。
    ///
    /// 他人主页的首屏内容由资料和帖子组成，资料与帖子请求在 `refreshAll()` 中并发执行。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refreshAll()
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
            if isMineCancellation(error) {
                posterState.isLoadingMore = false
                return
            }
            posterState.isLoadingMore = false
            alert = AppAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

}
