import CommunityTransport
import Foundation
import Network
import os
import Testing
import TransportCore
@testable import BIT101_iOS

private nonisolated final class CommunityIsolationServer: Sendable {
    private struct State: Sendable {
        var port: UInt16?
        var failure: NWError?
        var requests: [String] = []
        var delayed: NWConnection?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CommunityIsolationServer")
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [listener, state] value in
            state.withLock {
                if case .ready = value { $0.port = listener.port?.rawValue }
                if case let .failed(error) = value { $0.failure = error }
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [self] data, _, complete, error in
            if let error { state.withLock { $0.failure = error }; return }
            var bytes = buffered
            if let data { bytes.append(data) }
            let request = String(decoding: bytes, as: UTF8.self)
            if request.contains("\r\n\r\n") {
                state.withLock { $0.requests.append(request) }
                if request.hasPrefix("GET /slow ") { state.withLock { $0.delayed = connection } }
                else { reply(connection, request: request) }
            } else if !complete { receive(connection, buffered: bytes) }
        }
    }

    private func reply(_ connection: NWConnection, request: String) {
        if request.hasPrefix("POST /redirect ") {
            let response = Data("HTTP/1.1 303 See Other\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let body = request.lowercased().contains("\r\nfake-cookie: cookie-b\r\n") ? "B" : "A"
        let response = Data(("HTTP/1.1 200 OK\r\nCache-Control: public, max-age=3600\r\n" +
            "Content-Length: 1\r\nConnection: close\r\n\r\n" + body).utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    func url() async throws -> URL {
        try await waitForTestEvent {
            let snapshot = state.withLock { $0 }
            if let error = snapshot.failure { throw error }
            return snapshot.port != nil
        }
        let port = try #require(state.withLock { $0.port })
        return AppURL.required("http://127.0.0.1:\(port)")
    }
    var requests: [String] { state.withLock { $0.requests } }
    func waitForDelayedRequest() async throws {
        try await waitForTestEvent {
            let snapshot = state.withLock { $0 }
            if let error = snapshot.failure { throw error }
            return snapshot.delayed != nil
        }
    }
    func finishDelayedRequest() {
        let pending = state.withLock { value in
            let result = (value.delayed, value.requests.last { $0.hasPrefix("GET /slow ") } ?? "")
            value.delayed = nil; return result
        }
        if let connection = pending.0 { reply(connection, request: pending.1) }
    }
    func stop() {
        listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil
        state.withLock { $0.delayed?.cancel() }
        listener.cancel()
    }
}

/// 测试将加密来源映射到本机 HTTP fixture，沿生产 URLSession 执行缓存与 Cookie 策略。
private final class CommunityLoopbackTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var local = request
        var components = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        local.url = try #require(components?.url)
        let (data, response) = try await NetworkSessionPool.productionCommunity.data(for: local)
        let http = try #require(response as? HTTPURLResponse)
        let original = try #require(request.url)
        let mapped = try #require(HTTPURLResponse(url: original, statusCode: http.statusCode,
            httpVersion: nil, headerFields: nil))
        return (data, mapped)
    }
}

extension NetworkClientTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func productionTransportRecordsPostRedirectAsFinalGet() async throws {
        let server = try CommunityIsolationServer(); defer { server.stop() }
        let base = try await server.url()
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let client = HTTPClient(transport: UncachedHTTPTransport(base: session), observer: nil)
        var request = URLRequest(url: base.appending(path: "redirect")); request.httpMethod = "POST"
        var captured: HTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ captured = $0 }) { _ = try await client.send(request) }
        let evidence = try #require(captured)
        #expect(evidence.method == "POST" && evidence.finalMethod == "GET")
        #expect(evidence.finalEndpoint == base.appending(path: "final").absoluteString)
        #expect(server.requests.count == 2 && server.requests.last?.hasPrefix("GET /final ") == true)
    }
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func productionCommunityPoolIsolatesAccountSwitchesFromCookiesCacheAndLateResponses() async throws {
        final class Credentials: LoginCredentialsStoring {
            var values: [String: String] = [:]
            func read(account: String) -> String { values[account] ?? "" }
            func save(_ value: String, account: String) { values[account] = value }
            func delete(account: String) -> Bool { values[account] = nil; return true }
        }
        enum Failure: CommunityAPIServiceError { case signedOut, invalid
            static var communityNotLoggedIn: Self { .signedOut }
            static var communityInvalidResponse: Self { .invalid }
        }
        let domain = "BIT101Tests.community-production-isolation"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = LoginStorage(defaults: defaults, credentials: Credentials(), clearSchoolCookies: {})
        let server = try CommunityIsolationServer()
        defer { server.stop() }
        let base = try await server.url(), cachedURL = base.appending(path: "account")
        let cachedRequest = URLRequest(url: cachedURL)
        let previousCache = URLCache.shared.cachedResponse(for: cachedRequest)
        let response = try #require(HTTPURLResponse(url: cachedURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Cache-Control": "public, max-age=3600"]))
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: Data("cached-A".utf8)), for: cachedRequest)
        defer {
            URLCache.shared.removeCachedResponse(for: cachedRequest)
            if let previousCache { URLCache.shared.storeCachedResponse(previousCache, for: cachedRequest) }
        }
        let cookie = try #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "BIT101CommunityIsolation", .value: "ambient-A"]))
        let priorCookie = HTTPCookieStorage.shared.cookies?.first { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        HTTPCookieStorage.shared.setCookie(cookie)
        defer {
            HTTPCookieStorage.shared.deleteCookie(cookie)
            if let priorCookie { HTTPCookieStorage.shared.setCookie(priorCookie) }
        }
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: CommunityLoopbackTransport(), observer: nil),
            baseURL: base, errorDomain: "Isolation", credentials: { storage.communityCredentials })
        for account in ["A", "B", "A"] {
            try storage.saveLoginState(studentID: account, password: "fixture", fakeCookie: "cookie-\(account)")
            #expect(try await client.requestData(path: "account") == Data(account.utf8))
        }
        #expect(server.requests.count == 3)
        let delayed = Task { try await client.requestData(path: "slow") }
        defer { delayed.cancel() }
        try await server.waitForDelayedRequest()
        try storage.saveLoginState(studentID: "B", password: "fixture", fakeCookie: "cookie-B")
        #expect(try await client.requestData(path: "account") == Data("B".utf8))
        server.finishDelayedRequest()
        await #expect(throws: CancellationError.self) { try await delayed.value }
        #expect(server.requests.count == 5)
        #expect(server.requests.allSatisfy { !$0.lowercased().contains("\r\ncookie:") })
    }
}
