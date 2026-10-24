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
import OSLog
import os
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
struct ImageQuickLookPresenter: UIViewControllerRepresentable {
    @Environment(MediaEnvironment.self) private var media
    @Environment(\.appDiagnosticAlert) private var presentAlert
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
        context.coordinator.onFailure = { error in
            presentAlert?(AppAlert(title: "图片预览失败", error: error))
        }
        context.coordinator.receive(viewer, from: controller, media: media)
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
        private var media: MediaEnvironment
        private let makePreviewController: () -> QLPreviewController
        private static let logger = Logger(subsystem: "BIT101", category: "ImagePreview")
        init(media: MediaEnvironment, makePreviewController: @escaping () -> QLPreviewController = { QLPreviewController() }) {
            self.media = media
            self.makePreviewController = makePreviewController
        }
        private var requestID: UUID?
        private var pendingRequest: ImagePreviewRequest?
        private var preparationTask: Task<Void, Never>?
        private var upgradeTask: Task<Void, Never>?
        private var originalTasks: [Int: Task<Void, Never>] = [:]
        private var retryTask: Task<Void, Never>?
        private var selectionObservation: NSKeyValueObservation?
        private var activeRequest: ImagePreviewRequest?
        private var failures: [Int: any Error] = [:]
        private var failureGenerations: [Int: UInt64] = [:]
        private var reportedFailures: Set<Int> = []
        private let loadingIndicator = UIActivityIndicatorView(style: .medium)
        private lazy var retryButton: UIBarButtonItem = {
            let button = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(retryCurrentImage))
            button.accessibilityIdentifier = "media.preview.retry"
            button.accessibilityLabel = "重新加载图片"
            return button
        }()
        private var previewController: QLPreviewController?
        private var placeholderURL: URL?
        private var items: [MutableQuickLookItem] = []
        private var isPreviewPresentationComplete = false
        private var pendingCurrentRefresh = false
        var onDismiss: (() -> Void)?
        var onFailure: ((any Error) -> Void)?

        func receive(_ request: ImagePreviewRequest?, from host: HostViewController, media: MediaEnvironment) {
            if self.media !== media {
                cancel()
                self.media = media
            }
            guard let request else {
                cancel()
                return
            }
            let retryGeneration = media.imageRetryGeneration
            guard request.id != requestID else {
                if let index = previewController?.currentPreviewItemIndex,
                   failures[index] != nil, failureGenerations[index] != retryGeneration {
                    retryCurrentImage()
                }
                return
            }
            cancel()
            requestID = request.id
            activeRequest = request
            media.beginPreview(owner: request.id)
            pendingRequest = request
            presentPendingIfPossible(from: host)
        }

        func presentPendingIfPossible(from host: HostViewController) {
            guard host.viewIfLoaded?.window != nil, let request = pendingRequest else { return }
            pendingRequest = nil
            preparationTask = Task { [weak self, weak host, media] in
                guard let self, let host else { return }
                do {
                    let prepared = try await prepareInitialItems(for: request, media: media)
                    guard !Task.isCancelled, requestID == request.id, self.media === media else { return }
                    items = prepared.items

                    let controller = makePreviewController()
                    controller.dataSource = self
                    controller.delegate = self
                    controller.currentPreviewItemIndex = prepared.initialIndex
                    previewController = controller
                    controller.modalPresentationStyle = .fullScreen
                    let close = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(closePreview))
                    close.accessibilityIdentifier = "media.preview.close"
                    controller.navigationItem.leftBarButtonItem = close
                    loadingIndicator.accessibilityLabel = "正在加载图片"
                    updateRetryButton()
                    let observedRequestID = request.id
                    selectionObservation = controller.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] _, change in
                        guard let index = change.newValue else { return }
                        Task { @MainActor [weak self] in self?.selectionDidChange(index, requestID: observedRequestID) }
                    }
                    isPreviewPresentationComplete = false
                    host.present(controller, animated: true) { [weak self, weak controller] in
                        guard let self, let controller, self.previewController === controller, self.media === media else { return }
                        isPreviewPresentationComplete = true
                        if pendingCurrentRefresh {
                            pendingCurrentRefresh = false
                            refreshCurrentPreviewItemSmoothly()
                        }
                        selectionDidChange(controller.currentPreviewItemIndex, requestID: request.id)
                    }

                    upgradeTask = Task { [weak self, media] in
                        if case .local = request.source {
                            await self?.prepareRemainingLocalItems(for: request, initialIndex: prepared.initialIndex, media: media)
                        } else {
                            await self?.upgradeRemoteItems(for: request, initialIndex: prepared.initialIndex, media: media)
                        }
                    }
                } catch {
                    guard !Task.isCancelled, requestID == request.id, self.media === media else { return }
                    onDismiss?()
                    cancel()
                    reportFailure(error)
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
            guard controller === previewController else { return }
            onDismiss?()
            cancel()
        }

        func cancel() {
            preparationTask?.cancel()
            upgradeTask?.cancel()
            for task in originalTasks.values { task.cancel() }
            originalTasks.removeAll()
            retryTask?.cancel()
            selectionObservation?.invalidate()
            selectionObservation = nil
            if let requestID { media.endPreview(owner: requestID) }
            let controller = previewController
            previewController = nil
            controller?.dataSource = nil
            controller?.delegate = nil
            loadingIndicator.stopAnimating()
            controller?.dismiss(animated: false)
            preparationTask = nil
            upgradeTask = nil
            retryTask = nil
            activeRequest = nil
            failures.removeAll()
            failureGenerations.removeAll()
            reportedFailures.removeAll()
            pendingRequest = nil
            requestID = nil
            items = []
            isPreviewPresentationComplete = false
            pendingCurrentRefresh = false
        }

        /// 首张优先使用缓存，其余资源在系统预览显示后下载。
        func prepareInitialItems(
            for request: ImagePreviewRequest,
            media: MediaEnvironment
        ) async throws -> (items: [MutableQuickLookItem], initialIndex: Int) {
            let count: Int
            let initialIndex: Int
            let file: URL?
            switch request.source {
            case let .local(images):
                guard !images.isEmpty else { throw QuickLookPreparationError.noImages }
                count = images.count
                initialIndex = min(max(request.initialIndex, 0), images.count - 1)
                file = try await media.localPreviewFile(image: images[initialIndex], owner: request.id)
            case let .remote(images):
                guard !images.isEmpty else { throw QuickLookPreparationError.noImages }
                count = images.count
                initialIndex = min(max(request.initialIndex, 0), images.count - 1)
                let image = images[initialIndex]
                if let highURL = image.originalURL,
                   let cached = try await media.cachedRemotePreviewFile(for: highURL, owner: request.id) {
                    file = cached
                } else if let lowURL = image.thumbnailURL,
                          let cached = try await media.cachedRemotePreviewFile(for: lowURL, owner: request.id) {
                    file = cached
                } else { file = nil }
            }
            placeholderURL = nil
            if count > 1 || file == nil {
                do {
                    let placeholder = try await media.images.placeholderFile()
                    placeholderURL = try await media.previewFile(at: placeholder, owner: request.id)
                } catch {
                    try Task.checkCancellation()
                    Self.logger.debug("其余预览页待恢复：\(error.localizedDescription, privacy: .private)")
                }
            }
            let prepared = (0..<count).map { index in
                MutableQuickLookItem(url: index == initialIndex ? file ?? placeholderURL : placeholderURL,
                    title: index == initialIndex && file != nil ? "图片 \(index + 1)" : "正在加载图片")
            }
            return (prepared, initialIndex)
        }

        private func prepareRemainingLocalItems(for request: ImagePreviewRequest, initialIndex: Int, media: MediaEnvironment) async {
            guard case let .local(images) = request.source else { return }
            for index in images.indices where index != initialIndex {
                guard !Task.isCancelled, requestID == request.id, self.media === media else { return }
                do {
                    let file = try await media.localPreviewFile(image: images[index], owner: request.id)
                    guard !Task.isCancelled, requestID == request.id, items.indices.contains(index), self.media === media else { return }
                    updateItem(at: index, to: file)
                } catch {
                    guard !Task.isCancelled, requestID == request.id, self.media === media else { return }
                    recordFailure(error, at: index)
                }
            }
        }

        private func originalUpgrade(for image: RemotePreviewImage, at index: Int, requestID: UUID, media: MediaEnvironment) -> Task<Void, Never> {
            if let task = originalTasks[index] { return task }
            let task = Task<Void, Never> { [weak self, media] in
                await self?.upgradeOriginal(image, at: index, requestID: requestID, media: media)
            }
            originalTasks[index] = task
            return task
        }

        /// 当前选中页优先升级高清，其余图片随后逐张补低清并缓存高清。
        private func upgradeRemoteItems(for request: ImagePreviewRequest, initialIndex: Int, media: MediaEnvironment) async {
            guard case let .remote(images) = request.source else { return }
            let remainingIndices = images.indices.filter { $0 != initialIndex }

            // 当前高清下载与其它页低清补齐并行，既尽快让当前画面变清晰，也避免用户
            // 在高清大图下载期间左右滑动时看到透明占位。
            let currentUpgrade = originalUpgrade(
                for: images[initialIndex],
                at: initialIndex,
                requestID: request.id, media: media
            )

            for index in images.indices {
                guard !Task.isCancelled, requestID == request.id, self.media === media else { return }
                let image = images[index]
                if index == initialIndex, image.originalURL == nil || image.originalURL == image.thumbnailURL { continue }
                if items.indices.contains(index),
                   items[index].url == placeholderURL,
                   let lowURL = image.thumbnailURL {
                    do {
                        let preview = try await media.remotePreviewFile(for: lowURL, owner: request.id)
                        guard !Task.isCancelled, requestID == request.id, items.indices.contains(index), self.media === media else { return }
                        if items[index].url == placeholderURL || items[index].url == nil {
                            updateItem(at: index, to: preview, clearsFailure: image.originalURL == nil)
                        }
                    } catch {
                        guard !Task.isCancelled, requestID == request.id, self.media === media else { return }
                        Self.logger.debug("图片缩略图准备失败：\(error.localizedDescription, privacy: .private)")
                        if image.originalURL == nil { recordFailure(error, at: index) }
                    }
                }
            }
            await currentUpgrade.value

            for index in remainingIndices {
                guard !Task.isCancelled, requestID == request.id, images.indices.contains(index) else { return }
                await originalUpgrade(for: images[index], at: index, requestID: request.id, media: media).value
            }
        }

        private func upgradeOriginal(_ image: RemotePreviewImage, at index: Int, requestID expectedID: UUID, media: MediaEnvironment) async {
            guard !Task.isCancelled, requestID == expectedID, items.indices.contains(index), self.media === media else { return }
            guard let remoteURL = image.originalURL ?? image.thumbnailURL else { recordFailure(QuickLookPreparationError.unavailable, at: index); return }
            if image.originalURL == nil, items[index].url != nil, items[index].url != placeholderURL { return }
            do {
                let preview = try await media.remotePreviewFile(for: remoteURL, owner: expectedID)
                guard !Task.isCancelled, requestID == expectedID, items.indices.contains(index), self.media === media else { return }
                updateItem(at: index, to: preview)
            } catch {
                guard !Task.isCancelled, requestID == expectedID, items.indices.contains(index), self.media === media else { return }
                Self.logger.debug("图片原图准备失败：\(error.localizedDescription, privacy: .private)")
                recordFailure(error, at: index)
            }
        }

        private func updateItem(at index: Int, to url: URL, clearsFailure: Bool = true) {
            let changed = items[index].url != url
            if clearsFailure {
                failures[index] = nil
                failureGenerations[index] = nil
                reportedFailures.remove(index)
            }
            items[index].title = "图片 \(index + 1)"
            items[index].url = url
            updateRetryButton()
            if changed, previewController?.currentPreviewItemIndex == index {
                if isPreviewPresentationComplete {
                    refreshCurrentPreviewItemSmoothly()
                } else {
                    // 高清在系统入场动画完成前就绪时，视觉刷新延后到入场结束。
                    pendingCurrentRefresh = true
                }
            }
        }

        private func recordFailure(_ error: any Error, at index: Int) {
            guard items.indices.contains(index), let requestID else { return }
            failures[index] = error
            failureGenerations[index] = media.imageRetryGeneration
            if items[index].url == placeholderURL || items[index].url == nil {
                items[index].url = nil
                items[index].title = "图片待恢复"
            }
            selectionDidChange(previewController?.currentPreviewItemIndex ?? -1, requestID: requestID)
        }

        private func selectionDidChange(_ index: Int, requestID expectedID: UUID) {
            guard requestID == expectedID, previewController?.currentPreviewItemIndex == index else { return }
            if let request = activeRequest, case let .remote(images) = request.source, items.indices.contains(index) {
                _ = originalUpgrade(for: images[index], at: index, requestID: request.id, media: media)
            }
            guard isPreviewPresentationComplete, let error = failures[index] else { updateRetryButton(); return }
            if failureGenerations[index] != media.imageRetryGeneration {
                retryCurrentImage()
                return
            }
            if items[index].url != nil { updateRetryButton(); return }
            previewController?.refreshCurrentPreviewItem()
            updateRetryButton()
            if reportedFailures.insert(index).inserted { reportFailure(error) }
        }

        private func updateRetryButton() {
            guard let controller = previewController else { return }
            let index = controller.currentPreviewItemIndex
            if items.indices.contains(index), items[index].url == placeholderURL, failures[index] == nil {
                loadingIndicator.startAnimating()
                controller.navigationItem.titleView = loadingIndicator
            } else {
                loadingIndicator.stopAnimating()
                controller.navigationItem.titleView = nil
            }
            var buttons = (controller.navigationItem.leftBarButtonItems ?? []).filter { $0 !== retryButton }
            if failures[controller.currentPreviewItemIndex] != nil {
                retryButton.isEnabled = retryTask == nil
                buttons.append(retryButton)
            }
            controller.navigationItem.leftBarButtonItems = buttons
        }

        @objc private func closePreview() {
            onDismiss?()
            cancel()
        }

        @objc private func retryCurrentImage() {
            guard retryTask == nil, let request = activeRequest, let index = previewController?.currentPreviewItemIndex,
                  failures[index] != nil, items.indices.contains(index) else { return }
            reportedFailures.remove(index)
            retryTask = Task { [weak self, media] in
                guard let self else { return }
                defer {
                    if requestID == request.id { retryTask = nil; updateRetryButton() }
                }
                do {
                    let file: URL
                    let clearsFailure: Bool
                    switch request.source {
                    case let .local(images):
                        file = try await media.localPreviewFile(image: images[index], owner: request.id)
                        clearsFailure = true
                    case let .remote(images):
                        let image = images[index]
                        clearsFailure = image.originalURL == nil
                        if let low = image.thumbnailURL,
                           let preview = try? await media.remotePreviewFile(for: low, owner: request.id) {
                            file = preview
                        } else if let high = image.originalURL {
                            file = try await media.remotePreviewFile(for: high, owner: request.id)
                        } else { throw QuickLookPreparationError.unavailable }
                    }
                    guard !Task.isCancelled, requestID == request.id, self.media === media else { return }
                    updateItem(at: index, to: file, clearsFailure: clearsFailure)
                    if case let .remote(images) = request.source {
                        await upgradeOriginal(images[index], at: index, requestID: request.id, media: media)
                    }
                } catch {
                    guard !Task.isCancelled, requestID == request.id, self.media === media else { return }
                    recordFailure(error, at: index)
                }
            }
            updateRetryButton()
        }

        private func reportFailure(_ error: any Error) {
            Self.logger.error("图片预览准备失败：\(error.localizedDescription, privacy: .private)")
            onFailure?(error)
        }

        /// 用当前低清画面的快照盖住 Quick Look 重新载入文件时的短暂空白，再快速淡出。
        ///
        /// Quick Look 没有公开的渐进式换图接口，直接 `refreshCurrentPreviewItem()` 会由
        /// 系统重建当前预览时偶尔出现明显闪白。系统预览器保持原样；刷新时叠加一层
        /// 不接收触摸的画面快照，让低清到高清更接近一次轻微交叉渐变。
        private func refreshCurrentPreviewItemSmoothly() {
            guard let controller = previewController else { return }
            guard AppDesignSystem.Motion.transition(reduceMotion: UIAccessibility.isReduceMotionEnabled) != nil else {
                controller.refreshCurrentPreviewItem()
                return
            }
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
nonisolated final class MutableQuickLookItem: NSObject, QLPreviewItem, Sendable {
    private struct State { var url: URL?; var title: String? }
    private let state: OSAllocatedUnfairLock<State>
    var url: URL? {
        get { state.withLock { $0.url } }
        set { state.withLock { $0.url = newValue } }
    }
    var title: String? {
        get { state.withLock { $0.title } }
        set { state.withLock { $0.title = newValue } }
    }
    var previewItemTitle: String? { title }
    var previewItemURL: URL? { url }

    init(url: URL?, title: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(url: url, title: title))
    }
}

private enum QuickLookPreparationError: LocalizedError {
    case noImages
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noImages: "没有可供预览的图片。"
        case .unavailable: "图片暂时无法读取，请重新点击图片重试。"
        }
    }
}


#endif
