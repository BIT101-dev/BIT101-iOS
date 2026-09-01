//
//  GalleryRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI
import Network
import Combine

/// “话廊”底部页内部的一级内容分区。
///
/// 文章模块并入后，底部栏继续只保留“话廊”一个入口，
/// 再通过这里的顶部栏在“话题 / 文章”之间切换。
private enum GallerySurface: String, CaseIterable, Identifiable {
    case gallery
    case paper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gallery:
            return "话题"
        case .paper:
            return "文章"
        }
    }
}

// MARK: - Gallery Root

/// 话廊页根视图。
///
/// 顶部负责 feed 切换，下方负责承载当前选中的帖子流，并支持左右轻扫切换分区。
struct GalleryRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// 主 feed 视图模型，负责帖子流、搜索和详情入口状态。
    @StateObject private var viewModel = GalleryViewModel()
    /// 消息中心视图模型，与主 feed 独立，避免互相污染加载状态。
    @StateObject private var messageViewModel = GalleryMessageViewModel()
    /// 监听网络从断开恢复为可用，帮助失败态自动重试。
    @StateObject private var networkObserver = GalleryNetworkObserver()
    /// 全局话廊设置快照。
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var isShowingComposer = false
    @State private var isShowingMessages = false
    @Binding private var requestedPaperID: Int?
    @Binding private var requestedPosterID: Int?
    @State private var selectedSurface: GallerySurface = .gallery
    @State private var deepLinkedPoster: GalleryPoster?
    @State private var deepLinkAlert: AppAlert?

    init(
        requestedPaperID: Binding<Int?> = .constant(nil),
        requestedPosterID: Binding<Int?> = .constant(nil)
    ) {
        _requestedPaperID = requestedPaperID
        _requestedPosterID = requestedPosterID
    }

    var body: some View {
        Group {
            switch selectedSurface {
            case .gallery:
                galleryContent
            case .paper:
                PaperRootView(
                    requestedPaperID: $requestedPaperID,
                    selectedGallerySurfaceRawValue: Binding(
                        get: { selectedSurface.rawValue },
                        set: { newValue in
                            selectedSurface = GallerySurface(rawValue: newValue) ?? .gallery
                        }
                    )
                )
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("话廊内容", selection: $selectedSurface) {
                ForEach(GallerySurface.allCases) { surface in
                    Text(surface.title).tag(surface)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(.systemGroupedBackground))
        }
        .task(id: requestedPaperID) {
            guard requestedPaperID != nil else { return }
            selectedSurface = .paper
        }
        .onChange(of: requestedPaperID) { _, newValue in
            guard newValue != nil else { return }
            selectedSurface = .paper
        }
        .task(id: requestedPosterID) {
            await openRequestedPosterIfNeeded()
        }
        .navigationDestination(item: $deepLinkedPoster) { poster in
            GalleryPosterDetailView(poster: poster)
        }
        .diagnosticAlert(item: $deepLinkAlert)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func openRequestedPosterIfNeeded() async {
        guard let posterID = requestedPosterID else { return }
        selectedSurface = .gallery
        do {
            deepLinkedPoster = try await GalleryService().fetchPoster(id: posterID).asPoster
        } catch {
            deepLinkAlert = AppAlert(title: "无法打开话题", message: error.localizedDescription)
        }
        // `.task(id:)` 会在 id 改变时取消当前任务；必须等请求完成后再消费链接，
        // 否则这里一开始清空 binding 会立即取消刚发出的详情请求。
        if requestedPosterID == posterID {
            requestedPosterID = nil
        }
    }

    private var galleryContent: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)

            GalleryFeedView(
                feedState: filteredState(for: viewModel.selectedFeed),
                feedIdentity: viewModel.selectedFeed.rawValue,
                prefetchTriggerThreshold: viewModel.selectedFeed == .recommend ? 10 : 0,
                onRefresh: {
                    Task {
                        await viewModel.refresh(feed: viewModel.selectedFeed)
                    }
                },
                onPrefetch: { poster in
                    Task {
                        await viewModel.prefetchIfNeeded(for: viewModel.selectedFeed, currentPoster: poster)
                    }
                },
                onLoadMore: { poster in
                    Task {
                        await viewModel.loadMoreIfNeeded(for: viewModel.selectedFeed, currentPoster: poster)
                    }
                }
            )
            .simultaneousGesture(feedSwitchGesture)

            VStack(spacing: 10) {
                GalleryFloatingActionButton(
                    systemImage: "bell.badge",
                    badgeText: messageBadgeText,
                    accessibilityLabel: "消息"
                ) {
                    isShowingMessages = true
                }

                GalleryFloatingActionButton(systemImage: "square.and.pencil", accessibilityLabel: "发布话题") {
                    isShowingComposer = true
                }

                GalleryFloatingActionButton(systemImage: "magnifyingglass", accessibilityLabel: "搜索话廊") {
                    viewModel.isShowingSearch = true
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top) {
            Picker("话廊分区", selection: $viewModel.selectedFeed) {
                ForEach(GalleryFeedKind.allCases) { feed in
                    Text(feed.title).tag(feed)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(.systemGroupedBackground))
        }
        .task {
            async let feedTask: Void = viewModel.bootstrapIfNeeded()
            async let messageTask: Void = messageViewModel.refreshUnreadCounts()
            _ = await (feedTask, messageTask)
        }
        .onChange(of: viewModel.selectedFeed) { _, newFeed in
            if viewModel.state(for: newFeed).status == .idle {
                Task {
                    await viewModel.refresh(feed: newFeed)
                }
            }
        }
        .onChange(of: networkObserver.isReachable) { oldValue, newValue in
            guard newValue, !oldValue else { return }
            Task {
                await retryCurrentFeedIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await retryCurrentFeedIfNeeded()
            }
        }
        .sheet(isPresented: $viewModel.isShowingSearch) {
            NavigationStack {
                GallerySearchView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $isShowingMessages) {
            NavigationStack {
                GalleryMessagesView(viewModel: messageViewModel)
            }
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isShowingComposer) {
            GalleryComposerView {
                Task {
                    await MainActor.run {
                        viewModel.selectedFeed = .newest
                    }
                    await viewModel.refresh(feed: .newest)
                }
            }
        }
        .diagnosticAlert(item: $viewModel.alert)
    }

    private func filteredState(for feed: GalleryFeedKind) -> GalleryFeedState {
        var state = viewModel.state(for: feed)
        state.posters = filterPosters(state.posters)
        return state
    }

    /// 右下角消息按钮上的红点文案。
    ///
    /// 这里统一在入口处裁到 `99+`，避免按钮本身因为长数字撑坏布局。
    private var messageBadgeText: String? {
        let count = messageViewModel.totalUnreadCount
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// feed 左右轻扫切换手势。
    ///
    /// 这里没有使用系统 pager，而是保留当前“底部全覆盖 + 顶部 segmented”的布局，
    /// 通过横向拖拽手势做轻量切换。
    private var feedSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchFeed)
    }

    /// 把当前 feed 切换到相邻分区。
    private func switchFeed(step: Int) {
        let allFeeds = GalleryFeedKind.allCases
        guard let currentIndex = allFeeds.firstIndex(of: viewModel.selectedFeed) else { return }
        let lastIndex = allFeeds.index(before: allFeeds.endIndex)

        if (currentIndex == 0 && step == -1) || (currentIndex == lastIndex && step == 1) {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSurface = .paper
            }
            return
        }

        let nextIndex = currentIndex + step
        guard allFeeds.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.selectedFeed = allFeeds[nextIndex]
        }
    }

    /// 过滤逻辑与 Android 一致：支持隐藏匿名用户，以及按 UID 黑名单过滤。
    private func filterPosters(_ posters: [GalleryPoster]) -> [GalleryPoster] {
        CommunityModeration.filterVisiblePosters(posters, snapshot: settings.snapshot)
    }

    /// 网络恢复或应用回前台时，如果当前 feed 仍停在失败空态，则自动再试一次。
    ///
    /// 这里故意只处理“失败且列表为空”的情况，避免用户已经在正常列表里阅读时被后台自动刷新打断。
    private func retryCurrentFeedIfNeeded() async {
        guard networkObserver.isReachable else { return }

        let currentState = viewModel.state(for: viewModel.selectedFeed)
        guard case .failed = currentState.status, currentState.posters.isEmpty else { return }

        await viewModel.refresh(feed: viewModel.selectedFeed)
    }
}

/// 轻量网络可达性观察器。
///
/// 这里不做全局联网状态管理，只负责把“网络从不可用恢复为可用”的边界事件抛给话廊页。
/// 话廊失败态收到这个事件后，会尝试自动重拉当前 feed。
@MainActor
final class GalleryNetworkObserver: ObservableObject {
    @Published private(set) var isReachable = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "BIT101.GalleryNetworkObserver")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isReachable = isReachable
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/// 统一的右下角悬浮操作按钮。
///
/// 主 feed、搜索、消息等入口都复用这一套胶囊按钮样式。
private struct GalleryFloatingActionButton: View {
    let systemImage: String
    let badgeText: String?
    let accessibilityLabel: String
    let action: () -> Void

    init(
        systemImage: String,
        badgeText: String? = nil,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.badgeText = badgeText
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())

                if let badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, badgeText.count > 2 ? 5 : 4)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.red, in: Capsule())
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(badgeText.map { "\($0) 条未读" } ?? "")
    }
}

/// 单个 feed 的列表页。
///
/// 这个视图同时承担了：
/// 1. 列表展示
/// 2. 下拉刷新
/// 3. 预取和分页触发
/// 4. 刷新后滚动位置恢复
/// 5. 帖子详情、举报、看图等二级交互入口
///
/// 因此它是 `GalleryRootView` 中最关键的子视图。
