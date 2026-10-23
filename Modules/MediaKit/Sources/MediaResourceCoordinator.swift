#if os(iOS)
import Foundation
import Observation
import TransportCore
import UIKit

nonisolated func mediaImageURLs(_ values: [URL?]) -> [URL] {
    var result: [URL] = []
    for value in values.compactMap({ $0 }) {
        let url = HTTPSURLUpgrade.upgradedURL(from: value)
        if !result.contains(url) { result.append(url) }
    }
    return result
}

/// 头像和话廊共享传输名额；同一来源和 URL 的消费者共用在途响应。
@MainActor
final class MediaDownloadCoordinator {
    enum Source: Hashable, Sendable { case avatar, gallery }
    private struct Key: Hashable { let url: URL; let source: Source }
    private struct Operation {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<HTTPResponse, any Error>]
    }
    static let maximumConcurrentDownloads = 4
    private let avatarClient: HTTPClient
    private let galleryClient: HTTPClient
    private var operations: [Key: Operation] = [:]
    private var queued: [Key] = []
    private var activeTasks = Set<UUID>()
    var waitingConsumerCount: Int { operations.values.reduce(0) { $0 + $1.waiters.count } }

    init(avatarClient: HTTPClient, galleryClient: HTTPClient) {
        self.avatarClient = avatarClient
        self.galleryClient = galleryClient
    }

    func response(for url: URL, source: Source) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let key = Key(url: HTTPSURLUpgrade.upgradedURL(from: url), source: source)
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var operation = operations[key] {
                    operation.waiters[waiter] = continuation
                    operations[key] = operation
                } else {
                    operations[key] = Operation(id: UUID(), waiters: [waiter: continuation])
                    queued.append(key)
                }
                startQueuedDownloads()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(waiter: waiter, key: key) }
        }
    }

    private func startQueuedDownloads() {
        while activeTasks.count < Self.maximumConcurrentDownloads, !queued.isEmpty {
            let key = queued.removeFirst()
            guard var operation = operations[key] else { continue }
            let id = operation.id
            activeTasks.insert(id)
            let client = key.source == .avatar ? avatarClient : galleryClient
            operation.task = Task {
                let result: Result<HTTPResponse, any Error>
                do { result = .success(try await client.send(URLRequest(url: key.url), maximumBytes: RemoteImageResourceLimits.maximumEncodedBytes)) }
                catch { result = .failure(error) }
                self.finish(result, key: key, id: id)
            }
            operations[key] = operation
        }
    }

    private func finish(_ result: Result<HTTPResponse, any Error>, key: Key, id: UUID) {
        activeTasks.remove(id)
        defer { startQueuedDownloads() }
        guard operations[key]?.id == id, let operation = operations.removeValue(forKey: key) else { return }
        for waiter in operation.waiters.values { waiter.resume(with: result) }
    }

    private func cancel(waiter: UUID, key: Key) {
        guard var operation = operations[key], let continuation = operation.waiters.removeValue(forKey: waiter) else { return }
        if operation.waiters.isEmpty {
            operations[key] = nil
            queued.removeAll { $0 == key }
            operation.task?.cancel()
            startQueuedDownloads()
        } else { operations[key] = operation }
        continuation.resume(throwing: CancellationError())
    }

    func clear() {
        let pending = operations.values
        operations.removeAll()
        queued.removeAll()
        for operation in pending {
            operation.task?.cancel()
            for waiter in operation.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }
}

/// 活跃视图共享位图预算，同一 UIImage 的多个展示归属共用一次记账。
@Observable
@MainActor
final class MediaDisplayBudget {
    private struct Allocation { let bytes: Int; var owners: Int }
    private var images: [ObjectIdentifier: Allocation] = [:]
    private var owners: [UUID: ObjectIdentifier] = [:]
    let maximumBytes: Int
    private(set) var usedBytes = 0
    private(set) var releaseGeneration: UInt64 = 0

    init(maximumBytes: Int = RemoteImageResourceLimits.maximumDecodedBytes * 2) {
        self.maximumBytes = maximumBytes
    }

    func retain(_ image: UIImage, owner: UUID) -> Bool {
        let id = ObjectIdentifier(image)
        if owners[owner] == id { return true }
        let bytes = Self.decodedBytes(image)
        let old = owners[owner].flatMap { images[$0] }
        let freed = old?.owners == 1 ? old?.bytes ?? 0 : 0
        let added = images[id] == nil ? bytes : 0
        guard bytes > 0, added <= maximumBytes - (usedBytes - freed) else { return false }
        let previousBytes = usedBytes
        release(owner: owner, notify: false)
        var allocation = images[id] ?? Allocation(bytes: bytes, owners: 0)
        if allocation.owners == 0 { usedBytes += bytes }
        allocation.owners += 1
        images[id] = allocation
        owners[owner] = id
        if usedBytes < previousBytes { releaseGeneration &+= 1 }
        return true
    }

    func release(owner: UUID, notify: Bool = true) {
        guard let id = owners.removeValue(forKey: owner), var allocation = images[id] else { return }
        allocation.owners -= 1
        if allocation.owners == 0 {
            images[id] = nil
            usedBytes -= allocation.bytes
            if notify { releaseGeneration &+= 1 }
        } else { images[id] = allocation }
    }

    nonisolated static func decodedBytes(_ image: UIImage) -> Int {
        pixelBytes(image) + (image.images?.count ?? 0) * MemoryLayout<UIImage>.stride
    }

    nonisolated static func pixelBytes(_ image: UIImage) -> Int {
        BoundedStillImageDecoder.decodedBytes(in: [image])
    }
}

@Observable
@MainActor
final class MediaDisplayedImage {
    private(set) var image: UIImage?
    private(set) var waitingForBudget = false
    private let owner = UUID()
    @ObservationIgnored private var budget: MediaDisplayBudget?

    deinit {
        let selectedBudget = budget, selectedOwner = owner
        Task { @MainActor in selectedBudget?.release(owner: selectedOwner) }
    }

    @discardableResult
    func set(_ image: UIImage, budget: MediaDisplayBudget) -> Bool {
        guard budget.retain(image, owner: owner) else { waitingForBudget = true; return false }
        waitingForBudget = false
        if self.budget !== budget { self.budget?.release(owner: owner) }
        self.budget = budget
        self.image = image
        return true
    }

    func clear() {
        budget?.release(owner: owner)
        budget = nil
        image = nil
        waitingForBudget = false
    }
}
#endif
