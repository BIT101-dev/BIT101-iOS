import QuickLook
import SwiftUI
import UIKit

/// 一次系统图片预览请求。
struct GalleryImageViewerState: Identifiable {
    fileprivate enum Source {
        case remote([GalleryImage])
        case local([UIImage])
    }

    let id = UUID()
    fileprivate let source: Source
    let initialIndex: Int

    init(images: [GalleryImage], initialIndex: Int) {
        source = .remote(images)
        self.initialIndex = initialIndex
    }

    init(localImages: [UIImage], initialIndex: Int) {
        source = .local(localImages)
        self.initialIndex = initialIndex
    }
}

extension View {
    /// 直接从当前页面呈现系统 Quick Look，不增加自定义“正在准备”中间页。
    func gallerySystemImagePreview(item: Binding<GalleryImageViewerState?>) -> some View {
        background(GalleryQuickLookPresenter(viewer: item).frame(width: 0, height: 0))
    }
}

/// 挂在现有页面上的 UIKit 呈现锚点。
///
/// 相比 SwiftUI `.quickLookPreview`，`QLPreviewController` 允许预览期间刷新数据源，
/// 因而可以先显示低清缓存，再在同一预览器内原地替换成高清文件。
private struct GalleryQuickLookPresenter: UIViewControllerRepresentable {
    @Binding var viewer: GalleryImageViewerState?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> HostViewController {
        let controller = HostViewController()
        controller.onReady = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            coordinator.presentPendingIfPossible(from: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: HostViewController, context: Context) {
        context.coordinator.onDismiss = { viewer = nil }
        context.coordinator.receive(viewer, from: controller)
    }

    static func dismantleUIViewController(_ controller: HostViewController, coordinator: Coordinator) {
        coordinator.cancel()
    }

    final class HostViewController: UIViewController {
        var onReady: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onReady?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private var requestID: UUID?
        private var pendingRequest: GalleryImageViewerState?
        private var preparationTask: Task<Void, Never>?
        private var upgradeTask: Task<Void, Never>?
        private var previewController: QLPreviewController?
        private var items: [MutableQuickLookItem] = []
        private var isPreviewPresentationComplete = false
        private var pendingCurrentRefresh = false
        var onDismiss: (() -> Void)?

        func receive(_ request: GalleryImageViewerState?, from host: HostViewController) {
            guard let request else {
                if previewController == nil { cancel() }
                return
            }
            guard request.id != requestID else { return }
            cancel()
            requestID = request.id
            pendingRequest = request
            presentPendingIfPossible(from: host)
        }

        func presentPendingIfPossible(from host: HostViewController) {
            guard host.viewIfLoaded?.window != nil, let request = pendingRequest else { return }
            pendingRequest = nil
            preparationTask = Task { [weak self, weak host] in
                guard let self, let host else { return }
                do {
                    let prepared = try await prepareInitialItems(for: request)
                    guard !Task.isCancelled, requestID == request.id else { return }
                    items = prepared.items

                    let controller = QLPreviewController()
                    controller.dataSource = self
                    controller.delegate = self
                    controller.currentPreviewItemIndex = prepared.initialIndex
                    previewController = controller
                    isPreviewPresentationComplete = false
                    host.present(controller, animated: true) { [weak self] in
                        guard let self else { return }
                        isPreviewPresentationComplete = true
                        if pendingCurrentRefresh {
                            pendingCurrentRefresh = false
                            refreshCurrentPreviewItemSmoothly()
                        }
                    }

                    upgradeTask = Task { [weak self] in
                        await self?.upgradeRemoteItems(for: request, initialIndex: prepared.initialIndex)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    onDismiss?()
                    cancel()
                }
            }
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            items.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            items[index]
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onDismiss?()
            cancel()
        }

        func cancel() {
            preparationTask?.cancel()
            upgradeTask?.cancel()
            preparationTask = nil
            upgradeTask = nil
            pendingRequest = nil
            requestID = nil
            items = []
            previewController = nil
            isPreviewPresentationComplete = false
            pendingCurrentRefresh = false
        }

        /// 只保证用户点击的图片已有可读文件；其它图片优先复用缓存，否则暂用占位。
        /// 因此不会再等待整个帖子所有高清图下载完成后才打开预览。
        private func prepareInitialItems(
            for request: GalleryImageViewerState
        ) async throws -> (items: [MutableQuickLookItem], initialIndex: Int) {
            switch request.source {
            case let .local(images):
                var prepared: [MutableQuickLookItem] = []
                for image in images {
                    try Task.checkCancellation()
                    guard let data = image.pngData() else { continue }
                    let file = try await GalleryImageCache.shared.localFile(data: data)
                    prepared.append(MutableQuickLookItem(url: file))
                }
                guard !prepared.isEmpty else { throw QuickLookPreparationError.noImages }
                return (prepared, min(max(request.initialIndex, 0), prepared.count - 1))

            case let .remote(images):
                guard !images.isEmpty else { throw QuickLookPreparationError.noImages }
                let initialIndex = min(max(request.initialIndex, 0), images.count - 1)
                let placeholder = try await GalleryImageCache.shared.placeholderFile()
                let prepared = images.map { _ in MutableQuickLookItem(url: placeholder) }

                let initialImage = images[initialIndex]
                if let highURL = originalURL(for: initialImage),
                   let high = await GalleryImageCache.shared.cachedFile(for: highURL, variant: .original) {
                    prepared[initialIndex].url = high
                } else if let lowURL = thumbnailURL(for: initialImage) {
                    // 首页已经展示过的缩略图必然已进入统一磁盘缓存；点击时只做
                    // 一次缓存查询，不重新编码图片，也不等待帖子内其它图片。
                    prepared[initialIndex].url = if let cached = await GalleryImageCache.shared.cachedFile(
                        for: lowURL,
                        variant: .thumbnail
                    ) {
                        cached
                    } else {
                        // 极少数情况下，用户可能在图片尚未加载完成时立即点击；只有
                        // 这种缓存确实缺失的场景才兜底下载当前缩略图。
                        try await GalleryImageCache.shared.file(for: lowURL, variant: .thumbnail)
                    }
                } else if let highURL = originalURL(for: initialImage) {
                    prepared[initialIndex].url = try await GalleryImageCache.shared.file(
                        for: highURL,
                        variant: .original
                    )
                }
                return (prepared, initialIndex)
            }
        }

        /// 当前图优先升级高清，其余图片随后逐张补低清并缓存高清。
        private func upgradeRemoteItems(for request: GalleryImageViewerState, initialIndex: Int) async {
            guard case let .remote(images) = request.source else { return }
            let remainingIndices = images.indices.filter { $0 != initialIndex }

            // 当前高清下载与其它页低清补齐并行，既尽快让当前画面变清晰，也避免用户
            // 在高清大图下载期间左右滑动时看到透明占位。
            async let currentUpgrade: Void = upgradeOriginal(
                images[initialIndex],
                at: initialIndex,
                requestID: request.id
            )

            for index in remainingIndices {
                guard !Task.isCancelled, requestID == request.id else { return }
                let image = images[index]
                if items.indices.contains(index),
                   items[index].url.lastPathComponent == "preview-placeholder.png",
                   let lowURL = thumbnailURL(for: image),
                   let lowFile = try? await GalleryImageCache.shared.file(for: lowURL, variant: .thumbnail) {
                    items[index].url = lowFile
                }
            }
            await currentUpgrade

            for index in remainingIndices {
                guard !Task.isCancelled, requestID == request.id, images.indices.contains(index) else { return }
                await upgradeOriginal(images[index], at: index, requestID: request.id)
            }
        }

        private func upgradeOriginal(_ image: GalleryImage, at index: Int, requestID expectedID: UUID) async {
            guard let highURL = originalURL(for: image) else { return }
            guard let highFile = try? await GalleryImageCache.shared.file(for: highURL, variant: .original) else {
                return
            }
            guard !Task.isCancelled, requestID == expectedID, items.indices.contains(index) else { return }
            items[index].url = highFile

            if previewController?.currentPreviewItemIndex == index {
                if isPreviewPresentationComplete {
                    refreshCurrentPreviewItemSmoothly()
                } else {
                    // 高清在系统入场动画完成前就已就绪时，只更新数据源，延后视觉刷新。
                    // 避免给正在从底部上移的控制器截图，造成动画中途像被“按住”一下。
                    pendingCurrentRefresh = true
                }
            }
        }

        /// 用当前低清画面的快照盖住 Quick Look 重新载入文件时的短暂空白，再快速淡出。
        ///
        /// Quick Look 没有公开的渐进式换图接口，直接 `refreshCurrentPreviewItem()` 会由
        /// 系统重建当前预览，偶尔出现明显闪白。这里不改变系统预览器本身，只为这次刷新
        /// 加一层不接收触摸的旧画面快照，让低清到高清更接近一次轻微交叉渐变。
        private func refreshCurrentPreviewItemSmoothly() {
            guard let controller = previewController else { return }
            guard let snapshot = controller.view.snapshotView(afterScreenUpdates: false) else {
                controller.refreshCurrentPreviewItem()
                return
            }

            snapshot.isUserInteractionEnabled = false
            snapshot.frame = controller.view.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(snapshot)
            controller.refreshCurrentPreviewItem()

            UIView.animate(
                withDuration: 0.5,
                delay: 0.10,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }

        private func originalURL(for image: GalleryImage) -> URL? {
            URL(string: image.url.isEmpty ? image.lowUrl : image.url)
        }

        private func thumbnailURL(for image: GalleryImage) -> URL? {
            URL(string: image.lowUrl.isEmpty ? image.url : image.lowUrl)
        }
    }
}

/// Quick Look 会在需要时重新读取该对象的 URL，因此高清下载完成后可以原地替换。
private final class MutableQuickLookItem: NSObject, QLPreviewItem {
    var url: URL
    var previewItemTitle: String? { nil }
    var previewItemURL: URL? { url }

    init(url: URL) {
        self.url = url
    }
}

private enum QuickLookPreparationError: LocalizedError {
    case noImages

    var errorDescription: String? {
        "没有可供预览的图片。"
    }
}

/// 帖子时间文本格式化工具。
///
/// 服务端历史上使用过多种时间格式，这里集中做兼容，避免每个视图各自维护
/// 一套 `DateFormatter`。
enum GalleryDateDecoder {
    private static let formatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
    ]

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter = RelativeDateTimeFormatter()

    static func date(from string: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return iso8601Formatter.date(from: string)
    }

    static func relativeText(from string: String, fallback: String) -> String {
        guard let date = date(from: string) else { return fallback }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter
    }
}

/// 兼容服务端返回的十六进制颜色字符串。
extension Color {
    init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
