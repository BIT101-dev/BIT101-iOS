#if DEBUG
import ClientCore
import Combine
import CommunityCore
import CommunityTransport
import Foundation
import ScorePorts
import Testing
import TransportCore
import UIKit
import WebKit
import XCTest

@testable import BIT101_iOS
@testable import GalleryFeature
@testable import PaperFeature

nonisolated final class NetworkSmokeRegressionTests: XCTestCase {
    @MainActor
    private func capture<Value>(_ probe: NetworkSmokeProbe, operation: () async throws -> Value)
        async throws -> Value
    {
        let collector = NetworkSmokeRequestCollector()
        defer {
            do {
                let evidence = NetworkSmokeRequestEvidence(
                    probe: probe.rawValue, requests: collector.requests, expectedParameters: [:]
                )
                let attachment = XCTAttachment(
                    data: try JSONEncoder().encode(evidence),
                    uniformTypeIdentifier: "public.json")
                attachment.name = probe.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            } catch { XCTFail("请求证据应完成编码：\(error.localizedDescription)。") }
        }
        return try await collector.perform(operation, required: true, expectedParameters: [:])
    }

    @MainActor func testCurrentAccountGrades() async throws {
        let service = ReleaseNetworkSmokeRunner.freshScoreService()
        let challenge = try await capture(.scoreAuthentication) {
            try await service.startScoreChallenge()
        }
        let brief = try await capture(.scoreBrief) {
            try await service.fetchScores(detail: false, authenticatedBy: challenge)
        }
        XCTAssertFalse(brief.isEmpty)
        let detail = try await capture(.scoreDetail) {
            try await service.fetchScores(detail: true, authenticatedBy: challenge)
        }
        XCTAssertEqual(brief.count, detail.count)
        XCTAssertTrue(detail.contains { !$0.averageScore.isEmpty })
    }

    @MainActor func testGalleryWebLoadsCurrentAccount() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        controller.view = webView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            webView.stopLoading()
            window.isHidden = true
            window.rootViewController = nil
        }
        let storage = AppAccountSession.storage
        XCTAssertFalse(storage.fakeCookie.isEmpty)
        let coordinator = GalleryWebCoordinator(
            credentials: .init(
                cookie: { storage.fakeCookie },
                changes: storage.credentialsChanges.map { _ in () }.eraseToAnyPublisher()),
            openExternal: { _ in })
        webView.navigationDelegate = coordinator
        coordinator.start(in: webView, url: AppURL.required("https://bit101.cn/gallery"))
        var state: [String: Any] = [:]
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            state =
                (try? await webView.evaluateJavaScript(
                    """
                    (() => ({ ready: document.readyState, text: (document.body?.innerText || ''\
                    ).slice(0, 1500),
                        appChildren: document.querySelector('#app')?.children.length || 0,
                        hasCredential: Boolean(JSON.parse(localStorage.getItem('store') || '{}'\
                    ).fake_cookie) }))()
                    """)) as? [String: Any] ?? [:]
            let text = state["text"] as? String ?? ""
            if text.contains("话廊网页加载失败") { break }
            if !webView.isLoading, state["ready"] as? String == "complete",
                (state["appChildren"] as? Int ?? 0) > 0,
                state["hasCredential"] as? Bool == true, text.count > 30
            {
                break
            }
        } while ContinuousClock.now < deadline
        let evidence = XCTAttachment(string: "url=\(webView.url?.host ?? "")\nstate=\(state)")
        evidence.name = "gallery.web.runtime"
        evidence.lifetime = .keepAlways
        add(evidence)
        let snapshot = try await webView.takeSnapshot(configuration: nil)
        let screenshot = XCTAttachment(image: snapshot)
        screenshot.name = "gallery.web.screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse((state["text"] as? String ?? "").contains("话廊网页加载失败"))
        XCTAssertGreaterThan(state["appChildren"] as? Int ?? 0, 0)
        XCTAssertTrue(state["hasCredential"] as? Bool == true)
    }

    @MainActor func testFeedbackRecoveryReceipt() async throws {
        try await capture(.feedbackRecovery) {
            try await FeedbackSubmissionClient.submitNetworkSmoke(runID: "feedback-regression")
        }
    }

    @MainActor func testHotFeedSecondPage() async throws {
        try await capture(.galleryHot) {
            let gallery = ReleaseNetworkSmokeDependencies().makeGallery()
            _ = try await gallery.fetchFeed(kind: .hot, page: nil)
            _ = try await gallery.fetchFeed(kind: .hot, page: 1)
        }
    }

    @MainActor func testPaperNewestListsAndSearch() async throws {
        let dependencies = ReleaseNetworkSmokeDependencies()
        let papers = dependencies.makePapers()
        let rows = try await capture(.paperNewest) {
            try await NetworkSmokePaging.paperPage(
                order: .newest, requiresContent: true, requiresOrderingEvidence: true,
                currentIdentity: dependencies.communityIdentity
            ) { try await papers.fetchPapers(search: nil, order: .newest, page: $0) }
        }
        let sample = try XCTUnwrap(rows.first)
        let keyword = sample.title.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(keyword.isEmpty)
        _ = try await capture(.paperSearch) {
            try await NetworkSmokePaging.searchPage(
                matching: sample.id, keyword: keyword,
                currentIdentity: dependencies.communityIdentity
            ) { text, page in
                let rows = try await papers.fetchPapers(
                    search: text, order: .newest, page: page)
                try NetworkSmokePaging.checkPapers(rows, order: .newest)
                return rows
            }
        }
    }
}

@Suite("Network smoke regression contracts")
@MainActor
struct NetworkSmokeRegressionContractTests {
    @Test func preparedWebFailureWaitsForVisibleRetry() throws {
        let coordinator = GalleryWebCoordinator(
            credentials: .init(cookie: { "fixture" }, changes: Empty().eraseToAnyPublisher()),
            openExternal: { _ in })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = NetworkSmokeCoverageTests.PreparedWebView(
            frame: .zero, configuration: configuration)
        let url = try #require(URL(string: "https://bit101.cn/gallery"))
        coordinator.start(in: view, url: url, preparing: true)
        #expect(view.htmlLoads == 1)
        coordinator.webView(
            view, didFail: nil, withError: URLError(.notConnectedToInternet))
        #expect(view.htmlLoads == 1)
        coordinator.present(in: view, url: url)
        #expect(view.requests.count == 2)
    }

    @Test func webNetworkWaitsCountParallelRequestsOnce() throws {
        let duration = try #require(
            GalleryWebRequestFactory.networkDuration(
                [[0.2, 0.6], [0, 0.4], [0.8, 1], [0.3, 0.5]], documentDuration: 1))
        #expect(abs(duration - 0.8) < 0.000_001)
        #expect(GalleryWebRequestFactory.networkDuration([], documentDuration: 1) == 0)
        for interval in [[Double.nan, 1], [-1, 0], [1, 0], [0, 2], [0]] {
            #expect(
                GalleryWebRequestFactory.networkDuration([interval], documentDuration: 1) == nil)
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["account", "generation"])
    func galleryCachePersistsAndIsolatesOwners(change: String) async throws {
        let domain = "BIT101Tests.community-web-storage"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let cookie = try #require(
            HTTPCookie(properties: [
                .domain: "example.invalid", .path: "/", .name: "cache-test", .value: "first",
            ]))
        var credentials = CommunityCredentials(
            identity: .init(accountIdentifier: "first"), cookie: "first")
        let changes = PassthroughSubject<CommunityCredentials, Never>()
        let firstIdentifier: UUID
        var first: WKWebsiteDataStore?
        do {
            let cache = AppCommunityWebStorage(
                defaults: defaults, credentials: { credentials },
                changes: changes.eraseToAnyPublisher())
            let store = cache.dataStore(for: credentials.identity)
            first = store
            #expect(store.isPersistent)
            firstIdentifier = try #require(store.identifier)
            await store.httpCookieStore.setCookie(cookie)
        }
        let restored = AppCommunityWebStorage(
            defaults: defaults, credentials: { credentials },
            changes: changes.eraseToAnyPublisher())
        do {
            let reused = restored.dataStore(for: credentials.identity)
            #expect(reused.identifier == first?.identifier)
            #expect(await reused.httpCookieStore.allCookies().contains { $0.name == "cache-test" })
        }
        first = nil
        credentials = .init(
            identity: .init(
                accountIdentifier: change == "account" ? "second" : "first", generation: 1),
            cookie: "second")
        changes.send(credentials)
        do {
            let second = restored.dataStore(for: credentials.identity)
            #expect(second.identifier != nil && second.identifier != firstIdentifier)
            #expect(await second.httpCookieStore.allCookies().isEmpty)
        }
        await restored.finishCleanup()
        let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
        #expect(!remaining.contains(firstIdentifier))
        credentials = .init(identity: credentials.identity, cookie: "")
        changes.send(credentials)
        await restored.finishCleanup()
        #expect(!restored.dataStore(for: credentials.identity).isPersistent)
        await restored.clear()
        #expect(defaults.dictionary(forKey: "community.webStorage") == nil)
        #expect((defaults.stringArray(forKey: "community.retiredWebStorage") ?? []).isEmpty)
    }

    @Test(
        .serialized, .timeLimit(.minutes(1)),
        arguments: [
            "mailto:reader@example.invalid", "tel:+8610000", "https://bit101.cn/paper/17",
            "https://example.invalid/reader",
        ])
    func galleryWebUserWindow(address: String) async throws {
        var external: [URL] = []
        let coordinator = GalleryWebCoordinator(
            credentials: .init(cookie: { "fixture" }, changes: Empty().eraseToAnyPublisher()),
            openExternal: { external.append($0) })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = BootstrapWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = webView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            webView.stopLoading()
            window.isHidden = true
            window.rootViewController = nil
        }
        let original = AppURL.required("https://bit101.cn/gallery")
        coordinator.start(in: webView, url: original)
        try await waitForAsyncTestEvent {
            (try? await webView.evaluateJavaScript("window.initialCredential")) as? String
                == "fixture"
        }
        let link = "<a id='target' href='\(address)' target='_blank'>open</a>"
        let encoded = String(decoding: try JSONEncoder().encode(link), as: UTF8.self)
        let target = AppURL.required(address)
        if target.scheme == "tel" {
            #expect(
                await coordinator.webView(webView, decidePolicyFor: UserLinkAction(target))
                    == .cancel)
        } else {
            _ = try await webView.evaluateJavaScript(
                "document.body.innerHTML=\(encoded); document.getElementById('target').click()")
        }
        if GalleryWebRequestFactory.isTrustedPage(target) {
            try await waitForTestEvent { webView.request?.url == target }
            #expect(external.isEmpty)
        } else {
            try await waitForTestEvent { external == [target] }
            #expect(webView.request?.url == original)
        }
    }

    private final class BootstrapWebView: WKWebView {
        var request: URLRequest?
        override func load(_ request: URLRequest) -> WKNavigation? {
            self.request = request
            return loadHTMLString(
                """
                <script>window.initialCredential = JSON.parse(localStorage.getItem('store')\
                 || '{}').fake_cookie || '';</script><body>fixture</body>
                """,
                baseURL: request.url)
        }
    }

    private final class UserLinkAction: WKNavigationAction {
        private let selectedRequest: URLRequest
        override var request: URLRequest { selectedRequest }
        override var navigationType: WKNavigationType { .linkActivated }
        override var targetFrame: WKFrameInfo? { nil }
        init(_ url: URL) {
            selectedRequest = URLRequest(url: url)
            super.init()
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["navigation", "credentials"])
    func galleryWebFailuresPreserveDocument(path: String) async throws {
        let coordinator = GalleryWebCoordinator(
            credentials: .init(cookie: { "fixture" }, changes: Empty().eraseToAnyPublisher()),
            openExternal: { _ in })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = BootstrapWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        presenter.view = webView
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer {
            presenter.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        webView.navigationDelegate = coordinator
        let current = AppURL.required("https://bit101.cn/gallery/1")
        let failed = AppURL.required("https://bit101.cn/gallery/2?source=reading")
        webView.loadHTMLString(
            """
            <meta name='viewport' content='width=device-width, initial-scale=1'><script>loc\
            alStorage.setItem('store', JSON.stringify({fake_cookie:'fixture'}))</script><bo\
            dy style='height:3000px'><input id='editor' value='保留内容'></body>
            """,
            baseURL: current)
        try await waitForAsyncTestEvent {
            guard !webView.isLoading else { return false }
            return (try? await webView.evaluateJavaScript("document.readyState")) as? String
                == "complete"
        }
        _ = try await webView.evaluateJavaScript(
            """
            window.scrollTo(0, 200); localStorage.setItem('store', JSON.stringify({fake_coo\
            kie:'fixture'}))
            """
        )
        try await waitForAsyncTestEvent {
            (try? await webView.evaluateJavaScript("window.scrollY")) as? Double == 200
        }
        coordinator.webView(webView, didFinish: nil)
        let offset = try await webView.evaluateJavaScript("window.scrollY") as? Double
        if path == "credentials" {
            _ = try await webView.evaluateJavaScript(
                """
                Storage.prototype.setItem = () => { throw new Error('fixture'); }; localSto\
                rage.clear()
                """
            )
            coordinator.synchronizeCredentials(in: webView)
        } else {
            coordinator.webView(
                webView, didFailProvisionalNavigation: nil,
                withError: URLError(
                    .notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: failed]))
        }
        try await waitForTestEvent {
            guard let alert = presenter.presentedViewController as? UIAlertController else {
                return false
            }
            return !alert.isBeingPresented && alert.viewIfLoaded?.window != nil
        }
        #expect(
            try await webView.evaluateJavaScript("document.getElementById('editor')?.value")
                as? String == "保留内容")
        let actualOffset = try await webView.evaluateJavaScript("window.scrollY") as? Double
        #expect(
            actualOffset == offset,
            """
            path=\(path), initial scroll=\(String(describing: offset)), actual scroll=\
            \(String(describing: actualOffset))
            """
        )
        if path == "navigation" {
            coordinator.retryLastFailure(in: webView)
            #expect(webView.request?.url == failed)
        }
    }

    @Test(.timeLimit(.minutes(1))) func galleryWebBootstrapsCredentials() async throws {
        let cookie = "fixture-community-session"
        let coordinator = GalleryWebCoordinator(
            credentials: .init(cookie: { cookie }, changes: Empty().eraseToAnyPublisher()),
            openExternal: { _ in })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webBounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let webView = BootstrapWebView(frame: webBounds, configuration: configuration)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = webBounds
        let presenter = UIViewController()
        presenter.view = webView
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        webView.navigationDelegate = coordinator
        coordinator.start(in: webView, url: AppURL.required("https://bit101.cn/gallery"))
        try await waitForAsyncTestEvent {
            (try? await webView.evaluateJavaScript("window.initialCredential")) as? String
                == cookie
        }
        #expect(webView.configuration.userContentController.userScripts.count == 2)
        #expect(coordinator.firstContentDuration == nil)
        _ = try await webView.evaluateJavaScript(
            "document.body.innerHTML = '<a href=\"/gallery/1\">首条话题</a>'; true")
        try await waitForTestEvent { coordinator.firstContentDuration != nil }
        #expect(coordinator.firstContentLocalDuration == coordinator.firstContentDuration)
        _ = try await webView.evaluateJavaScript("true")
        _ = try await webView.evaluateJavaScript(
            """
            window.credentialReads = 0;
            const originalGetItem = Storage.prototype.getItem;
            Storage.prototype.getItem = function(key) {
                if (key === 'store') window.credentialReads++;
                return originalGetItem.call(this, key);
            };
            true;
            """)
        for _ in 0..<20 {
            coordinator.update(in: webView, to: AppURL.required("https://bit101.cn/gallery"))
        }
        let reads = try await webView.evaluateJavaScript("window.credentialReads") as? Int
        #expect(reads == 0)
        let article = AppURL.required("https://bit101.cn/paper")
        coordinator.update(in: webView, to: article)
        try await waitForTestEvent { webView.request?.url == article }
    }

    @Test(arguments: PaperSortOrder.allCases)
    func paperSmokeChecksRankTimezonesAndTies(order: PaperSortOrder) throws {
        let first = PaperSummary(
            id: 1, title: "", intro: "", likeNum: 2, commentNum: 3,
            updateTime: "2026-01-02T00:00:00Z")
        let tied = PaperSummary(
            id: 2, title: "", intro: "", likeNum: 2, commentNum: 3,
            updateTime: "2026-01-02T08:00:00+08:00")
        let older = PaperSummary(
            id: 3, title: "", intro: "", likeNum: 1, commentNum: 2,
            updateTime: "2026-01-01 08:00:00")
        try NetworkSmokePaging.checkPapers([], order: order)
        try NetworkSmokePaging.checkPapers([first, tied, older], order: order)
        if order == .newest {
            try NetworkSmokePaging.checkPapers([older, first], order: order)
        } else {
            #expect(throws: URLError.self) {
                try NetworkSmokePaging.checkPapers([older, first], order: order)
            }
        }
        if order == .newest {
            let invalid = PaperSummary(
                id: 4, title: "", intro: "", likeNum: 0, commentNum: 0, updateTime: "invalid")
            #expect(throws: URLError.self) {
                try NetworkSmokePaging.checkPapers([invalid], order: order)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func paperPagingChecksEachLiveRankingSnapshot() async throws {
        let first = PaperSummary(
            id: 1, title: "", intro: "", likeNum: 2, commentNum: 2,
            updateTime: "2026-01-01T00:00:00Z")
        let changed = PaperSummary(
            id: 2, title: "", intro: "", likeNum: 3, commentNum: 3,
            updateTime: "2026-01-02T00:00:00Z")
        for order in PaperSortOrder.allCases {
            let identity = { CommunitySessionIdentity(accountIdentifier: "paper-smoke") }
            let sample = try await NetworkSmokePaging.paperPage(
                order: order, currentIdentity: identity
            ) { $0 == 0 ? [first] : [changed] }
            #expect(sample.map(\.id) == [1, 2])
            if order == .newest {
                let batch = try await NetworkSmokePaging.paperPage(
                    order: order, currentIdentity: identity
                ) { $0 == 0 ? [first, changed] : [] }
                #expect(batch.map(\.id) == [1, 2])
            } else {
                await #expect(throws: URLError.self) {
                    try await NetworkSmokePaging.paperPage(
                        order: order, currentIdentity: identity
                    ) { _ in [first, changed] }
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func newestRequestAndServerOrderRemainIntact() async throws {
        let route = PaperRoute()
        let session = CommunitySession(
            httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "") },
            refresh: { _ in })
        let rows = try await PaperService(session: session).fetchPapers(
            search: "主题", order: .newest, page: 0)
        #expect(rows.map(\.id) == [2, 1])
        try NetworkSmokePaging.checkPapers(rows, order: .newest)
        let query = try #require(
            route.request?.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
            })
        #expect(
            Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }) == [
                "search": "主题", "page": "0",
            ])
    }

    private final class PaperRoute: HTTPTransport {
        var request: URLRequest?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.request = request
            let data = Data(
                #"""
                [{"id":2,"title":"主题","intro":"","like_num":1,"comment_num":1,"update_time\#
                ":"2026-01-01T00:00:00Z"},{"id":1,"title":"主题","intro":"","like_num":2,"co\#
                mment_num":2,"update_time":"2026-01-02T00:00:00Z"}]
                """#
                .utf8)
            let url = try #require(request.url)
            return (
                data,
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }
}
#endif
