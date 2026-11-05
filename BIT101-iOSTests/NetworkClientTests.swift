import ClientCore
import CommunityTransport
import Foundation
import ScheduleDomain
import SchedulePorts
import ScoreDomain
import ScoreInfrastructure
import Testing

@testable import BIT101_iOS
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
@testable import TransportCore

final class MockHTTPTransport: HTTPTransport {
    let handler: (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

@MainActor
final class StubNetworkPathProvider: NetworkPathProviding {
    let snapshot: NetworkConnectionSnapshot

    init(snapshot: NetworkConnectionSnapshot) {
        self.snapshot = snapshot
    }
}

nonisolated enum TestCommunityError: LocalizedError, CommunityAPIServiceError, Equatable {
    case notLoggedIn
    case invalidResponse
    static var communityNotLoggedIn: Self { .notLoggedIn }
    static var communityInvalidResponse: Self { .invalidResponse }
    var errorDescription: String? { "测试社区响应解析失败。" }
}

func makeTestURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else { throw URLError(.badURL) }
    return url
}

@Suite("Network stack")
struct NetworkClientTests {
    @Test(.timeLimit(.minutes(1))) @MainActor func schoolResponseDecodingRetainsFieldPath()
        async throws
    {
        let credentials = ScoreCredentials()
        let transport = MockHTTPTransport { request in
            let url = try #require(request.url)
            return (
                Data(#"{"required":7}"#.utf8),
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200,
                        httpVersion: nil, headerFields: nil))
            )
        }
        let service = ScheduleService(
            credentials: credentials, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer(restore: {
                credentials.currentStudentID
            }),
            teachingCenterState: TeachingCenterSessionState(
                cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)),
            transport: transport)
        do {
            let _: [String: String] = try await service.sendJSONRequest(path: "decoding-contract")
            Issue.record("响应类型差异应携带字段诊断")
        } catch {
            let failure = error as NSError
            let underlying = try #require(failure.userInfo[NSUnderlyingErrorKey] as? DecodingError)
            if case .typeMismatch(_, let context) = underlying {
                #expect(context.codingPath.map(\.stringValue) == ["required"])
            } else {
                Issue.record("诊断应保留实际字段类型差异")
            }
            #expect(
                failure.localizedDescription
                    == ScheduleServiceError.invalidResponse.localizedDescription)
        }
    }

    @Test("Classroom warmup and session retry preserve the requested date", .timeLimit(.minutes(1)))
    @MainActor
    func classroomRetryPreservesQueryDate() async throws {
        let queryDate = try #require(ScheduleDateCodec.parseDate("2001-01-01"))
        let credentials = ScoreCredentials()
        let state = TeachingCenterSessionState(
            cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        state.markDirectPreferred(for: credentials.currentStudentID)
        var dates: [String] = []
        var restorations = 0
        let transport = MockHTTPTransport { request in
            let url = try #require(request.url)
            var status = 200
            var payload = "{}"
            if url.path.hasSuffix("/cxkxjasqk.do") {
                let body = try #require(request.httpBody)
                let query = try #require(
                    URLComponents(
                        string: "https://example.invalid?" + String(decoding: body, as: UTF8.self)))
                dates.append(try #require(query.queryItems?.first { $0.name == "RQ" }?.value))
                status = dates.count == 1 ? 401 : 200
                payload = #"{"datas":{"cxkxjasqk":{"rows":[]}}}"#
            }
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(payload.utf8), response)
        }
        let service = ScheduleService(
            credentials: credentials, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer(restore: {
                restorations += 1
                return credentials.currentStudentID
            }),
            teachingCenterState: state, transport: transport)
        let rows = try await service.fetchClassrooms(
            buildingID: "fixture", term: "2026-2027-1", date: queryDate)
        #expect(rows.isEmpty)
        #expect(dates == ["2001-01-01", "2001-01-01"])
        #expect(restorations == 1)
        #expect(
            try await service.prefetchClassrooms(
                buildingID: "fixture", term: "2026-2027-1", date: queryDate)?.isEmpty == true)
        #expect(dates.count == 3 && restorations == 1)
        dates.removeAll()
        state.invalidate()
        #expect(
            try await service.prefetchClassrooms(
                buildingID: "fixture", term: "2026-2027-1", date: queryDate) == nil)
        #expect(dates.isEmpty)
        state.markDirectPreferred(for: credentials.currentStudentID)
        state.markPrepared(for: credentials.currentStudentID)
        do {
            _ = try await service.prefetchClassrooms(
                buildingID: "fixture", term: "2026-2027-1", date: queryDate)
            Issue.record("过期会话预取应交回失败结果")
        } catch ScheduleServiceError.teachingCenterSessionExpired {
            #expect(dates == ["2001-01-01"] && restorations == 1)
        }
    }

    @Test("The Eclass snapshot deadline cancels an active transport", .timeLimit(.minutes(1)))
    @MainActor
    func eclassDeadlineCancelsTheActiveTransport() async throws {
        let transport = EclassTimeoutTransport()
        let credentials = ScoreCredentials()
        let service = ScheduleService(
            credentials: credentials, crypto: AppScheduleServiceCrypto(),
            schoolSessionRestorer: AppScheduleSchoolSessionRestorer(restore: {
                Issue.record("Unexpected authentication restoration")
                return nil
            }),
            teachingCenterState: TeachingCenterSessionState(
                cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)),
            transport: transport)
        do {
            _ = try await service.fetchEclassSnapshot(
                owner: credentials.schoolSessionIdentity,
                budget: EclassSnapshotBudget(wait: { _ in
                    try await waitForTestEvent { transport.started }
                }))
            Issue.record("Expected the complete snapshot deadline")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(transport.started && transport.cancelled)
    }

    @Test(
        "Eclass decoding keeps task context and runs away from the main thread",
        .timeLimit(.minutes(1)))
    @MainActor
    func eclassDecodingRunsInBackground() async throws {
        let result: EclassDecodingProbe = try await EclassDecodingContext.$token.withValue(
            "snapshot"
        ) {
            try await ScheduleService.decodeEclassResponse(Data("{}".utf8))
        }
        #expect(result.token == "snapshot")
        #expect(result.leftMainThread)
    }

    @Test(
        "Large Eclass activity mapping allows the main actor to process work",
        .timeLimit(.minutes(1)))
    @MainActor
    func eclassLargeMappingKeepsMainActorResponsive() async throws {
        let json =
            "{\"activities\":["
            + (1...16_384).map {
                """
                {\"id\":\($0),\"title\":\"作业\",\"submit_times\":1,\"end_time\":\"2030-10-01 23:\
                59:00\"}
                """
            }.joined(separator: ",") + "]}"
        let page: EclassActivityPage = try await ScheduleService.decodeEclassResponse(
            Data(json.utf8))
        var started = false
        var finished = false
        let mapping = Task {
            started = true
            defer { finished = true }
            return try await ScheduleService.mapEclassActivities(page, courseName: "课程")
        }
        try await waitForTestEvent { started }
        var heartbeats = 0
        while !finished {
            heartbeats += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        let result = try await mapping.value
        #expect(result.events.count == 16_384)
        #expect(heartbeats > 0)
    }

    @Test(
        "Smoke requests bind actual responses to the operation and redact URL credentials",
        .timeLimit(.minutes(1)))
    @MainActor
    func smokeEvidenceRequiresTransport() async throws {
        let url = try makeTestURL(
            "https://student:password@example.invalid/probe?token=secret#private")
        let state = TeachingCenterSessionState(
            cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        var sends = 0
        let transport = SchoolCookieTransport(state: state) { _ in
            MockHTTPTransport { _ in
                sends += 1
                return (
                    Data(),
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
                )
            }
        }
        let client = HTTPClient(transport: transport, observer: nil)
        let collector = NetworkSmokeRequestCollector()
        await #expect(throws: NetworkSmokeRequestError.self) {
            try await collector.perform({ 1 }, required: true)
        }
        #expect(collector.requests.isEmpty)
        _ = try await collector.perform(
            {
                await #expect(throws: HTTPClientError.self) {
                    try await client.send(URLRequest(url: url))
                }
                return 1
            }, required: true)
        let evidence = try #require(collector.requests.first)
        #expect(evidence.endpoint == "https://example.invalid/probe")
        #expect(evidence.method == "GET" && evidence.statusCode == 401)
        #expect(HTTPRequestEvidenceContext.didReceive == nil)
        await #expect(throws: HTTPClientError.self) { try await client.send(URLRequest(url: url)) }
        #expect(collector.requests.count == 1)
        #expect(sends == 2)
    }

    final class ScoreCredentials: SchoolCredentialsProviding {
        var schoolSessionIdentity = SchoolSessionIdentity(
            accountIdentifier: "score-contract", generation: 0)
        var currentStudentID: String { schoolSessionIdentity.accountIdentifier }
        var currentPassword: String { "fixture-password" }
    }

    @Test(
        "Score authentication preserves its owner through the host transport contract",
        .timeLimit(.minutes(1)))
    @MainActor
    func scoreChallengeAndUseAccountGeneration() async throws {
        let credentials = ScoreCredentials()
        var requests: [URLRequest] = []
        let client = HTTPClient(
            transport: MockHTTPTransport { request in
                requests.append(request)
                let url = try #require(request.url)
                #expect(request.httpMethod == "POST")
                let data: Data
                if url.path.hasSuffix("/start") {
                    data = Data(
                        #"""
                        {"challenge_id":"fixture","access_token":"token","status":"authenticat\#
                        ed","expires_in":120}
                        """#
                        .utf8)
                } else {
                    #expect(url.path == "/api/jwb/bit101/score")
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
                    let body = try #require(request.httpBody)
                    let payload = try #require(
                        JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(payload["challenge_id"] as? String == "fixture")
                    #expect(payload["detail"] as? Bool == false)
                    data = Data(
                        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["功能验收","C1","80","2"]]}"#
                            .utf8)
                }
                return (
                    data,
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            }, observer: nil)
        let service = ScoreService(
            credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        let challenge = try await service.startScoreChallenge()
        #expect(challenge.ownerIdentity == credentials.schoolSessionIdentity)
        let rows = try await service.fetchScores(detail: false, authenticatedBy: challenge)
        #expect(rows.first?.score == "80")
        credentials.schoolSessionIdentity = .init(
            accountIdentifier: "score-contract", generation: 1)
        await #expect(throws: CancellationError.self) {
            try await service.fetchScores(detail: true, authenticatedBy: challenge)
        }
        #expect(requests.count == 2)
    }

    @Test(
        "Network smoke overrides cache reads and preserves request authentication",
        .timeLimit(.minutes(1)))
    @MainActor
    func smokeTransportReadsRemoteData() async throws {
        let url = try makeTestURL("https://example.invalid/cached")
        var captured: URLRequest?
        let transport = UncachedHTTPTransport(
            base: MockHTTPTransport { request in
                captured = request
                return (
                    Data("remote".utf8),
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            })
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad)
        request.httpMethod = "POST"
        request.httpBody = Data("payload".utf8)
        request.setValue("session=fixture", forHTTPHeaderField: "Cookie")
        let (data, _) = try await transport.data(for: request)
        #expect(data == Data("remote".utf8))
        #expect(captured?.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(
            captured?.httpMethod == request.httpMethod && captured?.httpBody == request.httpBody)
        #expect(captured?.value(forHTTPHeaderField: "Cookie") == "session=fixture")
        #expect(request.cachePolicy == .returnCacheDataDontLoad)
    }

    nonisolated private struct UserPayload: Decodable, Equatable, Sendable {
        let displayName: String
    }

    nonisolated struct SchoolProbePayload: Decodable, Equatable, Sendable {
        let accepted: Bool
    }

    @Test("School network warning leaves the injected transport available", .timeLimit(.minutes(1)))
    @MainActor
    func networkWarningKeepsTransportAvailable() async throws {
        let provider = StubNetworkPathProvider(
            snapshot: NetworkConnectionSnapshot(
                summary: "已连接 · Wi‑Fi + 虚拟/未知接口",
                virtualNetworkLikely: true
            )
        )
        let coordinator = AppPromptCoordinator(advanceDelay: .zero)
        coordinator.markHostReady()
        let center = NetworkMagicWarningCenter(
            pathProvider: provider,
            promptCoordinator: coordinator,
            cooldown: 600
        )
        var transportStarted = false
        let transport = MockHTTPTransport { request in
            transportStarted = true
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(), response)
        }
        let request = URLRequest(url: try #require(URL(string: "https://sso.bit.edu.cn/cas/login")))
        let task = Task { @MainActor in
            try await HTTPClient(
                transport: transport,
                networkWarningCenter: center
            ).send(request)
        }
        defer {
            task.cancel()
            if let action = coordinator.activePrompt?.actions.first {
                coordinator.perform(action, promptID: coordinator.activePrompt?.id)
            }
        }

        try await waitForTestEvent { coordinator.activePrompt != nil && transportStarted }
        _ = try await task.value
        #expect(transportStarted)
        #expect(coordinator.activePrompt?.title == "检测到可能在使用魔法")
        #expect(coordinator.activePrompt?.message == "关闭食用效果更佳～")
        #expect(coordinator.activePrompt?.actions.map(\.title) == ["知道了"])

        let action = try #require(coordinator.activePrompt?.actions.first)
        coordinator.perform(action, promptID: coordinator.activePrompt?.id)
        _ = try await task.value
        #expect(transportStarted)
        #expect(await center.consider(url: URL(string: "https://open.aihelpme.dev")) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancelledRequestsKeepOtherRequests() async throws {
        let provider = StubNetworkPathProvider(
            snapshot: .init(summary: "virtual", virtualNetworkLikely: true))
        let coordinator = AppPromptCoordinator(advanceDelay: .zero)
        coordinator.markHostReady()
        let center = NetworkMagicWarningCenter(
            pathProvider: provider, promptCoordinator: coordinator)
        var sends = 0
        let transport = MockHTTPTransport { request in
            sends += 1
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: url, statusCode: 204,
                    httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
        let client = HTTPClient(transport: transport, networkWarningCenter: center)
        let request = URLRequest(url: AppURL.required("https://sso.bit.edu.cn/cas/login"))
        let cancelled = Task { try await client.send(request) }
        cancelled.cancel()
        let continuing = Task { try await client.send(request) }
        defer {
            cancelled.cancel()
            continuing.cancel()
            if let action = coordinator.activePrompt?.actions.first {
                coordinator.perform(action, promptID: coordinator.activePrompt?.id)
            }
        }
        try await waitForTestEvent { coordinator.activePrompt != nil }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        _ = try await continuing.value
        #expect(sends == 1)
        #expect(coordinator.activePrompt != nil)
        coordinator.perform(
            try #require(coordinator.activePrompt?.actions.first),
            promptID: coordinator.activePrompt?.id)
        _ = try await continuing.value
        #expect(sends == 1)
    }

    @Test("HTTP errors preserve structured server messages", .timeLimit(.minutes(1)))
    func structuredHTTPError() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(#"{"message":"稍后重试"}"#.utf8), response)
        }

        let request = URLRequest(url: try #require(URL(string: "https://example.com")))
        do {
            _ = try await HTTPClient(transport: transport).send(request)
            Issue.record("Expected an HTTP error")
        } catch let error as HTTPClientError {
            #expect(error.errorDescription == "稍后重试")
        }
    }

    @Test("HTTP client rejects non-HTTP responses", .timeLimit(.minutes(1)))
    func nonHTTPResponse() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            return (
                Data("response".utf8),
                URLResponse(
                    url: requestURL, mimeType: "text/plain", expectedContentLength: 8,
                    textEncodingName: nil)
            )
        }
        let request = URLRequest(url: try #require(URL(string: "https://example.com")))

        do {
            _ = try await HTTPClient(transport: transport).send(request)
            Issue.record("Expected a non-HTTP response error")
        } catch let error as HTTPClientError {
            guard case .invalidResponse = error else {
                Issue.record("Unexpected HTTP client error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("HTTP client honors the supplied status range", .timeLimit(.minutes(1)))
    func statusRangeBoundary() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(), response)
        }
        let request = URLRequest(url: try #require(URL(string: "https://example.com")))

        do {
            _ = try await HTTPClient(transport: transport).send(request)
            Issue.record("Expected the default range to reject HTTP 302")
        } catch let HTTPClientError.unacceptableStatus(code, _) {
            #expect(code == 302)
        }

        let response = try await HTTPClient(transport: transport).send(
            request, accepting: 100..<400)
        #expect(response.statusCode == 302)
    }

    @Test("HTTP client preserves transport errors", .timeLimit(.minutes(1)))
    func transportErrorPropagation() async throws {
        let transport = MockHTTPTransport { _ in throw URLError(.timedOut) }
        let request = URLRequest(url: try #require(URL(string: "https://example.com")))

        do {
            _ = try await HTTPClient(transport: transport).send(request)
            Issue.record("Expected the transport error to propagate")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("HTTP error messages accept backend keys and plain text")
    func errorMessageVariants() {
        #expect(
            HTTPClient.errorMessage(from: Data(#"{"msg":"message from msg"}"#.utf8))
                == "message from msg")
        #expect(
            HTTPClient.errorMessage(from: Data(#"{"detail":"message from detail"}"#.utf8))
                == "message from detail")
        #expect(
            HTTPClient.errorMessage(from: Data(#"{"error":"message from error"}"#.utf8))
                == "message from error")
        #expect(HTTPClient.errorMessage(from: Data("  plain response  ".utf8)) == "plain response")
        #expect(HTTPClient.errorMessage(from: Data()) == nil)
    }

    @Test(
        "Community decoding errors retain their field diagnostics", .timeLimit(.minutes(1)),
        arguments: ["not-json", "{}", "{\"display_name\":42}"])
    func communityMalformedJSON(payload: String) async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(payload.utf8), response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: "session-token")
            }
        )

        do {
            let _: UserPayload = try await api.request(path: "users")
            Issue.record("Expected a response decoding failure")
        } catch let error as NSError {
            let failure = TestCommunityError.invalidResponse as NSError
            #expect(
                error.domain == failure.domain && error.code == failure.code
                    && error.localizedDescription == failure.localizedDescription)
            #expect(error.userInfo[NSUnderlyingErrorKey] is DecodingError)
        }
    }

    @Test("Community requests apply auth, query and snake case decoding", .timeLimit(.minutes(1)))
    func communityRequestConstruction() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == "session-token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(
                URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems == [
                        URLQueryItem(name: "page", value: "2")
                    ])
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(#"{"display_name":"BIT101"}"#.utf8), response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: "session-token")
            }
        )

        let payload: UserPayload = try await api.request(
            path: "users",
            queryItems: [URLQueryItem(name: "page", value: "2")]
        )
        #expect(payload == UserPayload(displayName: "BIT101"))
    }

    @Test("Required authentication fails before transport", .timeLimit(.minutes(1)))
    func requiredAuthentication() async throws {
        let transport = MockHTTPTransport { _ in
            Issue.record("Transport must not run without authentication")
            throw TestCommunityError.invalidResponse
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: "")
            }
        )

        await #expect(throws: TestCommunityError.notLoggedIn) {
            let _: UserPayload = try await api.request(path: "users")
        }
    }

    @Test("Optional authentication omits an empty cookie", .timeLimit(.minutes(1)))
    func optionalAuthentication() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == nil)
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(#"{"display_name":"Guest"}"#.utf8), response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: "")
            }
        )

        let payload: UserPayload = try await api.request(
            path: "users",
            authentication: .optional
        )
        #expect(payload.displayName == "Guest")
    }

    @Test("Community 401 refreshes the session and retries once", .timeLimit(.minutes(1)))
    func community401RefreshesAndRetries() async throws {
        final class State {
            var cookie = "expired-token"
            var requestCount = 0
        }

        let state = State()
        let transport = MockHTTPTransport { request in
            state.requestCount += 1
            let requestURL = try #require(request.url)
            let statusCode = state.requestCount == 1 ? 401 : 200
            if state.requestCount == 2 {
                #expect(request.value(forHTTPHeaderField: "fake-cookie") == "refreshed-token")
            }
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                ))
            let body =
                statusCode == 200
                ? Data(#"{"display_name":"BIT101"}"#.utf8)
                : Data(#"{"message":"expired"}"#.utf8)
            return (body, response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: state.cookie)
            },
            refreshHandler: { _ in state.cookie = "refreshed-token" }
        )

        let payload: UserPayload = try await api.request(path: "users")
        #expect(payload == UserPayload(displayName: "BIT101"))
        #expect(state.requestCount == 2)
    }

    @Test("Community authentication retries one 401 exactly once", .timeLimit(.minutes(1)))
    func community401RetryLimit() async throws {
        final class State {
            var cookie = "expired-token"
            var requestCount = 0
            var refreshCount = 0
        }

        let state = State()
        let transport = MockHTTPTransport { request in
            state.requestCount += 1
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == state.cookie)
            let requestURL = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: requestURL,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                ))
            return (Data(#"{"message":"expired"}"#.utf8), response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            credentials: {
                CommunityCredentials(
                    identity: CommunitySessionIdentity(accountIdentifier: "test-account"),
                    cookie: state.cookie)
            },
            refreshHandler: { _ in
                state.refreshCount += 1
                state.cookie = "refreshed-token"
            }
        )

        await #expect(throws: TestCommunityError.notLoggedIn) {
            let _: UserPayload = try await api.request(path: "users")
        }

        #expect(state.requestCount == 2)
        #expect(state.refreshCount == 1)
    }

    @Test("Multipart payload keeps the backend file contract")
    func multipartPayload() {
        let multipart = MultipartFormData.jpegFile(
            data: Data([0x01, 0x02]),
            filename: "avatar.jpg"
        )
        let text = String(decoding: multipart.body, as: UTF8.self)

        #expect(multipart.contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(text.contains("name=\"file\"; filename=\"avatar.jpg\""))
        #expect(text.contains("Content-Type: image/jpeg"))
        #expect(text.hasSuffix("--\r\n"))
    }

    @Test("School URLs are resolved and upgraded through one policy")
    func secureSchoolURLResolution() throws {
        let insecure = try #require(URL(string: "http://example.com/path?q=1"))
        #expect(
            HTTPSURLUpgrade.upgradedURL(from: insecure).absoluteString
                == "https://example.com/path?q=1")
        for (source, expected) in [
            ("http://example.com:80/path?q=1", "https://example.com/path?q=1"),
            ("http://example.com:8080/path", "https://example.com:8080/path"),
            ("https://example.com:80/path", "https://example.com:80/path"),
        ] {
            #expect(HTTPSURLUpgrade.upgradedURLString(from: source) == expected)
        }

        let login = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))
        #expect(
            HTTPSURLUpgrade.resolvedURL(from: "/gate/cas-success", relativeTo: login)?
                .absoluteString
                == "https://sso.bit.edu.cn/gate/cas-success"
        )
    }

}

nonisolated enum EclassDecodingContext {
    @TaskLocal static var token = "missing"
}

@MainActor
final class EclassTimeoutTransport: HTTPTransport {
    var started = false
    var cancelled = false
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        started = true
        do { try await Task.sleep(for: .seconds(60)) } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        throw URLError(.networkConnectionLost)
    }
}

nonisolated struct EclassDecodingProbe: Decodable, Sendable {
    let token: String
    let leftMainThread: Bool
    init(from decoder: any Decoder) throws {
        token = EclassDecodingContext.token
        leftMainThread = !Thread.isMainThread
    }
}
