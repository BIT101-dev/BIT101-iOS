import Foundation
import os

/// 系统任务指标确认 HTTP 请求尚未开始时，保留明确的发送前失败身份。
public struct HTTPRequestNotSent: LocalizedError, CustomNSError {
    public let underlying: any Error
    public init(underlying: any Error) { self.underlying = underlying }
    public var errorDescription: String? { underlying.localizedDescription }
    public var errorUserInfo: [String: Any] {
        [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: underlying.localizedDescription]
    }
}

final class HTTPTransmissionMetrics: NSObject, URLSessionTaskDelegate {
    private let started = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private let acceptedRequest: OSAllocatedUnfairLock<URLRequest>
    private let redirects: (any URLSessionTaskDelegate)?
    init(request: URLRequest, redirects: (any URLSessionTaskDelegate)?) {
        acceptedRequest = OSAllocatedUnfairLock(initialState: request)
        self.redirects = redirects
    }
    var confirmedUnsent: Bool { started.withLock { $0 == false } }

    func finalRequest(from current: URLRequest?) -> URLRequest? {
        guard var current else { return nil }
        let accepted = acceptedRequest.withLock { $0 }
        if current.url == accepted.url, current.httpMethod == accepted.httpMethod,
           current.httpBody == nil, let body = accepted.httpBody {
            current.httpBody = body
        }
        return current
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard !metrics.transactionMetrics.isEmpty else { return }
        started.withLock { $0 = metrics.transactionMetrics.contains { $0.requestStartDate != nil || $0.response != nil } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let accept: @Sendable (URLRequest?) -> Void = { [self] request in
            if let request { acceptedRequest.withLock { $0 = request } }
            completionHandler(request)
        }
        if let redirect = redirects?.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) {
            redirect(session, task, response, request, accept)
        } else {
            accept(request)
        }
    }
}

public protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    @concurrent
    public func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        guard let maximumBytes else { return try await data(for: request) }
        guard maximumBytes >= 0 else { throw HTTPClientError.responseTooLarge }
        let metrics = HTTPTransmissionMetrics(request: request, redirects: delegate as? any URLSessionTaskDelegate)
        let transfer = HTTPBoundedTransfer(maximumBytes: maximumBytes, metrics: metrics)
        let task = dataTask(with: request)
        task.delegate = transfer
        defer { task.cancel() }
        let (data, response) = try await transfer.receive(task)
        try Task.checkCancellation()
        if let finalRequest = metrics.finalRequest(from: task.currentRequest) {
            await HTTPRequestEvidenceContext.didReceiveFinalRequest?(finalRequest)
        }
        return (data, response)
    }
}

@MainActor
fileprivate final class HTTPValidationObservation {
    private let record: @MainActor (any Error) async -> Void
    private var recordedFailure = false
    init(_ record: @escaping @MainActor (any Error) async -> Void) { self.record = record }
    func report(_ error: any Error) async {
        guard !recordedFailure, !TaskCancellation.matches(error) else { return }
        recordedFailure = true
        await record(error)
    }
}

public nonisolated struct HTTPResponse: Sendable {
    public init(data: Data, response: HTTPURLResponse, finalRequest: URLRequest? = nil) {
        self.data = data
        self.response = response
        self.finalRequest = finalRequest
        validation = nil
    }

    private init(data: Data, response: HTTPURLResponse, finalRequest: URLRequest?, validation: HTTPValidationObservation) {
        self.data = data; self.response = response; self.finalRequest = finalRequest; self.validation = validation
    }
    private let validation: HTTPValidationObservation?
    @MainActor fileprivate func observingValidation(_ report: @escaping @MainActor (any Error) async -> Void) -> HTTPResponse {
        .init(data: data, response: response, finalRequest: finalRequest, validation: HTTPValidationObservation(report))
    }
    public func reportValidationFailure(_ error: any Error) async { await validation?.report(error) }
    @MainActor public func validated<Value: Sendable>(_ decode: (Data, HTTPURLResponse) async throws -> Value) async throws -> Value {
        do { return try await decode(data, response) }
        catch { await reportValidationFailure(error); throw error }
    }

    public let data: Data
    public let response: HTTPURLResponse
    public let finalRequest: URLRequest?

    public var statusCode: Int { response.statusCode }
}

public nonisolated enum HTTPClientError: LocalizedError {
    case invalidResponse
    case responseTooLarge
    case unacceptableStatus(code: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case .responseTooLarge:
            return "服务器返回的数据超过可处理范围。"
        case let .unacceptableStatus(code, message):
            return message?.isEmpty == false ? message : "请求失败，HTTP 状态码 \(code)。"
        }
    }
}

/// 传输观察接口。应用层实现提示、诊断与测试传输策略。
public protocol HTTPClientObserving {
    func forRequest() -> any HTTPClientObserving
    func willSend(_ request: URLRequest) async throws
    func didFinish(
        request: URLRequest,
        finalRequest: URLRequest?,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        elapsed: TimeInterval
    ) async
}

public extension HTTPClientObserving {
    func forRequest() -> any HTTPClientObserving { self }
}

/// 处理请求发送和 HTTP 协议层校验；业务认证规则由上层 Service 处理。
public nonisolated enum HTTPResponseResourceLimits {
    public static let maximumStructuredBytes = 8 * 1_024 * 1_024
    public static let maximumErrorBytes = 16 * 1_024
    public static let maximumErrorCharacters = 512
}

public struct HTTPClient {
    private let transport: any HTTPTransport
    private let observer: (any HTTPClientObserving)?

    public init(transport: any HTTPTransport, observer: (any HTTPClientObserving)?) {
        self.transport = transport
        self.observer = observer
    }

    public func send(
        _ request: URLRequest,
        accepting statusCodes: Range<Int> = 200 ..< 300,
        alsoAccepting additionalStatusCodes: Set<Int> = [],
        maximumBytes: Int? = HTTPResponseResourceLimits.maximumStructuredBytes
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let observer = observer?.forRequest()
        try await observer?.willSend(request)
        try Task.checkCancellation()
        let startedAt = Date()
        var receivedData: Data?
        var receivedResponse: URLResponse?
        var finalRequest: URLRequest?
        let parent = HTTPRequestEvidenceContext.didReceiveFinalRequest
        let result: HTTPResponse
        do {
            try Task.checkCancellation()
            HTTPRequestEvidenceContext.willStart?()
            let (data, response) = try await HTTPRequestEvidenceContext.$didReceive.withValue(nil) {
                try await HTTPRequestEvidenceContext.$didReceiveFinalRequest.withValue({ value in
                    finalRequest = value
                    parent?(value)
                }) {
                    try await transport.data(for: request,
                        maximumBytes: maximumBytes ?? HTTPResponseResourceLimits.maximumStructuredBytes)
                }
            }
            receivedData = data
            receivedResponse = response
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPClientError.invalidResponse
            }
            if let record = HTTPRequestEvidenceContext.didReceive {
                await record(request, HTTPResponse(data: data, response: httpResponse, finalRequest: finalRequest))
                try Task.checkCancellation()
            }
            guard statusCodes.contains(httpResponse.statusCode) || additionalStatusCodes.contains(httpResponse.statusCode) else {
                let message = try await Self.errorMessageInBackground(from: data)
                throw HTTPClientError.unacceptableStatus(
                    code: httpResponse.statusCode,
                    message: message
                )
            }
            result = HTTPResponse(data: data, response: httpResponse, finalRequest: finalRequest)
        } catch {
            await observer?.didFinish(
                request: request, finalRequest: finalRequest, data: receivedData, response: receivedResponse, error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        }
        await observer?.didFinish(
            request: request, finalRequest: result.finalRequest, data: result.data, response: result.response, error: nil,
            elapsed: Date().timeIntervalSince(startedAt)
        )
        try Task.checkCancellation()
        guard let observer else { return result }
        return result.observingValidation { error in
            await observer.didFinish(request: request, finalRequest: result.finalRequest, data: result.data, response: result.response,
                error: error, elapsed: Date().timeIntervalSince(startedAt))
        }
    }

    @concurrent
    private static func errorMessageInBackground(from data: Data) async throws -> String? {
        try Task.checkCancellation()
        let message = errorMessage(from: data)
        try Task.checkCancellation()
        return message
    }

    public nonisolated static func errorMessage(from data: Data) -> String? {
        guard data.count <= HTTPResponseResourceLimits.maximumErrorBytes else { return nil }
        if
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        {
            if let text = value as? String { return boundedErrorMessage(text) }
            guard let object = value as? [String: Any] else { return nil }
            for key in ["message", "msg", "detail", "error"] {
                if let value = object[key] as? String, let message = boundedErrorMessage(value) {
                    return message
                }
                if let nested = object[key] as? [String: Any] {
                    for field in ["message", "msg", "detail", "error"] {
                        if let value = nested[field] as? String, let message = boundedErrorMessage(value) { return message }
                    }
                }
            }
            return nil
        }

        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = text.first, !["<", "{", "["].contains(first) else { return nil }
        return boundedErrorMessage(text)
    }

    private nonisolated static func boundedErrorMessage(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        let limit = HTTPResponseResourceLimits.maximumErrorCharacters
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// 网络验收逐次访问远端，沿所选会话传递认证信息。
public struct UncachedHTTPTransport: HTTPTransport {
    private let base: any HTTPTransport
    public init(base: any HTTPTransport) { self.base = base }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, maximumBytes: nil)
    }
    public func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        var outgoing = request
        outgoing.cachePolicy = .reloadIgnoringLocalCacheData
        return try await base.data(for: outgoing, maximumBytes: maximumBytes)
    }
}
