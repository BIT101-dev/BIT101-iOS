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
    final class ProfilePosterRoute: HTTPTransport {
        var queries: [[String: String]] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(url.path == "/posters" && request.httpMethod == "GET")
            let items = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            queries.append(
                Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }))
            return (
                Data("[]".utf8),
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1))) func profileSmokeAndUseFixedCommunityPrefs() async throws {
        let route = ProfilePosterRoute()
        let session = CommunitySession(
            httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture")
            }, refresh: { _ in })
        let ordinary = MineService(
            session: session,
            preferences: {
                .init(
                    hideBots: true, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        _ = try await ordinary.fetchMyPosters(page: 0)
        let mine = ReleaseNetworkSmokeDependencies.mineService(session: session)
        _ = try await mine.fetchMyPosters(page: 0)
        _ = try await mine.fetchUserPosters(userID: 42, page: 1)
        let operations = CommunityWriteSmoke.Operations.production(mine: mine)
        #expect(try await operations.find(.poster, "功能验收") == [])
        #expect(
            route.queries == [
                ["mode": "search", "uid": "0", "page": "0", "hide_bot": "true"],
                ["mode": "search", "uid": "0", "page": "0"],
                ["mode": "search", "uid": "42", "page": "1"],
                ["mode": "search", "uid": "0", "page": "0"],
            ])
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "empty", "single", "equal", "separate-pages", "distinct", "reversed", "cross-page",
            "continued",
        ])
    func posterSortingRequiresValidDistinctResponse(sample: String) async throws {
        func poster(_ id: Int, likes: Int, date: String) -> CommunityPoster {
            CommunityPoster(
                anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0,
                createTime: date, editTime: "", id: id, images: [], likeNum: likes,
                public: true,
                tags: [], text: "", title: "", updateTime: "", user: user(1))
        }
        let first = poster(1, likes: 2, date: "2026-01-02T00:00:00Z")
        let second = poster(
            2, likes: sample == "equal" ? 2 : 1,
            date: sample == "equal" ? first.createTime : "2026-01-01T00:00:00Z")
        let third = poster(
            3, likes: sample == "cross-page" ? 3 : 0,
            date: sample == "cross-page" ? "2026-01-03T00:00:00Z" : "2025-12-31T00:00:00Z")
        for order in [GallerySearchOrder.like, .newest] {
            let load: (Int) async throws -> GalleryPageBatch<CommunityPoster> = { page in
                let items: [CommunityPoster]
                switch sample {
                case "empty": items = []
                case "single": items = page == 0 ? [first] : []
                case "separate-pages": items = page == 0 ? [first] : [second]
                case "cross-page", "continued":
                    items = page == 0 ? [first, second] : [third]
                case "reversed": items = page == 0 ? [second, first] : []
                default: items = page == 0 ? [first, second] : []
                }
                return .init(
                    items: items, nextSourcePage: page + 1, canLoadMore: !items.isEmpty)
            }
            if ["distinct", "continued"].contains(sample)
                || sample == "cross-page" && order == .like
            {
                #expect(
                    try await NetworkSmokePaging.posterPage(
                        order: order, requiresOrderingEvidence: true,
                        currentIdentity: { .init(accountIdentifier: "poster-ordering") },
                        load: load
                    ).items.count == (sample == "distinct" ? 2 : 3))
            } else {
                await #expect(throws: Error.self) {
                    try await NetworkSmokePaging.posterPage(
                        order: order, requiresOrderingEvidence: true,
                        currentIdentity: { .init(accountIdentifier: "poster-ordering") },
                        load: load)
                }
            }
        }
    }

    @Test func courseHistorySmokeRequiresUsableStatistics() throws {
        let valid = CourseHistoryGrade(
            term: "2026-2027-1", avgScore: 85, maxScore: 100, studentNum: 30)
        try NetworkSmokePaging.checkCourseHistories([valid])
        for grades in [
            [], [valid, valid],
            [.init(term: "term", avgScore: nil, maxScore: nil, studentNum: nil)],
            [.init(term: "term", avgScore: -.infinity, maxScore: 100, studentNum: 30)],
            [.init(term: "term", avgScore: 85, maxScore: 101, studentNum: 30)],
            [.init(term: "term", avgScore: 85, maxScore: 100, studentNum: -1)],
        ] {
            #expect(throws: Error.self) { try NetworkSmokePaging.checkCourseHistories(grades) }
        }
    }

    @Test func courseWeekSmokeChecksLiteralFiveWeekSource() throws {
        func course(_ id: String, name: String, weeks: [Int]) -> CourseRecord {
            CourseRecord(
                id: id, term: "2026-2027-1", name: name, teacher: "", classroom: "",
                description: "1-5周 星期一", weeks: weeks, weekday: 1, startSection: 1,
                endSection: 2,
                campus: "", number: id, credit: 0, hour: 0, type: "", category: "",
                department: "")
        }
        func payload(_ weeks: [Int]) -> CourseSyncPayload {
            let courses = [
                course("literal", name: "课程一", weeks: weeks),
                course("independent", name: "课程二", weeks: weeks),
            ]
            return CourseSyncPayload(
                term: "2026-2027-1", firstDayString: "2026-09-21",
                sourceFirstDayString: "2026-08-31",
                normalizationOffset: 3, rawWeeksByCourse: [[4, 5, 6, 7, 8], [4, 5, 6, 7, 8]],
                sourceDisplayWeeksByCourse: ["1-5周 星期一", "1-5周 星期一"],
                courses: courses, exams: [])
        }
        try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload([1, 2, 3, 4, 5]))
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload([1, 2, 3, 4]))
        }
    }

    @Test func runIdsMatchEntrypoints() throws {
        for (identifier, accepted) in [
            ("fixture-123-ABC", true), (String(repeating: "a", count: 128), true),
            ("a.b", false), ("运行", false), ("a b", false), ("fixture_1", false),
            (String(repeating: "a", count: 129), false),
        ] {
            var components = try #require(
                URLComponents(string: "bit101://network-smoke/bit101"))
            components.queryItems = [.init(name: "run", value: identifier)]
            #expect(
                (ReleaseNetworkSmokeLaunchRequest(url: try #require(components.url)) != nil)
                    == accepted)
            #expect(
                (ReleaseNetworkSmokeLaunchRequest(
                    scope: .bit101,
                    environment: ["BIT101_VALIDATION_RUN_ID": identifier]) != nil) == accepted)
            let data = try JSONSerialization.data(withJSONObject: [
                "scope": "bit101", "capture": "none", "runID": identifier,
            ])
            if accepted {
                #expect(
                    try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self, from: data)
                        .runID == identifier)
            } else {
                #expect(throws: DecodingError.self) {
                    try JSONDecoder().decode(ReleaseNetworkSmokeLaunchRequest.self, from: data)
                }
            }
        }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "empty", "single", "equal", "separate-pages", "distinct", "cross-page", "continued",
        ])
    func sortingProbesRequireResponse(sample: String) async throws {
        let first = PaperSummary(
            id: 1, title: "", intro: "", likeNum: 2, commentNum: 2,
            updateTime: "2026-01-02T00:00:00Z")
        let second = PaperSummary(
            id: 2, title: "", intro: "", likeNum: sample == "equal" ? 2 : 1,
            commentNum: sample == "equal" ? 2 : 1,
            updateTime: sample == "equal" ? first.updateTime : "2026-01-01T00:00:00Z")
        let third = PaperSummary(
            id: 3, title: "", intro: "",
            likeNum: sample == "cross-page" ? 3 : 0,
            commentNum: sample == "cross-page" ? 3 : 0,
            updateTime: sample == "cross-page"
                ? "2026-01-03T00:00:00Z" : "2025-12-31T00:00:00Z")
        for order in PaperSortOrder.allCases {
            let load: (Int) async throws -> [PaperSummary] = { page in
                switch sample {
                case "empty": return []
                case "single": return page == 0 ? [first] : []
                case "cross-page", "continued":
                    return page == 0 ? [first, second] : [third]
                case "separate-pages": return page == 0 ? [first] : [second]
                default: return page == 0 ? [first, second] : []
                }
            }
            if ["distinct", "continued", "cross-page"].contains(sample)
                || sample == "equal" && order == .newest
            {
                #expect(
                    try await NetworkSmokePaging.paperPage(
                        order: order, requiresOrderingEvidence: true,
                        currentIdentity: { .init(accountIdentifier: "ordering") }, load: load
                    ).count == (["distinct", "equal"].contains(sample) ? 2 : 3))
            } else {
                await #expect(throws: Error.self) {
                    try await NetworkSmokePaging.paperPage(
                        order: order, requiresOrderingEvidence: true,
                        currentIdentity: { .init(accountIdentifier: "ordering") }, load: load)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func eclassRequestEvidenceKeepsSelection(filtered: Bool) throws {
        let url = AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "page": 1, "page_size": 100, "fields": "id,name",
            "conditions": filtered ? ["token": "secret"] : [:],
        ])
        var final = request
        final.httpBody = Data(#"{"page":2,"page_size":101,"fields":"id","conditions":{}}"#.utf8)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(
            request: request, response: response, finalRequest: final)
        #expect(evidence.query["page_size"] == "100" && evidence.query["fields"] == "id,name")
        #expect(evidence.query["conditions"] == (filtered ? "[REDACTED]" : "{}"))
        #expect(
            evidence.finalQuery["page_size"] == "101" && evidence.finalQuery["fields"] == "id")
        #expect(evidence.finalQuery["conditions"] == "{}")
        #expect(
            !String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains(
                "secret"))
    }

    @Test(arguments: ["false", "true", "0", "null", "\"false\""])
    func scoreRequestEvidencePreservesBooleanTypes(value: String) throws {
        for (field, path) in [("detail", "bit101/score"), ("detailed", "cjd/cookies")] {
            let url = AppURL.required("https://login.bit101.flwfdd.xyz/api/jwb/" + path)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(
                """
                {\"\(field)\":\(value),\"username\":\"secret-account\",\"password\":\"secre\
                t-password\"}
                """
                .utf8)
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
            #expect(
                evidence.query[field]
                    == (["false", "true"].contains(value) ? value : "[REDACTED]"))
            #expect(evidence.finalQuery[field] == evidence.query[field])
            #expect(
                !String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains(
                    "secret-"))
        }
    }

    func smokeIdentity() -> CommunitySessionIdentity {
        .init(accountIdentifier: "fixture")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["array", "batch", "messages"], [false, true])
    func pagingUsesItsInjectedSessionAcrossPages(kind: String, switchesAccount: Bool)
        async throws
    {
        var identity = smokeIdentity()
        var calls = 0
        func advance() {
            calls += 1
            if switchesAccount && calls == 2 { identity = .init(accountIdentifier: "other") }
        }
        let operation: () async throws -> Void = {
            switch kind {
            case "array":
                let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(
                    currentIdentity: { identity }) { page in
                        advance()
                        return [user(page + 1)]
                    }
            case "batch":
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(
                    currentIdentity: { identity }) { page in
                        advance()
                        return .init(
                            items: [user(page + 1)], nextSourcePage: page + 1,
                            canLoadMore: page == 0, sourceIDs: [page + 1])
                    }
            default:
                _ = try await NetworkSmokePaging.messages(currentIdentity: { identity }) {
                    cursor in
                    advance()
                    return try JSONDecoder().decode(
                        [GalleryMessage].self,
                        from: Data(
                            """
                            [{\"fromUser\":{},\"id\":\(cursor == Int.max ? 9 : 8),\"linkObj\
                            \":\"\",\"obj\":\"\",\"text\":\"\",\"updateTime\":\"\"}]
                            """
                            .utf8))
                }
            }
        }
        if switchesAccount {
            await #expect(throws: CancellationError.self) { try await operation() }
        } else {
            try await operation()
        }
        #expect(calls == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["array", "batch"], [0, 1])
    func pagingRejectsDuplicateRowsBeforeMerging(kind: String, duplicatePage: Int) async throws {
        await #expect(throws: URLError.self) {
            if kind == "array" {
                let _: [CommunityUser] = try await NetworkSmokePaging.arrayPage(
                    currentIdentity: smokeIdentity
                ) { page in
                    page == duplicatePage ? [user(page + 1), user(page + 1)] : [user(page + 1)]
                }
            } else {
                let _: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(
                    currentIdentity: smokeIdentity
                ) { page in
                    let rows =
                        page == duplicatePage
                        ? [user(page + 1), user(page + 1)] : [user(page + 1)]
                    return .init(items: rows, nextSourcePage: page + 1, canLoadMore: page == 0)
                }
            }
        }
        let batch: GalleryPageBatch<CommunityUser> = try await NetworkSmokePaging.batch(
            currentIdentity: smokeIdentity
        ) { page in
            .init(
                items: [user(page == 0 ? 1 : 2)], nextSourcePage: page == 0 ? 2 : page + 1,
                canLoadMore: page == 0, sourceIDs: page == 0 ? [1, 1] : [1, 2])
        }
        #expect(batch.items.map(\.id) == [1, 2])
    }

    @Test(
        .serialized, .timeLimit(.minutes(1)),
        arguments: ["provisional", "navigation", "process"])
    func galleryWebFailuresRenderTheRetryDocument(path: String) async throws {
        let coordinator = GalleryWebCoordinator(
            credentials: .init(cookie: { "fixture" }, changes: Empty().eraseToAnyPublisher()),
            openExternal: { _ in })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        switch path {
        case "provisional":
            coordinator.webView(
                webView, didFailProvisionalNavigation: nil,
                withError: URLError(.notConnectedToInternet))
        case "navigation":
            coordinator.webView(
                webView, didFail: nil, withError: URLError(.networkConnectionLost))
        default: coordinator.webViewWebContentProcessDidTerminate(webView)
        }
        var text = ""
        let deadline = Date.now.addingTimeInterval(5)
        repeat {
            text =
                try await webView.evaluateJavaScript("document.body?.innerText ?? ''")
                as? String ?? ""
            if text.contains("重新加载") { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date.now < deadline
        #expect(text.contains("话廊网页加载失败") && text.contains("重新加载"))
        #expect(
            try await webView.evaluateJavaScript("document.querySelector('a')?.href") as? String
                == "https://bit101.cn/gallery")
    }
    final class CredentialWebView: WKWebView {
        var reloads = 0
        var initialRequest: URLRequest?
        override func load(_ request: URLRequest) -> WKNavigation? {
            initialRequest = request
            let html = #"<script>localStorage.store='{"other":"retained"}'</script>"#
            return loadHTMLString(html, baseURL: request.url)
        }
        override func reload() -> WKNavigation? {
            reloads += 1
            return loadHTMLString(
                "<body>fixture</body>", baseURL: AppURL.required("https://bit101.cn/gallery"))
        }
    }
    @Test(.timeLimit(.minutes(1))) func galleryWebCredentialsChanges() async throws {
        var cookie = "account-a\"\\\n"
        let changes = PassthroughSubject<Void, Never>()
        let coordinator = GalleryWebCoordinator(
            credentials: .init(cookie: { cookie }, changes: changes.eraseToAnyPublisher()),
            openExternal: { _ in })
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
            var actual = ""
            var other = ""
            repeat {
                actual =
                    (try? await webView.evaluateJavaScript(
                        "JSON.parse(localStorage.getItem('store') || '{}').fake_cookie"))
                    as? String ?? "missing"
                other =
                    (try? await webView.evaluateJavaScript(
                        "JSON.parse(localStorage.getItem('store') || '{}').other")) as? String
                    ?? ""
                if actual == cookie && other == "retained" && webView.reloads == index + 1
                    && !webView.isLoading
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            } while Date.now < deadline
            #expect(actual == cookie && other == "retained" && webView.reloads == index + 1)
        }
        coordinator.synchronizeCredentials(in: webView)
        _ = try await webView.evaluateJavaScript("true")
        await Task.yield()
        #expect(webView.reloads == 3)
    }

    final class BotFeed: GalleryFeedServicing {
        var pages: [Int] = []
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            pages.append(startPage)
            return .init(
                items: [], nextSourcePage: startPage + 5, canLoadMore: startPage < 10,
                sourceIDs: [startPage + 1])
        }
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<
            CommunityPoster
        > { throw URLError(.unsupportedURL) }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<
            CommunityPoster
        > { throw URLError(.unsupportedURL) }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws
            -> GalleryPageBatch<CommunityPoster>
        { throw URLError(.unsupportedURL) }
    }

    @Test(.timeLimit(.minutes(1))) func emptyBotBatchesContinueTheirSourceCursor() async {
        let service = BotFeed()
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .bot)
        #expect(
            service.pages == [0] && model.state(for: .bot).nextPage == 5
                && model.state(for: .bot).canLoadMore)
        await model.enqueueLoadMore(for: .bot, currentPoster: nil).value
        #expect(
            service.pages == [0, 5] && model.state(for: .bot).nextPage == 10
                && !model.state(for: .bot).isLoadingMore)
        await model.enqueueLoadMore(for: .bot, currentPoster: nil).value
        #expect(
            service.pages == [0, 5, 10] && model.state(for: .bot).nextPage == 15
                && !model.state(for: .bot).canLoadMore)
    }

    final class SelectorTransport: HTTPTransport {
        var body = Data()
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (
                body,
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["complete", "missing", "wrong", "empty", "malformed"])
    func eclassSmokeBindsRequest(stage: String) async throws {
        let transport = SelectorTransport()
        transport.body = Data(
            (stage == "malformed"
                ? "{}"
                : stage == "empty" ? #"{"courses":[]}"# : #"{"courses":[{"id":41},{"id":43}]}"#)
                .utf8)
        let client = HTTPClient(transport: transport, observer: nil)
        let collector = NetworkSmokeRequestCollector()
        let courseIDs: [Int]
        switch stage {
        case "empty": courseIDs = []
        case "missing": courseIDs = [41]
        case "wrong": courseIDs = [41, 45]
        default: courseIDs = [41, 43]
        }
        let operation = {
            var list = URLRequest(
                url: AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses"))
            list.httpMethod = "POST"
            list.setValue("application/json", forHTTPHeaderField: "Content-Type")
            list.httpBody = Data(
                #"{"page":1,"page_size":100,"fields":"id,name","conditions":{}}"#.utf8)
            _ = try await client.send(list)
            for id in courseIDs {
                _ = try await client.send(
                    URLRequest(
                        url: AppURL.required(
                            "https://zy-eclass.bit.edu.cn/api/courses/\(id)/activities")))
            }
        }
        if stage == "complete" || stage == "empty" {
            try await collector.perform(operation, required: true)
        } else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(operation, required: true)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["0", "99"], [false, true])
    func requestEvidenceRejectsAmbiguousParameters(value: String, redirected: Bool) async throws {
        let url = AppURL.required("https://bit101.flwfdd.xyz/papers?page=0")
        let duplicate = AppURL.required(url.absoluteString + "&page=\(value)")
        let request = URLRequest(url: redirected ? url : duplicate)
        let finalRequest = URLRequest(url: duplicate)
        let response = try #require(
            HTTPURLResponse(
                url: duplicate, statusCode: 200, httpVersion: nil, headerFields: nil))
        let collector = NetworkSmokeRequestCollector()
        await #expect(throws: NetworkSmokeRequestError.self) {
            try await collector.perform(
                {
                    await HTTPRequestEvidenceContext.didReceive?(
                        request,
                        HTTPResponse(
                            data: Data(), response: response, finalRequest: finalRequest))
                }, required: true)
        }
        #expect(collector.requests.count == 1 && HTTPRequestEvidenceContext.didReceive == nil)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["complete", "missing", "wrong-source", "wrong-query", "extra"])
    func imageSmokeBindsEverySelectedResource(stage: String) async throws {
        let urls = [
            "https://cdn.example.invalid/image.png?token=first",
            "https://cdn.example.invalid/other.png",
        ]
        let selected =
            stage == "missing"
            ? [urls[0]]
            : stage == "wrong-source"
                ? [urls[0], "https://other.example.invalid/image.png"]
                : stage == "wrong-query"
                    ? [urls[0].replacingOccurrences(of: "first", with: "second"), urls[1]]
                    : stage == "extra" ? urls + ["https://cdn.example.invalid/extra.png"] : urls
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        let collector = NetworkSmokeRequestCollector()
        let operation = {
            for url in selected {
                _ = try await client.send(URLRequest(url: AppURL.required(url)))
            }
        }
        if stage == "complete" {
            try await collector.perform(
                operation, required: true,
                expectedParameters: NetworkSmokePaging.imageResourceParameters(urls))
        } else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(
                    operation, required: true,
                    expectedParameters: NetworkSmokePaging.imageResourceParameters(urls))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["correct", "wrong", "missing"])
    func buildingSmokeKeepsItsSelectedCampus(selection: String) async throws {
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        let base =
            "https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do"
        let request = URLRequest(
            url: AppURL.required(
                base
                    + (selection == "missing"
                        ? "" : "?XXXQDM=" + (selection == "correct" ? "campus" : "other"))))
        let collector = NetworkSmokeRequestCollector()
        let operation = { try await client.send(request) }
        if selection == "correct" {
            _ = try await collector.perform(
                operation, required: true, expectedParameters: ["XXXQDM": "campus"])
        } else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(
                    operation, required: true, expectedParameters: ["XXXQDM": "campus"])
            }
        }
        let building = BuildingRecord(
            id: "building", name: "", buildingCode: "building", campusName: "",
            campusCode: selection == "correct" ? "campus" : "other")
        if selection == "correct" {
            try NetworkSmokePaging.checkBuildings([building], campusCode: "campus")
        } else {
            #expect(throws: URLError.self) {
                try NetworkSmokePaging.checkBuildings([building], campusCode: "campus")
            }
        }
    }

    @Test(arguments: [
        "valid", "full-and-thumbnail", "empty", "text-only", "image-only", "unsupported",
        "broken-image",
    ])
    func paperSmokeUsesProductionRenderer(stage: String) throws {
        let raw: String
        switch stage {
        case "empty":
            raw = ""
        case "text-only":
            raw = "text"
        case "image-only":
            raw = #"""
                {"blocks":[{"type":"image","data":{"file":{"url":"https://image.invali\#
                d/paper.png"}}}]}
                """#
        case "unsupported":
            raw = #"{"blocks":[{"type":"table","data":{}}]}"#
        case "full-and-thumbnail":
            raw = smokePaperContent.replacingOccurrences(
                of: "\"url\":\"https://image.invalid/paper.png\"",
                with:
                    """
                    \"url\":\"https://image.invalid/paper.png\",\"low_url\"\
                    :\"https://image.invalid/paper-low.png\"
                    """
            )
        default:
            let replacement =
                stage == "broken-image"
                ? "javascript:alert(1)" : "https://image.invalid/paper.png"
            raw = smokePaperContent.replacingOccurrences(
                of: "https://image.invalid/paper.png",
                with: replacement)
        }
        if stage == "valid" {
            #expect(
                try NetworkSmokePaging.checkPaperContent(raw) == [
                    "https://image.invalid/paper.png"
                ])
        } else if stage == "full-and-thumbnail" {
            #expect(
                try NetworkSmokePaging.checkPaperContent(raw) == [
                    "https://image.invalid/paper-low.png", "https://image.invalid/paper.png",
                ])
        } else {
            #expect(throws: URLError.self) { try NetworkSmokePaging.checkPaperContent(raw) }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["correct", "wrong", "missing"])
    func requestEvidenceChecksSelectedTerm(selection: String) async throws {
        let client = HTTPClient(transport: SelectorTransport(), observer: nil)
        var request = URLRequest(
            url: AppURL.required(
                """
                https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/kxjasbyController/c\
                xkxjasqk.do
                """
            ))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTPFormEncoding.body(
            [("XNXQDM", "2025-2026-1")]
                + (selection == "missing"
                    ? []
                    : [
                        (
                            "JXLDM",
                            selection == "correct" ? "selected-building" : "wrong-building"
                        )
                    ]))
        let collector = NetworkSmokeRequestCollector()
        let operation = { try await client.send(request) }
        let expected = ["XNXQDM": "2025-2026-1", "JXLDM": "selected-building"]
        if selection == "correct" {
            _ = try await collector.perform(
                operation, required: true, expectedParameters: expected)
        } else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(
                    operation, required: true, expectedParameters: expected)
            }
        }
        #expect(collector.requests.count == 1 && HTTPRequestEvidenceContext.didReceive == nil)
    }

    func user(_ id: Int) -> CommunityUser {
        .init(
            id: id, createTime: "", nickname: "fixture",
            avatar: .init(mid: "", url: "", lowUrl: ""), motto: "",
            identity: .init(
                id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
    }

    final class MediaRoute: HTTPTransport {
        var calls: [(String, String)] = []
        var referenced: [[String]] = []
        var brokenReference = false
        var failUpload = false
        var onUpload: (() -> Void)?
        var image: [String: Any] {
            ["mid": "uploaded", "url": "https://example.invalid/image.jpg", "low_url": ""]
        }
        var user: [String: Any] {
            [
                "id": 1, "create_time": "", "nickname": "fixture", "avatar": image, "motto": "",
                "identity": [
                    "id": 1, "color": "", "text": "", "create_time": "", "update_time": "",
                ],
            ]
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let method = request.httpMethod ?? "GET"
            calls.append((url.path, method))
            let result: [String: Any]
            if url.path == "/upload/image" {
                if failUpload { throw URLError(.networkConnectionLost) }
                #expect(
                    request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix(
                        "multipart/form-data;") == true)
                let body = try #require(request.httpBody)
                #expect(body.range(of: Data([0xFF, 0xD8])) != nil)
                result = image
                onUpload?()
            } else if method == "POST" {
                let body = try #require(request.httpBody)
                let payload = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: Any])
                referenced.append(try #require(payload["image_mids"] as? [String]))
                if url.path == "/posters" {
                    result = ["id": 9]
                } else {
                    result = [
                        "id": 10, "obj": "poster9", "images": [image], "user": user,
                        "anonymous": false,
                        "create_time": "", "update_time": "", "like": false, "like_num": 0,
                        "comment_num": 0,
                        "own": true, "rate": 0, "reply_user": user, "reply_obj": "",
                        "text": "fixture", "sub": [],
                    ]
                }
            } else {
                result = [
                    "id": 9, "title": "fixture", "text": "fixture", "anonymous": false,
                    "claim": ["id": 0, "text": ""],
                    "comment_num": 0, "create_time": "", "edit_time": "",
                    "images": brokenReference ? [] : [image],
                    "like": false, "like_num": 0, "own": true, "plugins": "[]", "public": false,
                    "tags": [],
                    "update_time": "", "user": user,
                ]
            }
            return (
                try JSONSerialization.data(withJSONObject: result),
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

}
#endif
