import CommunityCore
import CommunityTransport
import CourseFeature
import PaperFeature
import MineFeature
import Foundation
import Testing
import TransportCore
import BIT101TestSupport
@testable import GalleryFeature

@MainActor
struct ServiceContractTests {
    private final class ResponseObserver: HTTPClientObserving {
        var failures = 0
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(request: URLRequest, data: Data?, response: URLResponse?, error: (any Error)?, elapsed: TimeInterval) async {
            if error != nil { failures += 1 }
        }
    }
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func reportTypesKeepUsableUniqueChoices(empty: Bool) async throws {
        let body = empty ? #"[{"id":7,"text":" "}]"# : #"[{"id":7,"text":" "},{"id":42,"text":" 原因 "},{"id":42,"text":"重复"},{"id":7,"text":"其他"}]"#
        let service = GalleryService(session: session(Transport([(200, body)])), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        let types = try await service.fetchReportTypes()
        #expect(types.map(\.id) == (empty ? [] : [42, 7]))
        #expect(types.map(\.text) == (empty ? [] : ["原因", "其他"]))
    }
    @Test(.timeLimit(.minutes(1)), arguments: GallerySubscriptionLevel.allCases)
    func subscriptionWritesUseTheServerLevelAndAccount(level: GallerySubscriptionLevel) async throws {
        let transport = Transport([(200, "{}")])
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "subscriptions"), cookie: "fixture") }, refresh: { _ in })
        let service = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        try await service.setSubscription(objectID: "poster42", level: level)
        let request = try #require(transport.requests.first)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.httpMethod == "POST" && request.url?.path == "/subscriptions")
        #expect(body["obj"] as? String == "poster42" && body["level"] as? Int == level.rawValue)
        #expect(request.value(forHTTPHeaderField: "fake-cookie") == "fixture" && !request.httpShouldHandleCookies)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionsDecodeWebFavoritesAndKeepTheirSourcePage() async throws {
        let body = #"[{"id":4,"subscription_time":"2026-10-01T00:00:00Z","obj":"poster42","level":1,"text":"收藏话题"},{"id":5,"subscription_time":"","obj":"paper17","level":3,"text":"收藏文章"}]"#
        let transport = Transport([(200, body)])
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "subscriptions"), cookie: "fixture") }, refresh: { _ in })
        let service = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        let items = try await service.fetchSubscriptions(page: 2)
        #expect(items.map(\.level) == [.silent, .comment])
        #expect(items.first?.resource?.id == 42 && items.last?.resource?.kind == "paper")
        #expect(items.first?.subscriptionTime == "2026-10-01T00:00:00Z")
        #expect(transport.requests.first?.url?.query == "page=2")
        let counts = try JSONDecoder().decode(GalleryMessageUnreadCounts.self, from: Data(#"{"subscription":3}"#.utf8))
        #expect(counts.unreadCount(for: .subscription) == 3)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["reaction/like", "user/follow/1"], ["sent", "before-send", "rejected"])
    func togglesClassifyUncertainOutcomesAtTheRequestBoundary(path: String, boundary: String) async {
        let transport = Transport([(400, "{}")])
        if boundary == "sent" { transport.failure = URLError(.networkConnectionLost) }
        if boundary == "before-send" { transport.failure = HTTPRequestNotSent(underlying: URLError(.cannotFindHost)) }
        let api = CommunityAPIClient<CourseServiceError>(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "fixture",
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") })
        do {
            let _: CommunityLikeResult = try await api.request(path: path, method: "POST")
            Issue.record("Toggle failure fixture must propagate its outcome")
        } catch {
            #expect((error is CommunityToggleOutcomeUnknown) == (boundary == "sent"))
        }
        #expect(transport.requests.count == 1)
    }
#if os(macOS)
    @Test(.timeLimit(.minutes(1)), arguments: ["gallery.newest", "gallery.following", "gallery.hot", "gallery.recommend", "gallery.bots", "gallery.search", "gallery.subscriptions"])
    func productionGalleryRequestsPassThePythonSmokeContract(probe: String) async throws {
        let transport = Transport(Array(repeating: (200, "[]"), count: probe == "gallery.search" ? 16 : 10))
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://bit101.flwfdd.xyz"),
            credentials: { .init(identity: .init(accountIdentifier: "contracts"), cookie: "fixture") }, refresh: { _ in })
        let service = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        var requests: [(URLRequest, HTTPResponse)] = []
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in requests.append((request, response)) }) {
            for page in 0...1 {
                switch probe {
                case "gallery.search":
                    for keyword in [" BIT101 ", " excluded "] {
                        for order in GallerySearchOrder.allCases {
                            _ = try await service.searchPosters(query: .init(text: keyword, order: order), page: page == 0 ? nil : page)
                        }
                    }
                    for order in [GallerySearchOrder.like, .newest] {
                        _ = try await service.searchPosters(query: .init(text: "", order: order), page: page)
                    }
                case "gallery.recommend": _ = try await service.fetchRecommendPage(sourcePage: page)
                case "gallery.subscriptions": _ = try await service.fetchSubscriptions(page: page)
                case "gallery.bots": _ = try await service.fetchBotFeed(startPage: page)
                default:
                    let kind: GalleryFeedKind = probe == "gallery.following" ? .follow : (probe == "gallery.hot" ? .hot : .newest)
                    _ = try await service.fetchFeed(kind: kind, page: page == 0 ? nil : page)
                }
            }
        }
        try await assertSmokeContract(probe: probe, requests: requests,
            selectors: probe == "gallery.search" ? ["search": "BIT101", "excludedSearch": "excluded"] : [:])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["paper.detail", "paper.comments"], [false, true])
    func productionPaperRequestsPassThePythonSmokeContract(probe: String, authenticated: Bool) async throws {
        let transport = Transport(probe == "paper.detail" ? [(200, paperDetailBody(own: authenticated))] : Array(repeating: (200, "[]"), count: 6))
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://bit101.flwfdd.xyz"),
            credentials: { .init(identity: .init(accountIdentifier: "contracts"), cookie: authenticated ? "fixture" : "") }, refresh: { _ in })
        let service = PaperService(session: session)
        var requests: [(URLRequest, HTTPResponse)] = []
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in requests.append((request, response)) }) {
            if probe == "paper.detail" { _ = try await service.fetchPaper(id: 17) }
            else { for order in CommunityCommentOrder.allCases {
                for page in 0...1 { _ = try await service.fetchComments(paperID: 17, order: order, page: page) }
            } }
        }
        #expect(transport.authenticationRequests.isEmpty)
        try await assertSmokeContract(probe: probe, requests: requests,
            selectors: probe == "paper.detail" ? ["path": "/papers/17"] : ["obj": "paper17"])
    }

    private func assertSmokeContract(probe: String, requests: [(URLRequest, HTTPResponse)], selectors: [String: String] = [:]) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-B", root.appendingPathComponent("Scripts/network_request_contracts.py").path]
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        let (completion, finished) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in finished.yield(()); finished.finish() }
        try process.run()
        let rows = try requests.map { request, response in
            let metadata = HTTPRequestEvidence(request: request, response: response.response, finalRequest: response.finalRequest)
            var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
            func parameters(_ request: URLRequest) throws -> [String: String] {
                let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
                let allowed = ["page", "order", "search", "hide_bot", "obj", "mode", "type", "uid"]
                #expect(Set(items.map(\.name)).count == items.count)
                var result = items.reduce(into: [String: String]()) {
                    $0[$1.name] = allowed.contains($1.name) ? $1.value ?? "" : "[REDACTED]"
                }
                if let data = request.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["obj"] as? String {
                    result["obj"] = value
                }
                return result
            }
            row["query"] = try parameters(request)
            row["finalQuery"] = try parameters(response.finalRequest ?? request)
            if response.data == Data("[]".utf8) { row["responseMinimumID"] = "0" }
            return row
        }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["probe": probe, "requests": rows, "expectedParameters": selectors]))
        try input.fileHandleForWriting.close()
        var iterator = completion.makeAsyncIterator()
        _ = await iterator.next()
        #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
    }
#endif

    @Test(.timeLimit(.minutes(1))) func repeatedCommentPagesAdvanceUntilNewContent() async throws {
        func comment(_ id: Int) -> String {
            #"{"id":\#(id),"obj":"poster1","images":[],"user":\#(user),"anonymous":false,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":0,"reply_user":\#(user),"reply_obj":"","text":"评论","sub":[]}"#
        }
        let transport = Transport([1, 1, 1, 2].map { (200, "[" + comment($0) + "]") })
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let model = GalleryPosterDetailViewModel(initialPoster: try decoder.decode(CommunityPoster.self, from: Data(poster(id: 1).utf8)),
            service: GalleryService(session: session(transport), preferences: {
                .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
            }))
        await model.refreshComments()
        await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
        #expect(model.commentState.items.map(\.id) == [1, 2] && model.commentState.nextPage == 4 && !model.commentState.isLoadingMore)
        #expect(try transport.requests.map { try query($0)["page"] } == [nil, "1", "2", "3"])
    }

    @Test func galleryWebCredentialsUseTheTrustedHTTPSOrigin() {
        for address in ["https://bit101.cn/gallery", "https://BIT101.cn:443/paper/42"] {
            #expect(GalleryWebRequestFactory.isTrustedPage(URL(string: address)))
        }
        for address in ["http://bit101.cn/gallery", "https://bit101.cn:444/gallery",
                        "https://bit101.cn.example.invalid/", "https://example.invalid/?next=https://bit101.cn",
                        "https://bit101.cn@example.invalid", "file:///gallery"] {
            #expect(!GalleryWebRequestFactory.isTrustedPage(URL(string: address)))
        }
        #expect(!GalleryWebRequestFactory.isTrustedPage(nil))
    }

    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        var authenticationRequests: [URLRequest] = []
        var failure: (any Error)?
        var responseForRequest: ((URLRequest) throws -> (Int, String))?
        private var responses: [(Int, String)]
        var authenticationStatuses: [Int]
        init(_ responses: [(Int, String)], authenticationStatuses: [Int] = []) {
            self.responses = responses
            self.authenticationStatuses = authenticationStatuses
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try Task.checkCancellation()
            if request.url?.path == "/user/check" {
                authenticationRequests.append(request)
                let status = authenticationStatuses.isEmpty ? 200 : authenticationStatuses.removeFirst()
                let url = try #require(request.url)
                return (Data(), try #require(HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
            }
            requests.append(request)
            if let failure { throw failure }
            let response: (Int, String)
            if let responseForRequest { response = try responseForRequest(request) }
            else { response = try #require(responses.first); responses.removeFirst() }
            let url = try #require(request.url)
            return (Data(response.1.utf8), try #require(HTTPURLResponse(url: url, statusCode: response.0,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
        }
    }

    private let course = #"{"id":42,"name":"操作系统","number":"CS101","credits":"3.5","like_num":7,"comment_num":2,"rate":9.2,"teachers_name":"教师","teachers_number":"T1"}"#
    private let paper = #"{"id":17,"title":"文章","intro":"摘要","like_num":3,"comment_num":4,"update_time":"2026-09-01T08:00:00Z"}"#
    private let user = #"{"id":1,"create_time":"","nickname":"作者","avatar":{"mid":"avatar","url":"https://example.invalid/avatar","low_url":"https://example.invalid/small"},"motto":"","identity":{"id":0,"color":"","text":"","create_time":"","update_time":""}}"#

    private func poster(id: Int, anonymous: Bool = false, bot: Bool = false, userID: Int = 1) -> String {
        let author = user.replacingOccurrences(of: "\"id\":1", with: "\"id\":\(userID)")
        return "{\"id\":\(id),\"anonymous\":\(anonymous),\"claim\":{\"id\":0,\"text\":\"\"},\"comment_num\":0,\"create_time\":\"\",\"edit_time\":\"\",\"images\":[],\"like_num\":0,\"public\":true,\"tags\":\(bot ? "[\"bot\"]" : "[]"),\"text\":\"fixture\",\"title\":\"fixture\",\"update_time\":\"\",\"user\":\(author)}"
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["anonymous", "blocked", "bots"])
    func filteredSourcePagesAdvanceTheFeedAndSearchCursor(setting: String) async throws {
        let hidden = poster(id: 1, anonymous: setting == "anonymous", bot: setting == "bots")
        let visible = poster(id: 2, userID: 2)
        for search in [false, true] {
            let transport = Transport([(200, "[" + hidden + "]"), (200, "[" + visible + "]"), (200, "[]")])
            let service = GalleryService(session: session(transport), preferences: {
                CommunityPreferenceSnapshot(hideBots: setting == "bots", hiddenUserIDs: setting == "blocked" ? [1] : [],
                    hideAnonymous: setting == "anonymous", useWebView: false, hideMakeupOutliers: false)
            })
            let model = GalleryViewModel(service: service)
            if search { await model.performSearch() }
            else { await model.refresh(feed: .newest) }
            let state = search ? model.searchState : model.state(for: .newest)
            #expect(state.posters.map(\.id) == [2])
            #expect(state.nextPage == 2 && state.canLoadMore)
            if search { await model.loadMoreSearchResultsIfNeeded(currentPoster: state.posters.last) }
            else { await model.loadMoreIfNeeded(for: .newest, currentPoster: state.posters.last) }
            let end = search ? model.searchState : model.state(for: .newest)
            #expect(end.nextPage == 3 && end.canLoadMore == false)
            #expect(try query(transport.requests[1])["page"] == "1")
            #expect(try query(transport.requests[2])["page"] == "2")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func botBatchesDeduplicateOverlappingSourcePages(hideBots: Bool) async throws {
        let first = poster(id: 1, bot: true)
        let second = poster(id: 2, bot: true).replacingOccurrences(of: "[\"bot\"]", with: "[\"新闻\"]")
        let third = poster(id: 3, bot: true).replacingOccurrences(of: "[\"bot\"]", with: "[\"RoBoT\"]")
        let transport = Transport([(200, "[" + poster(id: 9) + "," + first + "," + second + "]"),
            (200, "[" + second + "," + third + "]"), (200, "[]")])
        let service = GalleryService(session: session(transport), preferences: {
            .init(hideBots: hideBots, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        let batch = try await service.fetchBotFeed(startPage: 0)
        #expect(batch.items.map(\.id) == [1, 2, 3] && batch.nextSourcePage == 3 && !batch.canLoadMore)
        #expect(batch.sourceIDs == [9, 1, 2, 2, 3])
        #expect(try transport.requests.map { try query($0)["page"] } == [nil, "1", "2"])
        #expect(try transport.requests.allSatisfy { try query($0)["hide_bot"] == nil })
    }

    @Test(.timeLimit(.minutes(1))) func botFilteringPreservesItsCursorAcrossBoundedBatches() async throws {
        let hidden = (1...5).map { poster(id: $0, bot: true) }
        let visible = poster(id: 8, bot: true, userID: 2)
        let transport = Transport(hidden.map { (200, "[" + $0 + "]") } + [(200, "[" + visible + "]"), (200, "[]")])
        let service = GalleryService(session: session(transport), preferences: {
            CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [1], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        let batch = try await service.fetchBotFeed(startPage: 0)
        #expect(batch.items.isEmpty && batch.sourceIDs == Array(1...5))
        #expect(batch.nextSourcePage == 5 && batch.canLoadMore && transport.requests.count == 5)
        let end = try await service.fetchBotFeed(startPage: batch.nextSourcePage)
        #expect(end.items.map(\.id) == [8] && end.nextSourcePage == 7 && end.canLoadMore == false)
        #expect(transport.requests.count == 7)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["feed", "bot", "recommend", "comments"])
    func repeatedFilteredPagesReleaseTheirLoadingState(kind: String) async throws {
        let hidden = poster(id: 1, anonymous: true)
        let comment = #"{"id":5,"obj":"poster1","images":[],"user":\#(user),"anonymous":true,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":0,"reply_user":\#(user),"reply_obj":"","text":"fixture","sub":[]}"#
        let transport = Transport(Array(repeating: (200, "[" + (kind == "comments" ? comment : hidden) + "]"), count: 8))
        let service = GalleryService(session: session(transport), preferences: {
            CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: true, useWebView: false, hideMakeupOutliers: false)
        })
        if kind == "recommend" {
            let model = GalleryViewModel(service: service)
            await model.refresh(feed: .recommend)
            #expect(model.state(for: .recommend).status != .loading && model.alert != nil)
        } else {
            await #expect(throws: URLError.self) {
                switch kind {
                case "feed": _ = try await service.fetchFeed(kind: .newest, page: nil)
                case "bot": _ = try await service.fetchBotFeed(startPage: 0)
                default: _ = try await service.fetchComments(objectID: "poster1", order: .newest, page: nil)
                }
            }
        }
        #expect(transport.requests.count == 5)
    }

    @Test(.timeLimit(.minutes(1))) func posterUpdateRetainsThePluginPayloadOnTheWire() async throws {
        let transport = Transport([(200, "")])
        let plugins = #"[{"type":"future","data":{"text":"preserved"}}]"#
        try await GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        }).updatePoster(id: 42, title: "编辑", text: "正文", imageMids: [], plugins: plugins,
            anonymous: false, tags: [], claimID: 0, isPublic: true)
        let body = try #require(transport.requests.first?.httpBody)
        #expect((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["plugins"] as? String == plugins)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func reportTransportCancellationPreservesItsClassification(urlError: Bool) async {
        let transport = Transport([])
        transport.failure = urlError ? URLError(.cancelled) : CancellationError()
        let service = GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        do {
            try await service.report(objectID: "poster1", typeID: 42, text: "说明")
            Issue.record("Cancelled report should release its caller")
        } catch { #expect(TaskCancellation.matches(error)) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [400, 503, 0])
    func reportCreationDistinguishesRejectionFromAnUnknownOutcome(status: Int) async {
        let transport = Transport([(status, "")])
        if status == 0 { transport.failure = URLError(.networkConnectionLost) }
        let service = GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        do { try await service.report(objectID: "poster1", typeID: 42, text: "说明"); Issue.record("需要呈现传输结果") }
        catch { #expect((error is CommunityCreateOutcomeUnknown) == (status != 400)) }
        #expect(transport.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["feed", "search", "comments"])
    func longFilteredRunsYieldAtTheBudgetAndContinueThroughTheirSourceCursor(kind: String) async throws {
        func comment(_ id: Int, hidden: Bool) -> String {
            #"{"id":\#(id),"obj":"poster1","images":[],"user":\#(user),"anonymous":\#(hidden),"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":0,"reply_user":\#(user),"reply_obj":"","text":"fixture","sub":[]}"#
        }
        let rows = (1...5).map { kind == "comments" ? comment($0, hidden: true) : poster(id: $0, anonymous: true) }
            + [kind == "comments" ? comment(6, hidden: false) : poster(id: 6)]
        let transport = Transport(rows.map { (200, "[" + $0 + "]") } + [(200, "[]")])
        let service = GalleryService(session: session(transport), preferences: {
            CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: true, useWebView: false, hideMakeupOutliers: false)
        })
        if kind == "comments" {
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let initial = try decoder.decode(CommunityPoster.self, from: Data(poster(id: 1).utf8))
            let model = GalleryPosterDetailViewModel(initialPoster: initial, service: service)
            await model.refreshComments()
            #expect(model.commentState.items.isEmpty && model.commentState.nextPage == 5 && model.commentState.canLoadMore)
            #expect(transport.requests.count == 5)
            await model.loadMoreCommentsIfNeeded(currentComment: nil)
            #expect(model.commentState.items.map(\.id) == [6] && model.commentState.nextPage == 6)
            await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
            #expect(!model.commentState.canLoadMore)
        } else {
            let model = GalleryViewModel(service: service)
            if kind == "search" { await model.performSearch() } else { await model.refresh(feed: .newest) }
            let first = kind == "search" ? model.searchState : model.state(for: .newest)
            #expect(first.posters.isEmpty && first.nextPage == 5 && first.canLoadMore)
            #expect(transport.requests.count == 5)
            if kind == "search" { await model.enqueueSearchLoadMore(currentPoster: nil).value }
            else { await model.loadMoreIfNeeded(for: .newest, currentPoster: nil) }
            let next = kind == "search" ? model.searchState : model.state(for: .newest)
            #expect(next.posters.map(\.id) == [6] && next.nextPage == 6)
            if kind == "search" { await model.enqueueSearchLoadMore(currentPoster: next.posters.last).value }
            else { await model.loadMoreIfNeeded(for: .newest, currentPoster: next.posters.last) }
            #expect(!(kind == "search" ? model.searchState : model.state(for: .newest)).canLoadMore)
        }
        #expect(transport.requests.count == 7)
    }

    @Test(.timeLimit(.minutes(1))) func filteredCommentPagesKeepTheirSourceCursorAndRawRecoveryRemainsAvailable() async throws {
        let comment = #"{"id":5,"obj":"poster1","images":[],"user":\#(user),"anonymous":false,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":0,"reply_user":\#(user),"reply_obj":"","text":"fixture","sub":[]}"#
        let hidden = comment.replacingOccurrences(of: "\"anonymous\":false", with: "\"anonymous\":true")
        let transport = Transport([(200, "[" + hidden + "]"), (200, "[" + comment + "]"), (200, "[]"), (200, "[" + hidden + "]")])
        let service = GalleryService(session: session(transport), preferences: {
            CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: true, useWebView: false, hideMakeupOutliers: false)
        })
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let initial = try decoder.decode(CommunityPoster.self, from: Data(poster(id: 1).utf8))
        let model = GalleryPosterDetailViewModel(initialPoster: initial, service: service)
        await model.refreshComments()
        #expect(model.commentState.items.map(\.id) == [5])
        #expect(model.commentState.nextPage == 2 && model.commentState.canLoadMore)
        await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
        #expect(model.commentState.nextPage == 3 && model.commentState.canLoadMore == false)
        let raw = try await service.fetchRawComments(objectID: "poster1", order: .newest, page: nil)
        #expect(raw.first?.anonymous == true)
        #expect(try query(transport.requests[2])["page"] == "2")
    }

    @Test(.timeLimit(.minutes(1)), arguments: GalleryMessageType.allCases)
    func messageHistoryCanStartAtTheUpperBoundAndPreserveUnreadCounts(type: GalleryMessageType) async throws {
        let transport = Transport([(200, "[]")])
        let service = GalleryService(session: session(transport), preferences: {
            CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
                                        useWebView: false, hideMakeupOutliers: false)
        })
        #expect(try await service.fetchMessages(type: type, lastID: .max).isEmpty)
        #expect(try query(transport.requests[0]) == ["type": type.rawValue, "last_id": String(Int.max)])
    }

    @Test(.timeLimit(.minutes(1)), arguments: GalleryMessageType.allCases, [[89, 80], [], [95], [90], [80, 89], [89, 89], [0]])
    func messageHistoryRequiresStrictlyOlderOrderedPages(type: GalleryMessageType, ids: [Int]) async throws {
        let messages = ids.map { id in
            #"{"id":\#(id),"from_user":{},"link_obj":"poster1","obj":"poster1","text":"消息","update_time":""}"#
        }
        let transport = Transport([(200, "[" + messages.joined(separator: ",") + "]")])
        let observer = ResponseObserver()
        let service = GalleryService(session: session(transport, observer: observer), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        if ids == [89, 80] || ids.isEmpty {
            #expect(try await service.fetchMessages(type: type, lastID: 90).map(\.id) == ids)
        } else {
            await #expect(throws: GalleryServiceError.self) { try await service.fetchMessages(type: type, lastID: 90) }
        }
        #expect(try query(transport.requests[0]) == ["type": type.rawValue, "last_id": "90"])
        #expect(observer.failures == (ids == [89, 80] || ids.isEmpty ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)), arguments: GalleryMessageType.allCases)
    func messageCategoriesKeepTheirCursorAcrossTwoHistoryPages(type: GalleryMessageType) async throws {
        func page(_ ids: [Int]) -> String {
            let rows = ids.map { id in
                #"{"id":\#(id),"from_user":{},"link_obj":"poster\#(id)","obj":"poster\#(id)","text":"消息","update_time":"2026-10-01T00:00:00Z"}"#
            }
            return "[" + rows.joined(separator: ",") + "]"
        }
        let transport = Transport([[90, 80], [90, 80], [70, 60], []].map { (200, page($0)) })
        let service = GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        for (cursor, ids) in [(nil as Int?, [90, 80]), (Int.max, [90, 80]), (80, [70, 60]), (60, [])] {
            let messages = try await service.fetchMessages(type: type, lastID: cursor)
            #expect(messages.map(\.id) == ids && messages.compactMap { $0.linkedResource?.id } == ids)
            let request = try #require(transport.requests.last)
            #expect(request.url?.path == "/messages")
            var expected = ["type": type.rawValue]
            if let cursor { expected["last_id"] = String(cursor) }
            #expect(try query(request) == expected)
        }
        #expect(transport.requests.count == 4)
    }

    @Test(.timeLimit(.minutes(1))) func commentOrdersUseDistinctSamplesAndRestartPagination() async throws {
        func comment(_ id: Int) -> String {
            #"{"id":\#(id),"obj":"poster1","images":[],"user":\#(user),"anonymous":false,"create_time":"2026-10-0\#(4 - id)T00:00:00Z","update_time":"2026-10-01T00:00:00Z","like":false,"like_num":\#(id == 2 ? 9 : id == 3 ? 6 : 3),"comment_num":0,"own":true,"rate":0,"reply_user":\#(user),"reply_obj":"","text":"评论\#(id)","sub":[]}"#
        }
        let ranked = ["new": [1, 2, 3], "old": [3, 2, 1], "like": [2, 3, 1]]
        let transport = Transport([])
        transport.responseForRequest = { request in
            let parameters = try query(request)
            let order = try #require(parameters["order"])
            let ids = try #require(ranked[order])
            let page = Int(parameters["page"] ?? "0") ?? 0
            let rows = page == 0 ? Array(ids.prefix(2)) : page == 1 ? Array(ids.suffix(1)) : []
            return (200, "[" + rows.map(comment).joined(separator: ",") + "]")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let initial = try decoder.decode(CommunityPoster.self, from: Data(poster(id: 1).utf8))
        let model = GalleryPosterDetailViewModel(initialPoster: initial, service: GalleryService(session: session(transport), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        }))
        for order in [CommunityCommentOrder.newest, .oldest, .like, .newest] {
            let ids = try #require(ranked[order.rawValue]), start = transport.requests.count
            if model.commentState.status == .idle { await model.refreshComments() }
            else { await model.setCommentOrder(order) }
            #expect(model.commentOrder == order && model.commentState.items.map(\.id) == Array(ids.prefix(2)))
            #expect(model.commentState.nextPage == 1 && model.commentState.canLoadMore)
            #expect(Set(model.commentState.items.map(\.createTime)).count == 2)
            #expect(Set(model.commentState.items.map(\.likeNum)).count == 2)
            await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
            #expect(model.commentState.items.map(\.id) == ids && model.commentState.nextPage == 2)
            await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
            #expect(!model.commentState.canLoadMore && !model.commentState.isLoadingMore)
            let requests = Array(transport.requests.dropFirst(start))
            #expect(requests.count == 3)
            #expect(try requests.map { try query($0)["page"] } == [nil, "1", "2"])
            #expect(try requests.allSatisfy { try query($0)["order"] == order.rawValue && query($0)["obj"] == "poster1" })
        }
    }

    private func session(_ transport: Transport, cookie: String = "fixture-cookie", observer: (any HTTPClientObserving)? = nil) -> CommunitySession {
        CommunitySession(httpClient: HTTPClient(transport: transport, observer: observer), baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "contracts"), cookie: cookie) }, refresh: { _ in })
    }

    private func paperDetailBody(own: Bool, title: String = "文章") -> String {
        "{\"id\":17,\"title\":\"\(title)\",\"intro\":\"摘要\",\"content\":\"正文\",\"create_time\":\"\",\"update_time\":\"\",\"update_user\":\(user),\"anonymous\":false,\"like_num\":3,\"comment_num\":0,\"public_edit\":false,\"like\":\(own),\"own\":\(own)}"
    }

    @Test(.timeLimit(.minutes(1))) func authenticatedPaperReadRestoresOnTheActualContentRequest() async throws {
        let transport = Transport([(401, ""), (200, "[" + paper + "]"), (200, paperDetailBody(own: true)), (200, "[]")])
        var credentials = CommunityCredentials(identity: .init(accountIdentifier: "contracts"), cookie: "expired")
        var restores = 0
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: { credentials }, refresh: { observed in
                #expect(observed.cookie == "expired")
                restores += 1
                credentials = .init(identity: observed.identity, cookie: "fresh")
            })
        let service = PaperService(session: session)
        #expect(try await service.fetchPapers(search: "文章", order: .newest, page: 0).first?.id == 17)
        let detail = try await service.fetchPaper(id: 17)
        _ = try await service.fetchComments(paperID: 17, order: .oldest, page: nil)
        #expect(detail.own && detail.like && detail.isViewerAuthenticated && restores == 1)
        #expect(transport.authenticationRequests.isEmpty)
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "fake-cookie") } == ["expired", "fresh", "fresh", "fresh"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["poster0", "poster-1", "posterXYZ", "poster999999999999999999999", "paper1", "course1", "comment1", "poster17", "poster01"])
    func messageLinksRequireAPositiveResourceIdentity(link: String) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func message(object: String) throws -> GalleryMessage {
            try decoder.decode(GalleryMessage.self, from: Data("{\"from_user\":{},\"id\":9,\"link_obj\":\"\(link)\",\"obj\":\"\(object)\",\"text\":\"\",\"update_time\":\"\"}".utf8))
        }
        let targets: [String: (CommunityResourceReference.Kind, Int)] = [
            "poster17": (.poster, 17), "poster01": (.poster, 1), "paper1": (.paper, 1), "course1": (.course, 1)]
        let expected = targets[link]
        let direct = try message(object: "").linkedResource
        #expect(direct?.kind == expected?.0 && direct?.id == expected?.1)
        let fallback = try message(object: "poster17").linkedResource
        #expect(fallback?.kind == (expected?.0 ?? .poster) && fallback?.id == (expected?.1 ?? 17))
    }

    @Test(.timeLimit(.minutes(1))) func anonymousPaperReadKeepsItsPublicContract() async throws {
        let transport = Transport([(200, paperDetailBody(own: false))])
        let detail = try await PaperService(session: session(transport, cookie: "")).fetchPaper(id: 17)
        #expect(!detail.own && !detail.like && !detail.isViewerAuthenticated && transport.authenticationRequests.isEmpty)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "fake-cookie") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func paperPreviewReusesTheBodyAndMutationInvalidatesIt() async throws {
        let transport = Transport([(200, paperDetailBody(own: true)), (200, paperDetailBody(own: true, title: "刷新")),
            (200, paperDetailBody(own: true)), (200, #"{"like":true,"like_num":4}"#), (200, paperDetailBody(own: true, title: "修改后"))])
        let service = PaperService(session: session(transport))
        _ = try await service.fetchPreviewMetadata(id: 17)
        #expect(await service.cachedPaper(id: 17)?.title == "文章")
        #expect(transport.requests.count == 1)
        #expect(try await service.fetchPaper(id: 17).title == "刷新")
        _ = try await service.fetchPreviewMetadata(id: 17)
        _ = try await service.likePaper(id: 17)
        #expect(try await service.fetchPaper(id: 17).title == "修改后")
        #expect(transport.requests.count == 5)
    }

    @Test(.timeLimit(.minutes(1))) func paperPreviewKeepsTheBodyAfterCookieRestoration() async throws {
        let transport = Transport([(401, ""), (200, paperDetailBody(own: true))])
        var credentials = CommunityCredentials(identity: .init(accountIdentifier: "contracts"), cookie: "expired")
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: { credentials }, refresh: { observed in
                credentials = .init(identity: observed.identity, cookie: "fresh")
            })
        let service = PaperService(session: session)
        _ = try await service.fetchPreviewMetadata(id: 17)
        #expect(await service.cachedPaper(id: 17)?.own == true)
        #expect(transport.requests.count == 2 && transport.authenticationRequests.isEmpty)
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "fake-cookie") } == ["expired", "fresh"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func prefetchedPaperBodyStaysReadableThroughOfflineListRefresh(failedListRefresh: Bool) async throws {
        let transport = Transport([(200, paperDetailBody(own: true))], authenticationStatuses: [503])
        let service = PaperService(session: session(transport))
        _ = try await service.fetchPreviewMetadata(id: 17)
        transport.failure = URLError(.notConnectedToInternet)
        if failedListRefresh {
            await #expect(throws: URLError.self) { _ = try await service.fetchPapers(search: nil, order: .newest, page: 0) }
        }
        #expect(await service.cachedPaper(id: 17)?.own == true)
        #expect(transport.requests.count == (failedListRefresh ? 2 : 1) && transport.authenticationRequests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func concurrentPaperPreviewsReadTheirContentDirectly() async throws {
        let transport = Transport([])
        transport.responseForRequest = { request in
            let id = try #require(request.url?.lastPathComponent)
            return (200, self.paperDetailBody(own: true).replacingOccurrences(of: "\"id\":17", with: "\"id\":\(id)"))
        }
        let service = PaperService(session: session(transport))
        let (starts, started) = AsyncStream<Void>.makeStream()
        let tasks = (17..<25).map { id in Task { started.yield(()); return try await service.fetchPreviewMetadata(id: id) } }
        defer { tasks.forEach { $0.cancel() }; started.finish() }
        var iterator = starts.makeAsyncIterator()
        for _ in tasks { _ = await iterator.next() }
        for task in tasks { _ = try await task.value }
        #expect(transport.authenticationRequests.isEmpty && transport.requests.count == 8)
        #expect(Set(transport.requests.compactMap { $0.url?.path }) == Set((17..<25).map { "/papers/\($0)" }))
    }

    private func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test(.timeLimit(.minutes(1))) func coursePagingAndDetailDecodeSnakeCaseAndFlexibleCredits() async throws {
        let detail = String(course.dropLast()) + #", "like":true}"#
        let transport = Transport([(200, "[" + course + "]"), (200, "[]"), (200, detail)])
        let service = CourseService(session: session(transport))
        let first = try await service.fetchCourses(search: "  操作系统 & A+B  ", page: 0)
        #expect(first.first?.credit == 3.5)
        #expect(first.first?.teachersName == "教师")
        #expect(first.first?.likeNum == 7)
        #expect(try query(transport.requests[0]) == ["search": "操作系统 & A+B", "order": "new", "page": "0"])
        #expect(transport.requests[0].value(forHTTPHeaderField: "fake-cookie") == "fixture-cookie")
        #expect(try await service.fetchCourses(search: "", page: 1).isEmpty)
        #expect(try query(transport.requests[1]) == ["order": "new", "page": "1"])
        let value = try await service.fetchCourse(id: 42)
        #expect(value.like && value.id == 42)
        #expect(value.credit == 3.5)
        #expect(transport.requests[2].url?.path == "/courses/42")
    }

    @Test(.timeLimit(.minutes(1))) func courseHistoryEscapesPathSeparatorsAndDecodesStatistics() async throws {
        let transport = Transport([(200, #"[{"term":"2026-2027-1","avg_score":"85.5","max_score":100,"student_num":"37"}]"#)])
        let values = try await CourseService(session: session(transport)).fetchCourseHistories(number: "MATH/1+中文%20")
        #expect(values.first?.avgScore == 85.5)
        #expect(values.first?.studentNum == 37)
        #expect(transport.requests.first?.url?.path == "/courses/histories/MATH/1+中文%20")
        #expect(transport.requests.first?.url?.absoluteString.contains("MATH%2F1%2B") == true)
        #expect(transport.requests.first?.url?.absoluteString.hasSuffix("%2520") == true)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["1e300", #""1e300""#, #""NaN""#, #""Infinity""#, #""-Infinity""#, "37.9", #""37.9""#])
    func courseHistoryTreatsOutOfRangeCountsAsMissing(raw: String) async throws {
        let transport = Transport([(200, "[{\"term\":\"2026-2027-1\",\"student_num\":\(raw)}]")])
        let values = try await CourseService(session: session(transport)).fetchCourseHistories(number: "MATH")
        #expect(values.count == 1 && values[0].studentNum == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["NaN", "Infinity", "-Infinity"])
    func courseHistoryTreatsNonFiniteScoresAsMissing(raw: String) async throws {
        let transport = Transport([(200, "[{\"term\":\"2026-2027-1\",\"avg_score\":\"\(raw)\",\"max_score\":\"\(raw)\"}]")])
        let values = try await CourseService(session: session(transport)).fetchCourseHistories(number: "MATH")
        #expect(values.count == 1 && values[0].avgScore == nil && values[0].maxScore == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [#"[{"term":"same"},{"term":"same"}]"#, #"[{"term":" "}]"#,
        #"[{"term":"term","student_num":-1}]"#, #"[{"term":"term","avg_score":-1}]"#,
        #"[{"term":"term","max_score":101}]"#, #"[{"term":"term","avg_score":1e300}]"#])
    func courseHistoryRejectsDuplicateTermsAndInvalidStatistics(body: String) async throws {
        let transport = Transport([(200, body)])
        let observer = ResponseObserver()
        await #expect(throws: CourseServiceError.self) {
            try await CourseService(session: session(transport, observer: observer)).fetchCourseHistories(number: "MATH")
        }
        #expect(observer.failures == 1)
    }

    @Test(.timeLimit(.minutes(1))) func expiredCourseCredentialsRestoreOnceAndReplayTheOwnedPage() async throws {
        let transport = Transport([(401, #"{"message":"expired"}"#), (200, "[" + course + "]")])
        var cookie = "old-cookie"
        var restores = 0
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "contracts", generation: 2), cookie: cookie) },
            refresh: { observed in
                #expect(observed.cookie == "old-cookie")
                restores += 1
                cookie = "new-cookie"
            })
        let values = try await CourseService(session: session).fetchCourses(search: "CS101", page: 3)
        #expect(values.map(\.id) == [42])
        #expect(restores == 1 && transport.requests.count == 2)
        #expect(transport.requests[1].value(forHTTPHeaderField: "fake-cookie") == "new-cookie")
        #expect(try query(transport.requests[0]) == query(transport.requests[1]))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["{}", "null", "<html>gateway</html>", #"[{"id":"invalid"}]"#])
    func malformedCourseAndPaperListsExposeTheirBusinessErrors(_ response: String) async {
        for course in [true, false] {
            do {
                let selected = session(Transport([(200, response)]), cookie: course ? "fixture-cookie" : "")
                if course { _ = try await CourseService(session: selected).fetchCourses(search: "", page: 0) }
                else { _ = try await PaperService(session: selected).fetchPapers(search: nil, order: .newest, page: 0) }
                Issue.record("损坏列表需要保留业务错误和解码原因。")
            } catch {
                let actual = error as NSError
                let expected = course ? CourseServiceError.invalidResponse as NSError : PaperServiceError.invalidResponse as NSError
                #expect(actual.domain == expected.domain && actual.code == expected.code)
                #expect(actual.userInfo[NSUnderlyingErrorKey] != nil)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [(false, false), (false, true), (true, false), (true, true)], [400, 404, 500])
    func resourceAbsenceHasAServiceTypeAcrossCredentialRecovery(fixture: (Bool, Bool), status: Int) async throws {
        let (paper, refresh) = fixture
        let response = paper ? #"{"message":"文章不存在Orz"}"# : #"{"message":"帖子不存在Orz"}"#
        let transport = Transport((refresh ? [(401, #"{"message":"expired"}"#)] : []) + [(status, response)])
        do {
            if paper { _ = try await PaperService(session: session(transport)).fetchPaper(id: 17) }
            else { _ = try await GalleryService(session: session(transport), preferences: { .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false) }).fetchPoster(id: 17) }
            Issue.record("已知缺失响应需要沿服务错误传播")
        } catch {
            if paper {
                guard case PaperServiceError.missingPaper = error else { throw error }
                #expect(error.localizedDescription == "文章已删除或暂时无法访问。")
            } else {
                guard case GalleryServiceError.missingPoster = error else { throw error }
                #expect(error.localizedDescription == "帖子已删除或暂时无法访问。")
            }
        }
        #expect(transport.requests.count == (refresh ? 2 : 1))
        #expect(transport.authenticationRequests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func resourceClassificationKeepsUnknownRoutesAndListFailuresVisible(paper: Bool, list: Bool) async throws {
        let response = list ? (paper ? #"{"message":"文章不存在Orz"}"# : #"{"message":"帖子不存在Orz"}"#) : #"{"message":"Not Found"}"#
        let transport = Transport([(404, response)])
        do {
            if paper {
                let service = PaperService(session: session(transport))
                if list { _ = try await service.fetchPapers(search: nil, order: .newest, page: 0) }
                else { _ = try await service.fetchPaper(id: 17) }
            } else {
                let service = GalleryService(session: session(transport), preferences: { .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false) })
                if list { _ = try await service.fetchFeed(kind: .newest, page: 0) }
                else { _ = try await service.fetchPoster(id: 17) }
            }
            Issue.record("服务失败需要保留原请求状态")
        } catch {
            let failure = error as NSError
            #expect(failure.code == 404 && failure.domain == (paper ? "BIT101.Paper" : "BIT101.Gallery"))
        }
    }

    @Test(.timeLimit(.minutes(1))) func publicPaperPagesKeepAnonymousAccessAndDecodeAuthorDetails() async throws {
        let detail = #"{"id":17,"title":"文章","intro":"摘要","content":"正文","create_time":"","update_time":"","update_user":\#(user),"anonymous":false,"like_num":3,"comment_num":4,"public_edit":true,"like":false,"own":true}"#
        let transport = Transport([(200, "[" + paper + "]"), (200, "[]"), (200, detail), (200, "[]")])
        let service = PaperService(session: session(transport, cookie: ""))
        #expect(try await service.fetchPapers(search: "主题 & A+B", order: .comment, page: 2).first?.commentNum == 4)
        #expect(try query(transport.requests[0]) == ["search": "主题 & A+B", "order": "comment", "page": "2"])
        #expect(transport.requests[0].value(forHTTPHeaderField: "fake-cookie") == nil)
        #expect(try await service.fetchPapers(search: nil, order: .newest, page: 3).isEmpty)
        #expect(try query(transport.requests[1]) == ["page": "3"])
        let value = try await service.fetchPaper(id: 17)
        #expect(value.updateUser.nickname == "作者" && value.publicEdit && value.own)
        #expect(value.content == "正文")
        #expect(try await service.fetchComments(paperID: 17, order: .oldest, page: 2).isEmpty)
        #expect(try query(transport.requests[3]) == ["obj": "paper17", "order": "old", "page": "2"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, -1])
    func contentCreationRejectsInvalidIdentifiers(id: Int) async throws {
        let transport = Transport(Array(repeating: (200, "{\"id\":\(id)}"), count: 2))
        let shared = session(transport)
        let gallery = GalleryService(session: shared, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await gallery.createPoster(title: "标题", text: "正文", imageMids: [], anonymous: false,
                tags: [], claimID: 0, isPublic: true)
        }
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await PaperService(session: shared).createPaper(title: "标题", intro: "摘要", content: "正文", anonymous: false)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, -1])
    func commentCreationKeepsInvalidIdentifiersInsideTheUnknownOutcomeBoundary(id: Int) async throws {
        let comment = #"{"id":\#(id),"obj":"poster1","images":[],"user":\#(user),"anonymous":false,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":0,"reply_user":\#(user),"reply_obj":"","text":"评论","sub":[]}"#
        let transport = Transport(Array(repeating: (200, comment), count: 3))
        let shared = session(transport)
        let gallery = GalleryService(session: shared, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await gallery.createComment(objectID: "poster1", text: "评论")
        }
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await PaperService(session: shared).createComment(objectID: "paper1", text: "评论")
        }
        await #expect(throws: CommunityCreateOutcomeUnknown.self) {
            try await CourseService(session: shared).createComment(objectID: "course1", text: "评论")
        }
        #expect(transport.requests.count == 3)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["", "   ", "fixture-image"])
    func imageUploadRequiresAResourceIdentifier(mid: String) async throws {
        let response = "{\"mid\":\"\(mid)\",\"url\":\"https://example.invalid/image.jpg\",\"low_url\":\"https://example.invalid/small.jpg\"}"
        let transport = Transport([(200, response)])
        let observer = ResponseObserver()
        let gallery = GalleryService(session: session(transport, observer: observer), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        if mid == "fixture-image" {
            #expect(try await gallery.uploadImage(data: Data([1, 2, 3])).mid == mid)
        } else {
            await #expect(throws: GalleryServiceError.self) { try await gallery.uploadImage(data: Data([1, 2, 3])) }
        }
        #expect(observer.failures == (mid == "fixture-image" ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, -1, 18])
    func detailReadsRejectDifferentObjects(returnedID: Int) async throws {
        let paper = paperDetailBody(own: true).replacingOccurrences(of: "\"id\":17", with: "\"id\":\(returnedID)")
        let course = String(course.replacingOccurrences(of: "\"id\":42", with: "\"id\":\(returnedID)").dropLast()) + #", "like":false}"#
        let poster = String(poster(id: returnedID).dropLast()) + #", "like":false, "own":true, "plugins":"[]"}"#
        let transport = Transport([(200, poster), (200, paper), (200, paper), (200, course)])
        let observer = ResponseObserver()
        let shared = session(transport, observer: observer)
        let gallery = GalleryService(session: shared, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        await #expect(throws: GalleryServiceError.self) { try await gallery.fetchPoster(id: 17) }
        let service = PaperService(session: shared)
        await #expect(throws: PaperServiceError.self) { try await service.fetchPaper(id: 17) }
        await #expect(throws: PaperServiceError.self) { try await service.fetchPreviewMetadata(id: 17) }
        await #expect(throws: CourseServiceError.self) { try await CourseService(session: shared).fetchCourse(id: 42) }
        #expect(transport.requests.count == 4)
        #expect(observer.failures == 4)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, -1, 18, 17])
    func publicProfileResponseMatchesTheRequestedUser(returnedID: Int) async throws {
        let returnedUser = user.replacingOccurrences(of: "\"id\":1", with: "\"id\":\(returnedID)")
        let profile = #"{"user":\#(returnedUser),"followingNum":2,"followerNum":3,"following":false,"follower":false,"own":false}"#
        let transport = Transport([(200, profile)])
        let observer = ResponseObserver()
        let service = MineService(session: session(transport, observer: observer), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        if returnedID == 17 {
            #expect(try await service.fetchUserInfo(id: 17).user.id == 17)
        } else {
            await #expect(throws: MineServiceError.self) { try await service.fetchUserInfo(id: 17) }
        }
        #expect(transport.requests.map { $0.url?.path } == ["/user/info/17"])
        #expect(observer.failures == (returnedID == 17 ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["valid", "object", "zero", "nested-zero", "duplicate", "nested-duplicate"])
    func commentServicesValidateObjectsAndAllThreadIdentities(damage: String) async throws {
        let comment = #"{"id":5,"obj":"OBJECT","images":[],"user":\#(user),"anonymous":false,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":false,"rate":0,"reply_user":\#(user),"reply_obj":"","text":"评论","sub":[]}"#
        let childID = damage == "nested-zero" ? 0 : damage == "nested-duplicate" ? 5 : 6
        let child = comment.replacingOccurrences(of: "\"id\":5", with: "\"id\":\(childID)")
            .replacingOccurrences(of: "OBJECT", with: "comment5")
        var root = comment.replacingOccurrences(of: "\"sub\":[]", with: "\"sub\":[\(child)]")
        if damage == "zero" { root = root.replacingOccurrences(of: "\"id\":5", with: "\"id\":0") }
        let rows = "[" + root + (damage == "duplicate" ? "," + root : "") + "]"
        let objects = ["poster1", "course1", "paper1"]
        let transport = Transport(objects.map { (200, rows.replacingOccurrences(of: "OBJECT", with: damage == "object" ? "poster2" : $0)) })
        let observer = ResponseObserver()
        let shared = session(transport, observer: observer)
        let gallery = GalleryService(session: shared, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        let course = CourseService(session: shared), paper = PaperService(session: shared)
        if damage == "valid" {
            #expect(try await gallery.fetchRawComments(objectID: "poster1", order: .newest, page: nil).first?.sub.first?.id == 6)
            #expect(try await course.fetchComments(courseID: 1, page: nil).count == 1)
            #expect(try await paper.fetchComments(paperID: 1, order: .newest, page: nil).count == 1)
        } else {
            await #expect(throws: GalleryServiceError.self) { try await gallery.fetchRawComments(objectID: "poster1", order: .newest, page: nil) }
            await #expect(throws: CourseServiceError.self) { try await course.fetchComments(courseID: 1, page: nil) }
            await #expect(throws: PaperServiceError.self) { try await paper.fetchComments(paperID: 1, order: .newest, page: nil) }
        }
        #expect(observer.failures == (damage == "valid" ? 0 : 3))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func userPosterSearchChecksTheRequestedAuthor(matching: Bool) async throws {
        let rows = "[" + poster(id: 1, userID: matching ? 1 : 2) + "]"
        let transport = Transport([(200, rows)])
        let observer = ResponseObserver()
        let service = MineService(session: session(transport, observer: observer), preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        if matching { #expect(try await service.fetchUserPosters(userID: 1, page: 0).first?.user.id == 1) }
        else { await #expect(throws: MineServiceError.self) { try await service.fetchUserPosters(userID: 1, page: 0) } }
        #expect(observer.failures == (matching ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1))) func paperCreationEditingAndDeletionPreserveTheWireContract() async throws {
        let transport = Transport([(200, #"{"id":17}"#), (204, ""), (204, "")])
        let service = PaperService(session: session(transport))
        #expect(try await service.createPaper(title: "标题", intro: "摘要", content: "正文", anonymous: true, publicEdit: false) == 17)
        try await service.updatePaper(id: 17, title: "编辑", intro: "摘要", content: "新正文", anonymous: false, publicEdit: true,
            lastUpdatedAt: "2026-10-01T08:00:00.123456789Z")
        try await service.deletePaper(id: 17)
        #expect(transport.requests.map(\.httpMethod) == ["POST", "PUT", "DELETE"])
        #expect(transport.requests.map { $0.url?.path } == ["/papers", "/papers/17", "/papers/17"])
        let created = try body(transport.requests[0])
        #expect(created["public_edit"] as? Bool == false && created["anonymous"] as? Bool == true)
        #expect(created["content"] as? String == "正文")
        let updated = try body(transport.requests[1])
        #expect(updated["public_edit"] as? Bool == true && updated["title"] as? String == "编辑")
        let lastTime = try #require(updated["last_time"] as? Double)
        #expect(abs(lastTime - 1_790_841_600.1234567) < 0.001)
        #expect(transport.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test(.timeLimit(.minutes(1))) func invalidArticleVersionStopsEditingBeforeSending() async {
        let transport = Transport([])
        let service = PaperService(session: session(transport))
        await #expect(throws: PaperServiceError.self) {
            try await service.updatePaper(id: 17, title: "编辑", intro: "摘要", content: "正文", anonymous: false,
                publicEdit: true, lastUpdatedAt: "")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func courseAndPaperCommentsSendReplyIdentityAndRating() async throws {
        let comment = #"{"id":5,"obj":"course42","images":[],"user":\#(user),"anonymous":false,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":8,"reply_user":\#(user),"reply_obj":"comment2","text":"回复","sub":[]}"#
        let like = #"{"like":true,"like_num":8}"#
        let transport = Transport([(200, comment), (200, comment), (200, comment),
            (200, like), (200, like), (200, like), (200, "[]")])
        let shared = session(transport)
        let courseService = CourseService(session: shared)
        let paperService = PaperService(session: shared)
        let galleryService = GalleryService(session: shared, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        #expect(try await courseService.createComment(objectID: "course42", text: "回复", replyObjectID: "comment2", replyUID: 1, rate: 8).rate == 8)
        #expect(try await paperService.createComment(objectID: "paper17", text: "回复", replyObjectID: "comment2", replyUID: 1, anonymous: true).id == 5)
        #expect(try await galleryService.createComment(objectID: "poster9", text: "回复", replyObjectID: "comment2", replyUID: 1,
            anonymous: true, imageMids: ["fixture-image"]).id == 5)
        let courseBody = try body(transport.requests[0])
        let paperBody = try body(transport.requests[1])
        #expect(courseBody["rate"] as? Int == 8 && courseBody["reply_uid"] as? Int == 1)
        #expect(courseBody["reply_obj"] as? String == "comment2")
        #expect(paperBody["obj"] as? String == "paper17" && paperBody["anonymous"] as? Bool == true)
        let galleryBody = try body(transport.requests[2])
        #expect(galleryBody["obj"] as? String == "poster9" && galleryBody["image_mids"] as? [String] == ["fixture-image"])
        #expect(galleryBody["reply_obj"] as? String == "comment2" && galleryBody["reply_uid"] as? Int == 1)
        #expect(galleryBody["rate"] == nil && paperBody["rate"] == nil)
        #expect(try await courseService.like(objectID: "course42").like)
        #expect(try await paperService.sendLike(objectID: "paper17").like)
        #expect(try await galleryService.like(objectID: "poster9").like)
        for (request, object) in zip(transport.requests[3...5], ["course42", "paper17", "poster9"]) {
            #expect(try body(request)["obj"] as? String == object)
        }
        #expect(try await courseService.fetchComments(courseID: 42, page: nil).isEmpty)
        #expect(try query(transport.requests[6]) == ["obj": "course42", "order": "new"])
    }

    @Test(.timeLimit(.minutes(1))) func cancelledCourseAndPaperRequestsFinishBeforeTransportAdmission() async {
        let transport = Transport([])
        let shared = session(transport)
        let task = Task {
            await #expect(throws: CancellationError.self) { try await CourseService(session: shared).fetchCourse(id: 42) }
            await #expect(throws: CancellationError.self) { try await PaperService(session: shared).fetchPaper(id: 17) }
        }
        task.cancel()
        await task.value
        #expect(transport.requests.isEmpty)
    }
}
