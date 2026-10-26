#if os(iOS)
import StorageCore
import TransportCore
import CryptoKit
import Foundation
import os
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// 话廊图片缓存容量偏好。
///
/// 单位为 MB；`0` 表示不主动限制。缓存本身仍位于系统 Caches 目录，iOS 在设备
/// 空间紧张时仍可以回收。
struct GalleryImageCachePreferences {
    let defaults: UserDefaults
    nonisolated static let limitMBKey = "gallery.image-cache.limit-mb"
    nonisolated static let defaultLimitMB = 500
    nonisolated static let maximumLimitMB = Int(Int64.max / 1_048_576)

    nonisolated static func normalizedLimitMB(_ value: Int) -> Int {
        min(max(value, 0), maximumLimitMB)
    }

    var limitMB: Int {
        get {
            guard defaults.object(forKey: Self.limitMBKey) != nil else {
                return Self.defaultLimitMB
            }
            return Self.normalizedLimitMB(defaults.integer(forKey: Self.limitMBKey))
        }
        nonmutating set {
            defaults.set(Self.normalizedLimitMB(newValue), forKey: Self.limitMBKey)
        }
    }
}

nonisolated enum ImageCacheDirectories {
    static func gallery(using files: any AppFileService) -> URL {
        files.directoryURL(.cachesDirectory)?.appending(path: "BIT101GalleryImages", directoryHint: .isDirectory)
            ?? files.temporaryDirectoryURL.appending(path: "BIT101GalleryImages", directoryHint: .isDirectory)
    }

    static func avatars(using files: any AppFileService) -> URL {
        files.directoryURL(.cachesDirectory)?.appending(path: "BIT101ImageCache", directoryHint: .isDirectory)
            ?? files.temporaryDirectoryURL.appending(path: "BIT101ImageCache", directoryHint: .isDirectory)
    }

    static func previews(using files: any AppFileService) -> URL {
        files.temporaryDirectoryURL.appending(path: "BIT101Previews", directoryHint: .isDirectory)
    }
}

/// Synchronizes active image-file registration with disk eviction.
nonisolated final class PreviewFileOwnership: Sendable {
    private struct State {
        var sessions: [UUID: Set<String>] = [:]
        var deferredRemoval: [String: (URL, any AppFileService)] = [:]
        var paths: Set<String> { sessions.values.reduce(into: []) { $0.formUnion($1) } }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let fileOperations = OSAllocatedUnfairLock()
    func begin(_ owner: UUID) { state.withLock { $0.sessions[owner] = [] } }
    @discardableResult
    func end(_ owner: UUID) -> Task<Void, Never> {
        state.withLock { $0.sessions[owner] = nil }
        return Task.detached {
            self.fileOperations.withLock { self.removeReleasedFiles() }
        }
    }
    private func removeReleasedFiles() {
        let released = state.withLock { state in
            let paths = state.paths
            return state.deferredRemoval.filter { !paths.contains($0.key) }
        }
        for (path, (file, files)) in released {
            do {
                try files.removeItemIfPresent(at: file)
                state.withLock { $0.deferredRemoval[path] = nil }
            }
            catch { continue }
        }
    }
    func contains(_ owner: UUID) -> Bool { state.withLock { $0.sessions[owner] != nil } }
    func pin(_ file: URL, using files: any AppFileService, owner: UUID) -> Bool {
        fileOperations.withLock {
            guard files.fileExists(at: file) else { return false }
            let path = files.canonicalFileURL(file).path
            return state.withLock { state in
                guard state.sessions[owner] != nil else { return false }
                state.sessions[owner]?.insert(path)
                return true
            }
        }
    }
    func materializeAndPin(_ file: URL, using files: any AppFileService, owner: UUID, create: @Sendable () throws -> Void) throws {
        try fileOperations.withLock {
            guard contains(owner) else { throw CancellationError() }
            try create()
            let path = files.canonicalFileURL(file).path
            let registered = state.withLock { state in
                guard state.sessions[owner] != nil else {
                    state.deferredRemoval[path] = (file, files)
                    return false
                }
                state.sessions[owner]?.insert(path)
                return true
            }
            guard registered else { removeReleasedFiles(); throw CancellationError() }
        }
    }
    func withPaths<T: Sendable>(_ operation: @Sendable (Set<String>) -> T) -> T {
        fileOperations.withLock { operation(state.withLock { $0.paths }) }
    }
    func clearDirectory(_ directory: URL, using files: any AppFileService) -> Bool {
        fileOperations.withLock {
            guard files.fileExists(at: directory) else { return true }
            guard let children = try? files.contentsOfDirectory(at: directory, options: []) else { return false }
            let paths = state.withLock { $0.paths }
            var succeeded = true
            for file in children {
                let path = files.canonicalFileURL(file).path
                if paths.contains(path) { state.withLock { $0.deferredRemoval[path] = (file, files) } }
                else {
                    do { try files.removeItem(at: file); state.withLock { $0.deferredRemoval[path] = nil } }
                    catch { succeeded = false }
                }
            }
            removeReleasedFiles()
            return succeeded
        }
    }
}

/// Enforces the image-cache setting across gallery media and avatar files as one LRU pool.
actor ImageCacheDiskQuota {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let files: any AppFileService
    private let configuredDirectories: [URL]?
    private let cacheLimitMB: @MainActor @Sendable () async -> Int
    private let previewOwnership: PreviewFileOwnership
    private let pruneInterval: TimeInterval
    private var lastPruneDate = Date.distantPast
    private var inventory: [URL: AppRegularFileMetadata] = [:]
    private var inventoryBytes: Int64 = 0

    init(
        files: any AppFileService,
        directories: [URL]? = nil,
        cacheLimitMB: @escaping @MainActor @Sendable () async -> Int,
        previewOwnership: PreviewFileOwnership = PreviewFileOwnership(),
        pruneInterval: TimeInterval = 60
    ) {
        self.files = files
        configuredDirectories = directories
        self.cacheLimitMB = cacheLimitMB
        self.previewOwnership = previewOwnership
        self.pruneInterval = pruneInterval
    }

    func usedBytes() -> Int64 {
        directories.reduce(Int64(0)) { total, directory in
            guard let children = try? files.contentsOfDirectory(at: directory, options: [.skipsHiddenFiles]) else {
                return total
            }
            return total + children.reduce(Int64(0)) { subtotal, url in
                subtotal + Int64(files.regularFileSize(at: url) ?? 0)
            }
        }
    }

    func clearDirectory(_ directory: URL) -> Bool {
        let cleared = previewOwnership.clearDirectory(directory, using: files)
        lastPruneDate = .distantPast
        inventory = [:]
        inventoryBytes = 0
        return cleared
    }

    nonisolated func beginFileUse(_ file: URL, owner: UUID, prepare: @Sendable () throws -> Void) throws {
        previewOwnership.begin(owner)
        do { try previewOwnership.materializeAndPin(file, using: files, owner: owner, create: prepare) }
        catch { previewOwnership.end(owner); throw error }
    }

    nonisolated func endFileUse(_ owner: UUID) { previewOwnership.end(owner) }

    func enforce(force: Bool = false, protecting protectedURLs: Set<URL> = []) async {
        let now = Date()
        for url in protectedURLs {
            let key = files.canonicalFileURL(url)
            if let metadata = inventory[key] {
                inventory[key] = .init(url: key, size: metadata.size, modificationDate: now)
            }
        }
        guard force || now.timeIntervalSince(lastPruneDate) >= pruneInterval else { return }
        lastPruneDate = now
        inventory = [:]
        inventoryBytes = 0
        let limitMB = await cacheLimitMB()
        guard limitMB > 0 else { return }
        for directory in directories {
            guard let entries = try? files.regularFileMetadata(in: directory) else { continue }
            for entry in entries where entry.url.lastPathComponent != "preview-placeholder.png" { inventory[entry.url] = entry }
        }
        inventoryBytes = inventory.values.reduce(Int64(0)) { $0 + Int64($1.size) }
        prune(limitMB: limitMB, protecting: protectedURLs)
    }

    func didReleaseFiles(_ urls: Set<URL>) async {
        for url in urls {
            let key = files.canonicalFileURL(url)
            if !files.fileExists(at: key) { inventoryBytes -= Int64(inventory.removeValue(forKey: key)?.size ?? 0) }
        }
        if Date().timeIntervalSince(lastPruneDate) >= pruneInterval { await enforce(); return }
        let limitMB = await cacheLimitMB()
        guard limitMB > 0 else { return }
        prune(limitMB: limitMB, protecting: [])
    }

    /// 写入时更新所属条目；全目录扫描沿现有周期及显式清理执行。
    func didWrite(_ url: URL) async {
        let limitMB = await cacheLimitMB()
        guard limitMB > 0 else { return }
        let key = files.canonicalFileURL(url)
        guard Date().timeIntervalSince(lastPruneDate) < pruneInterval else {
            await enforce(force: true, protecting: [key])
            return
        }
        inventoryBytes -= Int64(inventory.removeValue(forKey: key)?.size ?? 0)
        if let size = files.regularFileSize(at: key) {
            inventory[key] = .init(url: key, size: size, modificationDate: files.modificationDate(at: key) ?? Date())
            inventoryBytes += Int64(size)
        }
        prune(limitMB: limitMB, protecting: [key])
    }

    private func prune(limitMB: Int, protecting protectedURLs: Set<URL>) {
        let limit = Int64(limitMB) * 1_024 * 1_024
        let protectedPaths = Set(protectedURLs.map { files.canonicalFileURL($0).path })
            .union(previewOwnership.withPaths { $0 })
        var total = inventoryBytes + protectedPaths.reduce(Int64(0)) { total, path in
            let url = URL(fileURLWithPath: path)
            return total + (inventory[url] == nil ? Int64(files.regularFileSize(at: url) ?? 0) : 0)
        }
        guard total > limit else { return }

        let target = Int64(Double(limit) * 0.85)
        for entry in inventory.values.sorted(by: { $0.modificationDate < $1.modificationDate }) where total > target {
            let url = entry.url
            guard !protectedPaths.contains(url.path) else { continue }
            let removed = previewOwnership.withPaths { currentPaths in
                guard !currentPaths.contains(url.path) else { return false }
                do { try files.removeItem(at: url); return true }
                catch { return false }
            }
            if removed {
                total -= Int64(entry.size)
                inventoryBytes -= Int64(entry.size)
                inventory[url] = nil
            }
        }
    }

    private var directories: [URL] {
        configuredDirectories ?? [
            ImageCacheDirectories.gallery(using: files),
            ImageCacheDirectories.avatars(using: files),
            ImageCacheDirectories.previews(using: files),
        ]
    }

}

nonisolated enum RemoteImageSource: Sendable {
    case file(URL)
    case memory(Data, identity: UUID)
}

private nonisolated final class MemoryImageEntry: NSObject {
    let data: Data
    let target: URL
    let identity = UUID()
    init(data: Data, target: URL) { self.data = data; self.target = target }
}

private nonisolated final class RemoteImageLease: Sendable {
    let url: URL
    let source: RemoteImageSource
    let owner = UUID()
    private let quota: ImageCacheDiskQuota?
    init(url: URL, files: any AppFileService, quota: ImageCacheDiskQuota) throws {
        self.url = url
        source = .file(url)
        self.quota = quota
        try quota.beginFileUse(url, owner: owner) {
            guard files.fileExists(at: url) else { throw CocoaError(.fileReadNoSuchFile) }
        }
    }
    init(memory: MemoryImageEntry) {
        url = memory.target
        source = .memory(memory.data, identity: memory.identity)
        quota = nil
    }
    deinit { quota?.endFileUse(owner) }
}

/// 低清图、高清图和 GIF 共用的持久磁盘缓存。
///
/// 读取时更新文件修改时间，将其作为轻量 LRU 的“最近使用时间”；写入后若超过用户
/// 设置的上限，会从最久未使用的文件开始清理到上限的 85%，避免反复触发清理。
actor RemoteImageCache {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let transientImages: NSCache<NSURL, MemoryImageEntry> = {
        let cache = NSCache<NSURL, MemoryImageEntry>()
        cache.totalCostLimit = RemoteImageResourceLimits.maximumEncodedBytes
        return cache
    }()

    private struct DownloadResult: Sendable {
        let data: Data
        let mimeType: String?
    }

    private struct DownloadOperation {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<RemoteImageLease, any Error>]
    }

    private let files: any AppFileService
    private let quota: ImageCacheDiskQuota
    private let download: @Sendable (URL) async throws -> HTTPResponse
    private let directory: URL
    private var downloads: [String: DownloadOperation] = [:]
    private var activeFileUses: Set<UUID> = []
    private var generation: UInt64 = 0
    var cacheGeneration: UInt64 { generation }
    private let validatedFiles: NSCache<NSURL, NSString> = {
        let cache = NSCache<NSURL, NSString>()
        cache.countLimit = 80
        return cache
    }()
    var waitingConsumerCount: Int { downloads.values.reduce(0) { $0 + $1.waiters.count } }
    private let supportedExtensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bin"]
    init(files: any AppFileService, quota: ImageCacheDiskQuota, httpClient: HTTPClient,
         download: (@Sendable (URL) async throws -> HTTPResponse)? = nil) {
        self.files = files
        self.quota = quota
        self.download = download ?? { try await httpClient.send(URLRequest(url: HTTPSURLUpgrade.upgradedURL(from: $0)), maximumBytes: RemoteImageResourceLimits.maximumEncodedBytes) }
        directory = ImageCacheDirectories.gallery(using: files)
        Task { await self.removeLegacyFiles() }
    }

    private func removeLegacyFiles() async {
        for file in (try? files.contentsOfDirectory(at: directory, options: [])) ?? []
            where file.lastPathComponent.hasPrefix("low-") || file.lastPathComponent.hasPrefix("high-") {
            try? files.removeItem(at: file)
        }
        let avatars = ImageCacheDirectories.avatars(using: files)
        if files.fileExists(at: avatars) { _ = await quota.clearDirectory(avatars) }
    }

    func clearMemory() { transientImages.removeAllObjects() }

    private func acquireCachedFile(for requestURL: URL) async -> RemoteImageLease? {
        let remoteURL = HTTPSURLUpgrade.upgradedURL(from: requestURL)
        let owner = generation
        let prefix = filePrefix(for: remoteURL)
        for extensionName in supportedExtensions {
            let file = directory.appendingPathComponent("\(prefix).\(extensionName)")
            guard files.fileExists(at: file) else { continue }
            guard let identity = files.atomicFileIdentity(at: file), hasData(at: file) else {
                validatedFiles.removeObject(forKey: file as NSURL)
                try? files.removeItem(at: file)
                continue
            }
            guard validatedFiles.object(forKey: file as NSURL) as String? == identity || isDecodableImage(at: file) else {
                try? files.removeItem(at: file)
                continue
            }
            validatedFiles.setObject(identity as NSString, forKey: file as NSURL)
            touch(file)
            guard let lease = try? RemoteImageLease(url: file, files: files, quota: quota) else { continue }
            activeFileUses.insert(lease.owner)
            defer { activeFileUses.remove(lease.owner) }
            await quota.enforce(protecting: Set([file]))
            guard owner == generation, !Task.isCancelled else { return nil }
            return lease
        }
        return nil
    }

    func withFile<Value: Sendable>(for remoteURL: URL, operation: @Sendable (URL) async throws -> Value) async throws -> Value {
        let lease = try await acquireFile(for: remoteURL)
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        return try await operation(lease.url)
    }

    func withCachedFile<Value: Sendable>(for remoteURL: URL, operation: @Sendable (URL) async throws -> Value) async throws -> Value? {
        guard let lease = await acquireCachedFile(for: remoteURL) else { return nil }
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        return try await operation(lease.url)
    }

    func withSource<Value: Sendable>(for remoteURL: URL, download: (@Sendable (URL) async throws -> HTTPResponse)? = nil,
        operation: @Sendable (RemoteImageSource) async throws -> Value) async throws -> Value {
        let lease = try await acquireResource(for: remoteURL, downloader: download)
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        return try await operation(lease.source)
    }

    func withCachedSource<Value: Sendable>(for remoteURL: URL, operation: @Sendable (RemoteImageSource) async throws -> Value) async throws -> Value? {
        guard let lease = await acquireCachedResource(for: remoteURL) else { return nil }
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        return try await operation(lease.source)
    }

    private func acquireCachedResource(for remoteURL: URL) async -> RemoteImageLease? {
        let owner = generation
        if let cached = await acquireCachedFile(for: remoteURL) { return cached }
        guard owner == generation, !Task.isCancelled else { return nil }
        let key = HTTPSURLUpgrade.upgradedURL(from: remoteURL) as NSURL
        return transientImages.object(forKey: key).map { RemoteImageLease(memory: $0) }
    }

    private func write(_ data: Data, to target: URL, owner: UUID) async throws {
        try quota.beginFileUse(target, owner: owner) { [files, directory] in
            try files.createDirectory(at: directory)
            try files.writeData(data, to: target, options: [.atomic])
            try? files.setModificationDate(Date(), at: target)
        }
        activeFileUses.insert(owner)
        await quota.didWrite(target)
    }

    private func acquireFile(for remoteURL: URL) async throws -> RemoteImageLease {
        let generation = self.generation
        let lease = try await acquireResource(for: remoteURL)
        if case .file = lease.source { return lease }
        guard case let .memory(data, _) = lease.source else { throw CocoaError(.fileReadUnknown) }
        let owner = UUID()
        defer { activeFileUses.remove(owner); quota.endFileUse(owner) }
        try await write(data, to: lease.url, owner: owner)
        guard generation == self.generation, !Task.isCancelled else { throw CancellationError() }
        transientImages.removeObject(forKey: remoteURL as NSURL)
        return try RemoteImageLease(url: lease.url, files: files, quota: quota)
    }

    private func acquireResource(for requestURL: URL, downloader: (@Sendable (URL) async throws -> HTTPResponse)? = nil) async throws -> RemoteImageLease {
        let remoteURL = HTTPSURLUpgrade.upgradedURL(from: requestURL)
        try Task.checkCancellation()
        let owner = generation
        if let cached = await acquireCachedResource(for: remoteURL) {
            return cached
        }
        try Task.checkCancellation()
        guard owner == generation else { throw CancellationError() }

        let requestKey = remoteURL.absoluteString
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var running = downloads[requestKey] {
                    running.waiters[waiter] = continuation
                    downloads[requestKey] = running
                    return
                }
                let id = UUID()
                let selectedDownload = downloader ?? download
                let task = Task { [selectedDownload] in
                    let result: Result<DownloadResult, any Error>
                    do {
                        let response = try await selectedDownload(remoteURL)
                        result = .success(DownloadResult(data: response.data, mimeType: response.response.mimeType))
                    } catch { result = .failure(error) }
                    await finishDownload(result, key: requestKey, id: id, remoteURL: remoteURL)
                }
                downloads[requestKey] = DownloadOperation(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter, key: requestKey) }
        }
    }

    private func finishDownload(_ result: Result<DownloadResult, any Error>, key: String, id: UUID,
                                remoteURL: URL) async {
        guard downloads[key]?.id == id else { return }
        defer { activeFileUses.remove(id); quota.endFileUse(id) }
        let completed: Result<RemoteImageLease, any Error>
        do {
            let result = try result.get()
            completed = .success(try await persist(result, for: remoteURL, owner: id,
                isCurrent: { self.downloads[key]?.id == id }))
        } catch { completed = .failure(error) }
        guard downloads[key]?.id == id, let operation = downloads.removeValue(forKey: key) else { return }
        for continuation in operation.waiters.values { continuation.resume(with: completed) }
    }

    func store(_ data: Data, for requestURL: URL) async {
        let remoteURL = HTTPSURLUpgrade.upgradedURL(from: requestURL)
        let version = generation, owner = UUID()
        defer { activeFileUses.remove(owner); quota.endFileUse(owner) }
        _ = try? await persist(.init(data: data, mimeType: nil), for: remoteURL, owner: owner,
            isCurrent: { self.generation == version && !Task.isCancelled })
    }

    private func persist(_ result: DownloadResult, for remoteURL: URL, owner: UUID,
        isCurrent: () -> Bool) async throws -> RemoteImageLease {
        guard isCurrent() else { throw CancellationError() }
        guard result.data.count <= RemoteImageResourceLimits.maximumEncodedBytes,
              isDecodableImage(data: result.data) else { throw CocoaError(.fileReadCorruptFile) }
        let ext = preferredExtension(for: remoteURL, mimeType: result.mimeType)
        let target = directory.appendingPathComponent("\(filePrefix(for: remoteURL)).\(ext)")
        do {
            try await write(result.data, to: target, owner: owner)
            guard isCurrent() else { throw CancellationError() }
            return try RemoteImageLease(url: target, files: files, quota: quota)
        } catch {
            guard isCurrent(), !TaskCancellation.matches(error) else { throw CancellationError() }
            let memory = MemoryImageEntry(data: result.data, target: target)
            transientImages.setObject(memory, forKey: remoteURL as NSURL, cost: result.data.count)
            return RemoteImageLease(memory: memory)
        }
    }

    private func cancelWaiter(_ waiter: UUID, key: String) {
        guard var operation = downloads[key], let continuation = operation.waiters.removeValue(forKey: waiter) else { return }
        if operation.waiters.isEmpty {
            downloads[key] = nil
            operation.task.cancel()
            activeFileUses.remove(operation.id)
            quota.endFileUse(operation.id)
        } else { downloads[key] = operation }
        continuation.resume(throwing: CancellationError())
    }

    @discardableResult func clearAll() async -> Bool {
        generation &+= 1
        transientImages.removeAllObjects()
        validatedFiles.removeAllObjects()
        for use in activeFileUses { quota.endFileUse(use) }
        activeFileUses.removeAll()
        let pending = downloads.values
        downloads.removeAll()
        for operation in pending {
            operation.task.cancel()
            for continuation in operation.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
        return await quota.clearDirectory(directory)
    }

    func previewFile(at cachedURL: URL, using previewFiles: any AppFileService, sharesStorage: Bool,
        ownership: PreviewFileOwnership, owner: UUID?) throws -> URL {
        if sharesStorage {
            guard files.isRegularFile(at: cachedURL) else { throw CocoaError(.fileReadNoSuchFile) }
            if let owner, !ownership.pin(cachedURL, using: previewFiles, owner: owner) { throw CancellationError() }
            return cachedURL
        }
        let data = try files.readData(at: cachedURL)
        let directory = ImageCacheDirectories.previews(using: previewFiles)
        let name = "local-\(SHA256.hash(data: data).hexString).\(cachedURL.pathExtension)"
        let target = directory.appendingPathComponent(name)
        let materialize: @Sendable () throws -> Void = {
            try previewFiles.createDirectory(at: target.deletingLastPathComponent())
            if (try? previewFiles.readData(at: target)) != data {
                try previewFiles.writeData(data, to: target, options: [.atomic, .completeFileProtection])
            }
            if target != cachedURL { try previewFiles.setModificationDate(Date(), at: target) }
        }
        if let owner { try ownership.materializeAndPin(target, using: previewFiles, owner: owner, create: materialize) }
        else { try materialize() }
        return target
    }

    /// Quick Look 数据源暂时缺图时使用的透明占位文件。
    func placeholderFile() throws -> URL {
        let target = directory.appendingPathComponent("preview-placeholder.png")
        // 1 × 1 透明 PNG；固定字节同时修复已缓存的损坏占位文件。
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileWriteUnknown) }
        if (try? files.readData(at: target)) != data {
            try files.createDirectory(at: directory)
            try files.writeData(data, to: target, options: [.atomic])
        }
        return target
    }

    /// 设置改变后立即按新上限执行一次清理。
    func enforceCurrentLimit() async {
        await pruneIfNeeded(protecting: [], force: true)
    }

    /// 当前本地图片缓存实际占用的磁盘空间。
    ///
    /// 统计话廊图片、头像与预览目录；URLCache 维持独立。
    func usedBytes() async -> Int64 {
        await quota.usedBytes()
    }

    private func filePrefix(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).hexString
        return digest
    }

    private func preferredExtension(for url: URL, mimeType: String?) -> String {
        let existing = url.pathExtension.lowercased()
        if supportedExtensions.dropLast().contains(existing) { return existing }
        if let mimeType,
           let type = UTType(mimeType: mimeType.lowercased()),
           let preferred = type.preferredFilenameExtension,
           supportedExtensions.contains(preferred.lowercased()) {
            return preferred.lowercased()
        }
        return "jpg"
    }

    private func touch(_ url: URL) {
        try? files.setModificationDate(Date(), at: url)
    }

    private func hasData(at url: URL) -> Bool {
        guard let fileSize = files.regularFileSize(at: url) else { return false }
        return fileSize > 0 && fileSize <= RemoteImageResourceLimits.maximumEncodedBytes
    }

    private func isDecodableImage(at url: URL) -> Bool {
        guard let data = RemoteImageResourceLimits.cachedData(at: url, using: files) else { return false }
        return isDecodableImage(data: data)
    }

    private func isDecodableImage(data: Data) -> Bool {
        guard let source = RemoteImageResourceLimits.completeImageSource(from: data) else { return false }
        return containsDecodableImage(source)
    }

    private func containsDecodableImage(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 0 else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    private func pruneIfNeeded(protecting protectedURLs: Set<URL>, force: Bool = false) async {
        await quota.enforce(force: force, protecting: protectedURLs)
    }
}

public nonisolated enum BoundedStillImageDecoder {
    public static func hasCompleteImage(in data: Data) -> Bool {
        RemoteImageResourceLimits.completeImageSource(from: data) != nil
    }

    public static func decodedBytes(in images: [UIImage]) -> Int {
        var seen = Set<ObjectIdentifier>()
        return images.reduce(0) { bytes, image in
            (image.images ?? [image]).reduce(bytes) { total, frame in
                guard let pixels = frame.cgImage, seen.insert(ObjectIdentifier(pixels)).inserted else { return total }
                return total + pixels.bytesPerRow * pixels.height
            }
        }
    }

    public static func image(from data: Data, pointSize: CGFloat, displayScale: CGFloat) -> UIImage? {
        let pixels = pointSize * displayScale
        guard pointSize > 0, displayScale > 0, pixels >= 1, pixels < CGFloat(Int.max) else { return nil }
        return image(from: data, maximumPixelSize: Int(pixels))
    }

    public static func image(from data: Data, maximumDecodedBytes: Int = RemoteImageResourceLimits.maximumDecodedBytes,
                             maximumPixelSize: Int? = nil) -> UIImage? {
        guard maximumDecodedBytes >= 4, !Task.isCancelled,
              let source = RemoteImageResourceLimits.completeImageSource(from: data)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let depth = (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        guard (1...32).contains(depth) else { return nil }
        let bytesPerPixel = max(4, ((depth + 7) / 8) * 4)
        let budgetSide = Int(Double(maximumDecodedBytes / bytesPerPixel).squareRoot())
        let side = min(budgetSide, maximumPixelSize ?? budgetSide)
        guard side > 0 else { return nil }
        guard let image = thumbnail(from: source, at: 0, maximumPixelSize: side,
                                    maximumDecodedBytes: maximumDecodedBytes) else { return nil }
        return UIImage(cgImage: image)
    }

    /// 按实际行跨度收敛缩略图尺寸，将 ImageIO 的行对齐开销计入解码预算。
    static func thumbnail(from source: CGImageSource, at index: Int, maximumPixelSize: Int,
                          maximumDecodedBytes: Int) -> CGImage? {
        var side = maximumPixelSize
        while side > 0, !Task.isCancelled {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: false]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            let cost = image.bytesPerRow * image.height
            if cost <= maximumDecodedBytes { return Task.isCancelled ? nil : image }
            let scale = (Double(maximumDecodedBytes) / Double(cost)).squareRoot()
            side = min(side - 1, Int((Double(side) * scale).rounded(.down)))
        }
        return nil
    }
}

/// 串行后台解码话廊缩略图，避免多张图片同时进入屏幕时抢占主线程。
///
/// ImageIO 在像素预算内生成显示位图，后台解码和内存缓存沿用同一预算。
actor GalleryThumbnailDecoder {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let files: any AppFileService
    func clear() { images.removeAllObjects() }

    init(files: any AppFileService, maximumDecodedBytes: Int = RemoteImageResourceLimits.maximumDecodedBytes) {
        self.files = files
        images.totalCostLimit = maximumDecodedBytes
    }

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = RemoteImageResourceLimits.maximumDecodedBytes
        return cache
    }()

    func image(at file: URL, maximumPixelSize: Int? = nil) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard let identity = files.atomicFileIdentity(at: file) else { return nil }
        let key = "\(files.canonicalFileURL(file).path)|\(identity)|pixels:\(maximumPixelSize ?? 0)" as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }
        guard let data = RemoteImageResourceLimits.cachedData(at: file, using: files) else { return nil }
        return decode(data, key: key, maximumPixelSize: maximumPixelSize)
    }

    func image(from source: RemoteImageSource, maximumPixelSize: Int? = nil) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        switch source {
        case .file(let file): return image(at: file, maximumPixelSize: maximumPixelSize)
        case .memory(let data, let identity):
            let key = "memory:\(identity)|pixels:\(maximumPixelSize ?? 0)" as NSString
            if let cached = images.object(forKey: key) { return cached }
            return decode(data, key: key, maximumPixelSize: maximumPixelSize)
        }
    }

    private func decode(_ data: Data, key: NSString, maximumPixelSize: Int?) -> UIImage? {
        guard let decoded = BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: images.totalCostLimit,
                                                          maximumPixelSize: maximumPixelSize),
              let pixels = decoded.cgImage else { return nil }
        images.setObject(decoded, forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return decoded
    }
}

extension SHA256.Digest {
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

#endif
