import Foundation
import CommunityCore
import CommunityTransport
@testable import GalleryFeature
@testable import PaperFeature
import TransportCore
import ClientCore
import ScorePorts
import Combine
import UIKit
import WebKit
@testable import BIT101_iOS

#if RELEASE_NETWORK_SMOKE
import XCTest

nonisolated final class NetworkSmokeRegressionTests: XCTestCase {
    @MainActor
    private func capture<Value>(_ probe: NetworkSmokeProbe, operation: () async throws -> Value) async throws -> Value {
        let collector = NetworkSmokeRequestCollector()
        defer {
            do {
                let evidence = NetworkSmokeRequestEvidence(probe: probe.rawValue, requests: collector.requests, expectedParameters: [:])
                let attachment = XCTAttachment(data: try JSONEncoder().encode(evidence), uniformTypeIdentifier: "public.json")
                attachment.name = probe.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            } catch { XCTFail("请求证据应完成编码：\(error.localizedDescription)。") }
        }
        return try await collector.perform(operation, required: true, expectedParameters: [:])
    }

    @MainActor func testCurrentAccountGrades() async throws {
        let service = ReleaseNetworkSmokeRunner.freshScoreService()
        let challenge = try await capture(.scoreAuthentication) { try await service.startScoreChallenge() }
        let brief = try await capture(.scoreBrief) { try await service.fetchScores(detail: false, authenticatedBy: challenge) }
        XCTAssertFalse(brief.isEmpty)
        let detail = try await capture(.scoreDetail) { try await service.fetchScores(detail: true, authenticatedBy: challenge) }
        XCTAssertEqual(brief.count, detail.count)
        XCTAssertTrue(detail.contains { !$0.averageScore.isEmpty })
    }

    @MainActor func testGalleryWebLoadsCurrentAccount() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        controller.view = webView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { webView.stopLoading(); window.isHidden = true; window.rootViewController = nil }
        let storage = AppAccountSession.storage
        XCTAssertFalse(storage.fakeCookie.isEmpty)
        let coordinator = GalleryWebCoordinator(credentials: .init(cookie: { storage.fakeCookie },
            changes: storage.credentialsChanges.map { _ in () }.eraseToAnyPublisher()), openExternal: { _ in })
        webView.navigationDelegate = coordinator
        coordinator.start(in: webView, url: AppURL.required("https://bit101.cn/gallery"))
        var state: [String: Any] = [:]
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            state = (try? await webView.evaluateJavaScript("""
                (() => ({ ready: document.readyState, text: (document.body?.innerText || '').slice(0, 1500),
                    appChildren: document.querySelector('#app')?.children.length || 0,
                    hasCredential: Boolean(JSON.parse(localStorage.getItem('store') || '{}').fake_cookie) }))()
                """)) as? [String: Any] ?? [:]
            let text = state["text"] as? String ?? ""
            if text.contains("话廊网页加载失败") { break }
            if !webView.isLoading, state["ready"] as? String == "complete", (state["appChildren"] as? Int ?? 0) > 0,
               state["hasCredential"] as? Bool == true, text.count > 30 { break }
        } while ContinuousClock.now < deadline
        let evidence = XCTAttachment(string: "url=\(webView.url?.host ?? "")\nstate=\(state)")
        evidence.name = "gallery.web.runtime"; evidence.lifetime = .keepAlways; add(evidence)
        let snapshot = try await webView.takeSnapshot(configuration: nil)
        let screenshot = XCTAttachment(image: snapshot)
        screenshot.name = "gallery.web.screen"; screenshot.lifetime = .keepAlways; add(screenshot)
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
            try await NetworkSmokePaging.paperPage(order: .newest, requiresContent: true, requiresOrderingEvidence: true,
                currentIdentity: dependencies.communityIdentity) { try await papers.fetchPapers(search: nil, order: .newest, page: $0) }
        }
        let sample = try XCTUnwrap(rows.first)
        let keyword = sample.title.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(keyword.isEmpty)
        _ = try await capture(.paperSearch) {
            try await NetworkSmokePaging.searchPage(matching: sample.id, keyword: keyword,
                currentIdentity: dependencies.communityIdentity) { text, page in
                    let rows = try await papers.fetchPapers(search: text, order: .newest, page: page)
                    try NetworkSmokePaging.checkPapers(rows, order: .newest)
                    return rows
                }
        }
    }
}
#endif

#if DEBUG
import Testing

@Suite("Network smoke regression contracts")
@MainActor
struct NetworkSmokeRegressionContractTests {
    private final class BootstrapWebView: WKWebView {
        override func load(_ request: URLRequest) -> WKNavigation? {
            loadHTMLString("<script>window.initialCredential = JSON.parse(localStorage.getItem('store') || '{}').fake_cookie || '';</script><body>fixture</body>", baseURL: request.url)
        }
    }

    @Test(.timeLimit(.minutes(1))) func galleryWebBootstrapsCredentialsBeforePageScripts() async throws {
        let cookie = "fixture-community-session"
        let coordinator = GalleryWebCoordinator(credentials: .init(cookie: { cookie }, changes: Empty().eraseToAnyPublisher()), openExternal: { _ in })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = BootstrapWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        coordinator.start(in: webView, url: AppURL.required("https://bit101.cn/gallery"))
        try await waitForAsyncTestEvent {
            (try? await webView.evaluateJavaScript("window.initialCredential")) as? String == cookie
        }
        #expect(webView.configuration.userContentController.userScripts.count == 1)
    }

    @Test(arguments: PaperSortOrder.allCases)
    func paperSmokeChecksRankTimezonesAndTies(order: PaperSortOrder) throws {
        let first = PaperSummary(id: 1, title: "", intro: "", likeNum: 2, commentNum: 3, updateTime: "2026-01-02T00:00:00Z")
        let tied = PaperSummary(id: 2, title: "", intro: "", likeNum: 2, commentNum: 3, updateTime: "2026-01-02T08:00:00+08:00")
        let older = PaperSummary(id: 3, title: "", intro: "", likeNum: 1, commentNum: 2, updateTime: "2026-01-01 08:00:00")
        try NetworkSmokePaging.checkPapers([], order: order)
        try NetworkSmokePaging.checkPapers([first, tied, older], order: order)
        if order == .newest { try NetworkSmokePaging.checkPapers([older, first], order: order) }
        else { #expect(throws: URLError.self) { try NetworkSmokePaging.checkPapers([older, first], order: order) } }
        if order == .newest {
            let invalid = PaperSummary(id: 4, title: "", intro: "", likeNum: 0, commentNum: 0, updateTime: "invalid")
            #expect(throws: URLError.self) { try NetworkSmokePaging.checkPapers([invalid], order: order) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func paperPagingChecksEachLiveRankingSnapshot() async throws {
        let first = PaperSummary(id: 1, title: "", intro: "", likeNum: 2, commentNum: 2, updateTime: "2026-01-01T00:00:00Z")
        let changed = PaperSummary(id: 2, title: "", intro: "", likeNum: 3, commentNum: 3, updateTime: "2026-01-02T00:00:00Z")
        for order in PaperSortOrder.allCases {
            let identity = { CommunitySessionIdentity(accountIdentifier: "paper-smoke") }
            let sample = try await NetworkSmokePaging.paperPage(order: order, currentIdentity: identity) { $0 == 0 ? [first] : [changed] }
            #expect(sample.map(\.id) == [1, 2])
            if order == .newest {
                let batch = try await NetworkSmokePaging.paperPage(order: order, currentIdentity: identity) { $0 == 0 ? [first, changed] : [] }
                #expect(batch.map(\.id) == [1, 2])
            } else {
                await #expect(throws: URLError.self) {
                    try await NetworkSmokePaging.paperPage(order: order, currentIdentity: identity) { _ in [first, changed] }
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func newestRequestAndServerOrderRemainIntact() async throws {
        let route = PaperRoute()
        let session = CommunitySession(httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "") }, refresh: { _ in })
        let rows = try await PaperService(session: session).fetchPapers(search: "主题", order: .newest, page: 0)
        #expect(rows.map(\.id) == [2, 1])
        try NetworkSmokePaging.checkPapers(rows, order: .newest)
        let query = try #require(route.request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }) == ["search": "主题", "page": "0"])
    }

    private final class PaperRoute: HTTPTransport {
        var request: URLRequest?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.request = request
            let data = Data(#"[{"id":2,"title":"主题","intro":"","like_num":1,"comment_num":1,"update_time":"2026-01-01T00:00:00Z"},{"id":1,"title":"主题","intro":"","like_num":2,"comment_num":2,"update_time":"2026-01-02T00:00:00Z"}]"#.utf8)
            let url = try #require(request.url)
            return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }
}
#endif
