#if os(iOS)
import CommunityUI
import MediaKit
import CommunityCore
import DesignSystemKit
//
//  MineRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI

/// “我的”页内部导航。
///
/// 这里承载“我的主页”内部 push 的三个子列表，设置页使用独立路由，保持导航状态分离。
private enum MineRoute: Hashable, Identifiable {
    case followers
    case followings
    case posters

    /// 供导航绑定使用的稳定标识。
    var id: Self { self }
}

/// “我的”页根视图。
///
/// 页面包含资料卡、入口列表和子页面，交互使用 iOS 导航和列表样式。
public struct MineRootView: View {
    private let scene: MineRootViewScene
    private let identity: [ObjectIdentifier]

    public init(dependencies: MineDependencies, media: MediaEnvironment, posters: CommunityPosterDestination, settings: CommunitySettingsDestinations, fallbackStudentID: String, onLogout: @escaping () -> Void) {
        scene = MineRootViewScene(dependencies: dependencies, media: media, posters: posters, settings: settings, fallbackStudentID: fallbackStudentID, onLogout: onLogout)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
    }

    public var body: some View {
        scene.id(identity)
    }
}

private struct MineRootViewScene: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    private let dependencies: MineDependencies
    private let destinations: CommunitySettingsDestinations
    private let posters: CommunityPosterDestination
    private let media: MediaEnvironment
    /// 兜底学号，用于传给设置页的账号区域。
    let fallbackStudentID: String
    let onLogout: () -> Void

    /// “我的”主页状态机。
    @StateObject private var viewModel: MineViewModel

    init(dependencies: MineDependencies, media: MediaEnvironment, posters: CommunityPosterDestination, settings: CommunitySettingsDestinations, fallbackStudentID: String, onLogout: @escaping () -> Void) {
        self.dependencies = dependencies
        self.media = media
        self.posters = posters
        self.destinations = settings
        _viewModel = StateObject(wrappedValue: MineViewModel(service: dependencies.overview))
        self.fallbackStudentID = fallbackStudentID
        self.onLogout = onLogout
    }
    /// 粉丝 / 关注 / 帖子子列表路由。
    @State private var route: MineRoute?
    @State private var selectedUserID: Int?
    /// 设置页内部路由。
    @State private var settingsRoute: CommunitySettingsEntry?
    /// 建议入口通过独立 sheet 呈现，设置入口使用设置导航路由。
    @State private var isShowingSuggestion = false
    @State private var profileRefreshID = 0

    /// “我的”主页主体。
    ///
    /// 主页面展示资料卡和设置入口，列表内容进入子页面，保持主页层级清晰。
    var body: some View {
        content.environment(dependencies).environment(media).environment(posters)
    }

    private var content: some View {
        List {
            Section {
                profileSection
            }

            Section {
                settingsSection
            }
        }
        .accessibilityIdentifier("interaction.MineRootViewScene.list")
        .appGroupedListStyle()
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $route) { destination in
            Group {
                switch destination {
                case .followers:
                    MineUserListView(
                        title: "我的粉丝",
                        users: viewModel.followerState.items,
                        status: viewModel.followerState.status,
                        nextPage: viewModel.followerState.nextPage,
                        isLoadingMore: viewModel.followerState.isLoadingMore,
                        loadMoreError: viewModel.followerState.loadMoreError,
                        onRefresh: { await viewModel.refreshFollowers() },
                        onLoadMore: { user in await viewModel.loadMoreFollowersIfNeeded(currentUser: user) },
                        onOpenUser: { selectedUserID = $0.id }
                    )
                case .followings:
                    MineUserListView(
                        title: "我的关注",
                        users: viewModel.followingState.items,
                        status: viewModel.followingState.status,
                        nextPage: viewModel.followingState.nextPage,
                        isLoadingMore: viewModel.followingState.isLoadingMore,
                        loadMoreError: viewModel.followingState.loadMoreError,
                        onRefresh: { await viewModel.refreshFollowings() },
                        onLoadMore: { user in await viewModel.loadMoreFollowingsIfNeeded(currentUser: user) },
                        onOpenUser: { selectedUserID = $0.id }
                    )
                case .posters:
                    MinePosterListView(
                        posters: viewModel.posterState.items,
                        status: viewModel.posterState.status,
                        nextPage: viewModel.posterState.nextPage,
                        isLoadingMore: viewModel.posterState.isLoadingMore,
                        loadMoreError: viewModel.posterState.loadMoreError,
                        onRefresh: { await viewModel.refreshPosters() },
                        onLoadMore: { poster in await viewModel.loadMorePostersIfNeeded(currentPoster: poster) }
                    )
                }
            }
            .navigationDestination(item: $selectedUserID) { userID in
                UserProfileRootView(dependencies: dependencies, media: media, posters: posters, userID: userID)
            }
            .environment(dependencies)
            .environment(media)
            .environment(posters)
        }
        .navigationDestination(item: $settingsRoute) { destination in
            destinations.settings(CommunitySettingsRequest(entry: destination, studentID: fallbackStudentID, onLogout: onLogout))
        }
        .sheet(isPresented: $isShowingSuggestion) {
            NavigationStack {
                destinations.suggestion()
            }
        }
        .task(id: settingsRoute == nil ? profileRefreshID : nil) {
            guard settingsRoute == nil else { return }
            await viewModel.refreshOverview()
        }
        .refreshable {
            interactionEvidence?("interaction.MineRootViewScene.refreshable", "refresh")
            await viewModel.refreshAll()
        }
        .diagnosticAlert(item: $viewModel.alert)
    }

    /// 资料卡区域，根据加载状态展示骨架、错误页或真实内容。
    @ViewBuilder
    private var profileSection: some View {
        switch viewModel.profileStatus {
        case .idle, .loading:
            AppInlineLoadingState("正在加载个人信息")
        case let .failed(message):
            AppFailureState(
                title: "个人信息加载失败",
                systemImage: "person.crop.circle.badge.exclamationmark",
                message: message,
                onRetry: {
                    profileRefreshID &+= 1
                }
            )
            .frame(maxWidth: .infinity)
        case .loaded:
            if let info = viewModel.userInfo {
                MineProfileCard(
                    info: info,
                    posterCountText: viewModel.posterCountText,
                    onOpenFollowers: { route = .followers },
                    onOpenFollowings: { route = .followings },
                    onOpenPosters: { route = .posters }
                )
            }
        }
    }

    /// 设置入口列表。
    ///
    /// 设置入口进入 `SettingsRootView`，建议入口使用独立 sheet 呈现。
    private var settingsSection: some View {
        ForEach(destinations.settingsEntries) { route in
            Button {
                if route.id == "suggestion" {
                    isShowingSuggestion = true
                } else {
                    settingsRoute = route
                }
            } label: {
                AppNavigationRowLabel(
                    title: route.title,
                    showsDisclosureIndicator: true
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.route.\(route.id)")
            .appInteractiveListRow()
        }
    }
}

/// 他人主页。
///
/// 复用“我的”页的资料卡和话题卡片样式，统一用户主页的视觉表现。
public struct UserProfileRootView: View {
    private let scene: UserProfileRootViewScene
    private let identity: [ObjectIdentifier]
    private let resourceID: Int

    public init(dependencies: MineDependencies, media: MediaEnvironment, posters: CommunityPosterDestination, userID: Int) {
        scene = UserProfileRootViewScene(dependencies: dependencies, media: media, posters: posters, userID: userID)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
        resourceID = userID
    }

    public var body: some View {
        scene.id(identity)
            .id(resourceID)
    }
}

private struct UserProfileRootViewScene: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    private let dependencies: MineDependencies
    private let destinations: CommunityPosterDestination
    private let media: MediaEnvironment
    let userID: Int

    /// 指定用户主页状态机。
    @StateObject private var viewModel: UserProfileViewModel
    @State private var selectedPoster: CommunityPoster?
    @State private var imageViewer: ImagePreviewRequest?
    @State private var isProfileRetryRequested = false
    @State private var isPosterRetryRequested = false

    init(dependencies: MineDependencies, media: MediaEnvironment, posters: CommunityPosterDestination, userID: Int) {
        self.dependencies = dependencies
        self.media = media
        self.destinations = posters
        self.userID = userID
        _viewModel = StateObject(wrappedValue: UserProfileViewModel(userID: userID, service: dependencies.profile))
    }

    var body: some View {
        content.environment(dependencies).environment(media).environment(destinations)
    }

    private var content: some View {
        List {
            Section {
                profileSection
            }

            Section {
                posterSection
            }
        }
        .accessibilityIdentifier("interaction.UserProfileRootViewScene.list")
        .appGroupedListStyle()
        .refreshable {
            interactionEvidence?("interaction.UserProfileRootViewScene.refreshable", "refresh")
            await viewModel.refreshAll()
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isProfileRetryRequested) {
            if isProfileRetryRequested {
                await viewModel.refreshProfile()
                guard !Task.isCancelled else { return }
                isProfileRetryRequested = false
            } else {
                await viewModel.bootstrapIfNeeded()
            }
        }
        .task(id: isPosterRetryRequested) {
            guard isPosterRetryRequested else { return }
            await viewModel.refreshPosters()
            guard !Task.isCancelled else { return }
            isPosterRetryRequested = false
        }
        .sheet(item: $selectedPoster) { poster in
            NavigationStack {
                destinations.poster(.init(poster: poster,
                    onUpdated: { isPosterRetryRequested = true }, onDeleted: { isPosterRetryRequested = true }))
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .systemImagePreview(item: $imageViewer)
        .diagnosticAlert(item: $viewModel.alert)
    }

    @ViewBuilder
    private var profileSection: some View {
        switch viewModel.profileStatus {
        case .idle, .loading:
            AppInlineLoadingState("正在加载主页")
        case let .failed(message):
            AppFailureState(
                title: "主页加载失败",
                systemImage: "person.crop.circle.badge.exclamationmark",
                message: message,
                onRetry: {
                    isProfileRetryRequested = true
                }
            )
            .frame(maxWidth: .infinity)
        case .loaded:
            if let info = viewModel.userInfo {
                MineProfileCard(
                    info: info,
                    posterCountText: viewModel.posterCountText,
                    onOpenAvatar: {
                        imageViewer = ImagePreviewRequest(remoteImages: [info.user.avatar.previewImage], initialIndex: 0)
                    },
                    onFollow: {
                        Task { await viewModel.followUser() }
                    },
                    isFollowRequestInFlight: viewModel.isFollowingUser
                )
            }
        }
    }

    @ViewBuilder
    private var posterSection: some View {
        let visiblePosters = viewModel.posterState.items

        if isInitialPosterLoading {
            AppInlineLoadingState("正在加载帖子")
        } else if case let .failed(message) = viewModel.posterState.status, visiblePosters.isEmpty {
            AppFailureState(
                title: "帖子加载失败",
                systemImage: "text.bubble",
                message: message,
                onRetry: {
                    isPosterRetryRequested = true
                }
            )
        } else {
            if visiblePosters.isEmpty {
                AppEmptyState(title: "暂无帖子", systemImage: "text.bubble")
            } else {
                ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                    AppFeedRow(isLast: index == visiblePosters.count - 1) {
                        CommunityPosterCard(
                            poster: poster,
                            onOpenPoster: { selectedPoster = poster },
                            onOpenImage: { index, images in
                                imageViewer = ImagePreviewRequest(remoteImages: images.map(\.previewImage), initialIndex: index)
                            },
                            onDelete: nil,
                            onReport: nil
                        )
                        .task(id: viewModel.posterState.status == .loaded ? viewModel.posterState.nextPage : nil) {
                            await viewModel.loadMorePostersIfNeeded(currentPoster: poster)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                if let message = viewModel.posterState.loadMoreError {
                    AppFailureState(title: "加载更多失败", systemImage: "arrow.clockwise", message: message,
                        onRetry: { Task { await viewModel.loadMorePostersIfNeeded(currentPoster: visiblePosters.last) } })
                }
                if viewModel.posterState.isLoadingMore {
                    AppInlineLoadingState()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    private var isInitialPosterLoading: Bool {
        guard viewModel.posterState.items.isEmpty else { return false }
        switch viewModel.posterState.status {
        case .idle, .loading:
            return true
        default:
            return false
        }
    }

    private var navigationTitle: String {
        let nickname = viewModel.userInfo?.user.nickname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nickname.isEmpty ? "主页" : nickname
    }
}

/// 个人信息卡片。
///
/// “我的主页”和“他人主页”共用这张卡片，组件负责纯展示，导航和页面状态由上层传入。
private struct MineProfileCard: View {
    let info: MineUserInfo
    let posterCountText: String
    let onOpenFollowers: (() -> Void)?
    let onOpenFollowings: (() -> Void)?
    let onOpenPosters: (() -> Void)?
    let onOpenAvatar: (() -> Void)?
    let onFollow: (() -> Void)?
    let isFollowRequestInFlight: Bool

    init(
        info: MineUserInfo,
        posterCountText: String,
        onOpenFollowers: (() -> Void)? = nil,
        onOpenFollowings: (() -> Void)? = nil,
        onOpenPosters: (() -> Void)? = nil,
        onOpenAvatar: (() -> Void)? = nil,
        onFollow: (() -> Void)? = nil,
        isFollowRequestInFlight: Bool = false
    ) {
        self.info = info
        self.posterCountText = posterCountText
        self.onOpenFollowers = onOpenFollowers
        self.onOpenFollowings = onOpenFollowings
        self.onOpenPosters = onOpenPosters
        self.onOpenAvatar = onOpenAvatar
        self.onFollow = onFollow
        self.isFollowRequestInFlight = isFollowRequestInFlight
    }

    /// 资料卡主体。
    var body: some View {
        VStack(spacing: AppDesignSystem.Spacing.none) {
            if let onOpenAvatar {
                Button(action: onOpenAvatar) {
                    profileAvatar
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看头像")
            } else {
                profileAvatar
            }

            Spacer().frame(height: AppDesignSystem.Spacing.regular)

            HStack(spacing: AppDesignSystem.Spacing.regular) {
                Text(info.user.nickname)
                    .font(AppDesignSystem.Typography.titleEmphasis)

                if !info.user.identity.text.isEmpty {
                    Text(info.user.identity.text)
                        .font(AppDesignSystem.Typography.captionEmphasis)
                        .foregroundStyle(identityColor)
                }
            }

            Spacer().frame(height: AppDesignSystem.Spacing.tiny)

            Text(info.user.motto.isEmpty ? "空简介" : info.user.motto)
                .font(AppDesignSystem.Typography.body)

            Spacer().frame(height: AppDesignSystem.Spacing.regular)

            HStack(spacing: AppDesignSystem.Spacing.section) {
                MineStatButton(number: "\(info.followerNum)", title: "粉丝", action: onOpenFollowers)
                MineStatButton(number: "\(info.followingNum)", title: "关注", action: onOpenFollowings)
                MineStatButton(number: posterCountText, title: "帖子", action: onOpenPosters)
            }

            if let onFollow, !info.own {
                Button(action: onFollow) {
                    Text(info.following ? (info.follower ? "互相关注" : "已关注") : "关注")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFollowRequestInFlight)
                .accessibilityLabel(info.following ? "取消关注" : "关注")
                .padding(.top, AppDesignSystem.Spacing.regular)
                    .accessibilityIdentifier("ui.mine-profile-card.follow")
            }
        }
        .padding(.top, AppDesignSystem.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var profileAvatar: some View {
        AppAvatarView(
            imageURL: info.user.avatar.thumbnailURL,
            fallbackImageURL: info.user.avatar.originalURL,
            size: AppDesignSystem.Size.Avatar.profile,
            tint: AppDesignSystem.Palette.Accent.primary
        )
        .contentShape(Circle())
    }

    private var identityColor: Color {
        Color(hex: info.user.identity.color) ?? .secondary
    }
}

/// 粉丝 / 关注 列表页。
///
/// 页面展示一类用户数组，刷新和分页操作由上层 ViewModel 传入。
private struct MineUserListView: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    let title: String
    let users: [CommunityUser]
    let status: MineLoadStatus
    let nextPage: Int
    let isLoadingMore: Bool
    let loadMoreError: String?
    let onRefresh: () async -> Void
    let onLoadMore: (CommunityUser?) async -> Void
    let onOpenUser: (CommunityUser) -> Void
    @State private var isRefreshRequested = false

    var body: some View {
        Group {
            if isInitialLoading {
                AppLoadingState(title: "正在加载")
            } else if case let .failed(message) = status, users.isEmpty {
                AppFailureState(
                    title: "用户列表加载失败",
                    systemImage: "person.2.slash",
                    message: message,
                    onRetry: {
                        isRefreshRequested = true
                    }
                )
            } else {
                List {
                    ForEach(users) { user in
                        Button {
                            onOpenUser(user)
                        } label: {
                            HStack(spacing: AppDesignSystem.Spacing.content) {
                                AppAvatarView(
                                    imageURL: user.avatar.thumbnailURL,
                                    fallbackImageURL: user.avatar.originalURL,
                                    size: AppDesignSystem.Size.Avatar.standard,
                                    tint: AppDesignSystem.Palette.Accent.primary
                                )

                                VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                                    HStack(spacing: AppDesignSystem.Spacing.tiny) {
                                        Text(user.nickname)
                                            .font(AppDesignSystem.Typography.title)

                                        if !user.identity.text.isEmpty {
                                            Text(user.identity.text)
                                                .font(AppDesignSystem.Typography.captionEmphasis)
                                                .foregroundStyle(Color(hex: user.identity.color) ?? AppDesignSystem.Palette.Status.info)
                                        }
                                    }

                                    Text("UID：\(user.id)")
                                        .font(AppDesignSystem.Typography.caption)
                                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(user.nickname.isEmpty ? "未命名用户" : user.nickname)
                        .accessibilityValue("UID \(user.id)")
                        .accessibilityHint("打开用户主页")
                        .task(id: status == .loaded ? nextPage : nil) {
                            await onLoadMore(user)
                        }
                        .appInteractiveListRow()
                            .accessibilityIdentifier("ui.mine-user-list-view.user")
                    }

                    if let loadMoreError {
                        AppFailureState(title: "加载更多失败", systemImage: "arrow.clockwise", message: loadMoreError,
                            onRetry: { Task { await onLoadMore(users.last) } })
                    }
                    if isLoadingMore {
                        AppInlineLoadingState()
                    }
                }
                .accessibilityIdentifier("interaction.MineUserListView.list")
                .appGroupedListStyle()
                .refreshable {
                    interactionEvidence?("interaction.MineUserListView.refreshable", "refresh")

                    await onRefresh()
                }
            }
        }
        .task(id: isRefreshRequested) {
            if status == .idle || isRefreshRequested {
                await onRefresh()
                guard !Task.isCancelled else { return }
                isRefreshRequested = false
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isInitialLoading: Bool {
        if case .idle = status { return true }
        if case .loading = status { return users.isEmpty }
        return false
    }
}

/// 我的帖子列表页。
///
/// 复用话题卡片与详情实现，统一“我的帖子”和“话题详情”的视觉和交互逻辑。
private struct MinePosterListView: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    @Environment(MineDependencies.self) private var dependencies
    @Environment(CommunityPosterDestination.self) private var destinations
    let posters: [CommunityPoster]
    let status: MineLoadStatus
    let nextPage: Int
    let isLoadingMore: Bool
    let loadMoreError: String?
    let onRefresh: () async -> Void
    let onLoadMore: (CommunityPoster?) async -> Void
    @State private var selectedPoster: CommunityPoster?
    @State private var imageViewer: ImagePreviewRequest?
    @State private var deletingPoster: CommunityPoster?
    @State private var alert: AppAlert?
    @State private var deletedPosterIDs: Set<Int> = []
    @State private var isRefreshRequested = false

    /// 当前真正可展示的帖子列表。
    ///
    /// 过滤服务端刷新前已删除的帖子，保持删除后的列表状态。
    private var visiblePosters: [CommunityPoster] {
        posters.filter { !deletedPosterIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if isInitialLoading {
                AppLoadingState(title: "正在加载帖子")
            } else if case let .failed(message) = status, visiblePosters.isEmpty {
                AppFailureState(
                    title: "帖子加载失败",
                    systemImage: "text.bubble",
                    message: message,
                    onRetry: {
                        isRefreshRequested = true
                    }
                )
            } else if visiblePosters.isEmpty {
                AppEmptyState(title: "暂无可显示的帖子", systemImage: "text.bubble")
            } else {
                ScrollView {
                    LazyVStack(spacing: AppDesignSystem.Spacing.none) {
                        ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                            AppFeedRow(isLast: index == visiblePosters.count - 1) {
                                CommunityPosterCard(
                                    poster: poster,
                                    onOpenPoster: { selectedPoster = poster },
                                    onOpenImage: { index, images in
                                        imageViewer = ImagePreviewRequest(remoteImages: images.map(\.previewImage), initialIndex: index)
                                    },
                                    onDelete: { deletingPoster = poster },
                                    onReport: nil
                                )
                                .task(id: status == .loaded ? nextPage : nil) {
                                    await onLoadMore(poster)
                                }
                            }
                        }

                        if let loadMoreError {
                            AppFailureState(title: "加载更多失败", systemImage: "arrow.clockwise", message: loadMoreError,
                                onRetry: { Task { await onLoadMore(visiblePosters.last) } })
                        }
                        if isLoadingMore {
                            AppInlineLoadingState()
                        }
                    }
                }
                .accessibilityIdentifier("interaction.MinePosterListView.scroll")
                .refreshable {
                    interactionEvidence?("interaction.MinePosterListView.refreshable", "refresh")

                    await onRefresh()
                }
            }
        }
        .task(id: isRefreshRequested) {
            if status == .idle || isRefreshRequested {
                await onRefresh()
                guard !Task.isCancelled else { return }
                isRefreshRequested = false
            }
        }
        .background(AppDesignSystem.Palette.Background.grouped)
        .navigationTitle("我的帖子")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPoster) { poster in
            NavigationStack {
                destinations.poster(.init(
                    poster: poster,
                    onUpdated: { isRefreshRequested = true },
                    onDeleted: {
                        deletedPosterIDs.insert(poster.id)
                        isRefreshRequested = true
                    }
                ))
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .systemImagePreview(item: $imageViewer)
        .alert(
            "删除帖子",
            isPresented: Binding(
                get: { deletingPoster != nil },
                set: { if !$0 { deletingPoster = nil } }
            ),
            presenting: deletingPoster
        ) { poster in
            Button("取消", role: .cancel) {
                deletingPoster = nil
            }
                .accessibilityIdentifier("ui.mine-poster-list-view.cancel")
            Button("删除", role: .destructive) {
                Task {
                    await deletePoster(poster)
                    deletingPoster = nil
                }
            }
                .accessibilityIdentifier("ui.mine-poster-list-view.delete")
        } message: { poster in
            Text("确定删除“\(poster.title.isEmpty ? "未命名帖子" : poster.title)”吗？删除后无法恢复。")
        }
        .diagnosticAlert(item: $alert)
    }

    private var isInitialLoading: Bool {
        if case .idle = status { return true }
        if case .loading = status {
            return visiblePosters.isEmpty
        }
        return false
    }

    /// 删除帖子后先本地移除，再请求上层刷新列表。
    private func deletePoster(_ poster: CommunityPoster) async {
        do {
            try await dependencies.deletePoster(poster.id)
            deletedPosterIDs.insert(poster.id)
            if selectedPoster?.id == poster.id {
                selectedPoster = nil
            }
            await onRefresh()
        } catch {
            alert = AppAlert(title: "删除失败", error: error)
        }
    }
}

/// 我的页资料卡上的统计按钮。
///
/// action 存在时渲染按钮，缺少 action 时渲染静态文案。
private struct MineStatButton: View {
    let number: String
    let title: String
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                        .frame(minWidth: AppDesignSystem.Size.Control.touchTarget, minHeight: AppDesignSystem.Size.Control.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(number)
                    .accessibilityIdentifier("ui.mine-stat-button.destination")
            } else {
                content
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private var content: some View {
        HStack(spacing: AppDesignSystem.Spacing.tiny) {
            Text(number)
                .font(AppDesignSystem.Typography.titleEmphasis)
                .foregroundStyle(AppDesignSystem.Foreground.primary)
            Text(title)
                .font(AppDesignSystem.Typography.subheadlineEmphasis)
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
        }
    }
}


#endif
