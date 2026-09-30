import Foundation

/// 远程图片预览所需的下载地址。
public nonisolated struct RemotePreviewImage: Equatable, Sendable {
    public let thumbnailURL: URL?
    public let originalURL: URL?

    public init(thumbnailURL: URL?, originalURL: URL?) {
        self.thumbnailURL = thumbnailURL
        self.originalURL = originalURL
    }
}

#if os(iOS)
import DesignSystemKit
import QuickLook
import SwiftUI
import UIKit

/// 一次系统图片预览请求。
public struct ImagePreviewRequest: Identifiable {
    fileprivate enum Source {
        case remote([RemotePreviewImage])
        case local([UIImage])
    }

    public let id = UUID()
    fileprivate let source: Source
    let initialIndex: Int

    public init(remoteImages: [RemotePreviewImage], initialIndex: Int) {
        source = .remote(remoteImages)
        self.initialIndex = initialIndex
    }

    public init(localImages: [UIImage], initialIndex: Int) {
        source = .local(localImages)
        self.initialIndex = initialIndex
    }
}

extension View {
    /// 直接从当前页面呈现系统 Quick Look，不增加自定义“正在准备”中间页。
    public func systemImagePreview(item: Binding<ImagePreviewRequest?>) -> some View {
        background(ImageQuickLookPresenter(viewer: item).frame(width: AppDesignSystem.Spacing.none, height: AppDesignSystem.Spacing.none))
    }
}

/// 挂在现有页面上的 UIKit 呈现锚点。
///
/// 相比 SwiftUI `.quickLookPreview`，`QLPreviewController` 允许预览期间刷新数据源，
/// 因而可以先显示低清缓存，再在同一预览器内原地替换成高清文件。
private struct ImageQuickLookPresenter: UIViewControllerRepresentable {
    @Environment(MediaEnvironment.self) private var media
    @Binding var viewer: ImagePreviewRequest?

    func makeCoordinator() -> Coordinator {
        Coordinator(media: media)
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
        private let media: MediaEnvironment
        init(media: MediaEnvironment) { self.media = media }
        private var requestID: UUID?
        private var pendingRequest: ImagePreviewRequest?
        private var preparationTask: Task<Void, Never>?
        private var upgradeTask: Task<Void, Never>?
        private var previewController: QLPreviewController?
        private var placeholderURL: URL?
        private var items: [MutableQuickLookItem] = []
        private var isPreviewPresentationComplete = false
        private var pendingCurrentRefresh = false
        var onDismiss: (() -> Void)?

        func receive(_ request: ImagePreviewRequest?, from host: HostViewController) {
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

        /// 用户点击的图片先准备可读文件；其它图片使用缓存或占位，高清资源在预览展示后继续准备。
        private func prepareInitialItems(
            for request: ImagePreviewRequest
        ) async throws -> (items: [MutableQuickLookItem], initialIndex: Int) {
            switch request.source {
            case let .local(images):
                var prepared: [MutableQuickLookItem] = []
                var sourceIndexes: [Int] = []
                for (index, image) in images.enumerated() {
                    try Task.checkCancellation()
                    guard let data = image.pngData() else { continue }
                    let cached = try await media.images.localFile(data: data)
                    let file = try await media.previewFile(at: cached)
                    prepared.append(MutableQuickLookItem(url: file))
                    sourceIndexes.append(index)
                }
                guard !prepared.isEmpty else { throw QuickLookPreparationError.noImages }
                let requestedIndex = min(max(request.initialIndex, 0), images.count - 1)
                let preparedIndex = sourceIndexes.firstIndex(of: requestedIndex)
                    ?? sourceIndexes.firstIndex(where: { $0 > requestedIndex })
                    ?? prepared.count - 1
                return (prepared, preparedIndex)

            case let .remote(images):
                guard !images.isEmpty else { throw QuickLookPreparationError.noImages }
                let initialIndex = min(max(request.initialIndex, 0), images.count - 1)
                let cachedPlaceholder = try await media.images.placeholderFile()
                let placeholder = try await media.previewFile(at: cachedPlaceholder)
                placeholderURL = placeholder
                let prepared = images.map { _ in MutableQuickLookItem(url: placeholder) }

                let initialImage = images[initialIndex]
                let highURL = initialImage.originalURL
                if let highURL,
                   let high = await media.images.cachedFile(for: highURL, variant: .original) {
                    prepared[initialIndex].url = try await media.previewFile(at: high)
                } else if let lowURL = initialImage.thumbnailURL {
                    // 先查询已展示缩略图的统一缓存，当前图片优先进入系统预览。
                    if let cached = await media.images.cachedFile(
                        for: lowURL,
                        variant: .thumbnail
                    ) {
                        prepared[initialIndex].url = try await media.previewFile(at: cached)
                    } else if let lowFile = try? await media.images.file(
                        for: lowURL,
                        variant: .thumbnail
                    ) {
                        // 极少数情况下，用户可能在图片尚未加载完成时立即点击；只有
                        // 这种缓存确实缺失的场景才兜底下载当前缩略图。
                        prepared[initialIndex].url = try await media.previewFile(at: lowFile)
                    } else if let highURL {
                        // 缩略图服务异常时仍尝试原图，避免高清图可用却因低清失败而
                        // 直接关闭系统预览。
                        let cached = try await media.images.file(for: highURL, variant: .original)
                        prepared[initialIndex].url = try await media.previewFile(at: cached)
                    }
                } else if let highURL {
                    let cached = try await media.images.file(for: highURL, variant: .original)
                    prepared[initialIndex].url = try await media.previewFile(at: cached)
                }
                return (prepared, initialIndex)
            }
        }

        /// 当前图优先升级高清，其余图片随后逐张补低清并缓存高清。
        private func upgradeRemoteItems(for request: ImagePreviewRequest, initialIndex: Int) async {
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
                   items[index].url == placeholderURL,
                   let lowURL = image.thumbnailURL,
                   let lowFile = try? await media.images.file(for: lowURL, variant: .thumbnail) {
                    guard let preview = try? await media.previewFile(at: lowFile) else { continue }
                    guard !Task.isCancelled, requestID == request.id, items.indices.contains(index) else { return }
                    items[index].url = preview
                }
            }
            await currentUpgrade

            for index in remainingIndices {
                guard !Task.isCancelled, requestID == request.id, images.indices.contains(index) else { return }
                await upgradeOriginal(images[index], at: index, requestID: request.id)
            }
        }

        private func upgradeOriginal(_ image: RemotePreviewImage, at index: Int, requestID expectedID: UUID) async {
            guard let highURL = image.originalURL else { return }
            guard let highFile = try? await media.images.file(for: highURL, variant: .original) else {
                return
            }
            guard let preview = try? await media.previewFile(at: highFile) else { return }
            guard !Task.isCancelled, requestID == expectedID, items.indices.contains(index) else { return }
            items[index].url = preview

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
        /// 系统重建当前预览时偶尔出现明显闪白。系统预览器保持原样；刷新时叠加一层
        /// 不接收触摸的画面快照，让低清到高清更接近一次轻微交叉渐变。
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

/// 兼容服务端返回的十六进制颜色字符串。
extension Color {
    public init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

#endif
