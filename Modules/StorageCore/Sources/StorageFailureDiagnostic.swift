import Foundation

/// 存储诊断保留操作、系统错误码与已声明字段路径。
public nonisolated struct StorageFailureDiagnostic: Error, Equatable, Sendable {
    public let summary: String

    public init(_ error: any Error, operation: String, fields: Set<String> = []) {
        let kind: String
        let path: [any CodingKey]
        switch error {
        case DecodingError.keyNotFound(let key, let context): kind = "missing"; path = context.codingPath + [key]
        case DecodingError.typeMismatch(_, let context): kind = "type"; path = context.codingPath
        case DecodingError.valueNotFound(_, let context): kind = "null"; path = context.codingPath
        case DecodingError.dataCorrupted(let context): kind = "invalid"; path = context.codingPath
        default:
            let failure = error as NSError
            summary = "\(operation).\(failure.domain).\(failure.code)"
            return
        }
        let location = path.map { key in key.intValue != nil ? "[]" : fields.contains(key.stringValue) ? key.stringValue : "*" }
        summary = "\(operation).\(kind):\(location.isEmpty ? "$" : location.joined(separator: "."))"
    }
}
