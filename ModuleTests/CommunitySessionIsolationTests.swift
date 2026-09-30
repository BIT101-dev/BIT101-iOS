import CommunityTransport
import Foundation
import Testing
import TransportCore

@MainActor
struct CommunitySessionIsolationTests {
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
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await send(request) }
    }

    private func response(_ request: URLRequest, status: Int) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        return (Data(), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    @Test func accountSwitchStopsWriteRetry() async {
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

    @Test func returningToAnAccountUsesItsNewGeneration() async {
        let credentials = Credentials()
        let transport = Transport { request in
            credentials.identity = CommunitySessionIdentity(accountIdentifier: "account-a", generation: 1)
            return try response(request, status: 200)
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot })
        await #expect(throws: CancellationError.self) { try await client.requestData(path: "user") }
    }

    @Test func refreshCancellationKeepsCancellationSemantics() async {
        await assertRefreshError(CancellationError(), expected: CancellationError.self)
    }

    @Test func refreshTimeoutKeepsTransportSemantics() async {
        await assertRefreshError(URLError(.timedOut), expected: URLError.self)
    }

    @Test func explicitCredentialRejectionEntersSignedOutState() async {
        await assertRefreshError(CommunitySessionRestorationError.credentialsRejected, expected: Failure.self)
    }

    private func assertRefreshError<E: Error>(_ error: any Error, expected: E.Type) async {
        let credentials = Credentials()
        let transport = Transport { request in try response(request, status: 401) }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: transport, observer: nil), baseURL: AppURL.required("https://example.invalid"), errorDomain: "test", credentials: { credentials.snapshot }, refreshHandler: { _ in throw error })
        await #expect(throws: expected) { try await client.requestData(path: "user") }
    }

    @Test func refreshOwnerIsCheckedBeforeSaving() async {
        let credentials = Credentials()
        let coordinator = CommunitySessionRefreshCoordinator()
        let observed = credentials.snapshot
        await #expect(throws: CancellationError.self) {
            try await coordinator.refresh(observed: observed, current: { credentials.snapshot }) {
                credentials.identity = CommunitySessionIdentity(accountIdentifier: "account-b")
            }
        }
    }

    @Test func endpointCanChooseItsRetryPolicy() async {
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

    @Test func ownerChangeDuringRefreshStopsReplay() async {
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

    private final class RestoreGate {
        var calls = 0
        private var started: CheckedContinuation<Void, Never>?
        private var completion: CheckedContinuation<Void, Never>?
        func restore() async {
            calls += 1
            await withCheckedContinuation { completion = $0; started?.resume(); started = nil }
        }
        func waitUntilStarted() async {
            if completion != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish() { completion?.resume(); completion = nil }
    }

    @Test func concurrentRequestsShareOneRestorationWithinTheirSession() async throws {
        let credentials = Credentials()
        let coordinator = CommunitySessionRefreshCoordinator()
        let gate = RestoreGate()
        let first = Task { try await coordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { await gate.restore() }) }
        await gate.waitUntilStarted()
        var joined: CheckedContinuation<Void, Never>?
        let second = Task {
            joined?.resume()
            try await coordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { Issue.record("Session restoration is shared") })
        }
        await withCheckedContinuation { joined = $0 }
        #expect(gate.calls == 1)
        gate.finish()
        try await first.value
        try await second.value
    }

    @Test func independentSessionCoordinatorsOwnTheirRestorationTasks() async throws {
        let credentials = Credentials()
        let firstGate = RestoreGate()
        let secondGate = RestoreGate()
        let firstCoordinator = CommunitySessionRefreshCoordinator()
        let secondCoordinator = CommunitySessionRefreshCoordinator()
        let first = Task { try await firstCoordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { await firstGate.restore() }) }
        await firstGate.waitUntilStarted()
        let second = Task { try await secondCoordinator.refresh(observed: credentials.snapshot, current: { credentials.snapshot }, restore: { await secondGate.restore() }) }
        await secondGate.waitUntilStarted()
        #expect(firstGate.calls == 1)
        #expect(secondGate.calls == 1)
        firstGate.finish()
        secondGate.finish()
        try await first.value
        try await second.value
    }
}
