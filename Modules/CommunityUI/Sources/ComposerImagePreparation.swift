#if os(iOS)
import CommunityCore
import MediaKit
import Foundation

/// 每个编辑场景串行准备图片，压缩沿后台 actor 与既定草稿预算执行。
public actor ComposerImagePreparer {
    public init() {}
    public func prepare(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        let result = try ComposerDraftImageCompressor.compress(data)
        try Task.checkCancellation()
        return result
    }
}

public enum ComposerDraftImageCompressor {
    public nonisolated static let maximumBytes = ComposerDraftImagePolicy.maximumBytes

    public nonisolated static func compress(_ data: Data) throws -> Data {
        try ImageDataCompressor.compress(data, maximumBytes: maximumBytes)
    }
}
#endif
