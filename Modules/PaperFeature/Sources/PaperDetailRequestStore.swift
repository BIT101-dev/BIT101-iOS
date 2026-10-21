import CommunityTransport
import Foundation

/// 同一文章合并在途请求，作者预览以四个名额共享响应，并保留四篇详情供首次打开复用。
@MainActor
final class PaperDetailRequestStore {
    static let maximumConcurrentRequests = 4
    private struct Key: Hashable {
        let id: Int
        let account: String
        let generation: Int
        let authenticated: Bool
        let epoch: Int
        init(id: Int, credentials: CommunityCredentials, epoch: Int) {
            self.id = id
            account = credentials.identity.accountIdentifier
            generation = credentials.identity.generation
            authenticated = !credentials.cookie.isEmpty
            self.epoch = epoch
        }
    }
    private struct Operation {
        let id: UUID
        let epoch: Int
        let load: @MainActor () async throws -> PaperDetail
        var cacheResult: Bool
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<PaperDetail, any Error>]
    }
    private var operations: [Key: Operation] = [:]
    private var queued: [Key] = []
    private var active: Set<UUID> = []
    private var cache: [Key: PaperDetail] = [:]
    private var cacheOrder: [Key] = []
    private var cacheEpoch = 0

    func preview(id: Int, credentials: CommunityCredentials, load: @escaping @MainActor () async throws -> PaperDetail) async throws -> PaperPreviewMetadata {
        try Task.checkCancellation()
        let key = Key(id: id, credentials: credentials, epoch: cacheEpoch)
        if let detail = cache[key] { return detail.previewMetadata }
        let detail = try await response(key: key, cacheResult: true, load: load)
        try Task.checkCancellation()
        return detail.previewMetadata
    }

    func detail(id: Int, credentials: CommunityCredentials, load: @escaping @MainActor () async throws -> PaperDetail) async throws -> PaperDetail {
        try Task.checkCancellation()
        let key = Key(id: id, credentials: credentials, epoch: cacheEpoch)
        if let detail = cache.removeValue(forKey: key) {
            cacheOrder.removeAll { $0 == key }
            return detail
        }
        let detail = try await response(key: key, cacheResult: false, load: load)
        try Task.checkCancellation()
        cache[key] = nil
        cacheOrder.removeAll { $0 == key }
        return detail
    }

    func invalidate() {
        cacheEpoch &+= 1
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func response(key: Key, cacheResult: Bool, load: @escaping @MainActor () async throws -> PaperDetail) async throws -> PaperDetail {
        try Task.checkCancellation()
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var operation = operations[key] {
                    operation.cacheResult = operation.cacheResult || cacheResult
                    operation.waiters[waiter] = continuation
                    operations[key] = operation
                } else {
                    operations[key] = Operation(id: UUID(), epoch: cacheEpoch, load: load,
                        cacheResult: cacheResult, waiters: [waiter: continuation])
                    queued.append(key)
                }
                startQueued()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(waiter: waiter, key: key) }
        }
    }

    private func startQueued() {
        while active.count < Self.maximumConcurrentRequests, !queued.isEmpty {
            let key = queued.removeFirst()
            guard var operation = operations[key] else { continue }
            let id = operation.id
            active.insert(id)
            operation.task = Task {
                let result: Result<PaperDetail, any Error>
                do { result = .success(try await operation.load()) }
                catch { result = .failure(error) }
                self.finish(result, key: key, id: id)
            }
            operations[key] = operation
        }
    }

    private func finish(_ result: Result<PaperDetail, any Error>, key: Key, id: UUID) {
        active.remove(id)
        defer { startQueued() }
        guard operations[key]?.id == id, let operation = operations.removeValue(forKey: key) else { return }
        if operation.cacheResult, operation.epoch == cacheEpoch, case let .success(detail) = result,
           PaperContentResourceLimits.acceptsPreviewCache(detail) {
            cache[key] = detail
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            while cacheOrder.count > Self.maximumConcurrentRequests { cache[cacheOrder.removeFirst()] = nil }
        }
        for continuation in operation.waiters.values { continuation.resume(with: result) }
    }

    private func cancel(waiter: UUID, key: Key) {
        guard var operation = operations[key], let continuation = operation.waiters.removeValue(forKey: waiter) else { return }
        if operation.waiters.isEmpty {
            operations[key] = nil
            queued.removeAll { $0 == key }
            operation.task?.cancel()
        } else { operations[key] = operation }
        continuation.resume(throwing: CancellationError())
    }
}
