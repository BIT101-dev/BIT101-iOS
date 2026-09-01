//
//  MineRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI

/// “我的”页内部导航。
///
/// 这里仅收敛“我的主页内部会继续 push 的三个子列表”，设置页单独走另一条路由，
/// 避免把两类导航状态混在一起。
private enum MineRoute: Hashable, Identifiable {
    case followers
    case followings
    case posters

    /// 供导航绑定使用的稳定标识。
    var id: Self { self }
}

/// “我的”页根视图。
///
/// 顶部结构尽量向 Android 对齐，但交互仍然走 iOS 的导航和列表风格。
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

    /// “我的”主页主体。
    ///
    /// 主页面本身只展示资料卡和设置入口；更长的列表内容都拆到子页面里，避免主页滚动层级过深。
    var body: some View {
        List {
            Section {
                profileSection
            }

            Section {
                settingsSection
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refreshProfile()
            await viewModel.refreshPosters()
        }
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
            ProgressView("正在加载个人信息")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        case let .failed(message):
            ContentUnavailableView {
                Label("加载失败", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                DiagnosticRecoveryActions(title: "个人信息加载失败", message: message)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
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
    /// 这些入口最终都会跳进同一个 `SettingsRootView`，这里只负责展示“入口列表”这一层。
    private var settingsSection: some View {
        ForEach(SettingsRoute.allCases) { route in
            Button {
                settingsRoute = route
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: route.systemImage)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(route.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 他人主页。
///
/// 复用“我的”页已有资料卡和话题卡片样式，避免再做一套单独的用户页皮肤。
struct UserProfileRootView: View {
    let userID: Int

    /// 指定用户主页状态机。
    @StateObject private var viewModel: UserProfileViewModel
    @ObservedObject private var settings = AppSettingsStore.shared
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
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refreshAll()
        }
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
            ProgressView("正在加载主页")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        case let .failed(message):
            ContentUnavailableView {
                Label("加载失败", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                DiagnosticRecoveryActions(title: "主页加载失败", message: message)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
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
        // 他人主页也沿用社区本地治理过滤，避免被你屏蔽的用户/帖子在这里重新出现。
        let visiblePosters = CommunityModeration
            .filterVisiblePosters(viewModel.posterState.items, snapshot: settings.snapshot)

        switch viewModel.posterState.status {
        case .idle where visiblePosters.isEmpty:
            ProgressView("正在加载帖子")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        case .loading where visiblePosters.isEmpty:
            ProgressView("正在加载帖子")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        case let .failed(message) where visiblePosters.isEmpty:
            ContentUnavailableView {
                Label("加载帖子失败", systemImage: "text.bubble")
            } description: {
                Text(message)
            } actions: {
                DiagnosticRecoveryActions(title: "帖子加载失败", message: message)
            }
        default:
            if visiblePosters.isEmpty {
                ContentUnavailableView("暂无帖子", systemImage: "text.bubble")
            } else {
                ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                    VStack(spacing: 0) {
                        GalleryPosterCard(
                            poster: poster,
                            onOpenPoster: { selectedPoster = poster },
                            onOpenImage: { index, images in
                                imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                            },
                            onReport: nil,
                            onDelete: nil
                        )
                        .task {
                            await viewModel.loadMorePostersIfNeeded(currentPoster: poster)
                        }

                        if index != visiblePosters.count - 1 {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                if viewModel.posterState.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    private var navigationTitle: String {
        viewModel.userInfo?.user.nickname.isEmpty == false ? viewModel.userInfo!.user.nickname : "主页"
    }
}

/// 个人信息卡片。
///
/// “我的主页”和“他人主页”都共用这张卡片，因此这里只负责纯展示，
/// 不直接耦合导航和页面级状态。
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

            Spacer().frame(height: 8)

            HStack(spacing: 8) {
                Text(info.user.nickname)
                    .font(.title3.weight(.bold))

                if !info.user.identity.text.isEmpty {
                    Text(info.user.identity.text)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(identityColor)
                }
            }

            Spacer().frame(height: 6)

            Text(info.user.motto.isEmpty ? "空简介" : info.user.motto)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(height: 10)

            HStack(spacing: 18) {
                MineStatButton(number: "\(info.followerNum)", title: "粉丝", action: onOpenFollowers)
                MineStatButton(number: "\(info.followingNum)", title: "关注", action: onOpenFollowings)
                MineStatButton(number: posterCountText, title: "帖子", action: onOpenPosters)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private var profileAvatar: some View {
        CachedRemoteImage(url: URL(string: info.user.avatar.url)) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Circle()
                .fill(Color.blue.opacity(0.14))
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.blue)
                        .font(.title2)
                }
        }
        .frame(width: 78, height: 78)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    private var identityColor: Color {
        MineColorDecoder.color(from: info.user.identity.color) ?? .secondary
    }
}

/// 粉丝 / 关注 列表页。
///
/// 这个页面只关心一类用户数组的展示与分页，因此通过闭包把刷新和加载更多回传给上层 ViewModel。
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
                ProgressView("正在加载")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .failed(message) = status, users.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "person.2.slash")
                } description: {
                    Text(message)
                } actions: {
                    DiagnosticRecoveryActions(title: "用户列表加载失败", message: message)
                }
            } else {
                List {
                    ForEach(users) { user in
                        HStack(spacing: 12) {
                            CachedRemoteImage(url: URL(string: user.avatar.lowUrl.isEmpty ? user.avatar.url : user.avatar.lowUrl)) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(Color.blue.opacity(0.14))
                                    .overlay {
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.blue)
                                    }
                            }
                            .frame(width: 46, height: 46)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(user.nickname)
                                        .font(.headline)

                                    if !user.identity.text.isEmpty {
                                        Text(user.identity.text)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(MineColorDecoder.color(from: user.identity.color) ?? .blue)
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
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
                .refreshable {
                    onRefresh()
                }
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
/// 直接复用话题卡片与详情实现，避免“我的帖子”和“话题详情”之间出现两套视觉和交互逻辑。
private struct MinePosterListView: View {
    @ObservedObject private var settings = AppSettingsStore.shared
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
    /// 这里同时叠加“社区屏蔽规则”和“本地刚删掉但服务端还没刷新回来”的过滤，
    /// 供列表主体与 loading 判断共同复用，避免两处各自维护一套相同过滤。
    private var visiblePosters: [GalleryPoster] {
        CommunityModeration
            .filterVisiblePosters(posters, snapshot: settings.snapshot)
            .filter { !deletedPosterIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if isInitialLoading {
                ProgressView("正在加载帖子")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .failed(message) = status, visiblePosters.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "text.bubble")
                } description: {
                    Text(message)
                } actions: {
                    DiagnosticRecoveryActions(title: "帖子加载失败", message: message)
                }
            } else if visiblePosters.isEmpty {
                ContentUnavailableView("暂无可显示的帖子", systemImage: "text.bubble")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                            GalleryPosterCard(
                                poster: poster,
                                onOpenPoster: { selectedPoster = poster },
                                onOpenImage: { index, images in
                                    imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                                },
                                onReport: nil,
                                onDelete: { deletingPoster = poster }
                            )
                            .task {
                                onLoadMore(poster)
                            }

                            if index != visiblePosters.count - 1 {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }

                        if isLoadingMore {
                            ProgressView()
                                .padding(.vertical, 20)
                        }
                    }
                }
                .refreshable {
                    onRefresh()
                }
            }
        }
        .task {
            if case .idle = status {
                onRefresh()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("我的帖子")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPoster) { poster in
            NavigationStack {
                GalleryPosterDetailView(
                    poster: poster,
                    onReport: nil,
                    onDeleted: {
                        deletedPosterIDs.insert(poster.id)
                        Task {
                            onRefresh()
                        }
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
/// 同一套组件同时兼容“可点”和“纯展示”两种状态：有 action 时就是按钮，没有 action 时就是静态文案。
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
        HStack(spacing: 4) {
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
/// 用户身份颜色来自服务端十六进制字符串，因此在“我的”模块里单独保留一个轻量解码器。
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
