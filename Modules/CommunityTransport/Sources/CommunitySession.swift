import Foundation
import TransportCore

public nonisolated struct CommunitySessionIdentity: Equatable, Sendable {
    public let accountIdentifier: String
    public let generation: Int

    public init(accountIdentifier: String, generation: Int = 0) {
        self.accountIdentifier = accountIdentifier
        self.generation = generation
    }
}

public nonisolated struct CommunityCredentials: Sendable {
    public let identity: CommunitySessionIdentity
    public let cookie: String

    public init(identity: CommunitySessionIdentity, cookie: String) {
        self.identity = identity
        self.cookie = cookie
    }
}

public enum CommunitySessionRestorationError: Error {
    case credentialsRejected
}

/// 社区请求捕获身份快照，凭据更新保持在同一账号代际内。
public struct CommunitySession {
    public let httpClient: HTTPClient
    private let baseURL: URL
    private let credentials: () -> CommunityCredentials
    private let refresh: (CommunityCredentials) async throws -> Void

    public init(httpClient: HTTPClient, baseURL: URL, credentials: @escaping () -> CommunityCredentials, refresh: @escaping (CommunityCredentials) async throws -> Void) {
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.credentials = credentials
        self.refresh = refresh
    }

    public var fakeCookie: String { credentials().cookie }

    public func client<Failure: CommunityAPIServiceError>(errorDomain: String) -> CommunityAPIClient<Failure> {
        CommunityAPIClient(httpClient: httpClient, baseURL: baseURL, errorDomain: errorDomain, credentials: credentials, refreshHandler: refresh)
    }
}

/// 单个会话实例合并同账号的认证恢复，任务归属由身份快照维护。
public final class CommunitySessionRefreshCoordinator {
    private var pending: (identity: CommunitySessionIdentity, task: Task<Void, Error>)?

    public init() {}

    public func refresh(
        observed: CommunityCredentials,
        current: @escaping () -> CommunityCredentials,
        restore: @escaping () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard current().identity == observed.identity else { throw CancellationError() }
        guard current().cookie == observed.cookie else { return }
        if let pending, pending.identity == observed.identity {
            try await pending.task.value
            try Task.checkCancellation()
            guard current().identity == observed.identity else { throw CancellationError() }
            return
        }
        pending?.task.cancel()
        let task = Task { try await restore() }
        pending = (observed.identity, task)
        defer {
            if pending?.identity == observed.identity { pending = nil }
        }
        try await task.value
        try Task.checkCancellation()
        guard current().identity == observed.identity else { throw CancellationError() }
    }
}
