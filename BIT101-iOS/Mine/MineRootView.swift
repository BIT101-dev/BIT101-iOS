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
struct MineRootView: View {
    /// 兜底学号，用于传给设置页的账号区域。
    let fallbackStudentID: String
    let onLogout: () -> Void

    /// “我的”主页状态机。
    @StateObject private var viewModel = MineViewModel()
    /// 粉丝 / 关注 / 帖子子列表路由。
    @State private var route: MineRoute?
    /// 设置页内部路由。
    @State private var settingsRoute: SettingsRoute?
    /// 建议入口通过独立 sheet 呈现，设置入口使用设置导航路由。
    @State private var isShowingSuggestion = false

    /// “我的”主页主体。
    ///
    /// 主页面展示资料卡和设置入口，列表内容进入子页面，保持主页层级清晰。
    var body: some View {
        List {
            Section {
                profileSection
            }

            Section {
                settingsSection
            }
        }
        .appGroupedListStyle()
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $route) { destination in
            switch destination {
            case .followers:
                MineUserListView(
                    title: "我的粉丝",
                    users: viewModel.followerState.items,
                    status: viewModel.followerState.status,
                    isLoadingMore: viewModel.followerState.isLoadingMore,
                    onRefresh: {
                        Task { await viewModel.refreshFollowers() }
                    },
                    onLoadMore: { user in
                        Task { await viewModel.loadMoreFollowersIfNeeded(currentUser: user) }
                    }
                )
            case .followings:
                MineUserListView(
                    title: "我的关注",
                    users: viewModel.followingState.items,
                    status: viewModel.followingState.status,
                    isLoadingMore: viewModel.followingState.isLoadingMore,
                    onRefresh: {
                        Task { await viewModel.refreshFollowings() }
                    },
                    onLoadMore: { user in
                        Task { await viewModel.loadMoreFollowingsIfNeeded(currentUser: user) }
                    }
                )
            case .posters:
                MinePosterListView(
                    posters: viewModel.posterState.items,
                    status: viewModel.posterState.status,
                    isLoadingMore: viewModel.posterState.isLoadingMore,
                    onRefresh: {
                        Task { await viewModel.refreshPosters() }
                    },
                    onLoadMore: { poster in
                        Task { await viewModel.loadMorePostersIfNeeded(currentPoster: poster) }
                    }
                )
            }
        }
        .navigationDestination(item: $settingsRoute) { destination in
            SettingsRootView(initialRoute: destination, studentID: fallbackStudentID, onLogout: onLogout)
        }
        .sheet(isPresented: $isShowingSuggestion) {
            NavigationStack {
                DeveloperSuggestionPage()
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
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
                    Task { await viewModel.refreshProfile() }
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
    /// 入口最终都进入同一个 `SettingsRootView`，这里负责展示入口列表和选择路由。
    private var settingsSection: some View {
        ForEach(SettingsRoute.allCases) { route in
            Button {
                if route == .suggestion {
                    isShowingSuggestion = true
                } else {
                    settingsRoute = route
                }
            } label: {
                AppNavigationRowLabel(
                    title: route.title,
                    systemImage: route.systemImage,
                    showsDisclosureIndicator: true
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 他人主页。
///
/// 复用“我的”页的资料卡和话题卡片样式，统一用户主页的视觉表现。
struct UserProfileRootView: View {
    let userID: Int

    /// 指定用户主页状态机。
    @StateObject private var viewModel: UserProfileViewModel
    @State private var selectedPoster: GalleryPoster?
    @State private var imageViewer: GalleryImageViewerState?

    init(userID: Int) {
        self.userID = userID
        _viewModel = StateObject(wrappedValue: UserProfileViewModel(userID: userID))
    }

    var body: some View {
        List {
            Section {
                profileSection
            }

            Section {
                posterSection
            }
        }
        .appGroupedListStyle()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .sheet(item: $selectedPoster) { poster in
            NavigationStack {
                GalleryPosterDetailView(poster: poster)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .gallerySystemImagePreview(item: $imageViewer)
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
                    Task { await viewModel.refreshProfile() }
                }
            )
            .frame(maxWidth: .infinity)
        case .loaded:
            if let info = viewModel.userInfo {
                MineProfileCard(
                    info: info,
                    posterCountText: viewModel.posterCountText,
                    onOpenAvatar: {
                        imageViewer = GalleryImageViewerState(images: [info.user.avatar], initialIndex: 0)
                    }
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
                    Task { await viewModel.refreshPosters() }
                }
            )
        } else {
            if visiblePosters.isEmpty {
                AppEmptyState(title: "暂无帖子", systemImage: "text.bubble")
            } else {
                ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                    AppFeedRow(isLast: index == visiblePosters.count - 1) {
                        GalleryPosterCard(
                            poster: poster,
                            onOpenPoster: { selectedPoster = poster },
                            onOpenImage: { index, images in
                                imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                            },
                            onDelete: nil,
                            onReport: nil
                        )
                        .task {
                            await viewModel.loadMorePostersIfNeeded(currentPoster: poster)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
        guard let nickname = viewModel.userInfo?.user.nickname, !nickname.isEmpty else { return "主页" }
        return nickname
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

    init(
        info: MineUserInfo,
        posterCountText: String,
        onOpenFollowers: (() -> Void)? = nil,
        onOpenFollowings: (() -> Void)? = nil,
        onOpenPosters: (() -> Void)? = nil,
        onOpenAvatar: (() -> Void)? = nil
    ) {
        self.info = info
        self.posterCountText = posterCountText
        self.onOpenFollowers = onOpenFollowers
        self.onOpenFollowings = onOpenFollowings
        self.onOpenPosters = onOpenPosters
        self.onOpenAvatar = onOpenAvatar
    }

    /// 资料卡主体。
    var body: some View {
        VStack(spacing: 0) {
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
                    .font(.title3.weight(.bold))

                if !info.user.identity.text.isEmpty {
                    Text(info.user.identity.text)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(identityColor)
                }
            }

            Spacer().frame(height: AppDesignSystem.Spacing.tight)

            Text(info.user.motto.isEmpty ? "空简介" : info.user.motto)
                .font(AppDesignSystem.Typography.body)

            Spacer().frame(height: AppDesignSystem.Spacing.control)

            HStack(spacing: AppDesignSystem.Spacing.prominent) {
                MineStatButton(number: "\(info.followerNum)", title: "粉丝", action: onOpenFollowers)
                MineStatButton(number: "\(info.followingNum)", title: "关注", action: onOpenFollowings)
                MineStatButton(number: posterCountText, title: "帖子", action: onOpenPosters)
            }
        }
        .padding(.top, AppDesignSystem.Spacing.control)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var profileAvatar: some View {
        AppAvatarView(
            imageURL: URL(string: info.user.avatar.url),
            size: AppDesignSystem.Size.avatar.profile,
            tint: AppDesignSystem.Palette.info
        )
        .contentShape(Circle())
    }

    private var identityColor: Color {
        MineColorDecoder.color(from: info.user.identity.color) ?? .secondary
    }
}

/// 粉丝 / 关注 列表页。
///
/// 页面展示一类用户数组，刷新和分页操作由上层 ViewModel 传入。
private struct MineUserListView: View {
    let title: String
    let users: [GalleryUser]
    let status: MineLoadStatus
    let isLoadingMore: Bool
    let onRefresh: () -> Void
    let onLoadMore: (GalleryUser?) -> Void

    var body: some View {
        Group {
            if isInitialLoading {
                AppLoadingState(title: "正在加载")
            } else if case let .failed(message) = status, users.isEmpty {
                AppFailureState(
                    title: "用户列表加载失败",
                    systemImage: "person.2.slash",
                    message: message,
                    onRetry: onRefresh
                )
            } else {
                List {
                    ForEach(users) { user in
                        HStack(spacing: AppDesignSystem.Spacing.content) {
                            AppAvatarView(
                                imageURL: URL(string: user.avatar.lowUrl.isEmpty ? user.avatar.url : user.avatar.lowUrl),
                                size: AppDesignSystem.Size.avatar.list,
                                tint: AppDesignSystem.Palette.info
                            )

                            VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
                                HStack(spacing: AppDesignSystem.Spacing.tight) {
                                    Text(user.nickname)
                                        .font(.headline)

                                    if !user.identity.text.isEmpty {
                                        Text(user.identity.text)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(MineColorDecoder.color(from: user.identity.color) ?? AppDesignSystem.Palette.info)
                                    }
                                }

                                Text("UID：\(user.id)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .task {
                            onLoadMore(user)
                        }
                    }

                    if isLoadingMore {
                        AppInlineLoadingState()
                    }
                }
                .appGroupedListStyle()
            }
        }
        .task {
            if case .idle = status {
                onRefresh()
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
    let posters: [GalleryPoster]
    let status: MineLoadStatus
    let isLoadingMore: Bool
    let onRefresh: () -> Void
    let onLoadMore: (GalleryPoster?) -> Void
    @State private var selectedPoster: GalleryPoster?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var deletingPoster: GalleryPoster?
    @State private var alert: AppAlert?
    @State private var deletedPosterIDs: Set<Int> = []
    private let service = GalleryService()

    /// 当前真正可展示的帖子列表。
    ///
    /// 过滤服务端刷新前已删除的帖子，保持删除后的列表状态。
    private var visiblePosters: [GalleryPoster] {
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
                    onRetry: onRefresh
                )
            } else if visiblePosters.isEmpty {
                AppEmptyState(title: "暂无可显示的帖子", systemImage: "text.bubble")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                            AppFeedRow(isLast: index == visiblePosters.count - 1) {
                                GalleryPosterCard(
                                    poster: poster,
                                    onOpenPoster: { selectedPoster = poster },
                                    onOpenImage: { index, images in
                                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                                    },
                                    onDelete: { deletingPoster = poster },
                                    onReport: nil
                                )
                                .task {
                                    onLoadMore(poster)
                                }
                            }
                        }

                        if isLoadingMore {
                            AppInlineLoadingState()
                        }
                    }
                }
            }
        }
        .task {
            if case .idle = status {
                onRefresh()
            }
        }
        .background(AppDesignSystem.Palette.groupedBackground)
        .navigationTitle("我的帖子")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPoster) { poster in
            NavigationStack {
                GalleryPosterDetailView(
                    poster: poster,
                    onDeleted: {
                        deletedPosterIDs.insert(poster.id)
                        onRefresh()
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .gallerySystemImagePreview(item: $imageViewer)
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
            Button("删除", role: .destructive) {
                Task {
                    await deletePoster(poster)
                    deletingPoster = nil
                }
            }
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
    private func deletePoster(_ poster: GalleryPoster) async {
        do {
            try await service.deletePoster(id: poster.id)
            deletedPosterIDs.insert(poster.id)
            if selectedPoster?.id == poster.id {
                selectedPoster = nil
            }
            onRefresh()
        } catch {
            alert = AppAlert(title: "删除失败", message: error.localizedDescription)
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
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: AppDesignSystem.Spacing.tiny) {
            Text(number)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }
}

/// 我的页使用的颜色解码工具。
///
/// 处理服务端提供的十六进制用户身份颜色。
private enum MineColorDecoder {
    static func color(from hex: String) -> Color? {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
            return nil
        }

        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
