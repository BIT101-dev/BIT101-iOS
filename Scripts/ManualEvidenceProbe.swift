import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct ManualEvidenceProbe {
    struct Limits {
        var encodedBytes: Int
        var decodedBytes: Int
        var videoSeconds: Double
        var videoFrames: Int
        var pdfPages: Int
        init?(_ arguments: [String]) {
            guard arguments.count == 5, let encodedBytes = Int(arguments[0]), let decodedBytes = Int(arguments[1]),
                  let videoSeconds = Double(arguments[2]), let videoFrames = Int(arguments[3]), let pdfPages = Int(arguments[4]),
                  encodedBytes > 0, decodedBytes > 0, videoSeconds.isFinite, videoSeconds > 0,
                  videoFrames > 0, pdfPages > 0 else { return nil }
            self.encodedBytes = encodedBytes; self.decodedBytes = decodedBytes; self.videoSeconds = videoSeconds
            self.videoFrames = videoFrames; self.pdfPages = pdfPages
        }
    }
    static let movieURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().appendingPathComponent("evidence-media.mp4")

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let limits = Limits(Array(arguments.prefix(5))) else { print("false"); return }
        let valid: Bool
        if CommandLine.arguments.contains("--self-test") {
            valid = await selfTest(limits: limits)
        } else {
            do {
                var data = Data()
                while data.count <= limits.encodedBytes {
                    let chunk = try FileHandle.standardInput.read(upToCount: min(65536, limits.encodedBytes + 1 - data.count)) ?? Data()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                valid = await decode(data, limits: limits)
            } catch { valid = false }
        }
        print(valid ? "true" : "false")
    }

    static func decode(_ data: Data, limits: Limits) async -> Bool {
        guard !data.isEmpty, data.count <= limits.encodedBytes else { return false }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) || data.starts(with: [0xff, 0xd8]) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source),
                  [UTType.png.identifier, UTType.jpeg.identifier].contains(type as String),
                  CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete else { return false }
            for index in 0..<CGImageSourceGetCount(source) {
                let valid = autoreleasepool {
                    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return false }
                    let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
                    guard depth > 0, depth <= 16, width <= limits.decodedBytes / (4 * ((depth + 7) / 8)) / height else { return false }
                    guard let image = CGImageSourceCreateImageAtIndex(source, index,
                        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return false }
                    return image.width > 0 && image.height > 0 && image.bytesPerRow <= limits.decodedBytes / image.height
                        && CGImageSourceGetStatusAtIndex(source, index) == .statusComplete
                }
                guard valid else { return false }
            }
            return true
        }
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  document.numberOfPages > 0, document.numberOfPages <= limits.pdfPages, document.isUnlocked,
                  let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            for index in 1...document.numberOfPages {
                guard let page = document.page(at: index) else { return false }
                let bounds = page.getBoxRect(.mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return false }
                context.saveGState()
                context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: 32, height: 32), rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(page)
                context.restoreGState()
            }
            return true
        }
        guard data.count >= 16, data[4..<8] == Data("ftyp".utf8) else { return false }
        do {
            try data.write(to: movieURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: movieURL) }
            let asset = AVURLAsset(url: movieURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= limits.videoSeconds, try await asset.load(.isPlayable),
                  let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
            let size = try await track.load(.naturalSize)
            guard size.width.isFinite, size.height.isFinite, abs(size.width) > 0, abs(size.height) > 0,
                  abs(size.width) <= Double(limits.decodedBytes) / 4 / abs(size.height) else { return false }
            let frameRate = try await track.load(.nominalFrameRate)
            guard frameRate.isFinite, Double(frameRate) * duration <= Double(limits.videoFrames) else { return false }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings:
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            guard reader.startReading() else { return false }
            var frames = 0
            var withinBudget = true
            while autoreleasepool(invoking: {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                guard let buffer = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetHeight(buffer) > 0 else {
                    withinBudget = false; return true
                }
                withinBudget = CVPixelBufferGetBytesPerRow(buffer) <= limits.decodedBytes / CVPixelBufferGetHeight(buffer)
                return true
            }) {
                frames += 1
                if !withinBudget || frames > limits.videoFrames { reader.cancelReading(); return false }
            }
            return frames > 0 && reader.status == .completed
        } catch { return false }
    }

    static func selfTest(limits: Limits) async -> Bool {
        guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        for type in [UTType.png, UTType.jpeg] {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), await decode(bytes as Data, limits: limits) else { return false }
            var smaller = limits
            smaller.decodedBytes = 16 * 16 * 4 - 1
            guard await decode(bytes as Data, limits: smaller) == false else { return false }
            smaller = limits; smaller.encodedBytes = bytes.length - 1
            guard await decode(bytes as Data, limits: smaller) == false else { return false }
        }
        let pdf = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        guard let consumer = CGDataConsumer(data: pdf), let document = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { return false }
        for _ in 0..<2 {
            document.beginPDFPage(nil)
            document.draw(image, in: bounds)
            document.endPDFPage()
        }
        document.closePDF()
        guard await decode(pdf as Data, limits: limits) else { return false }
        var smaller = limits; smaller.pdfPages = 1
        guard await decode(pdf as Data, limits: smaller) == false else { return false }
        do {
            try? FileManager.default.removeItem(at: movieURL)
            defer { try? FileManager.default.removeItem(at: movieURL) }
            let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings:
                [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes:
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                 kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
            writer.add(input)
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { return false }
            for frame in 0..<2 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)) else { return false }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { return false }
            let data = try Data(contentsOf: movieURL)
            guard await decode(data, limits: limits) else { return false }
            smaller = limits; smaller.videoSeconds = 0.5
            guard await decode(data, limits: smaller) == false else { return false }
            smaller = limits; smaller.videoFrames = 1
            return await decode(data, limits: smaller) == false
        } catch { return false }
    }
}
