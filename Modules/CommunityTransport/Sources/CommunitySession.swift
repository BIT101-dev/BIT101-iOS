import Foundation
import Combine
import TransportCore
import OSLog

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
    private let backgroundRefresh: ((CommunityCredentials) -> Void)?
    public let credentialsChanges: AnyPublisher<CommunityCredentials, Never>

    public init(httpClient: HTTPClient, baseURL: URL, credentials: @escaping () -> CommunityCredentials,
                refresh: @escaping (CommunityCredentials) async throws -> Void,
                credentialsChanges: AnyPublisher<CommunityCredentials, Never> = Empty().eraseToAnyPublisher(),
                backgroundRefresh: ((CommunityCredentials) -> Void)? = nil) {
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.credentials = credentials
        self.refresh = refresh
        self.backgroundRefresh = backgroundRefresh
        self.credentialsChanges = credentialsChanges
    }

    public var currentCredentials: CommunityCredentials { credentials() }
    public var fakeCookie: String { currentCredentials.cookie }

    public func client<Failure: CommunityAPIServiceError>(errorDomain: String) -> CommunityAPIClient<Failure> {
        CommunityAPIClient(httpClient: httpClient, baseURL: baseURL, errorDomain: errorDomain, credentials: credentials,
            refreshHandler: refresh, backgroundRefresh: backgroundRefresh)
    }
}

/// 社区 Cookie 更新保留观察快照，并复用共享恢复协调器。
public final class CommunitySessionRefreshCoordinator {
    private static let logger = Logger(subsystem: "BIT101", category: "CommunitySession")
    private let coordinator = SessionRefreshCoordinator<CommunitySessionIdentity>()
    private var background: (id: UUID, observed: CommunityCredentials, task: Task<Void, Never>)?
    public init() {}

    public func start(observed: CommunityCredentials, operation: @escaping () async throws -> Void) {
        guard background?.observed != observed else { return }
        background?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            defer { if self?.background?.id == id { self?.background = nil } }
            do { try await operation() }
            catch {
                guard !TaskCancellation.matches(error) else { return }
                Self.logger.error("社区后台认证恢复受阻：\(String(describing: error), privacy: .private)")
            }
        }
        background = (id, observed, task)
    }

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

    public func cancel() {
        background?.task.cancel()
        background = nil
        coordinator.cancel()
    }
}
