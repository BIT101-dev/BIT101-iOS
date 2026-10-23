#if os(iOS)
import StorageCore
import DesignSystemKit
import TransportCore
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
    var budgetRetryGeneration: UInt64 = 0
    var pixelSize: Int = 0
}

/// 主 App 使用的远程图片缓存视图。
///
/// 在内存和 `Caches` 目录缓存图片数据，应用重启后可以复用磁盘缓存。
public struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    @Environment(MediaEnvironment.self) private var media
    @Environment(\.displayScale) private var displayScale
    @State private var pixelSize = 0
    @State private var budgetRetryGeneration: UInt64 = 0
    /// 需要加载的远程资源地址；为空时直接展示占位内容。
    let url: URL?
    let fallbackURL: URL?
    /// 成功加载后的渲染闭包，由调用方决定裁剪、圆角、缩放等样式。
    let content: (Image) -> Content
    /// 加载前或失败时的占位内容。
    let placeholder: () -> Placeholder

    /// 使用 `StateObject` 为单个视图实例保留加载状态，避免 `body` 重算时重复创建 loader。
    @StateObject private var loader = CachedRemoteImageLoader()

    /// 创建一个使用本地缓存的远程图片视图。
    public init(
        url: URL?,
        fallbackURL: URL? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
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
        .onGeometryChange(for: Int.self) { [scale = displayScale] geometry in
            Int((max(geometry.size.width, geometry.size.height) * scale).rounded(.up))
        } action: { pixelSize = $0 }
        .task(id: MediaImageLoadIdentity(urls: [url, fallbackURL], environment: ObjectIdentifier(media),
            retryGeneration: media.imageRetryGeneration, budgetRetryGeneration: budgetRetryGeneration, pixelSize: pixelSize)) {
            guard pixelSize > 0 else { return }
            await loader.load(url: url, fallbackURL: fallbackURL, media: media, maximumPixelSize: pixelSize)
        }
        .onChange(of: media.displayBudget.releaseGeneration) { if loader.waitingForBudget { budgetRetryGeneration &+= 1 } }
        .onDisappear { loader.releaseDisplayImage() }
    }
}

/// 主 App 的远程头像适配器；远程加载属于 App 层，头像容器保持在设计系统层。
public struct AppAvatarView: View {
    let imageURL: URL?
    let fallbackImageURL: URL?
    let size: CGFloat
    let tint: Color
    let systemImage: String
    let accessibilityLabel: String?
    let anonymous: Bool

    public init(
        imageURL: URL?,
        fallbackImageURL: URL? = nil,
        size: CGFloat = AppDesignSystem.Size.Avatar.standard,
        tint: Color = AppDesignSystem.Palette.Accent.primary,
        systemImage: String = "person.fill",
        accessibilityLabel: String? = nil,
        anonymous: Bool = false
    ) {
        self.imageURL = imageURL
        self.fallbackImageURL = fallbackImageURL
        self.size = size
        self.tint = tint
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.anonymous = anonymous
    }

    public var body: some View {
        CachedRemoteImage(url: imageURL, fallbackURL: fallbackImageURL) { image in
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
    @Published private(set) var waitingForBudget = false

    /// 当前候选地址用于核对异步响应所属的视图资源。
    private var currentURLs: [URL] = []
    private weak var currentMedia: MediaEnvironment?
    private var currentPixelSize: Int?
    private let displayOwner = UUID()
    private var retainedBudget: MediaDisplayBudget?

    deinit {
        let budget = retainedBudget, owner = displayOwner
        Task { @MainActor in budget?.release(owner: owner) }
    }

    func releaseDisplayImage() {
        retainedBudget?.release(owner: displayOwner)
        retainedBudget = nil
        image = nil
        waitingForBudget = false
    }

    private func display(_ value: UIImage, media: MediaEnvironment) {
        guard media.displayBudget.retain(value, owner: displayOwner) else { waitingForBudget = true; return }
        waitingForBudget = false
        if retainedBudget !== media.displayBudget { retainedBudget?.release(owner: displayOwner) }
        retainedBudget = media.displayBudget
        image = value
    }

    /// 先读取本地缓存，缓存未命中时下载。URL 更新时清空当前图片状态。
    func load(url: URL?, fallbackURL: URL? = nil, media: MediaEnvironment, maximumPixelSize: Int? = nil) async {
        let urls = mediaImageURLs([url, fallbackURL])
        if currentURLs == urls, currentMedia === media, currentPixelSize == maximumPixelSize, image != nil {
            return
        }

        currentMedia = media
        currentURLs = urls
        currentPixelSize = maximumPixelSize
        releaseDisplayImage()

        let generation = await media.avatars.cacheGeneration
        func isCurrent() async -> Bool {
            let cacheGeneration = await media.avatars.cacheGeneration
            return !Task.isCancelled && currentURLs == urls && currentMedia === media
                && currentPixelSize == maximumPixelSize && cacheGeneration == generation
        }
        for url in urls.reversed() {
            if let cachedImage = await media.avatars.image(for: url, maximumPixelSize: maximumPixelSize) {
                guard await isCurrent() else { return }
                display(cachedImage, media: media)
                return
            }
        }
        for url in urls {
            do {
                let response = try await media.downloads.response(for: url, source: .avatar)
                guard await isCurrent() else { return }
                guard let downloadedImage = await media.avatars.storeAndDecode(response.data, for: url,
                    generation: generation, maximumPixelSize: maximumPixelSize) else { continue }
                guard await isCurrent() else { return }
                display(downloadedImage, media: media)
                return
            } catch {
                guard await isCurrent(), !TaskCancellation.matches(error) else { return }
            }
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
    private var activeFileUses: Set<UUID> = []
    /// 磁盘缓存根目录。
    private let directoryURL: URL

    /// 初始化缓存目录。
    ///
    /// 缓存目录位于 `Caches`，系统可在空间不足时删除其中的内容。
    init(files: any AppFileService, quota: ImageCacheDiskQuota) {
        self.files = files
        self.quota = quota
        let directoryURL = ImageCacheDirectories.avatars(using: files)
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

        guard let data = diskData(for: url) else {
            await quota.enforce()
            return nil
        }
        try? files.setModificationDate(Date(), at: fileURL)
        await quota.enforce(protecting: Set([fileURL]))
        guard cacheGeneration == generation else { return nil }
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    func diskData(for url: URL) -> Data? {
        RemoteImageResourceLimits.cachedData(at: directoryURL.appendingPathComponent(cacheKey(for: url)), using: files)
    }

    /// 读取缓存图片，并准备其显示位图。
    func image(for url: URL, maximumPixelSize: Int? = nil) async -> UIImage? {
        let generation = cacheGeneration
        let key = "\(cacheKey(for: url))|pixels:\(maximumPixelSize ?? 0)"
        if let cached = imageCache.object(forKey: key as NSString) {
            touchDiskEntry(for: cacheKey(for: url))
            await quota.enforce(
                protecting: Set([directoryURL.appendingPathComponent(cacheKey(for: url))])
            )
            guard cacheGeneration == generation else { return nil }
            return cached
        }
        guard let data = await data(for: url),
              let decoded = BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: imageCache.totalCostLimit,
                                                          maximumPixelSize: maximumPixelSize)
        else { return nil }
        guard cacheGeneration == generation else { return nil }
        imageCache.setObject(decoded, forKey: key as NSString, cost: MediaDisplayBudget.pixelBytes(decoded))
        return decoded
    }

    /// 将图片数据写入内存缓存和磁盘。
    func store(_ data: Data, for url: URL) async {
        guard data.count <= RemoteImageResourceLimits.maximumEncodedBytes else { return }
        let key = cacheKey(for: url)
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        let fileURL = directoryURL.appendingPathComponent(key)
        let use = UUID()
        do {
            try quota.beginFileUse(fileURL, owner: use) { [files, directoryURL] in
                try files.createDirectory(at: directoryURL)
                try files.writeData(data, to: fileURL, options: [.atomic])
                try? files.setModificationDate(Date(), at: fileURL)
            }
        } catch { return }
        activeFileUses.insert(use)
        defer { activeFileUses.remove(use); quota.endFileUse(use) }
        await quota.didWrite(fileURL)
    }

    /// 写入下载数据，并缓存准备显示的位图。
    func storeAndDecode(_ data: Data, for url: URL, generation expected: UInt64? = nil, maximumPixelSize: Int? = nil) async -> UIImage? {
        let generation = expected ?? cacheGeneration
        guard cacheGeneration == generation, !Task.isCancelled,
              data.count <= RemoteImageResourceLimits.maximumEncodedBytes,
              let decoded = BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: imageCache.totalCostLimit,
                                                          maximumPixelSize: maximumPixelSize) else { return nil }
        await store(data, for: url)
        guard cacheGeneration == generation, !Task.isCancelled else { return nil }
        let key = "\(cacheKey(for: url))|pixels:\(maximumPixelSize ?? 0)" as NSString
        imageCache.setObject(decoded, forKey: key, cost: MediaDisplayBudget.pixelBytes(decoded))
        return decoded
    }

    /// 清空当前进程的内存缓存和磁盘中的远程图片缓存。
    @discardableResult func clearAll() async -> Bool {
        cacheGeneration &+= 1
        clearMemory()
        for use in activeFileUses { quota.endFileUse(use) }
        activeFileUses.removeAll()

        return await quota.clearDirectory(directoryURL)
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
        imageCache.removeAllObjects()
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

}

#endif
