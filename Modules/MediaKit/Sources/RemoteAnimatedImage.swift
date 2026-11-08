#if os(iOS)
import StorageCore
import DesignSystemKit
import ImageIO
import SwiftUI
import UIKit

/// GIF 原图的后台帧解码器，缓存编码数据并按播放时刻读取单帧。
actor RemoteAnimatedImageDecoder {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    private let files: any AppFileService
    private let maximumDecodedBytes: Int
    private let sequences = NSCache<NSString, RemoteImageSequence>()

    init(
        files: any AppFileService,
        maximumDecodedBytes: Int = RemoteImageResourceLimits.maximumDecodedBytes / 2
    ) {
        self.files = files
        self.maximumDecodedBytes = maximumDecodedBytes
        sequences.countLimit = 8
        sequences.totalCostLimit = RemoteImageResourceLimits.maximumEncodedBytes
    }

    func clear() { sequences.removeAllObjects() }

    func sequence(
        at file: URL, maximumPixelSize: Int? = nil, viewport: MediaImageViewport? = nil
    ) -> RemoteImageSequence? {
        guard !Task.isCancelled, let identity = files.atomicFileIdentity(at: file) else {
            return nil
        }
        let key =
            "\(files.canonicalFileURL(file).path)|\(identity)|\(maximumPixelSize ?? 0)"
            + "|\(viewport?.cacheKey ?? "none")"
        if let cached = sequences.object(forKey: key as NSString) { return cached }
        guard let data = RemoteImageResourceLimits.cachedData(at: file, using: files) else {
            return nil
        }
        return decode(
            data, key: key as NSString, maximumPixelSize: maximumPixelSize, viewport: viewport)
    }

    func sequence(
        from resource: RemoteImageSource, maximumPixelSize: Int? = nil,
        viewport: MediaImageViewport? = nil
    ) -> RemoteImageSequence? {
        guard !Task.isCancelled else { return nil }
        switch resource {
        case .file(let file):
            return sequence(at: file, maximumPixelSize: maximumPixelSize, viewport: viewport)
        case .memory(let data, let identity):
            let key =
                "memory:\(identity)|\(maximumPixelSize ?? 0)|\(viewport?.cacheKey ?? "none")"
                as NSString
            if let cached = sequences.object(forKey: key) { return cached }
            return decode(data, key: key, maximumPixelSize: maximumPixelSize, viewport: viewport)
        }
    }

    private func decode(
        _ data: Data, key: NSString, maximumPixelSize: Int?, viewport: MediaImageViewport?
    ) -> RemoteImageSequence? {
        guard !Task.isCancelled,
            let sequence = RemoteImageSequence(
                data: data, maximumDecodedBytes: maximumDecodedBytes,
                maximumPixelSize: maximumPixelSize, viewport: viewport)
        else { return nil }
        sequences.setObject(sequence, forKey: key, cost: data.count)
        return sequence
    }
}

/// 按播放时刻读取一帧，显示精度与整段动图的帧数无关。
actor RemoteImageSequence {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    nonisolated let count: Int
    private let source: CGImageSource
    private let maximumDecodedBytes: Int
    private let maximumPixelSize: Int?
    private let viewport: MediaImageViewport?

    init?(
        data: Data, maximumDecodedBytes: Int, maximumPixelSize: Int?,
        viewport: MediaImageViewport?
    ) {
        guard let source = RemoteImageResourceLimits.completeImageSource(from: data),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        self.source = source
        count = CGImageSourceGetCount(source)
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumPixelSize = maximumPixelSize
        self.viewport = viewport
    }

    nonisolated struct Frame: Sendable {
        let image: UIImage
        let duration: TimeInterval
    }

    func frame(at index: Int) -> Frame? {
        guard (0..<count).contains(index), !Task.isCancelled,
            let image = BoundedStillImageDecoder.image(
                from: source, at: index, maximumDecodedBytes: maximumDecodedBytes,
                maximumPixelSize: maximumPixelSize, viewport: viewport)
        else { return nil }
        return Frame(
            image: image, duration: frameDelay(at: index))
    }
    private func frameDelay(at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay.isFinite ? max(delay, 0.02) : 0.1
    }

}

enum RemoteAnimatedImagePhase { case loading, ready, failed }

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
    let maximumPixelSize: Int?
    let viewport: MediaImageViewport?
    let onPhaseChange: (@MainActor (RemoteAnimatedImagePhase) -> Void)?

    init(
        url: URL,
        isActive: Bool = true,
        contentMode: ContentMode = .fit,
        cornerRadius: CGFloat = AppDesignSystem.Spacing.none,
        maximumPixelSize: Int? = nil, viewport: MediaImageViewport? = nil,
        onPhaseChange: (@MainActor (RemoteAnimatedImagePhase) -> Void)? = nil
    ) {
        self.url = url
        self.isActive = isActive
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.maximumPixelSize = maximumPixelSize
        self.viewport = viewport
        self.onPhaseChange = onPhaseChange
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
        if isActive, maximumPixelSize != 0 {
            context.coordinator.load(
                url: url, into: imageView, media: media, reduceMotion: reduceMotion,
                retryGeneration: media.imageRetryGeneration,
                budgetGeneration: media.displayBudget.releaseGeneration,
                maximumPixelSize: maximumPixelSize, viewport: viewport, onPhaseChange: onPhaseChange
            )
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
        private var currentBudgetGeneration: UInt64 = 0
        private var currentPixelSize: Int?
        private var currentViewport: MediaImageViewport?
        private let displayed = MediaDisplayedImage()
        private var requestGeneration: UInt64 = 0
        private var task: Task<Void, Never>?

        func load(
            url: URL, into imageView: UIImageView, media: MediaEnvironment,
            reduceMotion: Bool = false, retryGeneration: UInt64 = 0,
            budgetGeneration: UInt64 = 0, maximumPixelSize: Int? = nil,
            viewport: MediaImageViewport? = nil,
            onPhaseChange: (@MainActor (RemoteAnimatedImagePhase) -> Void)? = nil
        ) {
            let sameResource =
                currentURL == url && self.media === media && currentReduceMotion == reduceMotion
                && currentPixelSize == maximumPixelSize && currentViewport == viewport
            if sameResource, imageView.image != nil { return }
            if sameResource, currentRetryGeneration == retryGeneration,
                !displayed.waitingForBudget || currentBudgetGeneration == budgetGeneration
            {
                return
            }
            self.media = media
            currentURL = url
            currentReduceMotion = reduceMotion
            currentPixelSize = maximumPixelSize
            currentViewport = viewport
            currentRetryGeneration = retryGeneration
            currentBudgetGeneration = budgetGeneration
            requestGeneration &+= 1
            let generation = requestGeneration
            task?.cancel()
            imageView.stopAnimating()
            imageView.image = nil
            displayed.clear()

            task = Task { [weak self, weak imageView, media] in
                var didLoadImage = false
                defer {
                    if self?.requestGeneration == generation {
                        self?.task = nil
                        if !Task.isCancelled, !didLoadImage { onPhaseChange?(.failed) }
                    }
                }
                onPhaseChange?(.loading)
                do {
                    try await Self.play(
                        url: url, media: media, reduceMotion: reduceMotion,
                        maximumPixelSize: maximumPixelSize, viewport: viewport
                    ) { frame in
                        guard self?.requestGeneration == generation, let imageView,
                            self?.displayed.set(frame, budget: media.displayBudget) == true
                        else { return false }
                        imageView.image = frame
                        if !didLoadImage { onPhaseChange?(.ready) }
                        didLoadImage = true
                        return true
                    }
                } catch {
                    guard !Task.isCancelled, self?.currentURL == url, self?.media === media
                    else { return }
                    imageView?.stopAnimating()
                    imageView?.image = nil
                }
            }
        }

        private static func play(
            url: URL, media: MediaEnvironment, reduceMotion: Bool,
            maximumPixelSize: Int?, viewport: MediaImageViewport?,
            receive: @escaping @MainActor (UIImage) -> Bool
        ) async throws {
            try await media.images.withSource(for: url) { @MainActor source in
                guard
                    let sequence = await media.animatedDecoder.sequence(
                        from: source, maximumPixelSize: maximumPixelSize, viewport: viewport)
                else { return }
                var index = 0
                while !Task.isCancelled {
                    let started = ContinuousClock.now
                    guard let frame = await sequence.frame(at: index), receive(frame.image)
                    else { return }
                    if reduceMotion || sequence.count == 1 { return }
                    index = (index + 1) % sequence.count
                    try await ContinuousClock().sleep(until: started + .seconds(frame.duration))
                }
            }
        }

        func cancel(imageView: UIImageView? = nil) {
            requestGeneration &+= 1
            task?.cancel()
            task = nil
            currentURL = nil
            displayed.clear()
            imageView?.stopAnimating()
            imageView?.image = nil
        }

    }
}

/// 根据滚动容器内的实际可见区域启停 GIF 播放和解码任务。
public struct RemoteAutoplayingImage: View {
    @Environment(\.displayScale) private var displayScale
    let url: URL
    let fallbackURL: URL?
    var contentMode: ContentMode = .fit
    var cornerRadius: CGFloat = AppDesignSystem.Spacing.none
    @State private var isActive = false
    @State private var isVisible = false
    @State private var viewport = MediaImageViewport.zero
    private var pixelSize: Int { viewport.maximumPixelSize }
    @State private var phase = RemoteAnimatedImagePhase.loading

    public var body: some View {
        ZStack {
            if isActive, phase != .ready {
                RemoteCachedStillImage(
                    url: fallbackURL ?? url, fallbackURL: url, contentMode: contentMode
                )
                .clipShape(AppDesignSystem.roundedRectangle(cornerRadius))
            }
            RemoteAnimatedImage(
                url: url,
                isActive: isActive,
                contentMode: contentMode,
                cornerRadius: cornerRadius,
                maximumPixelSize: pixelSize, viewport: viewport,
                onPhaseChange: { phase = $0 }
            )
            if isActive, phase == .loading { ProgressView().controlSize(.small) }
        }
        .onGeometryChange(for: Bool.self) { geometry in
            let image = CGRect(origin: .zero, size: geometry.size)
            return image.intersects(geometry.bounds(of: .scrollView) ?? image)
        } action: { visible in
            isVisible = visible
            isActive = visible
            if !visible { phase = .loading }
        }
        .onAppear { isActive = isVisible }
        .onDisappear {
            isActive = false
            phase = .loading
        }
        .onGeometryChange(for: MediaImageViewport.self) {
            [scale = displayScale, fills = contentMode == .fill] geometry in
            MediaImageViewport(size: geometry.size, scale: scale, fills: fills)
        } action: {
            viewport = $0
        }
    }
    public init(
        url: URL, fallbackURL: URL? = nil, contentMode: ContentMode = .fit,
        cornerRadius: CGFloat = AppDesignSystem.Spacing.none
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
    }
}

#endif
