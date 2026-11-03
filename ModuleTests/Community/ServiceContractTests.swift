import BIT101TestSupport
import CommunityCore
import CommunityTransport
import CourseFeature
import Foundation
import MineFeature
import PaperFeature
import Testing
import TransportCore

@testable import GalleryFeature

@MainActor
struct ServiceContractTests {
    final class ResponseObserver: HTTPClientObserving {
        var failures = 0
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(
            request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?,
            error: (any Error)?, elapsed: TimeInterval
        ) async {
            if error != nil { failures += 1 }
        }
    }
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func reportTypesKeepUsableUniqueChoices(empty: Bool) async throws {
        let body =
            empty
            ? #"[{"id":7,"text":" "}]"#
            : #"""
            [{"id":7,"text":" "},{"id":42,"text":" 原因 "},{"id":42,"text":"重复"},{"id":7,"text":\#
            "其他"}]
            """#
        let service = GalleryService(
            session: session(Transport([(200, body)])),
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        let types = try await service.fetchReportTypes()
        #expect(types.map(\.id) == (empty ? [] : [42, 7]))
        #expect(types.map(\.text) == (empty ? [] : ["原因", "其他"]))
    }
    @Test(.timeLimit(.minutes(1)), arguments: GallerySubscriptionLevel.allCases)
    func subscriptionWritesUseServerLevel(level: GallerySubscriptionLevel) async throws {
        let transport = Transport([(200, "{}")])
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                .init(identity: .init(accountIdentifier: "subscriptions"), cookie: "fixture")
            }, refresh: { _ in })
        let service = GalleryService(
            session: session,
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        try await service.setSubscription(objectID: "poster42", level: level)
        let request = try #require(transport.requests.first)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.httpMethod == "POST" && request.url?.path == "/subscriptions")
        #expect(body["obj"] as? String == "poster42" && body["level"] as? Int == level.rawValue)
        #expect(
            request.value(forHTTPHeaderField: "fake-cookie") == "fixture"
                && !request.httpShouldHandleCookies)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionsDecodeWebFavorites() async throws {
        let body =
            #"""
            [{"id":4,"subscription_time":"2026-10-01T00:00:00Z","obj":"poster42","level":1,"te\#
            xt":"收藏话题"},{"id":5,"subscription_time":"","obj":"paper17","level":3,"text":"收藏文章"\#
            }]
            """#
        let transport = Transport([(200, body)])
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                .init(identity: .init(accountIdentifier: "subscriptions"), cookie: "fixture")
            }, refresh: { _ in })
        let service = GalleryService(
            session: session,
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        let items = try await service.fetchSubscriptions(page: 2)
        #expect(items.map(\.level) == [.silent, .comment])
        #expect(items.first?.resource?.id == 42 && items.last?.resource?.kind == "paper")
        #expect(items.first?.subscriptionTime == "2026-10-01T00:00:00Z")
        #expect(transport.requests.first?.url?.query == "page=2")
        let counts = try JSONDecoder().decode(
            GalleryMessageUnreadCounts.self, from: Data(#"{"subscription":3}"#.utf8))
        #expect(counts.unreadCount(for: .subscription) == 3)
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: ["reaction/like", "user/follow/1"],
        ["sent", "before-send", "rejected"])
    func togglesClassifyUncertainBoundary(path: String, boundary: String) async {
        let transport = Transport([(400, "{}")])
        if boundary == "sent" { transport.failure = URLError(.networkConnectionLost) }
        if boundary == "before-send" {
            transport.failure = HTTPRequestNotSent(underlying: URLError(.cannotFindHost))
        }
        let api = CommunityAPIClient<CourseServiceError>(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "fixture",
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }
        )
        do {
            let _: CommunityLikeResult = try await api.request(
                path: path, method: "POST", mutation: .toggle)
            Issue.record("Toggle failure fixture must propagate its outcome")
        } catch {
            #expect((error is CommunityToggleOutcomeUnknown) == (boundary == "sent"))
        }
        #expect(transport.requests.count == 1)
    }
    #if os(macOS)
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "gallery.newest", "gallery.following", "gallery.hot", "gallery.recommend",
            "gallery.bots", "gallery.search", "gallery.subscriptions",
        ])
    func productionGalleryRequestsPassContract(probe: String) async throws {
        let transport = Transport(
            Array(repeating: (200, "[]"), count: probe == "gallery.search" ? 16 : 10))
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://bit101.flwfdd.xyz"),
            credentials: {
                .init(identity: .init(accountIdentifier: "contracts"), cookie: "fixture")
            }, refresh: { _ in })
        let service = GalleryService(
            session: session,
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        var requests: [(URLRequest, HTTPResponse)] = []
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in
            requests.append((request, response))
        }) {
            for page in 0...1 {
                try await exerciseServiceProbe(probe: probe, service: service, page: page)
            }
        }
        try await assertSmokeContract(
            probe: probe, requests: requests,
            selectors: probe == "gallery.search"
                ? ["search": "BIT101", "excludedSearch": "excluded"] : [:])
    }

    func exerciseServiceProbe(
        probe: String,
        service: GalleryService,
        page: Int
    ) async throws {
        switch probe {
        case "gallery.search":
            for keyword in [" BIT101 ", " excluded "] {
                for order in GallerySearchOrder.allCases {
                    let pageArg = page == 0 ? nil : page
                    _ = try await service.searchPosters(
                        query: .init(text: keyword, order: order),
                        page: pageArg)
                }
            }
            for order in [GallerySearchOrder.like, .newest] {
                _ = try await service.searchPosters(
                    query: .init(text: "", order: order), page: page)
            }
        case "gallery.recommend":
            _ = try await service.fetchRecommendPage(sourcePage: page)
        case "gallery.subscriptions":
            _ = try await service.fetchSubscriptions(page: page)
        case "gallery.bots":
            _ = try await service.fetchBotFeed(startPage: page)
        default:
            let kind: GalleryFeedKind
            if probe == "gallery.following" {
                kind = .follow
            } else if probe == "gallery.hot" {
                kind = .hot
            } else {
                kind = .newest
            }
            let pageArg = page == 0 ? nil : page
            _ = try await service.fetchFeed(kind: kind, page: pageArg)
        }
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: ["paper.detail", "paper.comments"], [false, true])
    func productionPaperRequestsPassPythonContract(probe: String, authenticated: Bool)
        async throws
    {
        let transport = Transport(
            probe == "paper.detail"
                ? [(200, paperDetailBody(own: authenticated))]
                : Array(repeating: (200, "[]"), count: 6))
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://bit101.flwfdd.xyz"),
            credentials: {
                .init(
                    identity: .init(accountIdentifier: "contracts"),
                    cookie: authenticated ? "fixture" : "")
            }, refresh: { _ in })
        let service = PaperService(session: session)
        var requests: [(URLRequest, HTTPResponse)] = []
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in
            requests.append((request, response))
        }) {
            if probe == "paper.detail" {
                _ = try await service.fetchPaper(id: 17)
            } else {
                for order in CommunityCommentOrder.allCases {
                    for page in 0...1 {
                        _ = try await service.fetchComments(
                            paperID: 17, order: order, page: page)
                    }
                }
            }
        }
        #expect(transport.authenticationRequests.isEmpty)
        try await assertSmokeContract(
            probe: probe, requests: requests,
            selectors: probe == "paper.detail" ? ["path": "/papers/17"] : ["obj": "paper17"])
    }

    func assertSmokeContract(
        probe: String, requests: [(URLRequest, HTTPResponse)], selectors: [String: String] = [:]
    ) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let rows = try requests.map { request, response in
            let metadata = HTTPRequestEvidence(
                request: request, response: response.response,
                finalRequest: response.finalRequest)
            var row = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
                    as? [String: Any])
            func parameters(_ request: URLRequest) throws -> [String: String] {
                let items =
                    URLComponents(
                        url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems ?? []
                let allowed = [
                    "page", "order", "search", "hide_bot", "obj", "mode", "type", "uid",
                ]
                #expect(Set(items.map(\.name)).count == items.count)
                var result = items.reduce(into: [String: String]()) {
                    $0[$1.name] = allowed.contains($1.name) ? $1.value ?? "" : "[REDACTED]"
                }
                if let data = request.httpBody,
                    let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any], let value = object["obj"] as? String
                {
                    result["obj"] = value
                }
                return result
            }
            row["query"] = try parameters(request)
            row["finalQuery"] = try parameters(response.finalRequest ?? request)
            if response.data == Data("[]".utf8) { row["responseMinimumID"] = "0" }
            return row
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "probe": probe, "requests": rows, "expectedParameters": selectors,
        ])
        let result = try await Self.runSmokeContract(
            payload, script: root.appendingPathComponent("Scripts/network_request_contracts.py")
        )
        #expect(result.status == 0, Comment(rawValue: result.error))
    }

    @concurrent
    static func runSmokeContract(_ payload: Data, script: URL) async throws -> (
        status: Int32, error: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-B", script.path]
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        let (completion, finished) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            finished.yield(())
            finished.finish()
        }
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        var iterator = completion.makeAsyncIterator()
        _ = await iterator.next()
        return (
            process.terminationStatus,
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
    #endif

    @Test(.timeLimit(.minutes(1))) func repeatedCommentPagesAdvanceUntilNewContent() async throws {
        func comment(_ id: Int) -> String {
            #"""
            {"id":\#(id),"obj":"poster1","images":[],"user":\#(user),"anonymous":false,"create\#
            _time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"r\#
            ate":0,"reply_user":\#(user),"reply_obj":"","text":"评论","sub":[]}
            """#
        }
        let transport = Transport([1, 1, 1, 2].map { (200, "[" + comment($0) + "]") })
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let model = GalleryPosterDetailViewModel(
            initialPoster: try decoder.decode(CommunityPoster.self, from: Data(poster(id: 1).utf8)),
            service: GalleryService(
                session: session(transport),
                preferences: {
                    .init(
                        hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                        hideMakeupOutliers: false)
                }))
        await model.refreshComments()
        await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
        #expect(
            model.commentState.items.map(\.id) == [1, 2] && model.commentState.nextPage == 4
                && !model.commentState.isLoadingMore)
        #expect(try transport.requests.map { try query($0)["page"] } == [nil, "1", "2", "3"])
    }

    @Test func galleryWebCredentialsUseTrustedHttpsOrigin() {
        for address in ["https://bit101.cn/gallery", "https://BIT101.cn:443/paper/42"] {
            #expect(GalleryWebRequestFactory.isTrustedPage(URL(string: address)))
        }
        for address in [
            "http://bit101.cn/gallery", "https://bit101.cn:444/gallery",
            "https://bit101.cn.example.invalid/", "https://example.invalid/?next=https://bit101.cn",
            "https://bit101.cn@example.invalid", "file:///gallery",
        ] {
            #expect(!GalleryWebRequestFactory.isTrustedPage(URL(string: address)))
        }
        #expect(!GalleryWebRequestFactory.isTrustedPage(nil))
    }

    final class Transport: HTTPTransport {
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
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try Task.checkCancellation()
            if request.url?.path == "/user/check" {
                authenticationRequests.append(request)
                let status =
                    authenticationStatuses.isEmpty ? 200 : authenticationStatuses.removeFirst()
                let url = try #require(request.url)
                return (
                    Data(),
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: status,
                            httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                )
            }
            requests.append(request)
            if let failure { throw failure }
            let response: (Int, String)
            if let responseForRequest {
                response = try responseForRequest(request)
            } else {
                response = try #require(responses.first)
                responses.removeFirst()
            }
            let url = try #require(request.url)
            return (
                Data(response.1.utf8),
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: response.0,
                        httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            )
        }
    }

    let course =
        #"""
        {"id":42,"name":"操作系统","number":"CS101","credits":"3.5","like_num":7,"comment_num":2,"\#
        rate":9.2,"teachers_name":"教师","teachers_number":"T1"}
        """#
    let paper =
        #"""
        {"id":17,"title":"文章","intro":"摘要","like_num":3,"comment_num":4,"update_time":"2026-09\#
        -01T08:00:00Z"}
        """#
    let user =
        #"""
        {"id":1,"create_time":"","nickname":"作者","avatar":{"mid":"avatar","url":"https://examp\#
        le.invalid/avatar","low_url":"https://example.invalid/small"},"motto":"","identity":{"\#
        id":0,"color":"","text":"","create_time":"","update_time":""}}
        """#

    func poster(id: Int, anonymous: Bool = false, bot: Bool = false, userID: Int = 1)
        -> String
    {
        let author = user.replacingOccurrences(of: "\"id\":1", with: "\"id\":\(userID)")
        return
            """
            {\"id\":\(id),\"anonymous\":\(anonymous),\"claim\":{\"id\":0,\"text\":\"\"},\"comme\
            nt_num\":0,\"create_time\":\"\",\"edit_time\":\"\",\"images\":[],\"like_num\":0,\"p\
            ublic\":true,\"tags\":\(bot ? "[\"bot\"]" : "[]"),\"text\":\"fixture\",\"title\":\"\
            fixture\",\"update_time\":\"\",\"user\":\(author)}
            """
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["anonymous", "blocked", "bots"])
    func filteredSourcePagesAdvanceFeed(setting: String) async throws {
        let hidden = poster(id: 1, anonymous: setting == "anonymous", bot: setting == "bots")
        let visible = poster(id: 2, userID: 2)
        for search in [false, true] {
            let transport = Transport([
                (200, "[" + hidden + "]"), (200, "[" + visible + "]"), (200, "[]"),
            ])
            let service = GalleryService(
                session: session(transport),
                preferences: {
                    CommunityPreferenceSnapshot(
                        hideBots: setting == "bots", hiddenUserIDs: setting == "blocked" ? [1] : [],
                        hideAnonymous: setting == "anonymous", useWebView: false,
                        hideMakeupOutliers: false)
                })
            let model = GalleryViewModel(service: service)
            if search { await model.performSearch() } else { await model.refresh(feed: .newest) }
            let state = search ? model.searchState : model.state(for: .newest)
            #expect(state.posters.map(\.id) == [2])
            #expect(state.nextPage == 2 && state.canLoadMore)
            if search {
                await model.loadMoreSearchResults(currentPoster: state.posters.last)
            } else {
                await model.loadMoreIfNeeded(for: .newest, currentPoster: state.posters.last)
            }
            let end = search ? model.searchState : model.state(for: .newest)
            #expect(end.nextPage == 3 && end.canLoadMore == false)
            #expect(try query(transport.requests[1])["page"] == "1")
            #expect(try query(transport.requests[2])["page"] == "2")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func botBatchesDeduplicatePages(hideBots: Bool) async throws {
        let first = poster(id: 1, bot: true)
        let second = poster(id: 2, bot: true).replacingOccurrences(
            of: "[\"bot\"]", with: "[\"新闻\"]")
        let third = poster(id: 3, bot: true).replacingOccurrences(
            of: "[\"bot\"]", with: "[\"RoBoT\"]")
        let transport = Transport([
            (200, "[" + poster(id: 9) + "," + first + "," + second + "]"),
            (200, "[" + second + "," + third + "]"), (200, "[]"),
        ])
        let service = GalleryService(
            session: session(transport),
            preferences: {
                .init(
                    hideBots: hideBots, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        let batch = try await service.fetchBotFeed(startPage: 0)
        #expect(
            batch.items.map(\.id) == [1, 2, 3] && batch.nextSourcePage == 3 && !batch.canLoadMore)
        #expect(batch.sourceIDs == [9, 1, 2, 2, 3])
        #expect(try transport.requests.map { try query($0)["page"] } == [nil, "1", "2"])
        #expect(try transport.requests.allSatisfy { try query($0)["hide_bot"] == nil })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func botFilteringPreservesCursorAcrossBatches(fails: Bool) async throws {
        let hidden = (1...5).map { poster(id: $0, bot: true) }
        let visible = poster(id: 8, bot: true, userID: 2)
        let tail = fails ? [(503, "{}"), (200, "[]")] : [(200, "[]")]
        let transport = Transport(
            hidden.map { (200, "[" + $0 + "]") } + [(200, "[" + visible + "]")] + tail)
        let service = GalleryService(
            session: session(transport),
            preferences: {
                CommunityPreferenceSnapshot(
                    hideBots: false, hiddenUserIDs: [1], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        let batch = try await service.fetchBotFeed(startPage: 0)
        #expect(batch.items.isEmpty && batch.sourceIDs == Array(1...5))
        #expect(batch.nextSourcePage == 5 && batch.canLoadMore && transport.requests.count == 5)
        let end = try await service.fetchBotFeed(startPage: batch.nextSourcePage)
        #expect(
            end.items.map(\.id) == [8] && end.nextSourcePage == (fails ? 6 : 7)
                && end.canLoadMore == fails)
        #expect(transport.requests.count == 7)
        if fails {
            let retry = try await service.fetchBotFeed(startPage: end.nextSourcePage)
            #expect(retry.items.isEmpty && retry.nextSourcePage == 7 && !retry.canLoadMore)
            #expect(transport.requests.count == 8)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["feed", "bot", "recommend", "comments"])
    func repeatedFilteredPagesState(kind: String) async throws {
        let hidden = poster(id: 1, anonymous: true)
        let comment =
            #"""
            {"id":5,"obj":"poster1","images":[],"user":\#(user),"anonymous":true,"create_time"\#
            :"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":0\#
            ,"reply_user":\#(user),"reply_obj":"","text":"fixture","sub":[]}
            """#
        let transport = Transport(
            Array(repeating: (200, "[" + (kind == "comments" ? comment : hidden) + "]"), count: 8))
        let service = GalleryService(
            session: session(transport),
            preferences: {
                CommunityPreferenceSnapshot(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: true, useWebView: false,
                    hideMakeupOutliers: false)
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
                default:
                    _ = try await service.fetchComments(
                        objectID: "poster1", order: .newest, page: nil)
                }
            }
        }
        #expect(transport.requests.count == 5)
    }

    @Test(.timeLimit(.minutes(1))) func posterUpdateRetainsPluginPayloadOnWire() async throws {
        let transport = Transport([(200, "")])
        let plugins = #"[{"type":"future","data":{"text":"preserved"}}]"#
        try await GalleryService(
            session: session(transport),
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            }
        ).updatePoster(
            id: 42, title: "编辑", text: "正文", imageMids: [], plugins: plugins,
            anonymous: false, tags: [], claimID: 0, isPublic: true)
        let body = try #require(transport.requests.first?.httpBody)
        #expect(
            (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["plugins"] as? String
                == plugins)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["feed", "search", "comments"])
    func longFilteredRunsYieldAtBudget(kind: String) async throws {
        func comment(_ id: Int, hidden: Bool) -> String {
            #"""
            {"id":\#(id),"obj":"poster1","images":[],"user":\#(user),"anonymous":\#(hidden),"c\#
            reate_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":tr\#
            ue,"rate":0,"reply_user":\#(user),"reply_obj":"","text":"fixture","sub":[]}
            """#
        }
        let rows =
            (1...5).map {
                kind == "comments" ? comment($0, hidden: true) : poster(id: $0, anonymous: true)
            }
            + [kind == "comments" ? comment(6, hidden: false) : poster(id: 6)]
        let transport = Transport(rows.map { (200, "[" + $0 + "]") } + [(200, "[]")])
        let service = GalleryService(
            session: session(transport),
            preferences: {
                CommunityPreferenceSnapshot(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: true, useWebView: false,
                    hideMakeupOutliers: false)
            })
        if kind == "comments" {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let initial = try decoder.decode(CommunityPoster.self, from: Data(poster(id: 1).utf8))
            let model = GalleryPosterDetailViewModel(initialPoster: initial, service: service)
            await model.refreshComments()
            #expect(
                model.commentState.items.isEmpty && model.commentState.nextPage == 5
                    && model.commentState.canLoadMore)
            #expect(transport.requests.count == 5)
            await model.loadMoreCommentsIfNeeded(currentComment: nil)
            #expect(model.commentState.items.map(\.id) == [6] && model.commentState.nextPage == 6)
            await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
            #expect(!model.commentState.canLoadMore)
        } else {
            let model = GalleryViewModel(service: service)
            if kind == "search" {
                await model.performSearch()
            } else {
                await model.refresh(feed: .newest)
            }
            let first = kind == "search" ? model.searchState : model.state(for: .newest)
            #expect(first.posters.isEmpty && first.nextPage == 5 && first.canLoadMore)
            #expect(transport.requests.count == 5)
            if kind == "search" {
                await model.enqueueSearchLoadMore(currentPoster: nil).value
            } else {
                await model.loadMoreIfNeeded(for: .newest, currentPoster: nil)
            }
            let next = kind == "search" ? model.searchState : model.state(for: .newest)
            #expect(next.posters.map(\.id) == [6] && next.nextPage == 6)
            if kind == "search" {
                await model.enqueueSearchLoadMore(currentPoster: next.posters.last).value
            } else {
                await model.loadMoreIfNeeded(for: .newest, currentPoster: next.posters.last)
            }
            #expect(!(kind == "search" ? model.searchState : model.state(for: .newest)).canLoadMore)
        }
        #expect(transport.requests.count == 7)
    }

    @Test(.timeLimit(.minutes(1))) func filteredCommentPagesRemainsAvailable() async throws {
        let comment =
            #"""
            {"id":5,"obj":"poster1","images":[],"user":\#(user),"anonymous":false,"create_time\#
            ":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":\#
            0,"reply_user":\#(user),"reply_obj":"","text":"fixture","sub":[]}
            """#
        let hidden = comment.replacingOccurrences(
            of: "\"anonymous\":false", with: "\"anonymous\":true")
        let transport = Transport([
            (200, "[" + hidden + "]"), (200, "[" + comment + "]"), (200, "[]"),
            (200, "[" + hidden + "]"),
        ])
        let service = GalleryService(
            session: session(transport),
            preferences: {
                CommunityPreferenceSnapshot(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: true, useWebView: false,
                    hideMakeupOutliers: false)
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
    func messageHistoryCanStartAtUpperBound(type: GalleryMessageType) async throws {
        let transport = Transport([(200, "[]")])
        let service = GalleryService(
            session: session(transport),
            preferences: {
                CommunityPreferenceSnapshot(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
                    useWebView: false, hideMakeupOutliers: false)
            })
        #expect(try await service.fetchMessages(type: type, lastID: .max).isEmpty)
        #expect(
            try query(transport.requests[0]) == ["type": type.rawValue, "last_id": String(Int.max)])
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: GalleryMessageType.allCases,
        [[89, 80], [], [95], [90], [80, 89], [89, 89], [0]])
    func messageHistoryRequiresStrictlyOlderPages(type: GalleryMessageType, ids: [Int]) async throws
    {
        let messages = ids.map { id in
            #"""
            {"id":\#(id),"from_user":{},"link_obj":"poster1","obj":"poster1","text":"消息","upda\#
            te_time":""}
            """#
        }
        let transport = Transport([(200, "[" + messages.joined(separator: ",") + "]")])
        let observer = ResponseObserver()
        let service = GalleryService(
            session: session(transport, observer: observer),
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        if ids == [89, 80] || ids.isEmpty {
            #expect(try await service.fetchMessages(type: type, lastID: 90).map(\.id) == ids)
        } else {
            await #expect(throws: GalleryServiceError.self) {
                try await service.fetchMessages(type: type, lastID: 90)
            }
        }
        #expect(try query(transport.requests[0]) == ["type": type.rawValue, "last_id": "90"])
        #expect(observer.failures == (ids == [89, 80] || ids.isEmpty ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)), arguments: GalleryMessageType.allCases)
    func messageCategoriesKeepPages(type: GalleryMessageType) async throws {
        func page(_ ids: [Int]) -> String {
            let rows = ids.map { id in
                #"""
                {"id":\#(id),"from_user":{},"link_obj":"poster\#(id)","obj":"poster\#(id)","te\#
                xt":"消息","update_time":"2026-10-01T00:00:00Z"}
                """#
            }
            return "[" + rows.joined(separator: ",") + "]"
        }
        let transport = Transport([[90, 80], [90, 80], [70, 60], []].map { (200, page($0)) })
        let service = GalleryService(
            session: session(transport),
            preferences: {
                .init(
                    hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                    hideMakeupOutliers: false)
            })
        for (cursor, ids) in [
            (nil as Int?, [90, 80]), (Int.max, [90, 80]), (80, [70, 60]), (60, []),
        ] {
            let messages = try await service.fetchMessages(type: type, lastID: cursor)
            #expect(
                messages.map(\.id) == ids && messages.compactMap { $0.linkedResource?.id } == ids)
            let request = try #require(transport.requests.last)
            #expect(request.url?.path == "/messages")
            var expected = ["type": type.rawValue]
            if let cursor { expected["last_id"] = String(cursor) }
            #expect(try query(request) == expected)
        }
        #expect(transport.requests.count == 4)
    }

    @Test(.timeLimit(.minutes(1))) func commentOrdersUseDistinctSamples() async throws {
        func comment(_ id: Int) -> String {
            #"""
            {"id":\#(id),"obj":"poster1","images":[],"user":\#(user),"anonymous":false,"create\#
            _time":"2026-10-0\#(4 - id)T00:00:00Z","update_time":"2026-10-01T00:00:00Z","like"\#
            :false,"like_num":\#(id == 2 ? 9 : id == 3 ? 6 : 3),"comment_num":0,"own":true,"ra\#
            te":0,"reply_user":\#(user),"reply_obj":"","text":"评论\#(id)","sub":[]}
            """#
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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let initial = try decoder.decode(CommunityPoster.self, from: Data(poster(id: 1).utf8))
        let model = GalleryPosterDetailViewModel(
            initialPoster: initial,
            service: GalleryService(
                session: session(transport),
                preferences: {
                    .init(
                        hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false,
                        hideMakeupOutliers: false)
                }))
        for order in [CommunityCommentOrder.newest, .oldest, .like, .newest] {
            let ids = try #require(ranked[order.rawValue])
            let start = transport.requests.count
            if model.commentState.status == .idle {
                await model.refreshComments()
            } else {
                await model.setCommentOrder(order)
            }
            #expect(
                model.commentOrder == order
                    && model.commentState.items.map(\.id) == Array(ids.prefix(2)))
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
            #expect(
                try requests.allSatisfy {
                    try query($0)["order"] == order.rawValue && query($0)["obj"] == "poster1"
                })
        }
    }

    func session(
        _ transport: Transport, cookie: String = "fixture-cookie",
        observer: (any HTTPClientObserving)? = nil
    ) -> CommunitySession {
        CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: observer),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "contracts"), cookie: cookie) },
            refresh: { _ in })
    }

    func paperDetailBody(own: Bool, title: String = "文章") -> String {
        """
        {\"id\":17,\"title\":\"\(title)\",\"intro\":\"摘要\",\"content\":\"正文\",\"create_time\":\
        \"\",\"update_time\":\"\",\"update_user\":\(user),\"anonymous\":false,\"like_num\":3,\"\
        comment_num\":0,\"public_edit\":false,\"like\":\(own),\"own\":\(own)}
        """
    }

    func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

}
