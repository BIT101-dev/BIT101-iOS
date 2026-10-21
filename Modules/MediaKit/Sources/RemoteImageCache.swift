#if os(iOS)
import StorageCore
import TransportCore
import DesignSystemKit
import CryptoKit
import Foundation
import os
import ImageIO
import OSLog
import SwiftUI
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
        ]
    }

}

private nonisolated final class RemoteImageFileLease: Sendable {
    let url: URL
    let owner = UUID()
    private let quota: ImageCacheDiskQuota
    init(url: URL, files: any AppFileService, quota: ImageCacheDiskQuota) throws {
        self.url = url
        self.quota = quota
        try quota.beginFileUse(url, owner: owner) {
            guard files.fileExists(at: url) else { throw CocoaError(.fileReadNoSuchFile) }
        }
    }
    deinit { quota.endFileUse(owner) }
}

/// 低清图、高清图和 GIF 共用的持久磁盘缓存。
///
/// 读取时更新文件修改时间，将其作为轻量 LRU 的“最近使用时间”；写入后若超过用户
/// 设置的上限，会从最久未使用的文件开始清理到上限的 85%，避免反复触发清理。
actor RemoteImageCache {

    private struct DownloadResult: Sendable {
        let data: Data
        let mimeType: String?
    }

    private struct DownloadOperation {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<RemoteImageFileLease, any Error>]
    }

    private let files: any AppFileService
    private let quota: ImageCacheDiskQuota
    private let download: @Sendable (URL) async throws -> HTTPResponse
    private let directory: URL
    private var downloads: [String: DownloadOperation] = [:]
    private var activeFileUses: Set<UUID> = []
    private var generation: UInt64 = 0
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
        self.download = download ?? { try await httpClient.send(URLRequest(url: $0), maximumBytes: RemoteImageResourceLimits.maximumEncodedBytes) }
        directory = ImageCacheDirectories.gallery(using: files)
        for file in (try? files.contentsOfDirectory(at: directory, options: [])) ?? []
            where file.lastPathComponent.hasPrefix("low-") || file.lastPathComponent.hasPrefix("high-") {
            try? files.removeItem(at: file)
        }
    }

    /// 返回已有缓存并刷新其 LRU 时间，不发起网络请求。
    func cachedFile(for remoteURL: URL) async -> URL? {
        await acquireCachedFile(for: remoteURL)?.url
    }

    private func acquireCachedFile(for remoteURL: URL) async -> RemoteImageFileLease? {
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
            guard let lease = try? RemoteImageFileLease(url: file, files: files, quota: quota) else { continue }
            activeFileUses.insert(lease.owner)
            defer { activeFileUses.remove(lease.owner) }
            await quota.enforce(protecting: Set([file]))
            guard owner == generation, !Task.isCancelled else { return nil }
            return lease
        }
        return nil
    }

    /// 获取缓存文件；同一 URL 的并发请求会合并成一次下载。
    func file(for remoteURL: URL) async throws -> URL {
        try await acquireFile(for: remoteURL).url
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

    private func acquireFile(for remoteURL: URL) async throws -> RemoteImageFileLease {
        try Task.checkCancellation()
        let owner = generation
        if let cached = await acquireCachedFile(for: remoteURL) {
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
                let task = Task { [download] in
                    let result: Result<DownloadResult, any Error>
                    do {
                        let response = try await download(remoteURL)
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
        let completed: Result<URL, any Error>
        do {
            let result = try result.get()
            guard isDecodableImage(data: result.data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let ext = preferredExtension(for: remoteURL, mimeType: result.mimeType)
            let target = directory.appendingPathComponent("\(filePrefix(for: remoteURL)).\(ext)")
            try quota.beginFileUse(target, owner: id) { [files, directory] in
                try files.createDirectory(at: directory)
                try files.writeData(result.data, to: target, options: [.atomic])
                try? files.setModificationDate(Date(), at: target)
            }
            activeFileUses.insert(id)
            await quota.didWrite(target)
            completed = .success(target)
        } catch { completed = .failure(error) }
        guard downloads[key]?.id == id, let operation = downloads.removeValue(forKey: key) else { return }
        for continuation in operation.waiters.values {
            do {
                let file = try completed.get()
                continuation.resume(returning: try RemoteImageFileLease(url: file, files: files, quota: quota))
            } catch { continuation.resume(throwing: error) }
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

    func previewFile(at cachedURL: URL, using previewFiles: any AppFileService, ownership: PreviewFileOwnership, owner: UUID?) throws -> URL {
        let data = try files.readData(at: cachedURL)
        let directory = ImageCacheDirectories.gallery(using: previewFiles)
        let name = "local-\(SHA256.hash(data: data).hexString).\(cachedURL.pathExtension)"
        let target = (try? previewFiles.readData(at: cachedURL)) == data ? cachedURL : directory.appendingPathComponent(name)
        let materialize: @Sendable () throws -> Void = {
            try previewFiles.createDirectory(at: target.deletingLastPathComponent())
            if (try? previewFiles.readData(at: target)) != data {
                try previewFiles.writeData(data, to: target, options: [.atomic])
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
    /// 统计话廊图片与头像目录；URLCache 维持独立。
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
        guard let decoded = BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: images.totalCostLimit,
                                                          maximumPixelSize: maximumPixelSize),
              let pixels = decoded.cgImage else { return nil }
        images.setObject(decoded, forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return decoded
    }
}

/// 静态话廊缩略图视图，确保首页显示过的低清图进入统一持久缓存。
public struct RemoteCachedStillImage: View {
    @Environment(MediaEnvironment.self) private var media
    @Environment(\.displayScale) private var displayScale
    @State private var pixelSize = 0
    @State private var budgetRetryGeneration: UInt64 = 0
    let url: URL?
    var contentMode: ContentMode = .fit
    var onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    @State private var displayed = MediaDisplayedImage()
    private var image: UIImage? { displayed.image }
    @State private var currentResource: MediaImageLoadIdentity?

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card)
                    .fill(AppDesignSystem.Palette.Accent.surface)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(AppDesignSystem.Palette.Accent.primary)
                    }
            }
        }
        .onGeometryChange(for: Int.self) { [scale = displayScale] geometry in
            Int((max(geometry.size.width, geometry.size.height) * scale).rounded(.up))
        } action: { pixelSize = $0 }
        .task(id: MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(media), retryGeneration: media.imageRetryGeneration, budgetRetryGeneration: budgetRetryGeneration, pixelSize: pixelSize)) {
            let resource = MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(media), pixelSize: pixelSize)
            if currentResource != resource { displayed.clear(); currentResource = resource }
            guard pixelSize > 0 else { return }
            guard image == nil else { return }
            guard let url else { return }
            do {
                let decoded = try await media.images.withFile(for: url) { @MainActor [media, pixelSize] file in
                    await media.stillDecoder.image(at: file, maximumPixelSize: pixelSize)
                }
                guard !Task.isCancelled else { return }
                if let decoded { displayed.set(decoded, budget: media.displayBudget) }
                if let decoded, decoded.size.height > 0 {
                    onAspectRatioResolved?(decoded.size.width / decoded.size.height)
                }
            } catch {
                guard !Task.isCancelled else { return }
                // 缩略图失败时显示占位内容。
                displayed.clear()
            }
        }
        .onChange(of: media.displayBudget.releaseGeneration) { if displayed.waitingForBudget { budgetRetryGeneration &+= 1 } }
        .onDisappear { displayed.clear() }
    }
    public init(url: URL?, contentMode: ContentMode = .fit, onAspectRatioResolved: ((CGFloat) -> Void)? = nil) {
        self.url = url
        self.contentMode = contentMode
        self.onAspectRatioResolved = onAspectRatioResolved
    }
}

/// 详情页图片先显示低清缓存，再在同一视图中替换为原图。
public struct RemoteProgressiveStillImage: View {
    @Environment(MediaEnvironment.self) private var media
    @Environment(\.displayScale) private var displayScale
    @State private var pixelSize = 0
    @State private var budgetRetryGeneration: UInt64 = 0
    @State private var hasOriginalImage = false
    private static let logger = Logger(subsystem: "BIT101", category: "CommunityImage")
    let thumbnailURL: URL?
    let originalURL: URL?
    var contentMode: ContentMode = .fit
    var onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    @State private var displayed = MediaDisplayedImage()
    private var image: UIImage? { displayed.image }
    @State private var currentResource: MediaImageLoadIdentity?

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card)
                    .fill(AppDesignSystem.Palette.Accent.surface)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(AppDesignSystem.Palette.Accent.primary)
                    }
            }
        }
        .onGeometryChange(for: Int.self) { [scale = displayScale] geometry in
            Int((max(geometry.size.width, geometry.size.height) * scale).rounded(.up))
        } action: { pixelSize = $0 }
        .task(id: MediaImageLoadIdentity(urls: [thumbnailURL, originalURL], environment: ObjectIdentifier(media), retryGeneration: media.imageRetryGeneration, budgetRetryGeneration: budgetRetryGeneration, pixelSize: pixelSize)) {
            let resource = MediaImageLoadIdentity(urls: [thumbnailURL, originalURL], environment: ObjectIdentifier(media), pixelSize: pixelSize)
            if currentResource != resource { displayed.clear(); hasOriginalImage = false; currentResource = resource }
            guard pixelSize > 0 else { return }
            if image == nil { await loadThumbnail() }
            guard !Task.isCancelled else { return }
            if !hasOriginalImage { await loadOriginal() }
        }
        .onChange(of: media.displayBudget.releaseGeneration) { if displayed.waitingForBudget { budgetRetryGeneration &+= 1 } }
        .onDisappear { displayed.clear(); hasOriginalImage = false }
    }

    private func loadThumbnail() async {
        guard let thumbnailURL else { return }
        do {
            let decoded = try await media.images.withFile(for: thumbnailURL) { @MainActor [media, pixelSize] file in
                await media.stillDecoder.image(at: file, maximumPixelSize: pixelSize)
            }
            guard !Task.isCancelled else { return }
            if let decoded { displayed.set(decoded, budget: media.displayBudget) }
            reportRatio(decoded)
        } catch {
            guard !Task.isCancelled else { return }
            displayed.clear()
        }
    }

    private func loadOriginal() async {
        guard let originalURL,
              originalURL != thumbnailURL
        else { return }
        do {
            let decoded = try await media.images.withFile(for: originalURL) { @MainActor [media, pixelSize] file in
                await media.stillDecoder.image(at: file, maximumPixelSize: pixelSize)
            }
            guard !Task.isCancelled, let decoded else { return }
            hasOriginalImage = displayed.set(decoded, budget: media.displayBudget)
            reportRatio(decoded)
        } catch {
            guard !Task.isCancelled else { return }
            // 详情页保留已经显示的低清图，原图失败时继续提供可读内容。
            Self.logger.debug("详情原图加载失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func reportRatio(_ image: UIImage?) {
        guard let image, image.size.height > 0 else { return }
        onAspectRatioResolved?(image.size.width / image.size.height)
    }
    public init(thumbnailURL: URL?, originalURL: URL?, contentMode: ContentMode = .fit, onAspectRatioResolved: ((CGFloat) -> Void)? = nil) {
        self.thumbnailURL = thumbnailURL
        self.originalURL = originalURL
        self.contentMode = contentMode
        self.onAspectRatioResolved = onAspectRatioResolved
    }
}

extension SHA256.Digest {
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

#endif
