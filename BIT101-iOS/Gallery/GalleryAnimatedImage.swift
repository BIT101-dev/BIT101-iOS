import ImageIO
import SwiftUI
import UIKit

/// GIF 原图的后台帧解码器。
///
/// 首页继续自动播放动图，下载后的逐帧 ImageIO 解码在独立 actor 中执行。
/// 串行 actor 将快速滑过多个 GIF 的帧创建排队，有上限的内存缓存复用最近解码结果。
private actor GalleryAnimatedImageDecoder {
    static let shared = GalleryAnimatedImageDecoder()

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    func image(at file: URL, reduceMotion: Bool) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(file.path)|reduce-motion:\(reduceMotion)" as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }

        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let decoded = Self.animatedImage(from: data, reduceMotion: reduceMotion) else { return nil }
        let pixelCost = (decoded.images ?? [decoded]).reduce(0) { total, frame in
            let width = Int(frame.size.width * frame.scale)
            let height = Int(frame.size.height * frame.scale)
            return total + width * height * 4
        }
        images.setObject(decoded, forKey: key, cost: max(pixelCost, data.count))
        return decoded
    }

    /// 将 GIF 各帧解码成可由 `UIImageView` 循环播放的动画。
    private nonisolated static func animatedImage(from data: Data, reduceMotion: Bool) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let count = CGImageSourceGetCount(source)
        if reduceMotion {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return UIImage(data: data)?.preparingForDisplay()
            }
            return UIImage(cgImage: cgImage).preparingForDisplay()
        }
        guard count > 1 else { return UIImage(data: data)?.preparingForDisplay() }

        var frames: [UIImage] = []
        var totalDuration: TimeInterval = 0
        for index in 0 ..< count {
            guard !Task.isCancelled else { return nil }
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let delay = frameDelay(source: source, index: index)
            // `UIImage.animatedImage` 为每帧分配相同时长；按 20ms 时间片复制帧，
            // 长延时最多保留 10 个时间片，限制异常 GIF 的内存占用。
            let repeats = min(max(Int((delay / 0.02).rounded()), 1), 10)
            let frame = UIImage(cgImage: cgImage)
            frames.append(contentsOf: repeatElement(frame, count: repeats))
            totalDuration += delay
        }

        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(totalDuration, 0.1))
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
struct GalleryAnimatedImage: UIViewRepresentable {
    let url: URL
    let isActive: Bool
    let contentMode: ContentMode
    let cornerRadius: CGFloat

    init(
        url: URL,
        isActive: Bool = true,
        contentMode: ContentMode = .fit,
        cornerRadius: CGFloat = 0
    ) {
        self.url = url
        self.isActive = isActive
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
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
            context.coordinator.load(url: url, into: imageView)
        } else {
            context.coordinator.cancel(imageView: imageView)
        }
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: Coordinator) {
        coordinator.cancel(imageView: imageView)
    }

    @MainActor
    final class Coordinator {
        private var currentURL: URL?
        private var task: Task<Void, Never>?

        func load(url: URL, into imageView: UIImageView) {
            guard currentURL != url else { return }
            currentURL = url
            task?.cancel()
            imageView.stopAnimating()
            imageView.image = nil

            task = Task { [weak self, weak imageView] in
                do {
                    let file = try await GalleryImageCache.shared.file(for: url, variant: .original)
                    guard !Task.isCancelled else { return }
                    let decoded = await GalleryAnimatedImageDecoder.shared.image(
                        at: file,
                        reduceMotion: UIAccessibility.isReduceMotionEnabled
                    )
                    guard !Task.isCancelled, self?.currentURL == url, let decoded, let imageView else { return }
                    imageView.image = decoded
                    if decoded.images != nil {
                        imageView.startAnimating()
                    }
                } catch {
                    guard !Task.isCancelled, self?.currentURL == url else { return }
                    // 动图失败时清除播放器状态，话廊继续浏览。
                    imageView?.stopAnimating()
                    imageView?.image = nil
                }
            }
        }

        func cancel(imageView: UIImageView? = nil) {
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
struct GalleryAutoplayingImage: View {
    let url: URL
    var contentMode: ContentMode = .fit
    var cornerRadius: CGFloat = 0
    @State private var isActive = false

    var body: some View {
        GalleryAnimatedImage(
            url: url,
            isActive: isActive,
            contentMode: contentMode,
            cornerRadius: cornerRadius
        )
            .onAppear { isActive = true }
            .onDisappear { isActive = false }
    }
}
