import CommunityTransport
import BIT101TestSupport
import Foundation
import Network
import os
import Testing
@testable import TransportCore

private nonisolated final class InterruptedResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var headers = ["X-Response-Evidence": "received"]
        if request.url?.path == "/declared" { headers["Content-Length"] = "100000" }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: HTTPResponseResourceLimits.maximumErrorBytes + 1))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private nonisolated final class InterruptedResponseServer: Sendable {
    private let listener: NWListener
    private let state = OSAllocatedUnfairLock(initialState: (port: UInt16?.none, error: NWError?.none, connection: NWConnection?.none))
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "BIT101.InterruptedResponseFixture")
        listener.stateUpdateHandler = { [listener, state] value in
            state.withLock {
                if case .ready = value { $0.port = listener.port?.rawValue }
                if case .failed(let error) = value { $0.error = error }
            }
        }
        listener.newConnectionHandler = { [state] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if String(decoding: data ?? Data(), as: UTF8.self).contains(" /redirect ") {
                    let response = "HTTP/1.1 303 See Other\r\nLocation: /partial\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let limit = HTTPResponseResourceLimits.maximumErrorBytes
                let header = "HTTP/1.1 200 OK\r\nContent-Length: \(limit * 4)\r\nX-Response-Evidence: received\r\nConnection: close\r\n\r\n"
                let response = Data(header.utf8) + Data(repeating: 65, count: limit * 2)
                state.withLock { $0.connection = connection }
                connection.send(content: response, completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: queue)
    }
    func url() async throws -> URL {
        try await waitForTestEvent {
            let state = self.state.withLock { $0 }
            if let error = state.error { throw error }
            return state.port != nil
        }
        let port = try #require(state.withLock { $0.port })
        return try #require(URL(string: "http://127.0.0.1:\(port)/redirect"))
    }
    func interrupt() { state.withLock { $0.connection?.cancel(); $0.connection = nil } }
    func stop() {
        interrupt()
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
        listener.cancel()
    }
}

@MainActor
struct HTTPResponseValidationTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["connection", "interface", "vpn", "wifi"])
    func usableRouteChangesPublishRecoveryEvents(kind: String) async throws {
        let path = NetworkPathState(snapshot: .init(status: kind == "connection" ? .disconnected : .connected, interfaces: [.wifi]))
        let recoveries = path.connectionRecoveries()
        var received = 0
        let consumer = Task { for await _ in recoveries { received += 1 } }
        defer { consumer.cancel() }
        path.update(snapshot: .init(status: .connected, interfaces: kind == "interface" ? [.cellular] : [.wifi],
            virtualNetworkLikely: kind == "vpn"))
        try await waitForTestEvent { received == 1 }
    }

    private struct Transport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (Data(#"{"required":7}"#.utf8), try #require(HTTPURLResponse(url: url,
                statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
    }
    private final class Observer: HTTPClientObserving {
        var errors: [(any Error)?] = []
        var data: Data?
        var response: URLResponse?
        var finalRequest: URLRequest?
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?, error: (any Error)?, elapsed: TimeInterval) async {
            errors.append(error)
            self.data = data; self.response = response; self.finalRequest = finalRequest
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["partial", "declared", "overflow"])
    func failedTransfersRetainBoundedEvidenceAndTheirOriginalError(kind: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = kind == "partial" ? [] : [InterruptedResponseProtocol.self]
        let server = kind == "partial" ? try InterruptedResponseServer() : nil
        defer { server?.stop() }
        let url = try await server?.url() ?? #require(URL(string: "https://example.invalid/" + kind))
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let observer = Observer()
        let client = HTTPClient(transport: session, observer: observer)
        var request = URLRequest(url: url)
        if kind == "partial" { request.httpMethod = "POST"; request.httpBody = Data("input".utf8) }
        var finished = false
        let requestTask = Task {
            defer { finished = true }
            return try await client.send(request, maximumBytes: kind == "partial"
                ? HTTPResponseResourceLimits.maximumStructuredBytes : HTTPResponseResourceLimits.maximumErrorBytes)
        }
        defer { requestTask.cancel() }
        if let server {
            try await waitForAsyncTestEvent {
                if finished { _ = try await requestTask.value; return true }
                return await session.allTasks.contains {
                    $0.response != nil && $0.countOfBytesReceived >= HTTPResponseResourceLimits.maximumErrorBytes * 2
                }
            }
            server.interrupt()
        }
        do {
            _ = try await requestTask.value
            Issue.record("Expected transport failure")
        } catch {
            if kind == "partial" {
                #expect((error as NSError).code == NSURLErrorNetworkConnectionLost, "\(error as NSError)")
            } else { #expect(error is HTTPClientError) }
        }
        let response = try #require(observer.response as? HTTPURLResponse)
        let expectedURL = kind == "partial" ? url.deletingLastPathComponent().appending(path: "partial") : url
        #expect(response.statusCode == 200 && response.url == expectedURL)
        #expect(response.value(forHTTPHeaderField: "X-Response-Evidence") == "received")
        #expect(observer.finalRequest?.url == expectedURL && observer.errors.count == 1)
        #expect((observer.data?.count ?? 0) <= HTTPResponseResourceLimits.maximumErrorBytes)
        if kind == "partial" {
            #expect(observer.data == Data(repeating: 65, count: HTTPResponseResourceLimits.maximumErrorBytes))
            #expect(observer.finalRequest?.httpMethod == "GET")
        }
        if kind == "overflow" { #expect(observer.data?.count == HTTPResponseResourceLimits.maximumErrorBytes) }
    }
    private enum Failure: CommunityAPIServiceError {
        case signedOut, invalid
        static var communityNotLoggedIn: Self { .signedOut }
        static var communityInvalidResponse: Self { .invalid }
    }

    @Test(.timeLimit(.minutes(1)))
    func validationReportsTheFirstFailureAndPreservesTheDecodingCause() async throws {
        let observer = Observer()
        let url = try #require(URL(string: "https://example.invalid/fields"))
        let response = try await HTTPClient(transport: Transport(), observer: observer).send(URLRequest(url: url))
        await response.reportValidationFailure(CancellationError())
        #expect(observer.errors.count == 1 && observer.errors[0] == nil)
        do {
            let _: [String: String] = try await response.validated { data, _ in
                try JSONDecoder().decode([String: String].self, from: data)
            }
            Issue.record("字段解析应传播类型错误")
        } catch {
            #expect(error is DecodingError)
        }
        await response.reportValidationFailure(URLError(.badServerResponse))
        let failure = try #require(observer.errors.last.flatMap { $0 })
        #expect(observer.errors.count == 2 && failure is DecodingError)
    }

    @Test(.timeLimit(.minutes(1)))
    func communityParsingFailureReachesTheRequestObserver() async throws {
        let observer = Observer()
        let client = CommunityAPIClient<Failure>(httpClient: HTTPClient(transport: Transport(), observer: observer),
            baseURL: try #require(URL(string: "https://example.invalid")), errorDomain: "fixture",
            credentials: { .init(identity: .init(accountIdentifier: "fixture", generation: 0), cookie: "") })
        do {
            let _: [String: String] = try await client.request(path: "fields", authentication: .none)
            Issue.record("社区解析应传播类型错误")
        } catch {
            #expect((error as NSError).userInfo[NSUnderlyingErrorKey] is DecodingError)
        }
        let failure = try #require(observer.errors.last.flatMap { $0 })
        #expect(observer.errors.count == 2 && failure is DecodingError)
    }
}
