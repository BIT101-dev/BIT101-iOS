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

extension MediaDependencyTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func clearingImagesInvalidatesDownloadQuota(avatar: Bool) async throws {
        let files = PreferenceMemoryFiles()
        let limit = SuspendedCacheLimit()
        let quota = ImageCacheDiskQuota(files: files, cacheLimitMB: { await limit.read() })
        let bytes = try png(width: 2)
        let cache = RemoteImageCache(
            files: files, quota: quota,
            httpClient: HTTPClient(transport: Images(bytes: bytes), observer: nil))
        let url = AppURL.required("https://example.invalid/quota.png")
        if avatar {
            let avatars = CachedRemoteImageStore(files: files, resources: cache)
            let preparation = Task { try await avatars.loadImage(for: url) }
            try await waitForTestEvent { limit.pending != nil }
            #expect(await avatars.clearAll())
            limit.pending?.resume(returning: 0)
            await #expect(throws: CancellationError.self) { try await preparation.value }
            #expect(await avatars.diskData(for: url) == nil)
        } else {
            let preparation = Task { try await cache.file(for: url) }
            try await waitForTestEvent { limit.pending != nil }
            await cache.clearAll()
            limit.pending?.resume(returning: 0)
            await #expect(throws: CancellationError.self) { try await preparation.value }
        }
        #expect(await cache.usedBytes() == 0)
        let restored = try await cache.file(for: url)
        #expect(try files.readData(at: restored) == bytes)
    }

    @Test(.timeLimit(.minutes(1))) func clearingAvatarsRejectsEarlierDownload() async throws {
        let transport = DelayedImages(bytes: try png(width: 2))
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: transport)
        let loader = CachedRemoteImageLoader()
        let url = AppURL.required("https://example.invalid/old.png")
        let download = Task { await loader.load(url: url, media: media) }
        try await waitForTestEvent { transport.pending != nil }
        await media.clearCaches()
        transport.pending?.resume()
        await download.value
        #expect(loader.image == nil)
        #expect(await media.avatars.data(for: url) == nil)
        #expect(
            files.totalRegularFileSize(at: try #require(files.directoryURL(.cachesDirectory))) == 0)
        let retry = Task { await loader.load(url: url, media: media) }
        try await waitForTestEvent { transport.requests >= 2 }
        transport.pending?.resume()
        await retry.value
        #expect(loader.image?.size.width == 2)
        #expect(await media.avatars.data(for: url) == transport.bytes)
    }

    @Test(.timeLimit(.minutes(1))) func anOldAvatarFailurePreservesTheNewURLImage() async throws {
        let transport = DelayedImages(bytes: try png(width: 2))
        let media = environment(
            files: PreferenceMemoryFiles(), previewFiles: PreferenceMemoryFiles(),
            transport: transport)
        let loader = CachedRemoteImageLoader()
        let old = Task {
            await loader.load(url: AppURL.required("https://example.invalid/old.png"), media: media)
        }
        try await waitForTestEvent { transport.pending != nil }
        await loader.load(url: AppURL.required("https://example.invalid/new.png"), media: media)
        #expect(loader.image?.size.width == 2)
        transport.pending?.resume(throwing: URLError(.timedOut))
        await old.value
        #expect(loader.image?.size.width == 2)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingOneImagePreservesDownload() async throws {
        let bytes = try png(width: 2)
        let transport = DelayedImages(bytes: bytes)
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/old.png")
        let first = Task { try await media.images.file(for: url) }
        try await waitForTestEvent { transport.pending != nil }
        let second = Task { try await media.images.file(for: url) }
        try await waitForTestEvent(isolation: media.images) { $0.waitingConsumerCount >= 2 }
        first.cancel()
        if case .success = await first.result { Issue.record("取消的等待者应立即结束") }
        #expect(transport.requests == 1)
        transport.pending?.resume()
        #expect(try files.readData(at: await second.value) == bytes)
    }

    @Test(.timeLimit(.minutes(1))) func clearingImagesCancelsWait() async throws {
        let transport = DelayedImages(bytes: try png(width: 2))
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: transport)
        let download = Task {
            try await media.images.file(for: AppURL.required("https://example.invalid/old.png"))
        }
        try await waitForTestEvent { transport.pending != nil }
        await media.clearCaches()
        if case .success = await download.result { Issue.record("缓存清理应终止既有下载") }
        transport.pending?.resume()
        try await waitForTestEvent { transport.finished != 0 }
        #expect(await media.images.waitingConsumerCount == 0)
        #expect(files.totalRegularFileSize(at: files.temporaryDirectoryURL) == 0)
    }

    @Test(.timeLimit(.minutes(1))) func previewPreparesPageRetainsAllPagePositions() async throws {
        let files = PreferenceMemoryFiles()
        let media = environment(files: files, previewFiles: files, transport: Images(bytes: Data()))
        let images = try (1...64).map { try #require(UIImage(data: png(width: $0))) }
        let request = ImagePreviewRequest(localImages: images, initialIndex: 63)
        media.beginPreview(owner: request.id)
        let coordinator = ImageQuickLookPresenter.Coordinator(media: media)
        let prepared = try await coordinator.prepareInitialItems(for: request, media: media)
        #expect(prepared.initialIndex == 63 && prepared.items.count == 64)
        let selectedFile = try #require(prepared.items[63].url)
        #expect(UIImage(data: try files.readData(at: selectedFile))?.size.width == 64)
        #expect(prepared.items.dropLast().allSatisfy { $0.url != selectedFile })
        let localFiles = try files.contentsOfDirectory(
            at: ImageCacheDirectories.previews(using: files), options: []
        )
        .filter { $0.lastPathComponent.hasPrefix("preview-local-") }
        #expect(localFiles == [selectedFile])
        await media.endPreview(owner: request.id).value
        #expect(files.fileExists(at: selectedFile) == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["gif", "png"])
    func productionImageProbeChecksAnimation(damaged: Bool, format: String) async throws {
        let data = NSMutableData()
        let files = PreferenceMemoryFiles()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for color in [UIColor.systemRed, .systemBlue] {
            let pixels = try #require(UIImage(data: png(width: 1, color: color))?.cgImage)
            CGImageDestinationAddImage(
                destination, pixels,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            )
        }
        #expect(CGImageDestinationFinalize(destination))
        let complete = format == "gif" ? data as Data : try png(width: 2)
        let bytes = damaged ? Data(complete.dropLast(format == "gif" ? 1 : 12)) : complete
        let media = environment(files: files, previewFiles: files, transport: Images(bytes: bytes))
        let url = AppURL.required("https://example.invalid/probe.gif")
        if damaged {
            #expect(BoundedStillImageDecoder.image(from: bytes) == nil)
            await #expect(throws: (any Error).self) { try await media.avatars.loadImage(for: url) }
            #expect(await media.avatars.data(for: url) == nil)
            await #expect(throws: (any Error).self) { try await media.images.file(for: url) }
            #expect(await media.images.cachedFile(for: url) == nil)
            await #expect(throws: (any Error).self) { try await media.verifyRemoteImage(at: url) }
        } else {
            #expect(BoundedStillImageDecoder.image(from: bytes) != nil)
            #expect(try await media.verifyRemoteImage(at: url) == bytes.count * 2)
        }
        await media.clearCaches()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0.4, 0.02])
    func gifFramesAndReducedMotionReadInjectedBytes(firstDelay: Double) async throws {
        let secondDelay = firstDelay == 0.4 ? 0.1 : 0.5
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for (color, delay) in [(UIColor.systemRed, firstDelay), (UIColor.systemBlue, secondDelay)] {
            let image = try #require(UIImage(data: png(width: 1, color: color))?.cgImage)
            CGImageDestinationAddImage(
                destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
                    as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let files = PreferenceMemoryFiles()
        let file = URL(fileURLWithPath: "/preference-sync/animation.gif")
        try files.writeData(data as Data, to: file, options: [.atomic])
        let transport = Images(bytes: data as Data)
        let media = environment(
            files: files, previewFiles: PreferenceMemoryFiles(), transport: transport)
        let sequence = try #require(await media.animatedDecoder.sequence(at: file))
        #expect(sequence.count == 2)
        let first = try #require(await sequence.frame(at: 0))
        let second = try #require(await sequence.frame(at: 1))
        #expect(abs(first.duration - firstDelay) < 0.001)
        #expect(abs(second.duration - secondDelay) < 0.001)
        let firstPixels = try #require(first.image.cgImage?.dataProvider?.data) as Data
        let secondPixels = try #require(second.image.cgImage?.dataProvider?.data) as Data
        #expect(firstPixels != secondPixels)
        let view = UIImageView()
        let coordinator = RemoteAnimatedImage.Coordinator(media: media)
        let url = AppURL.required("https://example.invalid/motion.gif")
        coordinator.load(url: url, into: view, media: media, reduceMotion: false)
        try await waitForTestEvent { view.image != nil }
        try await waitForTestEvent {
            view.image?.cgImage?.dataProvider?.data as Data? == secondPixels
        }
        coordinator.load(url: url, into: view, media: media, reduceMotion: true)
        try await waitForTestEvent { view.image != nil }
        #expect(view.image?.cgImage?.dataProvider?.data as Data? == firstPixels)
        let still = view.image
        try await Task.sleep(for: .seconds(firstDelay + 0.1))
        #expect(view.image === still)
        coordinator.load(url: url, into: view, media: media, reduceMotion: false)
        try await waitForTestEvent { view.image != nil }
        try await waitForTestEvent {
            view.image?.cgImage?.dataProvider?.data as Data? == secondPixels
        }
        #expect(transport.requests == 1)
        coordinator.cancel(imageView: view)
    }

    @Test(.timeLimit(.minutes(1))) func wideJPEGRespectsAlignedDecodeBudget() async throws {
        let bytes = try #require(
            UIImage(data: png(width: 4728, height: 1701))?.jpegData(compressionQuality: 0.8))
        let files = PreferenceMemoryFiles()
        let budget = RemoteImageResourceLimits.maximumDecodedBytes / 2
        let file = files.temporaryDirectoryURL.appending(path: "wide.jpeg")
        try files.writeData(bytes, to: file, options: [])
        let decoder = RemoteAnimatedImageDecoder(files: files, maximumDecodedBytes: budget)
        let sequence = try #require(await decoder.sequence(at: file))
        let image = try #require(await sequence.frame(at: 0)?.image)
        let pixels = try #require(image.cgImage)
        #expect(pixels.bytesPerRow * pixels.height <= budget)
        #expect(image.size.width < 4728 && image.size.height < 1701)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [4, 40])
    func animatedFramesKeepDisplayPixels(count: Int) async throws {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil))
        let colors = [UIColor.systemRed, .systemGreen, .systemBlue, .systemYellow]
        for index in 0..<count {
            let color = colors[index % colors.count]
            let image = try #require(
                UIImage(data: png(width: 64, height: 64, color: color))?.cgImage)
            CGImageDestinationAddImage(
                destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            )
        }
        #expect(CGImageDestinationFinalize(destination))
        let files = PreferenceMemoryFiles()
        let file = files.temporaryDirectoryURL.appending(path: "budget.gif")
        try files.writeData(data as Data, to: file, options: [])
        let decoder = RemoteAnimatedImageDecoder(files: files, maximumDecodedBytes: 32768)
        let sequence = try #require(await decoder.sequence(at: file))
        let image = try #require(await sequence.frame(at: 0)?.image)
        #expect(sequence.count == count)
        for index in [0, count - 1] {
            let frame = try #require(await sequence.frame(at: index))
            let pixels = try #require(frame.image.cgImage)
            #expect(pixels.width == 64 && pixels.height == 64)
            #expect(pixels.bytesPerRow * pixels.height <= 32768)
            #expect(abs(frame.duration - 0.1) < 0.001)
        }
        #expect(image.size == CGSize(width: 64, height: 64))
    }
}
