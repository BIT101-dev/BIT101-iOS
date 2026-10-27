import Foundation
import TransportCore
#if os(iOS)
import UIKit
import ImageIO
#endif

public enum ImageDataCompressor {
    public static func importImages(from sources: [@MainActor () async throws -> Data?],
        prepare: @MainActor (Data) async throws -> Data, isCurrent: @MainActor () -> Bool,
        onPrepared: @MainActor (Data) -> Void, onFailure: @MainActor (any Error) -> Void) async {
        for source in sources {
            guard isCurrent(), !Task.isCancelled else { return }
            do {
                guard let data = try await source() else { throw URLError(.cannotDecodeContentData) }
                try Task.checkCancellation()
                let prepared = try await prepare(data)
                guard isCurrent() else { return }
                try Task.checkCancellation()
                onPrepared(prepared)
            } catch {
                guard isCurrent(), !TaskCancellation.matches(error) else { return }
                onFailure(error)
            }
        }
    }

#if os(iOS)
    @concurrent public nonisolated static func prepare(_ data: Data, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        let prepared = try compress(data, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        return prepared
    }

    public nonisolated static func compress(_ data: Data, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1600
                  ] as CFDictionary
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var best = try render(image: image, maxDimension: 1600, quality: 0.68)
        if best.count <= maximumBytes { return best }

        for quality in [0.48, 0.32, 0.2] {
            best = try render(image: image, maxDimension: 1600, quality: quality)
            if best.count <= maximumBytes { return best }
        }

        for dimension in [1200, 900, 700, 512, 384, 256] {
            best = try render(image: image, maxDimension: CGFloat(dimension), quality: 0.5)
            if best.count <= maximumBytes { return best }
        }
        guard best.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return best
    }

    private nonisolated static func render(
        image: CGImage,
        maxDimension: CGFloat,
        quality: CGFloat
    ) throws -> Data {
        try Task.checkCancellation()
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = CGSize(
            width: max(1, width * scale),
            height: max(1, height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: quality) { context in
            context.cgContext.interpolationQuality = .medium
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        try Task.checkCancellation()
        return data
    }
#endif
}
