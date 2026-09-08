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
/// 底部栏保留“话廊”入口，顶部栏负责在“话题 / 文章”之间切换。
private enum GallerySurface: String, CaseIterable, Identifiable, Hashable {
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
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppTopSegmentedPicker(title: "话廊内容", selection: $selectedSurface) {
                ForEach(GallerySurface.allCases) { surface in
                    Text(surface.title).tag(surface)
                }
            }
        }
        .task(id: requestedPaperID) {
            guard requestedPaperID != nil else { return }
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
            AppDesignSystem.Palette.groupedBackground
                .ignoresSafeArea(edges: .bottom)

            GalleryFeedView(
                feedState: viewModel.state(for: viewModel.selectedFeed),
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

            AppFloatingActionStack {
                AppFloatingActionButton(
                    systemImage: "bell.badge",
                    badgeText: messageBadgeText,
                    accessibilityLabel: "消息"
                ) {
                    isShowingMessages = true
                }

                AppFloatingActionButton(systemImage: "square.and.pencil", accessibilityLabel: "发布话题") {
                    isShowingComposer = true
                }

                AppFloatingActionButton(systemImage: "magnifyingglass", accessibilityLabel: "搜索话廊") {
                    viewModel.isShowingSearch = true
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppTopSegmentedPicker(
                title: "话廊分区",
                selection: $viewModel.selectedFeed,
                variant: .stacked
            ) {
                ForEach(GalleryFeedKind.allCases) { feed in
                    Text(feed.title).tag(feed)
                }
            }
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

    /// 右下角消息按钮上的红点文案。
    ///
    /// 入口处将数量限制为 `99+`，防止长数字撑开按钮布局。
    private var messageBadgeText: String? {
        let count = messageViewModel.totalUnreadCount
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// feed 左右轻扫切换手势。
    ///
    /// 当前布局使用底部全覆盖内容、顶部 segmented 和横向拖拽手势完成分区切换。
    private var feedSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchFeed)
    }

    /// 把当前 feed 切换到相邻分区。
    private func switchFeed(step: Int) {
        let allFeeds = GalleryFeedKind.allCases
        guard let currentIndex = allFeeds.firstIndex(of: viewModel.selectedFeed) else { return }
        let lastIndex = allFeeds.index(before: allFeeds.endIndex)

        if (currentIndex == 0 && step == -1) || (currentIndex == lastIndex && step == 1) {
            withAnimation(.easeInOut) {
                selectedSurface = .paper
            }
            return
        }

        let nextIndex = currentIndex + step
        guard allFeeds.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut) {
            viewModel.selectedFeed = allFeeds[nextIndex]
        }
    }

    /// 网络恢复或应用回前台时，失败且列表为空的当前 feed 自动重试。
    ///
    /// 正常列表保留当前阅读内容，自动重试覆盖失败且列表为空的状态。
    private func retryCurrentFeedIfNeeded() async {
        guard networkObserver.isReachable else { return }

        let currentState = viewModel.state(for: viewModel.selectedFeed)
        guard case .failed = currentState.status, currentState.posters.isEmpty else { return }

        await viewModel.refresh(feed: viewModel.selectedFeed)
    }
}

/// 轻量网络可达性观察器。
///
/// 观察器维护话廊页的可达性状态，并发出“网络从不可用恢复为可用”的边界事件。
/// 话廊失败态收到事件后，自动重拉当前 feed。
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
