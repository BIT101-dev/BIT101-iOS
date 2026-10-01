import Foundation

public protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public nonisolated struct HTTPResponse: Sendable {
    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }

    public let data: Data
    public let response: HTTPURLResponse

    public var statusCode: Int { response.statusCode }
}

public nonisolated enum HTTPClientError: LocalizedError {
    case invalidResponse
    case unacceptableStatus(code: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case let .unacceptableStatus(code, message):
            return message?.isEmpty == false ? message : "请求失败，HTTP 状态码 \(code)。"
        }
    }
}

/// 传输观察接口。应用层实现提示、诊断与测试传输策略。
public protocol HTTPClientObserving {
    func willSend(_ request: URLRequest) async throws
    func didFinish(
        request: URLRequest,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        elapsed: TimeInterval
    ) async
}

/// 处理请求发送和 HTTP 协议层校验；业务认证规则由上层 Service 处理。
public struct HTTPClient {
    private let transport: any HTTPTransport
    private let observer: (any HTTPClientObserving)?

    public init(transport: any HTTPTransport, observer: (any HTTPClientObserving)?) {
        self.transport = transport
        self.observer = observer
    }

    public func send(
        _ request: URLRequest,
        accepting statusCodes: Range<Int> = 200 ..< 300
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        try await observer?.willSend(request)
        try Task.checkCancellation()
        let startedAt = Date()
        var receivedData: Data?
        var receivedResponse: URLResponse?
        let result: HTTPResponse
        do {
            let (data, response) = try await transport.data(for: request)
            receivedData = data
            receivedResponse = response
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPClientError.invalidResponse
            }
            guard statusCodes.contains(httpResponse.statusCode) else {
                let message = try await Self.errorMessageInBackground(from: data)
                throw HTTPClientError.unacceptableStatus(
                    code: httpResponse.statusCode,
                    message: message
                )
            }
            result = HTTPResponse(data: data, response: httpResponse)
        } catch {
            await observer?.didFinish(
                request: request, data: receivedData, response: receivedResponse, error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        }
        await observer?.didFinish(
            request: request, data: result.data, response: result.response, error: nil,
            elapsed: Date().timeIntervalSince(startedAt)
        )
        try Task.checkCancellation()
        return result
    }

    @concurrent
    private static func errorMessageInBackground(from data: Data) async throws -> String? {
        try Task.checkCancellation()
        let message = errorMessage(from: data)
        try Task.checkCancellation()
        return message
    }

    public nonisolated static func errorMessage(from data: Data) -> String? {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in ["message", "msg", "detail", "error"] {
                if let value = object[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
