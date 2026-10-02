import Foundation
import TransportCore

public enum CommunityAuthentication {
    case required
    case optional
    case none
}

public enum CommunityRetryPolicy {
    case never
    case afterCredentialRefresh
}

public protocol CommunityAPIServiceError: Error {
    static var communityNotLoggedIn: Self { get }
    static var communityInvalidResponse: Self { get }
}

/// `CommunityAPIClient` 统一处理 BIT101 社区后端的认证、URL、HTTP 状态码和 JSON 边界。
public struct CommunityAPIClient<Failure: CommunityAPIServiceError> {
    private let baseURL: URL
    private let httpClient: HTTPClient
    private let credentials: () -> CommunityCredentials
    private let refreshHandler: (CommunityCredentials) async throws -> Void
    private let errorDomain: String

    public init(
        httpClient: HTTPClient,
        baseURL: URL,
        errorDomain: String,
        credentials: @escaping () -> CommunityCredentials,
        refreshHandler: @escaping (CommunityCredentials) async throws -> Void = { _ in }
    ) {
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.errorDomain = errorDomain
        self.credentials = credentials
        self.refreshHandler = refreshHandler
    }

    public func request<Response: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        authentication: CommunityAuthentication = .required,
        retryPolicy: CommunityRetryPolicy = .afterCredentialRefresh
    ) async throws -> Response {
        let identity = authentication == .none ? nil : credentials().identity
        let response = try await send(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body,
            contentType: contentType,
            authentication: authentication,
            retryPolicy: retryPolicy
        )

        do {
            let value = try await Self.decodeResponse(Response.self, from: response.data)
            try validateIdentity(identity)
            return value
        } catch {
            if TaskCancellation.matches(error) {
                throw error
            }
            throw Failure.communityInvalidResponse
        }
    }

    public func requestData(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        authentication: CommunityAuthentication = .required,
        retryPolicy: CommunityRetryPolicy = .afterCredentialRefresh
    ) async throws -> Data {
        try await send(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body,
            contentType: contentType,
            authentication: authentication,
            retryPolicy: retryPolicy
        ).data
    }

    public func requestVoid(
        path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        authentication: CommunityAuthentication = .required,
        retryPolicy: CommunityRetryPolicy = .afterCredentialRefresh
    ) async throws {
        _ = try await send(
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            authentication: authentication,
            retryPolicy: retryPolicy
        )
    }

    public func encode<Body: Encodable>(_ body: Body) throws -> Data {
        try JSONEncoder().encode(body)
    }

    /// 后台解码沿用调用任务的优先级、取消状态和任务局部值。
    @concurrent
    private static func decodeResponse<Response: Decodable & Sendable>(
        _ type: Response.Type,
        from data: Data
    ) async throws -> Response {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(type, from: data)
        try Task.checkCancellation()
        return response
    }

    private func send(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String,
        body: Data?,
        contentType: String?,
        authentication: CommunityAuthentication,
        retryPolicy: CommunityRetryPolicy
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

        try Task.checkCancellation()
        let observed = credentials()
        let identity = authentication == .none ? nil : observed.identity
        switch authentication {
        case .required:
            let fakeCookie = observed.cookie
            guard !fakeCookie.isEmpty else { throw Failure.communityNotLoggedIn }
            request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
        case .optional:
            let fakeCookie = observed.cookie
            if !fakeCookie.isEmpty {
                request.setValue(fakeCookie, forHTTPHeaderField: "fake-cookie")
            }
        case .none:
            break
        }

        do {
            let response = try await httpClient.send(request)
            try validateIdentity(identity)
            return response
        } catch let HTTPClientError.unacceptableStatus(code, _) where code == 401 && authentication == .required && retryPolicy == .afterCredentialRefresh {
            do {
                try validateIdentity(identity)
                try await refreshHandler(observed)
            } catch CommunitySessionRestorationError.credentialsRejected {
                try validateIdentity(identity)
                throw Failure.communityNotLoggedIn
            } catch {
                try validateIdentity(identity)
                throw error
            }

            try validateIdentity(identity)
            let refreshedCookie = credentials().cookie
            guard !refreshedCookie.isEmpty else {
                throw Failure.communityNotLoggedIn
            }
            request.setValue(refreshedCookie, forHTTPHeaderField: "fake-cookie")

            do {
                let response = try await httpClient.send(request)
                try validateIdentity(identity)
                return response
            } catch let HTTPClientError.unacceptableStatus(retryCode, retryMessage) {
                try validateIdentity(identity)
                if retryCode == 401 { throw Failure.communityNotLoggedIn }
                throw NSError(
                    domain: errorDomain,
                    code: retryCode,
                    userInfo: [NSLocalizedDescriptionKey: retryMessage ?? "请求失败，HTTP 状态码 \(retryCode)。"]
                )
            } catch is HTTPClientError {
                try validateIdentity(identity)
                throw Failure.communityInvalidResponse
            } catch {
                try validateIdentity(identity)
                throw error
            }
        } catch let HTTPClientError.unacceptableStatus(code, message) {
            try validateIdentity(identity)
            if code == 401 { throw Failure.communityNotLoggedIn }
            throw NSError(
                domain: errorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message ?? "请求失败，HTTP 状态码 \(code)。"]
            )
        } catch is HTTPClientError {
            try validateIdentity(identity)
            throw Failure.communityInvalidResponse
        } catch {
            try validateIdentity(identity)
            throw error
        }
    }

    private func validateIdentity(_ identity: CommunitySessionIdentity?) throws {
        try Task.checkCancellation()
        guard let identity else { return }
        guard credentials().identity == identity else { throw CancellationError() }
    }
}

public enum MultipartFormData {
    public static func jpegFile(data: Data, filename: String, fieldName: String = "file") -> (body: Data, contentType: String) {
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
