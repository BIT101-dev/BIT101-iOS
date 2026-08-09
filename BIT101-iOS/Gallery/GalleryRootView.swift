//
//  GalleryRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI
import UIKit
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
    @State private var selectedSurface: GallerySurface = .gallery

    init(requestedPaperID: Binding<Int?> = .constant(nil)) {
        _requestedPaperID = requestedPaperID
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
        .toolbar(.hidden, for: .navigationBar)
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
                    badgeText: messageBadgeText
                ) {
                    isShowingMessages = true
                }

                GalleryFloatingActionButton(systemImage: "square.and.pencil") {
                    isShowingComposer = true
                }

                GalleryFloatingActionButton(systemImage: "magnifyingglass") {
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
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
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

/// 记录当前列表里“最靠近顶部的帖子”的垂直偏移。
///
/// 下拉刷新后会用它来恢复用户原先的阅读位置，减少刷新导致的“跳走感”。
private struct GalleryVisiblePosterOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 统一的右下角悬浮操作按钮。
///
/// 主 feed、搜索、消息等入口都复用这一套胶囊按钮样式。
private struct GalleryFloatingActionButton: View {
    let systemImage: String
    let badgeText: String?
    let action: () -> Void

    init(systemImage: String, badgeText: String? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.badgeText = badgeText
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
struct GalleryFeedView: View {
    let feedState: GalleryFeedState
    let feedIdentity: String
    let prefetchTriggerThreshold: Int
    let onRefresh: () -> Void
    let onPrefetch: (GalleryPoster?) -> Void
    let onLoadMore: (GalleryPoster?) -> Void
    @ObservedObject private var settings = AppSettingsStore.shared
    private let reportService = CommunityReportService()
    @State private var selectedPoster: GalleryPoster?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var reportContext: GalleryReportContext?
    @State private var deletedPosterIDs: Set<Int> = []
    @State private var currentTopPosterID: Int?
    @State private var pendingRestorePosterID: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isInitialLoading {
                    galleryPlaceholderContainer {
                        ProgressView("正在加载话廊")
                    }
                } else if case let .failed(message) = feedState.status, feedState.posters.isEmpty {
                    galleryPlaceholderContainer {
                        ContentUnavailableView {
                            Label("加载失败", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("重试") {
                                onRefresh()
                            }
                        }
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                            VStack(spacing: 0) {
                                GalleryPosterCard(
                                    poster: poster,
                                    onOpenPoster: { selectedPoster = poster },
                                    onOpenImage: { index, images in
                                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                                    },
                                    onReport: { action in
                                        reportContext = GalleryReportContext(poster: poster, action: action)
                                    },
                                    onDelete: nil
                                )

                                if index != visiblePosters.count - 1 {
                                    Divider()
                                        .padding(.leading, 14)
                                }
                            }
                            .id(poster.id)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: GalleryVisiblePosterOffsetPreferenceKey.self,
                                        value: [poster.id: geometry.frame(in: .named(feedScrollSpaceName)).minY]
                                    )
                                }
                            )
                            .onAppear {
                                if prefetchTriggerPosterIDs.contains(poster.id) {
                                    onPrefetch(poster)
                                }
                                guard poster.id == visiblePosters.last?.id else { return }
                                onLoadMore(poster)
                            }
                        }

                        if feedState.isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .coordinateSpace(name: feedScrollSpaceName)
            .background(Color(.systemGroupedBackground))
            .id(feedIdentity)
            .refreshable {
                pendingRestorePosterID = currentTopPosterID ?? visiblePosters.first?.id
                onRefresh()
            }
            .onPreferenceChange(GalleryVisiblePosterOffsetPreferenceKey.self) { offsets in
                currentTopPosterID = topVisiblePosterID(from: offsets)
            }
            .onChange(of: visiblePosterIDs) { _, newIDs in
                restoreScrollPositionIfNeeded(with: proxy, availableIDs: newIDs)
            }
            .background(Color(.systemGroupedBackground))
            .navigationDestination(item: $selectedPoster) { poster in
                GalleryPosterDetailView(
                    poster: poster,
                    onReport: { _ in },
                    onDeleted: {
                        deletedPosterIDs.insert(poster.id)
                        onRefresh()
                    }
                )
            }
            .fullScreenCover(item: $imageViewer) { viewer in
                GalleryImageViewer(viewer: viewer)
            }
            .sheet(item: $reportContext) { context in
                CommunityReportSheet(context: context) { type, note in
                    applyReport(context, type: type, note: note)
                }
            }
        }
    }

    /// 加载中和失败空态也放进统一滚动容器里，保证始终可以下拉刷新。
    @ViewBuilder
    private func galleryPlaceholderContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 120)
            content()
            Spacer(minLength: 240)
        }
        .frame(maxWidth: .infinity)
    }

    /// 首屏空态下是否应该显示中央加载指示器。
    private var isInitialLoading: Bool {
        switch feedState.status {
        case .idle, .loading:
            return visiblePosters.isEmpty
        default:
            return false
        }
    }

    /// 当前真正可见的帖子列表。
    ///
    /// 删帖成功后会先做本地移除，再等待上层刷新；因此这里要叠加一层
    /// `deletedPosterIDs` 过滤，保证体感上帖子会立刻消失。
    private var visiblePosters: [GalleryPoster] {
        feedState.posters.filter { !deletedPosterIDs.contains($0.id) }
    }

    private var visiblePosterIDs: [Int] {
        visiblePosters.map(\.id)
    }

    /// 进入可见列表尾部若干条时触发的预取集合。
    ///
    /// 预取只负责后台准备下一页，不直接把数据拼到列表里，这样可以降低滚动条比例
    /// 和当前位置突然变化带来的“跳走”感。
    private var prefetchTriggerPosterIDs: Set<Int> {
        guard prefetchTriggerThreshold > 0 else { return [] }
        return Set(visiblePosters.suffix(prefetchTriggerThreshold).map(\.id))
    }

    /// 当前 feed 独立的滚动坐标空间名称。
    private var feedScrollSpaceName: String {
        "GalleryFeedScroll-\(feedIdentity)"
    }

    /// 根据偏移字典推断当前位于屏幕顶部附近的帖子。
    ///
    /// 算法选择“距离 0 最近的 minY”，这样不需要真正知道可见区域高度，
    /// 也能粗略定位用户当时正在阅读哪一条。
    private func topVisiblePosterID(from offsets: [Int: CGFloat]) -> Int? {
        guard !offsets.isEmpty else { return currentTopPosterID }

        return offsets.min { lhs, rhs in
            let lhsDistance = abs(lhs.value)
            let rhsDistance = abs(rhs.value)
            if lhsDistance == rhsDistance {
                return lhs.value < rhs.value
            }
            return lhsDistance < rhsDistance
        }?.key
    }

    /// 刷新完成后，把滚动位置尽量恢复到刷新前的顶部帖子。
    ///
    /// 如果原帖子还在，就精确恢复；如果已经不在当前列表里，则退回到当前列表第一条，
    /// 至少避免页面直接跳到完全不可预期的位置。
    private func restoreScrollPositionIfNeeded(with proxy: ScrollViewProxy, availableIDs: [Int]) {
        guard let pendingRestorePosterID else { return }

        if availableIDs.contains(pendingRestorePosterID) {
            DispatchQueue.main.async {
                scrollToTopPoster(pendingRestorePosterID, with: proxy)
                self.pendingRestorePosterID = nil
            }
        } else if let fallbackID = availableIDs.first {
            DispatchQueue.main.async {
                scrollToTopPoster(fallbackID, with: proxy)
                self.pendingRestorePosterID = nil
            }
        } else {
            self.pendingRestorePosterID = nil
        }
    }

    /// 无动画滚回指定帖子顶部。
    ///
    /// 这里禁用动画是有意的：刷新完成后的补位应该尽量“静默”，否则用户会明显感知到
    /// 页面被强行滚动。
    private func scrollToTopPoster(_ posterID: Int, with proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(posterID, anchor: .top)
        }
    }

    /// 应用“举报并隐藏 / 举报并屏蔽用户”的本地治理动作，再异步上报。
    private func applyReport(_ context: GalleryReportContext, type: CommunityReportType, note: String) {
        applyGalleryModerationAction(context, type: type, note: note, settings: settings, reportService: reportService)
    }
}

/// 单个帖子卡片。
///
/// 帖子点击进入详情，图片点击进入全屏看图，二者需要显式拆开避免手势冲突。
struct GalleryPosterCard: View {
    let poster: GalleryPoster
    let onOpenPoster: () -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onReport: ((CommunityReportAction) -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(poster.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                GalleryAvatarView(imageURL: URL(string: poster.user.avatar.lowUrl.isEmpty ? poster.user.avatar.url : poster.user.avatar.lowUrl))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(poster.user.nickname)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !poster.user.identity.text.isEmpty {
                            Text(poster.user.identity.text)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(identityColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(identityColor)
                        }
                    }

                    if !poster.user.motto.isEmpty {
                        Text(poster.user.motto)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if onReport != nil || onDelete != nil {
                    GalleryPosterActionMenu(
                        onSelectAction: onReport,
                        onDelete: onDelete
                    )
                    // 右上角菜单需要吞掉点击，避免父卡片的 onTapGesture 同时触发进详情。
                    .contentShape(Rectangle())
                    .onTapGesture { }
                }
            }

            Text(poster.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(poster.images.count <= 2 ? 4 : 3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !poster.images.isEmpty {
                GalleryPosterImagesView(images: poster.images, onOpenImage: onOpenImage)
            }

            HStack(spacing: 10) {
                Label("\(poster.likeNum)", systemImage: "hand.thumbsup")
                Label("\(poster.commentNum)", systemImage: "bubble.right")

                if !poster.public {
                    Label("仅自己可见", systemImage: "eye.slash")
                }

                Spacer()

                Text(relativeTimeText(poster.editTime))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !poster.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(poster.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenPoster)
    }

    private var identityColor: Color {
        Color(hex: poster.user.identity.color) ?? .orange
    }

    /// 把后端时间文本转成相对时间文案。
    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知")
    }
}

/// 帖子作者头像。
///
/// 头像统一走 `CachedRemoteImage`，避免频繁出现在信息流里的用户头像每次冷启动都重新下载。
struct GalleryAvatarView: View {
    let imageURL: URL?

    var body: some View {
        CachedRemoteImage(url: imageURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(Color.orange.opacity(0.15))
                Image(systemName: "person.fill")
                    .foregroundStyle(.orange)
                    .font(.caption.weight(.bold))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }
}

/// 帖子图片网格。
///
/// 这里故意按图片数量做三套布局，而不是一律九宫格：
/// - 1 张图时尽量给更大的阅读空间
/// - 2 张图时用并排双列
/// - 3 张及以上再退回网格
private struct GalleryPosterImagesView: View {
    let images: [GalleryImage]
    let onOpenImage: (Int, [GalleryImage]) -> Void

    var body: some View {
        let displayedImages = images.count <= 2 ? images : Array(images.prefix(images.count == 3 ? 3 : 4))

        if displayedImages.count == 1 {
            thumbnailButton(image: displayedImages[0], index: 0, width: 180, maxHeight: 220, aspectRatio: 1)
        } else if displayedImages.count == 2 {
            HStack(spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 150, aspectRatio: 1)
                }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(displayedImages.count, 4)), spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 78, aspectRatio: 1)
                }
            }
        }
    }

    private func thumbnailButton(image: GalleryImage, index: Int, width: CGFloat?, maxHeight: CGFloat?, aspectRatio: CGFloat) -> some View {
        Button {
            onOpenImage(index, images)
        } label: {
            GalleryPosterThumbnail(
                image: image,
                width: width,
                maxHeight: maxHeight,
                aspectRatio: aspectRatio
            )
        }
        .buttonStyle(.plain)
    }
}

/// 单张帖子图片缩略图。
private struct GalleryPosterThumbnail: View {
    let image: GalleryImage
    let width: CGFloat?
    let maxHeight: CGFloat?
    let aspectRatio: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: image.lowUrl.isEmpty ? image.url : image.lowUrl)) { phase in
            switch phase {
            case let .success(renderedImage):
                renderedImage
                    .resizable()
                    .scaledToFit()
            default:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.orange)
                    }
            }
        }
        .frame(maxWidth: width == nil ? .infinity : width)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 帖子详情页。
///
/// 详情页是一个相对完整的“二级页面壳层”：
/// - 顶部帖子正文和互动按钮
/// - 评论列表与排序
/// - 举报、删帖、看图、评论输入
/// - 点击作者或评论作者跳到用户主页
struct GalleryPosterDetailView: View {
    private struct UserRoute: Identifiable, Hashable {
        let userID: Int
        var id: Int { userID }
    }

    @ObservedObject private var settings = AppSettingsStore.shared
    private let reportService = CommunityReportService()
    @StateObject private var viewModel: GalleryPosterDetailViewModel
    @State private var imageViewer: GalleryImageViewerState?
    @State private var reportContext: GalleryReportContext?
    @State private var composerTarget: GalleryCommentComposerTarget?
    @State private var userRoute: UserRoute?
    @State private var isShowingDeleteConfirmation = false
    let onReport: ((CommunityReportAction) -> Void)?
    let onDeleted: (() -> Void)?

    init(
        poster: GalleryPoster,
        onReport: ((CommunityReportAction) -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: GalleryPosterDetailViewModel(initialPoster: poster))
        self.onReport = onReport
        self.onDeleted = onDeleted
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.poster.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Group {
                            if canOpenPosterUserProfile {
                                Button {
                                    userRoute = UserRoute(userID: viewModel.poster.user.id)
                                } label: {
                                    authorSummary
                                }
                                .buttonStyle(.plain)
                            } else {
                                authorSummary
                            }
                        }

                        Spacer()

                        HStack(spacing: 10) {
                            Button {
                                composerTarget = .poster(posterID: viewModel.poster.id)
                            } label: {
                                Image(systemName: "bubble.right")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color.orange.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task {
                                    await viewModel.likePoster()
                                }
                            } label: {
                                Group {
                                    if viewModel.isLikingPoster {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: viewModel.poster.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                                            .font(.headline)
                                    }
                                }
                                .foregroundStyle(viewModel.poster.like ? Color.orange : Color.primary)
                                .frame(width: 34, height: 34)
                                .background(Color.orange.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLikingPoster)
                        }
                    }
                }

                if viewModel.poster.claim.id != 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                        Text(viewModel.poster.claim.text)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                }

                Text(viewModel.poster.text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !viewModel.poster.images.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(Array(viewModel.poster.images.enumerated()), id: \.element.id) { index, image in
                            Button {
                                imageViewer = GalleryImageViewerState(images: viewModel.poster.images, initialIndex: index)
                            } label: {
                                GalleryPosterThumbnail(
                                    image: image,
                                    width: nil,
                                    maxHeight: 320,
                                    aspectRatio: 1.6
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !viewModel.poster.tags.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(viewModel.poster.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }

                HStack(spacing: 18) {
                    Text("\(viewModel.poster.likeNum)赞")
                    Text("\(viewModel.poster.commentNum)评论")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Divider()

                GalleryPosterCommentsSection(
                    comments: filteredComments,
                    totalCommentCount: viewModel.poster.commentNum,
                    status: viewModel.commentState.status,
                    isLoadingMore: viewModel.commentState.isLoadingMore,
                    selectedOrder: viewModel.commentOrder,
                    likingCommentIDs: viewModel.likingCommentIDs,
                    onSelectOrder: { order in
                        Task {
                            await viewModel.setCommentOrder(order)
                        }
                    },
                    onReply: { target in
                        composerTarget = .comment(mainComment: target.mainComment, targetComment: target.targetComment)
                    },
                    onLikeComment: { comment in
                        Task {
                            await viewModel.likeComment(comment)
                        }
                    },
                    onOpenImage: { index, images in
                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                    },
                    onOpenUser: { user in
                        guard user.id > 0 else { return }
                        userRoute = UserRoute(userID: user.id)
                    },
                    onLoadMore: { comment in
                        Task {
                            await viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                        }
                    }
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .refreshable {
            await viewModel.refreshAll()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("帖子详情")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $userRoute) { route in
            UserProfileRootView(userID: route.userID)
        }
        .toolbar {
            if onReport != nil || viewModel.poster.own {
                ToolbarItem(placement: .topBarTrailing) {
                    GalleryPosterActionMenu(
                        onSelectAction: onReport == nil ? nil : { action in
                            reportContext = GalleryReportContext(poster: viewModel.poster.asPoster, action: action)
                        },
                        onDelete: viewModel.poster.own ? {
                            isShowingDeleteConfirmation = true
                        } : nil
                    )
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .fullScreenCover(item: $imageViewer) { viewer in
            GalleryImageViewer(viewer: viewer)
        }
        .sheet(item: $reportContext) { context in
            CommunityReportSheet(context: context) { type, note in
                applyReport(context, type: type, note: note)
            }
        }
        .sheet(item: $composerTarget) { target in
            GalleryCommentComposerSheet(
                target: target,
                isSubmitting: viewModel.isSubmittingComment
            ) { text, anonymous in
                Task {
                    let success = await viewModel.submitComment(text: text, anonymous: anonymous, target: target)
                    if success {
                        composerTarget = nil
                    }
                }
            }
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .alert(
            "删除帖子",
            isPresented: $isShowingDeleteConfirmation,
            presenting: viewModel.poster
        ) { _ in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    if await viewModel.deletePoster() {
                        onDeleted?()
                        dismiss()
                    }
                }
            }
        } message: { poster in
            Text("确定删除“\(poster.title.isEmpty ? "未命名帖子" : poster.title)”吗？删除后无法恢复。")
        }
    }

    /// 详情页顶部作者信息区域。
    private var authorSummary: some View {
        HStack(spacing: 12) {
            GalleryAvatarView(imageURL: URL(string: viewModel.poster.user.avatar.lowUrl.isEmpty ? viewModel.poster.user.avatar.url : viewModel.poster.user.avatar.lowUrl))

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.poster.user.nickname)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(relativeTimeText(viewModel.poster.editTime))
                    if !viewModel.poster.public {
                        Label("仅自己可见", systemImage: "eye.slash")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 当前帖子作者是否允许跳转到用户主页。
    private var canOpenPosterUserProfile: Bool {
        !viewModel.poster.anonymous && viewModel.poster.user.id > 0
    }

    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知时间")
    }

    private var filteredComments: [GalleryComment] {
        CommunityModeration.filterVisibleComments(viewModel.commentState.items, snapshot: settings.snapshot)
    }

    /// 在详情页里应用举报动作。
    private func applyReport(_ context: GalleryReportContext, type: CommunityReportType, note: String) {
        applyGalleryModerationAction(context, type: type, note: note, settings: settings, reportService: reportService)
    }
}

/// 评论区主体。
///
/// 这里只负责“评论列表如何展示”，不直接持有评论请求逻辑；请求和排序状态由上层
/// `GalleryPosterDetailViewModel` 驱动，再通过闭包把操作回传上去。
private struct GalleryPosterCommentsSection: View {
    let comments: [GalleryComment]
    let totalCommentCount: Int
    let status: GalleryFeedStatus
    let isLoadingMore: Bool
    let selectedOrder: GalleryCommentOrder
    let likingCommentIDs: Set<Int>
    let onSelectOrder: (GalleryCommentOrder) -> Void
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void
    let onLoadMore: (GalleryComment?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("评论")
                    .font(.headline)

                Text("\(totalCommentCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("排序", selection: Binding(get: { selectedOrder }, set: onSelectOrder)) {
                    ForEach(GalleryCommentOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                ProgressView("正在加载评论")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            case let .failed(message) where comments.isEmpty:
                ContentUnavailableView {
                    Label("加载评论失败", systemImage: "bubble.right.fill")
                } description: {
                    Text(message)
                }
            default:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: 0) {
                                GalleryCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment,
                                    onOpenImage: onOpenImage,
                                    onOpenUser: onOpenUser
                                )

                                if index != comments.count - 1 {
                                    Divider()
                                        .padding(.leading, 46)
                                }
                            }
                            .onAppear {
                                onLoadMore(comment)
                            }
                        }

                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                }
            }
        }
    }
}

/// 评论回复目标。
///
/// `mainComment` 表示发评论接口真正要挂靠的主评论，
/// `targetComment` 表示当前 UI 上用户实际点中的那条评论。
private struct GalleryCommentReplyTarget {
    let mainComment: GalleryComment
    let targetComment: GalleryComment
}

/// 单条评论及其子评论预览。
///
/// 主评论和子评论共用同一套气泡视图，只是在这一层决定是否渲染嵌套结构。
private struct GalleryCommentRow: View {
    let comment: GalleryComment
    let likingCommentIDs: Set<Int>
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GalleryCommentBubble(
                comment: comment,
                isSubComment: false,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(GalleryCommentReplyTarget(mainComment: comment, targetComment: comment))
                },
                onLike: {
                    onLikeComment(comment)
                },
                onOpenImage: onOpenImage,
                onOpenUser: {
                    onOpenUser(comment.user)
                }
            )

            if !comment.sub.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(comment.sub.enumerated()), id: \.element.id) { index, subComment in
                        VStack(spacing: 0) {
                            GalleryCommentBubble(
                                comment: subComment,
                                isSubComment: true,
                                isLiking: likingCommentIDs.contains(subComment.id),
                                onReply: {
                                    onReply(GalleryCommentReplyTarget(mainComment: comment, targetComment: subComment))
                                },
                                onLike: {
                                    onLikeComment(subComment)
                                },
                                onOpenImage: onOpenImage,
                                onOpenUser: {
                                    onOpenUser(subComment.user)
                                }
                            )

                            if index != comment.sub.count - 1 {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
                .padding(.leading, 42)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// 评论内容气泡。
///
/// 一个评论气泡内部同时包含：
/// - 头像/昵称
/// - 时间
/// - 正文
/// - 图片
/// - 点赞按钮
/// - 点击整块回复
private struct GalleryCommentBubble: View {
    let comment: GalleryComment
    let isSubComment: Bool
    let isLiking: Bool
    let onReply: () -> Void
    let onLike: () -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if canOpenUserProfile {
                    Button(action: onOpenUser) {
                        GalleryAvatarView(imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl))
                            .frame(width: isSubComment ? 28 : 34, height: isSubComment ? 28 : 34)
                    }
                    .buttonStyle(.plain)
                } else {
                    GalleryAvatarView(imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl))
                        .frame(width: isSubComment ? 28 : 34, height: isSubComment ? 28 : 34)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if canOpenUserProfile {
                            Button(action: onOpenUser) {
                                Text(comment.user.nickname)
                                    .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(comment.user.nickname)
                                .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Text(relativeTimeText(comment.createTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                commentText

                if !comment.images.isEmpty {
                    GalleryPosterImagesView(images: comment.images, onOpenImage: onOpenImage)
                }

                HStack(spacing: 10) {
                    Button(action: onReply) {
                        Label("回复", systemImage: "arrowshape.turn.up.left")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button(action: onLike) {
                        Label {
                            Text("\(comment.likeNum)")
                                .font(.caption)
                        } icon: {
                            if isLiking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: comment.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }
                        }
                        .foregroundStyle(comment.like ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    private var canOpenUserProfile: Bool {
        !comment.anonymous && comment.user.id > 0
    }

    @ViewBuilder
    /// 处理“回复某人”的前缀文本拼接。
    private var commentText: some View {
        if comment.replyUser.id != 0, !comment.replyUser.nickname.isEmpty {
            (
                Text("回复 @\(comment.replyUser.nickname)：")
                    .foregroundStyle(.secondary) +
                    Text(comment.text)
                    .foregroundStyle(.primary)
            )
            .font(.subheadline)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(comment.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知时间")
    }
}

/// 评论发送弹层。
///
/// 评论输入单独做成 sheet，而不是直接贴在详情页底部，是为了避免和 tab bar、抽屉详情、
/// 键盘安全区互相打架。
private struct GalleryCommentComposerSheet: View {
    let target: GalleryCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField(target.placeholder, text: $text, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)

                    Toggle("匿名评论", isOn: $anonymous)
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "发送中" : "发送") {
                        onSubmit(text, anonymous)
                    }
                    .disabled(isSubmitting)
                }
            }
        }
    }
}

/// 搜索页。
///
/// 搜索结果页直接复用 `GalleryFeedView`，只是在顶部额外挂一个搜索栏，
/// 这样搜索结果的分页、详情、举报和看图逻辑都不需要重复实现。
