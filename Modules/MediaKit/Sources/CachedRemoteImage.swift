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

import Observation
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

    /// 为单个视图实例保留加载状态。
    @State private var loader = CachedRemoteImageLoader()

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

@Observable @MainActor
final class CachedRemoteImageLoader {
    private let displayed = MediaDisplayedImage()
    var image: UIImage? { displayed.image }
    var waitingForBudget: Bool { displayed.waitingForBudget }

    /// 当前候选地址用于核对异步响应所属的视图资源。
    private var currentURLs: [URL] = []
    private weak var currentMedia: MediaEnvironment?
    private var currentPixelSize: Int?
    func releaseDisplayImage() { displayed.clear() }

    private func display(_ value: UIImage, media: MediaEnvironment) {
        displayed.set(value, budget: media.displayBudget)
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
                guard let downloadedImage = try await media.avatars.loadImage(for: url,
                    maximumPixelSize: maximumPixelSize) else { continue }
                guard await isCurrent() else { return }
                display(downloadedImage, media: media)
                return
            } catch {
                guard await isCurrent(), !TaskCancellation.matches(error) else { return }
            }
        }
    }
}

/// 头像解码共享原始资源缓存与租约，位图沿头像展示预算复用。
actor CachedRemoteImageStore {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()
    private let files: any AppFileService
    private let resources: RemoteImageCache
    private let download: (@Sendable (URL) async throws -> HTTPResponse)?
    private var decodedGeneration: UInt64 = 0
    var cacheGeneration: UInt64 { get async { await resources.cacheGeneration } }

    init(files: any AppFileService, resources: RemoteImageCache,
        download: (@Sendable (URL) async throws -> HTTPResponse)? = nil) {
        self.files = files
        self.resources = resources
        self.download = download
    }

    func data(for url: URL) async -> Data? {
        let data = try? await resources.withCachedSource(for: url) { [files] source -> Data? in Self.bytes(from: source, using: files) }
        return data ?? nil
    }

    func diskData(for url: URL) async -> Data? {
        let data = try? await resources.withCachedFile(for: url) { [files] file -> Data? in RemoteImageResourceLimits.cachedData(at: file, using: files) }
        return data ?? nil
    }

    func image(for url: URL, maximumPixelSize: Int? = nil) async -> UIImage? {
        let generation = await cacheGeneration
        if decodedGeneration != generation { clearDecoded(); decodedGeneration = generation }
        let key = cacheKey(for: url, maximumPixelSize: maximumPixelSize)
        if let image = imageCache.object(forKey: key) {
            _ = try? await resources.withCachedSource(for: url) { _ in true }
            guard await cacheGeneration == generation, !Task.isCancelled else { return nil }
            return image
        }
        guard let data = await data(for: url) else { return nil }
        return await decode(data, for: url, generation: generation, maximumPixelSize: maximumPixelSize)
    }

    func loadImage(for url: URL, maximumPixelSize: Int? = nil) async throws -> UIImage? {
        let generation = await cacheGeneration
        let data = try await resources.withSource(for: url, download: download) { [files] in Self.bytes(from: $0, using: files) }
        guard let data else { return nil }
        return await decode(data, for: url, generation: generation, maximumPixelSize: maximumPixelSize)
    }

    private func decode(_ data: Data, for url: URL, generation: UInt64, maximumPixelSize: Int?) async -> UIImage? {
        guard data.count <= RemoteImageResourceLimits.maximumEncodedBytes,
              let image = BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: imageCache.totalCostLimit,
                  maximumPixelSize: maximumPixelSize), await cacheGeneration == generation, !Task.isCancelled else { return nil }
        if decodedGeneration != generation { clearDecoded(); decodedGeneration = generation }
        imageCache.setObject(image, forKey: cacheKey(for: url, maximumPixelSize: maximumPixelSize), cost: MediaDisplayBudget.pixelBytes(image))
        return image
    }

    @discardableResult func clearAll() async -> Bool {
        clearDecoded()
        return await resources.clearAll()
    }

    func clearMemory() async { clearDecoded(); await resources.clearMemory() }
    private func clearDecoded() { imageCache.removeAllObjects() }
    private func cacheKey(for url: URL, maximumPixelSize: Int?) -> NSString {
        "\(HTTPSURLUpgrade.upgradedURL(from: url).absoluteString)|pixels:\(maximumPixelSize ?? 0)" as NSString
    }
    private nonisolated static func bytes(from source: RemoteImageSource, using files: any AppFileService) -> Data? {
        switch source {
        case .file(let file): RemoteImageResourceLimits.cachedData(at: file, using: files)
        case .memory(let data, _): data
        }
    }
}

#endif
