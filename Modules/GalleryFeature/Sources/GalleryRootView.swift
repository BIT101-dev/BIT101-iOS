#if os(iOS)
import MediaKit
import CommunityUI
import TransportCore
import CommunityCore
import DesignSystemKit
import SwiftUI
import Combine
import WebKit
import OSLog

/// “话廊”的一级内容分区。
///
/// 窄窗口通过模块切换栏选择“话题 / 文章”，宽幅窗口沿原生主导航进入。
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

public struct GallerySurfacePicker: View {
    @Binding private var selection: GallerySurface
    public init(selection: Binding<GallerySurface>) { _selection = selection }
    public var body: some View {
        AppTopSegmentedPicker(title: "话廊内容", selection: $selection) {
            ForEach(GallerySurface.allCases) { surface in Text(surface.title).tag(surface) }
        }
    }
}

// MARK: - Gallery Root

/// 话廊页根视图。
///
/// 顶部负责 feed 切换，下方负责承载当前选中的帖子流，并支持左右轻扫切换分区。
public struct GalleryRootView: View {
    private let dependencies: GalleryDependencies
    private let media: MediaEnvironment
    private let profiles: CommunityProfileDestination
    private let papers: CommunityPaperDestination
    private let courses: CommunityCourseDestination
    private let requestedPaperID: Binding<Int?>
    private let requestedPosterID: Binding<Int?>
    private let selection: Binding<GallerySurface>?
    private let includesPaperSurface: Bool
    private let identity: [ObjectIdentifier]

    public init(
        dependencies: GalleryDependencies,
        media: MediaEnvironment,
        profiles: CommunityProfileDestination,
        papers: CommunityPaperDestination,
        courses: CommunityCourseDestination,
        requestedPaperID: Binding<Int?> = .constant(nil),
        requestedPosterID: Binding<Int?> = .constant(nil),
        selection: Binding<GallerySurface>? = nil,
        includesPaperSurface: Bool = true
    ) {
        self.dependencies = dependencies
        self.media = media
        self.profiles = profiles
        self.papers = papers
        self.courses = courses
        self.requestedPaperID = requestedPaperID
        self.requestedPosterID = requestedPosterID
        self.selection = selection
        self.includesPaperSurface = includesPaperSurface
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
    }

    public var body: some View {
        GalleryRootViewScene(
            dependencies: dependencies, media: media, profiles: profiles, papers: papers,
            courses: courses, requestedPaperID: requestedPaperID,
            requestedPosterID: requestedPosterID, selection: selection,
            includesPaperSurface: includesPaperSurface
        ).id(identity)
    }
}

private struct GalleryRootViewScene: View {
    let includesPaperSurface: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let dependencies: GalleryDependencies
    private let destinations: CommunityPaperDestination
    private let courses: CommunityCourseDestination
    private let profiles: CommunityProfileDestination
    private let media: MediaEnvironment
    @Environment(\.scenePhase) private var scenePhase
    /// 主 feed 视图模型，负责帖子流、搜索和详情入口状态。
    @State private var ownedViewModel: AppViewModelOwner<GalleryViewModel>
    private var viewModel: GalleryViewModel { ownedViewModel.model }
    /// 消息中心独立维护视图模型和加载状态。
    @State private var ownedMessageViewModel: AppViewModelOwner<GalleryMessageViewModel>
    private var messageViewModel: GalleryMessageViewModel { ownedMessageViewModel.model }
    /// 监听网络从断开恢复为可用，帮助失败态自动重试。
    private var networkObserver: NetworkPathState { dependencies.networkPath }
    private var appSettings: CommunityPreferences
    private enum BrowserSelection: Hashable {
        case poster(CommunityPoster)
        case posterID(Int)
        case course(Int)
    }
    @State private var selectedContent: BrowserSelection?
    @State private var feedScrollPositions: [GalleryFeedKind: Int] = [:]
    @State private var feedImageViewer: ImagePreviewRequest?
    @State private var deletedFeedPosterIDs: Set<Int> = []
    @State private var isShowingComposer = false
    @State private var isShowingMessages = false
    @State private var isShowingSubscriptions = false
    @State private var unreadRefreshGeneration = 0
    @Binding private var requestedPaperID: Int?
    @Binding private var requestedPosterID: Int?
    @Environment(\.appExpandedNavigation) private var expandedNavigation
    @State private var localSurface: GallerySurface = .gallery
    private let selection: Binding<GallerySurface>?
    private var selectedSurface: GallerySurface {
        get { selection?.wrappedValue ?? localSurface }
        nonmutating set {
            if let selection {
                selection.wrappedValue = newValue
            } else {
                localSurface = newValue
            }
        }
    }
    private var surfaceSelection: Binding<GallerySurface> {
        Binding(get: { selectedSurface }, set: { selectedSurface = $0 })
    }

    init(
        dependencies: GalleryDependencies,
        media: MediaEnvironment,
        profiles: CommunityProfileDestination,
        papers: CommunityPaperDestination,
        courses: CommunityCourseDestination,
        requestedPaperID: Binding<Int?> = .constant(nil),
        requestedPosterID: Binding<Int?> = .constant(nil),
        selection: Binding<GallerySurface>? = nil,
        includesPaperSurface: Bool = true
    ) {
        _requestedPaperID = requestedPaperID
        _requestedPosterID = requestedPosterID
        self.dependencies = dependencies
        self.includesPaperSurface = includesPaperSurface
        self.selection = selection
        self.media = media
        self.profiles = profiles
        self.destinations = papers
        self.courses = courses
        _ownedViewModel = State(
            initialValue: AppViewModelOwner(GalleryViewModel(service: dependencies.feed)))
        _ownedMessageViewModel = State(
            initialValue: AppViewModelOwner(GalleryMessageViewModel(
                service: dependencies.messageService, readStore: dependencies.messages)))
        self.appSettings = dependencies.preferences
    }

    var body: some View {
        content
            .environment(dependencies).environment(media).environment(profiles)
            .appBrowserHeader(
                isPresented: !expandedNavigation && !appSettings.galleryUseWebView
            ) {
                GallerySurfacePicker(selection: surfaceSelection)
            }
    }

    private var content: some View {
        Group {
            if includesPaperSurface {
                AppPairedPages(showsFirst: selectedSurface == .gallery, pairsInLandscape: false) {
                    topicSurface
                } second: {
                    paperSurface
                }
                .accessibilityIdentifier("gallery.surfaces")
            } else {
                topicSurface
            }
        }
        .task(id: requestedPaperID) {
            guard requestedPaperID != nil else { return }
            selectedSurface = .paper
        }
        .task(id: requestedPosterID) {
            openRequestedPoster()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification)
        ) { _ in
            viewModel.releaseInactiveFeeds()
        }
        .onChange(of: appSettings.snapshot) { previous, settings in
            if previous.galleryUseWebView != settings.galleryUseWebView {
                selectedContent = nil
                selectedSurface = .gallery
            }
            guard
                previous.galleryHideBotPosterInSearch != settings.galleryHideBotPosterInSearch
                    || previous.galleryHiddenUserIDs != settings.galleryHiddenUserIDs
                    || previous.galleryHideAnonymousContent
                        != settings.galleryHideAnonymousContent
            else { return }
            if settings.galleryHideBotPosterInSearch && viewModel.selectedFeed == .bot {
                viewModel.selectedFeed = .recommend
            }
            viewModel.contentPreferencesChanged()
        }
    }

    @ViewBuilder
    private var paperSurface: some View {
        if appSettings.galleryUseWebView {
            GalleryWebContentView(
                dependencies: dependencies, surface: .paper,
                requestedPaperID: $requestedPaperID)
        } else {
            destinations.papers($requestedPaperID, { selectedSurface = .gallery })
        }
    }

    @ViewBuilder
    private var topicSurface: some View {
        if appSettings.galleryUseWebView && selectedContent == nil {
            GalleryWebContentView(dependencies: dependencies, surface: .gallery)
        } else {
            galleryContent
        }
    }

    private func openRequestedPoster() {
        guard let posterID = requestedPosterID else { return }
        selectedSurface = .gallery
        selectedContent = .posterID(posterID)
        requestedPosterID = nil
    }

    private var galleryContent: some View {
        AppBrowserLayout(
            selection: $selectedContent, title: "选择一个话题", symbol: "bubble.left.and.bubble.right"
        ) {
            galleryListContent
        } detail: { selection in
            switch selection {
            case .poster(let poster):
                GalleryPosterDetailView(
                    dependencies: dependencies, media: media, profiles: profiles,
                    poster: poster,
                    onUpdated: { viewModel.enqueueRefresh(for: viewModel.selectedFeed) },
                    onDeleted: {
                        deletedFeedPosterIDs.insert(poster.id)
                        selectedContent = nil
                        viewModel.enqueueRefresh(for: viewModel.selectedFeed)
                    })
            case .posterID(let id):
                GalleryPosterDestination(
                    id: id, dependencies: dependencies, media: media, profiles: profiles,
                    onUpdated: { viewModel.enqueueRefresh(for: viewModel.selectedFeed) },
                    onDeleted: {
                        selectedContent = nil
                        deletedFeedPosterIDs.insert(id)
                    }
                )
                .id(id)
            case .course(let id): courses.course(id)
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
        .communityReadRecovery(
            networkPath: networkObserver,
            isEnabled: selectedSurface == .gallery && !viewModel.isShowingSearch
                && !isShowingComposer
                && !isShowingMessages && !isShowingSubscriptions && selectedContent == nil
        ) {
            let state = viewModel.state(for: viewModel.selectedFeed)
            if state.needsRefresh {
                await viewModel.refresh(feed: viewModel.selectedFeed)
            } else if state.paginationError != nil {
                await viewModel.loadMoreIfNeeded(
                    for: viewModel.selectedFeed, currentPoster: state.posters.last)
            }
        }
        .sheet(isPresented: Bindable(viewModel).isShowingSearch) {
            NavigationStack {
                GallerySearchView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $isShowingMessages) {
            NavigationStack {
                GalleryMessagesView(
                    papers: destinations, courses: courses, viewModel: messageViewModel)
            }
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isShowingSubscriptions) {
            NavigationStack {
                GallerySubscriptionsView(service: dependencies.subscriptions) { kind, id in
                    if kind == "paper" {
                        isShowingSubscriptions = false
                        selectedSurface = .paper
                        requestedPaperID = id
                    } else if kind == "course" {
                        isShowingSubscriptions = false
                        selectedContent = .course(id)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingComposer) {
            GalleryComposerView {
                viewModel.enqueueComposerRefresh()
            }
        }
        .diagnosticAlert(item: Bindable(viewModel).alert)
        .onDisappear { viewModel.cancelPendingOperations() }
    }

    private var selectedPosterID: Int? {
        switch selectedContent {
        case .poster(let poster): poster.id
        case .posterID(let id): id
        default: nil
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
                    viewModel.enqueuePrefetch(
                        for: viewModel.selectedFeed, currentPoster: poster)
                },
                onLoadMore: { poster in
                    viewModel.enqueueLoadMore(
                        for: viewModel.selectedFeed, currentPoster: poster)
                },
                onSelectPoster: { selectedContent = .poster($0) },
                excludedPosterIDs: deletedFeedPosterIDs,
                selectedPosterID: selectedPosterID,
                scrollPosition: Binding(
                    get: { feedScrollPositions[viewModel.selectedFeed] },
                    set: {
                        if let value = $0 {
                            feedScrollPositions[viewModel.selectedFeed] = value
                        }
                    }),
                onPreview: { feedImageViewer = $0 }
            )
            .appPageSwitch(onStep: switchFeed)
            .appAccessibilitySurface()
            .accessibilityIdentifier("gallery.feed-surface")

        }
        .systemImagePreview(item: $feedImageViewer)
        .appBrowserActions {
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

            AppFloatingActionButton(
                systemImage: "square.and.pencil", accessibilityLabel: "发布话题"
            ) {
                isShowingComposer = true
            }

            AppFloatingActionButton(systemImage: "magnifyingglass", accessibilityLabel: "搜索话廊") {
                viewModel.isShowingSearch = true
            }
        }
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppTopSegmentedPicker(
                title: "话廊分区",
                selection: Bindable(viewModel).selectedFeed,
                variant: .stacked
            ) {
                ForEach(visibleFeeds) { feed in
                    Text(feed.title).tag(feed)
                }
            }
        }

    }

    /// 右下角消息按钮上的红点文案。
    ///
    /// 入口数量超过 99 时显示 `99+`。
    private var messageBadgeText: String? {
        let count = messageViewModel.totalUnreadCount
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    private var visibleFeeds: [GalleryFeedKind] {
        GalleryFeedKind.allCases.filter {
            !appSettings.snapshot.galleryHideBotPosterInSearch || $0 != .bot
        }
    }

    /// 把当前 feed 切换到相邻分区。
    private func switchFeed(step: Int) -> Bool {
        let allFeeds = visibleFeeds
        guard let currentIndex = allFeeds.firstIndex(of: viewModel.selectedFeed) else {
            return false
        }
        let nextIndex = currentIndex + step
        if nextIndex == allFeeds.count {
            withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
                selectedSurface = .paper
            }
            return true
        }
        guard allFeeds.indices.contains(nextIndex) else { return false }

        withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
            viewModel.selectedFeed = allFeeds[nextIndex]
        }
        return true
    }

}

/// 网页话廊的两个内容分区共用登录、导航和恢复行为。
public struct GalleryWebContentView: View {
    private let dependencies: GalleryDependencies
    private let surface: GallerySurface
    @Binding private var requestedPaperID: Int?
    @State private var destinationID: Int?

    public init(
        dependencies: GalleryDependencies, surface: GallerySurface,
        requestedPaperID: Binding<Int?> = .constant(nil)
    ) {
        self.dependencies = dependencies
        self.surface = surface
        _requestedPaperID = requestedPaperID
        _destinationID = State(initialValue: requestedPaperID.wrappedValue)
    }

    public var body: some View {
        let base = AppEndpoints.bit101Web.appendingPathComponent(surface.rawValue)
        GalleryWebView(url: destinationID.map { base.appendingPathComponent(String($0)) } ?? base)
            .environment(dependencies)
            .ignoresSafeArea(.container, edges: .bottom)
            .accessibilityIdentifier("gallery.web.\(surface.rawValue)")
            .onChange(of: requestedPaperID, initial: true) { _, id in
                guard let id else { return }
                destinationID = id
                requestedPaperID = nil
            }
    }
}

private struct GalleryWebView: UIViewRepresentable {
    @Environment(GalleryDependencies.self) private var dependencies
    @Environment(\.openURL) private var openURL
    let url: URL

    func makeCoordinator() -> GalleryWebCoordinator {
        GalleryWebCoordinator(
            credentials: dependencies.webCredentials, openExternal: { url in openURL(url) })
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.start(in: webView, url: url)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(in: webView, to: url)
    }
}

final class GalleryWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let logger = Logger(subsystem: "BIT101", category: "GalleryWeb")
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
    private(set) var requestedURL: URL?
    private var synchronizedCookie: String?
    private var retryURL = AppEndpoints.bit101Web.appendingPathComponent("gallery")
    private weak var recoveryAlert: UIAlertController?

    func start(in webView: WKWebView, url: URL) {
        requestedURL = url
        retryURL = url
        do { try configureBootstrap(in: webView, cookie: credentials.cookie()) } catch {
            showLoadFailure(in: webView, error: error)
            return
        }
        credentialsSubscription = credentials.changes.sink { [weak self, weak webView] _ in
            guard let webView else { return }
            self?.synchronizeCredentials(in: webView)
        }
        webView.load(GalleryWebRequestFactory.request(for: url))
    }

    func update(in webView: WKWebView, to url: URL) {
        if requestedURL != url {
            requestedURL = url
            retryURL = url
            isShowingFailure = false
            webView.load(GalleryWebRequestFactory.request(for: url))
        }
        if synchronizedCookie != credentials.cookie() {
            synchronizeCredentials(in: webView)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction)
        async -> WKNavigationActionPolicy
    {
        if isShowingFailure, navigationAction.request.url?.absoluteString == "about:blank" {
            return .allow
        }
        if navigationAction.navigationType == .linkActivated,
            let url = navigationAction.request.url,
            ["mailto", "tel"].contains(url.scheme?.lowercased() ?? "")
        {
            openExternal(url)
            return .cancel
        }
        if navigationAction.targetFrame?.isMainFrame != false,
            let url = navigationAction.request.url, GalleryWebRequestFactory.isTrustedPage(url)
        {
            retryURL = url
        }
        if navigationAction.navigationType == .linkActivated,
            GalleryWebRequestFactory.isTrustedPage(navigationAction.request.url)
        {
            isShowingFailure = false
        }
        guard navigationAction.targetFrame?.isMainFrame != false,
            !GalleryWebRequestFactory.isTrustedPage(navigationAction.request.url)
        else {
            return .allow
        }
        if navigationAction.navigationType == .linkActivated,
            let url = navigationAction.request.url,
            ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        {
            openExternal(url)
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
            GalleryWebRequestFactory.isTrustedPage(navigationAction.request.url)
        {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse)
        async -> WKNavigationResponsePolicy
    {
        if isShowingFailure, navigationResponse.response.url?.absoluteString == "about:blank" {
            return .allow
        }
        return navigationResponse.isForMainFrame
            && !GalleryWebRequestFactory.isTrustedPage(navigationResponse.response.url)
            ? .cancel : .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        if !isShowingFailure, GalleryWebRequestFactory.isTrustedPage(webView.url) {
            hasLoadedDocument = true
        }
        synchronizedCookie = nil
        synchronizeCredentials(in: webView)
    }

    private func configureBootstrap(in webView: WKWebView, cookie: String) throws {
        guard bootstrapCookie != cookie else { return }
        let script = try Self.credentialScript(cookie)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(
                source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        bootstrapCookie = cookie
    }

    private static func credentialScript(_ cookie: String) throws -> String {
        let encoded = String(decoding: try JSONEncoder().encode(cookie), as: UTF8.self)
        return """
            (() => {
                if (location.origin !== '\(AppEndpoints.bit101Web.absoluteString)') return false;
                let store = {};
                try {
                    const parsed = JSON.parse(localStorage.getItem('store') || '{}');
                    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) store =\
             parsed;
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
        } catch {
            showLoadFailure(in: webView, error: error)
            return
        }
        guard !credentialsUpdateInFlight, !webView.isLoading,
            GalleryWebRequestFactory.isTrustedPage(webView.url)
        else { return }
        credentialsUpdateInFlight = true
        credentialGeneration &+= 1
        let generation = credentialGeneration
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
            guard let self, let webView else { return }
            self.credentialsUpdateInFlight = false
            guard self.credentialGeneration == generation, !self.isShowingFailure,
                GalleryWebRequestFactory.isTrustedPage(webView.url)
            else { return }
            if self.credentials.cookie() != fakeCookie {
                self.synchronizeCredentials(in: webView)
                return
            }
            if let error {
                self.failedCredentialCookie = fakeCookie
                self.showLoadFailure(in: webView, error: error)
            } else {
                self.synchronizedCookie = fakeCookie
                if result as? Bool == true { webView.reload() }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        showLoadFailure(in: webView, error: error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
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
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled)
        else { return }
        Self.logger.error(
            "Web view failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        if let url = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
            GalleryWebRequestFactory.isTrustedPage(url)
        {
            retryURL = url
        }
        if hasLoadedDocument {
            guard recoveryAlert == nil else { return }
            var responder: UIResponder? = webView
            while let current = responder, !(current is UIViewController) {
                responder = current.next
            }
            guard let presenter = responder as? UIViewController,
                presenter.presentedViewController == nil
            else { return }
            let alert = UIAlertController(
                title: "话廊网页加载失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "继续阅读", style: .cancel))
            alert.addAction(
                UIAlertAction(title: "重新加载", style: .default) { [weak self, weak webView] _ in
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
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(
                of: "<", with: "&lt;")
        webView.loadHTMLString(
            """
            <body style=\"font: \(AppDesignSystem.Typography.webBodyCSS); padding: \
            \(padding)px;\">话廊网页加载失败。<p><a href=\"\(target)\">重新加载</a></p></body>
            """,
            baseURL: nil
        )
    }
}

private struct GalleryPosterDestination: View {
    let id: Int
    let dependencies: GalleryDependencies
    let media: MediaEnvironment
    let profiles: CommunityProfileDestination
    let onUpdated: () -> Void
    let onDeleted: () -> Void
    @State private var detail: GalleryPosterDetail?
    @State private var loadError: (any Error)?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let detail {
                GalleryPosterDetailView(
                    dependencies: dependencies, media: media, profiles: profiles,
                    poster: detail.asPoster, initialDetail: detail, onUpdated: onUpdated,
                    onDeleted: onDeleted)
            } else if let loadError {
                AppFailureState(
                    title: "无法打开话题", systemImage: "bubble.left.and.bubble.right",
                    message: loadError.localizedDescription, underlyingError: loadError,
                    onRetry: { attempt &+= 1 })
            } else {
                AppLoadingState(title: "正在加载话题")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("帖子详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) {
            loadError = nil
            do {
                let loaded = try await dependencies.posterDetail.fetchPoster(id: id)
                try Task.checkCancellation()
                detail = loaded
            } catch {
                guard !TaskCancellation.matches(error) else { return }
                loadError = error
            }
        }
        .communityReadRecovery(networkPath: dependencies.networkPath) {
            if loadError != nil { attempt &+= 1 }
        }
    }
}

#endif
