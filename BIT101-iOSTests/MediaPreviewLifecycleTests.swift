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
        let animated = try #require(
            await media.animatedDecoder.image(at: file, reduceMotion: false))
        let frames = try #require(animated.images)
        let firstPixels = try #require(frames.first?.cgImage?.dataProvider?.data) as Data
        let firstFrameCount = frames.filter {
            ($0.cgImage?.dataProvider?.data as Data?) == firstPixels
        }.count
        let firstDuration = animated.duration * Double(firstFrameCount) / Double(frames.count)
        #expect(abs(firstDuration - firstDelay) < 0.001)
        #expect(abs(animated.duration - firstDuration - secondDelay) < 0.001)
        var unique = Set<ObjectIdentifier>()
        let actualBytes = frames.reduce(0) { bytes, frame in
            guard let pixels = frame.cgImage, unique.insert(ObjectIdentifier(pixels)).inserted
            else { return bytes }
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
        try await waitForTestEvent { view.image != nil }
        #expect(view.image?.images != nil)
        coordinator.load(url: url, into: view, media: media, reduceMotion: true)
        try await waitForTestEvent { view.image != nil }
        #expect(view.image?.images == nil)
        coordinator.load(url: url, into: view, media: media, reduceMotion: false)
        try await waitForTestEvent { view.image != nil }
        #expect(view.image?.images != nil && transport.requests == 1)
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
        let image = try #require(await decoder.image(at: file, reduceMotion: false))
        let pixels = try #require(image.cgImage)
        #expect(pixels.bytesPerRow * pixels.height <= budget)
        #expect(image.size.width < 4728 && image.size.height < 1701)
    }

    @Test(.timeLimit(.minutes(1))) func animatedImageDownsamplesFrames() async throws {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 4, nil))
        for color in [UIColor.systemRed, .systemGreen, .systemBlue, .systemYellow] {
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
        let decoder = RemoteAnimatedImageDecoder(files: files, maximumDecodedBytes: 4096)
        let image = try #require(await decoder.image(at: file, reduceMotion: false))
        let frames = try #require(image.images)
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.size.width < 64 && $0.size.height < 64 })
        #expect(
            frames.reduce(0) { $0 + ($1.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) } <= 4096)
        #expect(abs(image.duration - 0.4) < 0.001)
    }
}
