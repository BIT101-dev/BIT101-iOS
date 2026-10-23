#if os(iOS)
import Foundation
import UIKit
import ImageIO

public enum ImageDataCompressor {
    public nonisolated static func compress(_ data: Data, maximumBytes: Int) throws -> Data {
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

        var best = render(image: image, maxDimension: 1600, quality: 0.68)
        if best.count <= maximumBytes { return best }

        for quality in [0.48, 0.32, 0.2] {
            best = render(image: image, maxDimension: 1600, quality: quality)
            if best.count <= maximumBytes { return best }
        }

        for dimension in [1200, 900, 700, 512, 384, 256] {
            best = render(image: image, maxDimension: CGFloat(dimension), quality: 0.5)
            if best.count <= maximumBytes { return best }
        }
        guard best.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return best
    }

    private nonisolated static func render(
        image: CGImage,
        maxDimension: CGFloat,
        quality: CGFloat
    ) -> Data {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = CGSize(
            width: max(1, width * scale),
            height: max(1, height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: quality) { context in
            context.cgContext.interpolationQuality = .medium
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif
