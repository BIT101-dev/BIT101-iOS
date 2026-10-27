import CommunityTransport
import Foundation

/// 四个请求名额为主动阅读预留一个，同一文章合并请求，预览保留四篇详情供首次打开复用。
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
    private struct Waiter {
        let foreground: Bool
        let continuation: CheckedContinuation<PaperDetail, any Error>
    }
    private struct Operation {
        let id: UUID
        let load: @MainActor () async throws -> PaperDetail
        var cacheResult: Bool
        var task: Task<Void, Never>?
        var waiters: [UUID: Waiter]
        var foreground: Bool { waiters.values.contains { $0.foreground } }
    }
    private var operations: [Key: Operation] = [:]
    private var queued: [Key] = []
    private var active: Set<UUID> = []
    private var previewActive: Set<UUID> = []
    private var cache: [Key: PaperDetail] = [:]
    private var cacheOrder: [Key] = []
    private var epochs: [Int: Int] = [:]
    private var epochSequence = 0

    func preview(id: Int, credentials: CommunityCredentials, load: @escaping @MainActor () async throws -> PaperDetail) async throws -> PaperPreviewMetadata {
        try Task.checkCancellation()
        let key = Key(id: id, credentials: credentials, epoch: epochs[id] ?? 0)
        if let detail = cache[key] { return detail.previewMetadata }
        let detail = try await response(key: key, cacheResult: true, foreground: false, load: load)
        try Task.checkCancellation()
        return detail.previewMetadata
    }

    func cachedDetail(id: Int, credentials: CommunityCredentials) -> PaperDetail? {
        let key = Key(id: id, credentials: credentials, epoch: epochs[id] ?? 0)
        cacheOrder.removeAll { $0 == key }
        let detail = cache.removeValue(forKey: key)
        discardUnusedEpochs()
        return detail
    }

    func detail(id: Int, credentials: CommunityCredentials, load: @escaping @MainActor () async throws -> PaperDetail) async throws -> PaperDetail {
        try Task.checkCancellation()
        let key = Key(id: id, credentials: credentials, epoch: epochs[id] ?? 0)
        let detail = try await response(key: key, cacheResult: false, foreground: true, load: load)
        try Task.checkCancellation()
        cache[key] = nil
        cacheOrder.removeAll { $0 == key }
        discardUnusedEpochs()
        return detail
    }

    func invalidate(ids: Set<Int>? = nil) {
        let affected = ids ?? Set(cache.keys.map(\.id)).union(operations.keys.map(\.id))
        epochSequence &+= 1
        cache = cache.filter { !affected.contains($0.key.id) }
        cacheOrder.removeAll { affected.contains($0.id) }
        for id in affected where operations.keys.contains(where: { $0.id == id }) { epochs[id] = epochSequence }
        discardUnusedEpochs()
    }

    private func discardUnusedEpochs() {
        let retained = Set(cache.keys.map(\.id)).union(operations.keys.map(\.id))
        epochs = epochs.filter { retained.contains($0.key) }
    }

    private func response(key: Key, cacheResult: Bool, foreground: Bool, load: @escaping @MainActor () async throws -> PaperDetail) async throws -> PaperDetail {
        try Task.checkCancellation()
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var operation = operations[key] {
                    operation.cacheResult = operation.cacheResult || cacheResult
                    operation.waiters[waiter] = Waiter(foreground: foreground, continuation: continuation)
                    operations[key] = operation
                } else {
                    operations[key] = Operation(id: UUID(), load: load,
                        cacheResult: cacheResult, waiters: [waiter: Waiter(foreground: foreground, continuation: continuation)])
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
            let foreground = queued.firstIndex { operations[$0]?.foreground == true }
            guard foreground != nil || previewActive.count < Self.maximumConcurrentRequests - 1 else { return }
            let next = foreground ?? queued.startIndex
            let key = queued.remove(at: next)
            guard var operation = operations[key] else { continue }
            let id = operation.id
            active.insert(id)
            if !operation.foreground { previewActive.insert(id) }
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
        previewActive.remove(id)
        defer { startQueued() }
        guard operations[key]?.id == id, let operation = operations.removeValue(forKey: key) else { return }
        if operation.cacheResult, key.epoch == (epochs[key.id] ?? 0), case let .success(detail) = result,
           detail.isViewerAuthenticated == key.authenticated,
           PaperContentResourceLimits.acceptsPreviewCache(detail) {
            cache[key] = detail
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            while cacheOrder.count > Self.maximumConcurrentRequests { cache[cacheOrder.removeFirst()] = nil }
        }
        for waiter in operation.waiters.values { waiter.continuation.resume(with: result) }
        discardUnusedEpochs()
    }

    private func cancel(waiter: UUID, key: Key) {
        guard var operation = operations[key], let removed = operation.waiters.removeValue(forKey: waiter) else { return }
        if operation.waiters.isEmpty {
            operations[key] = nil
            queued.removeAll { $0 == key }
            operation.task?.cancel()
        } else {
            if !operation.foreground, active.contains(operation.id) {
                previewActive.insert(operation.id)
                if previewActive.count > Self.maximumConcurrentRequests - 1 {
                    operation.task?.cancel()
                    operation = Operation(id: UUID(), load: operation.load, cacheResult: operation.cacheResult,
                        waiters: operation.waiters)
                    queued.append(key)
                }
            }
            operations[key] = operation
        }
        discardUnusedEpochs()
        removed.continuation.resume(throwing: CancellationError())
        startQueued()
    }
}
