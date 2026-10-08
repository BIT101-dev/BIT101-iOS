#if os(iOS)
import StorageCore
import DesignSystemKit
//
//  CachedRemoteImage.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-29.
//

import Combine
import SwiftUI
import UIKit

nonisolated struct MediaImageLoadIdentity: Hashable {
    let urls: [URL?]
    let environment: ObjectIdentifier
    var retryGeneration: UInt64 = 0
}

/// 主 App 使用的远程图片缓存视图。
///
/// 在内存和 `Caches` 目录缓存图片数据，应用重启后可以复用磁盘缓存。
public struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    @Environment(MediaEnvironment.self) private var media
    /// 需要加载的远程资源地址；为空时直接展示占位内容。
    let url: URL?
    /// 成功加载后的渲染闭包，由调用方决定裁剪、圆角、缩放等样式。
    let content: (Image) -> Content
    /// 加载前或失败时的占位内容。
    let placeholder: () -> Placeholder

    /// 使用 `StateObject` 为单个视图实例保留加载状态，避免 `body` 重算时重复创建 loader。
    @StateObject private var loader = CachedRemoteImageLoader()

    /// 创建一个使用本地缓存的远程图片视图。
    public init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    /// 按加载状态显示图片或占位内容。URL 变化时，`.task(id:)` 切换到对应加载任务。
    public var body: some View {
        Group {
            if let image = loader.image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(media), retryGeneration: media.imageRetryGeneration)) {
            await loader.load(url: url, media: media)
        }
    }
}

/// 主 App 的远程头像适配器；远程加载属于 App 层，头像容器保持在设计系统层。
public struct AppAvatarView: View {
    let imageURL: URL?
    let size: CGFloat
    let tint: Color
    let systemImage: String
    let accessibilityLabel: String?
    let anonymous: Bool

    public init(
        imageURL: URL?,
        size: CGFloat = AppDesignSystem.Size.Avatar.standard,
        tint: Color = AppDesignSystem.Palette.Accent.primary,
        systemImage: String = "person.fill",
        accessibilityLabel: String? = nil,
        anonymous: Bool = false
    ) {
        self.imageURL = imageURL
        self.size = size
        self.tint = tint
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.anonymous = anonymous
    }

    public var body: some View {
        CachedRemoteImage(url: imageURL) { image in
            AppAvatarContainer(
                image: image,
                size: size,
                tint: tint,
                systemImage: systemImage,
                accessibilityLabel: accessibilityLabel
            )
        } placeholder: {
            AppAvatarContainer(
                image: anonymous ? anonymousAvatarImage : nil,
                size: size,
                tint: tint,
                systemImage: systemImage,
                accessibilityLabel: accessibilityLabel
            )
        }
    }

    private var anonymousAvatarImage: Image? {
        let iconKey = UIDevice.current.userInterfaceIdiom == .pad
            ? "CFBundleIcons~ipad"
            : "CFBundleIcons"
        guard
            let icons = Bundle.main.infoDictionary?[iconKey] as? [String: Any],
            let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let iconNames = primaryIcon["CFBundleIconFiles"] as? [String],
            let iconName = iconNames.last,
            let image = UIImage(named: iconName)
        else {
            return nil
        }
        return Image(uiImage: image)
    }
}

@MainActor
final class CachedRemoteImageLoader: ObservableObject {
    /// 当前用于显示的位图。
    @Published private(set) var image: UIImage?

    /// 当前加载任务对应的 URL，用于校验网络响应是否仍属于当前视图。
    private var currentURL: URL?
    private weak var currentMedia: MediaEnvironment?

    /// 先读取本地缓存，缓存未命中时下载。URL 更新时清空当前图片状态。
    func load(url: URL?, media: MediaEnvironment) async {
        if currentURL == url, currentMedia === media, image != nil {
            return
        }

        currentMedia = media
        currentURL = url
        image = nil

        guard let url else { return }

        let generation = await media.avatars.cacheGeneration
        if let cachedImage = await media.avatars.image(for: url) {
            guard !Task.isCancelled, currentURL == url, currentMedia === media, await media.avatars.cacheGeneration == generation else { return }
            image = cachedImage
            return
        }

        do {
            let response = try await media.avatarHTTPClient.send(URLRequest(url: url), maximumBytes: RemoteImageResourceLimits.maximumEncodedBytes)
            let data = response.data
            guard !Task.isCancelled, currentURL == url, currentMedia === media, await media.avatars.cacheGeneration == generation else { return }
            guard let downloadedImage = await media.avatars.storeAndDecode(data, for: url, generation: generation) else {
                return
            }
            guard !Task.isCancelled, currentURL == url, currentMedia === media, await media.avatars.cacheGeneration == generation else { return }
            image = downloadedImage
        } catch {
            guard !Task.isCancelled, currentURL == url, currentMedia === media, await media.avatars.cacheGeneration == generation else { return }
            // 加载失败时保留占位内容。
            image = nil
        }
    }
}

actor CachedRemoteImageStore {
    /// 原始图片数据的内存缓存。
    private let memoryCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 160
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()
    /// 已准备显示的位图内存缓存。
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()
    private(set) var cacheGeneration: UInt64 = 0
    private let files: any AppFileService
    private let quota: ImageCacheDiskQuota
    /// 磁盘缓存根目录。
    private let directoryURL: URL

    /// 初始化缓存目录。
    ///
    /// 缓存目录位于 `Caches`，系统可在空间不足时删除其中的内容。
    init(files: any AppFileService, quota: ImageCacheDiskQuota) {
        self.files = files
        self.quota = quota
        let directoryURL = ImageCacheDirectories.avatars(using: files)
        try? files.createDirectory(at: directoryURL)
        self.directoryURL = directoryURL
    }

    /// 按“内存 -> 磁盘”顺序读取缓存数据。
    func data(for url: URL) async -> Data? {
        let generation = cacheGeneration
        let key = cacheKey(for: url)
        let fileURL = directoryURL.appendingPathComponent(key)

        if let cached = memoryCache.object(forKey: key as NSString) {
            touchDiskEntry(for: key)
            await quota.enforce(protecting: Set([fileURL]))
            guard cacheGeneration == generation else { return nil }
            return Data(referencing: cached)
        }

        guard let data = RemoteImageResourceLimits.cachedData(at: fileURL, using: files) else {
            await quota.enforce()
            return nil
        }
        try? files.setModificationDate(Date(), at: fileURL)
        await quota.enforce(protecting: Set([fileURL]))
        guard cacheGeneration == generation else { return nil }
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    /// 读取缓存图片，并准备其显示位图。
    func image(for url: URL) async -> UIImage? {
        let generation = cacheGeneration
        let key = cacheKey(for: url)
        if let cached = imageCache.object(forKey: key as NSString) {
            touchDiskEntry(for: key)
            await quota.enforce(
                protecting: Set([directoryURL.appendingPathComponent(key)])
            )
            guard cacheGeneration == generation else { return nil }
            return cached
        }
        guard let data = await data(for: url),
              let decoded = BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: imageCache.totalCostLimit)
        else { return nil }
        guard cacheGeneration == generation else { return nil }
        imageCache.setObject(decoded, forKey: key as NSString, cost: decodedPixelCost(decoded))
        return decoded
    }

    /// 将图片数据写入内存缓存和磁盘。
    func store(_ data: Data, for url: URL) async {
        guard data.count <= RemoteImageResourceLimits.maximumEncodedBytes else { return }
        let key = cacheKey(for: url)
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        let fileURL = directoryURL.appendingPathComponent(key)
        try? files.createDirectory(at: directoryURL)
        try? files.writeData(data, to: fileURL, options: [.atomic])
        try? files.setModificationDate(Date(), at: fileURL)
        await quota.enforce(protecting: Set([fileURL]))
    }

    /// 写入下载数据，并缓存准备显示的位图。
    func storeAndDecode(_ data: Data, for url: URL, generation expected: UInt64? = nil) async -> UIImage? {
        let generation = expected ?? cacheGeneration
        guard cacheGeneration == generation, !Task.isCancelled else { return nil }
        await store(data, for: url)
        guard cacheGeneration == generation, !Task.isCancelled else { return nil }
        guard let decoded = BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: imageCache.totalCostLimit) else { return nil }
        let key = cacheKey(for: url) as NSString
        imageCache.setObject(decoded, forKey: key, cost: decodedPixelCost(decoded))
        return decoded
    }

    /// 清空当前进程的内存缓存和磁盘中的远程图片缓存。
    func clearAll() {
        cacheGeneration &+= 1
        memoryCache.removeAllObjects()
        imageCache.removeAllObjects()

        guard files.fileExists(at: directoryURL) else { return }
        if let children = try? files.contentsOfDirectory(at: directoryURL, options: [.skipsHiddenFiles]) {
            for child in children {
                try? files.removeItem(at: child)
            }
        }
    }

    /// 使用 URL 的稳定短标识生成文件名，保持缓存文件名安全且紧凑。
    private func cacheKey(for url: URL) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 {
            value ^= UInt64(byte)
            value = value &* 1_099_511_628_211
        }
        return String(value, radix: 16)
    }

    private func touchDiskEntry(for key: String) {
        let fileURL = directoryURL.appendingPathComponent(key)
        try? files.setModificationDate(Date(), at: fileURL)
    }

    private func decodedPixelCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
    }
}

#endif
