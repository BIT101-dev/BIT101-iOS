import Foundation

enum CommunityAuthentication {
    case required
    case optional
    case none
}

protocol CommunityAPIServiceError: Error {
    static var communityNotLoggedIn: Self { get }
    static var communityInvalidResponse: Self { get }
}

/// `Decodable` 元类型只用于后台队列同步调用 `JSONDecoder`，生命周期由调用栈保证。
private struct CommunityDecodableType<Response: Decodable>: @unchecked Sendable {
    let value: Response.Type
}

/// BIT101 社区后端的统一认证、URL、状态码和 JSON 边界。
struct CommunityAPIClient<Failure: CommunityAPIServiceError> {
    private let baseURL: URL
    private let httpClient: HTTPClient
    private let fakeCookieProvider: () -> String
    private let errorDomain: String

    init(
        storage: LoginStorage = .shared,
        httpClient: HTTPClient = .community,
        baseURL: URL = AppURL.required("https://bit101.flwfdd.xyz"),
        errorDomain: String
    ) {
        fakeCookieProvider = { storage.fakeCookie }
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.errorDomain = errorDomain
    }

    init(
        httpClient: HTTPClient,
        baseURL: URL,
        errorDomain: String,
        fakeCookieProvider: @escaping () -> String
    ) {
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.errorDomain = errorDomain
        self.fakeCookieProvider = fakeCookieProvider
    }

    func request<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        authentication: CommunityAuthentication = .required
    ) async throws -> Response {
        let response = try await send(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body,
            contentType: contentType,
            authentication: authentication
        )

        do {
            return try await Self.decodeResponse(Response.self, from: response.data)
        } catch {
            throw Failure.communityInvalidResponse
        }
    }

    func requestData(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        authentication: CommunityAuthentication = .required
    ) async throws -> Data {
        try await send(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body,
            contentType: contentType,
            authentication: authentication
        ).data
    }

    func requestVoid(
        path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        authentication: CommunityAuthentication = .required
    ) async throws {
        _ = try await send(
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            authentication: authentication
        )
    }

    func encode<Body: Encodable>(_ body: Body) throws -> Data {
        try JSONEncoder().encode(body)
    }

    /// 社区列表响应可能包含大量帖子和嵌套图片；解码不应占用 MainActor 的滚动帧。
    private nonisolated static func decodeResponse<Response: Decodable>(
        _ type: Response.Type,
        from data: Data
    ) async throws -> Response {
        let responseType = CommunityDecodableType(value: type)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    continuation.resume(returning: try decoder.decode(responseType.value, from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func send(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String,
        body: Data?,
        contentType: String?,
        authentication: CommunityAuthentication
    ) async throws -> HTTPResponse {
        var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw Failure.communityInvalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let resolvedContentType = contentType ?? (body == nil ? nil : "application/json") {
            request.setValue(resolvedContentType, forHTTPHeaderField: "Content-Type")
        }

        let fakeCookie = fakeCookieProvider()
        switch authentication {
        case .required:
            guard !fakeCookie.isEmpty else { throw Failure.communityNotLoggedIn }
            request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
        case .optional:
            if !fakeCookie.isEmpty {
                request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
            }
        case .none:
            break
        }

        do {
            return try await httpClient.send(request)
        } catch let HTTPClientError.unacceptableStatus(code, message) {
            if code == 401 { throw Failure.communityNotLoggedIn }
            throw NSError(
                domain: errorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message ?? "请求失败，HTTP 状态码 \(code)。"]
            )
        } catch is HTTPClientError {
            throw Failure.communityInvalidResponse
        }
    }
}

enum MultipartFormData {
    static func jpegFile(data: Data, filename: String, fieldName: String = "file") -> (body: Data, contentType: String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}
