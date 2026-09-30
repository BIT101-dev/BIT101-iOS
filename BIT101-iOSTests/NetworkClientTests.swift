import ScheduleDomain
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
import TransportCore
import CommunityTransport
import ClientCore
import Foundation
import Testing
@testable import BIT101_iOS

private final class MockHTTPTransport: HTTPTransport {
    let handler: (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

@MainActor
private final class StubNetworkPathProvider: NetworkPathProviding {
    let snapshot: NetworkConnectionSnapshot

    init(snapshot: NetworkConnectionSnapshot) {
        self.snapshot = snapshot
    }
}

private enum TestCommunityError: LocalizedError, CommunityAPIServiceError {
    case notLoggedIn
    case invalidResponse

    static var communityNotLoggedIn: Self { .notLoggedIn }
    static var communityInvalidResponse: Self { .invalidResponse }
}

private func makeTestURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else { throw URLError(.badURL) }
    return url
}

@Suite("Network stack")
struct NetworkClientTests {
    nonisolated private struct UserPayload: Decodable, Equatable, Sendable {
        let displayName: String
    }

    nonisolated private struct SchoolProbePayload: Decodable, Equatable, Sendable {
        let accepted: Bool
    }

    @Test("School network warning gates the injected transport")
    @MainActor
    func networkWarningPrecedesTransport() async throws {
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
            let response = try #require(HTTPURLResponse(
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
                coordinator.perform(action)
            }
        }

        for _ in 0 ..< 100 where coordinator.activePrompt == nil {
            await Task.yield()
        }
        #expect(!transportStarted)
        #expect(coordinator.activePrompt?.title == "检测到可能在使用魔法")
        #expect(coordinator.activePrompt?.message == "关闭食用效果更佳～")
        #expect(coordinator.activePrompt?.actions.map(\.title) == ["知道了"])

        let action = try #require(coordinator.activePrompt?.actions.first)
        coordinator.perform(action)
        _ = try await task.value
        #expect(transportStarted)
        #expect(await center.consider(url: URL(string: "https://open.aihelpme.dev")) == false)
    }

    @Test("HTTP errors preserve structured server messages")
    func structuredHTTPError() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
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

    @Test("HTTP client rejects non-HTTP responses")
    func nonHTTPResponse() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            return (
                Data("response".utf8),
                URLResponse(url: requestURL, mimeType: "text/plain", expectedContentLength: 8, textEncodingName: nil)
            )
        }
        let request = URLRequest(url: try #require(URL(string: "https://example.com")))

        do {
            _ = try await HTTPClient(transport: transport).send(request)
            Issue.record("Expected a non-HTTP response error")
        } catch HTTPClientError.invalidResponse {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("HTTP client honors the supplied status range")
    func statusRangeBoundary() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
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

        let response = try await HTTPClient(transport: transport).send(request, accepting: 100 ..< 400)
        #expect(response.statusCode == 302)
    }

    @Test("HTTP client preserves transport errors")
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
        #expect(HTTPClient.errorMessage(from: Data(#"{"msg":"message from msg"}"#.utf8)) == "message from msg")
        #expect(HTTPClient.errorMessage(from: Data(#"{"detail":"message from detail"}"#.utf8)) == "message from detail")
        #expect(HTTPClient.errorMessage(from: Data(#"{"error":"message from error"}"#.utf8)) == "message from error")
        #expect(HTTPClient.errorMessage(from: Data("  plain response  ".utf8)) == "plain response")
        #expect(HTTPClient.errorMessage(from: Data()) == nil)
    }

    @Test("Community malformed JSON maps to the service response error")
    func communityMalformedJSON() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data("not-json".utf8), response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            fakeCookieProvider: { "session-token" }
        )

        do {
            let _: UserPayload = try await api.request(path: "users")
            Issue.record("Expected malformed JSON to fail")
        } catch TestCommunityError.invalidResponse {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Community requests apply auth, query and snake case decoding")
    func communityRequestConstruction() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == "session-token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == [
                URLQueryItem(name: "page", value: "2")
            ])
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
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
            fakeCookieProvider: { "session-token" }
        )

        let payload: UserPayload = try await api.request(
            path: "users",
            queryItems: [URLQueryItem(name: "page", value: "2")]
        )
        #expect(payload == UserPayload(displayName: "BIT101"))
    }

    @Test("Required authentication fails before transport")
    func requiredAuthentication() async throws {
        let transport = MockHTTPTransport { _ in
            Issue.record("Transport must not run without authentication")
            throw TestCommunityError.invalidResponse
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            fakeCookieProvider: { "" }
        )

        do {
            let _: UserPayload = try await api.request(path: "users")
            Issue.record("Expected authentication to fail")
        } catch TestCommunityError.notLoggedIn {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Optional authentication omits an empty cookie")
    func optionalAuthentication() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == nil)
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
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
            fakeCookieProvider: { "" }
        )

        let payload: UserPayload = try await api.request(
            path: "users",
            authentication: .optional
        )
        #expect(payload.displayName == "Guest")
    }

    @Test("Community 401 refreshes the session and retries once")
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
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ))
            let body = statusCode == 200
                ? Data(#"{"display_name":"BIT101"}"#.utf8)
                : Data(#"{"message":"expired"}"#.utf8)
            return (body, response)
        }
        let api = CommunityAPIClient<TestCommunityError>(
            httpClient: HTTPClient(transport: transport),
            baseURL: try #require(URL(string: "https://example.com")),
            errorDomain: "Test",
            fakeCookieProvider: { state.cookie },
            refreshHandler: { _ in state.cookie = "refreshed-token" }
        )

        let payload: UserPayload = try await api.request(path: "users")
        #expect(payload == UserPayload(displayName: "BIT101"))
        #expect(state.requestCount == 2)
    }

    @Test("Community authentication retries one 401 exactly once")
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
            let response = try #require(HTTPURLResponse(
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
            fakeCookieProvider: { state.cookie },
            refreshHandler: { _ in
                state.refreshCount += 1
                state.cookie = "refreshed-token"
            }
        )

        do {
            let _: UserPayload = try await api.request(path: "users")
            Issue.record("Expected the repeated 401 to end in an authentication error")
        } catch TestCommunityError.notLoggedIn {
        } catch {
            Issue.record("Unexpected error: \(error)")
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
        #expect(HTTPSURLUpgrade.upgradedURL(from: insecure).absoluteString == "https://example.com/path?q=1")

        let login = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))
        #expect(
            HTTPSURLUpgrade.resolvedURL(from: "/gate/cas-success", relativeTo: login)?.absoluteString
                == "https://sso.bit.edu.cn/gate/cas-success"
        )
    }

    @Test("School redirects upgrade HTTPS targets and isolate cross-origin credentials")
    func schoolRedirectPolicy() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let sourceURL = try #require(URL(string: "https://sso.bit.edu.cn/cas/login"))
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        ))
        let task = session.dataTask(with: sourceURL)
        let delegate = HTTPSUpgradingRedirectDelegate()

        var sameOriginResult: URLRequest?
        var sameOriginRequest = URLRequest(url: try #require(URL(string: "http://sso.bit.edu.cn/cas/continue")))
        sameOriginRequest.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: sameOriginRequest,
            completionHandler: { sameOriginResult = $0 }
        )
        #expect(sameOriginResult?.url?.absoluteString == "https://sso.bit.edu.cn/cas/continue")
        #expect(sameOriginResult?.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        var manuallyHandledRedirect: URLRequest? = sameOriginRequest
        NoRedirectURLSessionDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: sameOriginRequest,
            completionHandler: { manuallyHandledRedirect = $0 }
        )
        #expect(manuallyHandledRedirect == nil)

        var crossOriginResult: URLRequest?
        var crossOriginRequest = URLRequest(url: try #require(URL(string: "http://portal.example/landing")))
        crossOriginRequest.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        crossOriginRequest.setValue("proxy-token", forHTTPHeaderField: "Proxy-Authorization")
        crossOriginRequest.setValue("session", forHTTPHeaderField: "Cookie")
        crossOriginRequest.setValue("community-session", forHTTPHeaderField: "fake-cookie")
        crossOriginRequest.httpBody = Data("sensitive-body".utf8)
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: crossOriginRequest,
            completionHandler: { crossOriginResult = $0 }
        )
        #expect(crossOriginResult?.url?.absoluteString == "https://portal.example/landing")
        #expect(crossOriginResult?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(crossOriginResult?.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(crossOriginResult?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(crossOriginResult?.value(forHTTPHeaderField: "fake-cookie") == nil)
        #expect(crossOriginResult?.httpBody == nil)

        var crossOriginPostResult: URLRequest? = crossOriginRequest
        crossOriginRequest.httpMethod = "POST"
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: crossOriginRequest,
            completionHandler: { crossOriginPostResult = $0 }
        )
        #expect(crossOriginPostResult == nil)
    }

    @Test("bit-login challenge protocol is shared by school services")
    func sharedBITLoginChallengeProtocol() throws {
        let data = Data(
            #"{"challenge_id":"challenge-1","access_token":"token","status":"waiting_sms","masked_phone":"138****0000","expires_in":120}"#.utf8
        )
        let payload = try BITLoginChallengeSupport.decodePayload(from: data)
        let challenge = BITLoginChallengeSupport.challenge(from: payload, accessToken: "token")

        #expect(challenge.challengeID == "challenge-1")
        #expect(challenge.status == "waiting_sms")
        #expect(challenge.maskedPhone == "138****0000")
        #expect(
            BITLoginChallengeSupport.errorMessage(
                from: Data(#"{"detail":{"error":"验证码错误"}}"#.utf8)
            ) == "验证码错误"
        )
    }

    @Test("Schedule JSON requests preserve HTTPS and form contracts")
    func scheduleJSONRequestContract() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://school.example/api/courses.do")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/javascript, */*; q=0.01")
            #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(body == "term=2025-2026-1&search=software%20%26%20engineering")

            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(#"{"accepted":true}"#.utf8), response)
        }
        let service = ScheduleServiceFactory.make(transport: transport)
        let payload: SchoolProbePayload = try await service.sendJSONRequest(
            baseURL: try makeTestURL("http://school.example"),
            path: "/api/courses.do",
            method: "POST",
            body: [("term", "2025-2026-1"), ("search", "software & engineering")]
        )

        #expect(payload.accepted)
    }

    @Test("Schedule service returns school business errors from nested envelopes")
    func scheduleBusinessErrorContract() async throws {
        let transport = MockHTTPTransport { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            let data = Data(#"{"datas":{"cxxszhxqkb":{"extParams":{"code":3,"msg":"此学年学期的课表未发布"},"rows":[]}}}"#.utf8)
            return (data, response)
        }
        let service = ScheduleServiceFactory.make(transport: transport)

        do {
            let _: SchoolProbePayload = try await service.sendJSONRequest(
                baseURL: try makeTestURL("https://school.example"),
                path: "/api/courses.do"
            )
            Issue.record("Expected a school business error")
        } catch ScheduleServiceError.schoolResponse(let message) {
            #expect(message == "此学年学期的课表未发布")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Schedule SMS continuation sends the challenge contract and preserves its state")
    func scheduleSMSChallengeContract() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/auth/challenge-1/sms")
            #expect(request.value(forHTTPHeaderField: "X-Challenge-Token") == "access-token")
            let body = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(payload == ["code": "123456"])

            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            let data = Data(
                #"{"challenge_id":"challenge-1","access_token":"access-token","status":"waiting_sms","masked_phone":"138****0000","expires_in":120}"#.utf8
            )
            return (data, response)
        }
        let service = ScheduleServiceFactory.make(transport: transport)
        let challenge = BITLoginAuthenticationChallenge(
            challengeID: "challenge-1",
            accessToken: "access-token",
            status: "waiting_sms",
            maskedPhone: "138****0000",
            expiresIn: 120
        )

        do {
            try await service.submitSMSCodeForTeachingCenterAuthentication("123456", for: challenge)
            Issue.record("Expected the server to keep the challenge in its SMS state")
        } catch ScheduleServiceError.secondFactorRequired(let updatedChallenge) {
            #expect(updatedChallenge.challengeID == challenge.challengeID)
            #expect(updatedChallenge.accessToken == challenge.accessToken)
            #expect(updatedChallenge.maskedPhone == challenge.maskedPhone)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Expired SMS challenge responses preserve challenge invalidation")
    func scheduleExpiredSMSChallengeContract() async throws {
        let transport = MockHTTPTransport { request in
            #expect(request.url?.path == "/api/auth/challenge-1/sms")
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 409,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(#"{"message":"challenge expired"}"#.utf8), response)
        }
        let service = ScheduleServiceFactory.make(transport: transport)
        let challenge = BITLoginAuthenticationChallenge(
            challengeID: "challenge-1",
            accessToken: "access-token",
            status: "waiting_sms",
            maskedPhone: "138****0000",
            expiresIn: 120
        )

        do {
            try await service.submitSMSCodeForTeachingCenterAuthentication("123456", for: challenge)
            Issue.record("Expected the expired challenge to be rejected")
        } catch ScheduleServiceError.challengeInvalid(let message) {
            #expect(message.contains("challenge expired"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Network smoke scopes include exactly their typed probe areas")
    func networkSmokeScopeAreaMatrix() {
        let all = Set(NetworkSmokeArea.allCases)
        let expectations: [(NetworkSmokeScope, Set<NetworkSmokeArea>)] = [
            (.all, all),
            (.bit101, [.authentication, .bit101]),
            (.school, [.authentication, .schedule, .ddl, .school, .transcript]),
            (.transcript, [.authentication, .transcript]),
            (.schedule, [.authentication, .schedule]),
            (.ddl, [.authentication, .ddl])
        ]

        for (scope, includedAreas) in expectations {
            for area in NetworkSmokeArea.allCases {
                #expect(scope.includes(area) == includedAreas.contains(area))
            }
        }
    }

    @Test("Smoke report separates service health from coverage completeness")
    func networkSmokeCoverageStatus() {
        let startedAt = Date()
        func makeReport(coverageGaps: [String]) -> ReleaseNetworkSmokeReport {
            ReleaseNetworkSmokeReport(
                runID: "test-run",
                scope: .all,
                startedAt: startedAt,
                finishedAt: startedAt,
                passed: true,
                failures: [],
                authenticationBlockers: [],
                scheduleCache: nil,
                executedProbes: [],
                skippedProbes: coverageGaps,
                coverageGaps: coverageGaps,
                schoolSMSCoverage: "not_run"
            )
        }

        let complete = makeReport(coverageGaps: [])
        let partial = makeReport(coverageGaps: ["详情探针（列表为空）"])
        #expect(complete.passed)
        #expect(complete.coverageComplete)
        #expect(partial.passed)
        #expect(!partial.coverageComplete)
    }

#if DEBUG
    @Test("Release smoke validates external content contracts")
    func releaseSmokeExternalJSONContracts() throws {
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateTrustedTranscriptPages([])
        }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateTrustedTranscriptPages([Data("not an image".utf8)])
        }

        let html = Data("<!doctype html><html><body>BIT101</body></html>".utf8)
        #expect(
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                html,
                finalURL: URL(string: "https://bit101.cn/gallery/"),
                expectedHost: "bit101.cn"
            ) == html.count
        )
        #expect(
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                html,
                finalURL: URL(string: "https://open.aihelpme.dev/gallery/123"),
                expectedHost: "open.aihelpme.dev"
            ) == html.count
        )
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                html,
                finalURL: URL(string: "https://example.com/gallery/123"),
                expectedHost: "open.aihelpme.dev"
            )
        }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                Data("not a web document".utf8),
                finalURL: URL(string: "https://open.aihelpme.dev/gallery/123"),
                expectedHost: "open.aihelpme.dev"
            )
        }

        let lookup = Data(
            #"{"resultCount":1,"results":[{"version":"1.2.3","bundleId":"BIT101-dev.BIT101-iOS","trackViewUrl":"https://apps.apple.com/cn/app/bit101/id6761147125"}]}"#.utf8
        )
        #expect(try ReleaseNetworkSmokeRunner.validateAppStoreLookup(lookup) == 1)

        let wrongApp = Data(
            #"{"resultCount":1,"results":[{"version":"1.2.3","bundleId":"other.app","trackViewUrl":"https://apps.apple.com/cn/app/other/id1234567890"}]}"#.utf8
        )
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateAppStoreLookup(wrongApp)
        }

        let disabledNotice = Data(#"{"schema_version":1,"enabled":false}"#.utf8)
        #expect(try ReleaseNetworkSmokeRunner.validateEmergencyUpdateConfiguration(disabledNotice) == false)

        let enabledNotice = Data(
            #"{"schema_version":1,"enabled":true,"notice_id":"maintenance","maximum_affected_build":33,"title":"Update","message":"Install the current release.","update_url":"https://apps.apple.com/cn/app/bit101/id6761147125"}"#.utf8
        )
        #expect(try ReleaseNetworkSmokeRunner.validateEmergencyUpdateConfiguration(enabledNotice))

        let unsupportedNotice = Data(#"{"schema_version":2,"enabled":false}"#.utf8)
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateEmergencyUpdateConfiguration(unsupportedNotice)
        }
    }
#endif
}
