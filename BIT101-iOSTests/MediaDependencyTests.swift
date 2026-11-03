import CommunityCore
import CommunityUI
import Foundation
import ImageIO
import StorageCore
import Testing
import TransportCore
import UIKit
import UniformTypeIdentifiers

@testable import BIT101_iOS
@testable import MediaKit

@MainActor
struct MediaDependencyTests {
    @Test(arguments: [CGFloat(1), 2, 3])
    func thumbnailDecodeConvertsScale(scale: CGFloat) throws {
        let bytes = try png(width: 512)
        let decoded = try #require(
            BoundedStillImageDecoder.image(from: bytes, pointSize: 24, displayScale: scale)?.cgImage
        )
        #expect(max(decoded.width, decoded.height) == Int(24 * scale))
        for invalid in [CGFloat.zero, -1, .infinity, .nan] {
            #expect(
                BoundedStillImageDecoder.image(from: bytes, pointSize: invalid, displayScale: scale)
                    == nil)
            #expect(
                BoundedStillImageDecoder.image(from: bytes, pointSize: 24, displayScale: invalid)
                    == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["success", "gallery", "cache"])
    func productionImageProbeReusesResourceDecoders(stage: String) async throws {
        let files = PreferenceMemoryFiles()
        let bytes = try png(width: 2)
        let gallery = Images(bytes: stage == "gallery" ? Data("damaged".utf8) : bytes)
        let avatar = Images(bytes: stage == "avatar" ? Data("damaged".utf8) : bytes)
        let media = AppMedia.makeEnvironment(
            files: files, previewStorage: MediaPreviewStorage(files: files),
            imageHTTPClient: HTTPClient(transport: gallery, observer: nil),
            avatarHTTPClient: HTTPClient(transport: avatar, observer: nil))
        files.setFailures(writing: stage == "cache")
        let url = AppURL.required("https://example.invalid/probe.png")
        if stage == "success" {
            #expect(try await media.verifyRemoteImage(at: url) == bytes.count * 2)
            #expect(gallery.requests == 1 && avatar.requests == 0)
            #expect(try await media.verifyRemoteImage(at: url) == bytes.count * 2)
            #expect(gallery.requests == 1 && avatar.requests == 0)
            #expect(
                try files.contentsOfDirectory(
                    at: ImageCacheDirectories.gallery(using: files), options: []
                ).count == 1)
        } else {
            await #expect(throws: (any Error).self) { try await media.verifyRemoteImage(at: url) }
        }
        await media.clearCaches()
    }
    @Test(.timeLimit(.minutes(1)), arguments: ["empty", "oversized", "gif"])
    func downloadingReplacesUnusableExistingCache(kind: String) async throws {
        let files = PreferenceMemoryFiles()
        let bytes =
            kind == "gif"
            ? try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="))
            : try png(width: 2)
        let transport = Images(bytes: bytes)
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/cache.png")
        let original = try await media.images.file(for: url)
        let corrupt =
            kind == "gif"
            ? Data(bytes.dropLast())
            : Data(
                repeating: 0,
                count: kind == "empty" ? 0 : RemoteImageResourceLimits.maximumEncodedBytes + 1)
        try files.writeData(corrupt, to: original, options: [.atomic])
        #expect(await media.images.cachedFile(for: url) == nil)
        let repaired = try await media.images.file(for: url)
        #expect(repaired == original)
        #expect(try files.readData(at: repaired) == bytes)
        #expect(await media.stillDecoder.image(at: repaired)?.size.width == (kind == "gif" ? 1 : 2))
        #expect(await media.images.cachedFile(for: url) == repaired)
        #expect(transport.requests == 2)
    }

    @Test(.timeLimit(.minutes(1))) func resourceFiles() async throws {
        let files = PreferenceMemoryFiles()
        let transport = Images(bytes: try png(width: 2))
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/shared.png")
        let first = try await media.images.file(for: url)
        let original = try await media.images.file(for: url)
        #expect(first == original && transport.requests == 1)
        #expect(
            try files.contentsOfDirectory(
                at: ImageCacheDirectories.gallery(using: files), options: []
            ).count == 1)
        let image = try #require(await media.stillDecoder.image(at: first))
        let reads = files.readCount(at: first)
        #expect(await media.stillDecoder.image(at: first) === image)
        #expect(files.readCount(at: first) == reads)
        let animated = try #require(
            await media.animatedDecoder.image(at: first, reduceMotion: true))
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

    @Test(.timeLimit(.minutes(1))) func linkifiedTextPreservesLinksWithinBudget() async {
        let source = "阅读 https://bit101.cn/paper/42 与正文"
        let rendered = await communityLinkifiedText(source)
        #expect(String(rendered.characters) == source)
        #expect(
            rendered.runs.compactMap(\.link).map(\.absoluteString) == ["https://bit101.cn/paper/42"]
        )
        let oversized = await communityLinkifiedText(String(repeating: "中", count: 100_000))
        #expect(String(oversized.characters).utf8.count <= CommunityTextLimits.maximumDisplayBytes)
    }

    @Test(.timeLimit(.minutes(1))) func displaySizedImagesShare() async throws {
        let files = PreferenceMemoryFiles()
        let file = files.temporaryDirectoryURL.appending(path: "display-budget.png")
        try files.writeData(try png(width: 256, height: 256), to: file, options: [.atomic])
        let still = GalleryThumbnailDecoder(files: files)
        let image = try #require(await still.image(at: file, maximumPixelSize: 16))
        let pixels = try #require(image.cgImage)
        #expect(pixels.width == 16 && pixels.height == 16)
        let animated = RemoteAnimatedImageDecoder(files: files)
        #expect(
            await animated.image(at: file, reduceMotion: false, maximumPixelSize: 8)?.cgImage?.width
                == 8)
        let budget = MediaDisplayBudget(maximumBytes: pixels.bytesPerRow * pixels.height)
        let first = MediaDisplayedImage()
        let second = MediaDisplayedImage()
        let third = MediaDisplayedImage()
        #expect(first.set(image, budget: budget) && second.set(image, budget: budget))
        #expect(budget.usedBytes == budget.maximumBytes)
        let additional = UIImage(cgImage: pixels)
        #expect(
            third.set(additional, budget: budget) == false && third.image == nil
                && third.waitingForBudget)
        first.clear()
        #expect(budget.usedBytes == budget.maximumBytes)
        second.clear()
        #expect(budget.usedBytes == 0 && budget.releaseGeneration > 0)
        #expect(third.set(additional, budget: budget) && !third.waitingForBudget)
        third.clear()
        let repeated = try #require(
            UIImage.animatedImage(with: Array(repeating: image, count: 10), duration: 1))
        #expect(first.set(repeated, budget: budget) == false && budget.usedBytes == 0)
        first.clear()
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentAvatarsShareCancel() async throws {
        let transport = DelayedImages(bytes: try png(width: 2))
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/old.png")
        let first = CachedRemoteImageLoader()
        let second = CachedRemoteImageLoader()
        let cancelled = Task { await first.load(url: url, media: media) }
        let remaining = Task { await second.load(url: url, media: media) }
        defer {
            cancelled.cancel()
            remaining.cancel()
            transport.pending?.resume()
            transport.pending = nil
        }
        try await waitForAsyncTestEvent { await media.images.waitingConsumerCount == 2 }
        try await waitForTestEvent { !(transport.pending == nil) }
        #expect(transport.requests == 1)
        cancelled.cancel()
        await cancelled.value
        transport.pending?.resume()
        transport.pending = nil
        await remaining.value
        #expect(first.image == nil && second.image?.size.width == 2)
        #expect(transport.requests == 1)
        second.releaseDisplayImage()
        #expect(media.displayBudget.usedBytes == 0)
    }

    @Test(.timeLimit(.minutes(1))) func stillImagesDownsamplePreserveAspectRatio() async throws {
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
        #expect(
            BoundedStillImageDecoder.image(from: Data("damaged".utf8), maximumDecodedBytes: 4096)
                == nil)
    }
    final class BudgetedImages: HTTPTransport {
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
            return (
                bytes,
                try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["avatar", "thumbnail", "original"])
    func oversizedImageDownloadsPreserveCacheSpace(scope: String) async throws {
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

    final class DelayedImages: HTTPTransport {
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
            return (
                bytes,
                try #require(
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func avatarLoadingTracksUrl(delayed: Bool) async throws {
        let oldTransport = DelayedImages(bytes: try png(width: 1))
        let newTransport = Images(bytes: try png(width: 2))
        let first = environment(
            files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(),
            transport: oldTransport)
        let second = environment(
            files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(),
            transport: newTransport)
        let url = AppURL.required(
            delayed ? "https://example.invalid/old.png" : "https://example.invalid/image.png")
        let loader = CachedRemoteImageLoader()
        let old = Task { await loader.load(url: url, media: first) }
        if delayed {
            try await waitForTestEvent { !(oldTransport.pending == nil) }
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
        #expect(
            MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(first))
                != MediaImageLoadIdentity(urls: [url], environment: ObjectIdentifier(second)))
    }

    @Test(.timeLimit(.minutes(1)))
    func animatedImageCoordinatorReplacesResource() async throws {
        let oldTransport = DelayedImages(bytes: try png(width: 1))
        let newTransport = Images(bytes: try png(width: 2))
        let first = environment(
            files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(),
            transport: oldTransport)
        let second = environment(
            files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(),
            transport: newTransport)
        let coordinator = RemoteAnimatedImage.Coordinator(media: first)
        let view = UIImageView()
        let url = AppURL.required("https://example.invalid/old.png")
        coordinator.load(url: url, into: view, media: first)
        try await waitForTestEvent { !(oldTransport.pending == nil) }
        coordinator.load(url: url, into: view, media: second)
        try await waitForTestEvent { !(view.image == nil) }
        #expect(view.image?.size.width == 2)
        oldTransport.pending?.resume(throwing: URLError(.timedOut))
        try await waitForTestEvent { !(oldTransport.finished == 0) }
        await Task.yield()
        #expect(view.image?.size.width == 2)
        #expect(newTransport.requests == 1)
        coordinator.cancel(imageView: view)
        #expect(view.image == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["transport", "corrupt", "gif"])
    func imageRetryRestoresResource(failure: String) async throws {
        let bytes =
            failure == "gif"
            ? try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="))
            : try png(width: 2)
        let transport = Images(bytes: bytes)
        transport.failuresRemaining = failure == "transport" ? 1 : 0
        transport.corruptResponsesRemaining = failure == "transport" ? 0 : 1
        if failure == "gif" { transport.corruptResponseData = Data(bytes.dropLast()) }
        let media = environment(
            files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(),
            transport: transport)
        let coordinator = RemoteAnimatedImage.Coordinator(media: media)
        let view = UIImageView()
        let url = AppURL.required("https://example.invalid/retry.png")
        coordinator.load(url: url, into: view, media: media)
        try await waitForTestEvent { !(transport.requests == 0) }
        try await waitForTestEvent(isolation: media.images) { $0.waitingConsumerCount == 0 }
        #expect(view.image == nil)
        coordinator.load(url: url, into: view, media: media, budgetGeneration: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.requests == 1)
        let previousIdentity = MediaImageLoadIdentity(
            urls: [url], environment: ObjectIdentifier(media),
            retryGeneration: media.imageRetryGeneration)
        media.retryFailedImages()
        #expect(
            previousIdentity
                != MediaImageLoadIdentity(
                    urls: [url], environment: ObjectIdentifier(media),
                    retryGeneration: media.imageRetryGeneration))
        coordinator.load(
            url: url, into: view, media: media, retryGeneration: media.imageRetryGeneration)
        try await waitForTestEvent { !(view.image == nil) }
        #expect(view.image?.size.width == (failure == "gif" ? 1 : 2) && transport.requests == 2)
        media.retryFailedImages()
        coordinator.load(
            url: url, into: view, media: media, retryGeneration: media.imageRetryGeneration)
        #expect(view.image?.size.width == (failure == "gif" ? 1 : 2) && transport.requests == 2)
        coordinator.cancel(imageView: view)
    }

    @Test(.timeLimit(.minutes(1))) func previewEnvironmentReleasesOldSession() async throws {
        let first = environment(
            files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(),
            transport: Images(bytes: try png(width: 1)))
        let secondFiles = PreferenceMemoryFiles()
        let second = environment(
            files: secondFiles, previewFiles: secondFiles,
            transport: Images(bytes: try png(width: 2)))
        let host = ImageQuickLookPresenter.HostViewController()
        let coordinator = ImageQuickLookPresenter.Coordinator(media: first)
        let url = AppURL.required("https://example.invalid/preview.png")
        let request = ImagePreviewRequest(
            remoteImages: [.init(thumbnailURL: url, originalURL: url)], initialIndex: 0)
        coordinator.receive(request, from: host, media: first)
        let oldFile = try await first.images.file(for: url)
        _ = try await first.previewFile(at: oldFile, owner: request.id)
        coordinator.receive(request, from: host, media: second)
        await #expect(throws: CancellationError.self) {
            try await first.previewFile(at: oldFile, owner: request.id)
        }
        let newFile = try await second.images.file(for: url)
        let preview = try await second.previewFile(at: newFile, owner: request.id)
        #expect(UIImage(data: try secondFiles.readData(at: newFile))?.size.width == 2)
        coordinator.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.previewFile(at: preview, owner: request.id)
        }
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [UTType.png.identifier, UTType.heic.identifier, UTType.jpeg.identifier])
    func composerPreparesLargePixel(format: String) async throws {
        let source = try #require(
            CGImageSourceCreateWithData(png(width: 3200, height: 1600) as CFData, nil))
        let original = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let encoded = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(encoded, format as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, nil)
        #expect(CGImageDestinationFinalize(destination))
        let thumbnail = try #require(
            BoundedStillImageDecoder.image(from: encoded as Data, maximumPixelSize: 96)?.cgImage)
        #expect(thumbnail.width <= 96 && thumbnail.height <= 96)
        #expect(thumbnail.width == thumbnail.height * 2)
        let prepared = try await ComposerImagePreparer().prepare(encoded as Data)
        let image = try #require(UIImage(data: prepared))
        let result = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        #expect(CGImageSourceGetType(result) as String? == UTType.jpeg.identifier)
        #expect(image.size.width <= 1600 && image.size.height <= 1600)
        #expect(image.size.width == image.size.height * 2)
        #expect(prepared.count <= ComposerDraftImageCompressor.maximumBytes)
    }

    @Test(.timeLimit(.minutes(1))) func cacheValidation() async throws {
        let firstFiles = PreferenceMemoryFiles()
        let secondFiles = PreferenceMemoryFiles()
        let previewFiles = PreferenceMemoryFiles()
        let firstTransport = Images(bytes: try png(width: 1))
        let secondTransport = Images(bytes: try png(width: 2))
        let first = environment(
            files: firstFiles, previewFiles: previewFiles, transport: firstTransport)
        let second = environment(
            files: secondFiles, previewFiles: PreferenceMemoryFiles(), transport: secondTransport)
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

    @Test(.timeLimit(.minutes(1))) func previewPlaceholderDecodes() async throws {
        let files = PreferenceMemoryFiles()
        let previewFiles = PreferenceMemoryFiles()
        let media = environment(
            files: files, previewFiles: previewFiles, transport: Images(bytes: Data()))
        let placeholder = try await media.images.placeholderFile()
        let validBytes = try files.readData(at: placeholder)
        let image = try #require(UIImage(data: validBytes)?.cgImage)
        #expect(image.width == 1 && image.height == 1)
        let pixels = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8,
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

    @Test(.timeLimit(.minutes(1))) func clearingCacheKeepsDownloads() async throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let bytes = try png(width: 2)
        let transport = Images(bytes: bytes)
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/image.png")
        _ = try await media.avatars.loadImage(for: url)
        let original = try await media.images.file(for: url)
        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        await media.clearCaches()
        #expect(!files.fileExists(at: original))
        _ = try await media.avatars.loadImage(for: url)
        let reopened = environment(files: files, previewFiles: files, transport: transport)
        #expect(await reopened.avatars.data(for: url) == bytes)
        #expect(await reopened.avatars.image(for: url)?.size.width == 2)
        #expect(files.fileExists(at: original))
        let downloaded = try await media.images.file(for: url)
        #expect(try await media.previewFile(at: downloaded) == downloaded)
        #expect(try files.readData(at: downloaded) == bytes)
        #expect(transport.requests == 2)

        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        let owner = UUID()
        media.beginPreview(owner: owner)
        let local = try await media.localPreviewFile(data: bytes, owner: owner)
        #expect(try files.readData(at: local) == bytes)
        await media.endPreview(owner: owner).value
        #expect(files.fileExists(at: local) == false)

        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        let placeholder = try await media.images.placeholderFile()
        #expect(try await media.previewFile(at: placeholder) == placeholder)
        #expect(UIImage(data: try files.readData(at: placeholder)) != nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func successiveGalleryAndWritesEnforceBudget(avatar: Bool) async throws {
        let files = PreferenceMemoryFiles()
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { 1 })
        await quota.enforce()
        let initialScans = files.metadataScanCount
        let bytes = try png(width: 2) + Data(repeating: 1, count: 600_000)
        let images = RemoteImageCache(
            files: files, quota: quota,
            httpClient: HTTPClient(transport: Images(bytes: bytes), observer: nil))
        let avatars = CachedRemoteImageStore(files: files, resources: images)
        for index in 0..<3 {
            let url = AppURL.required("https://example.invalid/image\(index).png")
            if avatar {
                _ = try await avatars.loadImage(for: url)
                #expect(await avatars.data(for: url) == bytes)
            } else {
                let file = try await images.file(for: url)
                #expect(try files.readData(at: file) == bytes)
            }
            #expect(await quota.usedBytes() <= 1_048_576)
        }
        #expect(files.metadataScanCount == initialScans)
    }

    @Test(.timeLimit(.minutes(1))) func previewOwnershipRetainsPagesUntilCloses() async throws {
        let domain = "BIT101Tests.preview-file-ownership"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let files = PreferenceMemoryFiles()
        let client = HTTPClient(
            transport: Images(bytes: try png(width: 2) + Data(repeating: 1, count: 700_000)),
            observer: nil)
        let media = AppMedia.makeEnvironment(
            files: files, previewStorage: MediaPreviewStorage(files: files), defaults: defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        media.cacheLimitMB = 1
        let owner = UUID()
        media.beginPreview(owner: owner)
        let first = try await media.images.file(
            for: AppURL.required("https://example.invalid/first.png"))
        _ = try await media.previewFile(at: first, owner: owner)
        let second = try await media.images.file(
            for: AppURL.required("https://example.invalid/second.png"))
        _ = try await media.previewFile(at: second, owner: owner)
        let third = try await media.images.file(
            for: AppURL.required("https://example.invalid/third.png"))
        await media.enforceCurrentLimit()
        #expect(files.fileExists(at: first))
        #expect(files.fileExists(at: second))
        #expect(files.fileExists(at: third) == false)
        await media.endPreview(owner: owner).value
        await media.enforceCurrentLimit()
        #expect(await media.usedBytes() <= 1_048_576)
        await #expect(throws: CancellationError.self) {
            try await media.previewFile(at: first, owner: owner)
        }
    }

    @Test(.timeLimit(.minutes(1))) func previewBytesBelongAreRemovedOnClose() async throws {
        let files = PreferenceMemoryFiles()
        let previewFiles = PreferenceMemoryFiles()
        let media = environment(
            files: files, previewFiles: previewFiles, transport: Images(bytes: Data()))
        let bytes = try png(width: 2)
        let first = UUID()
        let second = UUID()
        media.beginPreview(owner: first)
        media.beginPreview(owner: second)
        let firstFile = try await media.localPreviewFile(data: bytes, owner: first)
        let secondFile = try await media.localPreviewFile(data: bytes, owner: second)
        #expect(firstFile == secondFile)
        #expect(files.totalRegularFileSize(at: files.temporaryDirectoryURL) == 0)
        await media.endPreview(owner: first).value
        #expect(try previewFiles.readData(at: secondFile) == bytes)
        await media.enforceCurrentLimit()
        #expect(previewFiles.fileExists(at: secondFile))
        await media.endPreview(owner: second).value
        #expect(previewFiles.fileExists(at: secondFile) == false)
        await #expect(throws: CancellationError.self) {
            try await media.localPreviewFile(data: bytes, owner: second)
        }
        let legacy = ImageCacheDirectories.gallery(using: previewFiles).appending(
            path: "local-legacy.png")
        let orphan = ImageCacheDirectories.gallery(using: previewFiles).appending(
            path: "preview-local-orphan.png")
        try previewFiles.writeData(bytes, to: orphan, options: [.atomic])
        let copiedLegacy = ImageCacheDirectories.gallery(using: previewFiles).appending(
            path: legacy.lastPathComponent)
        try previewFiles.writeData(bytes, to: copiedLegacy, options: [.atomic])
        let reopened = environment(
            files: files, previewFiles: previewFiles, transport: Images(bytes: Data()))
        await reopened.enforceCurrentLimit()
        #expect(previewFiles.fileExists(at: orphan) == false)
        #expect(previewFiles.fileExists(at: copiedLegacy) == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cacheCleanupKeepsRemotePreviewFiles(fails: Bool) async throws {
        let files = PreferenceMemoryFiles()
        let bytes = try png(width: 2)
        let media = environment(files: files, previewFiles: files, transport: Images(bytes: bytes))
        let cached = try await media.images.file(
            for: AppURL.required("https://example.invalid/active-preview.png"))
        let idle = try await media.images.file(
            for: AppURL.required("https://example.invalid/idle.png"))
        let first = UUID()
        let second = UUID()
        media.beginPreview(owner: first)
        media.beginPreview(owner: second)
        #expect(try await media.previewFile(at: cached, owner: first) == cached)
        #expect(try await media.previewFile(at: cached, owner: second) == cached)
        let legacyAvatar = ImageCacheDirectories.avatars(using: files).appending(path: "legacy.png")
        try files.createDirectory(at: legacyAvatar.deletingLastPathComponent())
        try files.writeData(bytes, to: legacyAvatar, options: [.atomic])
        files.setFailures(removal: fails)
        #expect(await media.clearCaches() == !fails)
        #expect(try files.readData(at: cached) == bytes)
        #expect(files.fileExists(at: idle) == fails)
        #expect(files.fileExists(at: legacyAvatar) == fails)
        files.setFailures()
        await media.endPreview(owner: first).value
        #expect(try files.readData(at: cached) == bytes)
        await media.endPreview(owner: second).value
        #expect(files.fileExists(at: cached) == false)
    }

    @Test(.timeLimit(.minutes(1))) func previewStorageRetainsFilesAcrossCleanup() async throws {
        let files = PreferenceMemoryFiles()
        let storage = MediaPreviewStorage(files: files)
        let client = HTTPClient(transport: Images(bytes: Data()), observer: nil)
        let first = AppMedia.makeEnvironment(
            files: files, previewStorage: storage, defaults: AppFileDirectories.defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        let ownerA = UUID()
        let ownerB = UUID()
        let bytes = try png(width: 2)
        first.beginPreview(owner: ownerA)
        let file = try await first.localPreviewFile(data: bytes, owner: ownerA)
        let second = AppMedia.makeEnvironment(
            files: files, previewStorage: storage, defaults: AppFileDirectories.defaults,
            imageHTTPClient: client, avatarHTTPClient: client)
        #expect(await second.clearCaches())
        #expect(files.fileExists(at: file))
        second.beginPreview(owner: ownerB)
        #expect(try await second.localPreviewFile(data: bytes, owner: ownerB) == file)
        #expect(await first.clearCaches())
        await first.endPreview(owner: ownerA).value
        await first.enforceCurrentLimit()
        #expect(try files.readData(at: file) == bytes)
        await second.endPreview(owner: ownerB).value
        #expect(files.fileExists(at: file) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func previewCreation() throws {
        let files = PreferenceMemoryFiles()
        let ownership = PreviewFileOwnership()
        let owner = UUID()
        let file = files.temporaryDirectoryURL.appending(path: "preview-creation.png")
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        ownership.begin(owner)
        defer { ownership.end(owner) }
        try ownership.materializeAndPin(file, using: files, owner: owner) {
            try files.writeData(Data("preview".utf8), to: file, options: [.atomic])
            DispatchQueue.global().async {
                ready.signal()
                ownership.withPaths { retained in
                    if !retained.contains(files.canonicalFileURL(file).path) {
                        Self.removeFileCatchingError(at: file, using: files)
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

    nonisolated static func removeFileCatchingError(at file: URL, using files: any AppFileService) {
        do {
            try files.removeItem(at: file)
        } catch {
            Issue.record(error)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func remotePreviewCopyPins() async throws {
        let files = PreferenceMemoryFiles()
        let previewFiles = PreferenceMemoryFiles()
        let ownership = PreviewFileOwnership()
        let owner = UUID()
        ownership.begin(owner)
        defer { ownership.end(owner) }
        let source = files.temporaryDirectoryURL.appending(path: "remote.png")
        let bytes = try png(width: 2)
        try files.writeData(bytes, to: source, options: [.atomic])
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { 0 })
        let images = RemoteImageCache(
            files: files, quota: quota,
            httpClient: HTTPClient(transport: Images(bytes: bytes), observer: nil))
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        previewFiles.interceptNextWrite {
            DispatchQueue.global().async {
                ready.signal()
                ownership.withPaths { retained in
                    let children =
                        (try? previewFiles.contentsOfDirectory(
                            at: ImageCacheDirectories.previews(using: previewFiles), options: []))
                        ?? []
                    for file in children
                    where !retained.contains(previewFiles.canonicalFileURL(file).path) {
                        Self.removeFileCatchingError(at: file, using: previewFiles)
                    }
                }
                finished.signal()
            }
            ready.wait()
            #expect(finished.wait(timeout: .now() + 1) == .timedOut)
        }
        let preview = try await images.previewFile(
            at: source, using: previewFiles, sharesStorage: false, ownership: ownership,
            owner: owner)
        try await waitForTestEvent { finished.wait(timeout: .now()) == .success }
        #expect(try previewFiles.readData(at: preview) == bytes)
    }

    @Test(.timeLimit(.minutes(1))) func clearingMediaReleasesDecodedMemoryCaches() async throws {
        let files = PreferenceMemoryFiles()
        let bytes = try png(width: 2)
        let media = environment(files: files, previewFiles: files, transport: Images(bytes: bytes))
        let url = AppURL.required("https://example.invalid/decoded.png")
        let original = try await media.images.file(for: url)
        let still = try #require(await media.stillDecoder.image(at: original))
        let animated = try #require(
            await media.animatedDecoder.image(at: original, reduceMotion: true))
        await media.clearCaches()
        let restored = try await media.images.file(for: url)
        let newStill = try #require(await media.stillDecoder.image(at: restored))
        let newAnimated = try #require(
            await media.animatedDecoder.image(at: restored, reduceMotion: true))
        #expect(newStill !== still)
        #expect(newAnimated !== animated)
    }

    @Test(.timeLimit(.minutes(1))) func memoryPressureReleasesCachedImages() async throws {
        let files = PreferenceMemoryFiles()
        let bytes = try png(width: 2)
        let transport = Images(bytes: bytes)
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/pressure.png")
        let file = try await media.images.file(for: url)
        let still = try #require(await media.stillDecoder.image(at: file))
        let animated = try #require(await media.animatedDecoder.image(at: file, reduceMotion: true))
        let avatar = try #require(await media.avatars.image(for: url))
        let display = MediaDisplayedImage()
        #expect(display.set(still, budget: media.displayBudget))
        let activeBytes = media.displayBudget.usedBytes
        await media.releaseCachedImages()
        #expect(display.image === still && media.displayBudget.usedBytes == activeBytes)
        #expect(await media.images.cachedFile(for: url) == file)
        #expect(await media.avatars.diskData(for: url) == bytes)
        #expect(await media.stillDecoder.image(at: file) !== still)
        #expect(await media.animatedDecoder.image(at: file, reduceMotion: true) !== animated)
        #expect(await media.avatars.image(for: url) !== avatar)
        #expect(transport.requests == 1)
        display.clear()
        #expect(media.displayBudget.usedBytes == 0)
    }

    final class SuspendedCacheLimit {
        var pending: CheckedContinuation<Int, Never>?
        var secondPending: CheckedContinuation<Int, Never>?
        private var reads = 0
        private let suspendedReads: Int
        private let eventualLimit: Int
        init(suspendedReads: Int = 1, eventualLimit: Int = 0) {
            self.suspendedReads = suspendedReads
            self.eventualLimit = eventualLimit
        }
        func read() async -> Int {
            reads += 1
            guard reads <= suspendedReads else { return eventualLimit }
            let first = reads == 1
            return await withCheckedContinuation {
                if first { pending = $0 } else { secondPending = $0 }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func concurrentQuotaWaitsKeepDownloadsReadable(firstFinishesFirst: Bool, avatar: Bool)
        async throws
    {
        let files = PreferenceMemoryFiles()
        let limit = SuspendedCacheLimit(suspendedReads: 2, eventualLimit: 1)
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { await limit.read() })
        let bytes = try png(width: 2) + Data(repeating: 1, count: 600_000)
        let cache = RemoteImageCache(
            files: files, quota: quota,
            httpClient: HTTPClient(transport: Images(bytes: bytes), observer: nil))
        let avatars = CachedRemoteImageStore(files: files, resources: cache)
        let first = Task {
            try await cache.withFile(for: AppURL.required("https://example.invalid/first.png")) {
                try files.readData(at: $0)
            }
        }
        try await waitForTestEvent { limit.pending != nil }
        let second = Task {
            let url = AppURL.required("https://example.invalid/second.png")
            if avatar {
                let image = try #require(try await avatars.loadImage(for: url))
                #expect(image.size.width == 2)
                return bytes
            }
            return try await cache.withFile(for: url) { try files.readData(at: $0) }
        }
        try await waitForTestEvent { limit.secondPending != nil }
        if firstFinishesFirst {
            limit.pending?.resume(returning: 1)
            #expect(try await first.value == bytes)
            limit.secondPending?.resume(returning: 1)
            #expect(try await second.value == bytes)
        } else {
            limit.secondPending?.resume(returning: 1)
            #expect(try await second.value == bytes)
            limit.pending?.resume(returning: 1)
            #expect(try await first.value == bytes)
        }
        try await waitForTestEvent(isolation: quota) { $0.usedBytes() <= 1_048_576 }
    }

    @Test(.timeLimit(.minutes(1)))
    func imageReadLeaseSurvivesConcurrentQuotaPrune() async throws {
        let files = PreferenceMemoryFiles()
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { 1 })
        let bytes = try png(width: 2) + Data(repeating: 1, count: 600_000)
        let cache = RemoteImageCache(
            files: files, quota: quota,
            httpClient: HTTPClient(transport: Images(bytes: bytes), observer: nil))
        let pausedRead = SuspendedCacheLimit()
        let read = Task {
            try await cache.withFile(for: AppURL.required("https://example.invalid/reading.png")) {
                @MainActor file in
                _ = await pausedRead.read()
                return try files.readData(at: file)
            }
        }
        try await waitForTestEvent { pausedRead.pending != nil }
        _ = try await cache.file(for: AppURL.required("https://example.invalid/new.png"))
        await quota.enforce(force: true)
        pausedRead.pending?.resume(returning: 0)
        #expect(try await read.value == bytes)
        try await waitForTestEvent(isolation: quota) { $0.usedBytes() <= 1_048_576 }
    }

}
