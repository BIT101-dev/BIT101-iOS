import Compression
import Foundation

/// Plain JSON remains readable for snapshots written by earlier app versions.
nonisolated enum ScoreCacheSyncPayloadCodec {
    private static let magic = Data([0x42, 0x49, 0x54, 0x31, 0x30, 0x31, 0x4c, 0x5a, 0x46, 0x53, 0x45, 0x01])
    static let maximumDecodedSize = 32 * 1_024 * 1_024

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let json = try JSONEncoder().encode(value)
        guard !json.isEmpty, json.count <= maximumDecodedSize else { return json }

        var compressed = Data(count: json.count + 64)
        let compressedCount = json.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard compressedCount > 0, compressedCount < json.count else { return json }

        compressed.count = compressedCount
        var result = magic
        var originalSize = UInt64(json.count).bigEndian
        withUnsafeBytes(of: &originalSize) { result.append(contentsOf: $0) }
        result.append(compressed)
        return result
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.starts(with: magic) else {
            return try JSONDecoder().decode(type, from: data)
        }

        let sizeStart = magic.count
        let payloadStart = sizeStart + MemoryLayout<UInt64>.size
        guard data.count > payloadStart else { throw CocoaError(.coderReadCorrupt) }

        let originalSize = data[sizeStart..<payloadStart].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard originalSize > 0, originalSize <= UInt64(maximumDecodedSize) else {
            throw CocoaError(.coderReadCorrupt)
        }

        var decoded = Data(count: Int(originalSize))
        let compressed = data.dropFirst(payloadStart)
        let decodedCount = compressed.withUnsafeBytes { source in
            decoded.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decodedCount == Int(originalSize) else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(type, from: decoded)
    }
}


/// 载荷计算消费不可变快照，返回后由协调器确认账号和版本。
nonisolated enum PreferenceCloudPayloadCodec {
    @concurrent
    static func encode<Payload: Codable & Sendable>(_ envelope: ExperimentalPreferenceSyncEnvelope<Payload>,
        seal: (@Sendable (Data) throws -> Data)?) async throws -> Data {
        try Task.checkCancellation()
        let data = try seal.map { try $0(ScoreCacheSyncPayloadCodec.encode(envelope)) } ?? JSONEncoder().encode(envelope)
        try Task.checkCancellation()
        return data
    }

    @concurrent
    static func decode<Payload: Codable & Sendable>(_ type: Payload.Type,
        open: @Sendable () throws -> Data) async throws -> ExperimentalPreferenceSyncEnvelope<Payload> {
        try Task.checkCancellation()
        let envelope = try ScoreCacheSyncPayloadCodec.decode(ExperimentalPreferenceSyncEnvelope<Payload>.self, from: open())
        try Task.checkCancellation()
        return envelope
    }
}
