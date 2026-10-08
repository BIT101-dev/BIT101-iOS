#if os(iOS)
import StorageCore
import DesignSystemKit
import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// GIF 原图的后台帧解码器。
///
/// 首页继续自动播放动图，下载后的逐帧 ImageIO 解码在独立 actor 中执行。
/// 串行 actor 将快速滑过多个 GIF 的帧创建排队，有上限的内存缓存复用最近解码结果。
actor RemoteAnimatedImageDecoder {
    private let files: any AppFileService
    func clear() { images.removeAllObjects() }
    private let maximumDecodedBytes: Int

    init(files: any AppFileService, maximumDecodedBytes: Int = 96 * 1_024 * 1_024) {
        self.files = files
        self.maximumDecodedBytes = maximumDecodedBytes
        images.totalCostLimit = maximumDecodedBytes
    }

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    func image(at file: URL, reduceMotion: Bool) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard let data = RemoteImageResourceLimits.cachedData(at: file, using: files) else { return nil }
        let key = "\(SHA256.hash(data: data).description)|reduce-motion:\(reduceMotion)" as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }

        guard let decoded = Self.animatedImage(from: data, reduceMotion: reduceMotion, budget: maximumDecodedBytes) else { return nil }
        let pixelCost = (decoded.images ?? [decoded]).reduce(0) { total, frame in
            let width = Int(frame.size.width * frame.scale)
            let height = Int(frame.size.height * frame.scale)
            return total + width * height * 4
        }
        images.setObject(decoded, forKey: key, cost: max(pixelCost, data.count))
        return decoded
    }

    /// 将 GIF 各帧解码成可由 `UIImageView` 循环播放的动画。
    private nonisolated static func animatedImage(from data: Data, reduceMotion: Bool, budget: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let count = reduceMotion ? min(CGImageSourceGetCount(source), 1) : CGImageSourceGetCount(source)
        let stride = MemoryLayout<UIImage>.stride
        guard count > 0, count < budget / (MemoryLayout<Int>.stride + stride) else { return nil }
        var ticks: [Int] = []
        for index in 0 ..< count {
            let delay = frameDelay(source: source, index: index)
            guard delay.isFinite, delay * 100 < Double(Int.max) else { return nil }
            ticks.append(Int((delay * 100).rounded()))
        }

        // GIF 以百分之一秒记录时长；共同时间片保持各帧比例并复用位图。
        let quantum = ticks.reduce(ticks[0]) { divisor, delay in
            var a = divisor
            var b = delay
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        var expandedCount = 0
        for delay in ticks {
            let (sum, overflow) = expandedCount.addingReportingOverflow(delay / quantum)
            guard !overflow, sum < budget / stride else { return nil }
            expandedCount = sum
        }
        let bookkeepingBytes = count * (MemoryLayout<Int>.stride + stride) + expandedCount * stride
        var pixelBudget = budget - bookkeepingBytes
        guard pixelBudget >= count * 4 else { return nil }
        let perFrameBudget = pixelBudget / count
        var frames: [UIImage] = []
        for index in 0 ..< count {
            guard !Task.isCancelled,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Double,
                  let height = properties[kCGImagePropertyPixelHeight] as? Double,
                  width > 0, height > 0 else { return nil }
            let scale = min(1, (Double(perFrameBudget) / (width * height * 4)).squareRoot())
            let side = max(Int((max(width, height) * scale).rounded(.down)), 1)
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
                  image.bytesPerRow * image.height <= pixelBudget else { return nil }
            pixelBudget -= image.bytesPerRow * image.height
            let frame = UIImage(cgImage: image)
            if count == 1 { return frame }
            frames.append(contentsOf: repeatElement(frame, count: ticks[index] / quantum))
        }
        let duration = ticks.reduce(0.0) { $0 + Double($1) } / 100
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private nonisolated static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return max(unclamped ?? clamped ?? 0.1, 0.02)
    }
}

/// 使用 `UIImageView` 播放话廊中的 GIF 动图。
///
/// SwiftUI 负责容器布局，GIF 原图由 UIKit 播放器处理。
/// 视图离开屏幕后取消任务并停止 `UIImageView` 播放。
struct RemoteAnimatedImage: UIViewRepresentable {
    @Environment(MediaEnvironment.self) private var media
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let url: URL
    let isActive: Bool
    let contentMode: ContentMode
    let cornerRadius: CGFloat

    init(
        url: URL,
        isActive: Bool = true,
        contentMode: ContentMode = .fit,
        cornerRadius: CGFloat = AppDesignSystem.Spacing.none
    ) {
        self.url = url
        self.isActive = isActive
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(media: media)
    }

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = cornerRadius
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.layer.cornerRadius = cornerRadius
        if isActive {
            context.coordinator.load(url: url, into: imageView, media: media, reduceMotion: reduceMotion,
                                     retryGeneration: media.imageRetryGeneration)
        } else {
            context.coordinator.cancel(imageView: imageView)
        }
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: Coordinator) {
        coordinator.cancel(imageView: imageView)
    }

    @MainActor
    final class Coordinator {
        private var media: MediaEnvironment
        init(media: MediaEnvironment) { self.media = media }
        private var currentURL: URL?
        private var currentReduceMotion = false
        private var currentRetryGeneration: UInt64 = 0
        private var requestGeneration: UInt64 = 0
        private var task: Task<Void, Never>?

        func load(url: URL, into imageView: UIImageView, media: MediaEnvironment,
                  reduceMotion: Bool = false, retryGeneration: UInt64 = 0) {
            let sameResource = currentURL == url && self.media === media && currentReduceMotion == reduceMotion
            if sameResource, imageView.image != nil { return }
            if sameResource, currentRetryGeneration == retryGeneration, task != nil { return }
            self.media = media
            currentURL = url
            currentReduceMotion = reduceMotion
            currentRetryGeneration = retryGeneration
            requestGeneration &+= 1
            let generation = requestGeneration
            task?.cancel()
            imageView.stopAnimating()
            imageView.image = nil

            task = Task { [weak self, weak imageView, media] in
                defer { if self?.requestGeneration == generation { self?.task = nil } }
                do {
                    let file = try await media.images.file(for: url, variant: .original)
                    guard !Task.isCancelled else { return }
                    let decoded = await media.animatedDecoder.image(
                        at: file,
                        reduceMotion: reduceMotion
                    )
                    guard !Task.isCancelled, self?.currentURL == url, self?.media === media, let decoded, let imageView else { return }
                    imageView.image = decoded
                    if decoded.images != nil {
                        imageView.startAnimating()
                    }
                } catch {
                    guard !Task.isCancelled, self?.currentURL == url, self?.media === media else { return }
                    // 动图失败时清除播放器状态，话廊继续浏览。
                    imageView?.stopAnimating()
                    imageView?.image = nil
                }
            }
        }

        func cancel(imageView: UIImageView? = nil) {
            requestGeneration &+= 1
            task?.cancel()
            task = nil
            currentURL = nil
            imageView?.stopAnimating()
            imageView?.image = nil
        }

    }
}

/// 播放处于 LazyVStack 活跃区域的 GIF，快速划过时停止对应播放器和解码任务。
/// 屏幕外的动图保持停止，降低 CPU/GPU 消耗。
public struct RemoteAutoplayingImage: View {
    let url: URL
    var contentMode: ContentMode = .fit
    var cornerRadius: CGFloat = AppDesignSystem.Spacing.none
    @State private var isActive = false

    public var body: some View {
        RemoteAnimatedImage(
            url: url,
            isActive: isActive,
            contentMode: contentMode,
            cornerRadius: cornerRadius
        )
            .onAppear { isActive = true }
            .onDisappear { isActive = false }
    }
    public init(url: URL, contentMode: ContentMode = .fit, cornerRadius: CGFloat = AppDesignSystem.Spacing.none) {
        self.url = url
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
    }
}

#endif
