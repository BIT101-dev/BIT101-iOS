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

public enum CommunitySessionRestorationError: Error {
    case credentialsRejected
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

/// 单个会话实例合并同账号的认证恢复，任务归属由身份快照维护。
public final class CommunitySessionRefreshCoordinator {
    private struct Pending {
        let id: UUID
        let identity: CommunitySessionIdentity
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Void, any Error>]
    }
    private var pending: Pending?

    public init() {}

    public func refresh(observed: CommunityCredentials, current: @escaping () -> CommunityCredentials,
                        restore: @escaping () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard current().identity == observed.identity else { throw CancellationError() }
        guard current().cookie == observed.cookie else { return }
        if let pending, pending.identity != observed.identity { finish(pending.id, result: .failure(CancellationError())); pending.task?.cancel() }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if pending != nil { pending?.waiters[waiter] = continuation }
                else {
                    let id = UUID()
                    pending = Pending(id: id, identity: observed.identity, waiters: [waiter: continuation])
                    pending?.task = Task {
                        do { try await restore(); self.finish(id, result: .success(())) }
                        catch { self.finish(id, result: .failure(error)) }
                    }
                }
            }
        } onCancel: { Task { @MainActor in self.cancel(waiter) } }
        try Task.checkCancellation()
        guard current().identity == observed.identity else { throw CancellationError() }
    }

    private func finish(_ id: UUID, result: Result<Void, any Error>) {
        guard let operation = pending, operation.id == id else { return }
        pending = nil
        for continuation in operation.waiters.values { continuation.resume(with: result) }
    }

    private func cancel(_ waiter: UUID) {
        guard let continuation = pending?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if pending?.waiters.isEmpty == true { pending?.task?.cancel(); pending = nil }
    }
}
