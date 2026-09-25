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

@MainActor
private final class CommunitySessionRefreshCoordinator {
    static let shared = CommunitySessionRefreshCoordinator()

    private var refreshTask: Task<Void, Error>?

    private init() {}

    func refreshIfNeeded(observedCookie: String, storage: LoginStorage) async throws {
        guard storage.fakeCookie == observedCookie else { return }
        if let refreshTask {
            try await refreshTask.value
            return
        }

        let task = Task { @MainActor in
            guard let credentials = try storage.loadCredentials() else {
                throw LoginServiceError.unableToRestoreSchoolSession
            }
            _ = try await LoginService(storage: storage).login(
                studentID: credentials.studentID,
                password: credentials.password
            )
        }
        refreshTask = task
        do {
            try await task.value
            refreshTask = nil
        } catch {
            refreshTask = nil
            throw error
        }
    }
}

/// `CommunityAPIClient` 统一处理 BIT101 社区后端的认证、URL、HTTP 状态码和 JSON 边界。
struct CommunityAPIClient<Failure: CommunityAPIServiceError> {
    private let baseURL: URL
    private let httpClient: HTTPClient
    private let fakeCookieProvider: () -> String
    private let refreshHandler: (String) async throws -> Void
    private let errorDomain: String

    init(
        storage: LoginStorage = .shared,
        httpClient: HTTPClient = .community,
        baseURL: URL = AppURL.required("https://bit101.flwfdd.xyz"),
        errorDomain: String
    ) {
        fakeCookieProvider = { storage.fakeCookie }
        refreshHandler = { observedCookie in
            try await CommunitySessionRefreshCoordinator.shared.refreshIfNeeded(
                observedCookie: observedCookie,
                storage: storage
            )
        }
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.errorDomain = errorDomain
    }

    init(
        httpClient: HTTPClient,
        baseURL: URL,
        errorDomain: String,
        fakeCookieProvider: @escaping () -> String,
        refreshHandler: @escaping (String) async throws -> Void = { _ in }
    ) {
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.errorDomain = errorDomain
        self.fakeCookieProvider = fakeCookieProvider
        self.refreshHandler = refreshHandler
    }

    func request<Response: Decodable & Sendable>(
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
            if TaskCancellation.matches(error) {
                throw error
            }
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

    /// 社区列表可能包含大量帖子、评论和图片元数据；解码放在独立并发任务，
    /// 返回值用 Sendable 约束跨回 MainActor 的数据边界。
    private static func decodeResponse<Response: Decodable & Sendable>(
        _ type: Response.Type,
        from data: Data
    ) async throws -> Response {
        let decodingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(type, from: data)
            try Task.checkCancellation()
            return response
        }
        let response = try await withTaskCancellationHandler {
            try await decodingTask.value
        } onCancel: {
            decodingTask.cancel()
        }
        try Task.checkCancellation()
        return response
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
        guard let rawURL = components?.url else {
            throw Failure.communityInvalidResponse
        }
        let url = HTTPSURLUpgrade.upgradedURL(from: rawURL)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let resolvedContentType = contentType ?? (body == nil ? nil : "application/json") {
            request.setValue(resolvedContentType, forHTTPHeaderField: "Content-Type")
        }

        var observedCookie: String?
        switch authentication {
        case .required:
            let fakeCookie = fakeCookieProvider()
            guard !fakeCookie.isEmpty else { throw Failure.communityNotLoggedIn }
            observedCookie = fakeCookie
            request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
        case .optional:
            let fakeCookie = fakeCookieProvider()
            if !fakeCookie.isEmpty {
                request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
            }
        case .none:
            break
        }

        do {
            return try await httpClient.send(request)
        } catch let HTTPClientError.unacceptableStatus(code, _) where code == 401 && authentication == .required {
            do {
                try await refreshHandler(observedCookie ?? "")
            } catch {
                throw Failure.communityNotLoggedIn
            }

            let refreshedCookie = fakeCookieProvider()
            guard !refreshedCookie.isEmpty else {
                throw Failure.communityNotLoggedIn
            }
            request.setValue(refreshedCookie, forHTTPHeaderField: "fake-cookie")

            do {
                return try await httpClient.send(request)
            } catch let HTTPClientError.unacceptableStatus(retryCode, retryMessage) {
                if retryCode == 401 { throw Failure.communityNotLoggedIn }
                throw NSError(
                    domain: errorDomain,
                    code: retryCode,
                    userInfo: [NSLocalizedDescriptionKey: retryMessage ?? "请求失败，HTTP 状态码 \(retryCode)。"]
                )
            } catch is HTTPClientError {
                throw Failure.communityInvalidResponse
            }
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
        let safeFieldName = escapedHeaderParameter(fieldName)
        let safeFilename = escapedHeaderParameter(filename)
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(safeFieldName)\"; filename=\"\(safeFilename)\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private static func escapedHeaderParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
