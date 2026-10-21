import Foundation

/// 按账号代际合并恢复操作，每位调用者独立处理取消。
@MainActor
public final class SessionRefreshCoordinator<Identity: Equatable & Sendable> {
    private struct Pending {
        let id: UUID
        let identity: Identity
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Void, any Error>]
    }
    private var pending: Pending?
    var waitingConsumerCount: Int { pending?.waiters.count ?? 0 }

    public init() {}

    /// 同账号认证共用操作，各等待者分别结束自己的请求。
    public func refresh(identity: Identity, restore: @escaping () async throws -> Void) async throws {
        try Task.checkCancellation()
        if let pending, pending.identity != identity { cancel() }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if pending != nil { pending?.waiters[waiter] = continuation }
                else {
                    let id = UUID()
                    pending = Pending(id: id, identity: identity, waiters: [waiter: continuation])
                    pending?.task = Task {
                        do { try await restore(); self.finish(id, result: .success(())) }
                        catch { self.finish(id, result: .failure(error)) }
                    }
                }
            }
        } onCancel: { Task { @MainActor in self.cancel(waiter) } }
        try Task.checkCancellation()
    }

    public func cancel() {
        guard let operation = pending else { return }
        finish(operation.id, result: .failure(CancellationError()))
        operation.task?.cancel()
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
