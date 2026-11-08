#if os(iOS)
import DesignSystemKit
import Foundation
import Observation
import StorageCore
import SwiftUI
import TransportCore
import UIKit

/// 静态图片按质量读取已有缓存，下载时沿低清和原图地址恢复。
@Observable @MainActor
final class RemoteStillImageLoader {
    let displayed = MediaDisplayedImage()
    private var currentResource: MediaImageLoadIdentity?
    private var displayedURL: URL?
    var image: UIImage? { displayed.image }

    func clear() {
        displayed.clear()
        displayedURL = nil
        currentResource = nil
    }

    func load(
        thumbnailURL: URL?, originalURL: URL?, loadsOriginal: Bool, media: MediaEnvironment,
        pixelSize: Int, viewport: MediaImageViewport? = nil,
        onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    ) async {
        let urls = mediaImageURLs([thumbnailURL, originalURL])
        let resource = MediaImageLoadIdentity(
            urls: urls.map(Optional.some), environment: ObjectIdentifier(media),
            pixelSize: pixelSize, viewport: viewport)
        if currentResource != resource {
            clear()
            currentResource = resource
        }
        let original = originalURL.map { HTTPSURLUpgrade.upgradedURL(from: $0) } ?? urls.first
        if image != nil && (!loadsOriginal || displayedURL == original) { return }
        func isCurrent() -> Bool { !Task.isCancelled && currentResource == resource }
        func display(_ image: UIImage, url: URL) -> Bool {
            guard displayed.set(image, budget: media.displayBudget) else { return false }
            displayedURL = url
            if image.size.height > 0 {
                onAspectRatioResolved?(image.size.width / image.size.height)
            }
            return true
        }

        for url in urls.reversed() {
            let cached: UIImage?? = try? await media.images.withCachedSource(for: url) {
                @MainActor source in
                await media.stillDecoder.image(
                    from: source, maximumPixelSize: pixelSize, viewport: viewport)
            }
            guard isCurrent() else { return }
            if let decoded = cached ?? nil {
                guard display(decoded, url: url) else { return }
                if !loadsOriginal || url == original { return }
                break
            }
        }
        for url in urls {
            if image != nil && url == displayedURL { continue }
            do {
                let decoded = try await media.images.withSource(for: url) { @MainActor source in
                    await media.stillDecoder.image(
                        from: source, maximumPixelSize: pixelSize, viewport: viewport)
                }
                guard isCurrent() else { return }
                guard let decoded else { continue }
                guard display(decoded, url: url) else { return }
                if !loadsOriginal || url == original { return }
            } catch {
                guard isCurrent(), !TaskCancellation.matches(error) else { return }
            }
        }
    }
}

private struct RemoteStillImage: View {
    @Environment(MediaEnvironment.self) private var media
    @Environment(\.displayScale) private var displayScale
    @State private var viewport = MediaImageViewport.zero
    private var pixelSize: Int { viewport.maximumPixelSize }
    @State private var budgetRetryGeneration: UInt64 = 0
    @State private var loader = RemoteStillImageLoader()
    let thumbnailURL: URL?
    let originalURL: URL?
    let loadsOriginal: Bool
    let contentMode: ContentMode
    let onAspectRatioResolved: ((CGFloat) -> Void)?

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card)
                    .fill(AppDesignSystem.Palette.Accent.surface)
                    .overlay {
                        Image(systemName: "photo").foregroundStyle(
                            AppDesignSystem.Palette.Accent.primary)
                    }
            }
        }
        .onGeometryChange(for: MediaImageViewport.self) {
            [scale = displayScale, fills = contentMode == .fill] geometry in
            MediaImageViewport(size: geometry.size, scale: scale, fills: fills)
        } action: {
            viewport = $0
        }
        .task(
            id: MediaImageLoadIdentity(
                urls: [thumbnailURL, originalURL], environment: ObjectIdentifier(media),
                retryGeneration: media.imageRetryGeneration,
                budgetRetryGeneration: budgetRetryGeneration, pixelSize: pixelSize,
                viewport: viewport)
        ) {
            guard pixelSize > 0 else { return }
            await loader.load(
                thumbnailURL: thumbnailURL, originalURL: originalURL,
                loadsOriginal: loadsOriginal,
                media: media, pixelSize: pixelSize, viewport: viewport,
                onAspectRatioResolved: onAspectRatioResolved
            )
        }
        .onChange(of: media.displayBudget.releaseGeneration) {
            if loader.displayed.waitingForBudget { budgetRetryGeneration &+= 1 }
        }
        .onDisappear { loader.clear() }
    }
}

/// 列表静态图复用已有缓存，低清故障时尝试原图。
public struct RemoteCachedStillImage: View {
    let url: URL?
    let fallbackURL: URL?
    let contentMode: ContentMode
    let onAspectRatioResolved: ((CGFloat) -> Void)?

    public init(
        url: URL?, fallbackURL: URL? = nil, contentMode: ContentMode = .fit,
        onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.contentMode = contentMode
        self.onAspectRatioResolved = onAspectRatioResolved
    }

    public var body: some View {
        RemoteStillImage(
            thumbnailURL: url, originalURL: fallbackURL, loadsOriginal: false,
            contentMode: contentMode, onAspectRatioResolved: onAspectRatioResolved)
    }
}

/// 详情静态图优先展示原图缓存，低清就绪后继续加载原图。
public struct RemoteProgressiveStillImage: View {
    let thumbnailURL: URL?
    let originalURL: URL?
    let contentMode: ContentMode
    let onAspectRatioResolved: ((CGFloat) -> Void)?

    public init(
        thumbnailURL: URL?, originalURL: URL?, contentMode: ContentMode = .fit,
        onAspectRatioResolved: ((CGFloat) -> Void)? = nil
    ) {
        self.thumbnailURL = thumbnailURL
        self.originalURL = originalURL
        self.contentMode = contentMode
        self.onAspectRatioResolved = onAspectRatioResolved
    }

    public var body: some View {
        RemoteStillImage(
            thumbnailURL: thumbnailURL, originalURL: originalURL, loadsOriginal: true,
            contentMode: contentMode, onAspectRatioResolved: onAspectRatioResolved)
    }
}
/// 在后台串行解码话廊缩略图。
///
/// ImageIO 在像素额度内生成显示位图，后台解码和内存缓存沿用同一额度。
actor GalleryThumbnailDecoder {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    private let files: any AppFileService
    func clear() { images.removeAllObjects() }

    init(
        files: any AppFileService,
        maximumDecodedBytes: Int = RemoteImageResourceLimits.maximumDecodedBytes
    ) {
        self.files = files
        images.totalCostLimit = maximumDecodedBytes
    }

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = RemoteImageResourceLimits.maximumDecodedBytes
        return cache
    }()

    func image(
        at file: URL, maximumPixelSize: Int? = nil,
        viewport: MediaImageViewport? = nil
    ) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard let identity = files.atomicFileIdentity(at: file) else { return nil }
        let key =
            """
                \(files.canonicalFileURL(file).path)|\(identity)|pixels:\(maximumPixelSize ?? 0)|\
                \(viewport?.cacheKey ?? "none")
                """
            as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }
        guard let data = RemoteImageResourceLimits.cachedData(at: file, using: files) else {
            return nil
        }
        return decode(data, key: key, maximumPixelSize: maximumPixelSize, viewport: viewport)
    }

    func image(
        from source: RemoteImageSource, maximumPixelSize: Int? = nil,
        viewport: MediaImageViewport? = nil
    ) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        switch source {
        case .file(let file):
            return image(at: file, maximumPixelSize: maximumPixelSize, viewport: viewport)
        case .memory(let data, let identity):
            let key =
                "memory:\(identity)|pixels:\(maximumPixelSize ?? 0)|\(viewport?.cacheKey ?? "none")"
                as NSString
            if let cached = images.object(forKey: key) { return cached }
            return decode(data, key: key, maximumPixelSize: maximumPixelSize, viewport: viewport)
        }
    }

    private func decode(
        _ data: Data, key: NSString, maximumPixelSize: Int?, viewport: MediaImageViewport?
    ) -> UIImage? {
        guard
            let decoded = BoundedStillImageDecoder.image(
                from: data, maximumDecodedBytes: images.totalCostLimit,
                maximumPixelSize: maximumPixelSize, viewport: viewport),
            let pixels = decoded.cgImage
        else { return nil }
        images.setObject(decoded, forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return decoded
    }
}

#endif
