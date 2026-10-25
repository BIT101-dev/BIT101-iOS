import BIT101TestSupport
import CommunityTransport
import Foundation
import Testing
import TransportCore

@MainActor
struct CommunitySessionIsolationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func publicReadingContinuesWhileOwnedCredentialRecoveryWaits(privateOnly: Bool) async throws {
        let credentials = Credentials(), coordinator = CommunitySessionRefreshCoordinator(), gate = RestoreGate()
        var cookies: [String?] = []
        var finished = false
        func restore(_ observed: CommunityCredentials) async throws {
            try await coordinator.refresh(observed: observed, current: { credentials.snapshot }) {
                await gate.restore()
                try Task.checkCancellation()
                credentials.cookie = "fresh"
            }
        }
        let transport = Transport { request in
            let cookie = request.value(forHTTPHeaderField: "fake-cookie")
            cookies.append(cookie)
            let status = cookie == "fresh" || (cookie == nil && !privateOnly) ? 200 : 401
            let (_, value) = try response(request, status: status)
            return (Data(#"{"id":1}"#.utf8), value)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot },
            refreshHandler: restore, backgroundRefresh: { observed in
                coordinator.start(observed: observed) { defer { finished = true }; try await restore(observed) }
            })
        let reading = Task { try await client.response(path: "papers", authentication: .optional) as CommunityAPIResponse<Receipt> }
        defer { reading.cancel(); coordinator.cancel(); gate.finish() }
        try await gate.waitUntilStarted()
        if !privateOnly {
            let first = try await reading.value
            #expect(first.value.id == 1 && !first.isAuthenticated && !finished)
            let second: CommunityAPIResponse<Receipt> = try await client.response(path: "papers", authentication: .optional)
            #expect(!second.isAuthenticated && gate.calls == 1)
        }
        gate.finish()
        try await waitForTestEvent { finished }
        #expect(credentials.cookie == "fresh")
        let result = try await reading.value
        #expect(result.isAuthenticated == privateOnly)
        let authenticated: CommunityAPIResponse<Receipt> = try await client.response(path: "papers", authentication: .optional)
        #expect(authenticated.isAuthenticated && cookies.last == "fresh")
    }

    @Test(.timeLimit(.minutes(1))) func ownedBackgroundRecoveryEndsWhenItsSessionIsCancelled() async throws {
        let credentials = Credentials(), coordinator = CommunitySessionRefreshCoordinator(), gate = RestoreGate()
        var finished = false
        coordinator.start(observed: credentials.snapshot) {
            defer { finished = true }
            try await coordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }) {
                await gate.restore()
                try Task.checkCancellation()
                credentials.cookie = "late"
            }
        }
        defer { coordinator.cancel(); gate.finish() }
        try await gate.waitUntilStarted()
        coordinator.cancel()
        try await waitForTestEvent { finished }
        gate.finish()
        #expect(credentials.cookie == "cookie-a")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["rejected", "timeout", "empty", "retry-rejected", "cancel", "account"])
    func optionalReadsRecoverPublicContentWithinTheirOriginalAccount(scenario: String) async throws {
        let credentials = Credentials()
        var cookies: [String?] = []
        let transport = Transport { request in
            let cookie = request.value(forHTTPHeaderField: "fake-cookie")
            cookies.append(cookie)
            let (_, value) = try response(request, status: cookie == nil ? 200 : 401)
            return (Data(#"{"id":1}"#.utf8), value)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot },
            refreshHandler: { _ in
                switch scenario {
                case "rejected": throw CommunitySessionRestorationError.credentialsRejected
                case "timeout": throw URLError(.timedOut)
                case "cancel": throw URLError(.cancelled)
                case "account": credentials.identity = .init(accountIdentifier: "account-b")
                case "empty": credentials.cookie = ""
                default: credentials.cookie = "refreshed"
                }
            })
        if ["cancel", "account"].contains(scenario) {
            do { _ = try await client.requestData(path: "papers", authentication: .optional); Issue.record("Cancelled reads preserve their boundary") }
            catch { #expect(TaskCancellation.matches(error)) }
            #expect(cookies == ["cookie-a"])
        } else {
            let result: CommunityAPIResponse<Receipt> = try await client.response(path: "papers", authentication: .optional)
            #expect(result.value.id == 1 && !result.isAuthenticated)
            #expect(cookies == (scenario == "retry-rejected" ? ["cookie-a", "refreshed", nil] : ["cookie-a", nil]))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [CommunityAuthentication.required, .optional])
    func writesKeepTheirAuthenticationRequirementDuringCredentialRejection(authentication: CommunityAuthentication) async {
        let credentials = Credentials()
        var requests = 0
        let transport = Transport { request in
            requests += 1
            #expect(request.value(forHTTPHeaderField: "fake-cookie") == "cookie-a")
            return try response(request, status: 401)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot },
            refreshHandler: { _ in throw CommunitySessionRestorationError.credentialsRejected })
        await #expect(throws: Failure.self) { try await client.requestVoid(path: "action", method: "POST", authentication: authentication) }
        #expect(requests == 1)
    }

    private nonisolated struct Receipt: Decodable, Sendable { let id: Int }
    private enum Failure: Error, CommunityAPIServiceError {
        case signedOut, invalidResponse
        static var communityNotLoggedIn: Self { .signedOut }
        static var communityInvalidResponse: Self { .invalidResponse }
    }

    private final class Credentials {
        var identity = CommunitySessionIdentity(accountIdentifier: "account-a")
        var cookie = "cookie-a"
        var snapshot: CommunityCredentials { CommunityCredentials(identity: identity, cookie: cookie) }
    }

    private struct Transport: HTTPTransport {
        let send: (URLRequest) async throws -> (Data, URLResponse)
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await send(request) }
    }

    private func response(_ request: URLRequest, status: Int) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["posters", "papers", "reaction/comments"],
        ["lost", "cancelled", "unsent", "rejected", "malformed", "server-error", "refresh-lost", "refresh-http-failure"])
    func creationFailuresKeepTheirTransmissionOutcome(path: String, scenario: String) async throws {
        let credentials = Credentials()
        var requests = 0
        let transport = Transport { request in
            requests += 1
            if ["refresh-lost", "refresh-http-failure"].contains(scenario), requests == 1 { return try response(request, status: 401) }
            if ["lost", "refresh-lost", "refresh-http-failure"].contains(scenario) { throw URLError(.networkConnectionLost) }
            if scenario == "cancelled" { throw CancellationError() }
            if scenario == "unsent" { throw HTTPRequestNotSent(underlying: URLError(.cannotConnectToHost)) }
            return try response(request, status: scenario == "rejected" ? 400 : scenario == "server-error" ? 500 : 200)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "test",
            credentials: { credentials.snapshot }, refreshHandler: { _ in
                if scenario == "refresh-http-failure" {
                    _ = try await HTTPClient(transport: transport, observer: nil).send(URLRequest(url: AppURL.required("https://example.invalid/login")))
                }
            })
        do {
            let _: Receipt = try await client.request(path: path, method: "POST")
            Issue.record("Creation fixture must fail")
        } catch {
            #expect((error is CommunityCreateOutcomeUnknown) == !["unsent", "rejected", "refresh-http-failure"].contains(scenario))
            if scenario == "cancelled" { #expect(TaskCancellation.matches(error)) }
            if scenario == "unsent" { #expect(error is HTTPRequestNotSent) }
        }
        #expect(requests == (["refresh-lost", "refresh-http-failure"].contains(scenario) ? 2 : 1))
    }

    @Test(.timeLimit(.minutes(1))) func authenticatedRequestsUseExplicitCredentialsAndFreshResponses() async throws {
        let credentials = Credentials()
        var captured: [URLRequest] = []
        let transport = Transport { request in
            captured.append(request)
            return try response(request, status: 200)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot })
        _ = try await client.requestData(path: "private")
        _ = try await client.requestData(path: "optional", authentication: .optional)
        _ = try await client.requestData(path: "public", authentication: .none)
        credentials.cookie = ""
        _ = try await client.requestData(path: "guest", authentication: .optional)
        #expect(captured.map(\.httpShouldHandleCookies) == [false, false, false, false])
        #expect(captured.map(\.cachePolicy) == [.reloadIgnoringLocalCacheData, .reloadIgnoringLocalCacheData, .useProtocolCachePolicy, .useProtocolCachePolicy])
        #expect(captured.map { $0.value(forHTTPHeaderField: "fake-cookie") } == ["cookie-a", "cookie-a", nil, nil])
    }

    @Test(.timeLimit(.minutes(1))) func accountSwitchStopsWriteRetry() async {
        let credentials = Credentials()
        var requests = 0
        let transport = Transport { request in
            requests += 1
            credentials.identity = CommunitySessionIdentity(accountIdentifier: "account-b")
            credentials.cookie = "cookie-b"
            return try response(request, status: 401)
        }
        let client = CommunityAPIClient<Failure>(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "test",
            credentials: { credentials.snapshot }, refreshHandler: { _ in Issue.record("Account owns the refresh") }
        )
        await #expect(throws: CancellationError.self) {
            try await client.requestVoid(path: "posters", method: "POST", body: Data("content".utf8))
        }
        #expect(requests == 1)
    }

    @Test(.timeLimit(.minutes(1))) func returningToAnAccountUsesItsNewGeneration() async {
        let credentials = Credentials()
        let transport = Transport { request in
            credentials.identity = CommunitySessionIdentity(accountIdentifier: "account-a", generation: 1)
            return try response(request, status: 200)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot })
        await #expect(throws: CancellationError.self) { try await client.requestData(path: "user") }
    }

    @Test(.timeLimit(.minutes(1))) func refreshCancellationKeepsCancellationSemantics() async {
        await assertRefreshError(CancellationError(), expected: CancellationError.self)
    }

    @Test(.timeLimit(.minutes(1))) func refreshTimeoutKeepsTransportSemantics() async {
        await assertRefreshError(URLError(.timedOut), expected: URLError.self)
    }

    @Test(.timeLimit(.minutes(1))) func explicitCredentialRejectionEntersSignedOutState() async {
        await assertRefreshError(CommunitySessionRestorationError.credentialsRejected, expected: Failure.self)
    }

    private func assertRefreshError<E: Error>(_ error: any Error, expected: E.Type) async {
        let credentials = Credentials()
        let transport = Transport { request in try response(request, status: 401) }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot }, refreshHandler: { _ in throw error })
        await #expect(throws: expected) { try await client.requestData(path: "user") }
    }

    @Test(.timeLimit(.minutes(1))) func refreshOwnerIsCheckedBeforeSaving() async {
        let credentials = Credentials()
        let coordinator = CommunitySessionRefreshCoordinator()
        let observed = credentials.snapshot
        await #expect(throws: CancellationError.self) {
            try await coordinator.refresh(observed: observed, current: { credentials.snapshot }) {
                credentials.identity = CommunitySessionIdentity(accountIdentifier: "account-b")
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func endpointCanChooseItsRetryPolicy() async {
        let credentials = Credentials()
        var requests = 0
        let transport = Transport { request in
            requests += 1
            return try response(request, status: 401)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot }, refreshHandler: { _ in Issue.record("Endpoint retry policy owns refresh admission") })
        await #expect(throws: Failure.self) {
            try await client.requestVoid(path: "action", method: "POST", retryPolicy: .never)
        }
        #expect(requests == 1)
    }

    @Test(.timeLimit(.minutes(1))) func ownerChangeDuringRefreshStopsReplay() async {
        let credentials = Credentials()
        var requests = 0
        let transport = Transport { request in
            requests += 1
            return try response(request, status: 401)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot }, refreshHandler: { _ in
            credentials.identity = CommunitySessionIdentity(accountIdentifier: "account-b")
            credentials.cookie = "cookie-b"
        })
        await #expect(throws: CancellationError.self) { try await client.requestData(path: "user") }
        #expect(requests == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationReleasesTheWaiterBeforeSharedRestorationCompletes(allConsumers: Bool) async throws {
        let credentials = Credentials(), coordinator = CommunitySessionRefreshCoordinator(), gate = RestoreGate()
        var cancelled = false
        let first = Task {
            do { try await coordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { await gate.restore() }) }
            catch is CancellationError { cancelled = true }
            catch { Issue.record(error) }
        }
        try await gate.waitUntilStarted()
        let second = allConsumers ? nil : Task {
            try await coordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { await gate.restore() })
        }
        if second != nil { await Task.yield() }
        first.cancel()
        try await waitForTestEvent { cancelled }
        #expect(gate.calls == 1)
        gate.finish()
        await first.value
        try await second?.value
        if allConsumers {
            var restarted = false
            try await coordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }) { restarted = true }
            #expect(restarted)
        }
    }

    private final class RestoreGate {
        var calls = 0
        private var completion: CheckedContinuation<Void, Never>?
        func restore() async {
            calls += 1
            await withCheckedContinuation { completion = $0 }
        }
        func waitUntilStarted() async throws {
            try await waitForTestEvent { completion != nil }
        }
        func finish() { completion?.resume(); completion = nil }
    }

    @Test(.timeLimit(.minutes(1))) func concurrentRequestsShareOneRestorationWithinTheirSession() async throws {
        let credentials = Credentials()
        let coordinator = CommunitySessionRefreshCoordinator()
        let gate = RestoreGate()
        let first = Task { try await coordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { await gate.restore() }) }
        try await gate.waitUntilStarted()
        var joined = false
        let second = Task {
            joined = true
            try await coordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { Issue.record("Session restoration is shared") })
        }
        defer { first.cancel(); second.cancel(); gate.finish() }
        try await waitForTestEvent { joined }
        #expect(gate.calls == 1)
        gate.finish()
        try await first.value
        try await second.value
    }

    @Test(.timeLimit(.minutes(1))) func independentSessionCoordinatorsOwnTheirRestorationTasks() async throws {
        let credentials = Credentials()
        let firstGate = RestoreGate()
        let secondGate = RestoreGate()
        let firstCoordinator = CommunitySessionRefreshCoordinator()
        let secondCoordinator = CommunitySessionRefreshCoordinator()
        let first = Task { try await firstCoordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { await firstGate.restore() }) }
        try await firstGate.waitUntilStarted()
        let second = Task { try await secondCoordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { await secondGate.restore() }) }
        try await secondGate.waitUntilStarted()
        #expect(firstGate.calls == 1)
        #expect(secondGate.calls == 1)
        firstGate.finish()
        secondGate.finish()
        try await first.value
        try await second.value
    }

    @Test(.timeLimit(.minutes(1))) func backgroundDecodingKeepsTaskContextAndLeavesMainThread() async throws {
        let transport = Transport { request in
            let (_, response) = try response(request, status: 200)
            return (Data("{}".utf8), response)
        }
        let client = CommunityAPIClient<Failure>(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), errorDomain: "test",
            credentials: { CommunityCredentials(identity: CommunitySessionIdentity(accountIdentifier: "decode"), cookie: "") }
        )
        let result: DecodingContextPayload = try await DecodingContext.$token.withValue("request-context") {
            try await client.request(path: "context", authentication: .none)
        }
        #expect(result.token == "request-context")
        #expect(result.leftMainThread)
    }

}


private nonisolated enum DecodingContext {
    @TaskLocal static var token = "missing"
}

private nonisolated struct DecodingContextPayload: Decodable, Sendable {
    let token: String
    let leftMainThread: Bool

    init(from decoder: any Decoder) throws {
        token = DecodingContext.token
        leftMainThread = !Thread.isMainThread
    }
}
