#if os(iOS)
import MediaKit
import CommunityUI
import TransportCore
import CommunityCore
import DesignSystemKit
//
//  GalleryRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI
import Combine
import WebKit
import OSLog

/// “话廊”底部页内部的一级内容分区。
///
/// 底部栏保留“话廊”入口，顶部栏负责在“话题 / 文章”之间切换。
public nonisolated enum GallerySurface: String, CaseIterable, Identifiable, Hashable, Sendable {
    case gallery
    case paper

    public var id: String { rawValue }

    public var title: String {
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
public struct GalleryRootView: View {
    private let scene: GalleryRootViewScene
    private let identity: [ObjectIdentifier]

    public init(dependencies: GalleryDependencies,
        media: MediaEnvironment,
        profiles: CommunityProfileDestination,
        papers: CommunityPaperDestination,
        courses: CommunityCourseDestination,
        requestedPaperID: Binding<Int?> = .constant(nil),
        requestedPosterID: Binding<Int?> = .constant(nil), selection: Binding<GallerySurface>? = nil) {
        scene = GalleryRootViewScene(dependencies: dependencies, media: media, profiles: profiles, papers: papers, courses: courses, requestedPaperID: requestedPaperID, requestedPosterID: requestedPosterID, selection: selection)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
    }

    public var body: some View {
        scene.id(identity)
    }
}

private struct GalleryRootViewScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let dependencies: GalleryDependencies
    private let destinations: CommunityPaperDestination
    private let courses: CommunityCourseDestination
    private let profiles: CommunityProfileDestination
    private let media: MediaEnvironment
    @Environment(\.scenePhase) private var scenePhase
    /// 主 feed 视图模型，负责帖子流、搜索和详情入口状态。
    @StateObject private var viewModel: GalleryViewModel
    /// 消息中心视图模型，与主 feed 独立，避免互相污染加载状态。
    @StateObject private var messageViewModel: GalleryMessageViewModel
    /// 监听网络从断开恢复为可用，帮助失败态自动重试。
    private var networkObserver: NetworkPathState { dependencies.networkPath }
    @ObservedObject private var appSettings: CommunityPreferences
    @State private var selectedFeedPoster: CommunityPoster?
    @State private var deletedFeedPosterIDs: Set<Int> = []
    @State private var isShowingComposer = false
    @State private var isShowingMessages = false
    @State private var isShowingSubscriptions = false
    @State private var selectedCourseID: Int?
    @State private var unreadRefreshGeneration = 0
    @State private var horizontalControlFrames: [CGRect] = []
    @Binding private var requestedPaperID: Int?
    @Binding private var requestedPosterID: Int?
    @Environment(\.appExpandedNavigation) private var expandedNavigation
    @State private var localSurface: GallerySurface = .gallery
    private let selection: Binding<GallerySurface>?
    private var selectedSurface: GallerySurface {
        get { selection?.wrappedValue ?? localSurface }
        nonmutating set {
            if let selection { selection.wrappedValue = newValue }
            else { localSurface = newValue }
        }
    }
    private var surfaceSelection: Binding<GallerySurface> {
        Binding(get: { selectedSurface }, set: { selectedSurface = $0 })
    }
    @State private var isShowingNativePaperRoute = false
    @State private var deepLinkedPoster: GalleryPosterDetail?
    @State private var deepLinkAlert: AppAlert?
    private let posterService: any GalleryPosterDetailServicing

    init(
        dependencies: GalleryDependencies,
        media: MediaEnvironment,
        profiles: CommunityProfileDestination,
        papers: CommunityPaperDestination,
        courses: CommunityCourseDestination,
        requestedPaperID: Binding<Int?> = .constant(nil),
        requestedPosterID: Binding<Int?> = .constant(nil),
        selection: Binding<GallerySurface>? = nil
    ) {
        _requestedPaperID = requestedPaperID
        _requestedPosterID = requestedPosterID
        self.dependencies = dependencies
        self.selection = selection
        self.media = media
        self.profiles = profiles
        self.destinations = papers
        self.courses = courses
        self.posterService = dependencies.posterDetail
        _viewModel = StateObject(wrappedValue: GalleryViewModel(service: dependencies.feed))
        _messageViewModel = StateObject(wrappedValue: GalleryMessageViewModel(service: dependencies.messageService, readStore: dependencies.messages))
        _appSettings = ObservedObject(wrappedValue: dependencies.preferences)
    }

    var body: some View {
        content.environment(dependencies).environment(media).environment(profiles)
    }

    private var content: some View {
        VStack(spacing: AppDesignSystem.Spacing.none) {
            if !expandedNavigation && !appSettings.galleryUseWebView {
                AppTopSegmentedPicker(title: "话廊内容", selection: surfaceSelection) {
                    ForEach(GallerySurface.allCases) { surface in
                        Text(surface.title).tag(surface)
                    }
                }
            }
            if appSettings.galleryUseWebView && !isShowingNativePaperRoute {
                GalleryWebContentView()
            } else {
                TabView(selection: surfaceSelection) {
                    galleryContent
                        .tag(GallerySurface.gallery)
                        .tabItem { Text(GallerySurface.gallery.title) }
                        .toolbar(.hidden, for: .tabBar)
                    destinations.papers(
                        $requestedPaperID,
                        { selectedSurface = .gallery }
                    )
                    .tag(GallerySurface.paper)
                    .tabItem { Text(GallerySurface.paper.title) }
                    .toolbar(.hidden, for: .tabBar)
                }
                .accessibilityIdentifier("gallery.surfaces")
            }
        }
        .task(id: requestedPaperID) {
            guard requestedPaperID != nil else { return }
            isShowingNativePaperRoute = true
            selectedSurface = .paper
        }
        .onChange(of: selectedSurface) { _, newSurface in
            isShowingNativePaperRoute = newSurface == .paper
        }
        .task(id: requestedPosterID) {
            await openRequestedPosterIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            viewModel.releaseInactiveFeeds()
        }
        .onChange(of: appSettings.snapshot) { previous, settings in
            if previous.galleryUseWebView != settings.galleryUseWebView {
                isShowingNativePaperRoute = false
                selectedSurface = .gallery
            }
            guard previous.galleryHideBotPosterInSearch != settings.galleryHideBotPosterInSearch
                || previous.galleryHiddenUserIDs != settings.galleryHiddenUserIDs
                || previous.galleryHideAnonymousContent != settings.galleryHideAnonymousContent else { return }
            if settings.galleryHideBotPosterInSearch && viewModel.selectedFeed == .bot { viewModel.selectedFeed = .recommend }
            viewModel.contentPreferencesDidChange()
        }
        .navigationDestination(item: $deepLinkedPoster) { poster in
            GalleryPosterDetailView(dependencies: dependencies, media: media, profiles: profiles, poster: poster.asPoster, initialDetail: poster)
        }
        .diagnosticAlert(item: $deepLinkAlert)
        .toolbar(.hidden, for: .navigationBar)
    }

    private struct GalleryWebContentView: View {
        var body: some View {
            GalleryWebView(url: AppURL.required("https://bit101.cn/gallery"))
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private struct GalleryWebView: UIViewRepresentable {
        @Environment(GalleryDependencies.self) private var dependencies
        @Environment(\.openURL) private var openURL
        let url: URL

        func makeCoordinator() -> GalleryWebCoordinator {
            GalleryWebCoordinator(credentials: dependencies.webCredentials, openExternal: { url in openURL(url) })
        }

        func makeUIView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = context.coordinator
            webView.allowsBackForwardNavigationGestures = true
            context.coordinator.start(in: webView, url: url)
            return webView
        }

        func updateUIView(_ webView: WKWebView, context: Context) {
            context.coordinator.synchronizeCredentials(in: webView)
        }


    }

    private func openRequestedPosterIfNeeded() async {
        guard let posterID = requestedPosterID else { return }
        selectedSurface = .gallery
        deepLinkAlert = nil
        do {
            let poster = try await posterService.fetchPoster(id: posterID)
            guard !Task.isCancelled, requestedPosterID == posterID else { return }
            deepLinkedPoster = poster
        } catch {
            guard !TaskCancellation.matches(error), requestedPosterID == posterID else { return }
            deepLinkAlert = AppAlert(title: "无法打开话题", error: error)
        }
        // 完成当前请求后消费链接，保持详情加载任务的生命周期。
        if requestedPosterID == posterID {
            requestedPosterID = nil
        }
    }

    private var galleryContent: some View {
        AppBrowserLayout(selection: $selectedFeedPoster, title: "选择一个话题", symbol: "bubble.left.and.bubble.right") {
            galleryListContent
        } detail: { poster in
            GalleryPosterDetailView(dependencies: dependencies, media: media, profiles: profiles, poster: poster,
                onUpdated: { viewModel.enqueueRefresh(for: viewModel.selectedFeed) },
                onDeleted: {
                    deletedFeedPosterIDs.insert(poster.id)
                    selectedFeedPoster = nil
                    viewModel.enqueueRefresh(for: viewModel.selectedFeed)
                })
        }
    }

    private var galleryListContent: some View {
        ZStack(alignment: .bottomTrailing) {
            AppDesignSystem.Palette.Background.grouped
                .ignoresSafeArea(edges: .bottom)

            GalleryFeedView(
                feedState: viewModel.state(for: viewModel.selectedFeed),
                feedIdentity: viewModel.selectedFeed.rawValue,
                prefetchTriggerThreshold: viewModel.selectedFeed == .recommend ? 10 : 0,
                onRefresh: {
                    media.retryFailedImages()
                    viewModel.enqueueRefresh(for: viewModel.selectedFeed)
                },
                onPullToRefresh: {
                    media.retryFailedImages()
                    await viewModel.enqueueRefresh(for: viewModel.selectedFeed).value
                },
                onPrefetch: { poster in
                    guard let poster else { return }
                    viewModel.enqueuePrefetch(for: viewModel.selectedFeed, currentPoster: poster)
                },
                onLoadMore: { poster in
                    viewModel.enqueueLoadMore(for: viewModel.selectedFeed, currentPoster: poster)
                },
                onSelectPoster: { selectedFeedPoster = $0 }, excludedPosterIDs: deletedFeedPosterIDs
            )
            .simultaneousGesture(feedSwitchGesture)
            .onPreferenceChange(AppHorizontalControlFramesKey.self) { horizontalControlFrames = $0 }
            .accessibilityIdentifier("gallery.feed-surface")

            AppFloatingActionStack {
                AppFloatingActionButton(systemImage: "bookmark", accessibilityLabel: "我的收藏") {
                    isShowingSubscriptions = true
                }
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
                ForEach(visibleFeeds) { feed in
                    Text(feed.title).tag(feed)
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .task(id: unreadRefreshGeneration) {
            await messageViewModel.refreshUnreadCounts()
        }
        .onChange(of: viewModel.selectedFeed) { _, newFeed in
            if viewModel.state(for: newFeed).status == .idle {
                viewModel.enqueueRefresh(for: newFeed)
            }
        }
        .onChange(of: networkObserver.snapshot.status) { _, newValue in
            guard newValue == .connected else { return }
            unreadRefreshGeneration &+= 1
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            guard networkObserver.isReachable else { return }
            unreadRefreshGeneration &+= 1
        }
        .communityReadRecovery(networkPath: networkObserver,
            isEnabled: selectedSurface == .gallery && !viewModel.isShowingSearch && !isShowingComposer
                && !isShowingMessages && !isShowingSubscriptions && deepLinkedPoster == nil && selectedCourseID == nil) {
            let state = viewModel.state(for: viewModel.selectedFeed)
            if case .failed = state.status { await viewModel.refresh(feed: viewModel.selectedFeed) }
            else if state.paginationError != nil {
                await viewModel.loadMoreIfNeeded(for: viewModel.selectedFeed, currentPoster: state.posters.last)
            }
        }
        .sheet(isPresented: $viewModel.isShowingSearch) {
            NavigationStack {
                GallerySearchView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $isShowingMessages) {
            NavigationStack {
                GalleryMessagesView(papers: destinations, courses: courses, viewModel: messageViewModel)
            }
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isShowingSubscriptions) {
            NavigationStack {
                GallerySubscriptionsView(service: dependencies.subscriptions) { kind, id in
                    if kind == "paper" {
                        isShowingSubscriptions = false
                        isShowingNativePaperRoute = true
                        selectedSurface = .paper
                        requestedPaperID = id
                    } else if kind == "course" {
                        isShowingSubscriptions = false
                        selectedCourseID = id
                    }
                }
            }
        }
        .navigationDestination(item: $selectedCourseID) { id in courses.course(id) }
        .sheet(isPresented: $isShowingComposer) {
            GalleryComposerView {
                viewModel.enqueueNewestRefreshAfterComposer()
            }
        }
        .diagnosticAlert(item: $viewModel.alert)
        .onDisappear { viewModel.cancelPendingOperations() }
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
        makeHorizontalSwitchGesture(excluding: horizontalControlFrames, onStep: switchFeed)
    }

    private var visibleFeeds: [GalleryFeedKind] {
        GalleryFeedKind.allCases.filter { !appSettings.snapshot.galleryHideBotPosterInSearch || $0 != .bot }
    }

    /// 把当前 feed 切换到相邻分区。
    private func switchFeed(step: Int) {
        let allFeeds = visibleFeeds
        guard let currentIndex = allFeeds.firstIndex(of: viewModel.selectedFeed) else { return }
        let lastIndex = allFeeds.index(before: allFeeds.endIndex)

        if (currentIndex == 0 && step == -1) || (currentIndex == lastIndex && step == 1) {
            withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
                selectedSurface = .paper
            }
            return
        }

        let nextIndex = currentIndex + step
        guard allFeeds.indices.contains(nextIndex) else { return }

        withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
            viewModel.selectedFeed = allFeeds[nextIndex]
        }
    }

}

final class GalleryWebCoordinator: NSObject, WKNavigationDelegate {
    private static let logger = Logger(subsystem: "BIT101-iOS", category: "GalleryWeb")
    let credentials: GalleryWebCredentials
    let openExternal: (URL) -> Void
    init(credentials: GalleryWebCredentials, openExternal: @escaping (URL) -> Void) {
        self.credentials = credentials
        self.openExternal = openExternal
    }
    private var credentialsSubscription: AnyCancellable?
    private var isShowingFailure = false
    private var credentialGeneration = 0
    private var bootstrapCookie: String?
    private var credentialsUpdateInFlight = false
    private var failedCredentialCookie: String?
    private var hasLoadedDocument = false
    private var retryURL = AppURL.required("https://bit101.cn/gallery")
    private weak var recoveryAlert: UIAlertController?

    func start(in webView: WKWebView, url: URL) {
        retryURL = url
        do { try configureBootstrap(in: webView, cookie: credentials.cookie()) }
        catch { showLoadFailure(in: webView, error: error); return }
        credentialsSubscription = credentials.changes.sink { [weak self, weak webView] _ in
            guard let webView else { return }
            self?.synchronizeCredentials(in: webView)
        }
        webView.load(GalleryWebRequestFactory.request(for: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if isShowingFailure, navigationAction.request.url?.absoluteString == "about:blank" { return .allow }
        if navigationAction.targetFrame?.isMainFrame != false,
           let url = navigationAction.request.url, GalleryWebRequestFactory.isTrustedPage(url) { retryURL = url }
        if navigationAction.navigationType == .linkActivated,
           GalleryWebRequestFactory.isTrustedPage(navigationAction.request.url) { isShowingFailure = false }
        guard navigationAction.targetFrame?.isMainFrame != false,
              !GalleryWebRequestFactory.isTrustedPage(navigationAction.request.url) else {
            return .allow
        }
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            openExternal(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if isShowingFailure, navigationResponse.response.url?.absoluteString == "about:blank" { return .allow }
        return navigationResponse.isForMainFrame
            && !GalleryWebRequestFactory.isTrustedPage(navigationResponse.response.url) ? .cancel : .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        if !isShowingFailure, GalleryWebRequestFactory.isTrustedPage(webView.url) { hasLoadedDocument = true }
        synchronizeCredentials(in: webView)
    }

    private func configureBootstrap(in webView: WKWebView, cookie: String) throws {
        guard bootstrapCookie != cookie else { return }
        let script = try Self.credentialScript(cookie)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        bootstrapCookie = cookie
    }

    private static func credentialScript(_ cookie: String) throws -> String {
        let encoded = String(decoding: try JSONEncoder().encode(cookie), as: UTF8.self)
        return """
        (() => {
            if (location.origin !== 'https://bit101.cn') return false;
            let store = {};
            try {
                const parsed = JSON.parse(localStorage.getItem('store') || '{}');
                if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) store = parsed;
            } catch (_) {}
            if (store.fake_cookie === \(encoded)) return false;
            store.fake_cookie = \(encoded);
            localStorage.setItem('store', JSON.stringify(store));
            return true;
        })();
        """
    }

    func synchronizeCredentials(in webView: WKWebView) {
        guard !isShowingFailure else { return }
        let fakeCookie = credentials.cookie()
        guard failedCredentialCookie != fakeCookie else { return }
        let script: String
        do {
            try configureBootstrap(in: webView, cookie: fakeCookie)
            script = try Self.credentialScript(fakeCookie)
        } catch { showLoadFailure(in: webView, error: error); return }
        guard !credentialsUpdateInFlight, !webView.isLoading, GalleryWebRequestFactory.isTrustedPage(webView.url) else { return }
        credentialsUpdateInFlight = true
        credentialGeneration &+= 1
        let generation = credentialGeneration
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
            guard let self, let webView else { return }
            self.credentialsUpdateInFlight = false
            guard self.credentialGeneration == generation, !self.isShowingFailure,
                  GalleryWebRequestFactory.isTrustedPage(webView.url) else { return }
            if self.credentials.cookie() != fakeCookie { self.synchronizeCredentials(in: webView); return }
            if let error { self.failedCredentialCookie = fakeCookie; self.showLoadFailure(in: webView, error: error) }
            else if result as? Bool == true { webView.reload() }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        showLoadFailure(in: webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        showLoadFailure(in: webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hasLoadedDocument = false
        showLoadFailure(in: webView, error: URLError(.networkConnectionLost))
    }

    func retryLastFailure(in webView: WKWebView) {
        isShowingFailure = false
        failedCredentialCookie = nil
        webView.load(GalleryWebRequestFactory.request(for: retryURL))
    }

    private func showLoadFailure(in webView: WKWebView, error: Error) {
        let failure = error as NSError
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
        Self.logger.error("Web view failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        if let url = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
           GalleryWebRequestFactory.isTrustedPage(url) { retryURL = url }
        if hasLoadedDocument {
            guard recoveryAlert == nil else { return }
            var responder: UIResponder? = webView
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let presenter = responder as? UIViewController, presenter.presentedViewController == nil else { return }
            let alert = UIAlertController(title: "话廊网页加载失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "继续阅读", style: .cancel))
            alert.addAction(UIAlertAction(title: "重新加载", style: .default) { [weak self, weak webView] _ in
                guard let webView else { return }
                self?.retryLastFailure(in: webView)
            })
            recoveryAlert = alert
            presenter.present(alert, animated: true)
            return
        }
        isShowingFailure = true
        let padding = Int(AppDesignSystem.Spacing.section)
        let target = retryURL.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        webView.loadHTMLString(
            "<body style=\"font: \(AppDesignSystem.Typography.webBodyCSS); padding: \(padding)px;\">话廊网页加载失败。<p><a href=\"\(target)\">重新加载</a></p></body>",
            baseURL: nil
        )
    }
}

#endif
