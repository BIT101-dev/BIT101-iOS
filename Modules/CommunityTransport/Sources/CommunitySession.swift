import Foundation
import Combine
import TransportCore

public nonisolated struct CommunitySessionIdentity: Equatable, Sendable {
    public let accountIdentifier: String
    public let generation: Int

    public init(accountIdentifier: String, generation: Int = 0) {
        self.accountIdentifier = accountIdentifier
        self.generation = generation
    }
}

public nonisolated struct CommunityCredentials: Equatable, Sendable {
    public let identity: CommunitySessionIdentity
    public let cookie: String

    public init(identity: CommunitySessionIdentity, cookie: String) {
        self.identity = identity
        self.cookie = cookie
    }
}

public enum CommunitySessionRestorationError: LocalizedError {
    case credentialsRejected
    public var errorDescription: String? {
        "请重新登录社区账号。本机日程与成绩继续可用。"
    }
}

/// 社区请求捕获身份快照，凭据更新保持在同一账号代际内。
public struct CommunitySession {
    public let httpClient: HTTPClient
    private let baseURL: URL
    private let credentials: () -> CommunityCredentials
    private let refresh: (CommunityCredentials) async throws -> Void
    public let credentialsChanges: AnyPublisher<CommunityCredentials, Never>

    public init(httpClient: HTTPClient, baseURL: URL, credentials: @escaping () -> CommunityCredentials,
                refresh: @escaping (CommunityCredentials) async throws -> Void,
                credentialsChanges: AnyPublisher<CommunityCredentials, Never> = Empty().eraseToAnyPublisher()) {
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.credentials = credentials
        self.refresh = refresh
        self.credentialsChanges = credentialsChanges
    }

    public var currentCredentials: CommunityCredentials { credentials() }
    public var fakeCookie: String { currentCredentials.cookie }

    public func client<Failure: CommunityAPIServiceError>(errorDomain: String) -> CommunityAPIClient<Failure> {
        CommunityAPIClient(httpClient: httpClient, baseURL: baseURL, errorDomain: errorDomain, credentials: credentials, refreshHandler: refresh)
    }
}

/// 社区 Cookie 更新保留观察快照，并复用共享恢复协调器。
public final class CommunitySessionRefreshCoordinator {
    private let coordinator = SessionRefreshCoordinator<CommunitySessionIdentity>()
    public init() {}

    public func refresh(observed: CommunityCredentials, current: @escaping () -> CommunityCredentials,
                        restore: @escaping () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard current().identity == observed.identity else { throw CancellationError() }
        guard current().cookie == observed.cookie else { return }
        try await refresh(identity: observed.identity, restore: restore)
        guard current().identity == observed.identity else { throw CancellationError() }
    }

    public func refresh(identity: CommunitySessionIdentity, restore: @escaping () async throws -> Void) async throws {
        try await coordinator.refresh(identity: identity, restore: restore)
    }

    public func cancel() { coordinator.cancel() }
}
