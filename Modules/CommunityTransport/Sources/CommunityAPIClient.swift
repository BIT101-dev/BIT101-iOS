import Foundation
import TransportCore

public struct CommunityLikeRequest: Encodable {
    public let obj: String
    public init(obj: String) { self.obj = obj }
}

public struct CommunityCreateCommentRequest: Encodable {
    public let obj: String
    public let text: String
    public let replyObj: String?
    public let replyUid: Int?
    public let anonymous: Bool?
    public let rate: Int?
    public let imageMids: [String]

    public init(obj: String, text: String, replyObj: String?, replyUid: Int?, anonymous: Bool?,
                rate: Int? = nil, imageMids: [String]) {
        self.obj = obj
        self.text = text
        self.replyObj = replyObj
        self.replyUid = replyUid
        self.anonymous = anonymous
        self.rate = rate
        self.imageMids = imageMids
    }

    enum CodingKeys: String, CodingKey {
        case obj, text, anonymous, rate
        case replyObj = "reply_obj"
        case replyUid = "reply_uid"
        case imageMids = "image_mids"
    }
}

public enum CommunityAuthentication {
    case required
    case optional
    case none
}

public enum CommunityRetryPolicy {
    case never
    case afterCredentialRefresh
}

public struct CommunityCreateOutcomeUnknown: LocalizedError, CustomNSError {
    public static let reviewMessage = "请求已发出，发布结果待确认。请关闭编辑页，刷新已发布内容并核对结果后再操作。"
    public static let commentReviewMessage = "这条评论的发送结果待确认。请先核对评论列表；当前可继续发送其他评论。"
    public static let reportReviewMessage = "举报请求已发出，提交结果待确认。请稍后关注处理结果。当前页面已暂停再次提交。"
    public let underlying: any Error
    public init(underlying: any Error) { self.underlying = underlying }
    public var errorDescription: String? {
        Self.reviewMessage
    }
    public var errorUserInfo: [String: Any] {
        [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: errorDescription ?? "发布结果待确认。"]
    }
}

public struct CommunityToggleOutcomeUnknown: LocalizedError, CustomNSError {
    public static let reviewMessage = "操作结果待确认。请刷新页面核对当前状态后再操作。"
    public let underlying: any Error
    public init(underlying: any Error) { self.underlying = underlying }
    public var errorDescription: String? { Self.reviewMessage }
    public var errorUserInfo: [String: Any] {
        [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: Self.reviewMessage]
    }
}

public protocol CommunityAPIServiceError: Error {
    static var communityNotLoggedIn: Self { get }
    static var communityInvalidResponse: Self { get }
    static func communityResourceFailure(path: String, message: String?) -> Self?
}

extension CommunityAPIServiceError {
    public static func communityResourceFailure(path: String, message: String?) -> Self? { nil }
}

private enum CommunityCredentialRefreshContext {
    @TaskLocal static var isRestoring = false
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
        pathComponent: String? = nil,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        authentication: CommunityAuthentication = .required,
        retryPolicy: CommunityRetryPolicy = .afterCredentialRefresh,
        validate: (@Sendable (Response) throws -> Void)? = nil
    ) async throws -> Response {
        let identity = authentication == .none ? nil : credentials().identity
        return try await withMutationOutcome(path: path, method: method) {
            let response = try await send(path: path, pathComponent: pathComponent,
                queryItems: queryItems, method: method, body: body, contentType: contentType,
                authentication: authentication, retryPolicy: retryPolicy)
            let value: Response
            do {
                value = try await Self.decodeResponse(Response.self, from: response.data)
                try validate?(value)
            } catch {
                if TaskCancellation.matches(error) { throw error }
                await response.reportValidationFailure(error)
                let failure = Failure.communityInvalidResponse as NSError
                throw NSError(domain: failure.domain, code: failure.code,
                    userInfo: failure.userInfo.merging([NSUnderlyingErrorKey: error,
                        NSLocalizedDescriptionKey: failure.localizedDescription]) { _, value in value })
            }
            try validateIdentity(identity)
            return value
        }
    }

    private func withMutationOutcome<Value: Sendable>(path: String, method: String,
        operation: () async throws -> Value) async throws -> Value {
        let isCreation = method == "POST" && ["posters", "papers", "reaction/comments", "manage/reports"].contains(path)
        let isToggle = method == "POST" && (path == "reaction/like" || path == "user/follow" || path.hasPrefix("user/follow/"))
        var started = false
        var rejected = false
        let parentStart = HTTPRequestEvidenceContext.willStart
        let parentReceive = HTTPRequestEvidenceContext.didReceive
        let receive: (@MainActor @Sendable (URLRequest, HTTPResponse) async -> Void)?
        if isCreation || isToggle {
            receive = { request, response in
                let evidence = HTTPRequestEvidence(request: request, response: response.response, finalRequest: response.finalRequest)
                if !CommunityCredentialRefreshContext.isRestoring {
                    rejected = (400..<500).contains(evidence.statusCode) && evidence.statusCode != 408
                        && evidence.endpoint == evidence.finalEndpoint && evidence.method == evidence.finalMethod
                }
                await parentReceive?(request, response)
            }
        } else { receive = parentReceive }
        do {
            return try await HTTPRequestEvidenceContext.$willStart.withValue({
                if !CommunityCredentialRefreshContext.isRestoring { started = true; rejected = false }
                parentStart?()
            }) {
                try await HTTPRequestEvidenceContext.$didReceive.withValue(receive) {
                    return try await operation()
                }
            }
        } catch {
            guard isCreation || isToggle, started, !rejected, !(error is HTTPRequestNotSent) else { throw error }
            if isToggle { throw CommunityToggleOutcomeUnknown(underlying: error) }
            throw CommunityCreateOutcomeUnknown(underlying: error)
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
        _ = try await withMutationOutcome(path: path, method: method) {
            try await send(
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            authentication: authentication,
            retryPolicy: retryPolicy
            )
        }
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
        pathComponent: String? = nil,
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
        if let pathComponent {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/%?#[]@!$&'()*+,;=")
            guard let encoded = pathComponent.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw Failure.communityInvalidResponse
            }
            components?.percentEncodedPath += "/" + encoded
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let rawURL = components?.url else {
            throw Failure.communityInvalidResponse
        }
        let url = HTTPSURLUpgrade.upgradedURL(from: rawURL)

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
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
        if request.value(forHTTPHeaderField: "fake-cookie") != nil {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }

        do {
            let response = try await httpClient.send(request)
            do {
                try validateResponse(response, request: request)
                try validateIdentity(identity)
            } catch { await response.reportValidationFailure(error); throw error }
            return response
        } catch let HTTPClientError.unacceptableStatus(code, _) where code == 401 && authentication != .none
            && !observed.cookie.isEmpty && retryPolicy == .afterCredentialRefresh {
            do {
                try validateIdentity(identity)
                try await CommunityCredentialRefreshContext.$isRestoring.withValue(true) { try await refreshHandler(observed) }
            } catch CommunitySessionRestorationError.credentialsRejected {
                try validateIdentity(identity)
                throw Failure.communityNotLoggedIn
            } catch {
                if error is HTTPRequestNotSent { throw error }
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
                do {
                    try validateResponse(response, request: request)
                    try validateIdentity(identity)
                } catch { await response.reportValidationFailure(error); throw error }
                return response
            } catch let HTTPClientError.unacceptableStatus(retryCode, retryMessage) {
                try validateIdentity(identity)
                if retryCode == 401 { throw Failure.communityNotLoggedIn }
                if method == "GET", let failure = Failure.communityResourceFailure(path: path, message: retryMessage) { throw failure }
                throw NSError(
                    domain: errorDomain,
                    code: retryCode,
                    userInfo: [NSLocalizedDescriptionKey: retryMessage ?? "请求失败，HTTP 状态码 \(retryCode)。"]
                )
            } catch is HTTPClientError {
                try validateIdentity(identity)
                throw Failure.communityInvalidResponse
            } catch {
                if error is HTTPRequestNotSent { throw error }
                try validateIdentity(identity)
                throw error
            }
        } catch let HTTPClientError.unacceptableStatus(code, message) {
            try validateIdentity(identity)
            if code == 401 { throw Failure.communityNotLoggedIn }
            if method == "GET", let failure = Failure.communityResourceFailure(path: path, message: message) { throw failure }
            throw NSError(
                domain: errorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message ?? "请求失败，HTTP 状态码 \(code)。"]
            )
        } catch is HTTPClientError {
            try validateIdentity(identity)
            throw Failure.communityInvalidResponse
        } catch {
            if error is HTTPRequestNotSent { throw error }
            try validateIdentity(identity)
            throw error
        }
    }

    private func validateResponse(_ response: HTTPResponse, request: URLRequest) throws {
        let evidence = HTTPRequestEvidence(request: request, response: response.response, finalRequest: response.finalRequest)
        guard response.response.url == request.url, evidence.method == evidence.finalMethod else {
            throw Failure.communityInvalidResponse
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
