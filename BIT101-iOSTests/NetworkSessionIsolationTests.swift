import CommunityTransport
import GalleryFeature
import DesignSystemKit
import Foundation
import Network
import os
import SchedulePorts
import Testing
import UIKit
@testable import ScheduleInfrastructure
@testable import TransportCore
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
        if request.hasPrefix("GET /drip ") {
            let header = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header, completion: .contentProcessed { [self] error in
                if error == nil { drip(connection, remaining: 100) }
            })
            return
        }
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

    private func drip(_ connection: NWConnection, remaining: Int) {
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            connection.send(content: Data([65]), completion: .contentProcessed { [self] error in
                if error == nil, remaining > 1 { drip(connection, remaining: remaining - 1) }
                else { connection.cancel() }
            })
        }
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

#if DEBUG
private final class SubscriptionSmokeTransport: HTTPTransport {
    var level = 0
    var failComment = false
    var writes: [Int] = []
    var deleted = false
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        #expect(request.value(forHTTPHeaderField: "fake-cookie") == "fixture")
        var status = 200
        var body = "{}"
        if url.path == "/subscriptions" {
            let data = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(payload["obj"] as? String == "poster42")
            let next = try #require(payload["level"] as? Int)
            writes.append(next)
            if failComment && next == 3 { status = 500 } else { level = next }
        } else if request.httpMethod == "DELETE" { deleted = true }
        else if request.httpMethod == "GET" {
            body = #"{"id":42,"anonymous":false,"claim":{"id":0,"text":""},"comment_num":0,"create_time":"","edit_time":"","images":[{"mid":"image","url":"","low_url":""}],"like":false,"like_num":0,"own":true,"plugins":"[]","public":false,"tags":[],"text":"fixture","title":"功能验收","update_time":"","user":{"id":1,"create_time":"","nickname":"作者","avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":0,"color":"","text":"","create_time":"","update_time":""}},"subscription":LEVEL}"#.replacingOccurrences(of: "LEVEL", with: String(level))
        }
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

extension NetworkClientTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor
    func ownedPosterSubscriptionSmokeRestoresBeforeDeletion(failed: Bool) async throws {
        let transport = SubscriptionSmokeTransport()
        transport.failComment = failed
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        let service = GalleryService(session: session, preferences: {
            .init(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
        })
        let operations = CommunityWriteSmoke.Operations.production(gallery: service)
        if failed { await #expect(throws: (any Error).self) { try await operations.edit(.poster, 42, "fixture") } }
        else { try await operations.edit(.poster, 42, "fixture") }
        try await operations.delete(.poster, 42)
        #expect(transport.writes == [1, 2, 3, 0] && transport.level == 0 && transport.deleted)
    }
}
#endif

extension NetworkClientTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func scoreAuthenticationFactoryFollowsItsSelectedCookieStorage() async throws {
        let server = try CommunityIsolationServer(); defer { server.stop() }
        let url = try await server.url().appending(path: "score")
        for productionPolicy in [false, true] {
            let state = AppSchoolSession.isolatedState()
            let transport = NetworkSessionPool.scoreAuthenticationTransport(state: state, productionPolicy: productionPolicy)
            let client = HTTPClient(transport: transport, observer: nil)
            for account in ["A", "B", "A"] {
                let cookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
                cookies.setCookie(try #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
                    .name: "score-session", .value: account])))
                state.replaceCookieStorage(with: cookies)
                _ = try await client.send(URLRequest(url: url))
                #expect(server.requests.last?.contains("score-session=\(account)") == true)
            }
        }
        #expect(server.requests.count == 6)
    }

    @Test(.timeLimit(.minutes(1)))
    func eclassDecodingFailurePreservesTheFieldContext() async throws {
        do {
            let _: [String: Int] = try await ScheduleService.decodeEclassResponse(Data(#"{"course":"broken"}"#.utf8))
            Issue.record("字段类型错误应保留解码诊断。")
        } catch {
            let failure = error as NSError
            #expect(failure.localizedDescription == ScheduleServiceError.invalidResponse.localizedDescription)
            let underlying = try #require(failure.userInfo[NSUnderlyingErrorKey] as? DecodingError)
            guard case let .typeMismatch(type, context) = underlying else {
                Issue.record("字段类型诊断应对应 typeMismatch。")
                return
            }
            #expect(ObjectIdentifier(type) == ObjectIdentifier(Int.self))
            #expect(context.codingPath.map(\.stringValue) == ["course"])
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor
    func cancelledAlertWaitsReleaseTheirQueuedPresentation(cancelBeforeStarting: Bool) async throws {
        var checks = 0
        var pending: [CheckedContinuation<Void, Never>] = []
        let presenter = AppErrorPresenter(presenter: { checks += 1; return nil }, retryDelay: {
            await withCheckedContinuation { pending.append($0) }
        })
        defer { presenter.reset(); pending.forEach { $0.resume() } }
        let alert = AppAlert(title: "取消提示", message: "等待前台", allowsDiagnostics: false, showsRecoveryLinks: false)
        let task = Task { await presenter.presentAndWait(alert) }
        defer { task.cancel() }
        if !cancelBeforeStarting { try await waitForTestEvent { !pending.isEmpty } }
        let retry = presenter.retryTask
        #expect((retry != nil) == !cancelBeforeStarting)
        task.cancel()
        await task.value
        let previousChecks = checks
        pending.forEach { $0.resume() }; pending.removeAll()
        await retry?.value
        #expect(checks == previousChecks && checks == (cancelBeforeStarting ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func queuedBackgroundAlertsShareOneRetryAndReleaseItOnReset() async throws {
        var checks = 0, retries = 0
        var pending: [CheckedContinuation<Void, Never>] = []
        let presenter = AppErrorPresenter(presenter: { checks += 1; return nil }, retryDelay: {
            retries += 1
            await withCheckedContinuation { pending.append($0) }
        })
        defer { presenter.reset(); pending.forEach { $0.resume() } }
        let alert = AppAlert(title: "排队提示", message: "等待前台", allowsDiagnostics: false, showsRecoveryLinks: false)
        for _ in 0..<3 { presenter.present(alert) }
        try await waitForTestEvent { retries > 0 }
        #expect(checks == 3 && retries == 1 && pending.count == 1)
        pending.removeFirst().resume()
        try await waitForTestEvent { retries > 1 }
        #expect(checks == 4 && retries == 2 && pending.count == 1)
        let retry = try #require(presenter.retryTask)
        presenter.reset()
        pending.removeFirst().resume()
        await retry.value
        #expect(checks == 5 && retries == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func resourceDeadlineEndsAContinuouslyReceivingResponse() async throws {
        let server = try CommunityIsolationServer()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        let defaultTransport = NetworkSessionPool.make(configuration: configuration, productionPolicy: true)
        #expect(configuration.timeoutIntervalForResource == 90)
        withExtendedLifetime(defaultTransport) {}
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 0.4
        let transport = NetworkSessionPool.make(configuration: configuration, productionPolicy: true)
        let url = try await server.url().appending(path: "drip")
        do {
            _ = try await transport.data(for: URLRequest(url: url))
            Issue.record("持续响应应沿整体资源期限结束。")
        } catch let error as URLError { #expect(error.code == .timedOut) }
        let response = try await transport.data(for: URLRequest(url: url.deletingLastPathComponent().appending(path: "account")))
        #expect(response.0 == Data("A".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func ownedTransportFinishesItsRequestAndReleasesTheSessionDelegate() async throws {
        final nonisolated class Invalidated: NSObject, URLSessionDelegate {
            let continuation: AsyncStream<Bool>.Continuation
            init(_ continuation: AsyncStream<Bool>.Continuation) { self.continuation = continuation }
            func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
                continuation.yield(error == nil); continuation.finish()
            }
        }
        let server = try CommunityIsolationServer(); defer { server.stop() }
        let request = URLRequest(url: try await server.url().appending(path: "slow"))
        let invalidation = AsyncStream<Bool>.makeStream()
        let session = URLSession(configuration: .ephemeral, delegate: Invalidated(invalidation.continuation), delegateQueue: nil)
        var transport: URLSessionTransport? = URLSessionTransport(ownedSession: session)
        weak let lease = transport
        func begin(_ transport: URLSessionTransport) -> Task<HTTPResponse, any Error> {
            let client = HTTPClient(transport: transport, observer: nil)
            return Task { try await client.send(request) }
        }
        let pending = begin(try #require(transport)); defer { pending.cancel() }
        try await server.waitForDelayedRequest()
        transport = nil
        #expect(lease != nil)
        server.finishDelayedRequest()
        #expect(try await pending.value.data == Data("A".utf8))
        var events = invalidation.stream.makeAsyncIterator()
        #expect(await events.next() == true)
        try await waitForTestEvent { lease == nil && session.delegate == nil }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func productionTransportRecordsPostRedirectAsFinalGet() async throws {
        let server = try CommunityIsolationServer(); defer { server.stop() }
        let base = try await server.url()
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let client = HTTPClient(transport: UncachedHTTPTransport(base: session), observer: nil)
        var request = URLRequest(url: base.appending(path: "redirect")); request.httpMethod = "POST"
        var captured: HTTPRequestEvidence?
        try await HTTPRequestEvidenceContext.$didReceive.withValue({ request, response in captured = HTTPRequestEvidence(request: request, response: response.response, finalRequest: response.finalRequest) }) { _ = try await client.send(request) }
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


#if DEBUG
enum NetworkSmokeWireFixtures {
    static let recovery = #"""
    {
      "accepted": [
        {"method":"GET","endpoint":"https://bit101.flwfdd.xyz/user/info/0","statusCode":200,"query":{},"responseBody":"{}"},
        {"method":"GET","endpoint":"https://bit101.flwfdd.xyz/reaction/comments","statusCode":200,"query":{"obj":"poster41","order":"new","page":"0"},"responseBody":"[]"},
        {"method":"DELETE","endpoint":"https://bit101.flwfdd.xyz/posters/41","statusCode":200,"query":{},"responseBody":"{}"},
        {"method":"GET","endpoint":"https://bit101.flwfdd.xyz/posters/41","statusCode":404,"query":{},"responseBody":"{\"detail\":\"帖子不存在Orz\"}","responseContentMissing":true},
        {"method":"GET","endpoint":"https://bit101.flwfdd.xyz/papers/45","statusCode":400,"query":{},"responseBody":"{\"detail\":\"文章不存在Orz\"}","responseContentMissing":true},
        {"method":"GET","endpoint":"https://bit101.flwfdd.xyz/papers/45","statusCode":500,"query":{},"responseBody":"{\"detail\":\"文章不存在Orz\"}","responseContentMissing":true}
      ],
      "rejected": [
        {"method":"GET","endpoint":"https://bit101.flwfdd.xyz/posters/41","statusCode":500,"query":{},"responseBody":"{\"detail\":\"内部错误\"}"},
        {"method":"GET","endpoint":"https://bit101.flwfdd.xyz/courses/43","statusCode":404,"query":{},"responseBody":"{\"detail\":\"帖子不存在Orz\"}"}
      ]
    }
    """#
}

extension NetworkSmokeCoverageTests {
    @Test(.timeLimit(.minutes(1))) func recoveryEvidenceMatchesTheSharedWireFixture() async throws {
        let groups = try #require(JSONSerialization.jsonObject(with: Data(NetworkSmokeWireFixtures.recovery.utf8)) as? [String: [[String: Any]]])
        for row in groups.values.flatMap({ $0 }) {
            let endpoint = try #require(row["endpoint"] as? String)
            var components = try #require(URLComponents(string: endpoint))
            let query = try #require(row["query"] as? [String: String])
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            let url = try #require(components.url)
            var request = URLRequest(url: url)
            request.httpMethod = try #require(row["method"] as? String)
            let status = try #require(row["statusCode"] as? Int)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            let body = try #require(row["responseBody"] as? String)
            let evidence = await NetworkSmokeHTTPRequestEvidence.capture(request: request, response: response, body: Data(body.utf8))
            #expect(evidence.endpoint == endpoint && evidence.query == query && evidence.finalQuery == query)
            #expect(evidence.responseContentMissing == row["responseContentMissing"] as? Bool)
        }
    }
    @Test(.timeLimit(.minutes(1)), arguments: ["correct", "positive-only", "negative-only", "unexpected", "final-wrong", "final-swapped"])
    func searchEvidenceBindsBothControlKeywords(stage: String) async throws {
        let expected = ["search": "课程 1", "excludedSearch": "exclusioncontrol"]
        let words = stage == "positive-only" ? ["课程 1"] : stage == "negative-only" ? ["exclusioncontrol"]
            : stage == "unexpected" ? ["课程 1", "other"] : ["课程 1", "exclusioncontrol"]
        let collector = NetworkSmokeRequestCollector()
        let operation = {
            for word in words {
                var components = try #require(URLComponents(string: "https://bit101.flwfdd.xyz/courses"))
                components.queryItems = [URLQueryItem(name: "search", value: word), URLQueryItem(name: "page", value: "0")]
                let request = URLRequest(url: try #require(components.url))
                if stage == "final-swapped" { components.queryItems = [URLQueryItem(name: "search", value: word == "课程 1" ? "exclusioncontrol" : "课程 1")] }
                if stage == "final-wrong" { components.queryItems = [URLQueryItem(name: "search", value: "other")] }
                let finalRequest = URLRequest(url: try #require(components.url))
                let finalURL = try #require(finalRequest.url)
                let response = try #require(HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil))
                await HTTPRequestEvidenceContext.didReceive?(request, HTTPResponse(data: Data(), response: response, finalRequest: finalRequest))
            }
        }
        if stage == "correct" { try await collector.perform(operation, required: true, expectedParameters: expected) }
        else { await #expect(throws: NetworkSmokeRequestError.self) { try await collector.perform(operation, required: true, expectedParameters: expected) } }
        #expect(collector.requests.count == words.count && HTTPRequestEvidenceContext.didReceive == nil)
    }
}
#endif

extension NetworkClientTests {
    @Test("Network diagnostics follow the injected connection state")
    @MainActor
    func networkDescriptionUsesSelectedPath() {
        #expect(NetworkPathSnapshot.Status(pathStatus: .satisfied) == .connected)
        #expect(NetworkPathSnapshot.Status(pathStatus: .unsatisfied) == .disconnected)
        let path = NetworkPathState(snapshot: NetworkPathSnapshot(status: .checking))
        let description = NetworkConnectionDescription(networkPath: path)
        #expect(description.current == "检测中")
        path.update(snapshot: NetworkPathSnapshot(status: .disconnected))
        #expect(description.current == "未连接")
        #expect(!path.isReachable)
        let waiting = NetworkPathSnapshot.Status(pathStatus: .requiresConnection)
        #expect(waiting == .requiresConnection)
        path.update(snapshot: NetworkPathSnapshot(status: waiting))
        #expect(description.current == "等待连接" && path.isReachable)
        path.update(snapshot: NetworkPathSnapshot(status: .connected, interfaces: [.wifi, .other], virtualNetworkLikely: true))
        #expect(description.current == "已连接 · Wi‑Fi + 虚拟/未知接口")
        #expect(description.snapshot.virtualNetworkLikely)
    }
}
