@testable import BIT101_iOS
@testable import MediaKit
import ClientCore
import Foundation
import Testing
import TransportCore
import UIKit
import os

@MainActor
struct MediaAvailabilityTests {
    @Test(.timeLimit(.minutes(1)))
    func closingPreviewsReusesTheQuotaInventory() async throws {
        let helper = MediaDependencyTests(), files = PreferenceMemoryFiles()
        let media = helper.environment(files: files, previewFiles: files, transport: MediaDependencyTests.Images(bytes: Data()))
        await media.enforceCurrentLimit()
        let scans = files.metadataScanCount
        for _ in 0..<3 {
            let owner = UUID()
            media.beginPreview(owner: owner)
            let file = try await media.localPreviewFile(data: helper.png(width: 2), owner: owner)
            await media.endPreview(owner: owner).value
            #expect(!files.fileExists(at: file))
        }
        #expect(files.metadataScanCount == scans)
    }

    @Test(arguments: [8, 16, 32])
    func decodedMemoryBudgetIncludesComponentDepthAndPaddedRows(bits: Int) throws {
        let rowBytes = 64, height = 2
        let provider = try #require(CGDataProvider(data: Data(repeating: 0, count: rowBytes * height) as CFData))
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        if bits == 32 { info.insert(.floatComponents) }
        let pixels = try #require(CGImage(width: 3, height: height, bitsPerComponent: bits,
            bitsPerPixel: bits * 4, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let image = UIImage(cgImage: pixels), owner = UUID()
        #expect(MediaDisplayBudget.pixelBytes(image) == rowBytes * height)
        #expect(!MediaDisplayBudget(maximumBytes: rowBytes * height - 1).retain(image, owner: owner))
        let budget = MediaDisplayBudget(maximumBytes: rowBytes * height)
        #expect(budget.retain(image, owner: owner) && budget.usedBytes == rowBytes * height)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cacheWriteFailureKeepsDownloadedImagesAvailable(animated: Bool) async throws {
        let helper = MediaDependencyTests()
        let bytes = animated ? try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")) : try helper.png(width: 2)
        let transport = MediaDependencyTests.Images(bytes: bytes), files = PreferenceMemoryFiles()
        files.setFailures(writing: true)
        let media = helper.environment(files: files, previewFiles: PreferenceMemoryFiles(), transport: transport)
        let url = AppURL.required("https://example.invalid/available.png")
        func load() async throws -> UIImage? {
            try await media.images.withSource(for: url) { @MainActor source in
                if animated { return await media.animatedDecoder.image(from: source, reduceMotion: false) }
                return await media.stillDecoder.image(from: source)
            }
        }
        let first = try #require(await load())
        let repeated = try #require(await load())
        #expect(first === repeated && transport.requests == 1)
        await #expect(throws: (any Error).self) { try await media.images.file(for: url) }
        files.setFailures()
        let restored = try await media.images.file(for: url)
        #expect(try files.readData(at: restored) == bytes && transport.requests == 1)
        #expect(await media.images.cachedFile(for: url) == restored)
    }

    @Test(.timeLimit(.minutes(1)))
    func memoryPressureReleasesTransientEncodedImages() async throws {
        let helper = MediaDependencyTests(), files = PreferenceMemoryFiles()
        files.setFailures(writing: true)
        let transport = MediaDependencyTests.Images(bytes: try helper.png(width: 2))
        let media = helper.environment(files: files, previewFiles: PreferenceMemoryFiles(), transport: transport)
        let url = AppURL.required("https://example.invalid/transient.png")
        for expected in 1...2 {
            let loaded = try await media.images.withSource(for: url) { @MainActor source in
                await media.stillDecoder.image(from: source)
            }
            #expect(loaded != nil && transport.requests == expected)
            await media.releaseCachedImages()
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func legacyImageCleanupRunsOnTheStorageExecutor() async throws {
        let helper = MediaDependencyTests(), files = PreferenceMemoryFiles()
        let legacy = ImageCacheDirectories.gallery(using: files).appending(path: "low-legacy.png")
        try files.writeData(try helper.png(width: 2), to: legacy, options: [])
        let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        files.beforeNextEnumeration { onMain.withLock { $0 = Thread.isMainThread } }
        let media = helper.environment(files: files, previewFiles: PreferenceMemoryFiles(), transport: MediaDependencyTests.Images(bytes: Data()))
        try await waitForTestEvent { onMain.withLock { $0 != nil } }
        _ = await media.images.cachedFile(for: AppURL.required("https://example.invalid/absent.png"))
        #expect(onMain.withLock { $0 == false } && !files.fileExists(at: legacy))
    }

}
