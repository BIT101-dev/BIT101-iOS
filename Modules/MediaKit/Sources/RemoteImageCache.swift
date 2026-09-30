#if os(iOS)
import StorageCore
import TransportCore
import DesignSystemKit
import CryptoKit
import Foundation
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
    case local
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

/// Enforces the image-cache setting across gallery media and avatar files as one LRU pool.
actor ImageCacheDiskQuota {

    private let files: any AppFileService
    private let configuredDirectories: [URL]?
    private let cacheLimitMB: @MainActor @Sendable () -> Int
    private let pruneInterval: TimeInterval
    private var lastPruneDate = Date.distantPast

    init(
        files: any AppFileService,
        directories: [URL]? = nil,
        cacheLimitMB: @escaping @MainActor @Sendable () -> Int,
        pruneInterval: TimeInterval = 60
    ) {
        self.files = files
        configuredDirectories = directories
        self.cacheLimitMB = cacheLimitMB
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
        let protectedPaths = Set(protectedURLs.map { Self.canonicalPath(for: $0) })
        let cacheFiles = directories.flatMap { directory -> [(URL, Int64, Date)] in
            guard let children = try? files.contentsOfDirectory(at: directory, options: [.skipsHiddenFiles]) else {
                return []
            }
            return children.compactMap { url in
                guard !protectedPaths.contains(Self.canonicalPath(for: url)),
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

    private var directories: [URL] {
        configuredDirectories ?? [
            ImageCacheDirectories.gallery(using: files),
            ImageCacheDirectories.avatars(using: files),
        ]
    }

    private nonisolated static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
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
        let task: Task<DownloadResult, Error>
    }

    private let files: any AppFileService
    private let quota: ImageCacheDiskQuota
    private let httpClient: HTTPClient
    private let directory: URL
    private var downloads: [String: DownloadOperation] = [:]
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
            return file
        }
        return nil
    }

    /// 获取缓存文件；同一 URL 的并发请求会合并成一次下载。
    func file(for remoteURL: URL, variant: RemoteImageCacheVariant) async throws -> URL {
        if let cached = await cachedFile(for: remoteURL, variant: variant) {
            return cached
        }

        let requestKey = "\(variant.rawValue):\(remoteURL.absoluteString)"
        let operation: DownloadOperation
        if let running = downloads[requestKey] {
            operation = running
        } else {
            let created = Task<DownloadResult, Error> {
                let response = try await httpClient.send(URLRequest(url: remoteURL))
                return DownloadResult(data: response.data, mimeType: response.response.mimeType)
            }
            let newOperation = DownloadOperation(id: UUID(), task: created)
            downloads[requestKey] = newOperation
            operation = newOperation
        }

        do {
            let result = try await operation.task.value
            if downloads[requestKey]?.id == operation.id {
                downloads[requestKey] = nil
            }
            guard isDecodableImage(data: result.data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let ext = preferredExtension(for: remoteURL, mimeType: result.mimeType)
            let target = directory.appendingPathComponent("\(filePrefix(for: remoteURL, variant: variant)).\(ext)")
            if !files.fileExists(at: target) {
                try files.writeData(result.data, to: target, options: [.atomic])
            }
            touch(target)
            await quota.enforce(protecting: Set([target]))
            return target
        } catch {
            if downloads[requestKey]?.id == operation.id {
                downloads[requestKey] = nil
            }
            throw error
        }
    }

    /// 把内存图片持久化为系统预览可读取的本地文件。
    func localFile(data: Data, pathExtension: String = "png") async throws -> URL {
        let digest = SHA256.hash(data: data).hexString
        let target = directory.appendingPathComponent("local-\(digest).\(pathExtension)")
        if !hasData(at: target) {
            try files.writeData(data, to: target, options: [.atomic])
        }
        touch(target)
        await quota.enforce(protecting: Set([target]))
        return target
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
        if !hasData(at: target) {
            // 1 × 1 透明 PNG。
            let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL1WQAAAABJRU5ErkJggg=="
            guard let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileWriteUnknown) }
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
        return fileSize > 0
    }

    private func isDecodableImage(at url: URL) -> Bool {
        guard let data = try? files.readData(at: url) else { return false }
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

/// 串行后台解码话廊缩略图，避免多张图片同时进入屏幕时抢占主线程。
///
/// 磁盘缓存保存的是压缩 WebP/JPEG；仅仅构造 `UIImage` 仍可能把真正的像素解压推迟到
/// SwiftUI 绘制阶段。这里额外调用 `preparingForDisplay()`，让解压工作在 actor 执行器
/// 上提前完成，并用较小的内存缓存复用最近浏览过的结果。
actor GalleryThumbnailDecoder {
    private let files: any AppFileService

    init(files: any AppFileService) { self.files = files }

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    func image(at file: URL) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard let data = try? files.readData(at: file) else { return nil }
        let key = SHA256.hash(data: data).hexString as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }

        guard let source = UIImage(data: data), !Task.isCancelled else { return nil }
        let decoded = source.preparingForDisplay() ?? source
        let pixelWidth = Int(decoded.size.width * decoded.scale)
        let pixelHeight = Int(decoded.size.height * decoded.scale)
        images.setObject(decoded, forKey: key, cost: pixelWidth * pixelHeight * 4)
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
        .task(id: url) {
            image = nil
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
                // 缩略图失败时保留占位，不弹窗干扰浏览。
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
        .task(id: thumbnailURL?.absoluteString ?? originalURL?.absoluteString) {
            image = nil
            await loadThumbnail()
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

private extension SHA256.Digest {
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

#endif
