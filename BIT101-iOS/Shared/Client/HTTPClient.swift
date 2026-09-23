import Foundation

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

struct HTTPResponse {
    let data: Data
    let response: HTTPURLResponse

    var statusCode: Int { response.statusCode }
}

enum HTTPClientError: LocalizedError {
    case invalidResponse
    case unacceptableStatus(code: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case let .unacceptableStatus(code, message):
            return message?.isEmpty == false ? message : "请求失败，HTTP 状态码 \(code)。"
        }
    }
}

/// 处理请求发送和 HTTP 协议层校验；业务认证规则由上层 Service 处理。
struct HTTPClient {
    let transport: any HTTPTransport
    let networkWarningCenter: NetworkMagicWarningCenter?

#if BIT101_AUTOMATED_TESTING
    private static let defaultNetworkWarningCenter: NetworkMagicWarningCenter? = nil
#else
    private static let defaultNetworkWarningCenter: NetworkMagicWarningCenter? = .shared
#endif

    init(
        transport: any HTTPTransport,
        networkWarningCenter: NetworkMagicWarningCenter? = HTTPClient.defaultNetworkWarningCenter
    ) {
        self.transport = transport
        self.networkWarningCenter = networkWarningCenter
    }

    func send(
        _ request: URLRequest,
        accepting statusCodes: Range<Int> = 200 ..< 300
    ) async throws -> HTTPResponse {
        if let url = request.url, let networkWarningCenter {
            _ = await networkWarningCenter.consider(url: url)
        }
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            await NetworkDiagnosticStore.shared.record(
                request: request, data: nil, response: nil, error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            let error = HTTPClientError.invalidResponse
            await NetworkDiagnosticStore.shared.record(
                request: request, data: data, response: response, error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        }
        guard statusCodes.contains(httpResponse.statusCode) else {
            let error = HTTPClientError.unacceptableStatus(
                code: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
            await NetworkDiagnosticStore.shared.record(
                request: request, data: data, response: httpResponse, error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        }
        await NetworkDiagnosticStore.shared.record(
            request: request, data: data, response: httpResponse, error: nil,
            elapsed: Date().timeIntervalSince(startedAt)
        )
        return HTTPResponse(data: data, response: httpResponse)
    }

    static let community = HTTPClient(transport: NetworkSessionPool.community)
    static let shared = HTTPClient(transport: NetworkSessionPool.shared)

    static func errorMessage(from data: Data) -> String? {
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

enum NetworkSessionPool {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    /// BIT101 社区接口共享连接池、Cookie 容器和 URLCache，供各 Service 复用 TLS 连接。
    static let community: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    static let scoreAuthentication: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    /// 可信成绩单图片使用内存态 ephemeral 会话，并与共享磁盘缓存隔离。
    static let sensitiveDownloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }()
}
