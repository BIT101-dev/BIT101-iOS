@testable import BIT101_iOS
import Foundation
import ImageIO
@testable import MediaKit
import StorageCore
import Testing
import TransportCore
import UIKit
import UniformTypeIdentifiers

@MainActor
struct MediaDependencyTests {
    private final class Images: HTTPTransport {
        let bytes: Data
        private(set) var requests = 0
        init(bytes: Data) { self.bytes = bytes }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            let url = try #require(request.url)
            return (bytes, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])))
        }
    }

    private func png(width: Int, color: UIColor = .systemBlue) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: 1), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        }
        return try #require(image.pngData())
    }

    private func environment(files: PreferenceMemoryFiles, previewFiles: PreferenceMemoryFiles, transport: Images) -> MediaEnvironment {
        let client = HTTPClient(transport: transport, observer: nil)
        return MediaEnvironment(files: files, previewFiles: previewFiles, defaults: AppFileDirectories.defaults,
                                imageHTTPClient: client, avatarHTTPClient: client)
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
        let firstURL = try await first.images.file(for: url, variant: .thumbnail)
        let secondURL = try await second.images.file(for: url, variant: .thumbnail)
        #expect(firstURL == secondURL)
        #expect(try await first.images.file(for: url, variant: .thumbnail) == firstURL)
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

    @Test func clearingCacheKeepsDownloadsLocalImagesAndQuickLookUsableInSameSession() async throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let bytes = try png(width: 2)
        let transport = Images(bytes: bytes)
        let media = environment(files: files, previewFiles: files, transport: transport)
        let url = AppURL.required("https://example.invalid/image.png")
        let original = try await media.images.file(for: url, variant: .original)
        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        #expect(!files.fileExists(at: original))
        let downloaded = try await media.images.file(for: url, variant: .original)
        #expect(try await media.previewFile(at: downloaded) == downloaded)
        #expect(try files.readData(at: downloaded) == bytes)
        #expect(transport.requests == 2)

        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        let local = try await media.images.localFile(data: bytes)
        #expect(try await media.previewFile(at: local) == local)
        #expect(try files.readData(at: local) == bytes)

        #expect(files.removeContents(of: files.temporaryDirectoryURL))
        let placeholder = try await media.images.placeholderFile()
        #expect(try await media.previewFile(at: placeholder) == placeholder)
        #expect(UIImage(data: try files.readData(at: placeholder)) != nil)
    }

    @Test func gifFramesAndReducedMotionReadInjectedBytes() async throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for color in [UIColor.systemRed, UIColor.systemBlue] {
            let image = try #require(UIImage(data: png(width: 1, color: color))?.cgImage)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let files = PreferenceMemoryFiles()
        let file = URL(fileURLWithPath: "/preference-sync/animation.gif")
        try files.writeData(data as Data, to: file, options: [.atomic])
        let media = environment(files: files, previewFiles: PreferenceMemoryFiles(), transport: Images(bytes: data as Data))
        let animated = try #require(await media.animatedDecoder.image(at: file, reduceMotion: false))
        #expect((animated.images?.count ?? 0) > 1)
        #expect(await media.animatedDecoder.image(at: file, reduceMotion: true)?.images == nil)
        #expect(await media.animatedDecoder.image(at: file, reduceMotion: true)?.size.width == 1)
    }
}
