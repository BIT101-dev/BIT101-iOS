import CommunityCore

#if os(iOS)
import CommunityUI
import DesignSystemKit
import Combine
import CommunityTransport
import TransportCore
import Observation
import WebKit
import UIKit

/// 话廊按首页、消息、详情、举报、编辑和图片上传分别注入服务。
public struct GalleryWebCredentials {
    let cookie: () -> String
    let changes: AnyPublisher<Void, Never>
    public init(cookie: @escaping () -> String, changes: AnyPublisher<Void, Never>) {
        self.cookie = cookie
        self.changes = changes
    }
}

struct GalleryWebEntryTiming {
    let measurement = AppPageLoadMeasurement()
    let startedAt = Date().timeIntervalSince1970
}

@MainActor
@Observable
public final class GalleryDependencies {
    @ObservationIgnored private var cachedWebStore:
        (identity: CommunitySessionIdentity, store: WKWebsiteDataStore)?
    private let webDataStoreProvider: ((CommunitySessionIdentity) -> WKWebsiteDataStore)?
    @ObservationIgnored private var credentialsSubscription: AnyCancellable?
    @ObservationIgnored private var memorySubscription: AnyCancellable?
    @ObservationIgnored private weak var preparationHost: UIView?
    @ObservationIgnored private var preparedIdentity: CommunitySessionIdentity?
    @ObservationIgnored private var preparedWebViews:
        [GallerySurface: (view: WKWebView, coordinator: GalleryWebCoordinator)] = [:]
    @ObservationIgnored private var createdWebSurfaces: Set<GallerySurface> = []
    @ObservationIgnored private var presentationTimings: [GallerySurface: GalleryWebEntryTiming] =
        [:]

    public func beginWebPresentation(for surface: GallerySurface) {
        let timing = GalleryWebEntryTiming()
        updatePreparedIdentity()
        presentationTimings[surface] = timing
    }

    func takeWebPresentation(for surface: GallerySurface) -> GalleryWebEntryTiming? {
        presentationTimings.removeValue(forKey: surface)
    }

    public func prepareWebContent(size: CGSize = .zero) {
        updatePreparedIdentity()
        for surface in [GallerySurface.gallery, .paper] where !createdWebSurfaces.contains(surface)
        {
            let view = makeWebView(for: surface)
            view.frame = CGRect(origin: .zero, size: size)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            preparationHost?.addSubview(view)
            let coordinator = GalleryWebCoordinator(
                credentials: webCredentials, openExternal: { _ in })
            view.navigationDelegate = coordinator
            view.uiDelegate = coordinator
            coordinator.start(
                in: view, url: AppEndpoints.bit101Web.appendingPathComponent(surface.rawValue),
                preparing: true)
            preparedWebViews[surface] = (view, coordinator)
        }
    }

    public func releasePreparedWebContent() {
        preparedWebViews.values.forEach {
            $0.view.stopLoading()
            $0.view.removeFromSuperview()
        }
        preparationHost?.subviews.forEach { $0.removeFromSuperview() }
        preparedWebViews.removeAll()
        createdWebSurfaces.removeAll()
        preparedIdentity = nil
        presentationTimings.removeAll()
    }

    private func trimPreparedWebContent() {
        for (surface, prepared) in preparedWebViews
        where prepared.coordinator.firstContentDuration == nil {
            prepared.view.stopLoading()
            prepared.view.removeFromSuperview()
            preparedWebViews.removeValue(forKey: surface)
        }
    }

    func attachPreparedWebContent(to host: UIView) {
        preparationHost = host
        prepareWebContent(size: host.bounds.size)
        for prepared in preparedWebViews.values {
            prepared.view.frame = host.bounds
            if prepared.view.superview !== host { host.addSubview(prepared.view) }
        }
    }

    private func updatePreparedIdentity() {
        let identity = currentIdentity()
        guard preparedIdentity != identity else { return }
        releasePreparedWebContent()
        preparedIdentity = identity
    }

    func makeWebView(for surface: GallerySurface) -> WKWebView {
        updatePreparedIdentity()
        createdWebSurfaces.insert(surface)
        if let prepared = preparedWebViews.removeValue(forKey: surface) {
            return prepared.view
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webDataStore
        return webViewProvider?(configuration)
            ?? WKWebView(frame: .zero, configuration: configuration)
    }

    func webCoordinator(
        for surface: GallerySurface, openExternal: @escaping (URL) -> Void
    ) -> GalleryWebCoordinator {
        updatePreparedIdentity()
        let coordinator =
            preparedWebViews[surface]?.coordinator
            ?? GalleryWebCoordinator(
                credentials: webCredentials, openExternal: openExternal)
        coordinator.openExternal = openExternal
        return coordinator
    }

    var webDataStore: WKWebsiteDataStore {
        let identity = currentIdentity()
        if let webDataStoreProvider { return webDataStoreProvider(identity) }
        if let cachedWebStore, cachedWebStore.identity == identity { return cachedWebStore.store }
        let store = WKWebsiteDataStore.nonPersistent()
        cachedWebStore = (identity, store)
        return store
    }

    private let webViewProvider: ((WKWebViewConfiguration) -> WKWebView)?
    let webCredentials: GalleryWebCredentials
    let currentIdentity: () -> CommunitySessionIdentity
    let feed: any GalleryFeedServicing
    let messageService: any GalleryMessageServicing
    let posterDetail: any GalleryPosterDetailServicing
    let subscriptions: any GallerySubscriptionServicing
    let reporting: any GalleryReportServicing
    let composer: any GalleryComposerServicing
    let images: any GalleryImageUploading
    let preferences: CommunityPreferences
    let messages: any GalleryMessageReadStoring
    let drafts: any GalleryComposerDraftStoring & ComposerPublicationStoring
    let networkPath: NetworkPathState

    public init(
        webCredentials: GalleryWebCredentials,
        currentIdentity: @escaping () -> CommunitySessionIdentity,
        feed: any GalleryFeedServicing,
        messageService: any GalleryMessageServicing,
        posterDetail: any GalleryPosterDetailServicing,
        subscriptions: any GallerySubscriptionServicing,
        reporting: any GalleryReportServicing,
        composer: any GalleryComposerServicing,
        images: any GalleryImageUploading,
        preferences: CommunityPreferences,
        messages: any GalleryMessageReadStoring,
        drafts: any GalleryComposerDraftStoring & ComposerPublicationStoring,
        networkPath: NetworkPathState,
        webDataStoreProvider: ((CommunitySessionIdentity) -> WKWebsiteDataStore)? = nil,
        webViewProvider: ((WKWebViewConfiguration) -> WKWebView)? = nil
    ) {
        self.webDataStoreProvider = webDataStoreProvider
        self.webViewProvider = webViewProvider
        self.webCredentials = webCredentials
        self.currentIdentity = currentIdentity
        self.feed = feed
        self.messageService = messageService
        self.posterDetail = posterDetail
        self.subscriptions = subscriptions
        self.reporting = reporting
        self.composer = composer
        self.images = images
        self.preferences = preferences
        self.messages = messages
        self.drafts = drafts
        self.networkPath = networkPath
        credentialsSubscription = webCredentials.changes.sink { [weak self] _ in
            guard let self, preparedIdentity != nil else { return }
            if preparedIdentity != currentIdentity() || webCredentials.cookie().isEmpty {
                releasePreparedWebContent()
            }
        }
        memorySubscription = NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        ).sink { [weak self] _ in self?.trimPreparedWebContent() }
    }
}

/// 等容器进入窗口且尺寸就绪后，直接接入预备网页，保留 WebKit 的窗口与排版。
final class GalleryWebContainer: AppPreparedViewHost<WKWebView> {
    private let coordinator: GalleryWebCoordinator
    private var url: URL
    private var timing: GalleryWebEntryTiming?

    init(
        webView: WKWebView, coordinator: GalleryWebCoordinator, url: URL,
        timing: GalleryWebEntryTiming?
    ) {
        self.coordinator = coordinator
        self.url = url
        self.timing = timing
        super.init(content: webView)
        onFirstMount = { [weak self] in
            guard let self else { return }
            self.coordinator.present(in: self.content, url: self.url, timing: self.timing)
            self.timing = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(to url: URL) {
        self.url = url
        if isContentMounted { coordinator.update(in: content, to: url) }
    }
}

#endif
