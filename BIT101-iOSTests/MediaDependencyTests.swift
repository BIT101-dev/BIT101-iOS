@testable import BIT101_iOS
import Foundation
import CommunityUI
import CommunityCore
import ImageIO
@testable import MediaKit
import StorageCore
import Testing
import TransportCore
import UIKit
import UniformTypeIdentifiers

@MainActor
struct MediaDependencyTests {
    @Test func resourceFilesAndDecodedHitsReuseTheirIdentityAndFollowAtomicReplacement() async throws {
        let files = PreferenceMemoryFiles()
        let transport = Images(bytes: try png(width: 2))
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/shared.png")
        let first = try await media.images.file(for: url)
        let original = try await media.images.file(for: url)
        #expect(first == original && transport.requests == 1)
        #expect(try files.contentsOfDirectory(at: ImageCacheDirectories.gallery(using: files), options: []).count == 1)
        let image = try #require(await media.stillDecoder.image(at: first))
        let reads = files.readCount(at: first)
        #expect(await media.stillDecoder.image(at: first) === image)
        #expect(files.readCount(at: first) == reads)
        let animated = try #require(await media.animatedDecoder.image(at: first, reduceMotion: true))
        let animatedReads = files.readCount(at: first)
        #expect(await media.animatedDecoder.image(at: first, reduceMotion: true) === animated)
        #expect(files.readCount(at: first) == animatedReads)
        _ = try await media.images.file(for: url)
        let cachedReads = files.readCount(at: first)
        _ = try await media.images.file(for: url)
        #expect(files.readCount(at: first) == cachedReads)
        try files.writeData(try png(width: 3), to: first, options: [.atomic])
        #expect(await media.stillDecoder.image(at: first)?.size.width == 3)
        #expect(await media.animatedDecoder.image(at: first, reduceMotion: true)?.size.width == 3)
    }

    @Test func linkifiedTextPreservesLinksWithinTheDisplayBudget() async {
        let source = "阅读 https://bit101.cn/paper/42 与正文"
        let rendered = await communityLinkifiedText(source)
        #expect(String(rendered.characters) == source)
        #expect(rendered.runs.compactMap(\.link).map(\.absoluteString) == ["https://bit101.cn/paper/42"])
        let oversized = await communityLinkifiedText(String(repeating: "中", count: 100_000))
        #expect(String(oversized.characters).utf8.count <= CommunityTextLimits.maximumDisplayBytes)
    }

    @Test func displaySizedImagesShareAndReleaseTheActiveBitmapBudget() async throws {
        let files = PreferenceMemoryFiles()
        let file = files.temporaryDirectoryURL.appending(path: "display-budget.png")
        try files.writeData(try png(width: 256, height: 256), to: file, options: [.atomic])
        let still = GalleryThumbnailDecoder(files: files)
        let image = try #require(await still.image(at: file, maximumPixelSize: 16))
        let pixels = try #require(image.cgImage)
        #expect(pixels.width == 16 && pixels.height == 16)
        let animated = RemoteAnimatedImageDecoder(files: files)
        #expect(await animated.image(at: file, reduceMotion: false, maximumPixelSize: 8)?.cgImage?.width == 8)
        let budget = MediaDisplayBudget(maximumBytes: pixels.bytesPerRow * pixels.height)
        let first = MediaDisplayedImage(), second = MediaDisplayedImage(), third = MediaDisplayedImage()
        #expect(first.set(image, budget: budget) && second.set(image, budget: budget))
        #expect(budget.usedBytes == budget.maximumBytes)
        let additional = UIImage(cgImage: pixels)
        #expect(third.set(additional, budget: budget) == false && third.image == nil)
        first.clear()
        #expect(budget.usedBytes == budget.maximumBytes)
        second.clear()
        #expect(budget.usedBytes == 0 && budget.releaseGeneration > 0)
        #expect(third.set(additional, budget: budget))
        third.clear()
        let repeated = try #require(UIImage.animatedImage(with: Array(repeating: image, count: 10), duration: 1))
        #expect(first.set(repeated, budget: budget) && budget.usedBytes == budget.maximumBytes)
        first.clear()
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentAvatarsShareTheirRequestAndKeepTheRemainingConsumerAfterCancellation() async throws {
        let transport = DelayedImages(bytes: try png(width: 2))
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/old.png")
        let first = CachedRemoteImageLoader(), second = CachedRemoteImageLoader()
        let cancelled = Task { await first.load(url: url, media: media) }
        let remaining = Task { await second.load(url: url, media: media) }
        while media.downloads.waitingConsumerCount < 2 { await Task.yield() }
        while transport.pending == nil { await Task.yield() }
        #expect(transport.requests == 1)
        cancelled.cancel()
        await cancelled.value
        transport.pending?.resume()
        await remaining.value
        #expect(first.image == nil && second.image?.size.width == 2)
        #expect(transport.requests == 1)
        second.releaseDisplayImage()
        #expect(media.displayBudget.usedBytes == 0)
    }

    private final class CountedDownloads: HTTPTransport {
        var requests: [URL] = []
        var pending: [URL: CheckedContinuation<Void, Never>] = [:]
        var active = 0
        var peak = 0
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            requests.append(url)
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            await withCheckedContinuation { pending[url] = $0 }
            try Task.checkCancellation()
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func release() {
            let retained = pending.values
            pending.removeAll()
            for continuation in retained { continuation.resume() }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func distinctMediaDownloadsStayWithinTheSharedLimitAndCancelQueuedWork() async throws {
        let transport = CountedDownloads()
        let client = HTTPClient(transport: transport, observer: nil)
        let coordinator = MediaDownloadCoordinator(avatarClient: client, galleryClient: client)
        let started = (0..<MediaDownloadCoordinator.maximumConcurrentDownloads).map { index in
            Task { try await coordinator.response(for: AppURL.required("https://example.invalid/\(index)"),
                                                  source: index.isMultiple(of: 2) ? .avatar : .gallery) }
        }
        while transport.requests.count < MediaDownloadCoordinator.maximumConcurrentDownloads { await Task.yield() }
        let queued = (MediaDownloadCoordinator.maximumConcurrentDownloads..<8).map { index in
            Task { try await coordinator.response(for: AppURL.required("https://example.invalid/\(index)"),
                                                  source: index.isMultiple(of: 2) ? .avatar : .gallery) }
        }
        let tasks = started + queued
        while coordinator.waitingConsumerCount < tasks.count { await Task.yield() }
        while transport.requests.count < MediaDownloadCoordinator.maximumConcurrentDownloads { await Task.yield() }
        #expect(transport.active == MediaDownloadCoordinator.maximumConcurrentDownloads)
        tasks[7].cancel()
        await #expect(throws: CancellationError.self) { try await tasks[7].value }
        while transport.requests.count < tasks.count - 1 {
            transport.release()
            await Task.yield()
        }
        transport.release()
        for task in tasks.dropLast() { _ = try await task.value }
        #expect(transport.peak == MediaDownloadCoordinator.maximumConcurrentDownloads)
        #expect(transport.requests.count == tasks.count - 1 && coordinator.waitingConsumerCount == 0)
    }

    @Test func stillImagesDownsampleWithinTheDecodeBudgetAndPreserveAspectRatio() async throws {
        let data = try png(width: 256, height: 128)
        let files = PreferenceMemoryFiles()
        let file = files.temporaryDirectoryURL.appending(path: "bounded-still.png")
        try files.writeData(data, to: file, options: [.atomic])
        let decoder = GalleryThumbnailDecoder(files: files, maximumDecodedBytes: 4096)
        let image = try #require(await decoder.image(at: file)?.cgImage)
        #expect(image.bytesPerRow * image.height <= 4096)
        #expect(image.width <= 32 && image.height <= 32)
        #expect(image.width == image.height * 2)
        #expect(BoundedStillImageDecoder.image(from: data, maximumDecodedBytes: 3) == nil)
        #expect(BoundedStillImageDecoder.image(from: Data("damaged".utf8), maximumDecodedBytes: 4096) == nil)
    }

    private final class Images: HTTPTransport {
        let bytes: Data
        private(set) var requests = 0
        var failuresRemaining = 0
        var corruptResponsesRemaining = 0
        init(bytes: Data) { self.bytes = bytes }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            if failuresRemaining > 0 { failuresRemaining -= 1; throw URLError(.notConnectedToInternet) }
            let url = try #require(request.url)
            let response = corruptResponsesRemaining > 0 ? Data("damaged".utf8) : bytes
            corruptResponsesRemaining = max(corruptResponsesRemaining - 1, 0)
            return (response, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])))
        }
    }

    private final class BudgetedImages: HTTPTransport {
        let bytes: Data
        var requests = 0
        init(bytes: Data) { self.bytes = bytes }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            Issue.record("Remote image download requires a response budget")
            throw HTTPClientError.responseTooLarge
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            #expect(maximumBytes == RemoteImageResourceLimits.maximumEncodedBytes)
            requests += 1
            if requests == 1 { throw HTTPClientError.responseTooLarge }
            let url = try #require(request.url)
            return (bytes, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(arguments: ["avatar", "thumbnail", "original"])
    func oversizedImageDownloadsPreserveCacheSpaceAndSupportRetry(scope: String) async throws {
        let files = PreferenceMemoryFiles()
        let transport = BudgetedImages(bytes: try png(width: 2))
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/bounded.png")
        let loader = CachedRemoteImageLoader()
        if scope == "avatar" {
            await loader.load(url: url, media: media)
            #expect(loader.image == nil)
        } else {
            await #expect(throws: HTTPClientError.self) { try await media.images.file(for: url) }
            #expect(await media.images.waitingConsumerCount == 0)
        }
        let directory = try #require(files.directoryURL(.cachesDirectory))
        #expect(files.totalRegularFileSize(at: directory) == 0)
        if scope == "avatar" {
            await loader.load(url: url, media: media)
            #expect(loader.image?.size.width == 2)
        } else {
            #expect(try files.readData(at: await media.images.file(for: url)) == transport.bytes)
        }
        #expect(transport.requests == 2)
    }

    private final class DelayedImages: HTTPTransport {
        let bytes: Data
        var pending: CheckedContinuation<Void, any Error>?
        var requests = 0
        var finished = 0
        init(bytes: Data) { self.bytes = bytes }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            defer { finished += 1 }
            let url = try #require(request.url)
            if url.lastPathComponent == "old.png" {
                try await withCheckedThrowingContinuation { pending = $0 }
            }
            return (bytes, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    private func png(width: Int, height: Int = 1, color: UIColor = .systemBlue) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(image.pngData())
    }

    private func environment(files: PreferenceMemoryFiles, previewFiles: PreferenceMemoryFiles, transport: any HTTPTransport) -> MediaEnvironment {
        let client = HTTPClient(transport: transport, observer: nil)
        return MediaEnvironment(files: files, previewStorage: MediaPreviewStorage(files: previewFiles), defaults: AppFileDirectories.defaults,
                                imageHTTPClient: client, avatarHTTPClient: client)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func avatarLoadingTracksAnEnvironmentReplacementAtTheSameURL(delayed: Bool) async throws {
        let oldTransport = DelayedImages(bytes: try png(width: 1))
        let newTransport = Images(bytes: try png(width: 2))
        let first = environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: oldTransport)
        let second = environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: newTransport)
        let url = AppURL.required(delayed ? "https://example.invalid/old.png" : "https://example.invalid/image.png")
        let loader = CachedRemoteImageLoader()
        let old = Task { await loader.load(url: url, media: first) }
        if delayed {
            while oldTransport.pending == nil { await Task.yield() }
        } else {
            await old.value
            #expect(loader.image?.size.width == 1)
        }
        await loader.load(url: url, media: second)
        #expect(loader.image?.size.width == 2)
        if delayed {
            oldTransport.pending?.resume(throwing: URLError(.timedOut))
            await old.value
        }
        #expect(loader.image?.size.width == 2)
        #expect(newTransport.requests == 1)
        #expect(MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(first))
            != MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(second)))
    }

    @Test(.timeLimit(.minutes(1)))
    func animatedImageCoordinatorReplacesItsEnvironmentAtTheSameResource() async throws {
        let oldTransport = DelayedImages(bytes: try png(width: 1))
        let newTransport = Images(bytes: try png(width: 2))
        let first = environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: oldTransport)
        let second = environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: newTransport)
        let coordinator = RemoteAnimatedImage.Coordinator(media: first)
        let view = UIImageView()
        let url = AppURL.required("https://example.invalid/old.png")
        coordinator.load(url: url, into: view, media: first)
        while oldTransport.pending == nil { await Task.yield() }
        coordinator.load(url: url, into: view, media: second)
        while view.image == nil { await Task.yield() }
        #expect(view.image?.size.width == 2)
        oldTransport.pending?.resume(throwing: URLError(.timedOut))
        while oldTransport.finished == 0 { await Task.yield() }
        await Task.yield()
        #expect(view.image?.size.width == 2)
        #expect(newTransport.requests == 1)
        coordinator.cancel(imageView: view)
        #expect(view.image == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func imageRetryRestoresTheSameResourceAfterTransportOrDecodeFailure(corrupt: Bool) async throws {
        let transport = Images(bytes: try png(width: 2))
        transport.failuresRemaining = corrupt ? 0 : 1
        transport.corruptResponsesRemaining = corrupt ? 1 : 0
        let media = environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: transport)
        let coordinator = RemoteAnimatedImage.Coordinator(media: media)
        let view = UIImageView()
        let url = AppURL.required("https://example.invalid/retry.png")
        coordinator.load(url: url, into: view, media: media)
        while transport.requests == 0 { await Task.yield() }
        while await media.images.waitingConsumerCount > 0 { await Task.yield() }
        #expect(view.image == nil)
        let previousIdentity = MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(media), retryGeneration: media.imageRetryGeneration)
        media.retryFailedImages()
        #expect(previousIdentity != MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(media), retryGeneration: media.imageRetryGeneration))
        coordinator.load(url: url, into: view, media: media, retryGeneration: media.imageRetryGeneration)
        while view.image == nil { await Task.yield() }
        #expect(view.image?.size.width == 2 && transport.requests == 2)
        media.retryFailedImages()
        coordinator.load(url: url, into: view, media: media, retryGeneration: media.imageRetryGeneration)
        #expect(view.image?.size.width == 2 && transport.requests == 2)
        coordinator.cancel(imageView: view)
    }

    @Test func previewEnvironmentReplacementReleasesTheOldSessionAndClaimsTheNewOne() async throws {
        let first = environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: Images(bytes: try png(width: 1)))
        let secondFiles = PreferenceMemoryFiles()
        let second = environment(files: secondFiles, previewFiles: secondFiles, transport: Images(bytes: try png(width: 2)))
        let host = ImageQuickLookPresenter.HostViewController()
        let coordinator = ImageQuickLookPresenter.Coordinator(media: first)
        let url = AppURL.required("https://example.invalid/preview.png")
        let request = ImagePreviewRequest(remoteImages: [.init(thumbnailURL: url, originalURL: url)], initialIndex: 0)
        coordinator.receive(request, from: host, media: first)
        let oldFile = try await first.images.file(for: url)
        _ = try await first.previewFile(at: oldFile, owner: request.id)
        coordinator.receive(request, from: host, media: second)
        await #expect(throws: CancellationError.self) { try await first.previewFile(at: oldFile, owner: request.id) }
        let newFile = try await second.images.file(for: url)
        let preview = try await second.previewFile(at: newFile, owner: request.id)
        #expect(UIImage(data: try secondFiles.readData(at: newFile))?.size.width == 2)
        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await second.previewFile(at: preview, owner: request.id) }
    }

    @Test(arguments: [UTType.png.identifier, UTType.heic.identifier, UTType.jpeg.identifier])
    func composerPreparesLargeImagesWithinTheExistingPixelAndByteBudget(format: String) async throws {
        let source = try #require(CGImageSourceCreateWithData(png(width: 3200, height: 1600) as CFData, nil))
        let original = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, format as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, nil)
        #expect(CGImageDestinationFinalize(destination))
        let prepared = try await ComposerImagePreparer().prepare(encoded as Data)
        let image = try #require(UIImage(data: prepared))
        let result = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        #expect(CGImageSourceGetType(result) as String? == UTType.jpeg.identifier)
        #expect(image.size.width <= 1600 && image.size.height <= 1600)
        #expect(image.size.width == image.size.height * 2)
        #expect(prepared.count <= ComposerDraftImageCompressor.maximumBytes)
    }

    @Test func cacheValidationAndDecodingFollowEachInjectedStorageInstance() async throws {
        let firstFiles = PreferenceMemoryFiles()
        let secondFiles = PreferenceMemoryFiles()
        let previewFiles = PreferenceMemoryFiles()
        let firstTransport = Images(bytes: try png(width: 1))
        let secondTransport = Images(bytes: try png(width: 2))
        let first = environment(files: firstFiles, previewFiles: previewFiles, transport: firstTransport)
        let second = environment(files: secondFiles, previewFiles: PreferenceMemoryFiles(), transport: secondTransport)
        let url = AppURL.required("https://example.invalid/image.png")
        let firstURL = try await first.images.file(for: url)
        let secondURL = try await second.images.file(for: url)
        #expect(firstURL == secondURL)
        #expect(try await first.images.file(for: url) == firstURL)
        #expect(firstTransport.requests == 1)
        #expect(await first.stillDecoder.image(at: firstURL)?.size.width == 1)
        #expect(await second.stillDecoder.image(at: secondURL)?.size.width == 2)
        let preview = try await first.previewFile(at: firstURL)
        #expect(try previewFiles.readData(at: preview) == firstFiles.readData(at: firstURL))
        try firstFiles.writeData(png(width: 3), to: firstURL, options: [.atomic])
        #expect(await first.stillDecoder.image(at: firstURL)?.size.width == 3)
        #expect(await second.stillDecoder.image(at: secondURL)?.size.width == 2)
    }

    @Test func previewPlaceholderDecodesAndRepairsCorruptedCache() async throws {
        let files = PreferenceMemoryFiles()
        let previewFiles = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: previewFiles, transport: Images(bytes: Data()))
        let placeholder = try await media.images.placeholderFile()
        let validBytes = try files.readData(at: placeholder)
        let image = try #require(UIImage(data: validBytes)?.cgImage)
        #expect(image.width == 1 && image.height == 1)
        let pixels = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(try #require(pixels.data).load(fromByteOffset: 3, as: UInt8.self) == 0)
        try files.writeData(Data("corrupted".utf8), to: placeholder, options: [.atomic])
        #expect(try await media.images.placeholderFile() == placeholder)
        #expect(try files.readData(at: placeholder) == validBytes)
        let preview = try await media.previewFile(at: placeholder)
        #expect(try previewFiles.readData(at: preview) == validBytes)
    }

    @Test func clearingCacheKeepsDownloadsAndQuickLookUsableInSameSession() async throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let bytes = try png(width: 2)
        let transport = Images(bytes: bytes)
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/image.png")
        _ = await media.avatars.storeAndDecode(bytes, for: url)
        let original = try await media.images.file(for: url)
        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        await media.clearCaches()
        _ = await media.avatars.storeAndDecode(bytes, for: url)
        let reopened = environment(files: files, previewFiles: files, transport: transport)
        #expect(await reopened.avatars.data(for: url) == bytes)
        #expect(await reopened.avatars.image(for: url)?.size.width == 2)
        #expect(!files.fileExists(at: original))
        let downloaded = try await media.images.file(for: url)
        #expect(try await media.previewFile(at: downloaded) == downloaded)
        #expect(try files.readData(at: downloaded) == bytes)
        #expect(transport.requests == 2)

        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        let owner = UUID()
        media.beginPreview(owner: owner)
        let local = try await media.localPreviewFile(data: bytes, owner: owner)
        #expect(try files.readData(at: local) == bytes)
        media.endPreview(owner: owner)
        #expect(files.fileExists(at: local) == false)

        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        let placeholder = try await media.images.placeholderFile()
        #expect(try await media.previewFile(at: placeholder) == placeholder)
        #expect(UIImage(data: try files.readData(at: placeholder)) != nil)
    }

    @Test func previewOwnershipRetainsEarlierPagesUntilTheSessionCloses() async throws {
        let domain = "BIT101Tests.preview-file-ownership"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let files = PreferenceMemoryFiles()
        let client = HTTPClient(transport: Images(bytes: try png(width: 2) + Data(repeating: 1, count: 700_000)), observer: nil)
        let media = MediaEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files), defaults: defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        media.cacheLimitMB = 1
        let owner = UUID()
        media.beginPreview(owner: owner)
        let first = try await media.images.file(for: AppURL.required("https://example.invalid/first.png"))
        _ = try await media.previewFile(at: first, owner: owner)
        let second = try await media.images.file(for: AppURL.required("https://example.invalid/second.png"))
        _ = try await media.previewFile(at: second, owner: owner)
        let third = try await media.images.file(for: AppURL.required("https://example.invalid/third.png"))
        await media.enforceCurrentLimit()
        #expect(files.fileExists(at: first))
        #expect(files.fileExists(at: second))
        #expect(files.fileExists(at: third) == false)
        media.endPreview(owner: owner)
        await media.enforceCurrentLimit()
        #expect(await media.usedBytes() <= 1_048_576)
        await #expect(throws: CancellationError.self) { try await media.previewFile(at: first, owner: owner) }
    }

    @Test func localPreviewBytesBelongToActiveOwnersAndAreRemovedOnClose() async throws {
        let files = PreferenceMemoryFiles()
        let previewFiles = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: previewFiles, transport: Images(bytes: Data()))
        let bytes = try png(width: 2)
        let first = UUID()
        let second = UUID()
        media.beginPreview(owner: first)
        media.beginPreview(owner: second)
        let firstFile = try await media.localPreviewFile(data: bytes, owner: first)
        let secondFile = try await media.localPreviewFile(data: bytes, owner: second)
        #expect(firstFile == secondFile)
        #expect(files.totalRegularFileSize(at: files.temporaryDirectoryURL) == 0)
        media.endPreview(owner: first)
        #expect(try previewFiles.readData(at: secondFile) == bytes)
        await media.enforceCurrentLimit()
        #expect(previewFiles.fileExists(at: secondFile))
        media.endPreview(owner: second)
        #expect(previewFiles.fileExists(at: secondFile) == false)
        await #expect(throws: CancellationError.self) { try await media.localPreviewFile(data: bytes, owner: second) }
        let legacy = ImageCacheDirectories.gallery(using: previewFiles).appending(path: "local-legacy.png")
        let orphan = ImageCacheDirectories.gallery(using: previewFiles).appending(path: "preview-local-orphan.png")
        try previewFiles.writeData(bytes, to: orphan, options: [.atomic])
        let copiedLegacy = ImageCacheDirectories.gallery(using: previewFiles).appending(path: legacy.lastPathComponent)
        try previewFiles.writeData(bytes, to: copiedLegacy, options: [.atomic])
        let reopened = environment(files: files, previewFiles: previewFiles, transport: Images(bytes: Data()))
        await reopened.enforceCurrentLimit()
        #expect(previewFiles.fileExists(at: orphan) == false)
        #expect(previewFiles.fileExists(at: copiedLegacy) == false)
    }

    @Test func sharedPreviewStorageRetainsFilesAcrossEnvironmentCleanupAndClosing() async throws {
        let files = PreferenceMemoryFiles()
        let storage = MediaPreviewStorage(files: files)
        let client = HTTPClient(transport: Images(bytes: Data()), observer: nil)
        let first = MediaEnvironment(files: files, previewStorage: storage, defaults: AppFileDirectories.defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        let ownerA = UUID(), ownerB = UUID(), bytes = try png(width: 2)
        first.beginPreview(owner: ownerA)
        let file = try await first.localPreviewFile(data: bytes, owner: ownerA)
        let second = MediaEnvironment(files: files, previewStorage: storage, defaults: AppFileDirectories.defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        await second.enforceCurrentLimit()
        #expect(files.fileExists(at: file))
        second.beginPreview(owner: ownerB)
        #expect(try await second.localPreviewFile(data: bytes, owner: ownerB) == file)
        first.endPreview(owner: ownerA)
        await first.enforceCurrentLimit()
        #expect(try files.readData(at: file) == bytes)
        second.endPreview(owner: ownerB)
        #expect(files.fileExists(at: file) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func previewCreationAndRegistrationExcludeConcurrentCleanup() throws {
        let files = PreferenceMemoryFiles(), ownership = PreviewFileOwnership(), owner = UUID()
        let file = files.temporaryDirectoryURL.appending(path: "preview-creation.png")
        let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        ownership.begin(owner)
        defer { ownership.end(owner) }
        try ownership.materializeAndPin(file, using: files, owner: owner) {
            try files.writeData(Data("preview".utf8), to: file, options: [.atomic])
            DispatchQueue.global().async {
                ready.signal()
                ownership.withPaths { retained in
                    if !retained.contains(files.canonicalFileURL(file).path) {
                        do { try files.removeItem(at: file) }
                        catch { Issue.record(error) }
                    }
                }
                finished.signal()
            }
            ready.wait()
            #expect(finished.wait(timeout: .now()) == .timedOut)
        }
        finished.wait()
        #expect(files.fileExists(at: file))
    }

    @Test func clearingMediaReleasesBothDecodedMemoryCaches() async throws {
        let files = PreferenceMemoryFiles()
        let bytes = try png(width: 2)
        let media = environment(files: files, previewFiles: files, transport: Images(bytes: bytes))
        let url = AppURL.required("https://example.invalid/decoded.png")
        let original = try await media.images.file(for: url)
        let still = try #require(await media.stillDecoder.image(at: original))
        let animated = try #require(await media.animatedDecoder.image(at: original, reduceMotion: true))
        await media.clearCaches()
        let restored = try await media.images.file(for: url)
        let newStill = try #require(await media.stillDecoder.image(at: restored))
        let newAnimated = try #require(await media.animatedDecoder.image(at: restored, reduceMotion: true))
        #expect(newStill !== still)
        #expect(newAnimated !== animated)
    }

    private final class SuspendedCacheLimit {
        var pending: CheckedContinuation<Int, Never>?
        func read() async -> Int { await withCheckedContinuation { pending = $0 } }
    }

    @Test(.timeLimit(.minutes(1))) func clearingImagesInvalidatesDownloadWaitingForItsQuota() async throws {
        let files = PreferenceMemoryFiles()
        let limit = SuspendedCacheLimit()
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { await limit.read() })
        let bytes = try png(width: 2)
        let cache = RemoteImageCache(files: files, quota: quota,
            httpClient: HTTPClient(transport: Images(bytes: bytes), observer: nil))
        let url = AppURL.required("https://example.invalid/quota.png")
        let preparation = Task { try await cache.file(for: url) }
        while limit.pending == nil { await Task.yield() }
        await cache.clearAll()
        limit.pending?.resume(returning: 0)
        await #expect(throws: CancellationError.self) { try await preparation.value }
        #expect(await cache.usedBytes() == 0)
        let restored = try await cache.file(for: url)
        #expect(try files.readData(at: restored) == bytes)
    }

    @Test(.timeLimit(.minutes(1))) func clearingAvatarsRejectsAnEarlierDownloadAndAllowsANewRequest() async throws {
        let transport = DelayedImages(bytes: try png(width: 2))
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: transport)
        let loader = CachedRemoteImageLoader()
        let url = AppURL.required("https://example.invalid/old.png")
        let download = Task { await loader.load(url: url, media: media) }
        while transport.pending == nil { await Task.yield() }
        await media.clearCaches()
        transport.pending?.resume()
        await download.value
        #expect(loader.image == nil)
        #expect(await media.avatars.data(for: url) == nil)
        #expect(files.totalRegularFileSize(at: try #require(files.directoryURL(.cachesDirectory))) == 0)
        let retry = Task { await loader.load(url: url, media: media) }
        while transport.requests < 2 { await Task.yield() }
        transport.pending?.resume()
        await retry.value
        #expect(loader.image?.size.width == 2)
        #expect(await media.avatars.data(for: url) == transport.bytes)
    }

    @Test func anOldAvatarFailurePreservesTheNewURLImage() async throws {
        let transport = DelayedImages(bytes: try png(width: 2))
        let media = environment(files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(), transport: transport)
        let loader = CachedRemoteImageLoader()
        let old = Task { await loader.load(url: AppURL.required("https://example.invalid/old.png"), media: media) }
        while transport.pending == nil { await Task.yield() }
        await loader.load(url: AppURL.required("https://example.invalid/new.png"), media: media)
        #expect(loader.image?.size.width == 2)
        transport.pending?.resume(throwing: URLError(.timedOut))
        await old.value
        #expect(loader.image?.size.width == 2)
    }

    @Test func cancellingOneImageConsumerPreservesTheSharedDownload() async throws {
        let bytes = try png(width: 2)
        let transport = DelayedImages(bytes: bytes)
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/old.png")
        let first = Task { try await media.images.file(for: url) }
        while transport.pending == nil { await Task.yield() }
        let second = Task { try await media.images.file(for: url) }
        while await media.images.waitingConsumerCount < 2 { await Task.yield() }
        first.cancel()
        if case .success = await first.result { Issue.record("取消的等待者应立即结束") }
        #expect(transport.requests == 1)
        transport.pending?.resume()
        #expect(try files.readData(at: await second.value) == bytes)
    }

    @Test func clearingImagesCancelsTheWaitAndRejectsLateDownloadBytes() async throws {
        let transport = DelayedImages(bytes: try png(width: 2))
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: transport)
        let download = Task { try await media.images.file(for: AppURL.required("https://example.invalid/old.png")) }
        while transport.pending == nil { await Task.yield() }
        await media.clearCaches()
        if case .success = await download.result { Issue.record("缓存清理应终止既有下载") }
        transport.pending?.resume()
        while transport.finished == 0 { await Task.yield() }
        #expect(await media.images.waitingConsumerCount == 0)
        #expect(files.totalRegularFileSize(at: files.temporaryDirectoryURL) == 0)
    }

    @Test func localPreviewPreparesTheSelectedPageAndRetainsAllPagePositions() async throws {
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: Images(bytes: Data()))
        let images = try (1...64).map { try #require(UIImage(data: png(width: $0))) }
        let request = ImagePreviewRequest(localImages: images, initialIndex: 63)
        media.beginPreview(owner: request.id)
        let coordinator = ImageQuickLookPresenter.Coordinator(media: media)
        let prepared = try await coordinator.prepareInitialItems(for: request, media: media)
        #expect(prepared.initialIndex == 63 && prepared.items.count == 64)
        let selectedFile = prepared.items[63].url
        #expect(UIImage(data: try files.readData(at: selectedFile))?.size.width == 64)
        #expect(prepared.items.dropLast().allSatisfy { $0.url != selectedFile })
        let localFiles = try files.contentsOfDirectory(at: ImageCacheDirectories.gallery(using: files), options: [])
            .filter { $0.lastPathComponent.hasPrefix("preview-local-") }
        #expect(localFiles == [selectedFile])
        media.endPreview(owner: request.id)
        #expect(files.fileExists(at: selectedFile) == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0.4, 0.02])
    func gifFramesAndReducedMotionReadInjectedBytes(firstDelay: Double) async throws {
        let secondDelay = firstDelay == 0.4 ? 0.1 : 0.5
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for (color, delay) in [(UIColor.systemRed, firstDelay), (UIColor.systemBlue, secondDelay)] {
            let image = try #require(UIImage(data: png(width: 1, color: color))?.cgImage)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let files = PreferenceMemoryFiles()
        let file = URL(fileURLWithPath: "/preference-sync/animation.gif")
        try files.writeData(data as Data, to: file, options: [.atomic])
        let transport = Images(bytes: data as Data)
        let media = environment(files: files, previewFiles: PreferenceMemoryFiles(), transport: transport)
        let animated = try #require(await media.animatedDecoder.image(at: file, reduceMotion: false))
        let frames = try #require(animated.images)
        let firstPixels = try #require(frames.first?.cgImage?.dataProvider?.data) as Data
        let firstFrameCount = frames.filter { ($0.cgImage?.dataProvider?.data as Data?) == firstPixels }.count
        let firstDuration = animated.duration * Double(firstFrameCount) / Double(frames.count)
        #expect(abs(firstDuration - firstDelay) < 0.001)
        #expect(abs(animated.duration - firstDuration - secondDelay) < 0.001)
        var unique = Set<ObjectIdentifier>()
        let actualBytes = frames.reduce(0) { bytes, frame in
            guard let pixels = frame.cgImage, unique.insert(ObjectIdentifier(pixels)).inserted else { return bytes }
            return bytes + pixels.bytesPerRow * pixels.height
        }
        #expect(unique.count == 2 && frames.count > unique.count)
        #expect(MediaDisplayBudget.pixelBytes(animated) == actualBytes)
        #expect(await media.animatedDecoder.image(at: file, reduceMotion: true)?.images == nil)
        #expect(await media.animatedDecoder.image(at: file, reduceMotion: true)?.size.width == 1)
        let view = UIImageView()
        let coordinator = RemoteAnimatedImage.Coordinator(media: media)
        let url = AppURL.required("https://example.invalid/motion.gif")
        coordinator.load(url: url, into: view, media: media, reduceMotion: false)
        while view.image == nil { await Task.yield() }
        #expect(view.image?.images != nil)
        coordinator.load(url: url, into: view, media: media, reduceMotion: true)
        while view.image == nil { await Task.yield() }
        #expect(view.image?.images == nil)
        coordinator.load(url: url, into: view, media: media, reduceMotion: false)
        while view.image == nil { await Task.yield() }
        #expect(view.image?.images != nil && transport.requests == 1)
        coordinator.cancel(imageView: view)
    }

    @Test func animatedImageDownsamplesFramesBeforeExceedingItsDecodeBudget() async throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 4, nil))
        for color in [UIColor.systemRed, .systemGreen, .systemBlue, .systemYellow] {
            let image = try #require(UIImage(data: png(width: 64, height: 64, color: color))?.cgImage)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let files = PreferenceMemoryFiles()
        let file = files.temporaryDirectoryURL.appending(path: "budget.gif")
        try files.writeData(data as Data, to: file, options: [])
        let decoder = RemoteAnimatedImageDecoder(files: files, maximumDecodedBytes: 4096)
        let image = try #require(await decoder.image(at: file, reduceMotion: false))
        let frames = try #require(image.images)
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.size.width < 64 && $0.size.height < 64 })
        #expect(frames.reduce(0) { $0 + ($1.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) } <= 4096)
        #expect(abs(image.duration - 0.4) < 0.001)
    }
}
