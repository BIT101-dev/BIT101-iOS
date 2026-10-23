#if os(iOS)
import DesignSystemKit
import Foundation
import Observation
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

    func clear() { displayed.clear(); displayedURL = nil; currentResource = nil }

    func load(thumbnailURL: URL?, originalURL: URL?, loadsOriginal: Bool, media: MediaEnvironment,
        pixelSize: Int, onAspectRatioResolved: ((CGFloat) -> Void)? = nil) async {
        let urls = mediaImageURLs([thumbnailURL, originalURL])
        let resource = MediaImageLoadIdentity(urls: urls.map(Optional.some), environment: ObjectIdentifier(media), pixelSize: pixelSize)
        if currentResource != resource { clear(); currentResource = resource }
        let original = originalURL.map { HTTPSURLUpgrade.upgradedURL(from: $0) } ?? urls.first
        if image != nil && (!loadsOriginal || displayedURL == original) { return }
        func isCurrent() -> Bool { !Task.isCancelled && currentResource == resource }
        func display(_ image: UIImage, url: URL) -> Bool {
            guard displayed.set(image, budget: media.displayBudget) else { return false }
            displayedURL = url
            if image.size.height > 0 { onAspectRatioResolved?(image.size.width / image.size.height) }
            return true
        }

        for url in urls.reversed() {
            let cached: UIImage?? = try? await media.images.withCachedSource(for: url) { @MainActor source in
                await media.stillDecoder.image(from: source, maximumPixelSize: pixelSize)
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
                    await media.stillDecoder.image(from: source, maximumPixelSize: pixelSize)
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
    @State private var pixelSize = 0
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
                    .overlay { Image(systemName: "photo").foregroundStyle(AppDesignSystem.Palette.Accent.primary) }
            }
        }
        .onGeometryChange(for: Int.self) { [scale = displayScale] geometry in
            Int((max(geometry.size.width, geometry.size.height) * scale).rounded(.up))
        } action: { pixelSize = $0 }
        .task(id: MediaImageLoadIdentity(urls: [thumbnailURL, originalURL], environment: ObjectIdentifier(media),
            retryGeneration: media.imageRetryGeneration, budgetRetryGeneration: budgetRetryGeneration, pixelSize: pixelSize)) {
            guard pixelSize > 0 else { return }
            await loader.load(thumbnailURL: thumbnailURL, originalURL: originalURL, loadsOriginal: loadsOriginal,
                media: media, pixelSize: pixelSize, onAspectRatioResolved: onAspectRatioResolved)
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

    public init(url: URL?, fallbackURL: URL? = nil, contentMode: ContentMode = .fit,
        onAspectRatioResolved: ((CGFloat) -> Void)? = nil) {
        self.url = url; self.fallbackURL = fallbackURL; self.contentMode = contentMode
        self.onAspectRatioResolved = onAspectRatioResolved
    }

    public var body: some View {
        RemoteStillImage(thumbnailURL: url, originalURL: fallbackURL, loadsOriginal: false,
            contentMode: contentMode, onAspectRatioResolved: onAspectRatioResolved)
    }
}

/// 详情静态图优先展示原图缓存，低清就绪后继续加载原图。
public struct RemoteProgressiveStillImage: View {
    let thumbnailURL: URL?
    let originalURL: URL?
    let contentMode: ContentMode
    let onAspectRatioResolved: ((CGFloat) -> Void)?

    public init(thumbnailURL: URL?, originalURL: URL?, contentMode: ContentMode = .fit,
        onAspectRatioResolved: ((CGFloat) -> Void)? = nil) {
        self.thumbnailURL = thumbnailURL; self.originalURL = originalURL; self.contentMode = contentMode
        self.onAspectRatioResolved = onAspectRatioResolved
    }

    public var body: some View {
        RemoteStillImage(thumbnailURL: thumbnailURL, originalURL: originalURL, loadsOriginal: true,
            contentMode: contentMode, onAspectRatioResolved: onAspectRatioResolved)
    }
}
#endif
