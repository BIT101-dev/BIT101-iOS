@testable import BIT101_iOS
@testable import MediaKit
import ClientCore
import Foundation
import QuickLook
import SwiftUI
import Testing
import TransportCore
import UIKit

#if os(iOS)
extension MediaDependencyTests {
    final class Images: HTTPTransport {
        let bytes: Data
        private(set) var requests = 0
        var failuresRemaining = 0
        var failedURLs = Set<URL>()
        var blockedURL: URL?
        var pending: CheckedContinuation<Void, Never>?
        var corruptResponsesRemaining = 0
        var corruptResponseData = Data("damaged".utf8)
        init(bytes: Data) { self.bytes = bytes }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            if failuresRemaining > 0 { failuresRemaining -= 1; throw URLError(.notConnectedToInternet) }
            let url = try #require(request.url)
            if url == blockedURL { await withCheckedContinuation { pending = $0 } }
            if failedURLs.contains(url) { throw URLError(.notConnectedToInternet) }
            let response = corruptResponsesRemaining > 0 ? corruptResponseData : bytes
            corruptResponsesRemaining = max(corruptResponsesRemaining - 1, 0)
            return (response, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])))
        }
    }

    func png(width: Int, height: Int = 1, color: UIColor = .systemBlue) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(image.pngData())
    }

    func environment(files: PreferenceMemoryFiles, previewFiles: PreferenceMemoryFiles, transport: any HTTPTransport) -> MediaEnvironment {
        let client = HTTPClient(transport: transport, observer: nil)
        return AppMedia.makeEnvironment(files: files, previewStorage: MediaPreviewStorage(files: previewFiles), defaults: AppFileDirectories.defaults,
                                imageHTTPClient: client, avatarHTTPClient: client)
    }

}
#endif

#if os(iOS)
@MainActor @Suite(.serialized)
struct MediaPresentationTests {
    private final class PreviewController: QLPreviewController {
        var refreshes = 0
        override func refreshCurrentPreviewItem() { refreshes += 1; super.refreshCurrentPreviewItem() }
    }
    private func window(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }
    @Test(.timeLimit(.minutes(1)), arguments: ["avatar", "still", "progressive"])
    func unrelatedBudgetReleasePreservesFailedImageRequestCount(kind: String) async throws {
        let helper = MediaDependencyTests(), transport = MediaDependencyTests.Images(bytes: try helper.png(width: 2))
        transport.failuresRemaining = 100
        let media = helper.environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: transport)
        let url = AppURL.required("https://example.invalid/image.png")
        let view: AnyView
        switch kind {
        case "avatar": view = AnyView(CachedRemoteImage(url: url, content: { $0.resizable() }, placeholder: { Color.clear }))
        case "still": view = AnyView(RemoteCachedStillImage(url: url))
        default: view = AnyView(RemoteProgressiveStillImage(thumbnailURL: url, originalURL: nil))
        }
        let host = UIHostingController(rootView: view.frame(width: 40, height: 40).environment(media))
        let window = try window(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForTestEvent { transport.requests > 0 }
        try await Task.sleep(for: .milliseconds(300))
        let count = transport.requests, owner = UUID(), image = try #require(UIImage(data: helper.png(width: 2)))
        #expect(media.displayBudget.retain(image, owner: owner))
        media.displayBudget.release(owner: owner)
        try await Task.sleep(for: .milliseconds(300))
        #expect(transport.requests == count)
        media.retryFailedImages()
        try await waitForTestEvent { transport.requests > count }
    }
    @Test(.timeLimit(.minutes(1)))
    func aVisiblePlaceholderRefreshesWhenItsThumbnailArrives() async throws {
        let helper = MediaDependencyTests(), transport = MediaDependencyTests.Images(bytes: try helper.png(width: 2))
        let media = helper.environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: transport)
        let low = AppURL.required("https://example.invalid/second.png"), high = AppURL.required("https://example.invalid/original.png")
        transport.blockedURL = low; transport.failedURLs = [high]
        let preview = PreviewController(), host = ImageQuickLookPresenter.HostViewController()
        let window = try window(host)
        let coordinator = ImageQuickLookPresenter.Coordinator(media: media, makePreviewController: { preview })
        defer { coordinator.cancel(); window.isHidden = true; window.rootViewController = nil }
        let request = ImagePreviewRequest(remoteImages: [.init(thumbnailURL: AppURL.required("https://example.invalid/first.png"), originalURL: nil), .init(thumbnailURL: low, originalURL: high)], initialIndex: 0)
        coordinator.receive(request, from: host, media: media)
        try await waitForTestEvent { transport.pending != nil && preview.viewIfLoaded?.window != nil && !preview.isBeingPresented }
        preview.currentPreviewItemIndex = 1
        let oldURL = preview.dataSource?.previewController(preview, previewItemAt: 1).previewItemURL
        let item = try #require(preview.dataSource?.previewController(preview, previewItemAt: 1) as? MutableQuickLookItem)
        #expect(await Task.detached { item.previewItemURL }.value == oldURL)
        transport.pending?.resume(); transport.pending = nil
        try await waitForTestEvent { preview.refreshes > 0 }
        #expect(preview.dataSource?.previewController(preview, previewItemAt: 1).previewItemURL != oldURL)
        #expect(await Task.detached { item.previewItemURL }.value == item.url)
    }
    @Test(.timeLimit(.minutes(1)))
    func cachedSingleImageOpensWithReadOnlySharedStorageAndReusesItsFile() async throws {
        let helper = MediaDependencyTests(), files = PreferenceMemoryFiles()
        let transport = MediaDependencyTests.Images(bytes: try helper.png(width: 2))
        let media = helper.environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/cached.png")
        let cached = try await media.images.file(for: url)
        let reads = files.readCount(at: cached)
        files.setFailures(writing: true)
        let coordinator = ImageQuickLookPresenter.Coordinator(media: media)
        let request = ImagePreviewRequest(remoteImages: [.init(thumbnailURL: url, originalURL: nil)], initialIndex: 0)
        media.beginPreview(owner: request.id)
        defer { media.endPreview(owner: request.id) }
        #expect(try await media.previewFile(at: cached, owner: request.id) == cached)
        #expect(files.readCount(at: cached) == reads)
        let prepared = try await coordinator.prepareInitialItems(for: request, media: media)
        #expect(prepared.items.count == 1 && prepared.items[0].url == cached)
        #expect(transport.requests == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedLaterPagesRecoverThroughTheNativeActionAndNetworkGeneration(networkRetry: Bool) async throws {
        let helper = MediaDependencyTests(), transport = MediaDependencyTests.Images(bytes: try helper.png(width: 2))
        let media = helper.environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: transport)
        let second = AppURL.required("https://example.invalid/second.png")
        transport.failedURLs = [second]
        let preview = PreviewController(), host = ImageQuickLookPresenter.HostViewController(), window = try window(host)
        let coordinator = ImageQuickLookPresenter.Coordinator(media: media, makePreviewController: { preview })
        defer { coordinator.cancel(); window.isHidden = true; window.rootViewController = nil }
        var failures = 0
        coordinator.onFailure = { _ in failures += 1 }
        let request = ImagePreviewRequest(remoteImages: [.init(thumbnailURL: AppURL.required("https://example.invalid/first.png"), originalURL: nil),
            .init(thumbnailURL: second, originalURL: nil)], initialIndex: 0)
        coordinator.receive(request, from: host, media: media)
        try await waitForTestEvent {
            preview.viewIfLoaded?.window != nil && !preview.isBeingPresented &&
            preview.dataSource?.previewController(preview, previewItemAt: 1).previewItemTitle == "图片待恢复"
        }
        #expect(failures == 0)
        preview.currentPreviewItemIndex = 1
        try await waitForTestEvent { failures == 1 }
        let button = try #require(preview.navigationItem.leftBarButtonItems?.first { $0.accessibilityIdentifier == "media.preview.retry" })
        #expect(button.isEnabled)
        transport.failedURLs = []
        if networkRetry {
            media.retryFailedImages()
            coordinator.receive(request, from: host, media: media)
        } else {
            let action = try #require(button.action)
            #expect(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
        }
        try await waitForTestEvent { preview.dataSource?.previewController(preview, previewItemAt: 1).previewItemURL != nil }
        #expect(preview.dataSource?.previewController(preview, previewItemAt: 1).previewItemTitle == "图片 2")
        #expect(preview.navigationItem.leftBarButtonItems?.contains { $0.accessibilityIdentifier == "media.preview.retry" } == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func initialPreviewFailureReleasesTheRequestAndReportsTheError() async throws {
        let helper = MediaDependencyTests(), transport = MediaDependencyTests.Images(bytes: try helper.png(width: 2))
        transport.failuresRemaining = 1
        let media = helper.environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: transport)
        let host = ImageQuickLookPresenter.HostViewController(), window = try window(host)
        let coordinator = ImageQuickLookPresenter.Coordinator(media: media)
        defer { coordinator.cancel(); window.isHidden = true; window.rootViewController = nil }
        var dismissed = false, failed = false
        coordinator.onDismiss = { dismissed = true }; coordinator.onFailure = { _ in failed = true }
        coordinator.receive(ImagePreviewRequest(remoteImages: [.init(thumbnailURL: AppURL.required("https://example.invalid/failed.png"), originalURL: nil)], initialIndex: 0), from: host, media: media)
        try await waitForTestEvent { failed }
        #expect(dismissed && host.presentedViewController == nil)
    }
}
#endif
