import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// 话廊图片缓存容量偏好。
///
/// 单位为 MB；`0` 表示不主动限制。缓存本身仍位于系统 Caches 目录，iOS 在设备
/// 空间紧张时仍可以回收。
enum GalleryImageCachePreferences {
    nonisolated static let limitMBKey = "gallery.image-cache.limit-mb"
    nonisolated static let defaultLimitMB = 500

    nonisolated static var limitMB: Int {
        get {
            guard UserDefaults.standard.object(forKey: limitMBKey) != nil else {
                return defaultLimitMB
            }
            return max(UserDefaults.standard.integer(forKey: limitMBKey), 0)
        }
        set {
            UserDefaults.standard.set(max(newValue, 0), forKey: limitMBKey)
        }
    }
}

enum GalleryImageCacheVariant: String, Sendable {
    case thumbnail = "low"
    case original = "high"
    case local
}

/// 低清图、高清图和 GIF 共用的持久磁盘缓存。
///
/// 读取时更新文件修改时间，将其作为轻量 LRU 的“最近使用时间”；写入后若超过用户
/// 设置的上限，会从最久未使用的文件开始清理到上限的 85%，避免反复触发清理。
actor GalleryImageCache {
    static let shared = GalleryImageCache()

    private struct DownloadResult: Sendable {
        let data: Data
        let mimeType: String?
    }

    private let fileManager = FileManager.default
    private let directory: URL
    private var downloads: [String: Task<DownloadResult, Error>] = [:]
    private let supportedExtensions = ["jpg", "jpeg", "png", "gif", "heic", "webp", "bin"]
    /// 不在每张缩略图落盘后遍历整个缓存目录；最多每分钟执行一次容量整理。
    private var lastPruneDate = Date()

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = caches.appendingPathComponent("BIT101GalleryImages", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 返回已有缓存并刷新其 LRU 时间，不发起网络请求。
    func cachedFile(for remoteURL: URL, variant: GalleryImageCacheVariant) -> URL? {
        let prefix = filePrefix(for: remoteURL, variant: variant)
        guard let file = supportedExtensions
            .map({ directory.appendingPathComponent("\(prefix).\($0)") })
            .first(where: { fileManager.fileExists(atPath: $0.path) })
        else { return nil }
        touch(file)
        return file
    }

    /// 获取缓存文件；同一 URL 的并发请求会合并成一次下载。
    func file(for remoteURL: URL, variant: GalleryImageCacheVariant) async throws -> URL {
        if let cached = cachedFile(for: remoteURL, variant: variant) {
            return cached
        }

        let requestKey = "\(variant.rawValue):\(remoteURL.absoluteString)"
        let task: Task<DownloadResult, Error>
        if let running = downloads[requestKey] {
            task = running
        } else {
            let created = Task<DownloadResult, Error> {
                let response = try await HTTPClient.community.send(URLRequest(url: remoteURL))
                return DownloadResult(data: response.data, mimeType: response.response.mimeType)
            }
            downloads[requestKey] = created
            task = created
        }

        do {
            let result = try await task.value
            downloads[requestKey] = nil
            let ext = preferredExtension(for: remoteURL, mimeType: result.mimeType)
            let target = directory.appendingPathComponent("\(filePrefix(for: remoteURL, variant: variant)).\(ext)")
            if !fileManager.fileExists(atPath: target.path) {
                try result.data.write(to: target, options: .atomic)
            }
            touch(target)
            pruneIfNeeded(protecting: Set([target]))
            return target
        } catch {
            downloads[requestKey] = nil
            throw error
        }
    }

    /// 把内存图片持久化为系统预览可读取的本地文件。
    func localFile(data: Data, pathExtension: String = "png") throws -> URL {
        let digest = SHA256.hash(data: data).hexString
        let target = directory.appendingPathComponent("local-\(digest).\(pathExtension)")
        if !fileManager.fileExists(atPath: target.path) {
            try data.write(to: target, options: .atomic)
        }
        touch(target)
        pruneIfNeeded(protecting: Set([target]))
        return target
    }

    /// Quick Look 数据源暂时缺图时使用的透明占位文件。
    func placeholderFile() throws -> URL {
        let target = directory.appendingPathComponent("preview-placeholder.png")
        if !fileManager.fileExists(atPath: target.path) {
            // 1 × 1 透明 PNG。
            let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL1WQAAAABJRU5ErkJggg=="
            guard let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: target, options: .atomic)
        }
        return target
    }

    /// 设置改变后立即按新上限执行一次清理。
    func enforceCurrentLimit() {
        pruneIfNeeded(protecting: [], force: true)
    }

    /// 当前话廊图片缓存实际占用的磁盘空间。
    ///
    /// 只统计统一图片缓存目录，不把 URLCache 或其他模块的缓存混入设置页数值。
    func usedBytes() -> Int64 {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return children.reduce(Int64(0)) { total, url in
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }

    private func filePrefix(for url: URL, variant: GalleryImageCacheVariant) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).hexString
        return "\(variant.rawValue)-\(digest)"
    }

    private func preferredExtension(for url: URL, mimeType: String?) -> String {
        let existing = url.pathExtension.lowercased()
        if supportedExtensions.dropLast().contains(existing) { return existing }
        switch mimeType?.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func pruneIfNeeded(protecting protectedURLs: Set<URL>, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPruneDate) >= 60 else { return }
        lastPruneDate = now

        let limitMB = GalleryImageCachePreferences.limitMB
        guard limitMB > 0 else { return }
        let limit = Int64(limitMB) * 1_024 * 1_024

        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let files = children.compactMap { url -> (URL, Int64, Date)? in
            guard
                !protectedURLs.contains(url),
                url.lastPathComponent != "preview-placeholder.png",
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                values.isRegularFile == true
            else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        let protectedSize = children
            .filter(protectedURLs.contains)
            .reduce(Int64(0)) { result, url in
                result + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        var total = files.reduce(protectedSize) { $0 + $1.1 }
        guard total > limit else { return }

        let target = Int64(Double(limit) * 0.85)
        for file in files.sorted(by: { $0.2 < $1.2 }) where total > target {
            if (try? fileManager.removeItem(at: file.0)) != nil {
                total -= file.1
            }
        }
    }
}

/// 串行后台解码话廊缩略图，避免多张图片同时进入屏幕时抢占主线程。
///
/// 磁盘缓存保存的是压缩 WebP/JPEG；仅仅构造 `UIImage` 仍可能把真正的像素解压推迟到
/// SwiftUI 绘制阶段。这里额外调用 `preparingForDisplay()`，让解压工作在 actor 执行器
/// 上提前完成，并用较小的内存缓存复用最近浏览过的结果。
private actor GalleryThumbnailDecoder {
    static let shared = GalleryThumbnailDecoder()

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    func image(at file: URL) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = file.path as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }

        guard let source = UIImage(contentsOfFile: file.path), !Task.isCancelled else { return nil }
        let decoded = source.preparingForDisplay() ?? source
        let pixelWidth = Int(decoded.size.width * decoded.scale)
        let pixelHeight = Int(decoded.size.height * decoded.scale)
        images.setObject(decoded, forKey: key, cost: pixelWidth * pixelHeight * 4)
        return decoded
    }
}

/// 静态话廊缩略图视图，确保首页显示过的低清图进入统一持久缓存。
struct GalleryCachedStillImage: View {
    let url: URL?
    var contentMode: ContentMode = .fit
    var onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card)
                    .fill(AppDesignSystem.Palette.highlight.opacity(0.12))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(AppDesignSystem.Palette.highlight)
                    }
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            do {
                let file = try await GalleryImageCache.shared.file(for: url, variant: .thumbnail)
                guard !Task.isCancelled else { return }
                let decoded = await GalleryThumbnailDecoder.shared.image(at: file)
                guard !Task.isCancelled else { return }
                image = decoded
                if let decoded, decoded.size.height > 0 {
                    onAspectRatioResolved?(decoded.size.width / decoded.size.height)
                }
            } catch {
                // 缩略图失败时保留占位，不弹窗干扰浏览。
            }
        }
    }
}

private extension SHA256.Digest {
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
