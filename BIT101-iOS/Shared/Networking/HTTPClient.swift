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

/// 只负责发送请求和校验 HTTP 协议层，不包含任何业务认证规则。
struct HTTPClient {
    let transport: any HTTPTransport

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    func send(
        _ request: URLRequest,
        accepting statusCodes: Range<Int> = 200 ..< 300
    ) async throws -> HTTPResponse {
        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        guard statusCodes.contains(httpResponse.statusCode) else {
            throw HTTPClientError.unacceptableStatus(
                code: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
        return HTTPResponse(data: data, response: httpResponse)
    }

    static let community = HTTPClient(transport: NetworkSessionPool.community)
    static let shared = HTTPClient(transport: URLSession.shared)

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
    /// BIT101 社区接口共享连接池、Cookie 容器和 URLCache，避免每个 Service 重建 TLS 连接。
    static let community: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    static let scoreAuthentication: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    /// 可信成绩单图片只使用内存态 ephemeral 会话，不进入共享磁盘缓存。
    static let sensitiveDownloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
}
