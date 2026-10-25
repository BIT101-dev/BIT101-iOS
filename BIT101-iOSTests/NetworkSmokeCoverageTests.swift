#if DEBUG
import Foundation
import Testing
import UIKit
import WebKit
import Combine
import ClientCore
import ScoreDomain
import ScorePorts
import ScheduleDomain
import SchedulePorts
@testable import ScheduleInfrastructure
import MediaKit
import CommunityCore
import CommunityTransport
@testable import GalleryFeature
import CourseFeature
@testable import MineFeature
@testable import PaperFeature
import TransportCore
import StorageCore
@testable import BIT101_iOS

@Suite("Network smoke coverage")
@MainActor
struct NetworkSmokeCoverageTests {
    private final class ProfilePosterRoute: HTTPTransport {
        var queries: [[String: String]] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(url.path == "/posters" && request.httpMethod == "GET")
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            queries.append(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }))
            return (Data("[]".utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1))) func profileSmokeAndWriteRecoveryUseFixedCommunityPreferences() async throws {
        let route = ProfilePosterRoute()
        let session = CommunitySession(httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        let ordinary = MineService(session: session, preferences: {
            .init(hideBots: true, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        _ = try await ordinary.fetchMyPosters(page: 0)
        let mine = ReleaseNetworkSmokeDependencies.mineService(session: session)
        _ = try await mine.fetchMyPosters(page: 0)
        _ = try await mine.fetchUserPosters(userID: 42, page: 1)
        let operations = CommunityWriteSmoke.Operations.production(mine: mine)
        #expect(try await operations.find(.poster, "功能验收") == [])
        #expect(route.queries == [
            ["mode": "search", "uid": "0", "page": "0", "hide_bot": "true"],
            ["mode": "search", "uid": "0", "page": "0"],
            ["mode": "search", "uid": "42", "page": "1"],
            ["mode": "search", "uid": "0", "page": "0"]
        ])
    }

    private struct LiteralOverloads {
        struct Number: ExpressibleByIntegerLiteral { init(integerLiteral: Int) {} }
        enum State { case active }
        static func integer(id: Int32) -> Bool { true }
        static func integer(id: String) -> Bool { false }
        static func unsigned(id: UInt32) -> Bool { true }
        static func unsigned(id: String) -> Bool { false }
        static func real(value: Float) -> Bool { true }
        static func real(value: String) -> Bool { false }
        static func custom(value: Number) -> Bool { true }
        static func custom(value: String) -> Bool { false }
        static func optional(value: Int?) -> Bool { true }
        static func optional(value: String) -> Bool { false }
        static func state(value: State) -> Bool { true }
        static func state(value: String) -> Bool { false }
        static func defaultInteger(value: Int) -> Bool { true }
        static func defaultInteger(value: Int32) -> Bool { false }
        static func defaultReal(value: Double) -> Bool { true }
        static func defaultReal(value: Float) -> Bool { false }
    }

    @Test func compilerSelectsContextualLiteralOverloads() {
        #expect(LiteralOverloads.integer(id: 1))
        #expect(LiteralOverloads.unsigned(id: 0x10))
        #expect(LiteralOverloads.real(value: 1.25))
        #expect(LiteralOverloads.custom(value: 1))
        #expect(LiteralOverloads.optional(value: nil))
        #expect(LiteralOverloads.state(value: .active))
        #expect(LiteralOverloads.defaultInteger(value: 1))
        #expect(LiteralOverloads.defaultReal(value: 1.25))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["empty", "single", "equal", "separate-pages", "distinct", "reversed", "cross-page", "continued"])
    func posterSortingRequiresAValidDistinctResponse(sample: String) async throws {
        func poster(_ id: Int, likes: Int, date: String) -> CommunityPoster {
            CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
                createTime: date, editTime: "", id: id, images: [], likeNum: likes, public: true,
                tags: [], text: "", title: "", updateTime: "", user: user(1))
        }
        let first = poster(1, likes: 2, date: "2026-01-02T00:00:00Z")
        let second = poster(2, likes: sample == "equal" ? 2 : 1,
            date: sample == "equal" ? first.createTime : "2026-01-01T00:00:00Z")
        for order in [GallerySearchOrder.like, .newest] {
            let load: (Int) async throws -> GalleryPageBatch<CommunityPoster> = { page in
                let items: [CommunityPoster]
                switch sample {
                case "empty": items = []
                case "single": items = page == 0 ? [first] : []
                case "separate-pages": items = page == 0 ? [first] : [second]
                case "cross-page", "continued": items = page == 0 ? [first, second]
                    : [poster(3, likes: sample == "cross-page" ? 3 : 0,
                        date: sample == "cross-page" ? "2026-01-03T00:00:00Z" : "2025-12-31T00:00:00Z")]
                case "reversed": items = page == 0 ? [second, first] : []
                default: items = page == 0 ? [first, second] : []
                }
                return .init(items: items, nextSourcePage: page + 1, canLoadMore: !items.isEmpty)
            }
            if ["distinct", "continued"].contains(sample) || sample == "cross-page" && order == .like {
                #expect(try await NetworkSmokePaging.posterPage(order: order, requiresOrderingEvidence: true,
                    currentIdentity: { .init(accountIdentifier: "poster-ordering") }, load: load).items.count == (sample == "distinct" ? 2 : 3))
            } else {
                await #expect(throws: Error.self) {
                    try await NetworkSmokePaging.posterPage(order: order, requiresOrderingEvidence: true,
                        currentIdentity: { .init(accountIdentifier: "poster-ordering") }, load: load)
                }
            }
        }
    }

    @Test func courseHistorySmokeRequiresUsableUniqueStatistics() throws {
        let valid = CourseHistoryGrade(term: "2026-2027-1", avgScore: 85, maxScore: 100, studentNum: 30)
        try NetworkSmokePaging.checkCourseHistories([valid])
        for grades in [[], [valid, valid], [.init(term: "term", avgScore: nil, maxScore: nil, studentNum: nil)],
            [.init(term: "term", avgScore: -.infinity, maxScore: 100, studentNum: 30)],
            [.init(term: "term", avgScore: 85, maxScore: 101, studentNum: 30)],
            [.init(term: "term", avgScore: 85, maxScore: 100, studentNum: -1)]] {
            #expect(throws: Error.self) { try NetworkSmokePaging.checkCourseHistories(grades) }
        }
    }

    @Test func courseWeekSmokeChecksALiteralFiveWeekSource() throws {
        func course(_ id: String, name: String, weeks: [Int]) -> CourseRecord { CourseRecord(id: id, term: "2026-2027-1", name: name, teacher: "", classroom: "",
            description: "1-5周 星期一", weeks: weeks, weekday: 1, startSection: 1, endSection: 2,
            campus: "", number: id, credit: 0, hour: 0, type: "", category: "", department: "") }
        func payload(_ weeks: [Int]) -> CourseSyncPayload {
            let courses = [course("literal", name: "课程一", weeks: weeks), course("independent", name: "课程二", weeks: weeks)]
            return CourseSyncPayload(term: "2026-2027-1", firstDayString: "2026-09-21", sourceFirstDayString: "2026-08-31",
                normalizationOffset: 3, rawWeeksByCourse: [[4, 5, 6, 7, 8], [4, 5, 6, 7, 8]], sourceDisplayWeeksByCourse: ["1-5周 星期一", "1-5周 星期一"],
                courses: courses, exams: [])
        }
        try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload([1, 2, 3, 4, 5]))
        #expect(throws: URLError.self) { try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload([1, 2, 3, 4])) }
    }

    @Test func runIdentifiersMatchTheFeedbackEndpointAcrossLaunchEntrypoints() throws {
        for (identifier, accepted) in [("fixture-123-ABC", true), (String(repeating: "a", count: 128), true),
            ("a.b", false), ("运行", false), ("a b", false), ("fixture_1", false),
            (String(repeating: "a", count: 129), false)] {
            var components = try #require(URLComponents(string: "bit101://network-smoke/bit101"))
            components.queryItems = [.init(name: "run", value: identifier)]
            #expect((ReleaseNetworkSmokeLaunchRequest(url: try #require(components.url)) != nil) == accepted)
            #expect((ReleaseNetworkSmokeLaunchRequest(scope: .bit101,
                environment: ["BIT101_VALIDATION_RUN_ID": identifier]) != nil) == accepted)
            let data = try JSONSerialization.data(withJSONObject: ["scope": "bit101", "capture": "none", "runID": identifier])
            if accepted {
                #expect(try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self, from: data).runID == identifier)
            } else {
                #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self, from: data) }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["empty", "single", "equal", "separate-pages", "distinct", "cross-page", "continued"])
    func sortingProbesRequireDistinctValuesInOneResponse(sample: String) async throws {
        let first = PaperSummary(id: 1, title: "", intro: "", likeNum: 2, commentNum: 2, updateTime: "2026-01-02T00:00:00Z")
        let second = PaperSummary(id: 2, title: "", intro: "", likeNum: sample == "equal" ? 2 : 1,
            commentNum: sample == "equal" ? 2 : 1,
            updateTime: sample == "equal" ? first.updateTime : "2026-01-01T00:00:00Z")
        for order in PaperSortOrder.allCases {
            let load: (Int) async throws -> [PaperSummary] = { page in
                switch sample {
                case "empty": return []
                case "single": return page == 0 ? [first] : []
                case "cross-page", "continued": return page == 0 ? [first, second]
                    : [PaperSummary(id: 3, title: "", intro: "", likeNum: sample == "cross-page" ? 3 : 0,
                        commentNum: sample == "cross-page" ? 3 : 0,
                        updateTime: sample == "cross-page" ? "2026-01-03T00:00:00Z" : "2025-12-31T00:00:00Z")]
                case "separate-pages": return page == 0 ? [first] : [second]
                default: return page == 0 ? [first, second] : []
                }
            }
            if ["distinct", "continued", "cross-page"].contains(sample) || sample == "equal" && order == .newest {
                #expect(try await NetworkSmokePaging.paperPage(order: order, requiresOrderingEvidence: true,
                    currentIdentity: { .init(accountIdentifier: "ordering") }, load: load).count == (["distinct", "equal"].contains(sample) ? 2 : 3))
            } else {
                await #expect(throws: Error.self) {
                    try await NetworkSmokePaging.paperPage(order: order, requiresOrderingEvidence: true,
                        currentIdentity: { .init(accountIdentifier: "ordering") }, load: load)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func eclassRequestEvidenceKeepsSelectionAndRedactsConditionValues(filtered: Bool) throws {
        let url = AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["page": 1, "page_size": 100, "fields": "id,name",
            "conditions": filtered ? ["token": "secret"] : [:]])
        var final = request
        final.httpBody = Data(#"{"page":2,"page_size":101,"fields":"id","conditions":{}}"#.utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response, finalRequest: final)
        #expect(evidence.query["page_size"] == "100" && evidence.query["fields"] == "id,name")
        #expect(evidence.query["conditions"] == (filtered ? "[REDACTED]" : "{}"))
        #expect(evidence.finalQuery["page_size"] == "101" && evidence.finalQuery["fields"] == "id")
        #expect(evidence.finalQuery["conditions"] == "{}")
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("secret"))
    }

    @Test(arguments: ["false", "true", "0", "null", "\"false\""])
    func scoreRequestEvidencePreservesBooleanTypes(value: String) throws {
        for (field, path) in [("detail", "bit101/score"), ("detailed", "cjd/cookies")] {
            let url = AppURL.required("https://login.bit101.flwfdd.xyz/api/jwb/" + path)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{\"\(field)\":\(value),\"username\":\"secret-account\",\"password\":\"secret-password\"}".utf8)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
            #expect(evidence.query[field] == (["false", "true"].contains(value) ? value : "[REDACTED]"))
            #expect(evidence.finalQuery[field] == evidence.query[field])
            #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("secret-"))
        }
    }

    private func smokeIdentity() -> CommunitySessionIdentity { .init(accountIdentifier: "fixture") }

    @Test(.timeLimit(.minutes(1)), arguments: ["array", "batch", "messages"], [false, true])
    func pagingUsesItsInjectedSessionAcrossPages(kind: String, switchesAccount: Bool) async throws {
        var identity = smokeIdentity()
        var calls = 0
        func advance() {
            calls += 1
            if switchesAccount && calls == 2 { identity = .init(accountIdentifier: "other") }
        }
        let operation: () async throws -> Void = {
            switch kind {
            case "array":
                let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(currentIdentity: { identity }) { page in
                    advance(); return [user(page + 1)]
                }
            case "batch":
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: { identity }) { page in
                    advance(); return .init(items: [user(page + 1)], nextSourcePage: page + 1, canLoadMore: page == 0, sourceIDs: [page + 1])
                }
            default:
                _ = try await NetworkSmokePaging.messages(currentIdentity: { identity }) { cursor in
                    advance()
                    return try JSONDecoder().decode([GalleryMessage].self,
                        from: Data("[{\"fromUser\":{},\"id\":\(cursor == Int.max ? 9 : 8),\"linkObj\":\"\",\"obj\":\"\",\"text\":\"\",\"updateTime\":\"\"}]".utf8))
                }
            }
        }
        if switchesAccount { await #expect(throws: CancellationError.self) { try await operation() } }
        else { try await operation() }
        #expect(calls == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["array", "batch"], [0, 1])
    func pagingRejectsDuplicateRowsBeforeMerging(kind: String, duplicatePage: Int) async throws {
        await #expect(throws: URLError.self) {
            if kind == "array" {
                let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                    page == duplicatePage ? [user(page + 1), user(page + 1)] : [user(page + 1)]
                }
            } else {
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                    let rows = page == duplicatePage ? [user(page + 1), user(page + 1)] : [user(page + 1)]
                    return .init(items: rows, nextSourcePage: page + 1, canLoadMore: page == 0)
                }
            }
        }
        let batch: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
            .init(items: [user(page == 0 ? 1 : 2)], nextSourcePage: page == 0 ? 2 : page + 1,
                canLoadMore: page == 0, sourceIDs: page == 0 ? [1, 1] : [1, 2])
        }
        #expect(batch.items.map(\.id) == [1, 2])
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["provisional", "navigation", "process", "credentials"])
    func galleryWebFailuresRenderTheRetryDocument(path: String) async throws {
        let coordinator = GalleryWebCoordinator(credentials: .init(cookie: { "fixture" }, changes: Empty().eraseToAnyPublisher()), openExternal: { _ in })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        switch path {
        case "provisional": coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        case "navigation": coordinator.webView(webView, didFail: nil, withError: URLError(.networkConnectionLost))
        case "credentials":
            webView.loadHTMLString("<script>Storage.prototype.setItem = () => { throw new Error('fixture'); };</script>",
                baseURL: AppURL.required("https://bit101.cn/gallery"))
        default: coordinator.webViewWebContentProcessDidTerminate(webView)
        }
        var text = ""
        let deadline = Date.now.addingTimeInterval(5)
        repeat {
            text = try await webView.evaluateJavaScript("document.body?.innerText ?? ''") as? String ?? ""
            if text.contains("重新加载") { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date.now < deadline
        #expect(text.contains("话廊网页加载失败") && text.contains("重新加载"))
        #expect(try await webView.evaluateJavaScript("document.querySelector('a')?.href") as? String == "https://bit101.cn/gallery")
    }
    private final class CredentialWebView: WKWebView {
        var reloads = 0
        var initialRequest: URLRequest?
        override func load(_ request: URLRequest) -> WKNavigation? {
            initialRequest = request
            return loadHTMLString("<script>localStorage.setItem('store', JSON.stringify({other:'retained'}))</script>", baseURL: request.url)
        }
        override func reload() -> WKNavigation? {
            reloads += 1
            return loadHTMLString("<body>fixture</body>", baseURL: AppURL.required("https://bit101.cn/gallery"))
        }
    }
    @Test(.timeLimit(.minutes(1))) func galleryWebCredentialsFollowLoginAccountChangesAndSignOut() async throws {
        var cookie = "account-a\"\\\n"
        let changes = PassthroughSubject<Void, Never>()
        let coordinator = GalleryWebCoordinator(credentials: .init(cookie: { cookie }, changes: changes.eraseToAnyPublisher()), openExternal: { _ in })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CredentialWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        coordinator.start(in: webView, url: AppURL.required("https://bit101.cn/gallery"))
        #expect(webView.initialRequest?.url?.absoluteString == "https://bit101.cn/gallery")
        for (index, value) in [cookie, "account-b", ""].enumerated() {
            cookie = value
            if index > 0 { changes.send() }
            let deadline = Date.now.addingTimeInterval(5)
            var actual = "", other = ""
            repeat {
                actual = (try? await webView.evaluateJavaScript("JSON.parse(localStorage.getItem('store') || '{}').fake_cookie")) as? String ?? "missing"
                other = (try? await webView.evaluateJavaScript("JSON.parse(localStorage.getItem('store') || '{}').other")) as? String ?? ""
                if actual == cookie && other == "retained" && webView.reloads == index + 1 && !webView.isLoading { break }
                try await Task.sleep(for: .milliseconds(50))
            } while Date.now < deadline
            #expect(actual == cookie && other == "retained" && webView.reloads == index + 1)
        }
        coordinator.synchronizeCredentials(in: webView)
        _ = try await webView.evaluateJavaScript("true")
        await Task.yield()
        #expect(webView.reloads == 3)
    }

    private final class BotFeed: GalleryFeedServicing {
        var pages: [Int] = []
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            pages.append(startPage)
            return .init(items: [], nextSourcePage: startPage + 5, canLoadMore: startPage < 10, sourceIDs: [startPage + 1])
        }
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> { throw URLError(.unsupportedURL) }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> { throw URLError(.unsupportedURL) }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> { throw URLError(.unsupportedURL) }
    }

    @Test(.timeLimit(.minutes(1))) func emptyBotBatchesContinueThroughTheirSourceCursor() async {
        let service = BotFeed()
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .bot)
        #expect(service.pages == [0] && model.state(for: .bot).nextPage == 5 && model.state(for: .bot).canLoadMore)
        await model.enqueueLoadMore(for: .bot, currentPoster: nil).value
        #expect(service.pages == [0, 5] && model.state(for: .bot).nextPage == 10 && !model.state(for: .bot).isLoadingMore)
        await model.enqueueLoadMore(for: .bot, currentPoster: nil).value
        #expect(service.pages == [0, 5, 10] && model.state(for: .bot).nextPage == 15 && !model.state(for: .bot).canLoadMore)
    }

    private final class SelectorTransport: HTTPTransport {
        var body = Data()
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (body, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["complete", "missing", "wrong", "empty", "malformed"])
    func eclassSmokeBindsEveryReturnedCourseToItsActivityRequest(stage: String) async throws {
        let transport = SelectorTransport()
        transport.body = Data((stage == "malformed" ? "{}" : stage == "empty" ? #"{"courses":[]}"# : #"{"courses":[{"id":41},{"id":43}]}"#).utf8)
        let client = HTTPClient(transport: transport, observer: nil)
        let collector = NetworkSmokeRequestCollector()
        let operation = {
            var list = URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses"))
            list.httpMethod = "POST"
            list.setValue("application/json", forHTTPHeaderField: "Content-Type")
            list.httpBody = Data(#"{"page":1,"page_size":100,"fields":"id,name","conditions":{}}"#.utf8)
            _ = try await client.send(list)
            for id in stage == "empty" ? [] : stage == "missing" ? [41] : stage == "wrong" ? [41, 45] : [41, 43] {
                _ = try await client.send(URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn/api/courses/\(id)/activities")))
            }
        }
        if stage == "complete" || stage == "empty" { try await collector.perform(operation, required: true) }
        else { await #expect(throws: NetworkSmokeRequestError.self) { try await collector.perform(operation, required: true) } }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["0", "99"], [false, true])
    func requestEvidenceRejectsAmbiguousBusinessParameters(value: String, redirected: Bool) async throws {
        let url = AppURL.required("https://bit101.flwfdd.xyz/papers?page=0")
        let duplicate = AppURL.required(url.absoluteString + "&page=\(value)")
        let request = URLRequest(url: redirected ? url : duplicate)
        let finalRequest = URLRequest(url: duplicate)
        let response = try #require(HTTPURLResponse(url: duplicate, statusCode: 200, httpVersion: nil, headerFields: nil))
        let collector = NetworkSmokeRequestCollector()
        await #expect(throws: NetworkSmokeRequestError.self) {
            try await collector.perform({ await HTTPRequestEvidenceContext.didReceive?(request, HTTPResponse(data: Data(), response: response, finalRequest: finalRequest)) }, required: true)
        }
        #expect(collector.requests.count == 1 && HTTPRequestEvidenceContext.didReceive == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["complete", "missing", "wrong-source", "wrong-query", "extra"])
    func imageSmokeBindsEverySelectedResource(stage: String) async throws {
        let urls = ["https://cdn.example.invalid/image.png?token=first", "https://cdn.example.invalid/other.png"]
        let selected = stage == "missing" ? [urls[0]] : stage == "wrong-source" ? [urls[0], "https://other.example.invalid/image.png"]
            : stage == "wrong-query" ? [urls[0].replacingOccurrences(of: "first", with: "second"), urls[1]]
            : stage == "extra" ? urls + ["https://cdn.example.invalid/extra.png"] : urls
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        let collector = NetworkSmokeRequestCollector()
        let operation = {
            for url in selected { _ = try await client.send(URLRequest(url: AppURL.required(url))) }
        }
        if stage == "complete" {
            try await collector.perform(operation, required: true, expectedParameters: NetworkSmokePaging.imageResourceParameters(urls))
        } else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(operation, required: true, expectedParameters: NetworkSmokePaging.imageResourceParameters(urls))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["correct", "wrong", "missing"])
    func buildingSmokeKeepsItsSelectedCampus(selection: String) async throws {
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        let base = "https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do"
        let request = URLRequest(url: AppURL.required(base + (selection == "missing" ? "" : "?XXXQDM=" + (selection == "correct" ? "campus" : "other"))))
        let collector = NetworkSmokeRequestCollector()
        let operation = { try await client.send(request) }
        if selection == "correct" { _ = try await collector.perform(operation, required: true, expectedParameters: ["XXXQDM": "campus"]) }
        else { await #expect(throws: NetworkSmokeRequestError.self) { try await collector.perform(operation, required: true, expectedParameters: ["XXXQDM": "campus"]) } }
        let building = BuildingRecord(id: "building", name: "", buildingCode: "building", campusName: "", campusCode: selection == "correct" ? "campus" : "other")
        if selection == "correct" { try NetworkSmokePaging.checkBuildings([building], campusCode: "campus") }
        else { #expect(throws: URLError.self) { try NetworkSmokePaging.checkBuildings([building], campusCode: "campus") } }
    }

    @Test(arguments: ["valid", "full-and-thumbnail", "empty", "text-only", "image-only", "unsupported", "broken-image"])
    func paperSmokeUsesTheProductionRendererAndRequiresReadableTextAndImages(stage: String) throws {
        let raw = stage == "empty" ? "" : stage == "text-only" ? "text" : stage == "image-only" ? #"{"blocks":[{"type":"image","data":{"file":{"url":"https://image.invalid/paper.png"}}}]}"#
            : stage == "unsupported" ? #"{"blocks":[{"type":"table","data":{}}]}"#
            : stage == "full-and-thumbnail" ? smokePaperContent.replacingOccurrences(of: "\"url\":\"https://image.invalid/paper.png\"", with: "\"url\":\"https://image.invalid/paper.png\",\"low_url\":\"https://image.invalid/paper-low.png\"")
            : smokePaperContent.replacingOccurrences(of: "https://image.invalid/paper.png", with: stage == "broken-image" ? "javascript:alert(1)" : "https://image.invalid/paper.png")
        if stage == "valid" { #expect(try NetworkSmokePaging.checkPaperContent(raw) == ["https://image.invalid/paper.png"]) }
        else if stage == "full-and-thumbnail" { #expect(try NetworkSmokePaging.checkPaperContent(raw) == ["https://image.invalid/paper-low.png", "https://image.invalid/paper.png"]) }
        else { #expect(throws: URLError.self) { try NetworkSmokePaging.checkPaperContent(raw) } }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["correct", "wrong", "missing"])
    func requestEvidenceChecksTheSelectedTermAndBuilding(selection: String) async throws {
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        var request = URLRequest(url: AppURL.required("https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPFormEncoding.body([("XNXQDM", "2025-2026-1")] + (selection == "missing" ? [] : [("JXLDM", selection == "correct" ? "selected-building" : "wrong-building")]))
        let collector = NetworkSmokeRequestCollector()
        let operation = { try await client.send(request) }
        let expected = ["XNXQDM": "2025-2026-1", "JXLDM": "selected-building"]
        if selection == "correct" { _ = try await collector.perform(operation, required: true, expectedParameters: expected) }
        else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(operation, required: true, expectedParameters: expected)
            }
        }
        #expect(collector.requests.count == 1 && HTTPRequestEvidenceContext.didReceive == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["obj", "uid", "path", "search"], ["correct", "wrong", "missing"])
    func requestEvidenceChecksTheSelectedCommunityInput(key: String, selection: String) async throws {
        let expected = key == "obj" ? "poster17" : key == "uid" ? "23" : key == "search" ? "课程 1" : "/courses/histories/课程 1"
        var components = try #require(URLComponents(string: "https://bit101.flwfdd.xyz" + (key == "path" ? "/courses/histories/17" : key == "obj" ? "/reaction/comments" : "/posters")))
        if key == "path" { components.path = expected }
        if key == "path", selection != "correct" {
            components.path = selection == "wrong" ? "/courses/histories/999" : "/user/check"
        } else if key != "path", selection != "missing" {
            components.queryItems = [URLQueryItem(name: key, value: selection == "correct" ? expected : key == "obj" ? "poster999" : "999")]
        }
        let url = try #require(components.url)
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        let collector = NetworkSmokeRequestCollector()
        let operation = { try await client.send(URLRequest(url: url)) }
        if selection == "correct" { _ = try await collector.perform(operation, required: true, expectedParameters: [key: expected]) }
        else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(operation, required: true, expectedParameters: [key: expected])
            }
        }
        #expect(collector.requests.count == 1 && HTTPRequestEvidenceContext.didReceive == nil)
    }

    @Test func smokeResponsesKeepTheirSelectedCommentParentAndPosterAuthor() throws {
        let user = user(23)
        let comment = CommunityComment(id: 1, obj: "paper17", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false, rate: 0,
            replyUser: user, replyObj: "", text: "", sub: [])
        try NetworkSmokePaging.checkComments([comment], for: "paper17")
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkComments([comment], for: "paper999") }
        let poster = CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0, createTime: "", editTime: "",
            id: 1, images: [], likeNum: 0, public: true, tags: [], text: "", title: "", updateTime: "", user: user)
        try NetworkSmokePaging.checkPosters([poster], for: 23)
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkPosters([poster], for: 999) }
    }

    @Test func serverAbsenceConfirmationTravelsThroughTheCleanupLaunchRequest() throws {
        let confirmation = CommunityWriteRecoveryConfirmation(marker: "功能验收 fixture", account: 1,
            serverReceipt: "backend-reconciliation", kinds: ["poster"], parents: ["course1"])
        let encoded = try JSONEncoder().encode(confirmation)
        let environment = ["BIT101_COMMUNITY_RECOVERY_CONFIRMATION": String(decoding: encoded, as: UTF8.self)]
        let request = try #require(ReleaseNetworkSmokeLaunchRequest(scope: .communityCleanup, environment: environment))
        #expect(request.communityRecoveryConfirmation?.serverReceipt == confirmation.serverReceipt)
        #expect(ReleaseNetworkSmokeLaunchRequest(scope: .ddl, environment: environment) == nil)
        let fileRequest = try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self, from: JSONEncoder().encode(request))
        #expect(fileRequest.communityRecoveryConfirmation?.marker == confirmation.marker)
        #expect(fileRequest.communityRecoveryConfirmation?.kinds == ["poster"])
        #expect(ReleaseNetworkSmokeLaunchRequest(scope: .communityCleanup,
            environment: ["BIT101_COMMUNITY_RECOVERY_CONFIRMATION": "{}"]) == nil)
    }

    @Test func botSmokeRejectsOrdinaryPostersAndAcceptsRecognizedTags() throws {
        func poster(tags: [String]) -> CommunityPoster {
            CommunityPoster(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0, createTime: "", editTime: "",
                id: 1, images: [], likeNum: 0, public: true, tags: tags, text: "", title: "", updateTime: "", user: user(1))
        }
        try NetworkSmokePaging.checkBotPosters([])
        for tags in [["BOT"], ["机器人"], ["通知"], ["新闻"]] {
            try NetworkSmokePaging.checkBotPosters([poster(tags: tags)])
        }
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkBotPosters([poster(tags: ["生活"])]) }
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkBotPosters([poster(tags: ["BOT"]), poster(tags: [])]) }
    }

    @Test(arguments: CommunityCommentOrder.allCases)
    func commentSmokeChecksRanksTimezonesAndTies(order: CommunityCommentOrder) throws {
        for object in ["paper17", "course17"] {
            func comment(_ id: Int, likes: Int, date: String) -> CommunityComment {
                CommunityComment(id: id, obj: object, images: [], user: user(23), anonymous: false,
                    createTime: date, updateTime: "", like: false, likeNum: likes, commentNum: 0, own: false,
                    rate: 0, replyUser: user(23), replyObj: "", text: "", sub: [])
            }
            let first = comment(1, likes: 2, date: "2026-01-02T00:00:00Z")
            let tied = comment(2, likes: 2, date: "2026-01-02T08:00:00+08:00")
            let older = comment(3, likes: 1, date: "2026-01-01T00:00:00Z")
            try NetworkSmokePaging.checkComments([], for: object, order: order)
            try NetworkSmokePaging.checkComments(order == .oldest ? [older, first, tied] : [first, tied, older], for: object, order: order)
            #expect(throws: URLError.self) {
                try NetworkSmokePaging.checkComments(order == .oldest ? [first, older] : [older, first], for: object, order: order)
            }
            if order != .like {
                #expect(throws: URLError.self) {
                    try NetworkSmokePaging.checkComments([comment(4, likes: 0, date: "invalid")], for: object, order: order)
                }
            }
        }
    }

    @Test func maintainedFixturesValidateAndTravelThroughBothLaunchEntrypoints() throws {
        let fixture = NetworkSmokeFixtures(posterID: 41, courseID: 43, courseNumber: "COURSE", paperID: 45)
        let encoded = try JSONEncoder().encode(fixture)
        let payload = try JSONSerialization.data(withJSONObject: ["scope": "bit101", "runID": "fixture",
            "capture": "none", "fixtures": try JSONSerialization.jsonObject(with: encoded)])
        let request = try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self, from: payload)
        #expect(request.fixtures?.isValid == true && request.fixtures?.courseID == 43)
        var components = try #require(URLComponents(string: "bit101://network-smoke/bit101"))
        components.queryItems = [.init(name: "fixtures", value: String(decoding: encoded, as: UTF8.self))]
        #expect(ReleaseNetworkSmokeLaunchRequest(url: try #require(components.url))?.fixtures?.posterID == 41)
        var environment = ["BIT101_NETWORK_SMOKE_FIXTURES": String(decoding: encoded, as: UTF8.self),
            "BIT101_VALIDATION_RUN_ID": "fixture", "BIT101_NETWORK_SMOKE_TERM": "2026-2027-1",
            "BIT101_COMMUNITY_FOLLOW_TARGET": "2", "BIT101_COMMUNITY_SMOKE_ACCOUNT": "1"]
        let environmentRequest = try #require(ReleaseNetworkSmokeLaunchRequest(scope: .bit101, environment: environment))
        #expect(environmentRequest.fixtures?.posterID == 41 && environmentRequest.fixtures?.courseID == 43)
        #expect(environmentRequest.scope == .bit101 && environmentRequest.runID == "fixture" && environmentRequest.capture == .none)
        #expect(environmentRequest.term == "2026-2027-1" && environmentRequest.communityFollowTarget == 2
            && environmentRequest.communityExpectedAccount == 1)
        for (key, value) in [("BIT101_NETWORK_SMOKE_CAPTURE", "invalid"), ("BIT101_NETWORK_SMOKE_FIXTURES", "{}"),
            ("BIT101_COMMUNITY_FOLLOW_TARGET", "0"), ("BIT101_COMMUNITY_SMOKE_ACCOUNT", "invalid")] {
            let original = environment[key]
            environment[key] = value
            #expect(ReleaseNetworkSmokeLaunchRequest(scope: .bit101, environment: environment) == nil)
            environment[key] = original
        }
        for value in [NetworkSmokeFixtures(posterID: 0, courseID: 43, courseNumber: "COURSE", paperID: 45),
            NetworkSmokeFixtures(posterID: 41, courseID: 43, courseNumber: " COURSE", paperID: 45)] {
            #expect(!value.isValid)
            components.queryItems = [.init(name: "fixtures", value: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))]
            #expect(ReleaseNetworkSmokeLaunchRequest(url: try #require(components.url)) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["empty", "single", "equal", "separate-pages", "distinct", "cross-page", "continued"])
    func commentOrderingProbesRequireDistinctValuesInOneResponse(sample: String) async throws {
        let object = "paper17"
        let first = CommunityComment(id: 1, obj: object, images: [], user: user(23), anonymous: false,
            createTime: "2026-01-02T00:00:00Z", updateTime: "", like: false, likeNum: 2, commentNum: 0,
            own: false, rate: 0, replyUser: user(23), replyObj: "", text: "", sub: [])
        let second = CommunityComment(id: 2, obj: object, images: [], user: user(23), anonymous: false,
            createTime: sample == "equal" ? first.createTime : "2026-01-01T00:00:00Z", updateTime: "", like: false,
            likeNum: sample == "equal" ? 2 : 1, commentNum: 0, own: false, rate: 0, replyUser: user(23), replyObj: "", text: "", sub: [])
        for order in CommunityCommentOrder.allCases {
            let load: (Int) async throws -> [CommunityComment] = { page in
                switch sample {
                case "empty": return []
                case "single": return page == 0 ? [first] : []
                case "cross-page", "continued":
                    if page == 0 { return order == .oldest ? [second, first] : [first, second] }
                    let newer = (sample == "cross-page") != (order == .oldest)
                    return [CommunityComment(id: 3, obj: object, images: [], user: user(23), anonymous: false,
                        createTime: newer ? "2026-01-03T00:00:00Z" : "2025-12-31T00:00:00Z", updateTime: "", like: false,
                        likeNum: sample == "cross-page" ? 3 : 0, commentNum: 0, own: false, rate: 0,
                        replyUser: user(23), replyObj: "", text: "", sub: [])]
                case "separate-pages": return order == .oldest ? (page == 0 ? [second] : [first]) : (page == 0 ? [first] : [second])
                default: return page == 0 ? (order == .oldest ? [second, first] : [first, second]) : []
                }
            }
            let identity = { CommunitySessionIdentity(accountIdentifier: "ordering") }
            let operations: [() async throws -> Void] = [
                { _ = try await NetworkSmokePaging.commentPage(for: object, order: order, currentIdentity: identity, load: load) },
                { _ = try await NetworkSmokePaging.commentBatch(for: object, order: order, currentIdentity: identity) { page in
                    let items = try await load(page)
                    return .init(items: items, nextSourcePage: page + 1, canLoadMore: page == 0 && !items.isEmpty)
                } }
            ]
            for operation in operations {
                if ["distinct", "continued"].contains(sample) || sample == "cross-page" && order == .like { try await operation() }
                else { await #expect(throws: Error.self) { try await operation() } }
            }
        }
    }

    @Test func pendingSmokeRequestRequiresSuccessfulConsumption() throws {
        let files = PreferenceMemoryFiles()
        let url = files.temporaryDirectoryURL.appending(path: "network-smoke-request.json")
        let data = Data(#"{"scope":"bit101","runID":"fixture","capture":"none"}"#.utf8)
        try files.writeData(data, to: url, options: [.atomic])
        files.setFailures(removal: true)
        #expect(throws: (any Error).self) { try ReleaseNetworkSmokeLaunchRequest.readPendingFile(files: files, at: url) }
        #expect(try files.readData(at: url) == data)
        files.setFailures()
        #expect(try ReleaseNetworkSmokeLaunchRequest.readPendingFile(files: files, at: url).runID == "fixture")
        #expect(!files.fileExists(at: url))
        #expect(throws: (any Error).self) { try ReleaseNetworkSmokeLaunchRequest.readPendingFile(files: files, at: url) }
        try files.writeData(Data("invalid-json".utf8), to: url, options: [.atomic])
        #expect(throws: DecodingError.self) { try ReleaseNetworkSmokeLaunchRequest.readPendingFile(files: files, at: url) }
        #expect(try files.readData(at: url) == Data("invalid-json".utf8))
    }

    @Test func imageProbeCollectsDistinctVariantsAcrossTheSampledList() {
        let empty = CommunityImage(mid: "empty", url: "", lowUrl: "")
        let image = CommunityImage(mid: "image", url: "https://image.invalid/full", lowUrl: "https://image.invalid/low")
        #expect(NetworkSmokePaging.imageURLs(in: [empty, image, image]) == [image.url, image.lowUrl])
        #expect(NetworkSmokePaging.imageURLs(in: [empty]).isEmpty)
        #expect(NetworkSmokePaging.imageURLs(in: [CommunityImage(mid: "full", url: image.url, lowUrl: "")]) == [image.url])
    }

    @Test func articleUnknownBlocksKeepTheirPositionAndOfferTheOriginal() {
        let raw = #"{"blocks":[{"id":"first","type":"paragraph","data":{"text":"正文"}},{"id":"future","type":"table","data":{"content":[["单元格"]]}},{"id":"last","type":"paragraph","data":{"text":"末段"}}]}"#
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.map(\.id) == ["first", "future", "last"])
        if case .requiresOriginal = blocks[1] {} else { Issue.record("Extended content should keep an original-reading placeholder") }
        #expect(PaperEditorContentBuilder.canEditAsPlainText(raw) == false)
    }

    @Test(arguments: ["body", "blocks", "block"])
    func articleResourceBudgetsStopBeforeRichTextImport(kind: String) throws {
        let raw: String
        switch kind {
        case "body": raw = String(repeating: "x", count: PaperContentResourceLimits.maximumBodyBytes + 1)
        case "blocks":
            let block: [String: Any] = ["type": "paragraph", "data": ["text": "text"]]
            raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": Array(repeating: block,
                count: PaperContentResourceLimits.maximumBlocks + 1)]), as: UTF8.self)
        default:
            raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": [["type": "paragraph",
                "data": ["text": String(repeating: "x", count: PaperContentResourceLimits.maximumBlockBytes + 1)]]]]), as: UTF8.self)
        }
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.count == 1)
        if case .requiresOriginal = blocks[0] {} else { Issue.record("Oversized content should offer original reading") }
    }

    private func user(_ id: Int) -> CommunityUser {
        .init(id: id, createTime: "", nickname: "fixture", avatar: .init(mid: "", url: "", lowUrl: ""), motto: "",
            identity: .init(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
    }

    @Test(.timeLimit(.minutes(1))) func pageFailureAndFilteredSourceCursorRemainPartOfTheProbe() async throws {
        var pages: [Int] = []
        await #expect(throws: URLError.self) {
            _ = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                if page == 1 { throw URLError(.timedOut) }
                return [user(1)]
            }
        }
        #expect(pages == [0, 1])
        pages = []
        let first: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
            pages.append(page)
            return .init(items: [], nextSourcePage: page == 0 ? 4 : 5, canLoadMore: page == 0, sourceIDs: [page + 1])
        }
        #expect(first.items.isEmpty && pages == [0, 4])
        pages = []
        let populated: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(requiresContent: true, currentIdentity: smokeIdentity) { page in
            pages.append(page)
            return .init(items: page == 8 ? [user(1)] : [], nextSourcePage: page + 4, canLoadMore: true, sourceIDs: [page + 1])
        }
        #expect(populated.items.map(\.id) == [1] && pages == [0, 4, 8])
        await #expect(throws: URLError.self) {
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                .init(items: [user(1)], nextSourcePage: 1, canLoadMore: true)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func repeatedPagesFailAndPartialOverlapOrTerminalPagesAdvance() async throws {
        for repeated in [true, false] {
            var pages: [Int] = []
            await #expect(throws: URLError.self) {
                _ = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                    pages.append(page)
                    return [user(repeated || page == 0 ? 1 : 0)]
                }
            }
            #expect(pages == (repeated ? [0, 1, 2, 3, 4] : [0, 1]))
            pages = []
            await #expect(throws: URLError.self) {
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                    pages.append(page)
                    return .init(items: [], nextSourcePage: page + 1, canLoadMore: true,
                        sourceIDs: [repeated || page == 0 ? 1 : 0])
                }
            }
            #expect(pages == (repeated ? [0, 1, 2, 3, 4] : [0, 1]))
        }
        for terminal in [false, true] {
            var pages: [Int] = []
            _ = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                return page == 0 ? [user(1), user(2)] : terminal ? [] : [user(2), user(3)]
            }
            #expect(pages == [0, 1])
            pages = []
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                return .init(items: [], nextSourcePage: page + 1, canLoadMore: page == 0,
                    sourceIDs: page == 0 ? [1, 2] : terminal ? [] : [2, 3])
            }
            #expect(pages == [0, 1])
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func missingMaintenanceSamplesStopAtTheScanBudget(pageBudget: Bool) async throws {
        var calls = 0
        await #expect(throws: NetworkSmokePaging.SamplingError.self) {
            let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(matchingID: Int.max, currentIdentity: smokeIdentity) { page in
                calls += 1
                return pageBudget ? [user(page + 1)] : page == 0
                    ? (1...NetworkSmokePaging.maximumSampleItems).map(user) : [user(NetworkSmokePaging.maximumSampleItems + 1)]
            }
        }
        #expect(calls == (pageBudget ? NetworkSmokePaging.maximumSamplePages : 2))
    }

    @Test(.timeLimit(.minutes(1))) func temporaryRepeatedPagesRecoverAndSampleContinuationImages() async throws {
        for repeated in [1, 3] {
            var pages: [Int] = []
            let values = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                return [user(page <= repeated ? 1 : 2)]
            }
            #expect(values.map(\.id) == [1, 2] && pages == Array(0...(repeated + 1)))
            pages = []
            let sample: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                let id = page <= repeated ? 1 : 2
                let value = CommunityUser(id: id, createTime: "", nickname: "fixture",
                    avatar: .init(mid: "image", url: id == 2 ? "https://image.invalid/continuation" : "", lowUrl: ""), motto: "",
                    identity: .init(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
                return .init(items: [value], nextSourcePage: page + 1, canLoadMore: true, sourceIDs: [id])
            }
            #expect(sample.items.map(\.id) == [1, 2] && pages == Array(0...(repeated + 1)))
            #expect(sample.sourceIDs == [1, 2] && sample.nextSourcePage == repeated + 2)
            #expect(NetworkSmokePaging.imageURLs(in: sample.items.map(\.avatar)) == ["https://image.invalid/continuation"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func terminalPagesExerciseContinuationAndMessagesUseTheirActualCursor() async throws {
        var pages: [Int] = []
        let empty: [CommunityUser] = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in pages.append(page); return [] }
        #expect(empty.isEmpty && pages == [0, 1])
        pages = []
        await #expect(throws: URLError.self) {
            let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                return page == 0 ? [] : [user(1)]
            }
        }
        #expect(pages == [0, 1])
        pages = []
        await #expect(throws: URLError.self) {
            let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(currentIdentity: smokeIdentity) { page in
                pages.append(page)
                return .init(items: page == 0 ? [] : [user(1)], nextSourcePage: page + 1, canLoadMore: false, sourceIDs: page == 0 ? [] : [1])
            }
        }
        #expect(pages == [0, 1])
        await #expect(throws: URLError.self) {
            let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(requiresContent: true, currentIdentity: smokeIdentity) { _ in [] }
        }
        let data = Data(#"{"from_user":{},"id":9,"link_obj":"poster1","obj":"poster1","text":"","update_time":""}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(GalleryMessage.self, from: data)
        var cursors: [Int?] = []
        let history = try decoder.decode(GalleryMessage.self, from: Data(#"{"from_user":{},"id":8,"link_obj":"poster1","obj":"poster1","text":"","update_time":""}"#.utf8))
        _ = try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in cursors.append(cursor); return cursor == Int.max ? [message] : [history] }
        #expect(cursors == [Int.max, 9])
        await #expect(throws: NetworkSmokePaging.SamplingError.self) { _ = try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in cursor == Int.max ? [message] : [] } }
        cursors = []
        await #expect(throws: NetworkSmokePaging.SamplingError.self) {
            _ = try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in cursors.append(cursor); return [] }
        }
        #expect(cursors == [Int.max])
        await #expect(throws: URLError.self) {
            _ = try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { _ in [message] }
        }
    }

    @Test func briefAndDetailedScoresKeepTheSameCourseIdentityAndGrade() throws {
        let headers = ["序号", "课程编号", "课程名称", "成绩", "开课学期", "学分"]
        let first = ScoreRow(index: 0, headers: headers, values: ["1", "CS101", "课程", "90", "2025", "2"])
        let detailed = ScoreRow(index: 1, headers: headers + ["平均分"], values: ["2", "CS101", "课程", "90", "2025", "2", "80"])
        try NetworkSmokePaging.checkScores(brief: [first], detailed: [detailed])
        #expect(throws: NetworkSmokePaging.SamplingError.self) { try NetworkSmokePaging.checkScores(brief: [], detailed: []) }
        for values in [["1", " ", "课程", "", "2025", "2"], ["1", "CS101", " ", "", "2025", "2"]] {
            let emptyIdentity = ScoreRow(index: 0, headers: headers, values: values)
            #expect(throws: URLError.self) { try NetworkSmokePaging.checkScores(brief: [emptyIdentity], detailed: [emptyIdentity]) }
        }
        for values in [["2", "CS102", "课程", "90", "2025", "2"], ["2", "CS101", "课程", "80", "2025", "2"]] {
            #expect(throws: URLError.self) { try NetworkSmokePaging.checkScores(brief: [first], detailed: [ScoreRow(index: 0, headers: headers, values: values)]) }
        }
        #expect(throws: URLError.self) { try NetworkSmokePaging.checkScores(brief: [first], detailed: []) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func messageSamplingPreservesUnreadCountsAsNewMessagesArrive(emptyFirstPage: Bool) async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(GalleryMessage.self,
            from: Data(#"{"from_user":{},"id":9,"link_obj":"poster1","obj":"poster1","text":"","update_time":""}"#.utf8))
        var messages: [GalleryMessage] = emptyFirstPage ? [] : [message]
        var unread = 3
        var requests = 0
        let read = { try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in
            requests += 1
            if emptyFirstPage && requests == 2 { messages = [message]; unread += 1 }
            let rows = messages.filter { cursor == nil || cursor == 0 || $0.id < (cursor ?? 0) }
            if (cursor == nil || cursor == 0) && !rows.isEmpty { unread = 0 }
            return rows
        } }
        if emptyFirstPage { await #expect(throws: NetworkSmokePaging.SamplingError.self) { try await read() } }
        else { await #expect(throws: NetworkSmokePaging.SamplingError.self) { try await read() } }
        #expect(requests == (emptyFirstPage ? 1 : 2) && unread == 3)
    }

    @Test(.timeLimit(.minutes(1))) func messageSmokeUsesTheProductionCursorAndRejectsUnorderedPages() async throws {
        func messages(_ ids: [Int]) throws -> [GalleryMessage] {
            let rows = ids.map { ["fromUser": [:], "id": $0, "linkObj": "", "obj": "", "text": "", "updateTime": ""] as [String: Any] }
            return try JSONDecoder().decode([GalleryMessage].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        for (first, second, valid) in [([9, 8], [7, 6], true), ([9, 8, 8], [7], false), ([8, 9], [7], false),
                                     ([9, 0], [], false), ([9, 8], [6, 7], false), ([9, 8], [7, 7], false), ([9, 8], [8], false)] {
            let firstPage = try messages(first), secondPage = try messages(second)
            var requested: [Int?] = [], page = GalleryMessageListState()
            page.applyFirstCursorPage(firstPage)
            let operation = { try await NetworkSmokePaging.messages(currentIdentity: smokeIdentity) { cursor in requested.append(cursor); return cursor == Int.max ? firstPage : secondPage } }
            if valid { _ = try await operation(); #expect(requested == [Int.max, page.nextCursor]) }
            else { await #expect(throws: URLError.self) { try await operation() } }
        }
    }

    private final class MediaRoute: HTTPTransport {
        var calls: [(String, String)] = []
        var referenced: [[String]] = []
        var brokenReference = false
        var failUpload = false
        var onUpload: (() -> Void)?
        private var image: [String: Any] { ["mid": "uploaded", "url": "https://example.invalid/image.jpg", "low_url": ""] }
        private var user: [String: Any] {
            ["id": 1, "create_time": "", "nickname": "fixture", "avatar": image, "motto": "",
                "identity": ["id": 1, "color": "", "text": "", "create_time": "", "update_time": ""]]
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let method = request.httpMethod ?? "GET"
            calls.append((url.path, method))
            let result: [String: Any]
            if url.path == "/upload/image" {
                if failUpload { throw URLError(.networkConnectionLost) }
                #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
                let body = try #require(request.httpBody)
                #expect(body.range(of: Data([0xFF, 0xD8])) != nil)
                result = image
                onUpload?()
            } else if method == "POST" {
                let body = try #require(request.httpBody)
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                referenced.append(try #require(payload["image_mids"] as? [String]))
                if url.path == "/posters" { result = ["id": 9] }
                else {
                    result = ["id": 10, "obj": "poster9", "images": [image], "user": user, "anonymous": false,
                        "create_time": "", "update_time": "", "like": false, "like_num": 0, "comment_num": 0,
                        "own": true, "rate": 0, "reply_user": user, "reply_obj": "", "text": "fixture", "sub": []]
                }
            } else {
                result = ["id": 9, "title": "fixture", "text": "fixture", "anonymous": false, "claim": ["id": 0, "text": ""],
                    "comment_num": 0, "create_time": "", "edit_time": "", "images": brokenReference ? [] : [image],
                    "like": false, "like_num": 0, "own": true, "plugins": "[]", "public": false, "tags": [],
                    "update_time": "", "user": user]
            }
            return (try JSONSerialization.data(withJSONObject: result),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1))) func productionWritesUploadJPEGAndVerifyServerImageReferences() async throws {
        let route = MediaRoute()
        let session = CommunitySession(httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        let gallery = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        var operations = CommunityWriteSmoke.Operations.production(gallery: gallery)
        var uploads: [String] = []
        #expect(try await operations.create(.poster, "fixture", { uploads.append($0) }, {}) == 9)
        #expect(try await operations.comment(.init(kind: .poster, object: "poster9"), "fixture", { uploads.append($0) }, {}).images.map(\.mid) == ["uploaded"])
        #expect(uploads == ["uploaded", "uploaded"])
        let imageData = try CommunityWriteMedia.jpeg()
        #expect(imageData == (try CommunityWriteMedia.jpeg()) && UIImage(data: imageData)?.size == CGSize(width: 1, height: 1))
        #expect(route.referenced == [["uploaded"], ["uploaded"]])
        #expect(route.calls.filter { $0.0 == "/upload/image" }.count == 2)
        route.brokenReference = true
        let created = try await operations.create(.poster, "fixture", { _ in }, {})
        #expect(try await operations.read(.poster, created)?.imageMids != ["uploaded"])
        let writes = route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count
        for comment in [false, true] {
            await #expect(throws: CocoaError.self) {
                let record: CommunityWriteSmoke.Operations.RecordImage = { _ in throw CocoaError(.fileWriteNoPermission) }
                if comment { _ = try await operations.comment(.init(kind: .poster, object: "poster9"), "fixture", record, {}) }
                else { _ = try await operations.create(.poster, "fixture", record, {}) }
            }
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
        route.failUpload = true
        for comment in [false, true] {
            await #expect(throws: (any Error).self) {
                let submit: CommunityWriteSmoke.Operations.RecordSubmission = { Issue.record("图片上传完成后记录业务提交") }
                if comment { _ = try await operations.comment(.init(kind: .poster, object: "poster9"), "fixture", { _ in }, submit) }
                else { _ = try await operations.create(.poster, "fixture", { _ in }, submit) }
            }
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
        route.failUpload = false
        var identity = CommunitySessionIdentity(accountIdentifier: "fixture")
        operations.identity = { identity }
        let scoped = operations.scoped(to: identity)
        route.onUpload = { identity = .init(accountIdentifier: "other") }
        await #expect(throws: CancellationError.self) {
            _ = try await scoped.create(.poster, "fixture", { _ in Issue.record("上传完成后沿账号归属保存资源") }, {})
        }
        #expect(route.calls.filter { $0.1 == "POST" && $0.0 != "/upload/image" }.count == writes)
    }
}
#endif
