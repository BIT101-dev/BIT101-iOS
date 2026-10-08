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

enum RemoteImageCacheVariant: String, Sendable {
    case thumbnail = "low"
    case original = "high"
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

/// Synchronizes preview-file registration with disk eviction.
nonisolated final class PreviewFileOwnership: Sendable {
    private let sessions = OSAllocatedUnfairLock(initialState: [UUID: Set<String>]())
    func begin(_ owner: UUID) { sessions.withLock { $0[owner] = [] } }
    func end(_ owner: UUID) { sessions.withLock { $0[owner] = nil } }
    func contains(_ owner: UUID) -> Bool { sessions.withLock { $0[owner] != nil } }
    func pin(_ file: URL, using files: any AppFileService, owner: UUID) -> Bool {
        sessions.withLock { sessions in
            guard sessions[owner] != nil, files.fileExists(at: file) else { return false }
            sessions[owner]?.insert(files.canonicalFileURL(file).path)
            return true
        }
    }
    func withPaths<T: Sendable>(_ operation: @Sendable (Set<String>) -> T) -> T {
        sessions.withLock { operation($0.values.reduce(into: []) { $0.formUnion($1) }) }
    }
}

/// Enforces the image-cache setting across gallery media and avatar files as one LRU pool.
actor ImageCacheDiskQuota {

    private let files: any AppFileService
    private let configuredDirectories: [URL]?
    private let cacheLimitMB: @MainActor @Sendable () async -> Int
    private let previewOwnership: PreviewFileOwnership
    private let pruneInterval: TimeInterval
    private var lastPruneDate = Date.distantPast

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

    func enforce(force: Bool = false, protecting protectedURLs: Set<URL> = []) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastPruneDate) >= pruneInterval else { return }
        lastPruneDate = now

        let limitMB = await cacheLimitMB()
        guard limitMB > 0 else { return }
        let limit = Int64(limitMB) * 1_024 * 1_024
        let cacheDirectories = directories
        previewOwnership.withPaths { previewPaths in
            let protectedPaths = Set(protectedURLs.map { files.canonicalFileURL($0).path }).union(previewPaths)
            let cacheFiles = cacheDirectories.flatMap { directory -> [(URL, Int64, Date)] in
                guard let children = try? files.contentsOfDirectory(at: directory, options: [.skipsHiddenFiles]) else {
                    return []
                }
                return children.compactMap { url in
                    guard !protectedPaths.contains(files.canonicalFileURL(url).path),
                          url.lastPathComponent != "preview-placeholder.png",
                          let size = files.regularFileSize(at: url)
                    else { return nil }
                    return (url, Int64(size), files.modificationDate(at: url) ?? .distantPast)
                }
            }
            var total = cacheFiles.reduce(Int64(0)) { $0 + $1.1 }
            total += protectedPaths.reduce(Int64(0)) {
                $0 + Int64(files.regularFileSize(at: URL(fileURLWithPath: $1)) ?? 0)
            }
            guard total > limit else { return }

            let target = Int64(Double(limit) * 0.85)
            for (url, size, _) in cacheFiles.sorted(by: { $0.2 < $1.2 }) where total > target {
                do {
                    try files.removeItem(at: url)
                    total -= size
                } catch {
                    continue
                }
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
        var waiters: [UUID: CheckedContinuation<URL, any Error>]
    }

    private let files: any AppFileService
    private let quota: ImageCacheDiskQuota
    private let httpClient: HTTPClient
    private let directory: URL
    private var downloads: [String: DownloadOperation] = [:]
    private var generation: UInt64 = 0
    var waitingConsumerCount: Int { downloads.values.reduce(0) { $0 + $1.waiters.count } }
    private let supportedExtensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bin"]
    init(files: any AppFileService, quota: ImageCacheDiskQuota, httpClient: HTTPClient) {
        self.files = files
        self.quota = quota
        self.httpClient = httpClient
        directory = ImageCacheDirectories.gallery(using: files)
        try? files.createDirectory(at: directory)
    }

    /// 返回已有缓存并刷新其 LRU 时间，不发起网络请求。
    func cachedFile(for remoteURL: URL, variant: RemoteImageCacheVariant) async -> URL? {
        let owner = generation
        let prefix = filePrefix(for: remoteURL, variant: variant)
        for extensionName in supportedExtensions {
            let file = directory.appendingPathComponent("\(prefix).\(extensionName)")
            guard files.fileExists(at: file) else { continue }
            guard hasData(at: file), isDecodableImage(at: file) else {
                try? files.removeItem(at: file)
                continue
            }
            touch(file)
            await quota.enforce(protecting: Set([file]))
            guard owner == generation, !Task.isCancelled else { return nil }
            return file
        }
        return nil
    }

    /// 获取缓存文件；同一 URL 的并发请求会合并成一次下载。
    func file(for remoteURL: URL, variant: RemoteImageCacheVariant) async throws -> URL {
        try Task.checkCancellation()
        let owner = generation
        if let cached = await cachedFile(for: remoteURL, variant: variant) {
            return cached
        }
        try Task.checkCancellation()
        guard owner == generation else { throw CancellationError() }

        let requestKey = "\(variant.rawValue):\(remoteURL.absoluteString)"
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
                let task = Task { [httpClient] in
                    let result: Result<DownloadResult, any Error>
                    do {
                        let response = try await httpClient.send(URLRequest(url: remoteURL), maximumBytes: RemoteImageResourceLimits.maximumEncodedBytes)
                        result = .success(DownloadResult(data: response.data, mimeType: response.response.mimeType))
                    } catch { result = .failure(error) }
                    await finishDownload(result, key: requestKey, id: id, remoteURL: remoteURL, variant: variant)
                }
                downloads[requestKey] = DownloadOperation(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter, key: requestKey) }
        }
    }

    private func finishDownload(_ result: Result<DownloadResult, any Error>, key: String, id: UUID,
                                remoteURL: URL, variant: RemoteImageCacheVariant) async {
        guard downloads[key]?.id == id else { return }
        let completed: Result<URL, any Error>
        do {
            let result = try result.get()
            guard isDecodableImage(data: result.data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let ext = preferredExtension(for: remoteURL, mimeType: result.mimeType)
            let target = directory.appendingPathComponent("\(filePrefix(for: remoteURL, variant: variant)).\(ext)")
            if !files.fileExists(at: target) {
                try files.createDirectory(at: directory)
                try files.writeData(result.data, to: target, options: [.atomic])
            }
            touch(target)
            await quota.enforce(protecting: Set([target]))
            completed = .success(target)
        } catch { completed = .failure(error) }
        guard downloads[key]?.id == id, let operation = downloads.removeValue(forKey: key) else { return }
        for continuation in operation.waiters.values { continuation.resume(with: completed) }
    }

    private func cancelWaiter(_ waiter: UUID, key: String) {
        guard var operation = downloads[key], let continuation = operation.waiters.removeValue(forKey: waiter) else { return }
        if operation.waiters.isEmpty {
            downloads[key] = nil
            operation.task.cancel()
        } else { downloads[key] = operation }
        continuation.resume(throwing: CancellationError())
    }

    func clearAll() {
        generation &+= 1
        let pending = downloads.values
        downloads.removeAll()
        for operation in pending {
            operation.task.cancel()
            for continuation in operation.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
        _ = files.removeContents(of: directory)
    }

    func previewFile(at cachedURL: URL, using previewFiles: any AppFileService) throws -> URL {
        let data = try files.readData(at: cachedURL)
        if (try? previewFiles.readData(at: cachedURL)) == data { return cachedURL }
        let directory = ImageCacheDirectories.gallery(using: previewFiles)
        try previewFiles.createDirectory(at: directory)
        let name = "local-\(SHA256.hash(data: data).hexString).\(cachedURL.pathExtension)"
        let target = directory.appendingPathComponent(name)
        if (try? previewFiles.readData(at: target)) != data {
            try previewFiles.writeData(data, to: target, options: [.atomic])
        }
        try previewFiles.setModificationDate(Date(), at: target)
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

    private func filePrefix(for url: URL, variant: RemoteImageCacheVariant) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).hexString
        return "\(variant.rawValue)-\(digest)"
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
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
    public static func image(from data: Data, maximumDecodedBytes: Int = RemoteImageResourceLimits.maximumDecodedBytes) -> UIImage? {
        guard maximumDecodedBytes >= 4, !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let depth = (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        guard (1...32).contains(depth) else { return nil }
        let bytesPerPixel = max(4, ((depth + 7) / 8) * 4)
        let side = Int(Double(maximumDecodedBytes / bytesPerPixel).squareRoot())
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.bytesPerRow * image.height <= maximumDecodedBytes, !Task.isCancelled else { return nil }
        return UIImage(cgImage: image)
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

    func image(at file: URL) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard let data = RemoteImageResourceLimits.cachedData(at: file, using: files) else { return nil }
        let key = SHA256.hash(data: data).hexString as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }

        guard let decoded = BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: images.totalCostLimit),
              let pixels = decoded.cgImage else { return nil }
        images.setObject(decoded, forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return decoded
    }
}

/// 静态话廊缩略图视图，确保首页显示过的低清图进入统一持久缓存。
public struct RemoteCachedStillImage: View {
    @Environment(MediaEnvironment.self) private var media
    let url: URL?
    var contentMode: ContentMode = .fit
    var onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    @State private var image: UIImage?
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
        .task(id: MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(media), retryGeneration: media.imageRetryGeneration)) {
            let resource = MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(media))
            if currentResource != resource { image = nil; currentResource = resource }
            guard image == nil else { return }
            guard let url else { return }
            do {
                let file = try await media.images.file(for: url, variant: .thumbnail)
                guard !Task.isCancelled else { return }
                let decoded = await media.stillDecoder.image(at: file)
                guard !Task.isCancelled else { return }
                image = decoded
                if let decoded, decoded.size.height > 0 {
                    onAspectRatioResolved?(decoded.size.width / decoded.size.height)
                }
            } catch {
                guard !Task.isCancelled else { return }
                // 缩略图失败时显示占位内容。
                image = nil
            }
        }
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
    private static let logger = Logger(subsystem: "BIT101", category: "CommunityImage")
    let thumbnailURL: URL?
    let originalURL: URL?
    var contentMode: ContentMode = .fit
    var onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    @State private var image: UIImage?
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
        .task(id: MediaImageLoadIdentity(urls: [thumbnailURL, originalURL], environment: ObjectIdentifier(media), retryGeneration: media.imageRetryGeneration)) {
            let resource = MediaImageLoadIdentity(urls: [thumbnailURL, originalURL], environment: ObjectIdentifier(media))
            if currentResource != resource { image = nil; currentResource = resource }
            if image == nil { await loadThumbnail() }
            guard !Task.isCancelled else { return }
            await loadOriginal()
        }
    }

    private func loadThumbnail() async {
        guard let thumbnailURL else { return }
        do {
            let file = try await media.images.file(for: thumbnailURL, variant: .thumbnail)
            guard !Task.isCancelled else { return }
            let decoded = await media.stillDecoder.image(at: file)
            guard !Task.isCancelled else { return }
            image = decoded
            reportRatio(decoded)
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
        }
    }

    private func loadOriginal() async {
        guard let originalURL,
              originalURL != thumbnailURL
        else { return }
        do {
            let file = try await media.images.file(for: originalURL, variant: .original)
            guard !Task.isCancelled else { return }
            let decoded = await media.stillDecoder.image(at: file)
            guard !Task.isCancelled, let decoded else { return }
            image = decoded
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
